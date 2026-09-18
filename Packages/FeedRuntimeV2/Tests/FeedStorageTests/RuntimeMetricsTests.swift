import Foundation
import GRDB
import XCTest
import FeedDomain
@testable import FeedStorage

/// Plan §16's instrumentation: the measures are recorded by operation ID/edition/epoch, the counters §16
/// names are counted where they happen, and a report says which world its numbers came from.
///
/// The recorder is fed by the instrumented paths through unstructured tasks, so that instrumentation can
/// never block or fail a hot path. The assertion therefore *waits* for the samples instead of assuming
/// they landed, with a bounded deadline.
final class RuntimeMetricsTests: RuntimeV2TestCase {
    /// Waits until every expected operation has been recorded.
    ///
    /// The instrumented paths record through unstructured tasks — instrumentation must never block or
    /// fail the work it measures — so the assertion waits for the samples rather than assuming they have
    /// landed. Waiting for a *total* would return as soon as the last-but-one arrived.
    private func report(
        _ recorder: RuntimeMetricsRecorder,
        expecting operations: [RuntimeOperation],
        timeout: TimeInterval = 5
    ) async throws -> RunMetricsReport {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = await recorder.report(world: "test")
        while Date() < deadline {
            if operations.allSatisfy({ latest.summary(for: $0) != nil }) { return latest }
            try await Task.sleep(nanoseconds: 20_000_000)
            latest = await recorder.report(world: "test")
        }
        return latest
    }

    func testPercentilesAreNearestRankOverTheSamplesThatOccurred() {
        let samples = [1.0, 2.0, 3.0, 4.0, 100.0].map {
            OperationSample(operation: .admission, operationID: "s", durationMilliseconds: $0, outcome: "admitted")
        }

        let summary = OperationSummary.summarize(.admission, samples)

        XCTAssertEqual(summary?.count, 5)
        XCTAssertEqual(summary?.p50Milliseconds, 3.0, "the median is a sample, not an interpolation")
        XCTAssertEqual(summary?.p95Milliseconds, 100.0)
        XCTAssertEqual(summary?.maxMilliseconds, 100.0)
        XCTAssertEqual(summary?.outcomes, ["admitted": 5])
        XCTAssertNil(OperationSummary.summarize(.admission, []), "an operation with no sample is not a zero")
    }

    func testTheInstrumentedPathsRecordTheirOperationAndTheirCounter() async throws {
        let recorder = RuntimeMetricsRecorder()
        try registerTarget()

        // Admission, including the replay §16 calls a no-op batch.
        let engine = AdmissionEngine(clock: fixedClock, metrics: recorder)
        let stamp = try stamp()
        let first = try batch(
            id: "batch-1",
            expectedCheckpoint: stamp.checkpointRevision,
            observations: [try observation(object: "admitted-one")]
        )
        guard case .admitted = engine.admit(first, in: database) else {
            return XCTFail("the fixture batch must be admitted")
        }
        guard case let .duplicate(batchID) = engine.admit(first, in: database) else {
            return XCTFail("a replayed batch must be answered from durable state")
        }
        XCTAssertEqual(batchID, "batch-1")

        // The candidate query, over the supply that admission just produced.
        let selectionRepository = SelectionSupplyRepository(metrics: recorder)
        _ = try selectionRepository.page(
            SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 64),
            in: database
        )

        // A publication commit that needed a retry: the first attempt fails in storage, the second
        // lands, and the retry is counted where the attempt number is known.
        let source = try ensureSource("catalog:alpha")
        let row = try insertSupplyRow(objectKey: "one", sourceIDs: [source], observedAt: 0)
        let context = try planContext()
        let draft = try openDraft(context: context, revisionTag: "rev-1")
        let card = CardInsertRecord(
            frozen: try frozenCard(
                edition: draft,
                segmentOrdinal: 0,
                absoluteOrdinal: 0,
                record: row,
                revisionTag: "rev-1"
            ),
            assetReferences: []
        )
        let failing = PublicationRepository(
            database: database,
            faults: .init(point: .storageFailureAtCommit, attempt: 1),
            metrics: recorder
        )
        XCTAssertThrowsError(
            try publish(failing, token: draft.token, cards: [card], activation: .activate(successorOf: nil))
        )
        let instrumented = PublicationRepository(database: database, metrics: recorder)
        let token = try instrumented.token(for: draft.editionID)
        _ = try instrumented.commit(
            SegmentCommitRequest(
                token: token,
                segmentOrdinal: token.tail.nextSegmentOrdinal,
                absoluteOrdinalStart: token.tail.nextAbsoluteOrdinal,
                segmentSeed: Data("segment-seed".utf8),
                policyRevision: token.editorialRevision.digest,
                committedAt: TestInstant.seconds(1),
                activation: .activate(successorOf: nil),
                cards: [card],
                assets: [],
                mediaPreparations: [],
                pinnedRevisions: []
            ),
            attempt: 2
        )

        // A retention run, and the orphan counter §16 asks for.
        try RetentionPolicyStore(database: database).declare(
            RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 86_400)
        )
        _ = try await RetentionCoordinator(
            database: database,
            clock: fixedClock,
            metrics: recorder
        ).run()

        let report = try await report(recorder, expecting: [.admission, .selectionQuery, .publicationCommit, .retentionRun])

        for operation in [
            RuntimeOperation.admission,
            .selectionQuery,
            .publicationCommit,
            .retentionRun,
        ] {
            let summary = try XCTUnwrap(report.summary(for: operation), "\(operation) has no measurement")
            XCTAssertGreaterThan(summary.count, 0)
            XCTAssertLessThanOrEqual(summary.p50Milliseconds, summary.p95Milliseconds)
            XCTAssertLessThanOrEqual(summary.p95Milliseconds, summary.maxMilliseconds)
            XCTAssertGreaterThanOrEqual(summary.maxMilliseconds, 0)
        }
        XCTAssertEqual(report.count(of: .noOpBatch), 1)
        XCTAssertEqual(report.count(of: .publicationRetry), 1)
        XCTAssertEqual(report.count(of: .gcRun), 1)
        XCTAssertEqual(
            report.summary(for: .admission)?.outcomes,
            ["admitted": 1, "duplicate": 1],
            "the sample records which answer the batch received"
        )
        XCTAssertEqual(report.summary(for: .publicationCommit)?.outcomes.count, 2, "one refusal, one publish")

        // The report carries the world its numbers came from, and nothing that could be a URL.
        let serialized = report.serialized()
        XCTAssertTrue(serialized.contains("world=test"))
        XCTAssertFalse(serialized.contains("http"), "a measure is counts and durations: §16 forbids URLs")
        XCTAssertFalse(serialized.contains("example.test"))
    }
}
