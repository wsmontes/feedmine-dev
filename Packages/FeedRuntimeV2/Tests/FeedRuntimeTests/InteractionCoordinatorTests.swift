import Foundation
import XCTest
import FeedDomain
import FeedRuntime

/// PR-14, interaction half: the boundary where a published action handle becomes an executed action
/// (ADR-001 D16, plan §19 #38, Technical Architecture I-05).
///
/// `actionExecutesWithoutProtocolBranchInView` is the plan's named test, and it is the reason the
/// renderer hands an offer back untouched: the caller here never reads a URL to decide what a card
/// does. Every rejection is a value the coordinator states, so a card whose action cannot run says so
/// instead of doing nothing.
final class InteractionCoordinatorTests: XCTestCase {

    // MARK: - Doubles

    private struct StubCapabilities: ActionCapabilityProvider {
        let granted: [ActionCapability.Kind: ActionCapability]

        func currentCapability(for kind: ActionCapability.Kind) -> ActionCapability? {
            granted[kind]
        }
    }

    private struct StubResources: ActionResourceProbe {
        let availabilityByResource: [ActionResource: ActionResourceAvailability]

        func availability(of resource: ActionResource) -> ActionResourceAvailability {
            availabilityByResource[resource] ?? .available
        }
    }

    private enum ExecutorRefusal: Error, Equatable {
        case refused
    }

    private actor RecordingExecutor: ActionExecuting {
        private var offers: [ActionOffer] = []
        private let refusal: ExecutorRefusal?

        init(refusal: ExecutorRefusal? = nil) {
            self.refusal = refusal
        }

        func execute(_ offer: ActionOffer) async throws -> ActionReceipt {
            offers.append(offer)
            if let refusal { throw refusal }
            return ActionReceipt(id: offer.id, detail: offer.action.reference)
        }

        func recordedOffers() -> [ActionOffer] { offers }
    }

    // MARK: - Fixtures

    private func makeOffer(
        edition: Int64 = 7,
        card: Int64 = 11,
        action: FeedPrimaryAction,
        generation: Int = 1
    ) throws -> ActionOffer {
        try ActionOffer(
            editionID: try EditionID(edition),
            cardID: try PublicationCardID(card),
            action: action,
            capability: ActionCapability(kind: action.capabilityKind, generation: generation)
        )
    }

    private func coordinator(
        granting kinds: [ActionCapability.Kind: ActionCapability] = [:],
        resources: StubResources = StubResources(availabilityByResource: [:]),
        executor: RecordingExecutor
    ) -> InteractionCoordinator {
        InteractionCoordinator(
            capabilities: StubCapabilities(granted: kinds),
            resources: resources,
            executor: executor
        )
    }

    /// The frozen payload a card publishes, with the action it carries. Built here from
    /// `PublishedCardPayload.Frozen` alone, so this suite needs no database and no storage fixture.
    private func frozen(primaryAction: FeedPrimaryAction?) throws -> PublishedCardPayload.Frozen {
        PublishedCardPayload.Frozen(
            editionID: try EditionID(7),
            segmentOrdinal: 0,
            absoluteOrdinal: 0,
            origin: PublishedOrigin(
                originRecordID: try OriginRecordID(1),
                originRevisionID: try OriginRevisionID(1)
            ),
            title: "Headline",
            primaryText: nil,
            publishedAt: nil,
            publishedAtKind: .none,
            observationAt: Date(timeIntervalSince1970: 1_700_000_000),
            media: .none,
            primaryAction: primaryAction,
            interactionSummary: nil,
            renderContract: RenderContract(
                version: RenderContract.currentVersion,
                kind: .textOnly,
                mediaSlot: .none,
                aspectRatio: nil
            ),
            editorialRevision: try EditorialRevision(
                schemeVersion: EditorialRevision.currentSchemeVersion,
                digest: String(repeating: "a", count: 64)
            )
        )
    }

    // MARK: - The named plan test

    /// Two published actions of different kinds both execute, and the executor receives the exact
    /// handle the card published: the caller decided nothing about the action.
    func test_actionExecutesWithoutProtocolBranchInView() async throws {
        let playback = FeedPrimaryAction.mediaPlayback("asset-a1b2c3")
        let connector = FeedPrimaryAction.connectorAction(try ActionID("connector-42"))
        let granted: [ActionCapability.Kind: ActionCapability] = [
            .mediaPlayback: ActionCapability(kind: .mediaPlayback, generation: 1),
            .connectorAction: ActionCapability(kind: .connectorAction, generation: 1),
        ]
        let executor = RecordingExecutor()
        let coordinator = coordinator(granting: granted, executor: executor)

        let playbackOffer = try makeOffer(action: playback)
        let connectorOffer = try makeOffer(card: 12, action: connector)

        let playbackOutcome = await coordinator.perform(playbackOffer)
        let connectorOutcome = await coordinator.perform(connectorOffer)

        XCTAssertEqual(playbackOutcome.receipt?.id, playbackOffer.id)
        XCTAssertEqual(connectorOutcome.receipt?.id, connectorOffer.id)
        XCTAssertEqual(
            playbackOutcome.receipt?.detail,
            playback.reference,
            "the receipt names the published reference the executor saw"
        )
        XCTAssertEqual(connectorOutcome.receipt?.detail, connector.reference)

        let recorded = await executor.recordedOffers()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.first?.action, playback, "the executor receives exactly the published handle")
        XCTAssertEqual(recorded.last?.action, connector)
        XCTAssertEqual(recorded.first?.id, playbackOffer.id)
    }

    /// The lookup is keyed by the action's own `capabilityKind`: a grant for a different kind does not
    /// satisfy a playback offer, even at the same generation.
    func test_offerIsRoutedByTheActionsOwnCapabilityKind() async throws {
        let executor = RecordingExecutor()
        let coordinator = coordinator(
            granting: [.connectorAction: ActionCapability(kind: .connectorAction, generation: 3)],
            executor: executor
        )
        let offer = try makeOffer(action: .mediaPlayback("asset-a1b2c3"), generation: 3)

        let outcome = await coordinator.perform(offer)

        XCTAssertEqual(outcome.rejection, ActionRejection.capabilityNotGranted(.mediaPlayback))
        let calls = await executor.recordedOffers()
        XCTAssertEqual(calls.count, 0)
    }

    /// An offer published under an older capability generation is revoked; the same offer under the
    /// generation the provider reports now runs. The rejection names both generations.
    func test_capabilityGenerationMismatchIsRevoked() async throws {
        let action = FeedPrimaryAction.thread(try InteractionHandle("thread-7"))
        let executor = RecordingExecutor()
        let stale = coordinator(
            granting: [.thread: ActionCapability(kind: .thread, generation: 2)],
            executor: executor
        )
        let offer = try makeOffer(action: action, generation: 1)

        let revoked = await stale.perform(offer)
        XCTAssertEqual(
            revoked.rejection,
            ActionRejection.capabilityRevoked(kind: .thread, presented: 1, current: 2)
        )
        let revokedCalls = await executor.recordedOffers()
        XCTAssertEqual(revokedCalls.count, 0, "a revoked offer reaches no executor")

        let current = coordinator(
            granting: [.thread: ActionCapability(kind: .thread, generation: 2)],
            executor: executor
        )
        let sameGeneration = try makeOffer(action: action, generation: 2)
        let executed = await current.perform(sameGeneration)
        XCTAssertNotNil(executed.receipt)
        let executedCalls = await executor.recordedOffers()
        XCTAssertEqual(executedCalls.count, 1)
    }

    /// A provider that grants nothing for the kind rejects the offer and never invokes the executor.
    func test_providerWithNoGrantRejectsWithoutExecuting() async throws {
        let executor = RecordingExecutor()
        let coordinator = coordinator(executor: executor)
        let offer = try makeOffer(action: .externalURL(try XCTUnwrap(URL(string: "https://example.test/a"))))

        let outcome = await coordinator.perform(offer)

        XCTAssertEqual(outcome.rejection, ActionRejection.capabilityNotGranted(.reader))
        let calls = await executor.recordedOffers()
        XCTAssertEqual(calls.count, 0)
    }

    /// A resource the probe reports as unavailable rejects the offer with the probe's reason, and the
    /// executor is never invoked; the same offer with the resource available runs.
    func test_unavailableResourceRejectsBeforeExecution() async throws {
        let action = FeedPrimaryAction.mediaPlayback("asset-a1b2c3")
        let offer = try makeOffer(action: action)
        let granted: [ActionCapability.Kind: ActionCapability] = [
            .mediaPlayback: ActionCapability(kind: .mediaPlayback, generation: 1),
        ]
        let executor = RecordingExecutor()

        let evicted = coordinator(
            granting: granted,
            resources: StubResources(
                availabilityByResource: [.publishedMedia("asset-a1b2c3"): .unavailable(reason: "asset evicted")]
            ),
            executor: executor
        )
        let refused = await evicted.perform(offer)
        XCTAssertEqual(
            refused.rejection,
            ActionRejection.resourceUnavailable(.publishedMedia("asset-a1b2c3"), reason: "asset evicted")
        )
        let unavailableCalls = await executor.recordedOffers()
        XCTAssertEqual(unavailableCalls.count, 0, "an unavailable resource reaches no executor")

        let available = coordinator(
            granting: granted,
            resources: StubResources(
                availabilityByResource: [.publishedMedia("asset-a1b2c3"): .available]
            ),
            executor: executor
        )
        let executed = await available.perform(offer)
        XCTAssertNotNil(executed.receipt)
        let availableCalls = await executor.recordedOffers()
        XCTAssertEqual(availableCalls.count, 1)
    }

    /// A card-local action needs the card the edition itself holds: the resource is derived from the
    /// offer's edition and card, not from the action alone.
    func test_cardLocalActionNeedsThePublishedCardResource() async throws {
        let cardID = try PublicationCardID(11)
        let offer = try makeOffer(edition: 7, card: 11, action: .localContentDetail(cardID))
        XCTAssertEqual(
            offer.resource,
            ActionResource.publishedCard(try EditionID(7), cardID),
            "the card-local resource names the edition and the card"
        )

        let executor = RecordingExecutor()
        let coordinator = coordinator(
            granting: [.localCardDetail: ActionCapability(kind: .localCardDetail, generation: 1)],
            resources: StubResources(
                availabilityByResource: [
                    .publishedCard(try EditionID(7), cardID): .unavailable(reason: "card purged"),
                ]
            ),
            executor: executor
        )

        let outcome = await coordinator.perform(offer)
        XCTAssertEqual(
            outcome.rejection,
            ActionRejection.resourceUnavailable(.publishedCard(try EditionID(7), cardID), reason: "card purged")
        )
        let calls = await executor.recordedOffers()
        XCTAssertEqual(calls.count, 0)
    }

    /// An executor that throws is a stated refusal, never a silent success.
    func test_throwingExecutorIsRefused() async throws {
        let executor = RecordingExecutor(refusal: .refused)
        let coordinator = coordinator(
            granting: [.mediaPlayback: ActionCapability(kind: .mediaPlayback, generation: 1)],
            executor: executor
        )
        let offer = try makeOffer(action: .mediaPlayback("asset-a1b2c3"))

        let outcome = await coordinator.perform(offer)

        XCTAssertEqual(outcome.rejection, ActionRejection.refusedByExecutor("refused"))
        let calls = await executor.recordedOffers()
        XCTAssertEqual(calls.count, 1, "the executor was asked and said no")
    }

    /// The id is derived, so the same four parts always address the same action, and each part
    /// participates. It is opaque: the reference is hashed, never embedded, so a renderer cannot read
    /// the URL out of the id.
    func test_actionIDIsDerivedFromItsPartsAndStaysOpaque() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/articles/secret-path?token=abc"))
        let otherURL = try XCTUnwrap(URL(string: "https://example.test/articles/secret-path?token=xyz"))
        let action = FeedPrimaryAction.externalURL(url)

        let first = try makeOffer(action: action, generation: 4)
        let again = try makeOffer(action: action, generation: 4)
        XCTAssertEqual(first.id, again.id, "a rerender addresses the same action")

        let otherEdition = try makeOffer(edition: 8, action: action, generation: 4)
        let otherCard = try makeOffer(card: 12, action: action, generation: 4)
        let otherReference = try makeOffer(
            action: .externalURL(otherURL),
            generation: 4
        )
        let otherGeneration = try makeOffer(action: action, generation: 5)
        let otherKind = try makeOffer(action: .thread(try InteractionHandle("thread-7")), generation: 4)

        for (label, offer) in [
            ("edition", otherEdition),
            ("card", otherCard),
            ("reference", otherReference),
            ("capability generation", otherGeneration),
            ("kind", otherKind),
        ] {
            XCTAssertNotEqual(offer.id, first.id, "changing the \(label) changes the id")
        }

        XCTAssertFalse(first.id.rawValue.contains("secret-path"), "the id is opaque: no URL text")
        XCTAssertFalse(first.id.rawValue.contains("example.test"))
        XCTAssertFalse(first.id.rawValue.contains("token"))
        XCTAssertTrue(
            first.id.rawValue.allSatisfy { $0.isHexDigit },
            "the id is a digest, not a concatenation of its parts"
        )
    }

    /// The vocabulary is closed on both sides: an offer whose capability kind does not match the
    /// action is refused when it is built, not when it is performed.
    func test_offerRefusesAMismatchedCapabilityKind() throws {
        let action = FeedPrimaryAction.externalURL(try XCTUnwrap(URL(string: "https://example.test/a")))
        XCTAssertThrowsError(
            try ActionOffer(
                editionID: try EditionID(7),
                cardID: try PublicationCardID(11),
                action: action,
                capability: ActionCapability(kind: .mediaPlayback, generation: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? InteractionError,
                InteractionError.capabilityKindMismatch(action: .externalURL, capability: .mediaPlayback)
            )
        }
    }

    /// A card that publishes no action offers none: absence is valid, and no URL is invented for it.
    func test_offerOfReturnsNilWhenTheCardPublishesNoAction() throws {
        let cardID = try PublicationCardID(11)
        let silent = PublishedCardPayload(cardID: cardID, frozen: try frozen(primaryAction: nil))
        XCTAssertNil(
            try ActionOffer.of(card: silent, cardID: cardID, capabilityGeneration: 1),
            "no action means no offer, and no synthesized URL"
        )

        let playing = PublishedCardPayload(
            cardID: cardID,
            frozen: try frozen(primaryAction: .mediaPlayback("asset-a1b2c3"))
        )
        let offer = try XCTUnwrap(
            ActionOffer.of(card: playing, cardID: cardID, capabilityGeneration: 2)
        )
        XCTAssertEqual(offer.action, .mediaPlayback("asset-a1b2c3"))
        XCTAssertEqual(offer.capability, ActionCapability(kind: .mediaPlayback, generation: 2))
        XCTAssertEqual(offer.editionID, playing.frozen.editionID)
    }
}
