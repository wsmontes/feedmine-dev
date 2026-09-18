import Foundation

/// Source, provider, binding, target, membership, observation and the two reversible equivalence
/// relations (ADR-003 D5–D7, D13–D15).
///
/// Everything here is a `Sendable` value. Nothing in this file allocates an identifier, derives one
/// identity from another, or writes: allocation and persistence belong to `FeedStorage` (PR-03).

// MARK: - Bindings (D5, D6)

/// Identity of a source binding: the connector that owns it plus the connector-owned binding key
/// (`UNIQUE (connector_namespace, binding_key)`). A binding has no runtime integer identity, because
/// continuity across endpoint changes is exactly what must keep the same `SourceID` (D6).
public struct SourceBindingKey: Hashable, Sendable {
    public let namespace: ConnectorNamespace
    public let bindingKey: String

    public init(namespace: ConnectorNamespace, bindingKey: String) {
        self.namespace = namespace
        self.bindingKey = bindingKey
    }
}

/// Eligibility, not identity: a disabled or revoked binding keeps its rows (invariant 20).
public enum BindingState: String, Hashable, Sendable, Codable, CaseIterable {
    case enabled
    case disabled
    case revoked
}

public enum SourceBindingError: Error, Equatable, Sendable {
    /// A generation starts at 1 and only ever increases (`CHECK (generation >= 1)`).
    case nonPositiveGeneration(UInt64)
    /// The monotonic generation counter is exhausted; a silent wrap would re-enable stale work.
    case generationExhausted
}

/// The declarative relation between one editorial source and one external system (D5).
///
/// The connector namespace and its configuration are connector-owned: `configurationJSON` is opaque
/// string data the core stores and never parses. Changing the endpoint or the configuration keeps the
/// same `SourceID` and advances `generation`; it never creates a source (D6).
public struct SourceBinding: Hashable, Sendable {
    public let key: SourceBindingKey
    public let sourceID: SourceID
    public let configurationJSON: String
    public let state: BindingState
    public let generation: UInt64

    public init(
        key: SourceBindingKey,
        sourceID: SourceID,
        configurationJSON: String,
        state: BindingState = .enabled,
        generation: UInt64 = 1
    ) throws {
        guard generation > 0 else { throw SourceBindingError.nonPositiveGeneration(generation) }
        self.init(
            uncheckedKey: key,
            sourceID: sourceID,
            configurationJSON: configurationJSON,
            state: state,
            generation: generation
        )
    }

    private init(
        uncheckedKey key: SourceBindingKey,
        sourceID: SourceID,
        configurationJSON: String,
        state: BindingState,
        generation: UInt64
    ) {
        self.key = key
        self.sourceID = sourceID
        self.configurationJSON = configurationJSON
        self.state = state
        self.generation = generation
    }

    /// D6: reconfiguring a binding is the same binding at the next generation. The source identity
    /// and the binding key are untouched, so nothing downstream re-points (continuity is asserted by
    /// an explicit mapping, never inferred from a URL: D6, D19).
    public func advanced(to configurationJSON: String) throws -> SourceBinding {
        guard generation < UInt64.max else { throw SourceBindingError.generationExhausted }
        return SourceBinding(
            uncheckedKey: key,
            sourceID: sourceID,
            configurationJSON: configurationJSON,
            state: state,
            generation: generation + 1
        )
    }

    /// Disablement changes eligibility, never identity: the source, the binding key and every
    /// identity row stay as they are (invariant 20).
    public func disabled() -> SourceBinding {
        SourceBinding(
            uncheckedKey: key,
            sourceID: sourceID,
            configurationJSON: configurationJSON,
            state: .disabled,
            generation: generation
        )
    }

    public func revoked() -> SourceBinding {
        SourceBinding(
            uncheckedKey: key,
            sourceID: sourceID,
            configurationJSON: configurationJSON,
            state: .revoked,
            generation: generation
        )
    }

    /// Whether work stamped with `generation` still belongs to this binding. A batch produced under
    /// an older generation (or a binding that is no longer enabled) is refused at Admission; the
    /// binding itself stays intact and usable at its current generation (D6, I-12).
    public func accepts(generation candidate: UInt64) -> Bool {
        state == .enabled && candidate == generation
    }
}

// MARK: - Providers (D5)

/// Attribution/authorship used for diversity and display. One source contains many providers and one
/// provider appears in sources it does not own: provider identity is never a grouping substitute for
/// `SourceID` (D5, invariant 17).
public struct Provider: Hashable, Sendable {
    public let id: ProviderID
    public let namespace: ConnectorNamespace
    /// Durable, namespace-scoped provider key (`UNIQUE (connector_namespace, provider_key)`).
    public let providerKey: String
    public let displayName: String
    public let createdAt: Date

    public init(
        id: ProviderID,
        namespace: ConnectorNamespace,
        providerKey: String,
        displayName: String,
        createdAt: Date
    ) {
        self.id = id
        self.namespace = namespace
        self.providerKey = providerKey
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public enum AttributionRole: String, Hashable, Sendable, Codable, CaseIterable {
    case primary
    case publisher
    case contributor
}

/// Attribution of one revision to one provider. It is a fact about a revision and never a change to
/// source identity or membership (D5, invariant 17).
public struct ProviderAttribution: Hashable, Sendable {
    public let revision: OriginRevisionID
    public let provider: ProviderID
    public let role: AttributionRole
    /// Connector-owned evidence for the attribution, kept so the claim can be replayed.
    public let evidenceKey: String?
    public let createdAt: Date

    public init(
        revision: OriginRevisionID,
        provider: ProviderID,
        role: AttributionRole,
        evidenceKey: String? = nil,
        createdAt: Date
    ) {
        self.revision = revision
        self.provider = provider
        self.role = role
        self.evidenceKey = evidenceKey
        self.createdAt = createdAt
    }
}

// MARK: - Membership and observation (D15)

/// How an editorial membership was known. An acquisition-backed claim names the target and the
/// binding generation that evidenced it; an editorial claim names neither, because there was no
/// acquisition behind it (D15).
public enum MembershipEvidence: Hashable, Sendable {
    case acquisition(target: AcquisitionTargetID, binding: SourceBindingKey, bindingGeneration: UInt64)
    case editorial
}

/// An editorial association between a record and a source. It exists only when something claimed it:
/// an observation through a shared target enrolls nothing (D15, invariant 6).
public struct SourceMembership: Hashable, Sendable {
    public let record: OriginRecordID
    public let sourceID: SourceID
    /// How it was known. Deliberately not an enumeration in the schema yet (ADR-003 OPEN item).
    public let membershipKind: String
    public let evidence: MembershipEvidence
    public let firstObservedAt: Date
    public let lastObservedAt: Date

    public init(
        record: OriginRecordID,
        sourceID: SourceID,
        membershipKind: String,
        evidence: MembershipEvidence,
        firstObservedAt: Date,
        lastObservedAt: Date
    ) {
        self.record = record
        self.sourceID = sourceID
        self.membershipKind = membershipKind
        self.evidence = evidence
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
    }
}

/// One fix's record that a target produced an observation of an external identity. It is operational
/// provenance: it names a target, not a source, and it creates no membership (D7, D15).
public struct TargetObservation: Hashable, Sendable {
    public let target: AcquisitionTargetID
    public let binding: SourceBindingKey
    public let bindingGeneration: UInt64
    public let key: ExternalObjectKey
    public let observedAt: Date

    public init(
        target: AcquisitionTargetID,
        binding: SourceBindingKey,
        bindingGeneration: UInt64,
        key: ExternalObjectKey,
        observedAt: Date
    ) {
        self.target = target
        self.binding = binding
        self.bindingGeneration = bindingGeneration
        self.key = key
        self.observedAt = observedAt
    }
}

/// Holds the three provenance relations of D5 and D15 side by side.
///
/// The only way in is an explicit claim of the matching kind: recording an observation cannot create
/// a membership, claiming a membership cannot create an observation, and attributing a revision to a
/// provider cannot change either (invariants 6 and 17).
public struct Provenance: Hashable, Sendable {
    public private(set) var observations: [TargetObservation] = []
    public private(set) var memberships: [SourceMembership] = []
    public private(set) var attributions: [ProviderAttribution] = []

    public init() {}

    public mutating func record(_ observation: TargetObservation) {
        observations.append(observation)
    }

    /// Returns `true` when the claim was new. The claim key is
    /// `(origin record, source, membership kind)`, so a repeated claim is a no-op.
    @discardableResult
    public mutating func claim(_ membership: SourceMembership) -> Bool {
        let isDuplicate = memberships.contains {
            $0.record == membership.record
                && $0.sourceID == membership.sourceID
                && $0.membershipKind == membership.membershipKind
        }
        guard !isDuplicate else { return false }
        memberships.append(membership)
        return true
    }

    /// Returns `true` when the attribution was new. The claim key is
    /// `(revision, provider, attribution role)`.
    @discardableResult
    public mutating func attribute(_ attribution: ProviderAttribution) -> Bool {
        let isDuplicate = attributions.contains {
            $0.revision == attribution.revision
                && $0.provider == attribution.provider
                && $0.role == attribution.role
        }
        guard !isDuplicate else { return false }
        attributions.append(attribution)
        return true
    }
}

// MARK: - Equivalence as a relation (D13)

public enum RelationsError: Error, Equatable, Sendable {
    /// `CHECK (confidence >= 0.0 AND confidence <= 1.0)`.
    case clusterConfidenceOutOfRange(Double)
}

/// Strong equivalence inside an explicit trust domain. A relation, not a merge: the record it names
/// keeps its own identity and revisions (D13).
public struct ContentEntityMember: Hashable, Sendable {
    public let entityID: Int64
    public let record: OriginRecordID
    public let method: String
    public let version: Int
    public let createdAt: Date

    public init(entityID: Int64, record: OriginRecordID, method: String, version: Int, createdAt: Date) {
        self.entityID = entityID
        self.record = record
        self.method = method
        self.version = version
        self.createdAt = createdAt
    }
}

/// Soft similarity carrying the confidence, method and version that produced it, so a weak
/// similarity is never presented as an identity (D13).
public struct ContentClusterMember: Hashable, Sendable {
    public let clusterID: Int64
    public let record: OriginRecordID
    public let confidence: Double
    public let method: String
    public let version: Int
    public let createdAt: Date

    public init(
        clusterID: Int64,
        record: OriginRecordID,
        confidence: Double,
        method: String,
        version: Int,
        createdAt: Date
    ) throws {
        guard confidence >= 0.0 && confidence <= 1.0 else {
            throw RelationsError.clusterConfidenceOutOfRange(confidence)
        }
        self.clusterID = clusterID
        self.record = record
        self.confidence = confidence
        self.method = method
        self.version = version
        self.createdAt = createdAt
    }
}

/// The entity/cluster relation rows of D13.
///
/// Nothing here owns a record: `split()` removes every relation row and the records it named stay
/// exactly as they were, individually resolvable and individually selectable (invariant 15).
public struct ContentEquivalence: Hashable, Sendable {
    public private(set) var entityMembers: [ContentEntityMember] = []
    public private(set) var clusterMembers: [ContentClusterMember] = []

    public init() {}

    /// Returns `true` when the relation row was new: `(entity, record)` is the primary key.
    @discardableResult
    public mutating func declare(_ member: ContentEntityMember) -> Bool {
        let isDuplicate = entityMembers.contains {
            $0.entityID == member.entityID && $0.record == member.record
        }
        guard !isDuplicate else { return false }
        entityMembers.append(member)
        return true
    }

    /// Returns `true` when the relation row was new: `(cluster, record)` is the primary key.
    @discardableResult
    public mutating func declare(_ member: ContentClusterMember) -> Bool {
        let isDuplicate = clusterMembers.contains {
            $0.clusterID == member.clusterID && $0.record == member.record
        }
        guard !isDuplicate else { return false }
        clusterMembers.append(member)
        return true
    }

    public func entityID(of record: OriginRecordID) -> Int64? {
        entityMembers.first { $0.record == record }?.entityID
    }

    public func clusterIDs(of record: OriginRecordID) -> [Int64] {
        clusterMembers.filter { $0.record == record }.map(\.clusterID).sorted()
    }

    public var isEmpty: Bool { entityMembers.isEmpty && clusterMembers.isEmpty }

    /// D13: dropping the relation restores the split. The records and their revisions are not
    /// touched, because the relation never owned them.
    public mutating func split() {
        entityMembers.removeAll()
        clusterMembers.removeAll()
    }
}

// MARK: - Promoted relations (D14)

/// A relation that changes how FeedMine selects or presents content. Anything else a connector
/// declares stays connector evidence and enters no canonical table (D14, invariant 16).
public struct ContentRelation: Hashable, Sendable {
    public enum Verb: String, Hashable, Sendable, Codable, CaseIterable {
        case replyTo
        case repostOf
        case quoteOf
        case references
    }

    /// The relation's object. An unresolved target stays an opaque external key: the core does not
    /// invent a record for it (D8, D14).
    public enum Target: Hashable, Sendable {
        case record(OriginRecordID)
        case externalKey(ExternalObjectKey)
    }

    public let subject: OriginRecordID
    public let verb: Verb
    public let target: Target
    public let createdAt: Date

    private init(subject: OriginRecordID, verb: Verb, target: Target, createdAt: Date) {
        self.subject = subject
        self.verb = verb
        self.target = target
        self.createdAt = createdAt
    }

    /// Promotes a connector-declared relation verb. `nil` means the verb is outside the four
    /// promoted relations: it may travel as connector evidence, and it must not be stored as a
    /// canonical relation (D14).
    public init?(
        subject: OriginRecordID,
        declaredVerb: String,
        target: Target,
        createdAt: Date
    ) {
        guard let verb = Verb(rawValue: declaredVerb) else { return nil }
        self.init(subject: subject, verb: verb, target: target, createdAt: createdAt)
    }
}
