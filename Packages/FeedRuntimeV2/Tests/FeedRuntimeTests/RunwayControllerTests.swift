import FeedDomain
import FeedRuntime
import Foundation
import XCTest

/// A scripted offer read. Every call is recorded, so a test asserts *how many* expensive reads happened
/// and how many rows they examined — the measurement plan §12 asks to be reported instead of "it was
/// fast".
actor RunwaySupplySpy: RunwaySupplyObserving {
    private(set) var requests: [RunwaySupplyRequest] = []
    private let script: [RunwaySupplyObservation]

    init(_ script: [RunwaySupplyObservation]) {
        self.script = script.isEmpty ? [.fixture()] : script
    }

    func observeSupply(_ request: RunwaySupplyRequest) async -> RunwaySupplyObservation {
        requests.append(request)
        return script[min(requests.count - 1, script.count - 1)]
    }

    func callCount() -> Int { requests.count }
}

extension RunwaySupplyObservation {
    /// The offer one bounded read reports, with the pool size a real indexed read would examine.
    static func fixture(
        generation: UInt64 = 1,
        canonical: Int = 1_000,
        sequenceable: Int = 40,
        mediaPrepared: Int = 40,
        published: Int = 60,
        examinedRows: Int = 96
    ) -> RunwaySupplyObservation {
        RunwaySupplyObservation(
            canonical: RunwayStockAmount(count: canonical, bytes: nil),
            sequenceable: RunwayStockAmount(count: sequenceable, bytes: nil),
            mediaPrepared: RunwayStockAmount(count: mediaPrepared, bytes: 4_096),
            published: RunwayStockAmount(count: published, bytes: nil),
            supplyGeneration: generation,
            examinedRows: examinedRows
        )
    }
}

/// A scripted refill. Its body is the only place in these tests that would touch Selection, the network
/// or a decode — hence the `stages` counter, which proves the observation path never reached them.
actor RunwayRefillSpy: RunwayRefilling {
    private(set) var requests: [RunwayRefillRequest] = []
    /// Incremented once a call gets past the gate: the "selection + network + decode" stage.
    private(set) var stages = 0
    private(set) var cancellationsObserved = 0
    private(set) var completedStops: [RunwayRefillStop] = []

    private let script: [RunwayRefillOutcome]
    private let holding: Bool
    private let honoursCancellation: Bool
    private var released = false
    private var cancelledCalls: Set<Int> = []
    private var held: [(call: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var enteredWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var completedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(script: [RunwayRefillOutcome], holding: Bool = true, honoursCancellation: Bool = false) {
        self.script = script
        self.holding = holding
        self.honoursCancellation = honoursCancellation
    }

    func refill(_ request: RunwayRefillRequest) async -> RunwayRefillOutcome {
        let call = requests.count
        requests.append(request)
        signalEntered()
        let cancelled = await waitForInput(call: call)
        if cancelled {
            cancellationsObserved += 1
            return RunwayRefillOutcome(
                producedItems: 0,
                producedBytes: 0,
                consumedSequenceable: 0,
                nextOrdinal: request.fromOrdinal,
                stop: .cancelled
            )
        }
        stages += 1
        let outcome = script[min(completedStops.count, script.count - 1)]
        completedStops.append(outcome.stop)
        signalCompleted()
        return outcome
    }

    func request(at index: Int) -> RunwayRefillRequest? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index]
    }

    /// Opens the gate for everything currently held, and for everything that arrives afterwards.
    func release() {
        released = true
        let pending = held
        held = []
        for waiter in pending { waiter.continuation.resume() }
    }

    func waitUntilEntered(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enteredWaiters.append((count, continuation))
        }
    }

    func waitUntilCompleted(_ count: Int) async {
        guard completedStops.count < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completedWaiters.append((count, continuation))
        }
    }

    private func waitForInput(call: Int) async -> Bool {
        guard holding, !released, !cancelledCalls.contains(call) else {
            return cancelledCalls.contains(call)
        }
        if honoursCancellation {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if cancelledCalls.contains(call) || released {
                        continuation.resume()
                    } else {
                        held.append((call, continuation))
                    }
                }
            } onCancel: {
                Task { await self.markCancelled(call) }
            }
        } else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released {
                    continuation.resume()
                } else {
                    held.append((call, continuation))
                }
            }
        }
        return cancelledCalls.contains(call)
    }

    private func markCancelled(_ call: Int) {
        cancelledCalls.insert(call)
        let pending = held.filter { $0.call == call }
        held.removeAll { $0.call == call }
        for waiter in pending { waiter.continuation.resume() }
    }

    private func signalEntered() {
        let satisfied = enteredWaiters.filter { requests.count >= $0.threshold }
        enteredWaiters.removeAll { requests.count >= $0.threshold }
        for waiter in satisfied { waiter.continuation.resume() }
    }

    private func signalCompleted() {
        let satisfied = completedWaiters.filter { completedStops.count >= $0.threshold }
        completedWaiters.removeAll { completedStops.count >= $0.threshold }
        for waiter in satisfied { waiter.continuation.resume() }
    }
}

final class RunwayControllerTests: XCTestCase {
    private func limits(
        downloads: Int = 4,
        decodes: Int = 3,
        pressureDownloads: Int = 1,
        pressureDecodes: Int = 1,
        diskBudgetBytes: Int = 4_096
    ) -> ResourceLimits {
        ResourceLimits(
            downloadConcurrency: downloads,
            decodeConcurrency: decodes,
            pressureDownloadConcurrency: pressureDownloads,
            pressureDecodeConcurrency: pressureDecodes,
            diskBudgetBytes: diskBudgetBytes
        )
    }

    private func governor(_ clock: RunwayTestClock, limits: ResourceLimits? = nil) -> ResourceGovernor {
        ResourceGovernor(limits: limits ?? self.limits(), clock: clock)
    }

    private func controller(
        clock: RunwayTestClock,
        supply: RunwaySupplySpy,
        refilling: RunwayRefillSpy,
        policy: RunwayPolicy = .baseline,
        limits: ResourceLimits? = nil
    ) -> RunwayController {
        RunwayController(
            policy: policy,
            clock: clock,
            supply: supply,
            refilling: refilling,
            governor: governor(clock, limits: limits)
        )
    }

    private func observation(
        _ edition: EditionID,
        lastVisible: Int,
        materializedTail: Int,
        speed: Double = 0,
        at: Date = RunwayFixture.instant
    ) -> RunwayViewportObservation {
        RunwayFixture.observation(
            edition: edition,
            lastVisible: lastVisible,
            materializedTail: materializedTail,
            speed: speed,
            at: at
        )
    }

    private func delivered(
        items: Int = 24,
        bytes: Int = 1_024,
        consumed: Int = 24,
        nextOrdinal: Int
    ) -> RunwayRefillOutcome {
        RunwayRefillOutcome(
            producedItems: items,
            producedBytes: bytes,
            consumedSequenceable: consumed,
            nextOrdinal: nextOrdinal,
            stop: .delivered
        )
    }

    // MARK: one refill per edition

    /// A fling is 200 viewport updates; the runway turns them into *one* refill, coalescing the rest,
    /// and reads the offer once.
    func testAFlingStartsExactlyOneRefillForTheEdition() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(script: [delivered(nextOrdinal: 84)])
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        let activated = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        XCTAssertEqual(activated.counters.expensiveRecomputations, 1)
        XCTAssertEqual(activated.counters.rowsExamined, 96)
        var first = activated

        var last = activated
        for step in 0 ..< 200 {
            let status = await sut.observeViewport(
                observation(edition, lastVisible: 250, materializedTail: 252, speed: 6_000)
            )
            if step == 0 { first = status }
            last = status
        }
        await refill.waitUntilEntered(1)

        let requests = await refill.requests
        XCTAssertEqual(requests.count, 1, "a fling is one request, not one per frame")
        XCTAssertEqual(requests.first?.fromOrdinal, 80)
        XCTAssertEqual(requests.first?.purpose, .readerDemand, "the reader is two cards from the end")
        XCTAssertEqual(requests.first?.itemLimit, 24)
        XCTAssertEqual(requests.first?.byteLimit, 2 * 1024 * 1024)
        XCTAssertEqual(requests.first?.deadline, RunwayFixture.instant.addingTimeInterval(10))

        XCTAssertEqual(first.decision, .refilling(.readerDemand))
        XCTAssertEqual(last.decision, .suppressed(.alreadyInFlight), "the rest coalesced into it")
        XCTAssertEqual(last.counters.refillsInFlight, 1)
        XCTAssertEqual(last.counters.scheduledRefills, 1)
        XCTAssertEqual(last.counters.coalescedDemands, 199)
        XCTAssertEqual(last.counters.cheapUpdates, 200)
        XCTAssertEqual(last.counters.expensiveRecomputations, 1, "no read per viewport update")
        XCTAssertEqual(last.counters.rowsExamined, 96)
        XCTAssertEqual(last.estimate?.level, .strained)

        await refill.release()
        await sut.awaitRefills()
        let settled = await sut.currentStatus()
        XCTAssertEqual(settled.tail, .open(nextOrdinal: 84))
        XCTAssertEqual(settled.counters.refillsInFlight, 0)

        let measured = await sut.observeViewport(
            observation(edition, lastVisible: 250, materializedTail: 252, speed: 6_000)
        )
        await sut.awaitRefills()
        XCTAssertEqual(
            measured.estimate?.p95ReplenishmentLatencyMilliseconds,
            0,
            "the refill's latency is the injected clock's difference"
        )
    }

    // MARK: cheap versus expensive

    /// The expensive read belongs to relevant changes only. 120 viewport updates add zero reads and
    /// zero examined rows; five relevant changes add exactly five reads of 96 rows each.
    func testTheExpensiveOfferIsReadOnlyOnRelevantChanges() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(script: [delivered(nextOrdinal: 84)], holding: false)
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        for _ in 0 ..< 120 {
            _ = await sut.observeViewport(
                observation(edition, lastVisible: 80, materializedTail: 100, speed: 1_000)
            )
        }
        var status = await sut.currentStatus()
        XCTAssertEqual(status.counters.cheapUpdates, 120)
        XCTAssertEqual(status.counters.expensiveRecomputations, 1)
        XCTAssertEqual(status.counters.rowsExamined, 96)
        let observed1 = await supply.callCount()
        XCTAssertEqual(observed1, 1)

        _ = await sut.noteRelevantChange(.exposureAdvanced(revision: 2))
        _ = await sut.noteRelevantChange(.mediaStateChanged)
        _ = await sut.noteRelevantChange(.publishedTailAdvanced(nextOrdinal: 84))
        _ = await sut.noteRelevantChange(.policyReplaced(.baseline))
        status = await sut.noteRelevantChange(.supplyAdvanced(generation: 3))

        XCTAssertEqual(status.counters.expensiveRecomputations, 6, "one per relevant change")
        XCTAssertEqual(status.counters.rowsExamined, 576)
        let observed2 = await supply.callCount()
        XCTAssertEqual(observed2, 6)

        for _ in 0 ..< 60 {
            status = await sut.observeViewport(
                observation(edition, lastVisible: 80, materializedTail: 100, speed: 1_000)
            )
        }
        XCTAssertEqual(status.counters.cheapUpdates, 180)
        XCTAssertEqual(status.counters.expensiveRecomputations, 6)
        XCTAssertEqual(status.counters.rowsExamined, 576)
        XCTAssertEqual(status.tail, .open(nextOrdinal: 84), "the tail advance moved the checkpoint")
    }

    // MARK: latency

    /// Replenishment latency is measured with the injected clock, and the *same* viewport estimates
    /// higher once the link has been slow — the estimate is what makes the runway start earlier.
    func testHighReplenishmentLatencyIsMeasuredWithTheInjectedClock() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(
            script: [delivered(nextOrdinal: 84), RunwayRefillOutcome(
                producedItems: 0,
                producedBytes: 0,
                consumedSequenceable: 0,
                nextOrdinal: 84,
                stop: .exhausted
            )],
            holding: true
        )
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        let before = await sut.observeViewport(
            observation(edition, lastVisible: 96, materializedTail: 100, speed: 2_000)
        )
        XCTAssertEqual(before.estimate?.level, .comfortable)
        XCTAssertNil(before.estimate?.p95ReplenishmentLatencyMilliseconds, "nothing measured yet")

        await refill.waitUntilEntered(1)
        clock.advance(by: 4)
        await refill.release()
        await sut.awaitRefills()

        _ = await sut.observeViewport(
            observation(edition, lastVisible: 96, materializedTail: 100, speed: 2_000)
        )
        await sut.awaitRefills()
        let after = await sut.currentStatus()

        XCTAssertEqual(after.estimate?.p95ReplenishmentLatencyMilliseconds, 4_000)
        XCTAssertGreaterThan(after.estimate?.pressure ?? 0, before.estimate?.pressure ?? 0)
        XCTAssertEqual(after.estimate?.level, .strained, "the same scroll is strained on a slow link")
        XCTAssertEqual(after.tail, .exhausted(atOrdinal: 84))
        XCTAssertEqual(after.counters.cancelledRefills, 0)
    }

    // MARK: exhausted supply

    /// `noSupplyDoesNotLoopOrEraseHistory` (matrix #37, I-17): an empty refill means the edition ended.
    /// The runway says so once, never asks again, invents no availability, and keeps every published
    /// ordinal it had.
    func testNoSupplyDoesNotLoopOrEraseHistory() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let exhausted = RunwayRefillOutcome(
            producedItems: 0,
            producedBytes: 0,
            consumedSequenceable: 0,
            nextOrdinal: 80,
            stop: .exhausted
        )
        let supply = RunwaySupplySpy([.fixture(sequenceable: 0, published: 60)])
        let refill = RunwayRefillSpy(script: [exhausted], holding: false)
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        let first = await sut.observeViewport(
            observation(edition, lastVisible: 100, materializedTail: 102, speed: 4_000)
        )
        XCTAssertEqual(first.decision, .refilling(.readerDemand))
        await sut.awaitRefills()

        let ended = await sut.currentStatus()
        XCTAssertEqual(ended.tail, .exhausted(atOrdinal: 80))
        XCTAssertEqual(ended.stocks.published.count, 60, "the history it had is still reported")
        XCTAssertEqual(ended.stocks.sequenceable.count, 0, "an honest empty pool")
        XCTAssertEqual(ended.stocks.canonical.count, 1_000, "the archive is not availability")

        var last = ended
        for _ in 0 ..< 300 {
            last = await sut.observeViewport(
                observation(edition, lastVisible: 100, materializedTail: 102, speed: 4_000)
            )
        }
        let observed3 = (await refill.requests).count
        XCTAssertEqual(observed3, 1, "exhaustion is reported once, not retried")
        XCTAssertEqual(last.decision, .suppressed(.exhausted))
        XCTAssertEqual(last.counters.scheduledRefills, 1, "one attempt, never a loop")
        XCTAssertEqual(last.tail, .exhausted(atOrdinal: 80), "the checkpoint survives")
        XCTAssertEqual(last.stocks.published.count, 60)
        XCTAssertEqual(last.counters.expensiveRecomputations, 1, "and no query loop either")

        let reopened = await sut.noteRelevantChange(.supplyAdvanced(generation: 2))
        XCTAssertEqual(reopened.tail, .open(nextOrdinal: 80), "more supply continues where it stopped")
        let again = await sut.observeViewport(
            observation(edition, lastVisible: 100, materializedTail: 102, speed: 4_000)
        )
        XCTAssertEqual(again.decision, .refilling(.readerDemand))
        await sut.awaitRefills()
        let resumed = await refill.request(at: 1)
        XCTAssertEqual(resumed?.fromOrdinal, 80, "no gap and no duplicate page")
    }

    // MARK: pressure

    /// A memory warning goes to the governor: concurrency drops, the speculative prefetch is cancelled,
    /// and the page the reader is waiting for survives and lands.
    func testAMemoryWarningCancelsSpeculativeWorkAndKeepsReaderDemand() async throws {
        let clock = RunwayTestClock()
        let visible = try RunwayFixture.edition(1)
        let successor = try RunwayFixture.edition(2)
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(
            script: [delivered(nextOrdinal: 324)],
            holding: true,
            honoursCancellation: true
        )
        let governor = self.governor(clock)
        let sut = RunwayController(
            policy: .baseline,
            clock: clock,
            supply: supply,
            refilling: refill,
            governor: governor
        )

        _ = await sut.activate(edition: visible, context: context, nextOrdinal: 200)
        let prefetch = await sut.observeViewport(
            observation(visible, lastVisible: 191, materializedTail: 200, speed: 4_000)
        )
        XCTAssertEqual(prefetch.decision, .refilling(.prefetch), "nine cards ahead is a speculation")
        await refill.waitUntilEntered(1)

        _ = await sut.activate(edition: successor, context: context, nextOrdinal: 300)
        let demand = await sut.observeViewport(observation(successor, lastVisible: 398, materializedTail: 400))
        XCTAssertEqual(demand.decision, .refilling(.readerDemand), "two cards ahead is demand")

        XCTAssertEqual(demand.counters.refillsInFlight, 2, "one per edition, two editions")
        let observed101 = await governor.speculativeWorkCount
        XCTAssertEqual(observed101, 1)

        let relief = await sut.applyMemoryPressure()

        XCTAssertEqual(relief.outcome.pressure, .memory)
        XCTAssertEqual(relief.outcome.cancelledSpeculativeWork, 1)
        XCTAssertEqual(relief.outcome.downloadConcurrency, 1)
        XCTAssertEqual(relief.outcome.decodeConcurrency, 1)
        XCTAssertEqual(relief.status.counters.cancelledRefills, 1)
        XCTAssertEqual(
            relief.status.counters.refillsInFlight,
            1,
            "the reader-demand refill is still in flight after the warning"
        )
        let observed102 = await refill.cancellationsObserved
        XCTAssertEqual(observed102, 1)
        let observed103 = await refill.completedStops
        XCTAssertEqual(observed103, [], "nothing the reader waited for was cancelled")

        await refill.release()
        await sut.awaitRefills()
        let successorStatus = await sut.currentStatus()
        XCTAssertEqual(successorStatus.tail, .open(nextOrdinal: 324))
        XCTAssertEqual(successorStatus.counters.refillsInFlight, 0)
        let observed104 = await refill.completedStops
        XCTAssertEqual(observed104, [.delivered])

        let visibleStatus = await sut.activate(edition: visible, context: context, nextOrdinal: 200)
        XCTAssertEqual(
            visibleStatus.tail,
            .open(nextOrdinal: 200),
            "a cancelled speculative refill costs no checkpoint"
        )

        _ = await sut.endMemoryPressure()
        let underPressure = await governor.isUnderPressure
        let restoredConcurrency = await governor.downloadConcurrency
        XCTAssertFalse(underPressure, "the warning is over and the governor says so")
        XCTAssertEqual(restoredConcurrency, 4)
    }

    /// `purposeBudgetStopsAcquisitionWithoutLosingCheckpoint` (matrix #36), from the runway: a refill
    /// that stops on its item budget advances the checkpoint by what it delivered, never by the budget.
    func testARefillThatStopsOnItsBudgetKeepsItsCheckpoint() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture(sequenceable: 40, published: 60)])
        let budgetStop = RunwayRefillOutcome(
            producedItems: 10,
            producedBytes: 4_096,
            consumedSequenceable: 10,
            nextOrdinal: 90,
            stop: .itemBudget
        )
        let refill = RunwayRefillSpy(script: [budgetStop], holding: false)
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        _ = await sut.observeViewport(observation(edition, lastVisible: 100, materializedTail: 102))
        await sut.awaitRefills()

        let afterFirst = await sut.currentStatus()
        XCTAssertEqual(afterFirst.tail, .open(nextOrdinal: 90))
        XCTAssertEqual(afterFirst.stocks.sequenceable.count, 30, "the pool paid for what it delivered")
        XCTAssertEqual(afterFirst.stocks.published.count, 60)

        _ = await sut.observeViewport(observation(edition, lastVisible: 100, materializedTail: 102))
        await sut.awaitRefills()

        let resumed = await refill.request(at: 1)
        XCTAssertEqual(resumed?.fromOrdinal, 90, "the next page continues from the delivered end")
        let observed4 = await refill.requests.map(\.fromOrdinal)
        XCTAssertEqual(observed4, [80, 90], "no gap and no overlap")
        let afterSecond = await sut.currentStatus()
        XCTAssertEqual(afterSecond.tail, .open(nextOrdinal: 90))
        XCTAssertEqual(afterSecond.stocks.sequenceable.count, 20)
    }

    /// A refill that reports a cursor behind the one it was asked to continue keeps the checkpoint where
    /// it was: the worst case is a repeated page, never a skipped one.
    func testTheCheckpointNeverGoesBackwards() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let regressed = RunwayRefillOutcome(
            producedItems: 4,
            producedBytes: 512,
            consumedSequenceable: 4,
            nextOrdinal: 70,
            stop: .delivered
        )
        let refill = RunwayRefillSpy(script: [regressed], holding: false)
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        _ = await sut.observeViewport(observation(edition, lastVisible: 100, materializedTail: 102))
        await sut.awaitRefills()

        let status = await sut.currentStatus()
        XCTAssertEqual(status.tail, .open(nextOrdinal: 80), "the cursor did not follow the report down")
        _ = await sut.observeViewport(observation(edition, lastVisible: 100, materializedTail: 102))
        await sut.awaitRefills()
        let resumed = await refill.request(at: 1)
        XCTAssertEqual(resumed?.fromOrdinal, 80)
    }

    /// Teardown stops what is in flight and keeps the checkpoint: the pages the reader already has stay
    /// available, and the next activation continues from the same ordinal.
    func testCancellingRefillsKeepsTheCheckpoint() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(
            script: [delivered(nextOrdinal: 84)],
            holding: true,
            honoursCancellation: true
        )
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        _ = await sut.observeViewport(observation(edition, lastVisible: 100, materializedTail: 102))
        await refill.waitUntilEntered(1)

        await sut.cancelRefills()

        let status = await sut.currentStatus()
        XCTAssertEqual(status.counters.refillsInFlight, 0)
        XCTAssertEqual(status.counters.cancelledRefills, 1)
        XCTAssertEqual(status.tail, .open(nextOrdinal: 80), "teardown loses no checkpoint")
        let observed = await refill.cancellationsObserved
        XCTAssertEqual(observed, 1)
    }

    // MARK: bounded buffers

    /// `frontierRemainsBoundedUnderCatalogGrowth` (matrix #35), from the runway: the outstanding refill
    /// buffer is bounded by items and bytes, and a catalogue a hundred times larger does not grow it.
    func testTheRefillBufferStaysBoundedUnderCatalogGrowth() async throws {
        let clock = RunwayTestClock()
        let context = try RunwayFixture.context()
        let editions = try (1 ... 4).map { try RunwayFixture.edition(Int64($0)) }
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(script: [delivered(nextOrdinal: 224)])
        let policy = RunwayPolicy.baseline
        let sut = controller(clock: clock, supply: supply, refilling: refill, policy: policy)

        var statuses: [RunwayStatus] = []
        for (index, edition) in editions.enumerated() {
            _ = await sut.activate(edition: edition, context: context, nextOrdinal: 200)
            statuses.append(
                await sut.observeViewport(observation(edition, lastVisible: 300, materializedTail: 302))
            )
            XCTAssertLessThanOrEqual(statuses[index].counters.outstandingItems, 48)
            XCTAssertLessThanOrEqual(statuses[index].counters.outstandingBytes, 4 * 1024 * 1024)
        }

        XCTAssertEqual(statuses[0].decision, .refilling(.readerDemand))
        XCTAssertEqual(statuses[1].decision, .refilling(.readerDemand))
        XCTAssertEqual(statuses[2].decision, .suppressed(.bufferBudget), "the item budget is full")
        XCTAssertEqual(statuses[3].decision, .suppressed(.bufferBudget))
        XCTAssertEqual(statuses[3].counters.refillsInFlight, 2)
        XCTAssertEqual(statuses[3].counters.suppressedByBudget, 2)
        XCTAssertEqual(statuses[3].counters.outstandingItems, 48)
        XCTAssertEqual(statuses[3].counters.outstandingBytes, 4 * 1024 * 1024)
        XCTAssertEqual(statuses[3].counters.scheduledRefills, 2, "two admitted, two refused")
        await refill.waitUntilEntered(2)
        let admitted = (await refill.requests).count
        XCTAssertEqual(admitted, 2)

        // A catalogue a hundred times larger changes neither the buffer nor the planned work.
        _ = await sut.noteRelevantChange(.supplyAdvanced(generation: 9))
        for _ in 0 ..< 100 {
            for edition in editions {
                _ = await sut.observeViewport(observation(edition, lastVisible: 300, materializedTail: 302))
            }
        }
        let grown = await sut.currentStatus()
        XCTAssertEqual(grown.stocks.canonical.count, 1_000)
        XCTAssertEqual(grown.counters.refillsInFlight, 2)
        XCTAssertEqual(grown.counters.outstandingItems, 48)
        XCTAssertEqual(grown.counters.outstandingBytes, 4 * 1024 * 1024)
        XCTAssertEqual(grown.counters.scheduledRefills, 2, "growth schedules nothing new")
        let stillAdmitted = (await refill.requests).count
        XCTAssertEqual(stillAdmitted, 2)

        await refill.release()
        await sut.awaitRefills()
        let third = await sut.observeViewport(
            observation(editions[0], lastVisible: 300, materializedTail: 302)
        )
        XCTAssertEqual(third.decision, .refilling(.readerDemand), "the freed buffer admits the next one")
        XCTAssertEqual(third.counters.scheduledRefills, 3)
        XCTAssertLessThanOrEqual(third.counters.outstandingItems, 48)
        await sut.awaitRefills()
        let afterRelease = (await refill.requests).count
        XCTAssertEqual(afterRelease, 3)
    }

    /// Repeated failures at one checkpoint are bounded: after `maximumRefillAttempts` the edition is
    /// degraded, not retried forever, and no availability is invented.
    func testRepeatedFailuresAreBoundedAndDegradeTheEdition() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let failed = RunwayRefillOutcome(
            producedItems: 0,
            producedBytes: 0,
            consumedSequenceable: 0,
            nextOrdinal: 80,
            stop: .failed
        )
        let refill = RunwayRefillSpy(script: [failed], holding: false)
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        var last = await sut.currentStatus()
        for _ in 0 ..< 50 {
            last = await sut.observeViewport(observation(edition, lastVisible: 100, materializedTail: 102))
            await sut.awaitRefills()
        }

        let observed8 = (await refill.requests).count
        XCTAssertEqual(observed8, 3, "three attempts, not fifty")
        XCTAssertEqual(last.tail, .degraded(atOrdinal: 80, attempts: 3))
        XCTAssertEqual(last.decision, .suppressed(.attemptsExhausted))
        XCTAssertEqual(last.counters.failedRefills, 3)
        XCTAssertEqual(last.stocks.published.count, 60, "a failure is not exhaustion and not supply")
    }

    // MARK: the observation path

    /// I-20: the scroll observation path awaits no port. The refill it schedules is suspended inside the
    /// spy — past the gate it would touch Selection, the network and a decode — and the path returned
    /// anyway, with those stages never reached. A regression that awaited the port would hang here.
    func testScrollObservationPathNeverAwaitsSelectionNetworkOrDecode() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(script: [delivered(nextOrdinal: 84)])
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)
        let first = await sut.observeViewport(
            observation(edition, lastVisible: 100, materializedTail: 102, speed: 6_000)
        )
        XCTAssertNotNil(first.estimate, "the estimate came back while the refill was still suspended")

        await refill.waitUntilEntered(1)
        let observed105 = await refill.stages
        XCTAssertEqual(observed105, 0, "no selection, network or decode from a scroll")
        let observed9 = await supply.callCount()
        XCTAssertEqual(observed9, 1, "and no offer read either")

        var last = first
        for _ in 0 ..< 60 {
            last = await sut.observeViewport(
                observation(edition, lastVisible: 100, materializedTail: 102, speed: 6_000)
            )
        }
        let observed106 = await refill.stages
        XCTAssertEqual(observed106, 0)
        let observed10 = (await refill.requests).count
        XCTAssertEqual(observed10, 1)
        XCTAssertEqual(last.counters.coalescedDemands, 60)
        XCTAssertEqual(last.counters.expensiveRecomputations, 1)
        XCTAssertEqual(last.counters.rowsExamined, 96)

        await refill.release()
        await sut.awaitRefills()
        let observed107 = await refill.stages
        XCTAssertEqual(observed107, 1, "the stages belong to the refill, not to the scroll path")
        let observed11 = await supply.callCount()
        XCTAssertEqual(observed11, 1)
    }

    /// An edition that was never adopted schedules nothing and reads nothing: the cheap path reports the
    /// estimate it can compute and promises no checkpoint.
    func testAnObservationForAnUnadoptedEditionQueriesNothing() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let supply = RunwaySupplySpy([.fixture()])
        let refill = RunwayRefillSpy(script: [delivered(nextOrdinal: 84)])
        let sut = controller(clock: clock, supply: supply, refilling: refill)

        let status = await sut.observeViewport(
            observation(edition, lastVisible: 250, materializedTail: 252, speed: 6_000)
        )

        XCTAssertNotNil(status.estimate)
        XCTAssertEqual(status.decision, .idle)
        XCTAssertEqual(status.tail, .unobserved)
        XCTAssertEqual(status.counters.refillsInFlight, 0)
        let observed12 = await supply.callCount()
        XCTAssertEqual(observed12, 0)
        let observed13 = (await refill.requests).count
        XCTAssertEqual(observed13, 0)
        XCTAssertEqual(status.stocks.canonical.isObserved, false)
    }

    // MARK: the governor does the reclaiming

    /// Disk pressure is the governor's business too: the runway states the usage and reports what the
    /// caches released.
    func testDiskPressureIsDelegatedToTheGovernor() async throws {
        let clock = RunwayTestClock()
        let edition = try RunwayFixture.edition()
        let context = try RunwayFixture.context()
        let account = RunwayDiskSpy(releases: [1_024, 512])
        let governor = ResourceGovernor(
            limits: limits(diskBudgetBytes: 3_000),
            clock: clock,
            mediaCache: await account.makeHandlers()
        )
        let sut = RunwayController(
            policy: .baseline,
            clock: clock,
            supply: RunwaySupplySpy([.fixture()]),
            refilling: RunwayRefillSpy(script: [delivered(nextOrdinal: 84)], holding: false),
            governor: governor
        )
        _ = await sut.activate(edition: edition, context: context, nextOrdinal: 80)

        let relief = await sut.applyDiskPressure(usedBytes: 4_096)

        XCTAssertEqual(relief.outcome.pressure, .disk)
        XCTAssertEqual(relief.outcome.collectedBytes, 1_536)
        XCTAssertEqual(relief.outcome.freedBytes, 1_536)
        let observed108 = await account.collectionCalls
        XCTAssertEqual(observed108, 2, "it stops when the caches stop releasing")
        XCTAssertEqual(relief.status.tail, .open(nextOrdinal: 80), "the cursor is untouched")
    }
}

/// The retention side of a composed media cache, scripted with the bytes it releases per call.
actor RunwayDiskSpy {
    private(set) var collectionCalls = 0
    private var releases: [Int]

    init(releases: [Int]) {
        self.releases = releases
    }

    func makeHandlers() -> MediaCachePressureHandlers {
        MediaCachePressureHandlers(
            discardDecodedMaterial: { 0 },
            trimUnpublishedDownloads: { 0 },
            runRetentionCollection: { [weak self] _ in await self?.release() ?? 0 }
        )
    }

    private func release() -> Int {
        collectionCalls += 1
        guard releases.count > 1 else { return releases.first ?? 0 }
        return releases.removeFirst()
    }
}
