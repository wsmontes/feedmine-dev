import XCTest
import CryptoKit
import FeedDomain
import FeedRuntime
import FeedStorage
@testable import feedmine

/// PR-12: the mirrored shadow (plan §13, `docs/runtime-v2/rollout.md` §5).
///
/// These assert the properties the plan calls non-negotiable, not the shape of the code: the shadow
/// adds no network, writes no user state, is bounded and honest about what it lost, and never blames
/// the runtime for a gap in its own coverage.
@MainActor
final class RuntimeV2ShadowTests: XCTestCase {

    private var tempDirectory: URL!
    private let fixedDate = Date(timeIntervalSince1970: 1_789_400_000)
    private let sourceURL = "https://example.com/feed.xml"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-shadow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let installed = ShadowMirrorRegistry.current { ShadowMirrorRegistry.remove(installed) }
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func database() throws -> RuntimeDatabase {
        try RuntimeDatabase(
            location: RuntimeDatabaseLocation(
                directory: tempDirectory.appendingPathComponent("shadow", isDirectory: true)
            )
        )
    }

    /// The measuring is scripted, not the real process: a test host under load would otherwise trip
    /// the shadow's own budget (its RSS and its CPU are the whole process's) and disable the shadow
    /// mid-test. `testShadowTurnsItselfOffOverBudgetAndSaysWhy` scripts the breach explicitly.
    private func bridge(
        database: RuntimeDatabase,
        budget: ShadowBudget = .standard,
        measuring: any ShadowResourceMeasuring = ScriptedResourceMeasuring([.zero])
    ) -> ShadowInputBridge {
        ShadowInputBridge(
            database: database,
            targetID: AcquisitionTargetID("test-shadow-target"),
            budget: budget,
            measuring: measuring,
            clock: { [fixedDate] in fixedDate }
        )
    }

    private func source(url: String? = nil) -> FeedSource {
        FeedSource(
            title: "Example Feed",
            url: url ?? sourceURL,
            category: "News",
            region: "global"
        )
    }

    private func item(
        id: String = "item-1",
        title: String = "A headline",
        url: String = "https://example.com/a",
        sourceURL: String? = nil,
        publishedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Example Feed",
            sourceURL: sourceURL ?? self.sourceURL,
            category: "News",
            title: title,
            excerpt: "An excerpt",
            url: url,
            imageURL: nil,
            publishedAt: publishedAt ?? fixedDate,
            region: "global",
            updatedAt: updatedAt
        )
    }

    /// A level-2 envelope for the item above, as the hook inside `RSSFetcher` would produce it.
    private func entry(
        for item: FeedItem,
        guid: String? = nil,
        link: String? = nil,
        updatedAt: Date? = nil
    ) -> ShadowParsedEntry {
        ShadowParsedEntry(
            legacyItemID: item.id,
            sourceURL: item.sourceURL,
            guid: guid,
            link: link ?? item.url,
            title: item.title,
            publishedAt: item.publishedAt,
            updatedAt: updatedAt,
            excerpt: item.excerpt,
            audioURL: nil
        )
    }

    private func mirror(_ items: [FeedItem], outcome: ShadowOutcomeKind = .newItems, url: String? = nil) -> ShadowFetchMirror {
        ShadowFetchMirror(
            sourceURL: url ?? sourceURL,
            sourceTitle: "Example Feed",
            outcome: outcome,
            items: items
        )
    }

    /// Mirrors one item at both levels and admits it.
    private func mirrorAndDrain(
        _ bridge: ShadowInputBridge,
        item: FeedItem,
        guid: String? = nil,
        updatedAt: Date? = nil
    ) {
        bridge.mirrorParsedEntry(entry(for: item, guid: guid, updatedAt: updatedAt))
        bridge.mirrorFetch(mirror([item]))
        bridge.drain()
    }

    // MARK: - No second fetch, no extra network

    /// The shadow consumes what the legacy path already fetched. The stub transport counts every
    /// request: one for the legacy fetch, none at all for the mirroring.
    func testShadowMirrorsWithoutExtraNetwork() async throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        CountingFeedTransport.reset(body: Self.rssFixture)

        let fetcher = RSSFetcher(shadow: bridge)
        let result = await fetcher.fetch(source(), transport: CountingFeedTransport.sync())

        XCTAssertEqual(CountingFeedTransport.requestCount, 1, "the legacy fetch is the only request")
        XCTAssertEqual(result.items.count, 2, "the fixture has two items")

        let report = bridge.drain()

        XCTAssertEqual(report.admitted, 1, "the fetch became one admitted batch")
        XCTAssertEqual(bridge.coverageReport().counters.mirroredItems, 2)
        XCTAssertEqual(
            CountingFeedTransport.requestCount, 1,
            "mirroring must not fetch: the shadow has no transport"
        )

        // And the mirror really wrote canonical state, so "no extra call" is not vacuous.
        let records = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM origin_record") ?? 0
        }
        XCTAssertEqual(records, 2)
    }

    // MARK: - No user state

    /// A mirror run leaves `user.sqlite` byte-identical: no bookmark, no exposure, no cursor.
    ///
    /// Scope of the proof, stated rather than implied: it covers the mirror path as invoked here, and
    /// the bridge holds no writer that could reach user state at all. It is not a process-wide
    /// guarantee against a future caller handing `ShadowInputBridge` a `UserStateBridge`.
    func testShadowDoesNotTouchUserState() async throws {
        let userDatabaseURL = tempDirectory.appendingPathComponent("user.sqlite")
        let userStore = try UserStateStore(databaseURL: userDatabaseURL)
        let contentStore = try FeedStore(inMemory: true)
        let bookmarks = BookmarkStore(userDB: userStore.db, contentDB: contentStore.db)
        let article = item()
        try await bookmarks.setBookmarked(
            itemID: article.id,
            wanted: true,
            operationID: "op-1",
            listID: nil,
            snapshot: BookmarkSnapshot(item: article, listID: bookmarks.defaultListID(), at: fixedDate),
            at: fixedDate
        )

        let database = try self.database()
        let bridge = self.bridge(database: database)
        let userState = UserStateBridge(
            bookmarks: bookmarks,
            projections: UserStateProjectionStore(database: database)
        )
        let root = try RuntimeCompositionRoot.compose(
            decision: Self.decision(mode: .mirroredShadow),
            applicationSupportDirectory: tempDirectory.appendingPathComponent("app-support", isDirectory: true),
            userState: userState
        )
        let before = try userDatabaseSignature(at: userDatabaseURL)
        XCTAssertFalse(before.isEmpty, "the user database exists and holds state before the mirror")

        root.installMirrorSink()
        let fetcher = RSSFetcher()
        let items = await fetcher.extractItems(fromFeedData: Data(Self.rssFixture.utf8), source: source())
        bridge.mirrorFetch(mirror(items))
        XCTAssertGreaterThan(bridge.drain().admitted, 0, "the mirror actually ran")

        let after = try userDatabaseSignature(at: userDatabaseURL)
        XCTAssertEqual(after, before, "a shadow run must not change one byte of user.sqlite")

        // The user's intention is still readable, so the proof is not "the file was never opened".
        let stored = await bookmarks.allBookmarkedItemIDs()
        XCTAssertTrue(stored.contains(article.id))
        root.removeMirrorSink()
    }

    /// The user database and everything SQLite keeps beside it, by content.
    private func userDatabaseSignature(at url: URL) throws -> [String: String] {
        let directory = url.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(url.lastPathComponent) }
        var signature: [String: String] = [:]
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            signature[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return signature
    }

    // MARK: - Bounded queue: drops are counted and invalidate their interval

    func testShadowCountsDropsAndInvalidatesThatInterval() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.queueCapacity = 1
        let bridge = self.bridge(database: database, budget: budget)

        let firstInterval = bridge.beginInterval()
        let queued = bridge.enqueue(mirror([item(id: "item-a")]))
        let droppedTwo = bridge.enqueue(mirror([item(id: "item-b")], url: "https://example.com/other.xml"))
        let droppedThree = bridge.enqueue(mirror([item(id: "item-c")], url: "https://example.com/third.xml"))

        XCTAssertEqual(queued, .queued)
        XCTAssertEqual(droppedTwo, .dropped(.queueFull))
        XCTAssertEqual(droppedThree, .dropped(.queueFull))

        let invalid = bridge.coverageReport()
        XCTAssertEqual(invalid.counters.droppedWork, 2)
        XCTAssertEqual(invalid.interval(firstInterval)?.droppedReasons["queueFull"], 2)
        XCTAssertTrue(invalid.invalidIntervals.contains(firstInterval))

        // The interval admitted its one item, and still counts as invalid: a lossy interval is not
        // evidence even where work did land.
        XCTAssertEqual(bridge.drain().admitted, 1)
        let afterDrain = bridge.coverageReport()
        let comparator = ShadowComparator()
        let legacy = [
            ShadowLegacyItem(item: item(id: "item-a")),
            ShadowLegacyItem(item: item(id: "item-c")),
        ]
        let comparison = comparator.compare(legacy: legacy, coverage: afterDrain)
        XCTAssertEqual(
            comparison.verdict(forLegacyItemID: "item-a"),
            .invalidInterval(firstInterval),
            "the mirrored item is not evidence either: the interval lost work"
        )
        XCTAssertEqual(comparison.verdict(forLegacyItemID: "item-c"), .invalidInterval(firstInterval))
        XCTAssertEqual(comparison.counters.invalidIntervalItems, 2)
        XCTAssertEqual(comparison.counters.divergences, 0, "a drop is never a runtime divergence")
    }

    func testShadowTurnsItselfOffOverBudgetAndSaysWhy() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.maximumCPUMillisecondsPerInterval = 50
        // Readings: composition, then the two the drain takes around its own work. Only the CPU the
        // shadow itself spends counts, so the scripted jump is the shadow's own cost.
        let measuring = ScriptedResourceMeasuring([
            ShadowResourceReading(residentBytes: 1_000, cpuMilliseconds: 0),
            ShadowResourceReading(residentBytes: 1_000, cpuMilliseconds: 10),
            ShadowResourceReading(residentBytes: 1_000, cpuMilliseconds: 900),
        ])
        let bridge = self.bridge(database: database, budget: budget, measuring: measuring)

        bridge.mirrorFetch(mirror([item()]))
        let report = bridge.drain()

        XCTAssertEqual(report.budgetBreach, .cpu)
        XCTAssertNotNil(bridge.disabledReason)
        XCTAssertTrue(bridge.disabledReason?.contains("cpu") == true)
        // A stop that does not name what breached is not diagnosable: the interval says which
        // quantity ended it, and the reason says which interval it was.
        let stopped = try XCTUnwrap(bridge.coverageReport().intervals.last)
        XCTAssertEqual(stopped.budgetStop, .cpu)
        XCTAssertTrue(
            try XCTUnwrap(bridge.disabledReason).contains(stopped.id.description),
            "the reason names the interval that stopped"
        )

        // Once over budget it stays off, and later work is dropped with the reason recorded.
        XCTAssertEqual(bridge.enqueue(mirror([item(id: "item-later")])), .dropped(.shadowDisabled(.cpu)))
        XCTAssertEqual(bridge.coverageReport().counters.skippedWhileDisabled, 1)
        XCTAssertEqual(bridge.coverageReport().counters.disabledReason, bridge.disabledReason)
    }

    /// Process-wide cost is measured and reported, never charged: a busy, large host cannot switch
    /// the shadow off, because no ceiling here is the host's to exceed.
    func testShadowMeasuresHostCostWithoutBeingChargedForIt() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.maximumCPUMillisecondsPerInterval = 50
        // The process holds 900 MB and has burned 5 s of CPU; the shadow's own drain adds nothing on
        // top of what it starts from.
        let measuring = ScriptedResourceMeasuring([
            ShadowResourceReading(residentBytes: 1_000, cpuMilliseconds: 5_000),
            ShadowResourceReading(residentBytes: 900_000_000, cpuMilliseconds: 5_000),
            ShadowResourceReading(residentBytes: 900_000_000, cpuMilliseconds: 5_000),
        ])
        let bridge = self.bridge(database: database, budget: budget, measuring: measuring)

        let interval = bridge.beginInterval()
        bridge.mirrorFetch(mirror([item()]))
        let report = bridge.drain()

        XCTAssertNil(report.budgetBreach, "the process's cost is not the shadow's cost")
        XCTAssertFalse(bridge.isDisabled)
        let coverage = bridge.coverageReport()
        XCTAssertNil(coverage.interval(interval)?.budgetStop)
        // Measured and reported, per plan §13's RSS requirement.
        XCTAssertEqual(coverage.interval(interval)?.residentGrowthBytes, 899_999_000)
    }

    // MARK: - Unmirrored is not divergence

    func testShadowDistinguishesUnmirroredFromDivergence() throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        let interval = bridge.beginInterval()

        let matched = item(id: "item-matched", title: "Matched headline", url: "https://example.com/matched")
        bridge.mirrorParsedEntry(entry(for: matched, guid: "guid-matched"))
        bridge.mirrorFetch(mirror([matched]))

        // An item the shadow never mirrored, in a source the interval did cover.
        let unmirrored = item(id: "item-unmirrored", title: "Never mirrored", url: "https://example.com/unmirrored")
        bridge.mirrorFetch(mirror([], outcome: .notModified))

        // A genuine runtime divergence: the same version key reappears with a different payload, and
        // the runtime refuses to overwrite a stored representation (ADR-003 D11) instead of silently
        // replacing it.
        let versioned = item(id: "item-versioned", title: "First headline", url: "https://example.com/versioned")
        let version = fixedDate.addingTimeInterval(3_600)
        bridge.mirrorParsedEntry(entry(for: versioned, guid: "guid-versioned", updatedAt: version))
        bridge.mirrorFetch(mirror([versioned]))
        bridge.drain()

        let edited = item(id: "item-versioned", title: "Edited headline", url: "https://example.com/versioned")
        bridge.mirrorParsedEntry(entry(for: edited, guid: "guid-versioned", updatedAt: version))
        bridge.mirrorFetch(mirror([edited]))
        let second = bridge.drain()

        XCTAssertGreaterThan(second.refused, 0, "the runtime refuses the divergent representation")

        let coverage = bridge.coverageReport()
        XCTAssertEqual(coverage.counters.auditedDivergences["version_payload_divergence"], 1)

        let comparator = ShadowComparator()
        let comparison = comparator.compare(
            legacy: [
                ShadowLegacyItem(item: matched),
                ShadowLegacyItem(item: unmirrored),
                ShadowLegacyItem(item: edited),
            ],
            coverage: coverage
        )

        XCTAssertEqual(comparison.verdict(forLegacyItemID: "item-matched"), .matched)
        XCTAssertEqual(
            comparison.verdict(forLegacyItemID: "item-unmirrored"),
            .notMirrored(.itemMissingInCoveredSource),
            "a gap in the shadow is not a defect of the runtime"
        )
        XCTAssertEqual(
            comparison.verdict(forLegacyItemID: "item-versioned"),
            .divergence(.versionPayloadDivergence(legacyItemID: "item-versioned"))
        )
        XCTAssertEqual(comparison.counters.matched, 1)
        XCTAssertEqual(comparison.counters.notMirrored, 1)
        XCTAssertEqual(comparison.counters.divergences, 1)
        XCTAssertFalse(coverage.invalidIntervals.contains(interval), "nothing was dropped in this interval")
    }

    /// A source the shadow never observed at all is a different gap from an item missing inside a
    /// covered source, and neither is a divergence.
    func testShadowReportsASourceItNeverCovered() throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        bridge.beginInterval()
        let covered = item()
        bridge.mirrorFetch(mirror([covered]))
        bridge.drain()

        let elsewhere = ShadowLegacyItem(
            legacyItemID: "item-elsewhere",
            sourceURL: "https://never-observed.example/feed.xml",
            title: "Other",
            url: "https://never-observed.example/a",
            publishedAt: fixedDate
        )
        let comparison = ShadowComparator().compare(
            legacy: [elsewhere],
            coverage: bridge.coverageReport()
        )
        XCTAssertEqual(comparison.verdict(forLegacyItemID: "item-elsewhere"), .notMirrored(.sourceNeverCovered))
        XCTAssertEqual(comparison.counters.divergences, 0)
    }

    // MARK: - Outcomes beyond "new items"

    func testShadowMirrorsEveryOutcomeNotOnlyNewItems() throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        let interval = bridge.beginInterval()

        let article = item(id: "item-covered")
        bridge.mirrorParsedEntry(entry(for: article, guid: "guid-covered"))
        bridge.mirrorFetch(mirror([article]))
        bridge.mirrorFetch(mirror([], outcome: .notModified))
        bridge.mirrorFetch(mirror([], outcome: .withoutNewItems))
        bridge.mirrorFetch(mirror([], outcome: .throttled, url: "https://example.com/b.xml"))
        bridge.mirrorFetch(mirror([], outcome: .failed, url: "https://example.com/c.xml"))
        let first = bridge.drain()

        XCTAssertEqual(first.admitted, 5, "every outcome is mirrored, including the empty ones")
        let coverage = bridge.coverageReport()
        let intervalCoverage = try XCTUnwrap(coverage.interval(interval))
        XCTAssertEqual(intervalCoverage.outcomes[.newItems], 1)
        XCTAssertEqual(intervalCoverage.outcomes[.notModified], 1)
        XCTAssertEqual(intervalCoverage.outcomes[.withoutNewItems], 1)
        XCTAssertEqual(intervalCoverage.outcomes[.throttled], 1)
        XCTAssertEqual(intervalCoverage.outcomes[.failed], 1)
        XCTAssertEqual(intervalCoverage.sources.count, 3, "coverage is measured per source")

        // The same content observed again is not new supply, and the shadow still saw it.
        bridge.mirrorParsedEntry(entry(for: article, guid: "guid-covered"))
        bridge.mirrorFetch(mirror([article]))
        _ = bridge.drain()
        XCTAssertEqual(bridge.coverageReport().counters.mirroredItems, 2)

        // An update of the same identity is mirrored too: with a new Atom `updated` the runtime
        // appends a revision and the pointer moves.
        let updated = item(id: "item-covered", title: "A revised headline", updatedAt: fixedDate.addingTimeInterval(600))
        bridge.mirrorParsedEntry(entry(for: updated, guid: "guid-covered", updatedAt: updated.updatedAt))
        bridge.mirrorFetch(mirror([updated]))
        _ = bridge.drain()

        XCTAssertEqual(
            bridge.coverageReport().interval(interval)?.admittedRevisionCount, 2,
            "the first observation and the update each appended a revision; the duplicate added none"
        )
        let comparison = ShadowComparator().compare(
            legacy: [ShadowLegacyItem(item: updated)],
            coverage: bridge.coverageReport()
        )
        XCTAssertEqual(
            comparison.verdict(forLegacyItemID: "item-covered"),
            .matched,
            "the runtime's current payload is the update the shadow sent"
        )
    }

    /// A durable alias that cannot be written is a gap in the shadow's index, not a divergence of the
    /// runtime, and it is counted instead of being swallowed.
    func testAliasWriteFailureIsCountedAndIsNotADivergence() throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        let interval = bridge.beginInterval()

        let article = item(id: "item-alias")
        bridge.mirrorParsedEntry(entry(for: article, guid: "guid-alias"))
        bridge.mirrorFetch(mirror([article]))

        // The alias table is gone; the canonical write still has to succeed.
        try database.write { db in
            try db.execute(sql: "DROP TABLE legacy_item_map")
        }
        XCTAssertEqual(bridge.drain().admitted, 1)
        XCTAssertEqual(bridge.coverageReport().counters.failedAliasWrites, 1)
        XCTAssertEqual(bridge.coverageReport().interval(interval)?.failedAliasWrites, 1)

        let records = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM origin_record") ?? 0
        }
        XCTAssertEqual(records, 1, "the content is committed even though the alias is not")

        let comparison = ShadowComparator().compare(
            legacy: [ShadowLegacyItem(item: article)],
            coverage: bridge.coverageReport()
        )
        XCTAssertEqual(comparison.verdict(forLegacyItemID: "item-alias"), .matched)
        XCTAssertEqual(comparison.counters.divergences, 0, "a shadow defect is never a runtime divergence")
    }

    /// Retention is bounded in wall-clock terms: a long-running shadow keeps only the last few
    /// intervals, so neither its per-item detail nor its invalidation window grows forever.
    func testIntervalsRotateSoRetentionStaysBounded() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.intervalDuration = 30
        budget.retainedIntervals = 2
        let clock = MutableClock(fixedDate)
        let bridge = ShadowInputBridge(
            database: database,
            targetID: AcquisitionTargetID("test-shadow-target"),
            budget: budget,
            measuring: ScriptedResourceMeasuring([.zero]),
            clock: { clock.now() }
        )

        for index in 0..<5 {
            let article = item(id: "item-\(index)")
            bridge.mirrorParsedEntry(entry(for: article, guid: "guid-\(index)"))
            bridge.mirrorFetch(mirror([article]))
            bridge.drain()
            clock.advance(40)
        }

        let report = bridge.coverageReport()
        XCTAssertEqual(
            report.intervals.count, 2,
            "only the retained intervals survive, whatever the session length"
        )
        // Work is admitted into the interval that was active when it was enqueued, so which of the
        // last intervals an item belongs to depends on when the rotation landed. The invariant is
        // that retention is bounded and that nothing from a pruned interval survives.
        XCTAssertFalse(report.mirrored.isEmpty)
        let retained = Set(report.intervals.map(\.id))
        XCTAssertTrue(
            report.mirrored.values.allSatisfy { retained.contains($0.interval) },
            "a mirrored item never outlives the interval it was admitted into"
        )
        XCTAssertNil(report.mirrored["item-0"], "the first interval's detail is long gone")
        XCTAssertEqual(report.counters.mirroredBatches, 5)
    }

    // MARK: - Bounds and visibility

    /// Entries are keyed by source, so two sources being parsed at once cannot borrow each other's
    /// identity — including when their outcomes arrive in the opposite order.
    ///
    /// Scope: this drives the capture points directly. The actor-level version (`fetchAll`'s task
    /// group) cannot be driven offline, because `fetchAll` builds its own `URLSession` and offers no
    /// transport seam.
    func testConcurrentSourcesKeepTheirOwnParsedEntries() throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        bridge.beginInterval()
        let sourceA = "https://a.example/feed.xml"
        let sourceB = "https://b.example/feed.xml"
        let articleA = item(id: "item-a", url: "https://a.example/1", sourceURL: sourceA)
        let articleB = item(id: "item-b", url: "https://b.example/1", sourceURL: sourceB)

        bridge.mirrorParsedEntry(entry(for: articleA, guid: "guid-a"))
        bridge.mirrorParsedEntry(entry(for: articleB, guid: "guid-b"))
        // The outcomes arrive in the order opposite to the parses.
        bridge.mirrorFetch(mirror([articleB], url: sourceB))
        bridge.mirrorFetch(mirror([articleA], url: sourceA))
        let report = bridge.drain()

        XCTAssertEqual(report.admitted, 2)
        let coverage = bridge.coverageReport()
        XCTAssertEqual(coverage.mirrored["item-a"]?.level, .parsedEntry)
        XCTAssertEqual(coverage.mirrored["item-b"]?.level, .parsedEntry)
        XCTAssertEqual(coverage.mirrored["item-a"]?.identityBytes, Data("guid-a".utf8))
        XCTAssertEqual(coverage.mirrored["item-b"]?.identityBytes, Data("guid-b".utf8))
        let covered = try XCTUnwrap(coverage.interval(covering: sourceA))
        XCTAssertEqual(coverage.interval(covered)?.sources.contains(sourceA), true)
    }

    /// The duplicate-record risk, made visible instead of described: one item mirrored first without
    /// its parsed entry (level 1, link-derived key) and then with it (level 2, GUID key) is two
    /// runtime records. The counters and the report expose it; the comparator does not, because the
    /// payloads agree — which is exactly why PR-15 has to decide the policy rather than inherit it.
    func testMirroringOneItemAtBothLevelsIsVisibleAsTwoRecords() throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        let interval = bridge.beginInterval()
        let article = item(id: "item-both", url: "https://example.com/both")

        bridge.mirrorFetch(mirror([article]))
        XCTAssertEqual(bridge.drain().admitted, 1)

        bridge.mirrorParsedEntry(entry(for: article, guid: "guid-both"))
        bridge.mirrorFetch(mirror([article]))
        XCTAssertEqual(bridge.drain().admitted, 1)

        let records = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM origin_record") ?? 0
        }
        XCTAssertEqual(records, 2, "both levels of one item are two records: the risk is real")
        let coverage = bridge.coverageReport()
        XCTAssertEqual(coverage.interval(interval)?.itemsWithoutParsedEntry, 1)
        XCTAssertEqual(coverage.interval(interval)?.itemsFromParsedEntry, 1, "the counters name it")
        XCTAssertEqual(
            ShadowComparator().compare(legacy: [ShadowLegacyItem(item: article)], coverage: coverage)
                .verdict(forLegacyItemID: "item-both"),
            .matched,
            "and the comparator cannot see it: payload agreement is not identity agreement"
        )
    }

    /// Admission that refuses everything is a shadow that stopped observing, which must not read as
    /// agreement. The target is revoked for real, so the refusals come from Admission itself.
    func testSustainedRefusalsStopCountingAsAgreement() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.refusalStallThreshold = 2
        let bridge = self.bridge(database: database, budget: budget)
        let health = item(id: "item-healthy")
        bridge.mirrorFetch(mirror([health]))
        XCTAssertEqual(bridge.drain().admitted, 1)
        XCTAssertFalse(bridge.isAdmissionStalled, "one admitted batch means the shadow is observing")

        try AcquisitionTargetStore().setState(.revoked, for: bridge.targetID, in: database)
        var refused = 0
        for index in 0..<2 {
            bridge.mirrorFetch(mirror([item(id: "item-refused-\(index)")]))
            refused += bridge.drain().refused
        }
        XCTAssertEqual(refused, 2, "the revoked target refuses every batch")
        XCTAssertTrue(bridge.isAdmissionStalled)
        XCTAssertTrue(
            try XCTUnwrap(bridge.admissionStallReason).contains("staleTarget"),
            "the stall names what Admission answered"
        )

        // A new interval while stalled is not evidence either.
        let stalled = bridge.beginInterval()
        let later = item(id: "item-after-stall")
        bridge.mirrorFetch(mirror([later]))
        _ = bridge.drain()
        let coverage = bridge.coverageReport()
        XCTAssertTrue(coverage.invalidIntervals.contains(stalled))
        XCTAssertEqual(
            ShadowComparator().compare(legacy: [ShadowLegacyItem(item: later)], coverage: coverage)
                .verdict(forLegacyItemID: "item-after-stall"),
            .invalidInterval(stalled),
            "a stall is never reported as 'no divergence'"
        )
    }

    /// A count of outcomes is not a size: the queue is bounded by the items it holds too.
    func testQueueIsBoundedByItemsNotOnlyByOutcomes() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.maximumQueuedItems = 1
        let bridge = self.bridge(database: database, budget: budget)

        XCTAssertEqual(bridge.enqueue(mirror([item(id: "item-1")])), .queued)
        XCTAssertEqual(bridge.enqueue(mirror([item(id: "item-2")])), .dropped(.queueItems))
        let coverage = bridge.coverageReport()
        XCTAssertEqual(coverage.counters.droppedWork, 1)
        XCTAssertEqual(coverage.intervals.last?.droppedReasons["queueItems"], 1)
        XCTAssertEqual(bridge.drain().admitted, 1)
        XCTAssertEqual(bridge.enqueue(mirror([item(id: "item-3")])), .queued, "draining frees the budget")
    }

    /// The entry map, not just each array, is bounded: a source whose outcome never arrives gives way.
    func testPendingEntrySourcesAreBounded() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.maximumSourcesWithPendingEntries = 2
        let bridge = self.bridge(database: database, budget: budget)
        let interval = bridge.beginInterval()
        let sourceA = "https://a.example/feed.xml"
        let sourceB = "https://b.example/feed.xml"
        let sourceC = "https://c.example/feed.xml"
        let articleA = item(id: "item-a", url: "https://a.example/1", sourceURL: sourceA)
        let articleB = item(id: "item-b", url: "https://b.example/1", sourceURL: sourceB)
        let articleC = item(id: "item-c", url: "https://c.example/1", sourceURL: sourceC)

        bridge.mirrorParsedEntry(entry(for: articleA, guid: "guid-a"))
        bridge.mirrorParsedEntry(entry(for: articleB, guid: "guid-b"))
        bridge.mirrorParsedEntry(entry(for: articleC, guid: "guid-c"))

        let coverage = bridge.coverageReport()
        XCTAssertEqual(coverage.counters.droppedWork, 1, "the oldest pending source had to give way")
        XCTAssertEqual(coverage.interval(interval)?.droppedReasons["pendingSourceOverflow"], 1)

        // The newest sources kept their entries; the dropped one falls back to level 1.
        bridge.mirrorFetch(mirror([articleC], url: sourceC))
        bridge.drain()
        XCTAssertEqual(bridge.coverageReport().mirrored["item-c"]?.level, .parsedEntry)
        bridge.mirrorFetch(mirror([articleA], url: sourceA))
        bridge.drain()
        XCTAssertEqual(bridge.coverageReport().mirrored["item-a"]?.level, .legacyItem)
    }

    /// Report paths are bounded: the conflict read is a prefix that says so, and payload chunking
    /// loses nothing.
    func testReportPathsAreBoundedAndSayWhenTheyTruncate() throws {
        let database = try self.database()
        var budget = ShadowBudget.standard
        budget.maximumReportedConflicts = 1
        budget.payloadQueryChunkSize = 1
        let bridge = self.bridge(database: database, budget: budget)
        let version = fixedDate.addingTimeInterval(7_200)

        for index in 0..<2 {
            let first = item(id: "item-clash-\(index)", title: "First", url: "https://example.com/clash\(index)")
            bridge.mirrorParsedEntry(entry(for: first, guid: "guid-clash-\(index)", updatedAt: version))
            bridge.mirrorFetch(mirror([first]))
            bridge.drain()
            let edited = item(id: "item-clash-\(index)", title: "Edited", url: "https://example.com/clash\(index)")
            bridge.mirrorParsedEntry(entry(for: edited, guid: "guid-clash-\(index)", updatedAt: version))
            bridge.mirrorFetch(mirror([edited]))
            bridge.drain()
        }

        let coverage = bridge.coverageReport()
        XCTAssertEqual(coverage.conflicts.count, 1, "the read is a bounded prefix, not the whole table")
        XCTAssertTrue(coverage.conflictsTruncated, "and it reports that it was truncated")

        // Two items read with one id per query: chunking must not lose either payload.
        let paired = item(id: "item-paired", title: "Paired", url: "https://example.com/paired")
        bridge.mirrorParsedEntry(entry(for: paired, guid: "guid-paired"))
        bridge.mirrorFetch(mirror([paired]))
        bridge.drain()
        let finalCoverage = bridge.coverageReport()
        let comparison = ShadowComparator().compare(
            legacy: [ShadowLegacyItem(item: paired)],
            coverage: finalCoverage
        )
        XCTAssertEqual(comparison.verdict(forLegacyItemID: "item-paired"), .matched)
    }

    // MARK: - The concurrent path, with no network at all

    /// `fetchAll`'s task group is the real actor-level path: several sources parsed and fetched
    /// concurrently, each outcome mirrored. PR-15 gave `RSSFetcher` a transport seam, which is what this
    /// test was missing: `URLProtocol` registration never reached the fetcher's sessions
    /// (`docs/runtime-v2/baseline.md` §8.8.3 measured the guard's count at 0), so an unreachable endpoint
    /// is now stated by the transport instead of by a process-wide guard — and the request count is the
    /// transport's own, which is a stronger claim than the guard's.
    func testFetchAllMirrorsEachSourceOutcomeWithoutExtraRequests() async throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        let sources = [
            source(url: "https://a.example/feed.xml"),
            source(url: "https://b.example/feed.xml"),
        ]

        let transport = UnreachableFeedTransport()
        let fetcher = RSSFetcher(shadow: bridge, transport: transport)
        let batch = await fetcher.fetchAll(sources, maxConcurrent: 2)

        let attempted = await transport.requestedURLs()
        XCTAssertEqual(attempted.count, 2, "the legacy path attempted exactly one fetch per source")
        XCTAssertEqual(Set(attempted), Set(sources.map(\.url)), "one attempt per endpoint, not per item")
        XCTAssertEqual(batch.failedSourceCount, 2, "and every attempt failed: the endpoint is unreachable")

        let report = bridge.drain()
        XCTAssertEqual(report.admitted, 2, "one mirrored batch per source outcome")
        XCTAssertEqual(report.mirroredItems, 0, "a failed fetch carries no items, and none are invented")
        let afterMirroring = await transport.requestedURLs()
        XCTAssertEqual(afterMirroring.count, 2, "the shadow added no attempt of its own")

        let coverage = bridge.coverageReport()
        let interval = try XCTUnwrap(coverage.intervals.last)
        XCTAssertEqual(interval.sources, Set(sources.map(\.url)), "coverage is per source")
        XCTAssertEqual(interval.outcomes[.failed], 2, "the outcomes are the failures the app really got")
    }

    // MARK: - Level 2 keeps the wire identity

    /// A GUID that looks like a URL is not normalized, resolved against a base URL or otherwise
    /// rewritten: the runtime's key is the bytes the feed declared (ADR-003 D10).
    func testMirrorLevelTwoPreservesTheOriginalGuidByteIdentical() async throws {
        let database = try self.database()
        let bridge = self.bridge(database: database)
        let declaredGUID = "HTTPS://Example.COM/Path/Sub/?b=2&a=1#Fragment"
        let fixture = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0"><channel>
              <title>Example</title><link>https://example.com</link><description>d</description>
              <item>
                <guid isPermaLink="true">HTTPS://Example.COM/Path/Sub/?b=2&amp;a=1#Fragment</guid>
                <title>An article</title>
                <link>https://example.com/path/sub?a=1&amp;b=2</link>
                <description>Body</description>
              </item>
            </channel></rss>
            """

        let fetcher = RSSFetcher(shadow: bridge)
        let items = await fetcher.extractItems(fromFeedData: Data(fixture.utf8), source: source())
        let article = try XCTUnwrap(items.first)
        XCTAssertEqual(article.id, FeedItem.generateID(
            sourceURL: sourceURL,
            guid: declaredGUID,
            link: "https://example.com/path/sub?a=1&b=2",
            title: "An article",
            publishedAt: article.publishedAt
        ), "the legacy alias is still derived from the raw GUID")

        bridge.mirrorFetch(mirror(items))
        bridge.drain()

        let mirrored = try XCTUnwrap(bridge.coverageReport().mirrored[article.id])
        XCTAssertEqual(mirrored.level, .parsedEntry)
        XCTAssertEqual(
            mirrored.identityBytes,
            Data(declaredGUID.utf8),
            "the key is the declared GUID, byte for byte"
        )
        XCTAssertNotEqual(mirrored.identityBytes, Data(article.url.utf8), "and it is not the item link")

        // The same identity survives in the database unchanged.
        let stored = try database.read { db in
            try Data.fetchOne(db, sql: "SELECT external_key FROM external_identity WHERE key_kind = 'object'")
        }
        XCTAssertEqual(stored, Data(declaredGUID.utf8))
    }

    // MARK: - Mode resolution and composition

    func testInvalidModeResolvesToLegacyWithReason() throws {
        let suiteName = "runtime-modes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // shadow + UI has no owner: two components would claim presentation.
        RuntimeModeLaunch.request(
            RequestedFeatures(shadow: true, v2UI: true, v2Network: false),
            in: defaults
        )
        let decision = RuntimeModeLaunch.decide(in: defaults, arguments: [], at: fixedDate)

        XCTAssertEqual(decision.mode, .legacy)
        XCTAssertFalse(decision.runsShadow)
        XCTAssertEqual(decision.source, .stored)
        let rejection = try XCTUnwrap(decision.rejection)
        XCTAssertTrue(rejection.contains("shadow=true"), rejection)
        XCTAssertTrue(rejection.contains("v2UI=true"), rejection)
        XCTAssertTrue(rejection.contains("legacy"), rejection)

        // The reason is recorded, not just returned.
        let recorded = RuntimeModeLaunch.current(in: defaults)
        XCTAssertEqual(recorded.mode, .legacy)
        XCTAssertEqual(recorded.rejection, rejection)

        // And the composition root runs nothing in that mode.
        let root = try RuntimeCompositionRoot.compose(
            decision: decision,
            applicationSupportDirectory: tempDirectory.appendingPathComponent("app-support", isDirectory: true)
        )
        XCTAssertNil(root.shadow)
        if case .legacyOnly(let reason) = root.outcome {
            XCTAssertTrue(reason.contains("rejected"), reason)
        } else {
            XCTFail("an invalid request must compose legacy only, got \(root.outcome)")
        }
        let shadowDirectory = RuntimeCompositionRoot.shadowDirectory(
            applicationSupportDirectory: tempDirectory.appendingPathComponent("app-support", isDirectory: true)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: shadowDirectory.path),
            "a mode that does not run a shadow must not create its database"
        )
    }

    func testModeRequestTakesEffectOnTheNextLaunchOnly() throws {
        let suiteName = "runtime-modes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // No request at all: legacy, and the decision is recorded.
        let firstLaunch = RuntimeModeLaunch.decide(in: defaults, arguments: [], at: fixedDate)
        XCTAssertEqual(firstLaunch.mode, .legacy)
        XCTAssertEqual(firstLaunch.source, .none)
        XCTAssertNil(firstLaunch.rejection, "legacy by default is not a rejection")

        // Asking for the shadow does not change the mode this launch runs.
        RuntimeModeLaunch.request(RequestedFeatures(shadow: true, v2UI: false, v2Network: false), in: defaults)
        XCTAssertEqual(RuntimeModeLaunch.current(in: defaults).mode, .legacy)

        // The next launch resolves it.
        let secondLaunch = RuntimeModeLaunch.decide(in: defaults, arguments: [], at: fixedDate.addingTimeInterval(60))
        XCTAssertEqual(secondLaunch.mode, .mirroredShadow)
        XCTAssertTrue(secondLaunch.runsShadow)
        XCTAssertNil(secondLaunch.rejection)
        XCTAssertEqual(RuntimeModeLaunch.current(in: defaults).mode, .mirroredShadow)

        // A launch argument overrides the stored request for one launch without persisting it.
        let argumentLaunch = RuntimeModeLaunch.decide(
            in: defaults,
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument],
            at: fixedDate
        )
        XCTAssertEqual(argumentLaunch.mode, .v2Full)
        XCTAssertEqual(argumentLaunch.source, .launchArguments)
        XCTAssertEqual(RuntimeModeLaunch.current(in: defaults).mode, .v2Full)
        XCTAssertEqual(
            RuntimeModeLaunch.storedRequest(in: defaults),
            RequestedFeatures(shadow: true, v2UI: false, v2Network: false),
            "an argument must not overwrite the stored request"
        )
    }

    /// The mode table itself: only the shadow mode observes, and only `v2Full` owns acquisition.
    func testMirroredShadowObservesAndNeverAcquires() throws {
        let modes = try RuntimeMode.allCases.map { mode -> RuntimeMode in
            let resolution = RuntimeModeResolver.resolve(Self.features(for: mode))
            XCTAssertNotNil(resolution.mode)
            return resolution.mode
        }
        XCTAssertEqual(Set(modes), Set(RuntimeMode.allCases))

        XCTAssertFalse(RuntimeMode.mirroredShadow.ownsAcquisition, "there is one owner of acquisition")
        XCTAssertTrue(RuntimeMode.mirroredShadow.runsShadow)
        XCTAssertEqual(
            RuntimeMode.allCases.filter(\.ownsAcquisition),
            [.v2Full],
            "only the full runtime acquires"
        )

        let root = try RuntimeCompositionRoot.compose(
            decision: Self.decision(mode: .mirroredShadow),
            applicationSupportDirectory: tempDirectory.appendingPathComponent("app-support", isDirectory: true)
        )
        guard case .shadowComposed(let directory) = root.outcome else {
            return XCTFail("the shadow mode composes a shadow, got \(root.outcome)")
        }
        XCTAssertNotNil(root.shadow)
        XCTAssertTrue(
            directory.path.hasSuffix("/RuntimeV2/shadow"),
            "the shadow database lives in its own directory, got \(directory.path)"
        )
        XCTAssertEqual(root.shadowDatabase?.location.directory, directory)
        XCTAssertNotEqual(
            directory,
            RuntimeDatabaseLocation.applicationSupport(
                tempDirectory.appendingPathComponent("app-support", isDirectory: true)
            ).directory,
            "and never in the runtime's production directory"
        )
        XCTAssertNil(root.drainShadow()?.budgetBreach)
    }

    // MARK: - Helpers

    private static func features(for mode: RuntimeMode) -> RequestedFeatures {
        switch mode {
        case .legacy: return RequestedFeatures(shadow: false, v2UI: false, v2Network: false)
        case .mirroredShadow: return RequestedFeatures(shadow: true, v2UI: false, v2Network: false)
        case .v2Presentation: return RequestedFeatures(shadow: false, v2UI: true, v2Network: false)
        case .v2Full: return RequestedFeatures(shadow: false, v2UI: true, v2Network: true)
        }
    }

    private static func decision(mode: RuntimeMode) -> RuntimeLaunchDecision {
        let features = Self.features(for: mode)
        return RuntimeLaunchDecision(
            mode: mode,
            requested: features,
            rejection: nil,
            source: .launchArguments,
            decidedAt: Date(timeIntervalSince1970: 1_789_400_000)
        )
    }

    private static let rssFixture = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Example</title><link>https://example.com</link><description>d</description>
          <item>
            <guid>guid-one</guid><title>First article</title>
            <link>https://example.com/one</link><description>Body one</description>
          </item>
          <item>
            <guid>guid-two</guid><title>Second article</title>
            <link>https://example.com/two</link><description>Body two</description>
          </item>
        </channel></rss>
        """
}

// MARK: - Test doubles

/// A clock the test advances, so interval rotation is exercised without waiting.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { self.value = start }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// A resource reading the test controls, so the budget can be exercised without making the test
/// process huge or busy. The last value repeats once the script is exhausted.
private final class ScriptedResourceMeasuring: ShadowResourceMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private let readings: [ShadowResourceReading]
    private var index = 0

    init(_ readings: [ShadowResourceReading]) {
        self.readings = readings.isEmpty ? [.zero] : readings
    }

    func reading() -> ShadowResourceReading {
        lock.lock()
        defer { lock.unlock() }
        let value = readings[min(index, readings.count - 1)]
        index += 1
        return value
    }
}

/// An endpoint that cannot be reached, without a socket: the transport seam PR-15 added is what makes
/// the concurrent path exercisable offline, and its request log is the count the test asserts on.
private actor UnreachableFeedTransport: FeedHTTPTransport {
    private var requests: [String] = []

    func requestedURLs() -> [String] { requests }

    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult {
        requests.append(source.url)
        return FetchHTTPResult(
            data: nil,
            outcome: .failed(URLError(.cannotConnectToHost)),
            updatedValidators: validators,
            canonicalURL: nil
        )
    }
}

/// A counting transport for the "no extra fetch" proof. `URLProtocol` is the only seam a
/// `URLSession` exposes, and it is reached before any socket is opened.
private final class CountingFeedTransport: URLProtocol {
    private static let lock = NSLock()
    /// Guarded by `lock`; `URLProtocol` is instantiated by the loading system, so the count has to
    /// live outside the instance.
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var responseBody = Data()

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset(body: String) {
        lock.lock()
        requests = 0
        responseBody = Data(body.utf8)
        lock.unlock()
    }

    /// A transport whose session never leaves the process, so a stray request cannot reach a network
    /// and would still be counted.
    static func sync() -> FeedHTTPSync {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingFeedTransport.self]
        return FeedHTTPSync(session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CountingFeedTransport.lock.lock()
        CountingFeedTransport.requests += 1
        let body = CountingFeedTransport.responseBody
        CountingFeedTransport.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/rss+xml", "Content-Length": "\(body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
