import Foundation
import GRDB
import UIKit

// MARK: - Image Resolution State

enum ImageResolutionState: String, Sendable {
    case pending     // waiting for retry
    case inProgress  // currently resolving
    case failed      // all retries exhausted
}

// MARK: - Delegate Protocol

/// Callbacks from the retry queue to FeedStore. FeedStore implements these
/// on @MainActor, but the protocol itself is not actor-bound so the ImageResolutionQueue
/// actor can call these methods without sendability warnings. FeedStore's implementation
/// naturally runs on MainActor since FeedStore is @MainActor.
@MainActor
protocol ImageResolutionQueueDelegate: AnyObject, Sendable {
    /// Called when a background retry resolves an image.
    ///
    /// This is the enforcement point for a hard contract: a card that has
    /// already been published keeps its presentation. The image is already in
    /// `ImageCache`, which is what the next composition reads, so a conformer
    /// MUST NOT rewrite a published card here — activating the hero slot changes
    /// the card's height and would shift every card below it under the reader.
    func imageResolutionQueue(didResolveImageFor itemID: String)

    /// Called when all retries are exhausted and the item is permanently
    /// text-only. FeedStore may record this for diagnostics.
    func imageResolutionQueue(didExhaustRetriesFor itemID: String)
}

// MARK: - Image Resolution Queue

/// Persistent retry queue for image resolution.
///
/// Items whose images failed during the initial pipeline (3-second timeout in
/// ``ReadyCardQueue``, transient network errors, truncated RSS feeds needing
/// article-OG resolution) enter this queue. Each item is retried with
/// exponential backoff, and when a retry succeeds the visible card is upgraded
/// in-place — no feed shift, no re-insertion.
///
/// Retry state survives app termination via the `image_retry_queue` SQLite
/// table, keyed by item ID with CASCADE delete.
///
/// ## Backoff schedule
///
/// | Attempt | Delay    |
/// |---------|----------|
/// | 1       | 30 s     |
/// | 2       | 2 min    |
/// | 3       | 10 min   |
/// | 4       | 1 h      |
/// | 5       | 6 h      |
/// | 6+      | failed   |
///
/// ## Concurrency
///
/// The actor processes items sequentially (one at a time) to avoid saturating
/// the network. The polling loop runs every 15 seconds, processing at most
/// 10 items per cycle. Since retry delays are measured in minutes-to-hours,
/// a 15-second poll is negligible.
actor ImageResolutionQueue {

    // MARK: - Configuration

    /// Exponential backoff delays indexed by `retry_count`.
    private static let backoffDelays: [TimeInterval] = [
        30,       // attempt 1 — transient network blip
        120,      // attempt 2 — slow CDN recovery
        600,      // attempt 3 — past ArticleImageResolver 300 s TTL
        3600,     // attempt 4 — 1 hour
        21600,    // attempt 5 — 6 hours
    ]

    /// Maximum number of retries before marking as failed.
    private static var maxRetries: Int { backoffDelays.count }

    /// Upper bound on how long the poll loop may sleep before it looks again.
    /// A newly enqueued item is picked up within this interval even when the
    /// retry it was enqueued next to is hours away.
    private static let pollInterval: TimeInterval = 15

    /// Floor on the sleep so an immediately eligible backlog (more than
    /// ``batchSize`` rows at once) cannot spin the loop.
    private static let minimumWakeDelay: TimeInterval = 0.25

    /// How long an `in_progress` claim is honoured before the loop takes it
    /// back. A row is written `in_progress` before its resolution starts; if
    /// nothing ever writes the outcome, no query selects it again — see
    /// ``recoverExpiredLeases(reclaimAll:)``.
    private static let inProgressLeaseTimeout: TimeInterval = 300

    /// Maximum items processed per poll cycle.
    private static let batchSize = 10

    // MARK: - State

    private let db: DatabaseQueue
    private weak var delegate: ImageResolutionQueueDelegate?

    private var pollTask: Task<Void, Never>?

    /// In-memory set of item IDs that have been enqueued and not yet resolved
    /// or failed. Used to avoid duplicate SQLite writes for already-pending items.
    private var pendingIDs: Set<String> = []

    // MARK: - Init

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Lifecycle

    /// Wire the delegate and start processing. Call once after FeedStore.init.
    func configure(delegate: ImageResolutionQueueDelegate) {
        self.delegate = delegate
        Task { await start() }
    }

    /// Recover abandoned claims, learn the rows already queued, then poll.
    ///
    /// Recovery runs *before* the loop: at this point no resolution of this
    /// actor can be in flight (the actor was just created for this process), so
    /// every `in_progress` row is a leftover from a run that died between the
    /// claim and the outcome. Without this, those rows are never selected by any
    /// query and the item never gets its retry.
    private func start() async {
        await recoverExpiredLeases(reclaimAll: true)
        await loadPendingFromSQLite()
        startPolling()
    }

    /// Stop the poll loop (e.g., on flush / reset).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Public API

    /// Enqueue a single item for retry. Idempotent — if the item is already
    /// pending, its `retry_count` is preserved.
    func enqueue(itemID: String) async {
        await enqueueBatch(itemIDs: [itemID])
    }

    /// Enqueue multiple items for retry. More efficient than calling
    /// `enqueue(itemID:)` in a loop because it uses a single SQLite write.
    func enqueueBatch(itemIDs: [String]) async {
        let now = Int(Date().timeIntervalSince1970)
        let newIDs = itemIDs.filter { !pendingIDs.contains($0) }
        guard !newIDs.isEmpty else { return }

        do {
            try await db.write { db in
                for id in newIDs {
                    // Upsert: only insert if not already present; if present,
                    // leave retry_count alone (don't reset backoff progress).
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO image_retry_queue
                            (item_id, state, retry_count, next_retry_at, created_at, updated_at)
                            VALUES (?, 'pending', 0, ?, ?, ?)
                            """,
                        arguments: [id, now, now, now]
                    )
                }
            }
            pendingIDs.formUnion(newIDs)
        } catch {
            Log.feed.error("ImageResolutionQueue enqueueBatch failed: \(error)")
        }

        startPolling()
    }

    /// Remove an item from the retry queue (e.g., a fresh fetch brought a
    /// working image URL, or the item was deleted).
    func dequeue(itemID: String) async {
        pendingIDs.remove(itemID)
        do {
            try await db.write { db in
                try db.execute(
                    sql: "DELETE FROM image_retry_queue WHERE item_id = ?",
                    arguments: [itemID]
                )
            }
        } catch {
            Log.feed.error("ImageResolutionQueue dequeue failed: \(error)")
        }
    }

    // MARK: - Polling

    private func startPolling() {
        // Already polling — don't start a second loop.
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.recoverExpiredLeases()
                await self.processBatch()

                // Existence of work and immediate eligibility are different
                // questions. The loop used to exit here on "no row is eligible
                // right now", which counted only rows whose `next_retry_at` had
                // already passed: a resolution that failed and rescheduled
                // itself 30 s (up to 6 h) into the future left rows that no
                // query selected and no task woke up for, so the retries that
                // the backoff schedule promised simply never happened. Wait for
                // the next date instead of stopping; the loop only ends when
                // there is no row left in the table.
                guard let wait = await self.nextWakeDelay() else {
                    await self.clearPollTask()
                    return
                }
                try? await Task.sleep(for: .seconds(wait))
            }
            await self.clearPollTask()
        }
    }

    private func clearPollTask() {
        pollTask = nil
    }

    // MARK: - Batch Processing

    private func processBatch() async {
        let now = Int(Date().timeIntervalSince1970)
        let batch: [ImageRetryQueueRecord] = (try? await db.read { db in
            try ImageRetryQueueRecord
                .fetchAll(db, sql: """
                    SELECT * FROM image_retry_queue
                    WHERE state = 'pending'
                      AND next_retry_at <= ?
                    ORDER BY next_retry_at ASC
                    LIMIT ?
                    """, arguments: [now, Self.batchSize]
                )
        }) ?? []

        for record in batch {
            guard !Task.isCancelled else { return }

            await resolve(record: record)
        }
    }

    // MARK: - Resolution

    private func resolve(record: ImageRetryQueueRecord) async {
        let itemID = record.itemID

        // 1. Mark in-progress
        let now = Int(Date().timeIntervalSince1970)
        try? await db.write { db in
            try db.execute(
                sql: """
                    UPDATE image_retry_queue
                    SET state = 'in_progress', updated_at = ?
                    WHERE item_id = ?
                    """,
                arguments: [now, itemID]
            )
        }

        // 2. Read the item from SQLite
        guard let itemRecord: FeedItemRecord = try? await db.read({ db in
            try FeedItemRecord.fetchOne(db, key: itemID)
        }) else {
            // Item was deleted — clean up the queue entry
            await dequeue(itemID: itemID)
            return
        }

        let feedItem = itemRecord.toFeedItem()

        // 3. Determine resolution URLs
        let imageURL = feedItem.bestImageURL.flatMap(URL.init(string:))
        let articleURL = feedItem.canResolveArticleImage ? URL(string: feedItem.url) : nil

        guard imageURL != nil || articleURL != nil else {
            // No resolution path available — mark as failed
            await markFailed(itemID: itemID, error: "No resolution URL available")
            return
        }

        // 4. Clear ArticleImageResolver miss cache for this article URL
        if let articleURL {
            await ArticleImageResolver.shared.resetMiss(for: articleURL)
        }

        // 5. Attempt resolution
        let resolvedImage = await ImageLoader.resolveImage(url: imageURL, articleURL: articleURL)

        guard !Task.isCancelled else { return }

        if resolvedImage != nil {
            // SUCCESS: remove from queue, notify delegate
            await onSuccess(itemID: itemID)
        } else {
            // FAILURE: increment retry count or exhaust
            await onFailure(itemID: itemID, record: record, error: "ImageLoader.resolveImage returned nil")
        }
    }

    // MARK: - Outcome Handlers

    private func onSuccess(itemID: String) async {
        pendingIDs.remove(itemID)
        await dequeue(itemID: itemID)

        // The resolved image is already in ImageCache, which is what the next
        // composition reads. The delegate is still notified so the contract is
        // enforced and testable at one place — see the protocol documentation:
        // it must not rewrite a card that was already published.
        await delegate?.imageResolutionQueue(didResolveImageFor: itemID)
    }

    private func onFailure(itemID: String, record: ImageRetryQueueRecord, error: String) async {
        let newRetryCount = record.retryCount + 1
        let now = Int(Date().timeIntervalSince1970)

        if newRetryCount >= Self.maxRetries {
            await markFailed(itemID: itemID, error: error)
            await delegate?.imageResolutionQueue(didExhaustRetriesFor: itemID)
        } else {
            let delayIdx = min(newRetryCount - 1, Self.backoffDelays.count - 1)
            let delay = Self.backoffDelays[delayIdx]
            let nextRetryAt = now + Int(delay)

            try? await db.write { db in
                try db.execute(
                    sql: """
                        UPDATE image_retry_queue
                        SET state = 'pending',
                            retry_count = ?,
                            next_retry_at = ?,
                            last_error = ?,
                            updated_at = ?
                        WHERE item_id = ? AND state = 'in_progress'
                        """,
                    arguments: [newRetryCount, nextRetryAt, error, now, itemID]
                )
            }

            // Keep polling to catch the next retry window
            startPolling()
        }
    }

    private func markFailed(itemID: String, error: String) async {
        pendingIDs.remove(itemID)
        let now = Int(Date().timeIntervalSince1970)
        try? await db.write { db in
            try db.execute(
                sql: """
                    UPDATE image_retry_queue
                    SET state = 'failed', last_error = ?, updated_at = ?
                    WHERE item_id = ? AND state = 'in_progress'
                    """,
                arguments: [error, now, itemID]
            )
        }
    }

    // MARK: - SQLite Helpers

    /// How long the loop may sleep before its next look, or `nil` when the
    /// table holds neither a `pending` row nor an `in_progress` claim.
    ///
    /// The delay is the time until the earliest scheduled retry (or until the
    /// oldest claim's lease expires), capped by ``pollInterval``: capping keeps
    /// the latency of a *newly* enqueued item bounded — a fresh row next to a
    /// six-hour backoff must not wait six hours — and keeps the query cost at
    /// the four-per-minute the loop always had while work was eligible.
    private func nextWakeDelay() async -> TimeInterval? {
        let now = Date().timeIntervalSince1970
        let snapshot = try? await db.read { db -> (pending: Int, nextAt: Int?, inProgress: Int, leaseAt: Int?)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                  (SELECT COUNT(*) FROM image_retry_queue WHERE state = 'pending') AS pending,
                  (SELECT MIN(next_retry_at) FROM image_retry_queue WHERE state = 'pending') AS next_at,
                  (SELECT COUNT(*) FROM image_retry_queue WHERE state = 'in_progress') AS in_progress,
                  (SELECT MIN(updated_at) FROM image_retry_queue WHERE state = 'in_progress') AS lease_at
                """) else { return nil }
            let pending: Int = row["pending"]
            let nextAt: Int? = row["next_at"]
            let inProgress: Int = row["in_progress"]
            let leaseAt: Int? = row["lease_at"]
            return (pending, nextAt, inProgress, leaseAt)
        }

        guard let snapshot, snapshot.pending > 0 || snapshot.inProgress > 0 else { return nil }

        var wait = Self.pollInterval
        if let nextAt = snapshot.nextAt {
            wait = min(wait, max(0, Double(nextAt) - now))
        }
        if let leaseAt = snapshot.leaseAt {
            wait = min(wait, max(0, Double(leaseAt) + Self.inProgressLeaseTimeout - now))
        }
        return max(Self.minimumWakeDelay, wait)
    }

    /// Return claims whose resolution never wrote an outcome to `pending` so a
    /// later cycle selects them again.
    ///
    /// `reclaimAll` is used by ``start()`` (a fresh actor owns no live lease, so
    /// every `in_progress` row is a leftover from a previous run); the poll loop
    /// passes `false` and takes back only leases older than
    /// ``inProgressLeaseTimeout``.
    private func recoverExpiredLeases(reclaimAll: Bool = false) async {
        let now = Int(Date().timeIntervalSince1970)
        let cutoff = reclaimAll ? Int.max : now - Int(Self.inProgressLeaseTimeout)
        try? await db.write { db in
            try db.execute(
                sql: """
                    UPDATE image_retry_queue
                    SET state = 'pending', next_retry_at = ?, updated_at = ?
                    WHERE state = 'in_progress' AND updated_at <= ?
                    """,
                arguments: [now, now, cutoff]
            )
        }
    }

    private func loadPendingFromSQLite() async {
        // Everything that is not terminal: `pending` rows are work by
        // definition (whatever their retry date) and `in_progress` rows are
        // claims that are about to be processed or recovered. The old query
        // loaded only rows eligible at this instant, so a row that was waiting
        // out its backoff was not even known to the in-memory de-duplication set.
        let ids: [String] = (try? await db.read { db in
            try String.fetchAll(db, sql: """
                SELECT item_id FROM image_retry_queue
                WHERE state IN ('pending', 'in_progress')
                ORDER BY next_retry_at ASC
                """)
        }) ?? []
        pendingIDs.formUnion(ids)
    }
}
