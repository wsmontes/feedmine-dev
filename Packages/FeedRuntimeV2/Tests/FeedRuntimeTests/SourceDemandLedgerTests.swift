import XCTest
import FeedRuntime

/// PR-14, demand half: the one-refill-per-endpoint rule as a count (ADR-… plan §14, rollout §4).
///
/// The twelve duplicated pairs PR-14 closes are two producers fetching the same endpoint; the evidence
/// the ledger offers is arithmetic, so every test here asserts a count, a grant partition or an
/// in-flight claim, never the ledger's intent. `led` is the only answer that performs a request, so a
/// test that counts `grant.led` across a run is counting refills.
final class SourceDemandLedgerTests: XCTestCase {

    private let endpoints = (0..<5).map { "https://example.test/feed/\($0)" }

    /// The twelve pairs' mechanism as one count: four concurrent consumers issuing 100 demands over 5
    /// endpoints perform exactly 5 refills, one per endpoint, because every later demand for an
    /// endpoint another demand already holds is `shared`.
    func testHundredDemandsFromFourConsumersRefillEachEndpointExactlyOnce() {
        var ledger = SourceDemandLedger()
        // The fake refill: only a `led` endpoint reaches the fetcher, so the closure is invoked once
        // per entry in `grant.led`.
        var refills: [String] = []
        var demandsPerEndpoint: [String: Int] = [:]
        let consumers: [SourceDemandLedger.Purpose] = [
            .bootstrap, .progressiveFetch, .backgroundDrip, .searchSweep,
        ]

        for round in 0..<25 {
            for consumer in 0..<4 {
                let endpoint = endpoints[(round + consumer) % endpoints.count]
                let grant = ledger.demand(
                    [endpoint],
                    purpose: consumers[consumer],
                    atMs: Int64(round * 10 + consumer)
                )
                refills.append(contentsOf: grant.led)
                demandsPerEndpoint[endpoint, default: 0] += 1
                XCTAssertEqual(grant.led.count + grant.shared.count, 1, "one endpoint, one answer")
            }
        }

        XCTAssertEqual(demandsPerEndpoint.values.reduce(0, +), 100, "the fixture drives the run it names")
        XCTAssertEqual(refills.count, endpoints.count, "exactly one refill per endpoint")
        XCTAssertEqual(Set(refills), Set(endpoints), "every endpoint is refilled, none is skipped")
        XCTAssertEqual(refills.count, Set(refills).count, "no endpoint is refilled twice")

        XCTAssertEqual(ledger.counters.demands, 100)
        XCTAssertEqual(ledger.counters.ledRefills, endpoints.count)
        XCTAssertEqual(ledger.counters.sharedRefills, 100 - endpoints.count)
        XCTAssertEqual(ledger.counters.freshSkips, 0)
        XCTAssertEqual(ledger.inFlightCount, endpoints.count, "one claim per refilled endpoint")

        for endpoint in endpoints {
            XCTAssertTrue(ledger.isInFlight(endpoint))
            ledger.finish([endpoint], atMs: 10_000, succeeded: [endpoint])
        }
        XCTAssertEqual(ledger.inFlightCount, 0, "a balanced run leaks no claim")
    }

    /// A second demand for an endpoint already in flight is `shared`, performs no refill, and does not
    /// create a second claim.
    func testSecondDemandWhileInFlightIsSharedAndRefillsNothing() {
        var ledger = SourceDemandLedger()
        let leader = ledger.demand(["a"], purpose: .bootstrap, atMs: 0)
        let joiner = ledger.demand(["a"], purpose: .sourceDetail, atMs: 1)

        XCTAssertEqual(leader.led, ["a"])
        XCTAssertTrue(leader.shared.isEmpty)
        XCTAssertEqual(joiner.shared, ["a"])
        XCTAssertTrue(joiner.led.isEmpty, "a shared demand issues no request")
        XCTAssertTrue(joiner.servedFresh.isEmpty)
        XCTAssertTrue(ledger.isInFlight("a"))
        XCTAssertEqual(ledger.inFlightCount, 1, "two demands, one claim")
        XCTAssertEqual(ledger.counters.ledRefills, 1)
        XCTAssertEqual(ledger.counters.sharedRefills, 1)

        // Mixed order inside one demand: an in-flight endpoint is shared, the rest are led, and both
        // lists keep the order they were asked in.
        let mixed = ledger.demand(["x", "a", "y"], purpose: .coverageMining, atMs: 2)
        XCTAssertEqual(mixed.shared, ["a"])
        XCTAssertEqual(mixed.led, ["x", "y"])
    }

    /// Inside the freshness window a demand is `servedFresh` and refills nothing; past it the endpoint
    /// is led again. The window is inclusive of its edge, and `nil` means "always refill".
    func testFreshnessWindowAnswersServedFreshInsideAndLedOutside() {
        var ledger = SourceDemandLedger()
        let first = ledger.demand(["a"], purpose: .progressiveFetch, atMs: 1_000)
        XCTAssertEqual(first.led, ["a"])
        ledger.finish(first, atMs: 1_000, succeeded: true)

        let inside = ledger.demand(
            ["a"],
            purpose: .sourceDetail,
            atMs: 200_000,
            freshnessWindowMs: 300_000
        )
        XCTAssertEqual(inside.servedFresh, ["a"])
        XCTAssertTrue(inside.led.isEmpty)
        XCTAssertEqual(ledger.counters.freshSkips, 1)

        let atTheEdge = ledger.demand(
            ["a"],
            purpose: .collectionDetail,
            atMs: 301_000,
            freshnessWindowMs: 300_000
        )
        XCTAssertEqual(atTheEdge.servedFresh, ["a"], "the window includes its own edge")
        XCTAssertTrue(atTheEdge.led.isEmpty)

        let outside = ledger.demand(
            ["a"],
            purpose: .sourceDetail,
            atMs: 301_001,
            freshnessWindowMs: 300_000
        )
        XCTAssertEqual(outside.led, ["a"], "past the window the endpoint is refilled")
        XCTAssertTrue(outside.servedFresh.isEmpty)
        ledger.finish(outside, atMs: 301_001, succeeded: true)

        let noWindow = ledger.demand(["a"], purpose: .searchSweep, atMs: 301_002)
        XCTAssertEqual(noWindow.led, ["a"], "a producer that needs current bytes refills regardless")
        XCTAssertTrue(noWindow.servedFresh.isEmpty)
    }

    /// Only an admitted result becomes fresh: a failed refill leaves the endpoint cold, so the next
    /// demand leads it again. The per-endpoint form attributes the outcome endpoint by endpoint.
    func testFailedRefillIsNotFreshAndSucceededRefillIs() {
        var ledger = SourceDemandLedger()
        let failed = ledger.demand(["a"], purpose: .backgroundDrip, atMs: 5_000)
        ledger.finish(failed, atMs: 5_000, succeeded: false)
        XCTAssertNil(ledger.lastRefillAtMs("a"), "a failure is not recency")
        XCTAssertEqual(ledger.inFlightCount, 0)

        let retry = ledger.demand(["a"], purpose: .backgroundDrip, atMs: 5_001, freshnessWindowMs: 900_000)
        XCTAssertEqual(retry.led, ["a"], "a failed refill does not suppress the next attempt")
        ledger.finish(retry, atMs: 5_001, succeeded: true)
        XCTAssertEqual(ledger.lastRefillAtMs("a"), 5_001)

        let served = ledger.demand(
            ["a"],
            purpose: .whatsNewBooster,
            atMs: 6_000,
            freshnessWindowMs: 900_000
        )
        XCTAssertEqual(served.servedFresh, ["a"])

        let partial = ledger.demand(["b", "c"], purpose: .importRefresh, atMs: 10_000)
        XCTAssertEqual(partial.led, ["b", "c"])
        ledger.finish(["b", "c"], atMs: 10_100, succeeded: ["b"])
        XCTAssertEqual(ledger.lastRefillAtMs("b"), 10_100)
        XCTAssertNil(ledger.lastRefillAtMs("c"), "an endpoint whose result was not admitted stays cold")
        XCTAssertEqual(
            ledger.demand(["c"], purpose: .regionSeed, atMs: 10_101, freshnessWindowMs: 60_000).led,
            ["c"]
        )
    }

    /// A led endpoint is released by its own `finish`, and a demand that only ever saw the endpoint as
    /// `shared` cannot release the claim or admit a result for it.
    func testFinishReleasesTheLeadersClaimAndASharedDemandReleasesNothing() {
        var ledger = SourceDemandLedger()
        let leader = ledger.demand(["a"], purpose: .progressiveFetch, atMs: 0)
        let joiner = ledger.demand(["a"], purpose: .sourceDetail, atMs: 10)
        XCTAssertEqual(joiner.shared, ["a"])

        // The joiner led nothing, so its whole-grant finish touches no endpoint.
        ledger.finish(joiner, atMs: 20, succeeded: true)
        XCTAssertTrue(ledger.isInFlight("a"), "a shared demand cannot release another demand's claim")
        XCTAssertNil(ledger.lastRefillAtMs("a"), "a shared demand admits no result of its own")

        ledger.finish(leader, atMs: 30, succeeded: false)
        XCTAssertFalse(ledger.isInFlight("a"))
        XCTAssertNil(ledger.lastRefillAtMs("a"))
    }

    /// A duplicate endpoint is claimed once and `Grant.led` keeps the order it was asked in; empty
    /// entries are no endpoint at all.
    func testDuplicateEndpointsAreClaimedOnceInInputOrder() {
        var ledger = SourceDemandLedger()
        let grant = ledger.demand(["b", "a", "b", "", "c", "a"], purpose: .bootstrap, atMs: 0)
        XCTAssertEqual(grant.led, ["b", "a", "c"], "deduplicated, input order preserved")
        XCTAssertTrue(grant.shared.isEmpty)
        XCTAssertTrue(grant.servedFresh.isEmpty)
        XCTAssertEqual(ledger.inFlightCount, 3)
        XCTAssertEqual(ledger.counters.ledRefills, 3)

        let replay = ledger.demand(["a", "a", "b"], purpose: .searchSweep, atMs: 1)
        XCTAssertEqual(replay.shared, ["a", "b"], "a duplicate of an in-flight endpoint is still one share")
        XCTAssertEqual(ledger.counters.sharedRefills, 2)
        XCTAssertEqual(ledger.counters.demands, 2)
    }

    /// The counters partition the demands: every distinct (demand, endpoint) pair is either led,
    /// shared or served fresh, and nothing else.
    func testCountersAddUpToTheDistinctDemandEndpointPairs() {
        var ledger = SourceDemandLedger()
        let batches: [[String]] = [
            ["a", "b", "a"],
            ["b", "c"],
            ["c", "b"],
            ["d"],
        ]

        let first = ledger.demand(batches[0], purpose: .bootstrap, atMs: 0)
        XCTAssertEqual(first.led, ["a", "b"])
        ledger.finish(first, atMs: 100, succeeded: true)

        let second = ledger.demand(batches[1], purpose: .sourceDetail, atMs: 200, freshnessWindowMs: 1_000)
        XCTAssertEqual(second.led, ["c"])
        XCTAssertEqual(second.servedFresh, ["b"])

        let third = ledger.demand(batches[2], purpose: .collectionDetail, atMs: 300)
        XCTAssertEqual(third.shared, ["c"])
        XCTAssertEqual(third.led, ["b"])

        let fourth = ledger.demand(batches[3], purpose: .regionSeed, atMs: 400)
        XCTAssertEqual(fourth.led, ["d"])

        let distinctPairs = batches.reduce(0) { total, batch in
            total + Set(batch.filter { !$0.isEmpty }).count
        }
        XCTAssertEqual(ledger.counters.demands, batches.count)
        XCTAssertEqual(
            ledger.counters.ledRefills + ledger.counters.sharedRefills + ledger.counters.freshSkips,
            distinctPairs
        )
        XCTAssertEqual(ledger.counters.ledRefills, 5)
        XCTAssertEqual(ledger.counters.sharedRefills, 1)
        XCTAssertEqual(ledger.counters.freshSkips, 1)
    }

    /// `forget` drops the recency, so an invalidated local result is refilled however recent it was.
    func testForgetMakesAnEndpointLeadAgain() {
        var ledger = SourceDemandLedger()
        let grant = ledger.demand(["a"], purpose: .regionSeed, atMs: 0)
        ledger.finish(grant, atMs: 0, succeeded: true)
        XCTAssertEqual(
            ledger.demand(["a"], purpose: .regionSeed, atMs: 10, freshnessWindowMs: 60_000).servedFresh,
            ["a"]
        )

        ledger.forget("a")
        XCTAssertNil(ledger.lastRefillAtMs("a"))
        XCTAssertEqual(
            ledger.demand(["a"], purpose: .regionSeed, atMs: 20, freshnessWindowMs: 60_000).led,
            ["a"]
        )
    }
}
