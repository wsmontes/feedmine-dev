import Foundation

/// The in-memory identity resolver: the value-level behaviour of ADR-003 D8–D12, D16.
///
/// It is a pure value/collection type. It allocates local identities, but it never writes, never
/// parses a wire format, and never mutates a stored representation: a changed payload is a new
/// revision and a contradiction is a recorded conflict (invariants 1, 3, 4, 5, 9, 14).

/// Where a conflict was detected. External conflicts happen inside one key space (D8); the legacy
/// bridge has no external scope and names the durable editorial key instead (D18).
public enum IdentityConflictScope: Hashable, Sendable {
    case external(ExternalScopeKey)
    case legacyBridge(EditorialSourceKey)
}

/// A recorded contradiction. Nothing is overwritten, merged or deleted to resolve one: the record
/// is evidence that a decision was refused or that two identities are distinct (D11, D12, D18).
public struct IdentityConflict: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The same version key arrived with a divergent payload (D11).
        case versionPayloadDivergence
        /// A key is claimed by two records in one scope; neither record moves (D12).
        case ambiguousAlias
        /// Two distinct full keys share an auxiliary digest. They stay distinct identities (D8).
        case digestCollision
        /// A legacy mapping row contests an established mapping (D18).
        case legacyMapConflict
    }

    public let kind: Kind
    public let scope: IdentityConflictScope
    /// The record that already owned the key or version key when the conflict was detected.
    public let existingRecord: OriginRecordID?
    /// The record that claimed it. `nil` when the claim came from a key that owns nothing yet.
    public let claimingRecord: OriginRecordID?
    /// The runtime source a persisted mapping already pointed at (D18).
    public let existingSource: SourceID?
    /// The runtime source a rebuild claimed for the same durable key (D18).
    public let claimedSource: SourceID?
    /// Digest of the key that arrived. Auxiliary evidence only; never a decision input (D8).
    public let incomingKeyDigest: ExternalKeyDigest?
    /// Payload digests compared by `versionPayloadDivergence`, stored against incoming (D11).
    public let storedPayloadDigest: PayloadDigest?
    public let incomingPayloadDigest: PayloadDigest?
    public let detectedAt: Date
}

public enum IdentityIndexError: Error, Equatable, Sendable {
    /// A mapping can never point at a record the index does not hold (foreign keys are real).
    case unknownRecord(OriginRecordID)
}

/// What happened to one representation.
public enum RevisionOutcome: Hashable, Sendable {
    /// A new immutable revision was appended (D9).
    case appended(OriginRevisionID)
    /// The identical representation was already stored: no new revision, no supply change.
    case duplicate(OriginRevisionID)
    /// The version key is already attached to a revision with a divergent payload. The stored
    /// revision is preserved unchanged and nothing was appended; the conflict records both digests
    /// (D11, invariant 4).
    case divergentPayloadPreserved(stored: OriginRevisionID)
}

/// The typed answer to "what is this observation's identity?" (D8–D12, D16).
public enum IdentityResolution: Hashable, Sendable {
    case newRecord(
        record: OriginRecordID,
        revision: RevisionOutcome,
        confidence: IdentityConfidence,
        fallbackSchemeVersion: Int?,
        conflicts: [IdentityConflict]
    )
    case existingRecord(
        record: OriginRecordID,
        revision: RevisionOutcome,
        confidence: IdentityConfidence,
        fallbackSchemeVersion: Int?,
        conflicts: [IdentityConflict]
    )
    /// The mapping was refused. Only the conflict log changed (D12).
    case refused(IdentityConflict)
}

/// One observation offered for resolution.
public struct IdentityResolutionRequest: Hashable, Sendable {
    public let key: ExternalObjectKey
    public let versionKey: ExternalVersionKey?
    public let payload: ObservationPayload
    public let confidence: IdentityConfidence
    /// Non-nil exactly when `confidence` is `.low` (D16).
    public let fallbackSchemeVersion: Int?

    /// A declared identity: the connector supplied a real external key (D8–D12).
    public init(
        key: ExternalObjectKey,
        versionKey: ExternalVersionKey? = nil,
        payload: ObservationPayload
    ) {
        self.init(key: key, versionKey: versionKey, payload: payload, confidence: .high, fallbackSchemeVersion: nil)
    }

    /// A fallback identity: there is no usable key, so the connector's versioned scheme is recorded
    /// with a low confidence. This is the only way to reach `.low` (D16).
    public init(
        key: ExternalObjectKey,
        versionKey: ExternalVersionKey? = nil,
        payload: ObservationPayload,
        fallbackScheme: FallbackIdentityScheme
    ) {
        self.init(
            key: key,
            versionKey: versionKey,
            payload: payload,
            confidence: .low,
            fallbackSchemeVersion: fallbackScheme.version
        )
    }

    private init(
        key: ExternalObjectKey,
        versionKey: ExternalVersionKey?,
        payload: ObservationPayload,
        confidence: IdentityConfidence,
        fallbackSchemeVersion: Int?
    ) {
        self.key = key
        self.versionKey = versionKey
        self.payload = payload
        self.confidence = confidence
        self.fallbackSchemeVersion = fallbackSchemeVersion
    }
}

/// D3: ascending allocation of positive row identifiers, with zero reserved and no wrap.
struct IdentifierCounter: Sendable, Equatable {
    private var next: Int64

    init() {
        next = 1
    }

    /// Resumes allocation after a persisted high-water mark. Zero and negatives are refused, because
    /// zero is the reserved "none" value and never a row (D3).
    init(next: Int64) throws {
        guard next > 0 else { throw RuntimeIDError.nonPositiveRowID(Int64.self, next) }
        self.next = next
    }

    mutating func allocate() throws -> Int64 {
        guard next < Int64.max else { throw RuntimeIDError.identifierSpaceExhausted(next) }
        defer { next += 1 }
        return next
    }
}

public struct IdentityIndex: Sendable {
    private struct ObjectIdentity: Sendable {
        let ref: ExternalIdentityRef
        let digest: ExternalKeyDigest
        let record: OriginRecordID
    }

    private struct VersionIdentity: Sendable {
        let record: OriginRecordID
        let revision: OriginRevisionID
        let payloadDigest: PayloadDigest
    }

    /// One entry of the auxiliary digest index. The kind is part of the slot because
    /// `UNIQUE (namespace, scope, key_kind, external_key)` keeps the two key spaces apart (D8).
    private struct DigestSlot: Hashable {
        let scope: ExternalScopeKey
        let kind: ExternalKeyKind
        let digest: ExternalKeyDigest
    }

    private enum KeySpaceMember: Hashable {
        case object(ExternalObjectKey)
        case version(ExternalVersionKey)

        var sortKey: String {
            switch self {
            case let .object(key):
                return "object|\(key.scope.description)|\(key.bytes.base64EncodedString())"
            case let .version(key):
                return "version|\(key.scope.description)|\(key.bytes.base64EncodedString())"
            }
        }
    }

    private enum RevisionPlan {
        case duplicate(OriginRevisionID)
        case divergentPayload(
            versionKey: ExternalVersionKey,
            stored: OriginRevisionID,
            storedDigest: PayloadDigest,
            incomingDigest: PayloadDigest
        )
        case append(OriginRevisionID, versionKey: ExternalVersionKey?, payloadDigest: PayloadDigest)
    }

    private let digestPolicy: any IdentityDigestPolicy
    private var objectIdentities: [ExternalObjectKey: ObjectIdentity] = [:]
    private var versionIdentities: [ExternalVersionKey: VersionIdentity] = [:]
    private var digestSlots: [DigestSlot: Set<KeySpaceMember>] = [:]
    private var recordsByID: [OriginRecordID: OriginRecord] = [:]
    private var recordOrder: [OriginRecordID] = []
    private var revisionsByID: [OriginRevisionID: OriginRevision] = [:]
    private var revisionsByRecord: [OriginRecordID: [OriginRevisionID]] = [:]
    private var conflictLog: [IdentityConflict] = []
    private var recordIDs = IdentifierCounter()
    private var revisionIDs = IdentifierCounter()

    public init(digestPolicy: any IdentityDigestPolicy = StandardIdentityDigest()) {
        self.digestPolicy = digestPolicy
    }

    // MARK: - Reads

    /// Records in allocation order.
    public var records: [OriginRecord] { recordOrder.compactMap { recordsByID[$0] } }

    public func record(_ id: OriginRecordID) -> OriginRecord? { recordsByID[id] }

    /// The record a full key resolves to, aliases included (D12).
    public func record(for key: ExternalObjectKey) -> OriginRecordID? {
        objectIdentities[key]?.record
    }

    /// The identity a key is known by, with the confidence it was declared with (D16).
    public func identity(for key: ExternalObjectKey) -> ExternalIdentityRef? {
        objectIdentities[key]?.ref
    }

    /// The revisions of a record, in append order. Deliberately not ordered by version key: no such
    /// order exists (D9, invariant 3).
    public func revisions(of record: OriginRecordID) -> [OriginRevision] {
        (revisionsByRecord[record] ?? []).compactMap { revisionsByID[$0] }
    }

    public func revision(_ id: OriginRevisionID) -> OriginRevision? { revisionsByID[id] }

    public var conflicts: [IdentityConflict] { conflictLog }

    public var recordCount: Int { recordOrder.count }
    public var revisionCount: Int { revisionsByID.count }
    public var identityCount: Int { objectIdentities.count + versionIdentities.count }

    // MARK: - Resolution

    /// Resolves one observation. Resolution never merges records: a key that no record owns creates
    /// one, and attaching a key to an existing record is the explicit claim of `attachAlias` (D12).
    @discardableResult
    public mutating func resolve(_ request: IdentityResolutionRequest) throws -> IdentityResolution {
        if let conflict = versionKeyClaimedByAnotherRecord(request) {
            conflictLog.append(conflict)
            return .refused(conflict)
        }

        if let existing = objectIdentities[request.key] {
            let plan = try revisionPlan(for: request, record: existing.record)
            updateObservation(of: existing.record, at: request.payload.observedAt)
            let (outcome, conflicts) = commit(
                plan,
                request: request,
                record: existing.record,
                confidence: existing.ref.confidence,
                fallbackSchemeVersion: existing.ref.fallbackSchemeVersion
            )
            conflictLog.append(contentsOf: conflicts)
            return .existingRecord(
                record: existing.record,
                revision: outcome,
                confidence: existing.ref.confidence,
                fallbackSchemeVersion: existing.ref.fallbackSchemeVersion,
                conflicts: conflicts
            )
        }

        let recordID = try OriginRecordID(recordIDs.allocate())
        let plan = try revisionPlan(for: request, record: nil)
        let ref = try ExternalIdentityRef(
            key: request.key,
            confidence: request.confidence,
            fallbackSchemeVersion: request.fallbackSchemeVersion
        )
        var conflicts = register(key: request.key, ref: ref, record: recordID, detectedAt: request.payload.observedAt)
        recordsByID[recordID] = OriginRecord(
            id: recordID,
            primaryIdentity: ref,
            firstObservedAt: request.payload.observedAt,
            lastObservedAt: request.payload.observedAt
        )
        recordOrder.append(recordID)
        let (outcome, revisionConflicts) = commit(
            plan,
            request: request,
            record: recordID,
            confidence: ref.confidence,
            fallbackSchemeVersion: ref.fallbackSchemeVersion
        )
        conflicts.append(contentsOf: revisionConflicts)
        conflictLog.append(contentsOf: conflicts)
        return .newRecord(
            record: recordID,
            revision: outcome,
            confidence: ref.confidence,
            fallbackSchemeVersion: ref.fallbackSchemeVersion,
            conflicts: conflicts
        )
    }

    /// D12: records `key` as additional evidence for `record`.
    ///
    /// Returns `nil` when the key already belongs to that record. When the key already belongs to a
    /// *different* record in the same scope the mapping is refused, neither record is rewritten and
    /// the returned `ambiguousAlias` conflict is appended to the log. A merge would need a separate,
    /// explicit and reversible decision (D13), never a side effect of resolution.
    @discardableResult
    public mutating func attachAlias(
        _ key: ExternalObjectKey,
        to record: OriginRecordID,
        observedAt: Date
    ) throws -> IdentityConflict? {
        guard recordsByID[record] != nil else { throw IdentityIndexError.unknownRecord(record) }
        if let existing = objectIdentities[key] {
            guard existing.record != record else { return nil }
            let conflict = IdentityConflict(
                kind: .ambiguousAlias,
                scope: .external(key.scope),
                existingRecord: existing.record,
                claimingRecord: record,
                existingSource: nil,
                claimedSource: nil,
                incomingKeyDigest: digestPolicy.digest(of: key),
                storedPayloadDigest: nil,
                incomingPayloadDigest: nil,
                detectedAt: observedAt
            )
            conflictLog.append(conflict)
            return conflict
        }
        let ref = try ExternalIdentityRef(key: key, confidence: .high, fallbackSchemeVersion: nil)
        conflictLog.append(contentsOf: register(key: key, ref: ref, record: record, detectedAt: observedAt))
        return nil
    }

    // MARK: - Resolution internals

    /// D12: the same bytes can never be an alias of two records in one scope.
    private func versionKeyClaimedByAnotherRecord(_ request: IdentityResolutionRequest) -> IdentityConflict? {
        guard let versionKey = request.versionKey,
              let owner = versionIdentities[versionKey]?.record
        else { return nil }
        let claimant = objectIdentities[request.key]?.record
        guard owner != claimant else { return nil }
        return IdentityConflict(
            kind: .ambiguousAlias,
            scope: .external(versionKey.scope),
            existingRecord: owner,
            claimingRecord: claimant,
            existingSource: nil,
            claimedSource: nil,
            incomingKeyDigest: digestPolicy.digest(of: versionKey),
            storedPayloadDigest: nil,
            incomingPayloadDigest: nil,
            detectedAt: request.payload.observedAt
        )
    }

    private mutating func register(
        key: ExternalObjectKey,
        ref: ExternalIdentityRef,
        record: OriginRecordID,
        detectedAt: Date
    ) -> [IdentityConflict] {
        let digest = digestPolicy.digest(of: key)
        let slot = DigestSlot(scope: key.scope, kind: key.keyKind, digest: digest)
        let conflicts = collisionConflicts(
            slot: slot,
            incoming: .object(key),
            incomingKeyDigest: digest,
            recordedFor: record,
            detectedAt: detectedAt
        )
        objectIdentities[key] = ObjectIdentity(ref: ref, digest: digest, record: record)
        digestSlots[slot, default: []].insert(.object(key))
        return conflicts
    }

    /// D8, invariant 9: a shared digest only shows that a full-key comparison is required. The
    /// colliding keys stay distinct identities and the collision is recorded.
    private func collisionConflicts(
        slot: DigestSlot,
        incoming: KeySpaceMember,
        incomingKeyDigest: ExternalKeyDigest,
        recordedFor record: OriginRecordID,
        detectedAt: Date
    ) -> [IdentityConflict] {
        (digestSlots[slot] ?? [])
            .filter { $0 != incoming }
            .sorted { $0.sortKey < $1.sortKey }
            .map { member in
                IdentityConflict(
                    kind: .digestCollision,
                    scope: .external(slot.scope),
                    existingRecord: recordOwning(member),
                    claimingRecord: record,
                    existingSource: nil,
                    claimedSource: nil,
                    incomingKeyDigest: incomingKeyDigest,
                    storedPayloadDigest: nil,
                    incomingPayloadDigest: nil,
                    detectedAt: detectedAt
                )
            }
    }

    private func recordOwning(_ member: KeySpaceMember) -> OriginRecordID? {
        switch member {
        case let .object(key): return objectIdentities[key]?.record
        case let .version(key): return versionIdentities[key]?.record
        }
    }

    /// Decides `(duplicate | divergent | append)` and allocates the revision identifier up front, so
    /// a resolution that cannot allocate changes nothing at all.
    private mutating func revisionPlan(
        for request: IdentityResolutionRequest,
        record: OriginRecordID?
    ) throws -> RevisionPlan {
        let incomingDigest = digestPolicy.digest(of: request.payload)
        if let versionKey = request.versionKey {
            if let stored = versionIdentities[versionKey] {
                guard stored.payloadDigest != incomingDigest else {
                    return .duplicate(stored.revision)
                }
                return .divergentPayload(
                    versionKey: versionKey,
                    stored: stored.revision,
                    storedDigest: stored.payloadDigest,
                    incomingDigest: incomingDigest
                )
            }
            return .append(try OriginRevisionID(revisionIDs.allocate()), versionKey: versionKey, payloadDigest: incomingDigest)
        }
        if let record,
           let duplicate = revisionsByRecord[record]?.first(where: { revisionsByID[$0]?.payloadDigest == incomingDigest }) {
            // D9: a versionless observation is deduplicated by payload digest; a changed payload
            // admits a new revision and never rewrites the previous one.
            return .duplicate(duplicate)
        }
        return .append(try OriginRevisionID(revisionIDs.allocate()), versionKey: nil, payloadDigest: incomingDigest)
    }

    private mutating func commit(
        _ plan: RevisionPlan,
        request: IdentityResolutionRequest,
        record: OriginRecordID,
        confidence: IdentityConfidence,
        fallbackSchemeVersion: Int?
    ) -> (RevisionOutcome, [IdentityConflict]) {
        switch plan {
        case let .duplicate(revision):
            return (.duplicate(revision), [])

        case let .divergentPayload(versionKey, stored, storedDigest, incomingDigest):
            let conflict = IdentityConflict(
                kind: .versionPayloadDivergence,
                scope: .external(versionKey.scope),
                existingRecord: record,
                claimingRecord: record,
                existingSource: nil,
                claimedSource: nil,
                incomingKeyDigest: digestPolicy.digest(of: versionKey),
                storedPayloadDigest: storedDigest,
                incomingPayloadDigest: incomingDigest,
                detectedAt: request.payload.observedAt
            )
            return (.divergentPayloadPreserved(stored: stored), [conflict])

        case let .append(revisionID, versionKey, payloadDigest):
            revisionsByID[revisionID] = OriginRevision(
                id: revisionID,
                record: record,
                versionKey: versionKey,
                payloadDigest: payloadDigest,
                payload: request.payload,
                identityConfidence: confidence,
                fallbackSchemeVersion: fallbackSchemeVersion
            )
            revisionsByRecord[record, default: []].append(revisionID)
            guard let versionKey else { return (.appended(revisionID), []) }

            let digest = digestPolicy.digest(of: versionKey)
            let slot = DigestSlot(scope: versionKey.scope, kind: versionKey.keyKind, digest: digest)
            let conflicts = collisionConflicts(
                slot: slot,
                incoming: .version(versionKey),
                incomingKeyDigest: digest,
                recordedFor: record,
                detectedAt: request.payload.observedAt
            )
            versionIdentities[versionKey] = VersionIdentity(
                record: record,
                revision: revisionID,
                payloadDigest: payloadDigest
            )
            digestSlots[slot, default: []].insert(.version(versionKey))
            return (.appended(revisionID), conflicts)
        }
    }

    private mutating func updateObservation(of record: OriginRecordID, at observedAt: Date) {
        guard let existing = recordsByID[record] else { return }
        recordsByID[record] = OriginRecord(
            id: existing.id,
            primaryIdentity: existing.primaryIdentity,
            firstObservedAt: existing.firstObservedAt,
            lastObservedAt: max(existing.lastObservedAt, observedAt)
        )
    }
}
