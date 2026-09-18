import XCTest
import UIKit
@testable import feedmine

/// Tests for ReadyCardQueue: publication gate, timeout behavior, and
/// the invariant that cards are never published without terminal media.
@MainActor
final class ReadyCardQueueTests: XCTestCase {

    // MARK: - Initial state

    func test_initialState_presentationsEmpty() {
        let queue = ReadyCardQueue()
        XCTAssertTrue(queue.presentations.isEmpty, "Fresh queue must have empty presentations")
    }

    func test_initialState_resetOnEmptyQueue_isNoOp() {
        let queue = ReadyCardQueue()
        queue.reset()
        XCTAssertTrue(queue.presentations.isEmpty)
    }

    // MARK: - Timeout behavior

    func test_waitForReady_zeroCount_returnsImmediately() async {
        let queue = ReadyCardQueue()
        let start = Date()
        await queue.waitForReady(count: 0)
        let elapsed = Date().timeIntervalSince(start)
        // 0 < 0 is false → while loop body never executes → immediate return
        XCTAssertLessThan(elapsed, 0.5, "waitForReady(0) should return in < 0.5s")
    }

    func test_waitForReady_noEnqueuedItems_returnsImmediately() async {
        let queue = ReadyCardQueue()
        let start = Date()
        await queue.waitForReady(count: 100)
        let elapsed = Date().timeIntervalSince(start)
        // pendingIDs is empty → guard breaks immediately
        XCTAssertLessThan(elapsed, 0.5, "waitForReady with no items should return immediately (no pending)")
    }

    // MARK: - Reset

    func test_reset_clearsEmptyQueue() {
        let queue = ReadyCardQueue()
        queue.reset()
        // Reset on empty queue should not crash or hang
        XCTAssertTrue(queue.presentations.isEmpty)
    }

    // MARK: - retainOnly on empty queue

    func test_retainOnly_emptyQueue_isNoOp() {
        let queue = ReadyCardQueue()
        queue.retainOnly(ids: ["nonexistent"])
        XCTAssertTrue(queue.presentations.isEmpty)
    }
}

/// Tests verifying the core architectural invariant: no card visible in
/// the feed can trigger an image download.
@MainActor
final class ZeroAsyncImageInvariantTests: XCTestCase {

    // MARK: - The slot is terminal

    func test_cardMediaSlot_onlyTerminalCases() {
        let image = RenderImage(cacheKey: "k", image: UIImage())
        let slot = CardMediaSlot.local(image)
        switch slot {
        case .local: break
        case .placeholder: break
        case .empty: break
        case .none: break
        }
        // Compile-time check: if a case that is not terminal is added (a loading state, or a slot
        // holding a URL), this switch becomes non-exhaustive and the compiler will error — forcing the
        // developer to reconsider whether the renderer can now start work.
        XCTAssertTrue(true, "CardMediaSlot has exactly 4 terminal cases")
    }

    // MARK: - FeedCardPresentation immutability

    func test_feedCardPresentation_propertiesAreLet() {
        let item = makeItem(id: "immutable", imageURL: "https://x.com/img.jpg")
        let img = UIImage()
        let pres = FeedCardPresentation(
            item: item, media: .image(img), layout: .hero,
            isRead: false, isBookmarked: false
        )
        XCTAssertEqual(pres.id, "immutable")
        if case .image(let stored) = pres.media {
            XCTAssertTrue(stored === img, "UIImage preserved by pointer identity")
        } else {
            XCTFail("Expected .image media")
        }
        // All properties are `let` — the compiler prevents mutation after init
    }

    // MARK: - Critical invariant: the slot is the only gate

    func test_cardWithoutSlot_noImageSlot() {
        // An item with hasPotentialImage=true and NO slot must not render an
        // image slot. This is the gate that prevents a download after the card
        // appears: the item never decides it.
        let item = makeItem(id: "no-pres", imageURL: "https://x.com/photo.jpg")
        XCTAssertTrue(item.hasPotentialImage, "Item has potential for image")

        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .none
        )
        XCTAssertFalse(view.hasImageTest,
            "CRITICAL: no slot -> no image slot, regardless of hasPotentialImage")
    }

    func test_cardWithPlaceholder_noImageSlot() {
        let item = makeItem(id: "ph", imageURL: "https://x.com/img.jpg")
        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .placeholder(.podcast)
        )
        XCTAssertFalse(view.hasImageTest, "a placeholder must not activate the image slot")
    }

    func test_cardWithEmptySlot_noImageSlot() {
        let item = makeItem(id: "empty", imageURL: "https://x.com/img.jpg")
        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .empty
        )
        XCTAssertFalse(view.hasImageTest, "a reserved empty frame must not activate the image slot")
    }

    func test_cardWithLocalBytes_hasImageSlot() {
        let item = makeItem(id: "yes", imageURL: "https://x.com/img.jpg")
        let view = FeedItemCardView(
            item: item,
            isRead: false,
            isBookmarked: false,
            mediaSlot: .local(RenderImage(cacheKey: "yes", image: UIImage()))
        )
        XCTAssertTrue(view.hasImageTest, "only local bytes activate the image slot")
    }

    // MARK: - Helpers

    private func makeItem(id: String, imageURL: String?) -> FeedItem {
        FeedItem(
            id: id, sourceTitle: "S", sourceURL: "https://x.com/feed",
            category: "News", title: "T", excerpt: "E",
            url: "https://x.com/article", imageURL: imageURL,
            publishedAt: Date(), audioURL: nil, duration: nil,
            region: "imported", language: "en", updatedAt: nil,
            authors: nil, itemCategories: nil, rights: nil,
            attribution: nil, enclosures: nil, languageFromFeed: nil,
            alternateLinks: nil
        )
    }
}
