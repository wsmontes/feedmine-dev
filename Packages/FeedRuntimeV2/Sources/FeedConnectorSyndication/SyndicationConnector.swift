import Foundation
import FeedDomain

/// The syndication connector: one target, one bounded fetch, one translated batch.
///
/// It builds the request, honours the checkpoint, parses, translates, assembles the batch with its
/// evidence and hands the batch back with the checkpoint it *proposes*. It writes to no database,
/// decodes nothing downstream and holds no mutable state: everything it knows about the last fetch
/// arrives as a `SyndicationCheckpoint` and everything it learns leaves as a proposed one
/// (ADR-005 D1, D11; plan §7).

/// One unit of acquisition work: an endpoint plus connector-owned configuration plus a generation.
///
/// It is not editorial identity: two Sources may share one target, and a target's configuration is
/// never read outside the connector and acquisition layers (ADR-005 D5, D10).
public struct SyndicationTarget: Hashable, Sendable {
    public let targetID: AcquisitionTargetID
    public let endpoint: URL
    public let generation: UInt64
    /// The connector-scoped key of the source this target serves. It is the caller's own value
    /// (a binding fingerprint, not a Source id) and it becomes the item scope (ADR-003 D8; ADR-005
    /// D10).
    public let scope: ExternalScopeKey

    public init(
        targetID: AcquisitionTargetID,
        endpoint: URL,
        generation: UInt64,
        sourceKey: String,
        identity: SyndicationIdentity = SyndicationIdentity()
    ) throws {
        self.init(
            targetID: targetID,
            endpoint: endpoint,
            generation: generation,
            scope: try identity.scope(sourceKey: sourceKey)
        )
    }

    /// The same target with the scope stated by the caller.
    ///
    /// A composition root that already derives the scope of a source (the app's own bridge does, so
    /// the shadow lane and the production lane put the same objects in the same scope) hands it over
    /// here instead of letting a second derivation spell it differently. Two scopes are never merged,
    /// so a second spelling is two identities for one source (ADR-003 D8).
    public init(
        targetID: AcquisitionTargetID,
        endpoint: URL,
        generation: UInt64,
        scope: ExternalScopeKey
    ) {
        self.targetID = targetID
        self.endpoint = endpoint
        self.generation = generation
        self.scope = scope
    }
}

/// A policy refusal: the connector did not produce a batch and did not mutate anything.
public enum SyndicationRefusal: Hashable, Sendable {
    case endpointRejected(String)
    case redirectTargetRejected(String)
    case missingRedirectLocation(status: Int)
    case redirectLimitExceeded(limit: Int)
    case compressedBodyTooLarge(limit: Int, declared: Int)
    case bodyTooLarge(limit: Int, received: Int)
    case notModifiedWithoutConditionalRequest
}

public struct SyndicationBatchOutcome: Hashable, Sendable {
    public let batch: AcquisitionBatch
    public let translation: SyndicationTranslation
    /// The checkpoint Admission may commit together with this batch, and only together with it
    /// (ADR-005 D11). The connector never commits it.
    public let proposedCheckpoint: SyndicationCheckpoint
    /// The endpoint the body actually came from: the last hop of the chain.
    public let endpoint: URL
    /// Every endpoint requested, in order. More than one entry means the target's configured
    /// endpoint redirected, which is an endpoint change the caller may need to record (D10).
    public let redirectChain: [URL]
    /// `true` when this run produced validators Admission may confirm with the batch, because the
    /// document was consumed whole (D12).
    public let proposesValidatorConfirmation: Bool
}

/// What one acquisition run reports. The taxonomy mirrors ADR-005 D15: the connector reports
/// transport, protocol and translation facts, and never reports an Admission outcome.
public enum SyndicationAcquisitionOutcome: Hashable, Sendable {
    case batch(SyndicationBatchOutcome)
    case notModified(endpoint: URL, checkpoint: SyndicationCheckpoint)
    case throttled(until: Date, retryAfter: TimeInterval?, checkpoint: SyndicationCheckpoint)
    case transportFailure(
        failureClass: SyndicationTransportFailureClass,
        retryable: Bool,
        checkpoint: SyndicationCheckpoint
    )
    case parseFailure(reason: String, checkpoint: SyndicationCheckpoint)
    /// The host is in backoff for this caller's gate, so no request was issued — the throttled host
    /// consumes nothing from the budget other hosts still use (ADR-005 D13).
    case hostInBackoff(host: String, until: Date, checkpoint: SyndicationCheckpoint)
    case refused(SyndicationRefusal, checkpoint: SyndicationCheckpoint)
    case unhandledStatus(status: Int, checkpoint: SyndicationCheckpoint)
    /// The caller's deadline had already passed: a budget stop is a normal outcome that leaves a
    /// usable checkpoint, not an error (ADR-005 D9).
    case deadlineReached(checkpoint: SyndicationCheckpoint)
}

public enum SyndicationConnectorError: Error, Equatable, Sendable {
    /// `FeedConnector.acquire(limit:)` has no checkpoint input and no place to report a non-batch
    /// outcome, so it refuses rather than reporting an empty batch. The richer surface is
    /// `acquire(limit:checkpoint:)`.
    case nonBatchOutcome(SyndicationAcquisitionOutcome)
}

/// Fingerprint over the canonical serialization of a batch's observations.
///
/// The observation time and the precedence instruction are deliberately excluded: they are local and
/// policy metadata, and folding them in would make a re-observation of unchanged content a different
/// batch with new bytes (plan §7; ADR-003 D17). Two runs over the same document with the same
/// checkpoint therefore produce the same fingerprint, which is what makes a replay free.
public enum SyndicationBatchFingerprint {
    public static func fingerprint(of observations: [AcquisitionObservation]) -> String {
        var bytes = Data()
        bytes.append(number(UInt64(observations.count)))
        for observation in observations {
            bytes.append(string(observation.externalKey.scope.namespace.rawValue))
            bytes.append(string(observation.externalKey.scope.scopeKey))
            bytes.append(lengthPrefixed(observation.externalKey.bytes))
            if let versionKey = observation.versionKey {
                bytes.append(presence(true))
                bytes.append(lengthPrefixed(versionKey.bytes))
            } else {
                bytes.append(presence(false))
            }
            bytes.append(optionalString(observation.payload.headline))
            bytes.append(optionalString(observation.payload.link?.absoluteString))
            bytes.append(optionalString(observation.payload.excerpt))
            bytes.append(optionalString(observation.payload.body))
            bytes.append(optionalDate(observation.payload.authoredAt))
            bytes.append(optionalDate(observation.payload.modifiedAt))
        }
        return SyndicationFingerprint.hex(SyndicationFingerprint.fingerprint128(bytes))
    }

    private static func string(_ value: String) -> Data { lengthPrefixed(Data(value.utf8)) }

    private static func optionalString(_ value: String?) -> Data {
        guard let value else { return presence(false) }
        return presence(true) + string(value)
    }

    private static func optionalDate(_ value: Date?) -> Data {
        guard let value else { return presence(false) }
        return presence(true) + number(value.timeIntervalSinceReferenceDate.bitPattern)
    }

    private static func number(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    private static func presence(_ isPresent: Bool) -> Data { Data([isPresent ? 1 : 0]) }

    private static func lengthPrefixed(_ part: Data) -> Data { number(UInt64(part.count)) + part }
}

public struct SyndicationConnector: FeedConnector, Sendable {
    public let target: SyndicationTarget
    public let transport: any HTTPTransport
    public let clock: any EditorialClock
    public let translator: SyndicationTranslator
    public let limits: SyndicationHTTPLimits
    public let backoff: SyndicationBackoffPolicy
    public let jitter: any SyndicationJitterSource
    /// Per-host eligibility owned by the caller, including the throttles this connector reported
    /// (ADR-005 D13).
    public let hostGate: SyndicationHostGate
    /// The editorial source every observation this connector translates is declared a member of.
    ///
    /// A connector composed without one claims no membership, and the content it admits enrolls no
    /// source: `selection_supply.source_id` stays `NULL` and Selection's eligibility predicate finds
    /// nothing to read however successful the fetch was (ADR-003 D15). It is optional only so a test
    /// can exercise translation without a runtime source.
    public let enrollment: SyndicationSourceEnrollment?

    public init(
        target: SyndicationTarget,
        transport: any HTTPTransport,
        clock: any EditorialClock = SystemEditorialClock(),
        translator: SyndicationTranslator = SyndicationTranslator(),
        limits: SyndicationHTTPLimits = SyndicationHTTPLimits(),
        backoff: SyndicationBackoffPolicy = SyndicationBackoffPolicy(),
        jitter: any SyndicationJitterSource = StableSyndicationJitter(),
        hostGate: SyndicationHostGate = SyndicationHostGate(),
        enrollment: SyndicationSourceEnrollment? = nil
    ) {
        self.target = target
        self.transport = transport
        self.clock = clock
        self.translator = translator
        self.limits = limits
        self.backoff = backoff
        self.jitter = jitter
        self.hostGate = hostGate
        self.enrollment = enrollment
    }

    public var targetID: AcquisitionTargetID { target.targetID }

    /// The PR-01 `FeedConnector` surface: one unconditional run, since it has no checkpoint to
    /// resume from. An unconditional fetch is always safe (a validator is never applied without a
    /// baseline), and anything that is not a batch is reported instead of being flattened into one.
    public func acquire(limit: AcquisitionLimit) async throws -> AcquisitionBatch {
        let outcome = try await acquire(limit: limit, checkpoint: nil)
        switch outcome {
        case .batch(let batch): return batch.batch
        default: throw SyndicationConnectorError.nonBatchOutcome(outcome)
        }
    }

    /// One bounded acquisition run for this target (plan §12, §14 PR-11).
    public func acquire(
        limit: AcquisitionLimit,
        checkpoint: SyndicationCheckpoint?
    ) async throws -> SyndicationAcquisitionOutcome {
        let now = clock.now
        let base = usableCheckpoint(checkpoint)

        if let host = SyndicationHostGate.host(of: target.endpoint), !hostGate.isEligible(target.endpoint, at: now) {
            return .hostInBackoff(
                host: host,
                until: hostGate.nextEligibleAt(target.endpoint) ?? now,
                checkpoint: base
            )
        }

        guard now < limit.deadline else {
            return .deadlineReached(checkpoint: base)
        }

        let http = SyndicationHTTPClient(transport: transport, limits: limits)
        let outcome: SyndicationHTTPOutcome
        do {
            outcome = try await http.fetch(
                endpoint: target.endpoint,
                generation: target.generation,
                checkpoint: base,
                byteCeiling: limit.maxBytes,
                now: now
            )
        } catch let error as SyndicationHTTPError {
            return failure(for: error, checkpoint: base)
        }

        switch outcome {
        case .notModified(let notModified):
            // A 304 removes nothing and changes nothing (invariant 9); it only confirms the baseline
            // the conditional request was built on. A 304 that arrives without one is refused rather
            // than accepted as a shortcut (D12).
            do {
                let confirmed = try base.confirmedByNotModified()
                return .notModified(endpoint: notModified.endpoint, checkpoint: confirmed)
            } catch {
                return .refused(.notModifiedWithoutConditionalRequest, checkpoint: base)
            }

        case .throttled(let retryAfter):
            let until = backoff.eligibleAt(
                now: now,
                retryAfter: retryAfter,
                targetID: target.targetID,
                jitter: jitter
            )
            return .throttled(until: until, retryAfter: retryAfter, checkpoint: base)

        case .unhandledStatus(let status):
            return .unhandledStatus(status: status, checkpoint: base)

        case .body(let body):
            return batchOutcome(body: body, checkpoint: base, now: now, limit: limit)
        }
    }

    // MARK: - Body handling

    private func batchOutcome(
        body: SyndicationHTTPBody,
        checkpoint: SyndicationCheckpoint,
        now: Date,
        limit: AcquisitionLimit
    ) -> SyndicationAcquisitionOutcome {
        let translation: SyndicationTranslation
        switch translator.translate(
            data: body.body,
            scope: target.scope,
            observedAt: now,
            maxItems: limit.maxItems,
            previousRepresentations: checkpoint.observedRepresentations,
            enrollment: enrollment
        ) {
        case .success(let translated): translation = translated
        case .failure(let error): return .parseFailure(reason: error.reason, checkpoint: checkpoint)
        }

        // The single rule that governs validator advancement (ADR-005 D12, `invariant 8`): the
        // validators of a body are proposed for confirmation only when this run consumed the whole
        // document. Everything else — a rejected item, an item ceiling, a parse failure, a truncated
        // body, a transport failure — leaves the checkpoint exactly as it arrived.
        let confirms = translation.consumedWholeDocument
        let proposed = confirms
            ? checkpoint.adoptingBaseline(
                validators: body.validators,
                endpoint: body.endpoint,
                observedRepresentations: translation.observedRepresentations
            )
            : checkpoint

        // The batch is bounded by construction: every payload is derived from a body that passed the
        // byte ceilings and from at most `maxItems` items, so no oversized batch can be emitted
        // (ADR-005 D4).
        let fingerprint = SyndicationBatchFingerprint.fingerprint(of: translation.observations)
        let batch = AcquisitionBatch(
            batchID: "\(target.targetID.rawValue)#\(target.generation)#\(fingerprint)",
            fingerprint: fingerprint,
            targetID: target.targetID,
            generation: target.generation,
            observations: translation.observations,
            evidence: evidence(translation: translation, body: body.body, chain: body.chain)
        )
        return .batch(SyndicationBatchOutcome(
            batch: batch,
            translation: translation,
            proposedCheckpoint: proposed,
            endpoint: body.endpoint,
            redirectChain: body.chain,
            proposesValidatorConfirmation: confirms
        ))
    }

    /// Opaque audit records. Nothing downstream decodes them, and removing all of them changes no
    /// selection or publication output (ADR-005 D1, `invariant 2`).
    private func evidence(
        translation: SyndicationTranslation,
        body: Data,
        chain: [URL]
    ) -> [ConnectorEvidence] {
        var evidence: [ConnectorEvidence] = []
        evidence.append(ConnectorEvidence(
            kind: .responseBody,
            digest: SyndicationFingerprint.hex(SyndicationFingerprint.fingerprint128(body)),
            bytes: body.count <= limits.evidenceBodyCeiling ? body : nil
        ))
        if chain.count > 1 {
            // The chain is recorded in its audit form: a query string is personal data and is never
            // logged or persisted (ADR-005 D14).
            let audit = chain.map(\.absoluteString).joined(separator: "\n")
            evidence.append(ConnectorEvidence(
                kind: .other,
                digest: SyndicationFingerprint.hex(SyndicationFingerprint.fingerprint128(Data(audit.utf8))),
                bytes: Data(audit.utf8)
            ))
        }
        for (index, item) in translation.items.enumerated() {
            for link in item.secondaryLinks {
                let material = Data("\(index)|\(link.relation.rawValue)|\(link.url)".utf8)
                evidence.append(ConnectorEvidence(
                    kind: .parsedEntry,
                    digest: SyndicationFingerprint.hex(SyndicationFingerprint.fingerprint128(material)),
                    bytes: Data(link.url.utf8)
                ))
            }
        }
        return evidence
    }

    // MARK: - Failure mapping

    private func failure(
        for error: SyndicationHTTPError,
        checkpoint: SyndicationCheckpoint
    ) -> SyndicationAcquisitionOutcome {
        switch error {
        case .transport(let failureClass):
            return .transportFailure(
                failureClass: failureClass,
                retryable: failureClass.isRetryable,
                checkpoint: checkpoint
            )
        case .invalidEndpoint(let rejection):
            return .refused(.endpointRejected(rejection.description), checkpoint: checkpoint)
        case .invalidRedirectTarget(let rejection):
            return .refused(.redirectTargetRejected(rejection.description), checkpoint: checkpoint)
        case .missingLocation(let status):
            return .refused(.missingRedirectLocation(status: status), checkpoint: checkpoint)
        case .redirectLimitExceeded(let limit):
            return .refused(.redirectLimitExceeded(limit: limit), checkpoint: checkpoint)
        case .compressedBodyTooLarge(let limit, let declared):
            return .refused(.compressedBodyTooLarge(limit: limit, declared: declared), checkpoint: checkpoint)
        case .decompressedBodyTooLarge(let limit, let received):
            return .refused(.bodyTooLarge(limit: limit, received: received), checkpoint: checkpoint)
        case .notModifiedWithoutConditionalRequest:
            return .refused(.notModifiedWithoutConditionalRequest, checkpoint: checkpoint)
        }
    }

    /// The checkpoint this run may use: one that belongs to this endpoint, generation and connector.
    ///
    /// Anything else is discarded and replaced by an initial checkpoint, so the fetch is
    /// unconditional. An endpoint change — including one learned through a redirect — never re-applies
    /// the previous endpoint's validator (ADR-005 D10, D12, `invariant 7`).
    private func usableCheckpoint(_ checkpoint: SyndicationCheckpoint?) -> SyndicationCheckpoint {
        guard let checkpoint,
              checkpoint.isUsable(
                for: target.endpoint,
                generation: target.generation,
                connectorNamespace: target.scope.namespace.rawValue
              )
        else {
            return SyndicationCheckpoint.initial(
                generation: target.generation,
                endpoint: target.endpoint,
                connectorNamespace: target.scope.namespace.rawValue
            )
        }
        return checkpoint
    }
}
