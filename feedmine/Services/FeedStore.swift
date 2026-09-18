import Foundation
import UIKit
import GRDB
import NaturalLanguage
import Observation
import FeedRuntime
import FeedDomain

private actor CuratedStarterSourceCache {
    static let shared = CuratedStarterSourceCache()
    private var sourcesByLanguage: [String: [FeedSource]] = [:]

    func sources(language: String, minimumCount: Int) -> [FeedSource]? {
        guard let sources = sourcesByLanguage[language],
              sources.count >= minimumCount else { return nil }
        return Array(sources.prefix(minimumCount))
    }

    func store(_ sources: [FeedSource], language: String) {
        guard sources.count > (sourcesByLanguage[language]?.count ?? 0) else { return }
        sourcesByLanguage[language] = sources
    }
}

@MainActor
@Observable
final class FeedStore {
    // MARK: - Subcomponents
    let db: DatabaseQueue
    let registry = SourceRegistry()
    let scheduler = AdaptiveScheduler()
    let reservoir = Reservoir()
    /// The process's one fetcher. Injectable so a test can script and count the requests a demand
    /// makes — the no-double-acquisition proof in PR-15 counts attempts, and a counter over the real
    /// network is neither scriptable nor offline.
    let fetcher: RSSFetcher
    let prefetcher = ImagePrefetcher()
    let cardQueue = ReadyCardQueue()
    private(set) var imageResolutionQueue: ImageResolutionQueue!

    // MARK: - Prepared feed pipeline (Phase 3+)
    /// Which path publishes. The prepared pipeline is the production path — the legacy synchronous path survives only
    /// as the in-memory affordance that lets unit tests assert on `visibleItems` without waiting for preparation.
    ///
    /// This used to be `usesPersistentStorage && Settings.preparedFeedPipelineEnabled`, which made the legacy branch
    /// *selectable in production* through a UserDefaults key that nothing exposed (`feedmineApp.swift` set it to true
    /// on every boot and no view offered it). Selection by UserDefaults was the duality; `usesPersistentStorage` is the
    /// seam the tests actually need. See review P1.3.
    private var usePreparedPipeline: Bool {
        usesPersistentStorage
    }

    // MARK: - Display State (extracted to FeedDisplayState)

    /// Extracted display state component.
    let display = FeedDisplayState()

    /// Monotonic counter incremented on filter/preset/mode changes.
    var presentationEpoch: UInt64 { display.presentationEpoch }
    /// Current feed mode — updated when switching between main/collection/bookmark/etc.
    private var currentMode: FeedPresentationMode = .main
    /// New pipeline components — initialized after DB is ready.
    private var mediaAssetStore: MediaAssetStore!
    private var runwayPolicy: RunwayPolicy!
    private var preparationCoordinator: CardPreparationCoordinator!
    private var runwayController: FeedRunwayController!
    private var pipelineTask: Task<Void, Never>?
    private var cardPreparationTask: Task<Void, Never>?
    let networkMonitor = NetworkMonitor()
    let userRepo: UserStateStore
    let bookmarkStore: BookmarkStore
    let smartFeedStore: SmartFeedStore
    let curatedFeedStore: CuratedFeedStore
    let sourceCollectionStore: SourceCollectionStore
    let searchEngine: SearchEngine
    let whatsNewManager: WhatsNewManager

    // MARK: - Public state
    var visibleItems: [FeedItem] { display.visibleItems }
    /// Pre-resolved card presentations for the main feed.
    var visibleCards: [FeedCardPresentation] { display.visibleCards }
    /// Monotonic generation counter — incremented on every visibleItems change.
    var visibleItemsGeneration: UInt64 { display.visibleItemsGeneration }
    /// Monotonic counter incremented on every visibleCards change (card-only
    /// swaps like placeholder → resolved image). FeedLoader includes this in
    /// its cache keys so resolved images actually render.
    var visibleCardsGeneration: UInt64 { display.visibleCardsGeneration }
    /// Monotonic counter incremented on in-place item mutations that skip
    /// the generation bump. FeedLoader includes this in its cache keys so
    /// read/bookmark state always re-renders.
    var readStateRevision: UInt64 { display.readStateRevision }
    private(set) var reservoirCount: Int = 0
    var lastToggleMessage: String?
    var loadingState: FeedLoadingState { display.loadingState }
    /// Current display phase — governs what the feed UI shows (loading, ready, empty, failed).
    /// Replaces the error-prone pattern of inferring state from items.isEmpty + loadingState.
    var feedDisplayPhase: FeedDisplayPhase { display.feedDisplayPhase }
    private(set) var lastRefreshDate: Date?
    private(set) var totalFetched = 0
    private(set) var fetchErrorCount = 0
    private(set) var lastFetchSucceeded = false  // reset error banner on success
    private(set) var emptyFeedCount = 0
    private(set) var totalDiscarded = 0
    var emptyStateFetchedCount: Int = 0
    var emptyStateFetchTotal: Int = 0
    private(set) var hasPreviouslyLoadedContent = false
    private(set) var startupFetchedSourceCount = 0
    private(set) var startupTargetSourceCount = 100
    private(set) var startupTotalSourceCount = 0
    private(set) var startupRecentSourceNames: [String] = []
    private(set) var startupRunwayReady = false

    /// True while a user-initiated composition is being fetched and prepared. The surface uses it to show
    /// the in-progress view instead of "no results": a type filter whose content is not local yet has
    /// nothing to show for several seconds, and an absence screen there is the user's own complaint
    /// ("empty screens appearing for no reason") — while a genuinely finished empty answer still settles.
    var isPreparingFilteredComposition: Bool { display.isFilteredCompositionInFlight }

    /// Items already fetched toward the first screen. This is what actually releases the page
    /// (`coldStartImmediateItemCount`), so the progress surface states it beside the source count —
    /// the same distinction that had to be made in the publication gate.
    private(set) var startupItemsReady = 0
    private var startupSeenItemIDs = Set<String>()

    /// Items that make a first screen.
    var startupItemsTarget: Int { Self.coldStartImmediateItemCount }
    var isPreparingInitialRunway: Bool { display.isPreparingInitialRunway }
    /// True while an urgent taxonomy fetch is in-flight — FeedScreen uses this
    /// to keep the empty state in .fetching mode until items actually arrive.
    private(set) var isUrgentFetching = false

    /// Cached podcast counts — updated after fetch batches, not on every access (#24)
    private(set) var podcastItemCount = 0
    private(set) var podcastSourceCount = 0

    private func refreshPodcastCounts() {
        Task {
            do {
                let (items, sources) = try await db.read { db -> (Int, Int) in
                    let items = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item WHERE audio_url IS NOT NULL") ?? 0
                    let sources = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT source_url) FROM feed_item WHERE audio_url IS NOT NULL") ?? 0
                    return (items, sources)
                }
                podcastItemCount = items
                podcastSourceCount = sources
            } catch {}
        }
    }

    // MARK: - Filter state (bidirectional)
    var activeRegion: String?
    var activeNodeIDs: Set<String> = []
    var activeContentType: FeedLoader.ContentType = .all
    var activeMood: FeedLoader.MoodFilter = .all
    var activeLanguages: Set<String> = []
    /// True when the user explicitly chose "all languages" (cleared filter).
    /// Reset when the user toggles a specific language. Not persisted — on
    /// next launch the device-language default is applied again.
    var hasUserClearedLanguageFilter = false

    /// Per-language item buffer. When the user switches from English to
    /// Portuguese and back, the English items are restored instantly from
    /// this buffer rather than requiring a full reload+fetch cycle.
    /// Max 2 language slots (current + previous); LRU eviction on third.
    private var languageItemBuffer: [String: [FeedItem]] = [:]
    private var languageBufferOrder: [String] = []  // LRU tracking, max 2

    // MARK: - Preset state

    /// The active feed preset. Drives scoring multipliers across the entire
    /// fetch pipeline (scheduler, reservoir, coverage mining, cold start).
    private(set) var activePreset: PresetSelector = Settings.activePreset

    /// Precomputed dictionary of source URL → scoring multiplier for the
    /// current activePreset. Rebuilt when the preset changes. Missing keys
    /// default to 1.0. Passed to scheduler, reservoir, and fetch methods.
    /// Only used for editorial presets; nil/empty for collection presets.
    private(set) var presetMultipliers: [String: Double] = [:]

    /// When the active preset is a `.collection`, this contains the **normalized**
    /// source URLs of all collection members. The fetch pipeline uses it as an
    /// **exclusive allowlist** — only these sources are fetched and displayed.
    /// `nil` for editorial presets (permissive scoring), non-nil for
    /// collection presets (exclusive filtering).
    /// URLs are normalized to match FeedItem.sourceURL in SQLite (which is
    /// stored normalized via `withNormalizedSourceURL`).
    private(set) var presetSourceFilter: Set<String>?

    /// Raw source URLs of collection members. Used by `rebuildPresetMultipliers`
    /// to build `presetSourceFilter`. Kept separately for cache invalidation.
    private var activeCollectionMemberURLs: Set<String> = []
    /// Cached identities for the active Smart Feed. Smart Feeds deliberately
    /// keep consumed items, so this set replaces the normal consumed-item
    /// exclusion while the preset is open.
    private var activeSmartFeedItemIDs: Set<String> = []
    private var activeSmartFeedSourceURLs: Set<String> = []

    /// Handle for the in-flight rebuildPresetMultipliers task. Cancelled before
    /// starting a new rebuild to prevent stale writes from the previous preset.
    private var presetRebuildTask: Task<Void, Never>?

    /// Cached set of feed URLs that match the current taxonomy selection.
    /// Invalidated when activeNodeIDs changes. Makes applyFilters O(items) instead
    /// of O(items x selectedNodes).
    private(set) var cachedTaxonomyFeedURLs: Set<String> = []
    private var cachedTaxonomyNodeIDs: Set<String> = []
    /// Size of the taxonomy tree when `cachedTaxonomyFeedURLs` was filled, so a refresh that ran
    /// before the tree existed can be redone once it appears.
    private var cachedTaxonomyShape: Int = -1
    /// Monotonic counter incremented on every filter change. Async operations
    /// (urgent fetch, reloadFromSQLite pipeline) capture the generation at launch
    /// and discard results if a newer filter has been applied in the meantime.
    private var filterGeneration: Int64 = 0
    /// Public read-only access for cache invalidation keys (FeedLoader).
    var activeFilterGeneration: Int64 { filterGeneration }
    /// Monotonic counter incremented on every preset change. Async operations
    /// originated by a preset selection (rebuild, source-enablement refresh,
    /// collection hydration, filter reloads) capture the generation at launch
    /// and discard results if a newer preset has been selected in the meantime.
    /// This prevents a stale editorial source-enablement flush from clearing
    /// correctly-hydrated collection content.
    private var presetGeneration: Int64 = 0
    /// When set, the feed shows only items from this bookmark list.
    var selectedBookmarkListID: Int64?
    /// Preferred box for saving bookmarks. Defaults to the "Favorites" list.
    var preferredBookmarkListID: Int64?
    private(set) var isBookmarkFeed = false

    /// Load a fixed bookmark feed — all items from the box, ordered by save date.
    /// Pauses all background processes that would modify the screen.
    func loadBookmarkFeed(items: [FeedItem]) {
        isBookmarkFeed = true
        currentMode = .bookmarks(selectedBookmarkListID)
        pipelineTask?.cancel()
        cardPreparationTask?.cancel()
        trimDebounceTask?.cancel()
        progressiveFetchTask?.cancel()
        coverageMiningTask?.cancel()
        backgroundRefreshTask?.cancel()
        setVisibleItems(items)
        reservoirCount = 0
        reservoir.clear()
    }

    /// Clear bookmark mode and reload the normal feed.
    func clearBookmarkFeed() {
        isBookmarkFeed = false
        currentMode = .main
        startBackgroundRefresh()
        applyUpdate(.flush())
    }
    /// Single eligibility rule — used by fetch and in-memory filter paths.
    /// (The SQL path loads items from taxonomy URLs unconditionally; the
    /// in-memory applyFilters pass then applies this rule to cull individually
    /// disabled sources.)
    ///
    /// - When taxonomy is active AND the item's source URL is in the taxonomy
    ///   set: bypass category/region disables but still respect individual
    ///   per-source opt-outs. An explicit taxonomy selection acts as a temporary
    ///   query over the full catalogue.
    /// - Otherwise: delegate to the normal SourceRegistry enablement check.
    private func isSourceEligible(sourceURL: String, taxonomySelectionActive: Bool) -> Bool {
        let isExplicitCatalogueQuery = activeContentType != .all
            || (taxonomySelectionActive
                && cachedTaxonomyFeedURLs.contains(OPMLParser.normalizeURL(sourceURL)))
        if isExplicitCatalogueQuery {
            // Bypass inherited disables (category, region) but respect individual off
            return !registry.isSourceExplicitlyDisabled(sourceURL)
        }
        return registry.isSourceEnabled(sourceURL)
    }

    /// Safety filter: excludes items from disabled regions/categories/feeds.
    /// Respects taxonomy override — see isSourceEligible for semantics.
    private func isItemEnabled(_ item: FeedItem) -> Bool {
        isSourceEligible(sourceURL: item.sourceURL, taxonomySelectionActive: !cachedTaxonomyFeedURLs.isEmpty)
    }

    /// Prefetch images for items if enabled (default: true).
    private func prefetchImagesIfEnabled(for items: [FeedItem]) {
        // When the prepared pipeline is active, CardPreparationCoordinator and
        // MediaAssetStore handle all image resolution via single-flight
        // deduplication. Avoid duplicate downloads that compete for network.
        guard !usePreparedPipeline else { return }
        guard Settings.prefetchImages else { return }
        let urls = items.compactMap { $0.bestImageURL ?? $0.imageURL }
        guard !urls.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: urls, priorityURLs: urls) }
    }

    /// Resolve article-page artwork in parallel background tasks so images
    /// are cached before cards render. Does NOT block the feed pipeline —
    /// items enter the reservoir immediately. Sentinel writes on failure
    /// prevent redundant resolution on future launches.
    private func resolveArticleImagesInBackground(_ items: [FeedItem]) {
        // When the prepared pipeline is active, CardPreparationCoordinator and
        // MediaAssetStore handle all image resolution. Skip legacy resolution
        // to avoid duplicate network and disk work.
        guard !usePreparedPipeline else { return }
        let needsResolution = items.filter {
            $0.bestImageURL == nil && $0.canResolveArticleImage
        }
        guard !needsResolution.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = needsResolution.makeIterator()
                let maxConcurrent = 4  // match ArticleImageResolver's limit
                var running = 0

                while running < maxConcurrent, let item = iterator.next() {
                    group.addTask { await self.resolveOneArticleImage(item) }
                    running += 1
                }
                while await group.next() != nil {
                    if let item = iterator.next() {
                        group.addTask { await self.resolveOneArticleImage(item) }
                    }
                }
            }
        }
    }

    private func resolveOneArticleImage(_ item: FeedItem) async {
        guard let articleURL = URL(string: item.url) else { return }
        // Skip if the article image is already cached from a previous session.
        guard !ImageCache.hasCachedImageData(for: articleURL) else { return }
        let found = await prefetcher.prefetchArticleImage(for: articleURL)
        if !found {
            // Instead of writing a permanent empty sentinel, enqueue for
            // background retry. The ImageResolutionQueue will retry with
            // exponential backoff and update the card in-place on success.
            Task { [weak self] in
                await self?.imageResolutionQueue.enqueue(itemID: item.id)
            }
        }
    }

    /// Prefetch the next batch of upcoming items so images are cached before
    /// the user scrolls to them.  Visible items are intentionally *not*
    /// included — by the time they are visible the cells have already started
    /// their own loads; the shared ``ImageDownloadTracker`` deduplicates them.
    private func prefetchUpcoming() {
        // When the prepared pipeline is active, CardPreparationCoordinator
        // and MediaAssetStore handle all image resolution. Skip legacy
        // prefetch to avoid duplicate network and disk work.
        guard !usePreparedPipeline else { return }
        guard Settings.prefetchImages else { return }
        let upcoming = reservoir.upcomingItems(100).compactMap { $0.bestImageURL ?? $0.imageURL }
        guard !upcoming.isEmpty else { return }
        Task { await prefetcher.prefetch(urls: upcoming, priorityURLs: []) }
    }

    /// Normalize a set of language codes to ISO 639-1 base codes.
    /// Used to ensure selected languages, persisted settings, and any
    /// BCP 47 input from external sources all converge on the same keys.
    static func normalizedLanguageSet(_ languages: some Sequence<String>) -> Set<String> {
        Set(languages.compactMap(normalizedLanguageCode))
    }

    /// Fast-path language filter — assumes `selectedLanguages` and
    /// `deviceLanguage` are already normalized to ISO 639-1 base codes.
    /// Only `itemLanguage` is normalized (items may carry raw BCP 47 tags
    /// or unrecognized input from feeds).
    ///
    /// Used in hot paths (`applyFilters`) where the set and device language
    /// are normalized once before the per-item loop.
    nonisolated static func languageFilterMatchesNormalized(
        itemLanguage: String?,
        selectedLanguages: Set<String>,
        deviceLanguage _: String?
    ) -> Bool {
        guard !selectedLanguages.isEmpty else { return true }
        if let lang = normalizedLanguageCode(itemLanguage) {
            return selectedLanguages.contains(lang)
        }
        return false
    }

    /// Public defensive wrapper — normalizes all three inputs before
    /// delegating to the fast path. Safe for external callers, tests,
    /// and any code that may receive unnormalized BCP 47 input.
    static func languageFilterMatches(
        itemLanguage: String?,
        selectedLanguages: Set<String>,
        deviceLanguage: String?
    ) -> Bool {
        languageFilterMatchesNormalized(
            itemLanguage: itemLanguage,
            selectedLanguages: normalizedLanguageSet(selectedLanguages),
            deviceLanguage: normalizedLanguageCode(deviceLanguage)
        )
    }

    /// Normalize a language tag to its ISO 639-1 base code.
    /// - Trims whitespace, normalizes underscores to hyphens
    /// - Extracts the primary language subtag from BCP 47 / RFC 5646 tags
    ///   (e.g. "pt-BR" → "pt", "en_US" → "en", "zh-Hant" → "zh")
    /// - Returns lowercase code, or nil for empty/whitespace-only input
    nonisolated static func normalizedLanguageCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty else { return nil }
        // Use Foundation's Locale.Language to extract the primary language
        // subtag — handles arbitrary BCP 47 complexity correctly.
        if let code = Locale.Language(identifier: trimmed).languageCode?.identifier {
            return code.lowercased()
        }
        // Fallback: split on first hyphen (covers codes Foundation may reject)
        return trimmed
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() }
    }

    /// Lightweight, Sendable input for off‑main‑actor language detection.
    private struct LanguageDetectionInput: Sendable {
        let title: String
        let excerpt: String
        /// Language declared by the item/feed or inherited from the catalogue.
        /// It is a fallback, not an authority: publishers often ship stale or
        /// incorrect language metadata.
        let explicitLanguage: String?
    }

    /// Scripts with a dependable one-language answer for Feedmine's supported
    /// language codes. This also handles short headlines that are too small for
    /// NLLanguageRecognizer and mixed feeds whose XML incorrectly declares en.
    nonisolated private static func distinctiveScriptLanguage(in text: String) -> String? {
        let scalars = text.unicodeScalars
        func count(in range: ClosedRange<UInt32>) -> Int {
            scalars.reduce(into: 0) { total, scalar in
                if range.contains(scalar.value) { total += 1 }
            }
        }

        if count(in: 0x0980...0x09FF) >= 2 { return "bn" } // Bengali
        if count(in: 0x0530...0x058F) >= 2 { return "hy" } // Armenian
        if count(in: 0x10A0...0x10FF) >= 2 { return "ka" } // Georgian
        if count(in: 0x0E00...0x0E7F) >= 2 { return "th" } // Thai
        if count(in: 0x1780...0x17FF) >= 2 { return "km" } // Khmer
        if count(in: 0xAC00...0xD7AF) >= 2 { return "ko" } // Hangul
        if count(in: 0x0590...0x05FF) >= 2 { return "he" } // Hebrew
        if count(in: 0x0370...0x03FF) >= 2 { return "el" } // Greek
        let kanaCount = count(in: 0x3040...0x30FF)
        if kanaCount >= 2 { return "ja" }
        // Han characters are not distinctive to Chinese: Japanese uses them
        // heavily, and an otherwise English article may quote a Chinese name.
        // Let NLLanguageRecognizer evaluate the complete text instead.
        return nil
    }

    /// Run language detection for a batch of items off the main actor.
    /// Reuses a single NLLanguageRecognizer across the batch to avoid
    /// per‑item allocation overhead. Returns resolved language codes in the
    /// same order as the input array.
    nonisolated private static func detectLanguages(_ inputs: [LanguageDetectionInput]) -> [String?] {
        guard !inputs.isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        let minimumTextForDetection = 12
        let minimumTextForSourceOverride = 48
        let minimumOverrideConfidence = 0.80
        let minimumOverrideMargin = 0.15
        return inputs.map { input in
            let text = (input.title + " " + input.excerpt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // NaturalLanguage has no Azerbaijani model and commonly reports
            // Turkish instead. Schwa is distinctive in Azerbaijani Latin text.
            if text.rangeOfCharacter(from: CharacterSet(charactersIn: "Əə")) != nil {
                return "az"
            }
            if let scriptLanguage = distinctiveScriptLanguage(in: text) {
                return scriptLanguage
            }
            // Run detection when there's enough text. Source-level OPML tags
            // can be wrong for multilingual feeds (e.g. youtube.opml tagged
            // "en" with content in many languages).
            if text.count >= minimumTextForDetection {
                recognizer.reset()
                recognizer.processString(text)
                let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
                    .compactMap { language, confidence -> (language: String, confidence: Double)? in
                        guard let code = normalizedLanguageCode(language.rawValue) else { return nil }
                        return (code, confidence)
                    }
                    .sorted { $0.confidence > $1.confidence }
                if let best = hypotheses.first {
                    let detected = best.language
                    let runnerUp = hypotheses.dropFirst().first?.confidence ?? 0
                    if let explicit = input.explicitLanguage, !explicit.isEmpty {
                        if explicit == detected { return explicit }
                        let margin = best.confidence - runnerUp
                        if text.count >= minimumTextForSourceOverride,
                           best.confidence >= minimumOverrideConfidence,
                           margin >= minimumOverrideMargin {
                            return detected
                        }
                        return explicit
                    }
                    return detected
                }
            }
            // Fall back to explicit source language (OPML header)
            if let lang = input.explicitLanguage, !lang.isEmpty {
                return lang
            }
            return nil
        }
    }

    nonisolated static func resolvedLanguage(
        title: String,
        excerpt: String,
        explicitLanguage: String? = nil
    ) -> String? {
        detectLanguages([
            LanguageDetectionInput(
                title: title,
                excerpt: excerpt,
                explicitLanguage: normalizedLanguageCode(explicitLanguage)
            )
        ]).first ?? nil
    }

    nonisolated static func googleNewsPublisher(fromArticleTitle title: String) -> String? {
        guard let separator = title.range(of: " - ", options: .backwards) else { return nil }
        let publisher = title[separator.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard publisher.count >= 2, publisher.count <= 80 else { return nil }
        return publisher
    }

    /// Apply all active filters to a list of items — single source of truth.
    /// Hit recording is NOT performed here; it happens once at ingestion time
    /// in persistFetchedItems so each item is counted exactly once regardless
    /// of how many times applyFilters runs on the same items.
    // Cache mood/content filter results per item ID to avoid O(k) string
    // scanning on every applyFilters call (called on each reservoir operation).
    private var moodMatchCache: [String: Bool] = [:]
    private var moodMatchCacheKey: String = ""
    private var contentFilterExcludeCache: [String: Bool] = [:]
    private var contentFilterCacheKey: String = ""

    /// Nonisolated, Sendable filter input — all state needed for a filter pass.
    /// Captured from the main actor and passed to a detached task so the
    /// per-item loop runs off the main thread.
    struct FilterInput: Sendable {
        let region: String?
        let contentType: FeedLoader.ContentType
        let languages: Set<String>
        let mood: FeedLoader.MoodFilter
        let deviceLanguage: String?
        let sourceFilter: Set<String>?
        let isClickHistory: Bool
        let isSmartFeed: Bool
        let clickIDs: Set<String>
        let smartFeedIDs: Set<String>
        let consumedIDs: Set<String>
        let taxonomyURLs: Set<String>
        let includeConsumed: Bool
        /// Snapshot of the user's enabled content filters. The off-main pass
        /// MUST apply the same keyword rule as the main-actor pass: without
        /// this, an item hidden by a content filter reappears through every
        /// path that filters off-main (startup, filter changes, append).
        let contentFilters: [(id: UUID, keywords: [String])]
        /// Key of the filter set above, as recorded in `contentFilterCacheKey`.
        /// Carried so the merge-back can be discarded when the filters change
        /// while this pass is still running off-main.
        let contentFilterKey: String
        // Snapshot of caches — read-only on the filtering side
        let moodMatchSnapshot: [String: Bool]
        let contentExcludeSnapshot: [String: Bool]
        /// Pre-computed set of explicitly disabled source URLs (normalized).
        /// Used instead of calling isSourceEnabled from off-main context.
        let disabledSourceURLs: Set<String>
        /// Normalized URLs the user turned off individually. An explicit catalogue
        /// query — a content-type filter, or a taxonomy selection that names the
        /// source — bypasses inherited disables (category, region) but not these,
        /// mirroring `isSourceEligible` on the main-actor path.
        let explicitlyDisabledSourceURLs: Set<String>
    }

    /// Off-main filter: runs the full predicate loop in a detached task.
    /// Returns filtered items + updated mood/content caches for the caller
    /// to merge back on the main actor.
    static func applyFiltersOffMain(
        _ items: [FeedItem],
        input: FilterInput
    ) async -> (filtered: [FeedItem], moodCache: [String: Bool], contentCache: [String: Bool]) {
        await Task.detached(priority: .userInitiated) {
            var moodCache = input.moodMatchSnapshot
            var contentCache = input.contentExcludeSnapshot
            let filtered = items.filter { item in
                let normalizedSourceURL = OPMLParser.normalizeURL(item.sourceURL)
                // Mirrors `isSourceEligible` on the main-actor path: an explicit
                // catalogue query — a content-type filter, or a taxonomy selection
                // that names this source — bypasses inherited disables (category,
                // region) but still respects a source the user turned off by hand.
                let isExplicitCatalogueQuery = input.contentType != .all
                    || (!input.taxonomyURLs.isEmpty
                        && input.taxonomyURLs.contains(normalizedSourceURL))
                let enabledByUser = input.sourceFilter?.contains(normalizedSourceURL)
                    ?? (isExplicitCatalogueQuery
                        ? !input.explicitlyDisabledSourceURLs.contains(normalizedSourceURL)
                        : !input.disabledSourceURLs.contains(normalizedSourceURL))
                let sourceEnabled = input.isClickHistory || input.isSmartFeed || enabledByUser
                guard sourceEnabled else { return false }
                guard !input.isClickHistory || input.clickIDs.contains(item.id) else { return false }
                guard !input.isSmartFeed || input.smartFeedIDs.contains(item.id) else { return false }
                guard input.includeConsumed || input.isClickHistory || input.isSmartFeed
                        || !input.consumedIDs.contains(item.id) else { return false }
                guard input.region == nil || item.region == input.region
                        || item.region.hasPrefix(input.region! + "/") else { return false }
                guard input.taxonomyURLs.isEmpty
                        || input.taxonomyURLs.contains(normalizedSourceURL) else { return false }
                guard languageFilterMatchesNormalized(
                    itemLanguage: item.language,
                    selectedLanguages: input.languages,
                    deviceLanguage: input.deviceLanguage
                ) else { return false }
                switch input.contentType {
                case .all: break
                case .text:  guard !item.isYouTube && !item.isPodcast && !item.isForum else { return false }
                case .video: guard item.isYouTube else { return false }
                case .audio: guard item.isPodcast else { return false }
                case .forum: guard item.isForum else { return false }
                }

                if input.mood != .all {
                    if let cached = moodCache[item.id] { guard cached else { return false } }
                    else {
                        let match = input.mood.matches(item.title)
                        moodCache[item.id] = match
                        guard match else { return false }
                    }
                }

                // Content filter check — mirrors the main-actor pass exactly.
                if !input.contentFilters.isEmpty {
                    if let cached = contentCache[item.id] { guard !cached else { return false } }
                    else {
                        let excluded = Self.firstMatchingContentFilterID(
                            in: item, filters: input.contentFilters
                        ) != nil
                        contentCache[item.id] = excluded
                        guard !excluded else { return false }
                    }
                }
                return true
            }
            return (filtered, moodCache, contentCache)
        }.value
    }

    /// Identity of the composition the feed is currently showing, used to key the
    /// cached first page so a warm start can only restore a page built under the
    /// same filters. Composition inputs only — the click/consumed history is
    /// deliberately excluded, because it changes on every interaction and a
    /// signature that volatile would leave the cache permanently unreachable.
    var pageCacheSignature: String {
        let contentFilterKey = ContentFilterStore.shared.isEnabled
            ? ContentFilterStore.shared.activeFilters
                .map { "\($0.id):\($0.keywords.joined(separator: ","))" }
                .joined(separator: "|")
            : ""
        return [
            activePreset.cacheKey,
            activeRegion ?? "",
            activeContentType.rawValue,
            activeLanguages.sorted().joined(separator: ","),
            activeMood.rawValue,
            presetSourceFilter?.sorted().joined(separator: "|") ?? "",
            cachedTaxonomyFeedURLs.sorted().joined(separator: "|"),
            contentFilterKey
        ].joined(separator: "\u{1F}")
    }

    /// Disabled-source URL snapshot for the off-main filter pass.
    ///
    /// It used to be recomputed inside `buildFilterInput` on every call — a walk over
    /// the whole catalogue plus a URL normalisation for each entry — so even a small
    /// append during scroll paid catalogue-sized work on the main actor (review
    /// finding 2). It is rebuilt only when the catalogue or the enablement changed, and
    /// that rebuild now happens off the main actor (see `eligibilitySets()`).
    ///
    /// Invalidation compares the registry's own `disabled` and `enabledOverrides` sets
    /// against copies, *in addition* to the revisions: the revision is bumped by the counts
    /// recompute, which the bulk toggles defer by ~120 ms (and `resetAllToggles` can skip),
    /// while the action's own reload runs inside that window. Comparing each set separately
    /// catches every mutation of either — including a source moving from one to the other,
    /// which a combined comparison would miss.
    private var eligibilityCache: (
        sourceRevision: UInt64,
        enablementRevision: UInt64,
        disabledKeys: Set<String>,
        overrideKeys: Set<String>,
        sets: (disabled: Set<String>, explicitlyDisabled: Set<String>)
    )?

    /// The filter pass's eligibility sets, rebuilt **in a detached task** when the
    /// catalogue or the enablement changed.
    ///
    /// `applyFiltersAsync` is already async, so the suspension is free — and the rebuild is
    /// regex work over 77,443 URLs that measured 1,599 ms on the main actor, which is why it
    /// does not happen there. (The synchronous `applyFilters` never asks for these sets: it
    /// resolves enablement per item.) `buildFilterInput` has exactly one caller, this one.
    private func eligibilitySets() async -> (disabled: Set<String>, explicitlyDisabled: Set<String>) {
        let inputs = registry.eligibilityInputs()
        let sourceRevision = registry.sourceRevision
        let enablementRevision = registry.enablementRevision
        if let cached = eligibilityCache,
           cached.sourceRevision == sourceRevision,
           cached.enablementRevision == enablementRevision,
           cached.disabledKeys == inputs.disabled,
           cached.overrideKeys == inputs.enabledOverrides {
            return cached.sets
        }
        let endMetric = FeedMetrics.beginInterval("Eligibility.snapshot")
        let sets = await Task.detached(priority: .userInitiated) {
            SourceRegistry.eligibilitySets(
                sources: inputs.sources,
                normalizedURLs: inputs.normalizedURLs,
                disabled: inputs.disabled,
                enabledOverrides: inputs.enabledOverrides
            )
        }.value
        endMetric()
        eligibilityCache = (
            sourceRevision,
            enablementRevision,
            inputs.disabled,
            inputs.enabledOverrides,
            sets
        )
        return sets
    }

    /// Build a FilterInput snapshot from current actor state so filtering
    /// can run off the main actor in a detached task. The eligibility sets are passed in
    /// because building them is catalogue-sized work that happens off the main actor.
    private func buildFilterInput(
        includeConsumed: Bool,
        eligibility: (disabled: Set<String>, explicitlyDisabled: Set<String>)
    ) -> FilterInput {
        let contentFilterState = activeContentFiltersForFilterPass()
        return FilterInput(
            region: activeRegion,
            contentType: activeContentType,
            languages: activeLanguages,
            mood: activeMood,
            deviceLanguage: Self.normalizedLanguageCode(Locale.current.language.languageCode?.identifier),
            sourceFilter: presetSourceFilter,
            isClickHistory: activePreset.isLastClicked,
            isSmartFeed: activePreset.isSmartFeed,
            clickIDs: clickedItemIDs,
            smartFeedIDs: activeSmartFeedItemIDs,
            consumedIDs: consumedItemIDs,
            taxonomyURLs: cachedTaxonomyFeedURLs,
            includeConsumed: includeConsumed,
            contentFilters: contentFilterState.filters,
            contentFilterKey: contentFilterState.key,
            moodMatchSnapshot: moodMatchCache,
            contentExcludeSnapshot: contentFilterExcludeCache,
            disabledSourceURLs: eligibility.disabled,
            explicitlyDisabledSourceURLs: eligibility.explicitlyDisabled
        )
    }

    /// Content-filter snapshot for a filter pass, with the cache invalidation
    /// that makes it safe to reuse. Both filter paths call this, so the
    /// per-item exclusion cache can never serve a verdict computed under a
    /// different filter set. The key is returned so the off-main caller can
    /// re-check it after the pass.
    private func activeContentFiltersForFilterPass()
        -> (filters: [(id: UUID, keywords: [String])], key: String) {
        let filters = ContentFilterStore.shared.isEnabled
            ? ContentFilterStore.shared.activeFilters : []
        if filters.isEmpty {
            contentFilterExcludeCache.removeAll()
        }
        let filterKey = filters.map { "\($0.id):\($0.keywords.joined(separator: ","))" }.joined(separator: "|")
        if filterKey != contentFilterCacheKey {
            contentFilterExcludeCache.removeAll()
            contentFilterCacheKey = filterKey
        }
        return (filters, filterKey)
    }

    /// Drops mood-match cache entries when the mood changes — a cached verdict
    /// is only valid for the mood it was computed under.
    private func invalidateMoodMatchCacheIfNeeded(_ mood: FeedLoader.MoodFilter) {
        let moodKey = mood.rawValue
        if moodKey != moodMatchCacheKey {
            moodMatchCache.removeAll()
            moodMatchCacheKey = moodKey
        }
    }

    /// Run applyFilters off the main actor. Used in hot paths (startup,
    /// filter changes, append/refresh) to keep the main thread responsive.
    func applyFiltersAsync(_ items: [FeedItem], includeConsumed: Bool = true) async -> [FeedItem] {
        guard !items.isEmpty else { return [] }
        // Same invalidation rules as the synchronous pass, applied before the
        // snapshot is taken — otherwise stale cache entries merged back below
        // would outlive the filter change that invalidated them.
        invalidateMoodMatchCacheIfNeeded(activeMood)
        // The synchronous `applyFilters` refreshes this cache as its first step; the async pass
        // must do the same, or the two disagree exactly when a taxonomy selection is active:
        // without the URLs, an explicit catalogue query is not recognised as one, the selected
        // source is treated as merely disabled, and its items are dropped from the page.
        refreshCachedTaxonomyFeedURLsIfNeeded()
        let eligibility = await eligibilitySets()
        let input = buildFilterInput(includeConsumed: includeConsumed, eligibility: eligibility)
        let (filtered, moodCache, contentCache) = await Self.applyFiltersOffMain(items, input: input)
        // Merge caches back so subsequent synchronous applyFilters calls benefit —
        // but only while the keys still match the pass that produced them. The
        // user can change filters while the detached pass runs, and the verdicts
        // it computed under the previous set must not survive that change.
        if !moodCache.isEmpty, input.mood.rawValue == moodMatchCacheKey {
            moodMatchCache.merge(moodCache) { _, new in new }
        }
        if !contentCache.isEmpty, input.contentFilterKey == contentFilterCacheKey {
            contentFilterExcludeCache.merge(contentCache) { _, new in new }
        }
        return filtered
    }

    func applyFilters(_ items: [FeedItem], includeConsumed: Bool = true) -> [FeedItem] {
        refreshCachedTaxonomyFeedURLsIfNeeded()
        let region = activeRegion
        let contentType = filterContentType
        let languages = activeLanguages
        let mood = activeMood
        let contentFilters = activeContentFiltersForFilterPass().filters
        let deviceLanguage = Self.normalizedLanguageCode(Locale.current.language.languageCode?.identifier)
        let sourceFilter = presetSourceFilter
        let isClickHistory = activePreset.isLastClicked
        let isSmartFeed = activePreset.isSmartFeed
        let clickIDs = clickedItemIDs
        let smartFeedIDs = activeSmartFeedItemIDs
        let consumedIDs = consumedItemIDs

        // Mood and content-filter caches are keyed on the filter state they
        // were computed under; both helpers are shared with the off-main path.
        invalidateMoodMatchCacheIfNeeded(mood)

        return items.filter { item in
            let normalizedSourceURL = OPMLParser.normalizeURL(item.sourceURL)
            let isEligibleSource = isClickHistory || isSmartFeed
                || (sourceFilter?.contains(normalizedSourceURL) ?? isItemEnabled(item))
            guard isEligibleSource else { return false }
            guard !isClickHistory || clickIDs.contains(item.id) else { return false }
            guard !isSmartFeed || smartFeedIDs.contains(item.id) else { return false }
            guard includeConsumed || isClickHistory || isSmartFeed || !consumedIDs.contains(item.id) else { return false }
            guard region == nil || item.region == region || item.region.hasPrefix(region! + "/") else { return false }
            guard cachedTaxonomyFeedURLs.isEmpty || cachedTaxonomyFeedURLs.contains(normalizedSourceURL) else { return false }
            guard Self.languageFilterMatchesNormalized(itemLanguage: item.language, selectedLanguages: languages, deviceLanguage: deviceLanguage) else { return false }
            guard contentType(item) else { return false }

            // Mood check — cached per item ID (deterministic for a given mood)
            if mood != .all {
                if let cached = moodMatchCache[item.id] { guard cached else { return false } }
                else {
                    let match = mood.matches(item.title)
                    moodMatchCache[item.id] = match
                    guard match else { return false }
                }
            }

            // Content filter check — cached per item ID
            if !contentFilters.isEmpty {
                if let cached = contentFilterExcludeCache[item.id] { guard !cached else { return false } }
                else {
                    let excluded = contentFilterExcludes(item, filters: contentFilters)
                    contentFilterExcludeCache[item.id] = excluded
                    guard !excluded else { return false }
                }
            }

            return true
        }
    }

    /// Matching engine shared by every filter path: returns the id of the first
    /// filter with a keyword present in the item's searchable text, or nil.
    /// `nonisolated` so the off-main pass applies the identical rule — the two
    /// paths must never disagree about which items a filter hides.
    ///
    /// Performance: plain `contains()` on pre-normalized strings. Keywords are
    /// already lowercased + diacritic-folded by ContentFilterStore.activeFilters;
    /// item text is computed once by FeedItem.searchableText.
    nonisolated static func firstMatchingContentFilterID(
        in item: FeedItem,
        filters: [(id: UUID, keywords: [String])]
    ) -> UUID? {
        guard !filters.isEmpty else { return nil }
        let text = item.searchableText
        for filter in filters {
            for keyword in filter.keywords where text.contains(keyword) {
                return filter.id
            }
        }
        return nil
    }

    private func _contentFilterExcludes(_ item: FeedItem, filters: [(id: UUID, keywords: [String])], hitIDs: inout [UUID]) -> Bool {
        guard let id = Self.firstMatchingContentFilterID(in: item, filters: filters) else { return false }
        hitIDs.append(id)
        return true
    }

    /// Pure predicate — no side effects. Used by applyFilters where hits are
    /// recorded once at ingestion time in persistFetchedItems instead of on
    /// every filter pass.
    private func contentFilterExcludes(_ item: FeedItem, filters: [(id: UUID, keywords: [String])]) -> Bool {
        var unused: [UUID] = []
        return _contentFilterExcludes(item, filters: filters, hitIDs: &unused)
    }

    /// Records a hit for each matching filter. Used at item ingestion time
    /// (persistFetchedItems) so each item is counted exactly once.
    private func contentFilterExcludesAndRecord(_ item: FeedItem, filters: [(id: UUID, keywords: [String])]) -> Bool {
        var hitIDs: [UUID] = []
        let excluded = _contentFilterExcludes(item, filters: filters, hitIDs: &hitIDs)
        for id in hitIDs {
            ContentFilterStore.shared.recordHit(id)
        }
        return excluded
    }

    private var filterContentType: (FeedItem) -> Bool {
        switch activeContentType {
        case .all: return { _ in true }
        case .text: return { !$0.isYouTube && !$0.isPodcast && !$0.isForum }
        case .video: return { $0.isYouTube }
        case .audio: return { $0.isPodcast }
        case .forum: return { $0.isForum }
        }
    }
    var isSearching = false
    private(set) var isSearchLoading = false
    private(set) var isSearchScanning = false
    private(set) var searchScannedSourceCount = 0
    private(set) var searchTotalSourceCount = 0
    private(set) var searchDiscoveredItemCount = 0
    private(set) var searchFailedSourceCount = 0
    private(set) var searchScanCompleted = false
    private(set) var unifiedSearchResults = UnifiedSearchResults.empty
    private var searchGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var activeSearchExpression = SearchExpression.empty
    private var activeSearchIncludesSources = true
    private var activeSearchIncludesContents = false
    /// Whether the active search's *online* content demand was requested. Separate from
    /// `activeSearchIncludesContents` so the local FTS query and the network sweep are two
    /// decisions: the sweep is explicit and never an implicit effect of the local search.
    private(set) var activeSearchDemandsOnlineContent = false
    private var searchNeedsRestartAfterFilterEditing = false

    // MARK: - Read & Seen state
    private(set) var readItemIDs: Set<String> = []
    private(set) var consumedItemIDs: Set<String> = []
    private(set) var clickedItemIDs: Set<String> = []
    private(set) var clickedSourceURLs: Set<String> = []
    /// Items that the user has bookmarked — loaded at startup and kept in sync
    /// with every toggle so `setVisibleItems` can stamp `isBookmarked` correctly.
    private(set) var bookmarkedItemIDs: Set<String> = []
    /// Items that have appeared in the main feed (surfaced). Tracked
    /// continuously so What's New can exclude already-seen content.
    private(set) var surfacedItemIDs: Set<String> = []
    private(set) var loadedIDsCount: Int = 0
    private var loadedIDs: Set<String> = []  // Bloom filter for dedup
    private static let lastWhatsNewSeenAtKey = "last_whats_new_seen_at"
    private static let hasPreviouslyLoadedContentKey = "has_previously_loaded_feed_content"

    /// Computed forwarding for What's New items from the manager.
    var whatsNewItems: [FeedItem] { whatsNewManager.whatsNewItems }

    private var hasStarted = false             // guards one-time startup work
    private let usesPersistentStorage: Bool
    nonisolated private static let coldStartMinimumSourceCount = 100
    nonisolated private static let coldStartCatalogSourceCount = 240
    nonisolated private static let coldStartFetchChunkSize = 240
    nonisolated static let sourceCoverageTarget = 100
    nonisolated static let immediateFilteredSourceTarget = 20
    private var coldStartPendingItems: [FeedItem] = []
    @ObservationIgnored private var startupSuccessfulSourceURLs: Set<String> = []
    /// Cancel every piece of background work this store owns and stop its network
    /// monitor. Distinct from what a flush does — a flush cancels the pipeline to
    /// rebuild the same feed and keeps monitoring — this is for ending the store's
    /// life. Tests that start a store use it so no fetch or preparation task runs
    /// into the next test, which is the leakage finding 10 attributes the suite's
    /// remaining timing failures to.
    func cancelAllWork() {
        pipelineTask?.cancel()
        cardPreparationTask?.cancel()
        progressiveFetchTask?.cancel()
        trimDebounceTask?.cancel()
        coverageMiningTask?.cancel()
        firstLaunchBootstrapTask?.cancel()
        networkMonitor.stop()
    }

    private var firstLaunchBootstrapTask: Task<Void, Never>?
    private var curatedOnboardingLastFetchAt: [String: Date] = [:]
    private var progressiveFetchTask: Task<Void, Never>?
    private var coverageMiningTask: Task<Void, Never>?
    private var isCoverageMiningActive = false
    private var backgroundRefreshTask: Task<Void, Never>?
    private var smartFeedMaintenanceTask: Task<Void, Never>?
    private var smartFeedRefreshesInFlight: Set<Int64> = []
    private var activityState: FeedActivityState = .active
    private var isRegularBackgroundFetchActive = false
    private var regionToggleTask: Task<Void, Never>?
    private var sourceToggleTask: Task<Void, Never>?
    private var filterDebounceTask: Task<Void, Never>?
    private var filterPersistenceTask: Task<Void, Never>?
    private var isEditingFilters = false
    private var pendingFilterReloadGeneration: Int64?
    private var sourceEnablementRefreshTask: Task<Void, Never>?
    private var urgentFetchTask: Task<Void, Never>?
    private var taxonomyCoverageCursor = 0
    private var backgroundCoverageCursor = 0

    // MARK: - Throttled reservoir append
    // Accumulates items from progressive/background fetches and flushes them
    // to the reservoir in a single interleave pass every few seconds, reducing
    // 10+ interleave passes to 2-3 during startup.
    private var pendingReservoirItems: [FeedItem] = []
    private var reservoirFlushTask: Task<Void, Never>?
    private static let reservoirFlushInterval: Duration = .seconds(3)

    /// Queue items for eventual reservoir append. Flushes after a debounce
    /// interval or when the pending batch reaches a size threshold.
    func throttledReservoirAppend(_ items: [FeedItem]) {
        pendingReservoirItems.append(contentsOf: items)
        reservoirFlushTask?.cancel()
        // Flush immediately if large batch (user might be scrolling).
        // Schedule via reservoirFlushTask so that flushPendingReservoir()
        // can await it when a pipeline op needs ordering guarantees.
        if pendingReservoirItems.count >= 100 {
            reservoirFlushTask = Task { [weak self] in
                guard let self else { return }
                self.reservoirFlushTask = nil
                await self.flushPendingReservoir()
            }
            return
        }
        reservoirFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reservoirFlushInterval)
            guard !Task.isCancelled, let self else { return }
            self.reservoirFlushTask = nil
            await self.flushPendingReservoir()
        }
    }

    /// Flush pending reservoir items — interleave + append — and return when
    /// the items are fully committed to the reservoir. Await this before any
    /// pipeline operation (.refresh, .append) that must see the new items.
    ///
    /// Drains any scheduled `reservoirFlushTask` before proceeding so that
    /// items batched by the throttled path are always committed before a
    /// refresh sees them. The task body clears its own reference before
    /// calling us, preventing a circular await.
    private func flushPendingReservoir() async {
        // Cancel and drain any scheduled flush task that hasn't started
        // executing yet so callers that need ordering guarantees do not wait
        // for the debounce interval before committing pending items.
        // (Tasks that already started clear reservoirFlushTask before calling us.)
        if let task = reservoirFlushTask {
            reservoirFlushTask = nil
            task.cancel()
            await task.value
        }

        // Keep background collection off the main feed while a filter sheet is
        // open. The pending items stay in memory and are published as soon as
        // editing ends, so a local toggle never competes with an interleave.
        guard !isEditingFilters, !pendingReservoirItems.isEmpty else { return }
        let batch = pendingReservoirItems

        // Compute interleave off the main actor — this is the expensive part
        // (O(n × sources) with multiple spread passes). Only the final
        // assignment to reservoir arrays needs MainActor.
        let readIDs = reservoir.readItemIDs
        let surfacedTs = reservoir.surfacedTimestamps
        let regionMap = reservoir.sourceRegionMap
        let visibleIDs = Set(reservoir.visibleItems.map(\.id))
        let trulyNew = batch.filter { !visibleIDs.contains($0.id) }
        guard !trulyNew.isEmpty else {
            pendingReservoirItems = []
            return
        }

        let interleaved = await Task.detached(priority: .userInitiated) {
            Reservoir.interleaveOffMain(
                trulyNew, readItemIDs: readIDs,
                surfacedTimestamps: surfacedTs, sourceRegionMap: regionMap
            )
        }.value

        // Drain the batch only after the interleave completes — otherwise a
        // concurrent caller during the suspension would see an empty queue
        // and proceed without waiting for the in-flight items.
        let batchIDs = Set(batch.map(\.id))
        pendingReservoirItems.removeAll { batchIDs.contains($0.id) }

        self.reservoir.appendPreInterleaved(interleaved)
        if !self.isSearching && self.visibleItems.isEmpty && !self.reservoir.reservoir.isEmpty {
            self.reservoir.moveToVisible(count: Reservoir.pageSize)
            // The published order is the sequencer's, not the Reservoir's (review P0.5): the Reservoir's interleave is an
            // input, and every path that reaches the reader goes through this single policy.
            self.setVisibleItems(EditorialSequencer.sequence(self.applyFilters(self.reservoir.visibleItems)))
        }
        self.reservoirCount = self.reservoir.reservoirCount
    }

    #if DEBUG
    func flushPendingReservoirForTesting() async {
        await flushPendingReservoir()
    }
    #endif

    // MARK: - Init
    init(inMemory: Bool = false, fetcher: RSSFetcher? = nil) throws {
        let endInitMetric = FeedMetrics.beginInterval("FeedStore.init")
        defer { endInitMetric() }
        self.fetcher = fetcher ?? RSSFetcher()
        self.usesPersistentStorage = !inMemory
        self.hasPreviouslyLoadedContent = !inMemory
            && UserDefaults.standard.bool(forKey: Self.hasPreviouslyLoadedContentKey)
        if inMemory {
            self.db = try DatabaseQueue(configuration: Self.dbConfig)
        } else {
            self.db = try DatabaseQueue(path: Self.dbPath, configuration: Self.dbConfig)
        }
        try Self.migrate(db)
        // Image resolution retry queue — starts polling after migration
        // creates the image_retry_queue table.
        self.imageResolutionQueue = ImageResolutionQueue(db: db)
        let assetStore = MediaAssetStore(db: db)
        let policy = RunwayPolicy.forDevice()
        self.mediaAssetStore = assetStore
        self.runwayPolicy = policy
        let coordinator = CardPreparationCoordinator(
            mediaStore: assetStore, policy: policy
        )
        self.preparationCoordinator = coordinator
        self.runwayController = FeedRunwayController(
            policy: policy, coordinator: coordinator
        )
        // user.sqlite — owns bookmark identity, survives catalog rebuilds
        self.userRepo = try UserStateStore(inMemory: inMemory)
        self.bookmarkStore = BookmarkStore(userDB: userRepo.db, contentDB: db)
        self.smartFeedStore = SmartFeedStore(userDB: userRepo.db, contentDB: db)
        self.curatedFeedStore = CuratedFeedStore(db: userRepo.db)
        self.sourceCollectionStore = SourceCollectionStore(db: userRepo.db)
        self.searchEngine = SearchEngine(
            db: db,
            userDB: userRepo.db,
            catalogURL: CatalogRuntime.activeCatalogURL()
        )
        self.whatsNewManager = WhatsNewManager(db: db)
        // Migrate legacy bookmark data from feedmine.sqlite → user.sqlite
        // if this is the first launch after the split.
        if !inMemory {
            Task { [weak self] in
                guard let self else { return }
                do {
                    if try self.userRepo.needsLegacyMigration(legacyDB: self.db) {
                        try await self.userRepo.migrateFromLegacy(legacyDB: self.db)
                    }
                    try await self.bookmarkStore.synchronizeRetentionPins()
                } catch {
                    Log.db.error("Bookmark migration to user.sqlite failed: \(error)")
                }
            }
        }
        // Create default "Favorites" list if not exists
        try? db.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_list WHERE is_default = 1") ?? 0
            if count == 0 {
                try db.execute(sql: """
                    INSERT INTO bookmark_list (name, sort_order, created_at, is_default)
                    VALUES ('Favorites', 0, \(Int(Date().timeIntervalSince1970)), 1)
                """)
            }
        }
        // Source health/validators are loaded in start() (deferred off the
        // init path — the synchronous GRDB read can stall first paint).

        // Memory pressure: forward to the coordinator to release decoded images
        // beyond the published window and trim the memory cache.
        let prepCoordinator = self.preparationCoordinator
        NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"),
            object: nil, queue: .main
        ) { _ in
            Task { await prepCoordinator?.handleMemoryPressure() }
        }
    }

    /// Last-resort fallback: creates an in-memory store. Uses try! because if
    /// even an in-memory SQLite database cannot be created, the device is in a
    /// state where no app using SQLite can run (out of memory, broken OS
    /// libraries). This is the one acceptable crash point — the app literally
    /// cannot function without a database.
    static func empty() -> FeedStore {
        try! FeedStore(inMemory: true)
    }

    // MARK: - Source Health Persistence

    private func loadSourceHealth() async {
        // GRDB's async read runs off the main actor — the synchronous
        // variant used to run in init and stall first paint by 100-500ms.
        do {
            let records = try await db.read { db in try SourceHealthRecord.loadAll(db) }
            for r in records {
                scheduler.loadHealth(
                    url: r.url,
                    lastFetchAt: Date(timeIntervalSince1970: TimeInterval(r.lastFetchAt)),
                    consecutiveFailures: r.consecutiveFailures
                )
                // Load HTTP validators from expanded health record
                let v = HTTPValidators(
                    etag: r.etag,
                    lastModified: r.lastModified,
                    cacheControl: r.cacheControlMaxAge.map { _ in
                        HTTPValidators.ParsedCacheControl(
                            maxAge: r.cacheControlMaxAge,
                            noCache: r.cacheControlNoCache,
                            noStore: r.cacheControlNoStore,
                            mustRevalidate: r.cacheControlMustRevalidate
                        )
                    },
                    expires: r.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    canonicalURL: r.canonicalURL,
                    lastFetchAt: r.lastFetchAt > 0 ? Date(timeIntervalSince1970: TimeInterval(r.lastFetchAt)) : nil,
                    lastOutcome: r.lastOutcome.flatMap(HTTPValidators.FetchOutcomeKind.init(rawValue:)),
                    retryAfter: r.retryAfter.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    ttl: r.ttl,
                    skipHours: r.skipHours.flatMap { try? Self.decodeJSON($0) },
                    skipDays: r.skipDays.flatMap { try? Self.decodeJSON($0) },
                    lastBuildDate: r.lastBuildDate.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    capabilities: r.capabilities.flatMap { try? Self.decodeJSON($0) },
                    publicationInterval: r.publicationInterval,
                    publicationIntervalConfidence: r.publicationIntervalConfidence
                )
                scheduler.loadValidators(url: r.url, v)
                let estimator = CadenceEstimator(
                    publicationInterval: r.publicationInterval ?? 3600,
                    confidence: r.publicationIntervalConfidence ?? 0,
                    lastPublication: r.lastFetchAt > 0 ? Date(timeIntervalSince1970: TimeInterval(r.lastFetchAt)) : .distantPast
                )
                scheduler.loadEstimator(url: r.url, estimator)
            }
        } catch {
            Log.db.error("loadSourceHealth failed: \(error.localizedDescription)")
        }
    }

    private func saveSourceHealth(for sourceURL: String) {
        // Single-source write — used for one-off toggles. Bulk paths use
        // saveSourceHealthBatch for efficiency.
        saveSourceHealthBatch([(sourceURL, nil)])
    }

    /// Batch-save source health for multiple URLs in a single transaction.
    /// Dramatically faster than N individual writes for 800+ sources.
    private func saveSourceHealthBatch(_ entries: [(url: String, itemCount: Int?)]) {
        guard !entries.isEmpty else { return }
        do {
            try db.write { db in
                for (sourceURL, itemCount) in entries {
                    let health = scheduler.healthSnapshot(for: sourceURL, itemCount: itemCount)
                    let v = health.validators
                    let e = health.estimator
                    try db.execute(sql: """
                        INSERT INTO source_health (
                            url, last_fetch_at, consecutive_failures, last_status, last_item_count,
                            etag, last_modified, cache_control_max_age, cache_control_no_cache,
                            cache_control_no_store, cache_control_must_revalidate, expires,
                            canonical_url, last_outcome, retry_after, ttl, skip_hours, skip_days,
                            capabilities, last_build_date, publication_interval, publication_interval_confidence
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(url) DO UPDATE SET
                            last_fetch_at = excluded.last_fetch_at,
                            consecutive_failures = excluded.consecutive_failures,
                            last_status = excluded.last_status,
                            last_item_count = excluded.last_item_count,
                            etag = excluded.etag,
                            last_modified = excluded.last_modified,
                            cache_control_max_age = excluded.cache_control_max_age,
                            cache_control_no_cache = excluded.cache_control_no_cache,
                            cache_control_no_store = excluded.cache_control_no_store,
                            cache_control_must_revalidate = excluded.cache_control_must_revalidate,
                            expires = excluded.expires,
                            canonical_url = excluded.canonical_url,
                            last_outcome = excluded.last_outcome,
                            retry_after = excluded.retry_after,
                            ttl = excluded.ttl,
                            skip_hours = excluded.skip_hours,
                            skip_days = excluded.skip_days,
                            capabilities = excluded.capabilities,
                            last_build_date = excluded.last_build_date,
                            publication_interval = excluded.publication_interval,
                            publication_interval_confidence = excluded.publication_interval_confidence
                        """, arguments: [
                            sourceURL,
                            Int(health.lastFetchAt.timeIntervalSince1970),
                            health.consecutiveFailures,
                            health.lastStatus,
                            health.lastItemCount,
                            v.etag,
                            v.lastModified,
                            v.cacheControl?.maxAge,
                            v.cacheControl?.noCache ?? false,
                            v.cacheControl?.noStore ?? false,
                            v.cacheControl?.mustRevalidate ?? false,
                            v.expires.map { Int($0.timeIntervalSince1970) },
                            v.canonicalURL,
                            v.lastOutcome?.rawValue,
                            v.retryAfter.map { Int($0.timeIntervalSince1970) },
                            v.ttl,
                            v.skipHours.flatMap { try? Self.encodeJSON($0) },
                            v.skipDays.flatMap { try? Self.encodeJSON($0) },
                            v.capabilities.flatMap { try? Self.encodeJSON($0) },
                            v.lastBuildDate.map { Int($0.timeIntervalSince1970) },
                            e.publicationInterval,
                            e.confidence
                        ])
                }
            }
        } catch {
            Log.db.error("saveSourceHealthBatch error: \(error.localizedDescription)")
        }
    }

    nonisolated static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    nonisolated static func decodeJSON<T: Decodable>(_ text: String) throws -> T {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static var dbPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("feedmine.sqlite").path
    }

    private static var dbConfig: Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    /// Epoch-seconds cutoff for the 30-day retention window. All feed_item date
    /// columns are stored as epoch-second integers, so every comparison uses
    /// integers too — mixing GRDB's default TEXT date encoding with integer
    /// cutoffs produced always-true/always-false comparisons (dead expurgo,
    /// broken What's New).
    nonisolated private static var thirtyDayCutoffEpoch: Int {
        Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)
    }

    /// Read a small, varied starter set from the active local catalog. This is
    /// intentionally not a replacement for SourceRegistry:
    /// it only overlaps first-install network latency with the authoritative
    /// OPML/taxonomy reconstruction.
    nonisolated static func activeStarterSources(
        language: String,
        limit: Int = coldStartCatalogSourceCount
    ) async -> [FeedSource] {
        guard limit > 0,
              let catalogURL = CatalogRuntime.activeCatalogURL() else { return [] }

        let normalizedLanguage = normalizedLanguageCode(language) ?? "en"
        if let cached = await CuratedStarterSourceCache.shared.sources(
            language: normalizedLanguage,
            minimumCount: limit
        ) {
            return cached
        }
        let selected = await Task.detached(priority: .userInitiated) {
            do {
                var configuration = Configuration()
                configuration.readonly = true
                let catalog = try DatabaseQueue(path: catalogURL.path, configuration: configuration)
                let candidatesPerTopic = 80
                let candidateLimit = max(
                    limit * 6,
                    candidatesPerTopic * CuratedTopic.allCases.count
                )
                let sourceCandidateLimit = max(5_000, candidateLimit * 4)
                let rows = try catalog.read { db in
                    try Row.fetchAll(db, sql: """
                        WITH source_candidates AS (
                            SELECT *
                            FROM catalog_source
                            WHERE (
                                    LOWER(REPLACE(language, '_', '-')) = ?
                                    OR LOWER(REPLACE(language, '_', '-')) LIKE ?
                                  )
                              AND request_url LIKE 'https://%'
                              AND default_enabled = 1
                            ORDER BY
                                COALESCE(quality_score, 0) DESC,
                                title COLLATE NOCASE ASC,
                                request_url ASC
                            LIMIT ?
                        ),
                        grouped AS (
                            SELECT
                                s.id AS source_id,
                                s.title AS title,
                                s.request_url AS url,
                                s.media_kind AS media_kind,
                                s.language AS language,
                                s.description AS description,
                                s.tags AS tags,
                                s.nature AS nature,
                                s.activity AS activity,
                                s.quality_score AS quality_score,
                                s.default_enabled AS default_enabled,
                                COALESCE(
                                    MIN(CASE
                                        WHEN n.key NOT LIKE '90_countries/%'
                                        THEN parent.name
                                        ELSE NULL
                                    END),
                                    MIN(CASE
                                        WHEN n.key LIKE '90_countries/%'
                                        THEN parent.name
                                        ELSE NULL
                                    END),
                                    'General Interests'
                                ) AS category,
                                MIN(CASE
                                    WHEN n.key LIKE '90_countries/%' THEN n.key
                                    ELSE NULL
                                END) AS country_key
                            FROM source_candidates s
                            JOIN catalog_placement p ON p.source_id = s.id
                            JOIN catalog_node n ON n.id = p.node_id
                            LEFT JOIN catalog_node parent ON parent.id = n.parent_id
                            WHERE n.kind = 3
                              AND n.key NOT LIKE 'languages/%'
                            GROUP BY
                                s.id, s.title, s.request_url,
                                s.media_kind, s.language
                        ),
                        ranked AS (
                            SELECT
                                *,
                                ROW_NUMBER() OVER (
                                    PARTITION BY category
                                    ORDER BY
                                        COALESCE(quality_score, 0) DESC,
                                        title COLLATE NOCASE ASC,
                                        url ASC
                                ) AS topic_rank
                            FROM grouped
                        )
                        SELECT *
                        FROM ranked
                        WHERE topic_rank <= ?
                        ORDER BY
                            topic_rank ASC,
                            category COLLATE NOCASE ASC,
                            title COLLATE NOCASE ASC
                        LIMIT ?
                        """, arguments: [
                            normalizedLanguage,
                            "\(normalizedLanguage)-%",
                            sourceCandidateLimit,
                            candidatesPerTopic,
                            candidateLimit,
                        ])
                }
                let candidates: [FeedSource] = rows.compactMap { row in
                    guard let title: String = row["title"],
                          let url: String = row["url"],
                          let kindValue: String = row["media_kind"],
                          let kind = MediaKind(rawValue: kindValue) else { return nil }
                    let countryKey: String? = row["country_key"]
                    let countryComponents = countryKey?
                        .split(separator: "/")
                        .map(String.init) ?? []
                    let category: String = row["category"] ?? "General Interests"
                    let region: String = {
                        guard countryComponents.first == "90_countries",
                              countryComponents.count >= 2 else { return "global" }
                        return "countries/\(countryComponents[1])"
                    }()
                    let tags: String? = row["tags"]
                    let rawLanguage: String? = row["language"]
                    return FeedSource(
                        title: title,
                        url: url,
                        category: category,
                        region: region,
                        mediaKind: kind,
                        language: normalizedLanguageCode(rawLanguage),
                        sourceDescription: row["description"],
                        tags: tags?
                            .split(separator: ",")
                            .map {
                                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            } ?? [],
                        nature: row["nature"],
                        activity: row["activity"],
                        qualityScore: row["quality_score"],
                        defaultEnabled: row["default_enabled"] ?? true
                    )
                }
                return CuratedPreferenceEngine.showcaseSources(
                    from: candidates,
                    limit: limit
                )
            } catch {
                Log.feed.error("Active starter catalog failed: \(error.localizedDescription)")
                return []
            }
        }.value
        await CuratedStarterSourceCache.shared.store(
            selected,
            language: normalizedLanguage
        )
        return selected
    }

    /// Compatibility entry point retained for tests and older callers. The
    /// returned data now comes from the active local snapshot, which may be the
    /// bundled bootstrap or a verified managed update.
    nonisolated static func bundledStarterSources(
        language: String,
        limit: Int = coldStartCatalogSourceCount
    ) async -> [FeedSource] {
        await activeStarterSources(language: language, limit: limit)
    }

    nonisolated static func coldStartRunwayIsUseful(
        _ items: [FeedItem],
        targetSourceCount: Int = coldStartMinimumSourceCount
    ) -> Bool {
        let target = max(1, min(coldStartMinimumSourceCount, targetSourceCount))
        return items.count >= target && Set(items.map(\.sourceURL)).count >= target
    }

    /// The cold-start **publish** gate: a complete page with the first page's breadth — not a screenful.
    ///
    /// `coldStartImmediateItemCount` (12) used to be enough to publish, which is the "Loading → partial → better"
    /// sequence the release review forbids: twelve items appeared, the reader started scrolling, and the page grew
    /// underneath them. A page is published only when it is complete: `Reservoir.pageSize` items from as many distinct
    /// providers — the same breadth policy the Reservoir applies when it front-loads unique providers. The 100-source
    /// target stays a *background* fill goal (`coldStartMinimumSourceCount`), exactly as the bootstrap comment says.
    nonisolated static func coldStartPageIsReady(_ items: [FeedItem]) -> Bool {
        // `coldStartRunwayIsUseful` already requires `items.count >= target`, so this is one condition, not two: the
        // page-sized target is what makes it "a full page of distinct providers".
        coldStartRunwayIsUseful(items, targetSourceCount: Reservoir.pageSize)
    }

    // MARK: - Source demand ledger (PR-14)

    /// One refill per endpoint, shared by every producer that draws from this store.
    ///
    /// The twelve acquisition pairs the map in `local://recon-acquisition.md` §3 names all come from
    /// producers calling `fetcher` directly with overlapping endpoint sets. The ledger is the value that
    /// decides — synchronously on the main actor, before any `await` — which endpoints a demand may
    /// refill and which it must join or answer from what is already retained locally.
    private var sourceDemandLedger = SourceDemandLedger()

    /// Observability for PR-14: how many demands this store led, joined and answered from a fresh refill.
    var sourceDemandCounters: SourceDemandLedger.Counters { sourceDemandLedger.counters }
    var sourcesInFlight: Int { sourceDemandLedger.inFlightCount }

    private static func sourceDemandTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Claims `[[urls]]` for one producer. The caller fetches only `grant.led`.
    ///
    /// `urls` are normalized with `OPMLParser.normalizeURL` and the grant's arrays are converted back to
    /// the normalized form, so every producer compares endpoints by the same identity.
    func claimSourceDemand(
        _ urls: [String],
        purpose: SourceDemandLedger.Purpose,
        freshnessWindowMs: Int64? = nil
    ) -> SourceDemandLedger.Grant {
        sourceDemandLedger.demand(
            urls.map { OPMLParser.normalizeURL($0) },
            purpose: purpose,
            atMs: Self.sourceDemandTimestampMs(),
            freshnessWindowMs: freshnessWindowMs
        )
    }

    /// Ends a claim. `outcomes` is the fetch result's per-source outcome map (keys are the raw source urls as the
    /// fetcher reports them); an endpoint whose outcome is `.failed` is not recorded as fresh, so the next demand
    /// retries it. The in-flight marks for `grant.led` are always cleared, including when `outcomes` is empty.
    func finishSourceDemand(
        _ grant: SourceDemandLedger.Grant,
        outcomes: [String: FeedFetchOutcome]
    ) {
        let succeeded = Set(outcomes.compactMap { url, outcome in
            outcome.isFailed ? nil : OPMLParser.normalizeURL(url)
        })
        sourceDemandLedger.finish(
            grant.led,
            atMs: Self.sourceDemandTimestampMs(),
            succeeded: succeeded
        )
    }

    nonisolated private static func activeCatalogSourceCount() -> Int {
        if let count = CatalogRuntime.activeManifest()?.sourceCount {
            return count
        }
        guard let url = Bundle.main.url(
            forResource: "catalog-manifest",
            withExtension: "json",
            subdirectory: "FeedEngine"
        ) ?? Bundle.main.url(
            forResource: "catalog-manifest",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let count = object["source_count"] as? Int else { return 0 }
        return count
    }

    func configureStartupProgress(targetSourceCount: Int) {
        // Reverted: the bar and its percentage read this pair, and the chip beside them counts the
        // *catalogue total* (`FeedScreen` uses `max(startupTotalSourceCount, sourceCount)`), so pointing
        // the bar at the page criterion made it fill at three sources while the chip read "3/77,443".
        // Which denominators these two should use — catalogue total, or "enough for the first screen"
        // with a separate signal for releasability — is a surface decision, recorded in
        // `docs/release/1.0-checklist.md`, not something to improvise here.
        startupTargetSourceCount = max(1, min(Self.coldStartMinimumSourceCount, targetSourceCount))
        startupFetchedSourceCount = min(startupTargetSourceCount, startupSuccessfulSourceURLs.count)
        startupRunwayReady = startupFetchedSourceCount >= startupTargetSourceCount
        startupItemsReady = 0
        startupSeenItemIDs.removeAll()
    }

    func recordStartupFetchProgress(_ result: FeedFetchResult) {
        guard result.status == .success else { return }
        let normalizedURL = OPMLParser.normalizeURL(result.source.url)
        guard startupSuccessfulSourceURLs.insert(normalizedURL).inserted else { return }

        startupFetchedSourceCount = min(startupTargetSourceCount, startupSuccessfulSourceURLs.count)
        startupRecentSourceNames.append(result.source.title)
        startupRunwayReady = startupFetchedSourceCount >= startupTargetSourceCount
    }

    /// Build a useful first-session runway instead of returning as soon as a
    /// handful of prolific feeds produce many items. Distinct sources are the
    /// release criterion; item count is only the secondary buffer criterion.
    ///
    /// - Parameter totalDeadline: Optional wall-clock ceiling across ALL
    ///   chunked attempts. Without it, 8 chunks × 10s timeouts can hold the
    ///   first-install bootstrap for ~80s while the loading screen shows.
    private func fetchColdStartRunway(
        from sources: [FeedSource],
        totalDeadline: Date? = nil
    ) async -> FeedFetchBatch {
        // Don't burn 10+ seconds on chunked timeouts when offline.
        guard !networkMonitor.isKnownOffline else {
            Log.feed.info("fetchColdStartRunway skipped: offline")
            return FeedFetchBatch(
                items: [], fetchedSourceCount: 0, failedSourceCount: 0,
                emptySourceCount: 0, notModifiedCount: 0, throttledCount: 0,
                sourceOutcomes: [:]
            )
        }
        // Sort by preset multiplier so high-quality sources are fetched first
        let multipliers = presetMultipliers
        let sorted = sources.sorted { lhs, rhs in
            (multipliers[lhs.url] ?? 1.0) > (multipliers[rhs.url] ?? 1.0)
        }
        let targetSourceCount = max(
            1,
            min(Self.coldStartMinimumSourceCount, Set(sorted.map(\.url)).count)
        )
        configureStartupProgress(targetSourceCount: targetSourceCount)
        var items: [FeedItem] = []
        var fetchedSourceCount = 0
        var failedSourceCount = 0
        var emptySourceCount = 0
        var statuses: [String: FeedFetchOutcome] = [:]
        var notModifiedCount = 0
        var throttledCount = 0

        for start in stride(from: 0, to: sorted.count, by: Self.coldStartFetchChunkSize) {
            // Honor the overall deadline across chunks — never let the
            // bootstrap run past it even when every chunk times out.
            if let totalDeadline, Date() >= totalDeadline { break }
            guard !Task.isCancelled else { break }
            let end = min(start + Self.coldStartFetchChunkSize, sorted.count)
            let chunk = Array(sorted[start..<end])
            let usefulSourceCount = Set(items.map(\.sourceURL)).count
            let remainingSources = max(1, targetSourceCount - usefulSourceCount)
            // Count what the caller actually needs. With a content type active, an early return on
            // "a screenful" can hand back a screenful of the *wrong* kind, and the filtered page is
            // then empty — measured: the podcast combo went from 4–5 cards to 0 after the speed-up.
            // Same distinction as `localOfActiveType` uses when deciding whether a fetch can defer.
            let relevantItems = self.activeContentType == .all
                ? items.count
                : items.filter { self.activeContentType.matches($0) }.count
            let remainingItems = max(1, Self.coldStartImmediateItemCount - relevantItems)
            // P1: the bootstrap leads its chunk; endpoints another producer is already refilling are joined,
            // and a chunk with nothing left to lead is answered by that producer instead of fetched again.
            let grant = claimSourceDemand(chunk.map(\.url), purpose: .bootstrap)
            let grantedURLs = Set(grant.led)
            let grantedChunk = chunk.filter {
                grantedURLs.contains(OPMLParser.normalizeURL($0.url))
            }
            guard !grantedChunk.isEmpty else { break }
            let result = await fetcher.fetchStarter(
                grantedChunk,
                maxConcurrent: min(48, chunk.count),
                // Stop a chunk at a *screenful* from a few publishers, not at the runway's
                // diversity target: with `coldStartFetchChunkSize = 240` equal to the measured source
                // count, the outer `totalDeadline` never fires (one chunk), so these two numbers plus
                // the soft internal deadline are the only brake — and ~100 sources/items each is why a
                // chunk ran 29.9 s. Speed comes from the item count; first-page diversity from the
                // source floor, so it stays at three rather than one.
                minimumSuccessfulSources: self.activeContentType == .all
                    ? min(remainingSources, Self.coldStartMinimumPageSources, chunk.count)
                    : min(remainingSources, max(Self.coldStartMinimumPageSources, 6), chunk.count),
                minimumItemCount: min(remainingItems, Self.coldStartImmediateItemCount),
                deadline: .seconds(10),
                onProgress: { [weak self] result in
                    self?.recordStartupFetchProgress(result)
                }
            )
            finishSourceDemand(grant, outcomes: result.sourceOutcomes)
            items.append(contentsOf: result.items)
            fetchedSourceCount += result.fetchedSourceCount
            failedSourceCount += result.failedSourceCount
            emptySourceCount += result.emptySourceCount
            notModifiedCount += result.notModifiedCount
            throttledCount += result.throttledCount
            statuses.merge(result.sourceOutcomes) { _, newest in newest }

            if Self.coldStartRunwayIsUseful(items, targetSourceCount: targetSourceCount) {
                break
            }
        }

        return FeedFetchBatch(
            items: items,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            notModifiedCount: notModifiedCount,
            throttledCount: throttledCount,
            sourceOutcomes: statuses
        )
    }

    private func startFirstLaunchBootstrapIfNeeded() -> Task<Void, Never>? {
        guard !Settings.hasInitializedLanguageDefault else { return nil }
        let storedItemCount = (try? db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item") ?? 0
        }) ?? 0
        guard storedItemCount == 0 else { return nil }

        let language = Self.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        ) ?? "en"
        activeLanguages = [language]
        Settings.filterLanguages = [language]
        Settings.hasInitializedLanguageDefault = true
        let generation = filterGeneration
        let startedAt = Date()

        return Task { [weak self] in
            guard let self else { return }
            let sourcesStartedAt = Date()
            let sources = await Self.activeStarterSources(language: language)
            let sourcesMs = Int(Date().timeIntervalSince(sourcesStartedAt) * 1000)
            guard !Task.isCancelled, !sources.isEmpty else { return }

            // Keep bootstrap items eligible until the full registry replaces
            // this temporary source set a few moments later.
            if self.registry.sources.isEmpty {
                self.registry.sources = sources
                self.reservoir.sourceRegionMap = self.registry.regionMap
            }

            // Bound the whole bootstrap: without a total deadline the
            // chunked 10s timeouts can block first paint for ~80s.
            let fetchStartedAt = Date()
            let result = await self.fetchColdStartRunway(
                from: sources,
                totalDeadline: Date().addingTimeInterval(15)
            )
            let fetchMs = Int(Date().timeIntervalSince(fetchStartedAt) * 1000)
            Log.feed.info("firstLaunchBootstrap stages: sourcesMs=\(sourcesMs) sources=\(sources.count) fetchMs=\(fetchMs) items=\(result.items.count)")
            guard !Task.isCancelled, generation == self.filterGeneration else { return }

            let targetSourceCount = min(Self.coldStartMinimumSourceCount, sources.count)
            let usefulSourceCount = Set(result.items.map(\.sourceURL)).count
            // Enough for the first screen is enough to publish. Withholding the whole batch until the
            // full source target is met is what starves first paint: measured on a clean install, the
            // bootstrap held 552 items from 15 sources back (`withheld: sources=15/100 items=552/100`)
            // and the page showed 13 items until the ~100-source threshold was reached — the "0/100"
            // the progress surface displays, and the reason a filter tap seconds after launch saw an
            // empty feed.
            guard Self.coldStartRunwayIsUseful(
                result.items,
                targetSourceCount: targetSourceCount
            ) || Self.coldStartPageIsReady(result.items) else {
                self.coldStartPendingItems = result.items
                Log.feed.info(
                    "firstLaunchBootstrap withheld: sources=\(usefulSourceCount)/\(targetSourceCount) items=\(result.items.count)/\(targetSourceCount)"
                )
                return
            }

            for (url, status) in result.sourceOutcomes {
                self.scheduler.recordFetch(sourceURL: url, outcome: status)
            }
            let actualNew = await self.persistInSlices(result.items)
            guard !Task.isCancelled, !actualNew.isEmpty else { return }

            // Prefetch BEFORE enqueuing — downloads start while reservoir
            // processes interleaving/filtering, so images are cached by render time.
            self.prefetchImagesIfEnabled(for: actualNew)
            self.collectWhatsNewCandidates(actualNew)
            let appendStartedAt = Date()
            self.throttledReservoirAppend(actualNew)
            await self.flushPendingReservoir()
            let publishHopMs = Int(Date().timeIntervalSince(appendStartedAt) * 1000)
            Log.feed.info("firstLaunchBootstrap append→flush: items=\(actualNew.count) appendHopMs=\(publishHopMs) reservoir=\(self.reservoir.reservoirCount) visible=\(self.visibleItems.count)")
            // A bootstrap that finishes after the user changed the composition must not force
            // `.ready` over the newer generation's `.preparing`: this block runs outside the flush's
            // guards, so it needs its own. Same terms the flush paths use.
            let bootstrapGeneration = self.filterGeneration
            if !self.visibleItems.isEmpty, bootstrapGeneration == self.filterGeneration {
                display.setIsPreparingInitialRunway(false)
                display.setLoadingState(.idle)
                display.setFeedDisplayPhase(.ready(contextID: self.presentationEpoch))
            } else if bootstrapGeneration != self.filterGeneration {
                Log.feed.info("firstLaunchBootstrap publication skipped: generation moved (\(bootstrapGeneration) → \(self.filterGeneration))")
            }
            Log.feed.info(
                "firstLaunchBootstrap published: sources=\(result.fetchedSourceCount) items=\(actualNew.count) visible=\(self.visibleItems.count) elapsed=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))s generation=\(bootstrapGeneration)"
            )
        }
    }

    // MARK: - Start (cold + warm)

    /// One-time startup: parse OPML, start the network monitor, hydrate from
    /// SQLite, snapshot the What's New baseline, and kick off the first fetch.
    /// Idempotent — calling it again (e.g. the view reappearing) is a no-op;
    /// use `refreshNow()` to pull fresh content after startup.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        display.setLoadingState(.initial)
        display.setIsPreparingInitialRunway(true)
        startupFetchedSourceCount = 0
        startupTargetSourceCount = Self.coldStartMinimumSourceCount
        startupTotalSourceCount = Self.activeCatalogSourceCount()
        startupRecentSourceNames = []
        startupRunwayReady = false
        startupSuccessfulSourceURLs.removeAll(keepingCapacity: true)
        FeedMetrics.event("Backend.start")
        networkMonitor.start()

        // Start the image retry queue — processes items whose images
        // failed during initial pipeline resolution.
        await imageResolutionQueue.configure(delegate: self)

        // Source health + HTTP validators were deferred out of init; load
        // them before any fetch scheduling begins. The GRDB read runs off
        // the main actor.
        await loadSourceHealth()

        // A persisted collection is already a complete source allowlist. Build
        // it before touching the bundled catalogue so a retained personal feed
        // can paint from SQLite while OPML/taxonomy startup continues.
        activePreset = Settings.activePreset
        if case .collection(let collectionID, _) = activePreset {
            await rebuildPresetMultipliers(for: activePreset)

            // Taxonomy needs the catalogue before it can be restored safely.
            // Every other persisted overlay is independent, so restore those
            // now and apply them to the cache-only first paint as usual.
            if Settings.hasInitializedLanguageDefault,
               Settings.filterTaxonomyNodes.isEmpty,
               case .collection(let currentID, _) = activePreset,
               currentID == collectionID {
                restoreFilters()
                do {
                    try await hydrateCollectionPresetFromCache(collectionID: collectionID)
                    if !visibleItems.isEmpty {
                        display.setIsPreparingInitialRunway(false)
                        display.setLoadingState(.idle)
                        display.setFeedDisplayPhase(.ready(contextID: presentationEpoch))
                    }
                } catch {
                    Log.feed.error("early collection preset cache hydration failed: \(error)")
                }
            }
        } else if activePreset.collectionID == nil,
                  !activePreset.isSmartFeed,
                  !activePreset.isLastClicked,
                  !activePreset.isCuratedFeed {
            // The same rule, for the common feed, and it is the case that
            // actually needs it: a warm install already holds a valid page in
            // SQLite plus a ~14 KB `visible-page-cache.json`, yet that page was
            // only published after the OPML parse (118 bundled files, ~26 MB
            // parse cache), the taxonomy load or build (~8.8 MB cache), the
            // filter restore, the read state and the bookmarks. Measured on a
            // warm simulator container: first content at ~23 s, against the
            // release target of one second for a *local* page.
            //
            // Restoring the persisted filters first is exactly what makes the
            // cached page's composition match the one now in effect — the
            // filters and the cache are both written from `Settings`, so they
            // agree by construction. Taxonomy-node filters are the exception:
            // they can only be validated once the taxonomy exists, so that case
            // keeps the old order and simply waits. Scoring multipliers are not
            // rebuilt here: the cached page needs filters, not ranking, and the
            // existing call later in `start()` stays the only writer.
            if Settings.filterTaxonomyNodes.isEmpty {
                restoreFilters()
                await loadReadState()
                reservoir.readItemIDs = consumedItemIDs
                bookmarkedItemIDs = await bookmarkStore.allBookmarkedItemIDsAsync()
                // Publish before the catalogue finishes. The rest of `start()` no longer finds an empty feed, so the
                // restored items are kept and only re-stamped once the full registry, taxonomy and read state are in —
                // the page never goes back to the waiting screen.
                await restorePreparedPageIfAny(generation: filterGeneration, reason: "launch")
            }
        }

        // On the first installation the full OPML registry and taxonomy still
        // need to be reconstructed. Start a small, language-matched network
        // race from the bundled compiled catalog while that CPU work runs so
        // first content is not serialized behind thousands of OPML files.
        if activePreset.collectionID == nil && !activePreset.isSmartFeed {
            firstLaunchBootstrapTask = startFirstLaunchBootstrapIfNeeded()
        }

        let endOPMLMetric = FeedMetrics.beginInterval("OPML.load")
        await registry.loadFromOPML()
        startupTotalSourceCount = registry.sourceCount
        // Dynamic target: the progress bar denominator reflects the actual
        // number of enabled sources, not a hardcoded 100. Capped at 100
        // so the loading screen never over-promises. When fewer sources
        // are enabled, the bar fills faster and shows accurate progress.
        startupTargetSourceCount = max(1, min(Self.coldStartMinimumSourceCount, registry.enabledSources.count))
        endOPMLMetric()
        FeedMetrics.event("OPML.sourceCount", "count=\(self.registry.sources.count)")
        FeedMetrics.memory("afterOPML")
        reservoir.sourceRegionMap = registry.regionMap

        // Build taxonomy tree from loaded sources — try cache first, build if needed
        let endTaxonomyMetric = FeedMetrics.beginInterval("Taxonomy.loadOrBuild")
        let taxonomyCacheHit = await TaxonomyStore.shared.loadFromCache(
            sources: registry.sources,
            sharedCountrySourceURLs: registry.sharedCountrySourceURLs
        )
        if !taxonomyCacheHit {
            await TaxonomyStore.shared.build(
                from: registry.sources,
                sharedCountrySourceURLs: registry.sharedCountrySourceURLs
            )
        }
        endTaxonomyMetric()
        if taxonomyCacheHit {
            FeedMetrics.event("Taxonomy.cacheHit")
        } else {
            FeedMetrics.event("Taxonomy.cacheMiss")
        }
        FeedMetrics.event(
            "Taxonomy.objectCounts",
            "nodes=\(TaxonomyStore.shared.flatIndex.count) sources=\(self.registry.sources.count)"
        )
        FeedMetrics.memory("afterTaxonomy")

        // Invalidate taxonomy filter cache after rebuild
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyShape = -1
        cachedTaxonomyFeedURLs = []

        // Restore persisted filters FIRST so the first render shows
        // correctly filtered content, not a flash of unfiltered items.
        restoreFilters()

        // Restore the active preset and rebuild scoring multipliers.
        // Must happen after registry is populated but before first fetch.
        activePreset = Settings.activePreset
        if activePreset.isCollection || activePreset.isCuratedFeed {
            // Collection presets must populate their allowlist; Curated Feeds
            // must restore their language lens and learned multipliers before
            // the first SQLite paint.
            await rebuildPresetMultipliers()
        } else {
            Task { await rebuildPresetMultipliers() }
        }

        // Set language default on first launch — only applies when no
        // persisted language filter was restored above.
        if !Settings.hasInitializedLanguageDefault {
            let deviceLang = Locale.current.language.languageCode?.identifier
            if let lang = deviceLang {
                let availableLangs = Self.normalizedLanguageSet(registry.sources.compactMap(\.language))
                if availableLangs.contains(lang) {
                    activeLanguages = [lang]
                    persistFilters()
                }
            }
            Settings.hasInitializedLanguageDefault = true
        }

        let endReadStateMetric = FeedMetrics.beginInterval("ReadState.load")
        await loadReadState()
        endReadStateMetric()
        reservoir.readItemIDs = consumedItemIDs
        // Async variant — the synchronous GRDB read used to block the
        // main actor during startup.
        bookmarkedItemIDs = await bookmarkStore.allBookmarkedItemIDsAsync()
        startSmartFeedMaintenance(initialDelay: 30)

        // Warm start: collection presets can address sources that are absent
        // from the bundled registry, so hydrate their exact member URLs instead
        // of sampling the global SQLite candidate window first. Both paths feed
        // the same reservoir and apply the same user filters.
        //
        // Fast-restore: if a cached first page exists from a previous launch,
        // publish it immediately via the legacy path so the UI paints before
        // SQLite or the card-preparation pipeline complete. The async pipeline
        // replaces the cached items with fresh cards later. Using the legacy
        // display.setVisibleItems directly (not the prepared-pipeline-gated
        // setVisibleItems) ensures instant paint — CachedAsyncImage handles
        // images until the coordinator produces terminal cards.
        let endReservoirLoadMetric = FeedMetrics.beginInterval("Reservoir.load")
        // Mode-blind restore guard: the page cache only ever holds MAIN
        // mode content. Smart/last-clicked/collection/curated presets must
        // not paint the main-feed cache and then skip their own loading.
        if visibleItems.isEmpty,
           !activePreset.isSmartFeed,
           !activePreset.isLastClicked,
           activePreset.collectionID == nil,
           !activePreset.isCuratedFeed,
           let cached = await display.restoreCachedPage() {
            let stamped = await applyFiltersAsync(cached.items)
            let cards = await PreparedPageRestoration.cards(for: stamped, projection: cached.cards,
                                                            mediaAssets: mediaAssetStore)
            display.publishCards(cards, items: stamped,
                                 readItemIDs: readItemIDs,
                                 bookmarkItemIDs: bookmarkedItemIDs,
                                 isAppend: false,
                                 mediaCacheKeys: Self.restoredMediaKeys(cached.cards))
            let withMedia = cards.filter { if case .image = $0.media { return true }; return false }.count
            Log.feed.info("restored cached page (late): items=\(stamped.count) withMedia=\(withMedia) generation=\(cached.generation)")
        }
        if let smartFeedID = activePreset.smartFeedID, visibleItems.isEmpty {
            await loadSmartFeedFeed(id: smartFeedID)
        } else if activePreset.isLastClicked, visibleItems.isEmpty {
            await loadLastClickedFeed()
        } else if let collectionID = activePreset.collectionID,
           presetSourceFilter != nil,
           visibleItems.isEmpty {  // skip if early-collection path already painted
            do {
                try await hydrateCollectionPresetFromCache(collectionID: collectionID)
            } catch {
                Log.feed.error("collection preset cache hydration failed: \(error)")
            }
        } else if visibleItems.isEmpty {
            await reloadFromSQLite()
        } else {
            // The parallel first-launch bootstrap may already have published a
            // page. Keep its stable IDs/order and only apply the now-complete
            // registry plus read/bookmark state.
            setVisibleItems(await applyFiltersAsync(visibleItems))
            reservoirCount = reservoir.reservoirCount
        }
        endReservoirLoadMetric()
        if !visibleItems.isEmpty {
            display.setIsPreparingInitialRunway(false)
            FeedMetrics.event("FirstVisibleItems", "count=\(visibleItems.count)")
            FeedMetrics.memory("afterFirstVisible")
            display.setLoadingState(.idle)
            // Phase must flip to .ready right here — the prepared pipeline's
            // card publish may still be in flight, and the loading screen
            // must not linger on .preparing while the network fetch fills
            // in behind (cached page / SQLite first paint).
            display.setFeedDisplayPhase(.ready(contextID: presentationEpoch))
            // Warm-up image resolution/prefetch (no-ops when prepared pipeline is active).
            resolveArticleImagesInBackground(visibleItems)
            prefetchUpcoming()
        }

        // Snapshot baseline for "What's New" — persisted so items don't vanish
        // just because the app restarted. Falls back to now on first launch.
        if let persisted = UserDefaults.standard.object(forKey: Self.lastWhatsNewSeenAtKey) as? Date {
            whatsNewManager.whatsNewBaselineDate = persisted
        } else {
            whatsNewManager.whatsNewBaselineDate = Date()
        }

        // Collection presets own an explicit source set, including personal
        // sources that do not exist in (or depend on) the enabled catalogue.
        // Cache hydration above owns first paint; refresh the same members
        // asynchronously without holding FeedLoader.start() open.
        if presetSourceFilter != nil,
           case .collection(let cid, _) = activePreset {
            display.setLoadingState(visibleItems.isEmpty ? .initial : .idle)
            refreshWhatsNew(shouldBoost: false)
            let capturedPreset = activePreset
            let capturedGen = presetGeneration
            progressiveFetchTask = Task { [weak self] in
                guard let self else { return }
                await self.loadCollectionPresetFeed(
                    collectionID: cid,
                    expectedPreset: capturedPreset,
                    expectedGeneration: capturedGen
                )
            }
            return
        }
        if activePreset.isLastClicked {
            display.setIsPreparingInitialRunway(false)
            display.setLoadingState(.idle)
            // Empty preset load must settle the phase — otherwise the
            // loading screen stays on .preparing forever.
            if visibleItems.isEmpty {
                display.setFeedDisplayPhase(.empty(contextID: presentationEpoch))
            }
            return
        }
        if activePreset.isSmartFeed {
            display.setIsPreparingInitialRunway(false)
            display.setLoadingState(.idle)
            // Empty smart feed with no cache — settle the phase explicitly.
            if visibleItems.isEmpty {
                display.setFeedDisplayPhase(.empty(contextID: presentationEpoch))
            }
            return
        }

        guard !registry.enabledSources.isEmpty else {
            display.setIsPreparingInitialRunway(false)
            display.setLoadingState(.idle)
            if visibleItems.isEmpty {
                display.setFeedDisplayPhase(.empty(contextID: presentationEpoch))
            }
            return
        }

        // A warm cache can render immediately. A gated cold start stays in its
        // preparation state until the 100-source runway is actually ready;
        // showing "no articles" while useful collection is in flight is false.
        display.setLoadingState(visibleItems.isEmpty ? .initial : .idle)

        // Seed What's New from local data now. Fresh network candidates arrive
        // through the starter/progressive pipeline, so a second 30-source
        // booster would only compete with first paint for bandwidth.
        refreshWhatsNew(shouldBoost: false)

        // Offline fast path: skip the cold-start network loop entirely when
        // connectivity is already KNOWN to be unavailable. Each fetch attempt
        // wastes 7–10 seconds on timeouts, and with the bootstrap await the
        // loading screen can persist for 35–45 seconds before hitting the
        // 30-second deadline. Going straight to empty/cached state gives the
        // user a responsive UI immediately.
        //
        // hasReceivedFirstPath gates the gate: NWPathMonitor's first path
        // callback is asynchronous, so isConnected == false before it fires
        // means "unknown", not "offline". An online launch that hits this
        // check before the callback would be misclassified as offline and
        // sent straight to .empty with no recovery.
        if networkMonitor.isKnownOffline && visibleItems.isEmpty {
            display.setIsPreparingInitialRunway(false)
            display.setLoadingState(.idle)
            display.setFeedDisplayPhase(.empty(contextID: presentationEpoch))
            Log.feed.info("cold start skipped: offline, no cached content")
            return
        }

        progressiveFetchTask = Task {
            await self.firstLaunchBootstrapTask?.value
            self.firstLaunchBootstrapTask = nil

            // A populated warm cache or the first-launch bootstrap already
            // owns first paint. Otherwise keep collecting distinct providers;
            // never fall through to the normal progressive path with a thin
            // four- or five-source sample.
            //
            // First attempt: fast deadline (12s) for first paint. Subsequent
            // attempts: full deadline for runway depth. This gets content on
            // screen quickly while background fills build the buffer.
            //
            // Connectivity check inside the loop: if the network drops mid-startup,
            // stop burning time on doomed fetch attempts.
            var coldStartAttempts = 0
            let firstPaintDeadline = Date().addingTimeInterval(12)
            let runwayDeadline = Date().addingTimeInterval(30)
            while self.visibleItems.isEmpty,
                  self.reservoir.reservoirCount == 0,
                  coldStartAttempts < 4,
                  Date() < runwayDeadline,
                  !self.networkMonitor.isKnownOffline {
                coldStartAttempts += 1
                // First attempt: quick deadline via modified fetchNextBatch path
                await self.fetchNextBatch()
                // fetchNextBatch returns immediately when searching;
                // only count real network attempts against the limit.
                if self.isSearching { coldStartAttempts -= 1 }
                // After first paint, bail the tight loop and let progressive
                // fetch fill the runway in background.
                if !self.visibleItems.isEmpty { break }
                // If first paint missed the 12s window, keep trying — but only a **complete page** ends the loop.
                if Date() > firstPaintDeadline, coldStartAttempts >= 2, !self.coldStartPendingItems.isEmpty {
                    // Persist everything gathered, not just the visible prefix: those items are
                    // already fetched, and discarding them threw away ~532 of a 552-item batch. The
                    // page only needs a prefix; storage wants all of it.
                    let pending = self.coldStartPendingItems
                    let persisted = await self.persistInSlices(pending)
                    self.coldStartPendingItems.removeAll()
                    let pageReady = Self.coldStartPageIsReady(persisted)
                    Log.feed.info("cold start persisted pending: items=\(persisted.count)/\(pending.count) pageReady=\(pageReady ? 1 : 0) after deadline")
                    // Review P0.3: a thin batch is not a page. It is persisted (the database must fill), but the run keeps
                    // collecting until the page gate passes or the runway deadline decides below.
                    if pageReady { break }
                }
            }
            // Review P0.3 — nothing partial is ever revealed on an empty database. Any leftover batch is persisted so the
            // database fills, but the page gate below is "a complete page of distinct providers", never "the reservoir
            // has something": publishing a four-source sample and growing it in place is exactly the Loading → partial →
            // better sequence the doctrine forbids. Staying in `.preparing` is the honest state here, and the deadline
            // below chooses between a real page and the empty surface.
            if self.visibleItems.isEmpty, !self.coldStartPendingItems.isEmpty {
                let pending = self.coldStartPendingItems
                let persisted = await self.persistInSlices(pending)
                self.coldStartPendingItems.removeAll()
                Log.feed.info("cold start persisted leftover: items=\(persisted.count)/\(pending.count) pageReady=\(Self.coldStartPageIsReady(persisted) ? 1 : 0)")
            }
            guard !self.visibleItems.isEmpty || Self.coldStartPageIsReady(self.reservoir.visibleItems) else {
                display.setIsPreparingInitialRunway(false)
                display.setLoadingState(.idle)
                display.setFeedDisplayPhase(.empty(contextID: self.presentationEpoch))
                Log.feed.info("cold start withheld: no complete page after \(coldStartAttempts) attempts (30 s deadline) — empty surface, no partial feed")
                return
            }
            // Bulk-fill only when the local runway is genuinely shallow. A
            // warm reservoir should stay quiet while the user starts reading.
            if self.reservoir.reservoirCount < Reservoir.progressiveFillTarget {
                await progressiveFetch()
            } else {
                Log.feed.info("progressiveFetch skipped: runway=\(self.reservoir.reservoirCount)")
            }
            guard !Task.isCancelled else { return }
            self.startCoverageMining(generation: self.filterGeneration)
        }

        // Slow-drip background refresh — keeps the database and What's New
        // fed with fresh content continuously while the app is in foreground.
        startBackgroundRefresh()

        // Maintenance is deliberately outside the startup runway. On a fresh
        // database even VACUUM can contend with ingestion and delay first paint.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await self?.performLightExpurgo()
        }
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.performHeavyMaintenance()
        }

        // Startup watchdog: if the phase never left .preparing, force the
        // transition so the loading screen can never linger forever. Fires
        // when loadingState is .idle (a publish raced ahead of the phase
        // transition, or a preset path forgot to settle it) AND when the
        // pipeline stalls in .initial without runway preparation running.
        //
        // A page on screen is always an answer, so it settles `.ready`. An
        // *empty* page is only an answer once the runway has stopped preparing
        // one: a transient clear during a rebuild leaves loadingState .idle with
        // nothing visible, and settling `.empty` there is what put "No sources
        // enabled" on screen while the catalogue was still loading.
        if case .preparing = display.feedDisplayPhase,
           display.loadingState == .idle
                || (display.loadingState == .initial && !isPreparingInitialRunway) {
            // A page on screen is always an answer, so it settles `.ready`. An
            // *empty* page is only an answer once the runway has stopped preparing
            // one: a transient clear during a rebuild leaves loadingState .idle with
            // nothing visible, and settling `.empty` there is what put "No sources
            // enabled" on screen while the catalogue was still loading.
            let hasPage = !display.visibleItems.isEmpty
            if hasPage || !isPreparingInitialRunway {
                display.setFeedDisplayPhase(hasPage
                    ? .ready(contextID: presentationEpoch)
                    : .empty(contextID: presentationEpoch))
                Log.feed.warning("startup watchdog: forced phase out of .preparing")
            }
        }
    }

    /// Rebind runtime consumers after a verified managed snapshot is activated.
    /// Feed items, bookmarks, history, collections, and user-imported sources
    /// live outside the managed catalog and are deliberately preserved.
    func reloadActiveCatalogAfterUpdate() async {
        let importedSources = registry.sources.filter { $0.region == "imported" }
        await registry.loadFromOPML()
        if !importedSources.isEmpty {
            registry.sources = OPMLParser.deduplicateSources(
                registry.sources + importedSources
            )
            registry.prepareFilterCaches()
        }

        reservoir.sourceRegionMap = registry.regionMap
        await TaxonomyStore.shared.build(
            from: registry.sources,
            sharedCountrySourceURLs: registry.sharedCountrySourceURLs
        )
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyShape = -1
        cachedTaxonomyFeedURLs = []
        startupTotalSourceCount = registry.sourceCount
        searchEngine.replaceCatalog(at: CatalogRuntime.activeCatalogURL())

        setFilter(
            region: activeRegion,
            nodeIDs: activeNodeIDs,
            type: activeContentType,
            mood: activeMood,
            languages: activeLanguages
        )
        FeedMetrics.event(
            "CatalogUpdate.reloaded",
            "sources=\(registry.sourceCount) revision=\(CatalogRuntime.activeManifest()?.revision ?? 0)"
        )
    }

    // MARK: - UI Pipeline
    /// All visibleItems writes route through this single pipeline.
    /// Category‑A triggers (.flush) cancel everything; scroll/fetch/trim
    /// chain behind the current task so only one actor mutates the UI.
    private enum FeedUIUpdate {
        case flush(
            forceFetch: Bool = false,
            skipRead: Bool = false,
            skipNetworkFetch: Bool = false,
            generation: Int64 = 0
        )
        case append         // Move from reservoir → visible (scroll)
        case refresh(generation: Int64 = 0)  // Sync visible from reservoir (after fetch)
        case trim(Int, generation: Int64 = 0)      // Trim buffer with currentVisibleIndex
        case replace([FeedItem])  // Full replace (search, toggle)
    }
    /// Single writer for `visibleItems`. Every mutation routes through here.
    /// Stamps each item with isRead/isBookmarked so views don't observe the
    /// global sets directly — reading one item won't invalidate all cards.
    /// Increments `visibleItemsGeneration` so FeedLoader caches invalidate reliably.


    /// Persist a batch in slices. `persistFetchedItems` is all-or-nothing — one language-resolution
    /// mismatch drops the entire call — so handing a cold-start batch of ~550 items to it is strictly
    /// more fragile than the 20-item path it replaced. Slicing keeps one bad row from discarding the
    /// work, which is the whole point of persisting it instead of throwing it away.
    @discardableResult
    private func persistInSlices(_ items: [FeedItem]) async -> [FeedItem] {
        var persisted: [FeedItem] = []
        for start in stride(from: 0, to: items.count, by: Self.coldStartPersistChunk) {
            let slice = Array(items[start..<min(start + Self.coldStartPersistChunk, items.count)])
            persisted.append(contentsOf: await persistFetchedItems(slice))
        }
        return persisted
    }


    /// Rebuild the presentations of a restored page from their persisted media projection, decoding
    /// through the same store the pipeline uses. The restored card then carries the very image the
    /// pipeline would publish for it, so the first prepared batch is not a visible change — which is
    /// the whole point: the page the reader sees first is the page they keep.
    ///
    /// The rule mirrors `CardPreparationCoordinator.decodeToRenderReady`: an image means a hero slot,
    /// and a card without its image must never take one.
    /// Ordered fingerprint of a published page: `id|layout|hasMedia` per card, joined. Used to prove
    /// that the page restored from cache and the pipeline's own first batch are the *same* page, which
    /// is what "the reader sees the page they keep" means. `FeedCardPresentation` itself cannot be
    /// compared: it carries `preparedAt: Date`, so `Equatable` is never equal across publications.
    private func pageFingerprint(_ cards: [FeedCardPresentation], prefix: Int) -> String {
        let parts = cards.prefix(prefix).map { card -> String in
            let layout: String
            switch card.layout {
            case .hero: layout = "hero"
            case .thumbnail: layout = "thumb"
            case .textOnly: layout = "text"
            }
            let hasMedia: String
            if case .image = card.media { hasMedia = "img" } else { hasMedia = "no" }
            return "\(card.item.id)|\(layout)|\(hasMedia)"
        }
        return parts.joined(separator: ",")
    }

    /// The media identity of a restored page: itemID → cache key, taken from the persisted projection.
    ///
    /// `publishCards` *replaces* `visibleCardCacheKeys` with what it is handed, so a restore that hands it nothing
    /// leaves the display believing no card on the page has an image — and the next write then persists cards that
    /// carry media with no way to rebuild it. Measured on a warm reopen: `page[restore] items=20 withMedia=17`
    /// followed by `page[cache] write sig=filtered items=20 cards=20 mediaKeys=0`, i.e. the launch after that got a
    /// page of placeholders where this one had images.
    nonisolated static func restoredMediaKeys(
        _ projection: [FeedDisplayState.CachedCardMedia]?
    ) -> [String: String] {
        (projection ?? []).reduce(into: [String: String]()) { keys, entry in
            guard let key = entry.cacheKey else { return }
            keys[entry.itemID] = key
        }
    }

    /// Publish the prepared page for the **current** composition from disk, if the repository holds one.
    ///
    /// One lookup serves both entry points, because the page cache is keyed by the composition signature (review P0.2):
    ///   * the launch path (`start()`), so a warm reopen paints the prepared page before the catalogue parses;
    ///   * the filter-change path (`setFilter`), so a context that was prepared before switches **without the network** —
    ///     the `filter tap → composição local → feed` step review P1.2 asks for, taken before the debounced reload and
    ///     its network work even start.
    ///
    /// Contract: publishes only a non-empty composition whose generation is still current, settles `.ready` (publishing
    /// alone does not leave `.preparing` while `loadingState == .refreshing`), and returns whether it published. Cards go
    /// through the same filter pass and the same persisted-media restoration as the launch path, so a restored page can
    /// never show an item the active filter excludes.
    @discardableResult
    private func restorePreparedPageIfAny(generation: Int64, reason: String) async -> Bool {
        guard let cached = await display.restoreCachedPage(filterSignature: pageCacheSignature),
              generation == filterGeneration else { return false }
        let stamped = await applyFiltersAsync(cached.items)
        guard generation == filterGeneration, !stamped.isEmpty else { return false }
        let cards = await PreparedPageRestoration.cards(for: stamped, projection: cached.cards,
                                                        mediaAssets: mediaAssetStore)
        guard generation == filterGeneration else { return false }
        display.publishCards(cards, items: stamped,
                             readItemIDs: readItemIDs,
                             bookmarkItemIDs: bookmarkedItemIDs,
                             isAppend: false,
                             mediaCacheKeys: Self.restoredMediaKeys(cached.cards))
        display.setIsPreparingInitialRunway(false)
        display.setLoadingState(.idle)
        display.setFeedDisplayPhase(.ready(contextID: presentationEpoch))
        let withMedia = cards.filter { if case .image = $0.media { return true }; return false }.count
        Log.feed.info("page[restore] items=\(stamped.count) withMedia=\(withMedia) fp=\(self.pageFingerprint(cards, prefix: 20)) reason=\(reason)")
        return true
    }

    /// How many fetched items are enough to paint the first page instead of waiting for the full
    /// cold-start source target. A screen, not a budget: the runway can keep filling behind it.
    private static let coldStartImmediateItemCount = 12

    /// Publishers that must have delivered before a cold-start chunk stops early. One source is a
    /// single channel and a thin first page; the floor keeps the page interleaved.
    private static let coldStartMinimumPageSources = 3

    /// Items per write when persisting a cold-start batch.
    private static let coldStartPersistChunk = 64

    private func setVisibleItems(
        _ items: [FeedItem],
        isAppend: Bool = false,
        settlesPhase: Bool = true,
        isUserInitiated: Bool = false
    ) {
        // Prepared pipeline: defer publication until cards are terminal.
        // The UI must never see a card without its resolved media, then
        // see an image appear later — that violates the "feed is sacred"
        // contract. Items go to the coordinator first; promotePreparedCards
        // publishes both visibleItems and visibleCards together.
        if usePreparedPipeline, !items.isEmpty {
            let ctx = display.activePresentationContext
            cardPreparationTask?.cancel()
            cardPreparationTask = Task { [weak self] in
                guard let self else { return }
                // Guard against stale work from a cancelled predecessor.
                guard !Task.isCancelled, ctx.epoch == self.presentationEpoch else { return }

                if isAppend {
                    await self.preparationCoordinator.appendEditorialSequence(items, context: ctx)
                    guard !Task.isCancelled, ctx.epoch == self.presentationEpoch else { return }
                    await self.preparationCoordinator.fillRunway(
                        targetRenderReady: self.runwayPolicy.renderReadyTarget,
                        context: ctx
                    )
                } else {
                    await self.preparationCoordinator.replaceEditorialSequence(items, context: ctx)
                    guard !Task.isCancelled, ctx.epoch == self.presentationEpoch else { return }
                    await self.preparationCoordinator.fillRunway(
                        targetRenderReady: self.runwayPolicy.initialPublishedCount,
                        context: ctx
                    )
                }
                guard !Task.isCancelled, ctx.epoch == self.presentationEpoch else { return }
                let pageSize = isAppend ? Reservoir.pageSize : self.runwayPolicy.initialPublishedCount
                await self.promotePreparedCards(context: ctx, isAppend: isAppend, maxCount: pageSize, isUserInitiated: isUserInitiated)
            }
            return  // <-- DO NOT publish items yet; wait for terminal cards
        }

        // Legacy path (or prepared pipeline with empty items):
        let countBefore = display.visibleItems.count
        display.setVisibleItems(items, readItemIDs: readItemIDs, bookmarkItemIDs: bookmarkedItemIDs,
            shouldCache: !isAppend && currentMode == .main,
            filterSignature: pageCacheSignature,
            settlesPhase: settlesPhase,
            isUserInitiated: isUserInitiated)
        if display.visibleItems.count > 0 || countBefore > 0 {
            markPreviouslyLoadedContentIfNeeded(items)
        }
    }

    /// Promote render-ready cards from the coordinator into visibleCards
    /// AND visibleItems simultaneously. No card is ever visible without
    /// its terminal media already resolved — the feed contract is preserved.
    ///
    /// Both first-paint and append paths wait for the contiguous prefix
    /// to become ready. First paint gets the full initial-viewport deadline
    /// (6s) and waits for at least initialPublishedCount cards; append gets
    /// a shorter 3s window. Cards that miss their deadline are terminal-
    /// fallbacked by the coordinator — the wait here just ensures the UI
    /// batch is contiguous.
    ///
    /// Uses ContinuousClock to compare against a deadline — never computes
    /// iteration count from Duration components (`.milliseconds(300).seconds`
    /// is 0, so division would fatal-error).
    private func promotePreparedCards(
        context: FeedPresentationContext,
        isAppend: Bool = false,
        maxCount: Int = 20,
        isUserInitiated: Bool = false
    ) async {
        let ready: [PreparedFeedCard]
        let clock = ContinuousClock()
        let maxWait: Duration = isAppend ? .seconds(3) : runwayPolicy.initialViewportDeadline
        let deadline = clock.now.advanced(by: maxWait)

        // First paint: wait until the full initial page is ready (or fewer
        // if the editorial sequence is shorter — a feed with only 5 items
        // should show 5 cards, not wait 6s for 20).
        // Append: accept any non-empty contiguous prefix.
        let editorialRemaining = await preparationCoordinator.editorialAheadCount
        let minimumCount: Int
        if isAppend {
            minimumCount = 1
        } else {
            minimumCount = min(runwayPolicy.initialPublishedCount, editorialRemaining)
        }

        // Suspend until the contiguous prefix is ready, or the deadline
        // fires, or the context changes. waitForContiguousPrefix is driven
        // by storeRenderReady signals — no polling, no race window, no
        // duplicate accumulation.
        let candidate = await preparationCoordinator.waitForContiguousPrefix(
            minimumCount: minimumCount,
            maximumCount: maxCount,
            deadline: deadline,
            context: context
        )

        guard !Task.isCancelled else { return }
        guard !candidate.isEmpty else { return }
        guard context.epoch == presentationEpoch else { return }

        // All checks passed — commit the cards as published.
        // commitPublished validates that the context is still active and
        // that the prefix hasn't changed since we peeked.
        let committed = await preparationCoordinator.commitPublished(
            expectedIDs: candidate.map(\.id),
            context: context
        )
        guard committed else { return }
        // Re-validate AFTER the commit hops: the epoch can change while that
        // await is in flight, and publishing now would show cards from the old
        // composition under the new one.
        guard !Task.isCancelled, context.epoch == presentationEpoch else { return }
        ready = candidate

        // Stamp before creating cards so FeedCardPresentation gets correct
        // isRead/isBookmarked. display.publishCards re-stamps for latest
        // state (idempotent, read/bookmark may have changed during prep).
        var stampedCards = ready
        for i in stampedCards.indices {
            stampedCards[i].item.stamp(
                readItemIDs: readItemIDs,
                bookmarkItemIDs: bookmarkedItemIDs
            )
        }

        let items = stampedCards.map(\.item)
        let cards = stampedCards.map { card in
            FeedCardPresentation(
                from: card,
                isRead: card.item.isRead,
                isBookmarked: card.item.isBookmarked
            )
        }

        // itemID → cache key, so the warm start can rebuild these exact cards. `reduce(into:)` on
        // purpose: a duplicate id must degrade, not crash.
        let mediaKeys = ready.reduce(into: [String: String]()) { acc, card in
            if case .image(let renderImage) = card.media { acc[card.item.id] = renderImage.cacheKey }
        }
        if !isAppend {
            let hasMedia = cards.filter { if case .image = $0.media { return true }; return false }.count
            Log.feed.info("page[pipeline] items=\(items.count) withMedia=\(hasMedia) fp=\(self.pageFingerprint(cards, prefix: 20))")
        }
        display.publishCards(cards, items: items,
            readItemIDs: readItemIDs, bookmarkItemIDs: bookmarkedItemIDs,
            isAppend: isAppend,
            // Appends are published too, not only replaces: a feed grows after its first page, so an append-only
            // writer freezes the cache at whatever the first flush happened to hold (measured: 2 items). The
            // display owns the depth, the no-shrink and the still-building-runway rules.
            shouldCache: currentMode == .main,
            filterSignature: pageCacheSignature,
            isUserInitiated: isUserInitiated,
            mediaCacheKeys: mediaKeys)

        if !isAppend {
            hasPreviouslyLoadedContent = true
            // What the reader actually keeps. The batch above can arrive with less media than is on
            // screen (the pipeline republishes ids it has not resolved yet); the display's upgrade-only
            // merge is what stops that from stripping images, so this is the number to watch.
            let shown = display.visibleCards
            let shownMedia = shown.filter { if case .image = $0.media { return true }; return false }.count
            Log.feed.info("page[visible] items=\(shown.count) withMedia=\(shownMedia) fp=\(self.pageFingerprint(shown, prefix: 20))")
        }

        // After publishing a batch, let the runway controller re-evaluate
        // whether preparation intensity needs adjustment.
        if usePreparedPipeline {
            Task { [weak self] in
                guard let self else { return }
                let idx = self.visibleItems.count - max(ready.count, 0)
                await self.runwayController.reportViewport(
                    currentIndex: max(0, idx),
                    publishedCount: self.visibleItems.count
                )
                await self.runwayController.evaluate()
            }
        }
    }

    private func markPreviouslyLoadedContentIfNeeded(_ items: [FeedItem]) {
        guard !items.isEmpty, !hasPreviouslyLoadedContent else { return }
        hasPreviouslyLoadedContent = true
        if usesPersistentStorage {
            UserDefaults.standard.set(true, forKey: Self.hasPreviouslyLoadedContentKey)
        }
    }

    /// Single writer for `visibleItems`. Every mutation routes through here.
    /// - `.flush`: cancels all competing work, clears, then reloads from SQLite.
    /// - `.append` / `.refresh` / `.trim`: serialized behind the current pipeline.
    /// - `.replace`: immediate (search results, source toggle — caller owns the data).
    private func applyUpdate(_ update: FeedUIUpdate) {
        // Bookmark mode is a fixed snapshot — no screen mutations allowed
        guard !isBookmarkFeed else { return }
        // Smart Feeds are also fixed cached queues. They are refreshed only by
        // the Smart Feed pipeline, never by the global reservoir.
        guard !activePreset.isSmartFeed else { return }
        switch update {
        case .flush(let forceFetch, let skipRead, let skipNetworkFetch, let generation):
            pipelineTask?.cancel()
            cardPreparationTask?.cancel()
            progressiveFetchTask?.cancel()
            trimDebounceTask?.cancel()
            setVisibleItems([], settlesPhase: false)
            reservoirCount = 0
            reservoir.clear()
            if !usePreparedPipeline {
                cardQueue.reset()
                display.setVisibleCards([])
            }
            Log.feed.info("[TaxonomyTrace] flush gen=\(generation) clearing visible+reservoir, will reloadFromSQLite")
            pipelineTask = Task { [weak self] in
                guard let self else { return }
                await self.reloadFromSQLite(skipRead: skipRead, generation: generation)
                guard !Task.isCancelled else { return }
                // Drop stale pipeline results — only when generation is explicitly tracked
                if generation != 0, generation != self.filterGeneration {
                    Log.feed.info("[TaxonomyTrace] flush gen=\(generation) dropping stale (current=\(self.filterGeneration))")
                    return
                }
                // Present the local composition now instead of holding it behind the
                // fetch below. "Has something valid to show" and "is fetching more"
                // are different states: the loader used to stay up until the network
                // returned, so changing a filter with a slow or unreachable server
                // showed nothing even though matching articles were already in
                // SQLite. The fetch below still appends in the background and the
                // terminal state further down is unchanged — it only decides
                // `.empty` when nothing was found at all.
                if !self.visibleItems.isEmpty,
                   generation == 0 || generation == self.filterGeneration {
                    self.display.setLoadingState(.idle)
                    self.display.setFeedDisplayPhase(.ready(contextID: self.presentationEpoch))
                    Log.feed.info("[TaxonomyTrace] flush gen=\(generation) local page published items=\(self.visibleItems.count)")
                }
                let sourcesBefore = Set(self.visibleItems.map(\.sourceURL)).count
                let needsFilteredBreadth = self.activeContentType != .all
                    && sourcesBefore < Self.immediateFilteredSourceTarget
                // Timed because this pair is the first-paint critical path for a content-type filter:
                // a filtered page has few distinct providers, so it always fetches over the network
                // and then reloads the whole page again to interleave whatever the fetch added.
                let fetchesBefore = self.totalFetched
                let fetchStart = ContinuousClock().now
                // Deferring the fetch is only a win when the page already holds content *of the type
                // being asked for*: otherwise the deferral also defers the filtered content, which is
                // worse than waiting (measured: the filter acceptance went from 6.7 s to 11.8 s when
                // the deferral did not check the type).
                let localOfActiveType = self.activeContentType == .all
                    ? self.visibleItems.count
                    : self.visibleItems.filter { self.activeContentType.matches($0) }.count
                let hasLocalPage = !self.visibleItems.isEmpty
                // OFF until the cold start is fixed. Head-to-head on the same combo in the same
                // position of the run: with the deferral off, `videos` showed 5 cards @1813 ms —
                // matching the pre-change baseline of 5 @1277 ms — and with it on, 0 cards. The one
                // benefit cited for it (podcast 6.68 s → 5.76 s) was a single sample contradicted by
                // the next on-run (10.4 s) and beaten by the off-run (2.03 s). Do not re-enable on
                // n=1; re-measure each configuration at least twice, and note `all` fails in both.
                let wantsFetch = !skipNetworkFetch
                    && (forceFetch || self.visibleItems.count < Reservoir.pageSize || needsFilteredBreadth)
                // The reader who already has a page must not wait on the network for it. Measured on a
                // content-type filter, the awaited fetch was the whole first-paint cost — 27.9 s and
                // 10.8 s against a 0.7 s reload — while the fetch's own job (finding more providers for
                // this content type) can happen behind the painted page: the display's upgrade-only
                // merge keeps the page steady when the interleaved batch lands.
                // A user-initiated composition change must not inherit the cold-start runway. The
                // first-launch bootstrap that owns first paint can run for ~80 s (its own comment), and
                // `progressiveFetchTask` awaits it; the flush cancels that waiter but not the bootstrap,
                // so while `isPreparingInitialRunway` stayed true the filter's fetch took the cold-start
                // branch and waited behind it — measured: 5.5 s and 10.6 s with 0 cards. The runway
                // belongs to the initial page; once the user asks for a different composition, the
                // bounded path is the right one.
                if generation != 0 {
                    self.display.setIsPreparingInitialRunway(false)
                }
                self.display.setFilteredCompositionInFlight(true)
                var fetchRanInline = false
                if wantsFetch {
                    // The deferral is gone, not disabled: it was never validated (the blind version measured
                    // as a regression, the type-gated benefit was n=1), and leaving a flag at `false` with a
                    // helper behind it made that helper dead code which silently disabled the idea.
                    await self.fetchNextBatch()
                    fetchRanInline = true
                }
                let fetchMs = Int((ContinuousClock().now - fetchStart).components.seconds * 1000
                    + (ContinuousClock().now - fetchStart).components.attoseconds / 1_000_000_000_000_000)
                // A filtered fetch may add providers after the cached page was
                // seeded. Rebuild once so those providers are interleaved into
                // the first page instead of waiting behind a prolific channel.
                let reloadStart = ContinuousClock().now
                var reloaded = false
                // Only the inline fetch is followed by this rebuild: it exists to interleave what the
                // fetch just added. When the fetch went to the background, the helper owns the pair and
                // rebuilding here would republish from SQLite without those providers — a second full
                // reload serving nothing, and the batch whose cards have no resolved media yet.
                if needsFilteredBreadth,
                   fetchRanInline,
                   !Task.isCancelled,
                   (generation == 0 || generation == self.filterGeneration) {
                    await self.reloadFromSQLite(skipRead: skipRead, generation: generation)
                    reloaded = true
                }
                let reloadMs = Int((ContinuousClock().now - reloadStart).components.seconds * 1000
                    + (ContinuousClock().now - reloadStart).components.attoseconds / 1_000_000_000_000_000)
                if needsFilteredBreadth || reloadMs > 50 {
                    let sourcesAfter = Set(self.visibleItems.map(\.sourceURL)).count
                    Log.feed.info("[Latency] flush gen=\(generation) type=\(String(describing: self.activeContentType)) localOfType=\(localOfActiveType) preparingRunway=\(self.display.isPreparingInitialRunway) bootstrap=\(self.firstLaunchBootstrapTask != nil) fetchMs=\(fetchMs) fetched=\(self.totalFetched - fetchesBefore) inline=\(fetchRanInline) reloadMs=\(reloadMs) reloaded=\(reloaded) sourcesBefore=\(sourcesBefore) sourcesAfter=\(sourcesAfter) items=\(self.visibleItems.count)")
                }
                if self.usesPersistentStorage,
                   !Task.isCancelled,
                   generation == self.filterGeneration {
                    self.startCoverageMining(generation: generation)
                }
                // The terminal state belongs to the operation that asked for it.
                // Without this guard a stale flush stamps `.empty`/`.ready` for the
                // *current* epoch after its network wait, flashing the wrong state
                // over a newer composition that is still working.
                // The composition for *this* generation is done: the surface may settle, even to empty.
                if generation == 0 || generation == self.filterGeneration {
                    self.display.setFilteredCompositionInFlight(false)
                }
                guard !Task.isCancelled,
                      generation == 0 || generation == self.filterGeneration else {
                    Log.feed.info("[TaxonomyTrace] flush gen=\(generation) dropping stale terminal state (current=\(self.filterGeneration))")
                    return
                }
                display.setLoadingState(.idle)
                display.setFeedDisplayPhase(self.visibleItems.isEmpty
                    ? .empty(contextID: self.presentationEpoch)
                    : .ready(contextID: self.presentationEpoch))
                Log.feed.info("[TaxonomyTrace] flush gen=\(generation) complete visibleItems=\(self.visibleItems.count)")
            }

        case .append:
            let prev = pipelineTask
            pipelineTask = Task { [weak self] in
                await prev?.value
                guard !Task.isCancelled, let self else { return }
                // This operation's inputs are collected right here — the reservoir
                // as it stands once `prev` finished — so the composition carried to
                // the publish below is the one in effect now. No guard is needed
                // before the mutations that follow: nothing suspends between this
                // capture and them.
                let ctx = self.display.activePresentationContext
                self.reservoir.moveToVisible(count: Reservoir.pageSize)
                self.markSurfaced(self.reservoir.visibleItems)
                let upcoming = self.reservoir.visibleItems
                // Run filter off main actor — keeps UI responsive during scroll-driven appends.
                let filtered = await self.applyFiltersAsync(upcoming)
                guard !Task.isCancelled, ctx.epoch == self.presentationEpoch else { return }

                if self.usePreparedPipeline {
                    // New pipeline: CardPreparationCoordinator handles everything.
                    // setVisibleItems appends items to the coordinator, fills the
                    // runway, and promotes render-ready cards — all async.
                    // visibleItems and visibleCards are set atomically inside
                    // promotePreparedCards when the contiguous prefix is ready.
                    self.setVisibleItems(filtered, isAppend: true)
                } else {
                    // Legacy pipeline: ReadyCardQueue + CardPreparationPipeline.
                    self.cardQueue.enqueue(upcoming)
                    await self.cardQueue.waitForReady(count: min(Reservoir.pageSize, upcoming.count))
                    let presMap = Dictionary(uniqueKeysWithValues: self.cardQueue.presentations.map { ($0.id, $0) })
                    self.setVisibleItems(filtered, isAppend: true)
                    display.setVisibleCards(filtered.compactMap { presMap[$0.id] })
                    self.enqueueFailedCardsForRetry(presMap: presMap, filtered: filtered)
                }
                self.reservoirCount = self.reservoir.reservoirCount
            }

        case .refresh(let generation):
            let prev = pipelineTask
            pipelineTask = Task { [weak self] in
                await prev?.value
                guard !Task.isCancelled, let self else { return }
                // Drop stale refresh — a newer filter may have been applied
                if generation != 0, generation != self.filterGeneration {
                    Log.feed.info("[TaxonomyTrace] refresh gen=\(generation) dropping stale (current=\(self.filterGeneration))")
                    return
                }
                // Move any new items from reservoir buffer to visible
                let oldCount = self.reservoir.visibleItems.count
                // The composition this refresh carries is the one in effect when it
                // collects its inputs (the reservoir, just now) — capturing at
                // request time would abort refreshes whose epoch moved while this
                // task waited for `prev`, leaving the feed empty.
                let ctx = self.display.activePresentationContext
                if self.reservoir.reservoirCount > 0 && oldCount < Reservoir.pageSize {
                    self.reservoir.moveToVisible(count: Reservoir.pageSize)
                }
                self.markSurfaced(self.reservoir.visibleItems)
                let upcoming = self.reservoir.visibleItems
                let filtered = await self.applyFiltersAsync(upcoming)
                guard !Task.isCancelled, ctx.epoch == self.presentationEpoch else { return }

                if self.usePreparedPipeline {
                    self.setVisibleItems(filtered, isAppend: true)
                } else {
                    self.cardQueue.enqueue(upcoming)
                    await self.cardQueue.waitForReady(count: min(Reservoir.pageSize, upcoming.count))
                    let presMap = Dictionary(uniqueKeysWithValues: self.cardQueue.presentations.map { ($0.id, $0) })
                    self.setVisibleItems(filtered, isAppend: true)
                    display.setVisibleCards(filtered.compactMap { presMap[$0.id] })
                    self.enqueueFailedCardsForRetry(presMap: presMap, filtered: filtered)
                }
                self.reservoirCount = self.reservoir.reservoirCount
                // Transition from preparing → ready/empty after filter reload completes.
                if case .preparing = self.feedDisplayPhase {
                    display.setFeedDisplayPhase(self.visibleItems.isEmpty
                        ? .empty(contextID: self.presentationEpoch)
                        : .ready(contextID: self.presentationEpoch))
                }
                Log.feed.info("[TaxonomyTrace] refresh gen=\(generation) visibleItems=\(self.visibleItems.count) (was \(oldCount))")
            }

        case .trim(let idx, let generation):
            let prev = pipelineTask
            pipelineTask = Task { [weak self] in
                await prev?.value
                guard !Task.isCancelled, let self else { return }
                // Drop stale trim — a newer filter may have triggered a more
                // recent pipeline that already seeded fresher data.
                if generation != 0, generation != self.filterGeneration { return }
                self.reservoir.trimBuffer(currentVisibleIndex: idx)
                if self.usePreparedPipeline {
                    // The prepared coordinator manages its own editorial sequence.
                    // Trim only affects the reservoir buffer — the coordinator's
                    // published cards are preserved. Calling setVisibleItems here
                    // would trigger a full replaceEditorialSequence, truncating
                    // the feed back to the initial page.
                    self.reservoirCount = self.reservoir.reservoirCount
                } else {
                    let filtered = EditorialSequencer.sequence(self.applyFilters(self.reservoir.visibleItems))
                    self.setVisibleItems(filtered)
                    // Rebuild visibleCards from legacy queue, keeping only items still visible
                    let presMap = Dictionary(uniqueKeysWithValues: self.cardQueue.presentations.map { ($0.id, $0) })
                    display.setVisibleCards(filtered.compactMap { presMap[$0.id] })
                    self.reservoirCount = self.reservoir.reservoirCount
                }
            }

        case .replace(let items):
            pipelineTask?.cancel()
            // This channel answers on its own, empty or not: the in-flight state ends here.
            display.setFilteredCompositionInFlight(false)
            if !usePreparedPipeline {
                cardQueue.reset()
                display.setVisibleCards([])
            }
            // `.replace` is the user-action channel (search results, source toggle, presets): the
            // caller owns the data, so an empty replacement is an answer — turning off the last
            // enabled source must empty the feed, not leave articles from the source just disabled.
            setVisibleItems(items, isUserInitiated: true)
        }
    }

    // MARK: - Scroll
    private var lastLoadedIndex = -1
    private var lastLoadMoreAttempt: Date?
    private var trimDebounceTask: Task<Void, Never>?

    /// User-initiated refresh (pull-to-refresh, retry, empty-state button).
    /// Forces a fresh fetch WITHOUT re-running one-time startup — no re-parsing
    /// OPML, no restarting the network monitor, no re-hydrating SQLite, no
    /// baseline reset. Falls back to full startup if the store never started.
    func refreshNow() async {
        guard hasStarted else { await start(); return }
        if let smartFeedID = activePreset.smartFeedID {
            await refreshSmartFeed(id: smartFeedID)
            return
        }
        guard !activePreset.isLastClicked else {
            await loadLastClickedFeed()
            return
        }
        // Collection presets may reference personal sources that are absent
        // from the bundled registry. Route through the collection-aware path
        // which queries exact member URLs instead of requiring enabledSources.
        if case .collection(let cid, _) = activePreset, presetSourceFilter != nil {
            display.setLoadingState(.refreshing)
            lastRefreshDate = nil
            let capturedPreset = activePreset
            let capturedGen = presetGeneration
            await loadCollectionPresetFeed(
                collectionID: cid,
                expectedPreset: capturedPreset,
                expectedGeneration: capturedGen
            )
            return
        }
        guard !registry.enabledSources.isEmpty else { return }
        display.setLoadingState(.refreshing)
        lastRefreshDate = nil   // bypass the staleness gate
        await fetchNextBatch()
        display.setLoadingState(.idle)
    }

    /// Replenishment scheduled from a viewport observation (PR-13).
    ///
    /// The per-item callback this replaces fired when a card appeared, so its demand signal was "a card
    /// exists" rather than "the viewport is here": it could not tell a fling from a settle, and with
    /// filters active it compared an index in the filtered page against the unfiltered count. The
    /// observation below states both numbers in the same space — the page the reader is looking at.
    ///
    /// The work is still bounded the same way: a 300 ms throttle that rejects the rapid-fire updates a
    /// scroll produces, one append of a reservoir page, and a trim debounce. The observation itself
    /// performs no selection, decode or fetch.
    func loadMoreIfNeeded(viewportLastVisibleOrdinal: Int, publishedOrdinalCount: Int) async {
        guard !isSearching else { return }
        guard !isBookmarkFeed else { return }
        guard !activePreset.isSmartFeed else { return }
        guard !activePreset.isLastClicked else { return }

        // Fast reject: if the last load-more was within 300ms, skip the O(1) threshold check.
        // The viewport moves in rapid succession during scroll; only the last position matters.
        let now = Date()
        if let last = lastLoadMoreAttempt, now.timeIntervalSince(last) < 0.3 { return }
        lastLoadMoreAttempt = now

        let itemIndex = viewportLastVisibleOrdinal
        guard publishedOrdinalCount > 0, itemIndex >= 0 else { return }
        guard itemIndex >= publishedOrdinalCount - Reservoir.loadMoreThreshold else { return }
        guard itemIndex != lastLoadedIndex else { return }
        lastLoadedIndex = itemIndex

        scheduler.recordConsumption()
        applyUpdate(.append)
        // Report viewport position and let the runway controller evaluate
        // whether preparation intensity needs adjustment.
        if usePreparedPipeline {
            Task { [weak self] in
                guard let self else { return }
                await self.runwayController.reportViewport(
                    currentIndex: itemIndex,
                    publishedCount: publishedOrdinalCount
                )
                await self.runwayController.evaluate()
            }
        }
        // Defer trimming: cancel previous, schedule new after 1.5s pause.
        trimDebounceTask?.cancel()
        let idx = itemIndex
        trimDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.applyUpdate(.trim(idx, generation: self.filterGeneration))
        }

        if reservoir.reservoirCount < Reservoir.reservoirLowWatermark {
            await fetchNextBatch()
        }
    }

    // MARK: - Stale refresh
    func refreshIfStale() async {
        if let smartFeedID = activePreset.smartFeedID {
            let shouldFetch = lastRefreshDate.map {
                Date().timeIntervalSince($0) > 900
            } ?? true
            if shouldFetch {
                await refreshSmartFeed(id: smartFeedID)
            }
            return
        }
        guard !activePreset.isLastClicked else { return }
        // Collection presets may reference personal sources outside the
        // bundled registry. Use the collection-aware path which queries
        // exact member URLs instead of depending on enabledSources.
        if case .collection(let cid, _) = activePreset, presetSourceFilter != nil {
            let shouldFetch: Bool
            if let last = lastRefreshDate {
                shouldFetch = Date().timeIntervalSince(last) > 900 || visibleItems.count < 10
            } else {
                shouldFetch = true
            }
            guard shouldFetch else { return }
            display.setLoadingState(.refreshing)
            let capturedPreset = activePreset
            let capturedGen = presetGeneration
            await loadCollectionPresetFeed(
                collectionID: cid,
                expectedPreset: capturedPreset,
                expectedGeneration: capturedGen
            )
            return
        }
        guard !registry.enabledSources.isEmpty else { return }
        let shouldFetch: Bool
        if let last = lastRefreshDate {
            shouldFetch = Date().timeIntervalSince(last) > 900 || visibleItems.count < 10
        } else {
            shouldFetch = true
        }
        guard shouldFetch else { return }
        display.setLoadingState(.refreshing)
        await fetchNextBatch()
        display.setLoadingState(.idle)
    }

    // MARK: - Filter

    /// Filters expire after 4 hours of inactivity so the user doesn't
    /// open the app to an empty or confusing feed. Cleared on restore if stale.
    private static let filterExpirySeconds: TimeInterval = 14400  // 4 hours

    private func persistFilters() {
        Settings.filterRegion = activeRegion
        Settings.filterTaxonomyNodes = Array(activeNodeIDs)
        Settings.filterContentType = activeContentType.rawValue
        Settings.filterLanguages = Array(activeLanguages)
        Settings.filterMood = activeMood.rawValue
        Settings.filterSetAt = Date().timeIntervalSince1970
    }

    private func scheduleFilterPersistence(generation: Int64) {
        filterPersistenceTask?.cancel()
        filterPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, generation == self.filterGeneration else { return }
            self.persistFilters()
        }
    }

    private func refreshCachedTaxonomyFeedURLsIfNeeded() {
        // Guarding on the node ids alone is not enough: the taxonomy may not be loaded yet when
        // this is called first (the early restore runs before it), and an empty URL set cached
        // then would never be refreshed — the ids do not change until the user picks another
        // selection — so the taxonomy restriction would silently stop applying for the whole
        // session. The tree's size is the cheapest signal that it appeared or changed.
        let taxonomyShape = TaxonomyStore.shared.flatIndex.count
        guard activeNodeIDs != cachedTaxonomyNodeIDs
                || taxonomyShape != cachedTaxonomyShape else { return }
        cachedTaxonomyNodeIDs = activeNodeIDs
        cachedTaxonomyShape = taxonomyShape
        cachedTaxonomyFeedURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: activeNodeIDs)
    }

    func restoreFilters() {
        let hasActiveFilters = Settings.filterRegion != nil
            || !Settings.filterTaxonomyNodes.isEmpty
            || (FeedLoader.ContentType(rawValue: Settings.filterContentType) ?? .all) != .all
            || !Settings.filterLanguages.isEmpty
            || (FeedLoader.MoodFilter(rawValue: Settings.filterMood) ?? .all) != .all

        if hasActiveFilters && Settings.filterAutoExpire {
            let elapsed = Date().timeIntervalSince1970 - Settings.filterSetAt
            if Settings.filterSetAt > 0 && elapsed > Self.filterExpirySeconds {
                Settings.filterRegion = nil
                Settings.filterTaxonomyNodes = []
                Settings.filterContentType = "All"
                Settings.filterMood = "all"
                Settings.filterLanguages = []
                Settings.filterSetAt = 0
                return
            }
        }

        activeRegion = Settings.filterRegion
        // Migrate persisted taxonomy node IDs: old flat global IDs
        // ("global/acoustics") may no longer exist after the topic-directory
        // reorganization.  Filter to only valid IDs; if every saved ID is
        // stale, clear the selection so the user doesn't see a ghost filter.
        let savedIDs = Settings.filterTaxonomyNodes
        let validIDs = savedIDs.filter { TaxonomyStore.shared.node(id: $0) != nil }
        if validIDs.count != savedIDs.count {
            Settings.filterTaxonomyNodes = validIDs
            if validIDs.isEmpty && !savedIDs.isEmpty {
                // All previously-saved IDs are gone — clear selection entirely.
                activeNodeIDs = []
                TaxonomyStore.shared.clearSelection()
            } else {
                activeNodeIDs = Set(validIDs)
                TaxonomyStore.shared.selectedNodeIDs = activeNodeIDs
            }
        } else {
            activeNodeIDs = Set(savedIDs)
            TaxonomyStore.shared.selectedNodeIDs = activeNodeIDs
        }
        // Rebuild taxonomy URL cache so applyFilters actually enforces the
        // restored taxonomy selection (cache is empty on cold start).
        cachedTaxonomyNodeIDs = activeNodeIDs
        cachedTaxonomyFeedURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: activeNodeIDs)
        activeLanguages = Self.normalizedLanguageSet(Settings.filterLanguages)
        if let type = FeedLoader.ContentType(rawValue: Settings.filterContentType) {
            activeContentType = type
        }
        if let mood = FeedLoader.MoodFilter(rawValue: Settings.filterMood) {
            activeMood = mood
        }
    }

    func setFilter(region: String?, nodeIDs: Set<String>, type: FeedLoader.ContentType, mood: FeedLoader.MoodFilter = .all, languages: Set<String>? = nil) {
        // Increment generation BEFORE updating state — every async operation
        // captures this and discards results if a newer filter supersedes it.
        filterGeneration &+= 1
        let (oldContext, newContext) = display.advanceEpoch(
            mode: currentMode,
            filterGeneration: filterGeneration,
            presetGeneration: presetGeneration
        )

        // Notify the runway controller of the context change so it can
        // adjust preparation targets for the new feed composition.
        if usePreparedPipeline {
            Task { [weak self] in
                guard let self else { return }
                await self.runwayController.stop(context: oldContext)
                await self.runwayController.start(context: newContext)
            }
        }
        let generation = filterGeneration

        // Update state immediately for UI responsiveness
        activeRegion = region
        activeNodeIDs = nodeIDs
        activeContentType = type
        activeMood = mood
        let oldLanguages = activeLanguages
        if let langs = languages {
            activeLanguages = Self.normalizedLanguageSet(langs)
        }

        // Language buffer: save current items keyed by the OLD language
        // before clearing, so switching back is instant.
        if oldLanguages != self.activeLanguages, !self.visibleItems.isEmpty {
            saveLanguageBuffer(items: self.visibleItems, for: oldLanguages)
        }

        // Mark the feed as preparing and clear stale visible items immediately.
        // A new filter composition starts from scratch — no partial subsets
        // from the previous filter should flash on screen.
        display.setLoadingState(.refreshing)
        display.setFeedDisplayPhase(.preparing(contextID: presentationEpoch, reason: .filterChange))

        // Language buffer: if switching TO a previously-used language,
        // restore buffered items instantly instead of clearing.
        var publishedFromLanguageBuffer = false
        if oldLanguages != activeLanguages,
           let buffered = restoreLanguageBuffer(for: self.activeLanguages),
           !buffered.isEmpty {
            // Apply any additional filters before publishing.
            // Synchronous is fine here — buffer items are pre-filtered from a prior pass.
            let filtered = applyFilters(buffered)
            if !filtered.isEmpty {
                setVisibleItems(filtered)
                display.setLoadingState(.idle)
                display.setFeedDisplayPhase(.ready(contextID: presentationEpoch))
                Log.feed.info("language buffer restore: items=\(filtered.count) lang=\(self.activeLanguages)")
                publishedFromLanguageBuffer = true
                // Keep network fetch running so fresh items replace buffered ones
            } else {
                if !visibleItems.isEmpty { setVisibleItems([], settlesPhase: false) }
            }
        } else if !visibleItems.isEmpty {
            // Reverted: keeping the page through a filter change shows the *previous* composition under the
            // new chip (article cards while the chip reads Podcasts — the filter lying, the same class as the
            // bar/chip mismatch), it makes the matrix assertion stop being evidence (`:365` only checks that
            // some card exists, which a kept page satisfies), and it can dead-end: once the flush tail settles
            // `.ready` + `.idle`, a genuinely empty filtered composition arrives with `userInitiated` false
            // and the display's invariant refuses it, leaving the old page up indefinitely with no recovery.
            // The honest fix is the in-progress surface (phase/emptyMode mapping), not the clear semantics.
            setVisibleItems([], settlesPhase: false)
        }

        // P1.2 — consult the prepared repository for the composition being switched *into*, before the reload goes near
        // the network.
        //
        // The page cache is keyed by the composition signature, so a context the reader prepared earlier has its own
        // prepared page on disk. Only `start()` used to look it up, which meant a filter tap into a context already
        // visited cleared the feed and waited for the debounced reload — its SQLite pass and its network work — for a page
        // that was already written. Publishing it here is the `filter tap → composição local → feed` step: the clear above
        // has already run, so nothing of the previous composition is shown under the new chip, and the scheduled reload
        // still runs afterwards to extend the runway in the background.
        //
        // Persistent storage only. In-memory mode is the unit-test affordance (`usePreparedPipeline`) and must never
        // publish a page it did not compose: the cache file lives in the host's caches directory, shared across tests.
        // The language buffer wins when it published — its items are in memory and fresher than any cached page.
        if usePreparedPipeline, !publishedFromLanguageBuffer {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.restorePreparedPageIfAny(generation: generation, reason: "filter")
            }
        }
        // Cull What's New items for the new filter — those render above
        // the main feed and must respect the new filter immediately.
        refreshCachedTaxonomyFeedURLsIfNeeded()
        cullWhatsNewForActiveFilter()

        Log.feed.info("[TaxonomyTrace] setFilter gen=\(generation) region=\(region ?? "nil") nodeIDs=\(self.activeNodeIDs)")

        scheduleFilterPersistence(generation: generation)

        // Cancel progressive fetch — waste of budget when user wants specific content
        progressiveFetchTask?.cancel()
        coverageMiningTask?.cancel()
        // Cancel any previous urgent fetch
        urgentFetchTask?.cancel()
        isUrgentFetching = false

        if isEditingFilters {
            // The sheet owns only selection state. Feed/DB/network work begins
            // once, after dismissal, so rapid taps remain purely interactive.
            filterDebounceTask?.cancel()
            pendingFilterReloadGeneration = generation
        } else {
            scheduleFilterReload(generation: generation, delay: .milliseconds(300))
        }
        restartActiveSearchIfNeeded()
    }

    private func immediatelyCullVisibleItemsForActiveFilter() {
        // Refresh taxonomy URL cache so the cull respects the just-updated
        // nodeIDs — setFilter changes activeNodeIDs but the cache is only
        // rebuilt lazily by applyFilters / scheduleFilterReload.
        refreshCachedTaxonomyFeedURLsIfNeeded()

        let region = activeRegion
        let languages = activeLanguages
        let contentType = filterContentType
        let mood = activeMood
        let taxonomyURLs = cachedTaxonomyFeedURLs
        let contentFilters = activeContentFiltersForFilterPass().filters
        let deviceLanguage = Self.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        )

        // Invalidate mood cache when mood changes so the cull predicate
        // re-evaluates mood matches rather than serving stale cache entries.
        invalidateMoodMatchCacheIfNeeded(mood)

        let filterPredicate: (FeedItem) -> Bool = { [self] item in
            (region == nil || item.region == region || item.region.hasPrefix(region! + "/"))
            && Self.languageFilterMatchesNormalized(
                itemLanguage: item.language,
                selectedLanguages: languages,
                deviceLanguage: deviceLanguage
            )
            && contentType(item)
            && (mood == .all || mood.matches(item.title))
            && (taxonomyURLs.isEmpty || taxonomyURLs.contains(OPMLParser.normalizeURL(item.sourceURL)))
            && (contentFilters.isEmpty || !contentFilterExcludes(item, filters: contentFilters))
        }
        if !visibleItems.isEmpty {
            setVisibleItems(visibleItems.filter(filterPredicate))
        }
        // The What's New carousel renders above the main feed. Its items were
        // collected under the previous filter and must be culled immediately
        // so an English card doesn't flash at the top after switching to Swedish.
        if !whatsNewManager.whatsNewItems.isEmpty {
            whatsNewManager.replaceItems(
                whatsNewManager.whatsNewItems.filter(filterPredicate)
            )
        }
    }

    /// Culls only the What's New carousel items for the active filter,
    /// without touching main feed visible items. Used during filter changes
    /// where the main feed is cleared entirely (via feedDisplayPhase) but
    /// the What's New surface still needs immediate filter alignment.
    private func cullWhatsNewForActiveFilter() {
        refreshCachedTaxonomyFeedURLsIfNeeded()

        let region = activeRegion
        let languages = activeLanguages
        let contentType = filterContentType
        let mood = activeMood
        let taxonomyURLs = cachedTaxonomyFeedURLs
        let contentFilters = activeContentFiltersForFilterPass().filters
        let deviceLanguage = Self.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        )

        invalidateMoodMatchCacheIfNeeded(mood)

        let filterPredicate: (FeedItem) -> Bool = { [self] item in
            (region == nil || item.region == region || item.region.hasPrefix(region! + "/"))
            && Self.languageFilterMatchesNormalized(
                itemLanguage: item.language,
                selectedLanguages: languages,
                deviceLanguage: deviceLanguage
            )
            && contentType(item)
            && (mood == .all || mood.matches(item.title))
            && (taxonomyURLs.isEmpty || taxonomyURLs.contains(OPMLParser.normalizeURL(item.sourceURL)))
            && (contentFilters.isEmpty || !contentFilterExcludes(item, filters: contentFilters))
        }

        if !whatsNewManager.whatsNewItems.isEmpty {
            whatsNewManager.replaceItems(
                whatsNewManager.whatsNewItems.filter(filterPredicate)
            )
        }
    }

    func beginFilterEditing() {
        isEditingFilters = true
    }

    func endFilterEditing() {
        isEditingFilters = false
        if let generation = pendingFilterReloadGeneration {
            pendingFilterReloadGeneration = nil
            // Flush any items that accumulated during editing BEFORE the
            // reload so the reservoir starts clean. Without this, items
            // fetched under a now-stale language filter can enter the
            // reservoir after the reload and leak through to the feed.
            if !pendingReservoirItems.isEmpty {
                Task { [weak self] in
                    await self?.flushPendingReservoir()
                    guard let self else { return }
                    self.scheduleFilterReload(generation: generation, delay: .zero)
                }
                return
            }
            scheduleFilterReload(generation: generation, delay: .zero)
        } else if !pendingReservoirItems.isEmpty {
            Task { [weak self] in
                await self?.flushPendingReservoir()
            }
        }
        if searchNeedsRestartAfterFilterEditing {
            searchNeedsRestartAfterFilterEditing = false
            restartActiveSearchIfNeeded()
        }
    }

    private func scheduleFilterReload(generation: Int64, delay: Duration) {
        filterDebounceTask?.cancel()
        let capturedPreset = activePreset
        let capturedPresetGen = presetGeneration
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  generation == self.filterGeneration else { return }

            self.refreshCachedTaxonomyFeedURLsIfNeeded()
            let priorityURLs = self.cachedTaxonomyFeedURLs
            display.setLoadingState(.refreshing)
            self.refreshWhatsNew(shouldBoost: false)

            // When a collection preset is active, the generic reloadFromSQLite
            // path (global candidate windows, 30-day cutoff, is_read exclusion)
            // can miss retained external-source items that the collection's
            // exact-URL query finds instantly. Route through the collection-
            // aware hydration path instead so the allowlist contract holds
            // across filter changes.
            if case .collection(let cid, _) = capturedPreset,
               capturedPreset == self.activePreset,
               capturedPresetGen == self.presetGeneration {
                do {
                    try await self.hydrateCollectionPresetFromCache(collectionID: cid)
                } catch {
                    Log.feed.error("collection filter reload failed: \(error)")
                }
                // Optionally refresh the same members from the network so the
                // feed stays current after a filter change. Skip when the
                // last network fetch is recent and we have enough visible
                // items — the cache hydration alone is sufficient.
                let shouldNetworkRefresh: Bool
                if let last = lastRefreshDate {
                    shouldNetworkRefresh = Date().timeIntervalSince(last) > 900 || visibleItems.count < 10
                } else {
                    shouldNetworkRefresh = true
                }
                if self.usesPersistentStorage, shouldNetworkRefresh {
                    self.progressiveFetchTask?.cancel()
                    self.progressiveFetchTask = Task { [weak self] in
                        guard let self else { return }
                        await self.loadCollectionPresetFeed(
                            collectionID: cid,
                            expectedPreset: capturedPreset,
                            expectedGeneration: capturedPresetGen
                        )
                    }
                }
                return
            }
            if capturedPreset.isLastClicked,
               capturedPreset == self.activePreset,
               capturedPresetGen == self.presetGeneration {
                await self.loadLastClickedFeed()
                return
            }
            if let smartFeedID = capturedPreset.smartFeedID,
               capturedPreset == self.activePreset,
               capturedPresetGen == self.presetGeneration {
                await self.loadSmartFeedFeed(id: smartFeedID)
                return
            }

            // Render the matching local cache before dispatching network work.
            // Besides making a saved feed react immediately, this prevents a
            // slow source probe from competing with the first filtered frame.
            let reloadFromCacheBeforeUrgentFetch = !priorityURLs.isEmpty
            self.applyUpdate(.flush(
                skipNetworkFetch: reloadFromCacheBeforeUrgentFetch,
                generation: generation
            ))
            let reloadTask = self.pipelineTask

            // In-memory stores are test/preview sandboxes. Their filtered
            // pipeline must stay local and deterministic instead of leaving
            // network tasks alive after an XCTest has released the store.
            if !priorityURLs.isEmpty, self.usesPersistentStorage {
                self.isUrgentFetching = true
                self.urgentFetchTask = Task { [weak self] in
                    await reloadTask?.value
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    await self.fetchUrgentTaxonomyBatch(sourceURLs: priorityURLs, generation: generation)
                    self.isUrgentFetching = false
                    self.startBackgroundRefresh()
                }
            }
        }
    }

    // MARK: - Language Buffer

    /// Save visible items keyed by language set so switching back is instant.
    /// Max 2 language slots; LRU eviction on overflow.
    private func saveLanguageBuffer(items: [FeedItem], for languages: Set<String>) {
        let key = languages.sorted().joined(separator: ",")
        guard !key.isEmpty, !items.isEmpty else { return }
        languageItemBuffer[key] = items
        languageBufferOrder.removeAll { $0 == key }
        languageBufferOrder.append(key)
        if languageBufferOrder.count > 2 {
            if let oldest = languageBufferOrder.first {
                languageItemBuffer.removeValue(forKey: oldest)
                languageBufferOrder.removeFirst()
            }
        }
    }

    /// Restore buffered items for a language set, if available.
    private func restoreLanguageBuffer(for languages: Set<String>) -> [FeedItem]? {
        let key = languages.sorted().joined(separator: ",")
        guard !key.isEmpty else { return nil }
        return languageItemBuffer[key]
    }

    func clearAllFilters() {
        filterGeneration &+= 1
        _ = display.advanceEpoch(mode: currentMode, filterGeneration: filterGeneration, presetGeneration: presetGeneration)
        let generation = filterGeneration

        activeRegion = nil
        activeNodeIDs = []
        activeContentType = .all
        activeMood = .all
        activeLanguages = []
        hasUserClearedLanguageFilter = true
        cachedTaxonomyNodeIDs = []
        cachedTaxonomyShape = -1
        cachedTaxonomyFeedURLs = []
        scheduleFilterPersistence(generation: generation)

        progressiveFetchTask?.cancel()
        coverageMiningTask?.cancel()
        urgentFetchTask?.cancel()
        isUrgentFetching = false

        if isEditingFilters {
            filterDebounceTask?.cancel()
            pendingFilterReloadGeneration = generation
            if isSearching {
                searchNeedsRestartAfterFilterEditing = true
            }
        } else {
            scheduleFilterReload(generation: generation, delay: .milliseconds(100))
            restartActiveSearchIfNeeded()
        }
    }

    // MARK: - Search

    /// Installs the canonical content index the local search reads, or removes it.
    ///
    /// Called by the composition of a launch whose runtime owns acquisition (`v2Full`) and by its
    /// teardown; never in `legacy`, `mirroredShadow` or `v2Presentation`, where nothing admits into a
    /// runtime database and the legacy `feed_item_fts` over `feedmine.sqlite` remains the index with
    /// content in it (plan §14 PR-14 clause two). The store does not decide the mode: it is handed the
    /// read path the composition authorized, so the search cannot disagree with the producer.
    func useCanonicalContentSearch(_ source: CanonicalContentSearch?) {
        searchEngine.canonicalContentSearch = source
    }

    func search(
        _ query: String,
        includeSources: Bool = true,
        includeContents: Bool = true,
        demandOnlineContent: Bool
    ) {
        search(
            SearchExpression(legacyQuery: query),
            includeSources: includeSources,
            includeContents: includeContents,
            demandOnlineContent: demandOnlineContent
        )
    }

    func search(
        _ expression: SearchExpression,
        includeSources: Bool = true,
        includeContents: Bool = true,
        demandOnlineContent: Bool
    ) {
        searchTask?.cancel()
        isSearching = true
        isSearchLoading = true
        isSearchScanning = false
        searchScannedSourceCount = 0
        searchTotalSourceCount = 0
        searchDiscoveredItemCount = 0
        searchFailedSourceCount = 0
        searchScanCompleted = false
        searchGeneration &+= 1
        let generation = searchGeneration
        activeSearchExpression = expression
        activeSearchIncludesSources = includeSources
        activeSearchIncludesContents = includeContents
        activeSearchDemandsOnlineContent = demandOnlineContent
        guard expression.canSearch else {
            unifiedSearchResults = .empty
            isSearchLoading = false
            return
        }
        // A submitted search is direct user intent. Keep its local query and
        // live source sweep at the highest practical structured-task priority
        // until the search is changed or closed.
        searchTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.refreshUnifiedSearchResults(
                expression: expression,
                includeSources: includeSources,
                includeContents: includeContents,
                generation: generation
            )
            guard !Task.isCancelled,
                  self.isSearching,
                  generation == self.searchGeneration else { return }
            // Source-only search is satisfied by the complete catalog index.
            // The local content search is the canonical FTS; the online sweep is a
            // separate, explicit demand and never an implicit effect of it.
            guard demandOnlineContent, includeContents, self.usesPersistentStorage else { return }
            await self.runRemoteSearchSweep(
                expression: expression,
                includeSources: includeSources,
                includeContents: includeContents,
                generation: generation
            )
        }
    }

    private func refreshUnifiedSearchResults(
        expression: SearchExpression,
        includeSources: Bool,
        includeContents: Bool,
        generation: UInt64
    ) async {
        let rawResults = await searchEngine.unifiedSearch(
            expression,
            includeSources: includeSources,
            includeContents: includeContents
        )
        guard !Task.isCancelled,
              isSearching,
              generation == searchGeneration else { return }
        unifiedSearchResults = UnifiedSearchResults(
            sources: rawResults.sources.filter(sourceMatchesActiveSearchFilters),
            savedItems: applyFilters(rawResults.savedItems, includeConsumed: true),
            localItems: applyFilters(rawResults.localItems, includeConsumed: true)
        )
        isSearchLoading = false
    }

    private func runRemoteSearchSweep(
        expression: SearchExpression,
        includeSources: Bool,
        includeContents: Bool,
        generation: UInt64
    ) async {
        isSearchScanning = true
        defer {
            if generation == searchGeneration {
                isSearchScanning = false
                searchScanCompleted = searchTotalSourceCount > 0
                    && searchScannedSourceCount >= searchTotalSourceCount
            }
        }

        var sources = await sourcesEligibleForActiveSearch()
        guard !Task.isCancelled,
              isSearching,
              generation == searchGeneration else { return }

        let immediatePriorityURLs = Set(
            unifiedSearchResults.sources.map {
                OPMLParser.normalizeURL($0.feedURL)
            }
            + (unifiedSearchResults.savedItems + unifiedSearchResults.localItems).map {
                OPMLParser.normalizeURL($0.sourceURL)
            }
        )
        sources.sort { lhs, rhs in
            let lhsPriority = immediatePriorityURLs.contains(
                OPMLParser.normalizeURL(lhs.url)
            )
            let rhsPriority = immediatePriorityURLs.contains(
                OPMLParser.normalizeURL(rhs.url)
            )
            if lhsPriority != rhsPriority { return lhsPriority }
            return (scheduler.lastFetchedAt[lhs.url] ?? .distantPast)
                < (scheduler.lastFetchedAt[rhs.url] ?? .distantPast)
        }
        searchTotalSourceCount = sources.count
        guard !sources.isEmpty else {
            searchScanCompleted = true
            return
        }

        let batchSize = 32
        for start in stride(from: 0, to: sources.count, by: batchSize) {
            guard !Task.isCancelled,
                  isSearching,
                  generation == searchGeneration else { return }
            let chunk = Array(sources[start..<min(start + batchSize, sources.count)])
            // P3/P8: the sweep leads only what no other producer is already refilling; a chunk with nothing
            // left to lead still advances the scan cursor so the progress denominator cannot stall.
            let grant = claimSourceDemand(chunk.map(\.url), purpose: .searchSweep)
            let grantedURLs = Set(grant.led)
            let grantedChunk = chunk.filter {
                grantedURLs.contains(OPMLParser.normalizeURL($0.url))
            }
            guard !grantedChunk.isEmpty else {
                searchScannedSourceCount = min(
                    searchTotalSourceCount,
                    searchScannedSourceCount + chunk.count
                )
                continue
            }
            let result = await fetcher.fetchAll(
                grantedChunk,
                maxConcurrent: min(16, chunk.count)
            )
            finishSourceDemand(grant, outcomes: result.sourceOutcomes)
            guard !Task.isCancelled,
                  isSearching,
                  generation == searchGeneration else { return }

            let itemCounts = Dictionary(
                grouping: result.items,
                by: { OPMLParser.normalizeURL($0.sourceURL) }
            ).mapValues(\.count)
            var healthEntries: [(url: String, itemCount: Int?)] = []
            for source in grantedChunk {
                let status = result.sourceOutcomes[source.url] ?? .failed(URLError(.unknown))
                scheduler.recordFetch(
                    sourceURL: source.url,
                    outcome: status
                )
                healthEntries.append((
                    source.url,
                    itemCounts[OPMLParser.normalizeURL(source.url)]
                ))
            }
            saveSourceHealthBatch(healthEntries)

            totalFetched += result.items.count
            fetchErrorCount += result.failedSourceCount
            emptyFeedCount += result.emptySourceCount
            searchFailedSourceCount += result.failedSourceCount

            let actualNew = await persistFetchedItems(result.items)
            guard !Task.isCancelled,
                  isSearching,
                  generation == searchGeneration else { return }
            if !actualNew.isEmpty {
                searchDiscoveredItemCount += actualNew.count
                collectWhatsNewCandidates(actualNew)
                await matchPersistentSearches(actualNew)
                await capSourceItemsBatch(Array(Set(actualNew.map(\.sourceURL))))
            }
            searchScannedSourceCount = min(
                searchTotalSourceCount,
                searchScannedSourceCount + chunk.count
            )

            await refreshUnifiedSearchResults(
                expression: expression,
                includeSources: includeSources,
                includeContents: includeContents,
                generation: generation
            )
        }
    }

    /// Complete endpoint set for a live content search. This is intentionally
    /// independent from `feed_item`: a source remains eligible even when none
    /// of its content has reached the local database yet.
    func sourcesEligibleForActiveSearch() async -> [FeedSource] {
        refreshCachedTaxonomyFeedURLsIfNeeded()
        let lookup = registry.lookupSnapshot()
        let sourcePool: [FeedSource]

        if let collectionID = activePreset.collectionID {
            let members = (try? await sourceCollectionStore.members(
                collectionID: collectionID
            )) ?? []
            sourcePool = members.map { member in
                registry.source(forURL: member.sourceURL)
                    ?? sourceReference(for: member).feedSource
            }
        } else if !activeNodeIDs.isEmpty {
            sourcePool = cachedTaxonomyFeedURLs.compactMap { url in
                guard !lookup.explicitlyDisabledURLs.contains(url) else {
                    return nil
                }
                return lookup.sourcesByNormalizedURL[url]
            }
        } else if activeContentType != .all {
            sourcePool = lookup.sourcesByNormalizedURL.compactMap { url, source in
                lookup.explicitlyDisabledURLs.contains(url) ? nil : source
            }
        } else {
            sourcePool = registry.enabledSources
        }

        var seenURLs = Set<String>()
        return sourcePool.filter { source in
            let normalizedURL = OPMLParser.normalizeURL(source.url)
            guard seenURLs.insert(normalizedURL).inserted else { return false }
            if activePreset.isLastClicked,
               !clickedSourceURLs.contains(normalizedURL) {
                return false
            }
            if activePreset.isSmartFeed,
               !activeSmartFeedSourceURLs.contains(normalizedURL) {
                return false
            }
            if let sourceFilter = presetSourceFilter,
               !sourceFilter.contains(normalizedURL) {
                return false
            }
            if let region = activeRegion,
               source.region != region,
               !source.region.hasPrefix(region + "/") {
                return false
            }
            if !activeLanguages.isEmpty,
               let language = Self.normalizedLanguageCode(source.language),
               !activeLanguages.contains(language) {
                return false
            }
            if !activeNodeIDs.isEmpty,
               !cachedTaxonomyFeedURLs.contains(normalizedURL) {
                return false
            }
            return sourceMatches(source, contentType: activeContentType)
        }
    }

    private func sourceMatchesActiveSearchFilters(_ result: SourceSearchResult) -> Bool {
        let normalizedURL = OPMLParser.normalizeURL(result.feedURL)
        if activePreset.isSmartFeed, !activeSmartFeedSourceURLs.contains(normalizedURL) {
            return false
        }
        if activePreset.isLastClicked, !clickedSourceURLs.contains(normalizedURL) {
            return false
        }
        if let sourceFilter = presetSourceFilter, !sourceFilter.contains(normalizedURL) {
            return false
        }

        let registered = registry.source(forURL: normalizedURL)
        if let region = activeRegion {
            guard let sourceRegion = registered?.region,
                  sourceRegion == region || sourceRegion.hasPrefix(region + "/")
            else { return false }
        }
        if !activeNodeIDs.isEmpty {
            refreshCachedTaxonomyFeedURLsIfNeeded()
            guard cachedTaxonomyFeedURLs.contains(normalizedURL) else { return false }
        }
        if !activeLanguages.isEmpty {
            let language = Self.normalizedLanguageCode(result.language ?? registered?.language)
            guard language.map({ activeLanguages.contains($0) }) == true else { return false }
        }
        let mediaKind = registered?.mediaKind ?? result.mediaKind
        switch activeContentType {
        case .all: break
        case .text: guard mediaKind == .text else { return false }
        case .video: guard mediaKind == .video else { return false }
        case .audio: guard mediaKind == .audio else { return false }
        case .forum: guard mediaKind == .forum else { return false }
        }
        return true
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isSearchLoading = false
        isSearchScanning = false
        searchScannedSourceCount = 0
        searchTotalSourceCount = 0
        searchDiscoveredItemCount = 0
        searchFailedSourceCount = 0
        searchScanCompleted = false
        activeSearchExpression = .empty
        activeSearchDemandsOnlineContent = false
        searchGeneration &+= 1
        unifiedSearchResults = .empty
    }

    func cancelSearchScan() {
        guard isSearchScanning else { return }
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isSearchLoading = false
        isSearchScanning = false
        searchScanCompleted = false
    }

    private func restartActiveSearchIfNeeded() {
        guard isSearching, activeSearchExpression.canSearch else { return }
        if isEditingFilters {
            searchTask?.cancel()
            searchTask = nil
            isSearchLoading = false
            isSearchScanning = false
            searchNeedsRestartAfterFilterEditing = true
            return
        }
        search(
            activeSearchExpression,
            includeSources: activeSearchIncludesSources,
            includeContents: activeSearchIncludesContents,
            demandOnlineContent: activeSearchDemandsOnlineContent
        )
    }

    // MARK: - Read & Seen

    /// Mark items as surfaced (appeared on screen in feed or What's New carousel).
    /// Tracked continuously so we know what the user has already seen.
    func markSurfaced(_ items: [FeedItem]) {
        for item in items { surfacedItemIDs.insert(item.id) }
    }

    func markAsSeen(_ itemID: String) {
        guard consumedItemIDs.insert(itemID).inserted else { return }
        reservoir.readItemIDs = consumedItemIDs
        let now = Int(Date().timeIntervalSince1970)
        Task {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE feed_item SET consumed_at = COALESCE(consumed_at, ?) WHERE id = ?",
                    arguments: [now, itemID]
                )
            }
        }
    }

    func markAsRead(_ itemID: String) {
        readItemIDs.insert(itemID)
        consumedItemIDs.insert(itemID)
        reservoir.readItemIDs = consumedItemIDs
        // Update stamped item in-place so only this card re-renders.
        // Do NOT bump visibleItemsGeneration — read-state must not invalidate caches.
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            display.mutateVisibleItem(at: idx) { $0.isRead = true }
        }
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item
                    SET is_read = 1, consumed_at = COALESCE(consumed_at, ?)
                    WHERE id = ?
                """, arguments: [Int(Date().timeIntervalSince1970), itemID])
            }
        }
    }

    func markAsClicked(_ itemID: String) {
        let wasAlreadyClicked = clickedItemIDs.contains(itemID)
        let clickedItem = visibleItems.first(where: { $0.id == itemID })
        readItemIDs.insert(itemID)
        consumedItemIDs.insert(itemID)
        clickedItemIDs.insert(itemID)
        reservoir.readItemIDs = consumedItemIDs
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            display.mutateVisibleItem(at: idx) { $0.isRead = true }
        }
        let now = Int(Date().timeIntervalSince1970)
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item
                    SET is_read = 1, opened_at = ?, clicked_at = ?,
                        consumed_at = COALESCE(consumed_at, ?)
                    WHERE id = ?
                """, arguments: [now, now, now, itemID])
            }
            if let sourceURL: String = try? await db.read({ db in
                try String.fetchOne(
                    db,
                    sql: "SELECT source_url FROM feed_item WHERE id = ?",
                    arguments: [itemID]
                )
            }) {
                clickedSourceURLs.insert(OPMLParser.normalizeURL(sourceURL))
            }
            if activePreset.isLastClicked {
                await loadLastClickedFeed()
            }
            if !wasAlreadyClicked, let clickedItem {
                await learnCuratedPreference(from: clickedItem)
            }
        }
    }

    private func learnCuratedPreference(from item: FeedItem) async {
        guard let curatedID = activePreset.curatedFeedID,
              let source = registry.source(forURL: item.sourceURL),
              let feed = try? await curatedFeedStore.curatedFeed(id: curatedID),
              feed.definition.learningEnabled else {
            return
        }
        let learned = CuratedPreferenceEngine.applyingExplicitOpen(
            item: item,
            source: source,
            to: feed.definition
        )
        guard learned != feed.definition else { return }
        // Persist the updated definition WITHOUT triggering a feed refresh.
        // updateCuratedFeed calls scheduleSourceEnablementRefresh which would
        // reload the feed while the user is reading — violating the rule that
        // opening content must never interfere with the feed.
        try? await curatedFeedStore.update(
            id: feed.id,
            name: feed.name,
            definition: learned
        )
    }

    /// Bulk mark-as-read — single UPDATE with WHERE id IN (...) instead of
    /// N individual writes. Same pattern as shakeToRefresh.
    func markAllAsRead(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            readItemIDs.insert(id)
            consumedItemIDs.insert(id)
        }
        reservoir.readItemIDs = consumedItemIDs
        // Update stamped items in-place — do NOT bump visibleItemsGeneration.
        let idSet = Set(ids)
        for idx in visibleItems.indices where idSet.contains(visibleItems[idx].id) {
            display.mutateVisibleItem(at: idx) { $0.isRead = true }
        }
        let now = Int(Date().timeIntervalSince1970)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        Task {
            try await db.write { db in
                try db.execute(sql: """
                    UPDATE feed_item SET is_read = 1,
                        consumed_at = COALESCE(consumed_at, \(now))
                    WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            }
        }
    }

    func markAsUnread(_ itemID: String) {
        readItemIDs.remove(itemID)
        reservoir.readItemIDs = consumedItemIDs
        // Update stamped item in-place — symmetric with markAsRead/markAllAsRead.
        // Do NOT bump visibleItemsGeneration: read-state must not invalidate
        // caches. The view re-renders this card from the item struct change
        // without needing a generation bump.
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            display.mutateVisibleItem(at: idx) { $0.isRead = false }
        }
        Task {
            try await db.write { db in
                // `consumed_at` intentionally remains: unread changes the
                // visual read state but never requeues an already seen card.
                try db.execute(sql: "UPDATE feed_item SET is_read = 0 WHERE id = ?", arguments: [itemID])
            }
        }
    }

    func clearReadHistory() {
        readItemIDs.removeAll()
        clickedItemIDs.removeAll()
        clickedSourceURLs.removeAll()
        reservoir.readItemIDs = consumedItemIDs
        if activePreset.isLastClicked {
            reservoir.clear()
            setVisibleItems([], settlesPhase: false)
        }
        Task {
            try await db.write { db in
                try db.execute(sql: "UPDATE feed_item SET is_read = 0, opened_at = NULL, clicked_at = NULL")
            }
        }
    }

    func clearAllBookmarks() {
        bookmarkStore.clearAllBookmarks()
        bookmarkedItemIDs.removeAll()
    }

    // MARK: - Source health

    /// Last fetch date for a source URL.
    func lastFetchDate(for sourceURL: String) -> Date? {
        scheduler.lastFetchedAt[sourceURL]
    }

    func toggleSource(_ sourceURL: String) {
        let wasEnabled = registry.isSourceEnabled(sourceURL)
        registry.toggleSource(sourceURL)
        if !wasEnabled {
            // Enabling a single feed — fetch it immediately
            if let source = registry.sources.first(where: { $0.url == sourceURL }) {
                // Same pattern as setRegionEnabled: hold a reference so a
                // rapid toggle can cancel the in-flight enable, and guard on
                // filterGeneration so stale fetches never publish results
                // after a filter/preset change.
                let generation = filterGeneration
                sourceToggleTask?.cancel()
                sourceToggleTask = Task { [weak self] in
                    guard let self else { return }
                    let result = await fetcher.fetchAll([source], maxConcurrent: 1)
                    let actualNew = await persistFetchedItems(result.items)
                    guard !Task.isCancelled, !actualNew.isEmpty else { return }
                    collectWhatsNewCandidates(actualNew)
                    // Prepend to visible feed
                    var combined = actualNew
                    combined.append(contentsOf: reservoir.visibleItems)
                    // Inputs collected here, so this is the composition to carry.
                    // The filter generation alone cannot prove the composition:
                    // a preset change bumps presetGeneration and the epoch without
                    // touching it, and `applyUpdate(.replace())` validates nothing
                    // itself.
                    let ctx = display.activePresentationContext
                    let interleaved = await reservoir.computeSeed(
                        items: combined, presetMultipliers: presetMultipliers
                    )
                    guard !Task.isCancelled,
                          generation == filterGeneration,
                          ctx.epoch == self.presentationEpoch else { return }
                    reservoir.commitSeed(interleaved, presetMultipliers: presetMultipliers)
                    applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
                    reservoirCount = reservoir.reservoirCount
                }
            }
        } else {
            // Disabling — remove only this feed's items, not its whole region.
            sourceToggleTask?.cancel()
            reservoir.removeSource(sourceURL)
            applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
            reservoirCount = reservoir.reservoirCount
        }
    }

    func isCategoryEnabled(_ category: String) -> Bool {
        registry.status(of: SourceRegistry.categoryKey(category)) != .off
    }

    func toggleCategory(_ category: String) {
        setCategoryEnabled(category, enabled: registry.status(of: SourceRegistry.categoryKey(category)) == .off)
    }

    func setCategoryEnabled(_ category: String, enabled: Bool) {
        registry.setCategoryEnabled(category, enabled: enabled)
        scheduleSourceEnablementRefresh()
    }

    /// Resets all source toggles to default (enabled). Used by "Reset All Data".
    func resetAllSourceToggles() {
        registry.resetAllToggles()
        scheduleSourceEnablementRefresh()
    }

    // MARK: - Preset management

    /// Change the active feed preset. Rebuilds the scoring multiplier dictionary
    /// and triggers a feed reload so the new ordering takes effect.
    /// For collection presets, eagerly fetches all member content (same as
    /// "Open Collection Feed") and seeds the main feed with results.
    func setPreset(_ preset: PresetSelector) {
        guard preset != activePreset else { return }
        activePreset = preset
        Settings.activePreset = preset
        // Update presentation mode for the new preset
        switch preset {
        case .collection(let id, _): currentMode = .collection(id)
        case .smartFeed: break  // Set when feed loads
        case .lastClicked: currentMode = .lastClicked
        default: currentMode = .main
        }
        if !preset.isSmartFeed {
            activeSmartFeedItemIDs = []
            activeSmartFeedSourceURLs = []
        }
        presetGeneration &+= 1
        let (oldContext, newContext) = display.advanceEpoch(
            mode: currentMode,
            filterGeneration: filterGeneration,
            presetGeneration: presetGeneration
        )
        if usePreparedPipeline {
            Task { [weak self] in
                guard let self else { return }
                await self.runwayController.stop(context: oldContext)
                await self.runwayController.start(context: newContext)
            }
        }
        let capturedGeneration = presetGeneration
        resetWhatsNewBaseline()

        // Cancel every task that can publish or clear content under the old
        // preset. Cancellation alone is not sufficient (a task may have already
        // passed its last suspension point), so every downstream site also
        // validates preset + generation before mutating shared state.
        presetRebuildTask?.cancel()
        sourceEnablementRefreshTask?.cancel()
        progressiveFetchTask?.cancel()
        coverageMiningTask?.cancel()
        backgroundRefreshTask?.cancel()
        filterDebounceTask?.cancel()
        startSmartFeedMaintenance(initialDelay: preset.isSmartFeed ? 5 : 30)

        presetRebuildTask = Task { [weak self] in
            guard let self else { return }
            await self.rebuildPresetMultipliers(for: preset)
            guard !Task.isCancelled, self.activePreset == preset,
                  self.presetGeneration == capturedGeneration else { return }
            self.restartActiveSearchIfNeeded()

            if let smartFeedID = preset.smartFeedID {
                await self.loadSmartFeedFeed(id: smartFeedID)
            } else if preset.isLastClicked {
                await self.loadLastClickedFeed()
            } else if case .collection(let collectionID, _) = preset {
                await self.loadCollectionPresetFeed(
                    collectionID: collectionID,
                    expectedPreset: preset,
                    expectedGeneration: capturedGeneration
                )
            } else {
                self.scheduleSourceEnablementRefresh(
                    expectedPreset: preset,
                    generation: capturedGeneration
                )
            }
        }
    }

    /// Fire-and-forget variant that captures the current preset and generation.
    /// Used only when the caller has already validated externally or the
    /// generation guard is not needed.
    private func loadCollectionPresetFeed(
        collectionID: Int64
    ) async {
        await loadCollectionPresetFeed(
            collectionID: collectionID,
            expectedPreset: activePreset,
            expectedGeneration: presetGeneration
        )
    }

    /// Display retained collection content immediately, then refresh every
    /// member and reseed the same reservoir with the merged result.
    /// Always validates that the preset and generation have not changed,
    /// so stale tasks cannot mutate shared state.
    private func loadCollectionPresetFeed(
        collectionID: Int64,
        expectedPreset: PresetSelector,
        expectedGeneration: Int64
    ) async {
        do {
            // Validate before mutating shared state — cancellation alone is not
            // sufficient because the task may have passed its last suspension.
            guard activePreset == expectedPreset && presetGeneration == expectedGeneration
            else { return }

            display.setLoadingState(.refreshing)
            defer {
                if activePreset == expectedPreset && presetGeneration == expectedGeneration {
                    display.setLoadingState(.idle)
                    display.setIsPreparingInitialRunway(false)
                    // Settle the phase on every exit path — without this,
                    // a collection preset that fails or returns nothing
                    // leaves the phase at .preparing forever (infinite
                    // "Loading your feed...").
                    if display.visibleItems.isEmpty {
                        display.setFeedDisplayPhase(.empty(contextID: presentationEpoch))
                    } else {
                        display.setFeedDisplayPhase(.ready(contextID: presentationEpoch))
                    }
                }
            }

            try await hydrateCollectionPresetFromCache(collectionID: collectionID)
            guard !Task.isCancelled else { return }

            let result = try await loadSourceCollectionContent(collectionID: collectionID)
            guard !Task.isCancelled,
                  case .collection(let currentID, _) = activePreset,
                  currentID == collectionID else { return }
            // Re-validate generation before publishing; a newer preset may have
            // been selected while the network fetch was in flight.
            guard activePreset == expectedPreset && presetGeneration == expectedGeneration
            else { return }
            await publishCollectionPresetItems(result.items, collectionID: collectionID)
            lastRefreshDate = .now
        } catch {
            Log.feed.error("collection preset load failed: \(error)")
        }
    }

    /// Read only the collection's retained rows. This is the fast startup path:
    /// no catalog-wide candidate scan and no network dependency before first paint.
    private func hydrateCollectionPresetFromCache(collectionID: Int64) async throws {
        let members = try await sourceCollectionStore.members(collectionID: collectionID)
        let items = await cachedSourceItems(
            sourceURLs: members.map(\.sourceURL),
            limit: 1_000
        )
        guard !Task.isCancelled else { return }
        await publishCollectionPresetItems(items, collectionID: collectionID)
    }

    /// Collection items still use the normal filters and Reservoir interleave;
    /// membership merely replaces global source enablement as the allowlist.
    private func publishCollectionPresetItems(_ items: [FeedItem], collectionID: Int64) async {
        // Identity for this operation is the collection plus the filter
        // generation the items were filtered with — deliberately NOT the epoch:
        // applying a preset is re-entrant (a round trip back to the same
        // collection bumps the epoch, and a discarded editorial flush can bump it
        // again while this operation is still the right one). A *filter* change
        // mid-await is what would make these items stale, and
        // `applyUpdate(.replace())` validates nothing itself.
        guard case .collection(let currentID, _) = activePreset,
              currentID == collectionID else { return }
        let filterGenerationAtStart = filterGeneration
        let filteredItems = applyFilters(items, includeConsumed: false)
        let interleaved = await reservoir.computeSeed(
            items: filteredItems, presetMultipliers: presetMultipliers
        )
        guard !Task.isCancelled,
              filterGenerationAtStart == filterGeneration,
              case .collection(let latestID, _) = activePreset,
              latestID == collectionID else {
            Log.feed.info("""
                [PresetTrace] collection seed dropped: cancelled=\(Task.isCancelled) \
                filterGen \(filterGenerationAtStart)→\(self.filterGeneration) \
                collection \(collectionID)→\(String(describing: self.activePreset))
                """)
            return
        }
        reservoir.commitSeed(interleaved, presetMultipliers: presetMultipliers)
        applyUpdate(.replace(reservoir.visibleItems))
        reservoirCount = reservoir.reservoirCount
    }

    /// Fixed history feed ordered by actual content taps, newest first.
    /// Visibility-only impressions never write `clicked_at`.
    private func loadLastClickedFeed() async {
        let records: [FeedItemRecord] = (try? await db.read { db in
            try FeedItemRecord.fetchAll(db, sql: """
                SELECT * FROM feed_item
                WHERE clicked_at IS NOT NULL
                ORDER BY clicked_at DESC, id
                LIMIT 1000
                """)
        }) ?? []
        guard activePreset.isLastClicked else { return }
        currentMode = .lastClicked
        reservoir.clear()
        reservoirCount = 0
        setVisibleItems(applyFilters(records.map { $0.toFeedItem() }))
        display.setLoadingState(.idle)
    }

    /// Rebuild the `presetMultipliers` dictionary from the current preset
    /// and enabled sources. Called on preset change and source registry reload.
    /// - Parameter expectedPreset: The preset this rebuild was dispatched for.
    ///   If `activePreset` no longer matches, the result is discarded to prevent
    ///   a stale write from a cancelled/overwritten task.
    func rebuildPresetMultipliers(for expectedPreset: PresetSelector? = nil) async {
        let targetPreset = expectedPreset ?? activePreset
        switch targetPreset {
        case .collection(let collectionID, _):
            // Resolve collection member URLs — this is an EXCLUSIVE allowlist,
            // not a scoring boost. Only these sources are fetched and shown.
            let members = (try? await sourceCollectionStore.members(collectionID: collectionID)) ?? []
            if Task.isCancelled || activePreset != targetPreset { return }

            // If the collection was deleted, fall back to Everything.
            if members.isEmpty {
                let allCollections = (try? await sourceCollectionStore.allCollections()) ?? []
                if !allCollections.contains(where: { $0.id == collectionID }) {
                    activePreset = .everything
                    Settings.activePreset = .everything
                    activeCollectionMemberURLs = []
                    presetMultipliers = [:]
                    presetSourceFilter = nil
                    return
                }
            }

            // Build the normalized URL allowlist from both member records and
            // matching registry sources. Normalized because all comparisons
            // (applyFilters, source pool, coverage) normalize at lookup time.
            let normalizedMembers = Set(members.map { OPMLParser.normalizeURL($0.sourceURL) })
            let registryMatches = registry.enabledSources
                .filter { normalizedMembers.contains(OPMLParser.normalizeURL($0.url)) }
                .map { OPMLParser.normalizeURL($0.url) }
            presetSourceFilter = normalizedMembers.union(registryMatches)
            activeCollectionMemberURLs = []  // unused for collections; kept for compatibility
            // Collections use exclusive filtering, not scoring — no multipliers needed
            presetMultipliers = [:]
        case .curatedFeed(let curatedFeedID, _):
            guard let curated = try? await curatedFeedStore.curatedFeed(id: curatedFeedID) else {
                if activePreset == targetPreset {
                    activePreset = .everything
                    Settings.activePreset = .everything
                    presetMultipliers = [:]
                    presetSourceFilter = nil
                }
                return
            }
            if Task.isCancelled || activePreset != targetPreset { return }
            activeCollectionMemberURLs = []
            presetSourceFilter = nil
            activeLanguages = Set(curated.definition.languages)
            hasUserClearedLanguageFilter = false
            persistFilters()
            presetMultipliers = PresetScorer.buildMultipliers(
                preset: targetPreset,
                sources: registry.enabledSources,
                curatedProfile: curated.definition
            )
        default:
            if Task.isCancelled { return }
            activeCollectionMemberURLs = []
            presetSourceFilter = nil
            presetMultipliers = PresetScorer.buildMultipliers(
                preset: targetPreset,
                sources: registry.enabledSources,
                collectionMemberURLs: []
            )
        }
    }

    func setTopicRegionsEnabled(_ enabled: Bool) {
        registry.setTopicRegionsEnabled(enabled)
        resetWhatsNewBaseline()
        scheduleSourceEnablementRefresh()
    }

    func scheduleSourceEnablementRefresh(
        expectedPreset: PresetSelector? = nil,
        generation: Int64 = 0
    ) {
        sourceEnablementRefreshTask?.cancel()
        sourceEnablementRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            // If a newer preset was selected while this task was sleeping,
            // discard — the flush would clear correctly-hydrated content.
            if generation != 0,
               activePreset != expectedPreset || presetGeneration != generation {
                return
            }
            if let smartFeedID = activePreset.smartFeedID {
                await loadSmartFeedFeed(id: smartFeedID)
                return
            }
            // If a collection preset is active, route through the collection-aware
            // path instead of flushing. A generic flush + reloadFromSQLite would
            // miss external-source items and read items.
            if presetSourceFilter != nil,
               case .collection(let cid, _) = activePreset {
                display.setLoadingState(.refreshing)
                refreshWhatsNew(shouldBoost: false)
                // Hydrate from cache for immediate display. Network refresh is
                // optional — only for persistent stores to keep the feed current.
                do {
                    try await hydrateCollectionPresetFromCache(collectionID: cid)
                } catch {
                    Log.feed.error("collection source-enablement refresh hydrate failed: \(error)")
                }
                if usesPersistentStorage {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.loadCollectionPresetFeed(
                            collectionID: cid,
                            expectedPreset: activePreset,
                            expectedGeneration: presetGeneration
                        )
                    }
                }
                return
            }
            display.setLoadingState(.refreshing)
            self.refreshWhatsNew(shouldBoost: false)
            self.applyUpdate(.flush())
        }
    }

    /// Consecutive failures for a source URL.
    func consecutiveFailures(for sourceURL: String) -> Int {
        scheduler.consecutiveFailures[sourceURL] ?? 0
    }

    // MARK: - What's New

    /// Items fetched since the baseline snapshot, respecting all active filters.
    /// Only items with images, unread, capped at 10, shuffled for variety.
    /// Called every time new items are persisted into the database.
    /// Feeds the What's New candidate pool — items accumulate in the
    /// background until the threshold is reached, then the carousel appears.
    func collectWhatsNewCandidates(_ newItems: [FeedItem]) {
        let visibleIDs = Set(reservoir.visibleItems.map(\.id))
        let readIDs = readItemIDs
        whatsNewManager.collectWhatsNewCandidates(
            newItems,
            visibleIDs: visibleIDs,
            readIDs: readIDs,
            matchesActiveFilters: { [self] in !applyFilters([$0]).isEmpty },
            markSurfaced: { [self] in markSurfaced($0) }
        )
    }

    /// Promote candidates to the visible carousel when the pool is full.
    private func promoteWhatsNewIfReady() {
        whatsNewManager.promoteWhatsNewIfReady(markSurfaced: { [self] in markSurfaced($0) })
    }

    /// Advance the carousel: return shown (unclicked) items to the pool so
    /// they remain available for future selections, then promote next batch.
    func advanceWhatsNew() {
        whatsNewManager.advanceWhatsNew(markSurfaced: { [self] in markSurfaced($0) })
    }

    /// Kick off an aggressive fetch to fill the What's New pool quickly at
    /// cold start. Runs alongside the DB seed — if the database has nothing,
    /// this fetches fresh content from the network immediately.
    func fetchWhatsNewBooster() {
        // P2: the booster joins the progressive/bootstrap refill instead of re-requesting enabled endpoints
        // they already hold, and answers from a refill inside the same 15-minute window the showcase uses.
        let enabled = registry.enabledSources
        let grant = claimSourceDemand(
            enabled.map(\.url),
            purpose: .whatsNewBooster,
            freshnessWindowMs: FeedSurfaceCatalog.plan(for: .whatsNew).refillFreshnessWindowMs
        )
        let grantedURLs = Set(grant.led)
        let grantedSources = enabled.filter {
            grantedURLs.contains(OPMLParser.normalizeURL($0.url))
        }
        whatsNewManager.fetchWhatsNewBooster(
            grantedSources: grantedSources,
            fetcher: fetcher,
            finishDemand: { [self] _, batch in
                finishSourceDemand(grant, outcomes: batch.sourceOutcomes)
            },
            persistFetchedItems: { [self] in await persistFetchedItems($0) },
            throttledReservoirAppend: { [self] in throttledReservoirAppend($0) },
            collectCandidates: { [self] in collectWhatsNewCandidates($0) },
            prefetchImages: { [self] in prefetchImagesIfEnabled(for: $0) },
            recordFetch: { [self] in scheduler.recordFetch(sourceURL: $0, outcome: $1) }
        )
    }

    /// Refresh What's New from the local DB. The network booster is reserved
    /// for startup so filter edits never cancel a write already in progress.
    func refreshWhatsNew(shouldBoost: Bool = false) {
        whatsNewManager.refreshWhatsNew(
            seedFromDB: { [self] in await seedWhatsNewFromDB() },
            booster: { [self] in
                if shouldBoost { fetchWhatsNewBooster() }
            }
        )
    }

    /// Seed the pool from existing SQLite content — runs once at startup
    /// so the carousel isn't empty while waiting for the first fetch batch.
    private func seedWhatsNewFromDB() async {
        await whatsNewManager.seedWhatsNewFromDB(
            surfacedIDs: surfacedItemIDs,
            readIDs: readItemIDs,
            matchesActiveFilters: { [self] in !applyFilters([$0]).isEmpty },
            markSurfaced: { [self] in markSurfaced($0) }
        )
    }

    /// Advance the baseline to now and persist it — so items already shown
    /// in the carousel aren't treated as "new" again next session.
    func advanceWhatsNewBaseline() {
        whatsNewManager.advanceWhatsNewBaseline()
    }

    /// Reset the What's New baseline to now so newly enabled content appears.
    /// Items fetched after this point (e.g. seedRegion) will be "new";
    /// weeks-old DB content won't be.
    func resetWhatsNewBaseline() {
        whatsNewManager.resetWhatsNewBaseline()
    }

    // MARK: - Private: fetch

    /// Persist freshly fetched items to SQLite and register them in the
    /// in-memory dedup set, atomically and consistently. Shared by every fetch
    /// path so none can diverge:
    /// - Deduplicates within the batch AND against already-loaded IDs, so two
    ///   feeds returning the same item in one batch can't collide on insert.
    /// - Writes in a single transaction, tolerating individual row failures, so
    ///   one bad/duplicate row can't roll back the whole batch.
    /// - Registers `loadedIDs` only after the write is attempted, so memory
    ///   reflects what was actually stored (no desync on write failure).
    ///
    /// Returns the deduplicated new items for the reservoir / prefetch / search.

    /// Merge incoming items with existing ones by ID.
    /// When an Atom entry has the same id but newer updated date, replace the old.
    func mergeItems(_ incoming: [FeedItem], into existing: [FeedItem]) -> [FeedItem] {
        var merged = Dictionary(grouping: existing + incoming, by: \.id)
            .compactMapValues { items in
                items.max { a, b in
                    let dateA = a.updatedAt ?? a.publishedAt
                    let dateB = b.updatedAt ?? b.publishedAt
                    return (dateA ?? .distantPast) < (dateB ?? .distantPast)
                }
            }
        return Array(merged.values)
    }

    @discardableResult
    func persistFetchedItems(_ items: [FeedItem], regionOverride: String? = nil) async -> [FeedItem] {
        // Existing IDs are normally skipped, but a newer parser may recover
        // artwork that an older build missed. Repair only empty image fields so
        // read state, bookmarks, and other persisted metadata stay untouched.
        let imageRepairs = items.compactMap { item -> (id: String, imageURL: String)? in
            guard loadedIDs.contains(item.id),
                  let imageURL = item.bestImageURL else { return nil }
            return (item.id, imageURL)
        }
        var seen = Set<String>()
        var actualNew: [FeedItem] = []
        var updateCandidates: [FeedItem] = []

        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            if loadedIDs.contains(item.id) {
                updateCandidates.append(item)
            } else {
                actualNew.append(item)
            }
        }

        // For items already in the DB, use mergeItems to determine if the
        // incoming version is newer (Atom entry update-by-ID). Only persist
        // updates when the incoming item has a newer updatedAt/publishedAt.
        var itemsToUpdate: [FeedItem] = []
        if !updateCandidates.isEmpty {
            let candidates = updateCandidates  // let copy for Sendable closure
            do {
                let existingRecords: [FeedItemRecord] = try await db.read { db in
                    try FeedItemRecord.fetchAll(db, keys: candidates.map(\.id))
                }
                let existingItems = existingRecords.map { $0.toFeedItem() }
                let existingByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
                let merged = mergeItems(candidates, into: existingItems)
                for mergedItem in merged {
                    if let existing = existingByID[mergedItem.id] {
                        let mergedDate = mergedItem.updatedAt ?? mergedItem.publishedAt
                        let existingDate = existing.updatedAt ?? existing.publishedAt
                        // Round to whole seconds — the DB stores Int(epoch), so
                        // sub-second differences are truncation artifacts, not
                        // real content updates (e.g. Atom entry refresh).
                        let mergedSec = Int(mergedDate.timeIntervalSince1970)
                        let existingSec = Int(existingDate.timeIntervalSince1970)
                        if mergedSec > existingSec {
                            itemsToUpdate.append(mergedItem)
                        }
                    } else {
                        // Not actually in DB despite being in loadedIDs — treat as new
                        actualNew.append(mergedItem)
                    }
                }
            } catch {
                Log.db.warning("persistFetchedItems: merge error: \(error.localizedDescription)")
                actualNew.append(contentsOf: updateCandidates)
            }
        }

        guard !actualNew.isEmpty || !itemsToUpdate.isEmpty else {
            guard !imageRepairs.isEmpty else { return [] }
            do {
                try await db.write { db in
                    for repair in imageRepairs {
                        try db.execute(
                            sql: "UPDATE feed_item SET image_url = ? WHERE id = ? AND image_url IS NULL",
                            arguments: [repair.imageURL, repair.id]
                        )
                    }
                }
            } catch {
                Log.db.warning("persistFetchedItems: image repair failed: \(error.localizedDescription)")
            }
            return []
        }

        // Combine new items and updates for enrichment
        let allItems = actualNew + itemsToUpdate
        let newCount = actualNew.count

        // Collect regions + explicit source languages on the main actor
        // (dictionary lookups are O(1) and cheap). Language detection via
        // NLLanguageRecognizer runs in a detached task to avoid blocking UI.
        let regions: [String] = allItems.map { regionOverride ?? registry.regionFor(sourceURL: $0.sourceURL) }
        let detectionInputs: [LanguageDetectionInput] = allItems.map { item in
            let itemLang = Self.normalizedLanguageCode(item.language)
            let sourceLang = Self.normalizedLanguageCode(registry.languageFor(sourceURL: item.sourceURL))
            // Item-level language is authoritative; source-level (OPML) can
            // be overridden by detection when content text disagrees.
            return LanguageDetectionInput(
                title: item.title,
                excerpt: item.excerpt,
                explicitLanguage: itemLang ?? sourceLang
            )
        }
        let resolvedLanguages: [String?] = await Task.detached(priority: .utility) {
            Self.detectLanguages(detectionInputs)
        }.value

        // Safety: all three arrays must have identical counts before we merge.
        guard allItems.count == regions.count,
              allItems.count == resolvedLanguages.count else {
            Log.db.error("persistFetchedItems: count mismatch — items=\(allItems.count) regions=\(regions.count) languages=\(resolvedLanguages.count)")
            return []
        }

        // Pre-compute section day offsets once so dateSections doesn't run
        // expensive Calendar operations on every scroll-driven cache miss.
        let now = Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        let sectionOffsets: [Int] = allItems.map { item in
            let itemStart = Calendar.current.startOfDay(for: item.publishedAt)
            let diff = todayStart.timeIntervalSince(itemStart)
            return Int(diff / 86400)  // days
        }

        // Enrich each item with the resolved region, language, normalized
        // sourceURL, and pre-computed section offset so the in-memory
        // representation matches exactly what is written to SQLite.
        let enriched: [FeedItem] = (0..<allItems.count).map { i in
            allItems[i]
                .replacingMetadata(region: regions[i], language: resolvedLanguages[i])
                .withNormalizedSourceURL
                .withSectionDayOffset(sectionOffsets[i])
        }
        let newEnriched = Array(enriched.prefix(newCount))
        let updateEnriched = Array(enriched.suffix(itemsToUpdate.count))

        do {
            // Single batch write. New items are inserted; items that were
            // already in the DB but have a newer updatedAt/publishedAt
            // (Atom entry update-by-ID) are updated via mergeItems.
            let succeeded: [FeedItem] = try await db.write { db -> [FeedItem] in
                for repair in imageRepairs {
                    try db.execute(
                        sql: "UPDATE feed_item SET image_url = ? WHERE id = ? AND image_url IS NULL",
                        arguments: [repair.imageURL, repair.id]
                    )
                }
                var ok: [FeedItem] = []
                // Phase 1: INSERT truly new items
                for item in newEnriched {
                    do {
                        let record = FeedItemRecord(from: item, region: item.region, language: item.language)
                        try record.insert(db)
                        ok.append(item)
                    } catch {
                        // Skip individual row failures. Items are deduplicated in
                        // memory (loadedIDs + batch-internal dedup + mergeItems), so
                        // the only expected failure is a PRIMARY KEY collision from
                        // a concurrent write. One bad row does not roll back the batch.
                        Log.db.warning("persistFetchedItems: skip \(item.id): \(error)")
                    }
                }
                // Phase 2: UPDATE items whose Atom entries were refreshed
                for item in updateEnriched {
                    do {
                        let record = FeedItemRecord(from: item, region: item.region, language: item.language)
                        try record.update(db)
                        ok.append(item)
                    } catch {
                        Log.db.warning("persistFetchedItems: update failed for \(item.id): \(error)")
                    }
                }
                return ok
            }
            for item in succeeded { loadedIDs.insert(item.id) }
            loadedIDsCount = loadedIDs.count

            // Record content filter hits on first ingestion (idempotent)
            if ContentFilterStore.shared.isEnabled {
                let filters = ContentFilterStore.shared.activeFilters
                for item in succeeded {
                    _ = contentFilterExcludesAndRecord(item, filters: filters)
                }
            }

            // Smart Feeds subscribe at the ingestion boundary so every fetch
            // path participates, including imports and explicit source loads.
            await matchSmartFeeds(succeeded)
            // The funnel every persistence path passes through, so the counter cannot under-report:
            // sitting in one caller (`seedRegion`) made the surface show "3 of 12" while the bootstrap
            // had published 57 and the starter ingest had persisted hundreds — the `/100` mistake in a
            // third direction. `startupSeenItemIDs` deduplicates, so counting here is safe.
            // Once a screenful is counted there is nothing left to count, and without this the id set
            // would grow with every ingestion of the session (it runs far less often in its old caller).
            guard startupItemsReady < startupItemsTarget else { return succeeded }
            for item in actualNew where startupSeenItemIDs.insert(item.id).inserted {
                startupItemsReady = min(startupItemsTarget, startupItemsReady + 1)
            }
            return succeeded
        } catch {
            Log.db.error("persist error: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchNextBatch() async {
        // When the user is searching, the feed surface is hidden behind the
        // search UI. Don't waste network fetches that won't be visible, but
        // also don't spin — yield briefly so the cold-start loop's deadline
        // can progress without burning a real attempt.
        guard !isSearching else {
            try? await Task.sleep(nanoseconds: 800_000_000)
            return
        }
        // Don't waste 7–10 seconds on doomed network timeouts when offline.
        // The cold-start loop checks this too, but fetchNextBatch is also
        // called from filter flushes and refresh paths — each must bail fast.
        guard !networkMonitor.isKnownOffline else {
            Log.feed.info("fetchNextBatch skipped: offline")
            return
        }
        let needsStarter = visibleItems.isEmpty && reservoir.reservoirCount == 0
        // The 100-source runway protects the first impression on a fresh app.
        // An empty result after a user changes filters is a different state: it
        // should fetch only compatible sources and publish their first batch.
        let needsInitialRunway = needsStarter && isPreparingInitialRunway
        let visibleSourceCount = Set(visibleItems.map(\.sourceURL)).count
        let needsFilteredRunway = !needsInitialRunway
            && activeContentType != .all
            && visibleSourceCount < Self.immediateFilteredSourceTarget
        refreshCachedTaxonomyFeedURLsIfNeeded()
        var sourcePool: [FeedSource]
        if activeContentType == .all {
            sourcePool = registry.enabledSources
        } else {
            // A top-level type is an explicit catalogue query, not a request
            // limited to the small default global-source subset.
            sourcePool = await coverageSources(
                for: activeContentType,
                languages: activeLanguages,
                region: nil,
                taxonomyURLs: nil
            )
        }
        // Collection presets: exclusive allowlist — only fetch member sources
        if let filter = presetSourceFilter {
            sourcePool = sourcePool.filter { filter.contains(OPMLParser.normalizeURL($0.url)) }
        }
        let sourcesByRegion = await Task.detached(priority: .userInitiated) {
            Dictionary(grouping: sourcePool, by: \.region)
        }.value
        let contentTypeStr: String? = switch activeContentType {
        case .video: "video"; case .audio: "audio"; case .text: "text"
        case .forum: "forum"; default: nil
        }
        let batch = scheduler.nextBatch(
            reservoir: reservoir.reservoir,
            sourcesByRegion: sourcesByRegion,
            activeRegion: activeRegion,
            activeCategory: nil,
            activeContentType: contentTypeStr,
            prioritySourceURLs: activeNodeIDs.isEmpty ? [] : cachedTaxonomyFeedURLs,
            activeLanguages: activeLanguages,
            minimumBatchSize: needsInitialRunway
                ? Self.coldStartCatalogSourceCount
                : (needsFilteredRunway ? 120 : 24),
            presetMultipliers: presetMultipliers
        )
        guard !batch.isEmpty else { return }
        let coldStartTargetSourceCount = min(
            Self.coldStartMinimumSourceCount,
            Set(batch.map(\.url)).count
        )

        display.setLoadingState(needsInitialRunway ? .initial : .refreshing)
        defer {
            display.setLoadingState(isPreparingInitialRunway && visibleItems.isEmpty ? .initial : .idle)
        }

        // The `all`-filter path produced no log line at all (`[Latency]` fires only when
        // `needsFilteredBreadth`), which is why two attributions for its 0-card combo were guesses. Log
        // the branch and the timing for every fetch, filter or not.
        let branchStart = ContinuousClock().now
        defer {
            let ms = Int((ContinuousClock().now - branchStart).components.seconds * 1000
                + (ContinuousClock().now - branchStart).components.attoseconds / 1_000_000_000_000_000)
            Log.feed.info("[Latency] fetch branch=\(self.activeContentType == .all ? (needsInitialRunway ? "cold" : "general") : "filtered") type=\(String(describing: self.activeContentType)) runway=\(needsInitialRunway) filtered=\(needsFilteredRunway) branchMs=\(ms) items=\(self.visibleItems.count)")
        }
        let result: FeedFetchBatch
        if needsInitialRunway {
            result = await fetchColdStartRunway(from: batch)
            Log.feed.info("starterFetch completed: sources=\(result.fetchedSourceCount) items=\(result.items.count) attempted=\(result.sourceOutcomes.count)")
        } else if needsFilteredRunway {
            let neededSources = max(1, Self.immediateFilteredSourceTarget - visibleSourceCount)
            // What the reader needs is a *screen*, not twelve successful publishers. Demanding the
            // full source target made the wait as long as the slowest sources in the batch and left no
            // margin: the deadline was 8 s, exactly the budget the filter acceptance test asserts, so
            // reload + preparation + publication had to fit in whatever the fetch left. One successful
            // source that yields a screenful is the honest stopping condition.
            // Count items of the type being asked for, and keep a source floor: a screenful from one
            // channel is thin, and a screenful of the *wrong* type is an empty filtered page. This
            // branch is the one a type filter reaches (generation != 0), not `fetchColdStartRunway`.
            let relevantOnPage = activeContentType == .all
                ? visibleItems.count
                : visibleItems.filter { activeContentType.matches($0) }.count
            let neededItemsForScreen = max(Self.coldStartImmediateItemCount, Self.coldStartImmediateItemCount - relevantOnPage)
            // Not 6 for a typed filter. Demanding six successful publishers means a slow batch never
            // satisfies the source criterion, the 2.5 s deadline fires and cancels the requests still in
            // flight — measured: audio pass 1 returned 0 items at 3.846 s (deadline + drain) and the very
            // next round brought 20 in 3.450 s, i.e. two network rounds for a typed filter with no local
            // content. The item criterion drives the return; the source floor only keeps the page from
            // being one channel.
            let neededPageSources = 3
            result = await fetcher.fetchStarter(
                batch,
                maxConcurrent: min(30, batch.count),
                minimumSuccessfulSources: min(neededPageSources, batch.count),
                minimumItemCount: neededItemsForScreen,
                // Twice the measured round-trip, not less than it: at 2.5 s the deadline fired and
                // cancelled requests still in flight — audio pass 1 returned 0 items at 3.846 s (deadline
                // plus drain) while the very next round brought 20 in 3.450 s, so a typed filter with no
                // local content paid two network rounds. A bound shorter than the answers it waits for is
                // not a bound, it is a cancel.
                deadline: .seconds(4)
            )
        } else {
            // Reverted: this is the *breadth* path (fetch/refresh without an active type), and a bounded
            // `fetchStarter` here cancels the rest in flight — the same `cancelAll` that drains up to 48
            // requests. That traded breadth for speed exactly as the podcast combo punished, and the
            // matrix acceptance (≥1 card in 8 s) cannot tell a thin page from a full one. Keep the whole
            // `fetchAll`; if first paint must not wait for it, do not await it (below), never shrink it.
            result = await fetcher.fetchAll(batch, maxConcurrent: 15)
        }
        // Yield to let pending UI work through after network I/O returns
        await Task.yield()

        // Drain per-source response times so future batches are speed-sorted.
        let responseTimes = await fetcher.drainResponseTimes()
        for (url, ms) in responseTimes {
            scheduler.recordResponseTime(sourceURL: url, milliseconds: ms)
        }

        totalFetched += result.items.count
        if result.failedSourceCount == 0 { fetchErrorCount = 0 }
        else { fetchErrorCount += result.failedSourceCount }
        lastFetchSucceeded = result.failedSourceCount == 0
        emptyFeedCount += result.emptySourceCount

        // Record per-source health in batch — count items once, look up O(1)
        let sourceItemCounts = Dictionary(grouping: result.items, by: \.sourceURL)
            .mapValues(\.count)
        var healthEntries: [(url: String, itemCount: Int?)] = []
        for source in batch {
            guard let status = result.sourceOutcomes[source.url] else { continue }
            scheduler.recordFetch(sourceURL: source.url, outcome: status)
            let count = sourceItemCounts[source.url]
            healthEntries.append((source.url, count))
        }
        saveSourceHealthBatch(healthEntries)

        let itemsToPersist: [FeedItem]
        if needsInitialRunway {
            coldStartPendingItems.append(contentsOf: result.items)
            let usefulSourceCount = Set(coldStartPendingItems.map(\.sourceURL)).count
            // Review P0.3: the publish trigger is a **complete page**, not a screenful. Publishing at twelve items is
            // what produced `Loading → partial → better` — a page that grows under a reader who already started
            // scrolling. The 100-source diversity target stays a *background* fill goal; the page-sized breadth gate is
            // what the user actually waits for, and until it is met the loading surface keeps reporting progress
            // (measured before this change: `starterIngest withheld: sources=63/100 items=990/100` — 990 fetched items
            // held back while the progress surface counted sources instead of content).
            guard Self.coldStartRunwayIsUseful(
                coldStartPendingItems,
                targetSourceCount: coldStartTargetSourceCount
            ) || Self.coldStartPageIsReady(coldStartPendingItems) else {
                Log.feed.info(
                    "starterIngest withheld: sources=\(usefulSourceCount)/\(coldStartTargetSourceCount) items=\(self.coldStartPendingItems.count) pageReady=\(Self.coldStartPageIsReady(self.coldStartPendingItems) ? 1 : 0)"
                )
                return
            }
            itemsToPersist = coldStartPendingItems
            coldStartPendingItems = []
        } else {
            itemsToPersist = result.items
        }

        let ingestStartedAt = Date()
        let actualNew = await persistInSlices(itemsToPersist)
        if needsInitialRunway {
            Log.feed.info("starterIngest persisted: items=\(actualNew.count) elapsed=\(Date().timeIntervalSince(ingestStartedAt), format: .fixed(precision: 3))s")
        }
        guard !actualNew.isEmpty else { return }

        // Yield again after heavy DB work before processing results
        await Task.yield()

        // Feed the What's New reactive pipeline
        collectWhatsNewCandidates(actualNew)

        // Diagnostic (opt-in via debug bar): surface non-English items so a
        // mis-languaged feed can be identified. See loop-focus-areas #5.
        if Settings.showDebugBar {
            logNonEnglishItems(actualNew)
        }

        // Warm-up image resolution/prefetch (no-ops when prepared pipeline is active).
        resolveArticleImagesInBackground(actualNew)
        prefetchImagesIfEnabled(for: actualNew)

        // Append to the reservoir via the batched off-main interleave path.
        throttledReservoirAppend(actualNew)
        // A cold feed or a nearly depleted runway cannot wait for the normal
        // three-second coalescing interval. Commit this batch now so the first
        // page appears immediately and fast scrolling always has content ahead.
        if visibleItems.isEmpty || reservoir.reservoirCount < Reservoir.reservoirLowWatermark {
            await flushPendingReservoir()
        }
        if needsInitialRunway {
            display.setIsPreparingInitialRunway(false)
            startupRunwayReady = true
            Log.feed.info("starterIngest published: visible=\(self.visibleItems.count) reservoir=\(self.reservoir.reservoirCount) elapsed=\(Date().timeIntervalSince(ingestStartedAt), format: .fixed(precision: 3))s")
        }

        // Database retention is maintenance, not a prerequisite for showing
        // content. Run it after publication so it never extends first paint.
        let sourceURLs = Array(Set(actualNew.map(\.sourceURL)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.capSourceItemsBatch(sourceURLs)
        }

        lastRefreshDate = .now

        // Check persistent searches
        await matchPersistentSearches(actualNew)
    }

    /// Debug diagnostic: logs items whose detected language isn't English,
    /// with source/region/url, so a mis-languaged feed can be spotted at
    /// runtime (loop-focus-areas #5). Gated behind the debug bar — no effect on
    /// the feed itself.
    private func logNonEnglishItems(_ items: [FeedItem]) {
        let recognizer = NLLanguageRecognizer()
        for item in items {
            let text = (item.title + " " + item.excerpt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 12 else { continue }  // too short to detect reliably
            recognizer.reset()
            recognizer.processString(text)
            guard let lang = recognizer.dominantLanguage, lang != .english else { continue }
            let region = registry.regionFor(sourceURL: item.sourceURL)
            Log.feed.debug("[LangCheck] \(lang.rawValue) source=\"\(item.sourceTitle)\" region=\(region) url=\(item.url)")
        }
    }

    /// Urgent fetch for the current taxonomy selection. Runs immediately when
    /// the user changes filters so the taxonomy-curated feed populates quickly
    /// instead of waiting for the next progressive or background refresh cycle.
    private func fetchUrgentTaxonomyBatch(sourceURLs: Set<String>, generation: Int64) async {
        // Drop if a newer filter was applied while this task was queued
        guard generation == self.filterGeneration else {
            Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) dropping stale before start (current=\(self.filterGeneration))")
            return
        }

        // Resolve taxonomy URLs against ALL registered sources, not just
        // enabledSources. An explicit taxonomy selection acts as a temporary
        // catalogue query — category/region disables are bypassed, but
        // individual per-source opt-outs are respected.
        let lookup = registry.lookupSnapshot()
        let languages = activeLanguages
        let typeRawValue = activeContentType.rawValue
        let region = activeRegion
        let allMatching = await Task.detached(priority: .userInitiated) {
            sourceURLs.compactMap { lookup.sourcesByNormalizedURL[$0] }
        }.value
        let individuallyDisabled = await Task.detached(priority: .utility) {
            allMatching.filter {
                lookup.explicitlyDisabledURLs.contains(OPMLParser.normalizeURL($0.url))
            }
        }.value
        let eligible = await Task.detached(priority: .userInitiated) {
            allMatching.filter { source in
                let normalizedURL = OPMLParser.normalizeURL(source.url)
                return !lookup.explicitlyDisabledURLs.contains(normalizedURL)
                    && Self.coverageSourceMatches(
                        source,
                        typeRawValue: typeRawValue,
                        languages: languages,
                        region: region
                    )
            }
        }.value
        let enabledSnapshot = registry.enabledSources
        let normallyEnabledCount = await Task.detached(priority: .utility) {
            let enabledURLs = Set(enabledSnapshot.map { OPMLParser.normalizeURL($0.url) })
            return eligible.reduce(into: 0) { count, source in
                if enabledURLs.contains(OPMLParser.normalizeURL(source.url)) { count += 1 }
            }
        }.value

        // [TaxonomyTrace] — detailed diagnostic for the 4 Acoustics feeds
        Log.feed.info("""
            [TaxonomyTrace] urgentFetch gen=\(generation): \
            taxonomyURLs=\(sourceURLs.count) \
            allMatching=\(allMatching.count) \
            normallyEnabled=\(normallyEnabledCount) \
            eligible=\(eligible.count) \
            individuallyDisabled=\(individuallyDisabled.count)
            """)
        for src in allMatching.prefix(20) {
            Log.feed.info("[TaxonomyTrace] source: title=\"\(src.title)\" url=\(src.url) enabled=\(self.registry.isSourceEnabled(src.url)) explicitOff=\(self.registry.isSourceExplicitlyDisabled(src.url))")
        }

        // Always define both progress values together, before any early return,
        // so stale totals from a previous fetch can never leak into the UI.
        emptyStateFetchTotal = eligible.count
        emptyStateFetchedCount = 0
        guard !eligible.isEmpty else {
            Log.feed.warning("[TaxonomyTrace] urgentFetch gen=\(generation): \(sourceURLs.count) taxonomy URLs matched 0 eligible sources (allMatching=\(allMatching.count), individuallyDisabled=\(individuallyDisabled.count))")
            return
        }

        // Check again before expensive network work
        guard generation == self.filterGeneration else {
            Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) dropping stale before fetch (current=\(self.filterGeneration))")
            return
        }

        let result = await fetcher.fetchAll(eligible, maxConcurrent: 15)
        emptyStateFetchedCount = result.sourceOutcomes.count

        // Log per-source fetch results
        for (url, status) in result.sourceOutcomes {
            let itemCount = result.items.filter { OPMLParser.normalizeURL($0.sourceURL) == OPMLParser.normalizeURL(url) }.count
            Log.feed.info("[TaxonomyTrace] fetchResult url=\(url) status=\(String(describing: status)) items=\(itemCount)")
        }

        // Final generation check before mutating state
        guard generation == self.filterGeneration else {
            Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) dropping stale after fetch (current=\(self.filterGeneration))")
            return
        }

        let actualNew = await persistFetchedItems(result.items)
        let filteredCount = self.applyFilters(actualNew).count
        Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation): fetched=\(result.items.count) persisted=\(actualNew.count) afterFilters=\(filteredCount)")

        // Bypass throttling: the user is waiting for taxonomy-filtered items.
        // Flush synchronously so items are committed to the reservoir BEFORE
        // the .refresh pipeline runs — the refresh must see the new items.
        prefetchImagesIfEnabled(for: actualNew)
        pendingReservoirItems.append(contentsOf: actualNew)
        reservoirFlushTask?.cancel()
        await flushPendingReservoir()

        // Now that the flush is complete, refresh to move items into visible.
        // The refresh is serialized behind the pipeline task, and the flush
        // is already done, so items are guaranteed to be in the reservoir.
        if !actualNew.isEmpty {
            applyUpdate(.refresh(generation: generation))
        }

        collectWhatsNewCandidates(actualNew)
        Log.feed.info("[TaxonomyTrace] urgentFetch gen=\(generation) DONE visibleItems=\(self.visibleItems.count)")
    }

    // MARK: - Source coverage

    private struct CoveragePlan: Sendable {
        let target: Int
        let representedCount: Int
        let deficit: Int
        let candidates: [FeedSource]
    }

    /// The screen can publish after 20 providers, but collection continues until
    /// a filter has 100 providers that have actually produced persisted items.
    /// A successful HTTP response with zero usable items does not count.
    private func startCoverageMining(generation: Int64) {
        // Collection presets don't need catalog coverage — only member sources
        guard presetSourceFilter == nil else { return }
        coverageMiningTask?.cancel()
        let preferredType = activeContentType
        let languages = activeLanguages
        isCoverageMiningActive = true
        coverageMiningTask = Task(priority: .utility) { [weak self] in
            defer { self?.isCoverageMiningActive = false }
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, generation == self.filterGeneration else { return }

            while self.isUrgentFetching, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, generation == self.filterGeneration else { return }

            if preferredType != .all {
                let activeSources = await self.coverageSources(
                    for: preferredType,
                    languages: languages,
                    region: self.activeRegion,
                    taxonomyURLs: self.activeNodeIDs.isEmpty ? nil : self.cachedTaxonomyFeedURLs
                )
                // The active filter owns the runway. Keep taking bounded passes
                // until 100 useful providers are represented; switching filters
                // cancels this task immediately through the generation guard.
                for pass in 1...6 {
                    guard !Task.isCancelled, generation == self.filterGeneration else { return }
                    let started = await self.mineCoverage(
                        sources: activeSources,
                        label: "active-\(preferredType.rawValue)-p\(pass)",
                        deadline: .seconds(20),
                        publish: true
                    )
                    guard started else { break }
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }

            let topTypes: [FeedLoader.ContentType] = [.video, .audio, .forum, .text]
            for type in topTypes where type != preferredType {
                guard !Task.isCancelled, generation == self.filterGeneration else { return }
                let sources = await self.coverageSources(
                    for: type,
                    languages: languages,
                    region: nil,
                    taxonomyURLs: nil
                )
                _ = await self.mineCoverage(
                    sources: sources,
                    label: "top-\(type.rawValue)",
                    deadline: .seconds(12),
                    publish: false
                )
                try? await Task.sleep(for: .milliseconds(750))
            }

            // Make visible progress across the catalogue on every session. The
            // slow refresh continues rotating through the remaining categories.
            for _ in 0..<6 {
                guard !Task.isCancelled, generation == self.filterGeneration else { return }
                guard await self.mineNextTaxonomyCoverage(languages: languages) else { break }
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func coverageSources(
        for type: FeedLoader.ContentType,
        languages: Set<String>,
        region: String?,
        taxonomyURLs: Set<String>?
    ) async -> [FeedSource] {
        let typeRawValue = type.rawValue
        let sourceSnapshot: [FeedSource]
        if let taxonomyURLs {
            let lookup = registry.lookupSnapshot()
            sourceSnapshot = await Task.detached(priority: .utility) {
                taxonomyURLs.compactMap { url in
                    guard !lookup.explicitlyDisabledURLs.contains(url) else { return nil }
                    return lookup.sourcesByNormalizedURL[url]
                }
            }.value
        } else if type == .all {
            sourceSnapshot = registry.enabledSources
        } else {
            // Top-level media filters query the complete catalogue. Inherited
            // category/region disables are bypassed, while an explicit source
            // opt-out remains absolute.
            let lookup = registry.lookupSnapshot()
            sourceSnapshot = await Task.detached(priority: .utility) {
                lookup.sourcesByNormalizedURL.compactMap { url, source in
                    lookup.explicitlyDisabledURLs.contains(url) ? nil : source
                }
            }.value
        }
        let matches = await Task.detached(priority: .utility) {
            sourceSnapshot.filter { source in
                Self.coverageSourceMatches(
                    source,
                    typeRawValue: typeRawValue,
                    languages: languages,
                    region: region
                )
            }
        }.value
        // Collection presets: exclusive allowlist — only mine member sources
        if let filter = presetSourceFilter {
            return matches.filter { filter.contains(OPMLParser.normalizeURL($0.url)) }
        }
        return matches
    }

    nonisolated private static func coverageSourceMatches(
        _ source: FeedSource,
        typeRawValue: String,
        languages: Set<String>,
        region: String?
    ) -> Bool {
        if let region,
           source.region != region,
           !source.region.hasPrefix(region + "/") { return false }
        if !languages.isEmpty,
           let language = normalizedLanguageCode(source.language),
           !languages.contains(language) { return false }
        switch typeRawValue {
        case "Videos":
            return source.isYouTube || source.mediaKind == .video
        case "Podcasts":
            return source.mediaKind == .audio
        case "Forums":
            return source.mediaKind == .forum
        case "Articles":
            return !source.isYouTube && source.mediaKind == .text
        default:
            return true
        }
    }

    private func storedSourceURLs() async -> Set<String> {
        let urls = (try? await db.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT source_url FROM feed_item")
        }) ?? []
        return Set(urls.map(OPMLParser.normalizeURL))
    }

    /// Returns true when a network coverage pass was started.
    @discardableResult
    private func mineCoverage(
        sources: [FeedSource],
        label: String,
        deadline: Duration,
        publish: Bool
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let stored = await storedSourceURLs()
        let plan = await Task.detached(priority: .utility) {
            Self.makeCoveragePlan(sources: sources, stored: stored)
        }.value
        guard plan.target > 0 else { return false }
        guard plan.deficit > 0 else {
            Log.feed.info("coverage \(label): ready \(plan.representedCount)/\(plan.target) useful sources")
            return false
        }
        let candidates = plan.candidates
        guard !candidates.isEmpty else { return false }

        // Sort coverage candidates by preset multiplier so quality sources
        // are mined into the database before lower-priority ones.
        let mults = presetMultipliers
        let orderedCandidates = candidates.sorted { lhs, rhs in
            (mults[lhs.url] ?? 1.0) > (mults[rhs.url] ?? 1.0)
        }

        Log.feed.info(
            "coverage \(label): mining \(plan.representedCount)/\(plan.target), candidates=\(orderedCandidates.count)"
        )
        let result = await fetcher.fetchStarter(
            orderedCandidates,
            maxConcurrent: min(36, orderedCandidates.count),
            minimumSuccessfulSources: min(plan.deficit, orderedCandidates.count),
            minimumItemCount: min(plan.deficit, orderedCandidates.count),
            deadline: deadline
        )
        guard !Task.isCancelled else { return true }

        let sourceItemCounts = await Task.detached(priority: .utility) {
            Dictionary(grouping: result.items, by: \.sourceURL).mapValues(\.count)
        }.value
        var healthEntries: [(url: String, itemCount: Int?)] = []
        for source in orderedCandidates {
            guard let status = result.sourceOutcomes[source.url] else { continue }
            scheduler.recordFetch(sourceURL: source.url, outcome: status)
            healthEntries.append((source.url, sourceItemCounts[source.url]))
        }
        saveSourceHealthBatch(healthEntries)

        totalFetched += result.items.count
        fetchErrorCount += result.failedSourceCount
        emptyFeedCount += result.emptySourceCount
        let actualNew = await persistFetchedItems(result.items)
        if publish {
            let visibleNew = await presentationItems(from: actualNew)
            if !visibleNew.isEmpty {
                throttledReservoirAppend(visibleNew)
                collectWhatsNewCandidates(visibleNew)
                prefetchImagesIfEnabled(for: visibleNew)
            }
        }
        if !actualNew.isEmpty {
            await capSourceItemsBatch(Array(Set(actualNew.map(\.sourceURL))))
            await matchPersistentSearches(actualNew)
        }

        let newlyUsefulCount = await Task.detached(priority: .utility) {
            Set(result.items.map { OPMLParser.normalizeURL($0.sourceURL) })
                .subtracting(stored).count
        }.value
        let usefulAfter = plan.representedCount + newlyUsefulCount
        Log.feed.info(
            "coverage \(label): \(min(usefulAfter, plan.target))/\(plan.target) useful sources after pass"
        )
        return true
    }

    nonisolated private static func makeCoveragePlan(
        sources: [FeedSource],
        stored: Set<String>
    ) -> CoveragePlan {
        var uniqueSources: [String: FeedSource] = [:]
        uniqueSources.reserveCapacity(sources.count)
        for source in sources {
            let key = OPMLParser.normalizeURL(source.url)
            if uniqueSources[key] == nil { uniqueSources[key] = source }
        }
        let target = min(sourceCoverageTarget, uniqueSources.count)
        let represented = uniqueSources.keys.reduce(into: 0) { count, url in
            if stored.contains(url) { count += 1 }
        }
        let deficit = max(0, target - represented)
        let unfetched = uniqueSources.compactMap { url, source in
            stored.contains(url) ? nil : source
        }
        let limit = min(unfetched.count, max(120, deficit * 4))
        return CoveragePlan(
            target: target,
            representedCount: represented,
            deficit: deficit,
            candidates: Array(unfetched.shuffled().prefix(limit))
        )
    }

    private func presentationItems(from items: [FeedItem]) async -> [FeedItem] {
        guard !items.isEmpty else { return [] }
        var filtered: [FeedItem] = []
        filtered.reserveCapacity(items.count)
        for start in stride(from: 0, to: items.count, by: 80) {
            let end = min(start + 80, items.count)
            filtered.append(contentsOf: applyFilters(Array(items[start..<end])))
            await Task.yield()
        }
        return filtered
    }

    /// Rotates through leaf taxonomy categories. A category with fewer than 100
    /// catalogued feeds is complete when every available feed has produced items.
    private func mineNextTaxonomyCoverage(languages: Set<String>) async -> Bool {
        let groups = TaxonomyStore.shared.coverageGroups
        guard !groups.isEmpty else { return false }
        let lookup = registry.lookupSnapshot()
        let stored = await storedSourceURLs()
        let cursor = taxonomyCoverageCursor
        let next = await Task.detached(priority: .utility) { () -> (Int, String, [FeedSource])? in
            for offset in 0..<groups.count {
                let index = (cursor + offset) % groups.count
                let group = groups[index]
                let sources = group.feedURLs.compactMap { url -> FeedSource? in
                    guard !lookup.explicitlyDisabledURLs.contains(url),
                          let source = lookup.sourcesByNormalizedURL[url] else { return nil }
                    if !languages.isEmpty,
                       let language = Self.normalizedLanguageCode(source.language),
                       !languages.contains(language) { return nil }
                    return source
                }
                let uniqueURLs = Set(sources.map { OPMLParser.normalizeURL($0.url) })
                let target = min(Self.sourceCoverageTarget, uniqueURLs.count)
                guard target > 0, uniqueURLs.intersection(stored).count < target else { continue }
                return (index, group.id, sources)
            }
            return nil
        }.value
        guard let (index, nodeID, sources) = next else { return false }
        taxonomyCoverageCursor = (index + 1) % groups.count
        return await mineCoverage(
            sources: sources,
            label: "category-\(nodeID)",
            deadline: .seconds(10),
            publish: false
        )
    }

    /// Fetch a budgeted batch of remaining enabled sources in the background.
    /// Capped per session to avoid hammering 800+ sources at every launch;
    /// the rest trickle in via normal refresh cycles. Shuffled for fair
    /// distribution across text/video/audio types.
    private func progressiveFetch() async {
        guard !networkMonitor.isKnownOffline else {
            Log.feed.info("progressiveFetch skipped: offline")
            return
        }
        let allEnabled = progressiveFetchSources()
        let budget = allEnabled.count
        let chunkSize = 20
        var processed = 0
        Log.feed.info("progressiveFetch starting: \(budget) filtered/diverse sources")
        for chunkStart in stride(from: 0, to: budget, by: chunkSize) {
            let end = min(chunkStart + chunkSize, budget)
            let chunk = Array(allEnabled[chunkStart..<end])
            processed += chunk.count
            // Gentle 1s inter-chunk delay (skip first) to avoid rate-limiting
            // from YouTube and other aggressive CDNs when processing 800+ sources.
            if chunkStart > 0 { try? await Task.sleep(for: .seconds(1)) }
            // P3: the progressive fill leads only the endpoints no other producer is already refilling.
            let grant = claimSourceDemand(chunk.map(\.url), purpose: .progressiveFetch)
            let grantedURLs = Set(grant.led)
            let grantedChunk = chunk.filter {
                grantedURLs.contains(OPMLParser.normalizeURL($0.url))
            }
            guard !grantedChunk.isEmpty else { continue }
            let result: FeedFetchBatch
            if chunkStart == 0 && reservoir.reservoirCount < Reservoir.reservoirLowWatermark {
                result = await fetcher.fetchStarter(grantedChunk, maxConcurrent: 10)
            } else {
                result = await fetcher.fetchAll(grantedChunk, maxConcurrent: 5)
            }
            finishSourceDemand(grant, outcomes: result.sourceOutcomes)
            guard !Task.isCancelled else { break }
            await Task.yield()  // Let UI work run between chunks
            totalFetched += result.items.count
            fetchErrorCount += result.failedSourceCount
            emptyFeedCount += result.emptySourceCount
            // Batch-save source health with real item counts
            let sourceItemCounts = Dictionary(grouping: result.items, by: \.sourceURL)
                .mapValues(\.count)
            var healthEntries: [(url: String, itemCount: Int?)] = []
            for source in grantedChunk {
                scheduler.recordFetch(sourceURL: source.url, outcome: result.sourceOutcomes[source.url] ?? .failed(URLError(.unknown)))
                let count = sourceItemCounts[source.url]
                healthEntries.append((source.url, count))
            }
            // Record per-source response times so future cold starts can
            // prioritize fast sources (learned ordering).
            let responseTimes = await fetcher.drainResponseTimes()
            for (url, ms) in responseTimes {
                scheduler.recordResponseTime(sourceURL: url, milliseconds: ms)
            }
            saveSourceHealthBatch(healthEntries)
            let actualNew = await persistFetchedItems(result.items)
            prefetchImagesIfEnabled(for: actualNew)
            throttledReservoirAppend(actualNew)
            if reservoir.reservoirCount < Reservoir.progressiveFillTarget {
                await flushPendingReservoir()
            }
            collectWhatsNewCandidates(actualNew)
            // Cap items per source so no single feed dominates (>50 items)
            if !actualNew.isEmpty {
                let sourceURLs = Array(Set(actualNew.map(\.sourceURL)))
                await capSourceItemsBatch(sourceURLs)
            }
            await matchPersistentSearches(actualNew)
            if visibleItems.isEmpty {
                await flushPendingReservoir()
            }
            if reservoir.reservoirCount >= Reservoir.progressiveFillTarget {
                Log.feed.info("progressiveFetch runway ready: reservoir=\(self.reservoir.reservoirCount)")
                break
            }
        }
        Log.feed.info("progressiveFetch DONE — \(processed)/\(allEnabled.count) sources processed")
        lastRefreshDate = .now
        await capAllSources()
    }

    private func progressiveFetchSources() -> [FeedSource] {
        let activeLangs = activeLanguages
        let activeType = activeContentType
        let recentCutoff = Date().addingTimeInterval(-300)
        let sourceFilter = presetSourceFilter
        var candidates = registry.enabledSources.filter { source in
            sourceMatches(source, languages: activeLangs)
                && sourceMatches(source, contentType: activeType)
                && (scheduler.lastFetchedAt[source.url] ?? .distantPast) < recentCutoff
        }
        // Collection presets: exclusive allowlist
        if let filter = sourceFilter {
            candidates = candidates.filter { filter.contains(OPMLParser.normalizeURL($0.url)) }
        }
        let budget = min(candidates.count, 200)  // per-session cap
        // Sort by historical speed: fast sources first so content appears sooner.
        // Falls back to preset-multiplier scoring for sources without timing data.
        let speedSorted = scheduler.sortedBySpeed(candidates)
        let multipliers = presetMultipliers
        let scored = speedSorted.map { source in
            let base = multipliers[source.url] ?? 1.0
            return (source: source, score: base * Double.random(in: 0.98...1.02))
        }
        return AdaptiveScheduler.diverseSources(from: scored, limit: budget)
    }

    private func sourceMatches(_ source: FeedSource, languages: Set<String>) -> Bool {
        guard !languages.isEmpty else { return true }
        let sourceLang = Self.normalizedLanguageCode(
            source.language.flatMap { $0.isEmpty ? nil : $0 }
        )
        guard let sourceLang else { return true }
        return languages.contains(sourceLang)
    }

    private func sourceMatches(_ source: FeedSource, contentType: FeedLoader.ContentType) -> Bool {
        switch contentType {
        case .all:
            return true
        case .text:
            return !source.isYouTube && source.mediaKind != .video
                && source.mediaKind != .audio && source.mediaKind != .forum
        case .video:
            return source.isYouTube || source.mediaKind == .video
        case .audio:
            return source.mediaKind == .audio
        case .forum:
            return source.mediaKind == .forum
        }
    }

    // MARK: - Persistent Smart Feed maintenance

    func setActivityState(_ state: FeedActivityState) {
        activityState = state
        switch state {
        case .active:
            startBackgroundRefresh()
            startSmartFeedMaintenance(initialDelay: 5)
        case .inactive:
            stopBackgroundRefresh()
            smartFeedMaintenanceTask?.cancel()
            smartFeedMaintenanceTask = nil
        case .background:
            stopBackgroundRefresh()
            smartFeedMaintenanceTask?.cancel()
            smartFeedMaintenanceTask = nil
        }
    }

    private func startSmartFeedMaintenance(initialDelay: TimeInterval) {
        guard usesPersistentStorage, hasStarted, activityState == .active else { return }
        smartFeedMaintenanceTask?.cancel()
        smartFeedMaintenanceTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(initialDelay))
            } catch {
                return
            }
            while !Task.isCancelled, self.activityState == .active {
                if self.canRunOpportunisticSmartFeedRefresh {
                    _ = await self.performNextSmartFeedRefresh(mode: .foreground)
                }
                let interval = SmartFeedRefreshPolicy.foregroundWakeInterval(
                    activeSmartFeedID: self.activePreset.smartFeedID
                )
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    private var canRunOpportunisticSmartFeedRefresh: Bool {
        activityState == .active
            && networkMonitor.isConnected
            && loadingState == .idle
            && !isSearching
            && !isPreparingInitialRunway
            && !isUrgentFetching
            && !isEditingFilters
            && !isCoverageMiningActive
            && !isRegularBackgroundFetchActive
    }

    private func performNextSmartFeedRefresh(
        mode: SmartFeedRefreshMode,
        presentWhenActive: Bool = true
    ) async -> Bool? {
        let states: [SmartFeedRefreshState]
        do {
            states = try await smartFeedStore.refreshStates()
        } catch {
            Log.db.error("Smart Feed refresh queue failed: \(error.localizedDescription)")
            return false
        }
        let due = SmartFeedRefreshPolicy.orderedDueStates(
            states,
            activeSmartFeedID: activePreset.smartFeedID,
            mode: mode
        )
        guard let candidate = due.first(where: {
            !smartFeedRefreshesInFlight.contains($0.id)
        }) else { return nil }
        let isActive = candidate.id == activePreset.smartFeedID
        let budget = SmartFeedRefreshPolicy.budget(
            isActivePreset: isActive,
            mode: mode,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        Log.feed.info(
            "Smart Feed maintenance id=\(candidate.id) active=\(isActive) mode=\(String(describing: mode)) sources=\(budget.sourceLimit)"
        )
        return await refreshSmartFeed(
            id: candidate.id,
            sourceLimit: budget.sourceLimit,
            maxConcurrent: budget.maxConcurrent,
            presentWhenActive: presentWhenActive && isActive
        )
    }

    /// Prepares only the catalog structures required to evaluate saved Smart
    /// Feed definitions. Unlike normal startup, this does not start the main
    /// feed runway, image prefetching, catalog updates, or regular refresh.
    func prepareForBackgroundSmartFeedRefresh() async {
        guard usesPersistentStorage else { return }
        if registry.sources.isEmpty {
            await registry.loadFromOPML()
            reservoir.sourceRegionMap = registry.regionMap
        }
        let taxonomyReady = await TaxonomyStore.shared.loadFromCache(
            sources: registry.sources,
            sharedCountrySourceURLs: registry.sharedCountrySourceURLs
        )
        if !taxonomyReady, TaxonomyStore.shared.flatIndex.isEmpty {
            await TaxonomyStore.shared.build(
                from: registry.sources,
                sharedCountrySourceURLs: registry.sharedCountrySourceURLs
            )
        }
        activePreset = Settings.activePreset
    }

    /// One bounded background refresh, on behalf of a `BGAppRefreshTask` (plan §14 PR-15).
    ///
    /// This is the demand the handler used to serve by building `loader ?? FeedLoader()` — a second
    /// `FeedStore`, `RSSFetcher`, OPML parse and taxonomy load for the same work the foreground was
    /// already doing (P9 in the acquisition map). The demand is served by *this* store, through the
    /// same fetcher, the same demand ledger and the same persistence the foreground uses.
    ///
    /// The due Smart Feed presets go first, because they are what the task identifier names; when none
    /// is due the budget is spent on a bounded refill of the enabled set. Both halves claim their
    /// endpoints on `SourceDemandLedger`, so an endpoint another producer already holds issues no
    /// request — which is the pair closing by a count rather than by a comment.
    ///
    /// The claim is released on every exit, including cancellation: endpoints this demand did not
    /// refill become eligible again, the ones it did refill stay fresh, and content it already
    /// committed stays committed.
    func runBackgroundRefreshDemand(_ demand: BackgroundRefreshDemand) async -> BackgroundRefreshDemandReport {
        var report = BackgroundRefreshDemandReport()
        guard demand.isAllowed else { return report }
        // No `usesPersistentStorage` guard: the demand is driven by tests as well as by the system, and
        // an in-memory store serves it through the same ledger, fetcher and persistence. The one thing
        // that does need durable storage is the catalogue preparation below, which guards itself.
        await prepareForBackgroundSmartFeedRefresh()
        guard !registry.sources.isEmpty else { return report }
        guard !Task.isCancelled else {
            report.cancelled = true
            return report
        }

        // Any condition that shrank the demand means one preset rather than two: a background window
        // is short, and a constrained device should spend it on less, not on the same amount twice.
        let maximumFeeds = demand.appliedSignals.isEmpty ? 2 : 1
        var refreshedPreset = false
        for _ in 0..<maximumFeeds {
            guard !Task.isCancelled else {
                report.cancelled = true
                return report
            }
            guard let succeeded = await performNextSmartFeedRefresh(
                mode: .background,
                presentWhenActive: false
            ) else { break }
            refreshedPreset = true
            if succeeded {
                report.smartFeedsRefreshed += 1
            } else {
                report.smartFeedsFailed += 1
            }
        }
        guard !refreshedPreset else { return report }

        await refillEnabledSet(for: demand, into: &report)
        return report
    }

    /// One bounded refill of the enabled set, claimed on the demand ledger and raced against the
    /// demand's own deadline.
    private func refillEnabledSet(
        for demand: BackgroundRefreshDemand,
        into report: inout BackgroundRefreshDemandReport
    ) async {
        let candidates = backgroundRefreshCandidates(limit: demand.sourceLimit)
        guard !candidates.isEmpty else { return }

        // No freshness window: a background refresh wants current bytes, and the ledger's `shared`
        // answer — not recency — is what keeps it from duplicating the foreground.
        let grant = claimSourceDemand(candidates.map(\.url), purpose: .backgroundDrip)
        report.led = grant.led.count
        report.shared = grant.shared.count
        report.servedFresh = grant.servedFresh.count
        guard !grant.led.isEmpty else { return }

        let grantedURLs = Set(grant.led)
        let granted = candidates.filter { grantedURLs.contains(OPMLParser.normalizeURL($0.url)) }
        var outcomes: [String: FeedFetchOutcome] = [:]
        defer {
            // Always: an endpoint whose outcome is a failure is not recorded as fresh, so the next
            // demand retries it, and no claim is left behind by a cancelled run.
            finishSourceDemand(grant, outcomes: outcomes)
        }
        guard !Task.isCancelled else {
            report.cancelled = true
            return
        }

        isRegularBackgroundFetchActive = true
        let fetcher = self.fetcher
        let cap = max(1, demand.maxConcurrency)
        let deadline = demand.deadline
        // Two structured children, so the demand's own cancellation reaches both. The fetch's result is
        // always the answer: a deadline that elapses stops the fetch starting new work and then keeps
        // draining for what it already produced, and a cancellation does the same. Discarding that batch
        // would make "committed then cancelled" indistinguishable from "cancelled before commit".
        enum RefillEvent: Sendable {
            case batch(FeedFetchBatch)
            case deadline
            case cancelled
        }
        var batch: FeedFetchBatch?
        await withTaskGroup(of: RefillEvent.self) { group in
            group.addTask { .batch(await fetcher.fetchAll(granted, maxConcurrent: cap)) }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline)
                    return .deadline
                } catch {
                    return .cancelled
                }
            }
            drain: while let event = await group.next() {
                switch event {
                case .batch(let value):
                    batch = value
                    // `withTaskGroup` awaits the children it is left with but does not cancel them, so
                    // the sleeper would otherwise hold the demand for its full ceiling.
                    group.cancelAll()
                    break drain
                case .deadline:
                    // The demand's own ceiling, not the system's window.
                    group.cancelAll()
                case .cancelled:
                    // The task went away; the fetch is cancelled with it and still reports what it has.
                    break
                }
            }
        }
        isRegularBackgroundFetchActive = false

        if let batch {
            outcomes = batch.sourceOutcomes
            report.attempted = batch.sourceOutcomes.count
            report.failed = batch.failedSourceCount
            for source in granted {
                let outcome = batch.sourceOutcomes[source.url] ?? .failed(URLError(.unknown))
                if !outcome.isFailed { report.committed += 1 }
                scheduler.recordFetch(sourceURL: source.url, outcome: outcome)
            }
            let responseTimes = await fetcher.drainResponseTimes()
            for (url, milliseconds) in responseTimes {
                scheduler.recordResponseTime(sourceURL: url, milliseconds: milliseconds)
            }
            report.newItems = await commitBackgroundItems(batch.items)
        }

        report.cancelled = Task.isCancelled
        if !report.cancelled { lastRefreshDate = .now }
    }

    /// The endpoints one background demand may spend its budget on: the enabled set, least recently
    /// fetched first, so a bounded slice spreads over the catalogue instead of repeating its head.
    private func backgroundRefreshCandidates(limit: Int) -> [FeedSource] {
        let enabled = registry.enabledSources
        guard enabled.count > limit else { return enabled }
        return Array(
            enabled
                .sorted {
                    (scheduler.lastFetchedAt[$0.url] ?? .distantPast)
                        < (scheduler.lastFetchedAt[$1.url] ?? .distantPast)
                }
                .prefix(limit)
        )
    }

    /// Persists what one demand fetched and runs the same downstream steps the drip runs, so a
    /// background commit reaches the reservoir, What's New and the image prefetcher exactly as a
    /// foreground one does. Returns how many items were new to the database.
    private func commitBackgroundItems(_ items: [FeedItem]) async -> Int {
        guard !items.isEmpty else { return 0 }
        let actualNew = await persistFetchedItems(items)
        let visibleNew = await presentationItems(from: actualNew)
        guard !visibleNew.isEmpty else { return actualNew.count }
        throttledReservoirAppend(visibleNew)
        collectWhatsNewCandidates(visibleNew)
        prefetchImagesIfEnabled(for: visibleNew)
        await capSourceItemsBatch(Array(Set(actualNew.map(\.sourceURL))))
        return actualNew.count
    }

    /// Slow-drip background refresh — fetches a small batch of sources every
    /// few minutes to keep the database and What's New fed with fresh content.
    /// Complements progressiveFetch (bulk initial fill) with continuous renewal.
    private func startBackgroundRefresh() {
        // Collection presets use eager loading — skip the slow-drip refresh.
        // The last-clicked feed must also stay click-only: background fetches
        // would seed non-clicked content into it.
        guard activityState == .active,
              presetSourceFilter == nil,
              !activePreset.isSmartFeed,
              !activePreset.isLastClicked else { return }
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            let interval: TimeInterval = 150  // 2.5 minutes
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                guard self.loadingState == .idle, !self.isSearching else { continue }
                guard self.networkMonitor.isConnected else { continue }

                let coverageStep = self.backgroundCoverageCursor
                self.backgroundCoverageCursor &+= 1
                let didMineCoverage: Bool
                if coverageStep.isMultiple(of: 2), !self.isCoverageMiningActive {
                    let types: [FeedLoader.ContentType] = [.video, .audio, .forum, .text]
                    let type = types[(coverageStep / 2) % types.count]
                    // Coverage mining rotates a fixed type order from a session-local cursor that restarts at
                    // group 0 on every launch, so a given type's turn depends on how many passes the session
                    // has had. Logged so "no audio ever arrives" can be told apart from "audio's turn never
                    // came": the latter is ordering/persistence, not the network.
                    Log.feed.info("[Coverage] step=\(coverageStep) type=\(type.rawValue) taxonomyCursor=\(self.taxonomyCoverageCursor)")
                    let sources = await self.coverageSources(
                        for: type,
                        languages: self.activeLanguages,
                        region: nil,
                        taxonomyURLs: nil
                    )
                    didMineCoverage = await self.mineCoverage(
                        sources: sources,
                        label: "refresh-\(type.rawValue)",
                        deadline: .seconds(10),
                        publish: type == self.activeContentType
                    )
                } else if !self.isCoverageMiningActive {
                    didMineCoverage = await self.mineNextTaxonomyCoverage(
                        languages: self.activeLanguages
                    )
                } else {
                    didMineCoverage = false
                }
                if didMineCoverage { continue }

                let batchSize = 5
                let sourceSnapshot = self.registry.enabledSources
                let batch = await Task.detached(priority: .utility) {
                    Array(sourceSnapshot.shuffled().prefix(batchSize))
                }.value
                guard !batch.isEmpty else { continue }
                // P3/P4: the drip joins a refill another producer already holds instead of duplicating it.
                let grant = self.claimSourceDemand(batch.map(\.url), purpose: .backgroundDrip)
                let grantedURLs = Set(grant.led)
                let grantedBatch = batch.filter {
                    grantedURLs.contains(OPMLParser.normalizeURL($0.url))
                }
                guard !grantedBatch.isEmpty else { continue }
                self.isRegularBackgroundFetchActive = true
                let result = await self.fetcher.fetchAll(grantedBatch, maxConcurrent: 2)
                self.isRegularBackgroundFetchActive = false
                self.finishSourceDemand(grant, outcomes: result.sourceOutcomes)
                guard !Task.isCancelled else { break }
                // Drain response times for future speed-sorted batches.
                let bgResponseTimes = await self.fetcher.drainResponseTimes()
                for (url, ms) in bgResponseTimes {
                    self.scheduler.recordResponseTime(sourceURL: url, milliseconds: ms)
                }
                let actualNew = await self.persistFetchedItems(result.items)
                let visibleNew = await self.presentationItems(from: actualNew)
                if !visibleNew.isEmpty {
                    self.throttledReservoirAppend(visibleNew)
                    self.collectWhatsNewCandidates(visibleNew)
                    self.prefetchImagesIfEnabled(for: visibleNew)
                    // Cap per source to prevent domination
                    await self.capSourceItemsBatch(Array(Set(actualNew.map(\.sourceURL))))
                }
                // Record fetch health for each source this pass actually refilled
                for source in grantedBatch {
                    self.scheduler.recordFetch(sourceURL: source.url, outcome: result.sourceOutcomes[source.url] ?? .failed(URLError(.unknown)))
                }
                self.lastRefreshDate = .now
            }
        }
    }

    func stopBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        isRegularBackgroundFetchActive = false
    }

    /// Cap ALL sources in the database at 50 items each. Runs once after
    /// progressiveFetch completes the initial bulk fetch. Uses a single
    /// query to find offenders so we don't scan 855 sources one-by-one.
    private func capAllSources() async {
        do {
            let offenders: [String] = try await db.read { db in
                try String.fetchAll(db, sql: """
                    SELECT source_url FROM feed_item
                    GROUP BY source_url HAVING COUNT(*) > 50
                """)
            }
            guard !offenders.isEmpty else { return }
            Log.db.info("capAllSources: capping \(offenders.count) sources (>50 items)")
            await capSourceItemsBatch(offenders)
        } catch {
            Log.db.error("capAllSources error: \(error.localizedDescription)")
        }
    }

    private func reloadFromSQLite(prepend: [FeedItem] = [], skipRead: Bool = false, generation: Int64 = 0) async {
        guard !isSearching else { return }
        refreshCachedTaxonomyFeedURLsIfNeeded()
        let region = activeRegion
        let contentType = activeContentType
        let languages = activeLanguages
        // Capture taxonomy feed URLs before entering the read closure (which may
        // run off the main actor). When taxonomy is active we load matching
        // items via batched IN clause with per-chunk and global caps.
        let taxonomyURLs: Set<String>? = activeNodeIDs.isEmpty ? nil : cachedTaxonomyFeedURLs
        // Always exclude read items — the feed should only show unseen content.
        // Read/opened items are tracked continuously and this information is
        // consumed by all feed-population paths (shake, filter, startup).
        let items: [FeedItemRecord] = (try? await db.read { db in
            var request = FeedItemRecord
                .filter(Column("fetched_at") > Self.thirtyDayCutoffEpoch)
                .filter(Column("is_read") == 0)
                .filter(Column("consumed_at") == nil)
            if let r = region {
                // Exact match or descendant prefix (e.g. "countries/brazil/sao-paulo")
                // matches both the region itself and its sub-regions, matching the
                // in-memory filter behavior in applyFilters.
                request = request.filter(
                    sql: "region = ? OR region LIKE ?",
                    arguments: [r, "\(r)/%"]
                )
            }
            // Filter by content type at SQL level to avoid loading 200 items
            // only to discard 95% in-memory (e.g. "Podcasts" filter with few
            // podcast items in the DB).
            switch contentType {
            case .audio: request = request.filter(Column("audio_url") != nil)
            case .video: request = request.filter(Column("source_url").like("%youtube%"))
            case .text:  request = request.filter(Column("audio_url") == nil)
                            .filter(!Column("source_url").like("%youtube%"))
                            .filter(!Column("source_url").like("%reddit%"))
            case .forum: request = request.filter(Column("source_url").like("%reddit%"))
            case .all: break
            }

            // Language filter — shared rule with applyFilters.
            // Unknown-language rows do not pass while a language filter is active.
            if !languages.isEmpty {
                let langArray = Array(languages)
                if langArray.count <= 999 {
                    let langPlaceholders = langArray.map { _ in "?" }.joined(separator: ",")
                    request = request.filter(
                        sql: "language IN (\(langPlaceholders))",
                        arguments: StatementArguments(langArray)
                    )
                } else {
                    // Fallback: batch in chunks of 999 (unlikely with real language counts)
                    let batchSize = 999
                    var orParts: [String] = []
                    var allArgs: [String] = []
                    for chunkStart in stride(from: 0, to: langArray.count, by: batchSize) {
                        let chunk = Array(langArray[chunkStart..<min(chunkStart + batchSize, langArray.count)])
                        orParts.append("language IN (\(chunk.map { _ in "?" }.joined(separator: ",")))")
                        allArgs.append(contentsOf: chunk)
                    }
                    request = request.filter(
                        sql: "(\(orParts.joined(separator: " OR ")))",
                        arguments: StatementArguments(allArgs)
                    )
                }
            }

            // Taxonomy filter — batched IN clause to stay within SQLite's
            // 999-parameter limit. When taxonomy is active, load matching items
            // items so the user sees the full curated feed rather than just
            // the 200 most recent items (which may not overlap at all with
            // the selected taxonomy nodes).
            if let urls = taxonomyURLs, !urls.isEmpty {
                let urlArray = Array(urls)
                let batchSize = 999
                let perChunkLimit = 400
                var allItems: [FeedItemRecord] = []
                for chunkStart in stride(from: 0, to: urlArray.count, by: batchSize) {
                    let chunk = Array(urlArray[chunkStart..<min(chunkStart + batchSize, urlArray.count)])
                    // Generate ALL URL variants that could appear in SQLite:
                    // - normalized URL (no trailing slash, no www, https)
                    // - normalized + trailing slash
                    // - www. variant (items stored with original OPML URL
                    //   may have www. that normalizeURL stripped)
                    // - www. variant + trailing slash
                    // - http:// variants for legacy rows stored before
                    //   normalizeURL began forcing https (v1-v5 era)
                    let chunkBoth = chunk.flatMap { url -> [String] in
                        var variants = [url, "\(url)/"]
                        // http:// variants — legacy rows may use http scheme
                        if let comps = URLComponents(string: url),
                           comps.scheme == "https" {
                            var httpComps = comps
                            httpComps.scheme = "http"
                            if let httpURL = httpComps.string {
                                variants.append(httpURL)
                                variants.append("\(httpURL)/")
                            }
                        }
                        // Add www.-prefixed variants if the normalized URL lacks www.
                        if let comps = URLComponents(string: url),
                           let host = comps.host, !host.hasPrefix("www.") {
                            var wwwComps = comps
                            wwwComps.host = "www.\(host)"
                            if let wwwURL = wwwComps.string {
                                variants.append(wwwURL)
                                variants.append("\(wwwURL)/")
                                // Also add http://www... for legacy rows
                                wwwComps.scheme = "http"
                                if let httpWWWURL = wwwComps.string {
                                    variants.append(httpWWWURL)
                                    variants.append("\(httpWWWURL)/")
                                }
                            }
                        }
                        return variants
                    }
                    let placeholders = chunkBoth.map { _ in "?" }.joined(separator: ",")
                    let chunkRequest = request.filter(
                        sql: "source_url IN (\(placeholders))",
                        arguments: StatementArguments(chunkBoth)
                    )
                    let batchItems = try chunkRequest
                        .order(Column("published_at").desc)
                        .limit(perChunkLimit)
                        .fetchAll(db)
                    allItems.append(contentsOf: batchItems)
                }
                // Sort merged batches by published_at desc so the most recent
                // items appear first regardless of which batch they came from.
                allItems.sort { $0.publishedAt > $1.publishedAt }
                // Global cap prevents memory runaway from very broad taxonomy nodes.
                let topN = min(allItems.count, 600)
                return Array(allItems.prefix(topN))
            }

            if contentType == .all {
                // A timestamp-only window can be entirely consumed by prolific
                // article sources. Read bounded media slices independently so
                // a mixed, language-only feed can still surface its videos and
                // podcasts while preserving a large pool of recent articles.
                let illustratedTextItems = try request
                    .filter(Column("audio_url") == nil)
                    .filter(!Column("source_url").like("%youtube%"))
                    .filter(!Column("source_url").like("%reddit%"))
                    .filter(Column("image_url") != nil && Column("image_url") != "")
                    .order(Column("published_at").desc)
                    .limit(Self.illustratedTextCandidateReadLimit)
                    .fetchAll(db)
                let textItems = try request
                    .filter(Column("audio_url") == nil)
                    .filter(!Column("source_url").like("%youtube%"))
                    .filter(!Column("source_url").like("%reddit%"))
                    .filter(Column("image_url") == nil || Column("image_url") == "")
                    .order(Column("published_at").desc)
                    .limit(Self.textCandidateReadLimit - Self.illustratedTextCandidateReadLimit)
                    .fetchAll(db)
                let videoItems = try request
                    .filter(Column("source_url").like("%youtube%"))
                    .order(Column("published_at").desc)
                    .limit(Self.mediaCandidateReadLimit)
                    .fetchAll(db)
                let audioItems = try request
                    .filter(Column("audio_url") != nil)
                    .order(Column("published_at").desc)
                    .limit(Self.mediaCandidateReadLimit)
                    .fetchAll(db)
                let forumItems = try request
                    .filter(Column("source_url").like("%reddit%"))
                    .order(Column("published_at").desc)
                    .limit(Self.forumCandidateReadLimit)
                    .fetchAll(db)
                return illustratedTextItems + textItems + videoItems + audioItems + forumItems
            }

            return try request
                .order(Column("published_at").desc)
                .limit(Self.candidateReadLimit)
                .fetchAll(db)
        }) ?? []
        var feedItems = items.map { $0.toFeedItem() }
        // Prepend seed items at the top so newly enabled region appears first
        if !prepend.isEmpty {
            feedItems = prepend + feedItems
        }
        // Drop stale reload BEFORE mutating loadedIDs — a newer filter may have
        // triggered a more recent pipeline that already seeded fresher data.
        // Only check when generation is explicitly tracked (non-zero).
        if generation != 0, generation != self.filterGeneration {
            Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) dropping stale seed (current=\(self.filterGeneration))")
            return
        }
        // Register all loaded IDs to prevent re-fetch duplicates.
        // Must happen AFTER the stale-generation guard so IDs are only
        // registered when the items are actually used.
        for item in feedItems { loadedIDs.insert(item.id) }
        loadedIDsCount = loadedIDs.count
        // Capture the composition this reload belongs to BEFORE the first
        // suspension, and never re-read it afterwards: a filter change while the
        // filter pass, the seed or the coordinator work is in flight must not hand
        // stale items the new composition's identity. Same guard style as
        // `setVisibleItems`.
        let ctx = display.activePresentationContext
        let filterGenerationAtStart = filterGeneration
        let presetGenerationAtStart = presetGeneration
        // Pre-filter before seeding so the reservoir never holds items that
        // would be filtered out. This prevents the reservoir from becoming a
        // trove of disabled-source items that leak through on .append/.trim
        // (even after Task 1-2 fixes, this avoids wasted memory and ensures
        // consistent reservoirCount).
        //
        // Both steps are pure, and on a full store they walk up to 5,000 candidates
        // through predicates that normalise text and strip HTML — which, done after
        // the SELECT returned, monopolised the main actor (review finding 7). They
        // now run in the off-main pass, whose cache merge-back is gated on the filter
        // generation.
        let filteredItems = await applyFiltersAsync(feedItems)
        let balancedItems = await Task.detached(priority: .userInitiated) {
            Self.balancedCandidatePool(filteredItems)
        }.value
        Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) loaded=\(feedItems.count) filtered=\(filteredItems.count) balanced=\(balancedItems.count) taxonomyURLs=\(taxonomyURLs?.count ?? 0)")
        let interleaved = await reservoir.computeSeed(
            items: balancedItems, presetMultipliers: presetMultipliers
        )
        // The inputs are the filters and the preset this reload read and filtered
        // with — checked as such rather than by epoch, which also counts changes
        // that leave those inputs valid (e.g. re-applying the same composition).
        guard !Task.isCancelled,
              filterGenerationAtStart == filterGeneration,
              presetGenerationAtStart == presetGeneration else {
            Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) dropping stale seed after interleave")
            return
        }
        reservoir.commitSeed(interleaved, presetMultipliers: presetMultipliers)
        // markSurfaced runs on reservoir.visibleItems AFTER commit, so only
        // items that actually appear on screen are recorded as surfaced.
        markSurfaced(reservoir.visibleItems)
        // Install the full editorial sequence into the coordinator in ONE
        // awaited operation. Previously setVisibleItems spawned an async Task
        // that set activeContext, and a subsequent appendEditorialSequence
        // raced against it — the append was often rejected because the
        // coordinator's activeContext hadn't been set yet.
        if usePreparedPipeline {
            // Review P0.5: the editorial order handed to the coordinator is the sequencer's output, and the invariant is
            // asserted right here — at the boundary where a composition becomes the page the reader will get. The
            // Reservoir supplies candidates and its breadth intent; it does not get to publish a run of one provider.
            let editorialItems = EditorialSequencer.sequence(
                reservoir.visibleItems + reservoir.upcomingItems(reservoir.reservoirCount)
            )
            assert(
                EditorialSequencer.isDiversityRespected(editorialItems),
                "published order violates provider diversity: \(EditorialSequencer.consecutiveRunIssues(in: editorialItems))"
            )
            await preparationCoordinator.replaceEditorialSequence(
                editorialItems, context: ctx
            )
            // The coordinator validates the context itself (`context ==
            // activeContext`), and it is called with the captured `ctx` — so a
            // composition change is rejected there, without this store-level guard
            // discarding work whose inputs are still valid.
            guard !Task.isCancelled else { return }
            await preparationCoordinator.fillRunway(
                targetRenderReady: runwayPolicy.initialPublishedCount,
                context: ctx
            )
            guard !Task.isCancelled else { return }
            await runwayController.start(context: ctx)
            await runwayController.evaluate()
            await promotePreparedCards(
                context: ctx,
                isAppend: false,
                maxCount: runwayPolicy.initialPublishedCount
            )
        } else {
            // Legacy pipeline: seed() already moved items to the visible
            // window. Set visibleItems directly from the reservoir's visible
            // items rather than relying on the moveToVisible loop (which
            // only runs when reservoir.reservoirCount > 0 — missing the case
            // where all seeded items fit in the first page).
            //
            // Kept synchronous on purpose: publishing under `await` would put a
            // suspension between the filter and the publish, and this branch carries
            // no generation guard of its own — a filter change landing in that window
            // would publish a superseded composition. This path is the low-volume one,
            // so the main-actor saving would not pay for that risk.
            let upcoming = applyFilters(reservoir.visibleItems)
            if !upcoming.isEmpty {
                setVisibleItems(upcoming)
                cardQueue.enqueue(upcoming)
                await cardQueue.waitForReady(count: min(Reservoir.pageSize, upcoming.count))
                let presMap = Dictionary(uniqueKeysWithValues: cardQueue.presentations.map { ($0.id, $0) })
                let filtered = applyFilters(upcoming)
                display.setVisibleCards(filtered.compactMap { presMap[$0.id] })
                // Enqueue failed resolutions for background retry
                enqueueFailedCardsForRetry(presMap: presMap, filtered: filtered)
            }
        }
        reservoirCount = reservoir.reservoirCount
        Log.feed.info("[TaxonomyTrace] reloadFromSQLite gen=\(generation) done visibleItems=\(self.visibleItems.count) reservoirCount=\(self.reservoirCount)")
    }

    /// Build a broad startup pool without letting the newest prolific feeds
    /// consume every slot. The first pass admits only a small number per
    /// provider; a second pass fills unused capacity so narrow filters still
    /// retain all available content.
    // Persistence caps each feed at 50 rows. Reading 5,000 candidates therefore
    // reaches at least 100 feeds even when prolific, fresh aggregator queries
    // occupy the entire leading edge of a language or category selection.
    nonisolated static let candidateReadLimit = 5_000
    nonisolated static let textCandidateReadLimit = 4_000
    nonisolated static let illustratedTextCandidateReadLimit = 300
    nonisolated static let mediaCandidateReadLimit = 500
    nonisolated static let forumCandidateReadLimit = 100

    nonisolated static func balancedCandidatePool(
        _ items: [FeedItem],
        limit: Int = 500,
        initialPerSource: Int = 8
    ) -> [FeedItem] {
        guard limit > 0, !items.isEmpty else { return [] }

        var uniqueItems: [FeedItem] = []
        var seenIDs = Set<String>()
        for item in items where seenIDs.insert(item.id).inserted {
            uniqueItems.append(item)
        }

        var selected: [FeedItem] = []
        var overflowByProvider: [String: [FeedItem]] = [:]
        var providerOrder: [String] = []
        var providerCounts: [String: Int] = [:]
        var selectedIDs = Set<String>()
        selected.reserveCapacity(min(limit, items.count))

        func registerProvider(for item: FeedItem) -> String {
            let provider = Reservoir.providerKey(item)
            if providerCounts[provider] == nil {
                providerOrder.append(provider)
            }
            return provider
        }

        // Reserve a bounded first pass for each non-text medium. The usual
        // source round-robin still applies, so one podcast or channel cannot
        // spend the reservation by itself.
        let perMediumReservation = max(1, limit / 5)
        for predicate in [
            { (item: FeedItem) in item.isPodcast },
            { (item: FeedItem) in item.isYouTube },
            { (item: FeedItem) in item.isForum },
        ] {
            var admitted = 0
            for item in uniqueItems where admitted < perMediumReservation {
                guard predicate(item) else { continue }
                let provider = registerProvider(for: item)
                guard providerCounts[provider, default: 0] < initialPerSource,
                      selected.count < limit else { continue }
                selected.append(item)
                selectedIDs.insert(item.id)
                providerCounts[provider, default: 0] += 1
                admitted += 1
            }
        }

        for item in uniqueItems where !selectedIDs.contains(item.id) {
            let provider = registerProvider(for: item)
            if providerCounts[provider, default: 0] < initialPerSource,
               selected.count < limit {
                selected.append(item)
                selectedIDs.insert(item.id)
                providerCounts[provider, default: 0] += 1
            } else {
                overflowByProvider[provider, default: []].append(item)
            }
        }

        // Source URLs originate in remote feeds and can repeat in malformed or
        // partially merged data. Build the index incrementally so a repeated
        // provider never turns a recoverable refresh into a duplicate-key trap.
        var overflowIndices: [String: Int] = [:]
        overflowIndices.reserveCapacity(providerOrder.count)
        for provider in providerOrder {
            overflowIndices[provider] = 0
        }
        while selected.count < limit {
            var appended = false
            for provider in providerOrder where selected.count < limit {
                let index = overflowIndices[provider, default: 0]
                guard let overflow = overflowByProvider[provider], index < overflow.count else { continue }
                selected.append(overflow[index])
                overflowIndices[provider] = index + 1
                appended = true
            }
            if !appended { break }
        }
        return selected
    }

    private func loadReadState() async {
        do {
            let state: (read: [String], consumed: [String], clicked: [String], sources: [String]) = try await db.read { db in
                let read = try String.fetchAll(db, sql: """
                    SELECT id FROM feed_item WHERE is_read = 1
                    ORDER BY COALESCE(clicked_at, opened_at, fetched_at) DESC
                """)
                let consumed = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM feed_item WHERE consumed_at IS NOT NULL"
                )
                let clicked = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM feed_item WHERE clicked_at IS NOT NULL"
                )
                let sources = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT source_url FROM feed_item WHERE clicked_at IS NOT NULL"
                )
                return (read, consumed, clicked, sources)
            }
            readItemIDs = Set(state.read)
            consumedItemIDs = Set(state.consumed)
            clickedItemIDs = Set(state.clicked)
            clickedSourceURLs = Set(state.sources.map(OPMLParser.normalizeURL))
        } catch {
            Log.db.error("loadReadState error: \(error.localizedDescription)")
        }
    }

    // MARK: - Region toggle

    func toggleRegion(_ region: String) {
        setRegionEnabled(
            region,
            enabled: registry.status(of: SourceRegistry.regionKey(region)) != .on
        )
    }

    func setRegionEnabled(_ region: String, enabled: Bool) {
        // Match exact region + sub-regions (e.g. "countries/brazil/sao-paulo")
        let sourceURLs = registry.sourceURLs(inRegionTree: region)
        registry.setRegionEnabled(region, enabled: enabled)
        if enabled {
            // Enabling: seed fresh content then reload.
            // Keep current content on screen (optimistic) — don't clear until
            // new content is ready, preventing empty-screen flashes.
            regionToggleTask?.cancel()
            scheduler.prioritize(sourceURLs: sourceURLs)
            resetWhatsNewBaseline()
            regionToggleTask = Task { [weak self] in
                guard let self else { return }
                let seedItems = await self.seedRegion(region)
                guard !Task.isCancelled else { return }
                if !seedItems.isEmpty {
                    let name: String
                    if region == "global" {
                        name = "Global feeds"
                    } else if region.hasPrefix("topic/") {
                        // Derive a human-readable name from the topic path
                        let topicPath = String(region.dropFirst(6))  // strip "topic/"
                        name = topicPath
                            .replacingOccurrences(of: "_", with: " ")
                            .capitalized
                    } else {
                        name = CountryStore.countryName(for: region.replacingOccurrences(of: "countries/", with: ""))
                    }
                    // Inform user about filter mismatch
                    let visibleCount = self.applyFilters(seedItems).count
                    if visibleCount == 0 && !seedItems.isEmpty {
                        self.lastToggleMessage = "\(name): \(seedItems.count) articles (0 match current filter)"
                    } else {
                        self.lastToggleMessage = "\(name): \(seedItems.count) new articles"
                    }
                }
                guard !Task.isCancelled else { return }
                await self.reloadFromSQLite(prepend: seedItems)
            }
        } else {
            // Disabling: remove from scheduler (incl. sub-regions), purge from reservoir
            regionToggleTask?.cancel()
            scheduler.remove(sourceURLs: sourceURLs)
            reservoir.removeRegion(region)
            applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
            reservoirCount = reservoir.reservoirCount
        }
    }

    func toggleAllCountries() {
        setAllCountriesEnabled(!registry.isAnyCountryEnabled)
    }

    func setAllCountriesEnabled(_ enabled: Bool) {
        registry.setAllCountriesEnabled(enabled)
        if !enabled {
            // Disabling all countries — purge their items from the reservoir
            // and all visible items. Unlike individual toggleRegion, this
            // affects every country at once, so a full flush is appropriate.
            let countryRegions = Set(registry.sources
                .filter { $0.isCountryFeed }
                .map(\.region))
            reservoir.removeRegions(countryRegions)
            applyUpdate(.replace(applyFilters(reservoir.visibleItems)))
        } else {
            // Enabling all countries — flush and reload from SQLite so
            // country content appears immediately.
            resetWhatsNewBaseline()
            scheduleSourceEnablementRefresh()
        }
        reservoirCount = reservoir.reservoirCount
    }

    /// Fetch a seed batch from a newly enabled region. Returns items to prepend.
    private func seedRegion(_ region: String) async -> [FeedItem] {
        let regionSources = registry.enabledSources
            .filter { $0.region == region }
            .prefix(10)
        guard !regionSources.isEmpty else { return [] }
        let batch = Array(regionSources)
        let result = await fetcher.fetchAll(batch, maxConcurrent: 10)
        // Record fetch health first — reachability is independent of whether the
        // items turn out to be new.
        for source in batch {
            scheduler.recordFetch(sourceURL: source.url, outcome: result.sourceOutcomes[source.url] ?? .failed(URLError(.unknown)))
            saveSourceHealth(for: source.url)
        }
        let actualNew = await persistFetchedItems(result.items, regionOverride: region)
        guard !actualNew.isEmpty else { return [] }
        await matchPersistentSearches(actualNew)
        prefetchImagesIfEnabled(for: actualNew)
        // What actually gates publication: an item counts only once it is *persisted*, not once it is
        // fetched. `persistFetchedItems` is all-or-nothing, so counting the fetcher's items would let
        // the surface promise a ready screen while storage was still pending — the `/100` mistake in
        // the opposite direction.
        return actualNew
    }

    // MARK: - Persistent search

    private func matchPersistentSearches(_ items: [FeedItem]) async {
        await bookmarkStore.matchPersistentSearches(items, regionResolver: { [self] in registry.regionFor(sourceURL: $0) })
    }

    // MARK: - Curated feeds

    func allCuratedFeeds() async throws -> [CuratedFeed] {
        try await curatedFeedStore.allCuratedFeeds()
    }

    func curatedFeed(id: Int64) async throws -> CuratedFeed? {
        try await curatedFeedStore.curatedFeed(id: id)
    }

    @discardableResult
    func createCuratedFeed(
        name: String,
        definition: CuratedProfileDefinition,
        recipe: FeedRecipeDefinition? = nil
    ) async throws -> CuratedFeed {
        let id = try await curatedFeedStore.create(
            name: name,
            definition: definition,
            recipe: recipe
        )
        guard let feed = try await curatedFeedStore.curatedFeed(id: id) else {
            throw CuratedFeedError.invalidDefinition
        }
        return feed
    }

    func updateCuratedFeed(
        id: Int64,
        name: String,
        definition: CuratedProfileDefinition,
        recipe: FeedRecipeDefinition? = nil
    ) async throws -> CuratedFeed {
        try await curatedFeedStore.update(
            id: id,
            name: name,
            definition: definition,
            recipe: recipe
        )
        guard let feed = try await curatedFeedStore.curatedFeed(id: id) else {
            throw CuratedFeedError.missingFeed
        }
        if activePreset.curatedFeedID == id {
            let refreshedPreset = PresetSelector.curatedFeed(
                curatedFeedID: id,
                curatedFeedName: feed.name
            )
            activePreset = refreshedPreset
            Settings.activePreset = refreshedPreset
            await rebuildPresetMultipliers(for: refreshedPreset)
            scheduleSourceEnablementRefresh()
        }
        return feed
    }

    func deleteCuratedFeed(id: Int64) async throws {
        try await curatedFeedStore.delete(id: id)
        if activePreset.curatedFeedID == id {
            setPreset(.everything)
        }
    }

    /// A broad, cache-backed set of real stories for onboarding comparisons.
    /// The normal startup pipeline remains the only network writer; onboarding
    /// simply consumes its retained results and can retry as that pool grows.
    func curatedOnboardingItems(languages: Set<String>) async -> [FeedItem] {
        let requested = Set(languages.compactMap {
            CuratedPreferenceEngine.baseLanguage($0)
        })
        var cached: [FeedItem] = (try? await db.read { db in
            try FeedItemRecord.fetchAll(db, sql: """
                SELECT *
                FROM feed_item
                ORDER BY published_at DESC, fetched_at DESC
                LIMIT 1200
                """).map { $0.toFeedItem() }
        }) ?? []

        // The onboarding screen is the first editorial promise the app makes.
        // If the ordinary cache does not yet contain a useful breadth for a
        // selected language, fetch only its deterministic showcase runway.
        // A short throttle prevents the UI's retry loop from re-fetching a
        // temporarily empty source.
        var showcaseToFetch: [FeedSource] = []
        let represented = Set((visibleItems + cached).map {
            OPMLParser.normalizeURL($0.sourceURL)
        })
        for language in requested.sorted() {
            let lastFetch = curatedOnboardingLastFetchAt[language] ?? .distantPast
            guard Date().timeIntervalSince(lastFetch) >= 30 else { continue }
            let showcase = await Self.activeStarterSources(
                language: language,
                limit: 32
            )
            let existingCount = showcase.reduce(into: 0) { count, source in
                if represented.contains(OPMLParser.normalizeURL(source.url)) {
                    count += 1
                }
            }
            guard existingCount < min(12, showcase.count) else { continue }
            curatedOnboardingLastFetchAt[language] = .now
            showcaseToFetch.append(contentsOf: showcase.filter {
                !represented.contains(OPMLParser.normalizeURL($0.url))
            }.prefix(24))
        }

        if !showcaseToFetch.isEmpty {
            var seenSourceURLs = Set<String>()
            let uniqueSources = showcaseToFetch.filter {
                seenSourceURLs.insert(OPMLParser.normalizeURL($0.url)).inserted
            }
            let balancedSources = CuratedPreferenceEngine.showcaseSources(
                from: uniqueSources,
                limit: min(24, uniqueSources.count)
            )

            // Text, video, and forum feeds can become comparison cards as
            // soon as their feed document arrives. Podcast feeds additionally
            // validate enclosures, which is important for playback but should
            // never hold the first onboarding choice hostage. The ordinary
            // startup pipeline continues loading audio in parallel.
            let quickSources = balancedSources.filter { $0.mediaKind != .audio }
            let fallbackAudio = balancedSources.filter { $0.mediaKind == .audio }
            var responsiveSources = Array(quickSources.prefix(18))
            if responsiveSources.count < 8 {
                responsiveSources.append(
                    contentsOf: fallbackAudio.prefix(8 - responsiveSources.count)
                )
            }

            // P1: the showcase joins the bootstrap instead of re-fetching endpoints it is already refilling,
            // and an endpoint the Main Feed refilled in the last 15 minutes is answered from local retention.
            let grant = claimSourceDemand(
                responsiveSources.map(\.url),
                purpose: .onboardingShowcase,
                freshnessWindowMs: FeedSurfaceCatalog.plan(for: .onboarding).refillFreshnessWindowMs
            )
            let grantedURLs = Set(grant.led)
            let grantedSources = responsiveSources.filter {
                grantedURLs.contains(OPMLParser.normalizeURL($0.url))
            }
            if !grantedSources.isEmpty {
                let result = await fetcher.fetchStarter(
                    grantedSources,
                    maxConcurrent: min(18, responsiveSources.count),
                    minimumSuccessfulSources: min(8, responsiveSources.count),
                    minimumItemCount: min(12, responsiveSources.count),
                    deadline: .seconds(7)
                )
                finishSourceDemand(grant, outcomes: result.sourceOutcomes)
                for source in grantedSources {
                    scheduler.recordFetch(
                        sourceURL: source.url,
                        outcome: result.sourceOutcomes[source.url] ?? .failed(URLError(.unknown))
                    )
                }
                let actualNew = await persistFetchedItems(result.items)
                if !actualNew.isEmpty {
                    cached.insert(contentsOf: actualNew, at: 0)
                    let visibleNew = await presentationItems(from: actualNew)
                    if !visibleNew.isEmpty {
                        throttledReservoirAppend(visibleNew)
                        prefetchImagesIfEnabled(for: visibleNew)
                    }
                }
            }
        }

        var seen = Set<String>()
        let pool = (visibleItems + cached).filter { item in
            guard seen.insert(item.id).inserted else { return false }
            guard !requested.isEmpty else { return true }
            guard let language = CuratedPreferenceEngine.baseLanguage(item.language) else {
                return false
            }
            return requested.contains(language)
        }

        // Prefetch images for the entire pool so comparison cards don't
        // render with placeholder gradients. This runs async — the pool
        // is returned immediately while downloads race ahead.
        if !pool.isEmpty {
            let urls = pool.compactMap { $0.bestImageURL ?? $0.imageURL }
            if !urls.isEmpty {
                Task { await prefetcher.prefetch(urls: urls, priorityURLs: urls) }
            }
        }

        return pool
    }

    // MARK: - Smart feeds

    func allSmartFeeds() async throws -> [SmartFeed] {
        try await smartFeedStore.allSmartFeeds()
    }

    func makeSmartFeedDefinition(
        query: String,
        includeSources: Bool,
        includeContents: Bool
    ) -> SmartFeedDefinition {
        makeSmartFeedDefinition(
            expression: SearchExpression(legacyQuery: query),
            includeSources: includeSources,
            includeContents: includeContents
        )
    }

    func makeSmartFeedDefinition(
        expression: SearchExpression,
        includeSources: Bool,
        includeContents: Bool
    ) -> SmartFeedDefinition {
        SmartFeedDefinition(
            query: expression.displayQuery,
            requiredSearchTerms: expression.requiredTerms,
            excludedSearchTerms: expression.excludedTerms,
            includeSources: includeSources,
            includeContents: includeContents,
            region: activeRegion,
            taxonomyNodeIDs: Array(activeNodeIDs),
            languages: Array(activeLanguages),
            contentType: activeContentType.rawValue,
            mood: activeMood.rawValue,
            sourceCollectionID: activePreset.collectionID,
            excludedKeywords: ContentFilterStore.shared.activeFilters
                .flatMap { $0.keywords }
                .filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        )
    }

    @discardableResult
    func createSmartFeed(
        name: String,
        query: String,
        includeSources: Bool,
        includeContents: Bool
    ) async throws -> SmartFeed {
        try await createSmartFeed(
            name: name,
            expression: SearchExpression(legacyQuery: query),
            includeSources: includeSources,
            includeContents: includeContents
        )
    }

    @discardableResult
    func createSmartFeed(
        name: String,
        expression: SearchExpression,
        includeSources: Bool,
        includeContents: Bool
    ) async throws -> SmartFeed {
        let definition = makeSmartFeedDefinition(
            expression: expression,
            includeSources: includeSources,
            includeContents: includeContents
        )
        let id = try await smartFeedStore.createSmartFeed(
            name: name,
            definition: definition
        )
        do {
            try await rebuildSmartFeedCache(id: id)
            guard let smartFeed = try await smartFeedStore.smartFeed(id: id) else {
                throw SmartFeedError.invalidDefinition
            }
            startSmartFeedMaintenance(initialDelay: 5)
            return smartFeed
        } catch {
            try? await smartFeedStore.deleteSmartFeed(id: id)
            throw error
        }
    }

    func deleteSmartFeed(id: Int64) async throws {
        try await smartFeedStore.deleteSmartFeed(id: id)
        if activePreset.smartFeedID == id {
            setPreset(.everything)
        }
        startSmartFeedMaintenance(initialDelay: 30)
    }

    private func rebuildSmartFeedCache(id: Int64) async throws {
        guard let smartFeed = try await smartFeedStore.smartFeed(id: id) else { return }
        let allowedURLs = try await smartFeedAllowedSourceURLs(smartFeed.definition)
        let records = try await smartFeedCandidateRecords(
            definition: smartFeed.definition,
            allowedSourceURLs: allowedURLs
        )
        let matches = records.compactMap { record -> String? in
            let item = record.toFeedItem()
            return smartFeedMatches(
                item,
                definition: smartFeed.definition,
                allowedSourceURLs: allowedURLs
            ) ? item.id : nil
        }
        try await smartFeedStore.cache(itemIDs: matches, for: id)
    }

    private func matchSmartFeeds(_ items: [FeedItem]) async {
        guard !items.isEmpty else { return }
        let smartFeeds: [SmartFeed]
        do {
            smartFeeds = try await smartFeedStore.allSmartFeeds()
        } catch {
            Log.db.error("Could not load Smart Feeds: \(error.localizedDescription)")
            return
        }
        guard !smartFeeds.isEmpty else { return }

        for smartFeed in smartFeeds {
            do {
                let allowedURLs = try await smartFeedAllowedSourceURLs(smartFeed.definition)
                let matchedIDs = items.compactMap { item in
                    smartFeedMatches(
                        item,
                        definition: smartFeed.definition,
                        allowedSourceURLs: allowedURLs
                    ) ? item.id : nil
                }
                try await smartFeedStore.cache(itemIDs: matchedIDs, for: smartFeed.id)
            } catch {
                Log.db.error(
                    "Smart Feed '\(smartFeed.name)' match failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func smartFeedAllowedSourceURLs(
        _ definition: SmartFeedDefinition
    ) async throws -> Set<String>? {
        var allowed: Set<String>?
        if !definition.taxonomyNodeIDs.isEmpty {
            allowed = TaxonomyStore.shared.feedURLs(
                inSubtreesOf: Set(definition.taxonomyNodeIDs)
            )
        }
        if let collectionID = definition.sourceCollectionID {
            let members = try await sourceCollectionStore.members(collectionID: collectionID)
            let collectionURLs = Set(members.map {
                OPMLParser.normalizeURL($0.sourceURL)
            })
            if let existing = allowed {
                allowed = existing.intersection(collectionURLs)
            } else {
                allowed = collectionURLs
            }
        }
        return allowed
    }

    private func smartFeedMatches(
        _ item: FeedItem,
        definition: SmartFeedDefinition,
        allowedSourceURLs: Set<String>?
    ) -> Bool {
        let sourceURL = OPMLParser.normalizeURL(item.sourceURL)
        if let allowedSourceURLs, !allowedSourceURLs.contains(sourceURL) {
            return false
        }
        let expandsCatalog = !definition.taxonomyNodeIDs.isEmpty
            || (FeedLoader.ContentType(rawValue: definition.contentType) ?? .all) != .all
        if definition.sourceCollectionID == nil,
           !expandsCatalog,
           !registry.isSourceEnabled(item.sourceURL) {
            return false
        }
        if let region = definition.region,
           item.region != region,
           !item.region.hasPrefix(region + "/") {
            return false
        }
        if !definition.languages.isEmpty {
            let language = Self.normalizedLanguageCode(item.language)
            guard language.map({ definition.languages.contains($0) }) == true else {
                return false
            }
        }
        let contentType = FeedLoader.ContentType(rawValue: definition.contentType) ?? .all
        guard contentType.matches(item) else { return false }
        let mood = FeedLoader.MoodFilter(rawValue: definition.mood) ?? .all
        guard mood == .all || mood.matches(item.title) else { return false }
        if definition.excludedKeywords.contains(where: {
            item.searchableText.contains(Self.normalizedSmartFeedText($0))
        }) {
            return false
        }

        let expression = definition.searchExpression
        guard expression.canSearch else { return false }
        let positiveExpression = SearchExpression(
            requiredTerms: expression.requiredTerms,
            excludedTerms: []
        )
        let contentText = Self.normalizedSmartFeedText(
            [item.title, item.excerpt]
                .joined(separator: " ")
        )
        let contentMatch = definition.includeContents
            && positiveExpression.matches(contentText)

        let sourceText: String
        if let source = registry.source(forURL: item.sourceURL) {
            sourceText = Self.normalizedSmartFeedText([
                source.title,
                source.url,
                source.category,
                source.sourceDescription ?? "",
                source.tags.joined(separator: " "),
                source.nature ?? "",
                source.activity ?? "",
            ].joined(separator: " "))
        } else {
            sourceText = Self.normalizedSmartFeedText(
                [item.sourceTitle, item.sourceURL, item.category].joined(separator: " ")
            )
        }
        let sourceMatch = definition.includeSources
            && positiveExpression.matches(sourceText)
        let searchedText = [
            definition.includeContents ? contentText : "",
            definition.includeSources ? sourceText : "",
        ].joined(separator: " ")
        if expression.excludedTerms.contains(where: {
            searchedText.contains(Self.normalizedSmartFeedText($0))
        }) {
            return false
        }
        return contentMatch || sourceMatch
    }

    private func smartFeedCandidateRecords(
        definition: SmartFeedDefinition,
        allowedSourceURLs: Set<String>?
    ) async throws -> [FeedItemRecord] {
        let cutoff = Int(
            Date().addingTimeInterval(-SmartFeedStore.retentionInterval)
                .timeIntervalSince1970
        )
        var recordsByID: [String: FeedItemRecord] = [:]

        if definition.includeContents {
            let match = Self.smartFeedFTSQuery(definition.searchExpression)
            let records = try await db.read { db in
                try FeedItemRecord.fetchAll(db, sql: """
                    SELECT fi.*
                    FROM feed_item fi
                    JOIN feed_item_fts ON feed_item_fts.rowid = fi.rowid
                    WHERE fi.fetched_at >= ?
                      AND feed_item_fts MATCH ?
                    """, arguments: [cutoff, match])
            }
            for record in records { recordsByID[record.id] = record }
        }

        if definition.includeSources {
            let matchingSourceURLs = smartFeedMatchingSourceURLs(
                definition: definition,
                allowedSourceURLs: allowedSourceURLs
            )
            if !matchingSourceURLs.isEmpty {
                let sourceRecords = try await db.read { db in
                    var result: [FeedItemRecord] = []
                    let urls = Array(matchingSourceURLs)
                    for start in stride(from: 0, to: urls.count, by: 400) {
                        let chunk = Array(urls[start..<min(start + 400, urls.count)])
                        let placeholders = Array(
                            repeating: "?",
                            count: chunk.count
                        ).joined(separator: ",")
                        result.append(contentsOf: try FeedItemRecord.fetchAll(db, sql: """
                            SELECT * FROM feed_item
                            WHERE fetched_at >= ?
                              AND source_url IN (\(placeholders))
                            """, arguments: StatementArguments([cutoff] + chunk)))
                    }
                    return result
                }
                for record in sourceRecords { recordsByID[record.id] = record }
            }
        }
        return Array(recordsByID.values)
    }

    private func smartFeedMatchingSourceURLs(
        definition: SmartFeedDefinition,
        allowedSourceURLs: Set<String>?
    ) -> Set<String> {
        let expression = definition.searchExpression
        guard expression.canSearch else { return [] }
        let selectedLanguages = Set(definition.languages)
        return Set(registry.sources.compactMap { source -> String? in
            let normalizedURL = OPMLParser.normalizeURL(source.url)
            if let allowedSourceURLs, !allowedSourceURLs.contains(normalizedURL) {
                return nil
            }
            let expandsCatalog = !definition.taxonomyNodeIDs.isEmpty
                || (FeedLoader.ContentType(rawValue: definition.contentType) ?? .all) != .all
            if definition.sourceCollectionID == nil,
               !expandsCatalog,
               !registry.isSourceEnabled(source.url) {
                return nil
            }
            if let region = definition.region,
               source.region != region,
               !source.region.hasPrefix(region + "/") {
                return nil
            }
            if !selectedLanguages.isEmpty {
                let language = Self.normalizedLanguageCode(source.language)
                guard language.map({ selectedLanguages.contains($0) }) == true else {
                    return nil
                }
            }
            let selectedType = FeedLoader.ContentType(rawValue: definition.contentType) ?? .all
            switch selectedType {
            case .all: break
            case .text: guard source.mediaKind == .text else { return nil }
            case .video: guard source.mediaKind == .video || source.isYouTube else { return nil }
            case .audio: guard source.mediaKind == .audio else { return nil }
            case .forum: guard source.mediaKind == .forum else { return nil }
            }
            let text = Self.normalizedSmartFeedText([
                source.title,
                source.url,
                source.category,
                source.sourceDescription ?? "",
                source.tags.joined(separator: " "),
                source.nature ?? "",
                source.activity ?? "",
            ].joined(separator: " "))
            return expression.matches(text) ? normalizedURL : nil
        })
    }

    nonisolated private static func smartFeedFTSQuery(
        _ expression: SearchExpression
    ) -> String {
        let terms = expression.requiredTerms
            .map { term in
                "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
        let excludedTerms = expression.excludedTerms.map { term in
            "NOT \"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        let query = terms.isEmpty
            ? "\"\""
            : (terms + excludedTerms).joined(separator: " ")
        return "{title excerpt} : (\(query))"
    }

    nonisolated private static func normalizedSmartFeedText(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    private func loadSmartFeedFeed(id: Int64) async {
        do {
            guard let smartFeed = try await smartFeedStore.smartFeed(id: id) else {
                activePreset = .everything
                Settings.activePreset = .everything
                activeSmartFeedItemIDs = []
                activeSmartFeedSourceURLs = []
                scheduleSourceEnablementRefresh()
                return
            }
            let items = try await smartFeedStore.cachedItems(smartFeedID: id)
            guard case .smartFeed(let activeID, _) = activePreset,
                  activeID == id else { return }
            activeSmartFeedItemIDs = Set(items.map(\.id))
            activeSmartFeedSourceURLs = Set(items.map {
                OPMLParser.normalizeURL($0.sourceURL)
            })
            currentMode = .smartFeed(id)
            pendingReservoirItems = []
            reservoirFlushTask?.cancel()
            reservoir.clear()
            reservoirCount = 0
            setVisibleItems(items)
            display.setIsPreparingInitialRunway(false)
            display.setLoadingState(.idle)
            Log.feed.info(
                "Smart Feed '\(smartFeed.name)' loaded \(items.count) cached items"
            )
        } catch {
            display.setLoadingState(.idle)
            Log.db.error("Smart Feed load failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func refreshSmartFeed(
        id: Int64,
        sourceLimit: Int = 80,
        maxConcurrent: Int = 12,
        presentWhenActive: Bool = true
    ) async -> Bool {
        guard smartFeedRefreshesInFlight.insert(id).inserted else { return true }
        defer { smartFeedRefreshesInFlight.remove(id) }

        guard let smartFeed = try? await smartFeedStore.smartFeed(id: id) else {
            if activePreset.smartFeedID == id {
                await loadSmartFeedFeed(id: id)
            }
            return false
        }
        let shouldPresent = presentWhenActive && activePreset.smartFeedID == id
        if shouldPresent { display.setLoadingState(.refreshing) }
        defer {
            if shouldPresent { display.setLoadingState(.idle) }
        }
        try? await smartFeedStore.markRefreshStarted(smartFeedID: id)

        do {
            let allowedURLs = try await smartFeedAllowedSourceURLs(smartFeed.definition)
            let definition = smartFeed.definition
            let contentType = FeedLoader.ContentType(rawValue: definition.contentType) ?? .all
            let sourcePool: [FeedSource]
            if let collectionID = definition.sourceCollectionID {
                let members = try await sourceCollectionStore.members(
                    collectionID: collectionID
                )
                sourcePool = members.map { member in
                    registry.source(forURL: member.sourceURL)
                        ?? sourceReference(for: member).feedSource
                }
            } else if !definition.taxonomyNodeIDs.isEmpty || contentType != .all {
                let lookup = registry.lookupSnapshot()
                sourcePool = lookup.sourcesByNormalizedURL.compactMap { url, source in
                    lookup.explicitlyDisabledURLs.contains(url) ? nil : source
                }
            } else {
                sourcePool = registry.enabledSources
            }
            var candidates = sourcePool.filter { source in
                let normalizedURL = OPMLParser.normalizeURL(source.url)
                if let allowedURLs, !allowedURLs.contains(normalizedURL) { return false }
                if let region = definition.region,
                   source.region != region,
                   !source.region.hasPrefix(region + "/") { return false }
                if !definition.languages.isEmpty {
                    let language = Self.normalizedLanguageCode(source.language)
                    if language.map({ definition.languages.contains($0) }) != true {
                        return false
                    }
                }
                switch contentType {
                case .all: return true
                case .text: return source.mediaKind == .text
                case .video: return source.mediaKind == .video || source.isYouTube
                case .audio: return source.mediaKind == .audio
                case .forum: return source.mediaKind == .forum
                }
            }
            if definition.includeSources && !definition.includeContents {
                let matchingURLs = smartFeedMatchingSourceURLs(
                    definition: definition,
                    allowedSourceURLs: allowedURLs
                )
                candidates = candidates.filter {
                    matchingURLs.contains(OPMLParser.normalizeURL($0.url))
                }
            }
            let affinityURLs = try await smartFeedStore.prioritizedSourceURLs(
                smartFeedID: id
            )
            let affinityRank = Dictionary(
                uniqueKeysWithValues: affinityURLs.enumerated().map {
                    (OPMLParser.normalizeURL($0.element), $0.offset)
                }
            )
            let learned = candidates
                .filter { affinityRank[OPMLParser.normalizeURL($0.url)] != nil }
                .sorted {
                    affinityRank[OPMLParser.normalizeURL($0.url), default: .max]
                        < affinityRank[OPMLParser.normalizeURL($1.url), default: .max]
                }
            let unexplored = candidates
                .filter { affinityRank[OPMLParser.normalizeURL($0.url)] == nil }
                .sorted {
                    (scheduler.lastFetchedAt[$0.url] ?? .distantPast)
                        < (scheduler.lastFetchedAt[$1.url] ?? .distantPast)
                }
            // Learned sources lead each refresh, while reserving capacity for
            // discovery so a Smart Feed can adapt when the topic moves.
            let limit = max(1, sourceLimit)
            let learnedBudget = max(1, limit * 3 / 4)
            var batch = Array(learned.prefix(learnedBudget))
            batch.append(contentsOf: unexplored.prefix(max(0, limit - batch.count)))
            if batch.count < limit {
                let learnedAlreadyIncluded = min(learnedBudget, learned.count)
                batch.append(contentsOf: learned.dropFirst(learnedAlreadyIncluded)
                    .prefix(limit - batch.count))
            }
            var refreshSucceeded = true
            if !batch.isEmpty {
                let result = await fetcher.fetchAll(
                    batch,
                    maxConcurrent: min(max(1, maxConcurrent), batch.count)
                )
                guard !Task.isCancelled else { return false }
                refreshSucceeded = result.failedSourceCount < batch.count
                for source in batch {
                    scheduler.recordFetch(sourceURL: source.url, outcome: result.sourceOutcomes[source.url] ?? .failed(URLError(.unknown)))
                }
                let actualNew = await persistFetchedItems(result.items)
                if !actualNew.isEmpty {
                    await matchPersistentSearches(actualNew)
                    await capSourceItemsBatch(Array(Set(actualNew.map(\.sourceURL))))
                }
            }
            try await rebuildSmartFeedCache(id: id)
            try? await smartFeedStore.markRefreshFinished(
                smartFeedID: id,
                succeeded: refreshSucceeded
            )
            if activePreset.smartFeedID == id {
                lastRefreshDate = .now
                if shouldPresent {
                    await loadSmartFeedFeed(id: id)
                }
            }
            return refreshSucceeded
        } catch {
            try? await smartFeedStore.markRefreshFinished(
                smartFeedID: id,
                succeeded: false
            )
            Log.feed.error("Smart Feed refresh failed: \(error.localizedDescription)")
            if shouldPresent {
                await loadSmartFeedFeed(id: id)
            }
            return false
        }
    }

    // MARK: - Source view and personal source collections

    func sourceReference(for item: FeedItem) -> SourceReference {
        if let source = registry.source(forURL: item.sourceURL) {
            return SourceReference(source: source)
        }
        let kind: MediaKind = item.isYouTube ? .video : (item.isPodcast ? .audio : (item.isForum ? .forum : .text))
        return SourceReference(
            title: item.sourceTitle,
            feedURL: item.sourceURL,
            category: item.category,
            region: item.region,
            mediaKind: kind,
            language: item.language
        )
    }

    func sourceReference(for member: SourceCollectionMember) -> SourceReference {
        if let source = registry.source(forURL: member.sourceURL) {
            return SourceReference(source: source)
        }
        return SourceReference(
            title: member.title,
            feedURL: member.sourceURL,
            mediaKind: member.mediaKind
        )
    }

    /// All locally retained posts for a source, without date, read-state,
    /// enablement, or normal-feed filters.
    func sourceContentFromCache(_ source: SourceReference) async -> [FeedItem] {
        await cachedSourceItems(sourceURLs: [source.feedURL], limit: nil)
    }

    /// Explicit source intent overrides default dormancy for this request only.
    /// It does not subscribe/enable the source. The endpoint's complete current
    /// payload is persisted and merged with any older local history.
    func loadSourceContent(_ source: SourceReference) async -> SourceContentResult {
        await recordExplicitSourceAccess(source.feedURL)
        let resolved = registry.source(forURL: source.feedURL) ?? source.feedSource
        // P6: an endpoint the Main Feed refilled inside this surface's window is answered from local
        // retention instead of being fetched a second time.
        let grant = claimSourceDemand(
            [resolved.url],
            purpose: .sourceDetail,
            freshnessWindowMs: FeedSurfaceCatalog.plan(for: .source).refillFreshnessWindowMs
        )
        guard !grant.led.isEmpty else {
            // servedFresh or shared: no request is made here. `FeedFetchStatus` has no notModified case —
            // a 304 maps to `.success` in `FeedFetchResult.status` — so `.success` with 0 new items is the
            // honest "unchanged, not refetched" answer for this surface.
            let items = await sourceContentFromCache(source)
            return SourceContentResult(items: items, fetchStatus: .success, fetchedItemCount: 0)
        }
        let fetchResult = await fetcher.fetch(resolved)
        finishSourceDemand(grant, outcomes: [resolved.url: fetchResult.outcome])
        if !fetchResult.items.isEmpty {
            _ = await persistFetchedItems(fetchResult.items)
        }
        let items = await sourceContentFromCache(source)
        return SourceContentResult(
            items: items,
            fetchStatus: fetchResult.status,
            fetchedItemCount: fetchResult.items.count
        )
    }

    func allSourceCollections() async throws -> [SourceCollection] {
        try await sourceCollectionStore.allCollections()
    }

    @discardableResult
    func createSourceCollection(name: String) async throws -> Int64 {
        try await sourceCollectionStore.createCollection(name: name)
    }

    func renameSourceCollection(id: Int64, name: String) async throws {
        try await sourceCollectionStore.renameCollection(id: id, name: name)
    }

    func deleteSourceCollection(id: Int64) async throws {
        try await sourceCollectionStore.deleteCollection(id: id)
    }

    func reorderSourceCollections(ids: [Int64]) async throws {
        try await sourceCollectionStore.reorderCollections(ids: ids)
    }

    func sourceCollectionMembers(collectionID: Int64) async throws -> [SourceCollectionMember] {
        try await sourceCollectionStore.members(collectionID: collectionID)
    }

    func addSource(_ source: SourceReference, toCollectionID id: Int64) async throws {
        try await sourceCollectionStore.add(source, to: id)
    }

    @discardableResult
    func addSourceURLs(_ sourceURLs: [String], toCollectionID id: Int64) async throws -> Int {
        var seen = Set<String>()
        var references: [SourceReference] = []
        for sourceURL in sourceURLs {
            let normalized = OPMLParser.normalizeURL(sourceURL)
            guard seen.insert(normalized).inserted else { continue }
            guard let source = registry.source(forURL: normalized) else {
                Log.import_.info("Skipping URL not found in registry: \(sourceURL)")
                continue
            }
            references.append(SourceReference(source: source))
        }
        try await sourceCollectionStore.add(references, to: id)
        return references.count
    }

    @discardableResult
    func migrateImportedSourceCollections() async throws -> Int {
        let importedSources = registry.sources.filter { $0.region == "imported" }
        return try await sourceCollectionStore.migrateImportedCategoriesToCollections(importedSources)
    }

    func removeSource(_ sourceURL: String, fromCollectionID id: Int64) async throws {
        try await sourceCollectionStore.remove(sourceURL: sourceURL, from: id)
    }

    func reorderSourceCollectionMembers(collectionID: Int64, sourceURLs: [String]) async throws {
        try await sourceCollectionStore.reorderMembers(collectionID: collectionID, sourceURLs: sourceURLs)
    }

    func sourceCollectionIDs(containing sourceURL: String) async throws -> Set<Int64> {
        try await sourceCollectionStore.collectionIDs(containing: sourceURL)
    }

    /// A collection is a reusable live filter over source identities. Opening
    /// it refreshes every member, then merges current endpoint payloads with
    /// locally retained history. Unlike a single-source inspection it does not
    /// grant every member extended retention, preventing large playlists from
    /// silently pinning an unbounded database.
    func loadSourceCollectionContent(collectionID: Int64) async throws -> SourceCollectionContentResult {
        let members = try await sourceCollectionStore.members(collectionID: collectionID)
        let sources = members.map { member in
            registry.source(forURL: member.sourceURL) ?? sourceReference(for: member).feedSource
        }
        guard !sources.isEmpty else {
            return SourceCollectionContentResult(items: [], sourceCount: 0, failedSourceCount: 0, emptySourceCount: 0)
        }
        // P7: members another producer is already refilling are joined, and a member refilled inside this
        // surface's window is answered from local retention. `cachedSourceItems` still runs over every member,
        // so a member this pass did not refill contributes its locally retained items exactly as before.
        let grant = claimSourceDemand(
            sources.map(\.url),
            purpose: .collectionDetail,
            freshnessWindowMs: FeedSurfaceCatalog.plan(for: .sourceCollection).refillFreshnessWindowMs
        )
        let grantedURLs = Set(grant.led)
        let grantedSources = sources.filter {
            grantedURLs.contains(OPMLParser.normalizeURL($0.url))
        }
        var batch = FeedFetchBatch(
            items: [], fetchedSourceCount: 0, failedSourceCount: 0,
            emptySourceCount: 0, notModifiedCount: 0, throttledCount: 0,
            sourceOutcomes: [:]
        )
        if !grantedSources.isEmpty {
            batch = await fetcher.fetchAll(grantedSources, maxConcurrent: min(8, sources.count))
            finishSourceDemand(grant, outcomes: batch.sourceOutcomes)
        }
        if !batch.items.isEmpty {
            _ = await persistFetchedItems(batch.items)
        }
        let items = await cachedSourceItems(sourceURLs: members.map(\.sourceURL), limit: 1_000)
        return SourceCollectionContentResult(
            items: items,
            sourceCount: sources.count,
            failedSourceCount: batch.failedSourceCount,
            emptySourceCount: batch.emptySourceCount
        )
    }

    func recordExplicitSourceAccess(_ sourceURL: String) async {
        do {
            try await db.write { db in
                try db.execute(sql: """
                    INSERT INTO source_history_access (source_url, last_accessed_at)
                    VALUES (?, ?)
                    ON CONFLICT(source_url) DO UPDATE SET
                        last_accessed_at = excluded.last_accessed_at
                    """, arguments: [
                        OPMLParser.normalizeURL(sourceURL),
                        Int(Date().timeIntervalSince1970),
                    ])
            }
        } catch {
            Log.db.warning("Could not retain explicit source history: \(error.localizedDescription)")
        }
    }

    private func cachedSourceItems(sourceURLs: [String], limit: Int?) async -> [FeedItem] {
        let normalized = Array(Set(sourceURLs.map(OPMLParser.normalizeURL)))
        guard !normalized.isEmpty else { return [] }
        let records: [FeedItemRecord] = (try? await db.read { db in
            var result: [FeedItemRecord] = []
            for start in stride(from: 0, to: normalized.count, by: 400) {
                let chunk = Array(normalized[start..<min(start + 400, normalized.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                result.append(contentsOf: try FeedItemRecord.fetchAll(db, sql: """
                    SELECT * FROM feed_item
                    WHERE source_url IN (\(placeholders))
                    ORDER BY published_at DESC
                    """, arguments: StatementArguments(chunk)))
            }
            let sorted = result.sorted { $0.publishedAt > $1.publishedAt }
            if let limit { return Array(sorted.prefix(limit)) }
            return sorted
        }) ?? []
        // Async variant — the synchronous GRDB read blocks the main actor
        // (FeedStore is @MainActor). bookmarkStore shares userRepo's DB.
        let bookmarked = await bookmarkStore.allBookmarkedItemIDsAsync()
        return records.map { record in
            record.toFeedItem().stamped(
                readItemIDs: record.isRead ? [record.id] : [],
                bookmarkItemIDs: bookmarked.contains(record.id) ? [record.id] : []
            )
        }
    }

    // MARK: - Maintenance

    /// Lightweight cleanup on every launch — deletes up to 500 expired items.
    func performLightExpurgo() async {
        let cutoff = Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970) // 30 days
        let smartFeedCutoff = Int(
            Date().addingTimeInterval(-SmartFeedStore.retentionInterval)
                .timeIntervalSince1970
        )
        do {
            try await db.write { db in
                try db.execute(
                    sql: "DELETE FROM smart_feed_item WHERE matched_at < ?",
                    arguments: [smartFeedCutoff]
                )
                // Use subquery instead of DELETE LIMIT for SQLite compatibility (#22)
                try db.execute(sql: """
                    DELETE FROM feed_item WHERE id IN (
                        SELECT id FROM feed_item
                        WHERE fetched_at < ?
                          AND id NOT IN (SELECT item_id FROM bookmark_item)
                          AND id NOT IN (SELECT item_id FROM smart_feed_item)
                          AND NOT EXISTS (
                              SELECT 1 FROM source_history_access sha
                              WHERE sha.source_url = feed_item.source_url
                                AND sha.last_accessed_at >= ?
                          )
                        LIMIT 500
                    )
                """, arguments: [cutoff, cutoff])
            }
        } catch {
            Log.db.warning("Expurgo error: \(error.localizedDescription)")
        }
    }

    /// Batch cap: enforce 50-item-per-source limit for multiple sources in a
    /// single transaction. Replaces the previous 3×N round-trip approach with
    /// one read + one write, dramatically reducing SQLite churn on startup.
    func capSourceItemsBatch(_ sourceURLs: [String]) async {
        let normalizedURLs = Array(Set(sourceURLs.map(OPMLParser.normalizeURL)))
        guard !normalizedURLs.isEmpty else { return }
        do {
            let removedIDs: [String] = try await db.write { db in
                // Find all sources that exceed the cap and collect IDs to delete
                let placeholders = normalizedURLs.map { _ in "?" }.joined(separator: ",")
                let retentionCutoff = Int(Date().addingTimeInterval(-2_592_000).timeIntervalSince1970)
                let smartFeedCutoff = Int(
                    Date().addingTimeInterval(-SmartFeedStore.retentionInterval)
                        .timeIntervalSince1970
                )
                let args = StatementArguments(normalizedURLs)

                // Identify items to delete: for each overflowing source, keep
                // the 50 newest by published_at, delete the rest (excluding
                // bookmarks). Consumed/clicked rows remain eligible for normal
                // retention, which is why Last clicked promises items that are
                // still present in the database rather than an unbounded archive.
                let idsToDelete = try String.fetchAll(db, sql: """
                    DELETE FROM feed_item WHERE id IN (
                        SELECT fi.id FROM feed_item fi
                        LEFT JOIN bookmark_item bi ON bi.item_id = fi.id
                        WHERE fi.source_url IN (\(placeholders))
                          AND bi.item_id IS NULL
                          AND NOT EXISTS (
                              SELECT 1 FROM smart_feed_item sfi
                              WHERE sfi.item_id = fi.id
                                AND sfi.matched_at >= \(smartFeedCutoff)
                          )
                          AND NOT EXISTS (
                              SELECT 1 FROM source_history_access sha
                              WHERE sha.source_url = fi.source_url
                                AND sha.last_accessed_at >= \(retentionCutoff)
                          )
                          AND fi.id NOT IN (
                              SELECT id FROM feed_item fi2
                              WHERE fi2.source_url = fi.source_url
                              ORDER BY fi2.published_at DESC
                              LIMIT 50
                          )
                    ) RETURNING id
                """, arguments: args)
                return idsToDelete
            }
            // Sync loadedIDs
            if !removedIDs.isEmpty {
                for id in removedIDs { loadedIDs.remove(id) }
                loadedIDsCount = loadedIDs.count
            }
        } catch {
            Log.db.error("capSourceItemsBatch error: \(error.localizedDescription)")
        }
    }

    /// Heavy maintenance — VACUUM + REINDEX. Run once per week in background.
    func performHeavyMaintenance() async {
        let lastKey = "lastHeavyMaintenance"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard now - last > 604800 else { return } // 7 days

        do {
            let smartFeedCutoff = Int(
                Date().addingTimeInterval(-SmartFeedStore.retentionInterval)
                    .timeIntervalSince1970
            )
            try await db.write { db in
                try db.execute(
                    sql: "DELETE FROM smart_feed_item WHERE matched_at < ?",
                    arguments: [smartFeedCutoff]
                )
                try db.execute(sql: """
                    DELETE FROM feed_item
                    WHERE fetched_at < ?
                      AND id NOT IN (SELECT item_id FROM bookmark_item)
                      AND id NOT IN (SELECT item_id FROM smart_feed_item)
                      AND NOT EXISTS (
                          SELECT 1 FROM source_history_access sha
                          WHERE sha.source_url = feed_item.source_url
                            AND sha.last_accessed_at >= ?
                      )
                """, arguments: [
                    Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970),
                    Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970),
                ])
                try db.execute(sql: "DELETE FROM source_history_access WHERE last_accessed_at < ?",
                               arguments: [Int(Date().addingTimeInterval(-2592000).timeIntervalSince1970)])
            }
            try await db.vacuum()
            UserDefaults.standard.set(now, forKey: lastKey)
            Log.db.info("Heavy maintenance complete")
        } catch {
            Log.db.error("Maintenance error: \(error.localizedDescription)")
        }
    }

    // MARK: - Bookmark CRUD

    func allBookmarkLists() async throws -> [BookmarkList] {
        try await bookmarkStore.allBookmarkLists()
    }

    func createBookmarkList(name: String, searchQuery: String? = nil,
                            region: String? = nil, category: String? = nil) async throws -> Int64 {
        try await bookmarkStore.createBookmarkList(name: name, searchQuery: searchQuery, region: region, category: category)
    }

    func toggleBookmark(itemID: String, listID: Int64? = nil) async throws {
        let wasBookmarked = try await bookmarkStore.isBookmarked(itemID: itemID, listID: listID)
        try await bookmarkStore.toggleBookmark(itemID: itemID, listID: listID)
        // Keep the in-memory set in sync so setVisibleItems stamps correctly.
        // Also re-stamp visible items in-place so the bookmark indicator
        // updates immediately without a full pipeline cycle.
        if wasBookmarked {
            bookmarkedItemIDs.remove(itemID)
        } else {
            bookmarkedItemIDs.insert(itemID)
        }
        if let idx = visibleItems.firstIndex(where: { $0.id == itemID }) {
            display.mutateVisibleItem(at: idx, bumpGeneration: true) { $0.isBookmarked = !wasBookmarked }
        }
    }

    func isBookmarked(itemID: String, listID: Int64? = nil) async throws -> Bool {
        try await bookmarkStore.isBookmarked(itemID: itemID, listID: listID)
    }

    func bookmarkedItems(listID: Int64? = nil) async throws -> [FeedItem] {
        try await bookmarkStore.bookmarkedItems(listID: listID)
    }

    func renameBookmarkList(_ id: Int64, name: String) async throws {
        try await bookmarkStore.renameBookmarkList(id, name: name)
    }

    func reorderBookmarkList(_ id: Int64, sortOrder: Int) async throws {
        try await bookmarkStore.reorderBookmarkList(id, sortOrder: sortOrder)
    }

    func deleteBookmarkList(_ id: Int64) async throws {
        try await bookmarkStore.deleteBookmarkList(id)
    }

    /// Toggle search_active on a persistent search bookmark list.
    /// When activated, retroactively adds matching existing items to the list.
    func toggleSearchActive(listID: Int64) async throws {
        try await bookmarkStore.toggleSearchActive(listID: listID)
    }

    // MARK: - Persistent Search (Active)

    func activeSearches() async throws -> [ActiveSearch] {
        try await bookmarkStore.activeSearches()
    }

    /// Build composite feed from multiple active searches with tiered scoring.
    func compositeSearchFeed() async throws -> [FeedItem] {
        try await bookmarkStore.compositeSearchFeed(regionResolver: { [self] in registry.regionFor(sourceURL: $0) })
    }

    // MARK: - Private helpers

    private func defaultListID() -> Int64 {
        bookmarkStore.defaultListID()
    }

    // MARK: - Emergency

    func emergencyTrim() {
        guard !activePreset.isSmartFeed else { return }
        reservoir.emergencyTrim()
        setVisibleItems(applyFilters(reservoir.visibleItems))
        reservoirCount = reservoir.reservoirCount
    }

    /// User refresh: persist threshold-visible cards, then reload/fetch a page
    /// that excludes every durably consumed item.
    func shakeToRefresh() {
        if let smartFeedID = activePreset.smartFeedID {
            Task { await refreshSmartFeed(id: smartFeedID) }
            return
        }
        if activePreset.isLastClicked {
            Task { await loadLastClickedFeed() }
            return
        }
        // Re-persist only cards that actually crossed the visibility threshold.
        // Prefetched cards below the fold have not been seen and remain eligible.
        let ids = reservoir.visibleItems
            .map(\.id)
            .filter { consumedItemIDs.contains($0) }
        reservoir.readItemIDs = consumedItemIDs
        Task {
            if !ids.isEmpty {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try await db.write { db in
                    try db.execute(sql: """
                        UPDATE feed_item
                        SET consumed_at = COALESCE(consumed_at, ?)
                        WHERE id IN (\(placeholders))
                    """, arguments: StatementArguments([Int(Date().timeIntervalSince1970)] + ids))
                }
            }
            // Clear everything, then force-fetch NEW content. The SQLite reload
            // skips consumed items so only unseen content appears.
            // Mark preparing state BEFORE flushing so the UI shows loading,
            // not "No articles found" during the brief window before
            // the pipeline publishes its first results.
            display.setLoadingState(.refreshing)
            _ = display.advanceEpoch(
                mode: currentMode,
                filterGeneration: filterGeneration,
                presetGeneration: presetGeneration
            )
            display.setFeedDisplayPhase(.preparing(contextID: presentationEpoch, reason: .manualRefresh))

            resetWhatsNewBaseline()
            lastRefreshDate = nil
            refreshWhatsNew(shouldBoost: false)
            applyUpdate(.flush(forceFetch: true, skipRead: true))
        }
    }

    // MARK: - Migration

    static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "feed_item") { t in
                t.primaryKey("id", .text)
                t.column("source_url", .text).notNull()
                t.column("source_title", .text).notNull()
                t.column("region", .text).notNull()
                t.column("category", .text).notNull()
                t.column("title", .text).notNull()
                t.column("excerpt", .text).notNull()
                t.column("url", .text).notNull()
                t.column("image_url", .text)
                t.column("audio_url", .text)
                t.column("duration", .double)
                t.column("published_at", .integer).notNull()
                t.column("fetched_at", .integer).notNull()
                t.column("is_read", .integer).notNull().defaults(to: 0)
                t.column("opened_at", .integer)
            }
            try db.create(index: "idx_item_region_date",
                          on: "feed_item", columns: ["region", "published_at"])
            try db.create(index: "idx_item_fetched",
                          on: "feed_item", columns: ["fetched_at"])
            try db.create(index: "idx_item_read",
                          on: "feed_item", columns: ["is_read"],
                          condition: "is_read = 1")

            try db.create(table: "bookmark_list") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("is_default", .integer).notNull().defaults(to: 0)
                t.column("search_query", .text)
                t.column("search_region", .text)
                t.column("search_category", .text)
                t.column("search_active", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "bookmark_item") { t in
                t.column("list_id", .integer).notNull()
                    .references("bookmark_list", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                    .references("feed_item", onDelete: .cascade)
                t.column("added_at", .integer).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.primaryKey(["list_id", "item_id"])
            }
            try db.create(index: "idx_bookmark_item_list",
                          on: "bookmark_item", columns: ["list_id", "sort_order"])
            try db.create(index: "idx_bookmark_item_item",
                          on: "bookmark_item", columns: ["item_id"])

            try db.create(virtualTable: "feed_item_fts", using: FTS5()) { t in
                t.synchronize(withTable: "feed_item")
                t.column("title")
                t.column("excerpt")
                t.column("source_title")
                t.column("category")
            }

            // Default "Favorites" list
            try db.execute(sql: """
                INSERT INTO bookmark_list (name, sort_order, created_at, is_default)
                VALUES ('Favorites', 0, \(Int(Date().timeIntervalSince1970)), 1)
            """)
        }
        // v2: earlier builds stored feed_item dates using GRDB's default TEXT
        // encoding ("yyyy-MM-dd HH:mm:ss.SSS") even though the columns are
        // INTEGER. That made integer-epoch comparisons (expurgo, What's New)
        // always-true/always-false. Convert any lingering TEXT timestamps to
        // epoch seconds in place — we can't drop the cache because bookmark_item
        // cascades from feed_item and dropping rows would delete users' saves.
        migrator.registerMigration("v2_epoch_dates") { db in
            for col in ["published_at", "fetched_at", "opened_at"] {
                try db.execute(sql: """
                    UPDATE feed_item
                    SET \(col) = CAST(strftime('%s', \(col)) AS INTEGER)
                    WHERE typeof(\(col)) = 'text'
                """)
            }
        }
        migrator.registerMigration("v3_source_health") { db in
            try db.create(table: "source_health") { t in
                t.column("url", .text).primaryKey()
                t.column("last_fetch_at", .integer).notNull()
                t.column("consecutive_failures", .integer).notNull().defaults(to: 0)
                t.column("last_status", .text)
                t.column("last_item_count", .integer)
            }
        }
        migrator.registerMigration("v4_indexes") { db in
            try db.create(index: "idx_item_source_pub",
                          on: "feed_item", columns: ["source_url", "published_at"])
            try db.create(index: "idx_item_category_fetched",
                          on: "feed_item", columns: ["category", "fetched_at"])
        }
        migrator.registerMigration("v5_source_toggle") { db in
            try db.create(table: "source_toggle") { t in
                t.column("key", .text).primaryKey()
                t.column("state", .integer).notNull()  // 0=disabled, 1=enabled_override
            }
            // Migrate existing UserDefaults data
            if let disabled = UserDefaults.standard.array(forKey: "toggleDisabled") as? [String] {
                for key in disabled {
                    try db.execute(sql: "INSERT OR IGNORE INTO source_toggle (key, state) VALUES (?, 0)", arguments: [key])
                }
            }
            if let overrides = UserDefaults.standard.array(forKey: "toggleEnabledOverrides") as? [String] {
                for key in overrides {
                    try db.execute(sql: "INSERT OR REPLACE INTO source_toggle (key, state) VALUES (?, 1)", arguments: [key])
                }
            }
        }
        // v6: Convert any TEXT dates in bookmark columns to INTEGER epoch seconds,
        // matching the v2 migration for feed_item columns. Older builds (commit
        // 8cc2551 era) could write TEXT values via GRDB's default Date encoding.
        migrator.registerMigration("v6_bookmark_epoch_dates") { db in
            try db.execute(sql: """
                UPDATE bookmark_list
                SET created_at = CAST(strftime('%s', created_at) AS INTEGER)
                WHERE typeof(created_at) = 'text'
            """)
            try db.execute(sql: """
                UPDATE bookmark_item
                SET added_at = CAST(strftime('%s', added_at) AS INTEGER)
                WHERE typeof(added_at) = 'text'
            """)
        }
        migrator.registerMigration("v7_language") { db in
            try db.alter(table: "feed_item") { t in
                t.add(column: "language", .text)
            }
            try db.create(index: "idx_item_language", on: "feed_item", columns: ["language"])
        }
        // Older RSSFetcher builds copied the OPML source language into every
        // item. That made FeedStore treat inherited metadata as authoritative,
        // so clearly non-English content could remain tagged "en". Clear the
        // obvious script mismatches; nil languages are excluded by an active
        // language filter and will be detected correctly when fetched again.
        migrator.registerMigration("v8_clear_mislabeled_english_items") { db in
            let scriptRanges = [
                "А-Яа-яЁёІіЇїЄєҐґ", // Cyrillic
                "؀-ۿ",             // Arabic
                "֐-׿",             // Hebrew
                "Ͱ-Ͽ",             // Greek
                "一-龿",            // Han
                "ぁ-ゟ",             // Hiragana
                "゠-ヿ",             // Katakana
                "가-힣",            // Hangul
                "ऀ-ॿ",             // Devanagari
                "ก-๿",             // Thai
                "က-႟",             // Myanmar
                "԰-֏",             // Armenian
                "ሀ-፼",             // Ethiopic
            ]
            let scriptClauses = scriptRanges.map { range in
                "(title || ' ' || excerpt) GLOB '*[\(range)]*[\(range)]*'"
            }.joined(separator: " OR ")
            try db.execute(sql: """
                UPDATE feed_item
                SET language = NULL
                WHERE language = 'en'
                  AND (\(scriptClauses))
            """)
        }
        // Remove values that older media extraction treated as images even
        // though ImageIO cannot render them. A later fetch can repair these
        // rows through persistFetchedItems without disturbing user state.
        migrator.registerMigration("v9_clear_invalid_image_urls") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET image_url = NULL
                WHERE image_url IS NOT NULL
                  AND (
                    lower(image_url) LIKE 'data:image/svg%'
                    OR lower(image_url) LIKE '%.svg%'
                    OR lower(image_url) LIKE '%.mp3%'
                    OR lower(image_url) LIKE '%.m4a%'
                    OR lower(image_url) LIKE '%youtube.com/embed/%'
                    OR lower(image_url) LIKE '%/tracker/%'
                    OR lower(image_url) LIKE '%count.gif%'
                    OR lower(image_url) LIKE '%track-rss-story%'
                  )
            """)
        }
        migrator.registerMigration("v10_fix_azerbaijani_language") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET language = 'az'
                WHERE language = 'en'
                  AND (title || ' ' || excerpt) GLOB '*[Əə]*'
            """)
        }
        migrator.registerMigration("v11_fix_distinctive_script_languages") { db in
            let scripts: [(language: String, ranges: [String])] = [
                ("bn", ["ঀ-৿"]),
                ("hy", ["԰-֏"]),
                ("ka", ["Ⴀ-ჿ"]),
                ("th", ["ก-๿"]),
                ("ko", ["가-힣"]),
                ("he", ["֐-׿"]),
                ("el", ["Ͱ-Ͽ"]),
                ("ja", ["ぁ-ゟ", "゠-ヿ"]),
                ("zh", ["㐀-䶿", "一-鿿"]),
            ]
            for script in scripts {
                let clauses = script.ranges.map { range in
                    "(title || ' ' || excerpt) GLOB '*[\(range)]*[\(range)]*'"
                }.joined(separator: " OR ")
                try db.execute(sql: """
                    UPDATE feed_item
                    SET language = ?
                    WHERE (language IS NULL OR language = 'en')
                      AND (\(clauses))
                """, arguments: [script.language])
            }
        }
        // v11 treated any two Han characters as Chinese. Re-evaluate those
        // rows from the full title and excerpt so English text quoting a name
        // such as "金萱", and Japanese text using kanji, leave the ZH feed.
        migrator.registerMigration("v12_reclassify_han_language") { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, title, excerpt FROM feed_item WHERE language = 'zh'"
            )
            let inputs = rows.map { row in
                LanguageDetectionInput(
                    title: row["title"],
                    excerpt: row["excerpt"],
                    explicitLanguage: nil
                )
            }
            let resolved = Self.detectLanguages(inputs)
            for (row, language) in zip(rows, resolved) {
                guard let language, language != "zh" else { continue }
                let id: String = row["id"]
                try db.execute(
                    sql: "UPDATE feed_item SET language = ? WHERE id = ?",
                    arguments: [language, id]
                )
            }
        }
        // Google News search feeds are collection endpoints, not publishers.
        // Older rows discarded the item-level <source>, but Google also appends
        // the publisher to article titles, so recover it for display/fairness.
        migrator.registerMigration("v13_recover_google_news_publishers") { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title
                    FROM feed_item
                    WHERE source_url LIKE '%news.google.com%'
                      AND source_title LIKE 'Candidate:%'
                """
            )
            for row in rows {
                let title: String = row["title"]
                guard let publisher = Self.googleNewsPublisher(fromArticleTitle: title) else { continue }
                let id: String = row["id"]
                try db.execute(
                    sql: "UPDATE feed_item SET source_title = ? WHERE id = ?",
                    arguments: [publisher, id]
                )
            }
        }
        migrator.registerMigration("v14_clear_google_news_channel_artwork") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET image_url = NULL
                WHERE source_url LIKE '%news.google.com%'
                  AND image_url = 'https://lh3.googleusercontent.com/-DR60l-K8vnyi99NZovm9HlXyZwQ85GMDxiwJWzoasZYCUrPuUM_P_4Rb7ei03j-0nRs0c4F=w256'
            """)
        }
        migrator.registerMigration("v15_remove_candidate_display_names") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET source_title = 'Google News'
                WHERE source_url LIKE '%news.google.com%'
                  AND source_title LIKE 'Candidate:%'
            """)
        }
        // Earlier builds turned escaped CDATA titles into the literal
        // placeholder "Untitled". Remove only unsaved cache rows; bookmarks
        // remain intact and the corrected parser will refill fresh cards.
        migrator.registerMigration("v16_remove_unsaved_placeholder_titles") { db in
            try db.execute(sql: """
                DELETE FROM feed_item
                WHERE lower(trim(title)) = 'untitled'
                  AND id NOT IN (SELECT item_id FROM bookmark_item)
            """)
        }
        // YouTube channel metadata can claim English even when the item title
        // is clearly Khmer. Reclassify cached rows so an English-only filter
        // cannot surface them before the channel is fetched again.
        migrator.registerMigration("v17_fix_khmer_language") { db in
            try db.execute(sql: """
                UPDATE feed_item
                SET language = 'km'
                WHERE language = 'en'
                  AND (title || ' ' || excerpt) GLOB '*[ក-៙]*[ក-៙]*'
            """)
        }
        migrator.registerMigration("v18_source_history_access") { db in
            try db.create(table: "source_history_access") { t in
                t.primaryKey("source_url", .text)
                t.column("last_accessed_at", .integer).notNull()
            }
            try db.create(index: "idx_source_history_access_date",
                          on: "source_history_access", columns: ["last_accessed_at"])
        }
        migrator.registerMigration("v19_clicked_history") { db in
            try db.alter(table: "feed_item") { table in
                table.add(column: "clicked_at", .integer)
                table.add(column: "consumed_at", .integer)
            }
            // Every row previously marked read had already been consumed under
            // the old model. Preserve that invariant while starting the new,
            // precise click history empty.
            try db.execute(sql: """
                UPDATE feed_item
                SET consumed_at = COALESCE(opened_at, fetched_at)
                WHERE is_read = 1
                """)
            try db.create(
                index: "idx_feed_item_clicked_at",
                on: "feed_item",
                columns: ["clicked_at"],
                condition: "clicked_at IS NOT NULL"
            )
            try db.create(
                index: "idx_feed_item_consumed_at",
                on: "feed_item",
                columns: ["consumed_at"],
                condition: "consumed_at IS NOT NULL"
            )
        }
        migrator.registerMigration("v20_smart_feed_cache") { db in
            try db.create(table: "smart_feed_item") { t in
                t.column("smart_feed_id", .integer).notNull()
                t.column("item_id", .text).notNull()
                    .references("feed_item", onDelete: .cascade)
                t.column("matched_at", .integer).notNull()
                t.primaryKey(["smart_feed_id", "item_id"])
            }
            try db.create(
                index: "idx_smart_feed_item_feed_date",
                on: "smart_feed_item",
                columns: ["smart_feed_id", "matched_at"]
            )
            try db.create(
                index: "idx_smart_feed_item_item",
                on: "smart_feed_item",
                columns: ["item_id"]
            )
        }
        migrator.registerMigration("v21_smart_feed_source_affinity") { db in
            try db.create(table: "smart_feed_source") { t in
                t.column("smart_feed_id", .integer).notNull()
                t.column("source_url", .text).notNull()
                t.column("hit_count", .integer).notNull().defaults(to: 0)
                t.column("last_matched_at", .integer).notNull()
                t.primaryKey(["smart_feed_id", "source_url"])
            }
            try db.create(
                index: "idx_smart_feed_source_priority",
                on: "smart_feed_source",
                columns: ["smart_feed_id", "hit_count", "last_matched_at"]
            )
        }
        // v22: Add HTTP validator columns to source_health for adaptive scheduling
        migrator.registerMigration("v22_source_health_v2") { db in
            let columns: [(String, String)] = [
                ("etag", "TEXT"),
                ("last_modified", "TEXT"),
                ("cache_control_max_age", "REAL"),
                ("cache_control_no_cache", "INTEGER DEFAULT 0"),
                ("cache_control_no_store", "INTEGER DEFAULT 0"),
                ("cache_control_must_revalidate", "INTEGER DEFAULT 0"),
                ("expires", "INTEGER"),
                ("canonical_url", "TEXT"),
                ("last_outcome", "TEXT"),
                ("retry_after", "INTEGER"),
                ("ttl", "INTEGER"),
                ("skip_hours", "TEXT"),
                ("skip_days", "TEXT"),
                ("capabilities", "TEXT"),
                ("last_build_date", "INTEGER"),
                ("publication_interval", "REAL DEFAULT 3600"),
                ("publication_interval_confidence", "REAL DEFAULT 0.0"),
            ]
            for (name, type) in columns {
                try db.execute(sql: "ALTER TABLE source_health ADD COLUMN \(name) \(type)")
            }
        }
        // v23: Add metadata columns to feed_item and rebuild FTS index
        migrator.registerMigration("v23_feed_item_metadata") { db in
            let columns: [(String, String)] = [
                ("updated_at", "INTEGER"),
                ("authors", "TEXT"),
                ("item_categories", "TEXT"),
                ("rights", "TEXT"),
                ("attribution_title", "TEXT"),
                ("attribution_url", "TEXT"),
                ("attribution_feed_url", "TEXT"),
                ("enclosures", "TEXT"),
                ("language_from_feed", "TEXT"),
                ("alternate_links", "TEXT"),
            ]
            for (name, type) in columns {
                try db.execute(sql: "ALTER TABLE feed_item ADD COLUMN \(name) \(type)")
            }

            // Rebuild FTS index to include new searchable columns
            try db.execute(sql: "DROP TABLE IF EXISTS feed_item_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE feed_item_fts USING fts5(
                    title, excerpt, source_title, category,
                    authors, item_categories, rights,
                    content='feed_item', content_rowid='rowid'
                )
            """)
            // Backfill existing rows. An external-content FTS5 table starts
            // empty — the CREATE does not index pre-existing data. Without
            // this INSERT, all items inserted before v23 are permanently
            // missing from search results and smart-feed matching.
            try db.execute(sql: """
                INSERT INTO feed_item_fts(rowid, title, excerpt, source_title, category,
                    authors, item_categories, rights)
                SELECT rowid, title, excerpt, source_title, category,
                    authors, item_categories, rights
                FROM feed_item
            """)
        }

        // v24: Image resolution retry queue.
        // Separates retry state from feed_item so the queue can be queried
        // efficiently (indexed scan) and cleaned up via CASCADE on item expiry.
        migrator.registerMigration("v24_image_retry_queue") { db in
            try db.create(table: "image_retry_queue") { t in
                t.column("item_id", .text).notNull()
                    .primaryKey()
                    .references("feed_item", onDelete: .cascade)
                t.column("state", .text).notNull().defaults(to: "pending")
                t.column("retry_count", .integer).notNull().defaults(to: 0)
                t.column("next_retry_at", .integer)       // epoch seconds
                t.column("last_error", .text)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(
                index: "idx_image_retry_state_next",
                on: "image_retry_queue",
                columns: ["state", "next_retry_at"]
            )
        }

        migrator.registerMigration("v25_image_resolution") { db in
            try db.create(table: "image_resolution") { t in
                t.column("item_id", .text)
                    .primaryKey()
                    .references("feed_item", column: "id", onDelete: .cascade)
                t.column("candidate_fingerprint", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "unknown")
                t.column("cache_key", .text)
                t.column("resolved_url", .text)
                t.column("pixel_width", .integer)
                t.column("pixel_height", .integer)
                t.column("byte_count", .integer)
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
                t.column("last_attempt_at", .integer)
                t.column("next_retry_at", .integer)
                t.column("failure_class", .text)
                t.column("failure_code", .integer)
                t.column("updated_at", .integer).notNull()
            }
            try db.create(
                index: "image_resolution_state_retry",
                on: "image_resolution",
                columns: ["state", "next_retry_at"]
            )
            // Clean up legacy empty-string image_url sentinels.
            // An empty string was written as a permanent "no image" marker,
            // but it could also represent a transient failure. Reset to NULL
            // so the new resolution pipeline can re-evaluate.
            try db.execute(sql: """
                UPDATE feed_item SET image_url = NULL WHERE image_url = ''
                """)
        }

        try migrator.migrate(db)
    }
}

struct SourceContentResult: Equatable, Sendable {
    let items: [FeedItem]
    let fetchStatus: FeedFetchStatus
    let fetchedItemCount: Int
}

struct SourceCollectionContentResult: Equatable, Sendable {
    let items: [FeedItem]
    let sourceCount: Int
    let failedSourceCount: Int
    let emptySourceCount: Int
}

// MARK: - Source Health Record

struct SourceHealthRecord: Codable, PersistableRecord, FetchableRecord {
    var url: String
    var lastFetchAt: Int
    var consecutiveFailures: Int
    var lastStatus: String?
    var lastItemCount: Int?
    var etag: String?
    var lastModified: String?
    var cacheControlMaxAge: Double?
    var cacheControlNoCache: Bool
    var cacheControlNoStore: Bool
    var cacheControlMustRevalidate: Bool
    var expires: Int?
    var canonicalURL: String?
    var lastOutcome: String?
    var retryAfter: Int?
    var ttl: Int?
    var skipHours: String?
    var skipDays: String?
    var capabilities: String?
    var lastBuildDate: Int?
    var publicationInterval: Double?
    var publicationIntervalConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case url
        case lastFetchAt = "last_fetch_at"
        case consecutiveFailures = "consecutive_failures"
        case lastStatus = "last_status"
        case lastItemCount = "last_item_count"
        case etag
        case lastModified = "last_modified"
        case cacheControlMaxAge = "cache_control_max_age"
        case cacheControlNoCache = "cache_control_no_cache"
        case cacheControlNoStore = "cache_control_no_store"
        case cacheControlMustRevalidate = "cache_control_must_revalidate"
        case expires
        case canonicalURL = "canonical_url"
        case lastOutcome = "last_outcome"
        case retryAfter = "retry_after"
        case ttl
        case skipHours = "skip_hours"
        case skipDays = "skip_days"
        case capabilities
        case lastBuildDate = "last_build_date"
        case publicationInterval = "publication_interval"
        case publicationIntervalConfidence = "publication_interval_confidence"
    }

    static let databaseTableName = "source_health"

    static func loadAll(_ db: Database) throws -> [SourceHealthRecord] {
        try fetchAll(db)
    }
}

// MARK: - FeedItem GRDB Record

/// Thin persistence record — maps FeedItem to SQLite columns.
/// Separate from FeedItem to avoid polluting the domain model with GRDB details.
struct FeedItemRecord: Codable, PersistableRecord, FetchableRecord {
    var id: String
    var sourceURL: String
    var sourceTitle: String
    var region: String
    var category: String
    var title: String
    var excerpt: String
    var url: String
    var imageURL: String?
    var audioURL: String?
    var duration: TimeInterval?
    var publishedAt: Int   // epoch seconds
    var fetchedAt: Int     // epoch seconds
    var isRead: Bool
    var openedAt: Int?     // epoch seconds
    var clickedAt: Int?    // epoch seconds; actual content tap only
    var consumedAt: Int?   // epoch seconds; at least 50% visible or explicitly read
    var language: String?
    var updatedAt: Int?    // epoch seconds
    var authors: String?          // JSON array of FeedItemAuthor
    var itemCategories: String?   // JSON array of FeedItemCategory
    var rights: String?
    var attributionTitle: String?
    var attributionURL: String?
    var attributionFeedURL: String?
    var enclosures: String?       // JSON array of FeedEnclosure
    var languageFromFeed: String?
    var alternateLinks: String?   // JSON array of FeedAlternateLink

    static var databaseTableName: String { "feed_item" }

    // GRDB Associations
    static let bookmarkItems = hasMany(BookmarkItemRecord.self, using: ForeignKey(["item_id"], to: ["id"]))

    enum CodingKeys: String, CodingKey {
        case id
        case sourceURL = "source_url"
        case sourceTitle = "source_title"
        case region
        case category
        case title
        case excerpt
        case url
        case imageURL = "image_url"
        case audioURL = "audio_url"
        case duration
        case publishedAt = "published_at"
        case fetchedAt = "fetched_at"
        case isRead = "is_read"
        case openedAt = "opened_at"
        case clickedAt = "clicked_at"
        case consumedAt = "consumed_at"
        case language
        case updatedAt = "updated_at"
        case authors
        case itemCategories = "item_categories"
        case rights
        case attributionTitle = "attribution_title"
        case attributionURL = "attribution_url"
        case attributionFeedURL = "attribution_feed_url"
        case enclosures
        case languageFromFeed = "language_from_feed"
        case alternateLinks = "alternate_links"
    }

    init(from item: FeedItem, region: String, language: String? = nil) {
        self.id = item.id
        self.sourceURL = item.sourceURL
        self.sourceTitle = item.sourceTitle
        self.region = region
        self.category = item.category
        self.title = item.title
        self.excerpt = item.excerpt
        self.url = item.url
        // Preserve sentinel ("" = confirmed no image) while falling back to
        // YouTube thumbnail for items that genuinely have no image URL yet.
        self.imageURL = item.imageURL ?? item.bestImageURL
        self.audioURL = item.audioURL
        self.duration = item.duration
        self.publishedAt = Int(item.publishedAt.timeIntervalSince1970)
        self.fetchedAt = Int(Date().timeIntervalSince1970)
        self.isRead = false
        self.openedAt = nil
        self.clickedAt = nil
        self.consumedAt = nil
        self.language = language
        // New metadata fields
        self.updatedAt = item.updatedAt.map { Int($0.timeIntervalSince1970) }
        self.authors = item.authors.flatMap { try? FeedStore.encodeJSON($0) }
        self.itemCategories = item.itemCategories.flatMap { try? FeedStore.encodeJSON($0) }
        self.rights = item.rights
        self.attributionTitle = item.attribution?.title
        self.attributionURL = item.attribution?.url
        self.attributionFeedURL = item.attribution?.feedURL
        self.enclosures = item.enclosures.flatMap { try? FeedStore.encodeJSON($0) }
        self.languageFromFeed = item.languageFromFeed
        self.alternateLinks = item.alternateLinks.flatMap { try? FeedStore.encodeJSON($0) }
    }

    func toFeedItem() -> FeedItem {
        let cleanedSourceTitle = FeedTextSanitizer.sanitizedHTMLText(sourceTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = FeedTextSanitizer.sanitizedHTMLText(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedExcerpt = FeedTextSanitizer.sanitizedHTMLText(excerpt)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parsedAttribution: FeedItemAttribution? = {
            if attributionTitle != nil || attributionURL != nil || attributionFeedURL != nil {
                return FeedItemAttribution(title: attributionTitle, url: attributionURL, feedURL: attributionFeedURL)
            }
            return nil
        }()

        return FeedItem(
            id: id,
            sourceTitle: cleanedSourceTitle.isEmpty ? sourceTitle : cleanedSourceTitle,
            sourceURL: sourceURL,
            category: category,
            title: cleanedTitle.isEmpty ? title : cleanedTitle,
            excerpt: cleanedExcerpt,
            url: url,
            imageURL: imageURL,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(publishedAt)),
            audioURL: audioURL,
            duration: duration,
            region: region,
            language: language,
            updatedAt: updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            authors: authors.flatMap { try? FeedStore.decodeJSON($0) },
            itemCategories: itemCategories.flatMap { try? FeedStore.decodeJSON($0) },
            rights: rights,
            attribution: parsedAttribution,
            enclosures: enclosures.flatMap { try? FeedStore.decodeJSON($0) },
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks.flatMap { try? FeedStore.decodeJSON($0) }
        )
    }
}

// MARK: - Image Retry Queue Record

/// A row in the `image_retry_queue` table. Tracks retry state for items
/// whose image resolution failed during initial pipeline processing.
struct ImageRetryQueueRecord: Codable, PersistableRecord, FetchableRecord {
    var itemID: String
    var state: String        // "pending" | "in_progress" | "failed"
    var retryCount: Int
    var nextRetryAt: Int?    // epoch seconds
    var lastError: String?
    var createdAt: Int
    var updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case state
        case retryCount = "retry_count"
        case nextRetryAt = "next_retry_at"
        case lastError = "last_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Bookmark Models

struct BookmarkListRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int
    var createdAt: Int  // epoch seconds (matches SQL storage)
    var isDefault: Bool
    var searchQuery: String?
    var searchRegion: String?
    var searchCategory: String?
    var searchActive: Bool

    static var databaseTableName: String { "bookmark_list" }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case isDefault = "is_default"
        case searchQuery = "search_query"
        case searchRegion = "search_region"
        case searchCategory = "search_category"
        case searchActive = "search_active"
    }
}

struct BookmarkItemRecord: Codable, FetchableRecord, PersistableRecord {
    var listId: Int64
    var itemId: String
    var addedAt: Int  // epoch seconds
    var sortOrder: Int

    static var databaseTableName: String { "bookmark_item" }

    enum CodingKeys: String, CodingKey {
        case listId = "list_id"
        case itemId = "item_id"
        case addedAt = "added_at"
        case sortOrder = "sort_order"
    }
}

// MARK: - Image Resolution Queue Delegate

extension FeedStore: ImageResolutionQueueDelegate {

    /// After the pipeline publishes visible cards, collect items that resolved
    /// to `.placeholder` but still have image potential and enqueue them for
    /// background retry with exponential backoff.
    func enqueueFailedCardsForRetry(
        presMap: [String: FeedCardPresentation],
        filtered: [FeedItem]
    ) {
        let retryEligible = filtered.compactMap { item -> String? in
            guard let pres = presMap[item.id],
                  case .placeholder = pres.media,
                  item.hasPotentialImage else { return nil }
            return item.id
        }
        guard !retryEligible.isEmpty else { return }

        Task { [weak self] in
            await self?.imageResolutionQueue.enqueueBatch(itemIDs: retryEligible)
        }
    }

    /// A background retry resolved an image for an item that may already be on
    /// screen.
    ///
    /// The published card is deliberately left alone. Its presentation is frozen
    /// at publication, so this only records the late resolution; the image is in
    /// `ImageCache` and the next composition publishes the card with it already
    /// in place. Rewriting the published card here would activate the hero slot
    /// and grow the card under a reader who is mid-scroll — the very shift the
    /// freeze exists to prevent (see `CardPreparationCoordinator`'s deferred
    /// retry, which takes the same decision). Pinned by
    /// `FeedStoreTests.test_lateImageResolutionDoesNotMutatePublishedCard`.
    func imageResolutionQueue(didResolveImageFor itemID: String) {
        Log.feed.info("""
            Image resolved late for \(itemID.prefix(12)); kept for the next composition \
            (published cards keep their presentation)
            """)
    }

    /// Called when all retries are exhausted. The item stays text-only.
    func imageResolutionQueue(didExhaustRetriesFor itemID: String) {
        Log.feed.info("Image retries exhausted for item \(itemID.prefix(12))...")
    }
}
