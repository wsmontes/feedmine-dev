import Foundation
import XCTest
import FeedDomain
@testable import FeedConnectorSyndication

/// The connector ties the layers together: request, checkpoint, translation, batch and the proposed
/// checkpoint (plan §14 PR-11; ADR-005 D12, D13, D15).
final class SyndicationConnectorTests: XCTestCase {
    private func target(generation: UInt64 = 7) throws -> SyndicationTarget {
        try SyndicationTarget.fixture(generation: generation)
    }

    /// A checkpoint that a previous, fully consumed fetch produced.
    private func admittedCheckpoint(
        for target: SyndicationTarget,
        etag: String = "\"a-1\""
    ) -> SyndicationCheckpoint {
        SyndicationCheckpoint.initial(generation: target.generation, endpoint: target.endpoint)
            .adoptingBaseline(
                validators: SyndicationValidators(etag: etag, lastModified: "Mon, 14 Sep 2026 10:00:00 GMT"),
                endpoint: target.endpoint,
                observedRepresentations: [:]
            )
    }

    private func makeConnector(
        _ replies: [ScriptedTransport.Reply],
        target: SyndicationTarget,
        limits: SyndicationHTTPLimits = SyndicationHTTPLimits(),
        gate: SyndicationHostGate = SyndicationHostGate()
    ) -> (SyndicationConnector, ScriptedTransport) {
        let transport = ScriptedTransport(replies)
        let connector = SyndicationConnector(
            target: target,
            transport: transport,
            clock: FixedClock(now: TestFixtures.observedAt),
            limits: limits,
            backoff: SyndicationBackoffPolicy(defaultDelay: 30, maxDelay: 600, jitterFraction: 0),
            jitter: FixedSyndicationJitter(value: 0.5),
            hostGate: gate
        )
        return (connector, transport)
    }

    // MARK: - The happy path

    func testBatchCarriesCanonicalObservationsAndAProposedCheckpoint() async throws {
        let target = try target()
        let (connector, transport) = makeConnector(
            [.ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"a-1\""])],
            target: target
        )
        let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: nil)

        guard case .batch(let result) = outcome else { return XCTFail("expected a batch, got \(outcome)") }
        XCTAssertEqual(result.batch.targetID, target.targetID)
        XCTAssertEqual(result.batch.generation, target.generation)
        XCTAssertEqual(result.batch.observations.count, 2)
        XCTAssertFalse(result.batch.fingerprint.isEmpty)
        XCTAssertFalse(result.batch.batchID.isEmpty)
        XCTAssertEqual(result.redirectChain, [target.endpoint])
        XCTAssertEqual(result.endpoint, target.endpoint)
        XCTAssertTrue(result.proposesValidatorConfirmation)

        // The proposal is Admission's to commit, and it carries the endpoint's own validators.
        XCTAssertEqual(result.proposedCheckpoint.validators.etag, "\"a-1\"")
        XCTAssertEqual(result.proposedCheckpoint.endpoint, target.endpoint.absoluteString)
        XCTAssertTrue(result.proposedCheckpoint.hasAdmittedBaseline)
        XCTAssertEqual(result.proposedCheckpoint.observedRepresentations.count, 2)

        // Evidence is opaque and removable: the response body is recorded with its digest.
        XCTAssertTrue(result.batch.evidence.contains {
            $0.kind == .responseBody && $0.bytes == Data(TestFixtures.rssTwoItems.utf8)
        })

        // A second, independent run over the same document produces the same batch identity, so a
        // replay can be recognised as one instead of becoming new supply.
        let (replay, _) = makeConnector([.ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"a-1\""])], target: target)
        let replayed = try await replay.acquire(limit: TestFixtures.limit(), checkpoint: nil)
        guard case .batch(let again) = replayed else { return XCTFail("expected a batch, got \(replayed)") }
        XCTAssertEqual(again.batch.fingerprint, result.batch.fingerprint)
        XCTAssertEqual(again.batch.batchID, result.batch.batchID)
        XCTAssertEqual(again.batch.observations, result.batch.observations)

        let requests = await transport.requestCount
        XCTAssertEqual(requests, 1)
    }

    func testEnclosureLinksAreRecordedAsRemovableEvidence() async throws {
        let target = try target()
        let (connector, _) = makeConnector(
            [.ok(TestFixtures.rssWithEnclosure, headers: ["ETag": "\"a-1\""])],
            target: target
        )
        let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: nil)

        guard case .batch(let result) = outcome else { return XCTFail("expected a batch, got \(outcome)") }
        let enclosure = Data("https://cdn.example.com/audio/episode-one.mp3".utf8)
        XCTAssertTrue(result.batch.evidence.contains { $0.kind == .parsedEntry && $0.bytes == enclosure })
        // The canonical payload still points at the declared article link.
        XCTAssertEqual(
            result.batch.observations[0].payload.link?.absoluteString,
            "https://example.com/episode-one"
        )
    }

    // MARK: - The non-negotiable validator property

    /// A validator may advance only when Admission-consistent content was produced, or when a 304
    /// arrived over a valid baseline (ADR-005 D12, invariant 8; plan §14 PR-11).
    func testValidatorAdvancesOnlyOnConsumedContentOrA304OverABaseline() async throws {
        let target = try target()

        // 1. A fully consumed body: the validators may be confirmed with the batch.
        let (first, firstTransport) = makeConnector(
            [.ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"a-1\""])],
            target: target
        )
        let firstOutcome = try await first.acquire(limit: TestFixtures.limit(), checkpoint: nil)
        guard case .batch(let confirmed) = firstOutcome else {
            return XCTFail("expected a batch, got \(firstOutcome)")
        }
        XCTAssertTrue(confirmed.proposesValidatorConfirmation)
        XCTAssertEqual(confirmed.proposedCheckpoint.validators.etag, "\"a-1\"")
        XCTAssertTrue(confirmed.proposedCheckpoint.hasAdmittedBaseline)
        let attempts = await firstTransport.requestCount
        XCTAssertEqual(attempts, 1)

        // 2. A 304 over that baseline: nothing advances, and nothing is removed.
        let (second, secondTransport) = makeConnector([.status(304)], target: target)
        let secondOutcome = try await second.acquire(
            limit: TestFixtures.limit(),
            checkpoint: confirmed.proposedCheckpoint
        )
        guard case .notModified(let endpoint, let afterNotModified) = secondOutcome else {
            return XCTFail("expected notModified, got \(secondOutcome)")
        }
        XCTAssertEqual(endpoint, target.endpoint)
        XCTAssertEqual(afterNotModified, confirmed.proposedCheckpoint)
        XCTAssertTrue(afterNotModified.hasAdmittedBaseline)
        XCTAssertEqual(afterNotModified.validators.etag, "\"a-1\"")
        let conditional = await secondTransport.header("If-None-Match", ofRequest: 0)
        XCTAssertEqual(conditional, "\"a-1\"")

        // 3. A body that was not consumed (an item the connector could not translate): the endpoint
        //    declared a new validator and it is NOT adopted.
        let (third, _) = makeConnector(
            [.ok(TestFixtures.rssWithEmptyItem, headers: ["ETag": "\"a-2\""])],
            target: target
        )
        let thirdOutcome = try await third.acquire(
            limit: TestFixtures.limit(),
            checkpoint: confirmed.proposedCheckpoint
        )
        guard case .batch(let unconsumed) = thirdOutcome else {
            return XCTFail("expected a batch, got \(thirdOutcome)")
        }
        XCTAssertFalse(unconsumed.proposesValidatorConfirmation)
        XCTAssertEqual(unconsumed.proposedCheckpoint, confirmed.proposedCheckpoint)
        XCTAssertEqual(unconsumed.proposedCheckpoint.validators.etag, "\"a-1\"")
    }

    func testParseFailureOnHTTP200DoesNotConfirmValidator() async throws {
        let target = try target()
        let checkpoint = admittedCheckpoint(for: target)
        let (connector, transport) = makeConnector(
            [.ok(TestFixtures.notAFeed, headers: ["ETag": "\"a-2\""])],
            target: target
        )
        let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: checkpoint)

        guard case .parseFailure(let reason, let afterFailure) = outcome else {
            return XCTFail("expected a parse failure, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        // The checkpoint is byte-for-byte the one that came in: no validator advanced, no baseline
        // moved, no representation record changed.
        XCTAssertEqual(afterFailure, checkpoint)
        XCTAssertEqual(afterFailure.validators.etag, "\"a-1\"")
        XCTAssertEqual(afterFailure.observedRepresentations, checkpoint.observedRepresentations)

        // It really was a conditional request: the failure is a parse failure, not an empty fetch.
        let conditional = await transport.header("If-None-Match", ofRequest: 0)
        XCTAssertEqual(conditional, "\"a-1\"")
    }

    func testZeroExtractedObservationsDoesNotConfirmValidator() async throws {
        let target = try target()

        // A parsed document whose items could not be extracted: the endpoint declared a new
        // validator and it must not be adopted (ADR-005 D12).
        let checkpoint = admittedCheckpoint(for: target)
        let (unmappable, _) = makeConnector(
            [.ok(TestFixtures.rssWithEmptyItem, headers: ["ETag": "\"a-2\""])],
            target: target
        )
        let unmappableOutcome = try await unmappable.acquire(
            limit: TestFixtures.limit(),
            checkpoint: checkpoint
        )
        guard case .batch(let unmapped) = unmappableOutcome else {
            return XCTFail("expected a batch, got \(unmappableOutcome)")
        }
        XCTAssertTrue(unmapped.batch.observations.isEmpty)
        XCTAssertEqual(unmapped.translation.rejections.count, 1)
        XCTAssertFalse(unmapped.proposesValidatorConfirmation)
        XCTAssertEqual(unmapped.proposedCheckpoint, checkpoint)
        XCTAssertEqual(unmapped.proposedCheckpoint.validators.etag, "\"a-1\"")

        // A valid document that declares no observations at all may confirm one: the connector can
        // tell the two apart.
        let (empty, _) = makeConnector(
            [.ok(TestFixtures.rssEmptyChannel, headers: ["ETag": "\"a-2\""])],
            target: target
        )
        let emptyOutcome = try await empty.acquire(limit: TestFixtures.limit(), checkpoint: checkpoint)
        guard case .batch(let quiet) = emptyOutcome else {
            return XCTFail("expected a batch, got \(emptyOutcome)")
        }
        XCTAssertTrue(quiet.batch.observations.isEmpty)
        XCTAssertTrue(quiet.translation.rejections.isEmpty)
        XCTAssertTrue(quiet.proposesValidatorConfirmation)
        XCTAssertEqual(quiet.proposedCheckpoint.validators.etag, "\"a-2\"")
        XCTAssertTrue(quiet.proposedCheckpoint.hasAdmittedBaseline)
    }

    // MARK: - Missing body and endpoint change

    func testMissingBodyRequiresUnconditionalFetch() async throws {
        let target = try target()
        // A validator inherited from a rebuild or a migration: V2 never received this endpoint's body.
        let inherited = SyndicationCheckpoint(
            generation: target.generation,
            endpoint: target.endpoint.absoluteString,
            validators: SyndicationValidators(etag: "\"a-1\""),
            hasAdmittedBaseline: false,
            observedRepresentations: [:]
        )

        let (connector, transport) = makeConnector([.status(304)], target: target)
        let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: inherited)

        // The fetch was unconditional, so a 304 can neither be trusted nor confirm anything.
        let conditional = await transport.header("If-None-Match", ofRequest: 0)
        let since = await transport.header("If-Modified-Since", ofRequest: 0)
        XCTAssertNil(conditional)
        XCTAssertNil(since)
        guard case .refused(let refusal, let afterRefusal) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(refusal, .notModifiedWithoutConditionalRequest)
        XCTAssertEqual(afterRefusal, inherited)

        // The unconditional fetch that follows does produce the baseline the validator needs.
        let (retry, _) = makeConnector(
            [.ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"a-1\""])],
            target: target
        )
        let retried = try await retry.acquire(limit: TestFixtures.limit(), checkpoint: inherited)
        guard case .batch(let baseline) = retried else { return XCTFail("expected a batch, got \(retried)") }
        XCTAssertTrue(baseline.proposedCheckpoint.hasAdmittedBaseline)
        XCTAssertEqual(baseline.proposedCheckpoint.validators.etag, "\"a-1\"")
    }

    func testEndpointChangedDiscardsPreviousValidator() async throws {
        let target = try target()
        // Validators learned from another endpoint — a different host, or an earlier generation:
        // neither may be re-applied to this target (ADR-005 D10, D12).
        let otherHost = SyndicationCheckpoint.initial(
            generation: target.generation,
            endpoint: try TestFixtures.url(TestFixtures.otherEndpoint)
        ).adoptingBaseline(
            validators: SyndicationValidators(etag: "\"b-1\""),
            endpoint: try TestFixtures.url(TestFixtures.otherEndpoint),
            observedRepresentations: [:]
        )
        let oldGeneration = SyndicationCheckpoint.initial(
            generation: target.generation - 1,
            endpoint: target.endpoint
        ).adoptingBaseline(
            validators: SyndicationValidators(etag: "\"old-1\""),
            endpoint: target.endpoint,
            observedRepresentations: [:]
        )

        for stale in [otherHost, oldGeneration] {
            let (connector, transport) = makeConnector(
                [.ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"a-1\""])],
                target: target
            )
            let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: stale)
            let conditional = await transport.header("If-None-Match", ofRequest: 0)
            XCTAssertNil(conditional, "a validator from \(stale.endpoint) may not be sent to \(target.endpoint)")

            guard case .batch(let result) = outcome else {
                return XCTFail("expected a batch, got \(outcome)")
            }
            XCTAssertEqual(result.proposedCheckpoint.endpoint, target.endpoint.absoluteString)
            XCTAssertEqual(result.proposedCheckpoint.validators.etag, "\"a-1\"")
            XCTAssertEqual(result.proposedCheckpoint.generation, target.generation)
        }
    }

    func testRedirectDoesNotTransferValidatorToNewEndpoint() async throws {
        let target = try target()
        let checkpoint = admittedCheckpoint(for: target)
        let moved = "\(TestFixtures.otherEndpoint)?token=secret"

        let (connector, transport) = makeConnector(
            [
                .status(301, headers: ["Location": moved]),
                .ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"b-1\""]),
            ],
            target: target
        )
        let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: checkpoint)
        guard case .batch(let result) = outcome else { return XCTFail("expected a batch, got \(outcome)") }

        let firstETag = await transport.header("If-None-Match", ofRequest: 0)
        let redirectedETag = await transport.header("If-None-Match", ofRequest: 1)
        XCTAssertEqual(firstETag, "\"a-1\"")
        XCTAssertNil(redirectedETag, "the previous endpoint's validator must not follow a redirect")
        XCTAssertEqual(result.redirectChain.count, 2)

        // The validators belong to the endpoint that issued them: the moved endpoint, without the
        // query the redirect carried.
        XCTAssertEqual(result.endpoint, try TestFixtures.url(TestFixtures.otherEndpoint))
        XCTAssertEqual(result.proposedCheckpoint.endpoint, TestFixtures.otherEndpoint)
        XCTAssertEqual(result.proposedCheckpoint.validators.etag, "\"b-1\"")

        // Query strings are personal data: the redirect is recorded without it (ADR-005 D14).
        let audit = result.batch.evidence
            .filter { $0.kind == .other }
            .compactMap { $0.bytes }
            .compactMap { String(decoding: $0, as: UTF8.self) }
            .joined(separator: " ")
        XCTAssertTrue(audit.contains("b.example.com"))
        XCTAssertFalse(audit.contains("token=secret"))
        XCTAssertFalse(audit.contains("?"))

        // The next run is addressed to the configured endpoint, so the moved endpoint's validator is
        // not reusable there: the fetch is unconditional (invariant 7).
        let (followUp, followUpTransport) = makeConnector([.status(304)], target: target)
        let followUpOutcome = try await followUp.acquire(
            limit: TestFixtures.limit(),
            checkpoint: result.proposedCheckpoint
        )
        let followUpETag = await followUpTransport.header("If-None-Match", ofRequest: 0)
        XCTAssertNil(followUpETag)
        guard case .refused(let refusal, _) = followUpOutcome else {
            return XCTFail("expected a refusal, got \(followUpOutcome)")
        }
        XCTAssertEqual(refusal, .notModifiedWithoutConditionalRequest)

        // And the redirect limit stops the work with a usable checkpoint (D9, D14).
        let (limited, limitedTransport) = makeConnector(
            [.status(301, headers: ["Location": moved])],
            target: target,
            limits: SyndicationHTTPLimits(maxRedirects: 0)
        )
        let limitedOutcome = try await limited.acquire(limit: TestFixtures.limit(), checkpoint: checkpoint)
        guard case .refused(let limitRefusal, let afterLimit) = limitedOutcome else {
            return XCTFail("expected a refusal, got \(limitedOutcome)")
        }
        XCTAssertEqual(limitRefusal, .redirectLimitExceeded(limit: 0))
        XCTAssertEqual(afterLimit, checkpoint)
        let attempts = await limitedTransport.requestCount
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Throttling and fairness

    func testThrottledHostDoesNotConsumeGlobalConnectionBudget() async throws {
        let throttledTarget = try target()
        let healthyTarget = try SyndicationTarget.fixture(
            targetID: "target-2",
            endpoint: TestFixtures.otherEndpoint,
            sourceKey: "binding-fingerprint-2"
        )
        let gate = SyndicationHostGate().recording(
            url: throttledTarget.endpoint,
            until: TestFixtures.observedAt.addingTimeInterval(60)
        )

        let (throttled, throttledTransport) = makeConnector([], target: throttledTarget, gate: gate)
        let throttledOutcome = try await throttled.acquire(limit: TestFixtures.limit(), checkpoint: nil)
        guard case .hostInBackoff(let host, let until, _) = throttledOutcome else {
            return XCTFail("expected hostInBackoff, got \(throttledOutcome)")
        }
        XCTAssertEqual(host, "a.example.com")
        XCTAssertEqual(until, TestFixtures.observedAt.addingTimeInterval(60))
        // The throttled host issued no request at all: it consumed nothing from the shared budget.
        let throttledAttempts = await throttledTransport.requestCount
        XCTAssertEqual(throttledAttempts, 0)

        // The same gate leaves the healthy host under the same global budget untouched.
        let (healthy, healthyTransport) = makeConnector(
            [.ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"b-1\""])],
            target: healthyTarget,
            gate: gate
        )
        let healthyOutcome = try await healthy.acquire(limit: TestFixtures.limit(), checkpoint: nil)
        guard case .batch = healthyOutcome else {
            return XCTFail("expected the healthy host to work, got \(healthyOutcome)")
        }
        let healthyAttempts = await healthyTransport.requestCount
        XCTAssertEqual(healthyAttempts, 1)
    }

    func testThrottledResponseKeepsTheCheckpointAndCarriesTheJitteredInstant() async throws {
        let target = try target()
        let checkpoint = admittedCheckpoint(for: target)
        let (connector, _) = makeConnector(
            [.status(429, headers: ["Retry-After": "120"])],
            target: target
        )
        let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: checkpoint)

        guard case .throttled(let until, let retryAfter, let afterThrottle) = outcome else {
            return XCTFail("expected throttled, got \(outcome)")
        }
        XCTAssertEqual(retryAfter, 120)
        XCTAssertEqual(until, TestFixtures.observedAt.addingTimeInterval(120))
        // A throttle is a health fact, never a content change: the checkpoint is untouched.
        XCTAssertEqual(afterThrottle, checkpoint)

        let (unavailable, _) = makeConnector(
            [.status(503, headers: ["Retry-After": "600"])],
            target: target
        )
        let unavailableOutcome = try await unavailable.acquire(
            limit: TestFixtures.limit(),
            checkpoint: checkpoint
        )
        guard case .throttled(let unavailableUntil, _, _) = unavailableOutcome else {
            return XCTFail("expected throttled, got \(unavailableOutcome)")
        }
        XCTAssertEqual(unavailableUntil, TestFixtures.observedAt.addingTimeInterval(600))
    }

    // MARK: - Other outcomes

    func testTransportFailureIsClassifiedAndRetryableWithoutTouchingTheCheckpoint() async throws {
        let target = try target()
        let checkpoint = admittedCheckpoint(for: target)
        let (connector, _) = makeConnector([.failure(.timedOut)], target: target)
        let outcome = try await connector.acquire(limit: TestFixtures.limit(), checkpoint: checkpoint)

        guard case .transportFailure(let failureClass, let retryable, let afterFailure) = outcome else {
            return XCTFail("expected a transport failure, got \(outcome)")
        }
        XCTAssertEqual(failureClass, .timedOut)
        XCTAssertTrue(retryable)
        XCTAssertEqual(afterFailure, checkpoint)
    }

    func testUnhandledStatusAndPastDeadlineLeaveTheCheckpointUsable() async throws {
        let target = try target()
        let checkpoint = admittedCheckpoint(for: target)

        let (notFound, _) = makeConnector([.status(404, body: "gone")], target: target)
        let notFoundOutcome = try await notFound.acquire(
            limit: TestFixtures.limit(),
            checkpoint: checkpoint
        )
        guard case .unhandledStatus(let status, let afterNotFound) = notFoundOutcome else {
            return XCTFail("expected an unhandled status, got \(notFoundOutcome)")
        }
        XCTAssertEqual(status, 404)
        XCTAssertEqual(afterNotFound, checkpoint)

        // A caller whose deadline has already passed issues nothing and keeps its checkpoint.
        let (expired, expiredTransport) = makeConnector([], target: target)
        let expiredOutcome = try await expired.acquire(
            limit: TestFixtures.limit(deadline: TestFixtures.observedAt.addingTimeInterval(-1)),
            checkpoint: checkpoint
        )
        guard case .deadlineReached(let afterDeadline) = expiredOutcome else {
            return XCTFail("expected deadlineReached, got \(expiredOutcome)")
        }
        XCTAssertEqual(afterDeadline, checkpoint)
        let attempts = await expiredTransport.requestCount
        XCTAssertEqual(attempts, 0)
    }

    // MARK: - The PR-01 protocol surface

    func testFeedConnectorConformanceFetchesUnconditionallyAndRefusesNonBatchOutcomes() async throws {
        let target = try target()
        let (connector, transport) = makeConnector(
            [.ok(TestFixtures.rssTwoItems, headers: ["ETag": "\"a-1\""])],
            target: target
        )
        let batch = try await connector.acquire(limit: TestFixtures.limit())
        XCTAssertEqual(batch.targetID, target.targetID)
        XCTAssertEqual(batch.observations.count, 2)
        // With no checkpoint input this surface can only fetch unconditionally.
        let conditional = await transport.header("If-None-Match", ofRequest: 0)
        XCTAssertNil(conditional)

        // Anything that is not a batch is reported, never flattened into an empty batch.
        let (failing, _) = makeConnector([.ok(TestFixtures.notAFeed)], target: target)
        do {
            _ = try await failing.acquire(limit: TestFixtures.limit())
            XCTFail("a non-batch outcome must not be reported as a batch")
        } catch let error as SyndicationConnectorError {
            guard case .nonBatchOutcome(.parseFailure) = error else {
                return XCTFail("expected a parse failure outcome, got \(error)")
            }
        }
    }
}
