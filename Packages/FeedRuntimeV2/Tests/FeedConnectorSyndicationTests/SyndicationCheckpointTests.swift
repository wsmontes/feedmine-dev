import Foundation
import XCTest
import FeedDomain
@testable import FeedConnectorSyndication

/// The checkpoint is the connector's own state machine: what it means, when it may advance and what
/// a missing body means (ADR-005 D11, D12; plan §14 PR-11).
final class SyndicationCheckpointTests: XCTestCase {
    private func url(_ raw: String = TestFixtures.feedEndpoint) throws -> URL {
        try TestFixtures.url(raw)
    }

    func testInitialCheckpointAuthorisesNoConditionalRequest() throws {
        let endpoint = try url()
        let checkpoint = SyndicationCheckpoint.initial(generation: 7, endpoint: endpoint)

        XCTAssertTrue(checkpoint.validators.isEmpty)
        XCTAssertFalse(checkpoint.hasAdmittedBaseline)
        XCTAssertTrue(checkpoint.observedRepresentations.isEmpty)
        XCTAssertTrue(checkpoint.conditionalHeaders(for: endpoint, generation: 7).isEmpty)
    }

    func testConditionalHeadersAreScopedToTheEndpointGenerationAndConnector() throws {
        let endpoint = try url()
        let checkpoint = SyndicationCheckpoint.initial(generation: 7, endpoint: endpoint)
            .adoptingBaseline(
                validators: SyndicationValidators(etag: "W/\"a-1\"", lastModified: "Mon, 14 Sep 2026 10:00:00 GMT"),
                endpoint: endpoint,
                observedRepresentations: [:]
            )

        XCTAssertEqual(checkpoint.conditionalHeaders(for: endpoint, generation: 7), [
            "If-None-Match": "W/\"a-1\"",
            "If-Modified-Since": "Mon, 14 Sep 2026 10:00:00 GMT",
        ])
        // Another endpoint never receives a validator that endpoint did not issue (D12, invariant 7).
        let other = try url(TestFixtures.otherEndpoint)
        XCTAssertTrue(checkpoint.conditionalHeaders(for: other, generation: 7).isEmpty)
        // A generation bump makes the old validator unusable (D10).
        XCTAssertTrue(checkpoint.conditionalHeaders(for: endpoint, generation: 8).isEmpty)
        // A checkpoint from another connector is not reusable either (D11).
        XCTAssertTrue(
            checkpoint.conditionalHeaders(for: endpoint, generation: 7, connectorNamespace: "other").isEmpty
        )
    }

    /// The non-negotiable property at the value level: a validator only advances together with a
    /// fully consumed body, and a 304 only confirms, never advances.
    func testValidatorAdvanceRequiresAFullyConsumedBody() throws {
        let endpoint = try url()
        let initial = SyndicationCheckpoint.initial(generation: 7, endpoint: endpoint)
        XCTAssertThrowsError(try initial.confirmedByNotModified()) { error in
            XCTAssertEqual(error as? SyndicationCheckpointError, .notModifiedWithoutAdmittedBaseline)
        }
        XCTAssertTrue(initial.conditionalHeaders(for: endpoint, generation: 7).isEmpty)

        let confirmed = initial.adoptingBaseline(
            validators: SyndicationValidators(etag: "\"a-2\""),
            endpoint: endpoint,
            observedRepresentations: [:]
        )
        XCTAssertTrue(confirmed.hasAdmittedBaseline)
        XCTAssertEqual(confirmed.validators.etag, "\"a-2\"")
        XCTAssertEqual(confirmed.conditionalHeaders(for: endpoint, generation: 7), ["If-None-Match": "\"a-2\""])

        // A 304 changes nothing at all: same validators, same representation record (invariant 9).
        XCTAssertEqual(try confirmed.confirmedByNotModified(), confirmed)
    }

    func testEncodedCheckpointRoundTripsAndRefusesAnotherSchemaVersion() throws {
        let endpoint = try url()
        let payload = ObservationPayload(
            headline: "Headline",
            link: try TestFixtures.url("https://example.com/one"),
            excerpt: nil,
            body: nil,
            authoredAt: TestFixtures.observedAt,
            modifiedAt: nil,
            observedAt: TestFixtures.observedAt
        )
        let checkpoint = SyndicationCheckpoint.initial(generation: 7, endpoint: endpoint)
            .adoptingBaseline(
                validators: SyndicationValidators(etag: "\"a-3\"", lastModified: nil),
                endpoint: endpoint,
                observedRepresentations: ["slot-1": SyndicationRepresentationStamp(
                    declaredVersion: "2026-09-14T10:00:00Z",
                    payload: payload
                )]
            )

        let encoded = try checkpoint.encoded()
        XCTAssertEqual(try SyndicationCheckpoint.decoded(from: encoded), checkpoint)
        // The payload is a value a repository can store without any SQL in this target.
        XCTAssertFalse(encoded.isEmpty)

        let future = SyndicationCheckpoint(
            schemaVersion: SyndicationCheckpoint.currentSchemaVersion + 1,
            generation: 7,
            endpoint: endpoint.absoluteString
        )
        let futureData = try future.encoded()
        XCTAssertThrowsError(try SyndicationCheckpoint.decoded(from: futureData)) { error in
            XCTAssertEqual(
                error as? SyndicationCheckpointError,
                .unsupportedSchemaVersion(SyndicationCheckpoint.currentSchemaVersion + 1)
            )
        }
    }
}
