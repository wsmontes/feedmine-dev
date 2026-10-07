import SwiftUI

/// Full-screen taxonomy browser with NavigationStack drill-down.
/// Each level shows direct children of the current node with checkboxes.
/// Tapping a row with children navigates deeper.
struct TaxonomyBrowseView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let root = store.root {
                TaxonomyLevelView(node: root, isRoot: true)
                    .navigationTitle("Topics")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                                .accessibilityIdentifier("topics-done")
                                .accessibilityValue("\(store.selectedNodeIDs.count)")
                        }
                    }
            }
        }
    }
}

/// A single level of the taxonomy browse — shows children of one node.
private struct TaxonomyLevelView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var store = TaxonomyStore.shared
    @State private var searchText = ""
    @State private var searchResults: [TaxonomyNode] = []
    @State private var searchTask: Task<Void, Never>?
    let node: TaxonomyNode
    var isRoot: Bool = false

    var body: some View {
        let children = store.children(of: node.id)
        List {
            // Search bar at root level only
            if isRoot {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search topics...", text: $searchText)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("search-topics")
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                searchResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onChange(of: searchText) { _, query in
                    searchTask?.cancel()
                    guard !query.isEmpty else {
                        searchResults = []
                        return
                    }
                    let q = query
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        searchResults = store.search(q)
                    }
                }
            }

            // Show search results or normal children
            if !searchText.isEmpty {
                ForEach(searchResults) { result in
                    searchResultRow(result)
                }
            } else {
                if node.id != TaxonomyNode.rootID {
                    // "All in this category" toggle
                    Button {
                        loader.toggleNode(node.id)
                    } label: {
                        HStack {
                            Image(systemName: store.selectedNodeIDs.contains(node.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary)
                            Text("All \(node.name)")
                                .fontWeight(.medium)
                            Spacer()
                            if let lang = node.language {
                                Text(lang.uppercased())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text("\(node.feedCount) feeds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                ForEach(children) { child in
                    if store.hasChildren(child.id) {
                        // Has children — navigate deeper
                        NavigationLink {
                            TaxonomyLevelView(node: child)
                                .navigationTitle(child.name)
                        } label: {
                            taxonomyRow(child)
                        }
                        .accessibilityIdentifier("topic-node-\(child.id)")
                        .accessibilityValue(store.selectedNodeIDs.contains(child.id) ? "selected" : "not selected")
                    } else {
                        // Leaf — no children, just toggle
                        Button {
                            loader.toggleNode(child.id)
                        } label: {
                            taxonomyRow(child)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("topic-node-\(child.id)")
                        .accessibilityValue(store.selectedNodeIDs.contains(child.id) ? "selected" : "not selected")
                    }
                }
            }
        }
        .listStyle(.plain)
        .onDisappear { searchTask?.cancel() }
    }

    private func taxonomyRow(_ child: TaxonomyNode) -> some View {
        HStack {
            Image(systemName: store.selectedNodeIDs.contains(child.id)
                  ? "checkmark.circle.fill"
                  : "circle")
                .foregroundStyle(store.selectedNodeIDs.contains(child.id) ? .blue : .secondary)
            Text(child.name)
            if let lang = child.language {
                Text(lang.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            Text("\(child.feedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func searchResultRow(_ node: TaxonomyNode) -> some View {
        Button {
            loader.toggleNode(node.id)
            searchText = ""
            searchResults = []
        } label: {
            HStack {
                Image(systemName: store.selectedNodeIDs.contains(node.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(store.selectedNodeIDs.contains(node.id) ? .blue : .secondary.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.subheadline)
                    let breadcrumb = store.ancestors(of: node.id)
                        .filter { $0.id != TaxonomyNode.rootID && $0.id != node.id }
                        .map(\.name)
                        .joined(separator: " › ")
                    if !breadcrumb.isEmpty {
                        Text(breadcrumb)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let lang = node.language {
                        Text(lang.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(node.feedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("taxonomy-node-\(node.id)")
        .accessibilityValue(store.selectedNodeIDs.contains(node.id) ? "selected" : "not selected")
    }
}
