import FeedDomain
import FeedRuntime
import Foundation
import XCTest
import os

/// A clock a test moves by hand. Nothing in these tests sleeps: latency is the difference between two
/// instants the test states (plan §12 requires an injected clock).
final class RunwayTestClock: EditorialClock, Sendable {
    private let instant: OSAllocatedUnfairLock<Date>

    init(start: Date = RunwayFixture.instant) {
        self.instant = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { instant.withLock { $0 } }

    @discardableResult
    func advance(by seconds: TimeInterval) -> Date {
        instant.withLock {
            $0 = $0.addingTimeInterval(seconds)
            return $0
        }
    }
}

/// Fixtures shared by the three Runway test files (the trio is one deliverable, and the doubles live
/// here because the estimator is the lowest of the three).
enum RunwayFixture {
    static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    static func edition(_ raw: Int64 = 1) throws -> EditionID { try EditionID(raw) }

    static func card(_ raw: Int64) throws -> PublicationCardID { try PublicationCardID(raw) }

    static func context(_ scope: String = "main") throws -> ContextKey {
        try ContextKey(surface: .main, scopeKey: scope, planIdentity: "plan-main")
    }

    static func observation(
        edition: EditionID,
        lastVisible: Int,
        materializedTail: Int,
        speed: Double = 0,
        firstVisible: Int? = nil,
        decodedCount: Int = 0,
        decodedBytes: Int = 0,
        at: Date = RunwayFixture.instant
    ) -> RunwayViewportObservation {
        RunwayViewportObservation(
            editionID: edition,
            firstVisibleOrdinal: firstVisible ?? lastVisible,
            lastVisibleOrdinal: lastVisible,
            materializedTailOrdinal: materializedTail,
            decodedCount: decodedCount,
            decodedBytes: decodedBytes,
            speed: speed,
            sampledAt: at
        )
    }

    static func reference(edition: EditionID, ordinal: Int) throws -> FeedWindowReference {
        FeedWindowReference(
            cardID: try card(Int64(ordinal + 1)),
            absoluteOrdinal: ordinal,
            editionID: edition,
            estimatedHeight: 100,
            decodedByteEstimate: 1_024
        )
    }
}

final class RunwayEstimatorTests: XCTestCase {
    private func estimator(policy: RunwayPolicy = .baseline) -> RunwayEstimator {
        RunwayEstimator(policy: policy)
    }

    // MARK: the cheap estimate

    /// A fling is the three terms at once: absolute speed, the distance left, and how slow refills
    /// have been lately — with the direction derived from the ordinals, not from the renderer.
    func testAFlingRaisesPressureThroughSpeedDistanceAndLatency() async throws {
        let edition = try RunwayFixture.edition()
        var sut = estimator()
        sut.recordReplenishmentLatency(milliseconds: 450)

        _ = sut.observe(RunwayFixture.observation(edition: edition, lastVisible: 10, materializedTail: 40))
        let estimate = sut.observe(
            RunwayFixture.observation(edition: edition, lastVisible: 38, materializedTail: 40, speed: 6_000)
        )

        XCTAssertEqual(estimate.direction, .towardTail)
        XCTAssertEqual(estimate.distance, 2)
        XCTAssertEqual(estimate.speedPressure, 1, "6 000 pt/s saturates the 4 000 pt/s reference")
        XCTAssertEqual(estimate.distancePressure, 22.0 / 24.0, accuracy: 1e-12)
        XCTAssertEqual(estimate.latencyPressure, 0.5, "450 ms is halfway past the 150 ms reference")
        let expectedRaw = 0.35 + 0.40 * (22.0 / 24.0) + 0.25 * 0.5
        XCTAssertEqual(estimate.raw, expectedRaw, accuracy: 1e-12)
        XCTAssertEqual(estimate.pressure, expectedRaw, accuracy: 1e-12)
        XCTAssertEqual(estimate.level, .strained)
        XCTAssertEqual(estimate.p95ReplenishmentLatencyMilliseconds, 450)
    }

    func testPressureIsClampedToTheStatedFloorAndCeiling() async throws {
        let edition = try RunwayFixture.edition()
        var quiet = estimator()
        let head = quiet.observe(RunwayFixture.observation(edition: edition, lastVisible: 2, materializedTail: 900))
        XCTAssertEqual(head.pressure, RunwayPolicy.baseline.floor, "a stated floor, not zero")

        var loud = estimator()
        for _ in 0 ..< 8 { loud.recordReplenishmentLatency(milliseconds: 60_000) }
        _ = loud.observe(RunwayFixture.observation(edition: edition, lastVisible: 0, materializedTail: 40))
        let pinned = loud.observe(
            RunwayFixture.observation(edition: edition, lastVisible: 40, materializedTail: 40, speed: 20_000)
        )
        XCTAssertGreaterThan(pinned.raw, RunwayPolicy.baseline.ceiling)
        XCTAssertEqual(pinned.pressure, RunwayPolicy.baseline.ceiling, "the ceiling caps the request")
    }

    /// The hysteresis band is not decoration: the raw estimate crosses the escalation threshold on half
    /// the samples, and the level still changes once. Without the band this count would climb with the
    /// number of samples.
    func testHysteresisDoesNotOscillateAroundTheEscalationThreshold() async throws {
        let edition = try RunwayFixture.edition()
        var sut = estimator()
        let threshold = RunwayPolicy.baseline.escalationThreshold

        var crossings = 0
        var transitions = 0
        for step in 0 ..< 100 {
            // A stationary viewport with a tail that advances by one card and back: distance 9 puts the
            // raw estimate exactly at the escalation threshold, distance 10 puts it inside the band,
            // above the de-escalation threshold.
            let tail = step.isMultiple(of: 2) ? 49 : 50
            let estimate = sut.observe(
                RunwayFixture.observation(edition: edition, lastVisible: 40, materializedTail: tail, speed: 4_000)
            )
            if estimate.raw >= threshold { crossings += 1 }
            if estimate.levelChanged { transitions += 1 }
        }

        XCTAssertEqual(crossings, 50, "the estimate rode the threshold half the time")
        XCTAssertEqual(transitions, 1, "and the level changed exactly once")
        XCTAssertEqual(sut.levelTransitions, 1)
        XCTAssertEqual(sut.level, .strained)
    }

    func testAReversalDiscountsTheSpeedTermWithoutFlappingTheLevel() async throws {
        let edition = try RunwayFixture.edition()
        var sut = estimator()
        for _ in 0 ..< 8 { sut.recordReplenishmentLatency(milliseconds: 3_000) }
        _ = sut.observe(RunwayFixture.observation(edition: edition, lastVisible: 30, materializedTail: 42))

        let forward = sut.observe(
            RunwayFixture.observation(edition: edition, lastVisible: 40, materializedTail: 42, speed: 4_000)
        )
        XCTAssertEqual(forward.direction, .towardTail)
        XCTAssertEqual(forward.pressure, RunwayPolicy.baseline.ceiling)

        let reversed = sut.observe(
            RunwayFixture.observation(edition: edition, lastVisible: 38, materializedTail: 42, speed: 4_000)
        )
        XCTAssertEqual(reversed.direction, .towardHead)
        XCTAssertEqual(
            reversed.pressure,
            0.35 * RunwayPolicy.baseline.reversalDiscount + 0.40 * (20.0 / 24.0) + 0.25,
            accuracy: 1e-12
        )
        XCTAssertLessThan(reversed.pressure, forward.pressure)
        XCTAssertGreaterThan(reversed.pressure, RunwayPolicy.baseline.deescalationThreshold)
        XCTAssertEqual(reversed.level, .strained, "the reversal does not flap the level")
        XCTAssertEqual(sut.levelTransitions, 1, "one transition: forward escalated, the reversal did not")
    }

    // MARK: latency window

    func testP95FollowsTheRecentWindowAndDropsOldSamples() async throws {
        var mutable = estimator()
        for millisecond in 100 ... 199 {
            mutable.recordReplenishmentLatency(milliseconds: Double(millisecond))
        }

        XCTAssertEqual(mutable.replenishmentLatencies.count, 64, "the sample window is bounded")
        XCTAssertEqual(mutable.replenishmentLatencies.first, 136, "the oldest samples left")
        XCTAssertEqual(mutable.p95ReplenishmentLatencyMilliseconds, 196)

        for _ in 0 ..< 64 { mutable.recordReplenishmentLatency(milliseconds: 5_000) }
        XCTAssertEqual(mutable.p95ReplenishmentLatencyMilliseconds, 5_000, "a slower network raises it")

        let untouched = estimator()
        XCTAssertNil(untouched.p95ReplenishmentLatencyMilliseconds, "no measurement, no percentile")
    }

    func testTheSameViewportEstimatesHigherWhenReplenishmentHasBeenSlow() async throws {
        let edition = try RunwayFixture.edition()
        var fast = estimator()
        fast.recordReplenishmentLatency(milliseconds: 150)
        _ = fast.observe(RunwayFixture.observation(edition: edition, lastVisible: 0, materializedTail: 40))
        let fastEstimate = fast.observe(
            RunwayFixture.observation(edition: edition, lastVisible: 36, materializedTail: 40, speed: 2_000)
        )

        var slow = estimator()
        for _ in 0 ..< 4 { slow.recordReplenishmentLatency(milliseconds: 750) }
        _ = slow.observe(RunwayFixture.observation(edition: edition, lastVisible: 0, materializedTail: 40))
        let slowEstimate = slow.observe(
            RunwayFixture.observation(edition: edition, lastVisible: 36, materializedTail: 40, speed: 2_000)
        )

        XCTAssertEqual(fastEstimate.pressure, 0.40 * (20.0 / 24.0) + 0.35 * 0.5, accuracy: 1e-12)
        XCTAssertEqual(slowEstimate.pressure, 0.40 * (20.0 / 24.0) + 0.35 * 0.5 + 0.25, accuracy: 1e-12)
        XCTAssertEqual(fastEstimate.level, .comfortable)
        XCTAssertEqual(slowEstimate.level, .strained, "the same scroll is strained on a slow link")
    }

    // MARK: five stocks

    /// The five stocks are never added together: an archive a hundred times larger changes neither the
    /// distance nor the decision, and an empty sequenceable pool is reported as empty while the archive
    /// is full.
    func testTheFiveStocksAreKeptSeparateAndNeverSummed() async throws {
        let edition = try RunwayFixture.edition()
        var sut = estimator()
        sut.apply(
            RunwaySupplyObservation(
                canonical: RunwayStockAmount(count: 100_000, bytes: nil),
                sequenceable: RunwayStockAmount(count: 0, bytes: nil),
                mediaPrepared: RunwayStockAmount(count: 12, bytes: 4_096),
                published: RunwayStockAmount(count: 33, bytes: nil),
                supplyGeneration: 7,
                examinedRows: 96
            )
        )
        _ = sut.observe(
            RunwayFixture.observation(
                edition: edition,
                lastVisible: 28,
                materializedTail: 32,
                decodedCount: 3,
                decodedBytes: 2_048
            )
        )

        XCTAssertEqual(sut.stocks.canonical.count, 100_000)
        XCTAssertEqual(sut.stocks.sequenceable.count, 0, "a full archive is not sequenceable supply")
        XCTAssertEqual(sut.stocks.mediaPrepared.count, 12)
        XCTAssertEqual(sut.stocks.mediaPrepared.bytes, 4_096)
        XCTAssertEqual(sut.stocks.published.count, 33, "published is its own stock, not a sum")
        XCTAssertEqual(sut.stocks.decoded.count, 3)
        XCTAssertEqual(sut.stocks.decoded.bytes, 2_048)
        XCTAssertTrue(sut.stocks.sequenceable.isEmpty)

        var biggerArchive = estimator()
        biggerArchive.apply(
            RunwaySupplyObservation(
                canonical: RunwayStockAmount(count: 200_000, bytes: nil),
                sequenceable: RunwayStockAmount(count: 0, bytes: nil),
                mediaPrepared: RunwayStockAmount(count: 12, bytes: 4_096),
                published: RunwayStockAmount(count: 33, bytes: nil),
                supplyGeneration: 8,
                examinedRows: 96
            )
        )
        var same = estimator()
        same.apply(
            RunwaySupplyObservation(
                canonical: RunwayStockAmount(count: 100_000, bytes: nil),
                sequenceable: RunwayStockAmount(count: 0, bytes: nil),
                mediaPrepared: RunwayStockAmount(count: 12, bytes: 4_096),
                published: RunwayStockAmount(count: 33, bytes: nil),
                supplyGeneration: 7,
                examinedRows: 96
            )
        )
        let observation = RunwayFixture.observation(edition: edition, lastVisible: 28, materializedTail: 32)
        let baseline = same.observe(observation)
        let grown = biggerArchive.observe(observation)
        XCTAssertEqual(grown.pressure, baseline.pressure)
        XCTAssertEqual(grown.level, baseline.level)
        XCTAssertEqual(grown.distance, baseline.distance)
        XCTAssertEqual(biggerArchive.stocks.canonical.count, 200_000)
    }

    func testStocksThatWereNeverObservedAreNotReportedAsEmptyAvailability() async throws {
        let sut = estimator()
        XCTAssertFalse(sut.hasObservedOffer)
        XCTAssertFalse(sut.stocks.canonical.isObserved)
        XCTAssertFalse(sut.stocks.sequenceable.isObserved)
        XCTAssertFalse(sut.stocks.mediaPrepared.isObserved)
        XCTAssertFalse(sut.stocks.published.isObserved)
        XCTAssertFalse(sut.stocks.decoded.isObserved)
        XCTAssertEqual(sut.stocks.published.description, "unobserved")
    }

    func testARefillConsumesTheSequenceablePoolWithoutTouchingTheOtherStocks() async throws {
        let edition = try RunwayFixture.edition()
        var sut = estimator()
        sut.apply(
            RunwaySupplyObservation(
                canonical: RunwayStockAmount(count: 500, bytes: nil),
                sequenceable: RunwayStockAmount(count: 30, bytes: nil),
                mediaPrepared: RunwayStockAmount(count: 30, bytes: 1_024),
                published: RunwayStockAmount(count: 11, bytes: nil),
                supplyGeneration: 1,
                examinedRows: 96
            )
        )
        _ = sut.observe(RunwayFixture.observation(edition: edition, lastVisible: 0, materializedTail: 10))

        sut.consumeSequenceable(items: 24)

        XCTAssertEqual(sut.stocks.sequenceable.count, 6)
        XCTAssertEqual(sut.stocks.canonical.count, 500)
        XCTAssertEqual(sut.stocks.published.count, 11)
    }

    // MARK: the window is the only viewport authority

    /// `windowShiftPreservesAnchorInBothDirections` (matrix #23, I-13), seen from the runway: the
    /// estimator reads the session's window in both directions instead of keeping a second one, the
    /// anchor survives the shift, and the ordinals the runway consumed are the window's own.
    func testWindowShiftPreservesAnchorInBothDirectionsWhileFeedingTheRunway() async throws {
        let edition = try RunwayFixture.edition()
        var window = FeedWindow(configuration: .baseline)
        let references = try (0 ..< 40).map { try RunwayFixture.reference(edition: edition, ordinal: $0) }
        let anchor = FeedWindowAnchor.top(of: try RunwayFixture.card(21), ordinal: 20, editionID: edition)
        window.materialize(
            references,
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 20, lastVisibleOrdinal: 24),
            anchor: anchor
        )
        let clock = RunwayTestClock()
        var sut = estimator()

        let forwardObservation = try XCTUnwrap(
            RunwayViewportObservation(window: window, edition: edition, speed: 2_000, sampledAt: clock.now)
        )
        XCTAssertEqual(forwardObservation.materializedTailOrdinal, 32, "the window's materialized tail")
        XCTAssertEqual(forwardObservation.decodedCount, window.materializedCount)
        XCTAssertEqual(forwardObservation.decodedBytes, window.materializedByteCount)

        window.shift(to: FeedWindow.Viewport(firstVisibleOrdinal: 24, lastVisibleOrdinal: 28))
        window.shift(to: FeedWindow.Viewport(firstVisibleOrdinal: 16, lastVisibleOrdinal: 20))
        XCTAssertEqual(window.anchor, anchor, "the anchor survived both directions by identity")

        let backObservation = try XCTUnwrap(
            RunwayViewportObservation(window: window, edition: edition, speed: 2_000, sampledAt: clock.now)
        )
        _ = sut.observe(forwardObservation)
        let estimate = sut.observe(backObservation)
        XCTAssertEqual(estimate.direction, .towardHead)
        XCTAssertEqual(
            backObservation.materializedTailOrdinal,
            28,
            "the window bounds itself around the viewport: the runway reads the materialized end"
        )
        XCTAssertEqual(estimate.distance, backObservation.distance)
        XCTAssertEqual(estimate.distance, 8)

        var evicted = FeedWindow(configuration: .baseline)
        evicted.materialize(
            references,
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 20, lastVisibleOrdinal: 24),
            anchor: anchor
        )
        evicted.releaseMaterializedContent()
        XCTAssertNil(RunwayViewportObservation(window: evicted, edition: edition, speed: 0, sampledAt: clock.now))
        XCTAssertEqual(evicted.anchor, anchor)
    }
}
