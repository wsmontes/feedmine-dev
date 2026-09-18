import Foundation
import Observation

// MARK: - Shared types (file scope for module access by FeedStore)

enum FeedLoadingState {
    case idle
    case initial
    case refreshing
    case loadingMore
}

/// The current phase of feed display. Decouples "what is on screen"
/// from loading state so the UI can distinguish between "empty because
/// we haven't finished preparing" and "empty because there's no content."
enum FeedDisplayPhase: Equatable {
    /// Feed composition is in progress — no content should be shown yet.
    case preparing(contextID: UInt64, reason: PreparationReason)

    /// Feed is fully ready with the published runway.
    case ready(contextID: UInt64)

    /// Preparation finished and confirmed zero results.
    case empty(contextID: UInt64)

    /// Preparation failed.
    case failed(contextID: UInt64, message: String)
}

enum PreparationReason: Equatable {
    case startup
    case filterChange
    case manualRefresh
    case source
    case collection
    case presetChange
}

enum DeferredToggleState: Equatable {
    case none
    case enabled
    case disabled
}

// MARK: - ViewModel

@MainActor
@Observable
final class FeedLoader {
    private let store: FeedStore
    private var pendingRegionToggleStates: [String: DeferredToggleState] = [:]

    // MARK: - UI State (from store)

    var items: [FeedItem] { store.visibleItems }
    /// Pre-resolved card presentations. The main feed should render from these
    /// when available — images are already resolved. Nil/empty for search and
    /// paths that skip the pipeline (views fall back to CachedAsyncImage).
    var cards: [FeedCardPresentation] { store.visibleCards }
    var loadingState: FeedLoadingState { store.loadingState }
    var feedDisplayPhase: FeedDisplayPhase { store.feedDisplayPhase }
    var totalFetched: Int { store.totalFetched }
    var fetchErrorCount: Int { store.fetchErrorCount }
    var sourceCount: Int { store.registry.sourceCount }
    /// Sources available under the current filter configuration
    /// (preset, region, language, content type, taxonomy).
    /// Active source count, cached per filter generation. Avoids recomputing
    /// the O(n) activeSources filter on every header render.
    @ObservationIgnored private var _cachedActiveSourceCount: Int?
    @ObservationIgnored private var _cachedActiveSourceCountGen: Int64?

    var activeSourceCount: Int {
        if let presetCount = store.presetSourceFilter?.count {
            return presetCount
        }
        let gen = store.activeFilterGeneration
        if let cached = _cachedActiveSourceCount, _cachedActiveSourceCountGen == gen {
            return cached
        }
        let count = activeSources.count
        _cachedActiveSourceCount = count
        _cachedActiveSourceCountGen = gen
        return count
    }

    var activeSources: [FeedSource] {
        if let filter = store.presetSourceFilter {
            return store.registry.sources.filter {
                filter.contains(OPMLParser.normalizeURL($0.url))
            }
        }
        let base = store.registry.enabledSources
        let hasRegion = store.activeRegion != nil
        let hasLanguages = !store.activeLanguages.isEmpty
        let hasContentType = store.activeContentType != .all
        let hasTaxonomy = !store.activeNodeIDs.isEmpty
        guard hasRegion || hasLanguages || hasContentType || hasTaxonomy else {
            return base
        }
        return base.filter { source in
            if hasRegion, let r = store.activeRegion {
                guard source.region == r || source.region.hasPrefix(r + "/") else { return false }
            }
            if hasLanguages {
                let lang = FeedStore.normalizedLanguageCode(source.language)
                guard lang.map({ store.activeLanguages.contains($0) }) ?? false else { return false }
            }
            if hasContentType {
                switch store.activeContentType {
                case .audio: guard source.mediaKind == .audio else { return false }
                case .video: guard source.mediaKind == .video else { return false }
                case .forum: guard source.mediaKind == .forum else { return false }
                case .text:  guard source.mediaKind == .text else { return false }
                case .all: break
                }
            }
            if hasTaxonomy {
                let urls = store.cachedTaxonomyFeedURLs
                guard urls.contains(OPMLParser.normalizeURL(source.url)) else { return false }
            }
            return true
        }
    }
    var podcastSourceCount: Int { store.podcastSourceCount }
    var podcastItemCount: Int { store.podcastItemCount }
    var totalDiscarded: Int { store.totalDiscarded }
    var emptyFeedCount: Int { store.emptyFeedCount }
    var emptyStateFetchedCount: Int { store.emptyStateFetchedCount }
    var emptyStateFetchTotal: Int { store.emptyStateFetchTotal }
    var hasPreviouslyLoadedContent: Bool { store.hasPreviouslyLoadedContent }
    var isUrgentFetching: Bool { store.isUrgentFetching }
    var startupFetchedSourceCount: Int { store.startupFetchedSourceCount }
    var startupTargetSourceCount: Int { store.startupTargetSourceCount }
    var startupItemsReady: Int { store.startupItemsReady }
    var isPreparingFilteredComposition: Bool { store.isPreparingFilteredComposition }
    var startupItemsTarget: Int { store.startupItemsTarget }
    var startupTotalSourceCount: Int { store.startupTotalSourceCount }
    var startupRecentSourceNames: [String] { store.startupRecentSourceNames }
    var startupRunwayReady: Bool { store.startupRunwayReady }
    var isPreparingInitialRunway: Bool { store.isPreparingInitialRunway }
    var catalogDiagnosticsStatus = FeedEngineCatalogDiagnosticsStatus.idle
    private var catalogDiagnosticsTask: Task<Void, Never>?
    private var catalogUpdateTask: Task<Void, Never>?

    // MARK: - Date Sections

    struct DateSection: Identifiable {
        let id: String
        let title: String
        let items: [FeedItem]
        let showsHeader: Bool

        init(id: String? = nil, title: String, items: [FeedItem], showsHeader: Bool = true) {
            self.id = id ?? title
            self.title = title
            self.items = items
            self.showsHeader = showsHeader
        }
    }

    /// Cards-by-item lookup per section, rebuilt only when the cards change.
    ///
    /// A section deliberately does **not** carry its cards (review P0.4): sectioning and filtering depend on items and
    /// order, so a card change — a media swap, or `setVisibleCards` on the legacy queue — must not invalidate them. The
    /// lookup below reads the loader's live `cards` instead, and the cache is per section so a body pass that renders
    /// several sections stays O(1) per section during scroll.
    @ObservationIgnored private var _cardsByIDBySection: [String: [String: FeedCardPresentation]] = [:]
    @ObservationIgnored private var _cardsByIDGeneration: UInt64 = .max

    /// itemID → card lookup for the given section, built from the loader's **live** `cards`.
    ///
    /// Rebuilt only when the cards generation moves; a request served from cache costs one dictionary hit, which is what
    /// FeedScreen needs on every body pass during scroll.
    func cardsByID(for section: DateSection) -> [String: FeedCardPresentation] {
        let cardsGeneration = store.visibleCardsGeneration
        if _cardsByIDGeneration != cardsGeneration {
            _cardsByIDBySection.removeAll(keepingCapacity: true)
            _cardsByIDGeneration = cardsGeneration
        }
        if let cached = _cardsByIDBySection[section.id] { return cached }
        let sectionIDs = Set(section.items.map(\.id))
        let dict = Dictionary(
            cards.filter { sectionIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        _cardsByIDBySection[section.id] = dict
        return dict
    }

    // MARK: - Layout

    enum FeedLayout { case card, list }
    var layout: FeedLayout = .card

    // MARK: - Content Type Filter

    enum ContentType: String, CaseIterable, Identifiable {
        case all = "All"
        case text = "Articles"
        case video = "Videos"
        case audio = "Podcasts"
        case forum = "Forums"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "circle.grid.3x3.fill"
            case .text: return "doc.text.fill"
            case .video: return "play.rectangle.fill"
            case .audio: return "headphones"
            case .forum: return "bubble.left.and.bubble.right.fill"
            }
        }
        func matches(_ item: FeedItem) -> Bool {
            switch self {
            case .all: return true
            case .text: return !item.isYouTube && !item.isPodcast && !item.isForum
            case .video: return item.isYouTube
            case .audio: return item.isPodcast
            case .forum: return item.isForum
            }
        }
    }
    // Single source of truth: all filter state lives in FeedStore
    var selectedContentType: ContentType { store.activeContentType }
    var selectedMood: MoodFilter { store.activeMood }
    var selectedNodeIDs: Set<String> { store.activeNodeIDs }
    var selectedNodeNames: [String] { TaxonomyStore.shared.selectedNodeNames }
    var selectedLanguages: Set<String> { store.activeLanguages }
    var selectedRegion: String? { store.activeRegion }
    var hasLanguageSelection: Bool { !store.activeLanguages.isEmpty }
    var hasTaxonomySelection: Bool { !selectedNodeIDs.isEmpty }
    var hasRegionSelection: Bool { selectedRegion != nil }
    var hasActiveFilters: Bool {
        if activePreset.isSmartFeed { return true }
        return activePreset != .everything
            || hasRegionSelection || hasTaxonomySelection || selectedMood != .all
            || selectedContentType != .all || hasLanguageSelection
    }
    var activeFilterCount: Int {
        if activePreset.isSmartFeed {
            return searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 2
        }
        var count = 0
        if activePreset != .everything { count += 1 }
        if hasRegionSelection { count += 1 }
        count += selectedNodeIDs.count
        count += selectedLanguages.count
        if selectedContentType != .all { count += 1 }
        if selectedMood != .all { count += 1 }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        return count
    }
    var availableTaxonomyRoot: TaxonomyNode? { TaxonomyStore.shared.root }

    /// Backward-compat: returns name of first selected node, or nil.
    var selectedCategory: String? {
        selectedNodeIDs.first.flatMap { TaxonomyStore.shared.flatIndex[$0]?.name }
    }

    // MARK: - Mood Filter

    enum MoodFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case serious = "Serious"
        case fun = "Fun"
        case technical = "Technical"
        case inspiring = "Inspiring"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .all: return "circle.grid.3x3.fill"
            case .serious: return "newspaper.fill"
            case .fun: return "sparkles"
            case .technical: return "gearshape.2.fill"
            case .inspiring: return "sun.max.fill"
            }
        }
        func matches(_ title: String) -> Bool {
            let lower = title.lowercased()
            switch self {
            case .all: return true
            case .serious:
                return lower.contains("crisis") || lower.contains("war") || lower.contains("death") ||
                       lower.contains("killed") || lower.contains("attack") || lower.contains("emergency") ||
                       lower.contains("ban") || lower.contains("ruling") || lower.contains("court")
            case .fun:
                return lower.contains("fun") || lower.contains("amazing") || lower.contains("incredible") ||
                       lower.contains("wow") || lower.contains("hilarious") || lower.contains("funny") ||
                       lower.contains("adorable") || lower.contains("genius") || lower.contains("brilliant")
            case .technical:
                return lower.contains("ai") || lower.contains("code") || lower.contains("data") ||
                       lower.contains("algorithm") || lower.contains("startup") || lower.contains("tech") ||
                       lower.contains("software") || lower.contains("hardware") || lower.contains("api") ||
                       lower.contains("quantum") || lower.contains("robot") || lower.contains("chip")
            case .inspiring:
                return lower.contains("discovered") || lower.contains("breakthrough") || lower.contains("solved") ||
                       lower.contains("cure") || lower.contains("hope") || lower.contains("inspiring") ||
                       lower.contains("hero") || lower.contains("changed") || lower.contains("revolutionary")
            }
        }
    }

    // MARK: - Language Filter

    struct LanguageInfo: Identifiable {
        var id: String { code }
        let code: String       // ISO 639-1
        let name: String       // localized display name
        let flag: String       // emoji flag
        let feedCount: Int     // enabled sources matching this language
        let totalFeedCount: Int
    }

    @ObservationIgnored private var _cachedAvailableLanguages: [LanguageInfo] = []
    @ObservationIgnored private var _cachedAvailableLanguagesSourceRevision: UInt64?
    @ObservationIgnored private var _cachedAvailableLanguagesEnablementRevision: UInt64?
    @ObservationIgnored private var _cachedAvailableLanguagesLocaleIdentifier: String?

    // MARK: - Search

    var searchQuery: String = ""
    private(set) var submittedSearchTerms: [SearchTerm] = []
    var searchIncludesSources = true
    var searchIncludesContents = false
    /// The reader's explicit online-content demand. The local FTS query and the network sweep are
    /// separate decisions: this is what asks `FeedStore` for the sweep, at the reader's request.
    var searchDemandsOnlineContent = false
    var isSearching: Bool { store.isSearching }
    var isSearchLoading: Bool { store.isSearchLoading }
    var isSearchScanning: Bool { store.isSearchScanning }
    var searchScannedSourceCount: Int { store.searchScannedSourceCount }
    var searchTotalSourceCount: Int { store.searchTotalSourceCount }
    var searchDiscoveredItemCount: Int { store.searchDiscoveredItemCount }
    var searchFailedSourceCount: Int { store.searchFailedSourceCount }
    var searchScanCompleted: Bool { store.searchScanCompleted }
    var unifiedSearchResults: UnifiedSearchResults { store.unifiedSearchResults }

    /// Installs the canonical content index the local content search reads, or removes it.
    ///
    /// Forwarded because `FeedStore` owns the search: the composition that authorizes the read path is
    /// the one that closes the legacy producers (plan §14 PR-14 clause two), and it reaches the store
    /// through the loader it already holds.
    func useCanonicalContentSearch(_ source: CanonicalContentSearch?) {
        store.useCanonicalContentSearch(source)
    }

    // MARK: - Filtered Items (reads from FeedStore as single source)

    private var _cachedFiltered: [FeedItem] = []
    private var _cachedGeneration: UInt64?
    private var _cachedReadRevision: UInt64?
    private var _cachedSearchQuery: String?

    /// Test-only instrument: how many times `filteredItems` actually rebuilt.
    ///
    /// The invariant "a card/media change never invalidates filtering" is not observable from the returned value — a
    /// rebuild produces the same array — so the count is what a test can assert. Compiled out of release builds.
    #if DEBUG
    private(set) var filteredItemsRebuildCount = 0
    private(set) var dateSectionsRebuildCount = 0
    #endif

    /// Filtered card presentations matching the active search/filter state.
    /// Mirrors filteredItems but uses pre-resolved FeedCardPresentation values.
    var filteredCards: [FeedCardPresentation] {
        let filteredIDs = Set(filteredItems.map(\.id))
        return cards.filter { filteredIDs.contains($0.id) }
    }

    /// Items matching the active search/filter state.
    ///
    /// **The key deliberately does not include the cards generation.** Which items are filtered depends on the source
    /// filters, the search query and the read/consumed stamps — never on a card's layout or media. Keying on cards made a
    /// pure presentation change (`setVisibleCards`, or any future media swap) invalidate filtering, which is the
    /// structural half of the scroll churn the release review describes: image completion → card change → generation
    /// change → re-filter/re-group while the reader is scrolling. `dateSections` still keys on both, because it embeds
    /// card presentations (see its own comment) — that embedding is what has to go next.
    var filteredItems: [FeedItem] {
        let generation = store.visibleItemsGeneration
        let readRevision = store.readStateRevision
        if _cachedGeneration == generation,
           _cachedReadRevision == readRevision,
           _cachedSearchQuery == searchQuery {
            return _cachedFiltered
        }
        _cachedGeneration = generation
        _cachedReadRevision = readRevision
        _cachedSearchQuery = searchQuery
        #if DEBUG
        filteredItemsRebuildCount &+= 1
        #endif
        var result = items
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let q = query.lowercased()
            if !isSearching {
                result = result.filter {
                    $0.title.localizedCaseInsensitiveContains(q) ||
                    $0.excerpt.localizedCaseInsensitiveContains(q) ||
                    $0.sourceTitle.localizedCaseInsensitiveContains(q)
                }
            }
            result = result
                .map { (item: $0, score: searchScore($0, q)) }
                .sorted { $0.score > $1.score }
                .map(\.item)
        }
        _cachedFiltered = result
        return result
    }

    private var _cachedSections: [DateSection] = []
    private var _cachedDateSectionsGen: UInt64?
    private var _cachedDateSectionsReadRev: UInt64?
    private var _cachedDateSectionsQuery: String?

    /// Items grouped for display, ordered by the editorial sequence.
    ///
    /// **The cache key has no cards generation.** Sections are items, order and headers; a card change (media resolution,
    /// `setVisibleCards`) must not regroup or reorder them — that was the second half of the scroll churn in the release
    /// review, and the reason `DateSection` no longer carries cards at all (the view resolves them through
    /// `cardsByID(for:)`, which is cached on its own generation).
    var dateSections: [DateSection] {
        let items = filteredItems
        if _cachedDateSectionsGen == _cachedGeneration,
           _cachedDateSectionsReadRev == _cachedReadRevision,
           _cachedDateSectionsQuery == _cachedSearchQuery {
            return _cachedSections
        }
        _cachedDateSectionsGen = _cachedGeneration
        _cachedDateSectionsReadRev = _cachedReadRevision
        _cachedDateSectionsQuery = _cachedSearchQuery
        #if DEBUG
        dateSectionsRebuildCount &+= 1
        #endif

        // A filtered feed already has an intentional provider/category/media
        // order. Regrouping it by date would move all fresh aggregator cards
        // ahead of older independent publishers and undo that diversity.
        if hasActiveFilters || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _cachedSections = items.isEmpty
                ? []
                : [DateSection(id: "ordered-results", title: "", items: items, showsHeader: false)]
            return _cachedSections
        }
        // Use pre-computed sectionDayOffset when available (new items);
        // fall back to Calendar for older items loaded from SQLite.
        let calendar = Calendar.current; let now = Date()
        var grouped: [String: [FeedItem]] = [:]
        for item in items {
            let section: String
            let offset = item.sectionDayOffset
            if offset > 0 {
                // Pre-computed offset — fast path, no Calendar needed
                if offset == 1 { section = "Yesterday" }
                else if offset < 7 { section = "This Week" }
                else { section = "Earlier" }
            } else {
                // Legacy item or explicit today — use Calendar for accuracy
                if calendar.isDateInToday(item.publishedAt) { section = "Today" }
                else if calendar.isDateInYesterday(item.publishedAt) { section = "Yesterday" }
                else {
                    let days = calendar.dateComponents([.day], from: item.publishedAt, to: now).day ?? 0
                    section = days < 7 ? "This Week" : "Earlier"
                }
            }
            grouped[section, default: []].append(item)
        }
        _cachedSections = ["Today", "Yesterday", "This Week", "Earlier"].compactMap { t in
            grouped[t].map { groupItems in
                DateSection(title: t, items: groupItems)
            }
        }
        return _cachedSections
    }

    private func searchScore(_ item: FeedItem, _ q: String) -> Int {
        let t = item.title.lowercased(); let e = item.excerpt.lowercased()
        if t == q { return 100 }; if t.hasPrefix(q) { return 80 }
        if t.contains(q) { return 60 }; if e.contains(q) { return 30 }
        return 10
    }

    // MARK: - Countries / Sources

    var availableCountries: [Country] { store.registry.availableCountries }
    var availableCategories: [String] { store.registry.availableCategories }
    var availableLanguages: [LanguageInfo] {
        let counts = store.registry.languageCountSnapshot()
        let localeIdentifier = Locale.current.identifier
        if _cachedAvailableLanguagesSourceRevision == counts.sourceRevision,
           _cachedAvailableLanguagesEnablementRevision == counts.enablementRevision,
           _cachedAvailableLanguagesLocaleIdentifier == localeIdentifier {
            return _cachedAvailableLanguages
        }

        // Use enabled sources so counts reflect what the user can actually see.
        // Normalize to ISO 639-1 base codes so "pt-BR" and "pt" merge into one entry.
        let languages = counts.enabled.map { code, count in
            LanguageInfo(
                code: code,
                name: Locale.current.localizedString(forLanguageCode: code) ?? code,
                flag: Self.flagEmoji(for: code),
                feedCount: count,
                totalFeedCount: counts.total[code] ?? count
            )
        }.sorted { $0.feedCount > $1.feedCount }

        _cachedAvailableLanguages = languages
        _cachedAvailableLanguagesSourceRevision = counts.sourceRevision
        _cachedAvailableLanguagesEnablementRevision = counts.enablementRevision
        _cachedAvailableLanguagesLocaleIdentifier = localeIdentifier
        return languages
    }

    private static let flagEmojiMapping: [String: String] = [
        "pt": "BR", "en": "US", "es": "ES", "fr": "FR", "de": "DE",
        "it": "IT", "ja": "JP", "ko": "KR", "zh": "CN", "ru": "RU",
        "ar": "SA", "hi": "IN", "nl": "NL", "sv": "SE", "no": "NO",
        "da": "DK", "fi": "FI", "pl": "PL", "tr": "TR", "th": "TH",
        "vi": "VN", "id": "ID", "ms": "MY", "fil": "PH", "he": "IL",
        "el": "GR", "cs": "CZ", "ro": "RO", "hu": "HU", "uk": "UA",
        "ca": "ES", "eu": "ES", "gl": "ES",
        "sw": "TZ", "ur": "PK", "fa": "IR", "bn": "BD", "km": "KH",
        "my": "MM", "ne": "NP", "si": "LK", "af": "ZA", "ha": "NG",
        "yo": "NG", "zu": "ZA", "so": "SO", "st": "LS", "tl": "PH",
        "am": "ET", "az": "AZ", "bg": "BG", "bs": "BA", "hr": "HR",
        "et": "EE", "ka": "GE", "is": "IS", "lv": "LV", "lt": "LT",
        "mk": "MK", "mt": "MT", "sk": "SK", "sl": "SI", "sr": "RS",
        "sq": "AL", "hy": "AM", "mn": "MN", "lo": "LA", "kk": "KZ",
        "ky": "KG", "tg": "TJ", "uz": "UZ", "ps": "AF", "ku": "IQ",
        "be": "BY", "ga": "IE", "cy": "GB", "fy": "NL", "lb": "LU",
        "jv": "ID", "su": "ID", "xh": "ZA", "ny": "MW", "mg": "MG",
        "om": "ET", "rw": "RW", "sn": "ZW", "ig": "NG", "ml": "IN",
        "kn": "IN", "ta": "IN", "te": "IN", "mr": "IN", "gu": "IN",
        "pa": "IN", "or": "IN", "as": "IN", "sd": "PK", "bo": "CN",
        "ug": "CN", "yi": "IL", "gd": "GB", "eo": "EU", "la": "VA",
    ]

    private static let flagEmojiBase: UInt32 = 127397

    private static func flagEmoji(for languageCode: String) -> String {
        guard let country = flagEmojiMapping[languageCode] else { return "🌐" }
        return country.unicodeScalars.map { scalar in
            String(UnicodeScalar(flagEmojiBase + scalar.value) ?? "�")
        }.joined()
    }
    var enabledSources: [FeedSource] { store.registry.enabledSources }
    var sources: [FeedSource] { store.registry.sources }
    /// The registry the launch's search reads source metadata from for canonical hits — language,
    /// region, title and category — which is where the legacy reader takes the same fields from.
    var sourceRegistry: SourceRegistry { store.registry }
    var disabledSourceIDs: Set<String> {
        Set(store.registry.sources.filter { !store.registry.isSourceEnabled($0.url) }.map(\.url))
    }

    // MARK: - OPML debug counters

    var opmlErrorCount: Int { store.registry.opmlErrorCount }
    var duplicateSourceCount: Int { store.registry.duplicateSourceCount }
    var opmlFileCount: Int { store.registry.opmlFileCount }

    // MARK: - Read / Bookmark

    var readItemIDs: Set<String> { store.readItemIDs }

    /// Cached bookmark item IDs — refreshed on load and on toggle.
    private var bookmarkItemIDs: Set<String> = []

    var bookmarkedItems: [FeedItem] {
        items.filter { bookmarkItemIDs.contains($0.id) }
    }

    var bookmarkedIDs: Set<String> { bookmarkItemIDs }

    /// Currently selected bookmark box — when set, the feed becomes a fixed
    /// list of that box's contents, ordered by save date. Dismiss to clear.
    var selectedBookmarkListID: Int64? {
        get { store.selectedBookmarkListID }
        set {
            store.selectedBookmarkListID = newValue
            if let listID = newValue {
                // Bookmark mode: load all items from the box
                Task { @MainActor in
                    do {
                        let lists = try await store.allBookmarkLists()
                        selectedBookmarkListName = lists.first(where: { $0.id == listID })?.name
                        let items = try await store.bookmarkedItems(listID: listID)
                        store.loadBookmarkFeed(items: items)
                    } catch {
                        store.selectedBookmarkListID = nil
                        selectedBookmarkListName = nil
                    }
                }
            } else {
                selectedBookmarkListName = nil
                store.clearBookmarkFeed()
            }
        }
    }

    /// Name of the currently selected bookmark box, if any.
    private(set) var selectedBookmarkListName: String? = nil

    /// Reload bookmark state from FeedStore (call on appear and after toggle).
    func refreshBookmarkState() async {
        do {
            let lists = try await store.allBookmarkLists()
            bookmarkLists = lists
            guard let defaultID = lists.first(where: { $0.isDefault })?.id ?? lists.first?.id else {
                bookmarkItemIDs = []
                return
            }
            let items = try await store.bookmarkedItems(listID: defaultID)
            bookmarkItemIDs = Set(items.map(\.id))
        } catch {
            Log.feed.error("refreshBookmarkState error: \(error)")
        }
    }

    // MARK: - Resources

    var networkMonitor: NetworkMonitor { store.networkMonitor }
    var currentVisibleIndex: Int = 0

    /// Records where the viewport is, for the trimming pass. The value is the last ordinal the
    /// renderer can see, in the published page's own order (PR-13): the per-card `onAppear` that used
    /// to report this could not tell a fling from a settle.
    func noteViewport(lastVisibleOrdinal: Int) {
        currentVisibleIndex = lastVisibleOrdinal
    }
    var loadedIDsCount: Int { store.loadedIDsCount }

    // MARK: - What's New

    var whatsNewLabel: String { "What's New" }
    var whatsNewVisible = false

    /// Refresh What's New once after startup and request a fresh booster batch.
    func loadWhatsNew() async {
        store.refreshWhatsNew(shouldBoost: true)
    }

    /// Mark a What's New item as read and remove it from the carousel immediately.
    func markWhatsNewAsRead(_ id: String) {
        store.markAsRead(id)
    }

    // MARK: - Source health (stub)

    struct SourceHealth {
        var lastFetchDate: Date?
        var consecutiveFailures: Int = 0
        var lastArticleCount: Int = 0
        var isStale: Bool { consecutiveFailures >= 3 }
    }
    private var sourceHealth: [String: SourceHealth] = [:]

    func healthFor(_ source: FeedSource) -> SourceHealth {
        SourceHealth(
            lastFetchDate: store.lastFetchDate(for: source.url),
            consecutiveFailures: store.consecutiveFailures(for: source.url)
        )
    }

    // MARK: - Init

    /// Non-nil if the default FeedStore failed to initialize.
    private(set) var initError: Error?

    /// Creates a FeedLoader. Pass a custom FeedStore for testing; uses SQLite-backed
    /// store by default. If store creation fails, captures the error for UI display.
    init(store: FeedStore? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                self.store = try FeedStore()
            } catch {
                self.initError = error
                Log.db.error("FeedStore init failed: \(error.localizedDescription). Using in-memory fallback.")
                // FeedStore.empty() creates an in-memory store as a last resort.
                // Uses try! — if even an in-memory store fails, SQLite is
                // fundamentally broken and the app cannot function.
                self.store = FeedStore.empty()
            }
        }
    }

    // MARK: - Actions (delegate to store)

    func start() async {
        await store.start()
        if restoreImportedSources() {
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
        }
        do {
            let migratedCount = try await store.migrateImportedSourceCollections()
            if migratedCount > 0 {
                Log.import_.info("Recovered \(migratedCount) imported sources into personal collections")
            }
        } catch {
            Log.import_.error("Failed to recover imported source collections: \(error)")
        }
        await loadWhatsNew()
        await refreshBookmarkLists()
        await refreshBookmarkState()
        await refreshActiveSearchState()
        #if DEBUG || INSTRUMENTATION
        scheduleCatalogDiagnosticsIfNeeded()
        #endif
        scheduleCatalogUpdateIfNeeded()
    }

    /// Local startup is never gated on GitHub. Once the local registry is
    /// usable, check for a newer revision in the background and hot-reload only
    /// after the complete staged snapshot has passed validation.
    private func scheduleCatalogUpdateIfNeeded() {
        guard catalogUpdateTask == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-UITest") }) else {
            return
        }

        // This is deliberately the lowest scheduling class: opening and using
        // the local catalog must always win over a remote catalog check.
        // The update service is an independent actor, so its network, staging,
        // checksum and compilation work never runs on the main actor.
        catalogUpdateTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await CatalogUpdateService.shared.updateIfAvailable()
                switch outcome {
                case .current(let revision):
                    FeedMetrics.event("CatalogUpdate.current", "revision=\(revision)")
                case .updated(let from, let to, let changed, let deleted):
                    FeedMetrics.event(
                        "CatalogUpdate.activated",
                        "from=\(from) to=\(to) changed=\(changed) deleted=\(deleted)"
                    )
                    await store.reloadActiveCatalogAfterUpdate()
                }
            } catch {
                // The previous local snapshot stays active for every failure:
                // offline, bad manifest, checksum mismatch, or compile error.
                Log.feed.error("Catalog update kept local snapshot: \(error.localizedDescription)")
            }
            catalogUpdateTask = nil
        }
    }

    #if DEBUG || INSTRUMENTATION
    private func scheduleCatalogDiagnosticsIfNeeded() {
        guard catalogDiagnosticsTask == nil else { return }
        let sources = store.registry.sources

        catalogDiagnosticsStatus = .opening
        let diagnostics = FeedEngineCatalogDiagnostics()
        catalogDiagnosticsTask = Task(priority: .utility) {
            do {
                let status = try await diagnostics.openActiveCatalog()
                catalogDiagnosticsStatus = status
            } catch {
                guard !sources.isEmpty else {
                    FeedMetrics.event("CatalogDiagnostics.failed", error.localizedDescription)
                    catalogDiagnosticsStatus = .failed(error)
                    catalogDiagnosticsTask = nil
                    return
                }
                do {
                    catalogDiagnosticsStatus = .compiling(sourceCount: sources.count)
                    let status = try await diagnostics.compileLegacyCatalog(sources: sources)
                    catalogDiagnosticsStatus = status
                } catch {
                    FeedMetrics.event("CatalogDiagnostics.failed", error.localizedDescription)
                    catalogDiagnosticsStatus = .failed(error)
                }
            }
            catalogDiagnosticsTask = nil
        }
    }
    #endif
    /// Replenishment driven by the viewport instead of by a card appearing (PR-13).
    ///
    /// The view reports the last ordinal it can see and how many ordinals the page holds; neither the
    /// scroll callback nor this call performs selection, decode or a fetch of its own — the store
    /// decides whether the observation is close enough to the tail to schedule one.
    func loadMoreIfNeeded(viewportLastVisibleOrdinal: Int, publishedOrdinalCount: Int) async {
        await store.loadMoreIfNeeded(
            viewportLastVisibleOrdinal: viewportLastVisibleOrdinal,
            publishedOrdinalCount: publishedOrdinalCount
        )
    }
    /// P5: two independent triggers call this — returning to the foreground and recovering the network —
    /// and coming back on a recovered network fires both. While a run is in flight, a second caller awaits
    /// that run instead of starting another; only a run that actually performs the work counts.
    private var staleRefreshTask: Task<Void, Never>?
    private(set) var staleRefreshRunCount = 0

    func refreshIfStale() async {
        if let inFlight = staleRefreshTask {
            await inFlight.value
            return
        }
        // The run clears its own slot so a caller arriving after the last await starts a fresh run
        // rather than awaiting a finished task.
        let run = Task { @MainActor [weak self] in
            defer { self?.staleRefreshTask = nil }
            guard let self else { return }
            await self.store.refreshIfStale()
            await self.loadWhatsNew()
        }
        staleRefreshTask = run
        staleRefreshRunCount += 1
        await run.value
    }
    func refresh() async {
        await store.refreshNow()
        await loadWhatsNew()
    }

    func toggleNode(_ nodeID: String) {
        TaxonomyStore.shared.toggle(nodeID)
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion,
                        nodeIDs: TaxonomyStore.shared.selectedNodeIDs,
                        type: store.activeContentType, mood: store.activeMood,
                        languages: languages)
    }

    /// Seeds the first reading lens from onboarding in one atomic update.
    /// Keeping the selection local until the final button avoids launching a
    /// filter reload (and an urgent network batch) for every tapped interest.
    func applyOnboardingTopics(_ nodeIDs: Set<String>) {
        let validNodeIDs = nodeIDs.filter { TaxonomyStore.shared.node(id: $0) != nil }
        guard !validNodeIDs.isEmpty else { return }

        TaxonomyStore.shared.selectedNodeIDs = Set(validNodeIDs)
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(
            region: store.activeRegion,
            nodeIDs: Set(validNodeIDs),
            type: store.activeContentType,
            mood: store.activeMood,
            languages: languages
        )
    }

    func toggleLanguage(_ code: String) {
        var langs = store.activeLanguages
        if langs.contains(code) {
            langs.remove(code)
        } else {
            langs.insert(code)
        }
        // Removing the last selected language is an explicit "all languages" choice.
        store.hasUserClearedLanguageFilter = langs.isEmpty
        store.setFilter(region: store.activeRegion,
                        nodeIDs: store.activeNodeIDs,
                        type: store.activeContentType, mood: store.activeMood,
                        languages: langs)
    }

    func clearTaxonomySelection() {
        TaxonomyStore.shared.clearSelection()
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion,
                        nodeIDs: [],
                        type: store.activeContentType, mood: store.activeMood,
                        languages: languages)
    }

    func clearRegionFilter() {
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: nil,
                        nodeIDs: store.activeNodeIDs,
                        type: store.activeContentType, mood: store.activeMood,
                        languages: languages)
    }

    /// Backward-compat shim for single-category selection.
    func selectCategory(_ category: String?) {
        if let cat = category {
            if let node = TaxonomyStore.shared.flatIndex.values.first(where: { $0.name == cat }) {
                toggleNode(node.id)
            }
        } else {
            clearTaxonomySelection()
        }
    }

    func selectMood(_ mood: MoodFilter) {
        let newValue = (store.activeMood == mood) ? .all : mood
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion, nodeIDs: store.activeNodeIDs,
                        type: store.activeContentType, mood: newValue,
                        languages: languages)
    }

    func selectContentType(_ type: ContentType) {
        let newValue = (store.activeContentType == type) ? .all : type
        let languages = resolvedLanguagesForFilter(store.activeLanguages)
        store.setFilter(region: store.activeRegion, nodeIDs: store.activeNodeIDs,
                        type: newValue, mood: store.activeMood,
                        languages: languages)
    }

    /// Return the user's effective language filter. When no explicit choice
    /// has been made and the user hasn't opted into "all languages," default
    /// to the device language so that content-type-only filters don't show
    /// videos/articles from every language.
    private func resolvedLanguagesForFilter(_ selected: Set<String>) -> Set<String> {
        if !selected.isEmpty { return selected }
        if store.hasUserClearedLanguageFilter { return [] }
        guard let deviceLang = FeedStore.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        ) else { return [] }
        return store.registry.availableLanguageCodes.contains(deviceLang) ? [deviceLang] : []
    }

    func clearAllFilters(preservingSearch: Bool = false) {
        if !preservingSearch {
            clearSubmittedSearch()
        }
        TaxonomyStore.shared.clearSelection()
        if activePreset != .everything {
            store.setPreset(.everything)
        }
        store.clearAllFilters()
    }

    func clearReadHistory() {
        store.clearReadHistory()
    }

    func clearAllBookmarks() {
        bookmarkItemIDs.removeAll()
        store.clearAllBookmarks()
        Task { await refreshBookmarkState() }
    }

    func resetAllSourceToggles() {
        store.resetAllSourceToggles()
    }

    /// Commits the visible tag set. Typing in the draft field never calls this;
    /// Return or the explicit add button is the only search trigger.
    func submitSearchTerms(_ terms: [SearchTerm]) {
        submittedSearchTerms = terms
        searchQuery = SearchExpression(terms: terms).displayQuery
        refreshSubmittedSearch()
    }

    func refreshSubmittedSearch() {
        let expression = SearchExpression(terms: submittedSearchTerms)
        if expression.canSearch {
            store.search(
                expression,
                includeSources: searchIncludesSources,
                includeContents: searchIncludesContents,
                demandOnlineContent: searchDemandsOnlineContent
            )
        } else {
            store.clearSearch()
        }
    }

    func clearSubmittedSearch() {
        submittedSearchTerms = []
        searchQuery = ""
        store.clearSearch()
    }

    /// Compatibility entry point for older UI paths that assign a one-line
    /// query. New search UI should use `submitSearchTerms(_:)`.
    func searchQueryChanged() {
        submittedSearchTerms = SearchExpression(legacyQuery: searchQuery).terms
        refreshSubmittedSearch()
    }

    func cancelSearchScan() {
        store.cancelSearchScan()
    }

    var lastToggleMessage: String? { store.lastToggleMessage }

    func toggleRegion(_ region: String) {
        store.toggleRegion(region)
    }
    func setRegionEnabled(_ region: String, enabled: Bool) {
        store.setRegionEnabled(region, enabled: enabled)
    }
    func regionToggleState(for region: String) -> DeferredToggleState {
        pendingRegionToggleStates[region] ?? .none
    }
    func requestRegionEnabled(_ region: String, enabled: Bool) {
        let requested: DeferredToggleState = enabled ? .enabled : .disabled
        pendingRegionToggleStates[region] = requested
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingRegionToggleStates[region] == requested else { return }
            self.store.setRegionEnabled(region, enabled: enabled)
            if self.pendingRegionToggleStates[region] == requested {
                self.pendingRegionToggleStates.removeValue(forKey: region)
            }
        }
    }

    func clearToggleMessage() {
        store.lastToggleMessage = nil
    }
    func beginFilterEditing() { store.beginFilterEditing() }
    func endFilterEditing() { store.endFilterEditing() }
    func applyFilterDraft(type: ContentType, mood: MoodFilter, languages: Set<String>) {
        store.hasUserClearedLanguageFilter = languages.isEmpty
        store.setFilter(
            region: store.activeRegion,
            nodeIDs: store.activeNodeIDs,
            type: type,
            mood: mood,
            languages: languages
        )
    }
    func toggleAllCountries() {
        store.toggleAllCountries()
    }
    func setAllCountriesEnabled(_ enabled: Bool) {
        store.setAllCountriesEnabled(enabled)
    }
    // MARK: - Feed Presets

    /// The active feed preset. Drives scoring multipliers across the fetch pipeline.
    var activePreset: PresetSelector {
        get { store.activePreset }
    }

    /// Change the active preset and trigger a feed reload with new scoring.
    func setActivePreset(_ preset: PresetSelector) {
        store.setPreset(preset)
    }

    func loadCuratedFeeds() async throws -> [CuratedFeed] {
        try await store.allCuratedFeeds()
    }

    /// Returns items ordered by how well they match a profile, without
    /// persisting or changing global state. Used for the onboarding preview.
    func previewCuratedFeed(
        profile: CuratedProfileDefinition,
        limit: Int = 5
    ) -> [FeedItem] {
        let sources = store.registry.sources
        let multipliers = CuratedPreferenceEngine.sourceMultipliers(
            sources: sources,
            profile: profile
        )
        guard !multipliers.isEmpty else {
            return Array(items.prefix(limit))
        }
        return items
            .map { item -> (FeedItem, Double) in
                let score = multipliers[item.sourceURL] ?? 1.0
                return (item, score)
            }
            .filter { $0.1 > 1.0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Returns fully prepared feed cards for the Composer preview zone.
    /// Uses the recipe+evidence merge, scores via sourceMultipliers,
    /// and resolves card presentations (image + layout) before returning.
    /// Cancellable — check Task.isCancelled between stages.
    func previewCuratedCards(
        recipe: FeedRecipeDefinition?,
        evidence: CuratedProfileDefinition,
        limit: Int = 3
    ) async -> [FeedCardPresentation] {
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        let sources = store.registry.sources
        let multipliers = CuratedPreferenceEngine.sourceMultipliers(
            sources: sources,
            profile: effective
        )

        let candidates: [FeedItem]
        if multipliers.isEmpty {
            candidates = Array(items.prefix(limit * 2))
        } else {
            candidates = items
                .map { item -> (FeedItem, Double) in
                    (item, multipliers[item.sourceURL] ?? 1.0)
                }
                .filter { $0.1 > 1.0 }
                .sorted { $0.1 > $1.1 }
                .prefix(limit * 2)
                .map { $0.0 }
        }

        guard !candidates.isEmpty else { return [] }
        guard !Task.isCancelled else { return [] }

        // Resolve presentations in parallel
        return await withTaskGroup(
            of: (Int, FeedCardPresentation?).self
        ) { group in
            for (index, item) in candidates.enumerated() {
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    let presentation = await Self.resolvePresentation(for: item)
                    return (index, presentation)
                }
            }

            var results: [(Int, FeedCardPresentation)] = []
            for await (index, presentation) in group {
                if let presentation {
                    results.append((index, presentation))
                }
            }

            return results
                .sorted { $0.0 < $1.0 }
                .prefix(limit)
                .map { $0.1 }
        }
    }

    /// Resolve a single card presentation — mirrors CollectionManagementView pattern.
    private nonisolated static func resolvePresentation(
        for item: FeedItem
    ) async -> FeedCardPresentation {
        let imageURL = item.imageURL.flatMap(URL.init(string:))
        let articleURL = URL(string: item.url)

        let media: ResolvedCardMedia
        if let resolvedImage = await ImageLoader.resolveImage(
            url: imageURL,
            articleURL: articleURL
        ) {
            media = .image(resolvedImage)
        } else if imageURL != nil || articleURL != nil {
            media = .placeholder
        } else {
            media = .none
        }

        let layout: FeedCardLayout
        switch media {
        case .image: layout = .hero
        case .placeholder: layout = .hero
        case .none: layout = .textOnly
        }

        return FeedCardPresentation(
            item: item,
            media: media,
            layout: layout,
            isRead: false,
            isBookmarked: false
        )
    }

    func curatedFeed(id: Int64) async throws -> CuratedFeed? {
        try await store.curatedFeed(id: id)
    }

    @discardableResult
    func createCuratedFeed(
        name: String,
        definition: CuratedProfileDefinition,
        recipe: FeedRecipeDefinition? = nil
    ) async throws -> CuratedFeed {
        try await store.createCuratedFeed(
            name: name,
            definition: definition,
            recipe: recipe
        )
    }

    @discardableResult
    func updateCuratedFeed(
        id: Int64,
        name: String,
        definition: CuratedProfileDefinition,
        recipe: FeedRecipeDefinition? = nil
    ) async throws -> CuratedFeed {
        try await store.updateCuratedFeed(
            id: id,
            name: name,
            definition: definition,
            recipe: recipe
        )
    }

    func deleteCuratedFeed(id: Int64) async throws {
        try await store.deleteCuratedFeed(id: id)
    }

    func applyCuratedLanguages(_ languages: Set<String>) {
        store.hasUserClearedLanguageFilter = false
        store.setFilter(
            region: store.activeRegion,
            nodeIDs: store.activeNodeIDs,
            type: store.activeContentType,
            mood: store.activeMood,
            languages: languages
        )
    }

    func curatedOnboardingCandidates(
        languages: Set<String>
    ) async -> [CuratedCandidate] {
        let items = await store.curatedOnboardingItems(languages: languages)
        return CuratedPreferenceEngine.makeCandidates(
            items: items,
            sources: store.registry.sources,
            languages: languages
        )
    }

    func loadSmartFeeds() async throws -> [SmartFeed] {
        try await store.allSmartFeeds()
    }

    @discardableResult
    func createSmartFeed(
        name: String,
        query: String,
        includeSources: Bool,
        includeContents: Bool
    ) async throws -> SmartFeed {
        let smartFeed = try await store.createSmartFeed(
            name: name,
            query: query,
            includeSources: includeSources,
            includeContents: includeContents
        )
        SmartFeedBackgroundScheduler.shared.schedule()
        return smartFeed
    }

    @discardableResult
    func createSmartFeed(
        name: String,
        terms: [SearchTerm],
        includeSources: Bool,
        includeContents: Bool
    ) async throws -> SmartFeed {
        let smartFeed = try await store.createSmartFeed(
            name: name,
            expression: SearchExpression(terms: terms),
            includeSources: includeSources,
            includeContents: includeContents
        )
        SmartFeedBackgroundScheduler.shared.schedule()
        return smartFeed
    }

    func deleteSmartFeed(id: Int64) async throws {
        try await store.deleteSmartFeed(id: id)
    }

    func setActivityState(_ state: FeedActivityState) {
        store.setActivityState(state)
    }

    /// One bounded background demand, served by the store that owns acquisition in this process
    /// (plan §14 PR-15). The loader is the scheduler's owner, not a builder: nothing here constructs a
    /// second store or fetcher, which is what closes P9.
    func runBackgroundRefresh(_ demand: BackgroundRefreshDemand) async -> BackgroundRefreshDemandReport {
        await store.runBackgroundRefreshDemand(demand)
    }

    // MARK: - Legacy Global Feeds (kept for backward compat)

    func toggleGlobalFeeds() {
        setGlobalFeedsEnabled(!isGlobalFeedsEnabled)
    }
    func setGlobalFeedsEnabled(_ enabled: Bool) {
        store.setTopicRegionsEnabled(enabled)
    }
    func toggleSource(_ sourceURL: String) { store.toggleSource(sourceURL) }
    /// True if the region is not explicitly disabled. Partial (disabled but
    /// some sources overridden) still counts as disabled from the user's POV.
    func isRegionEnabled(_ region: String) -> Bool { store.registry.status(of: SourceRegistry.regionKey(region)) == .on }
    func isSourceEnabled(_ url: String) -> Bool { store.registry.isSourceEnabled(url) }
    func nodeStatus(for key: String) -> NodeStatus { store.registry.status(of: key) }
    func activeCount(for key: String) -> Int { store.registry.activeCount(for: key) }
    func toggleCategory(_ category: String) { store.toggleCategory(category) }
    func setCategoryEnabled(_ category: String, enabled: Bool) {
        store.setCategoryEnabled(category, enabled: enabled)
    }
    /// True if the category is not explicitly disabled.
    func isCategoryEnabled(_ category: String) -> Bool { store.registry.status(of: SourceRegistry.categoryKey(category)) == .on }
    var isAnyCountryEnabled: Bool { store.registry.isAnyCountryEnabled }
    /// True when at least one topic region (or legacy global) is enabled.
    /// A partial state (some on, some off) still returns true — the toggle
    /// will turn everything off.  Use `globalFeedsStatus` for the three-way
    /// ON / OFF / PARTIAL distinction in UI.
    var isGlobalFeedsEnabled: Bool {
        let topicRegions = store.registry.allTopicRegions
        if !topicRegions.isEmpty {
            return topicRegions.contains { store.registry.status(of: SourceRegistry.regionKey($0)) == .on }
        }
        return store.registry.status(of: SourceRegistry.regionKey("global")) == .on
    }

    /// Three-way status for the Global Feeds toggle: ON (all topic groups
    /// enabled), OFF (none enabled), or PARTIAL (some enabled).
    var globalFeedsStatus: NodeStatus {
        let topicRegions = store.registry.allTopicRegions
        let keys = topicRegions.isEmpty
            ? [SourceRegistry.regionKey("global")]
            : topicRegions.map { SourceRegistry.regionKey($0) }
        let statuses = keys.map { store.registry.status(of: $0) }
        let onCount = statuses.filter { $0 == .on }.count
        if onCount == keys.count { return .on }
        if onCount == 0 { return .off }
        return .partial(activeCount: store.registry.sources
            .filter { $0.region.hasPrefix("topic/") || $0.region == "global" }
            .filter { store.registry.isSourceEnabled($0.url) }
            .count)
    }

    func markAsSeen(_ itemID: String) { store.markAsSeen(itemID) }
    func markAsRead(_ itemID: String) { store.markAsRead(itemID) }
    func markAsClicked(_ itemID: String) { store.markAsClicked(itemID) }
    func markAsUnread(_ itemID: String) { store.markAsUnread(itemID) }
    func isRead(_ itemID: String) -> Bool { store.readItemIDs.contains(itemID) }

    // MARK: - Bookmark Lists

    /// The legacy store that owns `user.sqlite` and the content database a bookmark is read from.
    ///
    /// Exposed for the runtime's durable user-state port: a bookmark taken on a runtime card has to land
    /// in the same two databases the app's own bookmark surface reads, and those databases are this
    /// store's (`RuntimeCardUserActions`). Nothing else about the store becomes public here.
    var bookmarkStore: BookmarkStore { store.bookmarkStore }

    func loadBookmarkLists() async throws -> [BookmarkList] {
        try await store.allBookmarkLists()
    }

    func loadBookmarkedItems(listID: Int64) async throws -> [FeedItem] {
        try await store.bookmarkedItems(listID: listID)
    }

    func toggleBookmark(_ itemID: String, listID: Int64? = nil) {
        let targetListID = listID ?? store.preferredBookmarkListID
        Task {
            try? await store.toggleBookmark(itemID: itemID, listID: targetListID)
            await refreshBookmarkState()
        }
    }

    var preferredBookmarkListID: Int64? {
        get { store.preferredBookmarkListID }
        set { store.preferredBookmarkListID = newValue }
    }

    /// Cached bookmark lists for context menus — loaded at startup, refreshed on changes.
    var bookmarkLists: [BookmarkList] = []

    func refreshBookmarkLists() async {
        do { bookmarkLists = try await store.allBookmarkLists() }
        catch {}
    }

    @discardableResult
    func createBookmarkList(name: String) async throws -> Int64 {
        try await store.createBookmarkList(name: name)
    }

    func renameBookmarkList(_ id: Int64, name: String) async throws {
        try await store.renameBookmarkList(id, name: name)
    }

    func reorderBookmarkList(_ id: Int64, sortOrder: Int) async throws {
        try await store.reorderBookmarkList(id, sortOrder: sortOrder)
    }

    func deleteBookmarkList(_ id: Int64) async throws {
        try await store.deleteBookmarkList(id)
    }

    func loadActiveSearches() async throws -> [ActiveSearch] {
        try await store.activeSearches()
    }

    func toggleSearchActive(listID: Int64) async throws {
        try await store.toggleSearchActive(listID: listID)
        await refreshActiveSearchState()
    }

    /// Whether any persistent search is currently active.
    private(set) var hasActiveSearches = false

    /// Items from active saved searches — displayed separately from What's New
    /// so the two features don't compete for the same state.
    private(set) var activeSearchItems: [FeedItem] = []

    private func refreshActiveSearchState() async {
        do {
            let searches = try await store.activeSearches()
            hasActiveSearches = !searches.isEmpty
            if hasActiveSearches {
                activeSearchItems = try await store.compositeSearchFeed()
            } else {
                activeSearchItems = []
            }
        } catch {
            hasActiveSearches = false
            activeSearchItems = []
        }
    }

    func isBookmarked(_ itemID: String) -> Bool {
        bookmarkItemIDs.contains(itemID)
    }

    func markAllAsRead() {
        store.markAllAsRead(items.map(\.id))
    }

    func shakeToRefresh() {
        clearSubmittedSearch()
        store.shakeToRefresh()
    }

    func pullToRefresh() async {
        clearSubmittedSearch()
        store.shakeToRefresh()
        // `shakeToRefresh` owns a guarded async flush/fetch pipeline. Keep the
        // system refresh indicator visible long enough for the first publish.
        try? await Task.sleep(for: .milliseconds(450))
        await loadWhatsNew()
    }

    func emergencyTrim() { store.emergencyTrim() }

    var reservoirCount: Int { store.reservoirCount }
    var lastRefreshDate: Date? { store.lastRefreshDate }

    // MARK: - Source helpers

    func sourceReference(for item: FeedItem) -> SourceReference {
        store.sourceReference(for: item)
    }

    func sourceReference(for member: SourceCollectionMember) -> SourceReference {
        store.sourceReference(for: member)
    }

    func sourceContentFromCache(_ source: SourceReference) async -> [FeedItem] {
        await store.sourceContentFromCache(source)
    }

    func loadSourceContent(_ source: SourceReference) async -> SourceContentResult {
        await store.loadSourceContent(source)
    }

    func loadSourceCollections() async throws -> [SourceCollection] {
        try await store.allSourceCollections()
    }

    @discardableResult
    func createSourceCollection(name: String) async throws -> Int64 {
        try await store.createSourceCollection(name: name)
    }

    func renameSourceCollection(id: Int64, name: String) async throws {
        try await store.renameSourceCollection(id: id, name: name)
    }

    func deleteSourceCollection(id: Int64) async throws {
        try await store.deleteSourceCollection(id: id)
    }

    func reorderSourceCollections(ids: [Int64]) async throws {
        try await store.reorderSourceCollections(ids: ids)
    }

    func sourceCollectionMembers(collectionID: Int64) async throws -> [SourceCollectionMember] {
        try await store.sourceCollectionMembers(collectionID: collectionID)
    }

    func addSource(_ source: SourceReference, toCollectionID id: Int64) async throws {
        try await store.addSource(source, toCollectionID: id)
    }

    @discardableResult
    func addSourceURLs(_ sourceURLs: [String], toCollectionID id: Int64) async throws -> Int {
        try await store.addSourceURLs(sourceURLs, toCollectionID: id)
    }

    func removeSource(_ sourceURL: String, fromCollectionID id: Int64) async throws {
        try await store.removeSource(sourceURL, fromCollectionID: id)
    }

    func reorderSourceCollectionMembers(collectionID: Int64, sourceURLs: [String]) async throws {
        try await store.reorderSourceCollectionMembers(collectionID: collectionID, sourceURLs: sourceURLs)
    }

    func sourceCollectionIDs(containing sourceURL: String) async throws -> Set<Int64> {
        try await store.sourceCollectionIDs(containing: sourceURL)
    }

    func loadSourceCollectionContent(collectionID: Int64) async throws -> SourceCollectionContentResult {
        try await store.loadSourceCollectionContent(collectionID: collectionID)
    }

    // MARK: - Import Pipeline

    private let importPipeline = ImportPipeline()

    /// Legacy addSources — still works but prefer importFeeds for new code.
    func addSources(_ newSources: [FeedSource]) {
        store.registry.sources = OPMLParser.deduplicateSources(
            store.registry.sources + newSources
        )
        persistImportedSources()
        Task {
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
        }
        // Trigger fetch for new sources + reload feed
        Task { await fetchAndReloadAfterImport(newSources) }
    }

    /// Replace the entire source list (used by collection management: rename, delete, move).
    func replaceAllSources(_ sources: [FeedSource]) {
        store.registry.sources = sources
        persistImportedSources()
        Task {
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
        }
    }

    /// Import feed URLs (paste, share sheet, etc.) with full validation.
    /// Pass `skipValidation: true` when URLs come from URLResolver (already probed).
    /// Returns ImportResult for UI feedback.
    func importFeeds(urls: [String], category: String = "Imported", skipValidation: Bool = false) async -> ImportResult {
        // P0-01: Identity for dedup uses normalizeURL; requestURL preserves
        // authorization/signed parameters for fetching. existingURLs tracks
        // canonical identities of sources already in the registry.
        let existingURLs = Set(store.registry.sources.map { OPMLParser.normalizeURL($0.url) })

        if skipValidation {
            // URLs already validated by URLResolver — skip probe, just dedup + register
            var results: [ImportItemResult] = []
            var newSources: [FeedSource] = []
            var seenIdentities = existingURLs
            for rawURL in urls {
                let identity = OPMLParser.normalizeURL(rawURL)
                let request = OPMLParser.requestURL(rawURL)
                if seenIdentities.contains(identity) {
                    results.append(ImportItemResult(url: rawURL, title: nil, status: .duplicate))
                } else {
                    seenIdentities.insert(identity)
                    let kind = ImportPipeline.detectMediaKind(url: request, title: nil)
                    let source = FeedSource(
                        title: ImportPipeline.titleFromURL(request),
                        url: request,  // P0-01: store the fetchable URL
                        category: category, region: "imported", mediaKind: kind
                    )
                    newSources.append(source)
                    results.append(ImportItemResult(url: rawURL, title: source.title, status: .imported))
                }
            }
            if !newSources.isEmpty {
                store.registry.sources = OPMLParser.deduplicateSources(
                    store.registry.sources + newSources
                )
                persistImportedSources()
                await TaxonomyStore.shared.build(
                    from: store.registry.sources,
                    sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
                )
                await fetchAndReloadAfterImport(newSources)
            }
            return ImportResult(items: results)
        }

        let (result, sources) = await importPipeline.ingest(
            urls: urls, category: category, existingURLs: existingURLs
        )
        if !sources.isEmpty {
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + sources
            )
            persistImportedSources()
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
            await fetchAndReloadAfterImport(sources)
        }
        return result
    }

    /// Import from OPML file data (file picker, AirDrop).
    func importOPML(data: Data, fileName: String, validate: Bool = false) async -> ImportResult {
        let existingURLs = Set(store.registry.sources.map { OPMLParser.normalizeURL($0.url) })
        let (result, sources) = await importPipeline.ingest(
            opmlData: data, fileName: fileName, existingURLs: existingURLs, validate: validate
        )
        if !sources.isEmpty {
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + sources
            )
            persistImportedSources()
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
            await fetchAndReloadAfterImport(sources)
        }
        return result
    }

    /// Import from a remote OPML URL.
    func importOPML(url: URL, validate: Bool = false) async -> ImportResult? {
        let existingURLs = Set(store.registry.sources.map { OPMLParser.normalizeURL($0.url) })
        guard let (result, sources) = await importPipeline.ingest(
            opmlURL: url, existingURLs: existingURLs, validate: validate
        ) else { return nil }
        if !sources.isEmpty {
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + sources
            )
            persistImportedSources()
            await TaxonomyStore.shared.build(
                from: store.registry.sources,
                sharedCountrySourceURLs: store.registry.sharedCountrySourceURLs
            )
            await fetchAndReloadAfterImport(sources)
        }
        return result
    }

    /// After importing new sources: fetch their content immediately and reload the feed.
    private func fetchAndReloadAfterImport(_ sources: [FeedSource]) async {
        let batch = Array(sources.prefix(20))  // Cap first fetch to 20 sources
        // P5: imported endpoints are a demand like any other; the reload below still runs unconditionally.
        let grant = store.claimSourceDemand(batch.map(\.url), purpose: .importRefresh)
        let grantedURLs = Set(grant.led)
        let grantedBatch = batch.filter {
            grantedURLs.contains(OPMLParser.normalizeURL($0.url))
        }
        if !grantedBatch.isEmpty {
            let result = await store.fetcher.fetchAll(grantedBatch, maxConcurrent: 5)
            store.finishSourceDemand(grant, outcomes: result.sourceOutcomes)
            let actualNew = await store.persistFetchedItems(result.items)
            if !actualNew.isEmpty {
                store.throttledReservoirAppend(actualNew)
                store.collectWhatsNewCandidates(actualNew)
            }
        }
        // Force reload to show new content
        store.setFilter(
            region: store.activeRegion,
            nodeIDs: store.activeNodeIDs,
            type: store.activeContentType,
            mood: store.activeMood,
            languages: store.activeLanguages
        )
    }

    /// P0-04: Persist imported sources into user.sqlite instead of a fragile
    /// standalone JSON file. The SQLite store shares the transaction, migration,
    /// backup, and conflict rules used for all other user state.
    ///
    /// The legacy `imported_sources.json` is deliberately NOT deleted here.
    /// This runs on every import — including a run whose registry has not been
    /// restored yet, where saving would replace the table with an empty set and
    /// the JSON would be the last copy of the user's sources.
    /// `migrateImportedSourcesFromJSONIfNeeded()` owns that file: it commits the
    /// rows and the completion marker in one transaction and removes the file
    /// only after that commit.
    private func persistImportedSources() {
        let imported = store.registry.sources.filter { $0.region == "imported" }
        do {
            try store.userRepo.saveImportedSources(imported)
        } catch {
            Log.import_.error("Failed to persist imported sources: \(error)")
        }
    }

    /// Restore previously imported sources from user.sqlite on app launch.
    /// Merges them into the registry without duplicating bundled sources.
    @discardableResult
    private func restoreImportedSources() -> Bool {
        do {
            // One-time migration from legacy JSON to SQLite
            store.userRepo.migrateImportedSourcesFromJSONIfNeeded()
            let imported = try store.userRepo.loadImportedSources()
            guard !imported.isEmpty else { return false }
            let sourceCountBeforeRestore = store.registry.sources.count
            store.registry.sources = OPMLParser.deduplicateSources(
                store.registry.sources + imported
            )
            store.registry.prepareFilterCaches()
            Log.import_.info("Restored \(imported.count) imported sources from user.sqlite")
            return store.registry.sources.count > sourceCountBeforeRestore
        } catch {
            Log.import_.error("Failed to restore imported sources: \(error)")
            return false
        }
    }

    func regionFeeds(for regionPath: String) -> [FeedSource] {
        store.registry.sources
            .filter { $0.region == regionPath }
            .sorted { $0.category < $1.category || ($0.category == $1.category && $0.title < $1.title) }
    }

    func countryFeeds(for region: String) -> [FeedSource] {
        regionFeeds(for: region)
    }

    func subRegions(for countryRegion: String) -> [String] {
        let prefix = "\(countryRegion)/"
        return store.registry.sources
            .map(\.region)
            .filter { $0.hasPrefix(prefix) }
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            .sorted()
    }
}
