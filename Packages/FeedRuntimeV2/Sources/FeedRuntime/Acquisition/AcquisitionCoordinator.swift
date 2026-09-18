import Foundation
import FeedDomain
import FeedStorage

/// One bounded, pull-driven step of a connector (ADR-005 D2, D3).
///
/// The request carries the durable state the runtime owns — the target's generation, binding
/// revision and lease epoch, the checkpoint it wants resumed and the purpose's limit — so the
/// connector can resume exactly where the last admitted batch left off. A checkpoint is opaque: the
/// acquisition layer stores it and hands it back, and never reads it (ADR-005 D11).
public struct AcquisitionPull: Hashable, Sendable {
    public let targetID: AcquisitionTargetID
    public let generation: UInt64
    public let bindingRevision: UInt64
    public let leaseEpoch: UInt64
    /// The opaque position to resume from, exactly as Admission committed it.
    public let checkpoint: ConnectorCheckpoint?
    /// The durable revision the returned batch must be produced against: the compare-and-swap
    /// expectation Admission checks (ADR-006 D5).
    public let checkpointRevision: UInt64
    public let purpose: AcquisitionPurpose
    public let limit: AcquisitionLimit

    public init(
        targetID: AcquisitionTargetID,
        generation: UInt64,
        bindingRevision: UInt64,
        leaseEpoch: UInt64,
        checkpoint: ConnectorCheckpoint?,
        checkpointRevision: UInt64,
        purpose: AcquisitionPurpose,
        limit: AcquisitionLimit
    ) {
        self.targetID = targetID
        self.generation = generation
        self.bindingRevision = bindingRevision
        self.leaseEpoch = leaseEpoch
        self.checkpoint = checkpoint
        self.checkpointRevision = checkpointRevision
        self.purpose = purpose
        self.limit = limit
    }
}

/// What one pull produced that the acquisition layer may act on.
///
/// These are protocol-free facts: a batch for Admission, or the end of the stream for a reason the
/// runtime does not interpret. A connector never reports an Admission outcome (ADR-005 D15).
public enum AcquisitionSourceEvent: Hashable, Sendable {
    /// A bounded batch, stamped with the state it was produced against.
    case batch(AcquisitionBatch)
    /// The stream lost continuity. Nothing is admitted: the durable checkpoint stays the resume
    /// point, because only Admission may advance it (ADR-005 D11).
    case disconnected
    /// The finite stream has no more work.
    case finished
    /// The stream ended because the caller cancelled.
    case cancelled
}

public enum AcquisitionSourceError: Error, Equatable, Sendable {
    case targetMismatch(expected: AcquisitionTargetID, received: AcquisitionTargetID)
    case generationMismatch(expected: UInt64, received: UInt64)
}

/// A connector as the acquisition layer consumes it: one bounded pull at a time.
///
/// The stream is pull-driven by construction, so backpressure is real rather than a buffer policy:
/// a source cannot advance to batch N+1 until the runtime has taken and admitted batch N, and a
/// source that cannot suspend stops at a durable checkpoint instead of reading on and discarding
/// (ADR-005 D3; `invariant 3`).
public protocol AcquisitionSource: Sendable {
    func pull(_ request: AcquisitionPull) async throws -> AcquisitionSourceEvent
}

/// Resolves a target to the connector composed for it.
///
/// Dispatch is a compile-time decision taken where the runtime is composed: the acquisition layer
/// never looks a connector up by matching a protocol string, which is what keeps a second ecosystem
/// from reaching Selection, Publication or Presentation (ADR-005 D2; Blueprint §90).
public struct AcquisitionSourceResolver: Sendable {
    private let resolve: @Sendable (AcquisitionTarget) -> (any AcquisitionSource)?

    public init(_ resolve: @escaping @Sendable (AcquisitionTarget) -> (any AcquisitionSource)?) {
        self.resolve = resolve
    }

    public func source(for target: AcquisitionTarget) -> (any AcquisitionSource)? {
        resolve(target)
    }

    /// A resolver over an explicit mapping. It exists so tests and the composition root can spell
    /// "this work is served by that connector" without the runtime learning a registry.
    public static func mapping(_ sources: [AcquisitionTargetID: any AcquisitionSource]) -> Self {
        Self { sources[$0.id] }
    }
}

/// Bridges the domain port `FeedConnector` — one unconditional bounded fetch — onto the acquisition
/// pull surface.
///
/// The bridge fills in the three stamp fields a connector cannot know (binding revision, lease epoch
/// and the checkpoint revision the batch is produced against, ADR-006 D1) and refuses a batch whose
/// target or generation disagrees with the request: a stamp the runtime cannot validate is not
/// passed on until Admission rejects it. A one-shot connector reports the end of its stream after
/// the first batch, so the runtime terminates instead of pulling a target that has nothing left.
public struct FeedConnectorSource: AcquisitionSource {
    private let state: State

    public init(_ connector: any FeedConnector) {
        self.state = State(connector: connector)
    }

    public func pull(_ request: AcquisitionPull) async throws -> AcquisitionSourceEvent {
        try await state.pull(request)
    }

    private actor State {
        private let connector: any FeedConnector
        private var delivered = false

        init(connector: any FeedConnector) {
            self.connector = connector
        }

        func pull(_ request: AcquisitionPull) async throws -> AcquisitionSourceEvent {
            guard !delivered else { return .finished }
            let batch = try await connector.acquire(limit: request.limit)
            guard batch.targetID == request.targetID else {
                throw AcquisitionSourceError.targetMismatch(expected: request.targetID, received: batch.targetID)
            }
            guard batch.generation == request.generation else {
                throw AcquisitionSourceError.generationMismatch(
                    expected: request.generation,
                    received: batch.generation
                )
            }
            delivered = true
            return .batch(AcquisitionBatch(
                batchID: AcquisitionBatch.ledgerID(
                    targetID: batch.targetID,
                    generation: batch.generation,
                    bindingRevision: request.bindingRevision,
                    leaseEpoch: request.leaseEpoch,
                    contentFingerprint: batch.fingerprint,
                    observations: batch.observations,
                    nextCheckpoint: batch.nextCheckpoint
                ),
                fingerprint: batch.fingerprint,
                targetID: batch.targetID,
                generation: batch.generation,
                observations: batch.observations,
                evidence: batch.evidence,
                bindingRevision: request.bindingRevision,
                leaseEpoch: request.leaseEpoch,
                expectedCheckpointRevision: request.checkpointRevision,
                nextCheckpoint: batch.nextCheckpoint
            ))
        }
    }
}

/// Why one acquisition episode ended. Every case is a reported state, never a silent empty run: the
/// runtime distinguishes "no more supply" from "policy prevented fetching" (ADR-005 D8; plan §19
/// #37).
public enum AcquisitionStopReason: Hashable, Sendable {
    /// The plan's work is done and the deficit it served is met.
    case planCompleted
    /// The deficit was already met: nothing needed fetching.
    case satisfied
    /// No eligible target has more work.
    case exhausted
    /// Supply exists but policy prevented fetching it.
    case degraded(FrontierDegradation)
    /// The purpose could not pay for the next unit of work.
    case budgetStop(AcquisitionPurpose)
    /// The purpose's time budget or the caller's deadline passed.
    case deadlineReached
    /// Admission refused a batch: the work was no longer valid, or the batch was not admissible.
    case refused(AdmissionResult)
    /// The source reported a transport failure. Retry belongs to the next demand, not to a loop.
    case transportFailure(AcquisitionTargetID)
    /// The caller cancelled. Work already committed stays committed (ADR-006 D9).
    case cancelled
}

/// What one episode did, and why it stopped.
public struct AcquisitionRunSummary: Hashable, Sendable {
    public let purpose: AcquisitionPurpose
    public let stop: AcquisitionStopReason
    /// Pulls this demand paid for. A demand that shared another's pending refill pays for none.
    public let pulls: Int
    public let admittedBatches: Int
    public let admittedObservations: Int
    public let duplicateBatches: Int
    public let refusedBatches: Int
    public let bytes: Int

    public init(
        purpose: AcquisitionPurpose,
        stop: AcquisitionStopReason,
        pulls: Int = 0,
        admittedBatches: Int = 0,
        admittedObservations: Int = 0,
        duplicateBatches: Int = 0,
        refusedBatches: Int = 0,
        bytes: Int = 0
    ) {
        self.purpose = purpose
        self.stop = stop
        self.pulls = pulls
        self.admittedBatches = admittedBatches
        self.admittedObservations = admittedObservations
        self.duplicateBatches = duplicateBatches
        self.refusedBatches = refusedBatches
        self.bytes = bytes
    }
}

/// Runs acquisition: leases shared targets, keeps exactly one refill in flight per target, feeds
/// Admission and honours its typed answer.
///
/// The coordinator is an actor because the coordination it owns is genuinely shared mutable state —
/// who holds a lease on which target, which refill is pending, what each purpose has spent. It owns
/// no canonical state: the target row, the checkpoint and the receipts are durable, and Admission
/// decides validity at write time (ADR-006 D1, D9; ADR-005 D6).
public actor AcquisitionCoordinator {
    // MARK: - Shared-refill bookkeeping

    private struct Tally {
        var pulls = 0
        var admittedBatches = 0
        var admittedObservations = 0
        var duplicateBatches = 0
        var refusedBatches = 0
        var bytes = 0

        mutating func merge(_ other: Tally) {
            pulls += other.pulls
            admittedBatches += other.admittedBatches
            admittedObservations += other.admittedObservations
            duplicateBatches += other.duplicateBatches
            refusedBatches += other.refusedBatches
            bytes += other.bytes
        }
    }

    /// What one refill produced. It is shared, not duplicated, when several demands want the same
    /// target: the work is done once and every holder sees the same outcome (ADR-005 D6).
    private enum RefillOutcome: Hashable, Sendable {
        case admitted(receipt: AdmissionReceipt, observations: Int, bytes: Int)
        case duplicate(batchID: String, bytes: Int)
        case refused(AdmissionResult)
        case sourceFinished
        case sourceDisconnected
        case sourceCancelled
        case sourceFailed(String)
        case targetUnavailable(FrontierDegradation)
    }

    private struct PendingRefill {
        var waiters: [CheckedContinuation<RefillOutcome, Never>] = []
    }

    private let budgets: AcquisitionBudgetTable
    private let planner: AcquisitionPlanner
    private let resolver: AcquisitionSourceResolver
    private let targetStore: AcquisitionTargetStore
    private let engine: AdmissionEngine
    private let clock: any EditorialClock

    private var frontier: AcquisitionFrontier
    private var leases: [AcquisitionTargetID: [AcquisitionLease]] = [:]
    private var inFlight: [AcquisitionTargetID: PendingRefill] = [:]
    private var usageByPurpose: [AcquisitionPurpose: PurposeUsage] = [:]
    private var refillObservers: [CheckedContinuation<Void, Never>] = []

    public init(
        resolver: AcquisitionSourceResolver,
        budgets: AcquisitionBudgetTable = .baseline,
        planner: AcquisitionPlanner? = nil,
        targetStore: AcquisitionTargetStore = AcquisitionTargetStore(),
        engine: AdmissionEngine = AdmissionEngine(),
        clock: any EditorialClock = SystemEditorialClock(),
        bound: FrontierBound = FrontierBound()
    ) {
        self.resolver = resolver
        self.budgets = budgets
        self.planner = planner ?? AcquisitionPlanner(budgets: budgets)
        self.targetStore = targetStore
        self.engine = engine
        self.clock = clock
        self.frontier = AcquisitionFrontier(bound: bound)
    }

    // MARK: - Running one episode

    /// Runs one bounded episode for `demand` over the eligible catalogue.
    ///
    /// The episode is bounded three times over: the plan holds at most one item per runnable target
    /// and never more than the purpose may pay for; each item pulls only until its share of the
    /// deficit is met; and every pull is charged against the purpose's request and byte budgets, so a
    /// stream that keeps producing content still stops. There is no retry loop: a failure ends the
    /// episode with an explicit reason and the next demand decides what happens next (ADR-005 D8,
    /// D9; `invariant 13`).
    public func run(
        _ demand: AcquisitionDemand,
        catalogue: [AcquisitionTarget],
        in database: RuntimeDatabase
    ) async -> AcquisitionRunSummary {
        frontier.rebuild(catalogue: catalogue, demand: demand, budget: budgets[demand.purpose])
        let plan = planner.plan(
            demand: demand,
            frontier: frontier,
            usage: usage(for: demand.purpose),
            now: clock.now
        )
        if let stop = plan.stop {
            return summary(purpose: demand.purpose, stop: Self.stopReason(for: stop), tally: Tally())
        }
        var tally = Tally()
        for item in plan.work {
            let outcome = await runWorkItem(item, plan: plan, in: database)
            tally.merge(outcome.tally)
            if let stop = outcome.stop {
                return summary(purpose: demand.purpose, stop: stop, tally: tally)
            }
        }
        return summary(purpose: demand.purpose, stop: .planCompleted, tally: tally)
    }

    private func runWorkItem(
        _ item: AcquisitionWorkItem,
        plan: AcquisitionPlan,
        in database: RuntimeDatabase
    ) async -> (stop: AcquisitionStopReason?, tally: Tally) {
        var tally = Tally()
        acquireLease(item.lease)
        defer {
            // The item's own cost against the target, host and connection dimensions. Request and
            // byte usage are charged per pull, because a stream pulls more than once per item.
            charge(plan.purpose, targets: 1, hosts: 1, connections: 1)
            releaseLease(item.lease)
        }
        frontier.markRunning(item.target.id)
        defer { frontier.markStopped(item.target.id) }

        var admitted = 0
        var consecutiveReplays = 0
        while true {
            // Cancellation saves work and never grants authority: a batch that arrived anyway is not
            // admitted, and nothing already committed is undone (ADR-006 D9).
            if Task.isCancelled { return (.cancelled, tally) }
            guard clock.now < plan.deadline else {
                frontier.markDegraded(.deadlineReached)
                return (.deadlineReached, tally)
            }
            guard usage(for: plan.purpose).hasRequestAndByteRoom(in: budgets[plan.purpose]) else {
                frontier.markDegraded(.budgetStop(plan.purpose))
                return (.budgetStop(plan.purpose), tally)
            }
            // The durable row is the authority on whether this work is still valid.
            guard let snapshot = try? targetStore.snapshot(for: item.target.id, in: database) else {
                frontier.markDegraded(.unknownTarget(item.target.id))
                return (.degraded(.unknownTarget(item.target.id)), tally)
            }
            guard snapshot.state == .active else {
                frontier.markDegraded(.revokedTargets(1))
                return (.degraded(.revokedTargets(1)), tally)
            }
            guard snapshot.generation == item.lease.generation,
                  snapshot.bindingRevision == item.lease.bindingRevision
            else {
                // The plan described work against a configuration that is no longer current: it is
                // not run at all, rather than run and refused later (ADR-005 D10).
                frontier.markDegraded(.bindingChanged(item.target.id))
                return (.degraded(.bindingChanged(item.target.id)), tally)
            }

            let request = AcquisitionPull(
                targetID: item.target.id,
                generation: snapshot.generation,
                bindingRevision: snapshot.bindingRevision,
                leaseEpoch: snapshot.leaseEpoch,
                checkpoint: snapshot.checkpoint,
                checkpointRevision: snapshot.checkpointRevision,
                purpose: plan.purpose,
                limit: item.limit
            )
            let refill = await refill(item.target, request: request, in: database)
            if refill.led, refill.requested {
                tally.pulls += 1
                charge(plan.purpose, requests: 1)
            }
            switch refill.outcome {
            case .admitted(_, let observations, let bytes):
                if refill.led { charge(plan.purpose, bytes: bytes) }
                tally.admittedBatches += 1
                tally.admittedObservations += observations
                tally.bytes += bytes
                admitted += observations
                consecutiveReplays = 0
                if admitted >= item.observationBudget { return (nil, tally) }

            case .duplicate(_, let bytes):
                if refill.led { charge(plan.purpose, bytes: bytes) }
                tally.duplicateBatches += 1
                consecutiveReplays += 1
                // A replay is a batch the ledger already holds. One is normal — the lost-response
                // replay ADR-006 D2 describes — and the stream is expected to continue past it, which
                // is why this is a count and not a stop. Two in a row means the source is re-sending
                // what it has already sent: the stream did not advance, so pulling again cannot add
                // supply. Charging the purpose the rest of its request budget to rediscover that is
                // waste, and it is what a stuck source did 24 times over (§8.55). The item ends; the
                // plan's other targets still run.
                guard consecutiveReplays >= 2 else { continue }
                return (nil, tally)

            case .refused(let result):
                tally.refusedBatches += 1
                if case .staleTarget = result { frontier.markDegraded(.revokedTargets(1)) }
                return (.refused(result), tally)

            case .sourceFinished:
                frontier.markFinished(item.target.id, bindingRevision: snapshot.bindingRevision)
                return (nil, tally)

            case .sourceDisconnected:
                frontier.markDegraded(.streamDisconnected(item.target.id))
                return (.degraded(.streamDisconnected(item.target.id)), tally)

            case .sourceCancelled:
                return (.cancelled, tally)

            case .sourceFailed:
                frontier.markDegraded(.transportFailure(item.target.id))
                return (.transportFailure(item.target.id), tally)

            case .targetUnavailable(let degradation):
                frontier.markDegraded(degradation)
                return (.degraded(degradation), tally)
            }
        }
    }

    // MARK: - The single pending refill per target

    /// - Returns: the outcome, whether this caller performed the refill (as opposed to sharing one
    ///   already in flight), and whether a request was actually issued to a connector. The last one
    ///   matters for the accounting: a target no connector serves costs the purpose nothing.
    private func refill(
        _ target: AcquisitionTarget,
        request: AcquisitionPull,
        in database: RuntimeDatabase
    ) async -> RefillResult {
        if inFlight[target.id] != nil {
            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<RefillOutcome, Never>) in
                inFlight[target.id]?.waiters.append(continuation)
                notifyRefillObservers()
            }
            return RefillResult(outcome: outcome, led: false, requested: false)
        }
        inFlight[target.id] = PendingRefill()
        notifyRefillObservers()
        let result = await performRefill(target, request: request, in: database)
        let waiters = inFlight.removeValue(forKey: target.id)?.waiters ?? []
        notifyRefillObservers()
        for waiter in waiters { waiter.resume(returning: result.outcome) }
        return RefillResult(outcome: result.outcome, led: true, requested: result.requested)
    }

    private func performRefill(
        _ target: AcquisitionTarget,
        request: AcquisitionPull,
        in database: RuntimeDatabase
    ) async -> (outcome: RefillOutcome, requested: Bool) {
        guard let source = resolver.source(for: target) else {
            return (.targetUnavailable(.missingSource(target.id)), false)
        }
        let event: AcquisitionSourceEvent
        do {
            event = try await source.pull(request)
        } catch {
            // Cancellation is control flow, not target health. Treating a connector's
            // CancellationError (or another error observed after this task was cancelled) as a
            // transport failure would incorrectly degrade the frontier and could suppress useful
            // work on the next demand.
            if error is CancellationError || Task.isCancelled {
                return (.sourceCancelled, true)
            }
            return (.sourceFailed("\(error)"), true)
        }
        switch event {
        case .finished:
            return (.sourceFinished, true)
        case .disconnected:
            return (.sourceDisconnected, true)
        case .cancelled:
            return (.sourceCancelled, true)
        case .batch(let batch):
            if Task.isCancelled { return (.sourceCancelled, true) }
            let bytes = AcquisitionByteAccounting.bytes(of: batch)
            switch engine.admit(batch, in: database) {
            case .admitted(let receipt):
                return (.admitted(receipt: receipt, observations: batch.observations.count, bytes: bytes), true)
            case .duplicate(let batchID):
                return (.duplicate(batchID: batchID, bytes: bytes), true)
            case let refused:
                return (.refused(refused), true)
            }
        }
    }

    /// What one shared refill produced and who paid for it.
    private struct RefillResult {
        let outcome: RefillOutcome
        /// This caller performed the refill rather than sharing one already in flight.
        let led: Bool
        /// A request was issued to a connector.
        let requested: Bool
    }

    // MARK: - Leases

    /// Registers one holder's interest in a target and returns the target's lease count.
    ///
    /// Acquiring a lease the holder already has for that purpose is not a second lease: the identity
    /// is `(target, holder, purpose)` (ADR-005 D6).
    @discardableResult
    public func acquireLease(_ lease: AcquisitionLease) -> Int {
        var holders = leases[lease.targetID] ?? []
        if !holders.contains(where: { $0.sharesIdentity(with: lease) }) {
            holders.append(lease)
        }
        leases[lease.targetID] = holders
        return holders.count
    }

    /// Releases one holder's interest and returns what remains.
    ///
    /// Releasing one lease never cancels work another live lease still needs: the target leaves
    /// `active` only when its last lease is gone (ADR-005 D6; `invariant 4`).
    @discardableResult
    public func releaseLease(_ lease: AcquisitionLease) -> Int {
        guard var holders = leases[lease.targetID] else { return 0 }
        holders.removeAll { $0.sharesIdentity(with: lease) }
        if holders.isEmpty {
            leases.removeValue(forKey: lease.targetID)
            return 0
        }
        leases[lease.targetID] = holders
        return holders.count
    }

    /// How many holders currently want this target. Nonzero means the target may stay active.
    public func leaseCount(for targetID: AcquisitionTargetID) -> Int {
        leases[targetID]?.count ?? 0
    }

    public func holders(of targetID: AcquisitionTargetID) -> [AcquisitionLease] {
        leases[targetID] ?? []
    }

    /// Revokes a target for real: the durable row moves to `revoked` and its lease epoch advances,
    /// so anything produced under the previous epoch fails Admission as `staleTarget` even though
    /// task cancellation was not immediate (ADR-005 D6; ADR-006 D1).
    ///
    /// Local leases for the target are dropped. The refill already in flight is deliberately left
    /// alone: it will deliver a batch that Admission refuses, which is the behaviour that has to be
    /// observable rather than assumed away.
    @discardableResult
    public func revoke(
        _ targetID: AcquisitionTargetID,
        in database: RuntimeDatabase
    ) throws -> AcquisitionTargetSnapshot {
        leases.removeValue(forKey: targetID)
        return try targetStore.setState(.revoked, for: targetID, in: database)
    }

    /// Sheds work under pressure in the ADR-005 D9 cancellation order: `speculative` first, then
    /// `backgroundMaintenance`, `activeRunway`, `bootstrap`, and `userInitiated` last. Within one
    /// purpose the lowest priority goes first.
    ///
    /// - Parameter keeping: how many targets may keep a lease.
    /// - Returns: the leases released, in the order they were released.
    @discardableResult
    public func shedUnderPressure(keeping targetBudget: Int) -> [AcquisitionLease] {
        var released: [AcquisitionLease] = []
        while leases.count > max(0, targetBudget) {
            let candidates = leases.values.flatMap { $0 }
            guard let victim = candidates.min(by: Self.sheddingOrder) else { break }
            releaseLease(victim)
            released.append(victim)
        }
        return released
    }

    private static func sheddingOrder(_ lhs: AcquisitionLease, _ rhs: AcquisitionLease) -> Bool {
        if lhs.purpose != rhs.purpose {
            return lhs.purpose.budget.cancellationOrder < rhs.purpose.budget.cancellationOrder
        }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.targetID != rhs.targetID { return lhs.targetID.rawValue < rhs.targetID.rawValue }
        return lhs.holderID < rhs.holderID
    }

    // MARK: - Usage and observability

    public func usage(for purpose: AcquisitionPurpose) -> PurposeUsage {
        usageByPurpose[purpose] ?? .zero
    }

    /// Starts a new accounting window for a purpose.
    public func resetUsage(for purpose: AcquisitionPurpose) {
        usageByPurpose[purpose] = .zero
    }

    public var frontierState: AcquisitionFrontierState { frontier.state }

    public var degradationReason: FrontierDegradation? { frontier.degradationReason }

    /// Waits until at least `count` demands are parked on the pending refill for `targetID`, and
    /// returns how many are.
    ///
    /// One is the ceiling the runtime aims for; the count is the evidence that two contexts share the
    /// work rather than duplicating it (ADR-005 D6). It also lets a caller observe sharing without
    /// polling or sleeping.
    public func awaitPendingRefillWaiters(
        for targetID: AcquisitionTargetID,
        atLeast count: Int = 1
    ) async -> Int {
        while (inFlight[targetID]?.waiters.count ?? 0) < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                refillObservers.append(continuation)
            }
        }
        return inFlight[targetID]?.waiters.count ?? 0
    }

    private func notifyRefillObservers() {
        guard !refillObservers.isEmpty else { return }
        let observers = refillObservers
        refillObservers = []
        for observer in observers { observer.resume() }
    }

    // MARK: - Charging

    private func charge(
        _ purpose: AcquisitionPurpose,
        targets: Int = 0,
        requests: Int = 0,
        bytes: Int = 0,
        hosts: Int = 0,
        connections: Int = 0
    ) {
        var usage = usageByPurpose[purpose] ?? .zero
        usage.targets += targets
        usage.requests += requests
        usage.bytes += bytes
        usage.hosts += hosts
        usage.connections += connections
        usageByPurpose[purpose] = usage
    }

    private static func stopReason(for stop: AcquisitionPlanStop) -> AcquisitionStopReason {
        switch stop {
        case .satisfied: return .satisfied
        case .exhausted: return .exhausted
        case .degraded(let reason): return .degraded(reason)
        case .budgetStop(let purpose): return .budgetStop(purpose)
        case .deadlineReached: return .deadlineReached
        }
    }

    private func summary(
        purpose: AcquisitionPurpose,
        stop: AcquisitionStopReason,
        tally: Tally
    ) -> AcquisitionRunSummary {
        AcquisitionRunSummary(
            purpose: purpose,
            stop: stop,
            pulls: tally.pulls,
            admittedBatches: tally.admittedBatches,
            admittedObservations: tally.admittedObservations,
            duplicateBatches: tally.duplicateBatches,
            refusedBatches: tally.refusedBatches,
            bytes: tally.bytes
        )
    }
}
