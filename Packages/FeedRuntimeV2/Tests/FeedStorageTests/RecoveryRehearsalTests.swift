import Foundation
import GRDB
import XCTest
import FeedDomain
@testable import FeedStorage

/// The recovery rehearsals of PR-16: each one *creates* the condition rather than describing it, and
/// each one asserts a recoverable state or an explicit diagnostic — never a silent empty database
/// (ADR-004 D9).
///
/// Three rehearsals live here — disk full, controlled corruption and an incompatible edition — plus the
/// compatible upgrade of a database at the shipped schema set. The other two need what this module does
/// not own: the kill switch flips a `RuntimeMode`, so its rehearsal lives where that type lives
/// (`FeedRuntimeTests/KillSwitchRehearsalTests`), and rollback needs a container fixture
/// (`RollbackRehearsalTests`).
final class RecoveryRehearsalTests: RuntimeV2TestCase {
    // MARK: - Disk full

    /// A real `SQLITE_FULL`, produced by capping the database's page count at the pages it already has.
    ///
    /// What D9 requires of this rehearsal is three things: the write is refused, the previous edition
    /// stays usable, and the failure is *classified* — a full disk has its own path (reclaim space),
    /// while a constraint violation is a caller error that retrying repeats.
    func testADiskFullWriteIsRefusedAndThePreviousStateStaysUsable() throws {
        let source = try ensureSource("catalog:alpha")
        let row = try insertSupplyRow(objectKey: "one", sourceIDs: [source], observedAt: 0)
        let context = try planContext()
        let draft = try openDraft(context: context, revisionTag: "rev-1")
        let receipt = try publish(
            repositories(),
            token: draft.token,
            cards: [
                CardInsertRecord(
                    frozen: try frozenCard(
                        edition: draft,
                        segmentOrdinal: 0,
                        absoluteOrdinal: 0,
                        record: row,
                        // The payload's editorial revision has to be the edition's: `restore` recomputes
                        // the digest against the edition's revision, and a card frozen under another one
                        // is a mismatch the write path does not currently refuse.
                        revisionTag: "rev-1"
                    ),
                    assetReferences: []
                )
            ],
            activation: .activate(successorOf: nil),
            pinned: [try OriginRevisionID(row.revisionID)]
        )
        let pagesBefore = try scalar("PRAGMA page_count", in: database)
        let revisionsBefore = try rowCount("origin_revision", in: database)
        let digestBefore = try string("SELECT payload_digest FROM published_card WHERE publication_card_id = \(receipt.cardIDs[0].rawValue)")
        // Precondition: the edition restores before the disk fills, so the assertion after the refused
        // write is about the refused write and not about the fixture.
        guard case .restored = try repositories().restore(context: context) else {
            return XCTFail("the fixture must restore cleanly before the disk fills")
        }

        // The disk fills: no page beyond the ones already on disk may be allocated.
        try database.write { db in
            try db.execute(sql: "PRAGMA max_page_count = \(pagesBefore)")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1")
        }

        var failure: Error?
        do {
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO origin_revision (
                        origin_record_id, payload_digest, headline, body_text, observed_at, created_at,
                        identity_confidence
                    ) VALUES (?, ?, 'too big for the disk', ?, 0, 0, 'high')
                    """, arguments: [row.recordID, Data("digest".utf8), String(repeating: "x", count: 400_000)])
            }
        } catch {
            failure = error
        }

        let thrown = try XCTUnwrap(failure, "the write must be refused when the disk cannot grow")
        XCTAssertEqual(
            RuntimeRecovery.reason(for: thrown),
            .diskFull,
            "a full disk has its own recovery path, so it must be classified: \(thrown)"
        )

        XCTAssertEqual(
            try string("SELECT payload_digest FROM published_card WHERE publication_card_id = \(receipt.cardIDs[0].rawValue)"),
            digestBefore,
            "the refused write changed no stored card"
        )
        XCTAssertEqual(try scalar("PRAGMA integrity_check"), 0, "0 rows means the integrity report was 'ok'")

        // The previous state stands, and it is *usable*: the edition still restores, the checkpoint is
        // untouched, and the refused row is not half-written.
        XCTAssertEqual(try rowCount("origin_revision", in: database), revisionsBefore)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM origin_revision WHERE headline = 'too big for the disk'", in: database),
            0
        )
        let restored = try repositories().restore(context: context)
        guard case .restored = restored else {
            return XCTFail("a full disk must not cost the edition that was already published: \(restored)")
        }
        XCTAssertEqual(try repositories().card(receipt.cardIDs[0])?.payload.title, "Headline")
        try assertPublicationIntegrity(label: "after a refused write")

        // Reclaiming space, not deleting data, is what makes writes possible again.
        try database.write { db in
            try db.execute(sql: "PRAGMA max_page_count = 1000000")
        }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO origin_revision (
                    origin_record_id, payload_digest, headline, body_text, observed_at, created_at,
                    identity_confidence
                ) VALUES (?, ?, 'fits now', 'small', 0, 0, 'high')
                """, arguments: [row.recordID, Data("digest-2".utf8)])
        }
        XCTAssertEqual(try rowCount("origin_revision", in: database), revisionsBefore + 1)
    }

    // MARK: - Controlled corruption

    func testAControlledCorruptionIsReportedReadOnlyAndRebuiltWithTheDamagedBytesPreserved() throws {
        let source = try ensureSource("catalog:alpha")
        let row = try insertSupplyRow(objectKey: "one", sourceIDs: [source], observedAt: 0)
        try database.checkpointWAL()
        let healthy = RuntimeDatabaseLocation(directory: directory)
        XCTAssertEqual(try RuntimeRecovery().inspect(healthy).outcome, .healthy)

        // The corruption is deliberate and page-scoped: the header stays valid, so the file is still a
        // database and the damage is what integrity_check is for.
        try database.pool.close()
        let fileURL = healthy.databaseURL
        let pageSize = 4_096
        let original = try Data(contentsOf: fileURL)
        XCTAssertGreaterThan(original.count, pageSize * 2)
        var damaged = original
        for offset in pageSize..<(pageSize * 2) {
            damaged[offset] = 0xFF
        }
        try damaged.write(to: fileURL)

        let inspection = try RuntimeRecovery().inspect(healthy)
        guard case let .readOnly(reason, quarantined) = inspection.outcome else {
            return XCTFail("corruption must be reported as read-only state, got \(inspection.outcome)")
        }
        XCTAssertFalse(inspection.outcome.isUsable)
        if case .corruption = reason {} else {
            XCTFail("the reason must name corruption, got \(reason)")
        }
        XCTAssertTrue(quarantined.isEmpty, "inspection preserves the damaged file in place; it moves nothing")

        // The rebuild is the authorised destructive step, and the damaged bytes survive it.
        let report = try RuntimeRecovery().rebuild(healthy, reason: reason, at: TestInstant.seconds(60))
        guard case let .rebuilt(into, preserved, rebuiltReason) = report.outcome else {
            return XCTFail("expected a controlled rebuild, got \(report.outcome)")
        }
        XCTAssertEqual(rebuiltReason, reason)
        XCTAssertEqual(into, healthy.databaseURL)
        XCTAssertFalse(preserved.isEmpty, "the damaged database must be preserved, not overwritten")
        let preservedURL = try XCTUnwrap(preserved.first { $0.lastPathComponent == "runtime-v2.sqlite" })
        XCTAssertEqual(
            try Data(contentsOf: preservedURL),
            damaged,
            "the quarantined file is the damaged file, byte for byte: a diagnosis needs the evidence"
        )

        // The fresh database is migrated, verified and *empty of the user's rows* — which is why it is
        // never built implicitly: the report says so, and it is a result rather than a silent state.
        XCTAssertEqual(try RuntimeRecovery().inspect(healthy).outcome, .healthy)
        let rebuilt = try RuntimeDatabase(location: healthy)
        XCTAssertEqual(try rowCount("origin_record", in: rebuilt), 0)
        XCTAssertEqual(try rowCount("feed_edition", in: rebuilt), 0)
        let schemaName = try rebuilt.read {
            try RuntimeMetadata.read($0, key: RuntimeMetadata.schemaNameKey)
        }
        XCTAssertEqual(schemaName, "runtime-v2")
        _ = row
    }

    // MARK: - Incompatible edition

    /// The edition's publication schema is not the database's version: D9's controlled refusal applies
    /// to the edition, and the rest of the database stays healthy and readable.
    func testAnIncompatibleEditionIsAnEditionScopedRefusalNotADatabaseOne() throws {
        let source = try ensureSource("catalog:alpha")
        let row = try insertSupplyRow(objectKey: "one", sourceIDs: [source], observedAt: 0)
        let context = try planContext()
        let draft = try openDraft(context: context, revisionTag: "rev-1")
        _ = try publish(
            repositories(),
            token: draft.token,
            cards: [
                CardInsertRecord(
                    frozen: try frozenCard(
                        edition: draft,
                        segmentOrdinal: 0,
                        absoluteOrdinal: 0,
                        record: row,
                        // The payload's editorial revision has to be the edition's: `restore` recomputes
                        // the digest against the edition's revision, and a card frozen under another one
                        // is a mismatch the write path does not currently refuse.
                        revisionTag: "rev-1"
                    ),
                    assetReferences: []
                )
            ],
            activation: .activate(successorOf: nil),
            pinned: [try OriginRevisionID(row.revisionID)]
        )
        // A newer build wrote this edition: the write path would refuse the version, so the fixture
        // writes it the way such a database arrives — already stored.
        try database.write { db in
            try db.execute(sql: "UPDATE feed_edition SET publication_schema_version = 99")
        }

        let outcome = try repositories().restore(context: context)
        XCTAssertEqual(outcome, .unsupportedPublicationSchemaVersion(99))
        XCTAssertEqual(RuntimeRecovery.editionReason(for: outcome), .incompatiblePublicationSchema(99))
        XCTAssertTrue(RuntimeRecovery.editionReason(for: outcome)?.isEditionScoped == true)

        // The database is fine; only the edition cannot be decoded. That distinction is what keeps the
        // cold/recovery classification from being read as "the database is broken".
        let inspection = try RuntimeRecovery().inspect(RuntimeDatabaseLocation(directory: directory))
        XCTAssertEqual(inspection.outcome, .healthy)
        XCTAssertNil(RuntimeRecovery.editionReason(for: .restored(draft, [])))
        XCTAssertNil(RuntimeRecovery.editionReason(for: .noEdition(context)))
    }

    // MARK: - Compatible upgrade

    /// A database written by the *shipped* schema set (every migration before the retention one) opens
    /// under this build with every durable row intact.
    ///
    /// This is the package's half of the upgrade rehearsal. The other half — build 17's *legacy*
    /// container relaunched over V2 data — is not producible here: the legacy schema belongs to the app
    /// target, and ADR-004 D12's window was already exercised at PR-13 close by a device run that
    /// counted the seeded user rows before and after a legacy relaunch (baseline §8.13.1). PR-17 owns
    /// the reinstall-over-V2 repeat.
    func testARuntimeDatabaseAtTheShippedSchemaSetUpgradesWithoutLosingARow() throws {
        let location = freshLocation(named: "upgrade")
        let shipped = try RuntimeDatabase(
            location: location,
            migrator: RuntimeMigrations.through("v5_session_and_exposure")
        )
        XCTAssertEqual(
            try shipped.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") },
            RuntimeMigrations.knownMigrationIdentifiers.filter {
                $0 != "v6_retention_schema" && $0 != "v7_user_list_membership"
            },
            "the fixture really is the shipped set, and it has neither the retention nor the list-membership migration"
        )
        try registerTarget(in: shipped)
        let sourceID = try insertSource(in: shipped)
        try shipped.write { db in
            // Dependency order: the identity row, then the record that names it, then the revision the
            // record points back at, then the relationships.
            try db.execute(sql: """
                INSERT INTO external_identity (
                    connector_namespace, scope_key, key_kind, external_key, key_digest, origin_record_id,
                    identity_confidence, first_observed_at, last_observed_at
                ) VALUES ('connector.test', 'feed-1', 'object', x'01', zeroblob(16), NULL, 'high', 0, 0)
                """)
            let identityID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO origin_record (
                    connector_namespace, scope_key, primary_identity_id, first_observed_at, last_observed_at
                ) VALUES ('connector.test', 'feed-1', ?, 0, 0)
                """, arguments: [identityID])
            let recordID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO origin_revision (
                    origin_record_id, payload_digest, headline, observed_at, created_at, identity_confidence
                ) VALUES (?, ?, 'Shipped headline', 0, 0, 'high')
                """, arguments: [recordID, Data("digest".utf8)])
            let revisionID = db.lastInsertedRowID
            try db.execute(
                sql: "UPDATE origin_record SET current_revision_id = ? WHERE id = ?",
                arguments: [revisionID, recordID]
            )
            try db.execute(
                sql: "UPDATE external_identity SET origin_record_id = ? WHERE id = ?",
                arguments: [recordID, identityID]
            )
            try db.execute(sql: """
                INSERT INTO source_membership (
                    origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at
                ) VALUES (?, ?, 'editorial', 0, 0)
                """, arguments: [recordID, sourceID.rawValue])
            try db.execute(sql: """
                INSERT INTO selection_supply (origin_record_id, origin_revision_id, source_id, observed_at)
                VALUES (?, ?, ?, 0)
                """, arguments: [recordID, revisionID, sourceID.rawValue])
            try db.execute(sql: """
                INSERT INTO user_state_projection (kind, subject_id, wanted, last_operation_id, revision, updated_at)
                VALUES ('bookmark', 'legacy-saved', 1, 'op-1', 1, 0)
                """)
            try db.execute(sql: """
                UPDATE user_state_watermark SET revision = 1, updated_at = 0 WHERE id = 1
                """)
            try db.execute(sql: """
                INSERT INTO feed_edition (
                    edition_id, context_key, editorial_revision, publication_schema_version, epoch, seed,
                    state, activated_at_ms, created_at_ms
                ) VALUES (1, ?, ?, 1, 1, x'01', 'active', 0, 0)
                """, arguments: [
                try planContext().canonicalSerialization,
                revisionDigest("rev-1"),
            ])
        }
        let tablesBefore = try shipped.read {
            try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        let rowsBefore = try dump(
            ["origin_record", "origin_revision", "external_identity", "source", "source_membership",
             "selection_supply", "user_state_projection", "user_state_watermark", "feed_edition",
             "admission_batch", "connector_checkpoint", "acquisition_target"],
            in: shipped
        )
        try shipped.pool.close()

        // The upgrade: the same location, this build's migrator.
        let upgraded = try RuntimeDatabase(location: location)
        let applied = try upgraded.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        XCTAssertEqual(applied, RuntimeMigrations.knownMigrationIdentifiers, "only the missing migration ran")
        XCTAssertEqual(
            try dump(
                ["origin_record", "origin_revision", "external_identity", "source", "source_membership",
                 "selection_supply", "user_state_projection", "user_state_watermark", "feed_edition",
                 "admission_batch", "connector_checkpoint", "acquisition_target"],
                in: upgraded
            ),
            rowsBefore,
            "no user row and no canonical row changed during the upgrade"
        )
        let tablesAfter = try upgraded.read {
            try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertTrue(
            try Set(tablesBefore).subtracting(tablesAfter).isEmpty,
            "no table disappeared during the upgrade"
        )
        XCTAssertEqual(
            try Set(tablesAfter).subtracting(tablesBefore),
            ["gc_run", "gc_run_class", "retention_policy", "user_list_membership"],
            "exactly the retention and list-membership migrations' tables are new"
        )
        XCTAssertEqual(
            try UserStateProjectionStore(database: upgraded).savedSubjects(kind: .bookmark),
            ["legacy-saved"],
            "the durable operation written before the upgrade is still resolvable"
        )
        XCTAssertEqual(try RuntimeRecovery().inspect(location).outcome, .healthy)
    }
}
