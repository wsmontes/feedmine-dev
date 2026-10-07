import SwiftUI

// MARK: - CatalogExploreView

/// Full-screen catalog browser and search tool.
///
/// Owns a ``CatalogBrowserViewModel`` and renders browse/search results in a
/// compact utilitarian layout — this is a debug/explore tool, not a landing page.
struct CatalogExploreView: View {
    @State private var viewModel: CatalogBrowserViewModel
    @Environment(\.dismiss) private var dismiss

    init(engine: FeedEngineProtocol) {
        _viewModel = State(initialValue: CatalogBrowserViewModel(engine: engine))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                content
            }
            .navigationTitle(viewModel.currentNodeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !viewModel.navigationPath.isEmpty {
                        Button {
                            Task { await viewModel.goBack() }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await viewModel.loadRoot() }
            .sheet(item: detailsBinding) { details in
                sourceDetailsView(details)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Search catalog...", text: $viewModel.searchText)
                    .font(.subheadline)

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            if viewModel.isLoading && !viewModel.hasContent {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isSearching {
                searchContent
            } else {
                browseContent
            }

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
    }

    // MARK: - Browse Mode

    private var browseContent: some View {
        List {
            if !viewModel.nodes.isEmpty {
                Section("Nodes") {
                    ForEach(viewModel.nodes) { node in
                        nodeRow(node)
                    }
                }
            }

            if !viewModel.sources.isEmpty {
                Section("Sources") {
                    ForEach(viewModel.sources) { source in
                        sourceRow(source)
                    }
                }
            }

            // The control belongs to the list, not to the Sources section: browse orders every node
            // of the level before its first source, so a full page of nodes with the cursor still
            // open would otherwise leave the rest of the level unreachable.
            if viewModel.canLoadMoreBrowse {
                loadMoreButton {
                    Task { await viewModel.loadNextPage() }
                }
            }

            if viewModel.isLoadingMore {
                loadingRow
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Search Mode

    private var searchContent: some View {
        List {
            if !viewModel.searchResults.isEmpty {
                Section {
                    ForEach(viewModel.searchResults) { source in
                        sourceRow(source)
                    }
                    if viewModel.canLoadMoreSearch {
                        loadMoreButton {
                            Task { await viewModel.loadNextSearchPage() }
                        }
                    }
                } header: {
                    let count = viewModel.estimatedTotalCount ?? viewModel.searchResults.count
                    Text("Search Results (\(count))")
                }
            }

            if viewModel.isLoadingMore {
                loadingRow
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Row Builders

    private func nodeRow(_ node: CatalogNodeSummary) -> some View {
        Button {
            Task { await viewModel.navigate(to: node) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: node.kind.icon)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(width: 20)
                Text(node.name)
                    .font(.subheadline)
                Spacer()
                if node.sourceCount > 0 {
                    Text("\(node.sourceCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func sourceRow(_ source: SourceSummary) -> some View {
        Button {
            Task { await viewModel.loadSourceDetails(for: source.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: source.mediaKind.icon)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let host = source.displayHost {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if viewModel.loadingDetailsSourceID == source.id {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 4)
                }
                if let lang = source.language {
                    Text(lang.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func loadMoreButton(action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Load More", action: action)
                .font(.subheadline)
                .buttonStyle(.bordered)
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    private var loadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .padding(.vertical, 8)
            Spacer()
        }
        .listRowSeparator(.hidden)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Source Details Sheet

    @ViewBuilder
    private func sourceDetailsView(_ details: SourceDetails) -> some View {
        NavigationStack {
            List {
                Section("Info") {
                    LabeledContent("Title", value: details.title)
                    LabeledContent("URL") {
                        Text(details.declaredURL.absoluteString)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                    }
                    LabeledContent("Request") {
                        Text(details.requestURL.absoluteString)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                    }
                    LabeledContent("Media") {
                        HStack(spacing: 4) {
                            Image(systemName: details.mediaKind.icon)
                                .foregroundStyle(.secondary)
                            Text(details.mediaKind.rawValue.capitalized)
                        }
                    }
                    if let lang = details.language {
                        LabeledContent("Language", value: lang.uppercased())
                    }
                }

                if !details.placements.isEmpty {
                    Section("Placements (\(details.placements.count))") {
                        ForEach(details.placements) { placement in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(placement.nodeName)
                                    .font(.subheadline)
                                Text(placement.opmlFile)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .navigationTitle(details.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { viewModel.clearSourceDetails() }
                }
            }
        }
    }

    // MARK: - Bindings

    private var detailsBinding: Binding<SourceDetails?> {
        Binding(
            get: { viewModel.selectedSourceDetails },
            set: { if $0 == nil { viewModel.clearSourceDetails() } }
        )
    }
}

// MARK: - Icon Extensions

private extension CatalogNodeKind {
    var icon: String {
        switch self {
        case .topic: return "folder"
        case .country: return "flag"
        case .region: return "map"
        case .subcategory: return "list.bullet"
        case .language: return "globe"
        }
    }
}

private extension MediaKind {
    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .audio: return "headphones"
        case .video: return "video"
        case .forum: return "bubble.left.and.bubble.right"
        }
    }
}
