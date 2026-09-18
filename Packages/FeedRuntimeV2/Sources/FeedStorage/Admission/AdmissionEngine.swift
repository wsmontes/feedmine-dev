import Foundation
import GRDB
import FeedDomain

/// Transactional Admission (plan §7, ADR-006).
///
/// One batch becomes canonical state in exactly one write transaction, in the order ADR-006 fixes:
/// validate the target stamp, validate the batch identity and the expected checkpoint, resolve
/// external identities by their full key, append unseen revisions, move the current pointer by
/// compare-and-swap, apply the claims, refresh the projection, persist the receipt and the new
/// checkpoint, and only then advance the supply generation.
///
/// The body is synchronous by construction (ADR-006 D8): no `await`, no HTTP, no parser, no decoder
/// and no callback runs inside the transaction, and the only clock read happens before it starts.
public struct AdmissionEngine: Sendable {
    /// Internal, not private: the transaction steps live in the same module but not in the same
    /// file, and one file per concept keeps this type readable.
    let digestPolicy: any IdentityDigestPolicy
    let clock: any EditorialClock

    /// Where this engine records what it measured (plan §16). `nil` in a composition with no
    /// diagnostics: instrumentation must not be a reason a call site cannot be built.
    let metrics: RuntimeMetricsRecorder?

    public init(
        digestPolicy: any IdentityDigestPolicy = StandardIdentityDigest(),
        clock: any EditorialClock = SystemEditorialClock(),
        metrics: RuntimeMetricsRecorder? = nil
    ) {
        self.digestPolicy = digestPolicy
        self.clock = clock
        self.metrics = metrics
    }

    /// Admits one batch, or reports why it refused to.
    ///
    /// A refusal never returns a partial result: every rejection happens before the first canonical
    /// mutation, and any error thrown inside the transaction rolls the whole body back, so the
    /// caller sees either the committed effect or the pre-transaction state (ADR-006 D1, D5, D13).
    public func admit(_ batch: AcquisitionBatch, in database: RuntimeDatabase) -> AdmissionResult {
        let started = ProcessInfo.processInfo.systemUptime
        // Read the clock outside the transaction: the write body performs no external call (D8).
        let committedAt = clock.now
        let result: AdmissionResult
        do {
            result = try database.write { database in
                try self.apply(batch, in: database, committedAt: committedAt)
            }
        } catch let stale as AdmissionCheckpointStale {
            result = .staleCheckpoint(expected: stale.expected, actual: stale.actual)
        } catch {
            result = .storageFailure(reason: "\(error)")
        }
        if let metrics {
            let elapsed = Double(ProcessInfo.processInfo.systemUptime - started) * 1_000
            let outcome = Self.outcome(of: result)
            let epoch = batch.generation
            Task {
                await metrics.record(
                    OperationSample(
                        operation: .admission,
                        operationID: batch.batchID,
                        editionID: nil,
                        epoch: Int64(epoch),
                        durationMilliseconds: elapsed,
                        outcome: outcome
                    )
                )
                if let event = Self.counter(for: result) {
                    await metrics.count(event)
                }
            }
        }
        return result
    }

    /// The verdict as a kind name: the sample records which answer the batch received, never its body.
    static func outcome(of result: AdmissionResult) -> String {
        switch result {
        case .admitted: return "admitted"
        case .duplicate: return "duplicate"
        case .batchConflict: return "batchConflict"
        case .staleTarget: return "staleTarget"
        case .staleCheckpoint: return "staleCheckpoint"
        case .identityConflict: return "identityConflict"
        case .invalidObservation: return "invalidObservation"
        case .storageFailure: return "storageFailure"
        }
    }

    /// §16's counter for the verdict, or `nil` when the verdict is the ordinary one. A replay is the
    /// no-op batch; a target/checkpoint refusal is a stale rejection; everything else is an audited
    /// refusal.
    static func counter(for result: AdmissionResult) -> RuntimeCounterEvent? {
        switch result {
        case .admitted: return nil
        case .duplicate: return .noOpBatch
        case .staleTarget, .staleCheckpoint: return .staleRejection
        case .batchConflict, .identityConflict, .invalidObservation, .storageFailure:
            return .admissionRefusal
        }
    }

    // MARK: - The transaction body

    /// The transaction body. `stopAfterStep` exists for one purpose: proving ADR-006's per-step
    /// crash table (a throw after step *n* must leave the database at its pre-transaction state).
    func apply(
        _ batch: AcquisitionBatch,
        in database: Database,
        committedAt: Date,
        stopAfterStep: Int? = nil
    ) throws -> AdmissionResult {
        if let invalid = validateShape(batch) { return .invalidObservation(reason: invalid) }
        let fingerprint = BatchFingerprint.of(batch)
        let stamp = batch.stamp

        // Step 1: the durable target row is the only authority on whether this work is still valid.
        guard let targetRow = try Row.fetchOne(database, sql: """
            SELECT state, generation, binding_revision, lease_epoch
            FROM acquisition_target WHERE id = ?
            """, arguments: [batch.targetID.rawValue]) else {
            return .staleTarget(generation: 0)
        }
        let targetState: String = targetRow["state"]
        let targetGeneration: Int64 = targetRow["generation"]
        let bindingRevision: Int64 = targetRow["binding_revision"]
        let leaseEpoch: Int64 = targetRow["lease_epoch"]
        // D1: the row must exist and must not be revoked. Disablement is not a refusal by itself —
        // it bumps the lease epoch, so work produced under the previous epoch fails the stamp below.
        guard targetState != "revoked",
              UInt64(targetGeneration) == stamp.targetGeneration,
              UInt64(bindingRevision) == stamp.bindingRevision,
              UInt64(leaseEpoch) == stamp.leaseEpoch
        else {
            return .staleTarget(generation: UInt64(targetGeneration))
        }
        try reached(1, stopAfterStep)

        // Step 2: read the durable checkpoint revision (the CAS expectation).
        let checkpointRevision = try Int64.fetchOne(database, sql: """
            SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = ?
            """, arguments: [batch.targetID.rawValue])
        try reached(2, stopAfterStep)

        // Step 3: batch identity first, then the checkpoint expectation.
        //
        // The order is load-bearing. A resend of a committed batch necessarily carries the
        // checkpoint revision it was produced against, which is behind by the very commit it is
        // asking about; the durable receipt decides that case, so a replay must be recognised before
        // the expectation is judged (ADR-006 D2). `staleCheckpoint` is what a batch degrades to when
        // its receipt is gone — evicted — while the checkpoint has already moved past it.
        if let stored = try String.fetchOne(database, sql: """
            SELECT fingerprint FROM admission_batch WHERE batch_id = ?
            """, arguments: [batch.batchID]) {
            return stored == fingerprint ? .duplicate(batchID: batch.batchID) : .batchConflict(batchID: batch.batchID)
        }
        guard let checkpointRevision, UInt64(checkpointRevision) == stamp.checkpointRevision else {
            return .staleCheckpoint(
                expected: stamp.checkpointRevision,
                actual: UInt64(checkpointRevision ?? 0)
            )
        }
        try reached(3, stopAfterStep)
        if let unknownSource = try firstUnknownMembershipSource(batch, in: database) {
            return .invalidObservation(reason: "observation \(unknownSource.index) claims a membership of unknown source \(unknownSource.sourceID)")
        }

        // Step 3b: identity resolution is read-only, so a divergence or an ambiguous alias can be
        // audited without mutating anything (ADR-003 D11, D12; ADR-006 D12).
        let resolutions = try resolve(batch, in: database)
        let conflicts = resolutions.compactMap(\.conflict)
        if !conflicts.isEmpty {
            for conflict in conflicts {
                try record(conflict, in: database, detectedAt: committedAt)
            }
            try reached(3, stopAfterStep)
            guard let first = resolutions.compactMap({ $0.conflict?.key }).first else {
                throw AdmissionInvariantViolation(detail: "conflict without a key")
            }
            return .identityConflict(first)
        }
        try reached(4, stopAfterStep)

        // Step 5: identity rows, records and unseen revisions.
        var revisions = RevisionBookkeeping()
        for resolution in resolutions {
            try appendIdentityAndRevision(
                resolution,
                in: database,
                committedAt: committedAt,
                bookkeeping: &revisions
            )
        }
        try reached(5, stopAfterStep)

        // Step 6: the current pointer moves only by compare-and-swap against the expected revision.
        var movedRecords: Set<Int64> = []
        for resolution in resolutions {
            guard case let .makeCurrent(expectedRevision) = resolution.observation.precedence,
                  let recordID = revisions.recordIDs[resolution.index],
                  let revisionID = revisions.revisionIDs[resolution.index]
            else { continue }
            let previousRevisionID = try currentRevisionID(recordID: recordID, in: database)
            try database.execute(sql: """
                UPDATE origin_record SET current_revision_id = ?
                WHERE id = ? AND current_revision_id IS ?
                """, arguments: [revisionID, recordID, expectedRevision.map(\.rawValue)])
            // Only a pointer that actually moved changes selectable supply (ADR-006 D6): a CAS that
            // rewrites the revision that is already current is not a supply event.
            if database.changesCount == 1, previousRevisionID != revisionID {
                movedRecords.insert(recordID)
            }
        }
        try reached(6, stopAfterStep)

        // Step 7: memberships, attributions, relations, media candidates and offers.
        var claims = ClaimBookkeeping()
        for resolution in resolutions {
            guard let recordID = revisions.recordIDs[resolution.index] else { continue }
            let revisionID = revisions.revisionIDs[resolution.index]
            try applyClaims(
                resolution,
                targetID: batch.targetID,
                recordID: recordID,
                revisionID: revisionID,
                in: database,
                committedAt: committedAt,
                bookkeeping: &claims
            )
        }
        try reached(7, stopAfterStep)

        // Step 8: the projection is written in the same transaction as the canonical state.
        var affectedRecords = movedRecords
        affectedRecords.formUnion(claims.selectabilityChangingRecords)
        for recordID in affectedRecords.sorted() {
            try refreshSupply(recordID: recordID, in: database)
        }
        try reached(8, stopAfterStep)

        let supplyChanged = !movedRecords.isEmpty
            || claims.newMembershipCount > 0
            || claims.newRelationCount > 0

        // Step 9: the receipt is durable before the checkpoint moves, so a retry after a lost
        // response is answerable from `admission_batch` alone (ADR-006 D2).
        let supplyGenerationBefore = try UInt64.fetchOne(database, sql: "SELECT value FROM supply_generation WHERE id = 1") ?? 0
        let supplyGenerationAfter = supplyGenerationBefore + (supplyChanged ? 1 : 0)
        let checkpointAfter = batch.nextCheckpoint == nil
            ? stamp.checkpointRevision
            : stamp.checkpointRevision + 1
        let receipt = AdmissionReceipt(
            batchID: batch.batchID,
            admittedRevisionCount: revisions.appendedRevisionCount,
            supplyGeneration: supplyGenerationAfter,
            checkpointRevision: checkpointAfter,
            supplyChanged: supplyChanged
        )
        try persist(receipt, batch: batch, fingerprint: fingerprint, committedAt: committedAt, in: database)
        try reached(9, stopAfterStep)

        // Step 10: the checkpoint advances by CAS, in the transaction that admitted the content it
        // represents (I-11). A failed CAS rolls the whole transaction back (D5).
        if let nextCheckpoint = batch.nextCheckpoint {
            try database.execute(sql: """
                UPDATE connector_checkpoint
                SET checkpoint_revision = checkpoint_revision + 1,
                    checkpoint_blob = ?,
                    serialization_schema = ?,
                    connector_version = ?,
                    updated_at = ?
                WHERE target_id = ? AND checkpoint_revision = ?
                """, arguments: [
                nextCheckpoint.blob,
                nextCheckpoint.serializationSchema,
                nextCheckpoint.connectorVersion,
                AdmissionTimestamp.milliseconds(committedAt),
                batch.targetID.rawValue,
                stamp.checkpointRevision,
            ])
            guard database.changesCount == 1 else {
                let actual = try Int64.fetchOne(database, sql: """
                    SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = ?
                    """, arguments: [batch.targetID.rawValue]) ?? 0
                throw AdmissionCheckpointStale(expected: stamp.checkpointRevision, actual: UInt64(actual))
            }
            try database.execute(sql: """
                UPDATE acquisition_target SET last_success_at = ? WHERE id = ?
                """, arguments: [AdmissionTimestamp.milliseconds(committedAt), batch.targetID.rawValue])
        }
        try reached(10, stopAfterStep)

        // Step 11: supply generation moves at most once, and only for selectable supply that changed.
        if supplyChanged {
            try database.execute(sql: "UPDATE supply_generation SET value = value + 1 WHERE id = 1")
            let stored = try UInt64.fetchOne(database, sql: "SELECT value FROM supply_generation WHERE id = 1") ?? 0
            guard stored == supplyGenerationAfter else {
                throw AdmissionInvariantViolation(detail: "supply generation drifted: \(stored) != \(supplyGenerationAfter)")
            }
        }
        try reached(11, stopAfterStep)

        return .admitted(receipt)
    }

    private func reached(_ step: Int, _ stopAfterStep: Int?) throws {
        if let stopAfterStep, step >= stopAfterStep {
            throw AdmissionTransactionProbe(stoppedAfterStep: step)
        }
    }
}

// MARK: - Errors thrown inside the transaction

/// The checkpoint compare-and-swap matched no row. The transaction rolls back and the caller is told
/// the durable revision so it can re-read before retrying (ADR-006 D5, D12).
struct AdmissionCheckpointStale: Error, Equatable {
    let expected: UInt64
    let actual: UInt64
}

/// Injected failure used to prove ADR-006's per-step crash table.
struct AdmissionTransactionProbe: Error, Equatable {
    let stoppedAfterStep: Int
}

/// A state that must be unreachable: an invariant checked inside the transaction disagreed with the
/// transaction's own computation.
struct AdmissionInvariantViolation: Error, Equatable {
    let detail: String
}

enum AdmissionTimestamp {
    /// Every timestamp the runtime owns is stored as epoch milliseconds, so a re-read is exact and
    /// comparisons never depend on a floating-point round trip.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - Transaction steps

/// The revisions one batch produced, plus the identity rows it created for its own later
/// observations. A batch may legitimately carry two versions of one object, so the second
/// observation must reuse the record the first one created instead of inserting a second one.
struct RevisionBookkeeping {
    var recordIDs: [Int: Int64] = [:]
    var revisionIDs: [Int: Int64] = [:]
    var appendedRevisionCount = 0
    /// Object key → the record the batch already created for it.
    var createdObjectIdentities: [String: (recordID: Int64, identityID: Int64)] = [:]
    /// Representation key → the revision the batch already appended for it.
    var stagedRepresentations: [String: Int64] = [:]
}

/// What the claims of one batch changed that selection can observe (ADR-006 D6).
struct ClaimBookkeeping {
    var newMembershipCount = 0
    var newRelationCount = 0
    var selectabilityChangingRecords: Set<Int64> = []
}

/// The audited detail of an identity conflict, stored as JSON beside the comparison inputs.
struct ConflictDetail: Codable {
    let versionKey: String
    let storedPayloadDigest: String?
    let incomingPayloadDigest: String?
}

extension AdmissionEngine {
    /// Pure shape validation: a batch whose own form is wrong is refused before the first read.
    func validateShape(_ batch: AcquisitionBatch) -> String? {
        if batch.batchID.isEmpty { return "batch id is empty" }
        for (index, observation) in batch.observations.enumerated() {
            guard observation.declaredIdentity != nil else {
                return "observation \(index) declares a low-confidence identity without a fallback scheme version"
            }
            if let versionKey = observation.versionKey, versionKey.scope != observation.externalKey.scope {
                return "observation \(index) carries a version key from a scope other than its object key"
            }
        }
        return nil
    }

    /// A membership can only claim a source the runtime owns. The check is read-only and happens
    /// before any mutation, so an unknown source is a refusal and never a foreign-key failure.
    func firstUnknownMembershipSource(
        _ batch: AcquisitionBatch,
        in database: Database
    ) throws -> (index: Int, sourceID: UInt64)? {
        var known: [UInt64: Bool] = [:]
        for (index, observation) in batch.observations.enumerated() {
            for membership in observation.memberships {
                let exists: Bool
                if let cached = known[membership.sourceID.rawValue] {
                    exists = cached
                } else {
                    exists = try Bool.fetchOne(database, sql: """
                        SELECT COUNT(*) > 0 FROM source WHERE id = ?
                        """, arguments: [membership.sourceID.rawValue]) ?? false
                    known[membership.sourceID.rawValue] = exists
                }
                if !exists { return (index, membership.sourceID.rawValue) }
            }
        }
        return nil
    }

    /// Records a contradiction as durable audit evidence. Nothing is resolved, overwritten or
    /// merged here: ADR-003 owns resolution, and a later decision reads this row (D11, D12).
    func record(_ conflict: IdentityConflictRecord, in database: Database, detectedAt: Date) throws {
        let detail = ConflictDetail(
            versionKey: conflict.incomingKeyBytes.base64EncodedString(),
            storedPayloadDigest: conflict.storedPayloadDigest?.base64EncodedString(),
            incomingPayloadDigest: conflict.incomingPayloadDigest?.base64EncodedString()
        )
        let detailJSON = String(data: try JSONEncoder().encode(detail), encoding: .utf8) ?? "{}"
        try database.execute(sql: """
            INSERT INTO identity_conflict (
                connector_namespace, scope_key, conflict_kind, existing_origin_record_id,
                existing_identity_id, incoming_external_key, incoming_key_digest, detail_json, detected_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
            conflict.scope.namespace.rawValue,
            conflict.scope.scopeKey,
            conflict.kind.rawValue,
            conflict.existingRecordID,
            conflict.existingIdentityID,
            conflict.incomingKeyBytes,
            conflict.incomingKeyDigest,
            detailJSON,
            AdmissionTimestamp.milliseconds(detectedAt),
        ])
    }

    /// Step 5: create the identity rows and the record the observation resolved to, then append the
    /// representation when it is genuinely new (ADR-003 D3, D8, D11).
    func appendIdentityAndRevision(
        _ resolution: ObservationResolution,
        in database: Database,
        committedAt: Date,
        bookkeeping: inout RevisionBookkeeping
    ) throws {
        let observation = resolution.observation
        let observedAt = AdmissionTimestamp.milliseconds(observation.payload.observedAt)
        let objectKeyID = Self.objectKeyIdentity(observation.externalKey)

        let recordID: Int64
        let identityID: Int64
        if let created = bookkeeping.createdObjectIdentities[objectKeyID] {
            recordID = created.recordID
            identityID = created.identityID
            try touchIdentityAndRecord(identityID: identityID, recordID: recordID, at: observedAt, in: database)
        } else {
            switch resolution.record {
            case .newRecord:
                identityID = try insertObjectIdentity(resolution, in: database, at: observedAt)
                recordID = try insertRecord(resolution, identityID: identityID, in: database, at: observedAt)
                try backfill(identityID: identityID, recordID: recordID, in: database)
            case let .bootstrapRecord(existingIdentityID):
                identityID = existingIdentityID
                recordID = try insertRecord(resolution, identityID: identityID, in: database, at: observedAt)
                try backfill(identityID: identityID, recordID: recordID, in: database)
            case let .existing(existingRecordID, existingIdentityID):
                recordID = existingRecordID
                identityID = existingIdentityID
                try touchIdentityAndRecord(
                    identityID: identityID,
                    recordID: recordID,
                    at: observedAt,
                    in: database
                )
            }
            bookkeeping.createdObjectIdentities[objectKeyID] = (recordID, identityID)
        }
        bookkeeping.recordIDs[resolution.index] = recordID

        if let versionKey = observation.versionKey, let versionDigest = resolution.versionDigest {
            if let existing = try versionIdentity(versionKey, in: database) {
                try database.execute(sql: """
                    UPDATE external_identity SET last_observed_at = MAX(last_observed_at, ?) WHERE id = ?
                    """, arguments: [observedAt, existing.id])
            } else {
                try database.execute(sql: """
                    INSERT INTO external_identity (
                        connector_namespace, scope_key, key_kind, external_key, key_digest, origin_record_id,
                        identity_confidence, fallback_scheme_version, first_observed_at, last_observed_at
                    ) VALUES (?, ?, 'version', ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    versionKey.scope.namespace.rawValue,
                    versionKey.scope.scopeKey,
                    versionKey.bytes,
                    versionDigest,
                    recordID,
                    observation.identityConfidence.rawValue,
                    observation.fallbackSchemeVersion,
                    observedAt,
                    observedAt,
                ])
            }
        }

        switch resolution.revision {
        case let .duplicate(revisionID):
            bookkeeping.revisionIDs[resolution.index] = revisionID
        case let .divergent(storedRevisionID, _):
            // Resolution refuses the batch before any write; kept total for exhaustiveness.
            bookkeeping.revisionIDs[resolution.index] = storedRevisionID
        case .append:
            if case .duplicate = observation.precedence {
                // The connector states this representation is already known: record nothing new and
                // move nothing (ADR-006 D3).
                bookkeeping.revisionIDs[resolution.index] = try currentRevisionID(
                    recordID: recordID,
                    in: database
                )
                return
            }
            let representationKey = Self.representationKey(
                objectKey: observation.externalKey,
                versionBytes: observation.versionKey?.bytes ?? Data()
            )
            if let staged = bookkeeping.stagedRepresentations[representationKey] {
                bookkeeping.revisionIDs[resolution.index] = staged
                return
            }
            let revisionID = try insertRevision(
                resolution,
                recordID: recordID,
                in: database,
                at: committedAt
            )
            bookkeeping.stagedRepresentations[representationKey] = revisionID
            bookkeeping.revisionIDs[resolution.index] = revisionID
            bookkeeping.appendedRevisionCount += 1
        }
    }

    /// Step 7: memberships, provider attributions, promoted relations, media candidates and offers.
    func applyClaims(
        _ resolution: ObservationResolution,
        targetID: AcquisitionTargetID,
        recordID: Int64,
        revisionID: Int64?,
        in database: Database,
        committedAt: Date,
        bookkeeping: inout ClaimBookkeeping
    ) throws {
        let observation = resolution.observation
        let observedAt = AdmissionTimestamp.milliseconds(observation.payload.observedAt)
        let createdAt = AdmissionTimestamp.milliseconds(committedAt)

        for membership in observation.memberships {
            let existing = try Int64.fetchOne(database, sql: """
                SELECT COUNT(*) FROM source_membership
                WHERE origin_record_id = ? AND source_id = ? AND membership_kind = ?
                """, arguments: [recordID, membership.sourceID.rawValue, membership.membershipKind]) ?? 0
            if existing > 0 {
                try database.execute(sql: """
                    UPDATE source_membership SET last_observed_at = MAX(last_observed_at, ?)
                    WHERE origin_record_id = ? AND source_id = ? AND membership_kind = ?
                    """, arguments: [
                    observedAt,
                    recordID,
                    membership.sourceID.rawValue,
                    membership.membershipKind,
                ])
            } else {
                try database.execute(sql: """
                    INSERT INTO source_membership (
                        origin_record_id, source_id, membership_kind, evidence_target_id,
                        evidence_binding_namespace, evidence_binding_key, evidence_binding_generation,
                        first_observed_at, last_observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    recordID,
                    membership.sourceID.rawValue,
                    membership.membershipKind,
                    targetID.rawValue,
                    membership.binding?.namespace.rawValue,
                    membership.binding?.bindingKey,
                    membership.bindingGeneration,
                    observedAt,
                    observedAt,
                ])
                bookkeeping.newMembershipCount += 1
                bookkeeping.selectabilityChangingRecords.insert(recordID)
            }
        }

        if let providerClaim = observation.provider, let revisionID {
            let providerID = try upsertProvider(providerClaim, in: database, at: createdAt)
            try database.execute(sql: """
                INSERT INTO provider_attribution (
                    origin_revision_id, provider_id, attribution_role, evidence_key, created_at
                ) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [
                revisionID,
                providerID,
                providerClaim.role.rawValue,
                providerClaim.evidenceKey,
                createdAt,
            ])
        }

        for relation in observation.relations {
            // An unresolved object stays connector evidence: the core does not invent a record for
            // a key it has never admitted (ADR-003 D14).
            guard let targetIdentity = try objectIdentity(relation.target, in: database) else { continue }
            try database.execute(sql: """
                INSERT INTO content_relation (
                    subject_origin_record_id, relation, object_external_identity_id,
                    object_origin_record_id, created_at
                ) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [
                recordID,
                relation.verb.rawValue,
                targetIdentity.id,
                targetIdentity.recordID,
                createdAt,
            ])
            if database.changesCount == 1 {
                bookkeeping.newRelationCount += 1
                bookkeeping.selectabilityChangingRecords.insert(recordID)
            }
        }

        guard let revisionID else { return }
        for candidate in observation.mediaCandidates {
            try database.execute(sql: """
                INSERT INTO media_candidate (
                    origin_record_id, origin_revision_id, role, resource_url, media_type_hint,
                    pixel_width, pixel_height, position, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [
                recordID,
                revisionID,
                candidate.role.rawValue,
                candidate.resourceURL,
                candidate.mediaTypeHint,
                candidate.pixelWidth,
                candidate.pixelHeight,
                candidate.position,
                createdAt,
            ])
        }
        for offer in observation.interactionOffers {
            try database.execute(sql: """
                INSERT INTO interaction_offer (
                    origin_record_id, origin_revision_id, offer_kind, handle, position, created_at
                ) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [
                recordID,
                revisionID,
                offer.kind,
                offer.handle,
                offer.position,
                createdAt,
            ])
        }
    }

    /// Step 8: the selectable-supply projection of one record, rebuilt from its current revision in
    /// the same transaction that made it current (plan §6, ADR-006 D6).
    func refreshSupply(recordID: Int64, in database: Database) throws {
        guard let currentRevisionID = try currentRevisionID(recordID: recordID, in: database),
              let revision = try Row.fetchOne(database, sql: """
                  SELECT observed_at, authored_at, search_projection FROM origin_revision WHERE id = ?
                  """, arguments: [currentRevisionID])
        else {
            try database.execute(sql: "DELETE FROM selection_supply WHERE origin_record_id = ?", arguments: [recordID])
            try database.execute(sql: "DELETE FROM origin_search WHERE rowid = ?", arguments: [recordID])
            return
        }

        let observedAt: Int64 = revision["observed_at"]
        let publishedAtClaim: Int64? = revision["authored_at"]
        let projection: String? = revision["search_projection"]
        let sourceID = try singleMembershipSource(recordID: recordID, in: database)
        try database.execute(sql: """
            INSERT INTO selection_supply (
                origin_record_id, origin_revision_id, source_id, observed_at, published_at_claim
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(origin_record_id) DO UPDATE SET
                origin_revision_id = excluded.origin_revision_id,
                source_id = excluded.source_id,
                observed_at = excluded.observed_at,
                published_at_claim = excluded.published_at_claim
            """, arguments: [recordID, currentRevisionID, sourceID, observedAt, publishedAtClaim])

        try database.execute(sql: "DELETE FROM origin_search WHERE rowid = ?", arguments: [recordID])
        if let projection, !projection.isEmpty {
            try database.execute(sql: """
                INSERT INTO origin_search (rowid, projection) VALUES (?, ?)
                """, arguments: [recordID, projection])
        }
    }

    /// The source a supply row is attributed to: the record's membership source when exactly one
    /// membership exists, otherwise `nil`. Selection owns the real scoping in PR-05; the projection
    /// only denormalises what is unambiguous.
    func singleMembershipSource(recordID: Int64, in database: Database) throws -> Int64? {
        let sources = try Int64.fetchAll(database, sql: """
            SELECT DISTINCT source_id FROM source_membership WHERE origin_record_id = ? ORDER BY source_id
            """, arguments: [recordID])
        return sources.count == 1 ? sources[0] : nil
    }

    /// Step 9: the receipt and the evidence, written before the checkpoint moves (ADR-006 D2, step 9).
    func persist(
        _ receipt: AdmissionReceipt,
        batch: AcquisitionBatch,
        fingerprint: String,
        committedAt: Date,
        in database: Database
    ) throws {
        let checkpointWritten: UInt64? = batch.nextCheckpoint == nil
            ? nil
            : batch.expectedCheckpointRevision + 1
        let committedAtMilliseconds = AdmissionTimestamp.milliseconds(committedAt)
        try database.execute(sql: """
            INSERT INTO admission_batch (
                batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                checkpoint_expected, checkpoint_written, observation_count, result, receipt_blob, committed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'admitted', ?, ?)
            """, arguments: [
            batch.batchID,
            batch.targetID.rawValue,
            batch.generation,
            batch.bindingRevision,
            batch.leaseEpoch,
            fingerprint,
            batch.expectedCheckpointRevision,
            checkpointWritten,
            batch.observations.count,
            try JSONEncoder().encode(receipt),
            committedAtMilliseconds,
        ])

        for evidence in batch.evidence {
            try database.execute(sql: """
                INSERT INTO connector_evidence (batch_id, kind, digest, bytes, created_at)
                VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [
                batch.batchID,
                evidence.kind.rawValue,
                evidence.digest,
                evidence.bytes,
                committedAtMilliseconds,
            ])
        }
    }

    // MARK: - Row helpers

    /// The in-batch identity of an object key. Only used to keep one batch consistent with itself;
    /// durable identity is the SQL uniqueness rule.
    static func objectKeyIdentity(_ key: ExternalObjectKey) -> String {
        "\(key.scope.namespace.rawValue)|\(key.scope.scopeKey)|\(key.bytes.base64EncodedString())"
    }

    /// The text the search projection indexes: what the reader would see, in one string.
    static func searchProjection(_ payload: ObservationPayload) -> String? {
        let parts = [payload.headline, payload.excerpt, payload.body]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func insertObjectIdentity(
        _ resolution: ObservationResolution,
        in database: Database,
        at observedAt: Int64
    ) throws -> Int64 {
        let key = resolution.observation.externalKey
        try database.execute(sql: """
            INSERT INTO external_identity (
                connector_namespace, scope_key, key_kind, external_key, key_digest, origin_record_id,
                identity_confidence, fallback_scheme_version, first_observed_at, last_observed_at
            ) VALUES (?, ?, 'object', ?, ?, NULL, ?, ?, ?, ?)
            """, arguments: [
            key.scope.namespace.rawValue,
            key.scope.scopeKey,
            key.bytes,
            resolution.keyDigest,
            resolution.observation.identityConfidence.rawValue,
            resolution.observation.fallbackSchemeVersion,
            observedAt,
            observedAt,
        ])
        return database.lastInsertedRowID
    }

    private func insertRecord(
        _ resolution: ObservationResolution,
        identityID: Int64,
        in database: Database,
        at observedAt: Int64
    ) throws -> Int64 {
        let key = resolution.observation.externalKey
        try database.execute(sql: """
            INSERT INTO origin_record (
                connector_namespace, scope_key, primary_identity_id, availability,
                first_observed_at, last_observed_at
            ) VALUES (?, ?, ?, 'available', ?, ?)
            """, arguments: [key.scope.namespace.rawValue, key.scope.scopeKey, identityID, observedAt, observedAt])
        return database.lastInsertedRowID
    }

    private func backfill(identityID: Int64, recordID: Int64, in database: Database) throws {
        try database.execute(sql: """
            UPDATE external_identity SET origin_record_id = ? WHERE id = ?
            """, arguments: [recordID, identityID])
    }

    private func touchIdentityAndRecord(
        identityID: Int64,
        recordID: Int64,
        at observedAt: Int64,
        in database: Database
    ) throws {
        try database.execute(sql: """
            UPDATE external_identity SET last_observed_at = MAX(last_observed_at, ?) WHERE id = ?
            """, arguments: [observedAt, identityID])
        try database.execute(sql: """
            UPDATE origin_record SET last_observed_at = MAX(last_observed_at, ?) WHERE id = ?
            """, arguments: [observedAt, recordID])
    }

    private func insertRevision(
        _ resolution: ObservationResolution,
        recordID: Int64,
        in database: Database,
        at committedAt: Date
    ) throws -> Int64 {
        let observation = resolution.observation
        let payload = observation.payload
        try database.execute(sql: """
            INSERT INTO origin_revision (
                origin_record_id, external_version_key, payload_digest, headline, summary, body_text,
                authored_at, modified_at, observed_at, primary_link, search_projection,
                identity_confidence, fallback_scheme_version, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
            recordID,
            observation.versionKey?.bytes,
            resolution.payloadDigest,
            payload.headline,
            payload.excerpt,
            payload.body,
            payload.authoredAt.map(AdmissionTimestamp.milliseconds),
            payload.modifiedAt.map(AdmissionTimestamp.milliseconds),
            AdmissionTimestamp.milliseconds(payload.observedAt),
            payload.link?.absoluteString,
            Self.searchProjection(payload),
            observation.identityConfidence.rawValue,
            observation.fallbackSchemeVersion,
            AdmissionTimestamp.milliseconds(committedAt),
        ])
        return database.lastInsertedRowID
    }

    private func upsertProvider(_ claim: ProviderClaim, in database: Database, at createdAt: Int64) throws -> Int64 {
        if let existing = try Int64.fetchOne(database, sql: """
            SELECT id FROM provider WHERE connector_namespace = ? AND provider_key = ?
            """, arguments: [claim.namespace.rawValue, claim.providerKey]) {
            return existing
        }
        try database.execute(sql: """
            INSERT INTO provider (connector_namespace, provider_key, display_name, created_at)
            VALUES (?, ?, ?, ?)
            """, arguments: [claim.namespace.rawValue, claim.providerKey, claim.displayName, createdAt])
        return database.lastInsertedRowID
    }
}

