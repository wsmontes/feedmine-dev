import Foundation
import GRDB
import XCTest
import FeedDomain
@testable import FeedStorage

/// `rollbackPreservesBookmarksCollectionsAndReadState` — ADR-004 D12's rollback rehearsal, at the layer
/// this package owns.
///
/// The rehearsal models a container as the coexistence design describes it: a `user.sqlite` that is the
/// **authority** for bookmarks, collections and read state (ADR-004 D1), and the runtime database beside
/// it that projects what it needs and maps legacy items to canonical records. A V2 run is then rolled
/// back by relaunching in legacy mode — the runtime is not started at all — and the rehearsal asserts what
/// ADR-004 D12 requires of that relaunch: the user's rows are exactly what they were, the content a
/// bookmark needs is still hydratable, and nothing acquired twice.
///
/// The container's schema is *synthetic*: ADR-004 D11 asks for "supported-version databases with
/// synthetic data", and the real legacy schema belongs to the app target
/// (`feedmine/Services/UserStateStore.swift`), which this package may not import. The device half —
/// reinstalling build 17's binary over a database V2 wrote — is recorded in baseline §8.13.1 (the seeded
/// user rows were identical before and after a legacy relaunch) and is repeated by PR-17.
final class RollbackRehearsalTests: XCTestCase {
    private var root: URL!
    private var containerURL: URL!
    private var container: DatabaseQueue!
    private var database: RuntimeDatabase!

    /// The tables the legacy reader owns. Synthetic, minimal, and shaped like the authority they stand
    /// for: a bookmark list with items, one collection, and durable read history.
    private static let legacySchema = """
        CREATE TABLE bookmark_list (list_id INTEGER PRIMARY KEY, title TEXT NOT NULL, position INTEGER NOT NULL);
        CREATE TABLE bookmark_item (
            list_id INTEGER NOT NULL, item_id TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL,
            position INTEGER NOT NULL, PRIMARY KEY (list_id, item_id)
        );
        CREATE TABLE source_collection (
            collection_id INTEGER PRIMARY KEY, name TEXT NOT NULL, source_keys TEXT NOT NULL
        );
        CREATE TABLE read_history (
            item_id TEXT PRIMARY KEY, read_at REAL NOT NULL, clicked_at REAL
        );
        CREATE TABLE user_operation (operation_id TEXT PRIMARY KEY, kind TEXT NOT NULL, applied_at REAL);
        """

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr16-rollback-\(UUID().uuidString)", isDirectory: true)
        let runtimeDirectory = root.appendingPathComponent("RuntimeV2", isDirectory: true)
        containerURL = root.appendingPathComponent("user.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        container = try DatabaseQueue(path: containerURL.path)
        try container.write { db in
            for statement in Self.legacySchema.split(separator: ";") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try db.execute(sql: String(statement))
            }
        }
        database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: runtimeDirectory))
    }

    override func tearDownWithError() throws {
        container = nil
        database = nil
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
        containerURL = nil
        try super.tearDownWithError()
    }

    /// Everything the authority holds, as one comparable value: the legacy reader's view.
    private func containerFingerprint() throws -> String {
        try container.read { db in
            let tables = ["bookmark_list", "bookmark_item", "source_collection", "read_history", "user_operation"]
            var lines: [String] = []
            for table in tables {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1")
                lines.append("\(table)=\(rows.count)")
                for row in rows {
                    lines.append(Array(zip(row.columnNames, row.databaseValues))
                        .map { "\($0.0)=\($0.1)" }
                        .joined(separator: ","))
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    private func runtimeFingerprint() throws -> [String] {
        try dump(
            ["feed_edition", "feed_segment", "published_card", "asset_version", "origin_record",
             "origin_revision", "legacy_item_map", "user_state_projection", "user_state_watermark",
             "acquisition_target", "connector_checkpoint", "admission_batch"],
            in: database
        )
    }

    private func dump(_ tables: [String], in database: RuntimeDatabase) throws -> [String] {
        try database.read { db in
            var lines: [String] = []
            for table in tables {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1")
                lines.append("\(table)=\(rows.count)")
                for row in rows {
                    lines.append(Array(zip(row.columnNames, row.databaseValues))
                        .map { "\($0.0)=\($0.1)" }
                        .joined(separator: ","))
                }
            }
            return lines
        }
    }

    func testRollbackPreservesBookmarksCollectionsAndReadState() throws {
        // MARK: V2 full: a session publishes, the user saves a card in it, and the runtime projects
        // what it needs to know about that decision.
        let source = try database.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO source (editorial_key, canonicalization_version, display_title, created_at)
                VALUES ('catalog:alpha', 1, 'Alpha', 0)
                """)
            return db.lastInsertedRowID
        }
        let (recordID, revisionID) = try database.write { db -> (Int64, Int64) in
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
            let record = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO origin_revision (
                    origin_record_id, payload_digest, headline, observed_at, created_at, identity_confidence
                ) VALUES (?, ?, 'Saved headline', 0, 0, 'high')
                """, arguments: [record, Data("digest".utf8)])
            let revision = db.lastInsertedRowID
            try db.execute(
                sql: "UPDATE origin_record SET current_revision_id = ? WHERE id = ?",
                arguments: [revision, record]
            )
            try db.execute(
                sql: "UPDATE external_identity SET origin_record_id = ? WHERE id = ?",
                arguments: [record, identityID]
            )
            try db.execute(sql: """
                INSERT INTO source_membership (
                    origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at
                ) VALUES (?, ?, 'editorial', 0, 0)
                """, arguments: [record, source])
            try db.execute(sql: """
                INSERT INTO selection_supply (origin_record_id, origin_revision_id, source_id, observed_at)
                VALUES (?, ?, ?, 0)
                """, arguments: [record, revision, source])
            return (record, revision)
        }

        let context = try ContextKey(surface: .main, scopeKey: "main", planIdentity: "MainFeedPlan")
        let revision = try EditorialRevision(
            schemeVersion: EditorialRevision.currentSchemeVersion,
            digest: String(repeating: "ab", count: 32)
        )
        let repository = PublicationRepository(database: database)
        let draft = try repository.beginEdition(
            context: context,
            editorialRevision: revision,
            epoch: 1,
            seed: Data("edition-seed".utf8),
            successorOf: nil,
            at: TestInstant.epoch
        )
        let card = CardInsertRecord(
            frozen: try PublishedCardPayload.Frozen(
                editionID: draft.editionID,
                segmentOrdinal: 0,
                absoluteOrdinal: 0,
                origin: PublishedOrigin(
                    originRecordID: try OriginRecordID(recordID),
                    originRevisionID: try OriginRevisionID(revisionID),
                    sourceID: try SourceID(UInt64(source)),
                    providerID: nil,
                    sourceDisplayName: "Alpha",
                    providerDisplayName: nil
                ),
                title: "Saved headline",
                primaryText: "An excerpt",
                publishedAt: TestInstant.epoch,
                publishedAtKind: .authored,
                observationAt: TestInstant.epoch,
                media: .none,
                primaryAction: nil,
                interactionSummary: nil,
                renderContract: RenderContract.resolved(media: .none),
                editorialRevision: revision,
                publicationSchemaVersion: PublicationSchema.currentVersion
            ),
            assetReferences: []
        )
        let receipt = try repository.commit(
            SegmentCommitRequest(
                token: try repository.token(for: draft.editionID),
                segmentOrdinal: 0,
                absoluteOrdinalStart: 0,
                segmentSeed: Data("segment-seed".utf8),
                policyRevision: revision.digest,
                committedAt: TestInstant.epoch,
                activation: .activate(successorOf: nil),
                cards: [card],
                assets: [],
                mediaPreparations: [],
                pinnedRevisions: [try OriginRevisionID(revisionID)]
            )
        )
        let savedCardID = receipt.cardIDs[0]

        // The user's decision is written to the *authority* first, and the runtime projects it.
        try container.write { db in
            try db.execute(sql: "INSERT INTO bookmark_list (list_id, title, position) VALUES (1, 'Read later', 0)")
            try db.execute(sql: """
                INSERT INTO bookmark_item (list_id, item_id, url, title, position)
                VALUES (1, 'legacy-saved', 'https://example.test/saved', 'Saved headline', 0)
                """)
            try db.execute(sql: """
                INSERT INTO source_collection (collection_id, name, source_keys) VALUES (1, 'Tech', 'catalog:alpha')
                """)
            try db.execute(sql: """
                INSERT INTO read_history (item_id, read_at, clicked_at) VALUES ('legacy-saved', 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO read_history (item_id, read_at, clicked_at) VALUES ('legacy-other', 0, NULL)
                """)
            try db.execute(sql: """
                INSERT INTO user_operation (operation_id, kind, applied_at) VALUES ('op-1', 'set_bookmarked', 0)
                """)
        }
        try UserStateProjectionStore(database: database).apply(
            kind: .bookmark,
            subjectID: "legacy-saved",
            wanted: true,
            operationID: "op-1",
            at: TestInstant.epoch
        )
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO legacy_item_map (
                    legacy_item_id, legacy_source_url, origin_record_id, origin_revision_id,
                    confidence, mapped_at
                ) VALUES ('legacy-saved', 'https://example.test/saved', ?, ?, 'high', 0)
                """, arguments: [recordID, revisionID])
        }
        try database.write { db in
            try db.execute(sql: "UPDATE user_state_watermark SET revision = 1, updated_at = 0 WHERE id = 1")
        }

        // One acquisition target already exists, with its checkpoint at zero: the counter the rollback
        // must not move.
        try AcquisitionTargetStore(clock: FixedClock(now: TestInstant.epoch)).register(
            AcquisitionTargetID("target-1"),
            connectorKind: "rss",
            connectorVersion: "connector.test",
            bindingRevision: 1,
            in: database
        )
        let containerBefore = try containerFingerprint()
        let runtimeBefore = try runtimeFingerprint()

        // MARK: The rollback: a legacy relaunch. The runtime is not started, so nothing in the runtime
        // database is written and nothing is acquired; the authority is what the legacy reader sees.
        let legacyView = try container.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM bookmark_item WHERE list_id = 1 ORDER BY position")
        }
        XCTAssertEqual(legacyView.count, 1)

        XCTAssertEqual(try containerFingerprint(), containerBefore, "the legacy relaunch rewrote a user row")
        XCTAssertEqual(try runtimeFingerprint(), runtimeBefore, "the legacy relaunch touched the runtime database")
        // No double acquisition: the rollback starts no run, so no target was added, no batch was
        // admitted and no cursor moved. This is the half of ADR-004 D12's "no double acquisition" a
        // database can show; the other half (one owner per target) is the mode table's exclusivity.
        XCTAssertEqual(
            try database.read { try Int64.fetchOne($0, sql: "SELECT COUNT(*) FROM acquisition_target") } ?? 0,
            1,
            "the rollback did not register an acquisition target"
        )
        XCTAssertEqual(
            try database.read { try Int64.fetchOne($0, sql: "SELECT COUNT(*) FROM admission_batch") } ?? 0,
            0,
            "the rollback admitted no batch"
        )
        XCTAssertEqual(
            try database.read {
                try Int64.fetchOne(
                    $0,
                    sql: "SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'"
                )
            } ?? -1,
            0,
            "the rollback did not advance the checkpoint"
        )

        // MARK: Every bookmark still resolves, and the content it needs is still hydratable — through the
        // durable mapping and the frozen published payload, without joining legacy content rows.
        for item in legacyView {
            let itemID: String = item["item_id"]
            let mapping = try database.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT origin_record_id, origin_revision_id FROM legacy_item_map WHERE legacy_item_id = ?
                    """, arguments: [itemID])
            }
            let mapped = try XCTUnwrap(mapping, "bookmark \(itemID) has no durable mapping")
            let mappedRecordID: Int64 = mapped["origin_record_id"]
            let mappedRevisionID: Int64 = mapped["origin_revision_id"]
            // The canonical rows are still there, so the reader can be handed the revision it saved.
            XCTAssertEqual(
                try database.read { db in
                    try Int64.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM origin_revision WHERE id = ? AND origin_record_id = ?",
                        arguments: [mappedRevisionID, mappedRecordID]
                    )
                },
                1
            )
            // And it is published in a retained edition, with the frozen payload the card renders from.
            let publishedCardID = try database.read { db in
                try Int64.fetchOne(db, sql: """
                    SELECT c.publication_card_id
                    FROM published_card c
                    JOIN feed_edition e ON e.edition_id = c.edition_id
                    WHERE c.origin_record_id = ? AND e.state <> 'purged'
                    """, arguments: [mappedRecordID])
            }
            XCTAssertEqual(publishedCardID, savedCardID.rawValue)
            let stored = try XCTUnwrap(try repository.card(savedCardID))
            XCTAssertEqual(stored.payload.title, "Saved headline")
            XCTAssertEqual(stored.payload.origin.originRevisionID, try OriginRevisionID(mappedRevisionID))
        }
        XCTAssertEqual(
            try UserStateProjectionStore(database: database).savedSubjects(kind: .bookmark),
            ["legacy-saved"],
            "the runtime's projection of the authority is intact for the next V2 launch"
        )
        XCTAssertTrue(
            try RuntimeRecovery().inspect(RuntimeDatabaseLocation(directory: database.location.directory))
                .outcome.isUsable
        )
    }
}
