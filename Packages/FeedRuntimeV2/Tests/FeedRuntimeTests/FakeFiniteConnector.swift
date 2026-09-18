import Foundation
import FeedDomain
import FeedRuntime

/// A finite connector: a fixed list of pages, one proposed checkpoint after each of them, then the
/// end of the stream.
///
/// It covers what plan §12 fixes for the finite case — pages, an empty page, an error, a replay of an
/// already-delivered batch and explicit checkpoint advancement — and it writes nothing: the
/// checkpoint it proposes only becomes durable when Admission commits it together with the batch it
/// belongs to (ADR-005 D11).
actor FakeFiniteConnector: AcquisitionSource {
    struct Script: Sendable {
        /// Each page is the list of external object keys it carries. An empty page is valid: it
        /// carries no content, advances the checkpoint and admits nothing.
        var pages: [[String]] = []
        /// The page whose pull throws instead of producing a batch.
        var errorAtPage: Int?
        /// The page that is re-sent unchanged (same batch id, same body, same expectation) right
        /// after it was delivered: the replay a lost response produces (ADR-006 D2).
        var replayAfterPage: Int?
        var shape: FixtureObservationShape = .plain
        /// Set to false to deliver a page that proposes no new checkpoint, which is how a connector
        /// says it has nothing to advance.
        var advanceCheckpoint = true
    }

    private let target: AcquisitionTarget
    private let scope: ExternalScopeKey
    private let script: Script
    private var index = 0
    private var replayPending = false
    private var versionLadder = FixtureVersionLadder()
    private var deliveredBatches: [AcquisitionBatch] = []
    private(set) var pulls: [AcquisitionPull] = []
    private var onPull: (@Sendable (AcquisitionPull) async -> Void)?

    init(
        target: AcquisitionTarget,
        script: Script,
        scope: ExternalScopeKey = FixtureScope.key()
    ) {
        self.target = target
        self.script = script
        self.scope = scope
    }

    /// A hook the test can use to change durable state between the request and the batch, which is
    /// how a revocation or a cancellation lands mid-flight without sleeping.
    func setOnPull(_ hook: @escaping @Sendable (AcquisitionPull) async -> Void) {
        onPull = hook
    }

    var pullCount: Int { pulls.count }

    /// The checkpoints the runtime asked to resume from, in pull order.
    var receivedCheckpoints: [ConnectorCheckpoint?] { pulls.map(\.checkpoint) }

    var delivered: [AcquisitionBatch] { deliveredBatches }

    /// Pages consumed, replay included.
    var pagesConsumed: Int { index }

    func pull(_ request: AcquisitionPull) async throws -> AcquisitionSourceEvent {
        pulls.append(request)
        if let onPull { await onPull(request) }
        if let errorAtPage = script.errorAtPage, index == errorAtPage {
            throw FixtureConnectorError.transport("page \(index)")
        }
        if replayPending, let last = deliveredBatches.last {
            replayPending = false
            return .batch(last)
        }
        guard index < script.pages.count else { return .finished }
        let sequence = index + 1
        let batch = try makeBatch(sequence: sequence, objects: script.pages[index], request: request)
        index += 1
        deliveredBatches.append(batch)
        if script.replayAfterPage == index - 1 { replayPending = true }
        return .batch(batch)
    }

    private func makeBatch(sequence: Int, objects: [String], request: AcquisitionPull) throws -> AcquisitionBatch {
        let observations = try objects.map { object in
            try fixtureObservation(
                object: object,
                version: versionLadder.next(for: object),
                shape: script.shape,
                scope: scope
            )
        }
        return try FixtureBatchIdentity.makeBatch(
            sequence: sequence,
            observations: observations,
            request: request,
            advanceCheckpoint: script.advanceCheckpoint
        )
    }
}
