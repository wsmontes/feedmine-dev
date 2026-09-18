import XCTest
import FeedDomain
import FeedStorage
@testable import feedmine

/// PR-04: durable user state and recoverable compatibility (plan §5.2).
///
/// These assert the promise the user actually has: a bookmark is never orphaned into a bare id, a
/// retry never duplicates or inverts an action, and a crash between the two databases is repaired by
/// reconciliation rather than reported as success.
@MainActor
final class RuntimeV2UserStateBridgeTests: XCTestCase {

    private var tempDirectory: URL!
    private var runtimeDatabase: RuntimeDatabase!
    private var store: FeedStore!
    private var bridge: UserStateBridge!

    private let fixedDate = Date(timeIntervalSince1970: 1_789_400_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("userstate-bridge-\(UUID().uuidString)", isDirectory: true)
        runtimeDatabase = try RuntimeDatabase(
            location: RuntimeDatabaseLocation(directory: tempDirectory)
        )
        store = try FeedStore(inMemory: true)
        bridge = UserStateBridge(
            bookmarks: store.bookmarkStore,
            projections: UserStateProjectionStore(database: runtimeDatabase)
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        runtimeDatabase = nil
        store = nil
        bridge = nil
        try super.tearDownWithError()
    }

    private func item(id: String, url: String = "https://example.com/a", title: String = "An article") -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Example Feed",
            sourceURL: "https://example.com/feed.xml",
            category: "News",
            title: title,
            excerpt: "Excerpt body",
            url: url,
            imageURL: "https://example.com/a.jpg",
            publishedAt: fixedDate,
            region: "global"
        )
    }

    private func snapshot(_ item: FeedItem, at: Date) -> BookmarkSnapshot {
        BookmarkSnapshot(item: item, listID: store.bookmarkStore.defaultListID(), at: at)
    }

    // MARK: - The bookmark survives a content rebuild

    func testBookmarkSurvivesAContentDatabaseRebuild() async throws {
        let article = item(id: "item-a")
        // The content row is inserted directly on purpose: driving the publish path from here writes
        // shared page-cache files, and `FeedDisplayStateTests.test_pageCacheFollowsGrowthAndNeverRegresses`
        // then finds its own freshly written cache evicted (observed once: "the first publication is
        // cached" failed only in the full-suite run). This test needs a hydratable row, not a published page.
        let fetchedAt = Int(fixedDate.timeIntervalSince1970)
        try await store.db.write { db in
            try db.execute(sql: """
                INSERT INTO feed_item
                    (id, source_url, source_title, region, category, title, excerpt, url,
                     image_url, published_at, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    article.id, article.sourceURL, article.sourceTitle, article.region,
                    article.category, article.title, article.excerpt, article.url,
                    article.imageURL,
                    Int(article.publishedAt.timeIntervalSince1970),
                    fetchedAt
                ])
        }

        let state = await bridge.setBookmarked(
            itemID: article.id,
            wanted: true,
            operationID: "op-1",
            snapshot: snapshot(article, at: fixedDate),
            at: fixedDate
        )
        XCTAssertEqual(state.state, .applied)

        // Hydrated while the content row exists.
        let before = try await store.bookmarkStore.hydration()
        XCTAssertEqual(before.items.map(\.id), [article.id])
        XCTAssertTrue(before.snapshotOnly.isEmpty)

        // Rebuild the content database: the item row disappears, the bookmark must not become a bare id.
        try await store.db.write { db in
            try db.execute(sql: "DELETE FROM feed_item")
        }

        let after = try await store.bookmarkStore.hydration()
        XCTAssertTrue(after.items.isEmpty)
        XCTAssertEqual(after.snapshotOnly.map(\.itemID), [article.id])
        let surviving = try XCTUnwrap(after.snapshotOnly.first)
        XCTAssertEqual(surviving.title, article.title)
        XCTAssertEqual(surviving.url, article.url, "the saved URL is what lets the reader open it again")
        XCTAssertEqual(surviving.sourceTitle, article.sourceTitle)
        XCTAssertEqual(surviving.excerpt, article.excerpt)

        // The legacy accessor is unchanged: it still hydrates what the content database has, and drops
        // what it cannot hydrate. The snapshot is what replaced that silence.
        let legacy = try await store.bookmarkStore.bookmarkedItems()
        XCTAssertTrue(legacy.isEmpty)
        let snapshots = try await store.bookmarkStore.bookmarkSnapshots()
        XCTAssertEqual(snapshots.count, 1)
    }

    func testBookmarkOfContentTheContentDatabaseNeverHadStillCarriesItsSnapshot() async throws {
        let runtimeOnly = item(id: "runtime-only-1", url: "https://example.com/runtime-only")

        let state = await bridge.setBookmarked(
            itemID: runtimeOnly.id,
            wanted: true,
            operationID: "op-runtime-only",
            snapshot: snapshot(runtimeOnly, at: fixedDate),
            at: fixedDate
        )
        XCTAssertEqual(state.state, .applied)

        let hydration = try await store.bookmarkStore.hydration()
        XCTAssertTrue(hydration.items.isEmpty)
        XCTAssertEqual(hydration.snapshotOnly.map(\.itemID), [runtimeOnly.id])
        XCTAssertEqual(hydration.snapshotOnly.first?.url, "https://example.com/runtime-only")
    }

    // MARK: - Idempotence

    func testRetryWithTheSameOperationIdDoesNotRepeatTheWrite() async throws {
        let article = item(id: "item-b")

        let first = await bridge.setBookmarked(
            itemID: article.id, wanted: true, operationID: "op-2",
            snapshot: snapshot(article, at: fixedDate), at: fixedDate
        )
        let revisionAfterFirst = try UserStateProjectionStore(database: runtimeDatabase).watermark().revision

        let second = await bridge.setBookmarked(
            itemID: article.id, wanted: true, operationID: "op-2",
            snapshot: snapshot(article, at: fixedDate), at: fixedDate.addingTimeInterval(60)
        )

        XCTAssertEqual(first.state, .applied)
        XCTAssertEqual(second.state, .applied, "a retry answers with the stored outcome, it does not act twice")
        let savedIDs = try await store.bookmarkStore.allBookmarkedItemIDs()
        XCTAssertEqual(savedIDs.count, 1)
        XCTAssertEqual(
            try UserStateProjectionStore(database: runtimeDatabase).watermark().revision,
            revisionAfterFirst,
            "replaying an applied operation must not advance the projection"
        )
        XCTAssertEqual(
            try UserStateProjectionStore(database: runtimeDatabase).projection(kind: .bookmark, subjectID: article.id)?.lastOperationID,
            "op-2"
        )
    }

    func testRemovalIsAbsoluteAndLeavesNoSnapshot() async throws {
        let article = item(id: "item-c")
        _ = await bridge.setBookmarked(
            itemID: article.id, wanted: true, operationID: "op-3a",
            snapshot: snapshot(article, at: fixedDate), at: fixedDate
        )

        let removed = await bridge.setBookmarked(
            itemID: article.id, wanted: false, operationID: "op-3b", at: fixedDate
        )
        XCTAssertEqual(removed.state, .applied)

        let savedAfterRemoval = try await store.bookmarkStore.allBookmarkedItemIDs()
        let snapshotsAfterRemoval = try await store.bookmarkStore.bookmarkSnapshots()
        XCTAssertTrue(savedAfterRemoval.isEmpty)
        XCTAssertTrue(snapshotsAfterRemoval.isEmpty)
        let projection = try XCTUnwrap(
            try UserStateProjectionStore(database: runtimeDatabase).projection(kind: .bookmark, subjectID: article.id)
        )
        XCTAssertFalse(projection.wanted, "a removal is a projection too: it must not look like 'never saved'")
        XCTAssertFalse(
            try UserStateProjectionStore(database: runtimeDatabase).savedSubjects().contains(article.id)
        )
    }

    // MARK: - Crash between the two databases

    func testCrashBetweenTheDatabasesIsRepairedByReconcile() async throws {
        let article = item(id: "item-d")

        // Only the user side ran: the intention is stored and marked applied, the runtime never saw it.
        _ = try await store.bookmarkStore.setBookmarked(
            itemID: article.id, wanted: true, operationID: "op-4",
            snapshot: snapshot(article, at: fixedDate), at: fixedDate
        )
        XCTAssertNil(
            try UserStateProjectionStore(database: runtimeDatabase).projection(kind: .bookmark, subjectID: article.id),
            "precondition: the projection is missing, which no flag in user.sqlite can detect"
        )

        let report = await bridge.reconcile(at: fixedDate)
        XCTAssertEqual(report, ReplayReport(applied: 1, failed: 0))
        let projection = try XCTUnwrap(
            try UserStateProjectionStore(database: runtimeDatabase).projection(kind: .bookmark, subjectID: article.id)
        )
        XCTAssertTrue(projection.wanted)
        XCTAssertEqual(projection.lastOperationID, "op-4")
        let savedAfterReconcile = try await store.bookmarkStore.allBookmarkedItemIDs()
        XCTAssertTrue(savedAfterReconcile.contains(article.id))

        let secondReport = await bridge.reconcile(at: fixedDate.addingTimeInterval(1))
        XCTAssertEqual(secondReport, ReplayReport(applied: 0, failed: 0), "reconciling twice is not two writes")
    }

    func testLaunchReconcileRepairsBothBookmarkProjectionAndListMembership() async throws {
        let article = item(id: "item-launch-reconcile")

        // Simulate a process dying after user.sqlite committed but before either runtime projection.
        _ = try await store.bookmarkStore.setBookmarked(
            itemID: article.id,
            wanted: true,
            operationID: "op-launch-reconcile",
            snapshot: snapshot(article, at: fixedDate),
            at: fixedDate
        )
        let projections = UserStateProjectionStore(database: runtimeDatabase)
        XCTAssertNil(try projections.projection(kind: .bookmark, subjectID: article.id))
        let listID = await store.bookmarkStore.defaultListID()
        XCTAssertNil(
            try projections.listMembership(
                listKey: UserStateBridge.listKey(for: listID),
                subjectID: article.id
            )
        )

        let report = await bridge.reconcileForLaunch(at: fixedDate)

        XCTAssertEqual(report, ReplayReport(applied: 2, failed: 0))
        XCTAssertEqual(
            try projections.projection(kind: .bookmark, subjectID: article.id)?.lastOperationID,
            "op-launch-reconcile"
        )
        XCTAssertEqual(
            try projections.listMembership(
                listKey: UserStateBridge.listKey(for: listID),
                subjectID: article.id
            )?.lastOperationID,
            "op-launch-reconcile"
        )
        XCTAssertEqual(
            await bridge.reconcileForLaunch(at: fixedDate.addingTimeInterval(1)),
            ReplayReport(applied: 0, failed: 0),
            "the launch repair is idempotent across both projections"
        )
    }

    func testOnlyTheNewestOperationPerSubjectDecidesTheProjection() async throws {
        let article = item(id: "item-e")
        _ = await bridge.setBookmarked(
            itemID: article.id, wanted: true, operationID: "op-5a",
            snapshot: snapshot(article, at: fixedDate), at: fixedDate
        )
        _ = await bridge.setBookmarked(
            itemID: article.id, wanted: false, operationID: "op-5b", at: fixedDate.addingTimeInterval(30)
        )

        // A stale replay of the old operation must not resurrect the bookmark.
        try UserStateProjectionStore(database: runtimeDatabase).apply(
            kind: .bookmark, subjectID: article.id, wanted: true,
            operationID: "op-5a", at: fixedDate.addingTimeInterval(60)
        )
        let report = await bridge.reconcile(at: fixedDate.addingTimeInterval(120))
        XCTAssertEqual(report.applied, 1, "the newest operation is the one that gets re-projected")

        let projection = try XCTUnwrap(
            try UserStateProjectionStore(database: runtimeDatabase).projection(kind: .bookmark, subjectID: article.id)
        )
        XCTAssertFalse(projection.wanted)
        XCTAssertEqual(projection.lastOperationID, "op-5b")
    }

    // MARK: - A failure is reported, never hidden

    func testAFailedProjectionIsReportedAndTheIntentionSurvives() async throws {
        let article = item(id: "item-f")
        // Break the projection path on purpose: the runtime cannot accept writes any more.
        try runtimeDatabase.write { db in
            try db.execute(sql: "DROP TABLE user_state_projection")
        }

        let state = await bridge.setBookmarked(
            itemID: article.id, wanted: true, operationID: "op-6",
            snapshot: snapshot(article, at: fixedDate), at: fixedDate
        )

        XCTAssertEqual(state.state, .failed)
        let reason = try XCTUnwrap(state.reason)
        XCTAssertTrue(reason.contains("projection"), reason)
        let savedIntention = try await store.bookmarkStore.allBookmarkedItemIDs()
        XCTAssertTrue(
            savedIntention.contains(article.id),
            "the bookmark is the user's intention and it is stored; only the projection is owed"
        )
        let operations = await store.bookmarkStore.newestOperationsBySubject()
        let operation = try XCTUnwrap(operations.first { $0.subjectID == article.id })
        XCTAssertEqual(operation.state, .failed)
        XCTAssertNotNil(operation.failureReason)
    }

    /// The watermark moves for a real change and stands still for a replay.
    ///
    /// It deliberately does not pin a count *per save*: one bookmark now writes two projections (the
    /// whole-set state and the list membership a box is selected by, `baseline.md` §8.59), so a save
    /// advances the revision twice. What the watermark is for — letting a reader detect what changed
    /// between two projections — is served by either, and the invariant that matters is the one this
    /// test now states: a replay writes nothing and therefore moves nothing.
    func testProjectionWatermarkAdvancesOnlyWithRealChanges() async throws {
        let first = item(id: "item-g")
        let second = item(id: "item-h")
        _ = await bridge.setBookmarked(
            itemID: first.id, wanted: true, operationID: "op-7a",
            snapshot: snapshot(first, at: fixedDate), at: fixedDate
        )
        let afterFirst = try UserStateProjectionStore(database: runtimeDatabase).watermark()
        XCTAssertGreaterThan(afterFirst.revision, 0, "a real change advances the watermark")

        // The half the test's name promises: the same operation, replayed. It is a no-op that answers the
        // current revision and writes nothing, which is what makes a rejected retry safe (plan §5.2 step 3).
        _ = await bridge.setBookmarked(
            itemID: first.id, wanted: true, operationID: "op-7a",
            snapshot: snapshot(first, at: fixedDate), at: fixedDate
        )
        XCTAssertEqual(
            try UserStateProjectionStore(database: runtimeDatabase).watermark().revision,
            afterFirst.revision,
            "a replayed operation writes nothing, so the watermark cannot move"
        )

        _ = await bridge.setBookmarked(
            itemID: second.id, wanted: true, operationID: "op-7b",
            snapshot: snapshot(second, at: fixedDate), at: fixedDate.addingTimeInterval(10)
        )
        let watermark = try UserStateProjectionStore(database: runtimeDatabase).watermark()
        XCTAssertGreaterThan(watermark.revision, afterFirst.revision)
        XCTAssertEqual(watermark.updatedAt, fixedDate.addingTimeInterval(10))
        XCTAssertEqual(
            try UserStateProjectionStore(database: runtimeDatabase).savedSubjects(),
            [first.id, second.id].sorted()
        )
    }

    // MARK: - Upgrade safety

    func testUpgradeReappliesAdditiveMigrationsWithoutResettingUserState() async throws {
        let userDatabaseURL = tempDirectory.appendingPathComponent("user.sqlite")

        // A database with the state a user already had.
        let before = try UserStateStore(databaseURL: userDatabaseURL)
        let collections = SourceCollectionStore(db: before.db)
        _ = try await collections.createCollection(name: "Saved things")
        try await before.db.write { db in
            try db.execute(sql: """
                INSERT INTO imported_source
                    (source_identity, request_url, title, category, media_kind, added_at, enabled)
                VALUES ('identity-1', 'https://example.com/feed.xml', 'Example', 'Imported', 'text', 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO smart_feed (name, definition_json, sort_order, created_at, updated_at)
                VALUES ('My smart feed', '{}', 0, 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO bookmark_item (list_id, item_id, added_at)
                SELECT id, 'item-legacy', 1 FROM bookmark_list WHERE is_default = 1
                """)
        }

        // Prove the upgrade path itself: remove what PR-04 added, exactly as a pre-PR-04 database
        // looks, and let the migrator re-apply it on open.
        try await before.db.write { db in
            try db.execute(sql: "DROP TABLE bookmark_snapshot")
            try db.execute(sql: "DROP TABLE user_operation")
            try db.execute(sql: """
                DELETE FROM grdb_migrations
                WHERE identifier IN ('v10_bookmark_snapshot', 'v11_user_operation')
                """)
        }

        let after = try UserStateStore(databaseURL: userDatabaseURL)

        // Everything the user had is still there.
        let collectionsAfter = try await SourceCollectionStore(db: after.db).allCollections()
        XCTAssertEqual(collectionsAfter.map(\.name), ["Saved things"])
        let importedCount = try await after.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM imported_source WHERE source_identity = 'identity-1'") ?? 0
        }
        XCTAssertEqual(importedCount, 1)
        let smartFeedCount = try await after.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM smart_feed WHERE name = 'My smart feed'") ?? 0
        }
        XCTAssertEqual(smartFeedCount, 1)
        let bookmarkCount = try await after.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_item WHERE item_id = 'item-legacy'") ?? 0
        }
        XCTAssertEqual(bookmarkCount, 1, "an upgrade must not clear bookmarks")

        // And the migrations really re-ran: the new tables exist, empty, alongside the old ones.
        let tables = try await after.db.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        XCTAssertTrue(tables.contains("bookmark_snapshot"))
        XCTAssertTrue(tables.contains("user_operation"))
        let snapshotCount = try await after.db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_snapshot") ?? -1
        }
        XCTAssertEqual(snapshotCount, 0)
    }
}
