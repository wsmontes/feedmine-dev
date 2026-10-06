import XCTest
import GRDB
import OSLog
import UIKit
@testable import feedmine

// MARK: - Wait instrumentation
//
// Lives here rather than in Support/TestHelpers.swift: that file is not a member of the
// feedmineTests target (it is absent from project.pbxproj, and nothing referenced its symbols, so it
// never failed a build). These two are used by other test files, which resolve them module-wide.

private let waitLog = Logger(subsystem: "com.feedmine.tests", category: "Wait")

/// Records how long a wait in a test actually took, and flags a slow one as a stall.
///
/// Test waits are bounded generously so a stalled process cannot fail an assertion that is about to
/// become true — but a generous deadline would also hide a *cold path* that genuinely took seconds.
/// So every widened wait reports its duration, and anything past `stallThreshold` is logged as a
/// stall to carry into the cold-path record instead of passing silently. This suite has logged an
/// 18.6 s one (run 1: 21:46:00.244 → 21:46:18.911, immediately before the app's own
/// "progressiveFetch starting: 200 filtered/diverse sources").
@MainActor
func recordWait(_ label: String, since start: CFAbsoluteTime, stallThreshold: TimeInterval = 2) {
    let waited = CFAbsoluteTimeGetCurrent() - start
    let rendered = String(format: "%.3f", waited)
    waitLog.info("WAIT \(label) — \(rendered)s")
    if waited > stallThreshold {
        waitLog.warning("WAIT STALL \(label) — \(rendered)s — too slow to be load; keep this window in the cold-path record")
    }
}

/// Wait for the async filter reload to publish a page — the condition the seeding helpers in
/// `FeedComposerPreviewTests`, `FeedLoaderCacheTests` and `FeedPreviewPipelineTests` assert on.
/// A condition with a bounded deadline, not a duration; the measured duration is recorded by
/// `recordWait`, and the caller asserts the exact page afterwards.
@MainActor
@discardableResult
func awaitPagePublication(
    of store: FeedStore,
    label: String,
    deadlineSeconds: TimeInterval = 30,
    stallThreshold: TimeInterval = 2
) async -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    let deadline = Date().addingTimeInterval(deadlineSeconds)
    while store.visibleItems.isEmpty, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    recordWait("\(label) page publication (seeding)", since: start, stallThreshold: stallThreshold)
    return CFAbsoluteTimeGetCurrent() - start
}

/// The process-wide state every suite must normalize before it builds a `FeedStore`.
///
/// A new `FeedStore` reads its whole baseline from UserDefaults-backed `Settings` plus the shared taxonomy, so both
/// have to be reset or one suite's filter/taxonomy state (and any of its tasks still in flight) decides whether the
/// next suite's reload can even load its items — the failing leg then reads `loaded=0 … taxonomyURLs=N`. Measured on
/// this tree: `FeedLoaderCacheTests.testFilteredDateSectionsPreserveProviderOrderAcrossDates` inherited a taxonomy
/// selection, its reload excluded its own 4 items, and `awaitPagePublication`'s 30 s deadline expired — 5 assertion
/// failures in two of three gate runs (gate 2 today, 35.7 s; gate 3, 36.7 s) for a suite that never selects a
/// taxonomy node. Same list as `resetFiltersForUITestLaunch()` in the app.
///
/// This lives in `FeedStoreTests.swift` rather than `Support/TestHelpers.swift` because the latter is not a member of
/// the committed test target (see the project-file gap in `docs/release/HANDOFF.md`).
@MainActor
func normalizeSharedFilterStateForTests() {
    Settings.activePreset = .everything
    Settings.filterRegion = nil
    Settings.filterTaxonomyNodes = []
    Settings.filterContentType = FeedLoader.ContentType.all.rawValue
    Settings.filterLanguages = []
    Settings.filterMood = FeedLoader.MoodFilter.all.rawValue
    Settings.filterSetAt = 0
    Settings.hasInitializedLanguageDefault = true
    TaxonomyStore.shared.clearSelection()
}

@MainActor
final class FeedStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        normalizeSharedFilterStateForTests()
    }

    override func tearDown() async throws {
        // Reset TaxonomyStore singleton between tests to avoid state leakage
        TaxonomyStore.shared.clearSelection()
        try await super.tearDown()
    }

    /// Poll `condition` until it holds, or `timeout` elapses. The waits in this file gate
    /// assertions on state an async write produces (a SQLite flush, a persisted seen/click
    /// timestamp); polling the readiness signal is what holds under full-suite load, where a
    /// fixed 50ms does not. Returns whether the condition held.
    private func waitUntil(
        timeout: TimeInterval = 30,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                recordWait("\(self.name) persistence condition (timed out)", since: start)
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) persistence condition", since: start)
        return true
    }

    func testStartupProgressCountsOnlyDistinctSuccessfulSources() throws {
        let store = try FeedStore(inMemory: true)
        store.configureStartupProgress(targetSourceCount: 3)

        let failedSource = FeedSource(
            title: "Unavailable",
            url: "https://example.com/failed",
            category: "News",
            region: "global"
        )
        store.recordStartupFetchProgress(
            FeedFetchResult(source: failedSource, items: [], outcome: .failed(NSError(domain: "test", code: 0)))
        )

        for index in 0..<3 {
            let source = FeedSource(
                title: "Source \(index)",
                url: "https://example.com/feed-\(index)",
                category: "News",
                region: "global"
            )
            store.recordStartupFetchProgress(
                FeedFetchResult(source: source, items: [], outcome: .notModified)
            )
            if index == 0 {
                store.recordStartupFetchProgress(
                    FeedFetchResult(source: source, items: [], outcome: .notModified)
                )
            }
        }

        XCTAssertEqual(store.startupFetchedSourceCount, 3)
        XCTAssertEqual(store.startupRecentSourceNames, ["Source 0", "Source 1", "Source 2"])
        XCTAssertTrue(store.startupRunwayReady)
    }

    func testRegistryCacheKeepsFirstEquivalentSourceURL() {
        let registry = SourceRegistry()
        registry.sources = [
            FeedSource(
                title: "Canonical",
                url: "https://example.com/feed",
                category: "News",
                region: "global"
            ),
            FeedSource(
                title: "Equivalent",
                url: "http://www.example.com/feed/",
                category: "News",
                region: "global"
            ),
        ]

        XCTAssertTrue(registry.isSourceEnabled("https://example.com/feed"))
        XCTAssertTrue(registry.isSourceEnabled("http://www.example.com/feed/"))
    }

    func testV7MigrationAddsLanguageColumn() throws {
        let store = try FeedStore(inMemory: true)
        try store.db.write { db in
            // Verify column exists by inserting a row with language
            try db.execute(sql: """
                INSERT INTO feed_item (id, source_url, source_title, region, category,
                                       title, excerpt, url, published_at, fetched_at, language)
                VALUES ('test-id', 'https://example.com/feed', 'Test', 'global', 'News',
                        'Title', 'Excerpt', 'https://example.com', 0, 0, 'en')
            """)
            let lang: String? = try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = 'test-id'")
            XCTAssertEqual(lang, "en")
        }
    }

    func testExistingItemWithoutImageIsRepairedOnRefetch() async throws {
        let store = try FeedStore(inMemory: true)
        let original = FeedItem(
            id: "repair-image",
            sourceTitle: "Feed",
            sourceURL: "https://example.com/feed",
            category: "News",
            title: "Item",
            excerpt: "Excerpt",
            url: "https://example.com/item",
            imageURL: nil,
            publishedAt: Date(),
            region: "global"
        )
        _ = await store.persistFetchedItems([original])

        let repaired = FeedItem(
            id: original.id,
            sourceTitle: original.sourceTitle,
            sourceURL: original.sourceURL,
            category: original.category,
            title: original.title,
            excerpt: original.excerpt,
            url: original.url,
            imageURL: "https://cdn.example.com/image.jpg",
            publishedAt: original.publishedAt,
            region: original.region
        )
        _ = await store.persistFetchedItems([repaired])

        let storedImage: String? = try await store.db.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT image_url FROM feed_item WHERE id = ?",
                arguments: [original.id]
            )
        }
        XCTAssertEqual(storedImage, repaired.imageURL)
    }

    /// An Atom entry refresh rewrites the stored row through `FeedItemRecord.update`,
    /// which writes every column. The reader's own state — read, opened, clicked,
    /// consumed — must survive that rewrite: before the fix the record's initializer
    /// defaults (`isRead = false`, nil stamps) were persisted and the item un-read
    /// itself on the next fetch.
    func testAtomEntryRefreshPreservesReaderState() async throws {
        let store = try FeedStore(inMemory: true)
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let original = FeedItem(
            id: "refresh-reader-state",
            sourceTitle: "Feed",
            sourceURL: "https://example.com/feed",
            category: "News",
            title: "Item",
            excerpt: "Excerpt",
            url: "https://example.com/item",
            imageURL: nil,
            publishedAt: published,
            region: "global"
        )
        _ = await store.persistFetchedItems([original])

        store.markAsRead(original.id)
        let readPersisted = await waitUntil {
            let isRead: Int? = try? await store.db.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT is_read FROM feed_item WHERE id = ?",
                    arguments: [original.id]
                )
            }
            return isRead == 1
        }
        XCTAssertTrue(readPersisted, "markAsRead must persist is_read before the refresh")

        // Same id with a newer Atom revision: the update-by-ID path.
        let refreshed = FeedItem(
            id: original.id,
            sourceTitle: original.sourceTitle,
            sourceURL: original.sourceURL,
            category: original.category,
            title: "Item (revised)",
            excerpt: original.excerpt,
            url: original.url,
            imageURL: nil,
            publishedAt: published,
            region: original.region,
            updatedAt: published.addingTimeInterval(3600)
        )
        _ = await store.persistFetchedItems([refreshed])

        let storedRead: Int? = try await store.db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT is_read FROM feed_item WHERE id = ?",
                arguments: [original.id]
            )
        }
        let storedConsumed: Int? = try await store.db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT consumed_at FROM feed_item WHERE id = ?",
                arguments: [original.id]
            )
        }
        let storedTitle: String? = try await store.db.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT title FROM feed_item WHERE id = ?",
                arguments: [original.id]
            )
        }

        XCTAssertEqual(storedRead, 1, "an Atom refresh must not un-read the item")
        XCTAssertNotNil(storedConsumed, "an Atom refresh must keep the consume stamp")
        XCTAssertEqual(storedTitle, "Item (revised)", "the refresh must still update the content")
    }

    /// P-01: a store that cannot be opened must be *visible* as such. The in-memory fallback
    /// keeps the loader constructible, and `persistenceUnavailable` is what `start()` and the
    /// screen branch on — if the failure were swallowed again, the app would draw an empty
    /// feed over data that still exists on disk and accept writes it discards at exit.
    func testPersistentStoreFailureIsVisibleRatherThanSwallowed() async {
        struct StoreFailure: Error {}
        let loader = FeedLoader(storeFactory: { throw StoreFailure() })

        XCTAssertNotNil(loader.initError, "the failure must be captured, not swallowed")
        XCTAssertTrue(loader.persistenceUnavailable, "start() and the screen branch on this")

        // The guard itself is a plain branch; this asserts the observable half — the loader
        // still answers after a refused start instead of publishing a fallback session.
        await loader.start()
        XCTAssertEqual(loader.sourceCount, 0, "a refused start must not load a source registry")
    }

    func testFeedItemRecordDecodesPersistedHTMLEntitiesWhenHydrating() {
        let record = FeedItemRecord(
            from: FeedItem(
                id: "entity-item",
                sourceTitle: "Example &amp; Co",
                sourceURL: "https://example.com/feed",
                category: "News",
                title: "That&#8217;s &quot;news&quot;",
                excerpt: "&lt;p&gt;A useful &amp; readable summary&#8217;s here.&lt;/p&gt;",
                url: "https://example.com/1",
                imageURL: nil,
                publishedAt: Date(),
                language: "en"
            ),
            region: "global",
            language: "en"
        )

        let item = record.toFeedItem()

        XCTAssertEqual(item.sourceTitle, "Example & Co")
        XCTAssertEqual(item.title, "That\u{2019}s \"news\"")
        XCTAssertEqual(item.excerpt, "A useful & readable summary\u{2019}s here.")
    }

    func testReloadFromSQLiteFiltersByTaxonomySourceURL() async throws {
        let store = try FeedStore(inMemory: true)

        // Seed sources and taxonomy
        let source = FeedSource(title: "Coffee Blog", url: "https://coffee.com/feed",
                                category: "Coffee", region: "global")
        store.registry.sources = [source]
        await TaxonomyStore.shared.build(from: [source])

        // Find the taxonomy node for our source
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://coffee.com/feed"))

        // Insert test items before triggering reload:
        // one item matching the taxonomy node, one that does not
        let matchingItem = FeedItemRecord(
            from: FeedItem(id: "match", sourceTitle: "S", sourceURL: "https://coffee.com/feed",
                           category: "Coffee", title: "Match", excerpt: "E",
                           url: "https://coffee.com/1", imageURL: nil, publishedAt: Date(),
                           audioURL: nil, duration: nil, region: "global"),
            region: "global"
        )
        let nonMatchingItem = FeedItemRecord(
            from: FeedItem(id: "nomatch", sourceTitle: "S", sourceURL: "https://other.com/feed",
                           category: "Other", title: "No Match", excerpt: "E",
                           url: "https://other.com/1", imageURL: nil, publishedAt: Date(),
                           audioURL: nil, duration: nil, region: "global"),
            region: "global"
        )
        try await store.db.write { db in
            try matchingItem.insert(db)
            try nonMatchingItem.insert(db)
        }

        // Trigger reload via setFilter — this computes cachedTaxonomyFeedURLs
        // internally and then flushes the pipeline after a 300ms debounce.
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        // Poll for result with timeout instead of a fixed sleep (avoids CI flakiness).
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)

        // Verify only matching item appears
        XCTAssertEqual(store.visibleItems.count, 1)
        XCTAssertEqual(store.visibleItems.first?.sourceURL, "https://coffee.com/feed")
    }

    // MARK: - Language Filter (shared rule)

    func testLanguageFilterNilBlockedEvenWhenDeviceLanguageSelected() {
        // Unknown language must not pass an active language filter. Falling
        // back to the device language lets unrelated video sources leak in.
        let result = FeedStore.languageFilterMatches(
            itemLanguage: nil,
            selectedLanguages: ["en", "pt"],
            deviceLanguage: "en"
        )
        XCTAssertFalse(result, "nil-language item must not pass an active language filter")
    }

    func testLanguageFilterNilBlockedWhenDeviceLanguageNotSelected() {
        // nil language + Japanese selected + device = English → block
        let result = FeedStore.languageFilterMatches(
            itemLanguage: nil,
            selectedLanguages: ["ja"],
            deviceLanguage: "en"
        )
        XCTAssertFalse(result, "nil-language item must not pass when device language (en) is NOT among selected (ja)")
    }

    func testLanguageFilterKnownLanguagePasses() {
        // ja + Japanese selected → pass
        let result = FeedStore.languageFilterMatches(
            itemLanguage: "ja",
            selectedLanguages: ["ja"],
            deviceLanguage: "en"
        )
        XCTAssertTrue(result)
    }

    func testLanguageFilterKnownLanguageBlocked() {
        // en + Japanese selected → block
        let result = FeedStore.languageFilterMatches(
            itemLanguage: "en",
            selectedLanguages: ["ja"],
            deviceLanguage: "pt"
        )
        XCTAssertFalse(result)
    }

    func testLanguageFilterEmptySelectionPassesAll() {
        // No selection → all pass (nil, known, any device language)
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: nil, selectedLanguages: [], deviceLanguage: "en"))
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: "ja", selectedLanguages: [], deviceLanguage: "en"))
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: "pt", selectedLanguages: [], deviceLanguage: nil))
    }

    // MARK: - Language persistence: memory ↔ SQLite consistency

    func testPersistDetectedLanguageReturnsEnrichedItem() async throws {
        let store = try FeedStore(inMemory: true)

        // Register a source WITHOUT explicit language — detection must fill it
        let source = FeedSource(title: "Asahi Shimbun", url: "https://asahi.com/feed",
                                category: "News", region: "countries/japan", language: nil)
        store.registry.sources = [source]

        // Item with clearly Japanese title/excerpt, no language from the source
        let item = FeedItem(
            id: "ja-item-1", sourceTitle: "Asahi Shimbun",
            sourceURL: "https://asahi.com/feed",
            category: "News",
            title: "日本の首相が記者会見を開き新たな経済政策を発表しました",
            excerpt: "本日午前、首相官邸で記者会見が行われ、新しい経済政策について詳細が明らかになりました。",
            url: "https://asahi.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/japan",
            language: nil  // explicitly nil — detection must fill this
        )

        let result = await store.persistFetchedItems([item])

        // 1. The returned item must carry the detected language
        let returned: FeedItem = try XCTUnwrap(result.first)
        XCTAssertEqual(returned.language, "ja",
                       "persistFetchedItems must return an enriched FeedItem with detected language")

        // 2. The SQLite record must also have the same language
        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "ja",
                       "SQLite record must contain the same detected language as the returned item")

        // 3. Both representations produce identical results in the language filter
        let japaneseSelected: Set<String> = ["ja"]
        let englishDevice = "en"
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: returned.language, selectedLanguages: japaneseSelected, deviceLanguage: englishDevice),
                      "Enriched item (ja) must pass Japanese filter")
        XCTAssertTrue(FeedStore.languageFilterMatches(itemLanguage: dbLanguage, selectedLanguages: japaneseSelected, deviceLanguage: englishDevice),
                      "DB record (ja) must pass Japanese filter")

        // 4. Both reject English-only selection
        let englishSelected: Set<String> = ["en"]
        XCTAssertFalse(FeedStore.languageFilterMatches(itemLanguage: returned.language, selectedLanguages: englishSelected, deviceLanguage: englishDevice),
                       "Enriched item (ja) must NOT pass English filter")
        XCTAssertFalse(FeedStore.languageFilterMatches(itemLanguage: dbLanguage, selectedLanguages: englishSelected, deviceLanguage: englishDevice),
                       "DB record (ja) must NOT pass English filter")
    }

    func testPersistKhmerScriptOverridesIncorrectEnglishSourceMetadata() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(
            title: "Kim Sav Phearith Official",
            url: "https://youtube.com/feeds/videos.xml?channel_id=khmer",
            category: "Videos",
            region: "global",
            mediaKind: .video,
            language: "en"
        )
        store.registry.sources = [source]
        let item = FeedItem(
            id: "khmer-video-1",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "ខ្មោចម្តាយដើម ដោយនំកូនតោ",
            excerpt: "Horror movie from Karuna Team",
            url: "https://youtube.com/watch?v=khmer-video-1",
            imageURL: nil,
            publishedAt: .now,
            region: source.region,
            language: "en"
        )

        let results = await store.persistFetchedItems([item])
        let persisted = try XCTUnwrap(results.first)
        XCTAssertEqual(persisted.language, "km")
        XCTAssertFalse(
            FeedStore.languageFilterMatches(
                itemLanguage: persisted.language,
                selectedLanguages: ["en"],
                deviceLanguage: "en"
            ),
            "Khmer content must not pass an English-only filter"
        )
    }

    func testPersistPreservesItemLanguageOverDetection() async throws {
        let store = try FeedStore(inMemory: true)

        // Source has NO explicit language — detection would be needed
        let source = FeedSource(title: "Le Monde", url: "https://lemonde.fr/feed",
                                category: "News", region: "countries/france", language: nil)
        store.registry.sources = [source]

        // But the item itself already carries "fr" (set by the fetcher).
        // Short, ambiguous text that could mislead detection.
        let item = FeedItem(
            id: "fr-item-1", sourceTitle: "Le Monde",
            sourceURL: "https://lemonde.fr/feed",
            category: "News",
            title: "Édito",
            excerpt: "Bref.",
            url: "https://lemonde.fr/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/france",
            language: "fr"  // already known — must not be overwritten
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        // The item's own language must survive, even with no registry language
        // and text too short for reliable detection
        XCTAssertEqual(returned.language, "fr",
                       "Item's own language 'fr' must be preserved when registry has none and text is short")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "fr",
                       "SQLite must also store the item's own language")
    }

    func testEmptyItemLanguageFallsBackToRegistryLanguage() async throws {
        let store = try FeedStore(inMemory: true)

        // Source has explicit "pt" language in the registry
        let source = FeedSource(title: "Folha", url: "https://folha.com/feed",
                                category: "News", region: "countries/brazil", language: "pt")
        store.registry.sources = [source]

        // Item has empty string for language — must fall back to registry "pt"
        let item = FeedItem(
            id: "empty-lang-1", sourceTitle: "Folha",
            sourceURL: "https://folha.com/feed",
            category: "News",
            title: "Breve",
            excerpt: "Nota.",
            url: "https://folha.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/brazil",
            language: ""  // empty — should fall through to registry
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        XCTAssertEqual(returned.language, "pt",
                       "Empty item.language must fall back to registry language 'pt'")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "pt",
                       "SQLite must store the registry language when item.language is empty")
    }

    func testWhitespaceItemLanguageFallsBackToRegistryLanguage() async throws {
        let store = try FeedStore(inMemory: true)

        let source = FeedSource(title: "Asahi", url: "https://asahi.com/feed",
                                category: "News", region: "countries/japan", language: "ja")
        store.registry.sources = [source]

        let item = FeedItem(
            id: "ws-lang-1", sourceTitle: "Asahi",
            sourceURL: "https://asahi.com/feed",
            category: "News",
            title: "短い",
            excerpt: "記事。",
            url: "https://asahi.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/japan",
            language: "   "  // whitespace-only — should fall through to registry
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        XCTAssertEqual(returned.language, "ja",
                       "Whitespace-only item.language must fall back to registry language 'ja'")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "ja",
                       "SQLite must store the registry language when item.language is whitespace")
    }

    func testPersistExplicitSourceLanguagePreserved() async throws {
        let store = try FeedStore(inMemory: true)

        // Register a source WITH explicit Portuguese language
        let source = FeedSource(title: "Folha", url: "https://folha.com/feed",
                                category: "News", region: "countries/brazil", language: "pt")
        store.registry.sources = [source]

        // Item where the text might be detected as something else, but the
        // explicit source language must win
        let item = FeedItem(
            id: "pt-item-1", sourceTitle: "Folha",
            sourceURL: "https://folha.com/feed",
            category: "News",
            title: "Governo anuncia novas medidas econômicas para o segundo semestre",
            excerpt: "O ministro da Fazenda apresentou hoje as projeções atualizadas para o PIB.",
            url: "https://folha.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/brazil",
            language: nil
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        // Explicit source language "pt" must be preserved — not overwritten by
        // text detection (which might also return "pt", but the point is the
        // source language takes priority)
        XCTAssertEqual(returned.language, "pt",
                       "Explicit source language 'pt' must be preserved in enriched item")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "pt",
                       "SQLite must also store the explicit source language")
    }

    // MARK: - Language code normalization (BCP 47 → ISO 639-1)

    func testNormalizedLanguageCodeExtractsBaseCode() {
        XCTAssertEqual(FeedStore.normalizedLanguageCode("pt-BR"), "pt")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("pt_BR"), "pt")
        XCTAssertEqual(FeedStore.normalizedLanguageCode(" EN-us "), "en")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("zh-Hant"), "zh")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("fr-CA"), "fr")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("es-MX"), "es")
        XCTAssertNil(FeedStore.normalizedLanguageCode(""))
        XCTAssertNil(FeedStore.normalizedLanguageCode("   "))
        XCTAssertNil(FeedStore.normalizedLanguageCode(nil))
        // Already-clean codes pass through unchanged
        XCTAssertEqual(FeedStore.normalizedLanguageCode("pt"), "pt")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("ja"), "ja")
    }

    func testBCP47ItemMatchesBaseCodeFilter() {
        // pt-BR vs pt → must match
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "pt-BR", selectedLanguages: ["pt"], deviceLanguage: "en"))
        // en-US vs en → must match
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "en-US", selectedLanguages: ["en"], deviceLanguage: "pt"))
        // fr-CA vs fr → must match
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "fr-CA", selectedLanguages: ["fr"], deviceLanguage: "en"))
    }

    func testBCP47ItemBlockedByDifferentBaseCodeFilter() {
        // pt-BR vs en → must NOT match
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: "pt-BR", selectedLanguages: ["en"], deviceLanguage: "en"))
        // en-US vs ja → must NOT match
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: "en-US", selectedLanguages: ["ja"], deviceLanguage: "en"))
    }

    func testBCP47PersistedAsBaseCode() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(title: "Test", url: "https://test.com/feed",
                                category: "News", region: "countries/brazil", language: "pt-BR")
        store.registry.sources = [source]

        let item = FeedItem(
            id: "bcp47-1", sourceTitle: "Test",
            sourceURL: "https://test.com/feed",
            category: "News",
            title: "Título em português do Brasil",
            excerpt: "Conteúdo do artigo com texto suficiente para detecção confiável de idioma.",
            url: "https://test.com/article/1", imageURL: nil,
            publishedAt: Date(),
            region: "countries/brazil",
            language: "pt-BR"  // BCP 47 — must be stored as "pt"
        )

        let result = await store.persistFetchedItems([item])
        let returned: FeedItem = try XCTUnwrap(result.first)

        XCTAssertEqual(returned.language, "pt",
                       "BCP 47 'pt-BR' must be normalized to 'pt' in returned item")

        let dbLanguage: String? = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT language FROM feed_item WHERE id = ?", arguments: [item.id])
        }
        XCTAssertEqual(dbLanguage, "pt",
                       "BCP 47 'pt-BR' must be stored as 'pt' in SQLite")
    }

    // MARK: - BCP 47 normalization in selectedLanguages + deviceLanguage

    func testBCP47SelectedLanguagesNormalizedDefensively() {
        // item = "pt", selected = ["pt-BR"] → must match because both normalize to "pt"
        XCTAssertTrue(FeedStore.languageFilterMatches(
            itemLanguage: "pt",
            selectedLanguages: ["pt-BR"],
            deviceLanguage: "en-US"
        ))
    }

    func testBCP47DeviceLanguageDoesNotRescueUnknownItemLanguage() {
        // Device language is normalized defensively, but unknown item language
        // still cannot satisfy an active language filter.
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: nil,
            selectedLanguages: ["en"],
            deviceLanguage: "en-GB"
        ))
    }

    func testNormalizedLanguageSetConvergesVariants() {
        let raw = ["pt-BR", "pt", "pt_BR", "en-US", "EN-us", "ja"]
        let normalized = FeedStore.normalizedLanguageSet(raw)
        XCTAssertEqual(normalized, ["pt", "en", "ja"])
    }

    func testLegacyBCP47SettingsNormalizedOnRestore() async throws {
        let store = try FeedStore(inMemory: true)

        // Simulate legacy persisted settings with BCP 47 codes
        UserDefaults.standard.set(["pt-BR", "en-US"], forKey: "filterLanguages")
        UserDefaults.standard.set(true, forKey: "filterAutoExpire")
        // Set a recent timestamp so auto-expire doesn't kick in
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "filterSetAt")
        // Persist neutral values for other filters
        UserDefaults.standard.set(nil, forKey: "filterRegion")
        UserDefaults.standard.set([], forKey: "filterTaxonomyNodes")
        UserDefaults.standard.set("All", forKey: "filterContentType")
        UserDefaults.standard.set("all", forKey: "filterMood")

        // Call restoreFilters directly — this is the actual code path that
        // reads legacy settings and populates activeLanguages
        store.restoreFilters()

        // activeLanguages must contain normalized base codes, not raw BCP 47
        XCTAssertEqual(store.activeLanguages, ["en", "pt"],
                       "restoreFilters must normalize legacy BCP 47 settings to ISO 639-1 base codes")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "filterLanguages")
        UserDefaults.standard.removeObject(forKey: "filterAutoExpire")
        UserDefaults.standard.removeObject(forKey: "filterSetAt")
        UserDefaults.standard.removeObject(forKey: "filterRegion")
        UserDefaults.standard.removeObject(forKey: "filterTaxonomyNodes")
        UserDefaults.standard.removeObject(forKey: "filterContentType")
        UserDefaults.standard.removeObject(forKey: "filterMood")
    }

    func testSetFilterNormalizesLanguagesOnEntry() async throws {
        let store = try FeedStore(inMemory: true)

        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["pt-BR", "en-US"])

        XCTAssertEqual(store.activeLanguages, ["en", "pt"],
                       "setFilter must normalize BCP 47 codes to base codes")
    }

    // MARK: - Taxonomy eligibility (category/region bypass)

    func testSourceExplicitlyDisabledFlag() {
        let registry = SourceRegistry()
        registry.sources = [
            FeedSource(title: "A", url: "https://a.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "B", url: "https://b.com/feed", category: "Acoustics", region: "global"),
        ]
        // Disable source A individually
        registry.toggleSource("https://a.com/feed")

        XCTAssertTrue(registry.isSourceExplicitlyDisabled("https://a.com/feed"))
        XCTAssertFalse(registry.isSourceExplicitlyDisabled("https://b.com/feed"))
    }

    func testSourceKeyNormalizesURLVariants() {
        // Trailing slash, http vs https, and www. must all map to the same key
        let registry = SourceRegistry()
        registry.sources = [
            FeedSource(title: "A", url: "https://example.com/feed", category: "X", region: "global"),
        ]
        // Disable with trailing slash
        registry.toggleSource("https://example.com/feed/")
        // Check without trailing slash — must still be recognized as disabled
        XCTAssertTrue(registry.isSourceExplicitlyDisabled("https://example.com/feed"),
                      "Trailing-slash variant must match normalized key")
        // Check http variant
        XCTAssertTrue(registry.isSourceExplicitlyDisabled("http://example.com/feed"),
                      "http→https upgrade must converge on same key")
        // Check www variant
        XCTAssertTrue(registry.isSourceExplicitlyDisabled("http://www.example.com/feed"),
                      "www. stripping must converge on same key")
    }

    func testTaxonomySelectionMakesDisabledCategorySourcesEligible() async throws {
        let store = try FeedStore(inMemory: true)

        // Four sources in Acoustics, category disabled
        let sources = [
            FeedSource(title: "Sound1", url: "https://sound1.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "Sound2", url: "https://sound2.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "Sound3", url: "https://sound3.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "Sound4", url: "https://sound4.com/feed", category: "Acoustics", region: "global"),
        ]
        store.registry.sources = sources
        store.registry.toggleCategory("Acoustics")  // disable entire category

        // Normally none are enabled
        XCTAssertFalse(store.registry.isSourceEnabled("https://sound1.com/feed"))
        XCTAssertFalse(store.registry.isSourceEnabled("https://sound2.com/feed"))

        // Build taxonomy tree
        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://sound1.com/feed"))
        let taxonomyURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(taxonomyURLs.count, 4)

        // Set taxonomy filter (simulates selecting Acoustics node)
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        // Settle signal, not a sampled duration: the assertions below read state the flush
        // writes, so wait for the pipeline to reach idle and then assert that it did — a
        // timeout here used to be silent and surfaced later as a confusing content mismatch.
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) pipeline settle", since: waitStart)
        XCTAssertEqual(store.loadingState, .idle,
                       "the feed pipeline must settle (loadingState == .idle) within 30s of the filter change")

        // All four should now be visible as eligible (category bypassed, none individually disabled)
        // Insert test items for these sources and verify they pass the REAL applyFilters
        let items = sources.map { src in
            FeedItem(id: FeedItem.generateID(sourceURL: src.url, guid: src.url, link: nil),
                     sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                     title: "Test Article", excerpt: "Content.",
                     url: src.url + "/article/1", imageURL: nil,
                     publishedAt: Date(), region: "global")
        }
        let persisted = await store.persistFetchedItems(items)
        XCTAssertEqual(persisted.count, 4, "All 4 items should be persisted")

        // This is the real filter pipeline — isSourceEligible, isItemEnabled,
        // cachedTaxonomyFeedURLs, all of it
        let filtered = store.applyFilters(persisted)
        XCTAssertEqual(filtered.count, 4,
                       "applyFilters must keep all 4 taxonomy items when none are individually disabled")
    }

    func testTaxonomySelectionStillBlocksIndividuallyDisabledSource() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "S1", url: "https://s1.com/feed", category: "Acoustics", region: "global"),
            FeedSource(title: "S2", url: "https://s2.com/feed", category: "Acoustics", region: "global"),
        ]
        store.registry.sources = sources
        // Toggle S1 off individually FIRST (category still enabled)
        store.registry.toggleSource("https://s1.com/feed")  // S1 → disabled
        // Then disable the category (S2 now blocked by category, S1 still individually off)
        store.registry.toggleCategory("Acoustics")

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://s1.com/feed"))

        // Select Acoustics node
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        // Settle signal, not a sampled duration: the assertions below read state the flush
        // writes, so wait for the pipeline to reach idle and then assert that it did — a
        // timeout here used to be silent and surfaced later as a confusing content mismatch.
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) pipeline settle", since: waitStart)
        XCTAssertEqual(store.loadingState, .idle,
                       "the feed pipeline must settle (loadingState == .idle) within 30s of the filter change")

        // S1 individually disabled → must be blocked
        // S2 category-disabled but taxonomy overrides → must be eligible
        XCTAssertTrue(store.registry.isSourceExplicitlyDisabled("https://s1.com/feed"),
                      "S1 is individually off")
        XCTAssertFalse(store.registry.isSourceExplicitlyDisabled("https://s2.com/feed"),
                       "S2 is NOT individually off")

        let items = sources.map { src in
            FeedItem(id: FeedItem.generateID(sourceURL: src.url, guid: src.url, link: nil),
                     sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                     title: "Test", excerpt: "Content.",
                     url: src.url + "/a/1", imageURL: nil,
                     publishedAt: Date(), region: "global")
        }
        let persisted = await store.persistFetchedItems(items)

        // This is the real filter — only S2 should survive
        let filtered = store.applyFilters(persisted)
        XCTAssertEqual(filtered.count, 1,
                       "Only S2 (not individually disabled) should pass taxonomy override")
        XCTAssertEqual(filtered.first?.sourceURL, "https://s2.com/feed",
                       "S2 must be the sole survivor")
    }

    func testClearingTaxonomyRestoresNormalEnablement() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "S1", url: "https://s1.com/feed", category: "Acoustics", region: "global"),
        ]
        store.registry.sources = sources
        store.registry.toggleCategory("Acoustics")

        XCTAssertFalse(store.registry.isSourceEnabled("https://s1.com/feed"),
                       "Category disabled → source not enabled")

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://s1.com/feed"))

        // Select taxonomy → temporarily eligible
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        // Settle signal, not a sampled duration: the assertions below read state the flush
        // writes, so wait for the pipeline to reach idle and then assert that it did — a
        // timeout here used to be silent and surfaced later as a confusing content mismatch.
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) pipeline settle", since: waitStart)
        XCTAssertEqual(store.loadingState, .idle,
                       "the feed pipeline must settle (loadingState == .idle) within 30s of the filter change")

        // Clear filters → normal enablement restored
        store.clearAllFilters()
        let clearDeadline = Date().addingTimeInterval(30)
        let waitStart2 = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < clearDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) pipeline settle", since: waitStart2)
        XCTAssertEqual(store.loadingState, .idle,
                       "clearing the filters must settle the pipeline (loadingState == .idle) within 30s")

        // Source should be disabled again (category still off, no taxonomy override)
        XCTAssertFalse(store.registry.isSourceEnabled("https://s1.com/feed"),
                       "After clearing taxonomy, normal category disable must be restored")
    }

    // MARK: - Acoustics real-world diagnostic

    /// Acoustics resolves exactly 4 URLs — the four feeds from general_english.opml.
    func testAcousticsResolvesExactlyFourURLs() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "Acoustical Society of America (ASA)", url: "https://acousticalsociety.org/rss/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics Today (ASA Magazine)", url: "https://acousticstoday.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics.org (Resource)", url: "https://acoustics.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Audio Engineering Society (AES)", url: "https://www.aes.org/rss/", category: "Acoustics", region: "topic/General"),
        ]
        store.registry.sources = sources
        await TaxonomyStore.shared.build(from: sources)

        // Find the Acoustics node
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://acousticstoday.org/feed/"))
        XCTAssertEqual(nodeID, "general/acoustics", "Node ID must be general/acoustics")

        let taxonomyURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(taxonomyURLs.count, 4, "Acoustics must resolve exactly 4 URLs")

        // Verify each URL is normalized correctly in the set
        let normalizedASA = OPMLParser.normalizeURL("https://acousticalsociety.org/rss/")
        let normalizedToday = OPMLParser.normalizeURL("https://acousticstoday.org/feed/")
        let normalizedOrg = OPMLParser.normalizeURL("https://acoustics.org/feed/")
        let normalizedAES = OPMLParser.normalizeURL("https://www.aes.org/rss/")
        XCTAssertTrue(taxonomyURLs.contains(normalizedASA))
        XCTAssertTrue(taxonomyURLs.contains(normalizedToday))
        XCTAssertTrue(taxonomyURLs.contains(normalizedOrg))
        XCTAssertTrue(taxonomyURLs.contains(normalizedAES))

        // Verify AES www→no-www normalization
        XCTAssertEqual(OPMLParser.normalizeURL("https://www.aes.org/rss/"), "https://aes.org/rss")
    }

    /// URL variants of the same source must resolve to the same identity.
    func testAcousticsURLNormalizationVariants() {
        let registry = SourceRegistry()
        registry.sources = [
            FeedSource(title: "AES", url: "https://www.aes.org/rss/", category: "Acoustics", region: "topic/General"),
        ]
        // Trailing slash variant
        XCTAssertEqual(OPMLParser.normalizeURL("https://www.aes.org/rss/"), OPMLParser.normalizeURL("https://www.aes.org/rss"))
        // HTTP variant
        XCTAssertEqual(OPMLParser.normalizeURL("http://www.aes.org/rss/"), "https://aes.org/rss")
        // No www, no trailing slash
        XCTAssertEqual(OPMLParser.normalizeURL("https://aes.org/rss"), "https://aes.org/rss")
        XCTAssertEqual(
            OPMLParser.normalizeURL("https://www.aes.org/rss/?utm_source=mail#latest"),
            "https://aes.org/rss"
        )
    }

    /// Acoustics selected, category disabled, no source individually disabled → 4 eligible.
    func testAcousticsEligibilityAllFourEnabled() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "ASA", url: "https://acousticalsociety.org/rss/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics Today", url: "https://acousticstoday.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics.org", url: "https://acoustics.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "AES", url: "https://www.aes.org/rss/", category: "Acoustics", region: "topic/General"),
        ]
        store.registry.sources = sources
        store.registry.toggleCategory("Acoustics")  // disable entire category

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://acousticstoday.org/feed/"))

        // Select Acoustics
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        // Settle signal, not a sampled duration: the assertions below read state the flush
        // writes, so wait for the pipeline to reach idle and then assert that it did — a
        // timeout here used to be silent and surfaced later as a confusing content mismatch.
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) pipeline settle", since: waitStart)
        XCTAssertEqual(store.loadingState, .idle,
                       "the feed pipeline must settle (loadingState == .idle) within 30s of the filter change")

        // Create test items for all 4 sources
        let items = sources.map { src in
            FeedItem(id: FeedItem.generateID(sourceURL: src.url, guid: src.url, link: nil),
                     sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                     title: "Article from \(src.title)", excerpt: "Content.",
                     url: src.url + "/a/1", imageURL: nil,
                     publishedAt: Date(), region: "topic/General")
        }
        let persisted = await store.persistFetchedItems(items)
        XCTAssertEqual(persisted.count, 4)

        let filtered = store.applyFilters(persisted)
        XCTAssertEqual(filtered.count, 4, "All 4 Acoustics items must pass filters when none individually disabled")
    }

    /// 4 sources, 1 individually disabled, Acoustics selected → 3 eligible.
    func testAcousticsEligibilityWithOneDisabled() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "ASA", url: "https://acousticalsociety.org/rss/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics Today", url: "https://acousticstoday.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics.org", url: "https://acoustics.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "AES", url: "https://www.aes.org/rss/", category: "Acoustics", region: "topic/General"),
        ]
        store.registry.sources = sources
        store.registry.toggleSource("https://acousticalsociety.org/rss/")  // disable ASA

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://acousticstoday.org/feed/"))

        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        // Settle signal, not a sampled duration: the assertions below read state the flush
        // writes, so wait for the pipeline to reach idle and then assert that it did — a
        // timeout here used to be silent and surfaced later as a confusing content mismatch.
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) pipeline settle", since: waitStart)
        XCTAssertEqual(store.loadingState, .idle,
                       "the feed pipeline must settle (loadingState == .idle) within 30s of the filter change")

        let items = sources.map { src in
            FeedItem(id: FeedItem.generateID(sourceURL: src.url, guid: src.url, link: nil),
                     sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                     title: "Test", excerpt: "Content.",
                     url: src.url + "/a/1", imageURL: nil,
                     publishedAt: Date(), region: "topic/General")
        }
        let filtered = store.applyFilters(items)
        XCTAssertEqual(filtered.count, 3, "Only 3 of 4 must pass — ASA is individually disabled")
        XCTAssertFalse(filtered.contains { OPMLParser.normalizeURL($0.sourceURL) == OPMLParser.normalizeURL("https://acousticalsociety.org/rss/") },
                       "ASA must be excluded")
    }

    /// Items from Acoustics URLs in SQLite must be loaded by Acoustics taxonomy selection.
    func testAcousticsSQLiteItemsLoadable() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "ASA", url: "https://acousticalsociety.org/rss/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics Today", url: "https://acousticstoday.org/feed/", category: "Acoustics", region: "topic/General"),
        ]
        store.registry.sources = sources
        await TaxonomyStore.shared.build(from: sources)

        // Insert items into SQLite
        let item1 = FeedItemRecord(from: FeedItem(
            id: "acoustics-1", sourceTitle: "ASA", sourceURL: "https://acousticalsociety.org/rss/",
            category: "Acoustics", title: "ASA Article", excerpt: "Content",
            url: "https://acousticalsociety.org/rss/1", imageURL: nil,
            publishedAt: Date(), region: "topic/General"), region: "topic/General")
        let item2 = FeedItemRecord(from: FeedItem(
            id: "acoustics-2", sourceTitle: "Acoustics Today", sourceURL: "https://acousticstoday.org/feed/",
            category: "Acoustics", title: "Today Article", excerpt: "Content",
            url: "https://acousticstoday.org/feed/1", imageURL: nil,
            publishedAt: Date(), region: "topic/General"), region: "topic/General")
        let nonAcoustics = FeedItemRecord(from: FeedItem(
            id: "other-1", sourceTitle: "Other", sourceURL: "https://other.com/feed",
            category: "Other", title: "Other Article", excerpt: "Content",
            url: "https://other.com/1", imageURL: nil,
            publishedAt: Date(), region: "global"), region: "global")

        try await store.db.write { db in
            try item1.insert(db)
            try item2.insert(db)
            try nonAcoustics.insert(db)
        }

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://acousticalsociety.org/rss/"))
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)

        XCTAssertEqual(store.visibleItems.count, 2, "Should load 2 Acoustics items from SQLite")
        XCTAssertTrue(store.visibleItems.allSatisfy { $0.sourceURL.contains("acoustic") || $0.sourceURL.contains("aes") },
                      "All visible items must be from Acoustics sources")
    }

    /// End-to-end: Acoustics selected → 4 taxonomy URLs → 4 eligible sources → 4 items visible.
    /// Uses the real applyFilters pipeline without any network dependency.
    func testAcousticsEndToEndLocalPipeline() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "ASA", url: "https://acousticalsociety.org/rss/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics Today", url: "https://acousticstoday.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Acoustics.org", url: "https://acoustics.org/feed/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "AES", url: "https://www.aes.org/rss/", category: "Acoustics", region: "topic/General"),
        ]
        store.registry.sources = sources
        store.registry.toggleCategory("Acoustics")  // disable category — taxonomy must bypass

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://acousticstoday.org/feed/"))
        XCTAssertEqual(nodeID, "general/acoustics")

        let taxonomyURLs = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(taxonomyURLs.count, 4, "Step 1: taxonomy URLs = 4")

        // Insert items into SQLite for all 4 sources
        let items = sources.map { src in
            FeedItemRecord(from: FeedItem(
                id: FeedItem.generateID(sourceURL: src.url, guid: UUID().uuidString, link: nil),
                sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                title: "Article from \(src.title)", excerpt: "Test content",
                url: src.url + "/a/\(UUID().uuidString.prefix(8))", imageURL: nil,
                publishedAt: Date(), region: "topic/General"), region: "topic/General")
        }
        try await store.db.write { db in
            for item in items { try item.insert(db) }
        }

        // Apply filter
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)

        // Final assertions
        let eligibleSources = store.registry.sources.filter {
            store.registry.isSourceExplicitlyDisabled($0.url) == false
        }
        XCTAssertEqual(eligibleSources.count, 4, "Step 2: eligible sources = 4")

        XCTAssertEqual(store.visibleItems.count, 4, "Step 3: visibleItems = 4")
        XCTAssertTrue(store.visibleItems.allSatisfy { item in
            sources.contains { OPMLParser.normalizeURL($0.url) == OPMLParser.normalizeURL(item.sourceURL) }
        }, "All visible items must be from Acoustics sources")
    }

    /// Verify generation tracking prevents stale filter results from overwriting fresh ones.
    func testFilterGenerationPreventsStaleOverwrite() async throws {
        let store = try FeedStore(inMemory: true)

        let sources = [
            FeedSource(title: "ASA", url: "https://acousticalsociety.org/rss/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Today", url: "https://acousticstoday.org/feed/", category: "Acoustics", region: "topic/General"),
        ]
        store.registry.sources = sources
        await TaxonomyStore.shared.build(from: sources)

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://acousticstoday.org/feed/"))

        // Insert ASA items into SQLite
        let asaItem = FeedItemRecord(from: FeedItem(
            id: "asa-1", sourceTitle: "ASA", sourceURL: "https://acousticalsociety.org/rss/",
            category: "Acoustics", title: "ASA Article", excerpt: "Content",
            url: "https://acousticalsociety.org/rss/1", imageURL: nil,
            publishedAt: Date(), region: "topic/General"), region: "topic/General")
        try await store.db.write { db in try asaItem.insert(db) }

        // Apply Acoustics filter
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)

        let itemsAfterAcoustics = store.visibleItems.count
        XCTAssertEqual(itemsAfterAcoustics, 1, "Should have 1 ASA item")

        // Clear filters → all items should be visible again (no taxonomy filter)
        // The ASA item from SQLite will appear since clearAllFilters reloads without taxonomy restriction
        store.clearAllFilters()
        let clearDeadline = Date().addingTimeInterval(30)
        let waitStart2 = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < clearDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) pipeline settle", since: waitStart2)
        XCTAssertEqual(store.loadingState, .idle,
                       "clearing the filters must settle the pipeline (loadingState == .idle) within 30s")

        // After clearing filters, the ASA item should still be visible (no taxonomy filter = show all)
        XCTAssertGreaterThan(store.visibleItems.count, 0, "Items should remain visible after clearing filters")
    }

    // MARK: - Single-feed category validation

    func testSingleFeedCategoryResolution() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(title: "Sententiae Antiquae", url: "https://sententiaeantiquae.com/feed/",
                                category: "Greek & Roman Mythology", region: "topic/Arts_Culture")
        store.registry.sources = [source]
        await TaxonomyStore.shared.build(from: [source])

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://sententiaeantiquae.com/feed/"))
        let urls = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(urls.count, 1, "Single-feed category must resolve exactly 1 URL")

        // Insert item and verify filter
        let item = FeedItemRecord(from: FeedItem(
            id: FeedItem.generateID(sourceURL: source.url, guid: "g1", link: nil),
            sourceTitle: source.title, sourceURL: source.url, category: source.category,
            title: "Test", excerpt: "Content", url: source.url + "/1", imageURL: nil,
            publishedAt: Date(), region: source.region), region: source.region)
        try await store.db.write { db in try item.insert(db) }

        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.count, 1, "Single-feed category must show exactly 1 item")
    }

    // MARK: - Many-feeds category validation

    func testManyFeedsCategoryResolution() async throws {
        let store = try FeedStore(inMemory: true)
        // Create 20 synthetic feeds in one category
        let sources = (0..<20).map { i in
            FeedSource(title: "Feed\(i)", url: "https://feed\(i).com/rss",
                       category: "Podcasts", region: "countries/italy")
        }
        store.registry.sources = sources
        await TaxonomyStore.shared.build(from: sources)

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://feed0.com/rss"))
        let urls = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(urls.count, 20, "Many-feeds category must resolve all 20 URLs")

        // Insert 1 item per source
        let items = sources.map { src in
            FeedItemRecord(from: FeedItem(
                id: FeedItem.generateID(sourceURL: src.url, guid: UUID().uuidString, link: nil),
                sourceTitle: src.title, sourceURL: src.url, category: "Podcasts",
                title: "Item from \(src.title)", excerpt: "Content",
                url: src.url + "/a/1", imageURL: nil,
                publishedAt: Date(), region: "countries/italy"), region: "countries/italy")
        }
        try await store.db.write { db in for item in items { try item.insert(db) } }

        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.count, 20, "Many-feeds category must show all 20 items")
    }

    // MARK: - Audio/podcast category validation

    func testPodcastCategoryFiltering() async throws {
        let store = try FeedStore(inMemory: true)
        // Podcast feed with audio URL
        let source = FeedSource(title: "NPR Wait Wait", url: "https://waitwait.npr.org/feed",
                                category: "More Comedy Podcasts", region: "topic/Entertainment", mediaKind: .audio)
        store.registry.sources = [source]
        await TaxonomyStore.shared.build(from: [source])

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://waitwait.npr.org/feed"))

        let item = FeedItemRecord(from: FeedItem(
            id: FeedItem.generateID(sourceURL: source.url, guid: "pod1", link: nil),
            sourceTitle: source.title, sourceURL: source.url, category: source.category,
            title: "Comedy Podcast Episode", excerpt: "Funny stuff",
            url: source.url + "/ep1", imageURL: nil,
            publishedAt: Date(), audioURL: "https://npr.org/audio.mp3", duration: 3600,
            region: source.region), region: source.region)
        try await store.db.write { db in try item.insert(db) }

        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.count, 1)
        XCTAssertTrue(store.visibleItems.first?.isPodcast ?? false, "Item must be identified as podcast")
    }

    // MARK: - Video category validation

    func testVideoCategoryFiltering() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(title: "Sorted Food", url: "https://www.youtube.com/feeds/videos.xml?channel_id=UCFallback",
                                category: "YouTube — Cooking Channels", region: "topic/Food_Drink", mediaKind: .video)
        store.registry.sources = [source]
        await TaxonomyStore.shared.build(from: [source])

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: source.url))

        let item = FeedItemRecord(from: FeedItem(
            id: FeedItem.generateID(sourceURL: source.url, guid: "vid1", link: nil),
            sourceTitle: source.title, sourceURL: source.url, category: source.category,
            title: "Cooking Tutorial", excerpt: "Learn to cook",
            url: "https://youtube.com/watch?v=abc123", imageURL: nil,
            publishedAt: Date(), region: source.region), region: source.region)
        try await store.db.write { db in try item.insert(db) }

        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.count, 1)
        XCTAssertTrue(store.visibleItems.first?.isYouTube ?? false, "Item must be identified as YouTube video")
    }

    // MARK: - Country-based category validation

    func testCountryCategoryFiltering() async throws {
        let store = try FeedStore(inMemory: true)
        let sources = [
            FeedSource(title: "Echorouk", url: "https://www.echoroukonline.com/rss/", category: "News", region: "countries/algeria"),
            FeedSource(title: "Algerie 360", url: "https://www.algerie360.com/rss/", category: "News", region: "countries/algeria"),
        ]
        store.registry.sources = sources
        await TaxonomyStore.shared.build(from: sources)

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://www.echoroukonline.com/rss/"))
        // Verify it's under countries/algeria path
        XCTAssertTrue(nodeID.hasPrefix("countries/") || nodeID.hasPrefix("algeria"),
                      "Country category node must be under countries hierarchy")

        let urls = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(urls.count, 2)

        let items = sources.map { src in
            FeedItemRecord(from: FeedItem(
                id: FeedItem.generateID(sourceURL: src.url, guid: UUID().uuidString, link: nil),
                sourceTitle: src.title, sourceURL: src.url, category: "News",
                title: "News from \(src.title)", excerpt: "Content",
                url: src.url + "/a/1", imageURL: nil,
                publishedAt: Date(), region: "countries/algeria"), region: "countries/algeria")
        }
        try await store.db.write { db in for item in items { try item.insert(db) } }

        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.count, 2)
    }

    // MARK: - Individually disabled feed still blocked under taxonomy

    func testIndividuallyDisabledFeedBlockedUnderTaxonomy() async throws {
        let store = try FeedStore(inMemory: true)
        let sources = [
            FeedSource(title: "ASA", url: "https://acousticalsociety.org/rss/", category: "Acoustics", region: "topic/General"),
            FeedSource(title: "Today", url: "https://acousticstoday.org/feed/", category: "Acoustics", region: "topic/General"),
        ]
        store.registry.sources = sources
        // Disable ASA individually, then disable entire category
        store.registry.toggleSource("https://acousticalsociety.org/rss/")
        store.registry.toggleCategory("Acoustics")

        await TaxonomyStore.shared.build(from: sources)
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://acousticstoday.org/feed/"))

        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        recordWait("\(self.name) pipeline settle", since: waitStart)
        XCTAssertEqual(store.loadingState, .idle,
                       "the feed pipeline must settle (loadingState == .idle) within 30s of the filter change")

        let items = sources.map { src in
            FeedItem(id: FeedItem.generateID(sourceURL: src.url, guid: src.url, link: nil),
                     sourceTitle: src.title, sourceURL: src.url, category: "Acoustics",
                     title: "Test", excerpt: "Content", url: src.url + "/1", imageURL: nil,
                     publishedAt: Date(), region: "topic/General")
        }
        let persisted = await store.persistFetchedItems(items)
        let filtered = store.applyFilters(persisted)
        XCTAssertEqual(filtered.count, 1, "ASA (individually disabled) must be blocked; Today must pass")
        // sourceURL is now normalized during persistence (no trailing slash)
        let todayURL = OPMLParser.normalizeURL("https://acousticstoday.org/feed/")
        XCTAssertEqual(OPMLParser.normalizeURL(filtered.first?.sourceURL ?? ""), todayURL)
    }

    // MARK: - Category with no recent items (graceful empty state)

    func testCategoryWithNoItemsShowsEmptyState() async throws {
        let store = try FeedStore(inMemory: true)
        let sources = [
            FeedSource(title: "EmptyFeed", url: "https://empty.example.com/feed", category: "Archived", region: "topic/General"),
        ]
        store.registry.sources = sources
        await TaxonomyStore.shared.build(from: sources)

        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://empty.example.com/feed"))
        let urls = TaxonomyStore.shared.feedURLs(inSubtreesOf: [nodeID])
        XCTAssertEqual(urls.count, 1)

        // No items in SQLite → filter should show empty state gracefully
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.loadingState != .idle && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        recordWait("\(self.name) pipeline settle", since: waitStart)
        XCTAssertEqual(store.loadingState, .idle,
                       "the feed pipeline must settle (loadingState == .idle) within 30s of the filter change")
        XCTAssertEqual(store.visibleItems.count, 0, "Category with no items must show 0 visible items")
        // App must not crash, loadingState must settle
        XCTAssertEqual(store.loadingState, .idle, "Loading state must settle even with empty results")
    }

    // MARK: - Bookmark Stamping

    func testStampedPreservesBookmarkStateFromRealIDs() {
        // Verify the stamping function passes through real bookmark IDs (not [])
        let item = FeedItem(id: "bm-test", sourceTitle: "S", sourceURL: "https://x.com/feed",
                           category: "News", title: "Test", excerpt: "E",
                           url: "https://x.com/1", imageURL: nil, publishedAt: Date(),
                           audioURL: nil, duration: nil, region: "global")

        // With real bookmark IDs — item should be stamped as bookmarked
        let stamped = item.stamped(readItemIDs: [], bookmarkItemIDs: ["bm-test"])
        XCTAssertTrue(stamped.isBookmarked, "Item whose ID is in bookmarkItemIDs must be stamped as bookmarked")

        // With empty bookmark IDs — item should NOT be bookmarked
        let notBookmarked = item.stamped(readItemIDs: [], bookmarkItemIDs: [])
        XCTAssertFalse(notBookmarked.isBookmarked, "Item stamped with empty set must not be bookmarked")

        // With unrelated bookmark IDs — item should NOT be bookmarked
        let unrelated = item.stamped(readItemIDs: [], bookmarkItemIDs: ["other-id"])
        XCTAssertFalse(unrelated.isBookmarked, "Item whose ID is not in bookmarkItemIDs must not be bookmarked")
    }

    // MARK: - Reservoir Flush Ordering

    func testPendingReservoirFlushCancelsDebounceAndCommitsImmediately() async throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(title: "S", url: "https://x.com/feed", category: "News", region: "global")
        ]
        let item = FeedItem(id: "pending-flush", sourceTitle: "S",
                            sourceURL: "https://x.com/feed",
                            category: "News", title: "Pending", excerpt: "E",
                            url: "https://x.com/1", imageURL: nil,
                            publishedAt: Date(), audioURL: nil,
                            duration: nil, region: "global")

        store.throttledReservoirAppend([item])

        let started = Date()
        await store.flushPendingReservoirForTesting()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.5, "Explicit flush must not wait for the 3s debounce")
        XCTAssertEqual(store.visibleItems.map(\.id), ["pending-flush"])
        XCTAssertEqual(store.reservoirCount, 0)
    }

    func testBalancedCandidatePoolProtectsSmallProvidersFromProlificSource() {
        func item(_ id: String, source: String) -> FeedItem {
            FeedItem(id: id, sourceTitle: source, sourceURL: "https://\(source).com/feed",
                     category: "News", title: id, excerpt: "E",
                     url: "https://example.com/\(id)", imageURL: nil,
                     publishedAt: Date(), region: "global")
        }

        let prolific = (0..<50).map { item("a-\($0)", source: "a") }
        let small = [item("b-0", source: "b"), item("c-0", source: "c"), item("d-0", source: "d")]

        let selected = FeedStore.balancedCandidatePool(
            prolific + small, limit: 12, initialPerSource: 2
        )

        XCTAssertEqual(selected.count, 12)
        XCTAssertTrue(Set(selected.prefix(5).map(\.sourceURL)).isSuperset(of: small.map(\.sourceURL)))
    }

    func testBalancedCandidatePoolRoundRobinsOverflowBetweenProviders() {
        func items(source: String, count: Int) -> [FeedItem] {
            (0..<count).map { index in
                FeedItem(id: "\(source)-\(index)", sourceTitle: source,
                         sourceURL: "https://\(source).com/feed", category: "News",
                         title: "Item \(index)", excerpt: "E",
                         url: "https://example.com/\(source)/\(index)", imageURL: nil,
                         publishedAt: Date(), region: "global")
            }
        }

        let selected = FeedStore.balancedCandidatePool(
            items(source: "a", count: 30)
                + items(source: "b", count: 6)
                + items(source: "c", count: 6),
            limit: 18,
            initialPerSource: 2
        )
        let counts = Dictionary(grouping: selected, by: \.sourceURL).mapValues(\.count)

        XCTAssertEqual(counts["https://a.com/feed"], 6)
        XCTAssertEqual(counts["https://b.com/feed"], 6)
        XCTAssertEqual(counts["https://c.com/feed"], 6)
    }

    func testBalancedCandidatePoolTreatsGoogleNewsQueriesAsOneProvider() {
        func items(sourceURL: String, prefix: String) -> [FeedItem] {
            (0..<10).map { index in
                FeedItem(
                    id: "\(prefix)-\(index)", sourceTitle: prefix,
                    sourceURL: sourceURL, category: "News",
                    title: "Item \(index)", excerpt: "E",
                    url: "https://example.com/\(prefix)/\(index)", imageURL: nil,
                    publishedAt: Date(), region: "global"
                )
            }
        }

        let googleNews = (0..<3).flatMap { query in
            items(
                sourceURL: "https://news.google.com/rss/search?q=topic-\(query)&hl=zh",
                prefix: "google-\(query)"
            )
        }
        let direct = (0..<3).flatMap { provider in
            items(sourceURL: "https://publisher-\(provider).cn/feed", prefix: "direct-\(provider)")
        }

        let selected = FeedStore.balancedCandidatePool(
            googleNews + direct, limit: 16, initialPerSource: 2
        )
        let counts = Dictionary(grouping: selected, by: Reservoir.providerKey).mapValues(\.count)

        XCTAssertEqual(counts["aggregator:news.google.com"], 4)
        XCTAssertEqual(Set(selected.map(Reservoir.providerKey)).count, 4)
        XCTAssertTrue(counts.values.allSatisfy { $0 == 4 })
    }

    func testBalancedCandidatePoolReservesAudioAndVideoInMixedResults() {
        func item(_ id: String, source: String, url: String, audioURL: String? = nil) -> FeedItem {
            FeedItem(
                id: id,
                sourceTitle: source,
                sourceURL: "https://\(source).example/feed",
                category: "General",
                title: id,
                excerpt: "Excerpt",
                url: url,
                imageURL: nil,
                publishedAt: Date(),
                audioURL: audioURL,
                region: "global"
            )
        }

        let text = (0..<300).map {
            item("text-\($0)", source: "text-\($0 / 10)", url: "https://example.com/text/\($0)")
        }
        let audio = (0..<12).map {
            item("audio-\($0)", source: "podcast-\($0 / 3)",
                 url: "https://example.com/audio/\($0)",
                 audioURL: "https://cdn.example.com/audio/\($0).mp3")
        }
        let video = (0..<12).map {
            item("video-\($0)", source: "video-\($0 / 3)",
                 url: "https://youtube.com/watch?v=video\($0)")
        }

        let selected = FeedStore.balancedCandidatePool(text + audio + video, limit: 60)

        XCTAssertEqual(selected.count, 60)
        XCTAssertTrue(selected.contains(where: \.isPodcast))
        XCTAssertTrue(selected.contains(where: \.isYouTube))
    }

    func testBalancedCandidatePoolToleratesRepeatedSourceOrder() {
        let items = (0..<4).map { index in
            FeedItem(
                id: "clockify-\(index)", sourceTitle: "Clockify Blog",
                sourceURL: "https://clockify.me/blog/feed", category: "News",
                title: "Item \(index)", excerpt: "E",
                url: "https://example.com/\(index)", imageURL: nil,
                publishedAt: Date(), region: "global"
            )
        }

        let selected = FeedStore.balancedCandidatePool(
            items,
            limit: 4,
            initialPerSource: 0
        )

        XCTAssertEqual(selected.map(\.id), items.map(\.id))
    }

    func testBundledStarterCatalogProvidesLanguageMatchedVariety() async {
        let sources = await FeedStore.bundledStarterSources(language: "en", limit: 30)
        let repeated = await FeedStore.bundledStarterSources(language: "en", limit: 30)

        XCTAssertEqual(sources.count, 30)
        XCTAssertTrue(sources.allSatisfy { $0.language == "en" })
        XCTAssertGreaterThanOrEqual(Set(sources.map(\.category)).count, 8)
        XCTAssertEqual(
            sources.map(\.url),
            repeated.map(\.url),
            "The first-run editorial runway must never depend on randomness"
        )
        XCTAssertTrue(sources.allSatisfy {
            CuratedPreferenceEngine.editorialAssessment(for: $0).isEligible
        })
    }

    func testColdStartRunwayRequiresBreadthNotJustItemVolume() {
        func items(sourceCount: Int, itemsPerSource: Int) -> [FeedItem] {
            (0..<sourceCount).flatMap { source in
                (0..<itemsPerSource).map { index in
                    FeedItem(
                        id: "\(source)-\(index)", sourceTitle: "Source \(source)",
                        sourceURL: "https://source\(source).example/feed",
                        category: "Category \(source % 8)", title: "Item \(index)",
                        excerpt: "Excerpt", url: "https://example.com/\(source)/\(index)",
                        imageURL: nil, publishedAt: Date(), region: "global", language: "en"
                    )
                }
            }
        }

        XCTAssertFalse(FeedStore.coldStartRunwayIsUseful(items(sourceCount: 5, itemsPerSource: 20)))
        XCTAssertFalse(FeedStore.coldStartRunwayIsUseful(items(sourceCount: 99, itemsPerSource: 2)))
        XCTAssertTrue(FeedStore.coldStartRunwayIsUseful(items(sourceCount: 100, itemsPerSource: 1)))
        XCTAssertTrue(FeedStore.coldStartRunwayIsUseful(
            items(sourceCount: 25, itemsPerSource: 1),
            targetSourceCount: 25
        ))
    }

    /// Review P0.3 — the **publish** gate is a complete page of distinct providers, not a screenful.
    ///
    /// The old trigger was `coldStartImmediateItemCount` (12 items), which is the `Loading → partial → better` sequence
    /// the review forbids: twelve items appeared, the reader started scrolling, and the page grew underneath them. These
    /// assertions pin the three interesting shapes — a screenful, a full page from too few providers, and a full page
    /// with the Reservoir's breadth — so the gate cannot quietly relax back to "the reservoir has something".
    func testColdStartPageGateRequiresAFullPageOfDistinctProviders() {
        func items(sourceCount: Int, itemsPerSource: Int) -> [FeedItem] {
            (0..<sourceCount).flatMap { source in
                (0..<itemsPerSource).map { index in
                    FeedItem(
                        id: "\(source)-\(index)", sourceTitle: "Source \(source)",
                        sourceURL: "https://source\(source).example/feed",
                        category: "Category \(source % 8)", title: "Item \(index)",
                        excerpt: "Excerpt", url: "https://example.com/\(source)/\(index)",
                        imageURL: nil, publishedAt: Date(), region: "global", language: "en"
                    )
                }
            }
        }

        XCTAssertFalse(FeedStore.coldStartPageIsReady(items(sourceCount: 6, itemsPerSource: 2)),
                       "a screenful from six providers is not a page")
        XCTAssertFalse(FeedStore.coldStartPageIsReady(items(sourceCount: 5, itemsPerSource: 8)),
                       "forty items from five providers is volume, not breadth")
        XCTAssertTrue(FeedStore.coldStartPageIsReady(items(sourceCount: Reservoir.pageSize, itemsPerSource: 1)))
    }

    func testWhatsNewUsesTheSameLanguageFilterAsMainFeed() throws {
        let store = try FeedStore(inMemory: true)
        let englishURLs = (0..<10).map { "https://english\($0).example/feed" }
        let italianURLs = (0..<10).map { "https://italian\($0).example/feed" }
        store.registry.sources = englishURLs.map {
            FeedSource(title: "English", url: $0, category: "News", language: "en")
        } + italianURLs.map {
            FeedSource(title: "Italian", url: $0, category: "News", language: "it")
        }
        store.activeLanguages = ["en"]

        let english = (0..<10).map { index in
            FeedItem(
                id: "en-new-\(index)", sourceTitle: "English", sourceURL: englishURLs[index],
                category: "News", title: "English item \(index)", excerpt: "English",
                url: "https://english.example/\(index)", imageURL: nil,
                publishedAt: Date(), region: "global", language: "en"
            )
        }
        let italian = (0..<10).map { index in
            FeedItem(
                id: "it-new-\(index)", sourceTitle: "Italian", sourceURL: italianURLs[index],
                category: "News", title: "Contenuto italiano \(index)", excerpt: "Italiano",
                url: "https://italian.example/\(index)", imageURL: nil,
                publishedAt: Date(), region: "global", language: "it"
            )
        }

        store.collectWhatsNewCandidates(italian + english)

        XCTAssertEqual(store.whatsNewItems.count, 10)
        XCTAssertTrue(store.whatsNewItems.allSatisfy { $0.language == "en" })
    }

    // MARK: - HTTP Legacy Alias Compatibility

    func testInMemoryFilterMatchesHTTPSourceForHTTPItem() async throws {
        let store = try FeedStore(inMemory: true)

        // Register source with https URL (as normalizeURL produces)
        let source = FeedSource(title: "Legacy Blog", url: "https://legacy.com/feed",
                                category: "News", region: "global")
        store.registry.sources = [source]
        await TaxonomyStore.shared.build(from: [source])
        let nodeID = try XCTUnwrap(TaxonomyStore.shared.nodeID(for: "https://legacy.com/feed"))

        // Activate taxonomy filter — this populates cachedTaxonomyFeedURLs
        store.setFilter(region: nil, nodeIDs: [nodeID], type: .all, mood: .all, languages: [])

        // Item with http:// URL (legacy row from v1-v5 era)
        let legacyItem = FeedItem(id: "http-item", sourceTitle: "S",
                                  sourceURL: "http://legacy.com/feed",
                                  category: "News", title: "Legacy", excerpt: "E",
                                  url: "http://legacy.com/1", imageURL: nil, publishedAt: Date(),
                                  audioURL: nil, duration: nil, region: "global")

        // applyFilters must not reject http:// items when https:// is in taxonomy
        let filtered = store.applyFilters([legacyItem])
        XCTAssertEqual(filtered.count, 1,
                       "http:// legacy source_url must survive in-memory filter when https:// counterpart is in taxonomy")
    }

    func testRegistrySourceLookupHandlesHTTPSchemeDifference() {
        let store = try! FeedStore(inMemory: true)

        // Source registered with https
        let source = FeedSource(title: "Test", url: "https://example.com/feed",
                                category: "News", region: "global")
        store.registry.sources = [source]

        // Legacy item with http:// — should still match via normalizeURL
        let isEnabled = store.registry.isSourceEnabled("http://example.com/feed")
        XCTAssertTrue(isEnabled, "Registry must match http:// source URLs via normalizeURL")
    }

    // MARK: - Language Filter: Content Type + Language Interaction

    func testVideoFilterWithPortugueseLanguageExcludesNonPortuguese() {
        // pt item + pt selected → passes
        XCTAssertTrue(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "pt", selectedLanguages: ["pt"], deviceLanguage: "en"))

        // tr item + pt selected → blocked
        XCTAssertFalse(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "tr", selectedLanguages: ["pt"], deviceLanguage: "en"))

        // en item + pt selected → blocked
        XCTAssertFalse(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "en", selectedLanguages: ["pt"], deviceLanguage: "en"))

        // nil item + pt selected + device en → blocked (device doesn't match pt)
        XCTAssertFalse(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: nil, selectedLanguages: ["pt"], deviceLanguage: "en"))
    }

    func testEmptyLanguageSelectionShowsAllUnlessUserExplicitlyCleared() {
        // No language filter → all pass
        XCTAssertTrue(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "tr", selectedLanguages: [], deviceLanguage: "en"))
        XCTAssertTrue(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: "pt", selectedLanguages: [], deviceLanguage: "en"))
        XCTAssertTrue(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: nil, selectedLanguages: [], deviceLanguage: "en"))
    }

    func testNilLanguageItemBlockedWhenDeviceLanguageSelected() {
        // nil item + en selected + device en → blocked (unknown is not en)
        XCTAssertFalse(FeedStore.languageFilterMatchesNormalized(
            itemLanguage: nil, selectedLanguages: ["en"], deviceLanguage: "en"))
    }

    func testSetFilterImmediatelyRemovesVisibleItemsOutsideSelectedLanguage() async throws {
        let store = try FeedStore(inMemory: true)
        let englishURL = "https://en.example/feed"
        let portugueseURL = "https://pt.example/feed"
        store.registry.sources = [
            FeedSource(title: "English", url: englishURL,
                       category: "News", region: "global", language: "en"),
            FeedSource(title: "Portuguese", url: portugueseURL,
                       category: "News", region: "global", language: "pt"),
        ]

        let englishItem = FeedItem(
            id: "en-visible", sourceTitle: "English", sourceURL: englishURL,
            category: "News", title: "English item", excerpt: "English content",
            url: "https://en.example/1", imageURL: nil, publishedAt: Date(),
            region: "global", language: "en"
        )
        let portugueseItem = FeedItem(
            id: "pt-visible", sourceTitle: "Portuguese", sourceURL: portugueseURL,
            category: "News", title: "Item em portugues", excerpt: "Conteudo em portugues",
            url: "https://pt.example/1", imageURL: nil, publishedAt: Date(),
            region: "global", language: "pt"
        )

        // Persist items to SQLite so filter reload can find them.
        try await store.db.write { db in
            try FeedItemRecord(from: englishItem, region: "global", language: englishItem.language).insert(db)
            try FeedItemRecord(from: portugueseItem, region: "global", language: portugueseItem.language).insert(db)
        }

        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["en"])

        // Wait for async filter reload to complete.
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.count < 1 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication (count)", since: waitStart)

        XCTAssertEqual(store.visibleItems.map(\.id), ["en-visible"],
                       "Selecting English should show only English items after reload")
    }

    func testDetectedLanguageOverridesWrongSourceLanguage() async {
        // When source says "en" but content is clearly Japanese,
        // detection should return "ja" — not blindly trust the source.
        let store = try! FeedStore(inMemory: true)
        let source = FeedSource(title: "YouTube Channel", url: "https://youtube.com/feed",
                                category: "General", region: "global",
                                language: "en")  // OPML says English
        store.registry.sources = [source]

        let item = FeedItem(
            id: "ja-video", sourceTitle: "YouTube",
            sourceURL: "https://youtube.com/feed",
            category: "General", title: "日本語のニュースまとめ 2024年最新情報をお届けします",
            excerpt: "本日は日本国内の最新ニュースを詳しく解説していきます。",
            url: "https://youtube.com/watch?v=test", imageURL: nil,
            publishedAt: Date(), region: "global",
            language: nil  // item has no explicit language — must be detected
        )

        let result = await store.persistFetchedItems([item])
        XCTAssertEqual(result.count, 1, "Japanese video should not be discarded")
        // The detected language should be Japanese, not English from the source
        if let lang = result.first?.language {
            XCTAssertEqual(lang, "ja",
                "Japanese-content video from English-tagged OPML should be detected as ja, got: \(lang)")
        } else {
            XCTFail("Language must be resolved for this item")
        }
    }

    func testIncidentalHanDoesNotTurnEnglishArticleChinese() {
        let language = FeedStore.resolvedLanguage(
            title: "The Lure of Jinxuan (金萱): Following a Tea Cultivar",
            excerpt: "This article follows Taiwan's celebrated tea cultivar across places, names, and sensory identities.",
            explicitLanguage: "zh"
        )

        XCTAssertEqual(language, "en")
    }

    func testChineseTextStillResolvesAsChineseWithoutScriptShortcut() {
        let language = FeedStore.resolvedLanguage(
            title: "中国茶文化的历史与现代发展",
            excerpt: "这篇文章介绍中国茶叶的种植方式、传统工艺以及现代市场的发展趋势。"
        )

        XCTAssertEqual(language, "zh")
    }

    func testRecoversGoogleNewsPublisherFromStoredArticleTitle() {
        XCTAssertEqual(
            FeedStore.googleNewsPublisher(fromArticleTitle: "咖啡的功效与副作用_哑评 - 新浪网"),
            "新浪网"
        )
        XCTAssertNil(FeedStore.googleNewsPublisher(fromArticleTitle: "没有发布者后缀"))
    }

    func testDetectedLanguageOverridesEnglishSourceForRussianContent() async throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://youtube.com/feeds/videos.xml?channel_id=russian"
        store.registry.sources = [
            FeedSource(
                title: "Russian channel mislabeled in catalogue",
                url: sourceURL,
                category: "Video",
                region: "global",
                language: "en"
            )
        ]
        let item = FeedItem(
            id: "ru-video",
            sourceTitle: "Лунтик",
            sourceURL: sourceURL,
            category: "Video",
            title: "Лунтик Футбольный праздник Сборник мультиков для детей",
            excerpt: "No description",
            url: "https://youtube.com/watch?v=russian",
            imageURL: nil,
            publishedAt: Date(),
            region: "global",
            language: nil
        )

        let result = await store.persistFetchedItems([item])

        XCTAssertEqual(try XCTUnwrap(result.first).language, "ru")
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: result.first?.language,
            selectedLanguages: ["en"],
            deviceLanguage: "en"
        ))
    }

    func testAzerbaijaniOrthographyOverridesEnglishSource() async throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://modern.az/rss"
        store.registry.sources = [
            FeedSource(
                title: "Modern",
                url: sourceURL,
                category: "News",
                region: "countries/azerbaijan",
                language: "en"
            )
        ]
        let item = FeedItem(
            id: "azerbaijani-item",
            sourceTitle: "Modern",
            sourceURL: sourceURL,
            category: "News",
            title: "Azərbaycan İraqa 1 milyonluq peçenye göndərdi",
            excerpt: "Modern.az xəbər verir ki, məlumat bu gün açıqlanıb.",
            url: "https://modern.az/item",
            imageURL: nil,
            publishedAt: Date(),
            region: "countries/azerbaijan",
            language: nil
        )

        let result = await store.persistFetchedItems([item])

        XCTAssertEqual(result.first?.language, "az")
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: result.first?.language,
            selectedLanguages: ["en"],
            deviceLanguage: "en"
        ))
    }

    func testBengaliScriptOverridesIncorrectItemLanguage() async throws {
        let store = try FeedStore(inMemory: true)
        let item = FeedItem(
            id: "bengali-item",
            sourceTitle: "Bangla Quran",
            sourceURL: "https://example.com/bangla.xml",
            category: "Podcast",
            title: "আল কোরআন বাংলা অনুবাদ সহ",
            excerpt: "Quran recitation with Bangla translation",
            url: "https://example.com/episode",
            imageURL: nil,
            publishedAt: Date(),
            region: "global",
            language: "en"
        )

        let result = await store.persistFetchedItems([item])

        XCTAssertEqual(result.first?.language, "bn")
        XCTAssertFalse(FeedStore.languageFilterMatches(
            itemLanguage: result.first?.language,
            selectedLanguages: ["en"],
            deviceLanguage: "en"
        ))
    }

    func testSourceWithCorrectLanguageIsPreserved() async {
        // When source says "pt" and content IS Portuguese, detection
        // should confirm "pt" — not override with something else.
        let store = try! FeedStore(inMemory: true)
        let source = FeedSource(title: "Brazilian Channel", url: "https://br.com/feed",
                                category: "News", region: "countries/brazil",
                                language: "pt")
        store.registry.sources = [source]

        let item = FeedItem(
            id: "pt-video", sourceTitle: "Brazilian News",
            sourceURL: "https://br.com/feed",
            category: "News", title: "Notícias do Brasil hoje",
            excerpt: "Confira as principais notícias do Brasil nesta semana.",
            url: "https://br.com/video", imageURL: nil,
            publishedAt: Date(), region: "countries/brazil",
            language: nil
        )

        let result = await store.persistFetchedItems([item])
        // Source is pt, content is pt — should stay pt
        if let lang = result.first?.language {
            XCTAssertEqual(lang, "pt",
                "Portuguese content from Portuguese source should stay pt, got: \(lang)")
        }
    }

    func testSourceLanguageNotOverriddenByShortContradictoryText() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(title: "Brazilian Channel", url: "https://br-short.com/feed",
                                category: "News", region: "countries/brazil",
                                language: "pt")
        store.registry.sources = [source]

        let item = FeedItem(
            id: "short-source-lang", sourceTitle: "Brazilian News",
            sourceURL: "https://br-short.com/feed",
            category: "News", title: "Breaking update",
            excerpt: "Live now",
            url: "https://br-short.com/video", imageURL: nil,
            publishedAt: Date(), region: "countries/brazil",
            language: nil
        )

        let result = await store.persistFetchedItems([item])
        let returned = try XCTUnwrap(result.first)
        XCTAssertEqual(returned.language, "pt",
                       "Short ambiguous text must not override an explicit source language")
    }

    func testSQLiteLanguageFilterExcludesUnknownLanguageVideos() async throws {
        let store = try FeedStore(inMemory: true)
        let ptURL = "https://youtube.com/feeds/videos.xml?channel_id=pt"
        let unknownURL = "https://youtube.com/feeds/videos.xml?channel_id=unknown"
        store.registry.sources = [
            FeedSource(title: "PT", url: ptURL, category: "Video", region: "global", mediaKind: .video, language: "pt"),
            FeedSource(title: "Unknown", url: unknownURL, category: "Video", region: "global", mediaKind: .video, language: nil),
        ]

        let ptItem = FeedItemRecord(from: FeedItem(
            id: "pt-video-db", sourceTitle: "PT", sourceURL: ptURL,
            category: "Video", title: "Video em portugues", excerpt: "Conteudo",
            url: "https://youtube.com/watch?v=pt", imageURL: nil,
            publishedAt: Date(), region: "global",
            language: "pt"
        ), region: "global", language: "pt")
        let unknownItem = FeedItemRecord(from: FeedItem(
            id: "unknown-video-db", sourceTitle: "Unknown", sourceURL: unknownURL,
            category: "Video", title: "Unknown video", excerpt: "Content",
            url: "https://youtube.com/watch?v=unknown", imageURL: nil,
            publishedAt: Date(), region: "global",
            language: nil
        ), region: "global", language: nil)

        try await store.db.write { db in
            try ptItem.insert(db)
            try unknownItem.insert(db)
        }

        store.setFilter(region: nil, nodeIDs: [], type: .video, mood: .all, languages: ["pt"])

        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)

        XCTAssertEqual(store.visibleItems.map(\.id), ["pt-video-db"],
                       "SQLite reload must not include unknown-language videos for an active language filter")
    }

    func testTopLevelVideoFilterQueriesCatalogueButRespectsExplicitSourceOptOut() throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://www.youtube.com/feeds/videos.xml?channel_id=country-video"
        store.registry.sources = [
            FeedSource(
                title: "Country Video",
                url: sourceURL,
                category: "Video",
                region: "countries/brazil",
                mediaKind: .video,
                language: "en"
            ),
        ]
        store.registry.toggleRegion("countries/brazil")
        XCTAssertFalse(store.registry.isSourceEnabled(sourceURL))

        store.beginFilterEditing()
        store.setFilter(
            region: nil,
            nodeIDs: [],
            type: .video,
            mood: .all,
            languages: ["en"]
        )
        let item = FeedItem(
            id: "country-video-item",
            sourceTitle: "Country Video",
            sourceURL: sourceURL,
            category: "Video",
            title: "A useful English video",
            excerpt: "Fresh content from the wider catalogue.",
            url: "https://www.youtube.com/watch?v=country-video",
            imageURL: nil,
            publishedAt: Date(),
            region: "countries/brazil",
            language: "en"
        )

        XCTAssertEqual(store.applyFilters([item]).map(\.id), [item.id])

        store.registry.toggleRegion("countries/brazil")
        store.registry.toggleSource(sourceURL)
        XCTAssertTrue(store.registry.isSourceExplicitlyDisabled(sourceURL))
        XCTAssertTrue(store.applyFilters([item]).isEmpty)
    }

    // MARK: - Clear All Filters + Content Type Integration

    func testClearAllFiltersThenSelectVideoHonorsLanguageFlag() async throws {
        let store = try FeedStore(inMemory: true)

        let deviceLang = FeedStore.normalizedLanguageCode(
            Locale.current.language.languageCode?.identifier
        ) ?? "en"
        let source = FeedSource(title: "Test", url: "https://test.com/feed",
                                category: "News", region: "global",
                                language: deviceLang)
        store.registry.sources = [source]

        // Clear all filters sets hasUserClearedLanguageFilter = true
        store.clearAllFilters()
        XCTAssertTrue(store.activeLanguages.isEmpty)
        XCTAssertTrue(store.hasUserClearedLanguageFilter,
                      "clearAllFilters must set hasUserClearedLanguageFilter")

        // When the flag is true, selecting content types with empty languages
        // yields all languages (user explicitly chose 'all')
        store.setFilter(region: nil, nodeIDs: [],
                        type: .video, mood: .all,
                        languages: store.activeLanguages)
        XCTAssertTrue(store.activeLanguages.isEmpty,
                      "After clearAllFilters + selectContentType, languages stay empty (user chose all)")

        // When the user toggles a specific language, the flag resets
        store.hasUserClearedLanguageFilter = false
        XCTAssertFalse(store.hasUserClearedLanguageFilter,
                       "Flag must reset after explicit language toggle")
    }

    func testTogglingLastLanguageKeepsAllLanguagesIntentForNextFilter() throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(title: "PT", url: "https://pt.com/feed",
                       category: "News", region: "global", language: "pt")
        ]
        let loader = FeedLoader(store: store)

        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["pt"])

        loader.toggleLanguage("pt")
        XCTAssertTrue(store.activeLanguages.isEmpty)
        XCTAssertTrue(store.hasUserClearedLanguageFilter,
                      "Removing the last language is an explicit all-languages choice")

        loader.selectContentType(.video)
        XCTAssertTrue(store.activeLanguages.isEmpty,
                      "Selecting a content type after clearing languages must not reapply device language")
    }

    func testBulkCountryToggleReportsOffBeforeCountRebuildCompletes() {
        let registry = SourceRegistry()
        registry.sources = [
            FeedSource(title: "Brazil", url: "https://example.com/br", category: "News", region: "countries/brazil"),
            FeedSource(title: "Canada", url: "https://example.com/ca", category: "News", region: "countries/canada"),
        ]

        registry.setAllCountriesEnabled(false)

        XCTAssertFalse(registry.isAnyCountryEnabled)
        XCTAssertEqual(registry.status(of: SourceRegistry.regionKey("countries/brazil")), .off)
        XCTAssertFalse(registry.isSourceEnabled("https://example.com/br"))
    }

    func testRegionSetterAppliesTheLatestRequestedState() {
        let registry = SourceRegistry()
        let sourceURL = "https://example.com/sao-paulo"
        registry.sources = [
            FeedSource(
                title: "Sao Paulo",
                url: sourceURL,
                category: "News",
                region: "countries/brazil/sao-paulo"
            ),
        ]

        registry.setRegionEnabled("countries/brazil", enabled: false)
        XCTAssertFalse(registry.isSourceEnabled(sourceURL))

        registry.setRegionEnabled("countries/brazil", enabled: true)
        XCTAssertTrue(registry.isSourceEnabled(sourceURL))
    }

    func testDormantCurrentSensitiveSourceIsDiscoverableButOptIn() {
        let registry = SourceRegistry()
        let source = FeedSource(
            title: "Dormant Daily News",
            url: "https://example.com/dormant-news.xml",
            category: "World News",
            region: "topic/01_News_&_Current_Affairs",
            sourceDescription: "An archived daily news source.",
            tags: ["news", "politics"],
            nature: "current-sensitive",
            activity: "dormant",
            qualityScore: 82,
            defaultEnabled: false
        )
        registry.sources = [source]

        XCTAssertEqual(registry.sources.count, 1, "Dormant source remains discoverable")
        XCTAssertFalse(registry.isSourceEnabled(source.url), "Dormant news is not fetched by default")

        registry.toggleSource(source.url)
        XCTAssertTrue(registry.isSourceEnabled(source.url), "Explicit user opt-in overrides the curated default")
    }

    func testUnifiedSearchPrioritizesSourcesThenSavedThenOldLocalContent() async throws {
        let store = try FeedStore(inMemory: true)
        let catalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedmine-search-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: catalogURL) }

        let occurrence = CatalogSourceOccurrence(
            title: "Deep Sky Notes",
            declaredURL: "https://example.com/deep-sky.xml",
            mediaKind: .text,
            language: "en",
            nodePath: [CatalogInputNode(name: "Technology & Science", kind: .topic)],
            opmlFile: "04_Technology_&_Science.opml",
            sortOrder: 0,
            sourceDescription: "Evergreen observations of the night sky.",
            tags: ["astronomy", "stargazing"],
            nature: "evergreen",
            activity: "dormant",
            qualityScore: 88,
            defaultEnabled: true
        )
        _ = try await SQLiteCatalogCompiler(
            input: .occurrences([occurrence]),
            databaseURL: catalogURL
        ).compileFull()

        let oldEpoch = Int(Date().addingTimeInterval(-120 * 86_400).timeIntervalSince1970)
        try await store.db.write { db in
            for (id, saved) in [("saved-astronomy", true), ("local-astronomy", false)] {
                let openedAt: Int? = saved ? nil : oldEpoch
                try db.execute(sql: """
                    INSERT INTO feed_item
                        (id, source_url, source_title, region, category, title, excerpt, url,
                         published_at, fetched_at, is_read, opened_at, language)
                    VALUES (?, ?, ?, 'global', 'Astronomy', ?, 'night sky observing', ?, ?, ?, ?, ?, 'en')
                    """, arguments: [
                        id,
                        "https://example.com/\(id).xml",
                        saved ? "Saved Observatory" : "Local Observatory",
                        saved ? "Saved astronomy guide" : "Old astronomy guide",
                        "https://example.com/\(id)",
                        oldEpoch,
                        oldEpoch,
                        saved ? 0 : 1,
                        openedAt,
                    ])
            }
        }
        try await store.bookmarkStore.toggleBookmark(itemID: "saved-astronomy")

        let engine = SearchEngine(db: store.db, userDB: store.userRepo.db, catalogURL: catalogURL)
        let results = await engine.unifiedSearch("astronomy")

        XCTAssertEqual(results.sources.first?.title, "Deep Sky Notes")
        XCTAssertEqual(results.savedItems.map(\.id), ["saved-astronomy"])
        XCTAssertEqual(results.localItems.map(\.id), ["local-astronomy"])
        XCTAssertEqual(results.sources.first?.nature, "evergreen")
    }

    func testSourceCollectionsAreManyToManyReferencesAndNeverMoveCatalogSources() async throws {
        let store = try FeedStore(inMemory: true)
        let catalogSource = FeedSource(
            title: "RuPaul",
            url: "https://example.com/rupaul/feed/",
            category: "Entertainment",
            region: "topic/03_Entertainment",
            mediaKind: .video,
            tags: ["drag", "reality television"]
        )
        store.registry.sources = [catalogSource]
        let reference = SourceReference(source: catalogSource)

        let queens = try await store.createSourceCollection(name: "Drag queens")
        let favorites = try await store.createSourceCollection(name: "Favorite creators")
        try await store.addSource(reference, toCollectionID: queens)
        try await store.addSource(reference, toCollectionID: favorites)
        // Equivalent URL is the same durable source identity, not a duplicate.
        try await store.addSource(
            SourceReference(title: "Duplicate label", feedURL: "http://www.example.com/rupaul/feed"),
            toCollectionID: queens
        )

        let queenMembers = try await store.sourceCollectionMembers(collectionID: queens)
        let favoriteMembers = try await store.sourceCollectionMembers(collectionID: favorites)
        let memberships = try await store.sourceCollectionIDs(containing: catalogSource.url)
        XCTAssertEqual(queenMembers.count, 1)
        XCTAssertEqual(favoriteMembers.count, 1)
        XCTAssertEqual(memberships, Set([queens, favorites]))
        XCTAssertEqual(store.registry.sources.count, 1)
        XCTAssertEqual(store.registry.sources.first?.category, "Entertainment")
        XCTAssertEqual(store.registry.sources.first?.region, "topic/03_Entertainment")

        try await store.deleteSourceCollection(id: queens)
        XCTAssertEqual(store.registry.sources.count, 1, "Deleting a playlist must not delete its source")
        let remainingMembers = try await store.sourceCollectionMembers(collectionID: favorites)
        XCTAssertEqual(remainingMembers.map(\.id), [reference.id])
    }

    func testCollectionPresetImmediatelyHydratesCachedExternalSource() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let externalSource = SourceReference(
            title: "Private Blog",
            feedURL: "https://127.0.0.1:1/private-feed.xml"
        )
        let collectionID = try await store.createSourceCollection(name: "Private")
        try await store.addSource(externalSource, toCollectionID: collectionID)

        let cachedItem = FeedItem(
            id: "private-cached-post",
            sourceTitle: externalSource.title,
            sourceURL: externalSource.feedURL,
            category: "Personal",
            title: "Cached private post",
            excerpt: "Available locally before the endpoint refresh finishes.",
            url: "https://example.com/private-cached-post",
            imageURL: nil,
            publishedAt: .now,
            region: "imported"
        )
        let persisted = await store.persistFetchedItems([cachedItem])
        XCTAssertEqual(persisted.map(\.id), [cachedItem.id])

        store.setPreset(.collection(
            collectionID: collectionID,
            collectionName: "Private"
        ))

        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)

        XCTAssertEqual(store.visibleItems.map(\.id), [cachedItem.id])
        XCTAssertEqual(
            store.presetSourceFilter,
            Set([OPMLParser.normalizeURL(externalSource.feedURL)])
        )

        let unrelatedItem = FeedItem(
            id: "unrelated-post",
            sourceTitle: "Other",
            sourceURL: "https://example.com/other.xml",
            category: "News",
            title: "Unrelated post",
            excerpt: "Must not leak into the collection preset.",
            url: "https://example.com/unrelated-post",
            imageURL: nil,
            publishedAt: .now,
            region: "global"
        )
        XCTAssertEqual(store.applyFilters([cachedItem, unrelatedItem]).map(\.id), [cachedItem.id])

        // Cancel the endpoint refresh started by setPreset before releasing the store.
        store.setPreset(.everything)
    }

    func testSourceURLsCanBeFiledInBulkWithoutChangingCatalogClassification() async throws {
        let store = try FeedStore(inMemory: true)
        let catalogSource = FeedSource(
            title: "Catalog Source",
            url: "https://example.com/catalog.xml",
            category: "Technology",
            region: "topic/technology"
        )
        let importedSource = FeedSource(
            title: "Personal Source",
            url: "https://example.com/personal.xml",
            category: "Imported",
            region: "imported"
        )
        store.registry.sources = [catalogSource, importedSource]
        let collectionID = try await store.createSourceCollection(name: "Weekend")

        let filedCount = try await store.addSourceURLs([
            catalogSource.url,
            "http://www.example.com/catalog.xml/",
            importedSource.url,
            "https://example.com/not-in-registry.xml",
        ], toCollectionID: collectionID)

        let members = try await store.sourceCollectionMembers(collectionID: collectionID)
        XCTAssertEqual(filedCount, 2)
        XCTAssertEqual(Set(members.map(\.sourceURL)), Set([
            OPMLParser.normalizeURL(catalogSource.url),
            OPMLParser.normalizeURL(importedSource.url),
        ]))
        XCTAssertEqual(store.registry.sources.first?.category, "Technology")
        XCTAssertEqual(store.registry.sources.first?.region, "topic/technology")
    }

    func testLegacyImportedCategoriesBecomeVisibleCollectionsOnlyOnce() async throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(
                title: "Unfiled Import",
                url: "https://example.com/imported.xml",
                category: "Imported",
                region: "imported"
            ),
            FeedSource(
                title: "Reading Import",
                url: "https://example.com/reading.xml",
                category: "Reading",
                region: "imported"
            ),
            FeedSource(
                title: "Bundled Reading",
                url: "https://example.com/bundled.xml",
                category: "Reading",
                region: "global"
            ),
        ]

        let migratedCount = try await store.migrateImportedSourceCollections()
        let collections = try await store.allSourceCollections()

        XCTAssertEqual(migratedCount, 2)
        XCTAssertEqual(Set(collections.map(\.name)), Set(["Imported", "Reading"]))
        XCTAssertEqual(collections.reduce(0) { $0 + $1.memberCount }, 2)

        let readingID = try XCTUnwrap(collections.first { $0.name == "Reading" }?.id)
        try await store.deleteSourceCollection(id: readingID)
        let repeatedMigrationCount = try await store.migrateImportedSourceCollections()
        let collectionsAfterDeletion = try await store.allSourceCollections()
        XCTAssertEqual(repeatedMigrationCount, 0)
        XCTAssertFalse(collectionsAfterDeletion.contains { $0.name == "Reading" })
    }

    func testExplicitSourceViewKeepsCompleteLocalHistoryPastAutomaticCap() async throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://example.com/archive.xml"
        let source = SourceReference(title: "Archive", feedURL: sourceURL)
        let items = (0..<75).map { index in
            FeedItem(
                id: "archive-\(index)",
                sourceTitle: source.title,
                sourceURL: sourceURL,
                category: "History",
                title: "Archived post \(index)",
                excerpt: "A retained post from the source archive.",
                url: "https://example.com/posts/\(index)",
                imageURL: nil,
                publishedAt: Date().addingTimeInterval(TimeInterval(-index * 86_400)),
                region: "global",
                language: "en"
            )
        }
        let persisted = await store.persistFetchedItems(items)
        XCTAssertEqual(persisted.count, 75)

        await store.recordExplicitSourceAccess(sourceURL)
        await store.capSourceItemsBatch([sourceURL])

        let retained = await store.sourceContentFromCache(source)
        XCTAssertEqual(retained.count, 75)
        XCTAssertEqual(retained.first?.id, "archive-0")
        XCTAssertEqual(retained.last?.id, "archive-74")
    }

    // MARK: - Collection preset round-trip

    /// Insert a single cached post directly into SQLite for an external source.
    /// Marking it as read ensures the generic ``reloadFromSQLite`` path (which
    /// filters `is_read == 0`) will **never** find it, while the collection-
    /// aware ``cachedSourceItems`` path (no read filter) will always find it.
    /// This makes the round-trip tests deterministic without needing thousands
    /// of catalog rows.
    private func insertReadPost(store: FeedStore, id: String, sourceURL: String, sourceTitle: String) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try await store.db.write { db in
            try db.execute(sql: """
                INSERT INTO feed_item (id, source_url, source_title, region, category,
                    title, excerpt, url, published_at, fetched_at, is_read, language)
                VALUES (?, ?, ?, 'imported', 'Personal', ?, ?, ?, ?, ?, 1, 'en')
                """, arguments: [
                    id, sourceURL, sourceTitle,
                    "Cached post \(id)", "Cached excerpt.",
                    "https://example.com/posts/\(id)",
                    now, now,
                ])
        }
    }

    func testCollectionPresetSurvivesEditorialRoundTripFast() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let externalURL = "https://127.0.0.1:1/private-feed.xml"
        let collectionID = try await store.createSourceCollection(name: "Private")
        try await store.addSource(
            SourceReference(title: "Private Blog", feedURL: externalURL),
            toCollectionID: collectionID
        )

        // Insert a read post so the generic reloadFromSQLite (is_read == 0)
        // cannot find it, but cachedSourceItems (no read filter) can.
        try await insertReadPost(store: store, id: "roundtrip-fast", sourceURL: externalURL, sourceTitle: "Private Blog")

        // Enter collection preset — must find the read post via exact-URL query.
        store.setPreset(.collection(collectionID: collectionID, collectionName: "Private"))
        var deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.map(\.id), ["roundtrip-fast"],
                       "Collection should hydrate the read post from cache")

        // Switch to editorial — fast return before the 300 ms source-enablement
        // refresh fires. Then immediately switch back to the collection.
        store.setPreset(.everything)
        // Yield a single tick so setPreset cancels stale work but does NOT
        // wait for the 300 ms editorial flush.
        try await Task.sleep(for: .milliseconds(10))

        store.setPreset(.collection(collectionID: collectionID, collectionName: "Private"))
        deadline = Date().addingTimeInterval(30)
        let waitStart2 = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart2)
        XCTAssertEqual(store.visibleItems.map(\.id), ["roundtrip-fast"],
                       "Fast return to collection must restore the cached post")
        // Cancel any in-flight work before the store is deallocated.
        store.setPreset(.everything)
    }

    func testCollectionPresetSurvivesEditorialRoundTripSlow() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let externalURL = "https://127.0.0.1:2/private-feed.xml"
        let collectionID = try await store.createSourceCollection(name: "Private")
        try await store.addSource(
            SourceReference(title: "Private Blog", feedURL: externalURL),
            toCollectionID: collectionID
        )

        try await insertReadPost(store: store, id: "roundtrip-slow", sourceURL: externalURL, sourceTitle: "Private Blog")

        // Enter collection.
        store.setPreset(.collection(collectionID: collectionID, collectionName: "Private"))
        var deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.map(\.id), ["roundtrip-slow"])

        // Switch to editorial and WAIT longer than the 300 ms source-enablement
        // refresh delay. This gives the stale editorial flush time to fire (and
        // be correctly discarded by the presetGeneration guard).
        store.setPreset(.everything)
        try await Task.sleep(for: .milliseconds(500))

        // Now switch back to the collection.
        store.setPreset(.collection(collectionID: collectionID, collectionName: "Private"))
        deadline = Date().addingTimeInterval(30)
        let waitStart2 = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart2)
        XCTAssertEqual(store.visibleItems.map(\.id), ["roundtrip-slow"],
                       "Slow return must survive the 300 ms editorial flush")
        XCTAssertEqual(
            store.presetSourceFilter,
            Set([OPMLParser.normalizeURL(externalURL)])
        )

        // Verify no non-member content leaked in.
        let allSourceURLs = Set(store.visibleItems.map(\.sourceURL))
        XCTAssertTrue(allSourceURLs.isSubset(of: [externalURL]),
                      "No content from outside the collection should appear")

        store.setPreset(.everything)
    }

    func testFilterSheetSimulationDoesNotTriggerUnnecessaryFilterReload() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let externalURL = "https://127.0.0.1:3/private-feed.xml"
        let collectionID = try await store.createSourceCollection(name: "Private")
        try await store.addSource(
            SourceReference(title: "Private Blog", feedURL: externalURL),
            toCollectionID: collectionID
        )

        try await insertReadPost(store: store, id: "filtersheet-sim", sourceURL: externalURL, sourceTitle: "Private Blog")

        // Simulate FilterSheetView.onAppear
        store.beginFilterEditing()

        // Enter collection preset (simulating user selecting it in the picker)
        store.setPreset(.collection(collectionID: collectionID, collectionName: "Private"))
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.map(\.id), ["filtersheet-sim"])

        // Simulate FilterSheetView.onDisappear: set the same filters (no actual
        // filter change — the old code would still trigger a reload because
        // draftIsDirty was true from the preset change alone).
        store.setFilter(region: nil, nodeIDs: [], type: .all)
        store.endFilterEditing()

        // Wait for the 80 ms filter reload debounce + some processing time.
        try await Task.sleep(for: .milliseconds(200))

        // The cached post must still be visible — the filter reload should
        // have used the collection-aware path (or been skipped because no
        // actual filter change occurred).
        XCTAssertFalse(store.visibleItems.isEmpty,
                       "FilterSheet dismiss should not flush collection content")
        XCTAssertEqual(store.visibleItems.map(\.id), ["filtersheet-sim"])

        store.setPreset(.everything)
    }

    func testCollectionToCollectionSwitch() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)

        let urlA = "https://127.0.0.1:4/collection-a.xml"
        let urlB = "https://127.0.0.1:5/collection-b.xml"

        let collA = try await store.createSourceCollection(name: "Collection A")
        let collB = try await store.createSourceCollection(name: "Collection B")
        try await store.addSource(SourceReference(title: "A", feedURL: urlA), toCollectionID: collA)
        try await store.addSource(SourceReference(title: "B", feedURL: urlB), toCollectionID: collB)

        try await insertReadPost(store: store, id: "post-a", sourceURL: urlA, sourceTitle: "Source A")
        try await insertReadPost(store: store, id: "post-b", sourceURL: urlB, sourceTitle: "Source B")

        // Open collection A.
        store.setPreset(.collection(collectionID: collA, collectionName: "Collection A"))
        var deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertEqual(store.visibleItems.map(\.id), ["post-a"])

        // Switch to collection B.
        store.setPreset(.collection(collectionID: collB, collectionName: "Collection B"))
        deadline = Date().addingTimeInterval(30)
        let waitStart2 = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.map(\.id) != ["post-b"] && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication (composition)", since: waitStart2)
        XCTAssertEqual(store.visibleItems.map(\.id), ["post-b"],
                       "Collection B should show only its own content")

        store.setPreset(.everything)
    }

    func testFilterChangesWhileCollectionActive() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let externalURL = "https://127.0.0.1:6/private-feed.xml"
        let collectionID = try await store.createSourceCollection(name: "Private")
        try await store.addSource(
            SourceReference(title: "Private Blog", feedURL: externalURL),
            toCollectionID: collectionID
        )

        // Insert one post in English, one in Portuguese.
        let now = Int(Date().timeIntervalSince1970)
        try await store.db.write { db in
            try db.execute(sql: """
                INSERT INTO feed_item (id, source_url, source_title, region, category,
                    title, excerpt, url, published_at, fetched_at, is_read, language)
                VALUES (?, ?, ?, 'imported', 'Personal', ?, ?, ?, ?, ?, 1, ?)
                """, arguments: [
                    "post-en", externalURL, "Private Blog",
                    "English post", "English excerpt.",
                    "https://example.com/en", now, now, "en",
                ])
            try db.execute(sql: """
                INSERT INTO feed_item (id, source_url, source_title, region, category,
                    title, excerpt, url, published_at, fetched_at, is_read, language)
                VALUES (?, ?, ?, 'imported', 'Personal', ?, ?, ?, ?, ?, 1, ?)
                """, arguments: [
                    "post-pt", externalURL, "Private Blog",
                    "Post em português", "Resumo em português.",
                    "https://example.com/pt", now, now, "pt",
                ])
        }

        // Open collection (all languages).
        store.setPreset(.collection(collectionID: collectionID, collectionName: "Private"))
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication (count)", since: waitStart)
        XCTAssertEqual(Set(store.visibleItems.map(\.id)), ["post-en", "post-pt"])

        // Apply Portuguese-only language filter.
        store.beginFilterEditing()
        store.setFilter(region: nil, nodeIDs: [], type: .all, languages: ["pt"])
        store.endFilterEditing()
        // Signal, not a duration: `setFilter` clears the page synchronously, so the reload's
        // first non-empty publication *is* the filtered composition. Waiting for that
        // publication (instead of sampling a fixed delay) is what makes this hold under suite
        // load; the exact page is asserted below, so a wrong composition still fails here
        // rather than being polled away.
        let publicationDeadline = Date().addingTimeInterval(30)
        let waitStart2 = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty, Date() < publicationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart2)
        XCTAssertFalse(
            store.visibleItems.isEmpty,
            "the filter reload must publish a page within 30s of endFilterEditing (setFilter cleared it synchronously and nothing came back)"
        )

        XCTAssertEqual(store.visibleItems.map(\.id), ["post-pt"],
                       "Language filter should apply over the collection allowlist")

        store.setPreset(.everything)
    }

    func testNoExternalContentLeaksIntoCollection() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let memberURL = "https://127.0.0.1:7/member.xml"
        let nonMemberURL = "https://example.com/non-member.xml"

        // Register the non-member source in the catalog so it has enabled
        // status and could leak through if the allowlist is broken.
        store.registry.sources = [
            FeedSource(title: "Non-Member", url: nonMemberURL, category: "News", region: "global")
        ]

        let collectionID = try await store.createSourceCollection(name: "Private")
        try await store.addSource(
            SourceReference(title: "Member", feedURL: memberURL),
            toCollectionID: collectionID
        )

        try await insertReadPost(store: store, id: "member-post", sourceURL: memberURL, sourceTitle: "Member")
        try await insertReadPost(store: store, id: "non-member-post", sourceURL: nonMemberURL, sourceTitle: "Non-Member")

        store.setPreset(.collection(collectionID: collectionID, collectionName: "Private"))
        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)

        XCTAssertEqual(store.visibleItems.map(\.id), ["member-post"],
                       "Only collection member content should appear")
        XCTAssertFalse(store.visibleItems.contains(where: { $0.id == "non-member-post" }),
                       "Non-member content must not leak into collection")

        store.setPreset(.everything)
    }

    func testEmptyCollectionShowsEmptyState() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let collectionID = try await store.createSourceCollection(name: "Empty")
        // Collection with zero items in cache and no members with content.
        try await store.addSource(
            SourceReference(title: "Empty Feed", feedURL: "https://127.0.0.1:8/empty.xml"),
            toCollectionID: collectionID
        )

        store.setPreset(.collection(collectionID: collectionID, collectionName: "Empty"))
        // Allow the cache hydration path to run (it will find nothing).
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(store.visibleItems.isEmpty,
                      "Empty collection should show no articles")
        // The loading state will be .refreshing while the network phase runs
        // (the in-memory store still tries real connections which take time
        // to fail). The key invariant is that no items appear, not that the
        // state settles quickly.

        store.setPreset(.everything)
    }

    func testSeenContentIsConsumedWithoutEnteringClickHistory() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let item = FeedItem(
            id: "seen-not-clicked",
            sourceTitle: "Example",
            sourceURL: "https://example.com/feed.xml",
            category: "Test",
            title: "Visible article",
            excerpt: "Crossed the visibility threshold.",
            url: "https://example.com/article",
            imageURL: nil,
            publishedAt: .now,
            region: "global",
            language: "en"
        )
        _ = await store.persistFetchedItems([item])

        store.markAsSeen(item.id)
        // `markAsSeen` persists in a fire-and-forget task; wait for that write to land (the
        // readiness signal) instead of assuming 50ms covers it under suite load, then assert
        // the exact row state.
        let persisted = await waitUntil {
            let consumedAt = try? await store.db.read { db -> Int? in
                try Int.fetchOne(
                    db,
                    sql: "SELECT consumed_at FROM feed_item WHERE id = ?",
                    arguments: [item.id]
                )
            }
            return consumedAt.flatMap { $0 } != nil
        }
        XCTAssertTrue(persisted, "markAsSeen must persist consumed_at within 30s")

        let state = try await store.db.read { db -> (Int?, Int?, Int?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT is_read, consumed_at, clicked_at FROM feed_item WHERE id = ?",
                arguments: [item.id]
            )
            return (row?["is_read"], row?["consumed_at"], row?["clicked_at"])
        }
        XCTAssertEqual(state.0, 0)
        XCTAssertNotNil(state.1)
        XCTAssertNil(state.2)

        store.setPreset(.lastClicked)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.visibleItems.isEmpty)
    }

    func testLastClickedOrdersOnlyActualClicksNewestFirst() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let items = ["older-click", "newer-click"].enumerated().map { index, id in
            FeedItem(
                id: id,
                sourceTitle: "Example \(index)",
                sourceURL: "https://example.com/\(index).xml",
                category: "Test",
                title: id,
                excerpt: "Clicked content.",
                url: "https://example.com/\(id)",
                imageURL: nil,
                publishedAt: .now,
                region: "global",
                language: "en"
            )
        }
        _ = await store.persistFetchedItems(items)

        store.markAsClicked("older-click")
        // `clicked_at` has second resolution, so the two clicks must land in different seconds
        // for the ordering assertion to mean anything. Wait for the clock to tick — a signal —
        // instead of sleeping a blind second.
        let firstClickSecond = Int(Date().timeIntervalSince1970)
        let ticked = await waitUntil { Int(Date().timeIntervalSince1970) > firstClickSecond }
        XCTAssertTrue(ticked, "the wall clock must reach a new second before the second click")

        store.markAsClicked("newer-click")
        // Both clicks must be persisted before the preset reads them back out of SQLite.
        let bothPersisted = await waitUntil {
            let clicked = try? await store.db.read { db -> Int? in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM feed_item WHERE clicked_at IS NOT NULL"
                )
            }
            return clicked.flatMap { $0 } == 2
        }
        XCTAssertTrue(bothPersisted, "both clicks must be persisted (clicked_at set) within 30s")

        store.setPreset(.lastClicked)

        let deadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication (count)", since: waitStart)
        XCTAssertEqual(store.visibleItems.map(\.id), ["newer-click", "older-click"])
    }

    func testSmartFeedCachesContentMatchesAndMovesSeenItemsToTailOnReload() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let source = FeedSource(
            title: "Culture Desk",
            url: "https://example.com/culture.xml",
            category: "Culture",
            region: "global",
            language: "en"
        )
        store.registry.sources = [source]
        store.activeLanguages = ["en"]

        let newer = FeedItem(
            id: "smart-madonna-newer",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "Madonna announces a new project",
            excerpt: "A detailed interview.",
            url: "https://example.com/newer",
            imageURL: nil,
            publishedAt: Date(),
            region: "global",
            language: "en"
        )
        let older = FeedItem(
            id: "smart-madonna-older",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "The influence of Madonna",
            excerpt: "A retrospective.",
            url: "https://example.com/older",
            imageURL: nil,
            publishedAt: Date().addingTimeInterval(-60),
            region: "global",
            language: "en"
        )
        let wrongLanguage = FeedItem(
            id: "smart-madonna-portuguese",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "Madonna anuncia novo projeto",
            excerpt: "Entrevista em português.",
            url: "https://example.com/pt",
            imageURL: nil,
            publishedAt: Date().addingTimeInterval(-120),
            region: "global",
            language: "pt"
        )
        _ = await store.persistFetchedItems([newer, older, wrongLanguage])

        let smartFeed = try await store.createSmartFeed(
            name: "Madonna",
            query: "madonna",
            includeSources: false,
            includeContents: true
        )
        XCTAssertEqual(smartFeed.cachedItemCount, 2)

        store.setPreset(.smartFeed(
            smartFeedID: smartFeed.id,
            smartFeedName: smartFeed.name
        ))
        let loadDeadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while store.visibleItems.count < 2 && Date() < loadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication (count)", since: waitStart)
        XCTAssertEqual(
            store.visibleItems.map(\.id),
            [newer.id, older.id],
            "Fresh Smart Feed items should start in publication order"
        )

        store.markAsSeen(newer.id)
        // The order on screen is synchronous — assert it before any wait, so the claim is about
        // visibility tracking rather than about how fast the cache write happens to be.
        XCTAssertEqual(
            store.visibleItems.map(\.id),
            [newer.id, older.id],
            "Visibility tracking must not move the card under the user's scroll position"
        )

        // The cache rewrite is what needs waiting for: wait for the seen item to leave the head
        // of the cached queue (the write landing), then assert the exact queue order.
        let queueMoved = await waitUntil {
            let cached = try? await store.smartFeedStore.cachedItems(smartFeedID: smartFeed.id)
            return cached?.first?.id != newer.id
        }
        XCTAssertTrue(queueMoved, "the seen item must be moved off the cached queue head within 30s")

        let reloadedQueue = try await store.smartFeedStore.cachedItems(
            smartFeedID: smartFeed.id
        )
        XCTAssertEqual(
            reloadedQueue.map(\.id),
            [older.id, newer.id],
            "Seen Smart Feed content should move behind every unseen item on reload"
        )
    }

    func testSourceScopedSmartFeedCachesContentFromMatchingSourceMetadataOnly() async throws {
        let store = try FeedStore(inMemory: true)
        let matchingSource = FeedSource(
            title: "Madonna Fan Club",
            url: "https://example.com/madonna.xml",
            category: "Music",
            region: "global",
            language: "en",
            sourceDescription: "News about the artist"
        )
        let otherSource = FeedSource(
            title: "General Culture",
            url: "https://example.com/general.xml",
            category: "Culture",
            region: "global",
            language: "en"
        )
        store.registry.sources = [matchingSource, otherSource]

        let sourceMatch = FeedItem(
            id: "source-scope-match",
            sourceTitle: matchingSource.title,
            sourceURL: matchingSource.url,
            category: matchingSource.category,
            title: "A completely unrelated headline",
            excerpt: "The query is absent from this article.",
            url: "https://example.com/source-match",
            imageURL: nil,
            publishedAt: .now,
            region: "global",
            language: "en"
        )
        let contentOnlyMatch = FeedItem(
            id: "source-scope-content-only",
            sourceTitle: otherSource.title,
            sourceURL: otherSource.url,
            category: otherSource.category,
            title: "Madonna retrospective",
            excerpt: "The query appears only in content.",
            url: "https://example.com/content-only",
            imageURL: nil,
            publishedAt: .now,
            region: "global",
            language: "en"
        )
        _ = await store.persistFetchedItems([sourceMatch, contentOnlyMatch])

        let smartFeed = try await store.createSmartFeed(
            name: "Madonna sources",
            query: "madonna",
            includeSources: true,
            includeContents: false
        )
        let cached = try await store.smartFeedStore.cachedItems(
            smartFeedID: smartFeed.id
        )
        XCTAssertEqual(cached.map(\.id), [sourceMatch.id])
    }

    func testContentsSearchDoesNotMatchSourceMetadata() async throws {
        let store = try FeedStore(inMemory: true)
        let items = [
            FeedItem(
                id: "source-metadata-only",
                sourceTitle: "Madonna Daily",
                sourceURL: "https://example.com/madonna-daily.xml",
                category: "Madonna",
                title: "An unrelated culture headline",
                excerpt: "No artist name appears in the article.",
                url: "https://example.com/unrelated",
                imageURL: nil,
                publishedAt: .now,
                region: "global",
                language: "en"
            ),
            FeedItem(
                id: "contents-match",
                sourceTitle: "Culture Daily",
                sourceURL: "https://example.com/culture.xml",
                category: "Culture",
                title: "Madonna announces a new project",
                excerpt: "The term appears in the content.",
                url: "https://example.com/contents",
                imageURL: nil,
                publishedAt: .now,
                region: "global",
                language: "en"
            ),
        ]
        _ = await store.persistFetchedItems(items)

        let results = await store.searchEngine.unifiedSearch(
            "madonna",
            includeSources: false,
            includeContents: true
        )
        XCTAssertEqual(results.localItems.map(\.id), ["contents-match"])
    }

    func testLiveSearchEligibilityIncludesSourcesWithoutCachedContentAndRespectsFilters() async throws {
        let store = try FeedStore(inMemory: true)
        let cachedEnglish = FeedSource(
            title: "Cached English",
            url: "https://example.com/cached-en.xml",
            category: "News",
            region: "global",
            language: "en"
        )
        let uncachedEnglish = FeedSource(
            title: "Uncached English",
            url: "https://example.com/uncached-en.xml",
            category: "News",
            region: "global",
            language: "en"
        )
        let uncachedPortuguese = FeedSource(
            title: "Uncached Portuguese",
            url: "https://example.com/uncached-pt.xml",
            category: "News",
            region: "global",
            language: "pt"
        )
        store.registry.sources = [
            cachedEnglish,
            uncachedEnglish,
            uncachedPortuguese,
        ]
        _ = await store.persistFetchedItems([
            FeedItem(
                id: "cached-search-item",
                sourceTitle: cachedEnglish.title,
                sourceURL: cachedEnglish.url,
                category: cachedEnglish.category,
                title: "Already cached",
                excerpt: "Only this source has local content.",
                url: "https://example.com/cached-item",
                imageURL: nil,
                publishedAt: .now,
                region: "global",
                language: "en"
            ),
        ])

        store.activeLanguages = ["en"]
        let eligibleURLs = Set(
            await store.sourcesEligibleForActiveSearch().map {
                OPMLParser.normalizeURL($0.url)
            }
        )
        XCTAssertEqual(
            eligibleURLs,
            Set([cachedEnglish.url, uncachedEnglish.url])
        )
        XCTAssertFalse(
            eligibleURLs.contains(uncachedPortuguese.url),
            "The active language filter must constrain the remote sweep"
        )

        store.registry.toggleSource(uncachedEnglish.url)
        let afterOptOut = Set(
            await store.sourcesEligibleForActiveSearch().map {
                OPMLParser.normalizeURL($0.url)
            }
        )
        XCTAssertEqual(afterOptOut, Set([cachedEnglish.url]))
    }

    func testSmartFeedAutomaticallyAccumulatesNewMatchingContentAtIngestion() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(
            title: "Music Wire",
            url: "https://example.com/music.xml",
            category: "Music",
            region: "global",
            language: "en"
        )
        store.registry.sources = [source]

        let smartFeed = try await store.createSmartFeed(
            name: "Madonna",
            query: "madonna",
            includeSources: false,
            includeContents: true
        )
        XCTAssertEqual(smartFeed.cachedItemCount, 0)

        let newMatch = FeedItem(
            id: "future-smart-match",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "Madonna returns with a surprise single",
            excerpt: "This arrived after the Smart Feed was created.",
            url: "https://example.com/future",
            imageURL: nil,
            publishedAt: .now,
            region: "global",
            language: "en"
        )
        _ = await store.persistFetchedItems([newMatch])

        let cached = try await store.smartFeedStore.cachedItems(
            smartFeedID: smartFeed.id
        )
        XCTAssertEqual(cached.map(\.id), [newMatch.id])
    }

    func testSmartFeedLearnsAndPrioritizesSourcesWithoutDoubleCountingMatches() async throws {
        let store = try FeedStore(inMemory: true)
        let frequentURL = "https://example.com/frequent.xml"
        let occasionalURL = "https://example.com/occasional.xml"
        store.registry.sources = [
            FeedSource(
                title: "Frequent Culture",
                url: frequentURL,
                category: "Culture",
                region: "global",
                language: "en"
            ),
            FeedSource(
                title: "Occasional Culture",
                url: occasionalURL,
                category: "Culture",
                region: "global",
                language: "en"
            ),
        ]
        let matches = [
            FeedItem(
                id: "affinity-frequent-1",
                sourceTitle: "Frequent Culture",
                sourceURL: frequentURL,
                category: "Culture",
                title: "Madonna announces a tour",
                excerpt: "First matching item.",
                url: "https://example.com/frequent/1",
                imageURL: nil,
                publishedAt: .now,
                region: "global",
                language: "en"
            ),
            FeedItem(
                id: "affinity-frequent-2",
                sourceTitle: "Frequent Culture",
                sourceURL: frequentURL,
                category: "Culture",
                title: "A Madonna retrospective",
                excerpt: "Second matching item.",
                url: "https://example.com/frequent/2",
                imageURL: nil,
                publishedAt: .now.addingTimeInterval(-60),
                region: "global",
                language: "en"
            ),
            FeedItem(
                id: "affinity-occasional-1",
                sourceTitle: "Occasional Culture",
                sourceURL: occasionalURL,
                category: "Culture",
                title: "Madonna appears at an event",
                excerpt: "One matching item.",
                url: "https://example.com/occasional/1",
                imageURL: nil,
                publishedAt: .now.addingTimeInterval(-120),
                region: "global",
                language: "en"
            ),
        ]
        _ = await store.persistFetchedItems(matches)

        let smartFeed = try await store.createSmartFeed(
            name: "Madonna",
            query: "madonna",
            includeSources: false,
            includeContents: true
        )
        let prioritizedURLs = try await store.smartFeedStore.prioritizedSourceURLs(
            smartFeedID: smartFeed.id
        )
        XCTAssertEqual(prioritizedURLs, [frequentURL, occasionalURL])

        try await store.smartFeedStore.cache(
            itemIDs: matches.map(\.id),
            for: smartFeed.id
        )
        let hitCounts = try await store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_url, hit_count
                FROM smart_feed_source
                WHERE smart_feed_id = ?
                """, arguments: [smartFeed.id]).reduce(into: [String: Int]()) {
                    result, row in
                    let sourceURL: String = row["source_url"]
                    let hitCount: Int = row["hit_count"]
                    result[sourceURL] = hitCount
                }
        }
        XCTAssertEqual(hitCounts[frequentURL], 2)
        XCTAssertEqual(hitCounts[occasionalURL], 1)

        try await store.deleteSmartFeed(id: smartFeed.id)
        let remainingAffinityCount = try await store.db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM smart_feed_source WHERE smart_feed_id = ?",
                arguments: [smartFeed.id]
            ) ?? 0
        }
        XCTAssertEqual(remainingAffinityCount, 0)
    }

    func testSmartFeedRefreshPolicyPrioritizesActivePresetAndBacksOffFailures() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let activeID: Int64 = 7
        let savedID: Int64 = 8
        let states = [
            SmartFeedRefreshState(
                id: savedID,
                lastAttemptAt: nil,
                lastSuccessAt: nil,
                consecutiveFailures: 0
            ),
            SmartFeedRefreshState(
                id: activeID,
                lastAttemptAt: now.addingTimeInterval(-6 * 60),
                lastSuccessAt: now.addingTimeInterval(-6 * 60),
                consecutiveFailures: 0
            ),
        ]
        XCTAssertEqual(
            SmartFeedRefreshPolicy.orderedDueStates(
                states,
                activeSmartFeedID: activeID,
                mode: .foreground,
                now: now
            ).map(\.id),
            [activeID, savedID],
            "The open Smart Feed must lead the opportunistic queue"
        )

        let failingActive = SmartFeedRefreshState(
            id: activeID,
            lastAttemptAt: now.addingTimeInterval(-6 * 60),
            lastSuccessAt: nil,
            consecutiveFailures: 1
        )
        XCTAssertEqual(
            SmartFeedRefreshPolicy.orderedDueStates(
                [failingActive],
                activeSmartFeedID: activeID,
                mode: .foreground,
                now: now
            ),
            [],
            "One failure doubles the active-preset interval from five to ten minutes"
        )
        XCTAssertEqual(
            SmartFeedRefreshPolicy.budget(
                isActivePreset: true,
                mode: .foreground,
                lowPower: false
            ),
            SmartFeedRefreshBudget(sourceLimit: 48, maxConcurrent: 6)
        )
        XCTAssertEqual(
            SmartFeedRefreshPolicy.budget(
                isActivePreset: false,
                mode: .background,
                lowPower: true
            ),
            SmartFeedRefreshBudget(sourceLimit: 4, maxConcurrent: 1)
        )
    }

    func testSmartFeedRefreshStatePersistsAttemptsFailuresAndSuccess() async throws {
        let store = try FeedStore(inMemory: true)
        let id = try await store.smartFeedStore.createSmartFeed(
            name: "Persistent Madonna",
            definition: SmartFeedDefinition(
                query: "madonna",
                includeSources: false,
                includeContents: true
            )
        )
        let attemptDate = Date(timeIntervalSince1970: 2_000_000_000)
        try await store.smartFeedStore.markRefreshStarted(
            smartFeedID: id,
            at: attemptDate
        )
        try await store.smartFeedStore.markRefreshFinished(
            smartFeedID: id,
            succeeded: false,
            at: attemptDate
        )
        try await store.smartFeedStore.markRefreshFinished(
            smartFeedID: id,
            succeeded: false,
            at: attemptDate
        )

        var states = try await store.smartFeedStore.refreshStates()
        var state = try XCTUnwrap(states.first { $0.id == id })
        XCTAssertEqual(state.lastAttemptAt, attemptDate)
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertEqual(state.consecutiveFailures, 2)

        let successDate = attemptDate.addingTimeInterval(60)
        try await store.smartFeedStore.markRefreshFinished(
            smartFeedID: id,
            succeeded: true,
            at: successDate
        )
        states = try await store.smartFeedStore.refreshStates()
        state = try XCTUnwrap(states.first { $0.id == id })
        XCTAssertEqual(state.lastSuccessAt, successDate)
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testSmartFeedDefinitionCapturesTheCompleteSearchContext() async throws {
        let previousPreset = Settings.activePreset
        defer { Settings.activePreset = previousPreset }

        let store = try FeedStore(inMemory: true)
        let collectionID = try await store.createSourceCollection(name: "Artists")
        store.activeRegion = "countries/canada"
        store.activeNodeIDs = ["music/pop"]
        store.activeLanguages = ["en"]
        store.activeContentType = .audio
        store.activeMood = .technical
        store.setPreset(.collection(
            collectionID: collectionID,
            collectionName: "Artists"
        ))

        let definition = store.makeSmartFeedDefinition(
            query: "madonna",
            includeSources: false,
            includeContents: true
        )
        XCTAssertEqual(definition.query, "madonna")
        XCTAssertFalse(definition.includeSources)
        XCTAssertTrue(definition.includeContents)
        XCTAssertEqual(definition.region, "countries/canada")
        XCTAssertEqual(definition.taxonomyNodeIDs, ["music/pop"])
        XCTAssertEqual(definition.languages, ["en"])
        XCTAssertEqual(definition.contentType, FeedLoader.ContentType.audio.rawValue)
        XCTAssertEqual(definition.mood, FeedLoader.MoodFilter.technical.rawValue)
        XCTAssertEqual(definition.sourceCollectionID, collectionID)

        store.setPreset(.everything)
    }

    func testSearchExpressionOnlyTreatsALeadingHyphenAsExclusion() throws {
        let terms = try [
            XCTUnwrap(SearchTerm(input: "post-punk")),
            XCTUnwrap(SearchTerm(input: "Jean-Michel")),
            XCTUnwrap(SearchTerm(input: "-rumor")),
        ]
        let expression = SearchExpression(terms: terms)

        XCTAssertEqual(expression.requiredTerms, ["post-punk", "Jean-Michel"])
        XCTAssertEqual(expression.excludedTerms, ["rumor"])
        XCTAssertTrue(
            expression.matches("A Jean-Michel post-punk retrospective")
        )
        XCTAssertFalse(
            expression.matches("A Jean-Michel post-punk rumor")
        )
        XCTAssertNil(SearchTerm(input: "-"))
    }

    func testComplexContentSearchCombinesTagsAndExclusions() async throws {
        let store = try FeedStore(inMemory: true)
        let matching = FeedItem(
            id: "complex-search-match",
            sourceTitle: "Culture",
            sourceURL: "https://example.com/culture.xml",
            category: "Culture",
            title: "Madonna announces a world tour",
            excerpt: "Confirmed dates arrive tomorrow.",
            url: "https://example.com/match",
            imageURL: nil,
            publishedAt: .now,
            region: "global",
            language: "en"
        )
        let excluded = FeedItem(
            id: "complex-search-excluded",
            sourceTitle: "Culture",
            sourceURL: "https://example.com/culture.xml",
            category: "Culture",
            title: "Madonna tour rumor spreads online",
            excerpt: "Nothing is confirmed.",
            url: "https://example.com/excluded",
            imageURL: nil,
            publishedAt: .now.addingTimeInterval(-10),
            region: "global",
            language: "en"
        )
        let missingTag = FeedItem(
            id: "complex-search-missing",
            sourceTitle: "Culture",
            sourceURL: "https://example.com/culture.xml",
            category: "Culture",
            title: "Madonna announces a movie",
            excerpt: "A new project.",
            url: "https://example.com/missing",
            imageURL: nil,
            publishedAt: .now.addingTimeInterval(-20),
            region: "global",
            language: "en"
        )
        _ = await store.persistFetchedItems([matching, excluded, missingTag])

        let expression = SearchExpression(terms: [
            try XCTUnwrap(SearchTerm(input: "Madonna")),
            try XCTUnwrap(SearchTerm(input: "tour")),
            try XCTUnwrap(SearchTerm(input: "-rumor")),
        ])
        let results = await store.searchEngine.unifiedSearch(
            expression,
            includeSources: false,
            includeContents: true
        )
        XCTAssertEqual(results.localItems.map(\.id), [matching.id])
    }

    func testComplexSmartFeedPersistsTermsAndAppliesExclusions() async throws {
        let store = try FeedStore(inMemory: true)
        let source = FeedSource(
            title: "Music Wire",
            url: "https://example.com/music-wire.xml",
            category: "Music",
            region: "global",
            language: "en"
        )
        store.registry.sources = [source]
        let accepted = FeedItem(
            id: "smart-complex-accepted",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "Madonna confirms a new tour",
            excerpt: "Official dates were published.",
            url: "https://example.com/accepted",
            imageURL: nil,
            publishedAt: .now,
            region: "global",
            language: "en"
        )
        let rejected = FeedItem(
            id: "smart-complex-rejected",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "Madonna tour rumor",
            excerpt: "An anonymous claim.",
            url: "https://example.com/rejected",
            imageURL: nil,
            publishedAt: .now.addingTimeInterval(-10),
            region: "global",
            language: "en"
        )
        _ = await store.persistFetchedItems([accepted, rejected])

        let expression = SearchExpression(terms: [
            try XCTUnwrap(SearchTerm(input: "Madonna")),
            try XCTUnwrap(SearchTerm(input: "tour")),
            try XCTUnwrap(SearchTerm(input: "-rumor")),
        ])
        let smartFeed = try await store.createSmartFeed(
            name: "Madonna tour",
            expression: expression,
            includeSources: false,
            includeContents: true
        )

        XCTAssertEqual(
            smartFeed.definition.requiredSearchTerms,
            ["Madonna", "tour"]
        )
        XCTAssertEqual(smartFeed.definition.excludedSearchTerms, ["rumor"])
        let cached = try await store.smartFeedStore.cachedItems(
            smartFeedID: smartFeed.id
        )
        XCTAssertEqual(cached.map(\.id), [accepted.id])

        let encoded = try JSONEncoder().encode(smartFeed.definition)
        let decoded = try JSONDecoder().decode(
            SmartFeedDefinition.self,
            from: encoded
        )
        XCTAssertEqual(decoded, smartFeed.definition)

        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "requiredSearchTerms")
        legacyJSON.removeValue(forKey: "excludedSearchTerms")
        legacyJSON["query"] = "Madonna tour"
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let migrated = try JSONDecoder().decode(
            SmartFeedDefinition.self,
            from: legacyData
        )
        XCTAssertEqual(migrated.requiredSearchTerms, ["Madonna", "tour"])
        XCTAssertEqual(migrated.excludedSearchTerms, [])
    }

    // MARK: - Content filters: main-actor vs off-main parity

    /// `applyFiltersAsync` runs on startup, on filter changes and on
    /// append/refresh, so it must hide exactly what the synchronous pass hides.
    /// When the two paths disagree, an item the user just hid through a content
    /// filter comes straight back through the off-main path.
    func testOffMainFilterAppliesContentFiltersLikeMainActorPass() async throws {
        let store = try FeedStore(inMemory: true)
        let sourceURL = "https://blog.example/feed"
        store.registry.sources = [
            FeedSource(title: "Blog", url: sourceURL, category: "News",
                       region: "global", language: "en"),
        ]
        let items = [
            contentFilterItem(id: "crypto",
                              title: "Bitcoin surges past its previous high",
                              sourceURL: sourceURL),
            contentFilterItem(id: "cats",
                              title: "Cat photos go viral",
                              sourceURL: sourceURL),
        ]

        let filters = ContentFilterStore.shared
        let isEnabledBefore = filters.isEnabled
        let idsBefore = Set(filters.filters.map(\.id))
        filters.isEnabled = true
        filters.addCustom(name: "Crypto", keywords: ["bitcoin"])
        let cryptoFilter = try XCTUnwrap(filters.filters.first { !idsBefore.contains($0.id) })
        defer {
            filters.removeCustom(cryptoFilter.id)
            filters.isEnabled = isEnabledBefore
        }

        XCTAssertEqual(store.applyFilters(items).map(\.id), ["cats"],
                       "The main-actor pass hides filtered content")
        let offMain = await store.applyFiltersAsync(items)
        XCTAssertEqual(offMain.map(\.id), ["cats"],
                       "The off-main pass must hide the same items")

        // Changing the filter set must invalidate what the off-main pass cached,
        // otherwise the next pass serves a verdict computed under the old filters.
        filters.removeCustom(cryptoFilter.id)
        filters.addCustom(name: "Cats", keywords: ["cat"])
        let catFilter = try XCTUnwrap(filters.filters.first { !idsBefore.contains($0.id) })
        defer { filters.removeCustom(catFilter.id) }

        let afterChange = await store.applyFiltersAsync(items)
        XCTAssertEqual(afterChange.map(\.id), ["crypto"],
                       "A new filter set must not be served from the previous cache")
    }

    // MARK: - Published presentation freeze

    /// An image that resolves after its card was published must not rewrite it.
    ///
    /// The hero slot is the card's only height difference, so a late image grows
    /// the card and shifts everything below it under the reader. The resolved
    /// image stays in `ImageCache` for the next composition instead. This test
    /// **fails against 1.0 (5)**, where the delegate handler swapped the
    /// published card to `.image` + `.hero`.
    func test_lateImageResolutionDoesNotMutatePublishedCard() throws {
        let store = try FeedStore(inMemory: true)
        let imageURL = "https://late.example/image.jpg"
        let item = FeedItem(
            id: "late-1",
            sourceTitle: "Blog",
            sourceURL: "https://late.example/feed",
            category: "News",
            title: "Text only until the image shows up",
            excerpt: "",
            url: "https://late.example/1",
            imageURL: imageURL,
            publishedAt: Date(),
            region: "global",
            language: "en"
        )
        store.display.publishCards(
            [FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                  isRead: false, isBookmarked: false)],
            items: [item],
            readItemIDs: [],
            bookmarkItemIDs: [],
            isAppend: false
        )

        // The retry only fires this notification once the image is cached.
        let url = try XCTUnwrap(URL(string: imageURL))
        ImageCache.shared.setImage(Self.onePixelImage(), for: url)

        store.imageResolutionQueue(didResolveImageFor: item.id)

        let cards = store.visibleCards
        XCTAssertEqual(cards.count, 1, "A late image must not insert or drop cards")
        XCTAssertEqual(cards[0].id, item.id, "Ids and order stay put")
        XCTAssertEqual(store.visibleItems.map(\.id), [item.id])
        XCTAssertEqual(cards[0].layout, .textOnly,
                       "A published card keeps the layout it was published with")
        guard case .none = cards[0].media else {
            return XCTFail("A published card must not gain media — the hero slot changes its height")
        }
    }

    /// 1×1 image so the cache has something real to hand back.
    private static func onePixelImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    private func contentFilterItem(id: String, title: String, sourceURL: String) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Blog",
            sourceURL: sourceURL,
            category: "News",
            title: title,
            excerpt: "",
            url: "https://example.com/\(id)",
            imageURL: nil,
            publishedAt: Date(),
            region: "global",
            language: "en"
        )
    }

    /// The off-main filter pass must see an enablement change immediately. Its
    /// disabled-source snapshot is now cached across calls (it used to be rebuilt per
    /// call, walking the whole catalogue on the main actor), so the cache is only
    /// correct if the registry's revisions invalidate it — this pins that, and the
    /// enablement revision that every toggle funnels through.
    func testFilterPassSeesSourceToggleImmediately() async throws {
        let store = try FeedStore(inMemory: true)
        defer { store.cancelAllWork() }
        await store.registry.loadFromOPML()
        let source = try XCTUnwrap(
            store.registry.enabledSources.first,
            "the bundled catalogue must offer an enabled source"
        )
        let items = [
            contentFilterItem(id: "toggled", title: "Toggle story", sourceURL: source.url)
        ]
        let enabledPass = await store.applyFiltersAsync(items)
        XCTAssertEqual(enabledPass.count, 1, "an enabled source must pass the filter")

        store.registry.toggleSource(source.url)
        let disabledPass = await store.applyFiltersAsync(items)
        XCTAssertTrue(
            disabledPass.isEmpty,
            "a source turned off must stop passing the filter on the very next pass"
        )

        store.registry.toggleSource(source.url)
        let reEnabledPass = await store.applyFiltersAsync(items)
        XCTAssertEqual(reEnabledPass.count, 1, "turning the source back on must restore it")
    }

    /// A filter change must present the matching local articles immediately,
    /// instead of holding them behind the network. The regression this pins: the
    /// local reload published into `visibleItems` but `publishCards` refused to
    /// leave `.preparing` while `loadingState` was `.refreshing`, so `FeedScreen`
    /// kept rendering `InitialFeedLoadingView` — with a slow or unreachable server
    /// the feed showed a spinner while matching articles were already in SQLite.
    func testFilterChangeShowsMatchingLocalArticlesWithoutANetwork() async throws {
        let store = try FeedStore(inMemory: true)
        defer { store.cancelAllWork() }
        // Local articles are only eligible when their source is in the catalogue:
        // `isSourceEnabled` answers false for a URL it does not know, so a made-up
        // source would be filtered out and the test would measure nothing.
        await store.registry.loadFromOPML()
        let sourceURL = try XCTUnwrap(
            store.registry.enabledSources.first?.url,
            "the bundled catalogue must offer an enabled source"
        )
        let articles = (0..<5).map {
            contentFilterItem(
                id: "local-\($0)",
                title: "Local story \($0)",
                sourceURL: sourceURL
            )
        }
        let persisted = await store.persistFetchedItems(articles)
        XCTAssertFalse(persisted.isEmpty, "the local articles must be stored")

        // Apply a filter composition and let the pipeline hydrate from SQLite. No
        // server is reachable from a test, which is the point of this test.
        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: nil)

        var published = false
        let publicationDeadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while Date() < publicationDeadline {
            if !store.visibleItems.isEmpty, case .ready = store.feedDisplayPhase {
                published = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertTrue(
            published,
            "matching local articles must be presented without waiting for the network"
        )
    }

    /// A warm install must publish the page it already holds *before* the bundled
    /// catalogue is parsed. The regression this pins: the cached page used to be
    /// published only after `loadFromOPML()`, the taxonomy load, the filter
    /// restore, the read state and the bookmarks — measured at ~23 s of
    /// "Preparing your feed…" on a warm simulator container, against the release
    /// target of one second for a *local* page.
    func testWarmStartPublishesCachedPageBeforeTheCatalogueLoads() async throws {
        let caches = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            "the app caches its first page in the caches directory"
        )
        func pageCacheFiles() -> [URL] {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: caches, includingPropertiesForKeys: nil
            )) ?? []
            return files.filter { $0.lastPathComponent.hasPrefix("visible-page-cache") }
        }
        // These tests run inside the app's process on this simulator, so the container
        // already holds real state — including a warm-start page cache. Snapshot it and
        // put it back, rather than deleting it: wiping it would destroy the very state a
        // warm-start measurement needs, which is not this test's business.
        let saved = pageCacheFiles().map { ($0, try? Data(contentsOf: $0)) }
        func clearPageCaches() { for file in pageCacheFiles() { try? FileManager.default.removeItem(at: file) } }
        clearPageCaches()
        defer {
            clearPageCaches()
            for (url, data) in saved { if let data { try? data.write(to: url) } }
        }

        let store = try FeedStore(inMemory: true)
        defer { store.cancelAllWork() }
        XCTAssertEqual(store.registry.sourceCount, 0, "the catalogue starts unloaded")

        // Arrange: the page a previous launch leaves behind, written through the
        // real cache path and keyed with the signature `start()` will look for.
        let previousLaunch = FeedDisplayState()
        previousLaunch.setVisibleItems(
            [FeedItem.makeMock(id: "cached-page")],
            readItemIDs: [],
            bookmarkItemIDs: [],
            shouldCache: true,
            filterSignature: store.pageCacheSignature
        )
        // The write is detached — wait until the cache is readable back, rather
        // than assume the file landed.
        var seeded = await previousLaunch.restoreCachedPage(filterSignature: store.pageCacheSignature) != nil
        let seedDeadline = Date().addingTimeInterval(30)
        let waitStart = CFAbsoluteTimeGetCurrent()
        while !seeded, Date() < seedDeadline {
            try await Task.sleep(for: .milliseconds(10))
            seeded = await previousLaunch.restoreCachedPage(filterSignature: store.pageCacheSignature) != nil
        }
        recordWait("\(self.name) page publication", since: waitStart)
        XCTAssertTrue(seeded, "the page cache must be readable before startup")

        // Act: watch the first publication against the catalogue's own progress.
        // Bounded by a spin count rather than the task's completion, which the
        // test cannot poll; `started.value` joins it afterwards either way.
        var sourceCountWhenPublished: Int?
        var spins = 0
        let started = Task { await store.start() }
        while sourceCountWhenPublished == nil, store.registry.sourceCount == 0, spins < 200_000 {
            if case .ready = store.feedDisplayPhase, !store.visibleItems.isEmpty {
                sourceCountWhenPublished = store.registry.sourceCount
            }
            spins += 1
            await Task.yield()
        }
        await started.value

        XCTAssertGreaterThan(
            store.registry.sourceCount, 0,
            "precondition: the bundled catalogue loads in this environment"
        )
        XCTAssertEqual(
            sourceCountWhenPublished, 0,
            "the cached page must be published before the catalogue loads; nil means it was never published early"
        )
    }
}
