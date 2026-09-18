import Foundation
import GRDB

@MainActor
final class BookmarkStore {
    /// Bookmark identity database (user.sqlite). Owns `bookmark_list` and
    /// `bookmark_item` — the canonical source for "what is bookmarked."
    let userDB: DatabaseQueue
    /// Content database (feedmine.sqlite). Owns `feed_item` — used only for
    /// queries that join bookmark identity with feed content.
    let contentDB: DatabaseQueue
    private var _defaultListID: Int64?

    init(userDB: DatabaseQueue, contentDB: DatabaseQueue) {
        self.userDB = userDB
        self.contentDB = contentDB
    }

    // MARK: - Default List

    func defaultListID() -> Int64 {
        if let cached = _defaultListID { return cached }
        let id: Int64 = (try? userDB.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM bookmark_list WHERE is_default = 1 LIMIT 1")
        }) ?? 1
        _defaultListID = id
        return id
    }

    // MARK: - CRUD

    func allBookmarkLists() async throws -> [BookmarkList] {
        try await userDB.read { db in
            let records = try BookmarkListRecord.order(Column("sort_order")).fetchAll(db)
            return try records.map { r in
                let count = try BookmarkItemRecord.filter(Column("list_id") == r.id!).fetchCount(db)
                return BookmarkList(
                    id: r.id!, name: r.name, sortOrder: r.sortOrder,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(r.createdAt)),
                    isDefault: r.isDefault,
                    searchQuery: r.searchQuery, searchRegion: r.searchRegion,
                    searchCategory: r.searchCategory, searchActive: r.searchActive,
                    itemCount: count
                )
            }
        }
    }

    func createBookmarkList(name: String, searchQuery: String? = nil,
                            region: String? = nil, category: String? = nil) async throws -> Int64 {
        try await userDB.write { db in
            try db.execute(sql: """
                INSERT INTO bookmark_list (name, sort_order, created_at, is_default,
                    search_query, search_region, search_category, search_active)
                VALUES (?, 0, ?, 0, ?, ?, ?, ?)
            """, arguments: [
                name,
                Int(Date().timeIntervalSince1970),
                searchQuery,
                region,
                category,
                searchQuery != nil
            ])
            return db.lastInsertedRowID
        }
    }

    /// Legacy entry point. The user-visible action is still a toggle, but the write goes through the
    /// idempotent primitive so every change is logged as an operation with an id (plan §5.2 step 4).
    /// PR-13 replaces this call site with an explicit `wanted` computed by the session, at which point a
    /// retry can be a replay instead of a fresh toggle.
    func toggleBookmark(itemID: String, listID: Int64? = nil) async throws {
        let targetListID = listID ?? defaultListID()
        let currentlySaved = try await isBookmarked(itemID: itemID, listID: targetListID)
        _ = try await setBookmarked(
            itemID: itemID,
            wanted: !currentlySaved,
            operationID: UUID().uuidString,
            listID: targetListID
        )
    }

    func isBookmarked(itemID: String, listID: Int64? = nil) async throws -> Bool {
        let targetListID = listID ?? defaultListID()
        return try await userDB.read { db in
            try BookmarkItemRecord
                .filter(Column("list_id") == targetListID && Column("item_id") == itemID)
                .fetchCount(db) > 0
        }
    }

    /// Whether the item exists in at least one bookmark list.
    ///
    /// The runtime's top-level bookmark overlay is global across boxes, while list membership is
    /// tracked separately. Removing an item from one box must therefore not make it look unbookmarked
    /// when another box still contains it.
    func isBookmarkedAnywhere(itemID: String) async throws -> Bool {
        try await userDB.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM bookmark_item WHERE item_id = ? LIMIT 1",
                arguments: [itemID]
            ) != nil
        }
    }

    /// All bookmarked item IDs across every list. Used by FeedStore to stamp
    /// `isBookmarked` on visible items so bookmark indicators render correctly.
    func allBookmarkedItemIDs() -> Set<String> {
        (try? userDB.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item"))
        }) ?? []
    }

    /// Async variant that runs the synchronous GRDB read off the main actor
    /// (startup fast path — the sync call above blocks its caller).
    func allBookmarkedItemIDsAsync() async -> Set<String> {
        let db = userDB
        return await Task.detached(priority: .userInitiated) {
            (try? db.read { db in
                try Set(String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item"))
            }) ?? []
        }.value
    }

    func bookmarkedItems(listID: Int64? = nil) async throws -> [FeedItem] {
        let targetListID = listID ?? defaultListID()
        // Fetch item IDs from user.sqlite in save order (newest bookmark first).
        let itemIDs: [String] = try await userDB.read { db in
            try String.fetchAll(db, sql: """
                SELECT item_id FROM bookmark_item WHERE list_id = ? ORDER BY added_at DESC
            """, arguments: [targetListID])
        }
        guard !itemIDs.isEmpty else { return [] }

        // Hydrate from content DB, then restore the save order. The content DB
        // query returns items in arbitrary order; we re-sort to match the
        // bookmark_item.added_at ordering from the user DB.
        let hydrated = try await contentDB.read { db in
            try FeedItemRecord
                .filter(itemIDs.contains(Column("id")))
                .fetchAll(db)
                .map { $0.toFeedItem() }
        }
        let itemByID = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
        return itemIDs.compactMap { itemByID[$0] }
    }

    func renameBookmarkList(_ id: Int64, name: String) async throws {
        try await userDB.write { db in
            try db.execute(sql: "UPDATE bookmark_list SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    func reorderBookmarkList(_ id: Int64, sortOrder: Int) async throws {
        try await userDB.write { db in
            try db.execute(sql: "UPDATE bookmark_list SET sort_order = ? WHERE id = ?",
                          arguments: [sortOrder, id])
        }
    }

    func deleteBookmarkList(_ id: Int64) async throws {
        try await userDB.write { db in
            let isDefault = try Bool.fetchOne(db, sql: "SELECT is_default FROM bookmark_list WHERE id = ?", arguments: [id]) ?? false
            guard !isDefault else { return }
            try db.execute(sql: "DELETE FROM bookmark_list WHERE id = ?", arguments: [id])
        }
        try await synchronizeRetentionPins()
    }

    func toggleSearchActive(listID: Int64) async throws {
        let wasActive: Bool = try await userDB.read { db in
            try Bool.fetchOne(db, sql: "SELECT search_active FROM bookmark_list WHERE id = ?", arguments: [listID]) ?? false
        }
        let newState = !wasActive
        try await userDB.write { db in
            try db.execute(sql: "UPDATE bookmark_list SET search_active = ? WHERE id = ?",
                          arguments: [newState, listID])
        }
        // If activating, retroactively match existing items in SQLite
        if newState {
            try await retroMatchSearch(listID: listID)
        }
    }

    func clearAllBookmarks() {
        Task {
            do {
                try await userDB.write { db in
                    try db.execute(sql: "DELETE FROM bookmark_item")
                }
                try await contentDB.write { db in
                    try db.execute(sql: "DELETE FROM bookmark_item")
                }
            } catch {
                Log.db.error("Failed to clear all bookmarks: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Idempotent operations and durable snapshots (Runtime V2, plan §5.2)

    /// Writes a bookmark intention idempotently.
    ///
    /// `wanted` is absolute (`true` = save, `false` = remove): a retry with the same `operationID` is a
    /// no-op, which is what makes recovery safe — there is no toggle to repeat. The intention, the
    /// authoritative `bookmark_item` row and the snapshot commit together in `user.sqlite`; projections
    /// (the legacy retention pin) run afterwards and their failure is recorded, not swallowed.
    @discardableResult
    func setBookmarked(
        itemID: String,
        wanted: Bool,
        operationID: String,
        listID: Int64? = nil,
        snapshot: BookmarkSnapshot? = nil,
        kind: String = "bookmark.set",
        at: Date = Date()
    ) async throws -> BookmarkOperationState {
        let targetListID = listID ?? defaultListID()
        let timestamp = Int(at.timeIntervalSince1970)

        let alreadyApplied = try await userDB.write { db -> Bool in
            let existing = try String.fetchOne(
                db,
                sql: "SELECT state FROM user_operation WHERE operation_id = ?",
                arguments: [operationID]
            )
            if existing == BookmarkOperationState.applied.rawValue { return true }

            try db.execute(sql: """
                INSERT INTO user_operation
                    (operation_id, kind, subject_id, payload_json, state, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(operation_id) DO UPDATE SET
                    payload_json = excluded.payload_json,
                    state = excluded.state,
                    failure_reason = NULL
                """, arguments: [
                    operationID, kind, itemID,
                    Self.operationPayload(wanted: wanted, listID: targetListID),
                    BookmarkOperationState.pending.rawValue, timestamp
                ])

            if wanted {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                    VALUES (?, ?, ?)
                    """, arguments: [targetListID, itemID, timestamp])
                if let snapshot {
                    try db.execute(sql: """
                        INSERT INTO bookmark_snapshot
                            (list_id, item_id, title, url, source_title, source_url,
                             excerpt, media_url, authored_at, captured_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(list_id, item_id) DO UPDATE SET
                            title = excluded.title,
                            url = excluded.url,
                            source_title = excluded.source_title,
                            source_url = excluded.source_url,
                            excerpt = excluded.excerpt,
                            media_url = excluded.media_url,
                            authored_at = excluded.authored_at
                        """, arguments: [
                            targetListID, itemID, snapshot.title, snapshot.url,
                            snapshot.sourceTitle, snapshot.sourceURL, snapshot.excerpt,
                            snapshot.mediaURL,
                            snapshot.authoredAt.map { Int($0.timeIntervalSince1970) },
                            timestamp
                        ])
                }
            } else {
                try db.execute(sql: "DELETE FROM bookmark_item WHERE list_id = ? AND item_id = ?",
                              arguments: [targetListID, itemID])
                try db.execute(sql: "DELETE FROM bookmark_snapshot WHERE list_id = ? AND item_id = ?",
                              arguments: [targetListID, itemID])
            }
            return false
        }

        if alreadyApplied { return .applied }

        do {
            try await synchronizeRetentionPin(itemID: itemID)
        } catch {
            let reason = "retention projection failed: \(error.localizedDescription)"
            try? await markOperation(operationID, state: .failed, reason: reason, at: at)
            return .failed
        }

        try await markOperation(operationID, state: .applied, reason: nil, at: at)
        return .applied
    }

    func markOperation(
        _ operationID: String,
        state: BookmarkOperationState,
        reason: String?,
        at: Date
    ) async throws {
        try await userDB.write { db in
            try db.execute(sql: """
                UPDATE user_operation SET state = ?, failure_reason = ?, applied_at = ?
                WHERE operation_id = ?
                """, arguments: [
                    state.rawValue, reason,
                    state == .applied ? Int(at.timeIntervalSince1970) : nil,
                    operationID
                ])
        }
    }

    /// Every stored operation the runtime has not applied yet, oldest first.
    func unappliedOperations() async -> [BookmarkOperationRecord] {
        (try? await userDB.read { db in
            try Row.fetchAll(db, sql: """
                SELECT operation_id, kind, subject_id, payload_json, state, created_at,
                       applied_at, failure_reason
                FROM user_operation
                WHERE state != ?
                ORDER BY created_at ASC, operation_id ASC
                """, arguments: [BookmarkOperationState.applied.rawValue]).map(Self.operationRecord(from:))
        }) ?? []
    }

    /// The newest operation per subject, which is the only one that decides the current state. Used by
    /// the bridge's reconciliation instead of a "was this projected?" flag, because a crash between the
    /// two databases leaves no such flag behind.
    func newestOperationsBySubject(kind: String = "bookmark.set") async -> [BookmarkOperationRecord] {
        (try? await userDB.read { db in
            try Row.fetchAll(db, sql: """
                SELECT operation_id, kind, subject_id, payload_json, state, created_at,
                       applied_at, failure_reason
                FROM (
                    SELECT *, ROW_NUMBER() OVER (
                        PARTITION BY subject_id ORDER BY created_at DESC, operation_id DESC
                    ) AS row_number
                    FROM user_operation WHERE kind = ?
                ) WHERE row_number = 1
                """, arguments: [kind]).map(Self.operationRecord(from:))
        }) ?? []
    }

    /// The newest operation for each (subject, list) pair.
    ///
    /// List membership is not the same state as "bookmarked anywhere": one item can belong to more
    /// than one box, and recovery must be able to replay a removal from one box without erasing the
    /// other. JSON is queried only here, in the user-state compatibility store; it never enters a
    /// Runtime V2 hot path.
    func newestOperationsBySubjectAndList(kind: String = "bookmark.set") async -> [BookmarkOperationRecord] {
        (try? await userDB.read { db in
            try Row.fetchAll(db, sql: """
                SELECT operation_id, kind, subject_id, payload_json, state, created_at,
                       applied_at, failure_reason
                FROM (
                    SELECT *, ROW_NUMBER() OVER (
                        PARTITION BY subject_id, json_extract(payload_json, '$.listID')
                        ORDER BY created_at DESC, operation_id DESC
                    ) AS row_number
                    FROM user_operation WHERE kind = ?
                ) WHERE row_number = 1
                ORDER BY subject_id, json_extract(payload_json, '$.listID')
                """, arguments: [kind]).map(Self.operationRecord(from:))
        }) ?? []
    }

    func bookmarkSnapshots(listID: Int64? = nil) async throws -> [BookmarkSnapshot] {
        let targetListID = listID ?? defaultListID()
        return try await userDB.read { db in
            try Row.fetchAll(db, sql: """
                SELECT list_id, item_id, title, url, source_title, source_url,
                       excerpt, media_url, authored_at, captured_at
                FROM bookmark_snapshot WHERE list_id = ?
                ORDER BY captured_at DESC
                """, arguments: [targetListID]).map(Self.snapshot(from:))
        }
    }

    func bookmarkSnapshot(itemID: String, listID: Int64? = nil) async throws -> BookmarkSnapshot? {
        let targetListID = listID ?? defaultListID()
        return try await userDB.read { db in
            try Row.fetchOne(db, sql: """
                SELECT list_id, item_id, title, url, source_title, source_url,
                       excerpt, media_url, authored_at, captured_at
                FROM bookmark_snapshot WHERE list_id = ? AND item_id = ?
                """, arguments: [targetListID, itemID]).map(Self.snapshot(from:))
        }
    }

    /// What a bookmark list looks like right now: items the content database can still hydrate, plus the
    /// ones whose content row is gone and whose snapshot must stand in for it.
    func hydration(listID: Int64? = nil) async throws -> BookmarkHydration {
        let targetListID = listID ?? defaultListID()
        let itemIDs: [String] = try await userDB.read { db in
            try String.fetchAll(db, sql: """
                SELECT item_id FROM bookmark_item WHERE list_id = ? ORDER BY added_at DESC
            """, arguments: [targetListID])
        }
        guard !itemIDs.isEmpty else { return BookmarkHydration(items: [], snapshotOnly: []) }

        let hydrated = try await contentDB.read { db in
            try FeedItemRecord
                .filter(itemIDs.contains(Column("id")))
                .fetchAll(db)
                .map { $0.toFeedItem() }
        }
        let itemByID = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
        let snapshots = try await bookmarkSnapshots(listID: targetListID)
        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.itemID, $0) })

        return BookmarkHydration(
            items: itemIDs.compactMap { itemByID[$0] },
            snapshotOnly: itemIDs.filter { itemByID[$0] == nil }.compactMap { snapshotByID[$0] }
        )
    }

    private nonisolated static func operationPayload(wanted: Bool, listID: Int64) -> String {
        // Small, explicit and stable: replay compares the operation id, not this payload.
        "{\"listID\":\(listID),\"wanted\":\(wanted ? "true" : "false")}"
    }

    private struct StoredOperationPayload: Decodable {
        let listID: Int64
        let wanted: Bool
    }

    private nonisolated static func operationRecord(from row: Row) -> BookmarkOperationRecord {
        let payload = row["payload_json"] as String
        let decoded = try? JSONDecoder().decode(StoredOperationPayload.self, from: Data(payload.utf8))
        return BookmarkOperationRecord(
            operationID: row["operation_id"],
            kind: row["kind"],
            subjectID: row["subject_id"],
            wanted: decoded?.wanted ?? false,
            listID: decoded?.listID ?? 0,
            state: BookmarkOperationState(rawValue: row["state"]) ?? .pending,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            appliedAt: (row["applied_at"] as Int64?).map { Date(timeIntervalSince1970: Double($0)) },
            failureReason: row["failure_reason"]
        )
    }

    private nonisolated static func snapshot(from row: Row) -> BookmarkSnapshot {
        BookmarkSnapshot(
            itemID: row["item_id"],
            listID: row["list_id"],
            title: row["title"],
            url: row["url"],
            sourceTitle: row["source_title"],
            sourceURL: row["source_url"],
            excerpt: row["excerpt"],
            mediaURL: row["media_url"],
            authoredAt: (row["authored_at"] as Int64?).map { Date(timeIntervalSince1970: Double($0)) },
            capturedAt: Date(timeIntervalSince1970: row["captured_at"])
        )
    }

    // MARK: - Retention bridge

    /// `user.sqlite` owns bookmark identity.  The legacy content database still
    /// consults its local bookmark table while expiring old cache rows, so keep
    /// a minimal mirror there to guarantee that saved articles remain hydratable.
    func synchronizeRetentionPins() async throws {
        let itemIDs = try await userDB.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item")
        }
        try await contentDB.write { db in
            try db.execute(sql: "DELETE FROM bookmark_item")
            let listID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM bookmark_list WHERE is_default = 1 LIMIT 1"
            ) ?? 1
            let now = Int(Date().timeIntervalSince1970)
            for itemID in itemIDs {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                    SELECT ?, id, ? FROM feed_item WHERE id = ?
                    """, arguments: [listID, now, itemID])
            }
        }
    }

    /// Mirrors one bookmark into the content database's own pin table, and removes it again when the
    /// bookmark is gone. The pin is what keeps the legacy retention pass from evicting a saved article.
    ///
    /// The insert selects the `feed_item` row, so it pins nothing while that row is absent — which is
    /// the normal state for content only the runtime ever acquired. A caller that projects such a row
    /// calls this again after writing it (`RuntimeCardUserActions`) and gets the pin then; the call is
    /// idempotent, so it is safe on every path.
    func synchronizeRetentionPin(itemID: String) async throws {
        let isPinned = try await userDB.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM bookmark_item WHERE item_id = ?",
                arguments: [itemID]
            ) ?? 0 > 0
        }
        try await contentDB.write { db in
            if isPinned {
                let listID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM bookmark_list WHERE is_default = 1 LIMIT 1"
                ) ?? 1
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                    SELECT ?, id, ? FROM feed_item WHERE id = ?
                    """, arguments: [listID, Int(Date().timeIntervalSince1970), itemID])
            } else {
                try db.execute(sql: "DELETE FROM bookmark_item WHERE item_id = ?", arguments: [itemID])
            }
        }
    }

    // MARK: - Retro Match

    /// Retroactively add all existing items in SQLite that match a persistent search.
    func retroMatchSearch(listID: Int64) async throws {
        let search: BookmarkListRecord? = try await userDB.read { db in
            try BookmarkListRecord.fetchOne(db, key: listID)
        }
        guard let search, let query = search.searchQuery,
              let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return }

        let cutoff = Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)
        let records: [FeedItemRecord] = try await contentDB.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > cutoff)
                .matching(pattern)
            if let region = search.searchRegion {
                request = request.filter(Column("region") == region)
            }
            if let cat = search.searchCategory {
                request = request.filter(Column("category") == cat)
            }
            return try request.fetchAll(db)
        }

        guard !records.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        try await userDB.write { db in
            for record in records {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                    VALUES (?, ?, ?)
                """, arguments: [listID, record.id, now])
            }
        }
    }

    // MARK: - Composite Search Feed

    func compositeSearchFeed(regionResolver: (String) -> String) async throws -> [FeedItem] {
        let searches = try await activeSearches()
        guard !searches.isEmpty else { return [] }

        let cutoff = Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)
        var scored: [(FeedItem, Int)] = []
        for search in searches {
            guard let pattern = FTS5Pattern(matchingAllTokensIn: search.searchQuery) else { continue }
            let records: [FeedItemRecord] = try await contentDB.read { db in
                var request = FeedItemRecord
                    .filter(Column("fetched_at") > cutoff)
                    .matching(pattern)
                if let r = search.region {
                    request = request.filter(Column("region") == r)
                }
                if let c = search.category {
                    request = request.filter(Column("category") == c)
                }
                return try request.limit(50).fetchAll(db)
            }
            for record in records {
                let item = record.toFeedItem()
                let score = search.matches(item, itemRegion: regionResolver(item.sourceURL))
                scored.append((item, score + 1))
            }
        }

        // Deduplicate and sum scores
        var bestScore: [String: (FeedItem, Int)] = [:]
        for (item, score) in scored {
            if let existing = bestScore[item.id] {
                bestScore[item.id] = (item, existing.1 + score)
            } else {
                bestScore[item.id] = (item, score)
            }
        }

        let sorted = bestScore.values.sorted { a, b in
            a.1 > b.1
        }
        return sorted.map { $0.0 }
    }

    // MARK: - Active Searches

    func activeSearches() async throws -> [ActiveSearch] {
        let records: [BookmarkListRecord] = try await userDB.read { db in
            try BookmarkListRecord
                .filter(Column("search_active") == 1)
                .fetchAll(db)
        }
        return records.map { r in
            ActiveSearch(
                id: r.id!, name: r.name,
                searchQuery: r.searchQuery ?? "",
                region: r.searchRegion, category: r.searchCategory
            )
        }
    }

    /// Match newly fetched items against all active persistent searches and auto-bookmark matches.
    func matchPersistentSearches(_ items: [FeedItem], regionResolver: (String) -> String) async {
        let searches: [BookmarkListRecord]
        do {
            searches = try await userDB.read { db in
                try BookmarkListRecord
                    .filter(Column("search_active") == 1)
                    .fetchAll(db)
            }
        } catch {
            Log.db.error("Failed to load persistent searches: \(error.localizedDescription)")
            return
        }
        guard !searches.isEmpty else { return }

        for search in searches {
            guard let query = search.searchQuery else { continue }
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { continue }
            let candidateIDs = items.filter { item in
                if let region = search.searchRegion,
                   region != regionResolver(item.sourceURL) { return false }
                if let cat = search.searchCategory, cat != item.category { return false }
                return true
            }.map(\.id)
            guard !candidateIDs.isEmpty else { continue }

            let matchedIDs: [String]
            do {
                matchedIDs = try await contentDB.read { db in
                    try FeedItemRecord
                        .filter(candidateIDs.contains(Column("id")))
                        .matching(pattern)
                        .fetchAll(db)
                        .map(\.id)
                }
            } catch {
                Log.db.error("Persistent search match failed for '\(search.name)': \(error.localizedDescription)")
                continue
            }
            guard !matchedIDs.isEmpty else { continue }

            let now = Int(Date().timeIntervalSince1970)
            do {
                try await userDB.write { db in
                    for id in matchedIDs {
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO bookmark_item (list_id, item_id, added_at)
                            VALUES (?, ?, ?)
                        """, arguments: [search.id!, id, now])
                    }
                }
            } catch {
                Log.db.error("Persistent search bookmark insert failed for '\(search.name)': \(error.localizedDescription)")
            }
        }
    }
}
