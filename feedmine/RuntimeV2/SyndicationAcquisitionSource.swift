import Foundation
import FeedConnectorSyndication
import FeedDomain
import FeedRuntime

/// The production converter: one syndication answer becomes one acquisition pull.
///
/// `SyndicationConnector` already owns everything the wire needs — the conditional request, the byte
/// ceilings, the redirect ceiling, the translation, the proposed checkpoint — and it reports its own
/// outcome taxonomy. What it does not know is the acquisition layer's vocabulary: an opaque
/// `ConnectorCheckpoint` blob, the four `AcquisitionSourceEvent` cases, and the stamps a batch must
/// carry. This type is that translation and nothing else:
///
/// * it decodes the durable checkpoint blob into the connector's own `SyndicationCheckpoint` and
///   encodes the proposed one back, so Admission is the only writer of the checkpoint and the runtime
///   never reads inside it (ADR-005 D11);
/// * it stamps the batch with the target generation, binding revision, lease epoch and checkpoint
///   revision the pull was made under, which is what Admission's compare-and-swap validates
///   (ADR-006 D1, D5);
/// * it maps the connector's non-batch outcomes onto the acquisition layer's: a `304` is the end of
///   this stream (nothing changed, nothing to admit, nothing to commit), a transport failure is thrown
///   so the coordinator reports it as one, and everything else — throttling, policy refusal, a
///   malformed document, an unhandled status, an exhausted deadline — is a discontinuity that admits
///   nothing and leaves the durable checkpoint as the resume point (ADR-005 D8, D15).
///
/// It holds no canonical state and writes no database.
struct SyndicationAcquisitionSource: AcquisitionSource {
    let ingredient: SyndicationAcquisitionIngredient
    /// The throttle the last pull learned, consulted and updated by the next one (ADR-005 D13).
    let hostGate: SyndicationHostGateStore

    init(ingredient: SyndicationAcquisitionIngredient, hostGate: SyndicationHostGateStore) {
        self.ingredient = ingredient
        self.hostGate = hostGate
    }

    func pull(_ request: AcquisitionPull) async throws -> AcquisitionSourceEvent {
        let connector = ingredient.connector(gate: await hostGate.current())
        let outcome = try await connector.acquire(
            limit: request.limit,
            checkpoint: Self.checkpoint(from: request.checkpoint)
        )
        switch outcome {
        case .batch(let batch):
            return .batch(try stamped(batch.batch, proposed: batch.proposedCheckpoint, request: request))

        case .notModified:
            // The endpoint confirmed the baseline the conditional request was built on: no
            // representation changed and no batch may be admitted. The confirmed checkpoint is
            // byte-identical to the one Admission already holds, so there is nothing to commit either.
            return .finished

        case .transportFailure(let failureClass, let retryable, _):
            // A transport failure is retryable work, not a broken stream: the coordinator reports it as
            // one and the next demand decides (ADR-005 D8).
            throw SyndicationAcquisitionError.transport(
                failureClass: failureClass,
                retryable: retryable
            )

        case .throttled(let until, _, _):
            // The host asked us to come back later. Recording it is what keeps the next pull from
            // asking the same host again (ADR-005 D13); the batch that would have been produced is not
            // produced at all.
            await hostGate.record(ingredient.target.endpoint, until: until)
            return .disconnected

        case .hostInBackoff:
            return .disconnected

        case .refused:
            return .disconnected

        case .parseFailure:
            return .disconnected

        case .unhandledStatus:
            return .disconnected

        case .deadlineReached:
            return .disconnected
        }
    }

    /// The batch the acquisition layer admits, stamped with the pull it answers.
    private func stamped(
        _ batch: AcquisitionBatch,
        proposed: SyndicationCheckpoint,
        request: AcquisitionPull
    ) throws -> AcquisitionBatch {
        guard batch.targetID == request.targetID else {
            throw AcquisitionSourceError.targetMismatch(expected: request.targetID, received: batch.targetID)
        }
        guard batch.generation == request.generation else {
            throw AcquisitionSourceError.generationMismatch(
                expected: request.generation,
                received: batch.generation
            )
        }
        return AcquisitionBatch(
            // The ledger key is the content, its position and the lease epoch the batch was produced
            // under — and never the expected checkpoint revision, which the runtime advances as a
            // consequence of admitting the batch itself. Stamping the connector's own narrow id refused
            // every launch's re-delivery of an unchanged page as `batchConflict` (baseline §8.55).
            batchID: AcquisitionBatch.ledgerID(
                targetID: batch.targetID,
                generation: batch.generation,
                bindingRevision: request.bindingRevision,
                leaseEpoch: request.leaseEpoch,
                contentFingerprint: batch.fingerprint,
                observations: batch.observations,
                nextCheckpoint: try Self.connectorCheckpoint(proposed)
            ),
            fingerprint: batch.fingerprint,
            targetID: batch.targetID,
            generation: batch.generation,
            observations: batch.observations,
            evidence: batch.evidence,
            bindingRevision: request.bindingRevision,
            leaseEpoch: request.leaseEpoch,
            expectedCheckpointRevision: request.checkpointRevision,
            nextCheckpoint: try Self.connectorCheckpoint(proposed)
        )
    }

    /// The connector's checkpoint as the opaque payload Admission stores.
    ///
    /// A blob that cannot be encoded is refused rather than dropped: a batch admitted without its
    /// checkpoint would be re-fetched unconditionally forever, and the failure would be invisible.
    static func connectorCheckpoint(_ checkpoint: SyndicationCheckpoint) throws -> ConnectorCheckpoint {
        let blob = try checkpoint.encoded()
        return try ConnectorCheckpoint(
            blob: blob,
            serializationSchema: SyndicationCheckpoint.currentSchemaVersion,
            connectorVersion: SyndicationNamespace.connector.rawValue
        )
    }

    /// The connector's checkpoint from the durable one, or `nil` for an unconditional fetch.
    ///
    /// A blob this build cannot read — another schema version, another connector, or damaged bytes —
    /// is not guessed at: the fetch is unconditional, which is always safe because no validator is
    /// applied without a baseline (ADR-005 D12).
    static func checkpoint(from stored: ConnectorCheckpoint?) -> SyndicationCheckpoint? {
        guard let stored,
              stored.serializationSchema == SyndicationCheckpoint.currentSchemaVersion,
              stored.connectorVersion == SyndicationNamespace.connector.rawValue,
              let blob = stored.blob
        else { return nil }
        return try? SyndicationCheckpoint.decoded(from: blob)
    }
}

/// Everything one connector needs, minus the host gate the caller owns.
struct SyndicationAcquisitionIngredient: Sendable {
    let target: SyndicationTarget
    let transport: any HTTPTransport
    let enrollment: SyndicationSourceEnrollment?
    let limits: SyndicationHTTPLimits
    let backoff: SyndicationBackoffPolicy
    let clock: any EditorialClock

    func connector(gate: SyndicationHostGate) -> SyndicationConnector {
        SyndicationConnector(
            target: target,
            transport: transport,
            clock: clock,
            limits: limits,
            backoff: backoff,
            hostGate: gate,
            enrollment: enrollment
        )
    }
}

/// Per-host eligibility, kept beside the source that learned it (ADR-005 D13).
///
/// `SyndicationHostGate` is an immutable caller-owned value, so the state has to live somewhere: the
/// source reads it before a pull and records what a throttle told it. Without it, a `429` would be
/// followed by another request to the same host on the very next demand.
actor SyndicationHostGateStore {
    private var gate = SyndicationHostGate()

    init() {}

    func current() -> SyndicationHostGate { gate }

    func record(_ url: URL, until: Date) {
        gate = gate.recording(url: url, until: until)
    }
}

enum SyndicationAcquisitionError: Error, Equatable, Sendable {
    /// The transport could not complete the request. Never a message: a URL error's description can
    /// carry the URL, and a query string is personal data (ADR-005 D14).
    case transport(failureClass: SyndicationTransportFailureClass, retryable: Bool)
}
