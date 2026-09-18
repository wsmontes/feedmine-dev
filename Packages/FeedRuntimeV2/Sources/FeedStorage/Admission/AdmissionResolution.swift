import Foundation
import GRDB
import FeedDomain

/// What one observation means for identity, resolved read-only before the transaction mutates
/// anything (ADR-003 D8–D12, D16; ADR-006 step 4).
///
/// Resolution answers two questions and returns both, because a refusal must be able to name what
/// it refused: which `origin_record` (if any) the full object key belongs to, and whether the
/// representation is new, already stored, or a divergence that must be audited instead of applied.

/// The record an observation resolves to, without creating anything.
enum RecordResolution: Equatable {
    /// No `external_identity` row exists for the full object key: the identity row, the record and
    /// the backfill are created inside the admitting transaction.
    case newRecord
    /// The identity row exists but never got its record (the bootstrap of ADR-003's schema note).
    case bootstrapRecord(identityID: Int64)
    case existing(recordID: Int64, identityID: Int64)

    var recordID: Int64? {
        if case let .existing(recordID, _) = self { return recordID }
        return nil
    }

    var identityID: Int64? {
        switch self {
        case .newRecord: return nil
        case let .bootstrapRecord(identityID): return identityID
        case let .existing(_, identityID): return identityID
        }
    }
}

/// What happens to the representation.
enum RevisionResolution: Equatable {
    /// Nothing with this version key (or, for a versionless observation, this payload) is stored.
    case append
    /// The identical representation is already stored: no new revision, no supply change.
    case duplicate(revisionID: Int64)
    /// The same version key already carries a divergent payload. Recorded, never overwritten.
    case divergent(storedRevisionID: Int64, storedDigest: Data)
}

/// An audited contradiction, ready to be written to `identity_conflict` (ADR-003 D11, D12).
struct IdentityConflictRecord: Equatable {
    enum Kind: String, Equatable {
        case versionPayloadDivergence = "version_payload_divergence"
        case ambiguousAlias = "ambiguous_alias"
    }

    let kind: Kind
    /// The incoming object key: what the caller is told conflicted.
    let key: ExternalObjectKey
    /// The scope the conflicting key lives in (a version key's scope, or the object key's).
    let scope: ExternalScopeKey
    let existingRecordID: Int64?
    let existingIdentityID: Int64?
    let incomingKeyBytes: Data
    let incomingKeyDigest: Data
    let storedPayloadDigest: Data?
    let incomingPayloadDigest: Data?
}

struct ObservationResolution {
    let index: Int
    let observation: AcquisitionObservation
    let payloadDigest: Data
    let keyDigest: Data
    let versionDigest: Data?
    let record: RecordResolution
    let revision: RevisionResolution
    let conflict: IdentityConflictRecord?
}

/// One row of `external_identity`, as identity resolution sees it.
struct StoredIdentity {
    let id: Int64
    let recordID: Int64?
    let confidence: IdentityConfidence
    let fallbackSchemeVersion: Int64?
}

extension AdmissionEngine {
    /// Resolves every observation of the batch without writing. Divergences and ambiguous aliases
    /// are returned, not applied: the caller audits them and mutates nothing (ADR-006 D12).
    func resolve(_ batch: AcquisitionBatch, in database: Database) throws -> [ObservationResolution] {
        var resolutions: [ObservationResolution] = []
        var seenRepresentations: [String: (payloadDigest: Data, index: Int)] = [:]

        for (index, observation) in batch.observations.enumerated() {
            let payloadDigest = digestPolicy.digest(of: observation.payload).bytes
            let keyDigest = digestPolicy.digest(of: observation.externalKey).bytes
            let stored = try objectIdentity(observation.externalKey, in: database)
            let record: RecordResolution
            switch stored {
            case .none:
                record = .newRecord
            case let .some(identity):
                if let recordID = identity.recordID {
                    record = .existing(recordID: recordID, identityID: identity.id)
                } else {
                    record = .bootstrapRecord(identityID: identity.id)
                }
            }

            var versionDigest: Data?
            var revision: RevisionResolution = .append
            var conflict: IdentityConflictRecord?

            if let versionKey = observation.versionKey {
                let digest = digestPolicy.digest(of: versionKey).bytes
                versionDigest = digest

                let storedVersionIdentity = try versionIdentity(versionKey, in: database)
                if let storedVersionIdentity,
                   let storedRecord = storedVersionIdentity.recordID,
                   record.recordID != storedRecord {
                    // One version key claimed by two records — including the case where the claim
                    // comes from a record the runtime has not created yet. Neither record moves and
                    // no merge happens (D12).
                    conflict = IdentityConflictRecord(
                        kind: .ambiguousAlias,
                        key: observation.externalKey,
                        scope: versionKey.scope,
                        existingRecordID: storedRecord,
                        existingIdentityID: storedVersionIdentity.id,
                        incomingKeyBytes: versionKey.bytes,
                        incomingKeyDigest: digest,
                        storedPayloadDigest: nil,
                        incomingPayloadDigest: payloadDigest
                    )
                } else if let recordID = record.recordID,
                          let storedRepresentation = try storedRevision(
                              recordID: recordID,
                              versionKey: versionKey,
                              in: database
                          ) {
                    if storedRepresentation.payloadDigest == payloadDigest {
                        revision = .duplicate(revisionID: storedRepresentation.id)
                    } else {
                        revision = .divergent(
                            storedRevisionID: storedRepresentation.id,
                            storedDigest: storedRepresentation.payloadDigest
                        )
                        conflict = IdentityConflictRecord(
                            kind: .versionPayloadDivergence,
                            key: observation.externalKey,
                            scope: versionKey.scope,
                            existingRecordID: recordID,
                            existingIdentityID: storedVersionIdentity?.id ?? record.identityID,
                            incomingKeyBytes: versionKey.bytes,
                            incomingKeyDigest: digest,
                            storedPayloadDigest: storedRepresentation.payloadDigest,
                            incomingPayloadDigest: payloadDigest
                        )
                    }
                }

                let representationKey = Self.representationKey(
                    objectKey: observation.externalKey,
                    versionBytes: versionKey.bytes
                )
                if let seen = seenRepresentations[representationKey] {
                    if seen.payloadDigest != payloadDigest, conflict == nil {
                        conflict = IdentityConflictRecord(
                            kind: .versionPayloadDivergence,
                            key: observation.externalKey,
                            scope: versionKey.scope,
                            existingRecordID: record.recordID,
                            existingIdentityID: record.identityID,
                            incomingKeyBytes: versionKey.bytes,
                            incomingKeyDigest: digest,
                            storedPayloadDigest: seen.payloadDigest,
                            incomingPayloadDigest: payloadDigest
                        )
                    }
                } else if conflict == nil {
                    seenRepresentations[representationKey] = (payloadDigest, index)
                }
            } else if let recordID = record.recordID,
                      let duplicateID = try revisionID(
                          recordID: recordID,
                          payloadDigest: payloadDigest,
                          in: database
                      ) {
                // A versionless representation is deduplicated on its payload: the same content
                // observed again is not a new revision (ADR-003 D16, invariant 14).
                revision = .duplicate(revisionID: duplicateID)
            }

            resolutions.append(
                ObservationResolution(
                    index: index,
                    observation: observation,
                    payloadDigest: payloadDigest,
                    keyDigest: keyDigest,
                    versionDigest: versionDigest,
                    record: record,
                    revision: revision,
                    conflict: conflict
                )
            )
        }
        return resolutions
    }

    /// The stable key of one representation for in-batch comparisons: the full object key plus the
    /// full version key bytes. It is never stored; identity is decided by the SQL uniqueness rule.
    static func representationKey(objectKey: ExternalObjectKey, versionBytes: Data) -> String {
        "\(objectKey.scope.namespace.rawValue)|\(objectKey.scope.scopeKey)|"
            + "\(objectKey.bytes.base64EncodedString())|\(versionBytes.base64EncodedString())"
    }

    func objectIdentity(_ key: ExternalObjectKey, in database: Database) throws -> StoredIdentity? {
        try identity(
            database,
            sql: """
                SELECT id, origin_record_id, identity_confidence, fallback_scheme_version
                FROM external_identity
                WHERE connector_namespace = ? AND scope_key = ? AND key_kind = 'object' AND external_key = ?
                """,
            arguments: [key.scope.namespace.rawValue, key.scope.scopeKey, key.bytes]
        )
    }

    func versionIdentity(_ key: ExternalVersionKey, in database: Database) throws -> StoredIdentity? {
        try identity(
            database,
            sql: """
                SELECT id, origin_record_id, identity_confidence, fallback_scheme_version
                FROM external_identity
                WHERE connector_namespace = ? AND scope_key = ? AND key_kind = 'version' AND external_key = ?
                """,
            arguments: [key.scope.namespace.rawValue, key.scope.scopeKey, key.bytes]
        )
    }

    private func identity(
        _ database: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> StoredIdentity? {
        guard let row = try Row.fetchOne(database, sql: sql, arguments: arguments) else { return nil }
        let recordID: Int64? = row["origin_record_id"]
        let confidenceName: String = row["identity_confidence"]
        let fallback: Int64? = row["fallback_scheme_version"]
        return StoredIdentity(
            id: row["id"],
            recordID: recordID,
            confidence: IdentityConfidence(rawValue: confidenceName) ?? .high,
            fallbackSchemeVersion: fallback
        )
    }

    /// The single revision that carries this version key for the record. At most one can exist: a
    /// divergent payload under the same key is refused instead of appended (ADR-003 D11).
    func storedRevision(
        recordID: Int64,
        versionKey: ExternalVersionKey,
        in database: Database
    ) throws -> (id: Int64, payloadDigest: Data)? {
        guard let row = try Row.fetchOne(database, sql: """
            SELECT id, payload_digest FROM origin_revision
            WHERE origin_record_id = ? AND external_version_key = ?
            ORDER BY id LIMIT 1
            """, arguments: [recordID, versionKey.bytes]) else { return nil }
        return (row["id"], row["payload_digest"])
    }

    func revisionID(recordID: Int64, payloadDigest: Data, in database: Database) throws -> Int64? {
        try Int64.fetchOne(database, sql: """
            SELECT id FROM origin_revision
            WHERE origin_record_id = ? AND payload_digest = ?
            ORDER BY id LIMIT 1
            """, arguments: [recordID, payloadDigest])
    }

    func currentRevisionID(recordID: Int64, in database: Database) throws -> Int64? {
        try Int64.fetchOne(
            database,
            sql: "SELECT current_revision_id FROM origin_record WHERE id = ?",
            arguments: [recordID]
        )
    }
}
