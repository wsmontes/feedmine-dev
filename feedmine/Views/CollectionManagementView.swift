import SwiftUI

/// Personal many-to-many playlists of sources. These collections are user
/// state: they never rename, move, duplicate, or delete catalog/OPML sources.
struct CollectionManagementView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var collections: [SourceCollection] = []
    @State private var newName = ""
    @State private var renameTarget: SourceCollection?
    @State private var deleteTarget: SourceCollection?
    @State private var showCreate = false
    @State private var showRename = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if collections.isEmpty {
                    ContentUnavailableView(
                        "No source collections",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Create a reusable playlist of sources. A source can belong to more than one collection.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(collections) { collection in
                                NavigationLink {
                                    SourceCollectionDetailView(collection: collection)
                                } label: {
                                    HStack {
                                        Label(collection.name, systemImage: "rectangle.stack.fill")
                                        Spacer()
                                        Text("\(collection.memberCount) sources")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { deleteTarget = collection } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        renameTarget = collection
                                        newName = collection.name
                                        showRename = true
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .onMove(perform: moveCollections)
                        } footer: {
                            Text("Collections reference sources by their normalized feed address. Deleting one removes only the playlist, never the source or its OPML placement.")
                        }
                    }
                }
            }
            .navigationTitle("Source Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !collections.isEmpty { EditButton() }
                    Button { newName = ""; showCreate = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create source collection")
                }
            }
            .alert("New Source Collection", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await createCollection() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use it like a playlist: add any mix of bundled and imported sources.")
            }
            .alert("Rename Source Collection", isPresented: $showRename) {
                TextField("Name", text: $newName)
                Button("Rename") { Task { await renameCollection() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete \"\(deleteTarget?.name ?? "")\"?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Collection", role: .destructive) {
                    guard let target = deleteTarget else { return }
                    deleteTarget = nil
                    Task { await deleteCollection(target) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text("The sources and their editorial classifications stay intact.")
            }
            .alert("Could not update collections", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
        .task { await reload() }
        .presentationDetents([.medium, .large])
    }

    private func reload() async {
        do { collections = try await loader.loadSourceCollections() }
        catch { errorMessage = error.localizedDescription }
    }

    private func createCollection() async {
        do {
            _ = try await loader.createSourceCollection(name: newName)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func renameCollection() async {
        guard let target = renameTarget else { return }
        do {
            try await loader.renameSourceCollection(id: target.id, name: newName)
            renameTarget = nil
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteCollection(_ collection: SourceCollection) async {
        do {
            try await loader.deleteSourceCollection(id: collection.id)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveCollections(from offsets: IndexSet, to destination: Int) {
        collections.move(fromOffsets: offsets, toOffset: destination)
        let ids = collections.map(\.id)
        Task {
            do { try await loader.reorderSourceCollections(ids: ids) }
            catch { errorMessage = error.localizedDescription; await reload() }
        }
    }
}

private struct SourceCollectionDetailView: View {
    @Environment(FeedLoader.self) private var loader
    let collection: SourceCollection
    @State private var members: [SourceCollectionMember] = []
    @State private var selectedSource: SourceReference?
    @State private var showFeed = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button { showFeed = true } label: {
                    Label("Open Collection Feed", systemImage: "play.rectangle.on.rectangle")
                }
                .disabled(members.isEmpty)
            } footer: {
                Text("Opening refreshes this exact set of sources and merges their available posts into one feed.")
            }

            Section("Sources") {
                if members.isEmpty {
                    Text("Add sources from a card or source result.")
                        .foregroundStyle(.secondary)
                }
                ForEach(members) { member in
                    Button {
                        selectedSource = loader.sourceReference(for: member)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: member.mediaKind))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.title).foregroundStyle(.primary)
                                Text(URL(string: member.sourceURL)?.host ?? member.sourceURL)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await remove(member) }
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
                .onMove(perform: moveMembers)
            }
        }
        .navigationTitle(collection.name)
        .toolbar { EditButton() }
        .task { await reload() }
        .sheet(item: $selectedSource) { SourceFeedView(source: $0) }
        .sheet(isPresented: $showFeed) { SourceCollectionFeedView(collection: collection) }
        .alert("Could not update collection", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func reload() async {
        do { members = try await loader.sourceCollectionMembers(collectionID: collection.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func remove(_ member: SourceCollectionMember) async {
        do {
            try await loader.removeSource(member.sourceURL, fromCollectionID: collection.id)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveMembers(from offsets: IndexSet, to destination: Int) {
        members.move(fromOffsets: offsets, toOffset: destination)
        let urls = members.map(\.sourceURL)
        Task {
            do { try await loader.reorderSourceCollectionMembers(collectionID: collection.id, sourceURLs: urls) }
            catch { errorMessage = error.localizedDescription; await reload() }
        }
    }
}

struct AddSourceToCollectionSheet: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let source: SourceReference
    @State private var collections: [SourceCollection] = []
    @State private var memberships: Set<Int64> = []
    @State private var newName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Collections") {
                    if collections.isEmpty {
                        Text("Create the first collection below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(collections) { collection in
                        Button { Task { await toggle(collection) } } label: {
                            HStack {
                                Text(collection.name).foregroundStyle(.primary)
                                Spacer()
                                if memberships.contains(collection.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Section("Create and add") {
                    TextField("Collection name", text: $newName)
                    Button {
                        Task { await createAndAdd() }
                    } label: {
                        Label("Create Collection", systemImage: "plus.circle.fill")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add \(source.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await reload() }
        .presentationDetents([.medium, .large])
        .alert("Could not update collections", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Unknown error") }
    }

    private func reload() async {
        do {
            async let lists = loader.loadSourceCollections()
            async let ids = loader.sourceCollectionIDs(containing: source.feedURL)
            collections = try await lists
            memberships = try await ids
        } catch { errorMessage = error.localizedDescription }
    }

    private func toggle(_ collection: SourceCollection) async {
        do {
            if memberships.contains(collection.id) {
                try await loader.removeSource(source.feedURL, fromCollectionID: collection.id)
                memberships.remove(collection.id)
            } else {
                try await loader.addSource(source, toCollectionID: collection.id)
                memberships.insert(collection.id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func createAndAdd() async {
        do {
            let id = try await loader.createSourceCollection(name: newName)
            try await loader.addSource(source, toCollectionID: id)
            newName = ""
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SourceFeedView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let source: SourceReference
    @State private var items: [FeedItem] = []
    /// Pre-resolved card presentations for source items. Built during load()
    /// so FeedItemCardView can render proper layouts and images instead of
    /// falling back to text-only when presentation is nil.
    @State private var cards: [FeedCardPresentation] = []
    @State private var isLoading = true
    @State private var result: SourceContentResult?
    @State private var articleItem: FeedItem?
    @State private var sourceToCollect: SourceReference?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    sourceHeader
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(items.isEmpty ? "Loading every post available from this source…" : "Checking the source for more posts…")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    if !isLoading && items.isEmpty {
                        ContentUnavailableView(
                            emptyTitle,
                            systemImage: result?.fetchStatus == .failed ? "wifi.exclamationmark" : "tray",
                            description: Text(emptyDescription)
                        )
                        .padding(.top, 30)
                    }
                    ForEach(items) { item in
                        let render = MainFeedCardBridge.card(
                            item: item,
                            presentation: cards.first { $0.id == item.id },
                            band: loader.layout
                        )
                        FeedItemView(
                            item: item,
                            card: render.card,
                            mediaSlot: render.mediaSlot,
                            onOpen: { articleItem = item },
                            onAddSourceToCollection: { sourceToCollect = source },
                            actionSurface: .source,
                            // The surface's materialization scope. A source's *history* scope is
                            // `.source(SourceID)`, a runtime identity ADR-003 D2/D18 forbids deriving
                            // from a URL, so this names the materialization and never claims history.
                            actionScopeKey: source.feedURL
                        )
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 12)
            }
            .refreshable { await load() }
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { sourceToCollect = source } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                    }
                    .accessibilityLabel("Add source to collection")
                }
            }
        }
        .task(id: source.id) { await load() }
        .sheet(item: $articleItem) { ArticleReaderView(item: $0) }
        .sheet(item: $sourceToCollect) { AddSourceToCollectionSheet(source: $0) }
        .accessibilityIdentifier("source-feed-\(source.id)")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
                .background(.ultraThinMaterial)
        }
    }

    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon(for: source.mediaKind))
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.title2.bold())
                    if let host = source.displayHost {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if let description = source.sourceDescription, !description.isEmpty {
                Text(description).font(.subheadline)
            }
            if !source.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(source.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.11), in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if let activity = source.activity {
                    Label(activity.capitalized, systemImage: "waveform.path.ecg")
                }
                if let language = source.language {
                    Label(language.uppercased(), systemImage: "character.book.closed")
                }
                if let result {
                    Label("\(result.items.count) posts", systemImage: "doc.on.doc")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !source.defaultEnabled {
                Label(
                    "Dormant in the automatic feed. Opening it here is intentional and does not enable future refreshes.",
                    systemImage: "archivebox"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button { loader.toggleSource(source.feedURL) } label: {
                    Label(loader.isSourceEnabled(source.feedURL) ? "Disable" : "Enable", systemImage: "antenna.radiowaves.left.and.right")
                }
                if let rawSiteURL = source.siteURL, let siteURL = URL(string: rawSiteURL) {
                    Link(destination: siteURL) { Label("Website", systemImage: "safari") }
                }
                ShareLink(item: source.feedURL) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.bordered)

            Text("Includes all posts currently exposed by the feed plus retained local history. A publisher website may keep older archives that RSS/Atom does not expose.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    private var emptyTitle: String {
        result?.fetchStatus == .failed ? "Source unavailable" : "No posts exposed"
    }

    private var emptyDescription: String {
        if result?.fetchStatus == .failed {
            return "Feedmine could not refresh this source, and no local history is available. Try again or open its website."
        }
        return "The feed endpoint returned no posts. Its website may still have an archive."
    }

    private func load() async {
        isLoading = true

        // Load items from cache first for immediate display while building
        // presentations. The endpoint refresh runs in parallel.
        let cached = await loader.sourceContentFromCache(source)
        let cachedPresentations = await buildPresentations(for: cached)
        if !cached.isEmpty {
            items = cached
            cards = cachedPresentations
        }

        let loaded = await loader.loadSourceContent(source)
        result = loaded

        // Build presentations for fresh items. Resolve images through the
        // same pipeline used by the main feed — memory/disk cache hits are
        // instant; misses download and are cached for subsequent views.
        let loadedPresentations = await buildPresentations(for: loaded.items)
        items = loaded.items
        cards = loadedPresentations
        isLoading = false
    }

    /// Resolves images and builds FeedCardPresentation objects for the given items.
    /// Uses ImageLoader.resolveImage which checks memory cache → disk cache →
    /// in-flight download → network download (with OG fallback for articles).
    /// nonisolated — runs image resolution off the main actor so the UI stays
    /// responsive during concurrent downloads.
    private nonisolated func buildPresentations(for items: [FeedItem]) async -> [FeedCardPresentation] {
        guard !items.isEmpty else { return [] }

        // Resolve images concurrently for the first page (20 items), then
        // continue resolving the rest in the background. This matches the
        // main feed's behavior: show the first page as soon as it's ready.
        let pageSize = 20
        let initialBatch = Array(items.prefix(pageSize))
        let rest = Array(items.dropFirst(pageSize))

        var presentations: [FeedCardPresentation] = []

        // Resolve first page concurrently
        await withTaskGroup(of: (Int, FeedCardPresentation).self) { group in
            for (idx, item) in initialBatch.enumerated() {
                group.addTask {
                    let pres = await Self.resolvePresentation(for: item)
                    return (idx, pres)
                }
            }
            var batchResults: [(Int, FeedCardPresentation)] = []
            for await result in group { batchResults.append(result) }
            batchResults.sort { $0.0 < $1.0 }
            presentations = batchResults.map(\.1)
        }

        // Resolve remaining items in background (don't block first paint)
        if !rest.isEmpty {
            Task.detached(priority: .background) {
                var restPresentations: [FeedCardPresentation] = []
                for item in rest {
                    guard !Task.isCancelled else { break }
                    restPresentations.append(await Self.resolvePresentation(for: item))
                }
                // Merge back into the main cards array on the next load
                // or refresh — for now, items beyond page 1 use placeholder.
            }
            // Fill remaining slots with placeholder presentations so the
            // cards array is complete (items beyond page 1 show placeholders
            // until the background task completes on next refresh).
            for item in rest {
                presentations.append(Self.placeholderPresentation(for: item))
            }
        }

        return presentations
    }

    /// Resolves the best available image for an item and returns a terminal
    /// FeedCardPresentation — `.image` if resolved, `.placeholder` otherwise.
    /// nonisolated — only accesses Sendable parameters and non-MainActor APIs.
    private nonisolated static func resolvePresentation(for item: FeedItem) async -> FeedCardPresentation {
        let imageURL = item.imageURL.flatMap(URL.init(string:))
        let articleURL = URL(string: item.url)

        let media: ResolvedCardMedia
        if let resolvedImage = await ImageLoader.resolveImage(url: imageURL, articleURL: articleURL) {
            media = .image(resolvedImage)
        } else if imageURL != nil || articleURL != nil {
            // Item has image candidates but resolution failed → placeholder
            media = .placeholder
        } else {
            // No image slot at all → text-only
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
            isRead: item.isRead,
            isBookmarked: item.isBookmarked
        )
    }

    /// Creates a placeholder presentation for items whose images haven't
    /// been resolved yet (beyond the first page).
    /// nonisolated — only accesses Sendable parameters.
    private nonisolated static func placeholderPresentation(for item: FeedItem) -> FeedCardPresentation {
        let hasImageCandidate = item.imageURL != nil || !item.url.isEmpty
        return FeedCardPresentation(
            item: item,
            media: hasImageCandidate ? .placeholder : .none,
            layout: hasImageCandidate ? .hero : .textOnly,
            isRead: item.isRead,
            isBookmarked: item.isBookmarked
        )
    }
}

private struct SourceCollectionFeedView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    let collection: SourceCollection
    @State private var items: [FeedItem] = []
    @State private var isLoading = true
    @State private var result: SourceCollectionContentResult?
    @State private var errorMessage: String?
    @State private var articleItem: FeedItem?
    @State private var selectedSource: SourceReference?
    @State private var sourceToCollect: SourceReference?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let result {
                        HStack {
                            Label("\(result.sourceCount) sources", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if result.failedSourceCount > 0 {
                                Text("\(result.failedSourceCount) unavailable").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 16)
                    }
                    if isLoading {
                        ProgressView("Refreshing collection sources…").padding()
                    } else if items.isEmpty {
                        ContentUnavailableView(
                            "No collection posts",
                            systemImage: "rectangle.stack",
                            description: Text(errorMessage ?? "Add a source or try refreshing this collection.")
                        )
                        .padding(.top, 40)
                    }
                    ForEach(items) { item in
                        let render = MainFeedCardBridge.card(
                            item: item,
                            presentation: nil,
                            band: loader.layout
                        )
                        FeedItemView(
                            item: item,
                            card: render.card,
                            mediaSlot: render.mediaSlot,
                            onOpen: { articleItem = item },
                            onViewSource: { selectedSource = loader.sourceReference(for: item) },
                            onAddSourceToCollection: { sourceToCollect = loader.sourceReference(for: item) },
                            actionSurface: .sourceCollection,
                            actionScopeKey: String(collection.id)
                        )
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 12)
            }
            .refreshable { await load() }
            .navigationTitle(collection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
        .sheet(item: $articleItem) { ArticleReaderView(item: $0) }
        .sheet(item: $selectedSource) { SourceFeedView(source: $0) }
        .sheet(item: $sourceToCollect) { AddSourceToCollectionSheet(source: $0) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
                .background(.ultraThinMaterial)
        }
    }

    private func load() async {
        isLoading = true
        do {
            let loaded = try await loader.loadSourceCollectionContent(collectionID: collection.id)
            result = loaded
            items = loaded.items
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private func icon(for kind: MediaKind) -> String {
    switch kind {
    case .text: return "doc.text"
    case .video: return "play.rectangle.fill"
    case .audio: return "headphones"
    case .forum: return "bubble.left.and.bubble.right.fill"
    }
}
