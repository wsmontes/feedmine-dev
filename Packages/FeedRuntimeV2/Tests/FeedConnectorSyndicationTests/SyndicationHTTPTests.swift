import Foundation
import XCTest
import FeedDomain
@testable import FeedConnectorSyndication

/// HTTP semantics, proven against a scripted transport: no socket, no real publisher, no bytes
/// beyond the synthetic documents in `TestFixtures` (plan §14 PR-11).
final class SyndicationHTTPTests: XCTestCase {
    private func url(_ raw: String = TestFixtures.feedEndpoint) throws -> URL {
        try TestFixtures.url(raw)
    }

    /// A checkpoint that already has an admitted baseline, which is the only state in which a
    /// conditional request may be sent.
    private func admittedCheckpoint(
        etag: String = "\"a-1\"",
        endpoint url: URL
    ) -> SyndicationCheckpoint {
        SyndicationCheckpoint.initial(generation: 7, endpoint: url)
            .adoptingBaseline(
                validators: SyndicationValidators(etag: etag, lastModified: "Mon, 14 Sep 2026 10:00:00 GMT"),
                endpoint: url,
                observedRepresentations: [:]
            )
    }

    private func fetch(
        _ replies: [ScriptedTransport.Reply],
        checkpoint: SyndicationCheckpoint? = nil,
        endpoint raw: String = TestFixtures.feedEndpoint,
        limits: SyndicationHTTPLimits = SyndicationHTTPLimits(),
        byteCeiling: Int = 1_048_576
    ) async throws -> (SyndicationHTTPOutcome, ScriptedTransport) {
        let transport = ScriptedTransport(replies)
        let client = SyndicationHTTPClient(transport: transport, limits: limits)
        let outcome = try await client.fetch(
            endpoint: try url(raw),
            generation: 7,
            checkpoint: checkpoint,
            byteCeiling: byteCeiling,
            now: TestFixtures.observedAt
        )
        return (outcome, transport)
    }

    private func assertHTTPError(
        _ expected: SyndicationHTTPError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SyndicationHTTPError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - 200

    func testHTTP200ReturnsTheBodyItsValidatorsAndTheChain() async throws {
        let endpoint = try url()
        let (outcome, transport) = try await fetch([.ok(
            TestFixtures.rssTwoItems,
            headers: ["ETag": "\"a-9\"", "Last-Modified": "Mon, 14 Sep 2026 10:00:00 GMT"]
        )])

        guard case .body(let body) = outcome else { return XCTFail("expected a body, got \(outcome)") }
        XCTAssertEqual(body.status, 200)
        XCTAssertEqual(body.endpoint, endpoint)
        XCTAssertEqual(body.body, Data(TestFixtures.rssTwoItems.utf8))
        XCTAssertEqual(body.validators, SyndicationValidators(
            etag: "\"a-9\"",
            lastModified: "Mon, 14 Sep 2026 10:00:00 GMT"
        ))
        XCTAssertEqual(body.chain, [endpoint])
        XCTAssertEqual(body.redirectCount, 0)
        // An unconditional first fetch sends no conditional header at all.
        let ifNoneMatch = await transport.header("If-None-Match", ofRequest: 0)
        let ifModifiedSince = await transport.header("If-Modified-Since", ofRequest: 0)
        XCTAssertNil(ifNoneMatch)
        XCTAssertNil(ifModifiedSince)
    }

    // MARK: - 304

    func testHTTP304RequiresAConditionalRequestOverAnAdmittedBaseline() async throws {
        let endpoint = try url()
        let checkpoint = admittedCheckpoint(endpoint: endpoint)
        let (outcome, transport) = try await fetch([.status(304)], checkpoint: checkpoint)

        guard case .notModified(let notModified) = outcome else {
            return XCTFail("expected notModified, got \(outcome)")
        }
        XCTAssertEqual(notModified.endpoint, endpoint)
        let sentETag = await transport.header("If-None-Match", ofRequest: 0)
        XCTAssertEqual(sentETag, "\"a-1\"")

        // A 304 that no conditional request could have produced is never trusted (D12): without a
        // baseline the body has to be fetched unconditionally.
        let transport2 = ScriptedTransport([.status(304)])
        let client = SyndicationHTTPClient(transport: transport2)
        await assertHTTPError(.notModifiedWithoutConditionalRequest) {
            _ = try await client.fetch(
                endpoint: endpoint,
                generation: 7,
                checkpoint: nil,
                byteCeiling: 1_048_576,
                now: TestFixtures.observedAt
            )
        }
    }

    // MARK: - Redirects

    func testRedirectsAreFollowedWithinTheLimitAndTheLimitStopsTheWork() async throws {
        let endpoint = try url()
        let destination = try url("https://a.example.com/moved/feed.xml")
        let (outcome, transport) = try await fetch([
            .status(301, headers: ["Location": destination.absoluteString]),
            .ok(TestFixtures.rssTwoItems),
        ])

        guard case .body(let body) = outcome else { return XCTFail("expected a body, got \(outcome)") }
        XCTAssertEqual(body.chain, [endpoint, destination])
        XCTAssertEqual(body.redirectCount, 1)
        XCTAssertEqual(body.endpoint, destination)
        let requested = await transport.requestedURLs
        XCTAssertEqual(requested, [endpoint, destination])

        // The redirect limit stops the work and leaves the caller with a checkpoint (D9, D14).
        let transport2 = ScriptedTransport([.status(301, headers: ["Location": destination.absoluteString])])
        let client = SyndicationHTTPClient(transport: transport2, limits: SyndicationHTTPLimits(maxRedirects: 0))
        await assertHTTPError(.redirectLimitExceeded(limit: 0)) {
            _ = try await client.fetch(
                endpoint: endpoint,
                generation: 7,
                checkpoint: nil,
                byteCeiling: 1_048_576,
                now: TestFixtures.observedAt
            )
        }
        let redirectAttempts = await transport2.requestCount
        XCTAssertEqual(redirectAttempts, 1)
    }

    func testRedirectDoesNotTransferValidatorToAnotherHost() async throws {
        let endpoint = try url()
        let otherHost = try TestFixtures.url("\(TestFixtures.otherEndpoint)?token=secret")
        let (outcome, transport) = try await fetch(
            [
                .status(302, headers: ["Location": otherHost.absoluteString]),
                .ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"b-1\""]),
            ],
            checkpoint: admittedCheckpoint(endpoint: endpoint)
        )

        guard case .body(let body) = outcome else { return XCTFail("expected a body, got \(outcome)") }
        XCTAssertEqual(body.endpoint, try TestFixtures.url(TestFixtures.otherEndpoint))
        // The original endpoint's validator is sent only where the endpoint policy allows it.
        let firstRequestETag = await transport.header("If-None-Match", ofRequest: 0)
        let redirectedETag = await transport.header("If-None-Match", ofRequest: 1)
        let redirectedSince = await transport.header("If-Modified-Since", ofRequest: 1)
        XCTAssertEqual(firstRequestETag, "\"a-1\"")
        XCTAssertNil(redirectedETag)
        XCTAssertNil(redirectedSince)

        // A same-host redirect is allowed to keep the validator: the resource is the same origin.
        let sameHost = try url("https://a.example.com/moved/feed.xml")
        let (_, transport3) = try await fetch(
            [
                .status(301, headers: ["Location": sameHost.absoluteString]),
                .status(304),
            ],
            checkpoint: admittedCheckpoint(endpoint: endpoint)
        )
        let sameHostETag = await transport3.header("If-None-Match", ofRequest: 1)
        XCTAssertEqual(sameHostETag, "\"a-1\"")
    }

    // MARK: - 429 / 503

    func testTooManyRequestsAndServiceUnavailableReportRetryAfter() async throws {
        let (tooMany, _) = try await fetch([.status(429, headers: ["Retry-After": "120"])])
        XCTAssertEqual(tooMany, .throttled(retryAfter: 120))

        let (unavailable, _) = try await fetch([.status(503, headers: ["Retry-After": "-5"])])
        XCTAssertEqual(unavailable, .throttled(retryAfter: 0))

        // An HTTP-date is honoured, converted against the caller's instant.
        let (dated, _) = try await fetch([.status(503, headers: ["Retry-After": "Mon, 14 Sep 2026 10:00:30 GMT"])])
        guard case .throttled(let retryAfter) = dated else { return XCTFail("expected throttled, got \(dated)") }
        XCTAssertEqual(try XCTUnwrap(retryAfter), 30, accuracy: 0.001)

        // An unusable header is not a licence to retry immediately: the caller's default applies.
        let (unreadable, _) = try await fetch([.status(429, headers: ["Retry-After": "soon-ish"])])
        XCTAssertEqual(unreadable, .throttled(retryAfter: nil))
    }

    func testBackoffIsClampedJitteredAndStable() throws {
        let now = TestFixtures.observedAt
        let targetID = AcquisitionTargetID("target-1")
        let policy = SyndicationBackoffPolicy(defaultDelay: 30, maxDelay: 600, jitterFraction: 0.2, salt: "test")
        // A fraction of 0.5 is the neutral jitter, so the declared delay is exact.
        let neutral = FixedSyndicationJitter(value: 0.5)

        XCTAssertEqual(
            policy.eligibleAt(now: now, retryAfter: 120, targetID: targetID, jitter: neutral),
            now.addingTimeInterval(120)
        )
        XCTAssertEqual(
            policy.eligibleAt(now: now, retryAfter: 100_000, targetID: targetID, jitter: neutral),
            now.addingTimeInterval(600),
            "a declared delay is clamped"
        )
        XCTAssertEqual(
            policy.eligibleAt(now: now, retryAfter: nil, targetID: targetID, jitter: neutral),
            now.addingTimeInterval(30),
            "an absent header uses the policy default"
        )
        XCTAssertEqual(
            policy.eligibleAt(now: now, retryAfter: .infinity, targetID: targetID, jitter: neutral),
            now.addingTimeInterval(30)
        )

        // The jitter is a stable function of the local salt, the target and the bucket — never the
        // wall clock, and never shared between two targets (ADR-005 D13, plan §20.3).
        let stable = StableSyndicationJitter()
        let first = policy.eligibleAt(now: now, retryAfter: 120, targetID: targetID, jitter: stable)
        let again = policy.eligibleAt(now: now, retryAfter: 120, targetID: targetID, jitter: stable)
        let sibling = policy.eligibleAt(
            now: now,
            retryAfter: 120,
            targetID: AcquisitionTargetID("target-2"),
            jitter: stable
        )
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, sibling)
        XCTAssertGreaterThanOrEqual(first, now.addingTimeInterval(96))
        XCTAssertLessThanOrEqual(first, now.addingTimeInterval(144))
    }

    // MARK: - Ceilings and validation

    func testByteCeilingsStopAnOversizedResponse() async throws {
        let client = SyndicationHTTPClient(
            transport: ScriptedTransport([.ok(TestFixtures.rssTwoItems)]),
            limits: SyndicationHTTPLimits()
        )
        let endpoint = try url()
        await assertHTTPError(.decompressedBodyTooLarge(
            limit: 16,
            received: Data(TestFixtures.rssTwoItems.utf8).count
        )) {
            _ = try await client.fetch(
                endpoint: endpoint,
                generation: 7,
                checkpoint: nil,
                byteCeiling: 16,
                now: TestFixtures.observedAt
            )
        }

        // A declared compressed size over the ceiling stops the response before it is read.
        let declared = ScriptedTransport([.ok(
            TestFixtures.rssTwoItems,
            headers: ["Content-Length": "2048"]
        )])
        let limited = SyndicationHTTPClient(
            transport: declared,
            limits: SyndicationHTTPLimits(maxCompressedBytes: 1024)
        )
        await assertHTTPError(.compressedBodyTooLarge(limit: 1024, declared: 2048)) {
            _ = try await limited.fetch(
                endpoint: endpoint,
                generation: 7,
                checkpoint: nil,
                byteCeiling: 1_048_576,
                now: TestFixtures.observedAt
            )
        }
    }

    func testEndpointIsValidatedBeforeAnyRequestLeaves() async throws {
        let transport = ScriptedTransport([.ok(TestFixtures.rssTwoItems)])
        let client = SyndicationHTTPClient(transport: transport)
        let local = try TestFixtures.url("file:///etc/passwd")

        await assertHTTPError(.invalidEndpoint(.unsupportedScheme("file"))) {
            _ = try await client.fetch(
                endpoint: local,
                generation: 7,
                checkpoint: nil,
                byteCeiling: 1_048_576,
                now: TestFixtures.observedAt
            )
        }
        let attempts = await transport.requestCount
        XCTAssertEqual(attempts, 0)

        // A redirect to an unusable endpoint is refused as a redirect target, not as the request.
        let redirected = ScriptedTransport([
            .status(301, headers: ["Location": "file:///etc/passwd"]),
        ])
        let redirecting = SyndicationHTTPClient(transport: redirected)
        await assertHTTPError(.invalidRedirectTarget(.unsupportedScheme("file"))) {
            _ = try await redirecting.fetch(
                endpoint: try url(),
                generation: 7,
                checkpoint: nil,
                byteCeiling: 1_048_576,
                now: TestFixtures.observedAt
            )
        }
    }

    func testTransportFailuresAreClassified() async throws {
        let endpoint = try url()
        for failureClass in SyndicationTransportFailureClass.allCases {
            let transport = ScriptedTransport([.failure(failureClass)])
            let client = SyndicationHTTPClient(transport: transport)
            await assertHTTPError(.transport(failureClass)) {
                _ = try await client.fetch(
                    endpoint: endpoint,
                    generation: 7,
                    checkpoint: nil,
                    byteCeiling: 1_048_576,
                    now: TestFixtures.observedAt
                )
            }
        }
    }

    // MARK: - Host fairness

    func testHostGateBacksOffOneHostOnly() throws {
        let now = TestFixtures.observedAt
        let throttledHost = try TestFixtures.url("https://a.example.com/feed.xml")
        let healthyHost = try TestFixtures.url(TestFixtures.otherEndpoint)

        let gate = SyndicationHostGate().recording(url: throttledHost, until: now.addingTimeInterval(60))
        XCTAssertFalse(gate.isEligible(throttledHost, at: now))
        XCTAssertEqual(gate.nextEligibleAt(throttledHost), now.addingTimeInterval(60))
        // The gate is keyed by host: a throttled host delays nothing else in the same budget.
        XCTAssertTrue(gate.isEligible(healthyHost, at: now))
        XCTAssertNil(gate.nextEligibleAt(healthyHost))
        // Once the instant passes, the host is eligible again without any further bookkeeping.
        XCTAssertTrue(gate.isEligible(throttledHost, at: now.addingTimeInterval(60)))
    }
}
