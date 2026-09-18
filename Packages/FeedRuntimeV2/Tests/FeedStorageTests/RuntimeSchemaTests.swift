import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// The constraints themselves, proved by trying to violate them: a migration test that only inserts
/// valid rows proves nothing about the schema (plan §6 integrity rules, ADR-003 D3, D8, D11).
final class RuntimeSchemaTests: RuntimeV2TestCase {
    /// A minimal valid graph inserted with raw SQL, so these tests are about the schema and not
    /// about Admission: two independent records with one revision each, plus a target and a batch.
    func seedRecordGraph() throws {
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO external_identity (
                    id, connector_namespace, scope_key, key_kind, external_key, key_digest,
                    origin_record_id, identity_confidence, first_observed_at, last_observed_at
                ) VALUES (1, 'n', 's', 'object', X'01', X'81', NULL, 'high', 0, 0);
                INSERT INTO origin_record (
                    id, connector_namespace, scope_key, primary_identity_id, first_observed_at, last_observed_at
                ) VALUES (1, 'n', 's', 1, 0, 0);
                UPDATE external_identity SET origin_record_id = 1 WHERE id = 1;
                INSERT INTO origin_revision (
                    id, origin_record_id, external_version_key, payload_digest, observed_at, created_at
                ) VALUES (1, 1, X'AA', X'BB', 0, 0);
                UPDATE origin_record SET current_revision_id = 1 WHERE id = 1;

                INSERT INTO external_identity (
                    id, connector_namespace, scope_key, key_kind, external_key, key_digest,
                    origin_record_id, identity_confidence, first_observed_at, last_observed_at
                ) VALUES (2, 'n', 's', 'object', X'02', X'82', NULL, 'high', 0, 0);
                INSERT INTO origin_record (
                    id, connector_namespace, scope_key, primary_identity_id, first_observed_at, last_observed_at
                ) VALUES (2, 'n', 's', 2, 0, 0);
                UPDATE external_identity SET origin_record_id = 2 WHERE id = 2;
                INSERT INTO origin_revision (
                    id, origin_record_id, external_version_key, payload_digest, observed_at, created_at
                ) VALUES (2, 2, X'CC', X'DD', 0, 0);
                UPDATE origin_record SET current_revision_id = 2 WHERE id = 2;

                INSERT INTO source (id, editorial_key, canonicalization_version, display_title, created_at)
                VALUES (1, 'catalog:one', 1, 'One', 0);
                INSERT INTO provider (id, connector_namespace, provider_key, display_name, created_at)
                VALUES (1, 'n', 'author-1', 'Author', 0);
                INSERT INTO acquisition_target (id, connector_kind, generation, binding_revision, lease_epoch, state)
                VALUES ('target-1', 'rss', 1, 1, 0, 'active');
                INSERT INTO connector_checkpoint (
                    target_id, checkpoint_revision, serialization_schema, connector_version, updated_at
                ) VALUES ('target-1', 0, 1, 'connector.test', 0);
                INSERT INTO admission_batch (
                    batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                    checkpoint_expected, checkpoint_written, observation_count, result, receipt_blob, committed_at
                ) VALUES ('batch-1', 'target-1', 1, 1, 0, '\(String(repeating: "0", count: 64))', 0, 1, 1, 'admitted', X'00', 0);
                INSERT INTO connector_evidence (id, batch_id, kind, digest, created_at)
                VALUES (1, 'batch-1', 'other', 'digest-seed', 0);
                """)
        }
    }

    // MARK: - Positive row identifiers

    /// `0` is the reserved "none" value and never a row (ADR-003 D3): every local identity table
    /// must refuse it even when the rest of the row is valid.
    func testZeroRowIdentifiersAreRefusedByEveryLocalIdentityTable() throws {
        try seedRecordGraph()

        let attempts = [
            ("source", """
                INSERT INTO source (id, editorial_key, canonicalization_version, display_title, created_at)
                VALUES (0, 'catalog:zero', 1, 'Zero', 0)
                """),
            ("source, negative", """
                INSERT INTO source (id, editorial_key, canonicalization_version, display_title, created_at)
                VALUES (-1, 'catalog:negative', 1, 'Negative', 0)
                """),
            ("provider", """
                INSERT INTO provider (id, connector_namespace, provider_key, display_name, created_at)
                VALUES (0, 'n', 'author-0', 'Author', 0)
                """),
            ("source_binding_runtime", """
                INSERT INTO source_binding_runtime (
                    id, source_id, connector_namespace, binding_key, created_at, updated_at
                ) VALUES (0, 1, 'n', 'binding-0', 0, 0)
                """),
            ("external_identity", """
                INSERT INTO external_identity (
                    id, connector_namespace, scope_key, key_kind, external_key, key_digest,
                    identity_confidence, first_observed_at, last_observed_at
                ) VALUES (0, 'n', 's', 'version', X'09', X'89', 'high', 0, 0)
                """),
            ("identity_conflict", """
                INSERT INTO identity_conflict (
                    id, connector_namespace, scope_key, conflict_kind, incoming_external_key,
                    incoming_key_digest, detected_at
                ) VALUES (0, 'n', 's', 'ambiguous_alias', X'09', X'89', 0)
                """),
            ("origin_record", """
                INSERT INTO origin_record (
                    id, connector_namespace, scope_key, primary_identity_id, first_observed_at, last_observed_at
                ) VALUES (0, 'n', 's', 1, 0, 0)
                """),
            ("origin_revision", """
                INSERT INTO origin_revision (id, origin_record_id, payload_digest, observed_at, created_at)
                VALUES (0, 1, X'09', 0, 0)
                """),
            ("provider_attribution", """
                INSERT INTO provider_attribution (
                    id, origin_revision_id, provider_id, attribution_role, created_at
                ) VALUES (0, 1, 1, 'primary', 0)
                """),
            ("content_relation", """
                INSERT INTO content_relation (
                    id, subject_origin_record_id, relation, object_origin_record_id, created_at
                ) VALUES (0, 1, 'replyTo', 1, 0)
                """),
            ("media_candidate", """
                INSERT INTO media_candidate (
                    id, origin_record_id, origin_revision_id, role, resource_url, created_at
                ) VALUES (0, 1, 1, 'image', 'https://cdn.example.test/a.jpg', 0)
                """),
            ("interaction_offer", """
                INSERT INTO interaction_offer (
                    id, origin_record_id, origin_revision_id, offer_kind, created_at
                ) VALUES (0, 1, 1, 'open', 0)
                """),
            ("connector_evidence", """
                INSERT INTO connector_evidence (id, batch_id, kind, digest, created_at)
                VALUES (0, 'batch-1', 'other', 'digest-0', 0)
                """),
        ]

        for (label, sql) in attempts {
            assertCheckFailure(sql)
            XCTAssertEqual(try rowCount("source WHERE id = 0"), 0, label)
        }
    }

    // MARK: - Ranges and closed vocabularies

    func testClosedVocabulariesAndRangesAreRefused() throws {
        try seedRecordGraph()

        assertCheckFailure("""
            INSERT INTO acquisition_target (id, connector_kind, generation, binding_revision, state)
            VALUES ('', 'rss', 1, 1, 'active')
            """)
        assertCheckFailure("""
            INSERT INTO acquisition_target (id, connector_kind, generation, binding_revision, state)
            VALUES ('target-2', 'rss', 0, 1, 'active')
            """)
        assertCheckFailure("""
            INSERT INTO acquisition_target (id, connector_kind, generation, binding_revision, state)
            VALUES ('target-2', 'rss', 1, 0, 'active')
            """)
        assertCheckFailure("""
            INSERT INTO acquisition_target (id, connector_kind, generation, binding_revision, state)
            VALUES ('target-2', 'rss', 1, 1, 'paused')
            """)
        assertCheckFailure("""
            INSERT INTO admission_batch (
                batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                checkpoint_expected, observation_count, result, receipt_blob, committed_at
            ) VALUES ('', 'target-1', 1, 1, 0, '\(String(repeating: "0", count: 64))', 0, 0, 'admitted', X'00', 0)
            """)
        assertCheckFailure("""
            INSERT INTO admission_batch (
                batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                checkpoint_expected, observation_count, result, receipt_blob, committed_at
            ) VALUES ('batch-2', 'target-1', 1, 1, 0, 'too-short', 0, 0, 'admitted', X'00', 0)
            """)
        assertCheckFailure("""
            INSERT INTO admission_batch (
                batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                checkpoint_expected, observation_count, result, receipt_blob, committed_at
            ) VALUES ('batch-3', 'target-1', 1, 1, 0, '\(String(repeating: "0", count: 64))', 0, 0, 'ignored', X'00', 0)
            """)
        assertCheckFailure("""
            INSERT INTO external_identity (
                connector_namespace, scope_key, key_kind, external_key, key_digest,
                identity_confidence, first_observed_at, last_observed_at
            ) VALUES ('n', 's', 'digest', X'09', X'89', 'high', 0, 0)
            """)
        assertCheckFailure("""
            INSERT INTO external_identity (
                connector_namespace, scope_key, key_kind, external_key, key_digest,
                identity_confidence, first_observed_at, last_observed_at
            ) VALUES ('n', 's', 'version', X'', X'89', 'high', 0, 0)
            """)
        assertCheckFailure("""
            INSERT INTO external_identity (
                connector_namespace, scope_key, key_kind, external_key, key_digest,
                identity_confidence, first_observed_at, last_observed_at
            ) VALUES ('n', 's', 'version', X'09', X'89', 'low', 0, 0)
            """)
        assertCheckFailure("""
            INSERT INTO identity_conflict (
                connector_namespace, scope_key, conflict_kind, incoming_external_key,
                incoming_key_digest, detected_at
            ) VALUES ('n', 's', 'something_else', X'09', X'89', 0)
            """)
        assertCheckFailure("""
            INSERT INTO source_membership (
                origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at
            ) VALUES (1, 1, 'editorial', 10, 5)
            """)
        assertCheckFailure("""
            INSERT INTO content_relation (
                subject_origin_record_id, relation, object_origin_record_id, created_at
            ) VALUES (1, 'likedBy', 1, 0)
            """)
        assertCheckFailure("""
            INSERT INTO content_relation (subject_origin_record_id, relation, created_at)
            VALUES (1, 'replyTo', 0)
            """)
        assertCheckFailure("""
            INSERT INTO provider_attribution (origin_revision_id, provider_id, attribution_role, created_at)
            VALUES (1, 1, 'editor', 0)
            """)
        assertCheckFailure("""
            INSERT INTO media_candidate (origin_record_id, origin_revision_id, role, resource_url, created_at)
            VALUES (1, 1, 'cover', 'https://cdn.example.test/a.jpg', 0)
            """)
        assertCheckFailure("""
            INSERT INTO media_candidate (origin_record_id, origin_revision_id, role, resource_url, created_at)
            VALUES (1, 1, 'image', '', 0)
            """)
        assertCheckFailure("""
            INSERT INTO media_candidate (origin_record_id, origin_revision_id, role, resource_url, position, created_at)
            VALUES (1, 1, 'image', 'https://cdn.example.test/a.jpg', -1, 0)
            """)
        assertCheckFailure("""
            INSERT INTO supply_generation (id, value) VALUES (2, 0)
            """)
        assertCheckFailure("""
            INSERT INTO legacy_item_map (legacy_item_id, legacy_source_url, confidence, mapped_at)
            VALUES ('legacy-1', 'https://example.test/feed', 'certain', 0)
            """)
        assertCheckFailure("""
            INSERT INTO legacy_source_map (
                catalog_source_key, catalog_source_id, canonicalization_version, runtime_source_id,
                legacy_url, mapped_at
            ) VALUES ('catalog:zero', 0, 1, 1, 'https://example.test/feed', 0)
            """)
    }

    // MARK: - Identity uniqueness

    func testExternalIdentityUniquenessComparesTheFullKeyAndTreatsTheDigestAsAuxiliary() throws {
        try seedRecordGraph()
        let sharedDigest = Data([0xDE, 0xAD, 0xBE, 0xEF])

        // Two different full keys that share an auxiliary digest are two identities: the digest only
        // prunes an index and never decides equality (ADR-003 D8).
        for key in [Data([0x10, 0x01]), Data([0x10, 0x02])] {
            try database.write { database in
                try database.execute(sql: """
                    INSERT INTO external_identity (
                        connector_namespace, scope_key, key_kind, external_key, key_digest,
                        identity_confidence, first_observed_at, last_observed_at
                    ) VALUES ('n', 's', 'version', ?, ?, 'high', 0, 0)
                    """, arguments: [key, sharedDigest])
            }
        }
        XCTAssertEqual(try rowCount("external_identity"), 4, "the seeded pair plus the digest twins")

        // The same full key in the same scope and kind is refused.
        assertUniqueFailure("""
            INSERT INTO external_identity (
                connector_namespace, scope_key, key_kind, external_key, key_digest,
                identity_confidence, first_observed_at, last_observed_at
            ) VALUES ('n', 's', 'version', ?, ?, 'high', 0, 0)
            """, [Data([0x10, 0x01]), sharedDigest])

        // Another scope, another namespace and another key kind are different key spaces.
        for (namespace, scope, kind) in [("n", "s2", "version"), ("n2", "s", "version"), ("n", "s", "object")] {
            try database.write { database in
                try database.execute(sql: """
                    INSERT INTO external_identity (
                        connector_namespace, scope_key, key_kind, external_key, key_digest,
                        origin_record_id, identity_confidence, first_observed_at, last_observed_at
                    ) VALUES (?, ?, ?, ?, ?, 1, 'high', 0, 0)
                    """, arguments: [namespace, scope, kind, Data([0x10, 0x01]), sharedDigest])
            }
        }
        XCTAssertEqual(try rowCount("external_identity"), 7, "uniqueness is scoped, not global")
    }

    // MARK: - Composite foreign keys

    func testCompositeForeignKeysKeepChildrenInsideTheirParentRecord() throws {
        try seedRecordGraph()

        // The current pointer can only name a revision of its own record.
        assertForeignKeyFailure("UPDATE origin_record SET current_revision_id = 2 WHERE id = 1")
        try database.write { database in
            try database.execute(sql: "UPDATE origin_record SET current_revision_id = 1 WHERE id = 1")
        }

        // A projection row can only name the current revision of its own record.
        assertForeignKeyFailure("""
            INSERT INTO selection_supply (origin_record_id, origin_revision_id, observed_at)
            VALUES (1, 2, 0)
            """)
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO selection_supply (origin_record_id, origin_revision_id, observed_at)
                VALUES (1, 1, 0)
                """)
        }

        // So can a media candidate and an offer.
        assertForeignKeyFailure("""
            INSERT INTO media_candidate (origin_record_id, origin_revision_id, role, resource_url, created_at)
            VALUES (1, 2, 'image', 'https://cdn.example.test/a.jpg', 0)
            """)
        assertForeignKeyFailure("""
            INSERT INTO interaction_offer (origin_record_id, origin_revision_id, offer_kind, created_at)
            VALUES (1, 2, 'open', 0)
            """)
        XCTAssertEqual(
            try rowCount("selection_supply"),
            1,
            "the valid direction still works, so the constraint is a constraint and not a wall"
        )
    }

    func testUniqueEditorialRulesRefuseDuplicateRows() throws {
        try seedRecordGraph()

        try database.write { database in
            try database.execute(sql: """
                INSERT INTO source_binding_runtime (
                    id, source_id, connector_namespace, binding_key, created_at, updated_at
                ) VALUES (1, 1, 'n', 'binding-1', 0, 0);
                INSERT INTO source_membership (
                    origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at
                ) VALUES (1, 1, 'editorial', 0, 0);
                INSERT INTO provider_attribution (
                    id, origin_revision_id, provider_id, attribution_role, created_at
                ) VALUES (1, 1, 1, 'primary', 0);
                INSERT INTO content_relation (
                    id, subject_origin_record_id, relation, object_external_identity_id, created_at
                ) VALUES (1, 1, 'replyTo', 1, 0);
                """)
        }

        assertUniqueFailure("""
            INSERT INTO source (editorial_key, canonicalization_version, display_title, created_at)
            VALUES ('catalog:one', 1, 'Again', 0)
            """)
        assertUniqueFailure("""
            INSERT INTO provider (connector_namespace, provider_key, display_name, created_at)
            VALUES ('n', 'author-1', 'Again', 0)
            """)
        assertUniqueFailure("""
            INSERT INTO source_binding_runtime (source_id, connector_namespace, binding_key, created_at, updated_at)
            VALUES (1, 'n', 'binding-1', 0, 0)
            """)
        assertUniqueFailure("""
            INSERT INTO source_membership (
                origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at
            ) VALUES (1, 1, 'editorial', 0, 0)
            """)
        assertUniqueFailure("""
            INSERT INTO provider_attribution (origin_revision_id, provider_id, attribution_role, created_at)
            VALUES (1, 1, 'primary', 0)
            """)
        assertUniqueFailure("""
            INSERT INTO content_relation (
                subject_origin_record_id, relation, object_external_identity_id, created_at
            ) VALUES (1, 'replyTo', 1, 0)
            """)
        assertUniqueFailure("""
            INSERT INTO connector_evidence (batch_id, kind, digest, created_at)
            VALUES ('batch-1', 'other', 'digest-seed', 0)
            """)
        assertUniqueFailure("""
            INSERT INTO admission_batch (
                batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                checkpoint_expected, observation_count, result, receipt_blob, committed_at
            ) VALUES ('batch-1', 'target-1', 1, 1, 0, '\(String(repeating: "1", count: 64))', 0, 0, 'admitted', X'00', 0)
            """)
    }

    // MARK: - Append-only revisions

    func testRevisionPayloadCannotBeUpdated() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [
                    try observation(
                        object: "item-1",
                        version: "v1",
                        headline: "Immutable",
                        body: "Body"
                    )
                ]
            )
        )

        for sql in [
            "UPDATE origin_revision SET headline = 'Rewritten' WHERE id = 1",
            "UPDATE origin_revision SET body_text = 'Rewritten' WHERE id = 1",
            "UPDATE origin_revision SET payload_digest = X'00' WHERE id = 1",
            "UPDATE origin_revision SET external_version_key = X'00' WHERE id = 1",
            "UPDATE origin_revision SET origin_record_id = 2 WHERE id = 1",
            "UPDATE origin_revision SET observed_at = 99 WHERE id = 1",
            "UPDATE origin_revision SET search_projection = 'rewritten' WHERE id = 1",
        ] {
            assertConstraintFailure(sql, containing: "origin_revision payload is append-only")
        }

        XCTAssertEqual(try string("SELECT headline FROM origin_revision WHERE id = 1"), "Immutable")
        XCTAssertEqual(try string("SELECT body_text FROM origin_revision WHERE id = 1"), "Body")
        XCTAssertEqual(
            try scalar("SELECT observed_at FROM origin_revision WHERE id = 1"),
            Int64(TestInstant.epoch.timeIntervalSince1970 * 1000)
        )
    }

    // MARK: - Projection

    func testSearchProjectionIndexesOnlyTheCurrentRevision() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [
                    try observation(object: "item-1", version: "v1", headline: "Alpha", body: "first only")
                ]
            )
        )
        XCTAssertEqual(try matchingRecordIDs("Alpha"), [1])
        XCTAssertEqual(try matchingRecordIDs("first"), [1])

        let newer = try observation(
            object: "item-1",
            version: "v2",
            precedence: .makeCurrent(expectedRevision: try OriginRevisionID(1)),
            headline: "Beta",
            body: "second only"
        )
        try admitRequiringSuccess(try batch(id: "batch-2", expectedCheckpoint: 1, observations: [newer]))

        XCTAssertEqual(try matchingRecordIDs("Beta"), [1])
        XCTAssertEqual(try matchingRecordIDs("second"), [1])
        XCTAssertTrue(
            try matchingRecordIDs("Alpha").isEmpty,
            "the search index describes what is current, never what once was"
        )
        XCTAssertTrue(try matchingRecordIDs("first").isEmpty)
    }

    private func matchingRecordIDs(_ term: String) throws -> [Int64] {
        try database.read { database in
            try Int64.fetchAll(
                database,
                sql: "SELECT rowid FROM origin_search WHERE origin_search MATCH ?",
                arguments: [term]
            )
        }
    }

    // MARK: - Batch fingerprint

    func testBatchFingerprintIsSHA256OverTheCanonicalBody() throws {
        // Published FIPS 180-4 vectors, including one message that spans blocks: "64 hex characters"
        // is not evidence of a digest.
        XCTAssertEqual(
            SHA256.hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hex(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )

        let base = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-1", version: "v1", headline: "One")]
        )
        let fingerprint = BatchFingerprint.of(base)
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertEqual(fingerprint, BatchFingerprint.of(base), "the same body is the same fingerprint")
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit })

        let changedPayload = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-1", version: "v1", headline: "Two")]
        )
        XCTAssertNotEqual(BatchFingerprint.of(changedPayload), fingerprint)

        let prefixObject = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [try observation(object: "item", version: "v1", headline: "One")]
        )
        XCTAssertNotEqual(BatchFingerprint.of(prefixObject), fingerprint, "length-prefixed, so no prefix collision")

        let reordered = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [
                try observation(object: "item-2", version: "v1", headline: "One"),
                try observation(object: "item-1", version: "v1", headline: "One"),
            ]
        )
        XCTAssertNotEqual(BatchFingerprint.of(reordered), fingerprint, "observation order is part of the body")

        let otherCheckpoint = try batch(
            id: "batch-1",
            expectedCheckpoint: 1,
            observations: [try observation(object: "item-1", version: "v1", headline: "One")]
        )
        XCTAssertEqual(
            BatchFingerprint.of(otherCheckpoint), fingerprint,
            "the expected checkpoint revision is runtime-derived and advances with the admission itself, so it is not part of the body (§8.55)"
        )

        // A local observation timestamp is not part of the body: a retry that re-stamps unchanged
        // content must still be a replay and not a conflict.
        let restamped = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [
                try observation(
                    object: "item-1",
                    version: "v1",
                    headline: "One",
                    observedAt: TestInstant.seconds(600)
                )
            ]
        )
        XCTAssertEqual(BatchFingerprint.of(restamped), fingerprint)

        try registerTarget()
        try admitRequiringSuccess(base)
        XCTAssertEqual(try string("SELECT fingerprint FROM admission_batch WHERE batch_id = 'batch-1'"), fingerprint)
    }

    // MARK: - Legacy bridges

    func testLegacyMappingStorePersistsBothBridges() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1")]
            )
        )
        let sourceID = try insertSource()
        let store = LegacyMappingStore()
        let editorialKey = try EditorialSourceKey(catalogIdentity: "catalog:example", canonicalizationVersion: 1)
        let mapping = LegacySourceMapping(
            editorialKey: editorialKey,
            catalogSourceID: CatalogSourceID(77),
            runtimeSourceID: sourceID,
            legacyURL: "https://example.test/feed",
            mappedAt: TestInstant.epoch
        )

        try store.recordSourceMapping(mapping, in: database)
        XCTAssertEqual(try store.sourceMapping(for: editorialKey, in: database), mapping)

        // An established durable key is not re-pointed by a later write; the mapper (ADR-003 D18)
        // records the contest instead.
        let contest = LegacySourceMapping(
            editorialKey: editorialKey,
            catalogSourceID: CatalogSourceID(78),
            runtimeSourceID: sourceID,
            legacyURL: "https://other.test/feed",
            mappedAt: TestInstant.seconds(5)
        )
        try store.recordSourceMapping(contest, in: database)
        XCTAssertEqual(try store.sourceMapping(for: editorialKey, in: database), mapping)

        let unresolved = LegacyItemMapping.unresolved(
            legacyItemID: "legacy-1",
            legacySourceURL: "https://example.test/feed",
            mappedAt: TestInstant.epoch
        )
        try store.recordItemMapping(unresolved, in: database)
        XCTAssertEqual(try store.itemMapping(forLegacyItemID: "legacy-1", in: database), unresolved)

        let resolved = LegacyItemMapping(
            legacyItemID: "legacy-1",
            legacySourceURL: "https://example.test/feed",
            record: try OriginRecordID(1),
            revision: try OriginRevisionID(1),
            confidence: .high,
            mappedAt: TestInstant.seconds(5)
        )
        try store.recordItemMapping(resolved, in: database)
        XCTAssertEqual(try store.itemMapping(forLegacyItemID: "legacy-1", in: database), resolved)
        XCTAssertNil(try store.itemMapping(forLegacyItemID: "legacy-unknown", in: database))
    }
}
