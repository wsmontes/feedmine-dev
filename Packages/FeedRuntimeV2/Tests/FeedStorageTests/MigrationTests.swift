import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// The migration matrix of ADR-004 D11 on real on-disk databases: empty, reopen, previous version,
/// interrupted. Erase-on-schema-change is prohibited, so nothing here may recreate a database.
final class MigrationTests: RuntimeV2TestCase {
    /// One migration that fails after writing, to prove a migration is all-or-nothing.
    private enum MigrationProbe: Error {
        case interrupted
    }

    func testEmptyDatabaseMigratesWithCleanIntegrityAndForeignKeys() throws {
        let database = try freshDatabase(named: "empty")

        XCTAssertEqual(
            try database.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") },
            "ok"
        )
        XCTAssertTrue(
            try database.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty,
            "a freshly migrated database has no dangling reference"
        )

        let tables = try database.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        // Every table an applied migration of this build must leave behind, grouped by the slice that
        // owns it. The list is deliberately literal: a migration that silently stops creating a table
        // is the failure this asserts against, and deriving the expectation from the migrated database
        // itself would assert nothing.
        for expected in [
            // PR-00/PR-03: metadata, acquisition, identity and canonical state.
            "acquisition_target", "connector_checkpoint", "admission_batch", "connector_evidence",
            "source", "provider", "source_binding_runtime", "external_identity",
            "legacy_source_map", "legacy_item_map",
            "origin_record", "origin_revision", "source_membership", "provider_attribution",
            "content_relation", "media_candidate", "interaction_offer",
            "selection_supply", "supply_generation", "origin_search", "runtime_metadata",
            // PR-04: the runtime's own user-state projection.
            "user_state_projection", "user_state_watermark",
            // PR-06: the publication aggregate and the minimal local media commit.
            "feed_edition", "feed_segment", "published_card", "published_asset_ref",
            "asset_version", "media_preparation",
            // PR-07: the session cursor, the exposure log and the projections policy reads.
            "session_checkpoint", "exposure_fact", "exposure_policy",
            "history_projection", "history_policy",
            // PR-16: the declared retention limits and the durable account of each GC run.
            "retention_policy", "gc_run", "gc_run_class",
        ] {
            XCTAssertTrue(tables.contains(expected), "the migrated schema must create \(expected)")
        }

        // Tables a *later* slice owns are still absent, and each one names its owner so the next slice
        // updates a name instead of rediscovering this test.
        //
        // `asset_pin` carries no owner on purpose. PR-08 was expected to want it, and did not: the pin
        // and GC mechanism it delivered is in memory, in `FeedMedia/DecodedImageCache.swift`
        // (`protectedByPin`, quotas per eviction class, `MediaEvictionReport`), which is where the PR-08
        // spec asked for it. A durable pin table is therefore unowned, and whichever slice needs pins
        // that outlive the process must claim it here rather than assume PR-08 left one behind.
        //
        // PR-16 closed its two entries the other way: the coordinator decides across classes what may
        // be collected and records every run, and a durable account has to outlive the process that
        // produced it, so `retention_policy` and `gc_run` moved into the must-exist list above (with
        // `gc_run_class`, their per-class result, in the same migration). The decision is recorded
        // here rather than left implicit in a diff.
        let laterSlices = [
            "asset_pin": "nobody yet: PR-08's pins are in-memory (FeedMedia/DecodedImageCache.swift)",
        ]
        for (absent, owner) in laterSlices.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(tables.contains(absent), "\(absent) belongs to \(owner)")
        }

        // The migration records derived metadata, and nothing that could disagree with the migrator.
        XCTAssertEqual(
            try database.read { try RuntimeMetadata.read($0, key: RuntimeMetadata.schemaNameKey) },
            "runtime-v2"
        )
        XCTAssertNil(
            try database.read { try RuntimeMetadata.read($0) },
            "runtime_metadata is not a second migration counter (ADR-004 D4)"
        )
        XCTAssertEqual(
            try database.read { try Int64.fetchOne($0, sql: "SELECT value FROM supply_generation WHERE id = 1") },
            0
        )
        // The append-only guard exists as a trigger, not only as a comment.
        XCTAssertEqual(
            try database.read { try Int64.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'trg_origin_revision_append_only'") },
            1
        )
    }

    func testReopeningAppliesNoMigrationAndChangesNoData() throws {
        let location = freshLocation(named: "reopen")
        let first = try RuntimeDatabase(location: location)
        try registerTarget(in: first)
        try insertSource(in: first)
        let migrations = try first.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        let before = try dump(in: first)

        let reopened = try RuntimeDatabase(location: location)

        XCTAssertEqual(
            try reopened.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") },
            migrations,
            "a second launch performs no migration"
        )
        XCTAssertEqual(try dump(in: reopened), before)
        XCTAssertEqual(try rowCount("source", in: reopened), 1)
        XCTAssertEqual(try reopened.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }, "ok")
        XCTAssertEqual(try reopened.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }?.lowercased(), "wal")
    }

    /// A database written by the previous schema version migrates forward without losing its rows.
    func testDatabaseAtThePreviousSchemaVersionMigratesForward() throws {
        let location = freshLocation(named: "v1")
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)

        var previous = DatabaseMigrator()
        previous.registerMigration("v1_runtime_metadata") { database in
            try database.execute(sql: """
                CREATE TABLE runtime_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """)
        }
        let queue = try DatabaseQueue(path: location.databaseURL.path)
        try previous.migrate(queue)
        try queue.write { database in
            try RuntimeMetadata.write(database, value: "1")
        }
        try queue.close()

        let migrated = try RuntimeDatabase(location: location)

        XCTAssertEqual(
            try migrated.read { try RuntimeMetadata.read($0) },
            "1",
            "the previous version's rows survive the upgrade"
        )
        XCTAssertEqual(
            try migrated.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") },
            "ok"
        )
        XCTAssertEqual(
            try migrated.read { try Int64.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'origin_revision'") },
            1
        )
        XCTAssertEqual(
            try migrated.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") },
            try freshDatabase(named: "current-schema").read {
                try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            },
            "a database carried forward from v1 receives exactly the migrations this build registers"
        )
    }

    /// A migration that dies half way is neither applied nor marked applied, and the schema keeps
    /// whatever the previous migrations committed (ADR-004 D11, "interrupted migration").
    func testInterruptedMigrationIsNotRecordedAsApplied() throws {
        let location = freshLocation(named: "interrupted")
        var failed = RuntimeMigrations.current
        failed.registerMigration("v3_interrupted") { database in
            try database.execute(sql: "CREATE TABLE half_written (id INTEGER PRIMARY KEY)")
            throw MigrationProbe.interrupted
        }

        XCTAssertThrowsError(try RuntimeDatabase(location: location, migrator: failed))

        let queue = try DatabaseQueue(path: location.databaseURL.path)
        // The invariant is "everything before the interrupted migration is applied, the interrupted one is
        // not" — derived from this build's own migrations instead of pinned, so registering a later
        // migration cannot make this test assert a schema that no longer exists.
        let appliedIdentifiers = try queue.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        XCTAssertEqual(
            appliedIdentifiers,
            try freshDatabase(named: "interrupted-baseline").read {
                try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            },
            "an interrupted migration is not recorded as applied, and the ones before it stay applied"
        )
        XCTAssertEqual(
            try queue.read { try Int64.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'half_written'") },
            0,
            "and it left nothing behind"
        )
        XCTAssertEqual(
            try queue.read { try Int64.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'origin_record'") },
            1,
            "the migrations that did commit stay applied"
        )
        try queue.close()

        // A corrected migrator finishes the schema instead of restarting it.
        var repaired = RuntimeMigrations.current
        repaired.registerMigration("v3_interrupted") { database in
            try database.execute(sql: "CREATE TABLE half_written (id INTEGER PRIMARY KEY)")
        }
        let database = try RuntimeDatabase(location: location, migrator: repaired)
        let repairedIdentifiers = try database.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        let baseline = try freshDatabase(named: "interrupted-repaired").read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        XCTAssertEqual(
            repairedIdentifiers,
            (baseline + ["v3_interrupted"]).sorted(),
            "the repaired migrator applies exactly the pending migration and never re-runs a committed one"
        )
        XCTAssertEqual(
            try database.read { try Int64.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'half_written'") },
            1
        )
    }

    /// A schema this build does not know is never erased, reset or rebuilt: the migrations are
    /// additive, `eraseDatabaseOnSchemaChange` stays off, and a table written by another build
    /// survives opening. Refusing a future schema explicitly is the recovery path of ADR-004 D9,
    /// which owns it in PR-16; what PR-03 must prove is that opening never destroys it.
    func testAnUnknownMigrationRecordNeverErasesTheDatabase() throws {
        let location = freshLocation(named: "future")
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: location.databaseURL.path)
        try queue.write { database in
            try database.execute(sql: """
                CREATE TABLE runtime_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                CREATE TABLE written_by_another_build (id INTEGER PRIMARY KEY, note TEXT NOT NULL);
                INSERT INTO grdb_migrations (identifier) VALUES ('v1_runtime_metadata');
                INSERT INTO grdb_migrations (identifier) VALUES ('v900_from_the_future');
                INSERT INTO runtime_metadata (key, value) VALUES ('last_purge_revision', '7');
                INSERT INTO written_by_another_build (id, note) VALUES (1, 'keep me');
                """)
        }
        try queue.close()

        let database = try RuntimeDatabase(location: location)

        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v900_from_the_future'", in: database),
            1,
            "an unknown migration record survives opening"
        )
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM written_by_another_build", in: database),
            1,
            "a table written by another build is not dropped (never erase on a schema mismatch)"
        )
        XCTAssertEqual(
            try string("SELECT value FROM runtime_metadata WHERE key = 'last_purge_revision'", in: database),
            "7",
            "durable metadata written before the open survives"
        )
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'origin_record'", in: database),
            1,
            "the known migrations are applied additively on top of what is already there"
        )
    }
}
