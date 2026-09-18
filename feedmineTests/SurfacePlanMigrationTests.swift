import XCTest
import GRDB
import FeedDomain
import FeedRuntime
import FeedStorage
@testable import feedmine

/// PR-14 item 1 and item 2 on the app side: the surface plans are registered, they resolve under the
/// history scope their row declares, the online content demand is separate from the local search, and
/// the local content search reads the index the launch's mode installed — the canonical
/// `origin_search` in a launch whose runtime owns acquisition, the legacy `feed_item_fts` otherwise.
///
/// The matrix itself lives in the package (`FeedSurfaceCatalog`) and is asserted there; what these
/// tests pin is that the app's adapters *use* it — a surface whose row says it preserves navigable
/// history must not be given a plan that excludes by `seen`, and a local content search must not be
/// able to start an online sweep as a side effect.
@MainActor
final class SurfacePlanMigrationTests: XCTestCase {

    private let fixedClock = FixedSurfaceClock(milliseconds: 1_700_000_000_000)

    override func setUp() {
        super.setUp()
        normalizeSharedFilterStateForTests()
    }

    override func tearDown() async throws {
        TaxonomyStore.shared.clearSelection()
        try await super.tearDown()
    }

    // MARK: - Registration

    /// Every surface the app renders resolves, and the scope it resolves under is the one the row
    /// declares. A row that forgot a surface, or a surface resolved under another surface's scope,
    /// fails here rather than in production.
    func testEveryCardSurfaceResolvesUnderItsOwnHistoryScope() throws {
        let adapters = SurfaceContextAdapters(clock: fixedClock)
        let cases: [(FeedSurface, HistoryScope)] = [
            (.main, .main),
            (.sourceCollection, .collection(key: "collection-7")),
            (.bookmarks, .bookmark(listKey: nil)),
            (.search, .search),
            (.smartFeed, .smartFeed(key: "smart-3")),
            (.persistentSearch, .persistentSearch(key: "saved-1")),
            (.lastClicked, .lastClicked),
            (.whatsNew, .whatsNew),
            (.onboarding, .onboarding),
        ]
        for (surface, expectedScope) in cases {
            let inputs = self.inputs(for: surface)
            let context = try adapters.context(surface, inputs: inputs)
            XCTAssertEqual(context.plan.historyPolicy.scope, expectedScope, "\(surface.rawValue)")
            XCTAssertEqual(
                context.plan.historyPolicy.applySeen,
                expectedScope.allowsSeenExclusion,
                "\(surface.rawValue): a surface may not declare an exposure rule of its own"
            )
            XCTAssertEqual(context.contextKey.surface, FeedSurfaceCatalog.plan(for: surface).contextSurface)
            XCTAssertEqual(context.row, FeedSurfaceCatalog.plan(for: surface))
        }
    }

    /// The Source surface's plan names a runtime source identity, and ADR-003 D2/D18 forbid deriving
    /// one from a catalogue id or a URL — so the app cannot state the plan, and says so instead of
    /// inventing a scope. This is the PR-14 gap the report names, as a test.
    func testSourceSurfaceRefusesAPlanWithoutAnAllocatedRuntimeIdentity() throws {
        let adapters = SurfaceContextAdapters(clock: fixedClock)
        let inputs = self.inputs(for: .source, scopeKey: "https://example.com/feed.xml")

        XCTAssertThrowsError(try adapters.context(.source, inputs: inputs)) { error in
            XCTAssertEqual(error as? FeedSurfacePlanError, .runtimeIdentityUnavailable(.source))
        }

        let sourceID = try FeedDomain.SourceID(9)
        let context = try adapters.context(.source, inputs: inputs, runtimeSourceID: sourceID)
        XCTAssertEqual(context.plan.historyPolicy.scope, .source(sourceID))
        XCTAssertFalse(context.plan.historyPolicy.applySeen, "a source keeps its complete history")
    }

    /// Catalogue browse composes no cards, so it has no plan. It is the source-search surface, and
    /// the row says it is a local catalogue query: no plan, no history scope, no network.
    func testCatalogueBrowseHasNoEditorialPlan() {
        let row = FeedSurfaceCatalog.plan(for: .catalogueBrowse)
        XCTAssertNil(row.contextSurface)
        XCTAssertEqual(row.acquisitions, [.localCatalogueQuery])
        XCTAssertEqual(row.owner, "SQLiteCatalogRepository")
    }

    // MARK: - The Main Feed's context is the runtime's context

    func testMainFeedContextKeyIsTheResolvedContextSerialized() {
        let loader = FeedLoader(store: .empty())
        let adapters = SurfaceContextAdapters(editionSeed: 1_000, clock: fixedClock)

        let key = MainFeedPresentation.contextKey(for: loader, contexts: adapters)

        XCTAssertEqual(key, adapters.mainFeed(loader: loader).contextKeyText)
        XCTAssertEqual(adapters.mainFeed(loader: loader).contextKey.surface, .main)
        XCTAssertTrue(key.contains("preset=everything"), key)
        XCTAssertTrue(key.contains("box=-"), key)
    }

    /// A card seen in Main never removes a card from a surface that preserves navigable history.
    ///
    /// Plan §19 #34 / ADR-007 D12, through the surfaces' own resolved plans: the rule is the resolver's
    /// answer, not a convention this test restates.
    func testMainExposureDoesNotHideTheOtherSurfacesHistory() throws {
        let surviving: [FeedSurface] = [
            .sourceCollection, .bookmarks, .search, .persistentSearch, .lastClicked, .whatsNew, .onboarding,
        ]
        for surface in surviving {
            XCTAssertFalse(
                try FeedSurfaceCatalog.excludes(
                    surface,
                    cardSeenIn: .main,
                    inputs: catalogInputs(for: surface),
                    clock: fixedClock
                ),
                "\(surface.rawValue) must not hide a card because Main showed it"
            )
        }
        XCTAssertTrue(
            try FeedSurfaceCatalog.excludes(
                .main,
                cardSeenIn: .main,
                inputs: catalogInputs(for: .main),
                clock: fixedClock
            ),
            "the Main Feed is the surface that applies seen"
        )
        XCTAssertTrue(
            try FeedSurfaceCatalog.excludes(
                .smartFeed,
                cardSeenIn: .smartFeed(key: "s"),
                inputs: catalogInputs(for: .smartFeed, scopeKey: "s"),
                clock: fixedClock
            ),
            "a smart feed excludes what it already showed"
        )
    }

    // MARK: - The search split (item 2)

    /// Source search is a catalogue query; content search is the canonical FTS — the index whose read
    /// path a launch whose runtime acquires installs (`FeedStore.useCanonicalContentSearch`, from
    /// `MainFeedRuntime.startSession`) — and the online sweep is a separate explicit demand, declared
    /// by exactly one row.
    func testOnlyTheSearchSurfaceDeclaresAnOnlineContentDemand() {
        let search = FeedSurfaceCatalog.plan(for: .search)
        XCTAssertEqual(search.acquisitions, [.localContentSearch, .explicitOnlineContentDemand])

        let declared = FeedSurfaceCatalog.matrix.filter {
            $0.acquisitions.contains(.explicitOnlineContentDemand)
        }
        XCTAssertEqual(declared.map(\.surface), [.search])
        // A saved search matches what has been admitted; it declares no refill of its own, so an
        // online sweep is never smuggled in through a surface that shares the search vocabulary.
        XCTAssertEqual(FeedSurfaceCatalog.plan(for: .persistentSearch).acquisitions, [.localContentSearch])
    }

    /// A local content search with the online demand switched off is not an acquisition: the store
    /// states the demand it was given and issues none — and the index it answered from is the legacy
    /// `feed_item_fts`, because this launch composes no acquiring runtime.
    ///
    /// Scope, stated so the evidence is not read for more than it is: the *content* half of the legacy
    /// search (which rows the legacy index returns) is pinned by `FeedStoreTests`
    /// (`testUnifiedSearchPrioritizesSourcesThenSavedThenOldLocalContent`); what this test adds is that
    /// the search path takes the online demand as an input, that the input's value is what gates it, and
    /// which index the mode reads. The gate's positive direction — demand on *and* persistent storage
    /// *and* the sweep running — is not reachable from an in-memory store, so it is stated here as a
    /// coverage gap rather than implied by a green run: the app suite cannot demonstrate it until
    /// `FeedStore`'s storage is injectable.
    func testLocalContentSearchIssuesNoOnlineDemand() async throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://example.com/legacy.xml"
        store.registry.sources = [Self.exampleSource(url: sourceURL)]
        try await Self.insertLegacyItem(
            into: store,
            id: "legacy-row",
            sourceURL: sourceURL,
            title: "A canonical item admitted before any runtime owned acquisition"
        )

        store.search("canonical", includeSources: false, includeContents: true, demandOnlineContent: false)
        await waitUntilSearchSettles(store)

        XCTAssertEqual(
            store.unifiedSearchResults.localItems.map(\.id),
            ["legacy-row"],
            "a launch that composes no acquiring runtime reads the legacy content index"
        )
        XCTAssertFalse(store.activeSearchDemandsOnlineContent)
        XCTAssertEqual(
            store.sourceDemandCounters.demands,
            0,
            "a local content search must not demand a single endpoint"
        )
        XCTAssertEqual(store.sourcesInFlight, 0, "and it must not leave a claim behind")
    }

    /// The same surface with the demand switched on records it, so the difference between "the reader
    /// asked for live content" and "the local index answered" is a readable fact — and it is a fact
    /// about the demand, not about which index answers it: the local read is the same either way.
    func testContentSearchStatesWhetherItDemandsTheNetwork() async throws {
        let store = try FeedStore(inMemory: true)
        store.search("anything", includeSources: false, includeContents: true, demandOnlineContent: true)
        XCTAssertTrue(store.activeSearchDemandsOnlineContent)
        store.search("anything", includeSources: false, includeContents: true, demandOnlineContent: false)
        XCTAssertFalse(store.activeSearchDemandsOnlineContent)
    }

    /// A launch whose runtime owns acquisition reads the canonical index, and only it.
    ///
    /// The store is given the read path the `v2Full` composition installs
    /// (`MainFeedRuntime.startSession` → `FeedStore.useCanonicalContentSearch`) over a runtime database
    /// holding one admitted record, while the legacy content database holds a row matching the same
    /// term. Exactly one result comes back and it is the canonical one: the index is a decision of the
    /// mode, never "whichever index happens to have rows" and never a union of the two authorities.
    /// The row's shape is the one `AdmissionEngine.refreshSupply` writes — the real write path behind it
    /// is exercised end to end by
    /// `OwnerSwapAcquisitionTests.testTheLocalContentSearchReturnsTheAdmittedCanonicalContent`.
    func testLocalContentSearchReadsTheCanonicalIndexWhenTheRuntimeOwnsAcquisition() async throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://example.com/canonical.xml"
        store.registry.sources = [Self.exampleSource(url: sourceURL)]
        try await Self.insertLegacyItem(
            into: store,
            id: "legacy-row",
            sourceURL: sourceURL,
            title: "A legacy row about telescopes the canonical launch must not return"
        )

        let (database, directory) = try Self.canonicalRuntimeDatabase(
            headline: "Canonical headline about telescopes",
            summary: "The admitted summary",
            link: "https://example.com/article",
            sourceKey: sourceURL,
            sourceTitle: "Canonical Source"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        store.useCanonicalContentSearch(
            CanonicalContentSearch(database: database, registry: store.registry)
        )

        store.search("telescopes", includeSources: false, includeContents: true, demandOnlineContent: false)
        await waitUntilSearchSettles(store)

        let items = store.unifiedSearchResults.localItems
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, "Canonical headline about telescopes")
        XCTAssertEqual(item.excerpt, "The admitted summary")
        XCTAssertEqual(item.url, "https://example.com/article")
        XCTAssertEqual(item.id, CanonicalContentSearch.canonicalItemIDPrefix + "1")
        XCTAssertEqual(item.sourceURL, sourceURL)
        XCTAssertEqual(item.sourceTitle, "Example Source")
        XCTAssertEqual(item.language, "en")
        XCTAssertFalse(
            items.contains { $0.id == "legacy-row" },
            "the legacy index is not a second authority behind the same search"
        )
        XCTAssertFalse(store.activeSearchDemandsOnlineContent)
        XCTAssertEqual(store.sourceDemandCounters.demands, 0)
        XCTAssertEqual(store.sourcesInFlight, 0)
    }

    /// The mode decides the index, not its contents: a launch whose runtime owns acquisition reads the
    /// canonical index even while that index is empty — admission has not landed yet, or failed — and
    /// does not quietly answer from the legacy content database instead.
    ///
    /// This is the deliberate half of the table. A fallback would put two authorities behind one search,
    /// and in this mode the legacy database is not being refreshed at all (the acquisition gate is
    /// closed). The cost is real and named in the report: a `v2Full` reader whose runtime has admitted
    /// nothing gets no local content results, which is the same answer the screen has for its cards.
    func testCanonicalModeDoesNotFallBackToTheLegacyIndex() async throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://example.com/empty.xml"
        store.registry.sources = [Self.exampleSource(url: sourceURL)]
        try await Self.insertLegacyItem(
            into: store,
            id: "legacy-row",
            sourceURL: sourceURL,
            title: "A legacy row about telescopes"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        store.useCanonicalContentSearch(
            CanonicalContentSearch(database: database, registry: store.registry)
        )

        store.search("telescopes", includeSources: false, includeContents: true, demandOnlineContent: false)
        await waitUntilSearchSettles(store)

        XCTAssertTrue(
            store.unifiedSearchResults.localItems.isEmpty,
            "an empty canonical index is the honest answer, not a silent fallback"
        )
        XCTAssertFalse(store.activeSearchDemandsOnlineContent)
        XCTAssertEqual(store.sourceDemandCounters.demands, 0)
    }

    // MARK: - Helpers

    private func inputs(for surface: FeedSurface, scopeKey: String? = nil) -> FeedSurfaceContextInputs {
        let defaults: [FeedSurface: String] = [
            .main: "preset=everything|box=-",
            .source: "https://example.com/feed.xml",
            .sourceCollection: "collection-7",
            .bookmarks: FeedSurfacePlan.allScopesKey,
            .search: "all",
            .smartFeed: "smart-3",
            .persistentSearch: "saved-1",
            .lastClicked: "recent",
            .whatsNew: "since-baseline",
            .onboarding: "showcase",
        ]
        return FeedSurfaceContextInputs(
            scopeKey: scopeKey ?? defaults[surface] ?? "scope",
            planIdentity: "\(surface.rawValue)Plan"
        )
    }

    private func catalogInputs(for surface: FeedSurface, scopeKey: String? = nil) -> FeedSurfaceCatalog.Inputs {
        let inputs = self.inputs(for: surface, scopeKey: scopeKey)
        return FeedSurfaceCatalog.Inputs(scopeKey: inputs.scopeKey, planIdentity: inputs.planIdentity)
    }

    private func waitUntilSearchSettles(_ store: FeedStore, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while store.isSearchLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Search fixtures

    /// One catalogue source the registry knows, so a result's source filters and metadata resolve.
    private static func exampleSource(url: String) -> FeedSource {
        FeedSource(
            title: "Example Source",
            url: url,
            category: "News",
            region: "global",
            mediaKind: .text,
            language: "en"
        )
    }

    /// One legacy content row, in the shape `SearchEngine`'s legacy read hydrates.
    private static func insertLegacyItem(
        into store: FeedStore,
        id: String,
        sourceURL: String,
        title: String
    ) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try await store.db.write { db in
            try db.execute(sql: """
                INSERT INTO feed_item
                    (id, source_url, source_title, region, category, title, excerpt, url,
                     published_at, fetched_at, is_read, language)
                VALUES (?, ?, 'Example Source', 'global', 'News', ?,
                        'an excerpt the legacy index searched', 'https://example.com/article',
                        ?, ?, 0, 'en')
                """, arguments: [id, sourceURL, title, now, now])
        }
    }

    /// A real runtime database with one admitted record, written in the shape Admission writes: the
    /// current revision's `search_projection` is the index row, its payload is what a result renders
    /// from, and the source it is a member of carries the catalogue key the app resolves a source by.
    private static func canonicalRuntimeDatabase(
        headline: String,
        summary: String,
        link: String,
        sourceKey: String,
        sourceTitle: String
    ) throws -> (database: RuntimeDatabase, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-search-\(UUID().uuidString)", isDirectory: true)
        let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let projection = [headline, summary].joined(separator: "\n")
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO external_identity
                    (id, connector_namespace, scope_key, key_kind, external_key, key_digest,
                     first_observed_at, last_observed_at)
                VALUES (1, 'connector.test', 'scope', 'object', x'01', x'02', ?, ?)
                """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO origin_record
                    (id, connector_namespace, scope_key, primary_identity_id,
                     first_observed_at, last_observed_at)
                VALUES (1, 'connector.test', 'scope', 1, ?, ?)
                """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO origin_revision
                    (id, origin_record_id, payload_digest, headline, summary, primary_link,
                     authored_at, observed_at, search_projection, created_at)
                VALUES (1, 1, x'03', ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [headline, summary, link, now, now, projection, now])
            try db.execute(sql: "UPDATE origin_record SET current_revision_id = 1 WHERE id = 1")
            try db.execute(sql: """
                INSERT INTO source
                    (id, editorial_key, canonicalization_version, display_title, created_at)
                VALUES (1, ?, 1, ?, ?)
                """, arguments: [sourceKey, sourceTitle, now])
            try db.execute(sql: """
                INSERT INTO source_membership
                    (origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at)
                VALUES (1, 1, 'editorial', ?, ?)
                """, arguments: [now, now])
            try db.execute(
                sql: "INSERT INTO origin_search (rowid, projection) VALUES (1, ?)",
                arguments: [projection]
            )
        }
        return (database, directory)
    }
}

/// A clock a test states, so a resolved plan is reproducible.
struct FixedSurfaceClock: EditorialClock {
    let milliseconds: Int64
    var now: Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}
