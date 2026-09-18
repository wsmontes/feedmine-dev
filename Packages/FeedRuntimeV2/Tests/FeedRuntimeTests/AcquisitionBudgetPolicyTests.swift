import XCTest
import FeedRuntime

/// PR-15, budget half: every condition the plan names changes the budget, and the *signal → budget*
/// pair is the evidence — the device is never read, the condition is injected.
final class AcquisitionBudgetPolicyTests: XCTestCase {

    /// A baseline in the shape the app states for a background demand.
    private let baseline = AcquisitionBudget(
        sourceLimit: 12,
        maxConcurrency: 4,
        deadlineMilliseconds: 25_000,
        allowsSpeculativeWork: true
    )

    private func budget(_ conditions: AcquisitionConditions) -> AcquisitionBudget {
        AcquisitionBudgetPolicy.budget(baseline: baseline, conditions: conditions)
    }

    /// No signal applied: the baseline stands, unmodified and unnamed.
    func testUnrestrictedConditionsLeaveTheBaselineStanding() {
        let unrestricted = budget(.unrestricted)
        XCTAssertEqual(unrestricted, baseline)
        XCTAssertTrue(unrestricted.appliedSignals.isEmpty, "nothing changed, so nothing is named")
    }

    /// The whole matrix, one row per signal: what changed and by how much.
    func testEachConditionIsNamedAndLowersExactlyWhatItShould() {
        struct Row {
            let signal: AcquisitionSignal
            let conditions: AcquisitionConditions
            let sourceLimit: Int
            let maxConcurrency: Int
            let allowsSpeculativeWork: Bool
        }
        let rows: [Row] = [
            Row(signal: .lowPowerMode,
                conditions: AcquisitionConditions(lowPowerMode: true),
                sourceLimit: 6, maxConcurrency: 4, allowsSpeculativeWork: false),
            Row(signal: .lowDataMode,
                conditions: AcquisitionConditions(network: .lowDataMode),
                sourceLimit: 6, maxConcurrency: 4, allowsSpeculativeWork: false),
            Row(signal: .expensiveNetwork,
                conditions: AcquisitionConditions(network: .expensive),
                sourceLimit: 6, maxConcurrency: 4, allowsSpeculativeWork: true),
            Row(signal: .thermalSerious,
                conditions: AcquisitionConditions(thermal: .serious),
                sourceLimit: 6, maxConcurrency: 2, allowsSpeculativeWork: false),
            Row(signal: .thermalCritical,
                conditions: AcquisitionConditions(thermal: .critical),
                sourceLimit: 3, maxConcurrency: 1, allowsSpeculativeWork: false),
            Row(signal: .memoryPressure,
                conditions: AcquisitionConditions(memoryPressure: true),
                sourceLimit: 12, maxConcurrency: 1, allowsSpeculativeWork: false),
        ]

        for row in rows {
            let result = budget(row.conditions)
            XCTAssertEqual(result.appliedSignals, [row.signal], "row \(row.signal) names its signal")
            XCTAssertEqual(result.sourceLimit, row.sourceLimit, "row \(row.signal) source limit")
            XCTAssertEqual(result.maxConcurrency, row.maxConcurrency, "row \(row.signal) concurrency")
            XCTAssertEqual(
                result.allowsSpeculativeWork, row.allowsSpeculativeWork,
                "row \(row.signal) speculative work"
            )
            XCTAssertEqual(
                result.deadlineMilliseconds, baseline.deadlineMilliseconds,
                "no signal shortens the demand's own deadline"
            )
        }
    }

    /// Signals compose, and each one is named: a hot device in Low Power Mode on a metered network
    /// shrinks three times, in the order the budget applied them.
    func testSignalsComposeAndAllAppearInOrder() {
        let result = budget(
            AcquisitionConditions(
                lowPowerMode: true,
                network: .expensiveAndConstrained,
                thermal: .serious,
                memoryPressure: true
            )
        )
        XCTAssertEqual(
            result.appliedSignals,
            [.expensiveNetwork, .lowDataMode, .lowPowerMode, .thermalSerious, .memoryPressure]
        )
        // 12 → 6 → 3 → 2 (halved, floored at one) → 1; concurrency 4 → 2 (serious) → 1 (memory).
        XCTAssertEqual(result.sourceLimit, 1)
        XCTAssertEqual(result.maxConcurrency, 1)
        XCTAssertFalse(result.allowsSpeculativeWork)
    }

    /// Monotone: applying any subset of signals never raises either dimension above the baseline.
    /// Checked exhaustively over every combination of the five booleans and four thermal states.
    func testNoCombinationOfConditionsRaisesTheBudget() {
        let networks: [NetworkCost] = NetworkCost.allCases
        for lowPower in [false, true] {
            for network in networks {
                for thermal in ThermalPressure.allCases {
                    for memory in [false, true] {
                        let result = budget(
                            AcquisitionConditions(
                                lowPowerMode: lowPower,
                                network: network,
                                thermal: thermal,
                                memoryPressure: memory
                            )
                        )
                        XCTAssertLessThanOrEqual(
                            result.sourceLimit, baseline.sourceLimit,
                            "lowPower=\(lowPower) network=\(network) thermal=\(thermal) memory=\(memory)"
                        )
                        XCTAssertLessThanOrEqual(result.maxConcurrency, baseline.maxConcurrency)
                        if result.sourceLimit > 0 {
                            XCTAssertGreaterThanOrEqual(result.sourceLimit, 1, "a running demand has work")
                            XCTAssertGreaterThanOrEqual(result.maxConcurrency, 1)
                        }
                    }
                }
            }
        }
    }

    /// No path at all is the one condition that stops acquisition instead of shrinking it, and it is
    /// the only one that reports a zero source limit.
    func testNoNetworkStopsAcquisitionEntirely() {
        for conditions in [
            AcquisitionConditions(network: .unavailable),
            AcquisitionConditions(allowsNetwork: false),
        ] {
            let result = budget(conditions)
            XCTAssertEqual(result.sourceLimit, 0)
            XCTAssertEqual(result.maxConcurrency, 0)
            XCTAssertFalse(result.allowsSpeculativeWork)
            XCTAssertEqual(result.appliedSignals, [.networkUnavailable])
        }
    }

    /// A tiny baseline is not rounded to zero: `sourceLimit` 1 stays 1 under every shrinking signal,
    /// so a constrained demand still refreshes one endpoint rather than nothing.
    func testShrinkingASingleSourceBaselineStillLeavesOneSource() {
        let tiny = AcquisitionBudget(
            sourceLimit: 1,
            maxConcurrency: 1,
            deadlineMilliseconds: 1_000,
            allowsSpeculativeWork: true
        )
        let result = AcquisitionBudgetPolicy.budget(
            baseline: tiny,
            conditions: AcquisitionConditions(
                lowPowerMode: true,
                network: .expensiveAndConstrained,
                thermal: .critical,
                memoryPressure: true
            )
        )
        XCTAssertEqual(result.sourceLimit, 1)
        XCTAssertEqual(result.maxConcurrency, 1)
    }
}
