import XCTest
@testable import FeedDomain
@testable import FeedRuntime

/// The exposure rules of ADR-007 as behaviour: what grants `seen`, what does not, and what a rerender,
/// a background transition or a fast fling leave behind.
///
/// The clock is injected and every test states the instant it wants: there is no sleep and no wall
/// clock anywhere. "Facts" here are the batches `drain()` hands to the caller; whether they become rows
/// is the storage tests' subject.
final class ExposureTrackerTests: XCTestCase {
    private func tracker(
        clock: TestMonotonicClock,
        policy: ExposurePolicy = .baseline,
        intervalLimit: Int = ExposureTracker.Configuration.baselineIntervalLimit
    ) throws -> ExposureTracker {
        ExposureTracker(
            edition: try EditionID(4),
            scope: .main,
            clock: clock,
            configuration: try ExposureTracker.Configuration(
                policy: policy,
                maximumTrackedIntervals: intervalLimit
            )
        )
    }

    private func card(_ value: Int64) throws -> PublicationCardID {
        try PublicationCardID(value)
    }

    private func observation(
        _ cardID: PublicationCardID,
        _ fraction: Double,
        _ edge: ViewportObservation.Edge,
        direction: Int = 0
    ) throws -> ViewportObservation {
        try ViewportObservation(cardID: cardID, visibleFraction: fraction, edge: edge, direction: direction)
    }

    // MARK: - D1: what grants seen

    /// 50% for one second, both from the policy version: a shorter or smaller interval grants nothing.
    func testSeenRequiresTheFractionAndTheDwell() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(1)

        tracker.submitViewport(try observation(id, 0.9, .entered))       // t=0
        clock.advance(500)
        tracker.submitViewport(try observation(id, 0.9, .sample))        // t=500, credited 500
        XCTAssertEqual(tracker.interval(forCardID: id)?.seenRecorded, false)
        XCTAssertEqual(tracker.interval(forCardID: id)?.creditedDwellMs, 500)

        clock.advance(600)
        tracker.submitViewport(try observation(id, 0.9, .sample))        // t=1100, credited 1100
        XCTAssertEqual(tracker.interval(forCardID: id)?.seenRecorded, true)

        let facts = tracker.drain()
        XCTAssertEqual(facts.map(\.type), [.viewportEntered, .seen])
        let seen = try XCTUnwrap(facts.last)
        XCTAssertEqual(seen.dwellMs, 1100)
        XCTAssertEqual(seen.visitOrdinal, 0)
        XCTAssertEqual(seen.maxVisibleFraction, 0.9)
        XCTAssertEqual(seen.policyVersion, ExposurePolicy.baseline.version)
        XCTAssertEqual(seen.scope, .main)
    }

    /// A card that is below the threshold the whole time is never credited: the interval closes with
    /// no dwell at all, which is how "credit starts when the card qualifies" is observable.
    func testACardBelowTheThresholdEarnsNothing() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(2)

        tracker.submitViewport(try observation(id, 0.4, .entered))   // t=0, under the threshold
        clock.advance(5000)
        tracker.submitViewport(try observation(id, 0.4, .left))      // t=5000

        let facts = tracker.drain()
        XCTAssertEqual(facts.map(\.type), [.viewportEntered, .viewportLeft])
        XCTAssertNil(facts.last?.dwellMs, "no qualifying window, so no credited dwell")
        XCTAssertEqual(facts.filter { $0.type == .seen }.count, 0)
        XCTAssertEqual(tracker.interval(forCardID: id)?.creditedDwellMs ?? -1, -1, "the interval is closed")
    }

    /// A fling: many crossings, no dwell, zero `seen`.
    func testFastFlingCrossesCentersAndGrantsNoSeen() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)

        for value in 1...10 {
            let id = try card(Int64(value))
            tracker.submitViewport(try observation(id, 0.2, .entered))
            clock.advance(20)
            tracker.centerCrossed(cardID: id, direction: 1)
            tracker.submitViewport(try observation(id, 0.0, .left))
            clock.advance(20)
        }

        let facts = tracker.drain()
        XCTAssertEqual(facts.filter { $0.type == .seen }.count, 0, "a fling never grants seen")
        XCTAssertEqual(facts.filter { $0.type == .centerCrossed }.count, 10)
        XCTAssertEqual(facts.filter { $0.type == .viewportEntered }.count, 10)
        XCTAssertEqual(facts.filter { $0.type == .viewportLeft }.count, 10)
        XCTAssertTrue(facts.filter { $0.type == .centerCrossed }.allSatisfy { $0.dwellMs == nil })
    }

    // MARK: - D3: the view's life is not the interval's life

    /// The named contract of plan §19 #24: a rerender produces nothing, does not restart credited dwell
    /// and cannot duplicate the `seen` that was already recorded.
    func testRerenderDoesNotDuplicateExposure() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(3)

        tracker.submitViewport(try observation(id, 0.9, .entered))   // t=0
        clock.advance(1100)                                          // t=1100
        tracker.submitViewport(try observation(id, 0.9, .sample))
        XCTAssertEqual(tracker.interval(forCardID: id)?.seenRecorded, true)
        let afterFirstSeen = tracker.stats.emittedFacts

        // The rerender: the cell goes away and comes back, with no viewport observation at all.
        clock.advance(50)                                            // t=1150
        tracker.viewDisappeared(cardID: id)
        tracker.viewAppeared(cardID: id)
        XCTAssertEqual(
            tracker.stats.emittedFacts,
            afterFirstSeen,
            "a rerender writes no fact"
        )
        XCTAssertEqual(tracker.interval(forCardID: id)?.seenRecorded, true)
        XCTAssertEqual(tracker.interval(forCardID: id)?.creditedDwellMs, 1100, "dwell is not restarted")

        // The card stays visible for another second: still one visit, still one seen.
        clock.advance(1000)                                          // t=2150
        tracker.submitViewport(try observation(id, 0.9, .sample))
        tracker.viewAppeared(cardID: id)

        let facts = tracker.drain()
        XCTAssertEqual(facts.filter { $0.type == .seen }.count, 1)
        XCTAssertEqual(facts.filter { $0.type == .viewportEntered }.count, 1)
        XCTAssertEqual(tracker.interval(forCardID: id)?.creditedDwellMs, 2150)
        XCTAssertEqual(tracker.trackedCardCount, 1, "one card, one visit")
    }

    /// `onAppear` is not exposure: it does not open an interval, does not start credit and writes
    /// nothing, however long the view is on screen.
    func testOnAppearNeverBecomesExposure() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(4)

        tracker.viewAppeared(cardID: id)
        clock.advance(60_000)
        tracker.viewDisappeared(cardID: id)

        XCTAssertEqual(tracker.drain(), [])
        XCTAssertEqual(tracker.activeIntervalCount, 0)
        XCTAssertEqual(tracker.stats.emittedFacts, 0)
    }

    // MARK: - D2: coalescing

    func testViewportSamplesAreCoalescedWithTheInjectedClock() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(5)

        tracker.submitViewport(try observation(id, 0.9, .entered))    // accepted at t=0
        clock.advance(10)
        tracker.submitViewport(try observation(id, 0.9, .sample))     // folded
        clock.advance(30)
        tracker.submitViewport(try observation(id, 0.9, .sample))     // folded
        clock.advance(40)                                             // t=80
        tracker.submitViewport(try observation(id, 0.9, .sample))     // accepted (80 >= 75)

        XCTAssertEqual(tracker.stats.coalescedSamples, 2)
        XCTAssertEqual(tracker.stats.acceptedSamples, 2)
        XCTAssertEqual(tracker.interval(forCardID: id)?.creditedDwellMs, 80)

        // A threshold crossing is a transition and is never folded, even inside the window.
        clock.advance(5)                                              // t=85
        tracker.submitViewport(try observation(id, 0.1, .sample))
        XCTAssertEqual(tracker.stats.crossThresholdTransitions, 1)
        XCTAssertNil(tracker.interval(forCardID: id), "below the threshold the interval closes")

        let facts = tracker.drain()
        XCTAssertEqual(facts.last?.type, .viewportLeft)
        XCTAssertEqual(facts.last?.closeReason, .leftViewport)
        XCTAssertEqual(facts.last?.dwellMs, 85)
    }

    // MARK: - Closures

    /// Background ends the interval, credits only up to the last sample, and does not invent `seen`.
    func testBackgroundEndsTheIntervalWithCreditedDwellOnly() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(6)

        tracker.submitViewport(try observation(id, 0.9, .entered))   // t=0
        clock.advance(600)
        tracker.submitViewport(try observation(id, 0.9, .sample))    // t=600
        clock.advance(300)                                           // t=900: background
        tracker.endIntervals(reason: .background)

        let facts = tracker.drain()
        XCTAssertEqual(facts.map(\.type), [.viewportEntered, .viewportLeft])
        XCTAssertEqual(facts.last?.closeReason, .background)
        XCTAssertEqual(facts.last?.dwellMs, 600, "unsampled time after the last sample is not credited")
        XCTAssertEqual(facts.filter { $0.type == .seen }.count, 0)
        XCTAssertEqual(tracker.activeIntervalCount, 0)
    }

    /// Eviction closes the interval as `windowEvicted`; the dwell is the credited one, never more.
    func testWindowEvictionClosesTheIntervalAtItsLastSample() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(7)

        tracker.submitViewport(try observation(id, 0.9, .entered))   // t=0
        clock.advance(400)
        tracker.submitViewport(try observation(id, 0.9, .sample))    // t=400
        clock.advance(5000)                                          // t=5400
        tracker.cardsEvicted([id])

        let facts = tracker.drain()
        XCTAssertEqual(facts.last?.type, .viewportLeft)
        XCTAssertEqual(facts.last?.closeReason, .windowEvicted)
        XCTAssertEqual(facts.last?.dwellMs, 400)
        XCTAssertEqual(facts.filter { $0.type == .seen }.count, 0)
    }

    /// A reboot between samples stops the arithmetic: the interval ends at the last sample of the old
    /// boot session and `seen` is not granted from across the boundary (D15).
    func testBootSessionResetClosesWithoutInventingSeen() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(8)

        tracker.submitViewport(try observation(id, 0.9, .entered))   // boot-1, t=0
        clock.advance(400)
        tracker.submitViewport(try observation(id, 0.9, .sample))    // boot-1, t=400

        clock.reboot(to: "boot-2", atMillis: 10)
        tracker.submitViewport(try observation(id, 0.9, .sample))

        XCTAssertEqual(tracker.stats.bootSessionResets, 1)
        let facts = tracker.drain()
        XCTAssertEqual(facts.map(\.type), [.viewportEntered, .viewportLeft])
        XCTAssertEqual(facts.last?.closeReason, .background)
        XCTAssertEqual(facts.last?.dwellMs, 400)
        XCTAssertEqual(facts.filter { $0.type == .seen }.count, 0)
    }

    // MARK: - D5/D7/D8: distinct facts, identity, revisits

    /// Center crossing is a separate, weaker fact: it is recorded with its direction, may repeat per
    /// direction, and never grants `seen`.
    func testCenterCrossingIsASeparateWeakerFact() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(9)

        // Never materialized: no interval, so no fact at all (H-02).
        tracker.centerCrossed(cardID: id, direction: 1)
        XCTAssertEqual(tracker.drain(), [])

        tracker.submitViewport(try observation(id, 0.9, .entered))
        tracker.centerCrossed(cardID: id, direction: 1)
        tracker.centerCrossed(cardID: id, direction: 1)      // same edge: a duplicate observation
        tracker.centerCrossed(cardID: id, direction: -1)      // the other edge: a distinct fact

        XCTAssertEqual(tracker.stats.duplicateObservations, 1)
        let facts = tracker.drain()
        XCTAssertEqual(facts.filter { $0.type == .centerCrossed }.map(\.direction), [1, -1])
        XCTAssertEqual(facts.filter { $0.type == .seen }.count, 0)
        XCTAssertNotEqual(
            facts[1].factKey,
            facts[2].factKey,
            "the direction is part of the key (ADR-007 D7)"
        )
    }

    /// A revisit is a new visit with its own interval, and `seen` stays once per visit.
    func testRevisitIsANewVisitAndSeenIsOncePerVisit() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(10)

        tracker.submitViewport(try observation(id, 0.9, .entered))
        clock.advance(1100)
        tracker.submitViewport(try observation(id, 0.9, .sample))     // seen, visit 0
        clock.advance(100)
        tracker.submitViewport(try observation(id, 0.0, .left))       // mixed: closes visit 0
        clock.advance(5000)
        tracker.submitViewport(try observation(id, 0.9, .entered))    // visit 1
        clock.advance(1100)
        tracker.submitViewport(try observation(id, 0.9, .sample))     // seen, visit 1

        let facts = tracker.drain()
        let seenVisits = facts.filter { $0.type == .seen }.map(\.visitOrdinal)
        XCTAssertEqual(seenVisits, [0, 1])
        XCTAssertNotEqual(
            facts.filter { $0.type == .seen }[0].factKey,
            facts.filter { $0.type == .seen }[1].factKey
        )
        XCTAssertEqual(facts.filter { $0.type == .viewportEntered }.map(\.visitOrdinal), [0, 1])
        XCTAssertEqual(tracker.trackedCardCount, 1)
    }

    /// `opened`, `read` and `bookmarked` are distinct facts, each keyed by its own rule, and replaying
    /// one is a no-op instead of a second fact.
    func testDurableFactsAreDistinctAndReplayIsIdempotent() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(11)

        tracker.opened(cardID: id)
        tracker.opened(cardID: id)                                  // replay: same edition, same key
        tracker.read(cardID: id, operationID: "op-read-1")
        tracker.read(cardID: id, operationID: "op-read-1")
        tracker.bookmarked(cardID: id, wanted: true, operationID: "op-bookmark-1")
        tracker.bookmarked(cardID: id, wanted: false, operationID: "op-bookmark-2")

        XCTAssertEqual(tracker.stats.duplicateObservations, 2)
        let facts = tracker.drain()
        XCTAssertEqual(facts.map(\.type), [.opened, .read, .bookmarked, .bookmarkRemoved])
        XCTAssertEqual(facts.allSatisfy { $0.visitOrdinal == 0 }, true)
        XCTAssertEqual(facts[1].userStateOperationID, "op-read-1")
        XCTAssertEqual(facts[2].userStateOperationID, "op-bookmark-1")
        XCTAssertTrue(facts[0].factKey.contains("event:opened"))
        XCTAssertTrue(facts[0].factKey.contains("scope:main"))
        XCTAssertFalse(facts[0].factKey.contains("visit:"), "opened is once per edition, not per visit")
        XCTAssertEqual(
            facts[3].factKey,
            "card:\(id.rawValue)|event:bookmarkRemoved|source:op-bookmark-2"
        )
    }

    /// The identity key distinguishes the visit, the direction and the durable operation: two facts of
    /// the same type are distinct only when they are really distinct.
    func testFactKeysFollowTheIdempotencyRule() throws {
        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock)
        let id = try card(12)

        tracker.submitViewport(try observation(id, 0.9, .entered))
        let facts = tracker.drain()
        XCTAssertEqual(
            facts[0].factKey,
            "edition:4|card:12|scope:main|ref:|visit:0|event:viewportEntered"
        )
    }

    // MARK: - Bounds

    /// Memory is asserted as counts: the tracked intervals are bounded by the window's reference limit,
    /// and the unconfirmed batch never grows past what the flush policy owes.
    func testTrackerBoundsIntervalsAndPendingFacts() throws {
        XCTAssertEqual(ExposureTracker.Configuration.baseline.maximumTrackedIntervals, 72)

        let clock = TestMonotonicClock()
        var tracker = try tracker(clock: clock, intervalLimit: 8)

        for value in 1...8 {
            tracker.submitViewport(try observation(try card(Int64(value)), 0.9, .entered))
        }
        XCTAssertEqual(tracker.activeIntervalCount, 8)
        tracker.submitViewport(try observation(try card(99), 0.9, .entered))
        XCTAssertEqual(tracker.activeIntervalCount, 8, "the interval limit holds")
        XCTAssertEqual(tracker.stats.refusedIntervals, 1)

        var drained = 0
        // Every card is closed again, so the interval limit is never the reason a fact is missing.
        tracker.endIntervals(reason: .sessionEnd)
        _ = tracker.drain()
        for value in 1...30 {
            let id = try card(Int64(200 + value))
            tracker.submitViewport(try observation(id, 0.9, .entered))
            clock.advance(1100)
            tracker.submitViewport(try observation(id, 0.9, .sample))
            clock.advance(100)
            tracker.submitViewport(try observation(id, 0.0, .left))
            drained += tracker.drainAtMilestone().count
            XCTAssertLessThanOrEqual(
                tracker.pendingFactCount,
                ExposurePolicy.baseline.flushFactCount,
                "the milestone keeps the unconfirmed batch bounded"
            )
            XCTAssertLessThanOrEqual(tracker.activeIntervalCount, 8)
        }
        drained += tracker.drain().count
        XCTAssertEqual(drained, 30 * 3, "one entry, one seen and one left per card")
    }

    /// A policy is versioned: the same observation sequence produces different facts under two
    /// versions, and each fact says which version produced it (ADR-007 D1).
    func testPolicyIsVersionedAndEveryFactCarriesIt() throws {
        let tight = try ExposurePolicy(
            version: "exposure-v1-tight",
            minVisibleFraction: 0.75,
            minDwellMs: 2000,
            coalesceWindowMs: 50,
            flushFactCount: 20,
            flushIntervalMs: 500
        )
        let clock = TestMonotonicClock()
        var baseline = try tracker(clock: clock)
        var strict = try tracker(clock: clock, policy: tight)
        let id = try card(13)

        baseline.submitViewport(try observation(id, 0.8, .entered))    // t=0
        strict.submitViewport(try observation(id, 0.8, .entered))
        clock.advance(1100)                                            // t=1100
        baseline.submitViewport(try observation(id, 0.8, .sample))
        strict.submitViewport(try observation(id, 0.8, .sample))

        XCTAssertEqual(baseline.interval(forCardID: id)?.seenRecorded, true, "50%/1000ms grants it")
        XCTAssertEqual(strict.interval(forCardID: id)?.seenRecorded, false, "75%/2000ms does not yet")

        clock.advance(1000)                                            // t=2100
        strict.submitViewport(try observation(id, 0.8, .sample))

        let baselineSeen = try XCTUnwrap(baseline.drain().last { $0.type == .seen })
        let strictSeen = try XCTUnwrap(strict.drain().last { $0.type == .seen })
        XCTAssertEqual(baselineSeen.dwellMs, 1100)
        XCTAssertEqual(baselineSeen.policyVersion, ExposurePolicy.baseline.version)
        XCTAssertEqual(strictSeen.dwellMs, 2100)
        XCTAssertEqual(strictSeen.policyVersion, "exposure-v1-tight")
        XCTAssertEqual(
            baselineSeen.factKey,
            strictSeen.factKey,
            "the idempotency key is the observation, not the policy: dedup must survive a policy change"
        )
        XCTAssertNotEqual(baselineSeen.dwellMs, strictSeen.dwellMs)
    }
}
