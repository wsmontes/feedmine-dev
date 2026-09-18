import Foundation
import GRDB
import FeedDomain

/// The durable answers a lost response, a restarted process or a resent batch must still find
/// (ADR-006 D2, D9; Blueprint §77).
///
/// None of these reads mutates anything: they exist so that the runtime never has to answer a
/// question about committed state from memory.

/// One row of `admission_batch`, including the fingerprint a retry is compared against.
public struct AdmissionBatchRecord: Hashable, Sendable {
    public let batchID: String
    public let targetID: AcquisitionTargetID
    public let targetGeneration: UInt64
    public let bindingRevision: UInt64
    public let leaseEpoch: UInt64
    public let fingerprint: String
    public let checkpointExpected: UInt64
    public let checkpointWritten: UInt64?
    public let observationCount: Int
    public let result: String
    public let committedAt: Date
}

/// One stored piece of connector evidence. The raw kind is returned as stored: an unknown kind is
/// still evidence, and dropping it would hide the fact that it exists.
public struct ConnectorEvidenceRecord: Hashable, Sendable {
    public let kind: String
    public let digest: String
    public let bytes: Data?
}

public struct AdmissionLedger: Sendable {
    public init() {}

    /// The receipt of an admitted batch, decoded from durable state.
    ///
    /// This is the recovery path ADR-006 D2 requires: a batch whose commit succeeded but whose
    /// response was lost is answered from here, without mutating supply again.
    public func receipt(forBatchID batchID: String, in database: RuntimeDatabase) throws -> AdmissionReceipt? {
        let blob = try database.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT receipt_blob FROM admission_batch WHERE batch_id = ?",
                arguments: [batchID]
            )
        }
        guard let blob else { return nil }
        return try JSONDecoder().decode(AdmissionReceipt.self, from: blob)
    }

    public func batch(_ batchID: String, in database: RuntimeDatabase) throws -> AdmissionBatchRecord? {
        try database.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                       checkpoint_expected, checkpoint_written, observation_count, result, committed_at
                FROM admission_batch WHERE batch_id = ?
                """, arguments: [batchID]) else { return nil }
            let written: Int64? = row["checkpoint_written"]
            let targetGeneration: Int64 = row["target_generation"]
            let bindingRevision: Int64 = row["binding_revision"]
            let leaseEpoch: Int64 = row["lease_epoch"]
            let checkpointExpected: Int64 = row["checkpoint_expected"]
            let committedAt: Int64 = row["committed_at"]
            return AdmissionBatchRecord(
                batchID: row["batch_id"],
                targetID: AcquisitionTargetID(row["target_id"]),
                targetGeneration: UInt64(targetGeneration),
                bindingRevision: UInt64(bindingRevision),
                leaseEpoch: UInt64(leaseEpoch),
                fingerprint: row["fingerprint"],
                checkpointExpected: UInt64(checkpointExpected),
                checkpointWritten: written.map(UInt64.init),
                observationCount: row["observation_count"],
                result: row["result"],
                committedAt: AdmissionTimestamp.date(milliseconds: committedAt)
            )
        }
    }

    public func evidence(
        forBatchID batchID: String,
        in database: RuntimeDatabase
    ) throws -> [ConnectorEvidenceRecord] {
        try database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT kind, digest, bytes FROM connector_evidence WHERE batch_id = ? ORDER BY id
                """, arguments: [batchID]).map { row in
                ConnectorEvidenceRecord(kind: row["kind"], digest: row["digest"], bytes: row["bytes"])
            }
        }
    }

    /// The monotone counter selection reads beside the candidate pool, from one snapshot.
    public func supplyGeneration(in database: RuntimeDatabase) throws -> UInt64 {
        try database.read { database in
            try UInt64.fetchOne(database, sql: "SELECT value FROM supply_generation WHERE id = 1") ?? 0
        }
    }

    /// The revision selection would hold today. The identifier is converted through the checked
    /// initializer, so a corrupted row surfaces instead of becoming a wrapped number (ADR-003 D3).
    public func currentRevisionID(
        ofRecord recordID: OriginRecordID,
        in database: RuntimeDatabase
    ) throws -> OriginRevisionID? {
        let raw = try database.read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT current_revision_id FROM origin_record WHERE id = ?",
                arguments: [recordID.rawValue]
            )
        }
        guard let raw else { return nil }
        return try OriginRevisionID(raw)
    }

    /// The record ids in allocation order. Used by tests and diagnostics; Selection reads through
    /// its own repository (PR-05).
    public func recordIDs(in database: RuntimeDatabase) throws -> [OriginRecordID] {
        try database.read { database in
            try Int64.fetchAll(database, sql: "SELECT id FROM origin_record ORDER BY id")
                .map { try OriginRecordID($0) }
        }
    }

    public func revisionCount(ofRecord recordID: OriginRecordID, in database: RuntimeDatabase) throws -> Int {
        try database.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM origin_revision WHERE origin_record_id = ?",
                arguments: [recordID.rawValue]
            ) ?? 0
        }
    }

    /// The search projection of a record, as the index holds it. Empty when nothing is current.
    public func searchProjection(ofRecord recordID: OriginRecordID, in database: RuntimeDatabase) throws -> String? {
        try database.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT projection FROM origin_search WHERE rowid = ?",
                arguments: [recordID.rawValue]
            )
        }
    }
}

extension AdmissionTimestamp {
    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
