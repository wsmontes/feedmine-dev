import XCTest
import FeedRuntime
@testable import feedmine

/// PR-15: the background refresh the app never had — registration, the exactly-once completion
/// contract on all three paths, expiration as real cancellation, and the demand's budget.
///
/// The system's `BGTaskScheduler` cannot be asked to launch or expire a task, so every contract here is
/// stated against the seam the scheduler actually uses. Two of the tests read the *real* launch path
/// instead: the shared scheduler is registered by `FeedmineEntryPoint.main()` before this bundle runs,
/// so its recorded outcome is evidence about the app, not about a fake.
@MainActor
final class BackgroundRefreshTests: XCTestCase {

    // MARK: - Registration

    /// The configuration half: the identifier the code registers is the identifier the bundle permits.
    /// Without this pair `register(forTaskWithIdentifier:)` cannot succeed, and the failure is silent.
    func testBundledPermittedIdentifiersNameTheIdentifierTheCodeRegisters() {
        let permitted = SmartFeedBackgroundScheduler.permittedIdentifiers()
        XCTAssertTrue(
            permitted.contains(SmartFeedBackgroundScheduler.taskIdentifier),
            "Info.plist permits \(permitted) but the code registers \(SmartFeedBackgroundScheduler.taskIdentifier)"
        )
    }

    /// A `BGAppRefreshTask` also needs the `fetch` background mode, or iOS never schedules it.
    func testBundledBackgroundModesCarryTheBackgroundFetchMode() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertTrue(modes.contains("fetch"), "UIBackgroundModes is \(modes)")
    }

    /// The registration half, observed rather than asserted: this process is the app, `FeedmineEntryPoint`
    /// registered the shared scheduler before the test bundle was injected, and this reads the outcome of
    /// that real call to `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)`.
    func testTheProcessRegisteredTheBackgroundTaskAtLaunch() {
        let scheduler = SmartFeedBackgroundScheduler.shared
        XCTAssertEqual(
            scheduler.registrationAttempts, 1,
            "one attempt at launch, and a second register() call is a no-op"
        )
        XCTAssertTrue(
            scheduler.lastRegistrationSucceeded,
            "BGTaskScheduler refused the identifier: registration is logged with the permitted list"
        )
        XCTAssertTrue(scheduler.isRegistered)
    }

    /// Repeated registration is a no-op: the first answer stands rather than being asked for again.
    func testRegistrationIsAttemptedOnceAndAnsweredFromTheFirstOutcome() {
        let registrar = ScriptedRegistrar()
        registrar.registrationResult = false
        let scheduler = SmartFeedBackgroundScheduler(backend: registrar)

        XCTAssertFalse(scheduler.register(), "the backend refused")
        XCTAssertEqual(scheduler.registrationAttempts, 1)
        XCTAssertFalse(scheduler.lastRegistrationSucceeded)
        // A refused registration is retried: the identifier may be permitted on a later launch.
        XCTAssertFalse(scheduler.register())
        XCTAssertEqual(scheduler.registrationAttempts, 2)

        let accepted = SmartFeedBackgroundScheduler(backend: ScriptedRegistrar())
        XCTAssertTrue(accepted.register())
        XCTAssertEqual(accepted.registrationAttempts, 1)
        XCTAssertTrue(accepted.register(), "already registered")
        XCTAssertEqual(accepted.registrationAttempts, 1, "an accepted registration is not asked for again")
        XCTAssertTrue(accepted.lastRegistrationSucceeded)
    }

    /// P12, re-proved in the state where it stops being vacuous: before PR-15 `schedule()` returned at
    /// `guard isRegistered`, so "at most one pending request" held because nothing was ever submitted.
    /// With the task registered, three call sites submit through the same flag and only the first lands.
    func testThreeSchedulingCallSitesLeaveAtMostOnePendingRequest() {
        let registrar = ScriptedRegistrar()
        let scheduler = SmartFeedBackgroundScheduler(backend: registrar)
        XCTAssertTrue(scheduler.register())

        // The three call sites: creating a smart feed twice, and the screen going to the background.
        scheduler.schedule()
        scheduler.schedule()
        scheduler.schedule()
        XCTAssertEqual(scheduler.pendingScheduleCount, 1, "one pending request, not three")
        XCTAssertEqual(registrar.submits.count, 1)
        XCTAssertTrue(scheduler.hasPendingRequest)

        // The handler runs: the pending request is consumed, and the chain is re-armed with one more.
        let owner = ScriptedOwner()
        scheduler.configure(ownerProvider: { owner })
        let task = ScriptedBackgroundTask()
        scheduler.handle(task)
        XCTAssertEqual(scheduler.pendingScheduleCount, 2, "the fired request is replaced by exactly one")
        XCTAssertEqual(registrar.submits.count, 2)
        XCTAssertTrue(scheduler.hasPendingRequest, "exactly one request stays pending")
    }

    /// A refused submit clears the flag, so the next `schedule()` is not suppressed by a request that
    /// never reached the scheduler.
    func testAFailedSubmitDoesNotLeaveARequestPending() {
        let registrar = ScriptedRegistrar()
        let scheduler = SmartFeedBackgroundScheduler(backend: registrar)
        XCTAssertTrue(scheduler.register())
        registrar.submitError = URLError(.backgroundSessionInUseByAnotherProcess)

        scheduler.schedule()
        XCTAssertEqual(scheduler.pendingScheduleCount, 0)
        XCTAssertFalse(scheduler.hasPendingRequest)

        registrar.submitError = nil
        scheduler.schedule()
        XCTAssertEqual(scheduler.pendingScheduleCount, 1)
    }

    // MARK: - Exactly-once completion

    /// The success path: the work decides the outcome and completes once.
    func testSuccessPathCompletesTheTaskExactlyOnce() async {
        let registrar = ScriptedRegistrar()
        let scheduler = SmartFeedBackgroundScheduler(backend: registrar)
        XCTAssertTrue(scheduler.register())
        let owner = ScriptedOwner(report: BackgroundRefreshDemandReport(
            led: 2, attempted: 2, committed: 2, newItems: 7
        ))
        scheduler.configure(ownerProvider: { owner })
        let task = ScriptedBackgroundTask()

        scheduler.handle(task)
        await scheduler.currentTask?.value

        XCTAssertEqual(task.completions, [true], "setTaskCompleted is called once, and with success")
        XCTAssertEqual(scheduler.taskRunCount, 1)
        XCTAssertEqual(scheduler.completionsForwarded, 1)
        XCTAssertEqual(scheduler.completionsIgnored, 0)
        XCTAssertEqual(scheduler.lastOutcome, .committed(sources: 2, newItems: 7))
        XCTAssertEqual(owner.demands.count, 1, "the demand is issued once")
    }

    /// The failure path: no cancellable work, no owner — the task still completes, exactly once.
    func testFailurePathCompletesTheTaskExactlyOnce() async {
        let registrar = ScriptedRegistrar()
        let scheduler = SmartFeedBackgroundScheduler(backend: registrar)
        XCTAssertTrue(scheduler.register())
        // The provider answers with no owner. The handler must not build one: the second `FeedLoader` was
        // P9, and the production default provider would hand it the process's own loader.
        scheduler.configure(ownerProvider: { nil })
        let task = ScriptedBackgroundTask()

        scheduler.handle(task)
        await scheduler.currentTask?.value

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(scheduler.completionsForwarded, 1)
        XCTAssertEqual(scheduler.completionsIgnored, 0)
        guard case .failed(let reason) = scheduler.lastOutcome else {
            return XCTFail("expected a failure outcome, got \(String(describing: scheduler.lastOutcome))")
        }
        XCTAssertTrue(reason.contains("owner"), "the reason names what was missing: \(reason)")
    }

    /// The expiration path: the system takes the task back, the work is cancelled, and the completion the
    /// work would have produced afterwards is swallowed — the handle sees one call in total.
    func testExpirationPathCancelsTheWorkAndCompletesExactlyOnce() async {
        let registrar = ScriptedRegistrar()
        let scheduler = SmartFeedBackgroundScheduler(backend: registrar)
        XCTAssertTrue(scheduler.register())
        let owner = ScriptedOwner()
        owner.delay = .seconds(30)
        scheduler.configure(ownerProvider: { owner })
        let task = ScriptedBackgroundTask()

        scheduler.handle(task)
        task.expire()
        await drainMainActor { scheduler.completionsForwarded == 1 }
        XCTAssertEqual(task.completions, [false], "expiration completes the task as unsuccessful")
        XCTAssertEqual(scheduler.completionsForwarded, 1)

        // The cancelled work returns and asks to complete as well: the request is counted, not forwarded.
        await scheduler.currentTask?.value
        XCTAssertEqual(task.completions, [false], "still exactly one call")
        XCTAssertEqual(scheduler.completionsForwarded, 1)
        XCTAssertEqual(scheduler.completionsIgnored, 1)
        XCTAssertEqual(scheduler.lastOutcome, .cancelledBeforeCommit)
    }

    /// A second expiration is not a second cancellation, and a completion that arrived before expiry is
    /// not undone by it: the task was already answered when the system took it back.
    func testExpirationAfterACompletionDoesNotCompleteTwice() async {
        let registrar = ScriptedRegistrar()
        let scheduler = SmartFeedBackgroundScheduler(backend: registrar)
        XCTAssertTrue(scheduler.register())
        let owner = ScriptedOwner(report: BackgroundRefreshDemandReport(
            led: 1, attempted: 1, committed: 1, newItems: 3
        ))
        scheduler.configure(ownerProvider: { owner })
        let task = ScriptedBackgroundTask()

        scheduler.handle(task)
        await scheduler.currentTask?.value
        XCTAssertEqual(task.completions, [true])

        task.expire()
        task.expire()
        // One expiry completion reaches the latch; the latch has already answered, so it is counted and
        // dropped. The second `expire()` is a no-op at the latch — a repeated expiration is not a second
        // cancellation — so it adds nothing to either count.
        await drainMainActor { scheduler.completionsIgnored == 1 }
        XCTAssertEqual(task.completions, [true], "a completed task is not completed again")
        XCTAssertEqual(scheduler.completionsForwarded, 1)
        XCTAssertEqual(scheduler.completionsIgnored, 1, "the expiry completion was refused")
        XCTAssertEqual(scheduler.lastOutcome, .committed(sources: 1, newItems: 3))
    }

    // MARK: - The outcome a report maps to

    /// "Cancelled before commit" and "committed then cancelled" are told apart by the store's counts,
    /// not by which code path ran.
    func testCancellationOutcomeDependsOnWhetherAnythingCommitted() {
        var beforeCommit = BackgroundRefreshDemandReport()
        beforeCommit.cancelled = true
        XCTAssertEqual(SmartFeedBackgroundScheduler.outcome(for: beforeCommit), .cancelledBeforeCommit)
        XCTAssertFalse(SmartFeedBackgroundScheduler.outcome(for: beforeCommit).isSuccess)

        var afterCommit = BackgroundRefreshDemandReport()
        afterCommit.cancelled = true
        afterCommit.committed = 3
        afterCommit.newItems = 12
        XCTAssertEqual(
            SmartFeedBackgroundScheduler.outcome(for: afterCommit),
            .cancelledAfterCommit(sources: 3, newItems: 12)
        )
        XCTAssertTrue(
            SmartFeedBackgroundScheduler.outcome(for: afterCommit).isSuccess,
            "work that committed before the cancellation is not reported as a failure"
        )

        var presetOnly = BackgroundRefreshDemandReport()
        presetOnly.cancelled = true
        presetOnly.smartFeedsRefreshed = 1
        XCTAssertEqual(
            SmartFeedBackgroundScheduler.outcome(for: presetOnly),
            .cancelledAfterCommit(sources: 0, newItems: 0),
            "a refreshed Smart Feed is committed work too"
        )
    }

    /// A demand whose endpoints were all held by another producer issued no request, and says so
    /// rather than reporting an empty commit.
    func testDemandServicedEntirelyByAnotherProducerReportsSharing() {
        let report = BackgroundRefreshDemandReport(led: 0, shared: 4, servedFresh: 1)
        XCTAssertEqual(
            SmartFeedBackgroundScheduler.outcome(for: report),
            .sharedWithForeground(sources: 4)
        )
        XCTAssertTrue(SmartFeedBackgroundScheduler.outcome(for: report).isSuccess)
        XCTAssertTrue(report.issuedNoRequests)

        XCTAssertEqual(
            SmartFeedBackgroundScheduler.outcome(for: BackgroundRefreshDemandReport()).isSuccess,
            false,
            "nothing to do is not a success: the task reports that it did not refresh"
        )
    }

    // MARK: - The budget matrix, with injected signals

    /// Each condition the plan names changes the demand the scheduler computes. The device is never
    /// read: every row is an injected signal, and the row is the *observed* `lastDemand`.
    func testEachInjectedConditionChangesTheDemandTheSchedulerIssues() async {
        struct Row {
            let name: String
            let conditions: AcquisitionConditions
            let sourceLimit: Int
            let maxConcurrency: Int
            let signals: [AcquisitionSignal]
        }
        let rows: [Row] = [
            Row(name: "unrestricted", conditions: .unrestricted,
                sourceLimit: 6, maxConcurrency: 2, signals: []),
            Row(name: "low power", conditions: AcquisitionConditions(lowPowerMode: true),
                sourceLimit: 3, maxConcurrency: 2, signals: [.lowPowerMode]),
            Row(name: "low data", conditions: AcquisitionConditions(network: .lowDataMode),
                sourceLimit: 3, maxConcurrency: 2, signals: [.lowDataMode]),
            Row(name: "expensive network", conditions: AcquisitionConditions(network: .expensive),
                sourceLimit: 3, maxConcurrency: 2, signals: [.expensiveNetwork]),
            Row(name: "thermal serious", conditions: AcquisitionConditions(thermal: .serious),
                sourceLimit: 3, maxConcurrency: 2, signals: [.thermalSerious]),
            Row(name: "thermal critical", conditions: AcquisitionConditions(thermal: .critical),
                sourceLimit: 1, maxConcurrency: 1, signals: [.thermalCritical]),
            Row(name: "memory pressure", conditions: AcquisitionConditions(memoryPressure: true),
                sourceLimit: 6, maxConcurrency: 1, signals: [.memoryPressure]),
        ]

        for row in rows {
            let scheduler = SmartFeedBackgroundScheduler(backend: ScriptedRegistrar())
            XCTAssertTrue(scheduler.register())
            let owner = ScriptedOwner()
            scheduler.configure(ownerProvider: { owner })
            scheduler.configure(conditions: { row.conditions })

            let task = ScriptedBackgroundTask()
            scheduler.handle(task)
            await scheduler.currentTask?.value

            let demand = scheduler.lastDemand
            XCTAssertEqual(demand?.sourceLimit, row.sourceLimit, "\(row.name) source limit")
            XCTAssertEqual(demand?.maxConcurrency, row.maxConcurrency, "\(row.name) concurrency")
            XCTAssertEqual(demand?.appliedSignals, row.signals, "\(row.name) applied signals")
            XCTAssertEqual(owner.demands.count, 1, "\(row.name): the owner was asked exactly once")
            XCTAssertNotEqual(demand?.deadline, .zero, "\(row.name): the demand carries a deadline")
        }
    }

    /// With no network the demand is refused before the owner is reached: no request, and the task says
    /// it did nothing rather than reporting a failure it did not have.
    func testUnavailableNetworkProducesNoDemandAtAll() async {
        let scheduler = SmartFeedBackgroundScheduler(backend: ScriptedRegistrar())
        XCTAssertTrue(scheduler.register())
        let owner = ScriptedOwner()
        scheduler.configure(ownerProvider: { owner })
        scheduler.configure(conditions: {
            AcquisitionConditions(network: .unavailable, allowsNetwork: false)
        })
        let task = ScriptedBackgroundTask()

        scheduler.handle(task)
        await scheduler.currentTask?.value

        XCTAssertEqual(scheduler.lastDemand?.sourceLimit, 0)
        XCTAssertEqual(owner.demands.count, 0, "the owner was never asked to fetch")
        XCTAssertEqual(task.completions, [false], "nothing was refreshed, so the task did not succeed")
        guard case .nothingToDo = scheduler.lastOutcome else {
            return XCTFail("expected nothingToDo, got \(String(describing: scheduler.lastOutcome))")
        }
    }

    /// The demand the scheduler hands the owner is the pinned baseline adapted by the policy — checked
    /// against the policy directly so the two cannot drift apart.
    func testTheIssuedDemandMatchesThePolicyAppliedToThePinnedBaseline() throws {
        let conditions = AcquisitionConditions(
            lowPowerMode: true,
            network: .expensiveAndConstrained,
            thermal: .serious,
            memoryPressure: true
        )
        let expected = AcquisitionBudgetPolicy.budget(
            baseline: BackgroundRefreshBudget.baseline,
            conditions: conditions
        )
        let demand = BackgroundRefreshBudget.demand(for: conditions)
        XCTAssertEqual(demand.sourceLimit, expected.sourceLimit)
        XCTAssertEqual(demand.maxConcurrency, expected.maxConcurrency)
        XCTAssertEqual(demand.appliedSignals, expected.appliedSignals)
        XCTAssertEqual(demand.deadline, .milliseconds(expected.deadlineMilliseconds))
    }


    /// Lets the scheduler's main-actor hop land before a count is read.
    ///
    /// `BGTask.expirationHandler` is called on a system queue, so the scheduler hop back to the main
    /// actor is part of the contract, not an accident; a test that read the counts immediately would be
    /// measuring its own scheduling instead of the contract.
    private func drainMainActor(_ finished: () -> Bool, iterations: Int = 1_000) async {
        for _ in 0..<iterations {
            if finished() { return }
            await Task.yield()
        }
    }
}

// MARK: - Doubles

/// Records what the scheduler asked the system for, and launches the handler the way the system does.
@MainActor
private final class ScriptedRegistrar: BackgroundTaskRegistering {
    private(set) var registerCount = 0
    private(set) var registeredIdentifiers: [String] = []
    private(set) var submits: [Date] = []
    var registrationResult = true
    var submitError: Error?
    private var launchHandler: ((any BackgroundTaskHandle) -> Void)?

    func register(
        identifier: String,
        launchHandler: @escaping (any BackgroundTaskHandle) -> Void
    ) -> Bool {
        registerCount += 1
        registeredIdentifiers.append(identifier)
        self.launchHandler = launchHandler
        return registrationResult
    }

    func submitAppRefresh(identifier: String, earliestBeginDate: Date) throws {
        if let submitError { throw submitError }
        submits.append(earliestBeginDate)
    }

    /// What `BGTaskScheduler` does when the app-refresh task fires.
    func launch(_ task: any BackgroundTaskHandle) {
        launchHandler?(task)
    }
}

/// Stands in for the `BGAppRefreshTask` the system creates: records every completion, so "exactly once"
/// is a count.
@MainActor
private final class ScriptedBackgroundTask: BackgroundTaskHandle {
    private(set) var completions: [Bool] = []
    var expirationHandler: (() -> Void)?

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    /// What `BGTaskScheduler` does when the window closes.
    func expire() {
        expirationHandler?()
    }
}

/// A demand owner whose answer the test states, and whose work can be made slow enough to cancel.
@MainActor
private final class ScriptedOwner: BackgroundRefreshOwning {
    var report: BackgroundRefreshDemandReport
    var delay: Duration = .zero
    private(set) var demands: [BackgroundRefreshDemand] = []

    init(report: BackgroundRefreshDemandReport = BackgroundRefreshDemandReport()) {
        self.report = report
    }

    func runBackgroundRefresh(_ demand: BackgroundRefreshDemand) async -> BackgroundRefreshDemandReport {
        demands.append(demand)
        var report = self.report
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch {
                // The task was cancelled while the work was in flight. Nothing had been committed by
                // this double, which is what "cancelled before commit" means.
                report.cancelled = true
            }
        }
        return report
    }
}
