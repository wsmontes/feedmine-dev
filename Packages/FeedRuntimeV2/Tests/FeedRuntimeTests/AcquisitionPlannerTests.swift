import XCTest
import FeedDomain
import FeedRuntime

/// The planner turns a demand into bounded work, and a purpose cannot exceed its budget
/// (ADR-005 D9; `invariant 10`, `invariant 19`).
///
/// Everything here is deterministic: the clock is the fixture's fixed instant and usage is an
/// argument, so a budget stop is a fact rather than a race.
final class AcquisitionPlannerTests: XCTestCase {
    private func catalogue(_ count: Int) -> [AcquisitionTarget] {
        (0..<count).map { index in
            AcquisitionTarget(
                id: AcquisitionTargetID("target-\(String(format: "%05d", index))"),
                connectorKind: "fixture"
            )
        }
    }

    private func demand(
        purpose: AcquisitionPurpose = .userInitiated,
        deficit: Int = 8,
        deadline: Date = FixtureInstant.seconds(600)
    ) -> AcquisitionDemand {
        AcquisitionDemand(
            purpose: purpose,
            holderID: "context-1",
            deficit: SupplyDeficit(items: deficit),
            deadline: deadline
        )
    }

    private func frontier(
        _ count: Int = 10,
        purpose: AcquisitionPurpose = .userInitiated,
        budget: PurposeBudget? = nil
    ) -> AcquisitionFrontier {
        var frontier = AcquisitionFrontier()
        frontier.rebuild(
            catalogue: catalogue(count),
            demand: demand(purpose: purpose),
            budget: budget ?? purpose.budget
        )
        return frontier
    }

    /// Every purpose table row caps its own plan: targets, and the host and connection dimensions
    /// that a single request spends (ADR-005 D9).
    func testEveryPurposeRespectsItsOwnTargetRequestAndConnectionBudget() {
        let planner = AcquisitionPlanner()
        for purpose in AcquisitionPurpose.allCases {
            let plan = planner.plan(
                demand: demand(purpose: purpose),
                frontier: frontier(50, purpose: purpose),
                usage: .zero,
                now: FixtureInstant.epoch
            )
            XCTAssertLessThanOrEqual(plan.work.count, purpose.budget.targets, "\(purpose) targets")
            XCTAssertLessThanOrEqual(plan.work.count, purpose.budget.requests, "\(purpose) requests")
            XCTAssertLessThanOrEqual(plan.work.count, purpose.budget.hosts, "\(purpose) hosts")
            XCTAssertLessThanOrEqual(plan.work.count, purpose.budget.connections, "\(purpose) connections")
            XCTAssertFalse(plan.work.isEmpty, "\(purpose) has a non-zero budget in the baseline")
        }
    }

    /// The host and connection dimensions bind on their own, not only through the target count.
    func testNarrowerHostOrConnectionBudgetsShrinkThePlan() {
        let narrowHosts = PurposeBudget(
            targets: 8, requests: 24, bytes: 1024 * 1024, hosts: 2, connections: 8,
            timeLimit: 20, cancellationOrder: 5
        )
        let narrowConnections = PurposeBudget(
            targets: 8, requests: 24, bytes: 1024 * 1024, hosts: 8, connections: 1,
            timeLimit: 20, cancellationOrder: 5
        )
        let planner = AcquisitionPlanner(budgets: AcquisitionBudgetTable([.userInitiated: narrowHosts]))
        XCTAssertEqual(
            planner.plan(
                demand: demand(),
                frontier: frontier(50, budget: narrowHosts),
                usage: .zero,
                now: FixtureInstant.epoch
            ).work.count,
            2
        )

        let connectionPlanner = AcquisitionPlanner(
            budgets: AcquisitionBudgetTable([.userInitiated: narrowConnections])
        )
        XCTAssertEqual(
            connectionPlanner.plan(
                demand: demand(),
                frontier: frontier(50, budget: narrowConnections),
                usage: .zero,
                now: FixtureInstant.epoch
            ).work.count,
            1
        )
    }

    /// The per-pull limit is the smaller of the purpose's remaining budget, the item ceiling and the
    /// byte ceiling — the bound the connector and Admission both check (ADR-005 D4).
    func testEveryWorkItemCarriesALimitInsideTheCeilings() {
        // Every dimension has room for the four items, so the byte budget is what is being shared.
        let budget = PurposeBudget(
            targets: 4, requests: 8, bytes: 400, hosts: 4, connections: 4,
            timeLimit: 20, cancellationOrder: 5
        )
        let planner = AcquisitionPlanner(budgets: AcquisitionBudgetTable([.userInitiated: budget]), itemCeiling: 3)
        let plan = planner.plan(
            demand: demand(deficit: 9),
            frontier: frontier(4, budget: budget),
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(plan.work.count, 4)
        for item in plan.work {
            XCTAssertLessThanOrEqual(item.limit.maxItems, 3)
            XCTAssertLessThanOrEqual(item.limit.maxBytes, 100, "the byte budget is shared across the plan")
            XCTAssertEqual(item.observationBudget, item.limit.maxItems)
            XCTAssertEqual(item.limit.deadline, FixtureInstant.seconds(20), "the purpose's own deadline")
        }
    }

    /// The deadline is the earlier of the purpose's time budget and the caller's own.
    func testDeadlineIsTheEarlierOfThePurposeAndTheCaller() {
        let planner = AcquisitionPlanner()
        let early = planner.plan(
            demand: demand(deadline: FixtureInstant.seconds(5)),
            frontier: frontier(2),
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(early.work.first?.limit.deadline, FixtureInstant.seconds(5))
        XCTAssertEqual(early.deadline, FixtureInstant.seconds(5))

        let late = planner.plan(
            demand: demand(deadline: FixtureInstant.seconds(600)),
            frontier: frontier(2),
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(late.work.first?.limit.deadline, FixtureInstant.seconds(20))
    }

    /// A deadline that has passed stops the plan instead of planning work nothing may run.
    func testAPassedDeadlineStopsThePlan() {
        let planner = AcquisitionPlanner()
        let plan = planner.plan(
            demand: demand(deadline: FixtureInstant.seconds(10)),
            frontier: frontier(4),
            usage: .zero,
            now: FixtureInstant.seconds(11)
        )
        XCTAssertEqual(plan.stop, .deadlineReached)
        XCTAssertTrue(plan.work.isEmpty)
    }

    /// Spending the purpose's window stops it, in every dimension (ADR-005 D9).
    func testSpentBudgetStopsThePlan() {
        let planner = AcquisitionPlanner()
        let spentDimensions: [PurposeUsage] = [
            PurposeUsage(targets: 4),
            PurposeUsage(requests: 24),
            PurposeUsage(bytes: 24 * 1024 * 1024),
            PurposeUsage(hosts: 8),
            PurposeUsage(connections: 4),
        ]
        for usage in spentDimensions {
            let plan = planner.plan(
                demand: demand(),
                frontier: frontier(4),
                usage: usage,
                now: FixtureInstant.epoch
            )
            XCTAssertEqual(plan.stop, .budgetStop(.userInitiated), "\(usage)")
            XCTAssertTrue(plan.work.isEmpty)
        }
    }

    /// A deficit already met needs no work, and that is not exhaustion of supply.
    func testMeetingTheDeficitStopsThePlan() {
        let plan = AcquisitionPlanner().plan(
            demand: demand(deficit: 0),
            frontier: frontier(4),
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(plan.stop, .satisfied)
        XCTAssertTrue(plan.work.isEmpty)
    }

    /// `speculative` may carry a zero budget: nothing is planned and the reason is explicit
    /// (ADR-005 D9; plan §20.3).
    func testSpeculativeMayCarryAZeroBudget() {
        let budgets = AcquisitionBudgetTable([.speculative: .zero(cancellationOrder: 1)])
        let planner = AcquisitionPlanner(budgets: budgets)
        let frontier = frontier(5, purpose: .speculative, budget: .zero(cancellationOrder: 1))
        let plan = planner.plan(
            demand: demand(purpose: .speculative),
            frontier: frontier,
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(plan.stop, .budgetStop(.speculative))
        XCTAssertTrue(plan.work.isEmpty)
    }

    /// An exhausted frontier is reported as exhaustion, so the runtime ends the episode instead of
    /// planning the same work again (ADR-005 D8).
    func testExhaustedFrontierIsReportedAsExhaustion() {
        var frontier = AcquisitionFrontier()
        let targets = catalogue(2)
        frontier.rebuild(catalogue: targets, demand: demand(), budget: AcquisitionPurpose.userInitiated.budget)
        frontier.markFinished(targets[0].id, bindingRevision: targets[0].bindingRevision)
        frontier.markFinished(targets[1].id, bindingRevision: targets[1].bindingRevision)

        let plan = AcquisitionPlanner().plan(
            demand: demand(),
            frontier: frontier,
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(plan.stop, .exhausted)
        XCTAssertTrue(plan.work.isEmpty)
    }

    /// The deficit bounds how many targets are started: a one-item deficit does not spin up four
    /// targets.
    func testTheDeficitBoundsHowManyTargetsStart() {
        let plan = AcquisitionPlanner().plan(
            demand: demand(deficit: 1),
            frontier: frontier(50),
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(plan.work.count, 1)
        XCTAssertEqual(plan.work.first?.observationBudget, 1)
    }

    /// The plan's leases say who wants the work and against which generation, and they are the
    /// demand's, not an editorial source's (ADR-005 D6).
    func testWorkItemsCarryTheDemandHolderAndTheTargetsGeneration() {
        let plan = AcquisitionPlanner().plan(
            demand: AcquisitionDemand(
                purpose: .activeRunway,
                holderID: "edition-42",
                priority: DemandPriority(urgency: 3),
                deficit: SupplyDeficit(items: 2),
                deadline: FixtureInstant.seconds(600)
            ),
            frontier: frontier(2, purpose: .activeRunway),
            usage: .zero,
            now: FixtureInstant.epoch
        )
        XCTAssertEqual(plan.work.count, 2)
        for item in plan.work {
            XCTAssertEqual(item.lease.holderID, "edition-42")
            XCTAssertEqual(item.lease.purpose, .activeRunway)
            XCTAssertEqual(item.lease.priority, DemandPriority(urgency: 3))
            XCTAssertEqual(item.lease.targetID, item.target.id)
            XCTAssertEqual(item.lease.generation, item.target.generation)
            XCTAssertEqual(item.lease.bindingRevision, item.target.bindingRevision)
        }
    }
}
