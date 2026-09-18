import FeedRuntime
import XCTest

/// The policy is numbers plus four pure rules: clamp, hysteresis, purpose and buffer admission. These
/// tests fix the *shape* the composition must keep (plan §12) and the arithmetic each rule promises.
final class RunwayPolicyTests: XCTestCase {
    private typealias Policy = RunwayPolicy

    private func policy(
        floor: Double = 0.05,
        ceiling: Double = 0.95,
        escalation: Double = 0.60,
        deescalation: Double = 0.40,
        speedSaturation: Double = 4_000,
        comfortableDistance: Int = 24,
        demandDistance: Int = 8,
        referenceLatency: Double = 150,
        latencyTolerance: Double = 600,
        speedWeight: Double = 0.35,
        distanceWeight: Double = 0.40,
        latencyWeight: Double = 0.25,
        reversalDiscount: Double = 0.25,
        latencySampleLimit: Int = 64,
        itemLimit: Int = 24,
        byteLimit: Int = 2 * 1024 * 1024,
        bufferItems: Int = 48,
        bufferBytes: Int = 4 * 1024 * 1024,
        maximumAttempts: Int = 3,
        deadlineMilliseconds: Int = 10_000
    ) throws -> Policy {
        try Policy(
            floor: floor,
            ceiling: ceiling,
            escalationThreshold: escalation,
            deescalationThreshold: deescalation,
            speedSaturation: speedSaturation,
            comfortableDistance: comfortableDistance,
            demandDistance: demandDistance,
            referenceLatencyMilliseconds: referenceLatency,
            latencyToleranceMilliseconds: latencyTolerance,
            speedWeight: speedWeight,
            distanceWeight: distanceWeight,
            latencyWeight: latencyWeight,
            reversalDiscount: reversalDiscount,
            latencySampleLimit: latencySampleLimit,
            itemLimitPerRefill: itemLimit,
            byteLimitPerRefill: byteLimit,
            bufferItemBudget: bufferItems,
            bufferByteBudget: bufferBytes,
            maximumRefillAttempts: maximumAttempts,
            refillDeadlineMilliseconds: deadlineMilliseconds
        )
    }

    private func refusal(_ build: () throws -> Policy) -> RunwayPolicyError? {
        do {
            _ = try build()
            return nil
        } catch let error as RunwayPolicyError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: shape

    func testTheBaselinePolicyIsValidAndItsWeightsSumToOne() {
        let baseline = RunwayPolicy.baseline
        XCTAssertEqual(baseline.speedWeight + baseline.distanceWeight + baseline.latencyWeight, 1, accuracy: 1e-12)
        XCTAssertLessThan(baseline.floor, baseline.ceiling)
        XCTAssertLessThan(baseline.deescalationThreshold, baseline.escalationThreshold)
        XCTAssertLessThanOrEqual(baseline.demandDistance, baseline.comfortableDistance)
        XCTAssertGreaterThanOrEqual(baseline.bufferItemBudget, baseline.itemLimitPerRefill)
        XCTAssertGreaterThanOrEqual(baseline.bufferByteBudget, baseline.byteLimitPerRefill)
    }

    func testAPolicyThatCouldFlapOrStarveIsRefused() {
        XCTAssertEqual(
            refusal { try policy(floor: 0.8, ceiling: 0.5) },
            .floorOrCeilingOutOfRange(floor: 0.8, ceiling: 0.5)
        )
        XCTAssertEqual(
            refusal { try policy(escalation: 0.4, deescalation: 0.4) },
            .hysteresisBandIsNotOrdered(escalation: 0.4, deescalation: 0.4),
            "a band of zero would oscillate on the threshold"
        )
        XCTAssertEqual(
            refusal { try policy(speedSaturation: 0) },
            .nonPositiveSpeedSaturation(0)
        )
        XCTAssertEqual(
            refusal { try policy(comfortableDistance: 8, demandDistance: 24) },
            .distanceHorizonIsNotOrdered(comfortable: 8, demand: 24)
        )
        XCTAssertEqual(
            refusal { try policy(latencyTolerance: 0) },
            .latencyWindowIsNotUsable(referenceMilliseconds: 150, toleranceMilliseconds: 0)
        )
        XCTAssertEqual(
            refusal { try policy(latencyWeight: 0.5) },
            .weightsDoNotSumToOne(1.25)
        )
        XCTAssertEqual(
            refusal { try policy(reversalDiscount: 1.5) },
            .reversalDiscountOutOfRange(1.5)
        )
        XCTAssertEqual(
            refusal { try policy(latencySampleLimit: 0) },
            .nonPositiveLimit("latencySampleLimit", 0)
        )
        XCTAssertEqual(
            refusal { try policy(itemLimit: 24, bufferItems: 12) },
            .bufferBudgetBelowOneRefill("items"),
            "a buffer smaller than one refill could never admit anything"
        )
        XCTAssertEqual(
            refusal { try policy(byteLimit: 8 * 1024 * 1024, bufferBytes: 4 * 1024 * 1024) },
            .bufferBudgetBelowOneRefill("bytes")
        )
    }

    // MARK: clamp

    func testClampKeepsTheEstimateInsideTheStatedFloorAndCeiling() throws {
        let sut = try policy(floor: 0.1, ceiling: 0.9)
        XCTAssertEqual(sut.clamp(-3), 0.1)
        XCTAssertEqual(sut.clamp(0), 0.1)
        XCTAssertEqual(sut.clamp(0.5), 0.5)
        XCTAssertEqual(sut.clamp(1), 0.9)
        XCTAssertEqual(sut.clamp(42), 0.9)
    }

    // MARK: hysteresis

    func testTheLevelOnlyChangesThroughTheBand() throws {
        let sut = try policy(escalation: 0.6, deescalation: 0.4)
        XCTAssertEqual(sut.level(previous: .comfortable, estimate: 0.59), .comfortable)
        XCTAssertEqual(sut.level(previous: .comfortable, estimate: 0.6), .strained)
        XCTAssertEqual(sut.level(previous: .strained, estimate: 0.41), .strained)
        XCTAssertEqual(sut.level(previous: .strained, estimate: 0.4), .comfortable)
    }

    // MARK: purpose and willingness

    func testAReaderAtTheTailGetsDemandAndAFlingGetsAPrefetch() throws {
        let sut = try policy(comfortableDistance: 24, demandDistance: 8)
        XCTAssertEqual(sut.refillPurpose(distance: 0, level: .strained), .readerDemand)
        XCTAssertEqual(sut.refillPurpose(distance: 8, level: .comfortable), .readerDemand)
        XCTAssertEqual(sut.refillPurpose(distance: 9, level: .strained), .prefetch)
        XCTAssertTrue(RunwayRefillPurpose.prefetch.isSpeculative)
        XCTAssertFalse(RunwayRefillPurpose.readerDemand.isSpeculative)
    }

    func testRefillsAreWantedOnlyWhereTheyCanHelp() throws {
        let sut = try policy(comfortableDistance: 24, demandDistance: 8)
        XCTAssertTrue(sut.wantsRefill(distance: 2, level: .comfortable), "the reader is at the tail")
        XCTAssertTrue(sut.wantsRefill(distance: 20, level: .strained))
        XCTAssertFalse(
            sut.wantsRefill(distance: 30, level: .strained),
            "hysteresis can leave a strained level long after the reader backed away"
        )
        XCTAssertFalse(sut.wantsRefill(distance: 20, level: .comfortable))
    }

    // MARK: buffer admission

    func testTheBufferAdmitsOnlyWhatFitsBothBudgets() throws {
        let sut = try policy(itemLimit: 24, byteLimit: 2 * 1024 * 1024, bufferItems: 48, bufferBytes: 4 * 1024 * 1024)
        XCTAssertTrue(
            sut.bufferAdmits(outstandingItems: 24, outstandingBytes: 2 * 1024 * 1024, itemLimit: 24, byteLimit: 2 * 1024 * 1024)
        )
        XCTAssertFalse(
            sut.bufferAdmits(outstandingItems: 48, outstandingBytes: 2 * 1024 * 1024, itemLimit: 24, byteLimit: 2 * 1024 * 1024),
            "the item budget is the binding one"
        )
        XCTAssertFalse(
            sut.bufferAdmits(outstandingItems: 0, outstandingBytes: 4 * 1024 * 1024, itemLimit: 24, byteLimit: 2 * 1024 * 1024),
            "the byte budget alone can refuse"
        )
        XCTAssertFalse(
            sut.bufferAdmits(outstandingItems: 0, outstandingBytes: 0, itemLimit: 0, byteLimit: 1),
            "a request with no room for items is not admitted"
        )
    }
}
