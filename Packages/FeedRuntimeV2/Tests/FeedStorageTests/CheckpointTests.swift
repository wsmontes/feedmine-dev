import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// The checkpoint is progress through an external stream, and it must never describe content the
/// runtime did not commit (I-11). These tests pin the CAS, the recovery path and the failure table
/// of ADR-006 step by step.
final class CheckpointTests: RuntimeV2TestCase {
    /// ADR-006's per-step table: a failure injected after any step must leave the database at its
    /// pre-transaction state, so the checkpoint can never be ahead of committed content.
    func testCheckpointNeverAdvancesPastCommittedProgress() throws {
        for step in 1...11 {
            let location = freshLocation(named: "step-\(step)")
            let database = try RuntimeDatabase(location: location)
            try registerTarget(in: database)
            let engine = AdmissionEngine(clock: fixedClock)
            let batch = try batch(
                id: "batch-\(step)",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1", headline: "Content")]
            )

            XCTAssertThrowsError(try database.write { database in
                do {
                    _ = try engine.apply(
                        batch,
                        in: database,
                        committedAt: TestInstant.epoch,
                        stopAfterStep: step
                    )
                    XCTFail("step \(step): the failure probe did not fire")
                } catch {
                    if step >= 5 {
                        XCTAssertEqual(
                            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM origin_revision"),
                            1,
                            "step \(step): the revision is staged before the failure"
                        )
                    }
                    throw error
                }
            })

            try assertPreTransactionState(in: database, label: "step \(step)")

            // The same file, opened by a later session, agrees.
            let reopened = try RuntimeDatabase(location: location)
            try assertPreTransactionState(in: reopened, label: "step \(step) reopened")

            // And the batch is still admissible: recovery is resumption, not a lost page.
            let receipt = try admitRequiringSuccess(batch, in: reopened)
            XCTAssertEqual(receipt.checkpointRevision, 1, "step \(step)")
            XCTAssertEqual(
                try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'", in: reopened),
                1,
                "step \(step): the checkpoint describes exactly the content admitted beside it"
            )
            XCTAssertEqual(try rowCount("origin_revision", in: reopened), 1, "step \(step)")
        }
    }

    func testCheckpointAdvancesOnlyUnderTheCASPredicate() throws {
        try registerTarget()
        // Every batch is built from the durable stamp, which is exactly what a connector does.
        for index in 1...3 {
            let stamp = try stamp()
            XCTAssertEqual(stamp.checkpointRevision, UInt64(index - 1))
            let key = "item-\(index)"
            let receipt = try admitRequiringSuccess(
                try batch(
                    id: "batch-\(index)",
                    generation: stamp.targetGeneration,
                    bindingRevision: stamp.bindingRevision,
                    leaseEpoch: stamp.leaseEpoch,
                    expectedCheckpoint: stamp.checkpointRevision,
                    observations: [try observation(object: key, version: "v\(index)", headline: key)]
                )
            )
            XCTAssertEqual(receipt.checkpointRevision, UInt64(index))
            XCTAssertEqual(
                try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'"),
                Int64(index)
            )
        }
        XCTAssertEqual(try stamp().checkpointRevision, 3)
    }

    /// A batch with nothing to resume from does not move the checkpoint: an absent next checkpoint is
    /// an absent advance, never an implied one.
    func testBatchWithoutANextCheckpointDoesNotAdvanceTheCheckpoint() throws {
        try registerTarget()
        let receipt = try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1")],
                advancesCheckpoint: false
            )
        )

        XCTAssertEqual(receipt.checkpointRevision, 0)
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'"),
            0
        )
        XCTAssertNil(try ledger.batch("batch-1", in: database)?.checkpointWritten)
        XCTAssertEqual(try rowCount("origin_revision"), 1, "the content is admitted; only the cursor stays")
        // The next batch is stamped against the unchanged checkpoint and is admitted normally.
        let next = try admitRequiringSuccess(
            try batch(
                id: "batch-2",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-2", version: "v2", headline: "Two")]
            )
        )
        XCTAssertEqual(next.checkpointRevision, 1)
    }

    func testCheckpointThatIsNoLongerCurrentIsReportedWithTheDurableRevision() throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1", headline: "One")]
            )
        )
        let before = try dump()

        // A connector that resets its cursor to an older value: the runtime never rewinds a
        // checkpoint implicitly, because rewinding is a new target decision.
        let rewound = try batch(
            id: "batch-rewound",
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-2", version: "v1", headline: "Two")]
        )
        let result = admit(rewound)

        XCTAssertEqual(result, .staleCheckpoint(expected: 0, actual: 1))
        XCTAssertEqual(try dump(), before)
        XCTAssertEqual(try rowCount("origin_record"), 1)
    }

    /// A commit whose response was lost is authoritative: a later session answers from durable state
    /// and a resend is a replay, with no second supply increment (ADR-006 D2, D9).
    func testCommittedAdmissionSurvivesLossOfInMemoryEvent() throws {
        let location = database.location
        try registerTarget()
        let batch = try batch(
            id: "batch-1",
            expectedCheckpoint: 0,
            observations: [try observation(object: "item-1", version: "v1", headline: "Committed")]
        )
        try admitRequiringSuccess(batch)
        let generation = try ledger.supplyGeneration(in: database)

        // The in-memory event never arrives; only the file is opened again.
        let reopened = try RuntimeDatabase(location: location)
        let receipt = try XCTUnwrap(try ledger.receipt(forBatchID: "batch-1", in: reopened))
        XCTAssertEqual(receipt.batchID, "batch-1")
        XCTAssertEqual(receipt.admittedRevisionCount, 1)
        XCTAssertEqual(try ledger.batch("batch-1", in: reopened)?.result, "admitted")

        XCTAssertEqual(admit(batch, in: reopened), .duplicate(batchID: "batch-1"))
        XCTAssertEqual(try ledger.supplyGeneration(in: reopened), generation)
        XCTAssertEqual(try rowCount("origin_revision", in: reopened), 1)
    }

    func testTargetLifecycleBumpsTheLeaseEpochOnlyOnARealStateChange() throws {
        let registered = try registerTarget()
        XCTAssertEqual(registered.state, .active)
        XCTAssertEqual(registered.generation, 1)
        XCTAssertEqual(registered.bindingRevision, 1)
        XCTAssertEqual(registered.leaseEpoch, 0)
        XCTAssertEqual(registered.checkpointRevision, 0)
        XCTAssertEqual(registered.checkpoint?.blob, nil)

        XCTAssertThrowsError(try registerTarget(), "operational identity is explicit") { error in
            XCTAssertEqual(error as? AcquisitionTargetError, .alreadyRegistered(AcquisitionTargetID("target-1")))
        }
        XCTAssertThrowsError(
            try targetStore.register(
                AcquisitionTargetID("target-blank-kind"),
                connectorKind: "",
                connectorVersion: "connector.test",
                in: database
            )
        ) { error in
            XCTAssertEqual(error as? AcquisitionTargetError, .emptyConnectorKind)
        }
        XCTAssertThrowsError(
            try targetStore.register(
                AcquisitionTargetID("target-blank-version"),
                connectorKind: "rss",
                connectorVersion: "",
                in: database
            )
        ) { error in
            XCTAssertEqual(error as? AdmissionContractError, .emptyConnectorVersion)
        }

        let unchanged = try targetStore.setState(.active, for: AcquisitionTargetID("target-1"), in: database)
        XCTAssertEqual(unchanged.leaseEpoch, 0, "a transition that changes nothing is not a new epoch")

        let disabled = try targetStore.setState(.disabled, for: AcquisitionTargetID("target-1"), in: database)
        XCTAssertEqual(disabled.leaseEpoch, 1)
        let revoked = try targetStore.setState(.revoked, for: AcquisitionTargetID("target-1"), in: database)
        XCTAssertEqual(revoked.leaseEpoch, 2)
        XCTAssertEqual(revoked.state, .revoked)

        XCTAssertNil(try targetStore.snapshot(for: AcquisitionTargetID("unknown"), in: database))
        XCTAssertThrowsError(
            try targetStore.setBindingRevision(0, for: AcquisitionTargetID("target-1"), in: database)
        )
        XCTAssertThrowsError(
            try targetStore.setState(.active, for: AcquisitionTargetID("unknown"), in: database)
        ) { error in
            XCTAssertEqual(error as? AcquisitionTargetError, .unknownTarget(AcquisitionTargetID("unknown")))
        }
    }
}
