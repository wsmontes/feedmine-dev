import Foundation
import GRDB
import FeedDomain

/// Registration and lifecycle of an acquisition target.
///
/// The target is operational work, owned by ADR-005; PR-03 needs it because Admission has nothing
/// to validate against until a target exists, and because revocation and disable/re-enable are
/// expressed as a lease epoch bump that late work fails against (ADR-006 D1, D12).

public enum AcquisitionTargetState: String, Hashable, Sendable, CaseIterable {
    case active
    case disabled
    case revoked
}

public enum AcquisitionTargetError: Error, Equatable, Sendable {
    case alreadyRegistered(AcquisitionTargetID)
    case unknownTarget(AcquisitionTargetID)
    case nonPositiveBindingRevision(UInt64)
    case emptyConnectorKind
}

/// The durable state of one target, checkpoint included: what a caller needs to build a stamp.
public struct AcquisitionTargetSnapshot: Hashable, Sendable {
    public let targetID: AcquisitionTargetID
    public let connectorKind: String
    public let generation: UInt64
    public let bindingRevision: UInt64
    public let leaseEpoch: UInt64
    public let state: AcquisitionTargetState
    public let checkpointRevision: UInt64
    public let checkpoint: ConnectorCheckpoint?
    public let updatedAt: Date

    /// The checkpoint a batch admitted now must carry: the CAS expectation (ADR-006 D5).
    public func stamp() -> TargetStamp {
        TargetStamp(
            targetID: targetID,
            targetGeneration: generation,
            bindingRevision: bindingRevision,
            leaseEpoch: leaseEpoch,
            checkpointRevision: checkpointRevision
        )
    }
}

public struct AcquisitionTargetStore: Sendable {
    private let clock: any EditorialClock

    public init(clock: any EditorialClock = SystemEditorialClock()) {
        self.clock = clock
    }

    /// Registers a target and its checkpoint row in one transaction. A target that already exists is
    /// never silently re-created: identity of operational work is explicit (ADR-006 D1).
    @discardableResult
    public func register(
        _ targetID: AcquisitionTargetID,
        connectorKind: String,
        connectorVersion: String,
        bindingRevision: UInt64 = 1,
        configurationBlob: Data? = nil,
        in database: RuntimeDatabase
    ) throws -> AcquisitionTargetSnapshot {
        guard !connectorKind.isEmpty else { throw AcquisitionTargetError.emptyConnectorKind }
        guard !connectorVersion.isEmpty else {
            throw AdmissionContractError.emptyConnectorVersion
        }
        guard bindingRevision > 0 else {
            throw AcquisitionTargetError.nonPositiveBindingRevision(bindingRevision)
        }
        let now = AdmissionTimestamp.milliseconds(clock.now)
        return try database.write { database in
            let exists = try Bool.fetchOne(
                database,
                sql: "SELECT COUNT(*) > 0 FROM acquisition_target WHERE id = ?",
                arguments: [targetID.rawValue]
            ) ?? false
            guard !exists else { throw AcquisitionTargetError.alreadyRegistered(targetID) }

            try database.execute(sql: """
                INSERT INTO acquisition_target (
                    id, connector_kind, generation, binding_revision, lease_epoch, state, configuration_blob
                ) VALUES (?, ?, 1, ?, 0, 'active', ?)
                """, arguments: [targetID.rawValue, connectorKind, bindingRevision, configurationBlob])
            try database.execute(sql: """
                INSERT INTO connector_checkpoint (
                    target_id, checkpoint_revision, checkpoint_blob, serialization_schema,
                    connector_version, updated_at
                ) VALUES (?, 0, NULL, 1, ?, ?)
                """, arguments: [targetID.rawValue, connectorVersion, now])
            guard let snapshot = try self.snapshot(for: targetID, in: database) else {
                throw AcquisitionTargetError.unknownTarget(targetID)
            }
            return snapshot
        }
    }

    /// Disable, re-enable or revoke. Every change of state bumps the lease epoch, so work produced
    /// under the previous epoch is stale at write admission even though its content is not
    /// (ADR-006 D1, edge cases: "disable/re-enable of a binding or target").
    @discardableResult
    public func setState(
        _ state: AcquisitionTargetState,
        for targetID: AcquisitionTargetID,
        in database: RuntimeDatabase
    ) throws -> AcquisitionTargetSnapshot {
        try database.write { database in
            guard let current = try self.snapshot(for: targetID, in: database) else {
                throw AcquisitionTargetError.unknownTarget(targetID)
            }
            guard current.state != state else { return current }
            try database.execute(sql: """
                UPDATE acquisition_target SET state = ?, lease_epoch = lease_epoch + 1 WHERE id = ?
                """, arguments: [state.rawValue, targetID.rawValue])
            guard let updated = try self.snapshot(for: targetID, in: database) else {
                throw AcquisitionTargetError.unknownTarget(targetID)
            }
            return updated
        }
    }

    /// Reconfigures the binding the target serves. The target and its checkpoint stay; the new
    /// revision makes every batch stamped with an older one stale (ADR-003 D6, plan §19 #4).
    @discardableResult
    public func setBindingRevision(
        _ revision: UInt64,
        for targetID: AcquisitionTargetID,
        in database: RuntimeDatabase
    ) throws -> AcquisitionTargetSnapshot {
        guard revision > 0 else {
            throw AcquisitionTargetError.nonPositiveBindingRevision(revision)
        }
        return try database.write { database in
            try database.execute(sql: """
                UPDATE acquisition_target SET binding_revision = ? WHERE id = ?
                """, arguments: [revision, targetID.rawValue])
            guard database.changesCount > 0, let snapshot = try self.snapshot(for: targetID, in: database) else {
                throw AcquisitionTargetError.unknownTarget(targetID)
            }
            return snapshot
        }
    }

    /// Reads the target and its checkpoint from one snapshot. `nil` when the target is unknown.
    public func snapshot(
        for targetID: AcquisitionTargetID,
        in database: RuntimeDatabase
    ) throws -> AcquisitionTargetSnapshot? {
        try database.read { database in try self.snapshot(for: targetID, in: database) }
    }

    func snapshot(
        for targetID: AcquisitionTargetID,
        in database: Database
    ) throws -> AcquisitionTargetSnapshot? {
        guard let row = try Row.fetchOne(database, sql: """
            SELECT target.connector_kind, target.generation, target.binding_revision, target.lease_epoch,
                   target.state, checkpoint.checkpoint_revision, checkpoint.checkpoint_blob,
                   checkpoint.serialization_schema, checkpoint.connector_version, checkpoint.updated_at
            FROM acquisition_target AS target
            JOIN connector_checkpoint AS checkpoint ON checkpoint.target_id = target.id
            WHERE target.id = ?
            """, arguments: [targetID.rawValue]) else { return nil }

        let stateName: String = row["state"]
        let blob: Data? = row["checkpoint_blob"]
        let schema: Int = row["serialization_schema"]
        let version: String = row["connector_version"]
        let generation: Int64 = row["generation"]
        let bindingRevision: Int64 = row["binding_revision"]
        let leaseEpoch: Int64 = row["lease_epoch"]
        let checkpointRevision: Int64 = row["checkpoint_revision"]
        let updatedAt: Int64 = row["updated_at"]
        return AcquisitionTargetSnapshot(
            targetID: targetID,
            connectorKind: row["connector_kind"],
            generation: UInt64(generation),
            bindingRevision: UInt64(bindingRevision),
            leaseEpoch: UInt64(leaseEpoch),
            state: AcquisitionTargetState(rawValue: stateName) ?? .revoked,
            checkpointRevision: UInt64(checkpointRevision),
            checkpoint: try ConnectorCheckpoint(blob: blob, serializationSchema: schema, connectorVersion: version),
            updatedAt: AdmissionTimestamp.date(milliseconds: updatedAt)
        )
    }
}
