import SwiftUI
import UIKit

struct ExportView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var engine = CircadianEngine.shared
    @State private var selectedScope: ExportScope = .all
    @State private var selectedFormat: ExportFormat = .opml
    /// Collection scope's selection. Deliberately not shared with the country picker: the two scopes
    /// filter on different keys, and one `String?` serving both leaked a category into the region
    /// picker (and the reverse), exporting zero feeds with no visible cause.
    @State private var selectedCollection: String?
    /// Country scope's selection — independent of `selectedCollection` for the same reason.
    @State private var selectedCountry: String?
    /// Bookmark box to export. `nil` means every box, deduplicated by item.
    @State private var selectedBookmarkListID: Int64?
    @State private var bookmarkLists: [BookmarkList] = []
    /// True while the bookmark composition is being read: export actions are blocked until it resolves
    /// so a fast tap cannot share an empty file, and the preview is rebuilt when it completes.
    @State private var isLoadingBookmarks = false
    @State private var preview: String = ""
    @State private var showDocumentPicker = false
    @State private var exportFileURL: URL?
    @State private var bookmarkedArticles: [FeedItem] = []
    /// Scope pickers group the whole catalog; cached instead of regrouped on every body pass.
    @State private var collectionOptions: [String] = []
    @State private var countryOptions: [String] = []

    private var scopedSources: [FeedSource] {
        switch selectedScope {
        case .all: return loader.sources
        case .enabledOnly: return loader.enabledSources
        case .collection:
            guard let col = selectedCollection else { return loader.sources }
            return loader.sources.filter { $0.category == col }
        case .country:
            guard let col = selectedCountry else { return loader.sources }
            return loader.sources.filter { $0.region == col || $0.region.hasPrefix(col + "/") }
        case .bookmarks: return loader.sources  // Bookmarks export uses articles, not sources
        case .fullBackup: return loader.sources
        }
    }

    private var enabledURLs: Set<String> {
        Set(loader.enabledSources.map(\.url))
    }

    /// Regroups the catalog once per presentation instead of on every body evaluation — the body used
    /// to rebuild both option lists (whole-catalog map + sort) for each state change of the sheet.
    private func refreshScopeOptions() {
        collectionOptions = Set(loader.sources.map(\.category)).sorted()
        countryOptions = Set(loader.sources.map(\.region).filter { $0.hasPrefix("countries/") }
            .map { $0.components(separatedBy: "/").prefix(2).joined(separator: "/") }).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Scope
                Section("What to export") {
                    Picker("Scope", selection: $selectedScope) {
                        ForEach(ExportScope.allCases) { scope in
                            Label(scope.rawValue, systemImage: scope.icon).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)

                    if selectedScope == .collection {
                        Picker("Collection", selection: $selectedCollection) {
                            Text("All").tag(nil as String?)
                            ForEach(collectionOptions, id: \.self) { col in
                                Text(col).tag(col as String?)
                            }
                        }
                    }
                    if selectedScope == .country {
                        Picker("Country", selection: $selectedCountry) {
                            Text("All").tag(nil as String?)
                            ForEach(countryOptions, id: \.self) { country in
                                Text(CountryStore.countryName(for: country.replacingOccurrences(of: "countries/", with: "")))
                                    .tag(country as String?)
                            }
                        }
                    }
                    if selectedScope == .bookmarks {
                        // "All" is every box, deduplicated by item: the export is named "Bookmarks",
                        // so an article saved to a non-default box must not be missing from it.
                        Picker("Box", selection: $selectedBookmarkListID) {
                            Text("All Boxes").tag(nil as Int64?)
                            ForEach(bookmarkLists) { box in
                                Text(box.name).tag(box.id as Int64?)
                            }
                        }
                        .disabled(isLoadingBookmarks)
                        if isLoadingBookmarks {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading bookmarks…").foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("Sources")
                        Spacer()
                        Text("\(scopedSources.count) feeds")
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Format
                Section("Format") {
                    ForEach(availableFormats) { format in
                        Button {
                            selectedFormat = format
                            updatePreview()
                        } label: {
                            HStack {
                                Label(format.rawValue, systemImage: format.icon)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedFormat == format {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(engine.accent)
                                }
                            }
                        }
                    }
                }

                // MARK: - Preview
                if !preview.isEmpty {
                    Section("Preview") {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(12)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Actions
                Section {
                    Button {
                        shareExport()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .foregroundStyle(engine.accent)
                    }

                    Button {
                        saveToFiles()
                    } label: {
                        Label("Save to Files", systemImage: "folder.badge.plus")
                            .foregroundStyle(engine.accent)
                    }

                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            .foregroundStyle(engine.accent)
                    }
                }
                .disabled(selectedScope == .bookmarks && isLoadingBookmarks)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                refreshScopeOptions()
                updatePreview()
            }
            .onChange(of: selectedScope) { _, newScope in
                if newScope == .bookmarks {
                    Task { await loadBookmarks() }
                }
                updatePreview()
            }
            .onChange(of: selectedCollection) { _, _ in updatePreview() }
            .onChange(of: selectedCountry) { _, _ in updatePreview() }
            .onChange(of: selectedBookmarkListID) { _, _ in
                guard selectedScope == .bookmarks else { return }
                Task { await loadBookmarks() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Available formats per scope

    private var availableFormats: [ExportFormat] {
        switch selectedScope {
        case .bookmarks:
            return [.text, .markdown, .csv, .html]  // Articles, not OPML
        case .fullBackup:
            return [.json]  // Only JSON for full backup
        default:
            return ExportFormat.allCases
        }
    }

    // MARK: - Actions

    /// Reads the bookmark composition for the selected box — every box when `selectedBookmarkListID`
    /// is nil — and rebuilds the preview from what was actually loaded. The caller blocks the export
    /// actions while this is in flight, so an export can never share the empty array the scope opened with.
    private func loadBookmarks() async {
        isLoadingBookmarks = true
        defer { isLoadingBookmarks = false }
        do {
            let lists = try await loader.loadBookmarkLists()
            bookmarkLists = lists
            if let selected = selectedBookmarkListID, !lists.contains(where: { $0.id == selected }) {
                selectedBookmarkListID = nil
            }
            let target = selectedBookmarkListID
            var seen = Set<String>()
            var articles: [FeedItem] = []
            for list in lists where target == nil || list.id == target {
                for item in try await loader.loadBookmarkedItems(listID: list.id)
                where seen.insert(item.id).inserted {
                    articles.append(item)
                }
            }
            bookmarkedArticles = articles
        } catch {
            bookmarkedArticles = []
        }
        updatePreview()
    }

    /// The preview is a *sample*: OPML/JSON/CSV/text/Markdown build the entire document, and the sheet
    /// used to serialize the whole catalog on the main actor only to cut it to 500 characters. The real
    /// export (`generateExportData`) still serializes the complete selection.
    private static let previewSourceLimit = 25

    private func updatePreview() {
        // Reset format if not available for current scope
        if !availableFormats.contains(selectedFormat) {
            selectedFormat = availableFormats.first ?? .opml
        }

        let allSources = scopedSources
        let sources = Array(allSources.prefix(Self.previewSourceLimit))
        switch selectedFormat {
        case .opml:
            preview = String(data: ExportEngine.opml(sources: sources).prefix(500), encoding: .utf8) ?? ""
        case .json:
            let filters = ContentFilterStore.shared.filters
            let bookmarkIDs = Array(loader.bookmarkedIDs)
            preview = String(data: ExportEngine.jsonBackup(sources: sources, contentFilters: filters, bookmarkIDs: bookmarkIDs).prefix(500), encoding: .utf8) ?? ""
        case .csv:
            if selectedScope == .bookmarks {
                preview = String(data: ExportEngine.csvArticles(items: bookmarkedArticles).prefix(500), encoding: .utf8) ?? ""
            } else {
                preview = String(data: ExportEngine.csv(sources: sources, enabledURLs: enabledURLs).prefix(500), encoding: .utf8) ?? ""
            }
        case .text:
            if selectedScope == .bookmarks {
                preview = String(ExportEngine.plainTextArticles(items: bookmarkedArticles).prefix(500))
            } else {
                preview = String(ExportEngine.plainText(sources: sources).prefix(500))
            }
        case .markdown:
            if selectedScope == .bookmarks {
                preview = String(ExportEngine.markdownArticles(items: bookmarkedArticles).prefix(500))
            } else {
                preview = String(ExportEngine.markdown(sources: sources).prefix(500))
            }
        case .html:
            if selectedScope == .bookmarks {
                preview = "HTML reading list (\(bookmarkedArticles.count) articles). Dark mode ready."
            } else {
                preview = "HTML blogroll (\(allSources.count) feeds, \(Set(allSources.map(\.category)).count) collections). Dark mode ready."
            }
        case .shareLink:
            // `ExportEngine.shareLink` writes a temp OPML for a batch selection: the preview used to call
            // it and write that file — for the whole catalog — on every scope/format change. Describe the
            // batch instead of materializing it; the real share builds it in `shareExport`.
            if allSources.count == 1, let only = allSources.first {
                if case .text(let s) = ExportEngine.shareLink(sources: [only]) { preview = s }
            } else {
                preview = "Share \(allSources.count) feeds as an OPML attachment"
            }
        case .socialCard:
            let stats = ExportEngine.SocialCardStats(
                streak: Settings.sessionStreak,
                articlesRead: loader.readItemIDs.count
            )
            preview = ExportEngine.socialCard(sources: allSources, stats: stats)
        }
        // Bookmarks scope previews articles, not sources: the sample note belongs only to a source preview.
        if selectedScope != .bookmarks,
           Self.wholeDocumentFormats.contains(selectedFormat),
           allSources.count > sources.count {
            preview += "\n… preview of the first \(sources.count) of \(allSources.count) sources"
        }
    }

    /// Formats whose preview builds an entire document. Only these are sampled; the count-only and
    /// single-string previews above still describe the complete selection.
    private static let wholeDocumentFormats: Set<ExportFormat> = [.opml, .json, .csv, .text, .markdown]

    private func generateExportData() -> (data: Data, filename: String)? {
        // The actions are disabled while the bookmark composition loads; this is the second line of
        // defence for any other caller: an unresolved bookmarks scope must never produce a file.
        guard !(selectedScope == .bookmarks && isLoadingBookmarks) else { return nil }
        let sources = scopedSources
        let name = "feedmine-export-\(Int(Date().timeIntervalSince1970))"

        // Bookmarks scope exports articles, not sources
        if selectedScope == .bookmarks {
            let articles = bookmarkedArticles
            switch selectedFormat {
            case .csv: return (ExportEngine.csvArticles(items: articles), "\(name)-bookmarks.csv")
            case .text: return (Data(ExportEngine.plainTextArticles(items: articles).utf8), "\(name)-bookmarks.txt")
            case .markdown: return (Data(ExportEngine.markdownArticles(items: articles).utf8), "\(name)-bookmarks.md")
            case .html: return (ExportEngine.htmlArticles(items: articles), "\(name)-bookmarks.html")
            default: return nil
            }
        }

        switch selectedFormat {
        case .opml: return (ExportEngine.opml(sources: sources), "\(name).opml")
        case .json:
            let filters = ContentFilterStore.shared.filters
            let bookmarkIDs = Array(loader.bookmarkedIDs)
            return (ExportEngine.jsonBackup(sources: sources, contentFilters: filters, bookmarkIDs: bookmarkIDs), "\(name).json")
        case .csv: return (ExportEngine.csv(sources: sources, enabledURLs: enabledURLs), "\(name).csv")
        case .text: return (Data(ExportEngine.plainText(sources: sources).utf8), "\(name).txt")
        case .markdown: return (Data(ExportEngine.markdown(sources: sources).utf8), "\(name).md")
        case .html: return (ExportEngine.htmlBlogroll(sources: sources), "\(name).html")
        case .shareLink, .socialCard: return nil
        }
    }

    private func shareExport() {
        if selectedFormat == .shareLink {
            let result = ExportEngine.shareLink(sources: scopedSources)
            presentShareSheet(items: result.activityItems)
            return
        }
        if selectedFormat == .socialCard {
            let stats = ExportEngine.SocialCardStats(
                streak: Settings.sessionStreak,
                articlesRead: loader.readItemIDs.count
            )
            let text = ExportEngine.socialCard(sources: scopedSources, stats: stats)
            presentShareSheet(items: [text])
            return
        }
        guard let (data, filename) = generateExportData() else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)
        presentShareSheet(items: [tempURL])
    }

    private func saveToFiles() {
        // Use Share Sheet which includes "Save to Files" as an option.
        // This is the standard iOS pattern — UIDocumentPickerViewController
        // is for opening files, not saving. The Share Sheet's "Save to Files"
        // action uses the proper system file saver.
        shareExport()
    }

    private func copyToClipboard() {
        let text: String
        switch selectedFormat {
        case .socialCard:
            let stats = ExportEngine.SocialCardStats(
                streak: Settings.sessionStreak,
                articlesRead: loader.readItemIDs.count
            )
            text = ExportEngine.socialCard(sources: scopedSources, stats: stats)
        case .shareLink:
            let result = ExportEngine.shareLink(sources: scopedSources)
            if case .text(let s) = result { text = s } else { text = "" }
        case .text, .markdown:
            // For bookmarks scope, export article content; for sources, export source list
            if selectedScope == .bookmarks, let (data, _) = generateExportData() {
                text = String(data: data, encoding: .utf8) ?? ""
            } else {
                text = selectedFormat == .text
                    ? ExportEngine.plainText(sources: scopedSources)
                    : ExportEngine.markdown(sources: scopedSources)
            }
        default:
            if let (data, _) = generateExportData() {
                text = String(data: data, encoding: .utf8) ?? ""
            } else { text = "" }
        }
        UIPasteboard.general.string = text
    }

    private func presentShareSheet(items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = windowScene.windows.first?.rootViewController else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        root.present(av, animated: true)
    }
}
