import Foundation
import FeedDomain
import FeedRuntime
import XCTest

/// A streaming connector: a scripted, versioned stream with relations, provenance and offers, read
/// by a producer that is bounded by a small mailbox.
///
/// It covers what plan §12 requires of the streaming case: bursts, duplicates, an out-of-order
/// representation, a disconnect and reconnection, and emission after cancellation. The producer is a
/// real task that suspends when the mailbox is full, so the fixture proves the runtime's pull-driven
/// discipline does not need an unbounded buffer and does not drop frames to stay bounded (ADR-005
/// D3; `invariant 3`).
actor FakeStreamingConnector: AcquisitionSource {
    enum Step: Hashable, Sendable {
        /// One batch carrying the given fresh objects.
        case burst([String])
        /// Re-send the previous batch unchanged: the duplicate a replay produces (ADR-006 D2).
        case replay
        /// A representation of an already-seen object that this connector knows is older. Only the
        /// connector can know that: the version key is opaque to the runtime (ADR-003 D9).
        case olderRevision(String)
        /// The connection drops. No content is committed and the durable checkpoint stays the resume
        /// point (ADR-005 D11).
        case discontinuity
    }

    private let target: AcquisitionTarget
    private let scope: ExternalScopeKey
    private let script: [Step]
    private let capacity: Int
    private let shape: FixtureObservationShape

    private var buffer: [Step] = []
    private var producerTask: Task<Void, Never>?
    private var producerParked: CheckedContinuation<Void, Never>?
    private var consumerWaiters: [CheckedContinuation<Step?, Never>] = []
    private var parkedObservers: [CheckedContinuation<Void, Never>] = []
    private var producedSteps = 0
    private var peakBufferedSteps = 0
    private var producerFinished = false
    private var sequence = 0
    private var versionLadder = FixtureVersionLadder()
    private var deliveredBatches: [AcquisitionBatch] = []
    private var pulls: [AcquisitionPull] = []
    private var callJournal: [String] = []
    private var protocolWriteRequests = 0
    private var onPull: (@Sendable (AcquisitionPull) async -> Void)?

    /// - Parameter capacity: how many stream frames the mailbox may hold. One is the strictest
    ///   pull-driven bound: the producer cannot read the next frame until the consumer took the
    ///   previous one.
    init(
        target: AcquisitionTarget,
        script: [Step],
        capacity: Int = 1,
        shape: FixtureObservationShape = .plain,
        scope: ExternalScopeKey = FixtureScope.key()
    ) {
        self.target = target
        self.script = script
        self.capacity = max(1, capacity)
        self.shape = shape
        self.scope = scope
    }

    // MARK: - Test control

    func setOnPull(_ hook: @escaping @Sendable (AcquisitionPull) async -> Void) {
        onPull = hook
    }

    /// Starts the producer. It is idempotent and happens on the first pull as well, so a test can
    /// observe the mailbox bound before any pull.
    func start() {
        guard producerTask == nil, !producerFinished else { return }
        producerTask = Task { [weak self] in await self?.produce() }
    }

    /// Stops the producer where it stands. A stream that cannot suspend stops at a checkpoint rather
    /// than reading on and discarding (ADR-005 D3); everything still in the script stays there for a
    /// later pull.
    func stop() {
        producerTask?.cancel()
        producerTask = nil
        if let parked = producerParked {
            producerParked = nil
            parked.resume()
        }
    }

    /// A protocol write capability. It exists so a test can prove the acquisition path never
    /// reaches for one, however much content flows (ADR-005 D19; plan §19 #39).
    func requestProtocolWrite(_ payload: String) -> Int {
        protocolWriteRequests += 1
        return protocolWriteRequests
    }

    // MARK: - Observations

    var pullCount: Int { pulls.count }
    var receivedCheckpoints: [ConnectorCheckpoint?] { pulls.map(\.checkpoint) }
    var delivered: [AcquisitionBatch] { deliveredBatches }
    var bufferedSteps: Int { buffer.count }
    var producedStepCount: Int { producedSteps }
    var peakBufferedStepCount: Int { peakBufferedSteps }
    var stepsRemaining: Int { script.count - producedSteps }
    var producerIsParked: Bool { producerParked != nil }
    var receivedCalls: [String] { callJournal }
    var protocolWriteCount: Int { protocolWriteRequests }

    /// Waits until the producer is parked on a full mailbox (or has finished). It is how a test
    /// observes backpressure without polling and without sleeping.
    func awaitProducerParked() async {
        while producerParked == nil && !producerFinished {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkedObservers.append(continuation)
            }
        }
    }

    /// Waits until the producer read the whole script.
    func awaitProducerFinished() async {
        while !producerFinished {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkedObservers.append(continuation)
            }
        }
    }

    // MARK: - The pull surface

    func pull(_ request: AcquisitionPull) async throws -> AcquisitionSourceEvent {
        callJournal.append("pull")
        pulls.append(request)
        start()
        if let onPull { await onPull(request) }
        // A stream may already hold a frame when cancellation arrives: a socket does not un-read
        // bytes. The fixture still hands it over; whether it is still valid is the runtime's call,
        // decided by Admission against durable state (ADR-005 D6, ADR-006 D9).
        guard let step = await take() else {
            return Task.isCancelled ? .cancelled : .finished
        }
        return try build(step, request: request)
    }

    // MARK: - Producer and mailbox

    private func produce() async {
        for step in script {
            if Task.isCancelled { return }
            await enqueue(step)
        }
        producerFinished = true
        notifyParkedObservers()
        pump()
    }

    private func enqueue(_ step: Step) async {
        while buffer.count >= capacity {
            if Task.isCancelled { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                producerParked = continuation
                notifyParkedObservers()
            }
        }
        buffer.append(step)
        producedSteps += 1
        peakBufferedSteps = max(peakBufferedSteps, buffer.count)
        pump()
    }

    private func take() async -> Step? {
        if !buffer.isEmpty {
            let step = buffer.removeFirst()
            pump()
            return step
        }
        if producerFinished { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Step?, Never>) in
            consumerWaiters.append(continuation)
            pump()
        }
    }

    /// Hands buffered frames to waiting consumers and releases a producer that was parked on a full
    /// mailbox. No frame is ever discarded: a frame leaves the buffer only by being taken.
    private func pump() {
        while !consumerWaiters.isEmpty {
            guard !buffer.isEmpty else {
                guard producerFinished else { break }
                consumerWaiters.removeFirst().resume(returning: nil)
                continue
            }
            consumerWaiters.removeFirst().resume(returning: buffer.removeFirst())
        }
        while buffer.count < capacity, let parked = producerParked {
            producerParked = nil
            parked.resume()
        }
    }

    private func notifyParkedObservers() {
        guard !parkedObservers.isEmpty else { return }
        let observers = parkedObservers
        parkedObservers = []
        for observer in observers { observer.resume() }
    }

    // MARK: - Frame translation

    private func build(_ step: Step, request: AcquisitionPull) throws -> AcquisitionSourceEvent {
        switch step {
        case .discontinuity:
            return .disconnected

        case .replay:
            guard let last = deliveredBatches.last else {
                throw FixtureConnectorError.misconfigured("replay without a delivered batch")
            }
            return .batch(last)

        case .burst(let objects):
            let observations = try objects.map { object in
                try fixtureObservation(
                    object: object,
                    version: versionLadder.next(for: object),
                    shape: shape,
                    scope: scope
                )
            }
            return .batch(try assemble(observations: observations, request: request))

        case .olderRevision(let object):
            let observations = [try fixtureObservation(
                object: object,
                version: FixtureVersioning.olderVersionKey(object: object),
                precedence: .historicalOnly,
                shape: shape,
                scope: scope
            )]
            return .batch(try assemble(observations: observations, request: request))
        }
    }

    private func assemble(observations: [AcquisitionObservation], request: AcquisitionPull) throws -> AcquisitionBatch {
        sequence += 1
        let batch = try FixtureBatchIdentity.makeBatch(
            sequence: sequence,
            observations: observations,
            request: request
        )
        deliveredBatches.append(batch)
        return batch
    }
}
