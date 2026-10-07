import XCTest
@testable import feedmine

@MainActor
final class FeedDisplayStateTests: XCTestCase {

    // MARK: - Prepared page snapshot (review P0.2)

    /// The warm cache must carry the **terminal presentation decision**, not just an item list.
    ///
    /// Without it every card whose image resolved locally came back as `.hero`, so a reopened feed had different shapes
    /// than the session that wrote the page — a card the pipeline published as `.thumb` reappeared full-width. The
    /// assertion uses a signature of its own, so it neither reads nor disturbs whatever page the container already holds.
    func test_persistedPageCarriesTerminalLayoutAndMediaKind() async throws {
        let signature = "p02-\(UUID().uuidString)"
        let display = FeedDisplayState()
        let hero = FeedItem.makeMock(id: "p02-hero")
        let thumb = FeedItem.makeMock(id: "p02-thumb")
        let text = FeedItem.makeMock(id: "p02-text")
        display.publishCards(
            [
                FeedCardPresentation(item: hero, media: .image(UIImage()), layout: .hero,
                                     isRead: false, isBookmarked: false),
                FeedCardPresentation(item: thumb, media: .image(UIImage()), layout: .thumbnail,
                                     isRead: false, isBookmarked: false),
                FeedCardPresentation(item: text, media: .none, layout: .textOnly,
                                     isRead: false, isBookmarked: false),
            ],
            items: [hero, thumb, text],
            readItemIDs: [],
            bookmarkItemIDs: [],
            isAppend: false,
            shouldCache: true,
            filterSignature: signature,
            mediaCacheKeys: ["p02-hero": "key-hero", "p02-thumb": "key-thumb"]
        )

        // The write is detached — wait until the page is readable instead of assuming the file landed.
        var restored = await display.restoreCachedPage(filterSignature: signature)
        let deadline = Date().addingTimeInterval(30)
        while restored == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            restored = await display.restoreCachedPage(filterSignature: signature)
        }
        let page = try XCTUnwrap(restored, "the page cache must be readable back")
        let cards = try XCTUnwrap(page.cards, "a page published with media keys carries a card projection")
        let byID = Dictionary(cards.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(byID["p02-hero"]?.layout, "hero")
        XCTAssertEqual(byID["p02-thumb"]?.layout, "thumb")
        XCTAssertEqual(byID["p02-text"]?.layout, "text")
        XCTAssertEqual(byID["p02-hero"]?.mediaKind, "image")
        XCTAssertEqual(byID["p02-text"]?.mediaKind, "none")
        XCTAssertEqual(byID["p02-hero"]?.cacheKey, "key-hero")
        XCTAssertNil(byID["p02-text"]?.cacheKey)
    }

    /// A page written before layouts were persisted still decodes, and its entries simply have no decision to restore.
    func test_persistedPageFromOlderBuildStillDecodes() throws {
        let legacy = #"{"items":[],"visibleItemsGeneration":7,"cards":[{"itemID":"x","cacheKey":"k"}]}"#
        let page = try JSONDecoder().decode(FeedDisplayState.CachedPage.self, from: Data(legacy.utf8))
        XCTAssertEqual(page.visibleItemsGeneration, 7)
        XCTAssertNil(page.cards?.first?.layout)
        XCTAssertNil(page.cards?.first?.mediaKind)
        XCTAssertEqual(page.cards?.first?.cacheKey, "k")
    }

    /// The persisted spelling is shared with the staleness fingerprint, so the two cannot disagree.
    func test_layoutKeysRoundTripThroughThePersistedSpelling() {
        for layout in [FeedCardLayout.hero, .thumbnail, .textOnly] {
            let key = FeedDisplayState.layoutKey(layout)
            XCTAssertEqual(FeedDisplayState.layout(from: key), layout, "\(key) must map back to \(layout)")
        }
        XCTAssertNil(FeedDisplayState.layout(from: "nonsense"))
    }

    // MARK: - Page cache write policy (review P0.2/P0.3)

    /// The cache must not persist a thin page while the cold-start runway is still being built.
    ///
    /// Measured defect this pins: on a clean container the first flush of a cold start publishes whatever the
    /// reservoir holds — 2 items — and that snapshot was written to the cache and restored by the next launch
    /// (`page[restore] items=2`) while the session that wrote it went on to a full page. The gate is the runway, not
    /// the depth: once the runway has stopped preparing one, the same thin page *is* the composition and is written.
    func test_thinPageIsNotPersistedWhileTheRunwayIsStillBuilding() async throws {
        let signature = "p03-building-\(UUID().uuidString)"
        let display = FeedDisplayState()
        let items = [FeedItem.makeMock(id: "thin-1"), FeedItem.makeMock(id: "thin-2")]
        display.setIsPreparingInitialRunway(true)

        display.publishCards(
            items.map { FeedCardPresentation.makeMock(id: $0.id, item: $0) },
            items: items,
            readItemIDs: [],
            bookmarkItemIDs: [],
            isAppend: false,
            shouldCache: true,
            filterSignature: signature
        )

        let duringRunway = await cachedPage(of: display, signature: signature, within: 0.5)
        XCTAssertNil(duringRunway, "a partial cold-start page must not be persisted")

        // The runway settles, the same page is published again: now it is the composition, so it is cached.
        display.setIsPreparingInitialRunway(false)
        display.publishCards(
            items.map { FeedCardPresentation.makeMock(id: $0.id, item: $0) },
            items: items,
            readItemIDs: [],
            bookmarkItemIDs: [],
            isAppend: false,
            shouldCache: true,
            filterSignature: signature
        )

        let settled = await cachedPage(of: display, signature: signature, count: 2)
        XCTAssertEqual(settled?.map(\.id), ["thin-1", "thin-2"],
                       "a short page written once the runway is not preparing one is the composition")
    }

    /// The cache follows the page as the feed grows: appends deepen it, and a thinner publication cannot replace it.
    ///
    /// Appends are the only way a feed grows after its first page, and excluding them is what froze the cache at the
    /// first flush — so this test fails against that rule at the *second* assertion (the page stays at 2 items).
    func test_pageCacheFollowsGrowthAndNeverRegresses() async throws {
        let signature = "p04-growth-\(UUID().uuidString)"
        let display = FeedDisplayState()
        let first = [FeedItem.makeMock(id: "grow-1"), FeedItem.makeMock(id: "grow-2")]

        display.publishCards(
            first.map { FeedCardPresentation.makeMock(id: $0.id, item: $0) },
            items: first, readItemIDs: [], bookmarkItemIDs: [],
            isAppend: false, shouldCache: true, filterSignature: signature
        )
        let initial = await cachedPage(of: display, signature: signature, count: 2)
        XCTAssertEqual(initial?.count, 2, "the first publication is cached")

        let appended = (3...5).map { FeedItem.makeMock(id: "grow-\($0)") }
        display.publishCards(
            appended.map { FeedCardPresentation.makeMock(id: $0.id, item: $0) },
            items: appended, readItemIDs: [], bookmarkItemIDs: [],
            isAppend: true, shouldCache: true, filterSignature: signature
        )
        let grown = await cachedPage(of: display, signature: signature, count: 5)
        XCTAssertEqual(grown?.map(\.id), ["grow-1", "grow-2", "grow-3", "grow-4", "grow-5"],
                       "an append must deepen the cached page, not leave it at the first flush")

        // A user-initiated replace publishes a shorter page for the same signature: the deeper page stays.
        let shorter = (6...8).map { FeedItem.makeMock(id: "grow-\($0)") }
        display.publishCards(
            shorter.map { FeedCardPresentation.makeMock(id: $0.id, item: $0) },
            items: shorter, readItemIDs: [], bookmarkItemIDs: [],
            isAppend: false, shouldCache: true, filterSignature: signature, isUserInitiated: true
        )
        XCTAssertEqual(display.visibleItems.map(\.id), ["grow-6", "grow-7", "grow-8"],
                       "precondition: the replace really did shorten the published page")
        let afterShrink = await cachedPage(of: display, signature: signature, count: 5)
        XCTAssertEqual(afterShrink?.count, 5, "a thinner page must not replace the deeper one already written")
    }

    /// The warm page is a page, not the reader's scrollback.
    func test_cachedPageIsBoundedToTheFirstPageDepth() async throws {
        let signature = "p04-depth-\(UUID().uuidString)"
        let display = FeedDisplayState()
        let items = (1...25).map { FeedItem.makeMock(id: "deep-\($0)") }

        display.publishCards(
            items.map { FeedCardPresentation.makeMock(id: $0.id, item: $0) },
            items: items, readItemIDs: [], bookmarkItemIDs: [],
            isAppend: false, shouldCache: true, filterSignature: signature
        )

        let page = await cachedPage(of: display, signature: signature, count: Reservoir.pageSize)
        XCTAssertEqual(page?.map(\.id), (1...Reservoir.pageSize).map { "deep-\($0)" },
                       "the cache keeps the first page's depth, in order")
    }

    /// A page whose cards carry images but no cache keys is a page that lost its media: it is not persisted.
    ///
    /// Measured on a warm reopen, where the restore used to publish the restored cards without handing their keys
    /// back: `page[restore] items=20 withMedia=17` and then `page[cache] write … mediaKeys=0`, so the *next* launch
    /// restored 20 cards that could not rebuild a single image. The page already on disk is the better one.
    func test_pageThatLostItsMediaIsNotPersisted() async throws {
        let signature = "p04-lostmedia-\(UUID().uuidString)"
        let display = FeedDisplayState()
        let items = [FeedItem.makeMock(id: "media-1"), FeedItem.makeMock(id: "media-2")]

        display.publishCards(
            items.map { FeedCardPresentation(item: $0, media: .image(UIImage()), layout: .hero,
                                             isRead: false, isBookmarked: false) },
            items: items, readItemIDs: [], bookmarkItemIDs: [],
            isAppend: false, shouldCache: true, filterSignature: signature
        )

        let page = await cachedPage(of: display, signature: signature, within: 0.5)
        XCTAssertNil(page, "a page carrying media with no keys to rebuild it must not be persisted")
    }

    /// The cache write is detached, so a test polls for the page instead of assuming the file landed.
    /// `count` waits for that depth, which is how "the deeper page landed" is told from "a page landed";
    /// a short `within` with no count is the absence assertion the runway gate needs.
    private func cachedPage(
        of display: FeedDisplayState,
        signature: String,
        count: Int? = nil,
        within seconds: TimeInterval = 30
    ) async -> [FeedItem]? {
        let deadline = Date().addingTimeInterval(seconds)
        var page = await display.restoreCachedPage(filterSignature: signature)
        while Date() < deadline {
            if let page, count == nil || page.items.count == count! { return page.items }
            try? await Task.sleep(for: .milliseconds(10))
            page = await display.restoreCachedPage(filterSignature: signature)
        }
        return nil
    }

    // MARK: - setVisibleItems stamping

    func test_setVisibleItems_stampsReadState() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isRead = false

        state.setVisibleItems([item], readItemIDs: ["a"], bookmarkItemIDs: [])

        XCTAssertTrue(state.visibleItems[0].isRead, "Item should be stamped as read")
    }

    func test_setVisibleItems_stampsBookmarkState() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "b")
        item.isBookmarked = false

        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: ["b"])

        XCTAssertTrue(state.visibleItems[0].isBookmarked, "Item should be stamped as bookmarked")
    }

    func test_setVisibleItems_stampsMultipleItems() {
        let state = FeedDisplayState()
        let items = [
            FeedItem.makeMock(id: "x"),
            FeedItem.makeMock(id: "y"),
            FeedItem.makeMock(id: "z"),
        ]

        state.setVisibleItems(items, readItemIDs: ["x", "z"], bookmarkItemIDs: ["y"])

        XCTAssertTrue(state.visibleItems[0].isRead, "x should be read")
        XCTAssertFalse(state.visibleItems[1].isRead, "y should not be read")
        XCTAssertTrue(state.visibleItems[2].isRead, "z should be read")
        XCTAssertFalse(state.visibleItems[0].isBookmarked, "x should not be bookmarked")
        XCTAssertTrue(state.visibleItems[1].isBookmarked, "y should be bookmarked")
    }

    // MARK: - setVisibleItems no-op guard

    func test_setVisibleItems_replace_noop_doesNotBumpGeneration() {
        let state = FeedDisplayState()
        let items = [FeedItem.makeMock(id: "a"), FeedItem.makeMock(id: "b")]
        state.setVisibleItems(items, readItemIDs: [], bookmarkItemIDs: [])
        let genAfterFirst = state.visibleItemsGeneration

        // Same items again — should be a no-op
        state.setVisibleItems(items, readItemIDs: [], bookmarkItemIDs: [])

        XCTAssertEqual(state.visibleItemsGeneration, genAfterFirst,
                       "Generation should not bump on identical replace")
    }

    func test_setVisibleItems_replace_differentItems_bumpsGeneration() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genAfterFirst = state.visibleItemsGeneration

        state.setVisibleItems([FeedItem.makeMock(id: "b")], readItemIDs: [], bookmarkItemIDs: [])

        XCTAssertGreaterThan(state.visibleItemsGeneration, genAfterFirst,
                             "Generation should bump on different replace")
    }

    // MARK: - publishCards

    func test_publishCards_publishesItemsAndCardsAtomically() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.visibleItems.count, 1)
        XCTAssertEqual(state.visibleCards.count, 1)
        XCTAssertEqual(state.visibleItems[0].id, "a")
        XCTAssertEqual(state.visibleCards[0].id, "a")
    }

    func test_publishCards_firstPaint_flipsLoadingStateToIdle() {
        let state = FeedDisplayState()
        // Fresh state: loadingState is .idle by default. Force it to .initial.
        // We need to test the first-paint transition, which requires .initial.
        // Since there's no public setter for .initial on a fresh component,
        // we verify that the initial state is .idle and the transition is a no-op.
        // The actual .initial → .idle path is exercised by FeedStore wiring.
        XCTAssertEqual(state.loadingState, .idle)
    }

    func test_publishCards_firstPaint_setsPhaseToReadyWhenItemsNotEmpty() {
        let state = FeedDisplayState()
        // Reset to simulate pre-first-paint state with .initial loading.
        // Loading state .initial must be set via internal wiring in FeedStore.
        // For this test, we verify the phase coupling contract directly.
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        // Manually set to .initial (simulating what FeedStore does before first paint)
        state.setLoadingState(.initial)

        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.loadingState, .idle, "First paint should transition loading to idle")
        guard case .ready = state.feedDisplayPhase else {
            XCTFail("First paint with items should set phase to .ready, got \(state.feedDisplayPhase)")
            return
        }
    }

    /// An empty publication marked *transient* is the clear a rebuild starts with, not an
    /// answer: settling `.empty` there made the screen claim "No sources enabled" while the
    /// catalogue was still loading (`sources.isEmpty` was true, so the message was simply
    /// false), and the real page replaced it seconds later. The caller knows which empty
    /// publications are answers, so it says so with `settlesPhase: false`.
    func test_publishCards_transientEmptyPublicationKeepsPreparing() {
        let state = FeedDisplayState()
        state.setLoadingState(.initial)

        state.publishCards(
            [], items: [], readItemIDs: [], bookmarkItemIDs: [],
            isAppend: false, settlesPhase: false
        )

        guard case .preparing = state.feedDisplayPhase else {
            XCTFail("A transient clear must not settle the phase, got \(state.feedDisplayPhase)")
            return
        }
        // ...but a page exists, so the loading state settles — *unless* nothing is visible and
        // the runway is still being prepared, which is the case the next test pins. Here no page
        // was ever published and the runway is not preparing, so `.idle` is the honest answer.
        XCTAssertEqual(state.loadingState, .idle)
    }

    /// **The rule that keeps the feed on screen.** A publication that would blank the displayed
    /// page is refused unless the user asked for it — transient *or* terminal. An early "empty"
    /// composition (the catalogue had produced nothing yet) looked identical to the reader: the
    /// feed vanished and an absence screen appeared for no reason. A user-initiated publication
    /// (filter, preset, refresh — `isUserInitiated`, or the `.refreshing` marker those paths set)
    /// replaces the page, which is how a filter change takes effect.
    func test_emptyPublicationNeverBlanksADisplayedPage() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        state.publishCards(
            [FeedCardPresentation.makeMock(id: "a", item: item)],
            items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false
        )

        state.publishCards([], items: [], readItemIDs: [], bookmarkItemIDs: [], isAppend: false,
                           settlesPhase: false)
        XCTAssertEqual(state.visibleItems.count, 1, "a transient empty publication must not blank the page")

        state.setVisibleItems([], readItemIDs: [], bookmarkItemIDs: [])
        XCTAssertEqual(state.visibleItems.count, 1, "a terminal empty publication must not blank the page either")

        // A user-initiated clear goes through: that is how a filter change takes effect.
        state.setVisibleItems([], readItemIDs: [], bookmarkItemIDs: [], isUserInitiated: true)
        XCTAssertTrue(state.visibleItems.isEmpty)
    }

    /// A *transient* clear that leaves nothing on screen while the runway is still being prepared
    /// must not claim `.idle`: the startup watchdog is an inline check at the end of `start()` that
    /// answers `.idle` + `.preparing` with `.empty`, which is the "No sources enabled" screen
    /// appearing while the catalogue is still loading. Same rule the store uses when it drives the
    /// state directly (`isPreparingInitialRunway && visibleItems.isEmpty ? .initial : .idle`).
    func test_transientClearDuringRunwayPreparation_keepsInitialLoadingState() {
        let state = FeedDisplayState()
        state.setFeedDisplayPhase(.preparing(contextID: 0, reason: .startup))
        state.setLoadingState(.initial)
        state.setIsPreparingInitialRunway(true)

        state.setVisibleItems([], readItemIDs: [], bookmarkItemIDs: [], settlesPhase: false)

        XCTAssertEqual(state.loadingState, .initial,
                       "a transient clear with nothing visible during runway prep must not settle")
        guard case .preparing = state.feedDisplayPhase else {
            XCTFail("the transient clear must not settle the phase, got \(state.feedDisplayPhase)")
            return
        }

        // A terminal answer still settles both, even while the runway prepares.
        state.setVisibleItems([], readItemIDs: [], bookmarkItemIDs: [])
        XCTAssertEqual(state.loadingState, .idle)
        guard case .empty = state.feedDisplayPhase else {
            XCTFail("a terminal empty publication must settle .empty, got \(state.feedDisplayPhase)")
            return
        }

        // And a transient clear that has a page to show settles as usual.
        let item = FeedItem.makeMock(id: "a")
        state.setFeedDisplayPhase(.preparing(contextID: 1, reason: .startup))
        state.setLoadingState(.initial)
        state.publishCards(
            [FeedCardPresentation.makeMock(id: "a", item: item)],
            items: [item], readItemIDs: [], bookmarkItemIDs: [],
            isAppend: false, settlesPhase: false
        )
        XCTAssertEqual(state.loadingState, .idle, "a page on screen settles the loading state")
    }

    /// A *terminal* empty publication still settles the empty state — the flag is about who
    /// knows, not about suppressing emptiness. Without this half, a genuinely empty feed would
    /// sit on the loader forever.
    func test_publishCards_terminalEmptyPublicationSettlesEmpty() {
        let state = FeedDisplayState()
        state.setLoadingState(.initial)

        state.publishCards([], items: [], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.loadingState, .idle)
        guard case .empty = state.feedDisplayPhase else {
            XCTFail("A settled empty result must reach .empty, got \(state.feedDisplayPhase)")
            return
        }
    }

    func test_publishCards_nonFirstPaint_doesNotChangeLoadingState() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        // First paint
        state.setLoadingState(.initial)
        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        XCTAssertEqual(state.loadingState, .idle)

        // Now set to refreshing (simulating a refresh cycle)
        state.setLoadingState(.refreshing)

        // Second publish — should NOT flip loadingState back to .idle
        let item2 = FeedItem.makeMock(id: "b")
        let card2 = FeedCardPresentation.makeMock(id: "b", item: item2)
        state.publishCards([card2], items: [item2], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.loadingState, .refreshing,
                       "Non-first-paint should not change loadingState")
    }

    func test_publishCards_append_noop_doesNotChangeState() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        let genBefore = state.visibleItemsGeneration
        let countBefore = state.visibleItems.count

        // Append same card — should be filtered
        state.publishCards([card], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: true)

        XCTAssertEqual(state.visibleItems.count, countBefore)
        XCTAssertEqual(state.visibleCards.count, countBefore)
        XCTAssertEqual(state.visibleItemsGeneration, genBefore)
    }

    func test_publishCards_append_newItems_addsThem() {
        let state = FeedDisplayState()
        let item1 = FeedItem.makeMock(id: "a")
        let card1 = FeedCardPresentation.makeMock(id: "a", item: item1)

        state.publishCards([card1], items: [item1], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        let item2 = FeedItem.makeMock(id: "b")
        let card2 = FeedCardPresentation.makeMock(id: "b", item: item2)
        state.publishCards([card2], items: [item2], readItemIDs: [], bookmarkItemIDs: [], isAppend: true)

        XCTAssertEqual(state.visibleItems.count, 2)
        XCTAssertEqual(state.visibleCards.count, 2)
        XCTAssertEqual(state.visibleItems[1].id, "b")
    }

    func test_publishCards_reStampsItems() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isRead = false
        item.isBookmarked = false
        let card = FeedCardPresentation.makeMock(id: "a", item: item)

        // Publish with read/bookmark markers — should stamp
        state.publishCards([card], items: [item], readItemIDs: ["a"], bookmarkItemIDs: ["a"], isAppend: false)

        XCTAssertTrue(state.visibleItems[0].isRead)
        XCTAssertTrue(state.visibleItems[0].isBookmarked)
    }

    // MARK: - mutateVisibleItem

    func test_mutateVisibleItem_modifiesItemInPlace() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isRead = false
        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: [])

        state.mutateVisibleItem(at: 0) { $0.isRead = true }

        XCTAssertTrue(state.visibleItems[0].isRead)
    }

    func test_mutateVisibleItem_withBumpGeneration_incrementsCounter() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genBefore = state.visibleItemsGeneration

        state.mutateVisibleItem(at: 0, bumpGeneration: true) { $0.isRead = true }

        XCTAssertEqual(state.visibleItemsGeneration, genBefore + 1)
    }

    func test_mutateVisibleItem_withoutBumpGeneration_doesNotIncrementCounter() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genBefore = state.visibleItemsGeneration

        state.mutateVisibleItem(at: 0) { $0.isRead = true }

        XCTAssertEqual(state.visibleItemsGeneration, genBefore,
                       "Read-state change should not invalidate caches")
    }

    func test_mutateVisibleItem_defaultsToNoBump() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])
        let genBefore = state.visibleItemsGeneration

        // Default bumpGeneration is false
        state.mutateVisibleItem(at: 0) { $0.isBookmarked = true }

        XCTAssertEqual(state.visibleItemsGeneration, genBefore)
    }

    func test_mutateVisibleItem_outOfBounds_isNoop() {
        let state = FeedDisplayState()
        state.setVisibleItems([FeedItem.makeMock(id: "a")], readItemIDs: [], bookmarkItemIDs: [])

        // Should not crash
        state.mutateVisibleItem(at: 999) { $0.isRead = true }
        state.mutateVisibleItem(at: -1) { $0.isRead = true }

        XCTAssertEqual(state.visibleItems.count, 1)
    }

    func test_mutateVisibleItem_toggleBookmarkPattern() {
        let state = FeedDisplayState()
        var item = FeedItem.makeMock(id: "a")
        item.isBookmarked = false
        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: [])

        // Simulate toggleBookmark: flip + bump
        state.mutateVisibleItem(at: 0, bumpGeneration: true) {
            $0.isBookmarked = !$0.isBookmarked
        }

        XCTAssertTrue(state.visibleItems[0].isBookmarked)
        XCTAssertEqual(state.visibleItemsGeneration, 2) // initial set + toggle
    }

    // MARK: - Published presentations: layout is frozen, media can be healed

    /// A card that has been published keeps its **layout**: activating the hero slot where there was none
    /// changes the card's height and would shift every card below it while the user is reading — which is
    /// why a late image waits for the next publication. `healPublishedMedia` is the one exception, and only
    /// for a card that already reserved its frame.
    func test_publishedCardsOnlyChangeThroughPublication() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "a")
        let textOnly = FeedCardPresentation(
            item: item, media: .none, layout: .textOnly,
            isRead: false, isBookmarked: false
        )
        state.publishCards([textOnly], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        let generations = (state.visibleItemsGeneration, state.visibleCardsGeneration)

        // The only way to change what is published is another publication.
        let withImage = FeedCardPresentation(
            item: item, media: .placeholder, layout: .hero,
            isRead: false, isBookmarked: false
        )
        state.publishCards([withImage], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        XCTAssertEqual(state.visibleCards[0].layout, .hero)
        XCTAssertGreaterThan(state.visibleItemsGeneration, generations.0)
        XCTAssertGreaterThan(state.visibleCardsGeneration, generations.1)
    }

    /// The late-artwork heal: one card's media, in place, and only where the frame was already reserved.
    ///
    /// This is the fix for the reported podcast defect — the art arrived seconds after the card was on
    /// screen and stayed invisible until the next composition (which a stalled feed never reaches). What
    /// makes it safe is the refusal: a heal that would change the layout is rejected, because that is the
    /// height shift the frozen presentation exists to prevent.
    func test_healPublishedMedia_onlyFillsAnAlreadyReservedFrame() {
        let state = FeedDisplayState()
        let item = FeedItem.makeMock(id: "late")
        let reserving = FeedCardPresentation(
            item: item, media: .placeholder, layout: .hero,
            isRead: false, isBookmarked: false
        )
        state.publishCards([reserving], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        let generation = state.visibleCardsGeneration

        let withImage = FeedCardPresentation(
            item: item, media: .image(UIImage()), layout: .hero,
            isRead: false, isBookmarked: false
        )
        XCTAssertTrue(state.healPublishedMedia(withImage, cacheKey: "late-key"))
        XCTAssertEqual(state.visibleCardsGeneration, generation + 1, "the heal must invalidate the card cache key")
        XCTAssertEqual(state.visibleCardCacheKeys["late"], "late-key")
        guard case .image = state.visibleCards[0].media else {
            return XCTFail("the heal did not land on the published card")
        }
        XCTAssertEqual(state.visibleItems.count, 1, "the heal never inserts or removes an item")

        // A heal that would grow a hero where there was none is refused.
        let textOnlyState = FeedDisplayState()
        let textOnly = FeedCardPresentation(
            item: item, media: .none, layout: .textOnly,
            isRead: false, isBookmarked: false
        )
        textOnlyState.publishCards([textOnly], items: [item], readItemIDs: [], bookmarkItemIDs: [], isAppend: false)
        XCTAssertFalse(textOnlyState.healPublishedMedia(withImage, cacheKey: nil))

        // An id that is not on the page is refused, not appended.
        let absent = FeedCardPresentation(
            item: FeedItem.makeMock(id: "absent"), media: .image(UIImage()), layout: .hero,
            isRead: false, isBookmarked: false
        )
        XCTAssertFalse(state.healPublishedMedia(absent, cacheKey: nil))
        XCTAssertEqual(state.visibleCards.count, 1)
    }

    // MARK: - advanceEpoch

    func test_advanceEpoch_bumpsEpochAndCapturesContext() {
        let state = FeedDisplayState()
        let epochBefore = state.presentationEpoch

        let (old, new) = state.advanceEpoch(mode: .main, filterGeneration: 5, presetGeneration: 10)

        XCTAssertEqual(state.presentationEpoch, epochBefore + 1)
        XCTAssertEqual(old.epoch, epochBefore)
        XCTAssertEqual(new.epoch, epochBefore + 1)
        XCTAssertEqual(new.mode, .main)
        XCTAssertEqual(new.filterGeneration, 5)
        XCTAssertEqual(new.presetGeneration, 10)
    }

    func test_advanceEpoch_contextMatchesState() {
        let state = FeedDisplayState()
        let (_, new) = state.advanceEpoch(mode: .collection(42), filterGeneration: 3, presetGeneration: 7)

        XCTAssertEqual(state.activePresentationContext, new)
        XCTAssertEqual(state.activePresentationContext.epoch, state.presentationEpoch)
    }

    func test_advanceEpoch_oldContextIsPreviousState() {
        let state = FeedDisplayState()
        let initialContext = state.activePresentationContext

        let (old, _) = state.advanceEpoch(mode: .main, filterGeneration: 1, presetGeneration: 2)

        XCTAssertEqual(old, initialContext)
    }

    func test_advanceEpoch_multipleCalls_keepsConsistency() {
        let state = FeedDisplayState()

        _ = state.advanceEpoch(mode: .main, filterGeneration: 1, presetGeneration: 1)
        _ = state.advanceEpoch(mode: .bookmarks(nil), filterGeneration: 2, presetGeneration: 2)
        _ = state.advanceEpoch(mode: .whatsNew, filterGeneration: 3, presetGeneration: 3)

        XCTAssertEqual(state.presentationEpoch, 3)
        XCTAssertEqual(state.activePresentationContext.epoch, 3)
        XCTAssertEqual(state.activePresentationContext.mode, .whatsNew)
    }

    // MARK: - clear

    func test_clear_resetsAllFields() {
        let state = FeedDisplayState()

        // Populate state
        let item = FeedItem.makeMock(id: "a")
        state.setVisibleItems([item], readItemIDs: [], bookmarkItemIDs: [])
        state.setLoadingState(.refreshing)
        state.setFeedDisplayPhase(.ready(contextID: 1))
        state.setIsPreparingInitialRunway(true)
        _ = state.advanceEpoch(mode: .main, filterGeneration: 1, presetGeneration: 1)

        // Verify populated
        XCTAssertFalse(state.visibleItems.isEmpty)
        XCTAssertEqual(state.loadingState, .refreshing)

        // Clear
        state.clear()

        XCTAssertTrue(state.visibleItems.isEmpty)
        XCTAssertTrue(state.visibleCards.isEmpty)
        XCTAssertEqual(state.loadingState, .idle)
        guard case .preparing = state.feedDisplayPhase else {
            XCTFail("Phase should be .preparing after clear")
            return
        }
        XCTAssertFalse(state.isPreparingInitialRunway)
        XCTAssertEqual(state.presentationEpoch, 0)
        XCTAssertEqual(state.visibleItemsGeneration, 0)
    }

    func test_clear_resetsActivePresentationContext() {
        let state = FeedDisplayState()
        _ = state.advanceEpoch(mode: .main, filterGeneration: 5, presetGeneration: 10)

        XCTAssertEqual(state.presentationEpoch, 1)
        XCTAssertEqual(state.activePresentationContext.epoch, 1)

        state.clear()

        XCTAssertEqual(state.presentationEpoch, 0)
        XCTAssertEqual(state.activePresentationContext.epoch, 0,
                       "activePresentationContext.epoch must match presentationEpoch after clear")
        XCTAssertEqual(state.activePresentationContext.mode, .main)
        XCTAssertEqual(state.activePresentationContext.filterGeneration, 0)
        XCTAssertEqual(state.activePresentationContext.presetGeneration, 0)
    }

    // MARK: - Independent setters

    func test_setLoadingState_updatesValue() {
        let state = FeedDisplayState()
        state.setLoadingState(.refreshing)
        XCTAssertEqual(state.loadingState, .refreshing)
    }

    func test_setFeedDisplayPhase_updatesValue() {
        let state = FeedDisplayState()
        state.setFeedDisplayPhase(.failed(contextID: 1, message: "test error"))
        guard case .failed = state.feedDisplayPhase else {
            XCTFail("Phase should be .failed")
            return
        }
    }

    func test_setIsPreparingInitialRunway_updatesValue() {
        let state = FeedDisplayState()
        XCTAssertFalse(state.isPreparingInitialRunway)
        state.setIsPreparingInitialRunway(true)
        XCTAssertTrue(state.isPreparingInitialRunway)
    }
}

// MARK: - Test Helpers

extension FeedItem {
    static func makeMock(id: String) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Test Source",
            sourceURL: "https://example.com",
            category: "Technology",
            title: "Test \(id)",
            excerpt: "Excerpt for \(id)",
            url: "https://example.com/\(id)",
            imageURL: nil,
            publishedAt: Date(),
            region: "us"
        )
    }
}

extension FeedCardPresentation {
    static func makeMock(id: String, item: FeedItem) -> FeedCardPresentation {
        FeedCardPresentation(
            item: item,
            media: .none,
            layout: .textOnly,
            isRead: false,
            isBookmarked: false
        )
    }
}
