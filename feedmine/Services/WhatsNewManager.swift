import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class WhatsNewManager {
    let db: DatabaseQueue

    // MARK: - State
    private(set) var whatsNewPool: [FeedItem] = []
    private(set) var whatsNewItems: [FeedItem] = []
    var whatsNewBoosterTask: Task<Void, Never>?
    var whatsNewBaselineDate: Date?

    private let whatsNewThreshold = 10
    private static let lastWhatsNewSeenAtKey = "last_whats_new_seen_at"

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Candidate Collection

    /// Items fetched since the baseline snapshot, respecting all active filters.
    /// Called every time new items are persisted into the database.
    /// Feeds the What's New candidate pool — items accumulate in the
    /// background until the threshold is reached, then the carousel appears.
    func collectWhatsNewCandidates(
        _ newItems: [FeedItem],
        visibleIDs: Set<String>,
        readIDs: Set<String>,
        matchesActiveFilters: (FeedItem) -> Bool,
        markSurfaced: ([FeedItem]) -> Void
    ) {
        let weekAgo = Date().addingTimeInterval(-604800)  // 7 days
        let candidates = newItems.filter { item in
            item.publishedAt > weekAgo
            && matchesActiveFilters(item)
            && !visibleIDs.contains(item.id)
            && !readIDs.contains(item.id)
        }
        guard !candidates.isEmpty else { return }
        // Merge into pool: one per source, newest first
        var pool = (candidates + whatsNewPool).sorted { $0.publishedAt > $1.publishedAt }
        var seen = Set<String>()
        pool = pool.filter { seen.insert($0.sourceURL).inserted }
        whatsNewPool = pool
        // Promote when threshold reached
        promoteWhatsNewIfReady(markSurfaced: markSurfaced)
    }

    /// Promote candidates to the visible carousel when the pool is full.
    func promoteWhatsNewIfReady(markSurfaced: ([FeedItem]) -> Void) {
        guard whatsNewItems.isEmpty, whatsNewPool.count >= whatsNewThreshold else { return }
        whatsNewItems = Array(whatsNewPool.prefix(whatsNewThreshold))
        whatsNewPool.removeFirst(min(whatsNewThreshold, whatsNewPool.count))
        // Carousel items are visible on screen — mark as surfaced
        markSurfaced(whatsNewItems)
    }

    /// Advance the carousel: return shown (unclicked) items to the pool so
    /// they remain available for future selections, then promote next batch.
    func advanceWhatsNew(markSurfaced: ([FeedItem]) -> Void) {
        // Return unclicked items to the pool — they were only previewed, not consumed
        if !whatsNewItems.isEmpty {
            whatsNewPool = (whatsNewItems + whatsNewPool)
                .sorted { $0.publishedAt > $1.publishedAt }
        }
        whatsNewItems = []
        promoteWhatsNewIfReady(markSurfaced: markSurfaced)
    }

    /// Kick off an aggressive fetch to fill the What's New pool quickly at
    /// cold start. Runs alongside the DB seed — if the database has nothing,
    /// this fetches fresh content from the network immediately.
    func fetchWhatsNewBooster(
        grantedSources: [FeedSource],
        fetcher: RSSFetcher,
        finishDemand: @escaping ([FeedSource], FeedFetchBatch) -> Void,
        persistFetchedItems: @escaping ([FeedItem]) async -> [FeedItem],
        throttledReservoirAppend: @escaping ([FeedItem]) -> Void,
        collectCandidates: @escaping ([FeedItem]) -> Void,
        prefetchImages: @escaping ([FeedItem]) -> Void,
        recordFetch: @escaping (String, FeedFetchOutcome) -> Void
    ) {
        // A cancelled task may already be inside GRDB's transactional write.
        // Let that short write finish and reuse it for the current filters:
        // candidate matching is evaluated when the results arrive.
        let declinedBatch = FeedFetchBatch(
            items: [], fetchedSourceCount: 0, failedSourceCount: 0,
            emptySourceCount: 0, notModifiedCount: 0, throttledCount: 0,
            sourceOutcomes: [:]
        )
        guard whatsNewBoosterTask == nil else {
            // The store claimed these endpoints before calling in; a declined boost still releases them.
            finishDemand(grantedSources, declinedBatch)
            return
        }
        whatsNewBoosterTask = Task { [weak self] in
            guard let self else {
                finishDemand(grantedSources, declinedBatch)
                return
            }
            defer { self.whatsNewBoosterTask = nil }
            let sources = Array(grantedSources.shuffled().prefix(30))
            guard !sources.isEmpty else {
                finishDemand(sources, declinedBatch)
                return
            }
            let result = await fetcher.fetchAll(sources, maxConcurrent: 5)
            // Every remaining exit path releases the claim here, including cancellation, and only once.
            finishDemand(sources, result)
            guard !Task.isCancelled else { return }
            await Task.yield()
            let actualNew = await persistFetchedItems(result.items)
            guard !Task.isCancelled else { return }
            if !actualNew.isEmpty {
                prefetchImages(actualNew)
                throttledReservoirAppend(actualNew)
                collectCandidates(actualNew)
                for source in sources {
                    recordFetch(source.url, result.sourceOutcomes[source.url] ?? .failed(URLError(.unknown)))
                }
            }
        }
    }

    /// Refresh What's New: clear the pool and re-seed it from the local DB.
    /// An optional booster can add fresh network results when the app starts.
    func refreshWhatsNew(
        seedFromDB: @escaping () async -> Void,
        booster: @escaping () -> Void
    ) {
        whatsNewItems = []
        whatsNewPool = []
        Task { await seedFromDB() }
        booster()
    }

    /// Seed the pool from existing SQLite content — runs once at startup
    /// so the carousel isn't empty while waiting for the first fetch batch.
    func seedWhatsNewFromDB(
        surfacedIDs: Set<String>,
        readIDs: Set<String>,
        matchesActiveFilters: (FeedItem) -> Bool,
        markSurfaced: ([FeedItem]) -> Void
    ) async {
        guard whatsNewPool.isEmpty else { return }
        do {
            let records: [FeedItemRecord] = try await db.read { db in
                try FeedItemRecord
                    .filter(Column("published_at") > Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970))
                    .filter(Column("is_read") == 0)
                    .order(Column("published_at").desc)
                    .limit(500)
                    .fetchAll(db)
            }
            let items = records.map { $0.toFeedItem() }
                .filter(matchesActiveFilters)
                .filter { !surfacedIDs.contains($0.id) && !readIDs.contains($0.id) }
            var seen = Set<String>()
            whatsNewPool = items.filter { seen.insert($0.sourceURL).inserted }
            promoteWhatsNewIfReady(markSurfaced: markSurfaced)
        } catch {
            Log.db.error("Failed to refresh What's New pool: \(error)")
        }
    }

    /// Replace visible carousel items in-place — used by the immediate filter
    /// cull so a stale-language card doesn't flash at the top after switching.
    func replaceItems(_ items: [FeedItem]) {
        whatsNewItems = items
    }

    /// Advance the baseline to now and persist it — so items already shown
    /// in the carousel aren't treated as "new" again next session.
    func advanceWhatsNewBaseline() {
        let now = Date()
        whatsNewBaselineDate = now
        UserDefaults.standard.set(now, forKey: Self.lastWhatsNewSeenAtKey)
    }

    /// Reset the What's New baseline to now so newly enabled content appears.
    func resetWhatsNewBaseline() {
        let now = Date()
        whatsNewBaselineDate = now
        UserDefaults.standard.set(now, forKey: Self.lastWhatsNewSeenAtKey)
    }
}
