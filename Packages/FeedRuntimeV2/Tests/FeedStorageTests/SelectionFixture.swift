import Foundation
import GRDB
import FeedDomain
@testable import FeedStorage

/// Fixtures for the PR-05 selection reads.
///
/// Rows are written directly rather than through Admission: the repository is the unit under test, and
/// a fixture must be able to express states Admission does not produce yet — a revoked record, an
/// unsupported plan context, a hundred thousand rows — without inventing a connector for each case.
/// Admission's own transactional path is covered by `AdmissionTests`/`CheckpointTests`.
extension RuntimeV2TestCase {
    struct SupplyRow {
        let recordID: Int64
        let revisionID: Int64
    }

    /// The row id of a source, creating it when it does not exist. The durable key is the one the plan
    /// names (`editorial_key` + `canonicalization_version`).
    @discardableResult
    func ensureSource(
        _ catalogIdentity: String,
        canonicalizationVersion: Int = 1,
        displayTitle: String = "Source",
        in database: RuntimeDatabase? = nil
    ) throws -> Int64 {
        try (database ?? self.database).write { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO source (
                    editorial_key, canonicalization_version, display_title, created_at
                ) VALUES (?, ?, ?, 0)
                """, arguments: [catalogIdentity, canonicalizationVersion, displayTitle])
            return try Int64.fetchOne(database, sql: """
                SELECT id FROM source WHERE editorial_key = ? AND canonicalization_version = ?
                """, arguments: [catalogIdentity, canonicalizationVersion]) ?? 0
        }
    }

    @discardableResult
    func ensureProvider(
        namespace: String = "connector.test",
        key: String,
        in database: RuntimeDatabase? = nil
    ) throws -> Int64 {
        try (database ?? self.database).write { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO provider (
                    connector_namespace, provider_key, display_name, created_at
                ) VALUES (?, ?, ?, 0)
                """, arguments: [namespace, key, key])
            return try Int64.fetchOne(database, sql: """
                SELECT id FROM provider WHERE connector_namespace = ? AND provider_key = ?
                """, arguments: [namespace, key]) ?? 0
        }
    }

    /// One record with one revision, its memberships, its optional primary attribution, its media roles
    /// and its supply row. `observedAt`/`authoredAt` are epoch milliseconds: the runtime stores
    /// timestamps that way (`AdmissionTimestamp`) and a fixture must not round-trip a floating point.
    @discardableResult
    func insertSupplyRow(
        objectKey: String,
        sourceIDs: [Int64],
        providerID: Int64? = nil,
        namespace: String = "connector.test",
        scopeKey: String = "feed-1",
        headline: String? = "Headline",
        summary: String? = nil,
        publishedAtClaim: Int64? = nil,
        observedAt: Int64,
        availability: String = "available",
        mediaRoles: [MediaRole] = [],
        in database: RuntimeDatabase? = nil
    ) throws -> SupplyRow {
        try (database ?? self.database).write { database in
            let keyBytes = Data(objectKey.utf8)
            try database.execute(sql: """
                INSERT INTO external_identity (
                    connector_namespace, scope_key, key_kind, external_key, key_digest,
                    origin_record_id, identity_confidence, first_observed_at, last_observed_at
                ) VALUES (?, ?, 'object', ?, zeroblob(16), NULL, 'high', ?, ?)
                """, arguments: [namespace, scopeKey, keyBytes, observedAt, observedAt])
            let identityID = database.lastInsertedRowID

            try database.execute(sql: """
                INSERT INTO origin_record (
                    connector_namespace, scope_key, primary_identity_id, availability,
                    first_observed_at, last_observed_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [namespace, scopeKey, identityID, availability, observedAt, observedAt])
            let recordID = database.lastInsertedRowID
            try database.execute(
                sql: "UPDATE external_identity SET origin_record_id = ? WHERE id = ?",
                arguments: [recordID, identityID]
            )

            try database.execute(sql: """
                INSERT INTO origin_revision (
                    origin_record_id, external_version_key, payload_digest, headline, summary,
                    authored_at, observed_at, created_at, identity_confidence
                ) VALUES (?, NULL, ?, ?, ?, ?, ?, 0, 'high')
                """, arguments: [
                recordID,
                Data("digest-\(objectKey)".utf8),
                headline,
                summary,
                publishedAtClaim,
                observedAt,
            ])
            let revisionID = database.lastInsertedRowID
            try database.execute(
                sql: "UPDATE origin_record SET current_revision_id = ? WHERE id = ?",
                arguments: [revisionID, recordID]
            )

            for sourceID in sourceIDs {
                try database.execute(sql: """
                    INSERT INTO source_membership (
                        origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at
                    ) VALUES (?, ?, 'editorial', ?, ?)
                    """, arguments: [recordID, sourceID, observedAt, observedAt])
            }
            if let providerID {
                try database.execute(sql: """
                    INSERT INTO provider_attribution (
                        origin_revision_id, provider_id, attribution_role, created_at
                    ) VALUES (?, ?, 'primary', 0)
                    """, arguments: [revisionID, providerID])
            }
            for (position, role) in mediaRoles.enumerated() {
                try database.execute(sql: """
                    INSERT INTO media_candidate (
                        origin_record_id, origin_revision_id, role, resource_url, position, created_at
                    ) VALUES (?, ?, ?, ?, ?, 0)
                    """, arguments: [
                    recordID, revisionID, role.rawValue, "https://example.test/\(objectKey)", position,
                ])
            }
            try database.execute(sql: """
                INSERT INTO selection_supply (
                    origin_record_id, origin_revision_id, source_id, observed_at, published_at_claim
                ) VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                recordID, revisionID, sourceIDs.count == 1 ? sourceIDs[0] : nil, observedAt, publishedAtClaim,
            ])
            return SupplyRow(recordID: recordID, revisionID: revisionID)
        }
    }

    /// A promoted syndication relation between two records (ADR-003 D14): the input a cluster grouping
    /// is derived from, and the only input that groups them.
    func insertRelation(
        subject: Int64,
        verb: String,
        object: Int64,
        in database: RuntimeDatabase? = nil
    ) throws {
        try (database ?? self.database).write { database in
            try database.execute(sql: """
                INSERT INTO content_relation (
                    subject_origin_record_id, relation, object_origin_record_id, created_at
                ) VALUES (?, ?, ?, 0)
                """, arguments: [subject, verb, object])
        }
    }

    /// Connector evidence for a record, which Selection must not be able to read: it is stored against
    /// an admission batch, exactly as the connector left it.
    func insertConnectorEvidence(
        batchID: String,
        digest: String,
        bytes: Data?,
        in database: RuntimeDatabase? = nil
    ) throws {
        try (database ?? self.database).write { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO acquisition_target (
                    id, connector_kind, generation, binding_revision, lease_epoch, state
                ) VALUES ('target-evidence', 'rss', 1, 1, 0, 'active')
                """)
            try database.execute(sql: """
                INSERT OR IGNORE INTO admission_batch (
                    batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                    checkpoint_expected, checkpoint_written, observation_count, result, receipt_blob,
                    committed_at
                ) VALUES (?, 'target-evidence', 1, 1, 0, ?, 0, 0, 0, 'admitted', x'00', 0)
                """, arguments: [batchID, String(repeating: "0", count: 64)])
            try database.execute(sql: """
                INSERT INTO connector_evidence (batch_id, kind, digest, bytes, created_at)
                VALUES (?, 'responseBody', ?, ?, 0)
                """, arguments: [batchID, digest, bytes])
        }
    }

    /// The supply counter Selection reads beside the pool.
    func setSupplyGeneration(_ value: Int64, in database: RuntimeDatabase? = nil) throws {
        try (database ?? self.database).write { database in
            try database.execute(sql: "UPDATE supply_generation SET value = ? WHERE id = 1", arguments: [value])
        }
    }
}
