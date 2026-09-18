import XCTest
import FeedRuntime
@testable import feedmine

/// PR-15, demand half: the background refresh goes through the process's one acquisition pipeline, and
/// the foreground/background pair is closed by counting *requests* rather than by looking at the UI.
///
/// The counter is `RSSFetcher.fetchAttemptCount()`, incremented once per `performFetch` before the
/// transport is asked, plus the transport's own record of what reached it. The demand ledger's counters
/// are read too, but as a separate claim: the ledger counts *decisions* (an endpoint was `shared`), the
/// fetcher counts *requests*, and "no double acquisition" has to be true of the second.
@MainActor
final class BackgroundRefreshDemandTests: XCTestCase {

    private let endpointA = "https://a.example.test/feed.xml"
    private let endpointB = "https://b.example.test/feed.xml"

    private static func rssFixture(guid: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Example</title><link>https://example.com</link><description>d</description>
          <item>
            <guid>\(guid)</guid><title>First article</title>
            <link>https://example.com/\(guid)</link><description>Body one</description>
          </item>
        </channel></rss>
        """
    }

    private func demand(sourceLimit: Int = 6, maxConcurrency: Int = 2) -> BackgroundRefreshDemand {
        BackgroundRefreshDemand(
            sourceLimit: sourceLimit,
            maxConcurrency: maxConcurrency,
            deadline: .seconds(10),
            appliedSignals: []
        )
    }

    /// A store over an in-memory database, with the pinned fetcher the test can count, and `urls`
    /// enabled sources.
    private func makeStore(
        transport: ScriptedFeedTransport,
        urls: [String]
    ) throws -> (store: FeedStore, fetcher: RSSFetcher) {
        let fetcher = RSSFetcher(transport: transport)
        let store = try FeedStore(inMemory: true, fetcher: fetcher)
        store.registry.sources = urls.map {
            FeedSource(title: "Fixture \($0)", url: $0, category: "News")
        }
        for source in store.registry.sources where !store.registry.isSourceEnabled(source.url) {
            store.registry.toggleSource(source.url)
        }
        XCTAssertEqual(
            store.registry.enabledSources.count, urls.count,
            "every fixture source must be enabled for the demand to see it"
        )
        return (store, fetcher)
    }

    // MARK: - No double acquisition

    /// The pair: while a foreground producer holds both endpoints, the background demand issues no
    /// request at all — proved by the fetch counter and by what reached the transport.
    ///
    /// The second half is what makes the zero meaningful: with the claim released, the same demand does
    /// fetch both endpoints, so the counter can move and does.
    func testBackgroundDemandIssuesNoRequestForEndpointsAnotherProducerHolds() async throws {
        let transport = ScriptedFeedTransport()
        let (store, fetcher) = try makeStore(transport: transport, urls: [endpointA, endpointB])

        // The foreground producer claims both endpoints and has not finished: the window the pair is
        // about.
        let held = store.claimSourceDemand([endpointA, endpointB], purpose: .bootstrap)
        XCTAssertEqual(held.led.count, 2, "the foreground owns both endpoints")

        let attemptsBefore = await fetcher.fetchAttemptCount()
        let report = await store.runBackgroundRefreshDemand(demand())

        let attemptsAfterNoop = await fetcher.fetchAttemptCount()
        let requestsAfterNoop = await transport.requests()
        XCTAssertEqual(
            attemptsAfterNoop, attemptsBefore,
            "the background demand attempted no fetch: \(report)"
        )
        XCTAssertEqual(requestsAfterNoop, [], "and nothing reached the transport")
        XCTAssertEqual(report.led, 0)
        XCTAssertEqual(report.shared, 2, "both endpoints were already being refilled")
        XCTAssertEqual(report.attempted, 0)
        XCTAssertTrue(report.issuedNoRequests)
        XCTAssertEqual(store.sourceDemandCounters.sharedRefills, 2, "the ledger counted the sharing")

        // Release the claim: now the demand does fetch, one attempt per endpoint.
        store.finishSourceDemand(held, outcomes: [:])
        let fetched = await store.runBackgroundRefreshDemand(demand())
        let attemptsAfterFetch = await fetcher.fetchAttemptCount()
        let requestsAfterFetch = await transport.requests()
        XCTAssertEqual(
            attemptsAfterFetch, attemptsBefore + 2,
            "with nothing holding them, the demand attempts one fetch per endpoint"
        )
        XCTAssertEqual(requestsAfterFetch.count, 2)
        XCTAssertEqual(fetched.led, 2)
        XCTAssertEqual(fetched.attempted, 2)
    }

    /// The demand is bounded by the budget it was given, not by the size of the enabled set.
    func testBackgroundDemandSpendsOnlyTheBudgetItWasGiven() async throws {
        let urls = (0..<5).map { "https://a\($0).example.test/feed.xml" }
        let transport = ScriptedFeedTransport()
        let (store, fetcher) = try makeStore(transport: transport, urls: urls)

        let report = await store.runBackgroundRefreshDemand(demand(sourceLimit: 2, maxConcurrency: 1))
        XCTAssertEqual(report.led, 2, "two endpoints, not five")
        let attempts = await fetcher.fetchAttemptCount()
        let requests = await transport.requests()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(store.sourcesInFlight, 0, "the demand leaves no claim behind")
    }

    /// What the demand fetched is committed through the same persistence the foreground uses.
    func testBackgroundDemandCommitsThroughTheCommonPipeline() async throws {
        let transport = ScriptedFeedTransport(bodies: [
            endpointA: Self.rssFixture(guid: "a-one"),
            endpointB: Self.rssFixture(guid: "b-one"),
        ])
        let (store, fetcher) = try makeStore(transport: transport, urls: [endpointA, endpointB])

        let report = await store.runBackgroundRefreshDemand(demand())

        XCTAssertEqual(report.led, 2)
        XCTAssertEqual(report.attempted, 2)
        XCTAssertEqual(report.committed, 2, "both fetches succeeded")
        XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.newItems, 2, "one item per source, distinct by guid")
        let attempts = await fetcher.fetchAttemptCount()
        XCTAssertEqual(attempts, 2)
        let persisted = try await store.db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM feed_item")
        }
        XCTAssertEqual(persisted, report.newItems, "every reported item is in the database")
        XCTAssertEqual(
            store.sourceDemandCounters.freshSkips, 0,
            "no freshness window was passed: the demand wants current bytes, not a recent page"
        )
    }

    /// A demand with nothing to do releases nothing and fetches nothing.
    func testDemandWithNoEnabledSourcesIssuesNoRequest() async throws {
        let transport = ScriptedFeedTransport()
        let (store, fetcher) = try makeStore(transport: transport, urls: [])
        let report = await store.runBackgroundRefreshDemand(demand())
        XCTAssertEqual(report, BackgroundRefreshDemandReport())
        let attempts = await fetcher.fetchAttemptCount()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(store.sourcesInFlight, 0)
    }

    // MARK: - Cancellation

    /// Cancelled before it fetched anything: no request, no commit, and no claim left behind. The task
    /// is cancelled while the main actor is still the test's, so the demand's first cancellation check
    /// cannot be raced past.
    func testCancellationBeforeTheFetchLeavesNothingCommittedAndNoClaim() async throws {
        let transport = ScriptedFeedTransport()
        let (store, fetcher) = try makeStore(transport: transport, urls: [endpointA, endpointB])

        // The main actor is still ours when `cancel()` runs, so the demand's body cannot have started;
        // its first cancellation check is therefore deterministic rather than a race.
        let task = Task { await store.runBackgroundRefreshDemand(demand()) }
        task.cancel()
        let report = await task.value

        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.attempted, 0)
        XCTAssertEqual(report.led, 0)
        XCTAssertFalse(report.committedWork)
        let attempts = await fetcher.fetchAttemptCount()
        XCTAssertEqual(attempts, 0, "no request was made")
        XCTAssertEqual(store.sourcesInFlight, 0, "and no endpoint was left claimed")
        XCTAssertEqual(SmartFeedBackgroundScheduler.outcome(for: report), .cancelledBeforeCommit)
        XCTAssertFalse(SmartFeedBackgroundScheduler.outcome(for: report).isSuccess)
    }

    /// Cancelled while a fetch was in flight and already answered: the source counts as committed, so the
    /// outcome is `cancelledAfterCommit` rather than `cancelledBeforeCommit`. The distinction is made from
    /// the store's own counts, not from which path cancelled.
    func testCancellationAfterAFetchWasAnsweredIsReportedAsCommittedThenCancelled() async throws {
        let transport = ScriptedFeedTransport(bodies: [endpointA: Self.rssFixture(guid: "a-one")])
        let (store, fetcher) = try makeStore(transport: transport, urls: [endpointA])
        let box = CancellationBox()
        await transport.setFirstRequestHook { await box.cancelWhenHeld() }

        let task = Task { await store.runBackgroundRefreshDemand(demand(sourceLimit: 1, maxConcurrency: 1)) }
        await box.hold(task)
        let report = await task.value

        // `committed` is the store's own count of endpoints whose fetch succeeded, and it is what decides
        // the outcome. Whether the *write* of that batch landed is GRDB's cancellation behaviour, which is
        // why the durable half of this rule is proved by the test below rather than here.
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.attempted, 1, "the fetch was answered")
        XCTAssertEqual(report.committed, 1, "and the ledger records that endpoint as refilled")
        XCTAssertTrue(report.committedWork)
        let attempts = await fetcher.fetchAttemptCount()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(
            SmartFeedBackgroundScheduler.outcome(for: report),
            .cancelledAfterCommit(sources: 1, newItems: report.newItems)
        )
        XCTAssertEqual(
            store.sourcesInFlight, 0,
            "a cancelled demand releases every claim it held, so the endpoint is refillable again"
        )
    }

    /// The durable half of the same rule: a commit that already completed is not rolled back by a later
    /// cancellation. The first demand's content is still in the database and its endpoint is still
    /// recorded as refilled, while the second demand committed nothing.
    func testCancellationDoesNotRollBackACommitThatAlreadyCompleted() async throws {
        let transport = ScriptedFeedTransport(bodies: [endpointA: Self.rssFixture(guid: "a-one")])
        let (store, fetcher) = try makeStore(transport: transport, urls: [endpointA])

        let committed = await store.runBackgroundRefreshDemand(demand(sourceLimit: 1, maxConcurrency: 1))
        XCTAssertEqual(committed.newItems, 1)
        let persistedBefore = try await store.db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM feed_item")
        }
        XCTAssertEqual(persistedBefore, 1)

        let task = Task { await store.runBackgroundRefreshDemand(demand(sourceLimit: 1, maxConcurrency: 1)) }
        task.cancel()
        let cancelled = await task.value

        XCTAssertTrue(cancelled.cancelled)
        XCTAssertFalse(cancelled.committedWork)
        let persistedAfter = try await store.db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM feed_item")
        }
        XCTAssertEqual(
            persistedAfter, persistedBefore,
            "the completed commit is untouched by the cancellation"
        )
        // The endpoint the first demand refilled is still recorded as refilled: a cancelled run does not
        // forget it, and a fresh demand would still fetch it because no freshness window is passed.
        let attempts = await fetcher.fetchAttemptCount()
        XCTAssertEqual(attempts, 1, "the cancelled run made no attempt")
    }
}

// MARK: - Test doubles

/// Counts requests, answers a scripted body per endpoint, and runs a hook on the first request — the
/// hook is how a test cancels the demand at the point the system's expiration handler would.
///
/// An actor rather than a locked class: the protocol is `Sendable`, and a shared mutable request log is
/// exactly what an actor is for. A test that wants the count awaits it instead of reading a lock.
private actor ScriptedFeedTransport: FeedHTTPTransport {
    private var requestLog: [String] = []
    private let bodies: [String: String]
    private var firstRequestHook: (@Sendable () async -> Void)?

    init(bodies: [String: String] = [:]) {
        self.bodies = bodies
    }

    func setFirstRequestHook(_ hook: @escaping @Sendable () async -> Void) {
        firstRequestHook = hook
    }

    func requests() -> [String] { requestLog }

    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult {
        requestLog.append(source.url)
        if requestLog.count == 1, let hook = firstRequestHook {
            firstRequestHook = nil
            await hook()
        }
        guard let body = bodies[source.url] else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(URLError(.cannotConnectToHost)),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }
        let data = Data(body.utf8)
        return FetchHTTPResult(
            data: data,
            outcome: .success(data),
            updatedValidators: validators,
            canonicalURL: source.url
        )
    }
}

/// Holds the demand task so a transport hook can cancel it at a point the test controls. Either order of
/// `hold` and `cancelWhenHeld` produces the same result, which is what keeps the test deterministic.
private actor CancellationBox {
    private var task: Task<BackgroundRefreshDemandReport, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func hold(_ task: Task<BackgroundRefreshDemandReport, Never>) {
        self.task = task
        waiter?.resume()
        waiter = nil
    }

    func cancelWhenHeld() async {
        if task == nil {
            await withCheckedContinuation { waiter = $0 }
        }
        task?.cancel()
    }
}
