import SwiftUI
import UIKit

struct FeedScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(FeedLoader.self) private var loader
    /// The launch's runtime: which mode is running, and the observations/intents this screen may
    /// produce (PR-13). The mode is fixed at launch, so nothing here re-decides it.
    @Environment(MainFeedRuntime.self) private var runtime
    @State private var articleItem: FeedItem?
    /// The last item the viewport observation saw, in the page's own order. It is what the persisted
    /// scroll position is written from (the card identity of ADR-001 is carried by the legacy id until
    /// the runtime allocates one — PR-14).
    @State private var lastVisibleItemID: String?
    /// Uncommitted text in the field. It does not trigger a search until Return
    /// or the add button turns it into a tag.
    @State private var searchText = ""
    @State private var searchTerms: [SearchTerm] = []
    @State private var isSearching = false
    @State private var selectedSource: SourceReference?
    @State private var sourceToCollect: SourceReference?
    @FocusState private var searchFocused: Bool
    @State private var showSettings = false
    @State private var showSources = false
    @State private var showFilters = false
    @State private var showBookmarks = false
    @State private var showAddFeed = false
    @State private var addFeedCollectionID: Int64?
    @State private var addFeedCollectionName: String?
    @State private var showCollections = false
    @State private var showExport = false
    @State private var showCollectionExport = false
    @State private var showCollectionImporter = false
    @State private var showCreateCollectionPrompt = false
    @State private var createCollectionName = ""
    @State private var pendingCollectionSources: [SourceReference] = []
    @State private var showCreateSmartFeedPrompt = false
    @State private var createSmartFeedName = ""
    @State private var showDeleteSmartFeedConfirmation = false
    @State private var showCuratedOnboarding = false
    @State private var showCuratedInspector = false
    @State private var showDeleteCuratedFeedConfirmation = false
    @State private var showCatalogExplore = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastIcon = "checkmark"
    @State private var headerHeight: CGFloat = 48
    @State private var searchControlsHeight: CGFloat = 92
    @State private var filterLensExpanded = true
    @State private var lastScrollOffset: CGFloat = 0
    @State private var filterLensCollapseTask: Task<Void, Never>?
    @State private var engine = CircadianEngine.shared
    @AppStorage("showDebugBar") private var showDebugBar = false
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("lastScrollItemID") private var lastScrollItemID = ""
    @AppStorage("filterLensDismissedSignature") private var filterLensDismissedSignature = ""
    @AppStorage("searchIncludesSources") private var searchIncludesSources = true
    @AppStorage("searchIncludesContents") private var searchIncludesContents = false
    @State private var scrollTargetID: String? = nil
    /// True once the user has actually scrolled the feed. Gates the one-shot
    /// cold-start position restore so it can never yank a user who already
    /// started reading. (Feed is sacred: it doesn't move on its own.)
    @State private var userHasScrolled = false
    @State private var didRestoreScroll = false
    @State private var didRecordFirstScreen = false
    @State private var didRecordFirstUsefulContent = false
    @State private var player = AudioPlayerManager.shared

    /// The empty surface for a selection the runtime does not own, from the legacy page's own state:
    /// preset and taxonomy filters, whether a filtered composition is in flight, and what the page has
    /// actually fetched so far. It is only read by `legacyFeedContent`; the surface the session owns
    /// states its empty variant itself (`MainFeedSessionSurface.empty`), because the snapshot carries no
    /// filters and the runtime's own acquisition counters are not part of it.
    private var emptyMode: FeedEmptyMode {
        let activeTopic = (loader.activePreset.isSmartFeed || loader.activePreset.isCuratedFeed)
            ? loader.activePreset.displayName
            : loader.selectedNodeNames.joined(separator: ", ")
        if loader.sources.isEmpty || (!loader.isGlobalFeedsEnabled && !loader.isAnyCountryEnabled) {
            return .noSourcesEnabled
        }
        if loader.hasActiveFilters && loader.items.isEmpty && (loader.loadingState == .refreshing || loader.isUrgentFetching) {
            return .fetching(
                topic: activeTopic,
                fetched: loader.emptyStateFetchedCount,
                total: loader.selectedNodeIDs.reduce(0) { $0 + (TaxonomyStore.shared.node(id: $1)?.feedCount ?? 0) }
            )
        }
        if loader.hasActiveFilters, loader.items.isEmpty, loader.isPreparingFilteredComposition {
            // The composition for this filter is still being fetched and prepared: show the in-progress
            // surface, not an absence. Measured: a type filter with no local content of that type has
            // nothing for several seconds (audio: first pass 0 items, next pass 20), and "no results"
            // there is the user's "empty screens appearing for no reason". A finished empty answer still
            // settles, because the flag clears when the generation's flush completes.
            return .fetching(
                topic: activeTopic,
                fetched: loader.emptyStateFetchedCount,
                total: loader.selectedNodeIDs.reduce(0) { $0 + (TaxonomyStore.shared.node(id: $1)?.feedCount ?? 0) }
            )
        }
        if loader.hasActiveFilters && loader.items.isEmpty && loader.loadingState == .idle {
            return .noResults(topic: activeTopic)
        }
        return .generic
    }

    /// The number of cards the page the reader is on is drawing, in that page's own terms: the session's
    /// published cards for the surface the session owns, the legacy page's items everywhere else.
    ///
    /// It is the subject of the "first useful content" metric, which used to read the legacy page in
    /// every mode — in `v2Full` that page is the cached one, so the interval it measured was not the one
    /// the reader saw.
    private var surfaceContentCount: Int {
        guard let surface = runtime.sessionSurface else { return loader.items.count }
        return surface == .content ? runtime.presentation.ordinalCount : 0
    }

    var body: some View {
        screenWithSheets
    }

    private var screenContent: some View {
        ZStack(alignment: .top) {
            // Full-bleed feed content with circadian page tint. The 2s period
            // crossfade is scoped to this background only — attaching it higher
            // (screenWithSheets) animated every animatable property in the whole
            // hierarchy. Skipped entirely under Reduce Motion.
            engine.pageBackground
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.0), value: engine.period)

            if isSearching && hasCommittedSearch {
                unifiedSearchPanel
            } else if let session = runtime.sessionSurface {
                sessionFeedContent(session)
            } else {
                legacyFeedContent
            }

            // Floating compact header
            VStack(spacing: 0) {
                compactHeader
                if isSearching { searchBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
            }

            // Shake detector. On the surface the session owns, the refresh is the session's: the legacy
            // store's own refresh is refused by `LegacyAcquisitionGate` in that mode, so the gesture
            // would otherwise do nothing at all.
            ShakeDetector {
                if runtime.sessionSurface != nil {
                    Task { await runtime.refresh() }
                } else {
                    loader.shakeToRefresh()
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            // Mini player bar — full-width bottom bar, always on top
            VStack {
                Spacer()
                MiniPlayerBar()
                    .background(.ultraThinMaterial)
            }

            // Toast + Onboarding overlays
            toastOverlay
            OnboardingTipsView()
        }
    }

    /// The feed's content for a selection this launch's runtime owns (plan §17, DoD2).
    ///
    /// Everything the surface says about itself — whether there is a page, whether it is empty, which
    /// empty surface to show — is the session boundary's own statement, and the rows are the session's
    /// snapshots. Nothing here reads the legacy loader: it keeps running in this mode (hydration,
    /// filters, taxonomy, the cached page) but it is not this surface's source of truth, and the page it
    /// holds for this selection is the cached one.
    @ViewBuilder
    private func sessionFeedContent(_ surface: MainFeedSessionSurface) -> some View {
        switch surface {
        case .preparing:
            // The loading chrome on this surface is the runtime's own statement. The legacy startup
            // runway's counters are not read here at all — in this mode the legacy engine's requests are
            // refused by the gate, so those counters are not this launch's acquisition.
            InitialFeedLoadingView(session: runtime.sessionLoadingStatement)
        case .content:
            // A refresh in flight does not empty this surface: the session keeps its last snapshot until
            // the next one lands, so the page the reader is on stays until there is a new one.
            feedScrollView(legacyPageFallback: false)
        case .empty(let mode):
            // The empty surface on this selection is the runtime's own statement — the variant the
            // session states plus its acquisition where the legacy wording owed a source count. The
            // legacy loader's counters are not read here at all: in this mode its page is the cached
            // one and its fetches are refused by the gate.
            FeedEmptyStateView(
                mode: mode,
                onRefresh: { await runtime.refresh() },
                session: runtime.sessionEmptyStatement
            )
        }
    }

    /// The feed's content for a selection the runtime does not own — and for every mode but the
    /// acquiring one, unchanged from before this slice.
    ///
    /// The phase, the emptiness and the empty-state variant come from the legacy loader's own page,
    /// which is the page that selection actually has. In `v2Full` too: the gate refuses *fetches*
    /// (`RSSFetcher.performFetch`), and the store's local content, filters and taxonomy keep working, so
    /// a bookmark box or a Smart Feed still draws its own articles.
    @ViewBuilder
    private var legacyFeedContent: some View {
        switch loader.feedDisplayPhase {
        case .preparing where !loader.items.isEmpty:
            // The store keeps the displayed page while a rebuild runs, and setFilter /
            // manualRefresh both enter `.preparing`. Swapping to the loading screen here
            // would blank a feed the user is already reading; the page stays until the new
            // composition lands.
            feedScrollView(legacyPageFallback: !loader.items.isEmpty)
        case .preparing:
            InitialFeedLoadingView()
        case .ready where loader.items.isEmpty:
            FeedEmptyStateView(mode: emptyMode)
        case .ready:
            feedScrollView(legacyPageFallback: !loader.items.isEmpty)
        case .empty where loader.items.isEmpty:
            FeedEmptyStateView(mode: emptyMode)
        case .empty:
            feedScrollView(legacyPageFallback: !loader.items.isEmpty)
        case .failed:
            FeedEmptyStateView(mode: .generic)
        }
    }

    private var lifecycleObservedScreen: some View {
        screenContent
        .task {
            await startScreen()
        }
        .onAppear { recordFirstScreenMetric() }
        .onChange(of: surfaceContentCount) { _, count in recordFirstUsefulContentMetric(count: count) }
        .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
        .onReceive(NotificationCenter.default.publisher(for: .onboardingDidSaveCuratedFeed)) { notification in
            let name = notification.userInfo?["feedName"] as? String ?? "Your mix"
            toastMessage = "\(name) is ready"
            toastIcon = "slider.horizontal.3"
            withAnimation { showToast = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleWillEnterForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            loader.emergencyTrim()
        }
    }

    private var searchObservedScreen: some View {
        lifecycleObservedScreen
        .onChange(of: searchIncludesSources) { _, value in
            loader.searchIncludesSources = value
            if !searchTerms.isEmpty {
                loader.submitSearchTerms(searchTerms)
            }
        }
        .onChange(of: searchIncludesContents) { _, value in
            loader.searchIncludesContents = value
            // The online sweep is a separate demand (PR-14 item 2): it follows the reader's switch
            // that already meant "walk the live endpoints", and it is never implied by the local FTS
            // running. `FeedStore.search` takes it as its own parameter.
            loader.searchDemandsOnlineContent = value
            if !searchTerms.isEmpty {
                loader.submitSearchTerms(searchTerms)
            }
        }
        .onChange(of: loader.submittedSearchTerms) { _, terms in
            if searchTerms != terms {
                searchTerms = terms
            }
        }
        .onChange(of: filterLensSignature) { _, _ in
            handleFilterLensContentChange()
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused && searchText.isEmpty && searchTerms.isEmpty {
                isSearching = false
            }
        }
    }

    private var observedScreen: some View {
        searchObservedScreen
        .onChange(of: loader.readItemIDs.count) { _, _ in updateBadge() }
        .onChange(of: loader.lastToggleMessage) { _, msg in
            if let msg {
                toastMessage = msg; toastIcon = "antenna.radiowaves.left.and.right"
                withAnimation { showToast = true }
                loader.clearToggleMessage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedImportCompleted)) { notification in
            if let msg = notification.userInfo?["message"] as? String {
                toastMessage = msg; toastIcon = "plus.circle.fill"
                withAnimation { showToast = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSourceView)) { notification in
            guard let feedURL = notification.userInfo?["feedURL"] as? String,
                  !feedURL.isEmpty else { return }
            let normalized = OPMLParser.normalizeURL(feedURL)
            let ref = SourceReference(
                title: "Source",
                feedURL: normalized,
                category: "",
                region: "global",
                mediaKind: .text
            )
            selectedSource = ref
        }
        .onChange(of: player.lastPlaybackError) { _, error in
            if let error {
                toastMessage = error; toastIcon = "exclamationmark.triangle"
                withAnimation { showToast = true }
                player.clearPlaybackError()
            }
        }
        .onChange(of: loader.networkMonitor.isConnected) { _, connected in
            // Refresh when the network recovers from a known-disconnected
            // state. Gating on wasDisconnected (not just connected) prevents
            // the startup false→true transition from triggering a redundant
            // concurrent fetch on every normal online launch.
            if connected, loader.networkMonitor.wasDisconnected {
                Task { await loader.refreshIfStale() }
            }
        }
    }

    private var screenWithSheets: some View {
        observedScreen
        .sheet(item: $articleItem) { item in
            // The other half of the ignored-tap diagnostic (see `FeedItemView`'s tap log): if `card tap` is logged and
            // this is not, the app received the tap and the reader did not present; if both are logged, the reader opened
            // and a test's presentation probe is what failed.
            ArticleReaderView(item: item)
                .onAppear { Log.ui.info("reader presented id=\(item.id)") }
                .onDisappear { Log.ui.info("reader dismissed id=\(item.id)") }
        }
        .sheet(item: $selectedSource) { SourceFeedView(source: $0) }
        .sheet(item: $sourceToCollect) { AddSourceToCollectionSheet(source: $0) }
        .sheet(isPresented: $showSettings) { SettingsSheetView() }
        .sheet(isPresented: $showSources) { SourceManagementView() }
        .sheet(isPresented: $showFilters) { FilterSheetView() }
        .sheet(isPresented: $showBookmarks) { BookmarkBoxesView() }
        .sheet(isPresented: $showAddFeed) {
            AddFeedView(
                targetCollectionID: addFeedCollectionID,
                targetCollectionName: addFeedCollectionName
            )
        }
        .sheet(isPresented: $showCollections) { CollectionManagementView() }
        .sheet(isPresented: $showExport) { ExportView() }
        .fullScreenCover(isPresented: $showCuratedOnboarding) {
            CuratedOnboardingView(
                isFirstRun: false,
                onCancel: { showCuratedOnboarding = false },
                onSaved: { feed in
                    showCuratedOnboarding = false
                    toastMessage = "\(feed.name) is ready"
                    toastIcon = "slider.horizontal.3"
                    withAnimation { showToast = true }
                }
            )
        }
        .sheet(isPresented: $showCuratedInspector) {
            if let curatedFeedID = loader.activePreset.curatedFeedID {
                CuratedFeedInspectorView(curatedFeedID: curatedFeedID)
            }
        }
        .sheet(isPresented: $showCollectionExport) {
            if let collectionID = loader.activePreset.collectionID {
                CollectionOPMLExportView(
                    collectionID: collectionID,
                    collectionName: loader.activePreset.displayName
                )
            }
        }
        .sheet(isPresented: $showCatalogExplore) {
            if let databaseURL = FeedEngineCatalogDiagnostics.activeDatabaseURL(),
               let repository = try? SQLiteCatalogRepository(databaseURL: databaseURL, readOnly: true) {
                CatalogExploreView(engine: repository)
            } else {
                ContentUnavailableView(
                    "Catalog unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The local catalog could not be opened.")
                )
            }
        }
        .tint(engine.accent)
        .overlay { if nightMode { nightOverlay } }
        .fileImporter(
            isPresented: $showCollectionImporter,
            allowedContentTypes: [.xml, .init(filenameExtension: "opml")!]
        ) { result in
            handleCollectionImport(result)
        }
        .alert("Create collection from filters", isPresented: $showCreateCollectionPrompt) {
            TextField("Collection name", text: $createCollectionName)
            Button("Create") { Task { await createCollectionFromContext() } }
                .disabled(createCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pendingCollectionSources.count) matching source\(pendingCollectionSources.count == 1 ? "" : "s") will be added.")
        }
        .alert("Save as Smart Bookmark", isPresented: $showCreateSmartFeedPrompt) {
            TextField("Smart Bookmark name", text: $createSmartFeedName)
            Button("Save") { Task { await createSmartFeedFromSearch() } }
                .disabled(createSmartFeedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New matching content will be added automatically. Seen items stay available at the end of the feed.")
        }
        .alert("Delete Smart Bookmark?", isPresented: $showDeleteSmartFeedConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deleteActiveSmartFeed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved search and its cache. It does not delete sources or articles from Feedmine.")
        }
        .alert("Delete Curated Feed?", isPresented: $showDeleteCuratedFeedConfirmation) {
            Button("Delete", role: .destructive) {
                Task { await deleteActiveCuratedFeed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes its preference profile. Sources and articles stay in Feedmine.")
        }
        .onDisappear {
            filterLensCollapseTask?.cancel()
        }
    }

    private var hasFilterLensContent: Bool {
        loader.activeFilterCount > 0
    }

    private var isFilterLensDismissedForCurrentSelection: Bool {
        hasFilterLensContent
            && !filterLensSignature.isEmpty
            && filterLensDismissedSignature == filterLensSignature
    }

    private var isFilterLensVisible: Bool {
        !isSearching && hasFilterLensContent && filterLensExpanded && !isFilterLensDismissedForCurrentSelection
    }

    private var feedTopPadding: CGFloat {
        max(48, headerHeight)
            + (isSearching ? searchControlsHeight : (isFilterLensVisible ? 20 : 0))
    }

    @State private var _cachedFilterLensKey: String = ""
    @State private var _cachedFilterLensSig: String = ""

    private var filterLensSignature: String {
        guard hasFilterLensContent else { return "" }
        // Cache against filter state to avoid string join on every scroll frame
        let key = "\(loader.selectedRegion ?? ".")|\(loader.selectedContentType.rawValue)|\(loader.selectedMood.rawValue)|\(loader.searchQuery)"
        if key == _cachedFilterLensKey { return _cachedFilterLensSig }
        var parts: [String] = []
        parts.append(loader.activePreset.displayName)
        parts.append(loader.selectedRegion ?? "")
        parts.append(loader.selectedContentType.rawValue)
        parts.append(loader.selectedMood.rawValue)
        parts.append(loader.selectedNodeIDs.sorted().joined(separator: ","))
        parts.append(loader.selectedLanguages.sorted().joined(separator: ","))
        parts.append(loader.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        let sig = parts.joined(separator: "|")
        _cachedFilterLensKey = key
        _cachedFilterLensSig = sig
        return sig
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            CompactErrorBanner()
            HStack(spacing: 8) {
                if showDebugBar {
                    CompactDebugInfo()
                } else {
                    // The chip is drawn for the whole screen, so on the page the session owns it is the
                    // session's in every state of that surface — preparing, content and empty.
                    CompactFeedStatus(session: runtime.sessionChipStatement)
                }

                Spacer()

                HStack(spacing: 4) {
                    Button {
                        if isSearching {
                            closeSearch()
                        } else {
                            applySearchScopeToLoader()
                            withAnimation(.easeInOut(duration: 0.3)) { isSearching = true }
                            searchFocused = true
                        }
                    } label: {
                        Image(systemName: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .headerButtonStyle(accent: engine.accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityIdentifier("search-button")
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        showBookmarks = true
                    } label: {
                        Image(systemName: loader.selectedBookmarkListID != nil ? "bookmark.fill" : "bookmark")
                            .headerButtonStyle(accent: engine.accent)
                    }
                    .accessibilityIdentifier("bookmark-boxes-button")
                    .overlay(alignment: .topTrailing) {
                        if loader.selectedBookmarkListID != nil {
                            Circle().fill(engine.accent).frame(width: 6, height: 6)
                        }
                    }
                    filterButton
                    if showDebugBar {
                        Button {
                            showCatalogExplore = true
                        } label: {
                            Image(systemName: "books.vertical")
                                .headerButtonStyle(accent: engine.accent)
                        }
                        .accessibilityLabel("Explore Catalog")
                    }
                    Menu {
                        Button {
                            showCuratedOnboarding = true
                        } label: {
                            Label("Create Curated Feed", systemImage: "wand.and.stars")
                        }
                        if loader.activePreset.isCuratedFeed {
                            Button {
                                showCuratedInspector = true
                            } label: {
                                Label("Open Curated Feed hood", systemImage: "slider.horizontal.3")
                            }
                            Button(role: .destructive) {
                                showDeleteCuratedFeedConfirmation = true
                            } label: {
                                Label("Delete Curated Feed", systemImage: "trash")
                            }
                        }
                        Divider()
                        if shouldOfferCreateSmartFeed {
                            Button { prepareSmartFeedFromSearch() } label: {
                                Label(
                                    "Save as Smart Bookmark",
                                    systemImage: "sparkles.rectangle.stack"
                                )
                            }
                        }
                        if shouldOfferCreateCollection {
                            Button { prepareCollectionFromContext() } label: {
                                Label("Collect these sources", systemImage: "folder.badge.plus")
                            }
                        }
                        if let collectionID = loader.activePreset.collectionID {
                            Button { showCollectionExport = true } label: {
                                Label("Export collection", systemImage: "square.and.arrow.up")
                            }
                            Button { showCollectionImporter = true } label: {
                                Label("Import to collection", systemImage: "square.and.arrow.down")
                            }
                            Button {
                                addFeedCollectionID = collectionID
                                addFeedCollectionName = loader.activePreset.displayName
                                showAddFeed = true
                            } label: {
                                Label("Add feed to collection", systemImage: "link.badge.plus")
                            }
                            Divider()
                        }
                        if loader.activePreset.isSmartFeed {
                            Button(role: .destructive) {
                                showDeleteSmartFeedConfirmation = true
                            } label: {
                                Label("Delete Smart Bookmark", systemImage: "trash")
                            }
                            Divider()
                        }
                        Button {
                            addFeedCollectionID = nil
                            addFeedCollectionName = nil
                            showAddFeed = true
                        } label: {
                            Label("Add Feed", systemImage: "plus.circle")
                        }
                        Button { showExport = true } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Button { showCollections = true } label: {
                            Label("Source Collections", systemImage: "rectangle.stack.fill")
                        }
                        Button { showSources = true } label: {
                            Label("Sources", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .headerButtonStyle(accent: engine.accent)
                    }
                    .accessibilityIdentifier("more-menu")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Divider().opacity(0.3)
            }

            if isFilterLensVisible {
                FilterLensBar {
                    dismissFilterLensForCurrentSelection()
                }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .readHeaderHeight($headerHeight)
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Add a term · use -term to exclude", text: $searchText)
                    .focused($searchFocused)
                    .accessibilityIdentifier("unified-search-field")
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { commitSearchDraft() }
                if !searchText.isEmpty {
                    Button {
                        commitSearchDraft()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(engine.accent)
                    }
                    .accessibilityLabel("Add search term")
                }
                Button("Cancel") {
                    closeSearch()
                }
                .font(.caption).foregroundStyle(engine.accent)
            }

            if !searchTerms.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(searchTerms) { term in
                            searchTermChip(term)
                        }
                    }
                }
                .accessibilityIdentifier("search-term-tags")
            }

            HStack(spacing: 18) {
                searchScopeButton(
                    title: "Sources",
                    isOn: $searchIncludesSources,
                    accessibilityID: "search-sources-toggle"
                )
                searchScopeButton(
                    title: "Contents",
                    isOn: $searchIncludesContents,
                    accessibilityID: "search-contents-toggle"
                )
                Spacer()
            }
            .font(.caption.weight(.medium))

            if !searchTerms.isEmpty {
                searchActivityLine
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .onAppear { searchFocused = true }
        .readSearchControlsHeight($searchControlsHeight)
    }

    private func searchTermChip(_ term: SearchTerm) -> some View {
        HStack(spacing: 5) {
            Image(systemName: term.isExcluded ? "minus.circle.fill" : "tag.fill")
                .font(.caption2)
            Text(term.displayText)
                .lineLimit(1)
            Button {
                removeSearchTerm(term)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .accessibilityLabel("Remove \(term.displayText)")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(term.isExcluded ? Color.red : engine.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            (term.isExcluded ? Color.red : engine.accent).opacity(0.1),
            in: Capsule()
        )
    }

    @ViewBuilder
    private var searchActivityLine: some View {
        let expression = SearchExpression(terms: searchTerms)
        if !expression.canSearch {
            Label("Add at least one positive term to search", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        } else if searchIncludesContents && loader.isSearchScanning {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .foregroundStyle(engine.accent)
                Text("\(loader.searchScannedSourceCount) sources checked")
                if loader.searchDiscoveredItemCount > 0 {
                    Text("· \(loader.searchDiscoveredItemCount) new cached")
                }
            }
            .foregroundStyle(.secondary)
        } else if searchIncludesContents && loader.searchScanCompleted {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("\(loader.searchScannedSourceCount) sources checked")
                if loader.searchDiscoveredItemCount > 0 {
                    Text("· \(loader.searchDiscoveredItemCount) new cached")
                }
            }
            .foregroundStyle(.secondary)
        } else if loader.isSearchLoading {
            Label("Searching…", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    private func searchScopeButton(
        title: String,
        isOn: Binding<Bool>,
        accessibilityID: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(
                title,
                systemImage: isOn.wrappedValue ? "checkmark.square.fill" : "square"
            )
            .foregroundStyle(isOn.wrappedValue ? engine.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityValue(isOn.wrappedValue ? "selected" : "not selected")
    }

    private var unifiedSearchPanel: some View {
        let results = loader.unifiedSearchResults
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if loader.isSearchLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching the local library…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                }

                if !results.sources.isEmpty {
                    searchSectionHeader("Sources", count: results.sources.count, icon: "antenna.radiowaves.left.and.right")
                    ForEach(results.sources) { source in
                        Button {
                            searchFocused = false
                            selectedSource = source.sourceReference
                        } label: {
                            SourceSearchRow(source: source)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("source-result-\(source.id)")
                        .contextMenu {
                            Button {
                                searchFocused = false
                                selectedSource = source.sourceReference
                            } label: {
                                Label("View Source", systemImage: "rectangle.stack")
                            }
                            Button { sourceToCollect = source.sourceReference } label: {
                                Label("Add Source to Collection", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                    }
                }

                if !results.savedItems.isEmpty {
                    searchSectionHeader("Saved", count: results.savedItems.count, icon: "bookmark.fill")
                    ForEach(results.savedItems) { item in
                        searchContentRow(item, saved: true)
                    }
                }

                if !results.localItems.isEmpty {
                    searchSectionHeader("History & local content", count: results.localItems.count, icon: "clock.arrow.circlepath")
                    ForEach(results.localItems) { item in
                        searchContentRow(item, saved: false)
                    }
                }

                if !loader.isSearchLoading && results.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text(loader.isSearchScanning
                            ? "Results will appear here while sources are checked online."
                            : "Try another term or adjust the active filters.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 90)
        }
        .scrollDismissesKeyboard(.interactively)
        .padding(.top, headerHeight + searchControlsHeight)
        .accessibilityIdentifier("unified-search-results")
    }

    private func searchSectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(title).fontWeight(.semibold)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(engine.accent)
        .padding(.top, 8)
    }

    private func searchContentRow(_ item: FeedItem, saved: Bool) -> some View {
        Button {
            searchFocused = false
            loader.markAsClicked(item.id)
            articleItem = item
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: saved ? "bookmark.fill" : (item.isRead ? "clock.fill" : "doc.text"))
                    .foregroundStyle(saved ? engine.accent : Color.secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(item.sourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var filterButton: some View {
        let activeCount = loader.activeFilterCount
        return Button {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            showFilters = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .headerButtonStyle(accent: engine.accent)
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(engine.accent))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .accessibilityIdentifier("filter-button")
        .accessibilityValue("\(activeCount)")
    }

    // MARK: - Feed Scroll

    /// The scrollable feed: the runtime's presentation, already ordered, one row contract for every
    /// source of truth.
    ///
    /// - Parameter legacyPageFallback: whether the legacy page may justify the "this category has
    ///   articles, they may have been trimmed" guidance (`!loader.items.isEmpty`, unchanged). It is the
    ///   legacy branch's rule, and only its: a surface drawn from session snapshots passes `false`,
    ///   because in that mode the legacy page is not a second page to fall back to. This is the site the
    ///   DoD item names — the screen could draw from two sources — and it is now a value its own
    ///   surface state supplies.
    private func feedScrollView(legacyPageFallback: Bool) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(spacing: engine.cardGap) {
                        Color.clear.frame(height: 0).id("top")
                        // Bookmark box header — replaces What's New in bookmark mode
                        if loader.selectedBookmarkListID != nil {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(engine.accent)
                                Text(loader.selectedBookmarkListName ?? "Bookmarks")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                        }
                        ForEach(runtime.presentation.sections) { section in
                            Section {
                                // Rows are the runtime's presentation, already ordered: the card
                                // carries identity, media and chrome, and the media slot the current
                                // band draws. Nothing here inspects the item to decide either.
                                ForEach(section.rows) { row in
                                    FeedItemView(item: row.item,
                                        card: row.card,
                                        mediaSlot: row.mediaSlot,
                                        onOpen: {
                                            guard !searchFocused else {
                                                searchFocused = false
                                                return
                                            }
                                            articleItem = row.item
                                        },
                                        onCopy: { toastMessage = "Link copied"; toastIcon = "doc.on.doc"; withAnimation { showToast = true } },
                                        onPlaybackFailed: {
                                            toastMessage = "Audio unavailable"
                                            toastIcon = "exclamationmark.triangle"
                                            withAnimation { showToast = true }
                                        },
                                        onViewSource: { selectedSource = loader.sourceReference(for: row.item) },
                                        onAddSourceToCollection: { sourceToCollect = loader.sourceReference(for: row.item) }
                                    )
                                    .id(row.id)
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                    .onScrollVisibilityChange(
                                        threshold: MainFeedRuntime.cardVisibilityThreshold
                                    ) { visible in
                                        // The visibility transition, in the vocabulary this file already
                                        // uses for the scroll surface: `true` is the row crossing above the
                                        // threshold, and the callback fires on that transition rather than on
                                        // a render. The view states the crossing and no fraction — it has
                                        // none — so the runtime declares the policy's own number, which is
                                        // the one this callback fires under.
                                        //
                                        // Who hears it is the runtime's decision, per page: on the surface
                                        // the session owns the row's visibility is an exposure observation
                                        // (`FeedSessionIntent.cardVisibility`), and on the legacy page — and
                                        // in every other mode — it is the read-state write it always was. A
                                        // runtime row's id is the bridge's display id, which names no
                                        // `feed_item` row, so it is never the id that write receives.
                                        //
                                        // `false` writes nothing, as it wrote nothing before: the read state
                                        // records that a card was shown, never that it scrolled away.
                                        if visible {
                                            runtime.cardBecameVisible(itemID: row.item.id)
                                        }
                                    }
                                }
                            } header: {
                                if section.showsHeader {
                                    sectionHeader(section.title)
                                }
                            }
                        }

                        // Filters/search matched nothing, but the feed itself
                        // has content — show guidance instead of a blank screen.
                        if legacyPageFallback && runtime.presentation.sections.isEmpty {
                            EmptyFilterView(category: loader.selectedNodeNames.joined(separator: ", "))
                        }
                    }
                    .padding(.top, feedTopPadding)
                    .scrollTargetLayout()
                }
                .refreshable {
                    await runtime.refresh()
                }
                .scrollDismissesKeyboard(.interactively)
                // The viewport observation (PR-13). It replaces the per-card `onAppear` that used to
                // call `loadMoreIfNeeded`: a callback on appearance cannot tell a fling from a settle,
                // and the demand signal it produced was "a card exists" rather than "the viewport is
                // here". This reports identities only, does no work, and the runtime decides what the
                // position costs.
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { visibleIDs in
                    handleViewportChanged(visibleIDs)
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                    geo.contentOffset.y
                }, action: { _, newOffset in
                    handleScrollOffset(newOffset)
                })
            }
            .onChange(of: scrollTargetID) { _, targetID in
                guard let targetID else { return }
                // Short delay so LazyVStack has time to lay out the target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetID, anchor: .top)
                    }
                }
                scrollTargetID = nil
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Floating Buttons

    // MARK: - Overlays

    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showToast {
                HStack(spacing: 8) {
                    Image(systemName: toastIcon).font(.subheadline)
                    Text(toastMessage).font(.subheadline).fontWeight(.medium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.black.opacity(0.8), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toastMessage) {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showToast = false }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showToast)
            }
        }
    }

    private var nightOverlay: some View {
        Color.black.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func startScreen() async {
        // The runtime follows this loader's published page from here: acquisition lifetime is tied to
        // the screen (PR-13), and the mode decided at launch is what it follows it with.
        runtime.attach(loader: loader)
        applySearchScopeToLoader()
        searchTerms = loader.submittedSearchTerms
        await loader.start()
        // `FeedLoader.start()` already awaited `refreshBookmarkState()`; the second call here was the
        // duplicate demand P10 in the acquisition map: two full bookmark hydrations on every cold
        // start, the second one 10 lines after the first.
        updateBadge()
        engine.refresh()
        // Restore scroll position once on cold start, but never if the user
        // already started reading.
        if !didRestoreScroll && !userHasScrolled
            && !lastScrollItemID.isEmpty && !loader.items.isEmpty {
            scrollTargetID = lastScrollItemID
        }
        didRestoreScroll = true
    }

    private var shouldOfferCreateCollection: Bool {
        hasCommittedSearch || loader.activeFilterCount >= 2
    }

    private var shouldOfferCreateSmartFeed: Bool {
        isSearching
            && hasCommittedSearch
            && (searchIncludesSources || searchIncludesContents)
    }

    private var currentContextSources: [SourceReference] {
        var candidates: [SourceReference] = []
        if isSearching && hasCommittedSearch {
            let results = loader.unifiedSearchResults
            candidates.append(contentsOf: results.sources.map(\.sourceReference))
            candidates.append(contentsOf: (results.savedItems + results.localItems).map {
                loader.sourceReference(for: $0)
            })
        } else if loader.activePreset.collectionID == nil,
                  loader.selectedMood == .all {
            candidates.append(contentsOf: loader.activeSources.map {
                SourceReference(source: $0)
            })
        } else {
            candidates.append(contentsOf: loader.filteredItems.map {
                loader.sourceReference(for: $0)
            })
        }

        var seen = Set<String>()
        return candidates.filter {
            seen.insert(OPMLParser.normalizeURL($0.feedURL)).inserted
        }
    }

    private func prepareCollectionFromContext() {
        pendingCollectionSources = currentContextSources
        guard !pendingCollectionSources.isEmpty else {
            toastMessage = "No matching sources to collect"
            toastIcon = "folder.badge.questionmark"
            withAnimation { showToast = true }
            return
        }
        let query = SearchExpression(terms: searchTerms).displayQuery
        createCollectionName = query.isEmpty ? "Filtered feeds" : query
        showCreateCollectionPrompt = true
    }

    private func createCollectionFromContext() async {
        do {
            let name = createCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = try await loader.createSourceCollection(name: name)
            for source in pendingCollectionSources {
                try await loader.addSource(source, toCollectionID: id)
            }
            toastMessage = "\(pendingCollectionSources.count) sources added to \(name)"
            toastIcon = "folder.badge.plus"
            pendingCollectionSources = []
            withAnimation { showToast = true }
        } catch {
            toastMessage = "Could not create collection"
            toastIcon = "exclamationmark.triangle"
            withAnimation { showToast = true }
        }
    }

    private func prepareSmartFeedFromSearch() {
        let expression = SearchExpression(terms: searchTerms)
        guard expression.canSearch, searchIncludesSources || searchIncludesContents else {
            return
        }
        createSmartFeedName = expression.displayQuery
        showCreateSmartFeedPrompt = true
    }

    private func createSmartFeedFromSearch() async {
        let name = createSmartFeedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = SearchExpression(terms: searchTerms)
        guard !name.isEmpty, expression.canSearch else { return }
        do {
            let smartFeed = try await loader.createSmartFeed(
                name: name,
                terms: searchTerms,
                includeSources: searchIncludesSources,
                includeContents: searchIncludesContents
            )
            loader.setActivePreset(.smartFeed(
                smartFeedID: smartFeed.id,
                smartFeedName: smartFeed.name
            ))
            closeSearch()
            toastMessage = "\(smartFeed.name) saved as a Smart Bookmark"
            toastIcon = "sparkles.rectangle.stack.fill"
            withAnimation { showToast = true }
        } catch {
            toastMessage = error.localizedDescription
            toastIcon = "exclamationmark.triangle"
            withAnimation { showToast = true }
        }
    }

    private func deleteActiveSmartFeed() async {
        guard let id = loader.activePreset.smartFeedID else { return }
        do {
            try await loader.deleteSmartFeed(id: id)
            toastMessage = "Smart Bookmark deleted"
            toastIcon = "trash"
        } catch {
            toastMessage = "Could not delete Smart Bookmark"
            toastIcon = "exclamationmark.triangle"
        }
        withAnimation { showToast = true }
    }

    private func deleteActiveCuratedFeed() async {
        guard let id = loader.activePreset.curatedFeedID else { return }
        do {
            try await loader.deleteCuratedFeed(id: id)
            toastMessage = "Curated Feed deleted"
            toastIcon = "trash"
        } catch {
            toastMessage = "Could not delete Curated Feed"
            toastIcon = "exclamationmark.triangle"
        }
        withAnimation { showToast = true }
    }

    private func handleCollectionImport(_ result: Result<URL, Error>) {
        guard let collectionID = loader.activePreset.collectionID else { return }
        switch result {
        case .failure:
            toastMessage = "Could not open OPML"
            toastIcon = "exclamationmark.triangle"
            withAnimation { showToast = true }
        case .success(let url):
            Task {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url)
                    let imported = await loader.importOPML(
                        data: data,
                        fileName: url.deletingPathExtension().lastPathComponent,
                        validate: false
                    )
                    let sourceURLs = imported.items.compactMap { item -> String? in
                        switch item.status {
                        case .imported, .duplicate: return item.url
                        case .invalid, .unreachable: return nil
                        }
                    }
                    let count = try await loader.addSourceURLs(
                        sourceURLs,
                        toCollectionID: collectionID
                    )
                    toastMessage = "\(count) feed\(count == 1 ? "" : "s") added to \(loader.activePreset.displayName)"
                    toastIcon = "square.and.arrow.down"
                } catch {
                    toastMessage = "Could not import OPML"
                    toastIcon = "exclamationmark.triangle"
                }
                withAnimation { showToast = true }
            }
        }
    }

    private func closeSearch() {
        searchText = ""
        searchTerms = []
        searchFocused = false
        loader.clearSubmittedSearch()
        withAnimation(.easeInOut(duration: 0.25)) { isSearching = false }
    }

    private var hasCommittedSearch: Bool {
        SearchExpression(terms: searchTerms).canSearch
    }

    private func commitSearchDraft() {
        guard let term = SearchTerm(input: searchText) else { return }
        var updatedTerms = searchTerms
        let normalized = SearchExpression.normalized(term.text)
        // Re-entering a term replaces its previous polarity, which makes
        // correcting "term" to "-term" (or back) a single action.
        updatedTerms.removeAll {
            SearchExpression.normalized($0.text) == normalized
        }
        updatedTerms.append(term)
        searchTerms = updatedTerms
        searchText = ""
        loader.searchIncludesSources = searchIncludesSources
        loader.searchIncludesContents = searchIncludesContents
        loader.submitSearchTerms(updatedTerms)
        searchFocused = true
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func removeSearchTerm(_ term: SearchTerm) {
        searchTerms.removeAll { $0.id == term.id }
        loader.submitSearchTerms(searchTerms)
        searchFocused = true
    }

    /// The viewport observation behind the feed's replenishment (PR-13).
    ///
    /// It records where the reader is and hands the identities to the runtime; it does not fetch,
    /// decode or select. `visibleIDs` is every row the scroll surface currently has on screen, which is
    /// the same signal the session's window wants (`viewportChanged`), and the runtime turns it into
    /// ordinals plus the anchor it currently holds.
    private func handleViewportChanged(_ visibleIDs: [String]) {
        guard !visibleIDs.isEmpty else { return }
        runtime.viewportChanged(visibleItemIDs: visibleIDs)
        var last: (id: String, ordinal: Int)?
        for id in visibleIDs {
            guard let ordinal = runtime.presentation.ordinalByItemID[id] else { continue }
            if last == nil || ordinal > last!.ordinal { last = (id, ordinal) }
        }
        guard let last else { return }
        lastVisibleItemID = last.id
        loader.noteViewport(lastVisibleOrdinal: last.ordinal)
    }

    /// Scroll offset (points) beyond which the scroll-to-top button appears.
    private func handleScrollOffset(_ newOffset: CGFloat) {
        if newOffset > 40 { userHasScrolled = true }
        let delta = newOffset - lastScrollOffset
        lastScrollOffset = newOffset

        guard hasFilterLensContent, !isSearching, !isFilterLensDismissedForCurrentSelection else { return }

        if delta > 8 && newOffset > 24 {
            collapseFilterLens()
        } else if delta < -8 {
            revealFilterLens()
        }
    }

    private func revealFilterLens(scheduleAutoCollapse: Bool = false) {
        guard hasFilterLensContent, !isFilterLensDismissedForCurrentSelection else { return }
        filterLensCollapseTask?.cancel()

        if !filterLensExpanded {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                filterLensExpanded = true
            }
        }

        if scheduleAutoCollapse {
            scheduleFilterLensCollapse()
        }
    }

    private func handleFilterLensContentChange() {
        guard hasFilterLensContent else {
            filterLensCollapseTask?.cancel()
            filterLensExpanded = true
            filterLensDismissedSignature = ""
            return
        }

        if isFilterLensDismissedForCurrentSelection {
            filterLensCollapseTask?.cancel()
            filterLensExpanded = false
        } else {
            revealFilterLens(scheduleAutoCollapse: true)
        }
    }

    private func dismissFilterLensForCurrentSelection() {
        guard hasFilterLensContent, !filterLensSignature.isEmpty else { return }
        filterLensCollapseTask?.cancel()
        filterLensDismissedSignature = filterLensSignature
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            filterLensExpanded = false
        }
    }

    private func collapseFilterLens() {
        filterLensCollapseTask?.cancel()
        guard hasFilterLensContent, filterLensExpanded else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            filterLensExpanded = false
        }
    }

    private func scheduleFilterLensCollapse() {
        filterLensCollapseTask?.cancel()
        filterLensCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, hasFilterLensContent, !isSearching else { return }
            if filterLensExpanded {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    filterLensExpanded = false
                }
            }
        }
    }

    private func updateBadge() {
        let unread = loader.items.count - loader.readItemIDs.count
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(max(0, unread)) }
    }

    private func recordFirstScreenMetric() {
        guard !didRecordFirstScreen else { return }
        didRecordFirstScreen = true
        FeedMetrics.event("UI.firstScreenRendered")
        FeedMetrics.memory("firstScreenRendered")
    }

    private func recordFirstUsefulContentMetric(count: Int) {
        guard count > 0, !didRecordFirstUsefulContent else { return }
        didRecordFirstUsefulContent = true
        FeedMetrics.event("UI.firstUsefulContent", "count=\(count)")
        FeedMetrics.memory("firstUsefulContent")
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            loader.setActivityState(.active)
            engine.refresh()
            // Do NOT restore scroll on foreground: SwiftUI already preserves
            // the position across background, so re-scrolling here only makes
            // the feed jump under the user. (Feed is sacred.)
        case .inactive:
            loader.setActivityState(.inactive)
        case .background:
            loader.setActivityState(.background)
            SmartFeedBackgroundScheduler.shared.schedule()
            AudioPlayerManager.shared.savePosition()
            // The persisted position is the card the viewport last saw, not an index into a page that
            // may have been rebuilt since (PR-13).
            if let lastVisibleItemID { lastScrollItemID = lastVisibleItemID }
        @unknown default:
            break
        }
    }

    /// The reader's search switches, stated to the loader in one place.
    ///
    /// Three scopes, three statements: source search is the catalogue query, contents search is the
    /// canonical FTS, and the live-endpoint sweep is the explicit online demand that follows the
    /// Contents switch. Before PR-14 the sweep was a side effect of `includeContents` inside
    /// `FeedStore.search`, so a reader who asked for local content also started an online walk.
    private func applySearchScopeToLoader() {
        loader.searchIncludesSources = searchIncludesSources
        loader.searchIncludesContents = searchIncludesContents
        loader.searchDemandsOnlineContent = searchIncludesContents
    }

    private func handleWillEnterForeground() {
        Task {
            engine.refresh()
            await loader.refreshIfStale()
        }
    }
}

private struct CollectionOPMLExportView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let collectionID: Int64
    let collectionName: String
    @State private var fileURL: URL?
    @State private var sourceCount = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Collection", value: collectionName)
                    LabeledContent("Sources", value: "\(sourceCount)")
                }

                Section {
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Export OPML", systemImage: "square.and.arrow.up")
                        }
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "Export unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                    } else {
                        HStack {
                            ProgressView()
                            Text("Preparing OPML…")
                        }
                    }
                } footer: {
                    Text("The OPML contains exactly the sources in this collection.")
                }
            }
            .navigationTitle("Export collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await prepareExport() }
        .presentationDetents([.medium])
    }

    private func prepareExport() async {
        do {
            let members = try await loader.sourceCollectionMembers(collectionID: collectionID)
            let sources = members.map { loader.sourceReference(for: $0).feedSource }
            sourceCount = sources.count
            let data = ExportEngine.opml(sources: sources, title: collectionName)
            let safeName = collectionName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(safeName).opml")
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Compact Subviews

struct CompactDebugInfo: View {
    @Environment(FeedLoader.self) private var loader
    private var unread: Int { loader.items.count - loader.readItemIDs.count }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(loader.loadingState == .idle ? Color.green : Color.blue).frame(width: 6, height: 6)
            Text("\(loader.filteredItems.count)")
                .font(.caption).fontWeight(.semibold).contentTransition(.numericText())
            if unread > 0 {
                Text("\(unread) new")
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.blue))
            }
            if loader.podcastItemCount > 0 {
                Text("🎧\(loader.podcastItemCount)").font(.caption2).foregroundStyle(.purple)
            }
            if loader.fetchErrorCount > 0 {
                Text("·\(loader.fetchErrorCount) err").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SearchControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 92
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func readHeaderHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: HeaderHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { height.wrappedValue = $0 }
    }

    func readSearchControlsHeight(_ height: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SearchControlsHeightKey.self,
                    value: proxy.size.height
                )
            }
        }
        .onPreferenceChange(SearchControlsHeightKey.self) {
            height.wrappedValue = $0
        }
    }
}

// MARK: - Compact header chip

/// The legacy chip's own inputs: every `FeedLoader` property the header chip read before the surface a
/// launch's runtime owns existed.
///
/// They are values, materialized once by `CompactFeedDisplay.forSurface`, so the layout below reads no
/// loader at all and the session's lane cannot reach one of them.
struct CompactFeedLegacyFacts: Equatable {
    /// Whether the legacy startup runway is still building the first page (`isPreparingInitialRunway`).
    let isPreparingRunway: Bool
    /// How many of its own source fetches the legacy engine has completed (`startupFetchedSourceCount`).
    let fetchedSourceCount: Int
    /// The runway's denominator: `startupTotalSourceCount` floored by the catalogue the registry has
    /// counted — the chip's own fold (`max(startupTotalSourceCount, sourceCount)`), kept verbatim.
    let totalSourceCount: Int
    /// Articles the legacy ingest has ready for the first screen (`startupItemsReady`) against the count
    /// that makes one (`startupItemsTarget`).
    let itemsReady: Int
    let itemsTarget: Int
    /// The legacy catalogue: its enabled sources against all of them (`activeSourceCount`/`sourceCount`).
    let activeSourceCount: Int
    let sourceCount: Int
    /// Whether the legacy runway finished its wave (`startupRunwayReady`), which raises the chip's
    /// completion cue.
    let runwayReady: Bool
}

/// What the header chip draws, in the two shapes it has always drawn.
enum CompactFeedContent: Equatable {
    /// The startup-figures element: the counter where the runway prints `fetched/total`, the first-screen
    /// clause beside it and the completion cue. Both lanes draw this shape — only the legacy lane's
    /// figures are the runway's.
    case figures(counter: String, articles: String?, isComplete: Bool, label: String)
    /// The bare catalogue line (`·enabled/total sources`): the legacy chip's shape once its runway is
    /// done and the registry has counted the catalogue.
    case catalogueLine(String)

    /// The figure this content states, for the chip's own diagnostic line.
    var diagnosticValue: String {
        switch self {
        case .figures(let counter, _, _, _): return counter
        case .catalogueLine(let text): return text
        }
    }
}

/// What the header chip states, and which owner it states it from.
///
/// A launch's session owns exactly one selection, and the chip is drawn for the whole screen rather than
/// for one of its content branches: on that selection it states the runtime's own statement in **every**
/// state of the surface the session owns — preparing, content and empty. Everywhere else it is the legacy
/// chip, verbatim: the legacy startup runway's counters, which a launch whose runtime acquires for never
/// advances, because `LegacyAcquisitionGate` refuses that engine's requests
/// (`docs/runtime-v2/baseline.md` §8.26) — measured on the chip as `· 71,234/77,443 sources` while the
/// runtime watched 32 (`loading-progress-report.md` §6 item 1).
///
/// The lane is a value so the choice is assertable without a rendering, and it is the structural half of
/// "the legacy runway's counters are not read there": the session's case carries none of them, so the
/// layout has nothing of the runway to interpolate. It is the third surface with this shape, after
/// `FeedLoadingDisplay` and `FeedEmptyDisplay`.
enum CompactFeedDisplay: Equatable {
    /// The runtime's own statement — the value the loading chrome and the empty surface state too, so one
    /// launch cannot be described two ways.
    case session(MainFeedLoadingStatement)
    /// The legacy startup runway, verbatim: the counters this chip read before this slice.
    case legacy(CompactFeedLegacyFacts)

    /// The lane for one screen.
    ///
    /// `session` is non-nil exactly on the surface a launch's runtime owns
    /// (`MainFeedRuntime.sessionChipStatement`), and then the loader is not read at all: the guard below
    /// is the whole of the separation. It is `@MainActor` — rather than the whole value type, which is
    /// pure — because the legacy lane reads the loader, and its only call site is a view body.
    @MainActor
    static func forSurface(
        session: MainFeedLoadingStatement?,
        loader: FeedLoader
    ) -> CompactFeedDisplay {
        guard let session else {
            return .legacy(
                CompactFeedLegacyFacts(
                    isPreparingRunway: loader.isPreparingInitialRunway,
                    fetchedSourceCount: loader.startupFetchedSourceCount,
                    totalSourceCount: max(loader.startupTotalSourceCount, loader.sourceCount),
                    itemsReady: loader.startupItemsReady,
                    itemsTarget: loader.startupItemsTarget,
                    activeSourceCount: loader.activeSourceCount,
                    sourceCount: loader.sourceCount,
                    runwayReady: loader.startupRunwayReady
                )
            )
        }
        return .session(session)
    }

    /// Which lane drew this chip: `session` or `legacy`. It is what makes the choice a production
    /// observable rather than a test-only one (the chip's own log line).
    var source: String {
        switch self {
        case .session: return "session"
        case .legacy: return "legacy"
        }
    }

    /// The legacy runway's readiness, the value the chip's completion cue watches. Nil on the session's
    /// lane: the runtime's statement carries counts, not a completion, so its lane watches nothing rather
    /// than borrowing the runway's cue.
    var runwayReady: Bool? {
        guard case .legacy(let facts) = self else { return nil }
        return facts.runwayReady
    }

    /// What this lane draws, given the view's own transient cue (`readyPulse`).
    ///
    /// Nil when the lane states no figure at all: the legacy chip before its runway or its catalogue has
    /// anything to say, and the session's lane when the session has nothing to acquire from — the page's
    /// own empty surface states "No sources enabled", and the legacy chip is silent in that condition too.
    func content(readyPulse: Bool) -> CompactFeedContent? {
        switch self {
        case .session(let statement):
            // `readyPulse` is not read on this lane: the cue marks the runway's wave, and the runtime
            // states no completion of its own to raise it for.
            guard statement != .noCatalogue else { return nil }
            let sentence = FeedLoadingDisplay.session(statement).detail
            return .figures(counter: "· " + sentence, articles: nil, isComplete: false, label: sentence)
        case .legacy(let facts):
            if facts.isPreparingRunway || readyPulse {
                return .figures(
                    counter: "· \(facts.fetchedSourceCount)/\(facts.totalSourceCount)",
                    articles: "· \(facts.itemsReady) of \(facts.itemsTarget) articles for your first screen",
                    isComplete: readyPulse,
                    label: "\(facts.fetchedSourceCount) of \(facts.totalSourceCount) sources verified"
                )
            }
            // The local first page is published before the catalogue is loaded, so the runway flag
            // clears while the total is still unknown. "0/0 sources" is a claim the app cannot make yet;
            // stay silent until the registry has actually counted them.
            guard facts.sourceCount > 0 else { return nil }
            return .catalogueLine("·\(facts.activeSourceCount)/\(facts.sourceCount) sources")
        }
    }

    /// The figure this lane states right now, for the chip's own diagnostic line.
    var diagnosticValue: String {
        content(readyPulse: false)?.diagnosticValue ?? "none"
    }
}

struct CompactFeedStatus: View {
    @Environment(FeedLoader.self) private var loader
    @State private var engine = CircadianEngine.shared
    @State private var showReadyPulse = false
    @AppStorage("showDebugBar") private var showDebugBar = false

    /// The runtime's own statement, on the one surface a launch's runtime owns (plan §17, DoD2). Nil
    /// everywhere else — `CompactFeedStatus()` is the legacy chip — and then this chip reads the loader's
    /// startup runway exactly as it did before this entry point existed: `CompactFeedDisplay.forSurface`
    /// is where the two lanes split.
    var session: MainFeedLoadingStatement? = nil

    /// What this chip draws. It is the only thing the body reads, so the legacy counters are read on
    /// exactly one lane and the session's lane cannot read them at all.
    private var display: CompactFeedDisplay {
        CompactFeedDisplay.forSurface(session: session, loader: loader)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image("Symbol-Gradient")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text("Feedmine").font(.caption).fontWeight(.bold)
            if let content = display.content(readyPulse: showReadyPulse) {
                switch content {
                case .figures(let counter, let articles, let isComplete, let label):
                    HStack(spacing: 3) {
                        Text(counter)
                        // What actually gates the first screen, stated as such. The source count above is
                        // the catalogue-scope figure (the chip's own denominator); this is the content one,
                        // so the two never have to be the same number or agree by coincidence.
                        if let articles {
                            Text(articles)
                                .contentTransition(.numericText())
                        }
                        if isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolEffect(.pulse, value: showReadyPulse)
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isComplete ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(label)
                case .catalogueLine(let text):
                    Text(text)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            Log.ui.info("surface[header-chip] appear source=\(display.source) value=\(display.diagnosticValue)")
        }
        // The chip appears once and its figure then changes in place — the runway's counters on the legacy
        // lane, the session's statement on the surface the runtime owns — so the line above states only the
        // first one. This is the rest of them, beside `surface[initial-loading]`'s own, so "which lane, and
        // what does it say" is readable after the fact.
        .onChange(of: display) { _, next in
            Log.ui.info("surface[header-chip] statement source=\(next.source) value=\(next.diagnosticValue)")
        }
        // Secret gesture: triple-tap the feed status to toggle debug bar.
        // Not exposed in Settings — intentional, for development use only.
        .onTapGesture(count: 3) {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            withAnimation(.easeInOut(duration: 0.3)) {
                showDebugBar.toggle()
            }
        }
        .task(id: display.runwayReady) {
            guard display.runwayReady == true else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showReadyPulse = true
            }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                showReadyPulse = false
            }
        }
    }
}

struct CompactErrorBanner: View {
    @Environment(FeedLoader.self) private var loader
    var body: some View {
        if loader.fetchErrorCount > 0 && !loader.networkMonitor.isConnected {
            HStack {
                Image(systemName: "wifi.slash").font(.caption2)
                Text("Offline").font(.caption2)
            }
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.red.opacity(0.85))
        }
    }
}

private struct SourceSearchRow: View {
    let source: SourceSearchResult

    private var mediaIcon: String {
        switch source.mediaKind {
        case .text: return "doc.text"
        case .video: return "play.rectangle.fill"
        case .audio: return "headphones"
        case .forum: return "bubble.left.and.bubble.right.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: mediaIcon)
                .foregroundStyle(source.defaultEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(source.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !source.defaultEnabled {
                        Text("DORMANT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.13), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = source.sourceDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    if let host = source.displayHost {
                        Text(host).lineLimit(1)
                    }
                    ForEach(source.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.09), in: Capsule())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SourceSearchDetailView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let source: SourceSearchResult

    private var isEnabled: Bool { loader.isSourceEnabled(source.feedURL) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.title)
                            .font(.title2.bold())
                        if let host = source.displayHost {
                            Text(host).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let description = source.sourceDescription {
                            Text(description).font(.body)
                        }
                    }

                    if !source.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Topics").font(.headline)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(source.tags, id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Label(source.mediaKind.rawValue.capitalized, systemImage: "dot.radiowaves.left.and.right")
                        if let activity = source.activity {
                            Label(activity.capitalized, systemImage: "waveform.path.ecg")
                        }
                        if let language = source.language {
                            Label(language, systemImage: "character.book.closed")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !source.defaultEnabled {
                        Label(
                            "Kept for discovery, but not refreshed by default because this current-sensitive source is dormant.",
                            systemImage: "archivebox"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        loader.toggleSource(source.feedURL)
                    } label: {
                        Label(
                            isEnabled ? "Disable source" : "Enable source",
                            systemImage: isEnabled ? "minus.circle" : "plus.circle.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack {
                        if let rawSiteURL = source.siteURL, let siteURL = URL(string: rawSiteURL) {
                            Link(destination: siteURL) {
                                Label("Website", systemImage: "safari")
                            }
                        }
                        Spacer()
                        ShareLink(item: source.feedURL) {
                            Label("Share feed", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Initial Feed Loading

/// What the loading surface draws, and which owner it draws it from.
///
/// A launch has exactly one owner of this surface: the runtime's own statement on the surface its
/// session owns (`MainFeedLoadingStatement`, plan §17 DoD2), the legacy startup runway's counters
/// everywhere else — every other mode, and every selection this launch's session was not built for. The
/// lane is a value so the choice is assertable without a rendering, and it is the structural half of "the
/// legacy counters are not read there": the session's lane carries no fetched count, no target and no
/// percentage, so the layout has nothing of the runway to interpolate.
enum FeedLoadingDisplay: Equatable {
    /// The runtime's own statement. It has no fraction in it and the surface prints none: the runtime has
    /// no measurement for how much of the feed is loaded (plan §16).
    case session(MainFeedLoadingStatement)
    /// The legacy startup runway, verbatim: the counters this surface read before this slice.
    case runway(
        fetched: Int,
        target: Int,
        isReady: Bool,
        recentlyFetchedSourceNames: [String],
        hasPreviouslyLoadedContent: Bool
    )

    /// The lane for one launch.
    ///
    /// `session` is non-nil exactly on the surface a launch's runtime owns while its session has not
    /// published (`MainFeedRuntime.sessionLoadingStatement`), and then the loader is not read at all: the
    /// guard below is the whole of the separation. It is `@MainActor` — rather than the whole value type,
    /// which is pure — because the legacy lane reads the loader, and every call site is a view body.
    @MainActor
    static func forSurface(
        session: MainFeedLoadingStatement?,
        loader: FeedLoader
    ) -> FeedLoadingDisplay {
        guard let session else {
            return .runway(
                fetched: loader.startupFetchedSourceCount,
                target: loader.startupTargetSourceCount,
                isReady: loader.startupRunwayReady,
                recentlyFetchedSourceNames: loader.startupRecentSourceNames,
                hasPreviouslyLoadedContent: loader.hasPreviouslyLoadedContent
            )
        }
        return .session(session)
    }

    /// Whether the wave renders as complete. The legacy runway states its own `startupRunwayReady`; the
    /// session's surface exists only while no edition has been published, so it states that it is not
    /// ready rather than borrowing a readiness it does not have.
    var isReady: Bool {
        switch self {
        case .runway(_, _, let isReady, _, _): return isReady
        case .session: return false
        }
    }

    /// Whether this lane has a fraction to draw a bar with: the legacy runway does, the session's
    /// statement does not, and no bar is drawn without one (an empty bar is a 0% claim).
    var hasProgressBar: Bool {
        if case .runway = self { return true }
        return false
    }

    /// The fraction the bar fills with, in the runway's own terms. Zero on the session's lane, which
    /// draws no bar (`hasProgressBar`).
    var progressFraction: Double {
        guard case .runway(let fetched, let target, _, _, _) = self, target > 0 else { return 0 }
        return min(1, Double(fetched) / Double(target))
    }

    /// The runway's own percentage. Nil on the session's lane: there is no measurement behind one.
    var percentage: String? {
        guard hasProgressBar else { return nil }
        return "\(Int((progressFraction * 100).rounded()))%"
    }

    /// The number the title and the counter line interpolate with `.numericText()`: the runway's fetched
    /// count, or how many sources the session's acquisition owner took on.
    var displayedCount: Int {
        switch self {
        case .runway(let fetched, _, _, _, _): return fetched
        case .session(.acquiring(_, let watched)): return watched.count
        case .session: return 0
        }
    }

    /// The title. The runway's three cases are the ones this surface had before the slice, in the same
    /// order; the session's cases state the session's own answer.
    var title: String {
        switch self {
        case .runway(let fetched, _, _, _, let hasPreviouslyLoadedContent):
            if fetched > 0 { return String(localized: "Loading \(fetched) sources...") }
            if hasPreviouslyLoadedContent { return String(localized: "Loading your feed...") }
            return String(localized: "Preparing your feed...")
        case .session(.readingCatalogue):
            return String(localized: "Preparing your feed...")
        case .session(.acquiring(_, let watched)):
            // The sources this launch's acquisition owner actually took on — not the catalogue's size,
            // which is what the session is *offered* and is thousands of feeds larger. The catalogue is
            // the detail line's own number, so the two never have to agree by coincidence.
            return String(localized: "Acquiring \(watched.count) sources...")
        case .session(.noCatalogue):
            return String(localized: "No sources enabled")
        }
    }

    /// The line where the runway prints `fetched/target`: on the session's lane, the statement's own
    /// facts — never a fraction the runtime cannot know.
    var detail: String {
        switch self {
        case .runway(let fetched, let target, _, _, _):
            return "\(fetched)/\(target)"
        case .session(.readingCatalogue):
            return String(localized: "Waiting for the source catalogue")
        case .session(.acquiring(let sources, let watched)):
            var line = String(localized: "\(watched.count) of \(sources) sources watched")
            if watched.refused > 0 {
                line += " · " + String(localized: "\(watched.refused) refused")
            }
            return line
        case .session(.noCatalogue):
            return String(localized: "Nothing to acquire from")
        }
    }

    /// The source names rotated under "Loading articles": the runway's own recently fetched sources, and
    /// none on the session's lane, whose statement carries counts and not titles.
    var rotatingSourceTitles: [String] {
        guard case .runway(_, _, _, let names, _) = self else { return [] }
        return names
    }

    /// The value the surface states where the runway states `fetched/target`.
    var accessibilityValue: String {
        switch self {
        case .runway(let fetched, let target, _, _, _):
            return "\(fetched)/\(target)"
        case .session:
            return detail
        }
    }

    /// Which lane drew this surface, for the surface's own log line: `session` or `runway`. It is what
    /// makes the choice a production observable rather than a test-only one.
    var source: String {
        switch self {
        case .session: return "session"
        case .runway: return "runway"
        }
    }
}

struct InitialFeedLoadingView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = CircadianEngine.shared
    @State private var displayedSourceName = ""
    @State private var nextSourceNameIndex = 0

    /// The runtime's own statement, on the one surface a launch's runtime owns while its session has not
    /// published (plan §17, DoD2). Nil everywhere else — `InitialFeedLoadingView()` is the legacy lane —
    /// and then this view is the legacy surface it was before the slice: `FeedLoadingDisplay.forSurface`
    /// is where the two lanes split.
    var session: MainFeedLoadingStatement? = nil

    /// What this surface draws. It is the only thing the body reads, so the legacy counters are read on
    /// exactly one lane and the session's lane cannot read them at all.
    private var display: FeedLoadingDisplay {
        FeedLoadingDisplay.forSurface(session: session, loader: loader)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: max(88, proxy.size.height * 0.13))

                StartupSignalView(
                    accent: engine.accent,
                    isReady: display.isReady,
                    reduceMotion: reduceMotion
                )
                .frame(width: 152, height: 72)
                .drawingGroup()  // Offload wave rendering to GPU/Metal, keeps main thread free

                Text(display.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: display.displayedCount)
                    .padding(.top, 22)

                Text(String(localized: "We are keeping you entertained while the content arrives."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    // The bar is the runway's own instrument: it fills with `fetched/target`. The
                    // session's lane has no such fraction, so it draws no bar rather than an empty one.
                    if display.hasProgressBar {
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.14))
                                Capsule()
                                    .fill(display.isReady ? Color.green : engine.accent)
                                    .frame(width: max(4, bar.size.width * display.progressFraction))
                            }
                        }
                        .frame(height: 5)
                        .animation(.smooth(duration: 0.3), value: display.progressFraction)
                    }

                    HStack {
                        Text(verbatim: display.detail)
                            .contentTransition(.numericText())
                            .animation(.smooth, value: display.displayedCount)
                        Spacer()
                        if let percentage = display.percentage {
                            Text(verbatim: percentage)
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 290)
                .padding(.top, 28)

                VStack(spacing: 7) {
                    Text(String(localized: "Loading articles"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    ZStack {
                        Text(displayedSourceName.isEmpty ? display.title : displayedSourceName)
                            .id(displayedSourceName)
                            .transition(.opacity)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(engine.accent)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300, minHeight: 42)
                }
                .padding(.top, 34)

                Spacer(minLength: 44)
            }
            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            .padding(.horizontal, 24)
        }
        .drawingGroup()  // Offload entire loading view to GPU/Metal — zero main-thread rendering
        .disabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("initial-feed-loading")
        .accessibilityLabel(display.title)
        .accessibilityValue(display.accessibilityValue)
        // The doctrine's headline case ("close and reopen … no loading screen") is not measurable from the test side:
        // `XCUIApplication.launch()` returns only when the app is idle, which on a warm relaunch is ~2.2 s in, so the
        // test can only sample from there onward and the earlier window is unobserved. These lines timestamp the
        // surface in the *app's* log — where `page[restore]` and `publishCards firstPaint` already live — so the whole
        // window is covered by instruments the harness cannot block.
        .onAppear {
            Log.ui.info(
                "surface[initial-loading] appear source=\(display.source) label=\(display.title) value=\(display.accessibilityValue)"
            )
        }
        .onDisappear { Log.ui.info("surface[initial-loading] disappear") }
        // The surface appears once and the statement then changes in place, so the line above states
        // only the first one. This is the rest of them, in the app's own log beside `page-source=`: it is
        // where "which lane, and what does it say" is readable after the fact.
        .onChange(of: display) { _, next in
            Log.ui.info(
                "surface[initial-loading] statement source=\(next.source) label=\(next.title) value=\(next.accessibilityValue)"
            )
        }
        .task {
            while !Task.isCancelled {
                // The rotation is the runway's own chrome (the sources it just fetched). The session's
                // lane states counts and not titles, so it rotates nothing and the title stands.
                let names = display.rotatingSourceTitles
                if nextSourceNameIndex < names.count {
                    let backlog = names.count - nextSourceNameIndex
                    let step = max(1, backlog / 8)
                    let index = min(names.count - 1, nextSourceNameIndex + step - 1)
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        displayedSourceName = names[index]
                    }
                    nextSourceNameIndex = index + 1
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private struct StartupSignalView: View {
    let accent: Color
    let isReady: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<13, id: \.self) { index in
                    let wave = reduceMotion
                        ? 0.45
                        : (sin(time * 4.2 + Double(index) * 0.72) + 1) / 2
                    Capsule()
                        .fill((isReady ? Color.green : accent).opacity(0.35 + wave * 0.65))
                        .frame(width: 5, height: 12 + wave * 42)
                }
            }
            .frame(width: 152, height: 72)
            .animation(.easeInOut(duration: 0.25), value: isReady)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Empty Filter
struct EmptyFilterView: View {
    let category: String
    var body: some View {
        ContentUnavailableView("No \(category) articles", systemImage: "rectangle.stack.fill", description: Text("This category has articles in the feed, but they may have been trimmed from the visible buffer. Try scrolling through All first.")).padding(.top, 80)
    }
}

// MARK: - Header Button Style

extension View {
    func headerButtonStyle(accent: Color) -> some View {
        self.frame(width: 44, height: 44)
            .background(accent.opacity(0.1))
            .clipShape(Circle())
    }
}
