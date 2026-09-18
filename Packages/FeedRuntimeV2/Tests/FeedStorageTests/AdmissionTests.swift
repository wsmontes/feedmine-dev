import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// Admission behaviour on a real database: what a batch is allowed to change, what a refusal leaves
/// behind, and which order the three orders (generation, checkpoint, editorial precedence) obey.
final class AdmissionTests: RuntimeV2TestCase {
    // MARK: - The admitted path

    func testAdmissionWritesCanonicalStateReceiptAndProjection() throws {
        let target = try registerTarget()
        XCTAssertEqual(target.checkpointRevision, 0)
        XCTAssertEqual(target.checkpoint?.blob, nil)
        let source = try insertSource()
        let membership = try MembershipClaim(sourceID: source, membershipKind: "editorial")
        let media = try MediaCandidateClaim(
            role: .image,
            resourceURL: "https://cdn.example.test/a.jpg",
            mediaTypeHint: "image/jpeg",
            pixelWidth: 1200,
            pixelHeight: 800
        )
        let offer = try InteractionOfferClaim(kind: "open", handle: "https://example.test/item-1")
        let provider = try ProviderClaim(
            namespace: ConnectorNamespace("connector.test"),
            providerKey: "author-1",
            displayName: "Author",
            role: .primary
        )
        let first = try observation(
            object: "item-1",
            version: "v1",
            headline: "First headline",
            excerpt: "Excerpt text",
            body: "Body text",
            link: "https://example.test/item-1",
            authoredAt: TestInstant.seconds(-600),
            provider: provider,
            memberships: [membership],
            media: [media],
            offers: [offer],
            observedAt: TestInstant.seconds(1)
        )
        let batch = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [first],
            evidence: [ConnectorEvidence(kind: .parsedEntry, digest: "digest-1", bytes: Data("raw".utf8))]
        )

        let result = admit(batch)

        guard case let .admitted(receipt) = result else {
            return XCTFail("expected admission, got \(result)")
        }
        XCTAssertEqual(
            receipt,
            AdmissionReceipt(
                batchID: "batch-1",
                admittedRevisionCount: 1,
                supplyGeneration: 1,
                checkpointRevision: 1,
                supplyChanged: true
            )
        )

        let recordID = try XCTUnwrap(try ledger.recordIDs(in: database).first)
        XCTAssertEqual(try ledger.revisionCount(ofRecord: recordID, in: database), 1)
        XCTAssertEqual(try ledger.currentRevisionID(ofRecord: recordID, in: database)?.rawValue, 1)
        XCTAssertEqual(try ledger.supplyGeneration(in: database), 1)
        XCTAssertEqual(try rowCount("origin_record"), 1)
        XCTAssertEqual(try rowCount("external_identity"), 2, "the object key and the version key")
        XCTAssertEqual(try rowCount("selection_supply"), 1)
        XCTAssertEqual(try rowCount("source_membership"), 1)
        XCTAssertEqual(try rowCount("provider_attribution"), 1)
        XCTAssertEqual(try rowCount("media_candidate"), 1)
        XCTAssertEqual(try rowCount("interaction_offer"), 1)
        XCTAssertEqual(try rowCount("connector_evidence"), 1)
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'"),
            1
        )
        XCTAssertEqual(
            try string("SELECT origin_revision_id FROM selection_supply"),
            "1",
            "supply names the revision that is current in the same snapshot"
        )
        XCTAssertEqual(
            try scalar("SELECT published_at_claim FROM selection_supply"),
            Int64(TestInstant.seconds(-600).timeIntervalSince1970 * 1000),
            "a declared authored date is stored as the publication claim"
        )
        XCTAssertEqual(
            try string("SELECT primary_link FROM origin_revision WHERE id = 1"),
            "https://example.test/item-1"
        )
        XCTAssertEqual(
            try ledger.searchProjection(ofRecord: recordID, in: database),
            "First headline\nExcerpt text\nBody text"
        )

        // The receipt is durable, and the fingerprint the runtime persisted is its own digest.
        let stored = try XCTUnwrap(try ledger.receipt(forBatchID: "batch-1", in: database))
        XCTAssertEqual(stored, receipt)
        let storedBatch = try XCTUnwrap(try ledger.batch("batch-1", in: database))
        XCTAssertEqual(storedBatch.fingerprint, BatchFingerprint.of(batch))
        XCTAssertEqual(storedBatch.checkpointExpected, 0)
        XCTAssertEqual(storedBatch.checkpointWritten, 1)
        XCTAssertEqual(storedBatch.observationCount, 1)
        XCTAssertEqual(storedBatch.result, "admitted")
        XCTAssertEqual(storedBatch.committedAt, TestInstant.epoch)
        XCTAssertEqual(try ledger.evidence(forBatchID: "batch-1", in: database).first?.digest, "digest-1")
    }

    func testSameExternalKeyResolvesSameRecord() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1", headline: "One")]
            )
        )

        let second = try observation(
            object: "item-1",
            version: "v2",
            precedence: .makeCurrent(expectedRevision: try OriginRevisionID(1)),
            headline: "Two"
        )
        try admitRequiringSuccess(try batch(id: "batch-2", expectedCheckpoint: 1, observations: [second]))

        XCTAssertEqual(try rowCount("origin_record"), 1, "the full key resolves the same logical object")
        XCTAssertEqual(try rowCount("origin_revision"), 2)
        XCTAssertEqual(try rowCount("external_identity WHERE key_kind = 'object'"), 1)
        XCTAssertEqual(try rowCount("external_identity WHERE key_kind = 'version'"), 2)
        let recordID = try XCTUnwrap(try ledger.recordIDs(in: database).first)
        XCTAssertEqual(try ledger.currentRevisionID(ofRecord: recordID, in: database)?.rawValue, 2)
    }

    func testOneBatchCanCarryTwoVersionsOfOneObject() throws {
        try registerTarget()
        let older = try observation(
            object: "item-1",
            version: "v1",
            precedence: .historicalOnly,
            headline: "Older",
            observedAt: TestInstant.seconds(1)
        )
        let newer = try observation(
            object: "item-1",
            version: "v2",
            precedence: .makeCurrent(expectedRevision: nil),
            headline: "Newer",
            observedAt: TestInstant.seconds(2)
        )

        let receipt = try admitRequiringSuccess(
            try batch(id: "batch-1", expectedCheckpoint: 0, observations: [older, newer])
        )

        XCTAssertEqual(receipt.admittedRevisionCount, 2)
        XCTAssertEqual(try rowCount("origin_record"), 1, "one object key, even appearing twice in one batch")
        XCTAssertEqual(try rowCount("origin_revision"), 2)
        XCTAssertEqual(try string("SELECT current_revision_id FROM origin_record"), "2")
    }

    // MARK: - Refusals leave nothing behind

    func testInvalidBatchDoesNotMutateCanonicalState() throws {
        try registerTarget()
        let source = try insertSource()
        let membership = try MembershipClaim(sourceID: source, membershipKind: "editorial")
        try admitRequiringSuccess(
            try batch(
                id: "batch-ok",
                expectedCheckpoint: 0,
                observations: [
                    try observation(
                        object: "item-1",
                        version: "v1",
                        memberships: [membership]
                    )
                ]
            )
        )
        let before = try dump()

        // (a) an invalid observation: a low-confidence identity that names no versioned scheme.
        let invalid = try observation(
            object: "item-2",
            version: "v1",
            confidence: .low,
            fallbackSchemeVersion: nil
        )
        let invalidResult = admit(try batch(id: "batch-invalid", expectedCheckpoint: 1, observations: [invalid]))
        guard case .invalidObservation = invalidResult else {
            return XCTFail("expected invalidObservation, got \(invalidResult)")
        }

        // (b) a bad schema: a version key from a scope its object key does not live in.
        let crossScoped = try observation(
            object: "item-3",
            version: "v1",
            versionInScope: "another-feed",
            namespace: "connector.test"
        )
        let schemaResult = admit(try batch(id: "batch-schema", expectedCheckpoint: 1, observations: [crossScoped]))
        guard case .invalidObservation = schemaResult else {
            return XCTFail("expected invalidObservation, got \(schemaResult)")
        }

        // (c) a stamp that no longer matches the durable target.
        let stale = try batch(
            id: "batch-stale",
            leaseEpoch: 1,
            expectedCheckpoint: 1,
            observations: [try observation(object: "item-4", version: "v1")]
        )
        guard case .staleTarget = admit(stale) else {
            return XCTFail("expected staleTarget for a stamp the target does not carry")
        }

        // (d) a stamp from another target generation.
        let wrongGeneration = try batch(
            id: "batch-generation",
            generation: 2,
            expectedCheckpoint: 1,
            observations: [try observation(object: "item-5", version: "v1")]
        )
        guard case .staleTarget = admit(wrongGeneration) else {
            return XCTFail("expected staleTarget for work from another generation")
        }

        XCTAssertEqual(try dump(), before, "no refusal may mutate canonical state")
    }

    func testRevokedStreamCannotMutateSupply() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1", headline: "Admitted")]
            )
        )
        _ = try targetStore.setState(.revoked, for: AcquisitionTargetID("target-1"), in: database)
        // The revocation itself is the only change; nothing canonical may follow it.
        let before = try dump(Self.canonicalTables.filter { $0 != "acquisition_target" })

        let late = try batch(
            id: "batch-late",
            expectedCheckpoint: 1,
            observations: [try observation(object: "item-2", version: "v1", headline: "Late")]
        )

        guard case let .staleTarget(generation) = admit(late) else {
            return XCTFail("a stream event after revocation must be stale work")
        }
        XCTAssertEqual(generation, 1)
        XCTAssertEqual(try dump(Self.canonicalTables.filter { $0 != "acquisition_target" }), before)
        XCTAssertEqual(try rowCount("origin_record"), 1)
        XCTAssertEqual(try rowCount("origin_revision"), 1)
        XCTAssertEqual(try ledger.supplyGeneration(in: database), 1)
    }

    func testDisableThenReenableRejectsOldFiniteResult() throws {
        try registerTarget()
        _ = try targetStore.setState(.disabled, for: AcquisitionTargetID("target-1"), in: database)
        let reenabled = try targetStore.setState(.active, for: AcquisitionTargetID("target-1"), in: database)
        XCTAssertEqual(reenabled.leaseEpoch, 2, "disable and re-enable are two transitions, two epochs")
        let before = try dump(Self.canonicalTables.filter { $0 != "acquisition_target" })

        let finite = try batch(
            id: "batch-finite",
            leaseEpoch: 0,
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-1", version: "v1")]
        )

        guard case .staleTarget = admit(finite) else {
            return XCTFail("a finite result produced before the flip must be stale")
        }
        XCTAssertEqual(try dump(Self.canonicalTables.filter { $0 != "acquisition_target" }), before)
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'"),
            0,
            "stale work never advances the checkpoint"
        )

        // Work produced under the new epoch is admitted normally.
        try admitRequiringSuccess(
            try batch(
                id: "batch-fresh",
                leaseEpoch: 2,
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1")]
            )
        )
        XCTAssertEqual(try rowCount("origin_revision"), 1)
    }

    func testContextEpochABARejectsStaleEpochWork() throws {
        try registerTarget()
        // Context A runs at epoch 0.
        try admitRequiringSuccess(
            try batch(
                id: "batch-a1",
                leaseEpoch: 0,
                expectedCheckpoint: 0,
                observations: [try observation(object: "a-1", version: "va1")]
            )
        )
        // Context B takes the target over, then A comes back: two transitions, two epochs.
        _ = try targetStore.setState(.disabled, for: AcquisitionTargetID("target-1"), in: database)
        try admitRequiringSuccess(
            try batch(
                id: "batch-b1",
                leaseEpoch: 1,
                expectedCheckpoint: 1,
                observations: [try observation(object: "b-1", version: "vb1")]
            )
        )
        _ = try targetStore.setState(.active, for: AcquisitionTargetID("target-1"), in: database)
        let before = try dump(Self.canonicalTables.filter { $0 != "acquisition_target" })

        // A's late work still carries the first A epoch.
        let late = try batch(
            id: "batch-a2",
            leaseEpoch: 0,
            expectedCheckpoint: 2,
            observations: [try observation(object: "a-2", version: "va2")]
        )

        guard case .staleTarget = admit(late) else {
            return XCTFail("an A → B → A epoch sequence must reject the first A's late work")
        }
        XCTAssertEqual(try dump(Self.canonicalTables.filter { $0 != "acquisition_target" }), before)
        XCTAssertEqual(try rowCount("origin_record"), 2, "B's content stays, A's late content does not arrive")

        // A's current epoch works.
        try admitRequiringSuccess(
            try batch(
                id: "batch-a3",
                leaseEpoch: 2,
                expectedCheckpoint: 2,
                observations: [try observation(object: "a-3", version: "va3")]
            )
        )
        XCTAssertEqual(try rowCount("origin_record"), 3)
    }

    func testStaleWorkCannotUpdateMembershipOrCheckpoint() throws {
        try registerTarget()
        let source = try insertSource()
        let membership = try MembershipClaim(
            sourceID: source,
            membershipKind: "editorial",
            binding: SourceBindingKey(
                namespace: ConnectorNamespace("connector.test"),
                bindingKey: "binding-1"
            ),
            bindingGeneration: 3
        )
        let other = try ExternalObjectKey(scope: testScope(), text: "item-1")
        let claimed = try observation(
            object: "item-1",
            version: "v1",
            memberships: [membership],
            relations: [RelationClaim(verb: .replyTo, target: other)],
            media: [try MediaCandidateClaim(role: .poster, resourceURL: "https://cdn.example.test/p.jpg")],
            offers: [try InteractionOfferClaim(kind: "play", handle: "handle-1")]
        )
        let stale = try batch(
            id: "batch-stale",
            leaseEpoch: 1,
            expectedCheckpoint: 0,
            observations: [claimed]
        )

        guard case .staleTarget = admit(stale) else {
            return XCTFail("a stamp from another epoch is stale work")
        }

        for table in [
            "origin_record", "origin_revision", "external_identity", "source_membership",
            "provider_attribution", "content_relation", "media_candidate", "interaction_offer",
            "selection_supply", "admission_batch", "connector_evidence", "identity_conflict",
        ] {
            XCTAssertEqual(try rowCount(table), 0, "\(table) must stay untouched by stale work")
        }
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'"),
            0
        )
        XCTAssertEqual(try ledger.supplyGeneration(in: database), 0)
        XCTAssertEqual(try rowCount("origin_search"), 0)
        // The only permitted residue is the target row itself, and it was not the batch that wrote it.
        XCTAssertEqual(try string("SELECT state FROM acquisition_target WHERE id = 'target-1'"), "active")
    }

    func testBindingChangeInvalidatesOldGeneration() throws {
        try registerTarget()
        let rebound = try targetStore.setBindingRevision(2, for: AcquisitionTargetID("target-1"), in: database)
        XCTAssertEqual(rebound.bindingRevision, 2)
        let before = try dump(Self.canonicalTables.filter { $0 != "acquisition_target" })

        let oldBinding = try batch(
            id: "batch-old",
            bindingRevision: 1,
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-1", version: "v1")]
        )

        guard case .staleTarget = admit(oldBinding) else {
            return XCTFail("work from the previous binding revision must be refused at commit")
        }
        XCTAssertEqual(try dump(Self.canonicalTables.filter { $0 != "acquisition_target" }), before)

        try admitRequiringSuccess(
            try batch(
                id: "batch-new",
                bindingRevision: 2,
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1")]
            )
        )
        XCTAssertEqual(try rowCount("origin_revision"), 1)
    }

    // MARK: - Precedence

    func testOlderRevisionRemainsHistoricalAfterNewerCurrent() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v2", headline: "Current")]
            )
        )
        let recordID = try XCTUnwrap(try ledger.recordIDs(in: database).first)

        let older = try observation(
            object: "item-1",
            version: "v1",
            precedence: .historicalOnly,
            headline: "Older",
            observedAt: TestInstant.seconds(5)
        )
        let receipt = try admitRequiringSuccess(
            try batch(id: "batch-2", expectedCheckpoint: 1, observations: [older])
        )

        XCTAssertEqual(receipt.admittedRevisionCount, 1, "the representation is preserved as a revision")
        XCTAssertFalse(receipt.supplyChanged, "an older revision that does not become current changes no supply")
        XCTAssertEqual(receipt.checkpointRevision, 2, "the checkpoint may advance on a historical-only batch")
        XCTAssertEqual(try ledger.revisionCount(ofRecord: recordID, in: database), 2)
        XCTAssertEqual(
            try ledger.currentRevisionID(ofRecord: recordID, in: database)?.rawValue,
            1,
            "a backfilled older revision never moves the current pointer"
        )
        XCTAssertEqual(try string("SELECT origin_revision_id FROM selection_supply"), "1")
        XCTAssertEqual(try ledger.searchProjection(ofRecord: recordID, in: database), "Current")

        let newer = try observation(
            object: "item-1",
            version: "v3",
            precedence: .makeCurrent(expectedRevision: try OriginRevisionID(1)),
            headline: "Newer",
            observedAt: TestInstant.seconds(10)
        )
        let second = try admitRequiringSuccess(
            try batch(id: "batch-3", expectedCheckpoint: 2, observations: [newer])
        )

        XCTAssertTrue(second.supplyChanged)
        XCTAssertEqual(try ledger.currentRevisionID(ofRecord: recordID, in: database)?.rawValue, 3)
        XCTAssertEqual(try string("SELECT origin_revision_id FROM selection_supply"), "3")
        XCTAssertEqual(try ledger.searchProjection(ofRecord: recordID, in: database), "Newer")
        XCTAssertEqual(try ledger.supplyGeneration(in: database), 2)
    }

    func testCurrentPointerMovesOnlyAgainstTheExpectedRevision() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1", headline: "One")]
            )
        )
        // The connector believes revision 7 is current. It is not, so the CAS fails and the
        // representation is preserved without overwriting what the runtime holds.
        let mistaken = try observation(
            object: "item-1",
            version: "v2",
            precedence: .makeCurrent(expectedRevision: try OriginRevisionID(7)),
            headline: "Two"
        )
        let receipt = try admitRequiringSuccess(
            try batch(id: "batch-2", expectedCheckpoint: 1, observations: [mistaken])
        )

        XCTAssertEqual(receipt.admittedRevisionCount, 1)
        XCTAssertFalse(receipt.supplyChanged)
        XCTAssertEqual(try string("SELECT current_revision_id FROM origin_record"), "1")
        XCTAssertEqual(try rowCount("origin_revision"), 2)
        XCTAssertEqual(try string("SELECT headline FROM origin_revision WHERE id = 1"), "One")
    }

    func testReAdmittingTheSameRepresentationMovesNothingAndChangesNoSupply() throws {
        try registerTarget()
        let first = try observation(object: "item-1", version: "v1", headline: "One")
        try admitRequiringSuccess(try batch(id: "batch-1", expectedCheckpoint: 0, observations: [first]))
        let before = try dump(["origin_revision", "selection_supply", "supply_generation"])

        // A new batch, a new observation of the same representation, and the connector asserts it
        // should be current — which it already is. Nothing moves and no supply generation is spent.
        let again = try observation(
            object: "item-1",
            version: "v1",
            precedence: .makeCurrent(expectedRevision: try OriginRevisionID(1)),
            headline: "One",
            observedAt: TestInstant.seconds(60)
        )
        let receipt = try admitRequiringSuccess(
            try batch(id: "batch-2", expectedCheckpoint: 1, observations: [again])
        )

        XCTAssertEqual(receipt.admittedRevisionCount, 0)
        XCTAssertFalse(receipt.supplyChanged)
        XCTAssertEqual(try ledger.supplyGeneration(in: database), 1)
        XCTAssertEqual(try rowCount("origin_revision"), 1)
        XCTAssertEqual(try string("SELECT current_revision_id FROM origin_record"), "1")
        XCTAssertEqual(try rowCount("selection_supply"), 1)
        XCTAssertEqual(
            try dump(["origin_revision", "selection_supply", "supply_generation"]),
            before,
            "no revision, no projection row and no supply generation"
        )
        // The only things that legitimately move are the observation high-water marks, which are
        // observation metadata and never a supply event (ADR-003 D17).
        let observedAt = Int64(TestInstant.seconds(60).timeIntervalSince1970 * 1000)
        XCTAssertEqual(try scalar("SELECT last_observed_at FROM origin_record"), observedAt)
        XCTAssertEqual(
            try scalar("SELECT last_observed_at FROM external_identity WHERE key_kind = 'version'"),
            observedAt
        )
        XCTAssertEqual(
            try scalar("SELECT observed_at FROM origin_revision"),
            Int64(TestInstant.epoch.timeIntervalSince1970 * 1000),
            "the stored representation keeps its own observation time"
        )
    }

    func testDuplicateObservationInstructionDoesNotCreateRevisionOrSupplyChange() throws {
        try registerTarget()
        let source = try insertSource()
        let membership = try MembershipClaim(sourceID: source, membershipKind: "editorial")
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [
                    try observation(
                        object: "item-1",
                        version: "v1",
                        memberships: [membership]
                    )
                ]
            )
        )
        let supplyRevisionBefore = try string("SELECT origin_revision_id FROM selection_supply")

        let duplicate = try observation(
            object: "item-1",
            version: "v1",
            precedence: .duplicate,
            observedAt: TestInstant.seconds(30)
        )
        let receipt = try admitRequiringSuccess(
            try batch(id: "batch-2", expectedCheckpoint: 1, observations: [duplicate])
        )

        XCTAssertEqual(receipt.admittedRevisionCount, 0)
        XCTAssertFalse(receipt.supplyChanged)
        XCTAssertEqual(receipt.checkpointRevision, 2, "the connector did make progress through the stream")
        XCTAssertEqual(try rowCount("origin_revision"), 1)
        XCTAssertEqual(try ledger.supplyGeneration(in: database), 1)
        XCTAssertEqual(try string("SELECT origin_revision_id FROM selection_supply"), supplyRevisionBefore)
    }

    // MARK: - Batch identity

    func testReplayedBatchDoesNotIncrementSupplyGeneration() throws {
        try registerTarget()
        let replayable = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-1", version: "v1", headline: "One")]
        )
        try admitRequiringSuccess(replayable)
        let generationAfterCommit = try ledger.supplyGeneration(in: database)
        let before = try dump()

        let replay = admit(replayable)

        XCTAssertEqual(replay, .duplicate(batchID: "batch-1"))
        XCTAssertEqual(try ledger.supplyGeneration(in: database), generationAfterCommit)
        XCTAssertEqual(try dump(), before)
        XCTAssertEqual(
            try ledger.receipt(forBatchID: "batch-1", in: database)?.batchID,
            "batch-1",
            "a retry after a lost response is answered from durable state"
        )
    }

    func testDuplicateEventDeliveryDoesNotDoubleApplyCanonicalMutation() throws {
        try registerTarget()
        let source = try insertSource()
        let membership = try MembershipClaim(sourceID: source, membershipKind: "editorial")
        let target = try ExternalObjectKey(scope: testScope(), text: "item-1")
        let delivered = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [
                try observation(
                    object: "item-1",
                    version: "v1",
                    provider: try ProviderClaim(
                        namespace: ConnectorNamespace("connector.test"),
                        providerKey: "author-1",
                        displayName: "Author",
                        role: .primary
                    ),
                    memberships: [membership],
                    relations: [RelationClaim(verb: .references, target: target)],
                    media: [try MediaCandidateClaim(role: .thumbnail, resourceURL: "https://cdn.example.test/t.jpg")],
                    offers: [try InteractionOfferClaim(kind: "open")]
                )
            ]
        )
        try admitRequiringSuccess(delivered)
        let before = try dump()

        let secondDelivery = admit(delivered)

        XCTAssertEqual(secondDelivery, .duplicate(batchID: "batch-1"))
        XCTAssertEqual(try dump(), before, "the second delivery adds no revision, membership, relation or offer")
        XCTAssertEqual(try rowCount("origin_revision"), 1)
        XCTAssertEqual(try rowCount("source_membership"), 1)
        XCTAssertEqual(try rowCount("content_relation"), 1)
        XCTAssertEqual(try ledger.supplyGeneration(in: database), 1)
    }

    /// The ledger key moves with the lease epoch and with the batch's position, and carries no
    /// runtime-derived expectation.
    ///
    /// Both halves are measured findings (§8.55). The lease half is the production defect: every launch
    /// acquires a fresh lease epoch, and the key the connectors used —
    /// `target#generation#observations` — ignored it, so a launch presented the same key with a
    /// different body and Admission answered `batchConflict` for its own re-delivery. The other half is
    /// the opposite error, and the reason the first fix of that defect could not ship: the expected
    /// checkpoint revision is derived from the durable row *and advances as a consequence of admitting
    /// the batch*, so keying on it made one episode admit the same page 24 times, bounded only by the
    /// request budget. The parameter list is the contract: `ledgerID` cannot express an expectation.
    func testTheLedgerKeyCoversTheLeaseAndThePositionAndNoExpectation() throws {
        let target = AcquisitionTargetID("target-1")
        let checkpoint = try ConnectorCheckpoint(
            blob: Data("v1".utf8),
            serializationSchema: 1,
            connectorVersion: "connector.test"
        )
        func key(leaseEpoch: UInt64, nextCheckpoint: ConnectorCheckpoint?) -> String {
            AcquisitionBatch.ledgerID(
                targetID: target,
                generation: 1,
                bindingRevision: 1,
                leaseEpoch: leaseEpoch,
                contentFingerprint: String(repeating: "a", count: 64),
                observations: [],
                nextCheckpoint: nextCheckpoint
            )
        }

        XCTAssertNotEqual(
            key(leaseEpoch: 1, nextCheckpoint: checkpoint),
            key(leaseEpoch: 2, nextCheckpoint: checkpoint),
            "a new lease epoch is a new batch: the launch that acquires one must not be refused"
        )
        XCTAssertNotEqual(
            key(leaseEpoch: 1, nextCheckpoint: checkpoint),
            key(leaseEpoch: 1, nextCheckpoint: nil),
            "where the stream resumes after the batch is part of what the batch is"
        )
    }

    func testDuplicateBatchIdWithDifferentFingerprintIsRejected() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1", headline: "One")]
            )
        )
        let before = try dump()

        let divergentBody = try batch(
            id: "batch-1",
            expectedCheckpoint: 1,
            observations: [try observation(object: "item-2", version: "v1", headline: "Two")]
        )
        let result = admit(divergentBody)

        XCTAssertEqual(result, .batchConflict(batchID: "batch-1"))
        XCTAssertEqual(try dump(), before)
        XCTAssertEqual(try rowCount("origin_record"), 1)
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'"),
            1
        )
    }

    // MARK: - Identity conflicts

    func testVersionCollisionIsAuditedNotOverwritten() throws {
        try registerTarget()
        let original = try observation(
            object: "item-1",
            version: "v1",
            headline: "Original",
            body: "First body"
        )
        try admitRequiringSuccess(try batch(id: "batch-1", expectedCheckpoint: 0, observations: [original]))
        let before = try dump(Self.canonicalTables.filter { $0 != "identity_conflict" })
        let recordID = try XCTUnwrap(try ledger.recordIDs(in: database).first)

        let divergent = try observation(
            object: "item-1",
            version: "v1",
            headline: "Rewritten",
            body: "Second body",
            observedAt: TestInstant.seconds(10)
        )
        let result = admit(try batch(id: "batch-2", expectedCheckpoint: 1, observations: [divergent]))

        guard case let .identityConflict(key) = result else {
            return XCTFail("a divergent payload under a used version key is a conflict, got \(result)")
        }
        XCTAssertEqual(key.bytes, Data("item-1".utf8))

        // The stored revision is preserved byte for byte, and no second revision appears.
        XCTAssertEqual(try string("SELECT headline FROM origin_revision WHERE id = 1"), "Original")
        XCTAssertEqual(try string("SELECT body_text FROM origin_revision WHERE id = 1"), "First body")
        XCTAssertEqual(try rowCount("origin_revision"), 1)
        XCTAssertEqual(try ledger.currentRevisionID(ofRecord: recordID, in: database)?.rawValue, 1)

        // The contradiction is auditable, with both digests.
        XCTAssertEqual(try rowCount("identity_conflict"), 1)
        XCTAssertEqual(try string("SELECT conflict_kind FROM identity_conflict"), "version_payload_divergence")
        let detailJSON = try XCTUnwrap(try string("SELECT detail_json FROM identity_conflict"))
        let detail = try JSONDecoder().decode(ConflictDetail.self, from: Data(detailJSON.utf8))
        XCTAssertEqual(
            detail.storedPayloadDigest,
            PayloadDigest.of(original.payload).bytes.base64EncodedString()
        )
        XCTAssertEqual(
            detail.incomingPayloadDigest,
            PayloadDigest.of(divergent.payload).bytes.base64EncodedString()
        )
        XCTAssertNotEqual(detail.storedPayloadDigest, detail.incomingPayloadDigest)

        // No canonical mutation and no checkpoint advance: only the audit row is written.
        XCTAssertEqual(try dump(Self.canonicalTables.filter { $0 != "identity_conflict" }), before)
    }

    func testAmbiguousAliasDoesNotMergeOrigins() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "shared-version")]
            )
        )
        let before = try dump(Self.canonicalTables.filter { $0 != "identity_conflict" })

        // Another object claims a version key that already belongs to the first record.
        let claimant = try observation(object: "item-2", version: "shared-version")
        let result = admit(try batch(id: "batch-2", expectedCheckpoint: 1, observations: [claimant]))

        guard case let .identityConflict(key) = result else {
            return XCTFail("an alias claimed by two records is a conflict, got \(result)")
        }
        XCTAssertEqual(key.bytes, Data("item-2".utf8))
        XCTAssertEqual(try rowCount("identity_conflict"), 1)
        XCTAssertEqual(try string("SELECT conflict_kind FROM identity_conflict"), "ambiguous_alias")
        XCTAssertEqual(try rowCount("origin_record"), 1, "neither record is merged and no record is invented")
        XCTAssertEqual(try dump(Self.canonicalTables.filter { $0 != "identity_conflict" }), before)
    }

    /// Claims and checkpoints refuse the shapes that cannot be persisted, instead of reaching SQL
    /// and failing there as a constraint error (D16, ADR-003 D5, Blueprint §49, §62).
    func testClaimsAndCheckpointsRefuseUnusableInput() throws {
        let source = try insertSource()
        let binding = SourceBindingKey(
            namespace: ConnectorNamespace("connector.test"),
            bindingKey: "binding-1"
        )

        XCTAssertThrowsError(try MembershipClaim(sourceID: source, membershipKind: "")) { error in
            XCTAssertEqual(error as? AdmissionContractError, .emptyMembershipKind)
        }
        XCTAssertThrowsError(
            try MembershipClaim(sourceID: source, membershipKind: "editorial", bindingGeneration: 2)
        ) { error in
            XCTAssertEqual(error as? AdmissionContractError, .bindingGenerationWithoutBinding)
        }
        XCTAssertThrowsError(
            try MediaCandidateClaim(role: .image, resourceURL: "", position: 0)
        ) { error in
            XCTAssertEqual(error as? AdmissionContractError, .emptyMediaResourceURL)
        }
        XCTAssertThrowsError(
            try MediaCandidateClaim(role: .image, resourceURL: "https://cdn.example.test/a.jpg", position: -1)
        ) { error in
            XCTAssertEqual(error as? AdmissionContractError, .negativeMediaPosition(-1))
        }
        XCTAssertThrowsError(try InteractionOfferClaim(kind: "")) { error in
            XCTAssertEqual(error as? AdmissionContractError, .emptyOfferKind)
        }
        XCTAssertThrowsError(
            try ConnectorCheckpoint(blob: nil, serializationSchema: 0, connectorVersion: "connector.test")
        ) { error in
            XCTAssertEqual(error as? AdmissionContractError, .nonPositiveCheckpointSchema(0))
        }

        // A valid claim of each kind still constructs, including the acquisition-backed membership.
        let backed = try MembershipClaim(
            sourceID: source,
            membershipKind: "editorial",
            binding: binding,
            bindingGeneration: 2
        )
        XCTAssertEqual(backed.bindingGeneration, 2)
    }

    /// The rollback proof of plan §7: a transaction that fails after the revision insert leaves no
    /// revision, no supply row and no checkpoint advance, and reopening the file shows the state the
    /// database had before the transaction started.
    func testTransactionFailureAfterRevisionInsertLeavesNothingBehind() throws {
        let location = freshLocation(named: "rollback")
        let database = try RuntimeDatabase(location: location)
        try registerTarget(in: database)
        let batch = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-1", version: "v1", headline: "Rolled back")]
        )
        let before = try dump(in: database)

        XCTAssertThrowsError(try database.write { database in
            do {
                _ = try engine.apply(
                    batch,
                    in: database,
                    committedAt: TestInstant.epoch,
                    stopAfterStep: 5
                )
                XCTFail("the failure probe did not fire")
            } catch {
                // The revision really was staged before the failure arrived, and the projection was
                // not: this is a rollback, not an empty transaction.
                XCTAssertEqual(
                    try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM origin_revision"),
                    1,
                    "step 5 writes the revision"
                )
                XCTAssertEqual(
                    try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM selection_supply"),
                    0,
                    "the projection is written at step 8"
                )
                throw error
            }
        })

        XCTAssertEqual(try dump(in: database), before)
        try assertPreTransactionState(in: database, label: "after rollback")

        // Nothing survives in the file either: a later session reads the pre-transaction state.
        let reopened = try RuntimeDatabase(location: location)
        XCTAssertEqual(try dump(in: reopened), before)
        try assertPreTransactionState(in: reopened, label: "after reopen")
        XCTAssertNil(try ledger.receipt(forBatchID: "batch-1", in: reopened))

        // The batch was never admitted, so it is admitted normally afterwards.
        let receipt = try admitRequiringSuccess(batch, in: reopened)
        XCTAssertEqual(receipt.admittedRevisionCount, 1)
        XCTAssertEqual(try rowCount("origin_revision", in: reopened), 1)
    }

    func testLowConfidenceIdentityIsPersistedWithItsFallbackSchemeVersion() throws {
        try registerTarget()
        let fallback = try FallbackIdentityScheme(version: 1)
        let key = try fallback.key(
            scope: testScope(),
            title: "Headline",
            authoredAt: nil,
            disambiguator: "disambiguator-1"
        )
        let observation = AcquisitionObservation(
            externalKey: key,
            versionKey: nil,
            precedence: .makeCurrent(expectedRevision: nil),
            payload: ObservationPayload(
                headline: "Headline",
                link: nil,
                excerpt: nil,
                body: nil,
                authoredAt: nil,
                modifiedAt: nil,
                observedAt: TestInstant.epoch
            ),
            identityConfidence: .low,
            fallbackSchemeVersion: fallback.version
        )

        try admitRequiringSuccess(try batch(id: "batch-1", expectedCheckpoint: 0, observations: [observation]))

        XCTAssertEqual(try string("SELECT identity_confidence FROM external_identity"), "low")
        XCTAssertEqual(try string("SELECT fallback_scheme_version FROM external_identity"), "1")
        XCTAssertEqual(try string("SELECT identity_confidence FROM origin_revision"), "low")
        XCTAssertEqual(try string("SELECT fallback_scheme_version FROM origin_revision"), "1")
        XCTAssertEqual(
            try string("SELECT primary_link IS NULL FROM origin_revision"),
            "1",
            "a missing primary link is admissible and is never synthesized"
        )
    }
}
