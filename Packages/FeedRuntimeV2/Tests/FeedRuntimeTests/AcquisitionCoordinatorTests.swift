import XCTest
import FeedDomain
import FeedStorage
import FeedRuntime

/// Acquisition: leases on shared targets, one pending refill per target, cancellation, and the
/// Admission results the coordinator has to honour (ADR-005 D2, D3, D6; ADR-006 D9).
///
/// Every test runs against a real runtime database and the real Admission engine: the point of the
/// coordinator is that it feeds that write path and does nothing else with canonical state.
final class AcquisitionCoordinatorTests: AcquisitionTestCase {
    private func demand(
        purpose: AcquisitionPurpose = .userInitiated,
        deficit: Int = 1,
        holder: String = "context-1",
        urgency: Int = 0
    ) -> AcquisitionDemand {
        AcquisitionDemand(
            purpose: purpose,
            holderID: holder,
            priority: DemandPriority(urgency: urgency),
            deficit: SupplyDeficit(items: deficit),
            deadline: deadline()
        )
    }

    private func makeCoordinator(
        sources: [AcquisitionTargetID: any AcquisitionSource],
        budgets: AcquisitionBudgetTable = .baseline,
        bound: FrontierBound = FrontierBound()
    ) -> AcquisitionCoordinator {
        AcquisitionCoordinator(
            resolver: AcquisitionSourceResolver.mapping(sources),
            budgets: budgets,
            targetStore: targetStore,
            engine: engine,
            clock: clock,
            bound: bound
        )
    }

    // MARK: - Targets are work, not identity

    /// `targetIsIndependentOfSourceIdentity` (plan §19 #5).
    ///
    /// Two editorial Sources are served by one target, the content it carries is one canonical
    /// record with two memberships, and a demand resolves to the same work whichever source asked
    /// for it: nothing in the plan is derived from, or compared against, a Source.
    func testTargetIsIndependentOfSourceIdentity() async throws {
        let alpha = try insertSource("catalog:alpha")
        let beta = try insertSource("catalog:beta")
        try registerTarget("shared-work", connectorKind: "fixture")
        let target = try acquisitionTarget("shared-work")

        let shape = FixtureObservationShape(memberships: [alpha, beta])
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["story-1"]], shape: shape)
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])
        let summary = await coordinator.run(demand(holder: "context-alpha"), catalogue: [target], in: database)

        XCTAssertEqual(summary.stop, .planCompleted)
        XCTAssertEqual(try rowCount("origin_record"), 1, "one target, one canonical record")
        XCTAssertEqual(try rowCount("source_membership"), 2, "both editorial sources are memberships of it")
        XCTAssertEqual(try scalar("SELECT COUNT(DISTINCT origin_record_id) FROM source_membership"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(DISTINCT source_id) FROM source_membership"), 2)

        // Whichever source holds the demand, the operational work the planner produces is the same.
        let planner = AcquisitionPlanner()
        var frontier = AcquisitionFrontier()
        let forAlpha = AcquisitionDemand(
            purpose: .activeRunway, holderID: "context-alpha",
            deficit: SupplyDeficit(items: 1), deadline: deadline()
        )
        let forBeta = AcquisitionDemand(
            purpose: .activeRunway, holderID: "context-beta",
            deficit: SupplyDeficit(items: 1), deadline: deadline()
        )
        frontier.rebuild(catalogue: [target], demand: forAlpha, budget: AcquisitionPurpose.activeRunway.budget)
        let alphaPlan = planner.plan(demand: forAlpha, frontier: frontier, usage: .zero, now: FixtureInstant.epoch)
        frontier.rebuild(catalogue: [target], demand: forBeta, budget: AcquisitionPurpose.activeRunway.budget)
        let betaPlan = planner.plan(demand: forBeta, frontier: frontier, usage: .zero, now: FixtureInstant.epoch)

        XCTAssertEqual(alphaPlan.work.map(\.target), betaPlan.work.map(\.target))
        XCTAssertEqual(alphaPlan.work.map(\.target.id), [target.id])
    }

    // MARK: - Sharing

    /// `twoSourcesShareTargetWithoutDuplicateWork` (plan §19 #6; `invariant 4`).
    ///
    /// Two demands for one target share the single pending refill: one pull, one admission, and each
    /// holder keeps its own lease until it releases it.
    func testTwoSourcesShareTargetWithoutDuplicateWork() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["shared-1"]])
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])
        let leases = ValueProbe<Int>()
        let slot = TaskSlot()
        let database = database!

        // The second demand arrives from inside the first demand's pull, so it is parked on the
        // pending refill before that pull returns: no sleep, no race.
        let betaDemand = demand(holder: "context-beta")
        let alphaDemand = demand(holder: "context-alpha")
        await connector.setOnPull { _ in
            await slot.start { await coordinator.run(betaDemand, catalogue: [target], in: database) }
            _ = await coordinator.awaitPendingRefillWaiters(for: target.id)
            await leases.record(await coordinator.leaseCount(for: target.id))
        }

        async let alpha = coordinator.run(alphaDemand, catalogue: [target], in: database)
        let beta = await slot.value()
        let alphaSummary = await alpha

        let pullCount = await connector.pullCount
        XCTAssertEqual(pullCount, 1, "the target's work is done once")
        XCTAssertEqual(try rowCount("origin_record"), 1)
        XCTAssertEqual(try rowCount("admission_batch"), 1)
        XCTAssertEqual(alphaSummary.admittedBatches, 1)
        XCTAssertEqual(alphaSummary.pulls, 1)
        XCTAssertEqual(beta?.admittedBatches, 1, "the second demand is served by the same refill")
        XCTAssertEqual(beta?.pulls, 0, "the second demand paid for no request of its own")
        let leaseCountsWhileInFlight = await leases.recorded()
        XCTAssertEqual(leaseCountsWhileInFlight, [2], "both contexts held a lease while the refill was in flight")
        let leasesAfterBothRuns = await coordinator.leaseCount(for: target.id)
        XCTAssertEqual(leasesAfterBothRuns, 0, "each run releases its own lease")
    }

    /// Abandoning one context leaves another's interest untouched: the target stops only when its
    /// last lease is gone (ADR-005 D6; `invariant 4`).
    func testAbandoningOneLeaseDoesNotReleaseAnother() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let coordinator = makeCoordinator(sources: [target.id: FakeFiniteConnector(target: target, script: .init())])

        let alpha = AcquisitionLease(
            targetID: target.id, holderID: "context-alpha", purpose: .userInitiated,
            generation: 1, bindingRevision: 1
        )
        let beta = AcquisitionLease(
            targetID: target.id, holderID: "context-beta", purpose: .activeRunway,
            generation: 1, bindingRevision: 1
        )

        let afterAcquiringAlpha = await coordinator.acquireLease(alpha)
        XCTAssertEqual(afterAcquiringAlpha, 1)
        let afterAcquiringBeta = await coordinator.acquireLease(beta)
        XCTAssertEqual(afterAcquiringBeta, 2)
        let afterReacquiringAlpha = await coordinator.acquireLease(alpha)
        XCTAssertEqual(afterReacquiringAlpha, 2, "one holder has one lease per purpose")
        let afterReleasingAlpha = await coordinator.releaseLease(alpha)
        XCTAssertEqual(afterReleasingAlpha, 1, "beta's interest survives alpha's departure")
        let remainingLeases = await coordinator.leaseCount(for: target.id)
        XCTAssertEqual(remainingLeases, 1)
        let remainingHolders = await coordinator.holders(of: target.id).map(\.holderID)
        XCTAssertEqual(remainingHolders, ["context-beta"])
        let afterReleasingBeta = await coordinator.releaseLease(beta)
        XCTAssertEqual(afterReleasingBeta, 0)
        let leasesAfterBothReleased = await coordinator.leaseCount(for: target.id)
        XCTAssertEqual(leasesAfterBothReleased, 0)
    }

    /// `speculative` is the first category shed under pressure, then `backgroundMaintenance`, and
    /// `userInitiated` last (ADR-005 D9).
    func testSheddingReleasesSpeculativeFirst() async throws {
        try registerTarget("work-0")
        try registerTarget("work-1")
        try registerTarget("work-2")
        let first = try acquisitionTarget("work-0")
        let second = try acquisitionTarget("work-1")
        let third = try acquisitionTarget("work-2")
        let coordinator = makeCoordinator(sources: [:])

        let speculative = AcquisitionLease(
            targetID: first.id, holderID: "warm-up", purpose: .speculative,
            generation: 1, bindingRevision: 1
        )
        let maintenance = AcquisitionLease(
            targetID: second.id, holderID: "background", purpose: .backgroundMaintenance,
            generation: 1, bindingRevision: 1
        )
        let reader = AcquisitionLease(
            targetID: third.id, holderID: "reader", purpose: .userInitiated,
            generation: 1, bindingRevision: 1
        )
        for lease in [speculative, maintenance, reader] { await coordinator.acquireLease(lease) }

        let released = await coordinator.shedUnderPressure(keeping: 1)
        XCTAssertEqual(released.map(\.purpose), [.speculative, .backgroundMaintenance])
        let readerLeases = await coordinator.leaseCount(for: third.id)
        XCTAssertEqual(readerLeases, 1, "the reader keeps its work")
        let nothingLeftToShed = await coordinator.shedUnderPressure(keeping: 1).isEmpty
        XCTAssertTrue(nothingLeftToShed, "nothing left to shed")
    }

    // MARK: - Revocation and late streams

    /// `revokedStreamCannotMutateSupply` (plan §19 #30; `invariant 5`, `I-12`).
    ///
    /// A batch produced before the revocation arrives after it, carrying the lease epoch it was
    /// produced against. Admission refuses it, and no canonical row, projection or checkpoint moves.
    func testRevokedStreamCannotMutateSupply() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let targetID = target.id
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["rev-1"], ["rev-2"]])
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])
        let database = database!

        let first = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(first.stop, .planCompleted)
        XCTAssertEqual(try checkpointRevision(), 1)

        // The revocation lands while the next batch is already being produced.
        await connector.setOnPull { _ in
            _ = try? await coordinator.revoke(targetID, in: database)
        }
        let before = try dump(Self.contentTables)
        let late = await coordinator.run(demand(), catalogue: [target], in: database)
        let after = try dump(Self.contentTables)

        XCTAssertEqual(late.stop, .refused(.staleTarget(generation: 1)))
        XCTAssertEqual(late.refusedBatches, 1)
        XCTAssertEqual(late.admittedBatches, 0)
        XCTAssertEqual(try checkpointRevision(), 1, "a refused batch must not advance the checkpoint")
        XCTAssertEqual(before, after, "a stale stream writes no canonical row, projection or checkpoint")
        let deliveredBatches = await connector.delivered.count
        XCTAssertEqual(deliveredBatches, 2, "the late batch really was produced")
        let leasesAfterRevocation = await coordinator.leaseCount(for: targetID)
        XCTAssertEqual(leasesAfterRevocation, 0, "the revocation released the local leases")

        // Once the revocation is durable, no further pull is issued for that target at all.
        let afterwards = await coordinator.run(demand(deficit: 4), catalogue: [target], in: database)
        XCTAssertEqual(afterwards.stop, .degraded(.revokedTargets(1)))
        XCTAssertEqual(afterwards.pulls, 0)
        let pullsAfterRefusal = await connector.pullCount
        XCTAssertEqual(pullsAfterRefusal, 2, "a revoked target is not pulled again")
    }

    /// A configuration change moves the binding revision, so a batch produced against the previous
    /// one is stale even though nothing was cancelled (ADR-005 D10; ADR-006 D1).
    func testBindingRevisionChangeInvalidatesTheLateBatch() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let targetID = target.id
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["br-1"], ["br-2"]])
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])
        let database = database!
        let store = targetStore

        let first = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(first.stop, .planCompleted)

        await connector.setOnPull { _ in
            _ = try? store.setBindingRevision(2, for: targetID, in: database)
        }
        let before = try dump(Self.contentTables)
        let late = await coordinator.run(demand(), catalogue: [target], in: database)
        let after = try dump(Self.contentTables)

        XCTAssertEqual(late.stop, .refused(.staleTarget(generation: 1)))
        XCTAssertEqual(late.admittedBatches, 0)
        XCTAssertEqual(try checkpointRevision(), 1)
        XCTAssertEqual(before, after)
    }

    /// Work planned against a configuration that has already been replaced is not run at all: the
    /// coordinator re-reads the durable row before pulling (ADR-005 D10).
    func testAStaleCatalogueIsNotRunAtAll() async throws {
        try registerTarget()
        let stale = try acquisitionTarget(bindingRevision: 1)
        _ = try targetStore.setBindingRevision(2, for: stale.id, in: database)
        let connector = FakeFiniteConnector(
            target: stale,
            script: FakeFiniteConnector.Script(pages: [["stale-1"]])
        )
        let coordinator = makeCoordinator(sources: [stale.id: connector])

        let summary = await coordinator.run(demand(), catalogue: [stale], in: database)
        XCTAssertEqual(summary.stop, .degraded(.bindingChanged(stale.id)))
        let pullsForStalePlan = await connector.pullCount
        XCTAssertEqual(pullsForStalePlan, 0)
        XCTAssertEqual(try rowCount("origin_record"), 0)
    }

    /// A batch that arrives after the caller cancelled is not admitted: cancellation saves work and
    /// never grants authority, and the fixture really did emit it (ADR-006 D9).
    func testLateEmissionAfterCancellationIsNotAdmitted() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["late-1"]])
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])
        let database = database!
        let cancellation = CancellationSlot()
        let request = demand()

        await connector.setOnPull { _ in await cancellation.cancelNow() }
        let task = Task { await coordinator.run(request, catalogue: [target], in: database) }
        await cancellation.hold(task)
        let summary = await task.value

        XCTAssertEqual(summary.stop, .cancelled)
        XCTAssertEqual(summary.admittedBatches, 0)
        XCTAssertEqual(summary.pulls, 1)
        let deliveredAfterCancellation = await connector.delivered.count
        XCTAssertEqual(deliveredAfterCancellation, 1, "the stream emitted the batch anyway")
        XCTAssertEqual(try checkpointRevision(), 0)
        XCTAssertEqual(try rowCount("origin_record"), 0)
    }

    // MARK: - Budgets and checkpoints

    /// `purposeBudgetStopsAcquisitionWithoutLosingCheckpoint` (plan §19 #36; `invariant 11`, `I-19`).
    ///
    /// The purpose stops at its own byte budget without overshooting it, and the checkpoint it
    /// leaves is exactly where the next demand resumes.
    func testPurposeBudgetStopsAcquisitionWithoutLosingCheckpoint() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let shape = FixtureObservationShape(bodyPadding: 100)

        // Predict one page's cost exactly, so the budget stops at the byte rather than near it.
        let sample = AcquisitionPull(
            targetID: target.id,
            generation: target.generation,
            bindingRevision: target.bindingRevision,
            leaseEpoch: 0,
            checkpoint: nil,
            checkpointRevision: 0,
            purpose: .activeRunway,
            limit: AcquisitionLimit(maxItems: 1, maxBytes: 4096, deadline: deadline())
        )
        let pageCost = AcquisitionByteAccounting.bytes(of: try FixtureBatchIdentity.makeBatch(
            sequence: 1,
            observations: [try fixtureObservation(
                object: "obj-001",
                version: FixtureVersioning.versionKey(object: "obj-001", emission: 1),
                shape: shape
            )],
            request: sample
        ))
        XCTAssertGreaterThan(pageCost, 0)

        let runway = PurposeBudget(
            targets: 2, requests: 8, bytes: 3 * pageCost, hosts: 4, connections: 2,
            timeLimit: 15, cancellationOrder: 3
        )
        let pages = (1...6).map { ["obj-\(String(format: "%03d", $0))"] }
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: pages, shape: shape)
        )
        let coordinator = makeCoordinator(
            sources: [target.id: connector],
            budgets: AcquisitionBudgetTable([.activeRunway: runway])
        )

        let stopped = await coordinator.run(demand(purpose: .activeRunway, deficit: 6), catalogue: [target], in: database)
        XCTAssertEqual(stopped.stop, .budgetStop(.activeRunway))
        XCTAssertEqual(stopped.pulls, 3)
        XCTAssertEqual(stopped.bytes, runway.bytes, "the purpose stops at its budget, it does not overshoot it")
        let pullsAfterBudgetStop = await connector.pullCount
        XCTAssertEqual(pullsAfterBudgetStop, 3, "no pull is issued once the budget is spent")
        XCTAssertEqual(try checkpointRevision(), 3, "the budget stop leaves the checkpoint where it stopped")

        let runwayUsage = await coordinator.usage(for: .activeRunway)
        XCTAssertEqual(runwayUsage.requests, 3, "every request is attributed to the purpose that paid for it")
        XCTAssertEqual(runwayUsage.bytes, runway.bytes)
        XCTAssertEqual(runwayUsage.targets, 1)

        // A budget stop is a window, not a permanent state: the next window for the same purpose
        // resumes the same work from the checkpoint it stopped at.
        await coordinator.resetUsage(for: .activeRunway)
        let nextWindow = await coordinator.run(demand(purpose: .activeRunway, deficit: 1), catalogue: [target], in: database)
        XCTAssertEqual(nextWindow.stop, .planCompleted)
        let checkpoints = await connector.receivedCheckpoints
        XCTAssertEqual(checkpoints.count, 4)
        XCTAssertEqual(checkpoints.last ?? nil, try FixtureBatchIdentity.proposedCheckpoint(sequence: 3))
        XCTAssertEqual(try checkpointRevision(), 4)
        XCTAssertEqual(try rowCount("origin_record"), 4, "the stream continued; page 1 was not replayed")
    }

    // MARK: - Exhaustion

    /// `noSupplyDoesNotLoopOrEraseHistory` (plan §19 #37; `invariant 13`, `I-16`).
    ///
    /// Exhausted supply is a reported state: no further pull is issued and the history ingested so
    /// far is untouched.
    func testNoSupplyDoesNotLoopOrEraseHistory() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["only-1"]])
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])

        let first = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(first.stop, .planCompleted)
        XCTAssertEqual(try rowCount("origin_record"), 1)
        let history = try dump()

        // The episode that discovers the end of the stream, and then the state it leaves behind.
        let ending = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(ending.stop, .planCompleted)
        let exhausted = await coordinator.run(demand(), catalogue: [target], in: database)

        XCTAssertEqual(exhausted.stop, .exhausted)
        XCTAssertEqual(exhausted.pulls, 0)
        let pullsAtExhaustion = await connector.pullCount
        XCTAssertEqual(pullsAtExhaustion, 2, "one page, one end-of-stream report, nothing after")
        let frontierStateAfterExhaustion = await coordinator.frontierState
        XCTAssertEqual(frontierStateAfterExhaustion, .exhausted)
        XCTAssertEqual(try dump(), history, "exhaustion reports a state; it does not erase history")
    }

    /// A source with nothing at all ends the episode and is reported as exhaustion, with no rows.
    func testEmptySupplyIsReportedAsExhaustedWithoutRows() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeFiniteConnector(target: target, script: FakeFiniteConnector.Script(pages: []))
        let coordinator = makeCoordinator(sources: [target.id: connector])

        let first = await coordinator.run(demand(deficit: 4), catalogue: [target], in: database)
        XCTAssertEqual(first.stop, .planCompleted)
        let pullsAfterEmptyStream = await connector.pullCount
        XCTAssertEqual(pullsAfterEmptyStream, 1, "an empty stream is one pull, not a loop")

        let second = await coordinator.run(demand(deficit: 4), catalogue: [target], in: database)
        XCTAssertEqual(second.stop, .exhausted)
        XCTAssertEqual(second.pulls, 0)
        XCTAssertEqual(try rowCount("origin_record"), 0)
        XCTAssertEqual(try rowCount("admission_batch"), 0)
        XCTAssertEqual(try checkpointRevision(), 0)
    }

    /// A transport failure ends the episode with an explicit reason and no retry loop; the next
    /// demand decides whether to try again (ADR-005 D8, D9).
    func testTransportFailureStopsTheEpisodeWithoutMutatingSupply() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["err-1"], ["err-2"]], errorAtPage: 1)
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])

        let first = await coordinator.run(demand(deficit: 4), catalogue: [target], in: database)
        XCTAssertEqual(first.stop, .transportFailure(target.id))
        XCTAssertEqual(first.admittedBatches, 1)
        let pullsAfterFailure = await connector.pullCount
        XCTAssertEqual(pullsAfterFailure, 2, "one page, one failure: nothing retries inside the episode")
        XCTAssertEqual(try checkpointRevision(), 1)
        let degradationAfterFailure = await coordinator.degradationReason
        XCTAssertEqual(degradationAfterFailure, .transportFailure(target.id))

        let before = try dump(Self.contentTables)
        let second = await coordinator.run(demand(deficit: 4), catalogue: [target], in: database)
        XCTAssertEqual(second.stop, .transportFailure(target.id))
        let pullsAfterSecondFailure = await connector.pullCount
        XCTAssertEqual(pullsAfterSecondFailure, 3, "the second episode pulls once and stops again")
        XCTAssertEqual(try dump(Self.contentTables), before)
    }

    // MARK: - Replay and empty pages

    /// A replayed batch is free: no canonical mutation and no supply increment. An empty page is a
    /// valid, content-free page that advances the checkpoint (ADR-005 D12, D16; ADR-006 D2).
    func testReplayIsFreeAndAnEmptyPageAdvancesTheCheckpoint() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["rep-1"], []], replayAfterPage: 0)
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])

        let summary = await coordinator.run(demand(deficit: 4), catalogue: [target], in: database)

        XCTAssertEqual(summary.stop, .planCompleted)
        XCTAssertEqual(summary.admittedBatches, 2, "the page and the empty page")
        XCTAssertEqual(summary.duplicateBatches, 1, "the replay")
        XCTAssertEqual(summary.admittedObservations, 1)
        let pullsAfterReplayRun = await connector.pullCount
        XCTAssertEqual(pullsAfterReplayRun, 4, "page, replay, empty page, end of stream")
        XCTAssertEqual(try rowCount("origin_record"), 1)
        XCTAssertEqual(try rowCount("origin_revision"), 1, "a replay appends no revision")
        XCTAssertEqual(try scalar("SELECT value FROM supply_generation WHERE id = 1"), 1, "a replay moves no supply")
        XCTAssertEqual(try checkpointRevision(), 2, "the empty page still advanced the checkpoint")
    }

    /// A connector that proposes no checkpoint advances none, whatever it admitted (ADR-005 D11).
    func testABatchWithoutACheckpointDoesNotAdvanceIt() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeFiniteConnector(
            target: target,
            script: FakeFiniteConnector.Script(pages: [["np-1"]], advanceCheckpoint: false)
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])

        let summary = await coordinator.run(demand(deficit: 4), catalogue: [target], in: database)

        XCTAssertEqual(summary.admittedBatches, 1)
        XCTAssertEqual(try rowCount("origin_record"), 1)
        XCTAssertEqual(try checkpointRevision(), 0)
    }

    // MARK: - Streaming

    /// The producer is suspended by the mailbox bound rather than racing ahead, and nothing is
    /// dropped to stay bounded (ADR-005 D3; `invariant 3`).
    func testStreamingProducerSuspendsAtTheBoundedMailboxAndLosesNothing() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeStreamingConnector(
            target: target,
            script: [
                .burst(["s-1", "s-2"]),
                .burst(["s-3", "s-4"]),
                .burst(["s-5", "s-6"]),
            ],
            capacity: 1
        )
        await connector.start()
        await connector.awaitProducerParked()

        let parkedBeforeAnyPull = await connector.producerIsParked
        XCTAssertTrue(parkedBeforeAnyPull, "the producer is suspended, not racing ahead")
        let bufferedBeforeAnyPull = await connector.bufferedSteps
        XCTAssertEqual(bufferedBeforeAnyPull, 1)
        let producedBeforeAnyPull = await connector.producedStepCount
        XCTAssertEqual(producedBeforeAnyPull, 1, "the producer cannot advance past the bound")
        let stepsRemainingBeforeAnyPull = await connector.stepsRemaining
        XCTAssertEqual(stepsRemainingBeforeAnyPull, 2)
        let peakBufferedBeforeAnyPull = await connector.peakBufferedStepCount
        XCTAssertEqual(peakBufferedBeforeAnyPull, 1)

        let coordinator = makeCoordinator(sources: [target.id: connector])
        let summary = await coordinator.run(demand(deficit: 6), catalogue: [target], in: database)
        await connector.awaitProducerFinished()

        XCTAssertEqual(summary.stop, .planCompleted)
        XCTAssertEqual(summary.admittedObservations, 6)
        XCTAssertEqual(summary.pulls, 3)
        let deliveredBatchesAfterRun = await connector.delivered.count
        XCTAssertEqual(deliveredBatchesAfterRun, 3)
        XCTAssertEqual(try rowCount("origin_record"), 6, "every scripted event was delivered: nothing was dropped")
        let producedAfterRun = await connector.producedStepCount
        XCTAssertEqual(producedAfterRun, 3)
        let stepsRemainingAfterRun = await connector.stepsRemaining
        XCTAssertEqual(stepsRemainingAfterRun, 0)
        let peakBufferedAfterRun = await connector.peakBufferedStepCount
        XCTAssertEqual(peakBufferedAfterRun, 1, "the mailbox never exceeded its bound")
        let bufferedAfterRun = await connector.bufferedSteps
        XCTAssertEqual(bufferedAfterRun, 0)
        await connector.stop()
    }

    /// A discontinuity ends the episode with the durable checkpoint intact, and the next demand
    /// resumes from it (ADR-005 D11; `invariant 11`).
    func testDisconnectStopsTheRunAndTheNextDemandResumesFromTheCheckpoint() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeStreamingConnector(
            target: target,
            script: [.burst(["d-1"]), .discontinuity, .burst(["d-2"])],
            capacity: 2
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])

        let disconnected = await coordinator.run(demand(deficit: 8), catalogue: [target], in: database)
        XCTAssertEqual(disconnected.stop, .degraded(.streamDisconnected(target.id)))
        XCTAssertEqual(disconnected.admittedBatches, 1)
        XCTAssertEqual(try checkpointRevision(), 1, "a discontinuity commits nothing")
        XCTAssertEqual(try storedCheckpoint()?.blob, FixtureBatchIdentity.checkpointToken(sequence: 1))

        let resumed = await coordinator.run(demand(deficit: 1), catalogue: [target], in: database)
        XCTAssertEqual(resumed.stop, .planCompleted)
        let checkpoints = await connector.receivedCheckpoints
        XCTAssertEqual(checkpoints.count, 3)
        XCTAssertEqual(
            checkpoints.last ?? nil,
            try FixtureBatchIdentity.proposedCheckpoint(sequence: 1),
            "the reconnection resumes from the durable checkpoint"
        )
        XCTAssertEqual(try checkpointRevision(), 2)
        XCTAssertEqual(try rowCount("origin_record"), 2)
        await connector.stop()
    }

    /// A representation the connector knows is older is recorded without becoming current: the
    /// runtime never interprets a version key to decide precedence (ADR-006 D3, D4).
    func testOutOfOrderRevisionIsPreservedWithoutBecomingCurrent() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeStreamingConnector(
            target: target,
            script: [.burst(["o-1"]), .olderRevision("o-1"), .burst(["o-2"])],
            capacity: 2
        )
        let coordinator = makeCoordinator(sources: [target.id: connector])

        let summary = await coordinator.run(demand(deficit: 3), catalogue: [target], in: database)
        await connector.stop()

        XCTAssertEqual(summary.admittedBatches, 3)
        XCTAssertEqual(try rowCount("origin_record"), 2)
        XCTAssertEqual(try rowCount("origin_revision"), 3, "the older representation is kept as a revision")
        let firstRecord = try scalar("""
            SELECT id FROM origin_record
            WHERE connector_namespace = 'fixture.connector' AND scope_key = 'fixture-feed'
            ORDER BY id LIMIT 1
            """)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM origin_revision WHERE origin_record_id = \(firstRecord)"),
            2,
            "the older representation was preserved for the record it belongs to"
        )
        XCTAssertEqual(
            try scalar("SELECT current_revision_id FROM origin_record WHERE id = \(firstRecord)"),
            1,
            "the older representation did not become current: only the connector declares precedence"
        )
    }

    // MARK: - The domain port

    /// The PR-01/PR-11 domain port (`FeedConnector`, one bounded fetch) reaches the same pull surface
    /// through a bridge, and a one-shot connector ends its stream instead of being pulled forever.
    func testDomainPortConnectorRunsThroughTheSamePullSurface() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let observations = [try fixtureObservation(object: "port-1", version: "r1")]
        let domainConnector = DomainPortConnector(
            targetID: target.id,
            observations: observations,
            batchID: "port-batch-1"
        )
        let coordinator = makeCoordinator(sources: [target.id: FeedConnectorSource(domainConnector)])

        let first = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(first.stop, .planCompleted)
        XCTAssertEqual(first.admittedBatches, 1)
        XCTAssertEqual(try rowCount("origin_record"), 1)
        XCTAssertEqual(try checkpointRevision(), 0, "a connector that proposes no checkpoint advances none")

        let second = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(second.stop, .planCompleted)
        XCTAssertEqual(second.admittedBatches, 0, "the one-shot stream ends after its single batch")
        XCTAssertEqual(try rowCount("origin_record"), 1)

        let third = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(third.stop, .exhausted)
    }

    /// A domain-port batch stamped for another generation is refused by the bridge instead of being
    /// restamped: a stamp the runtime cannot validate is never passed on (ADR-006 D1).
    func testDomainPortBatchForAnotherGenerationIsRefused() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let domainConnector = DomainPortConnector(
            targetID: target.id,
            observations: [try fixtureObservation(object: "port-2", version: "r1")],
            batchID: "port-batch-2",
            generation: 7
        )
        let coordinator = makeCoordinator(sources: [target.id: FeedConnectorSource(domainConnector)])

        let summary = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(summary.stop, .transportFailure(target.id))
        XCTAssertEqual(try rowCount("origin_record"), 0)
    }

    /// A target with no composed connector is reported as degraded rather than crashing an episode.
    func testMissingSourceIsReportedAsDegraded() async throws {
        try registerTarget()
        // The catalogue entry names a connector kind the composition root did not compose a
        // connector for. Dispatch is a compile-time decision taken there (ADR-005 D2), and a target
        // nothing serves is reported rather than run.
        let target = try acquisitionTarget(connectorKind: "rss")
        let coordinator = AcquisitionCoordinator(
            resolver: AcquisitionSourceResolver { composed in
                composed.connectorKind == "fixture"
                    ? FakeFiniteConnector(target: composed, script: .init())
                    : nil
            },
            targetStore: targetStore,
            engine: engine,
            clock: clock
        )

        let summary = await coordinator.run(demand(), catalogue: [target], in: database)
        XCTAssertEqual(summary.stop, .degraded(.missingSource(target.id)))
        XCTAssertEqual(summary.pulls, 0)
    }

    /// A source that keeps re-sending what the ledger already holds ends the item, instead of spending
    /// the purpose's whole request budget rediscovering that the stream has not advanced.
    ///
    /// The threshold is two consecutive replays, and the first one is why it is a threshold at all: a
    /// single replay is the lost-response case ADR-006 D2 describes, and the stream is expected to
    /// continue past it (`testReplayIsFreeAndAnEmptyPageAdvancesTheCheckpoint` scripts exactly that).
    /// The second in a row is a source with nothing left to say. Before this, the loop spent the whole
    /// request budget on it — 24 pulls where the design intends three (baseline §8.55).
    func testAStuckSourceEndsTheItemAfterTwoConsecutiveReplays() async throws {
        try registerTarget()
        let target = try acquisitionTarget()
        let request = AcquisitionPull(
            targetID: target.id,
            generation: target.generation,
            bindingRevision: target.bindingRevision,
            leaseEpoch: 0,
            checkpoint: nil,
            checkpointRevision: 0,
            purpose: .activeRunway,
            limit: AcquisitionLimit(maxItems: 1, maxBytes: 4096, deadline: deadline())
        )
        let repeated = try FixtureBatchIdentity.makeBatch(
            sequence: 1,
            observations: [try fixtureObservation(object: "stuck-1", version: "r1")],
            request: request
        )
        let coordinator = makeCoordinator(sources: [target.id: StuckSource(batch: repeated)])

        let summary = await coordinator.run(demand(deficit: 8), catalogue: [target], in: database)

        XCTAssertEqual(summary.admittedBatches, 1, "the page is admitted once")
        XCTAssertEqual(summary.duplicateBatches, 2, "two re-deliveries, both answered as replays")
        XCTAssertEqual(summary.pulls, 3, "delivery, replay, replay — not the whole request budget")
        XCTAssertEqual(summary.stop, .planCompleted, "the item ends; the plan's other targets still run")
        XCTAssertEqual(try rowCount("origin_revision"), 1, "no replay appended a revision")
    }
}

/// The smallest implementation of the PR-01 domain port: one unconditional, bounded fetch.
private struct DomainPortConnector: FeedConnector {
    let targetID: AcquisitionTargetID
    let observations: [AcquisitionObservation]
    let batchID: String
    var generation: UInt64 = 1

    func acquire(limit: AcquisitionLimit) async throws -> AcquisitionBatch {
        AcquisitionBatch(
            batchID: batchID,
            fingerprint: String(repeating: "0", count: 64),
            targetID: targetID,
            generation: generation,
            observations: Array(observations.prefix(limit.maxItems))
        )
    }
}

/// A source with nothing left to say: it re-sends the same batch for as long as it is pulled, which is
/// what a connector does when the upstream is unchanged and it has no way to report it.
private struct StuckSource: AcquisitionSource {
    let batch: AcquisitionBatch

    func pull(_ request: AcquisitionPull) async throws -> AcquisitionSourceEvent {
        .batch(batch)
    }
}
