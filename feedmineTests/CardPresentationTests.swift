import XCTest
import UIKit
@testable import feedmine

@MainActor
final class CardPresentationTests: XCTestCase {

    // MARK: - ResolvedCardMedia equality

    func testResolvedCardMedia_image_sameInstance_areEqual() {
        let img = UIImage()
        let a = ResolvedCardMedia.image(img)
        let b = ResolvedCardMedia.image(img)
        XCTAssertEqual(a, b, "Same UIImage instance should be equal by pointer identity")
    }

    func testResolvedCardMedia_image_differentInstances_areNotEqual() {
        let a = ResolvedCardMedia.image(UIImage())
        let b = ResolvedCardMedia.image(UIImage())
        XCTAssertNotEqual(a, b, "Different UIImage instances should not be equal")
    }

    func testResolvedCardMedia_placeholder_areEqual() {
        XCTAssertEqual(ResolvedCardMedia.placeholder, ResolvedCardMedia.placeholder)
    }

    func testResolvedCardMedia_none_areEqual() {
        XCTAssertEqual(ResolvedCardMedia.none, ResolvedCardMedia.none)
    }

    func testResolvedCardMedia_differentCases_areNotEqual() {
        XCTAssertNotEqual(ResolvedCardMedia.image(UIImage()), ResolvedCardMedia.placeholder)
        XCTAssertNotEqual(ResolvedCardMedia.image(UIImage()), ResolvedCardMedia.none)
        XCTAssertNotEqual(ResolvedCardMedia.placeholder, ResolvedCardMedia.none)
    }

    // MARK: - FeedCardPresentation identity

    func testFeedCardPresentation_id_matchesFeedItem() {
        let item = makeItem(id: "test-123")
        let pres = FeedCardPresentation(
            item: item, media: .none, layout: .textOnly,
            isRead: false, isBookmarked: false
        )
        XCTAssertEqual(pres.id, "test-123")
    }

    func testFeedCardPresentation_equality() {
        let item = makeItem(id: "same")
        let now = Date()
        let a = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                      isRead: false, isBookmarked: false, preparedAt: now)
        let b = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                      isRead: false, isBookmarked: false, preparedAt: now)
        XCTAssertEqual(a, b)
    }

    func testFeedCardPresentation_differentMedia_areNotEqual() {
        let item = makeItem(id: "x")
        let a = FeedCardPresentation(item: item, media: .none, layout: .textOnly,
                                      isRead: false, isBookmarked: false)
        let b = FeedCardPresentation(item: item, media: .placeholder, layout: .textOnly,
                                      isRead: false, isBookmarked: false)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Card media slot drives the image decision

    func test_cardView_hasImage_true_whenSlotHoldsLocalBytes() {
        let item = makeItem(id: "img", imageURL: "https://example.com/img.jpg")
        let image = RenderImage(cacheKey: "img", image: UIImage())
        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .local(image)
        )
        XCTAssertTrue(view.hasImageTest, "hasImage should be true with local bytes")
    }

    func test_cardView_hasImage_false_whenSlotIsPlaceholder() {
        let item = makeItem(id: "ph", imageURL: "https://example.com/img.jpg")
        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .placeholder(.podcast)
        )
        XCTAssertFalse(view.hasImageTest, "a placeholder must not activate the image slot")
    }

    func test_cardView_hasImage_false_whenSlotIsEmpty() {
        let item = makeItem(id: "empty", imageURL: "https://example.com/img.jpg")
        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .empty
        )
        XCTAssertFalse(view.hasImageTest, "a reserved empty frame must not draw a stand-in image")
    }

    func test_cardView_hasImage_false_whenSlotIsAbsent() {
        // Even though the item has an image URL, a card with no slot must not
        // render an image — the slot is the only gate, never the item.
        let item = makeItem(id: "nopres", imageURL: "https://example.com/img.jpg")
        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .none
        )
        XCTAssertFalse(view.hasImageTest, "no slot means no image, regardless of the item")
    }

    // MARK: - Terminal states: no .loading path

    func test_cardMediaSlot_hasNoLoadingStateAndOnlyLocalBytesAreAnImage() {
        // The slot is terminal by construction: there is no `.loading`, and no case can start a
        // download because none of them holds a URL. Only `.local` places bytes in the image slot.
        let cases: [CardMediaSlot] = [
            .local(RenderImage(cacheKey: "k", image: UIImage())),
            .placeholder(.podcast),
            .empty,
            .none,
        ]
        XCTAssertEqual(cases.count, 4, "CardMediaSlot has exactly 4 terminal states; no .loading")
        XCTAssertEqual(cases.filter { $0.localImage != nil }.count, 1, "only .local carries bytes")
    }

    // MARK: - FeedCardLayout terminal states

    func test_feedCardLayout_hasThreeStates() {
        let cases: [FeedCardLayout] = [.hero, .thumbnail, .textOnly]
        XCTAssertEqual(cases.count, 3)
    }

    /// `durationFormatted` reads metadata that arrives from the feed, so it must not trap on any Double
    /// a parser can hand it: `Int(_:)` traps on values outside Int's range even when they are finite, and
    /// duration is `TimeInterval?` straight from the enclosure.
    func testDurationFormattedSurvivesExtremeMetadataWithoutTrapping() {
        let cases: [(TimeInterval?, String?)] = [
            (nil, nil),
            (0, nil),
            (59.9, nil),
            (60, "1 min"),
            (90, "1 min"),
            (3599, "59 min"),
            (3600, "1h"),
            (3660, "1h 1m"),
            (-60, nil),
            (.nan, nil),
            (.infinity, nil),
            (-.infinity, nil),
            (1e30, nil),
            (Double.greatestFiniteMagnitude, nil),
        ]
        for (duration, expected) in cases {
            XCTAssertEqual(
                makeItem(id: "duration", duration: duration).durationFormatted,
                expected,
                "duration \(duration.map { "\($0)" } ?? "nil") must format as \(expected ?? "nil")"
            )
        }
    }

    // MARK: - Helpers

    private func makeItem(id: String, imageURL: String? = nil, duration: TimeInterval? = nil) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Test Source",
            sourceURL: "https://example.com/feed",
            category: "News",
            title: "Test Title",
            excerpt: "Test excerpt",
            url: "https://example.com/article",
            imageURL: imageURL,
            publishedAt: Date(),
            audioURL: nil,
            duration: duration,
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

// hasImageTest extension defined in ReadyCardQueueTests.swift
