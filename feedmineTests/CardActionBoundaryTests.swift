import XCTest
import FeedDomain
import FeedRuntime
@testable import feedmine

/// PR-14 item 4: a card's action has a stable identity, it is validated against the capability and the
/// resource the surface grants *now*, and the renderer never infers an action from the item's protocol.
///
/// `actionExecutesWithoutProtocolBranchInView` is the test plan §19 #38 names. It is written as
/// behaviour rather than as a source scan: three items of three legacy protocols (a YouTube link, a
/// Reddit source, a plain article) whose published affordance is flipped between "open the reader" and
/// "play the card" — the action follows the presentation every time, and the protocol flags change
/// nothing. If a view went back to deciding by `isYouTube`/`isPodcast`/`isForum`, the affordance flip
/// would stop deciding and this test would fail.
@MainActor
final class CardActionBoundaryTests: XCTestCase {

    private let edition = try! EditionID(5)
    private let capabilities = CardActionCapabilities(generation: 1)

    // MARK: - No protocol branch

    func test_actionExecutesWithoutProtocolBranchInView() throws {
        let youtube = makeItem(id: "yt", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let forum = makeItem(id: "rd", sourceURL: "https://reddit.com/r/swift/comments/abc")
        let article = makeItem(id: "ar", url: "https://example.com/post")

        // The legacy inference really does disagree between these three; if it did not, the test would
        // be proving nothing.
        XCTAssertTrue(youtube.isYouTube)
        XCTAssertTrue(forum.isForum)
        XCTAssertFalse(youtube.isForum)
        XCTAssertFalse(article.isYouTube)

        for item in [youtube, forum, article] {
            let reader = try XCTUnwrap(offer(item: item, tap: .openReader))
            XCTAssertEqual(reader.action.kind, .externalURL, "\(item.id): the presentation asked for the reader")

            let audio = try XCTUnwrap(offer(item: item, tap: .playAudio))
            XCTAssertEqual(audio.action.kind, .mediaPlayback, "\(item.id): the presentation asked for playback")
            XCTAssertNotEqual(reader.id, audio.id, "two different actions are two different identities")
        }
    }

    /// The one item fact that *can* change the action is whether there is anything to play. That is
    /// data the producer decided, not a protocol the renderer sniffed.
    func testEnclosurePresenceDecidesTheCombinedAffordance() throws {
        let withEnclosure = makeItem(id: "pod", audioURL: "https://cdn.example.com/ep.mp3")
        let withoutEnclosure = makeItem(id: "plain")

        let playing = try XCTUnwrap(offer(item: withEnclosure, tap: .openReaderOrPlayAudioFromMedia))
        XCTAssertEqual(playing.action.kind, .mediaPlayback)

        let reading = try XCTUnwrap(offer(item: withoutEnclosure, tap: .openReaderOrPlayAudioFromMedia))
        XCTAssertEqual(reading.action.kind, .externalURL)
    }

    // MARK: - Identity

    func testActionIdentityIsStableAndDoesNotCarryTheLocation() throws {
        let item = makeItem(id: "a", url: "https://example.com/secret-path?token=abc")
        let card = makeCard(item: item, tap: .openReader)

        let first = try XCTUnwrap(offer(item: item, card: card, tap: .openReader))
        let again = try XCTUnwrap(offer(item: item, card: card, tap: .openReader))
        XCTAssertEqual(first.id, again.id, "the same offer keeps the same identity")

        let other = try XCTUnwrap(offer(item: makeItem(id: "a", url: "https://example.com/other"), card: card, tap: .openReader))
        XCTAssertNotEqual(first.id, other.id, "a different location is a different action")

        XCTAssertFalse(
            first.id.rawValue.contains("example.com"),
            "the handle is opaque: a renderer cannot read a protocol out of it"
        )
        XCTAssertFalse(first.id.rawValue.contains("secret-path"))
    }

    // MARK: - Validation

    func testAnActionIsRefusedWhenTheCapabilityGenerationMovedOn() async throws {
        let item = makeItem(id: "stale", url: "https://example.com/post")
        let offer = try XCTUnwrap(offer(item: item, tap: .openReader))

        var effects = 0
        let outcome = await CardActionBridge.perform(
            offer,
            capabilities: CardActionCapabilities(generation: 2),
            resources: CardActionResources(hasPlaybackMaterial: false),
            effect: { _ in effects += 1; return "opened" }
        )

        XCTAssertEqual(
            outcome.rejection,
            .capabilityRevoked(kind: .reader, presented: 1, current: 2),
            "a card whose surface moved on is refused before anything is executed"
        )
        XCTAssertEqual(effects, 0)
    }

    func testAPlaybackActionIsRefusedWhenTheCardHasNothingToPlay() async throws {
        let item = makeItem(id: "silent")
        let offer = try XCTUnwrap(offer(item: item, tap: .playAudio))

        var effects = 0
        let outcome = await CardActionBridge.perform(
            offer,
            capabilities: capabilities,
            resources: CardActionResources(hasPlaybackMaterial: false),
            effect: { _ in effects += 1; return "played" }
        )

        guard case .resourceUnavailable(let resource, let reason) = outcome.rejection else {
            return XCTFail("expected a resource refusal, got \(outcome)")
        }
        XCTAssertEqual(resource, .publishedMedia("silent"))
        XCTAssertFalse(reason.isEmpty, "a refusal says what is missing")
        XCTAssertEqual(effects, 0)
    }

    func testAConversationActionIsNotGrantedInThisBuild() async throws {
        let offer = try ActionOffer(
            editionID: edition,
            cardID: try PublicationCardID(11),
            action: .thread(try InteractionHandle("thread-1")),
            capability: ActionCapability(kind: .thread, generation: 1)
        )

        var effects = 0
        let outcome = await CardActionBridge.perform(
            offer,
            capabilities: capabilities,
            resources: CardActionResources(hasPlaybackMaterial: false),
            effect: { _ in effects += 1; return "opened" }
        )

        XCTAssertEqual(outcome.rejection, .capabilityNotGranted(.thread))
        XCTAssertEqual(effects, 0)
    }

    func testAGrantedActionExecutesTheEffectOnce() async throws {
        let item = makeItem(id: "good", url: "https://example.com/post")
        let offer = try XCTUnwrap(offer(item: item, tap: .openReader))

        var executed: [FeedPrimaryAction] = []
        let outcome = await CardActionBridge.perform(
            offer,
            capabilities: capabilities,
            resources: CardActionResources(hasPlaybackMaterial: false),
            effect: { action in executed.append(action); return "reader" }
        )

        XCTAssertEqual(outcome.receipt?.detail, "reader")
        XCTAssertEqual(outcome.receipt?.id, offer.id)
        XCTAssertEqual(executed, [.externalURL(URL(string: "https://example.com/post")!)])
    }

    // MARK: - Helpers

    private func offer(
        item: FeedItem,
        card: CardPresentation? = nil,
        tap: CardPresentation.Affordances.Tap
    ) throws -> ActionOffer? {
        try CardActionBridge.offer(
            item: item,
            card: card ?? makeCard(item: item, tap: tap),
            editionID: edition,
            capabilityGeneration: capabilities.generation
        )
    }

    private func makeCard(item: FeedItem, tap: CardPresentation.Affordances.Tap) -> CardPresentation {
        CardPresentation(
            id: try! PublicationCardID(7),
            absoluteOrdinal: 0,
            title: item.title,
            subtitle: nil,
            media: .none,
            layout: .textOnly,
            isBookmarked: false,
            isRead: false,
            affordances: CardPresentation.Affordances(
                placeholder: .article,
                overlay: nil,
                badges: [],
                durationLabel: nil,
                tap: tap
            )
        )
    }

    private func makeItem(
        id: String,
        url: String = "https://example.com/a",
        audioURL: String? = nil,
        sourceURL: String = "https://example.com/feed"
    ) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Test Source",
            sourceURL: sourceURL,
            category: "News",
            title: "Title \(id)",
            excerpt: "Excerpt",
            url: url,
            imageURL: nil,
            publishedAt: Date(),
            audioURL: audioURL,
            duration: nil,
            region: "imported",
            language: "en",
            updatedAt: nil,
            authors: nil,
            itemCategories: nil,
            rights: nil,
            attribution: nil,
            enclosures: nil,
            languageFromFeed: nil,
            alternateLinks: nil
        )
    }
}
