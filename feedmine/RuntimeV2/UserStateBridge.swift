import Foundation
import FeedDomain
import FeedStorage

/// Durable snapshot of one bookmark (plan §5.2).
///
/// `user.sqlite` owns bookmark identity; the content that makes the bookmark worth having lives in the
/// rebuildable `feedmine.sqlite`. This is the minimum that survives a content rebuild: title, URL,
/// authorship/source, text and the media reference. It is captured when the bookmark is written and is
/// never rewritten by a rebuild, so a bookmark is never orphaned into a bare id.
struct BookmarkSnapshot: Hashable, Sendable {
    let itemID: String
    let listID: Int64
    let title: String
    let url: String?
    let sourceTitle: String?
    let sourceURL: String?
    let excerpt: String?
    let mediaURL: String?
    let authoredAt: Date?
    let capturedAt: Date

    init(item: FeedItem, listID: Int64, at: Date) {
        self.itemID = item.id
        self.listID = listID
        self.title = item.title
        self.url = item.url.isEmpty ? nil : item.url
        self.sourceTitle = item.sourceTitle.isEmpty ? nil : item.sourceTitle
        self.sourceURL = item.sourceURL.isEmpty ? nil : item.sourceURL
        self.excerpt = item.excerpt.isEmpty ? nil : item.excerpt
        self.mediaURL = item.imageURL
        self.authoredAt = item.publishedAt
        self.capturedAt = at
    }

    init(
        itemID: String, listID: Int64, title: String, url: String?, sourceTitle: String?,
        sourceURL: String?, excerpt: String?, mediaURL: String?, authoredAt: Date?, capturedAt: Date
    ) {
        self.itemID = itemID
        self.listID = listID
        self.title = title
        self.url = url
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.excerpt = excerpt
        self.mediaURL = mediaURL
        self.authoredAt = authoredAt
        self.capturedAt = capturedAt
    }
}

/// The row a bookmark on a runtime card needs in the legacy content database (ADR-004 D6/D7, D12).
///
/// `user.sqlite` owns the bookmark, but the legacy reader renders one by joining
/// `bookmark_item.item_id` to `feedmine.sqlite.feed_item` — the join `BookmarkStore.bookmarkedItems`
/// performs, and the only hydration build 17 has. A card the runtime acquired has no such row, so a
/// bookmark on it is stored and invisible both in the mode it was taken in and after a rollback. This
/// is that row, derived from the bookmark's own snapshot: the durable content record of ADR-004 D7, in
/// the shape the legacy schema declares.
///
/// What the payload does not freeze is stated rather than approximated: the region and the category are
/// catalogue metadata (`FeedSource.region`/`.category`) that no card carries, so the row takes the
/// legacy default region and no category, and the article's language is left absent. The row's dates
/// come from the snapshot: `published_at` is the declared date the card already displays by, and
/// `fetched_at` is when the reader acted, which is when this row entered the content database.
struct LegacyCardContent: Hashable, Sendable {
    let itemID: String
    let sourceURL: String
    let sourceTitle: String
    let region: String
    let category: String
    let title: String
    let excerpt: String
    let url: String
    let imageURL: String?
    let publishedAt: Date
    let fetchedAt: Date

    init(snapshot: BookmarkSnapshot) {
        self.itemID = snapshot.itemID
        self.sourceURL = snapshot.sourceURL ?? ""
        self.sourceTitle = snapshot.sourceTitle ?? ""
        self.region = "global"
        self.category = ""
        self.title = snapshot.title
        self.excerpt = snapshot.excerpt ?? ""
        self.url = snapshot.url ?? ""
        self.imageURL = snapshot.mediaURL
        self.publishedAt = snapshot.authoredAt ?? snapshot.capturedAt
        self.fetchedAt = snapshot.capturedAt
    }
}

/// Writes the legacy-visible content row for content the reader acted on (ADR-004 D6/D7, D12).
///
/// Two rules shape what this writes:
///
/// * **Insert only when the id is free.** A row that already exists belongs to the legacy lane — legacy
///   fetched that article — and ADR-004 D1 forbids rewriting a row V2 does not own. The bookmark then
///   hydrates from the row the legacy lane wrote, which is the better outcome anyway.
/// * **One row per action, never one per card.** Nothing here runs for a published card the reader did
///   not act on. An eager mirror of the feed would bloat the legacy database and make the rollback
///   window meaningless, and the row it would add is one the reader never asked to keep.
///
/// The row is pinned through `BookmarkStore.synchronizeRetentionPin` afterwards, so the legacy retention
/// pass treats it exactly as it treats a legacy bookmark: the insert selects the `feed_item` row, which
/// is why the pin has to follow the write rather than precede it.
struct LegacyContentProjection: Sendable {
    let bookmarks: BookmarkStore
    let mappings: LegacyMappingStore
    let database: RuntimeDatabase

    init(bookmarks: BookmarkStore, mappings: LegacyMappingStore, database: RuntimeDatabase) {
        self.bookmarks = bookmarks
        self.mappings = mappings
        self.database = database
    }

    /// The legacy URL of the source a runtime card came from.
    ///
    /// It is the catalogue's own identity string for the source, read from the durable row the acquiring
    /// composition allocated (`RuntimeSourceRegistry`): for a syndication source that is the normalized
    /// fetch URL the whole app agrees on. A card's frozen payload carries no source URL at all — ADR-002
    /// D3 keeps it out — so this is the durable evidence of one, read from the runtime's own `source`
    /// row rather than from the legacy bridge (`legacy_source_map.legacy_url`) that records the same
    /// mapping as legacy evidence (ADR-003 D18). Deriving it from a display name or an endpoint is the
    /// derivation D2 rejects. A source with no allocated row answers `nil`, and the caller states the
    /// absence instead of inventing a URL.
    ///
    /// The id is `FeedDomain.SourceID` and not the app's own same-named `UInt32` identity: the runtime's
    /// ids are a different namespace by design (ADR-003 D2), and the app alias exists so the two cannot be
    /// confused.
    func legacySourceURL(for sourceID: FeedDomain.SourceID?) throws -> String? {
        guard let sourceID else { return nil }
        return try RuntimeSourceRegistry().editorialKey(for: sourceID, in: database)?.catalogIdentity
    }

    /// Writes the content row if the legacy database does not already hold it, records the durable alias
    /// for the subject, and pins the bookmark.
    ///
    /// The alias is `legacy_item_map`, the row that lets the runtime resolve the subject to canonical
    /// content — the runtime's own retention root reads it, and so does a reader with these two databases
    /// and no card id. It is written after the row and is not itself user state: losing it leaves the
    /// bookmark intact and resolvable through the snapshot (ADR-004 invariant 11).
    @MainActor
    func write(_ content: LegacyCardContent, alias: LegacyItemMapping) async throws {
        try await bookmarks.contentDB.write { db in
            try db.execute(sql: """
                INSERT INTO feed_item
                    (id, source_url, source_title, region, category, title, excerpt, url,
                     image_url, published_at, fetched_at, is_read)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [
                    content.itemID,
                    content.sourceURL,
                    content.sourceTitle,
                    content.region,
                    content.category,
                    content.title,
                    content.excerpt,
                    content.url,
                    content.imageURL,
                    Int(content.publishedAt.timeIntervalSince1970),
                    Int(content.fetchedAt.timeIntervalSince1970),
                ])
        }
        try await bookmarks.synchronizeRetentionPin(itemID: content.itemID)
        try mappings.recordItemMapping(alias, in: database)
    }

    /// Whether the content row says the article was opened.
    ///
    /// The session's confirmed user state carries read state, and a hard `false` would claim something
    /// this build cannot know: a row the legacy lane wrote may already be read. Reading it back is the
    /// only honest answer, and it is the row the reader sees either way.
    @MainActor
    func isRead(itemID: String) async throws -> Bool {
        try await bookmarks.contentDB.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT is_read FROM feed_item WHERE id = ?",
                arguments: [itemID]
            ) ?? false
        }
    }
}

/// What the user must be told about an operation. `pending` and `failed` mean the intention is stored
/// but a projection is still owed — never that it succeeded (plan §5.2 step 5).
enum BookmarkOperationState: String, Sendable {
    case pending
    case applied
    case failed
}

/// The result a caller must show. The stored state is a plain value (`user_operation.state`); the
/// reason travels with the answer instead of being encoded into it.
struct BookmarkOperationOutcome: Equatable, Sendable {
    let state: BookmarkOperationState
    let reason: String?

    static let applied = BookmarkOperationOutcome(state: .applied, reason: nil)

    static func failed(_ reason: String) -> BookmarkOperationOutcome {
        BookmarkOperationOutcome(state: .failed, reason: reason)
    }

    static func pending(_ reason: String? = nil) -> BookmarkOperationOutcome {
        BookmarkOperationOutcome(state: .pending, reason: reason)
    }
}

struct BookmarkOperationRecord: Hashable, Sendable {
    let operationID: String
    let kind: String
    let subjectID: String
    let wanted: Bool
    let listID: Int64
    let state: BookmarkOperationState
    let createdAt: Date
    let appliedAt: Date?
    let failureReason: String?
}

/// A bookmark list as it can be shown right now. `snapshotOnly` entries are bookmarks whose content row
/// is gone from the content database: their identity and snapshot survived, and the article has to be
/// re-fetched or opened from the snapshot's URL — which is exactly the promise `user.sqlite` owns.
struct BookmarkHydration: Sendable {
    let items: [FeedItem]
    let snapshotOnly: [BookmarkSnapshot]
}

struct ReplayReport: Equatable, Sendable {
    let applied: Int
    let failed: Int
}

/// Bridges one user intention to the runtime's projection, replayably (plan §5.2).
///
/// The order is fixed and cannot be reversed: the intention and the authoritative state are written in
/// `user.sqlite` first, then the runtime projection, then the operation is marked applied. A crash
/// between the two databases can lose the projection but never the bookmark; the projection is repaired
/// by replaying the operation id, and a failed projection is surfaced instead of being reported as
/// success.
struct UserStateBridge: Sendable {
    let bookmarks: BookmarkStore
    let projections: UserStateProjectionStore

    init(bookmarks: BookmarkStore, projections: UserStateProjectionStore) {
        self.bookmarks = bookmarks
        self.projections = projections
    }

    /// Sets the bookmark state for one item. `wanted` is absolute: retrying is safe for the same
    /// `operationID`, and there is no toggle to repeat.
    @discardableResult
    func setBookmarked(
        itemID: String,
        wanted: Bool,
        operationID: String,
        listID: Int64? = nil,
        snapshot: BookmarkSnapshot? = nil,
        at: Date = Date()
    ) async -> BookmarkOperationOutcome {
        let state: BookmarkOperationState
        // The list the save lands in, resolved once: the store's own rule is `listID ?? default`, and
        // the membership has to name the same list the authority wrote.
        let targetListID: Int64
        if let listID {
            targetListID = listID
        } else {
            targetListID = await bookmarks.defaultListID()
        }
        do {
            state = try await bookmarks.setBookmarked(
                itemID: itemID,
                wanted: wanted,
                operationID: operationID,
                listID: listID,
                snapshot: snapshot,
                at: at
            )
        } catch {
            return .failed("user database write failed: \(error.localizedDescription)")
        }
        guard state == .applied else {
            return BookmarkOperationOutcome(state: state, reason: nil)
        }

        do {
            try projections.apply(
                kind: .bookmark,
                subjectID: itemID,
                wanted: wanted,
                operationID: operationID,
                at: at
            )
            // The list membership, in the same write path and for the same reason: a box's content is
            // *that list's* membership, and the runtime's selection reads it
            // (`SubjectSelection.savedSubjects(kind:listKey:)`, baseline §8.59). The store resolves which
            // list a save with no explicit list landed in — the default — and the projection has to name
            // the same one, or a card saved through the runtime would be missing from the box the reader
            // opens.
            try projections.applyListMembership(
                listKey: Self.listKey(for: targetListID),
                subjectID: itemID,
                wanted: wanted,
                operationID: operationID,
                at: at
            )
            return .applied
        } catch {
            let reason = "runtime projection failed: \(error.localizedDescription)"
            // The bookmark is stored; only the projection is owed. Say so, and keep it replayable.
            try? await bookmarks.markOperation(operationID, state: .failed, reason: reason, at: at)
            return .failed(reason)
        }
    }

    /// Sets the read state for one item. Read is absolute like a bookmark's `wanted`: this build has no
    /// clear-unread affordance and the fact vocabulary declares no `readCleared` event type, so there is
    /// one direction, and retrying it is safe for the same `operationID` because
    /// `UserStateProjectionStore.apply` is idempotent on the operation id (plan §5.2 step 3).
    ///
    /// The order is `setBookmarked`'s with one fewer step, and for a stated reason: read has no
    /// authority row in `user.sqlite` (the legacy content row is what the reader's surfaces agree on),
    /// and this bridge deliberately does not write it — that projection is the durable-state policy
    /// decision `read-state-report.md` names and leaves to the owner. What it writes is the runtime's
    /// own projection of the intent, which is what lets the session answer a confirmed state without
    /// trusting its own optimism.
    @discardableResult
    func setRead(itemID: String, operationID: String, at: Date = Date()) -> BookmarkOperationOutcome {
        do {
            try projections.apply(
                kind: .read,
                subjectID: itemID,
                wanted: true,
                operationID: operationID,
                at: at
            )
            return .applied
        } catch {
            return .failed("runtime projection failed: \(error.localizedDescription)")
        }
    }

    /// The one spelling of a list key.
    ///
    /// A list is the app's own container (`bookmark_list.id`), and the runtime never resolves it into
    /// anything else: it stores the key, and the plan that selects a box states the same string. One
    /// function so the two cannot drift.
    static func listKey(for listID: Int64) -> String { "list:\(listID)" }

    /// Repairs every runtime projection that can be reconstructed from the durable bookmark
    /// authority. This is the launch entry point: a process may have died after user.sqlite committed
    /// while either the bookmark projection or the list-membership projection was still owed.
    ///
    /// Both component repairs are idempotent on the operation id, so running this on every launch is
    /// safe and turns the recovery contract into one call site instead of letting callers remember
    /// only half of it.
    @discardableResult
    func reconcileForLaunch(at: Date = Date()) async -> ReplayReport {
        let bookmarks = await reconcile(at: at)
        let memberships = await reconcileListMemberships(at: at)
        return ReplayReport(
            applied: bookmarks.applied + memberships.applied,
            failed: bookmarks.failed + memberships.failed
        )
    }

    /// Projects the authority's list membership for every list the reader has.
    ///
    /// The save path writes one row per save, and a bookmark taken before this projection existed has
    /// none — without this pass its box would show only what was saved since, which is a wrong page
    /// rather than a missing one. The authority is `user.sqlite`'s `bookmark_item(list_id, item_id)`,
    /// read through the store, and the operation id the subject's newest bookmark operation carries is
    /// what makes each write idempotent: replaying it is a no-op that still answers the same revision.
    @discardableResult
    func reconcileListMemberships(at: Date = Date()) async -> ReplayReport {
        var applied = 0
        var failed = 0
        let operationBySubject = Dictionary(
            ((try? await bookmarks.newestOperationsBySubject()) ?? []).map { ($0.subjectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let lists = (try? await bookmarks.allBookmarkLists()) ?? []
        for list in lists {
            let listKey = Self.listKey(for: list.id)
            let items = (try? await bookmarks.bookmarkedItems(listID: list.id)) ?? []
            for item in items {
                // A subject with no bookmark operation has no operation id to key idempotence on, and
                // inventing one would make every launch a new write. It is skipped, not guessed.
                guard let operation = operationBySubject[item.id] else { continue }
                let projected = try? projections.listMembership(listKey: listKey, subjectID: item.id)
                if projected?.lastOperationID == operation.operationID, projected?.wanted == true {
                    continue
                }
                do {
                    try projections.applyListMembership(
                        listKey: listKey,
                        subjectID: item.id,
                        wanted: true,
                        operationID: operation.operationID,
                        at: at
                    )
                    applied += 1
                } catch {
                    failed += 1
                }
            }
        }
        return ReplayReport(applied: applied, failed: failed)
    }

    /// Reconciles the runtime projection with the authoritative operation log. Run at launch.
    ///
    /// A crash between the two databases leaves the user side applied and the projection missing, and no
    /// flag inside `user.sqlite` can distinguish that from a completed operation — the operation never
    /// sees the runtime write. So the comparison is between the two stores: for each subject, the newest
    /// operation must be the one the projection last applied. Anything else is replayed. Replaying an
    /// operation the runtime already applied is a no-op that still returns the same revision, so this is
    /// safe to run on every launch.
    @discardableResult
    func reconcile(at: Date = Date()) async -> ReplayReport {
        let newest = (try? await bookmarks.newestOperationsBySubject()) ?? []
        var applied = 0
        var failed = 0
        for operation in newest {
            let projected = try? projections.projection(kind: .bookmark, subjectID: operation.subjectID)
            if projected?.lastOperationID == operation.operationID {
                if operation.state != .applied {
                    try? await bookmarks.markOperation(operation.operationID, state: .applied, reason: nil, at: at)
                }
                continue
            }
            do {
                try projections.apply(
                    kind: .bookmark,
                    subjectID: operation.subjectID,
                    wanted: operation.wanted,
                    operationID: operation.operationID,
                    at: at
                )
                try? await bookmarks.markOperation(operation.operationID, state: .applied, reason: nil, at: at)
                applied += 1
            } catch {
                try? await bookmarks.markOperation(
                    operation.operationID,
                    state: .failed,
                    reason: "runtime projection failed during reconcile: \(error.localizedDescription)",
                    at: at
                )
                failed += 1
            }
        }
        return ReplayReport(applied: applied, failed: failed)
    }
}
