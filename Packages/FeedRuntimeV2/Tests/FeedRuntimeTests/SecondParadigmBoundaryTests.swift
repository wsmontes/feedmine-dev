import XCTest
import FeedDomain
import FeedStorage
import FeedRuntime

/// The second paradigm: a versioned streaming connector with relations, provenance, offers and a
/// discontinuity, running through the runtime that was already there.
///
/// The two connectors are different ecosystems — a finite paginated one and a live versioned one —
/// and nothing between the connector and canonical state knows which is which. That is proved twice
/// over: the same code path runs both, and the same content delivered by either one leaves
/// byte-identical canonical state (ADR-005 D2, D18; plan §19 #40).
final class SecondParadigmBoundaryTests: AcquisitionTestCase {
    private func shape(memberships: [SourceID]) -> FixtureObservationShape {
        FixtureObservationShape(
            memberships: memberships,
            relations: [FixtureRelation(verb: .references, object: "obj-001")],
            offerKinds: ["bookmark", "share"],
            mediaRoles: [.thumbnail, .audio],
            providerKey: "provider-1",
            excerpt: "An excerpt"
        )
    }

    private func demand(deficit: Int = 2) -> AcquisitionDemand {
        AcquisitionDemand(
            purpose: .bootstrap,
            holderID: "second-paradigm",
            deficit: SupplyDeficit(items: deficit),
            deadline: FixtureInstant.seconds(120)
        )
    }

    /// One call, whichever connector is behind it: the runtime has no protocol branch to take.
    private func run(
        _ connector: any AcquisitionSource,
        target: AcquisitionTarget,
        in database: RuntimeDatabase,
        deficit: Int = 2
    ) async -> AcquisitionRunSummary {
        let coordinator = AcquisitionCoordinator(
            resolver: AcquisitionSourceResolver.mapping([target.id: connector]),
            targetStore: targetStore,
            engine: engine,
            clock: clock
        )
        return await coordinator.run(demand(deficit: deficit), catalogue: [target], in: database)
    }

    /// `versionedStreamingConnectorUsesUnchangedRuntime` (plan §19 #40; `invariant 18`, `I-03`).
    ///
    /// The same content through the finite connector and through the versioned streaming one:
    /// identical summaries, identical canonical state, and the streaming side's relations,
    /// provenance, media and offers all stored. A discontinuity in that stream then keeps the
    /// durable checkpoint as the resume point.
    func testVersionedStreamingConnectorUsesUnchangedRuntime() async throws {
        let finiteDatabase = try freshDatabase(named: "finite")
        let streamingDatabase = try freshDatabase(named: "streaming")

        let finiteSources = [
            try insertSource("catalog:alpha", in: finiteDatabase),
            try insertSource("catalog:beta", in: finiteDatabase),
        ]
        let streamingSources = [
            try insertSource("catalog:alpha", in: streamingDatabase),
            try insertSource("catalog:beta", in: streamingDatabase),
        ]
        try registerTarget("shared-work", in: finiteDatabase)
        try registerTarget("shared-work", in: streamingDatabase)

        let finiteTarget = try acquisitionTarget("shared-work", in: finiteDatabase)
        let streamingTarget = try acquisitionTarget("shared-work", in: streamingDatabase)

        let finiteConnector = FakeFiniteConnector(
            target: finiteTarget,
            script: FakeFiniteConnector.Script(
                pages: [["obj-001"], ["obj-002"]],
                shape: shape(memberships: finiteSources)
            )
        )
        // The streaming connector reads on: after the two mirrored bursts comes a discontinuity and
        // the content that follows the reconnection.
        let streamingConnector = FakeStreamingConnector(
            target: streamingTarget,
            script: [.burst(["obj-001"]), .burst(["obj-002"]), .discontinuity, .burst(["obj-003"])],
            capacity: 2,
            shape: shape(memberships: streamingSources)
        )

        let finiteSummary = await run(finiteConnector, target: finiteTarget, in: finiteDatabase)
        let streamingSummary = await run(streamingConnector, target: streamingTarget, in: streamingDatabase)

        XCTAssertEqual(finiteSummary, streamingSummary, "one acquisition pipeline, two ecosystems")
        XCTAssertEqual(finiteSummary.stop, .planCompleted)
        XCTAssertEqual(finiteSummary.admittedBatches, 2)
        XCTAssertEqual(
            try dump(in: finiteDatabase),
            try dump(in: streamingDatabase),
            "the same content leaves byte-identical canonical state whichever connector produced it"
        )

        // What the second paradigm brought with it is canonical content, not connector-specific state.
        XCTAssertEqual(try rowCount("origin_record", in: streamingDatabase), 2)
        XCTAssertEqual(try rowCount("origin_revision", in: streamingDatabase), 2)
        XCTAssertEqual(try rowCount("content_relation", in: streamingDatabase), 2)
        XCTAssertEqual(try rowCount("provider_attribution", in: streamingDatabase), 2)
        XCTAssertEqual(try rowCount("media_candidate", in: streamingDatabase), 4)
        XCTAssertEqual(try rowCount("interaction_offer", in: streamingDatabase), 4)
        XCTAssertEqual(try rowCount("source_membership", in: streamingDatabase), 4)
        XCTAssertEqual(try rowCount("selection_supply", in: streamingDatabase), 2)
        XCTAssertEqual(try checkpointRevision("shared-work", in: streamingDatabase), 2)

        // The discontinuity: nothing is committed, and the durable checkpoint stays the resume point.
        let disconnected = await run(streamingConnector, target: streamingTarget, in: streamingDatabase, deficit: 1)
        XCTAssertEqual(disconnected.stop, .degraded(.streamDisconnected(streamingTarget.id)))
        XCTAssertEqual(disconnected.admittedBatches, 0)
        XCTAssertEqual(try checkpointRevision("shared-work", in: streamingDatabase), 2)
        XCTAssertEqual(try rowCount("origin_record", in: streamingDatabase), 2)

        // The reconnection resumes from it: the connector is handed back the checkpoint Admission
        // committed, not a position of its own choosing (ADR-005 D11).
        let resumed = await run(streamingConnector, target: streamingTarget, in: streamingDatabase, deficit: 1)
        let checkpoints = await streamingConnector.receivedCheckpoints
        XCTAssertEqual(resumed.stop, .planCompleted)
        XCTAssertEqual(checkpoints.count, 4)
        XCTAssertEqual(checkpoints.last ?? nil, try FixtureBatchIdentity.proposedCheckpoint(sequence: 2))
        XCTAssertEqual(try rowCount("origin_record", in: streamingDatabase), 3)
        XCTAssertEqual(try checkpointRevision("shared-work", in: streamingDatabase), 3)
        await streamingConnector.stop()
    }

    /// `coreHasNoUniversalProtocolWriteDependency` (plan §19 #39; `invariant 15`, `I-18`).
    ///
    /// The connector offers a write capability and the runtime never reaches for it: the acquisition
    /// path uses the read pull and nothing else, however much content flows. Offers arrive as data
    /// with an opaque handle and are never resolved into an action by the runtime.
    func testCoreHasNoUniversalProtocolWriteDependency() async throws {
        let alpha = try insertSource("catalog:alpha")
        try registerTarget()
        let target = try acquisitionTarget()
        let connector = FakeStreamingConnector(
            target: target,
            script: [.burst(["w-1"]), .burst(["w-2"])],
            capacity: 2,
            shape: FixtureObservationShape(memberships: [alpha], offerKinds: ["bookmark"])
        )

        // The capability is real and callable: the test proves the counter works before claiming the
        // runtime never uses it.
        let probeWrite = await connector.requestProtocolWrite("probe")
        XCTAssertEqual(probeWrite, 1)

        let coordinator = AcquisitionCoordinator(
            resolver: AcquisitionSourceResolver.mapping([target.id: connector]),
            targetStore: targetStore,
            engine: engine,
            clock: clock
        )
        let first = await coordinator.run(demand(deficit: 1), catalogue: [target], in: database)
        XCTAssertEqual(first.stop, .planCompleted)
        XCTAssertEqual(try rowCount("origin_record"), 1)

        // The offers are content: stored with the connector's own opaque handle, never executed.
        XCTAssertEqual(try rowCount("interaction_offer"), 1)
        let handle = try string("SELECT handle FROM interaction_offer ORDER BY id LIMIT 1")
        XCTAssertEqual(handle, "fixture://bookmark")

        let offersBefore = Array(try dump(["interaction_offer"]).dropFirst())
        let second = await coordinator.run(demand(deficit: 1), catalogue: [target], in: database)
        XCTAssertEqual(second.stop, .planCompleted)
        let offersAfter = Array(try dump(["interaction_offer"]).dropFirst())
        XCTAssertEqual(
            offersAfter.first,
            offersBefore.first,
            "the stored offer is untouched: the runtime keeps no execution state for it"
        )
        XCTAssertEqual(offersAfter.count, 2, "one offer per admitted observation, stored verbatim")

        let writes = await connector.protocolWriteCount
        XCTAssertEqual(writes, 1, "the runtime performed no protocol write of its own")
        let calls = await connector.receivedCalls
        XCTAssertEqual(Set(calls), ["pull"], "the only capability the acquisition path uses is the read pull")
        XCTAssertEqual(calls.count, first.pulls + second.pulls)
        await connector.stop()
    }

    /// The same runtime selects the same supply from both ecosystems: `selection_supply` names the
    /// current revision of each record, and the current revision is the newest one, not the last
    /// arrival (ADR-006 D4).
    func testBothEcosystemsLeaveSelectionReadySupply() async throws {
        let finiteDatabase = try freshDatabase(named: "finite-supply")
        let streamingDatabase = try freshDatabase(named: "streaming-supply")
        let finiteSources = [try insertSource("catalog:alpha", in: finiteDatabase)]
        let streamingSources = [try insertSource("catalog:alpha", in: streamingDatabase)]
        try registerTarget(in: finiteDatabase)
        try registerTarget(in: streamingDatabase)
        let finiteTarget = try acquisitionTarget(in: finiteDatabase)
        let streamingTarget = try acquisitionTarget(in: streamingDatabase)

        let finiteConnector = FakeFiniteConnector(
            target: finiteTarget,
            script: FakeFiniteConnector.Script(pages: [["s-1"]], shape: shape(memberships: finiteSources))
        )
        let streamingConnector = FakeStreamingConnector(
            target: streamingTarget,
            script: [.burst(["s-1"])],
            capacity: 2,
            shape: shape(memberships: streamingSources)
        )

        _ = await run(finiteConnector, target: finiteTarget, in: finiteDatabase, deficit: 1)
        _ = await run(streamingConnector, target: streamingTarget, in: streamingDatabase, deficit: 1)
        await streamingConnector.stop()

        XCTAssertEqual(
            try dump(["selection_supply", "origin_record", "origin_revision"], in: finiteDatabase),
            try dump(["selection_supply", "origin_record", "origin_revision"], in: streamingDatabase)
        )
        XCTAssertEqual(
            try scalar("""
                SELECT COUNT(*) FROM selection_supply AS supply
                JOIN origin_record AS record ON record.id = supply.origin_record_id
                WHERE supply.origin_revision_id = record.current_revision_id
                """, in: streamingDatabase),
            1
        )
    }
}
