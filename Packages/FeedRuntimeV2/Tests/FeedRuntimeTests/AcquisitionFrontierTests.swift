import XCTest
import FeedDomain
import FeedRuntime

/// The frontier is finite and classified by work, not by URL (ADR-005 D7).
///
/// These tests cover the accounting that keeps a large catalogue from becoming a large amount of
/// running work, and the two reported end states — `exhausted` and `degraded` — that stop an episode
/// instead of looping (ADR-005 D8; plan §19 #35, #37).
final class AcquisitionFrontierTests: XCTestCase {
    private func catalogue(_ count: Int, bindingRevision: UInt64 = 1) -> [AcquisitionTarget] {
        (0..<count).map { index in
            AcquisitionTarget(
                id: AcquisitionTargetID("target-\(String(format: "%05d", index))"),
                connectorKind: "fixture",
                generation: 1,
                bindingRevision: bindingRevision
            )
        }
    }

    private func demand(
        purpose: AcquisitionPurpose = .userInitiated,
        deficit: Int = 8,
        holder: String = "context-1"
    ) -> AcquisitionDemand {
        AcquisitionDemand(
            purpose: purpose,
            holderID: holder,
            deficit: SupplyDeficit(items: deficit),
            deadline: FixtureInstant.seconds(60)
        )
    }

    private var planner: AcquisitionPlanner { AcquisitionPlanner() }

    /// `frontierRemainsBoundedUnderCatalogGrowth` (plan §19 #35; `invariant 12`).
    ///
    /// A hundred times the catalogue raises eligibility and leaves concurrently runnable work
    /// exactly where it was, and the planned work stays the same size as the purpose budget allows.
    func testFrontierRemainsBoundedUnderCatalogGrowth() {
        var frontier = AcquisitionFrontier(bound: FrontierBound())
        let budget = AcquisitionPurpose.userInitiated.budget

        frontier.rebuild(catalogue: catalogue(4), demand: demand(), budget: budget)
        let smallPlan = planner.plan(demand: demand(), frontier: frontier, usage: .zero, now: FixtureInstant.epoch)

        frontier.rebuild(catalogue: catalogue(10_000), demand: demand(), budget: budget)

        XCTAssertEqual(frontier.eligibleCount, 10_000, "catalogue growth is eligibility")
        XCTAssertEqual(
            frontier.state,
            .work(eligible: 10_000, runnable: 4),
            "running work does not grow with the catalogue"
        )
        XCTAssertEqual(frontier.runnableCount, budget.targets)

        let largePlan = planner.plan(demand: demand(), frontier: frontier, usage: .zero, now: FixtureInstant.epoch)
        XCTAssertEqual(largePlan.work.count, smallPlan.work.count)
        XCTAssertEqual(largePlan.work.count, budget.targets)
        XCTAssertEqual(
            largePlan.work.map(\.target.id),
            smallPlan.work.map(\.target.id),
            "the window is the first targets by rank, not a sample of the catalogue"
        )
    }

    /// The window is capped per class, and the classes mean what ADR-005 D7 says they mean.
    func testWorkIsClassifiedByRoleAndEachRoleIsCapped() {
        var frontier = AcquisitionFrontier(bound: FrontierBound(head: 1, active: 1, exploration: 1))
        let budget = AcquisitionPurpose.userInitiated.budget
        let targets = catalogue(6)

        frontier.rebuild(catalogue: targets, demand: demand(), budget: budget)
        XCTAssertEqual(frontier.head.count, 1)
        XCTAssertEqual(frontier.active.count, 0)
        XCTAssertEqual(frontier.exploration.count, 1)
        XCTAssertEqual(frontier.runnableCount, 2, "the window is capped by the bound, not by the catalogue")
        XCTAssertEqual(frontier.head.first?.workClass, .head)
        XCTAssertEqual(frontier.exploration.first?.workClass, .exploration)

        frontier.markRunning(targets[0].id)
        XCTAssertEqual(frontier.active.count, 1)
        XCTAssertEqual(frontier.active.first?.workClass, .active)
        XCTAssertEqual(frontier.active.first?.target.id, targets[0].id)
        XCTAssertEqual(frontier.runnableCount, 3)
    }

    /// A finished target reports no more work for that binding revision, and it disappears from the
    /// window rather than being served again (ADR-005 D8: no unbounded retry loop).
    func testFinishedTargetLeavesTheWindowWithoutLosingItsPlaceInTheCatalogue() {
        var frontier = AcquisitionFrontier()
        let targets = catalogue(3)
        let budget = AcquisitionPurpose.userInitiated.budget
        frontier.rebuild(catalogue: targets, demand: demand(), budget: budget)

        frontier.markFinished(targets[0].id, bindingRevision: targets[0].bindingRevision)
        frontier.markFinished(targets[1].id, bindingRevision: targets[1].bindingRevision)

        XCTAssertEqual(frontier.finishedCount, 2)
        XCTAssertEqual(frontier.eligibleCount, 1)
        XCTAssertEqual(frontier.runnableItems.map(\.target.id), [targets[2].id])
        XCTAssertEqual(frontier.state, .work(eligible: 1, runnable: 1))

        frontier.markFinished(targets[2].id, bindingRevision: targets[2].bindingRevision)
        XCTAssertEqual(frontier.state, .exhausted, "no eligible work is exhaustion, not degradation")
    }

    /// A configuration change is new work: the same target becomes eligible again under a new binding
    /// revision (ADR-005 D8, D10).
    func testNewBindingRevisionMakesAFinishedTargetEligibleAgain() {
        var frontier = AcquisitionFrontier()
        let targets = catalogue(1)
        let budget = AcquisitionPurpose.userInitiated.budget
        frontier.rebuild(catalogue: targets, demand: demand(), budget: budget)
        frontier.markFinished(targets[0].id, bindingRevision: targets[0].bindingRevision)
        XCTAssertEqual(frontier.state, .exhausted)

        let reconfigured = catalogue(1, bindingRevision: 2)
        frontier.rebuild(catalogue: reconfigured, demand: demand(), budget: budget)
        XCTAssertEqual(frontier.finishedCount, 0)
        XCTAssertEqual(frontier.runnableItems.map(\.target.bindingRevision), [2])
    }

    /// Supply exists but policy forbids fetching it: `degraded`, not `exhausted` (ADR-005 D8).
    func testAZeroBudgetPurposeReportsDegradedNotExhausted() {
        var frontier = AcquisitionFrontier()
        frontier.rebuild(
            catalogue: catalogue(3),
            demand: demand(purpose: .speculative),
            budget: PurposeBudget.zero(cancellationOrder: 1)
        )
        XCTAssertEqual(frontier.eligibleCount, 3)
        XCTAssertEqual(frontier.runnableCount, 0)
        XCTAssertEqual(frontier.state, .degraded(.budgetStop(.speculative)))
    }

    /// An explicit degradation is reported beside the work that remains runnable: it says why the
    /// last episode stopped, not that the frontier is empty.
    func testAnExplicitDegradationIsReportedBesideTheWorkThatRemains() {
        var frontier = AcquisitionFrontier()
        let budget = AcquisitionPurpose.activeRunway.budget
        let disconnected = AcquisitionTargetID("target-00000")

        frontier.rebuild(catalogue: catalogue(2), demand: demand(purpose: .activeRunway), budget: budget)
        frontier.markDegraded(.streamDisconnected(disconnected))

        XCTAssertEqual(frontier.degradationReason, .streamDisconnected(disconnected))
        XCTAssertEqual(
            frontier.state,
            .work(eligible: 2, runnable: 2),
            "the frontier still reports what it can run; the degradation is reported beside it"
        )

        frontier.rebuild(catalogue: catalogue(2), demand: demand(purpose: .activeRunway), budget: budget)
        XCTAssertNil(frontier.degradationReason, "a new demand is a new attempt")
        XCTAssertEqual(frontier.state, .work(eligible: 2, runnable: 2))

        // With nothing runnable, the explicit reason is the state: supply exists and policy or
        // failure is why it is not being fetched.
        var blocked = AcquisitionFrontier()
        blocked.rebuild(
            catalogue: catalogue(1),
            demand: demand(purpose: .speculative),
            budget: PurposeBudget.zero(cancellationOrder: 1)
        )
        blocked.markDegraded(.transportFailure(disconnected))
        XCTAssertEqual(blocked.state, .degraded(.transportFailure(disconnected)))
    }

    func testAnEmptyFrontierIsExhaustion() {
        let frontier = AcquisitionFrontier()
        switch frontier.state {
        case .exhausted: break
        default: XCTFail("an empty frontier reports exhaustion, got \(frontier.state)")
        }
    }
}
