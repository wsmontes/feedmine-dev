import SwiftUI

struct SourceManagementView: View {
    @Environment(FeedLoader.self) private var loader
    @State private var isTesting = false
    /// Keyed by source URL (not title) — many feeds share a title, which would
    /// collide and overwrite each other's result. Title is carried in the value
    /// for display.
    @State private var testResults: [String: TestResult] = [:]
    /// Display order for the health results, computed once per run. The body used to sort the whole
    /// result set on every evaluation, so each completed request re-sorted every result by title.
    @State private var healthOrder: [String] = []
    /// Running count of `.ok` results, so the footer does not rescan the whole dictionary per body pass.
    @State private var healthSucceeded = 0
    /// The run in flight, held so it can be cancelled: the button used to start an untracked task that
    /// kept testing the whole catalog after the sheet was dismissed.
    @State private var healthTask: Task<Void, Never>?
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var pendingCategoryIDs = Set<String>()
    @State private var enabledPendingCategoryIDs = Set<String>()

    struct TestResult {
        let title: String
        var status: SourceStatus
    }

    enum SourceStatus {
        case ok, failed, testing
        var icon: String {
            switch self { case .ok: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .testing: "circle.dashed" }
        }
        var color: Color {
            switch self { case .ok: .green; case .failed: .red; case .testing: .gray }
        }
        var label: String {
            switch self { case .ok: "OK"; case .failed: "Failed"; case .testing: "Testing..." }
        }
    }

    private var sourcesByCategory: [(String, [FeedSource])] {
        let grouped = Dictionary(grouping: loader.sources, by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                if loader.sources.isEmpty {
                    ContentUnavailableView(
                        "No Sources",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add .opml files to Resources/Feeds/ to populate sources.")
                    )
                }

                // Category toggles
                Section("Categories") {
                    ForEach(sourcesByCategory, id: \.0) { category, sources in
                        HStack {
                            Label("\(category) (\(sources.count))", systemImage: categoryIcon(category))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: {
                                    pendingCategoryIDs.contains(category)
                                        ? enabledPendingCategoryIDs.contains(category)
                                        : loader.isCategoryEnabled(category)
                                },
                                set: { setCategory(category, enabled: $0) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                }

                ForEach(sourcesByCategory, id: \.0) { category, sources in
                    Section {
                        ForEach(sources, id: \.url) { source in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(source.title)
                                            .font(.subheadline)
                                        let health = loader.healthFor(source)
                                        if health.isStale {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                        if health.consecutiveFailures > 0 {
                                            Text("\(health.consecutiveFailures) fails")
                                                .font(.caption2)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    Text(source.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { loader.isSourceEnabled(source.url) },
                                    set: { _ in
                                        loader.toggleSource(source.url)
                                    }
                                ))
                                .labelsHidden()
                                .tint(.green)
                            }
                        }
                    } header: {
                        Label(category, systemImage: categoryIcon(category))
                            .font(.subheadline)
                    }
                }

                Section {
                    HStack {
                        Text("Enabled")
                        Spacer()
                        Text("\(loader.enabledSources.count) of \(loader.sources.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Disabled")
                        Spacer()
                        Text("\(loader.disabledSourceIDs.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Disabled sources are skipped during feed fetching. Changes take effect on next refresh.")
                }

                Section {
                    Button {
                        startHealthCheck()
                    } label: {
                        HStack {
                            Label("Test All Sources", systemImage: "checkmark.circle")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    if !testResults.isEmpty {
                        ForEach(healthOrder, id: \.self) { url in
                            if let result = testResults[url] {
                                HStack {
                                    Image(systemName: result.status.icon)
                                        .font(.caption)
                                        .foregroundStyle(result.status.color)
                                    Text(result.title)
                                        .font(.caption)
                                    Spacer()
                                    Text(result.status.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Health Check")
                } footer: {
                    if !testResults.isEmpty {
                        Text("\(healthSucceeded)/\(testResults.count) sources responding")
                    }
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import OPML File", systemImage: "doc.badge.plus")
                    }
                    if let error = importError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    NavigationLink {
                        ExportView()
                    } label: {
                        Label("Export Sources", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Import & Export")
                } footer: {
                    Text("Import an OPML file or export in multiple formats (OPML, CSV, Markdown, HTML, JSON).")
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        // The health run belongs to this sheet: dismissing it must stop the requests it started.
        .onDisappear { healthTask?.cancel() }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.xml, .init(filenameExtension: "opml")!]) { result in
            switch result {
            case .success(let url):
                do {
                    let newSources = try OPMLParser.parseImportedFile(url: url)
                    loader.addSources(newSources)
                    importError = nil
                } catch {
                    importError = "Failed to parse: \(error.localizedDescription)"
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private func setCategory(_ category: String, enabled: Bool) {
        pendingCategoryIDs.insert(category)
        if enabled {
            enabledPendingCategoryIDs.insert(category)
        } else {
            enabledPendingCategoryIDs.remove(category)
        }
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()

        DispatchQueue.main.async {
            guard pendingCategoryIDs.contains(category), enabledPendingCategoryIDs.contains(category) == enabled else { return }
            loader.setCategoryEnabled(category, enabled: enabled)
            if enabledPendingCategoryIDs.contains(category) == enabled {
                pendingCategoryIDs.remove(category)
            }
        }
    }

    private func startHealthCheck() {
        healthTask?.cancel()
        healthTask = Task { await testSources() }
    }

    /// Tests every source with a bounded sliding window. Cancelled when the sheet goes away or a new run
    /// starts, and it stops issuing requests the moment it is cancelled: the button used to launch an
    /// untracked task that kept walking a catalog of tens of thousands of feeds after dismissal.
    private func testSources() async {
        isTesting = true
        testResults = [:]
        healthSucceeded = 0
        // Order computed once, in the order the results are displayed (by title, as before).
        healthOrder = loader.sources.sorted { $0.title < $1.title }.map(\.url)

        for source in loader.sources {
            testResults[source.url] = TestResult(title: source.title, status: .testing)
        }

        // Bound concurrency with a sliding window. loader.sources can hold
        // thousands of feeds; firing that many simultaneous URLSession requests
        // exhausts the connection pool and produces mass false failures. Keep
        // at most `cap` in flight, refilling each slot as it completes.
        let cap = 10
        await withTaskGroup(of: (String, SourceStatus).self) { group in
            var iterator = loader.sources.makeIterator()
            var started = 0
            while started < cap, !Task.isCancelled, let source = iterator.next() {
                group.addTask { await Self.testSource(source) }
                started += 1
            }
            while let (url, status) = await group.next() {
                guard !Task.isCancelled else { break }
                testResults[url]?.status = status
                if status == .ok { healthSucceeded += 1 }
                guard !Task.isCancelled, let source = iterator.next() else { continue }
                group.addTask { await Self.testSource(source) }
            }
            group.cancelAll()
        }

        isTesting = false
    }

    private static func testSource(_ source: FeedSource) async -> (String, SourceStatus) {
        guard let url = URL(string: source.url) else {
            return (source.url, .failed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Feedmine/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return (source.url, .ok)
            }
            return (source.url, .failed)
        } catch {
            return (source.url, .failed)
        }
    }

    private func categoryIcon(_ category: String) -> String {
        switch category.lowercased() {
        case "tech": return "laptopcomputer"
        case "news": return "newspaper.fill"
        case "science": return "flask.fill"
        case "design": return "paintpalette.fill"
        case "culture": return "theatermasks.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
