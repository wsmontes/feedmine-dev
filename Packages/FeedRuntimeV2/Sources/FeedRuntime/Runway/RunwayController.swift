import FeedDomain
import Foundation

/// The cheap read of the offer: what a refill could still take for one context and edition.
///
/// It is a port because it is the one expensive thing the runway does, and the plan's rule is that it
/// happens per *relevant change*, never per viewport update (plan §12). PR-13/PR-14 wire it to
/// Selection's indexed pool; the tests wire it to a spy that counts invocations and rows.
public protocol RunwaySupplyObserving: Sendable {
    func observeSupply(_ request: RunwaySupplyRequest) async -> RunwaySupplyObservation
}

/// One bounded refill of one edition: the page request the runway schedules, and nothing more.
public struct RunwayRefillRequest: Hashable, Sendable {
    public let editionID: EditionID
    public let context: ContextKey
    /// The first unpublished ordinal to work from: the checkpoint this refill continues.
    public let fromOrdinal: Int
    public let purpose: RunwayRefillPurpose
    public let itemLimit: Int
    public let byteLimit: Int
    public let deadline: Date

    public init(
        editionID: EditionID,
        context: ContextKey,
        fromOrdinal: Int,
        purpose: RunwayRefillPurpose,
        itemLimit: Int,
        byteLimit: Int,
        deadline: Date
    ) {
        self.editionID = editionID
        self.context = context
        self.fromOrdinal = fromOrdinal
        self.purpose = purpose
        self.itemLimit = itemLimit
        self.byteLimit = byteLimit
        self.deadline = deadline
    }
}

/// What one refill did, and where it left its own checkpoint.
///
/// `nextOrdinal` is the refill's statement of its durable progress, so a cancelled or failed attempt
/// that committed nothing repeats its `fromOrdinal` and the runway does not lose the cursor.
public struct RunwayRefillOutcome: Hashable, Sendable {
    public let producedItems: Int
    public let producedBytes: Int
    /// Rows this refill took out of the sequenceable pool. The port states it; the runway does not guess.
    public let consumedSequenceable: Int
    public let nextOrdinal: Int
    public let stop: RunwayRefillStop

    public init(
        producedItems: Int,
        producedBytes: Int,
        consumedSequenceable: Int,
        nextOrdinal: Int,
        stop: RunwayRefillStop
    ) {
        self.producedItems = max(0, producedItems)
        self.producedBytes = max(0, producedBytes)
        self.consumedSequenceable = max(0, consumedSequenceable)
        self.nextOrdinal = max(0, nextOrdinal)
        self.stop = stop
    }
}

/// The refill path. The controller never inspects what a refill composes — it asks for one page under
/// limits, and reads the stop.
///
/// `refill` must honour cancellation the way `ResourceGovernor.startSpeculative`'s bodies do: a memory
/// warning and `cancelRefills()` both *wait* for the work they stopped, so an implementation that
/// ignores `Task.isCancelled` would hold a pressure application open. Reporting `.cancelled` is the
/// expected answer, with `nextOrdinal` stating where its own durable progress actually stopped.
public protocol RunwayRefilling: Sendable {
    func refill(_ request: RunwayRefillRequest) async -> RunwayRefillOutcome
}

/// A change that can alter the *offer* — the expensive read. A viewport update is deliberately not one
/// of these (plan §12).
public enum RunwayRelevantChange: Hashable, Sendable {
    case contextChanged(ContextKey)
    case supplyAdvanced(generation: UInt64)
    case exposureAdvanced(revision: Int64)
    case mediaStateChanged
    /// The edition published more cards. `nextOrdinal` is the first unpublished ordinal, so an edition
    /// whose tail moved forward reopens at the *new* checkpoint instead of re-requesting old work.
    case publishedTailAdvanced(nextOrdinal: Int)
    case policyReplaced(RunwayPolicy)
}

/// Where the edition's tail stands (plan §19 #37).
///
/// `exhausted` is an honest end: the supply behind the context ran out, the runway says so once, and it
/// keeps every published ordinal. `degraded` is a repeated failure at the same checkpoint, bounded by
/// `maximumRefillAttempts`; neither state invents availability and neither loops.
public enum RunwayTailState: Hashable, Sendable {
    case unobserved
    case open(nextOrdinal: Int)
    case exhausted(atOrdinal: Int)
    case degraded(atOrdinal: Int, attempts: Int)

    /// The checkpoint the next refill would continue from, when there is one.
    public var nextOrdinal: Int? {
        switch self {
        case .unobserved: return nil
        case let .open(next): return next
        case let .exhausted(at): return at
        case let .degraded(at, _): return at
        }
    }
}

/// Why a wanted refill was not started.
public enum RunwayRefillSuppression: Hashable, Sendable {
    /// One refill for this edition is already in flight. This is the coalescing that makes a fling one
    /// request instead of one request per frame.
    case alreadyInFlight
    /// The outstanding buffer would exceed its item/byte budget (plan §12).
    case bufferBudget
    /// The supply ran out. Reported once, then the state stays honest.
    case exhausted
    /// The same checkpoint failed `maximumRefillAttempts` times. Bounded retry, no loop.
    case attemptsExhausted
}

public enum RunwayDecision: Hashable, Sendable {
    case idle
    case refilling(RunwayRefillPurpose)
    case suppressed(RunwayRefillSuppression)
}

/// The counts the plan asks to be reported rather than summarised (plan §12, §15).
public struct RunwayCounters: Hashable, Sendable {
    /// Cheap pressure updates: one per viewport observation.
    public let cheapUpdates: Int
    /// Expensive offer recomputations: one per relevant change, never one per viewport update.
    public let expensiveRecomputations: Int
    /// Rows the expensive reads examined, summed. The measurement the offer's cost is stated in.
    public let rowsExamined: Int
    public let levelTransitions: Int
    public let refillsInFlight: Int
    public let scheduledRefills: Int
    public let coalescedDemands: Int
    public let suppressedByBudget: Int
    public let cancelledRefills: Int
    public let failedRefills: Int
    public let outstandingItems: Int
    public let outstandingBytes: Int

    public init(
        cheapUpdates: Int,
        expensiveRecomputations: Int,
        rowsExamined: Int,
        levelTransitions: Int,
        refillsInFlight: Int,
        scheduledRefills: Int,
        coalescedDemands: Int,
        suppressedByBudget: Int,
        cancelledRefills: Int,
        failedRefills: Int,
        outstandingItems: Int,
        outstandingBytes: Int
    ) {
        self.cheapUpdates = cheapUpdates
        self.expensiveRecomputations = expensiveRecomputations
        self.rowsExamined = rowsExamined
        self.levelTransitions = levelTransitions
        self.refillsInFlight = refillsInFlight
        self.scheduledRefills = scheduledRefills
        self.coalescedDemands = coalescedDemands
        self.suppressedByBudget = suppressedByBudget
        self.cancelledRefills = cancelledRefills
        self.failedRefills = failedRefills
        self.outstandingItems = outstandingItems
        self.outstandingBytes = outstandingBytes
    }
}

public struct RunwayStatus: Hashable, Sendable {
    public let editionID: EditionID?
    public let context: ContextKey?
    public let estimate: RunwayVisualEstimate?
    public let stocks: RunwayStocks
    public let tail: RunwayTailState
    public let decision: RunwayDecision
    public let counters: RunwayCounters
}

/// The outcome of asking the governor for relief, with the runway state it left behind.
public struct RunwayPressureRelief: Equatable, Sendable {
    public let outcome: ResourcePressureOutcome
    public let status: RunwayStatus
}

/// The local runway (plan §12, §14 PR-09).
///
/// It owns three things and delegates everything else:
///
/// * **the estimate** — a cheap, viewport-driven pressure update (`RunwayEstimator`);
/// * **the offer** — the five separate stocks, refreshed only on a relevant change through
///   `RunwaySupplyObserving`;
/// * **the refill bookkeeping** — exactly one pending refill per edition, admitted only inside the
///   policy's item/byte buffer, and started as *speculative* work when nothing visible is waiting for
///   it so `ResourceGovernor` can cancel it under pressure.
///
/// It does not own a window: `RunwayViewportObservation` is read out of the session's `FeedWindow`, and
/// the observation path touches no port, so a scroll cannot await Selection, network or decode (I-20).
public actor RunwayController {
    private struct PendingRefill {
        let request: RunwayRefillRequest
        let startedAt: Date
    }

    private struct Attempts {
        var ordinal: Int
        var count: Int
    }

    private let clock: any EditorialClock
    private let supply: any RunwaySupplyObserving
    private let refilling: any RunwayRefilling
    private let governor: ResourceGovernor

    private var estimator: RunwayEstimator
    private var currentEdition: EditionID?
    private var currentContext: ContextKey?
    private var supplyGeneration: UInt64 = 0
    private var offerIsStale = true
    /// The last offer read per edition, so moving between the visible edition and its successor does
    /// not force a query — and does not silently leave the runway without an offer either.
    private var offers: [EditionID: RunwaySupplyObservation] = [:]

    private var pending: [EditionID: PendingRefill] = [:]
    private var demandTasks: [EditionID: Task<Void, Never>] = [:]
    private var attempts: [EditionID: Attempts] = [:]
    private var tails: [EditionID: RunwayTailState] = [:]

    private var lastDecision: RunwayDecision = .idle
    private var expensiveRecomputations = 0
    private var rowsExamined = 0
    private var scheduledRefills = 0
    private var coalescedDemands = 0
    private var suppressedByBudget = 0
    private var cancelledRefills = 0
    private var failedRefills = 0

    public init(
        policy: RunwayPolicy = .baseline,
        clock: any EditorialClock,
        supply: any RunwaySupplyObserving,
        refilling: any RunwayRefilling,
        governor: ResourceGovernor
    ) {
        self.clock = clock
        self.supply = supply
        self.refilling = refilling
        self.governor = governor
        self.estimator = RunwayEstimator(policy: policy)
    }

    // MARK: lifecycle

    /// Adopts the edition the screen is showing and reads the offer once. This is where a cold start,
    /// a restore and a context switch price their single query, and where the checkpoint the first
    /// refill continues from is stated by the session.
    public func activate(
        edition: EditionID,
        context: ContextKey,
        nextOrdinal: Int
    ) async -> RunwayStatus {
        if currentEdition != edition || currentContext != context {
            estimator.abandonViewport()
            currentEdition = edition
            currentContext = context
        }
        if tails[edition]?.nextOrdinal == nil {
            tails[edition] = .open(nextOrdinal: max(0, nextOrdinal))
        }
        offerIsStale = true
        await refreshOfferIfStale()
        lastDecision = .idle
        return status()
    }

    /// The viewport path. Cheap by construction: it recomputes pressure from the observation, and it
    /// starts at most one refill per edition — asynchronously, never awaited here.
    public func observeViewport(_ observation: RunwayViewportObservation) async -> RunwayStatus {
        if observation.editionID != currentEdition {
            // A different edition is a different surface: its position, level and offer are not the
            // previous one's. The offer is deliberately *not* read here (that is the expensive path): a
            // cached read is reused, and without one the runway promises nothing until the composition
            // adopts the edition through `activate`.
            estimator.abandonViewport()
            currentEdition = observation.editionID
            if let cached = offers[observation.editionID] {
                estimator.apply(cached)
            }
        }
        let estimate = estimator.observe(observation)
        lastDecision = await scheduleRefill(observation, estimate: estimate)
        return status()
    }

    /// A change that can alter the offer: read it, once, and let the next viewport update use it.
    ///
    /// A supply advance reopens an exhausted or degraded edition *at the same checkpoint*, so more
    /// supply never costs the cursor (plan §19 #36).
    public func noteRelevantChange(_ change: RunwayRelevantChange) async -> RunwayStatus {
        switch change {
        case let .contextChanged(context):
            guard context != currentContext else { break }
            estimator.abandonViewport()
            currentEdition = nil
            currentContext = context
            lastDecision = .idle
        case let .supplyAdvanced(generation):
            supplyGeneration = generation
            attempts.removeAll()
            // New supply reopens what ran out or gave up — at the *same* checkpoint, so more supply
            // never costs the cursor.
            for edition in Array(tails.keys) {
                switch tails[edition] {
                case .exhausted(atOrdinal: let at), .degraded(atOrdinal: let at, attempts: _):
                    tails[edition] = .open(nextOrdinal: at)
                case .open, .unobserved, nil:
                    break
                }
            }
        case let .policyReplaced(policy):
            estimator.replacePolicy(policy)
        case let .publishedTailAdvanced(nextOrdinal):
            let next = max(0, nextOrdinal)
            if let edition = currentEdition, (tails[edition]?.nextOrdinal ?? Int.min) < next {
                tails[edition] = .open(nextOrdinal: next)
                attempts[edition] = nil
            }
        case .exposureAdvanced, .mediaStateChanged:
            break
        }
        offerIsStale = true
        await refreshOfferIfStale()
        lastDecision = .idle
        return status()
    }

    // MARK: pressure relief

    /// A memory warning: everything re-derivable goes, and the governor cancels speculative work — the
    /// runway's prefetches — before anything the reader is waiting for. A reader-demand refill is
    /// ordinary work and survives.
    public func applyMemoryPressure() async -> RunwayPressureRelief {
        let outcome = await governor.applyMemoryPressure()
        return RunwayPressureRelief(outcome: outcome, status: status())
    }

    public func endMemoryPressure() async -> RunwayStatus {
        await governor.endMemoryPressure()
        return status()
    }

    /// Disk maintenance is the governor's too: the runway states the usage and delegates the ceiling.
    public func applyDiskPressure(usedBytes: Int) async -> RunwayPressureRelief {
        let outcome = await governor.enforceDiskBudget(usedBytes: usedBytes)
        return RunwayPressureRelief(outcome: outcome, status: status())
    }

    /// Stops the runway's work: teardown, or a context the screen left for good. The refills record
    /// their own cancellation first, exactly as under a memory warning.
    public func cancelRefills() async {
        let tasks = demandTasks
        for task in tasks.values { task.cancel() }
        for task in tasks.values { await task.value }
        _ = await governor.cancelSpeculativeWork()
        pending.removeAll()
        demandTasks.removeAll()
    }

    /// Waits for the refills this controller started. Speculative work belongs to the governor and is
    /// waited for by its own cancellation path.
    public func awaitRefills() async {
        let tasks = demandTasks
        for task in tasks.values { await task.value }
    }

    public func currentStatus() -> RunwayStatus { status() }

    // MARK: scheduling

    private func scheduleRefill(
        _ observation: RunwayViewportObservation,
        estimate: RunwayVisualEstimate
    ) async -> RunwayDecision {
        let edition = observation.editionID

        // Until an offer has been read, the runway promises nothing: it cannot know whether a refill
        // would find supply, and guessing would be inventing availability.
        guard estimator.hasObservedOffer else { return .idle }
        guard estimator.policy.wantsRefill(distance: estimate.distance, level: estimate.level) else {
            return .idle
        }
        // No checkpoint for this edition: nothing to continue from, so nothing is promised.
        guard let tail = tails[edition] else { return .idle }
        guard case let .open(nextOrdinal) = tail else {
            if case .exhausted = tail { return .suppressed(.exhausted) }
            return .suppressed(.attemptsExhausted)
        }
        guard pending[edition] == nil else {
            coalescedDemands += 1
            return .suppressed(.alreadyInFlight)
        }
        guard let context = currentContext else { return .idle }

        let purpose = estimator.policy.refillPurpose(distance: estimate.distance, level: estimate.level)
        let request = RunwayRefillRequest(
            editionID: edition,
            context: context,
            fromOrdinal: nextOrdinal,
            purpose: purpose,
            itemLimit: estimator.policy.itemLimitPerRefill,
            byteLimit: estimator.policy.byteLimitPerRefill,
            deadline: clock.now.addingTimeInterval(
                Double(estimator.policy.refillDeadlineMilliseconds) / 1_000
            )
        )
        guard estimator.policy.bufferAdmits(
            outstandingItems: outstandingItems,
            outstandingBytes: outstandingBytes,
            itemLimit: request.itemLimit,
            byteLimit: request.byteLimit
        ) else {
            suppressedByBudget += 1
            return .suppressed(.bufferBudget)
        }

        await start(request)
        return .refilling(purpose)
    }

    /// One refill in flight per edition: the entry in `pending` *is* that invariant, and it is written
    /// before the work starts so a second demand in the same turn coalesces instead of racing.
    private func start(_ request: RunwayRefillRequest) async {
        let edition = request.editionID
        pending[edition] = PendingRefill(request: request, startedAt: clock.now)
        scheduledRefills += 1
        if request.purpose.isSpeculative {
            _ = await governor.startSpeculative { [weak self] in
                await self?.runRefill(request)
            }
        } else {
            demandTasks[edition] = Task { [weak self] in
                await self?.runRefill(request)
            }
        }
    }

    private func runRefill(_ request: RunwayRefillRequest) async {
        let outcome = await refilling.refill(request)
        complete(request, outcome: outcome)
    }

    private func complete(_ request: RunwayRefillRequest, outcome: RunwayRefillOutcome) {
        let edition = request.editionID
        guard let entry = pending[edition], entry.request == request else { return }
        pending[edition] = nil
        demandTasks[edition] = nil

        switch outcome.stop {
        case .delivered, .itemBudget, .byteBudget:
            if outcome.stop.advancedTheTail {
                estimator.recordReplenishmentLatency(
                    milliseconds: clock.now.timeIntervalSince(entry.startedAt) * 1_000
                )
            }
            estimator.consumeSequenceable(items: outcome.consumedSequenceable)
            tails[edition] = .open(nextOrdinal: checkpoint(after: request, outcome: outcome))
            attempts[edition] = nil
        case .exhausted:
            tails[edition] = .exhausted(atOrdinal: checkpoint(after: request, outcome: outcome))
            attempts[edition] = nil
        case .cancelled:
            cancelledRefills += 1
            tails[edition] = .open(nextOrdinal: checkpoint(after: request, outcome: outcome))
        case .failed:
            failedRefills += 1
            let count = recordAttempt(edition: edition, ordinal: request.fromOrdinal)
            let next = checkpoint(after: request, outcome: outcome)
            if count >= estimator.policy.maximumRefillAttempts {
                tails[edition] = .degraded(atOrdinal: next, attempts: count)
            } else {
                tails[edition] = .open(nextOrdinal: next)
            }
        }
    }

    /// The cursor never goes backwards: a refill that reports an ordinal behind the one it was asked to
    /// continue from (an out-of-order completion, a port that reports what it examined instead of what
    /// it committed) keeps the checkpoint where it was, so the worst case is a repeated page — never a
    /// skipped one.
    private func checkpoint(after request: RunwayRefillRequest, outcome: RunwayRefillOutcome) -> Int {
        max(request.fromOrdinal, outcome.nextOrdinal)
    }

    private func recordAttempt(edition: EditionID, ordinal: Int) -> Int {
        let existing = attempts[edition]
        let count = (existing?.ordinal == ordinal ? (existing?.count ?? 0) : 0) + 1
        attempts[edition] = Attempts(ordinal: ordinal, count: count)
        return count
    }

    // MARK: offer

    private func refreshOfferIfStale() async {
        guard offerIsStale, let edition = currentEdition, let context = currentContext else { return }
        offerIsStale = false
        let request = RunwaySupplyRequest(
            editionID: edition,
            context: context,
            generation: supplyGeneration,
            observedAt: clock.now
        )
        let observation = await supply.observeSupply(request)
        expensiveRecomputations += 1
        rowsExamined += observation.examinedRows
        offers[edition] = observation
        estimator.apply(observation)
    }

    // MARK: reporting

    private var outstandingItems: Int {
        pending.values.reduce(0) { $0 + $1.request.itemLimit }
    }

    private var outstandingBytes: Int {
        pending.values.reduce(0) { $0 + $1.request.byteLimit }
    }

    private func status() -> RunwayStatus {
        let tail = currentEdition.flatMap { tails[$0] } ?? .unobserved
        return RunwayStatus(
            editionID: currentEdition,
            context: currentContext,
            estimate: estimator.lastEstimate,
            stocks: estimator.stocks,
            tail: tail,
            decision: lastDecision,
            counters: RunwayCounters(
                cheapUpdates: estimator.cheapUpdates,
                expensiveRecomputations: expensiveRecomputations,
                rowsExamined: rowsExamined,
                levelTransitions: estimator.levelTransitions,
                refillsInFlight: pending.count,
                scheduledRefills: scheduledRefills,
                coalescedDemands: coalescedDemands,
                suppressedByBudget: suppressedByBudget,
                cancelledRefills: cancelledRefills,
                failedRefills: failedRefills,
                outstandingItems: outstandingItems,
                outstandingBytes: outstandingBytes
            )
        )
    }
}
