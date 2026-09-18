import Foundation

/// What a connector hands to Admission: canonical DTOs plus opaque evidence.
///
/// A connector never hands GRDB rows, FeedKit objects or closures to be interpreted downstream
/// (plan §7, ADR-005 D1). Everything here is a `Sendable` value type, so the translation can
/// happen on a worker and the evidence can be deleted without changing selection or publication.
///
/// The claims that belong to one observation travel on it (technical architecture §11: "a
/// implementação proposta agrupa claims pertencentes à mesma observation"), so applying a batch
/// never has to join several parallel arrays by position.

public enum AdmissionContractError: Error, Equatable, Sendable {
    case emptyMembershipKind
    case bindingGenerationWithoutBinding
    case emptyProviderKey
    case emptyProviderNamespace
    case emptyMediaResourceURL
    case negativeMediaPosition(Int)
    case emptyOfferKind
    case negativeOfferPosition(Int)
    case nonPositiveCheckpointSchema(Int)
    case emptyConnectorVersion
}

/// One observation of one external object, already translated out of its wire format.
public struct AcquisitionObservation: Hashable, Sendable {
    /// Namespace of the connector plus the origin/account/feed scope plus the full external key.
    public let externalKey: ExternalObjectKey
    /// Version key of this representation. Not assumed to be globally ordered (ADR-003 D9).
    public let versionKey: ExternalVersionKey?
    /// Instruction the connector derived from the wire format: the core never re-reads it.
    public let precedence: PrecedenceInstruction
    /// Canonicalized content for this representation.
    public let payload: ObservationPayload
    /// How the connector declared this identity. `.low` requires a fallback scheme version (D16).
    public let identityConfidence: IdentityConfidence
    /// Non-nil exactly when `identityConfidence` is `.low` (D16).
    public let fallbackSchemeVersion: Int?
    /// Attribution/authorship claim (ADR-003 D5).
    public let provider: ProviderClaim?
    /// Editorial membership claims (ADR-003 D15).
    public let memberships: [MembershipClaim]
    /// Promoted relations (ADR-003 D14).
    public let relations: [RelationClaim]
    /// Media the connector says this representation carries (plan §6, canonical group).
    public let mediaCandidates: [MediaCandidateClaim]
    /// Protocol-free interaction offers (Blueprint §49, ADR-005 D19).
    public let interactionOffers: [InteractionOfferClaim]

    public init(
        externalKey: ExternalObjectKey,
        versionKey: ExternalVersionKey?,
        precedence: PrecedenceInstruction,
        payload: ObservationPayload,
        identityConfidence: IdentityConfidence = .high,
        fallbackSchemeVersion: Int? = nil,
        provider: ProviderClaim? = nil,
        memberships: [MembershipClaim] = [],
        relations: [RelationClaim] = [],
        mediaCandidates: [MediaCandidateClaim] = [],
        interactionOffers: [InteractionOfferClaim] = []
    ) {
        self.externalKey = externalKey
        self.versionKey = versionKey
        self.precedence = precedence
        self.payload = payload
        self.identityConfidence = identityConfidence
        self.fallbackSchemeVersion = fallbackSchemeVersion
        self.provider = provider
        self.memberships = memberships
        self.relations = relations
        self.mediaCandidates = mediaCandidates
        self.interactionOffers = interactionOffers
    }

    /// The identity the observation declared, or `nil` when the declared confidence and fallback
    /// scheme version contradict each other. A low-confidence identity always names the versioned
    /// scheme that produced it, so `nil` here is not an identity at all (D16).
    public var declaredIdentity: ExternalIdentityRef? {
        try? ExternalIdentityRef(
            key: externalKey,
            confidence: identityConfidence,
            fallbackSchemeVersion: fallbackSchemeVersion
        )
    }
}

/// Closed instructions from the connector to Admission. The core executes these generically and
/// never parses RSS/Atom to choose precedence (plan §7, ADR-006 D3).
public enum PrecedenceInstruction: Hashable, Sendable {
    /// Record the representation, but do not make it current.
    case historicalOnly
    /// Identical to what is already current; do not create a spurious supply change.
    case duplicate
    /// Make this representation current if and only if the current revision is the expected one.
    case makeCurrent(expectedRevision: OriginRevisionID?)

    public var isCurrentRequest: Bool {
        if case .makeCurrent = self { return true }
        return false
    }
}

/// The canonical, protocol-free content of one observation.
public struct ObservationPayload: Hashable, Sendable {
    public let headline: String?
    /// `nil` when the source genuinely has no link. Never synthesize one for a view (ADR-003).
    public let link: URL?
    public let excerpt: String?
    public let body: String?
    public let authoredAt: Date?
    public let modifiedAt: Date?
    /// Always local: when this runtime observed the representation.
    public let observedAt: Date

    public init(
        headline: String?,
        link: URL?,
        excerpt: String?,
        body: String?,
        authoredAt: Date?,
        modifiedAt: Date?,
        observedAt: Date
    ) {
        self.headline = headline
        self.link = link
        self.excerpt = excerpt
        self.body = body
        self.authoredAt = authoredAt
        self.modifiedAt = modifiedAt
        self.observedAt = observedAt
    }
}

/// Opaque connector payload kept for audit and identity proof. Removable without changing
/// selection or publication (plan §7).
public struct ConnectorEvidence: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case parsedEntry
        case responseBody
        case other
    }

    public let kind: Kind
    public let digest: String
    public let bytes: Data?

    public init(kind: Kind, digest: String, bytes: Data? = nil) {
        self.kind = kind
        self.digest = digest
        self.bytes = bytes
    }
}

// MARK: - Claims (ADR-003 D5, D13–D15; Blueprint §49)

/// Attribution of a representation to a provider. The provider row is the runtime's; the
/// connector owns only the namespace-scoped key and the display name (ADR-003 D5).
public struct ProviderClaim: Hashable, Sendable {
    public let namespace: ConnectorNamespace
    public let providerKey: String
    public let displayName: String
    public let role: AttributionRole
    public let evidenceKey: String?

    public init(
        namespace: ConnectorNamespace,
        providerKey: String,
        displayName: String,
        role: AttributionRole,
        evidenceKey: String? = nil
    ) throws {
        guard !namespace.rawValue.isEmpty else { throw AdmissionContractError.emptyProviderNamespace }
        guard !providerKey.isEmpty else { throw AdmissionContractError.emptyProviderKey }
        self.namespace = namespace
        self.providerKey = providerKey
        self.displayName = displayName
        self.role = role
        self.evidenceKey = evidenceKey
    }
}

/// An editorial association claimed for the observation's record.
///
/// The claim names an editorial source and how it was known. Operational provenance (the target the
/// batch ran for) is added by Admission from the batch's stamp, so observing content through a
/// shared target still enrolls nothing (ADR-003 D15).
public struct MembershipClaim: Hashable, Sendable {
    public let sourceID: SourceID
    /// How it was known. Deliberately not an enumeration in the schema (ADR-003 D15).
    public let membershipKind: String
    /// The binding the claim came from, when the connector names one (ADR-003 D5/D6).
    public let binding: SourceBindingKey?
    public let bindingGeneration: UInt64?

    public init(
        sourceID: SourceID,
        membershipKind: String,
        binding: SourceBindingKey? = nil,
        bindingGeneration: UInt64? = nil
    ) throws {
        guard !membershipKind.isEmpty else { throw AdmissionContractError.emptyMembershipKind }
        guard bindingGeneration == nil || binding != nil else {
            throw AdmissionContractError.bindingGenerationWithoutBinding
        }
        self.sourceID = sourceID
        self.membershipKind = membershipKind
        self.binding = binding
        self.bindingGeneration = bindingGeneration
    }
}

/// A relation FeedMine promotes to canonical state. Verbs outside the four promoted ones are
/// connector evidence and never reach a canonical table (ADR-003 D14).
public struct RelationClaim: Hashable, Sendable {
    public let verb: ContentRelation.Verb
    /// The relation's object. An unresolved key stays evidence: the core does not invent a record.
    public let target: ExternalObjectKey

    public init(verb: ContentRelation.Verb, target: ExternalObjectKey) {
        self.verb = verb
        self.target = target
    }
}

/// What kind of media the connector says the representation carries (plan §6, canonical group).
/// Deliberately not a closed product vocabulary beyond these structural roles.
public enum MediaRole: String, Hashable, Sendable, Codable, CaseIterable {
    case image
    case thumbnail
    case poster
    case audio
    case video
    case waveform
}

/// A media candidate: where the connector says the bytes are, never a fetched asset.
///
/// The URL is opaque text: the core neither parses nor normalizes it, and Admission never fetches
/// (ADR-005 D17: media probing happens after admission, in FeedMedia).
public struct MediaCandidateClaim: Hashable, Sendable {
    public let role: MediaRole
    public let resourceURL: String
    public let mediaTypeHint: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let position: Int

    public init(
        role: MediaRole,
        resourceURL: String,
        mediaTypeHint: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        position: Int = 0
    ) throws {
        guard !resourceURL.isEmpty else { throw AdmissionContractError.emptyMediaResourceURL }
        guard position >= 0 else { throw AdmissionContractError.negativeMediaPosition(position) }
        self.role = role
        self.resourceURL = resourceURL
        self.mediaTypeHint = mediaTypeHint
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.position = position
    }
}

/// A capability the content offers without exposing the protocol that produces it (Blueprint §49).
/// `kind` is not enumerated: the vocabulary is a product decision, and the core only stores it.
public struct InteractionOfferClaim: Hashable, Sendable {
    public let kind: String
    /// The internal handle the offer points at; `nil` when the connector offers nothing executable.
    public let handle: String?
    public let position: Int

    public init(kind: String, handle: String? = nil, position: Int = 0) throws {
        guard !kind.isEmpty else { throw AdmissionContractError.emptyOfferKind }
        guard position >= 0 else { throw AdmissionContractError.negativeOfferPosition(position) }
        self.kind = kind
        self.handle = handle
        self.position = position
    }
}

// MARK: - Stamp and checkpoint (ADR-006 D1, D5; Blueprint §62)

/// Operational unit of acquisition work: independent from source identity (ADR-005 D5).
///
/// It is opaque text, not a local row identity: it names work, never editorial identity, and
/// nothing downstream derives selection or attribution from it (ADR-003 D7).
public struct AcquisitionTargetID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The durable state a batch was produced against.
///
/// Validity is decided at write admission, never when the work was scheduled: every one of these
/// values is compared to its durable row inside the admitting transaction (ADR-006 D1).
public struct TargetStamp: Hashable, Sendable {
    public let targetID: AcquisitionTargetID
    public let targetGeneration: UInt64
    public let bindingRevision: UInt64
    public let leaseEpoch: UInt64
    /// The checkpoint revision the connector believes is current (the CAS expectation).
    public let checkpointRevision: UInt64

    public init(
        targetID: AcquisitionTargetID,
        targetGeneration: UInt64,
        bindingRevision: UInt64,
        leaseEpoch: UInt64,
        checkpointRevision: UInt64
    ) {
        self.targetID = targetID
        self.targetGeneration = targetGeneration
        self.bindingRevision = bindingRevision
        self.leaseEpoch = leaseEpoch
        self.checkpointRevision = checkpointRevision
    }
}

/// Resumption state through an external stream. Opaque to the core: it is stored and handed back
/// to the connector, never interpreted (Blueprint §62).
public struct ConnectorCheckpoint: Hashable, Sendable {
    public let blob: Data?
    public let serializationSchema: Int
    public let connectorVersion: String

    public init(blob: Data?, serializationSchema: Int, connectorVersion: String) throws {
        guard serializationSchema > 0 else {
            throw AdmissionContractError.nonPositiveCheckpointSchema(serializationSchema)
        }
        guard !connectorVersion.isEmpty else { throw AdmissionContractError.emptyConnectorVersion }
        self.blob = blob
        self.serializationSchema = serializationSchema
        self.connectorVersion = connectorVersion
    }
}

/// One batch of observations for one acquisition target, identified so that a replay is free and
/// a repeated id with a different body is an error (plan §7, ADR-006 D3).
public struct AcquisitionBatch: Hashable, Sendable {
    public let batchID: String
    /// The connector's own fingerprint. Admission persists its own digest of the body instead:
    /// a value the runtime cannot recompute is not evidence (ADR-006 D2, rejected alternatives).
    public let fingerprint: String
    public let targetID: AcquisitionTargetID
    public let generation: UInt64
    public let observations: [AcquisitionObservation]
    public let evidence: [ConnectorEvidence]
    public let bindingRevision: UInt64
    public let leaseEpoch: UInt64
    /// The checkpoint revision this batch was produced against (ADR-006 D5).
    public let expectedCheckpointRevision: UInt64
    /// Where the stream resumes after this batch. `nil` when the connector has nothing to advance.
    public let nextCheckpoint: ConnectorCheckpoint?

    public init(
        batchID: String,
        fingerprint: String,
        targetID: AcquisitionTargetID,
        generation: UInt64,
        observations: [AcquisitionObservation],
        evidence: [ConnectorEvidence] = [],
        bindingRevision: UInt64 = 1,
        leaseEpoch: UInt64 = 0,
        expectedCheckpointRevision: UInt64 = 0,
        nextCheckpoint: ConnectorCheckpoint? = nil
    ) {
        self.batchID = batchID
        self.fingerprint = fingerprint
        self.targetID = targetID
        self.generation = generation
        self.observations = observations
        self.evidence = evidence
        self.bindingRevision = bindingRevision
        self.leaseEpoch = leaseEpoch
        self.expectedCheckpointRevision = expectedCheckpointRevision
        self.nextCheckpoint = nextCheckpoint
    }

    /// The ledger key an adapter must stamp: the target, its generation, the binding revision, the
    /// **lease epoch**, the connector's content fingerprint and the next checkpoint.
    ///
    /// The connector's own id — `target#generation#observations` — is narrower on both ends that
    /// matter. It omits the next checkpoint, so a page re-delivered with a new position under the same
    /// content would reuse a key belonging to a different proposal. And it omits the lease epoch, so a
    /// launch — which acquires a fresh epoch every time — presented the *same* key with a different
    /// body, which is `batchConflict` by definition: every warm launch refused its own re-delivery
    /// (§8.55). The lease belongs in the key because the ADR-006 D2 body carries it: work under a
    /// superseded epoch is different work.
    ///
    /// The key deliberately does **not** carry the expected checkpoint revision, even though that
    /// field is part of the runtime's stamp. It is derived from the durable row and advances as a
    /// consequence of admitting the batch itself, so a key that carried it would make the same page a
    /// new batch forever — measured: 24 admissions in one episode where the design intends one (§8.55).
    /// `BatchFingerprint` excludes it for the same reason, so the key and the digest agree on what
    /// "the same batch" means. Both adapters call this — `FeedConnectorSource` in the package and
    /// `SyndicationAcquisitionSource` in the app.
    public static func ledgerID(
        targetID: AcquisitionTargetID,
        generation: UInt64,
        bindingRevision: UInt64,
        leaseEpoch: UInt64,
        contentFingerprint: String,
        observations: [AcquisitionObservation],
        nextCheckpoint: ConnectorCheckpoint?
    ) -> String {
        [
            targetID.rawValue,
            String(generation),
            String(bindingRevision),
            String(leaseEpoch),
            contentFingerprint,
            precedenceSignature(of: observations),
            String(nextCheckpoint?.serializationSchema ?? 0),
            nextCheckpoint?.connectorVersion ?? "-",
            nextCheckpoint?.blob?.base64EncodedString() ?? "-"
        ].joined(separator: "#")
    }

    /// What the batch instructs the runtime to do with each observation, in order.
    ///
    /// The instruction is part of the runtime's digest — an unchanged representation re-delivered by a
    /// connector whose stamps have caught up is a different proposal from the first sighting, and its
    /// effect differs — so the ledger key has to cover it as well. Without it, the same page fetched
    /// twice inside one episode is the same key with a different body: `batchConflict` by definition.
    /// That is what a warm launch did on its second pull, one epoch and one deficit into the episode
    /// (§8.55), and the refusal is why its checkpoint never advanced.
    public static func precedenceSignature(of observations: [AcquisitionObservation]) -> String {
        observations.map { observation in
            switch observation.precedence {
            case .historicalOnly: return "h"
            case .duplicate: return "d"
            case .makeCurrent: return "c"
            }
        }.joined()
    }

    /// What Admission validates against the durable target row (ADR-006 D1).
    public var stamp: TargetStamp {
        TargetStamp(
            targetID: targetID,
            targetGeneration: generation,
            bindingRevision: bindingRevision,
            leaseEpoch: leaseEpoch,
            checkpointRevision: expectedCheckpointRevision
        )
    }
}

/// What Admission is allowed to answer. Logs must distinguish identity conflicts from transport
/// failures (plan §7).
public enum AdmissionResult: Hashable, Sendable {
    case admitted(AdmissionReceipt)
    /// The batch was already admitted: zero canonical mutation, zero supply increment. The stored
    /// receipt is read back through the admission ledger (ADR-006 D2).
    case duplicate(batchID: String)
    /// The same batch id arrived with a different body. Nothing is mutated and the conflict is
    /// audited (ADR-006 D2, D12).
    case batchConflict(batchID: String)
    case staleTarget(generation: UInt64)
    case staleCheckpoint(expected: UInt64, actual: UInt64)
    case identityConflict(ExternalObjectKey)
    case invalidObservation(reason: String)
    case storageFailure(reason: String)
}

public struct AdmissionReceipt: Hashable, Sendable, Codable {
    public let batchID: String
    public let admittedRevisionCount: Int
    public let supplyGeneration: UInt64
    public let checkpointRevision: UInt64
    public let supplyChanged: Bool

    public init(
        batchID: String,
        admittedRevisionCount: Int,
        supplyGeneration: UInt64,
        checkpointRevision: UInt64,
        supplyChanged: Bool
    ) {
        self.batchID = batchID
        self.admittedRevisionCount = admittedRevisionCount
        self.supplyGeneration = supplyGeneration
        self.checkpointRevision = checkpointRevision
        self.supplyChanged = supplyChanged
    }
}
