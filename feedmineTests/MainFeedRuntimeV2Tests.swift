import XCTest
import UIKit
import FeedDomain
import FeedRuntime
import FeedUIBridge
@testable import feedmine

/// PR-13: the Main Feed's V2 presentation, its mode wiring and its viewport trigger.
///
/// The page these tests publish is built as a value (`MainFeedPage`) and never through
/// `FeedStore.persistFetchedItems`: publishing a real page writes the process-wide page cache
/// (`docs/runtime-v2/baseline.md` §8.3), and a test that only wants to state "this page" must not leave
/// one behind for an unrelated page-cache test to trip over.
@MainActor
final class MainFeedRuntimeV2Tests: XCTestCase {

    // MARK: - Mode wiring

    func testLegacyLaunchInstallsNoMirrorSinkAndPresentsWithoutASnapshotStore() {
        let defaults = makeDefaults(name: "pr13-legacy")
        // A legacy launch is the default: no request, no arguments.
        let runtime = MainFeedRuntime.launch(defaults: defaults, arguments: [])
        defer { runtime.stop() }

        XCTAssertEqual(runtime.decision.mode, .legacy)
        XCTAssertFalse(runtime.presentsFromV2)
        XCTAssertNil(runtime.presentation.store, "legacy must not put a V2 store in the path")
        XCTAssertNil(ShadowMirrorRegistry.current, "a legacy launch must install no mirror sink")
    }

    func testV2PresentationRequestIsHonouredOnTheNextLaunchAndLogsItsReason() {
        let defaults = makeDefaults(name: "pr13-v2")
        // The request is written now and applies to the *next* launch: a mode change is a relaunch,
        // because live transfer between modes does not exist.
        RuntimeModeLaunch.request(
            RequestedFeatures(shadow: false, v2UI: true, v2Network: false),
            in: defaults
        )
        XCTAssertEqual(RuntimeModeLaunch.current(in: defaults).mode, .legacy,
                       "the running mode is the decision taken at launch, never a fresh resolution")

        let runtime = MainFeedRuntime.launch(defaults: defaults, arguments: [])
        defer { runtime.stop() }

        XCTAssertEqual(runtime.decision.mode, .v2Presentation)
        XCTAssertTrue(runtime.presentsFromV2)
        XCTAssertNotNil(runtime.presentation.store, "v2Presentation puts the snapshot store in the path")
        XCTAssertNil(ShadowMirrorRegistry.current,
                     "v2Presentation owns no shadow: the mirror is not composed in this build")
        XCTAssertTrue(runtime.diagnostics.contains("presentation=v2-snapshots"), runtime.diagnostics)
        XCTAssertTrue(runtime.diagnostics.contains("mode=v2Presentation"), runtime.diagnostics)
    }

    func testInvalidRequestResolvesToLegacyAndTheReasonIsReported() {
        let defaults = makeDefaults(name: "pr13-invalid")
        RuntimeModeLaunch.request(
            RequestedFeatures(shadow: true, v2UI: true, v2Network: true),
            in: defaults
        )
        let runtime = MainFeedRuntime.launch(defaults: defaults, arguments: [])
        defer { runtime.stop() }

        XCTAssertEqual(runtime.decision.mode, .legacy)
        XCTAssertFalse(runtime.presentsFromV2)
        XCTAssertTrue(runtime.diagnostics.contains("rejected="), runtime.diagnostics)
        XCTAssertNil(ShadowMirrorRegistry.current)
    }

    // MARK: - The bridge: protocol and media are presentation, not view inference

    func testYouTubeItemStatesVideoChromeAndAPlayOverlay() {
        let item = makeItem(id: "yt", url: "https://www.youtube.com/watch?v=abc123")
        let affordances = MainFeedCardBridge.affordances(for: item)

        XCTAssertEqual(affordances.placeholder, .video)
        XCTAssertEqual(affordances.overlay, .play)
        XCTAssertEqual(affordances.badges, [.video])
        XCTAssertEqual(affordances.tap, .openReader)
    }

    func testPodcastItemStatesBadgeDurationOverlayAndMediaslotAudioTap() {
        let item = makeItem(
            id: "podcast",
            url: "https://example.com/episode",
            audioURL: "https://example.com/ep.mp3",
            duration: 3600
        )
        let affordances = MainFeedCardBridge.affordances(for: item)

        XCTAssertEqual(affordances.placeholder, .podcast)
        XCTAssertEqual(affordances.overlay, .headphones)
        XCTAssertEqual(affordances.badges, [.podcast])
        XCTAssertEqual(affordances.durationLabel, "1h")
        XCTAssertEqual(affordances.tap, .openReaderOrPlayAudioFromMedia)

        let value = MainFeedCardBridge.value(
            item: item,
            ordinal: 0,
            presentation: nil,
            band: .card
        )
        XCTAssertEqual(value.mediaSlot, .placeholder(.podcast),
                       "an episode with no image reserves the hero with its own surface")
        XCTAssertEqual(value.card.layout, .hero)
        XCTAssertEqual(value.card.affordances, affordances)
    }

    func testDirectAudioItemTakesTheWholeCardTap() {
        let item = makeItem(id: "direct", url: "https://cdn.example.com/ep.mp3")
        XCTAssertEqual(MainFeedCardBridge.affordances(for: item).tap, .playAudio)
    }

    func testForumItemStatesTheForumPlaceholder() {
        let item = makeItem(
            id: "forum",
            url: "https://example.com/thread",
            sourceURL: "https://www.reddit.com/r/swift/"
        )
        XCTAssertEqual(MainFeedCardBridge.affordances(for: item).placeholder, .forum)
    }

    func testTextOnlyItemFromTodayCarriesTheRecencyBadgeAndNoSlot() {
        let item = makeItem(id: "text", url: "https://example.com/a")
        let affordances = MainFeedCardBridge.affordances(for: item)
        XCTAssertEqual(affordances.badges, [.new])
        XCTAssertNil(affordances.overlay)

        let value = MainFeedCardBridge.value(
            item: item,
            ordinal: 0,
            presentation: nil,
            band: .card
        )
        XCTAssertEqual(value.mediaSlot, .none)
        XCTAssertEqual(value.card.layout, .textOnly)
        XCTAssertEqual(value.card.media, .none, "no slot means no media decision to draw")
    }

    func testResolvedImageBecomesLocalBytesAndNeverAURL() {
        let item = makeItem(id: "img", url: "https://example.com/a")
        let image = UIImage()
        let presentation = FeedCardPresentation(
            item: item,
            media: .image(image),
            layout: .hero,
            isRead: false,
            isBookmarked: false
        )
        let value = MainFeedCardBridge.value(
            item: item,
            ordinal: 3,
            presentation: presentation,
            band: .card
        )
        XCTAssertEqual(value.mediaSlot, .local(RenderImage(cacheKey: item.id, image: image)))
        XCTAssertEqual(value.card.media, .local(assetDigest: item.id))
        XCTAssertEqual(value.card.absoluteOrdinal, 3)
    }

    func testSessionLocalMediaDrawsThePrewarmedImage() throws {
        let presentation = makePresentation()
        let key = "main-feed|preset=everything|box=-"
        presentation.beginSession(contextKey: key)
        let cardID = try PublicationCardID(41)
        let image = UIImage()
        let rendered = RenderImage(cacheKey: "digest_r1", image: image)
        let card = CardPresentation(
            id: cardID,
            absoluteOrdinal: 0,
            title: "Prepared",
            subtitle: nil,
            media: .local(assetDigest: "digest"),
            layout: .hero,
            isBookmarked: false,
            isRead: false
        )

        XCTAssertNotNil(presentation.applySnapshot(
            makeSnapshot(contextKey: key, sequence: 1, cards: [card]),
            localMedia: [cardID: rendered]
        ))

        XCTAssertEqual(
            presentation.sections.first?.rows.first?.mediaSlot,
            .local(rendered),
            "a local publication reaches SwiftUI as the exact prewarmed pixels"
        )
    }

    func testMissingPublishedBytesBecomeAPlaceholderNeverAnEmptyFrame() throws {
        let presentation = makePresentation()
        let key = "main-feed|preset=everything|box=-"
        presentation.beginSession(contextKey: key)
        let card = CardPresentation(
            id: try PublicationCardID(42),
            absoluteOrdinal: 0,
            title: "Evicted",
            subtitle: nil,
            media: .local(assetDigest: "missing-digest"),
            layout: .hero,
            isBookmarked: false,
            isRead: false
        )

        XCTAssertNotNil(presentation.applySnapshot(
            makeSnapshot(contextKey: key, sequence: 1, cards: [card]),
            localMedia: [:]
        ))

        XCTAssertEqual(
            presentation.sections.first?.rows.first?.mediaSlot,
            .placeholder(.article),
            "published identity without local bytes degrades deterministically; the renderer never waits"
        )
    }

    func testCardIdentityIsStableAcrossPublicationsAndDistinctPerItem() {
        let first = MainFeedCardBridge.cardID(forLegacyItemID: "item-a")
        let again = MainFeedCardBridge.cardID(forLegacyItemID: "item-a")
        let other = MainFeedCardBridge.cardID(forLegacyItemID: "item-b")

        XCTAssertEqual(first, again, "the same item keeps the same card identity")
        XCTAssertNotEqual(first, other)
        XCTAssertGreaterThan(first.rawValue, 0, "the alias stays inside the allocatable range")
    }

    // MARK: - Publication

    func testPublishingAPageStatesEveryCardInTheSnapshotAndInOrder() {
        let presentation = makePresentation()
        let items = [makeItem(id: "a"), makeItem(id: "b"), makeItem(id: "c")]
        let page = makePage(items: items)

        let snapshot = presentation.publish(page)

        XCTAssertEqual(snapshot.cards.map(\.absoluteOrdinal), [0, 1, 2])
        XCTAssertEqual(snapshot.cards.count, 3)
        XCTAssertEqual(presentation.sections.flatMap(\.rows).map(\.item.id), ["a", "b", "c"])
        XCTAssertEqual(presentation.ordinalCount, 3)
        XCTAssertEqual(snapshot.editionID, presentation.snapshot?.editionID)
        XCTAssertEqual(presentation.store?.latest?.sequence, snapshot.sequence)
    }

    func testASessionCardShowsDisplayTextRatherThanThePublishersMarkup() {
        // The defect this pins, measured on screen on 2026-09-18 (a `v2Full` launch; the screenshot note
        // in `docs/runtime-v2/contract-matrix.md`): the frozen payload keeps what the publisher published
        // (`PublishedCardPayload.primaryText`), the package states it as the card's `subtitle`
        // (`FeedSessionReducer`), and this pipeline used to forward it — so the same feed showed `<p>…`
        // in `v2Full` while `legacy` showed clean text, because the legacy ingestion strips markup.
        let presentation = makePresentation()
        let key = "main-feed|preset=everything|box=-"
        presentation.beginSession(contextKey: key)

        let card = MainFeedCardBridge.value(
            item: makeItem(id: "a", excerpt: "<p>Raw <em>markup</em> from the publisher &amp; more</p>"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        XCTAssertNotNil(presentation.applySnapshot(makeSnapshot(contextKey: key, sequence: 1, cards: [card])))

        let drawn = presentation.sections.flatMap(\.rows)
        XCTAssertEqual(
            drawn.first?.item.excerpt,
            "Raw markup from the publisher & more",
            "a session card's excerpt is display text: the payload keeps the markup, the display side strips it"
        )
    }

    func testAnOlderPageForTheSameSessionNeverReplacesTheAppliedOne() {
        let presentation = makePresentation()
        _ = presentation.publish(makePage(items: [makeItem(id: "a")]))

        // A snapshot stamped with an older sequence than the applied one is refused and counted: the
        // store is the last place a stale result can be stopped before it paints.
        let stale = FeedPresentationSnapshot(
            sessionStamp: SessionStamp(0),
            sequence: 0,
            contextKey: "main-feed|preset=everything|box=-",
            editionID: nil,
            editorialRevision: nil,
            renderEnvironment: .unspecified,
            cards: []
        )
        XCTAssertFalse(presentation.store!.apply(stale))
        XCTAssertEqual(presentation.store!.rejectedSnapshotCount, 1)
    }

    func testContextKeyFollowsThePresetAndTheBookmarkBoxOnly() {
        let loader = FeedLoader(store: .empty())
        // PR-14: the key is the surface-context adapter's `ContextKey` for the Main Feed, serialized,
        // instead of the hand-built string PR-13 used. What it follows is unchanged: the preset and the
        // bookmark box are the only selectors in it.
        let key = MainFeedPresentation.contextKey(for: loader, contexts: SurfaceContextAdapters())
        XCTAssertTrue(key.contains("preset=everything"), key)
        XCTAssertTrue(key.contains("box=-"), key)
    }

    // MARK: - The viewport is the trigger

    func testViewportObservationSendsTheOrdinalsAndTheAnchorItHolds() {
        let recorded = IntentRecorder()
        let presentation = makePresentation(recording: recorded)
        _ = presentation.publish(makePage(items: (0..<30).map { makeItem(id: "item-\($0)") }))
        let runtime = makeRuntime(presentation: presentation)

        runtime.viewportChanged(visibleItemIDs: ["item-27", "item-25", "item-26"])

        XCTAssertEqual(recorded.viewports.count, 1)
        let viewport = try? XCTUnwrap(recorded.viewports.first)
        XCTAssertEqual(viewport?.firstVisibleOrdinal, 25)
        XCTAssertEqual(viewport?.lastVisibleOrdinal, 27)
        XCTAssertEqual(viewport?.anchor?.absoluteOrdinal, 25)
        XCTAssertEqual(viewport?.anchor?.cardID, presentation.cardByItemID["item-25"]?.id)
    }

    func testViewportReplenishmentUsesTheObservationAndNothingElse() async {
        let prober = ReplenishmentProbe()
        // The V2 path end to end: the observation goes to the store, the store forwards the intent to
        // the router this runtime answers, and the runtime schedules the replenishment.
        let router = MainFeedIntentRouter()
        let presentation = MainFeedPresentation(
            store: FeedScreenStore { intent in router.send(intent) },
            sessionStamp: SessionStamp(42),
            contexts: SurfaceContextAdapters(editionSeed: 1_000)
        )
        _ = presentation.publish(makePage(items: (0..<10).map { makeItem(id: "item-\($0)") }))
        let runtime = makeRuntime(router: router, presentation: presentation, probe: prober)

        // A card appearing is not a trigger: the same observation twice, and one is enough.
        runtime.viewportChanged(visibleItemIDs: ["item-1"])
        runtime.viewportChanged(visibleItemIDs: ["item-1"])
        await prober.waitForObservations(1)

        let lastOrdinal = await prober.lastOrdinal
        let lastCount = await prober.lastCount
        let observed = await prober.count
        XCTAssertEqual(lastOrdinal, 1)
        XCTAssertEqual(lastCount, 10)
        XCTAssertGreaterThanOrEqual(observed, 1)
    }

    // MARK: - The page the screen draws, per selection (plan §17, DoD2)

    /// In the acquiring mode the surface the session's plan was built for draws the session and nothing
    /// else: the phase, the emptiness and the empty surface come from its snapshots, while the legacy
    /// page of the *same* selection — the cached one, which the legacy store still holds — is on screen
    /// in no form at all.
    ///
    /// The test keeps that legacy page deliberately non-empty (`store.loadBookmarkFeed`), so the
    /// assertions are about the choice and not about the page being empty by accident: `loader.items`
    /// has an item, `presentation.sections` has none until the session publishes, and the state the
    /// screen consumes is the session's.
    func testAV2FullLaunchDrawsTheSessionSurfaceForTheSelectionItsPlanWasBuiltFor() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "dod2-v2full"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        XCTAssertEqual(runtime.decision.mode, .v2Full)
        XCTAssertTrue(runtime.ownsAcquisition)

        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        // The legacy page for this selection exists and has an item: it is the page the screen used to
        // be able to fall back to.
        store.loadBookmarkFeed(items: [makeItem(id: "legacy-page-item")])
        XCTAssertFalse(loader.items.isEmpty)

        // The first frame, before the screen attaches: the launch's own facts already answer, because a
        // runtime that owns acquisition claims the selection its plan is built for as the first thing
        // `attach` does. Answering `nil` here painted the legacy startup runway on this surface for
        // 7.3 ms of every launch (`loading-progress-report.md` §4).
        XCTAssertEqual(
            runtime.sessionSurface, .preparing,
            "the first frame is the session's, not the legacy lane"
        )

        runtime.attach(loader: loader)

        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        XCTAssertEqual(runtime.presentation.selectionContextKey, sessionKey)
        XCTAssertEqual(runtime.presentation.pageSource, .sessionSnapshot)
        XCTAssertTrue(runtime.presentation.sections.isEmpty)
        XCTAssertEqual(
            runtime.sessionSurface, .preparing,
            "the session owns this selection and has published nothing yet"
        )

        // An edition with no cards is the session saying empty. The legacy page still has its item, and
        // it is not consulted: the screen's empty surface is the session's statement, not the legacy
        // "these articles may have been trimmed" guidance.
        XCTAssertNotNil(runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [])
        ))
        XCTAssertEqual(runtime.sessionSurface, .empty(.generic))
        XCTAssertFalse(loader.items.isEmpty, "the legacy page is still there and still not the source")

        // An edition with cards draws the session's own rows.
        let cards = ["a", "b"].map { id in
            MainFeedCardBridge.value(
                item: makeItem(id: id),
                ordinal: id == "a" ? 0 : 1,
                presentation: nil,
                band: .card
            ).card
        }
        XCTAssertNotNil(runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 2, cards: cards)
        ))
        XCTAssertEqual(runtime.sessionSurface, .content)
        let drawn = runtime.presentation.sections.flatMap(\.rows)
        XCTAssertEqual(drawn.map(\.item.id), ["card:\(cards[0].id)", "card:\(cards[1].id)"])
        XCTAssertFalse(
            drawn.contains { $0.item.id == "legacy-page-item" },
            "the legacy page's item is not what the runtime-owned surface draws"
        )
    }

    /// The session owns one selection, not the screen. A reader who moves to a bookmark box, a Smart
    /// Feed or a collection is on a surface the session's plan was not built for, and that surface draws
    /// its own legacy page — which the store still holds in this mode, because `LegacyAcquisitionGate`
    /// refuses fetches and not local reads. Coming back to the session's selection draws the session's
    /// last snapshot again rather than the page it replaced.
    func testThePageFollowsTheSelectionRatherThanTheMode() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The active preset persists in `UserDefaults.standard` and `FeedStore.setPreset` refuses a change to
        // the value it already holds, so this test must start from a known selection: another test leaving
        // `.lastClicked` persisted turns the switch below into a no-op and the page never follows. Measured by
        // the read-state slice, whose own test ran before this one and made it fail. Save-and-restore is the
        // idiom `FeedStoreTests` already uses for the same reason.
        let previousPreset = Settings.activePreset
        Settings.activePreset = .everything
        defer { Settings.activePreset = previousPreset }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "dod2-selection"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        runtime.attach(loader: loader)

        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        let card = MainFeedCardBridge.value(
            item: makeItem(id: "a"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        _ = runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [card])
        )
        XCTAssertEqual(runtime.sessionSurface, .content)

        // Another selection: the session's plan was built for the preset this launch started with.
        loader.setActivePreset(.lastClicked)
        await waitForPageSource(.legacyPage, in: runtime.presentation)
        XCTAssertNil(
            runtime.sessionSurface,
            "the screen draws this selection's own legacy page, with its own phase and items"
        )

        // And that selection's own content is what the page draws. The store still has it because the
        // gate closes *fetches* (`RSSFetcher.performFetch:131`), not local reads: the local path here is
        // the shape `FeedStore.loadLastClickedFeed` (a `db.read`) and the bookmark box's
        // `FeedStore.bookmarkedItems` follow.
        store.loadBookmarkFeed(items: [makeItem(id: "other-surface-item")])
        await waitForDrawnItem("other-surface-item", in: runtime.presentation)
        XCTAssertFalse(
            runtime.presentation.sections.flatMap(\.rows).contains { $0.item.id == "card:\(card.id)" },
            "the session's card is not what another selection draws"
        )

        // Back to the selection the session owns: its snapshot is still the page.
        loader.setActivePreset(.everything)
        await waitForPageSource(.sessionSnapshot, in: runtime.presentation)
        XCTAssertEqual(runtime.presentation.sections.flatMap(\.rows).map(\.item.id), ["card:\(card.id)"])
        XCTAssertEqual(runtime.sessionSurface, .content)
    }

    /// In every other mode the legacy page is still the page, unchanged, including `v2Presentation`,
    /// where a `FeedScreenStore` is in the path: a store in the path is not a session that owns a
    /// surface.
    func testEveryModeThatOwnsNoAcquisitionKeepsTheLegacyPage() {
        for (name, request) in [
            ("dod2-legacy", nil),
            ("dod2-v2presentation", RequestedFeatures(shadow: false, v2UI: true, v2Network: false)),
        ] as [(String, RequestedFeatures?)] {
            let defaults = makeDefaults(name: name)
            if let request { RuntimeModeLaunch.request(request, in: defaults) }
            let runtime = MainFeedRuntime.launch(defaults: defaults, arguments: [])
            defer { runtime.stop() }
            XCTAssertFalse(runtime.ownsAcquisition)

            let loader = FeedLoader(store: .empty())
            runtime.attach(loader: loader)

            XCTAssertNil(runtime.sessionSurface, "\(name): the legacy page is the page")
            XCTAssertEqual(runtime.presentation.pageSource, .legacyPage, name)
            XCTAssertNil(runtime.presentation.sessionContextKey, name)
            XCTAssertEqual(runtime.sessionDiagnostics, "session=none", name)
        }
    }

    /// The state the session's own publication states, over every combination the boundary has.
    ///
    /// There is no `FeedLoader` in this mapping by construction: nothing here can answer with the legacy
    /// page's phase, its item count or its filters.
    func testTheSessionSurfaceStatesOnlyTheSessionsOwnPublication() {
        let key = "main-feed|preset=everything|box=-"
        let empty = makeSnapshot(contextKey: key, sequence: 1, cards: [])
        let card = MainFeedCardBridge.value(
            item: makeItem(id: "a"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        let content = makeSnapshot(contextKey: key, sequence: 2, cards: [card])

        XCTAssertEqual(MainFeedSessionSurface.forSession(snapshot: nil, state: .notStarted), .preparing)
        XCTAssertEqual(
            MainFeedSessionSurface.forSession(snapshot: nil, state: .acquiring(sources: 32)),
            .preparing
        )
        XCTAssertEqual(
            MainFeedSessionSurface.forSession(snapshot: empty, state: .acquiring(sources: 32)),
            .empty(.generic)
        )
        XCTAssertEqual(
            MainFeedSessionSurface.forSession(snapshot: content, state: .acquiring(sources: 32)),
            .content
        )
        // Nothing to acquire from is a definitive answer: the reader is told, rather than left on the
        // preparing surface, and the snapshot is irrelevant to it.
        XCTAssertEqual(
            MainFeedSessionSurface.forSession(snapshot: nil, state: .noCatalogue),
            .empty(.noSourcesEnabled)
        )
        XCTAssertEqual(
            MainFeedSessionSurface.forSession(snapshot: content, state: .noCatalogue),
            .empty(.noSourcesEnabled)
        )
    }

    // MARK: - The loading chrome: the runtime's statement, or the runway verbatim

    /// The loading chrome on the surface the session owns reads the runtime's own statement, and the
    /// legacy startup runway's counters are not read there at all.
    ///
    /// The runway is deliberately non-trivial — one of three sources fetched, through `FeedStore`'s own
    /// path — so the assertion is about the choice and not about the counters being empty by accident:
    /// the same loader yields "1/3" and "33%" on the lane that still owns it, and neither number on the
    /// session's. The statement itself is the runtime's: the session state plus the acquisition owner's
    /// own watch report, and no fraction, because the runtime has no measurement for one.
    func testTheSessionLoadingSurfaceStatesTheRuntimesOwnAcquisitionAndNotTheLegacyRunway() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "loading-v2full"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        XCTAssertTrue(runtime.ownsAcquisition)

        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        makeLegacyRunway(on: store)
        runtime.attach(loader: loader)

        // The surface the session owns, before its first publication: the loading chrome is the session's
        // own statement, and the session has not reached the acquisition owner yet, so it states that.
        XCTAssertEqual(runtime.sessionSurface, .preparing)
        let statement = try XCTUnwrap(runtime.sessionLoadingStatement)
        XCTAssertEqual(
            statement,
            MainFeedLoadingStatement.forSession(state: .notStarted, report: nil),
            "the launch is in its bootstrap: the session states nothing about sources yet"
        )
        XCTAssertEqual(statement, .readingCatalogue)

        let session = FeedLoadingDisplay.forSurface(session: statement, loader: loader)
        XCTAssertEqual(session, .session(statement))
        XCTAssertEqual(session.source, "session")
        XCTAssertFalse(session.hasProgressBar, "no fraction means no bar, and no 0% claim either")
        XCTAssertNil(session.percentage, "the runtime has no measurement for how much of the feed is loaded")
        XCTAssertFalse(session.isReady)
        XCTAssertTrue(session.rotatingSourceTitles.isEmpty)
        XCTAssertFalse(session.detail.contains("1/3"), session.detail)
        XCTAssertFalse(session.accessibilityValue.contains("1/3"), session.accessibilityValue)

        // The same loader on the lane that still owns the counters: verbatim, percentage included.
        let legacy = FeedLoadingDisplay.forSurface(session: nil, loader: loader)
        XCTAssertEqual(legacy.source, "runway")
        XCTAssertEqual(
            legacy,
            .runway(
                fetched: 1,
                target: 3,
                isReady: false,
                recentlyFetchedSourceNames: ["Legacy Source"],
                hasPreviouslyLoadedContent: false
            )
        )
        XCTAssertEqual(legacy.displayedCount, 1)
        XCTAssertEqual(legacy.detail, "1/3")
        XCTAssertEqual(legacy.percentage, "33%")
        XCTAssertEqual(legacy.accessibilityValue, "1/3")
        XCTAssertEqual(legacy.rotatingSourceTitles, ["Legacy Source"])
        XCTAssertTrue(legacy.hasProgressBar)

        // What a started session's surface states: the owner's own watch report, as counts of sources.
        let report = V2AcquisitionReport(
            watched: 32,
            registered: 30,
            reused: 2,
            refused: ["catalogue-key: refused"]
        )
        let acquiring = MainFeedLoadingStatement.forSession(state: .acquiring(sources: 118), report: report)
        XCTAssertEqual(acquiring, .acquiring(catalogueSources: 118, watched: .init(count: 32, refused: 1)))

        let acquiringDisplay = FeedLoadingDisplay.forSurface(session: acquiring, loader: loader)
        XCTAssertEqual(acquiringDisplay.source, "session")
        XCTAssertEqual(acquiringDisplay.displayedCount, 32)
        XCTAssertNil(acquiringDisplay.percentage)
        XCTAssertFalse(acquiringDisplay.hasProgressBar)
        XCTAssertTrue(acquiringDisplay.title.contains("32"), acquiringDisplay.title)
        XCTAssertFalse(
            acquiringDisplay.title.contains("118"),
            "the title states what the acquisition owner took on, not the catalogue the session was offered: \(acquiringDisplay.title)"
        )
        XCTAssertTrue(acquiringDisplay.detail.contains("32"), acquiringDisplay.detail)
        XCTAssertTrue(acquiringDisplay.detail.contains("118"), acquiringDisplay.detail)
        XCTAssertFalse(acquiringDisplay.detail.contains("1/3"), acquiringDisplay.detail)
        XCTAssertNotEqual(acquiringDisplay, legacy, "the statement is not the runway's counters")
        XCTAssertNotEqual(
            acquiringDisplay.title,
            FeedLoadingDisplay.session(.readingCatalogue).title,
            "the two session states say different things"
        )
    }

    /// Every mode whose runtime owns no acquisition — and the acquiring mode on a selection the session's
    /// plan was not built for — keeps the legacy loading runway: no statement, so the chrome reads the
    /// counters exactly as it did before this entry point existed.
    func testEveryModeAndEverySelectionThatOwnsNoSessionKeepsTheLegacyLoadingRunway() async throws {
        for (name, request) in [
            ("loading-legacy", nil),
            ("loading-v2presentation", RequestedFeatures(shadow: false, v2UI: true, v2Network: false)),
        ] as [(String, RequestedFeatures?)] {
            let defaults = makeDefaults(name: name)
            if let request { RuntimeModeLaunch.request(request, in: defaults) }
            let runtime = MainFeedRuntime.launch(defaults: defaults, arguments: [])
            defer { runtime.stop() }

            let store = FeedStore.empty()
            let loader = FeedLoader(store: store)
            makeLegacyRunway(on: store)
            runtime.attach(loader: loader)

            XCTAssertNil(runtime.sessionLoadingStatement, "\(name): the runway is the loading chrome")
            XCTAssertEqual(
                FeedLoadingDisplay.forSurface(session: runtime.sessionLoadingStatement, loader: loader),
                .runway(
                    fetched: 1,
                    target: 3,
                    isReady: false,
                    recentlyFetchedSourceNames: ["Legacy Source"],
                    hasPreviouslyLoadedContent: false
                ),
                name
            )
        }

        // The acquiring mode, on the selection the session's plan was not built for: that surface's own
        // legacy page is the page, and its loading chrome is the legacy one.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Same reason as `dod2-selection`: this test reaches another selection by switching the preset, which
        // is a no-op when the persisted value is already the target.
        let previousPreset = Settings.activePreset
        Settings.activePreset = .everything
        defer { Settings.activePreset = previousPreset }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "loading-other-selection"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        makeLegacyRunway(on: store)
        runtime.attach(loader: loader)
        XCTAssertEqual(runtime.sessionSurface, .preparing)
        XCTAssertNotNil(runtime.sessionLoadingStatement)

        loader.setActivePreset(.lastClicked)
        await waitForPageSource(.legacyPage, in: runtime.presentation)
        XCTAssertNil(
            runtime.sessionLoadingStatement,
            "another selection's loading chrome is the legacy runway's"
        )
        XCTAssertEqual(
            FeedLoadingDisplay.forSurface(session: runtime.sessionLoadingStatement, loader: loader).detail,
            "1/3"
        )

        // Back on the selection the session owns, the statement is the session's again.
        loader.setActivePreset(.everything)
        await waitForPageSource(.sessionSnapshot, in: runtime.presentation)
        XCTAssertEqual(runtime.sessionSurface, .preparing)
        XCTAssertEqual(runtime.sessionLoadingStatement, .readingCatalogue)
    }

    // MARK: - The empty surface: the runtime's statement, or the legacy page verbatim

    /// The empty surface on the surface the session owns is built from the runtime's own statement, and
    /// the legacy loader's counters are not read there at all.
    ///
    /// The legacy page is deliberately non-trivial — two sources with one toggled off, and its own loading
    /// state — so the assertion is about the choice and not about the loader being empty by accident: the
    /// same loader yields "Loading your feed..." and "Fetching articles from 2 sources." on the lane that
    /// still owns it, and neither figure on the session's.
    func testTheSessionEmptySurfaceStatesTheRuntimesOwnAcquisitionAndNotTheLegacyPage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "empty-v2full"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        XCTAssertTrue(runtime.ownsAcquisition)

        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        makeLegacyEmptyPage(on: store)
        runtime.attach(loader: loader)

        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        XCTAssertNotNil(runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [])
        ))
        XCTAssertEqual(runtime.sessionSurface, .empty(.generic))

        // What the screen is handed: the session's variant and the session's own acquisition — the launch
        // is in its bootstrap, so that is what it states — and nothing of the legacy page.
        let statement = try XCTUnwrap(runtime.sessionEmptyStatement)
        XCTAssertEqual(statement.mode, .generic)
        XCTAssertEqual(statement.acquisition, .readingCatalogue)

        let display = FeedEmptyDisplay.forSurface(session: statement, mode: .generic, loader: loader)
        XCTAssertEqual(display, .session(statement))
        XCTAssertEqual(display.source, "session")
        XCTAssertEqual(
            display.title,
            "No articles yet",
            "the session published an empty edition; it is not the legacy page's loading state"
        )
        XCTAssertEqual(display.iconName, "newspaper.fill")
        XCTAssertFalse(display.isRefreshing, "the runtime states no refresh in flight")
        XCTAssertTrue(display.showActions)
        XCTAssertFalse(display.showOpenFilters)
        XCTAssertNil(display.disabledSourcesTip, "the runtime states no disabled-source count")
        XCTAssertEqual(display.progressText, "Waiting for the source catalogue")
        let circadian = display.description(circadian: "circadian")
        XCTAssertEqual(circadian, "circadian", "no legacy figure takes the session's description")

        // The same loader on the lane that still owns the legacy page: verbatim, counters included. The
        // whole value is pinned, so every legacy property the lane reads is accounted for.
        let legacy = FeedEmptyDisplay.forSurface(session: nil, mode: .generic, loader: loader)
        XCTAssertEqual(
            legacy,
            .legacy(
                FeedEmptyLegacyFacts(
                    mode: .generic,
                    isRefreshing: false,
                    isInitial: true,
                    sourceCount: 2,
                    fetchErrorCount: 0,
                    totalFetched: 0,
                    hasAnySource: true,
                    disabledSourceCount: 1
                )
            )
        )
        XCTAssertEqual(legacy.source, "legacy")
        XCTAssertEqual(legacy.title, "Loading your feed...")
        XCTAssertEqual(legacy.description(circadian: "circadian"), "Fetching articles from 2 sources.")
        XCTAssertEqual(legacy.iconName, "antenna.radiowaves.left.and.right")
        XCTAssertFalse(legacy.isRefreshing)
        XCTAssertFalse(legacy.showActions)
        XCTAssertNil(legacy.progressText)
        XCTAssertEqual(legacy.disabledSourcesTip, "Tip: 1 source is disabled")
        XCTAssertNotEqual(display, legacy, "the statement is not the legacy page's own empty surface")

        // What a started session's surface states: the owner's own watch report, in the loading surface's
        // own vocabulary, where the legacy wording stated a source count — and no legacy figure.
        let report = V2AcquisitionReport(
            watched: 32,
            registered: 30,
            reused: 2,
            refused: ["catalogue-key: refused"]
        )
        let acquiring = FeedEmptyStatement(
            mode: .generic,
            acquisition: MainFeedLoadingStatement.forSession(state: .acquiring(sources: 118), report: report)
        )
        let acquiringDisplay = FeedEmptyDisplay.forSurface(session: acquiring, mode: .generic, loader: loader)
        let line = try XCTUnwrap(acquiringDisplay.progressText)
        XCTAssertTrue(line.contains("32"), line)
        XCTAssertTrue(line.contains("118"), line)
        XCTAssertFalse(line.contains("Fetching articles from"), line)
        XCTAssertEqual(acquiringDisplay.title, "No articles yet")

        // The no-catalogue answer: the session's own variant, with no count owed and no legacy read either.
        let none = FeedEmptyDisplay.forSurface(
            session: FeedEmptyStatement(mode: .noSourcesEnabled, acquisition: .noCatalogue),
            mode: .noSourcesEnabled,
            loader: loader
        )
        XCTAssertEqual(none.title, "No sources enabled")
        XCTAssertEqual(
            none.description(circadian: "circadian"),
            "Enable some countries or topics in Filters to start seeing content."
        )
        XCTAssertEqual(none.iconName, "globe.americas.fill")
        XCTAssertTrue(none.showOpenFilters)
        XCTAssertTrue(none.showActions)
        XCTAssertNil(none.progressText)
        XCTAssertNil(none.disabledSourcesTip)
    }

    /// Every mode whose runtime owns no acquisition — and the acquiring mode on a selection the session's
    /// plan was not built for — keeps the legacy empty surface: no statement, so the surface reads the same
    /// loader properties it read before this entry point existed.
    func testEveryModeAndEverySelectionThatOwnsNoSessionKeepsTheLegacyEmptySurface() async throws {
        for (name, request, mode) in [
            ("empty-legacy", nil, RuntimeMode.legacy),
            (
                "empty-mirroredshadow",
                RequestedFeatures(shadow: true, v2UI: false, v2Network: false),
                RuntimeMode.mirroredShadow
            ),
            (
                "empty-v2presentation",
                RequestedFeatures(shadow: false, v2UI: true, v2Network: false),
                RuntimeMode.v2Presentation
            ),
        ] as [(String, RequestedFeatures?, RuntimeMode)] {
            let defaults = makeDefaults(name: name)
            if let request { RuntimeModeLaunch.request(request, in: defaults) }
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let runtime = MainFeedRuntime.launch(
                applicationSupportDirectory: directory,
                defaults: defaults,
                arguments: []
            )
            defer { runtime.stop() }

            XCTAssertEqual(runtime.decision.mode, mode, name)
            XCTAssertFalse(
                runtime.ownsAcquisition,
                "\(name): the legacy engine is this launch's acquisition owner, if anything is"
            )

            let store = FeedStore.empty()
            let loader = FeedLoader(store: store)
            makeLegacyEmptyPage(on: store)
            runtime.attach(loader: loader)

            XCTAssertNil(runtime.sessionEmptyStatement, "\(name): the legacy page is this surface's owner")
            let display = FeedEmptyDisplay.forSurface(
                session: runtime.sessionEmptyStatement,
                mode: .generic,
                loader: loader
            )
            XCTAssertEqual(display.source, "legacy", name)
            XCTAssertEqual(display.title, "Loading your feed...", name)
            XCTAssertEqual(display.description(circadian: "circadian"), "Fetching articles from 2 sources.", name)
            XCTAssertEqual(display.iconName, "antenna.radiowaves.left.and.right", name)
            XCTAssertEqual(display.disabledSourcesTip, "Tip: 1 source is disabled", name)
            XCTAssertFalse(display.showActions, name)
        }

        // The acquiring mode, on the selection the session's plan was not built for: that surface's own
        // legacy page is the page — and its empty variant and figures are the legacy page's own too. The
        // store is left with no source at all, so the session's task finds no catalogue and nothing is
        // published while this half runs.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Same reason as the loading slice's test: this test reaches another selection by switching the
        // preset, which is a no-op when the persisted value is already the target.
        let previousPreset = Settings.activePreset
        Settings.activePreset = .everything
        defer { Settings.activePreset = previousPreset }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "empty-other-selection"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        runtime.attach(loader: loader)

        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        XCTAssertNotNil(runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [])
        ))
        XCTAssertEqual(runtime.sessionSurface, .empty(.generic))
        XCTAssertNotNil(runtime.sessionEmptyStatement, "the session's own surface states its variant")

        loader.setActivePreset(.lastClicked)
        await waitForPageSource(.legacyPage, in: runtime.presentation)
        XCTAssertNil(
            runtime.sessionEmptyStatement,
            "another selection's empty surface is the legacy page's"
        )
        let display = FeedEmptyDisplay.forSurface(
            session: runtime.sessionEmptyStatement,
            mode: .generic,
            loader: loader
        )
        XCTAssertEqual(display.source, "legacy")
        XCTAssertEqual(display.title, "No sources found", "the empty store's page, verbatim")

        // Back on the selection the session owns: its own statement is the surface's again.
        loader.setActivePreset(.everything)
        await waitForPageSource(.sessionSnapshot, in: runtime.presentation)
        XCTAssertEqual(runtime.sessionEmptyStatement?.mode, .generic)
    }

    // MARK: - The header chip: the session's statement, or the legacy runway verbatim

    /// The header chip on the page the session owns states the runtime's own statement, and the legacy
    /// startup runway's counters are not read there at all.
    ///
    /// The runway is deliberately non-trivial — one of four sources fetched and still preparing, through
    /// `FeedStore`'s own path — so the assertion is about the choice and not about the counters being empty
    /// by accident: the same loader yields "1/4" and "1 of 4 sources verified" on the lane that still owns
    /// them, and neither figure on the session's.
    func testTheSessionHeaderChipStatesTheRuntimesOwnStatementAndNotTheLegacyRunway() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "chip-v2full"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        XCTAssertTrue(runtime.ownsAcquisition)

        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        makeLegacyCatalogue(on: store)
        makeLegacyRunway(on: store)
        store.display.setIsPreparingInitialRunway(true)
        runtime.attach(loader: loader)

        // The screen the session owns, before its first publication: the chip states the runtime's
        // statement, in the loading chrome's own words, and no runway figure is reachable from it.
        XCTAssertEqual(runtime.sessionSurface, .preparing)
        let statement = try XCTUnwrap(runtime.sessionChipStatement)
        XCTAssertEqual(statement, .readingCatalogue)
        XCTAssertEqual(runtime.sessionLoadingStatement, statement, "one launch, one statement")

        let display = CompactFeedDisplay.forSurface(session: statement, loader: loader)
        XCTAssertEqual(display, .session(statement))
        XCTAssertEqual(display.source, "session")
        XCTAssertNil(display.runwayReady, "the runtime states no completion for the runway's cue to watch")
        let content = try XCTUnwrap(display.content(readyPulse: false))
        XCTAssertEqual(
            content,
            .figures(
                counter: "· Waiting for the source catalogue",
                articles: nil,
                isComplete: false,
                label: "Waiting for the source catalogue"
            ),
            "the chip states the session's own sentence and no first-screen clause"
        )
        XCTAssertEqual(
            display.content(readyPulse: true),
            content,
            "the completion cue is the runway's; the session's lane does not raise it"
        )
        XCTAssertEqual(display.diagnosticValue, "· Waiting for the source catalogue")

        // The same loader on the lane that still owns the chip: verbatim, the runway's own figures. The
        // whole value is pinned, so every legacy property the lane reads is accounted for — the runway's
        // denominator included, which is the chip's own fold (`max(startupTotalSourceCount, sourceCount)`):
        // this store never called `start()`, which is what stamps `startupTotalSourceCount` from the
        // bundle's catalogue manifest, so the fold answers the four sources the registry has.
        let legacy = CompactFeedDisplay.forSurface(session: nil, loader: loader)
        XCTAssertEqual(
            legacy,
            .legacy(
                CompactFeedLegacyFacts(
                    isPreparingRunway: true,
                    fetchedSourceCount: 1,
                    totalSourceCount: 4,
                    itemsReady: 0,
                    itemsTarget: loader.startupItemsTarget,
                    activeSourceCount: 4,
                    sourceCount: 4,
                    runwayReady: false
                )
            )
        )
        XCTAssertEqual(legacy.source, "legacy")
        let legacyArticles = "· 0 of \(loader.startupItemsTarget) articles for your first screen"
        XCTAssertEqual(
            legacy.content(readyPulse: false),
            .figures(
                counter: "· 1/4",
                articles: legacyArticles,
                isComplete: false,
                label: "1 of 4 sources verified"
            )
        )
        // The cue is what keeps the figures up for the 1.4 s after the wave is ready, so the same lane
        // answers with the same figures and the completion state raised.
        XCTAssertEqual(
            legacy.content(readyPulse: true),
            .figures(
                counter: "· 1/4",
                articles: legacyArticles,
                isComplete: true,
                label: "1 of 4 sources verified"
            )
        )
        XCTAssertNotEqual(display, legacy, "the statement is not the runway's counters")
        XCTAssertFalse(
            content.diagnosticValue.contains("1/4"),
            "the runway's denominator is not reachable from the session's lane: \(content.diagnosticValue)"
        )

        // The chip is the session's in every state of that surface, not only while nothing is published:
        // the loading chrome's guard (the session has published nothing yet) is narrower than the chip's,
        // because the chrome is one content branch while the chip is the whole screen's.
        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        let card = MainFeedCardBridge.value(
            item: makeItem(id: "chip-card"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        XCTAssertNotNil(runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [card])
        ))
        XCTAssertEqual(runtime.sessionSurface, .content)
        XCTAssertNil(runtime.sessionLoadingStatement, "the loading chrome is gone once the session publishes")
        XCTAssertEqual(
            runtime.sessionChipStatement,
            statement,
            "the chip is still the session's on the published page"
        )

        // What a started session's chip states: the catalogue its owner was offered and how many sources
        // it watched, in the loading chrome's own sentence — never the runway's fraction.
        let report = V2AcquisitionReport(
            watched: 32,
            registered: 30,
            reused: 2,
            refused: ["catalogue-key: refused"]
        )
        let acquiring = MainFeedLoadingStatement.forSession(state: .acquiring(sources: 71_234), report: report)
        XCTAssertEqual(acquiring, .acquiring(catalogueSources: 71_234, watched: .init(count: 32, refused: 1)))
        let acquiringContent = try XCTUnwrap(
            CompactFeedDisplay.forSurface(session: acquiring, loader: loader).content(readyPulse: false)
        )
        let sentence = FeedLoadingDisplay.session(acquiring).detail
        XCTAssertEqual(
            acquiringContent,
            .figures(counter: "· " + sentence, articles: nil, isComplete: false, label: sentence),
            "the chip states the acquisition in the loading chrome's own sentence"
        )
        XCTAssertTrue(acquiringContent.diagnosticValue.contains("32"), acquiringContent.diagnosticValue)
        XCTAssertTrue(acquiringContent.diagnosticValue.contains("watched"), acquiringContent.diagnosticValue)
        XCTAssertFalse(
            acquiringContent.diagnosticValue.contains("verified"),
            "the runtime watches sources; it does not verify them: \(acquiringContent.diagnosticValue)"
        )
        XCTAssertFalse(acquiringContent.diagnosticValue.contains("1/4"), acquiringContent.diagnosticValue)

        // Nothing to acquire from: the page's own empty surface states "No sources enabled", and the
        // legacy chip is silent in the same condition — so is this one.
        let none = CompactFeedDisplay.forSurface(session: .noCatalogue, loader: loader)
        XCTAssertEqual(none, .session(.noCatalogue))
        XCTAssertNil(none.content(readyPulse: false))
        XCTAssertEqual(none.diagnosticValue, "none")
    }

    /// Every mode whose runtime owns no acquisition — and the acquiring mode on a selection the session's
    /// plan was not built for — keeps the legacy header chip, verbatim: no statement, so the chip reads the
    /// same loader properties it read before this entry point existed.
    func testEveryModeAndEverySelectionThatOwnsNoSessionKeepsTheLegacyHeaderChip() async throws {
        for (name, request, mode) in [
            ("chip-legacy", nil, RuntimeMode.legacy),
            (
                "chip-mirroredshadow",
                RequestedFeatures(shadow: true, v2UI: false, v2Network: false),
                RuntimeMode.mirroredShadow
            ),
            (
                "chip-v2presentation",
                RequestedFeatures(shadow: false, v2UI: true, v2Network: false),
                RuntimeMode.v2Presentation
            ),
        ] as [(String, RequestedFeatures?, RuntimeMode)] {
            let defaults = makeDefaults(name: name)
            if let request { RuntimeModeLaunch.request(request, in: defaults) }
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let runtime = MainFeedRuntime.launch(
                applicationSupportDirectory: directory,
                defaults: defaults,
                arguments: []
            )
            defer { runtime.stop() }
            XCTAssertEqual(runtime.decision.mode, mode, name)

            let store = FeedStore.empty()
            let loader = FeedLoader(store: store)
            // Four enabled sources and no runway yet: the chip's second branch, which is the catalogue's
            // own line, and its denominator is the fold the chip has always made
            // (`max(startupTotalSourceCount, sourceCount)`) — the registry's four, since this store never
            // called `start()`, which is what stamps `startupTotalSourceCount`.
            makeLegacyCatalogue(on: store)
            runtime.attach(loader: loader)

            XCTAssertNil(runtime.sessionChipStatement, "\(name): the runway is this chip's owner")
            let display = CompactFeedDisplay.forSurface(session: runtime.sessionChipStatement, loader: loader)
            XCTAssertEqual(display.source, "legacy", name)
            XCTAssertEqual(display.runwayReady, false, name)
            XCTAssertEqual(display.content(readyPulse: false), .catalogueLine("·4/4 sources"), name)
            // The transient cue still shows the startup figures, as it did: it is the chip's own shape.
            XCTAssertEqual(
                display.content(readyPulse: true),
                .figures(
                    counter: "· 0/4",
                    articles: "· 0 of \(loader.startupItemsTarget) articles for your first screen",
                    isComplete: true,
                    label: "0 of 4 sources verified"
                ),
                name
            )

            // With the runway building its first page, the same lane states the runway's figures.
            makeLegacyRunway(on: store)
            store.display.setIsPreparingInitialRunway(true)
            let preparing = CompactFeedDisplay.forSurface(session: runtime.sessionChipStatement, loader: loader)
            XCTAssertEqual(
                preparing.content(readyPulse: false),
                .figures(
                    counter: "· 1/4",
                    articles: "· 0 of \(loader.startupItemsTarget) articles for your first screen",
                    isComplete: false,
                    label: "1 of 4 sources verified"
                ),
                name
            )
            XCTAssertEqual(preparing.diagnosticValue, "· 1/4", name)
        }

        // The acquiring mode, on the selection the session's plan was not built for: that surface's own
        // legacy page is the page, and the chip on it is the legacy one too.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Same reason as the loading slice's test: this test reaches another selection by switching the
        // preset, which is a no-op when the persisted value is already the target.
        let previousPreset = Settings.activePreset
        Settings.activePreset = .everything
        defer { Settings.activePreset = previousPreset }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "chip-other-selection"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        makeLegacyRunway(on: store)
        store.display.setIsPreparingInitialRunway(true)
        runtime.attach(loader: loader)
        XCTAssertEqual(runtime.sessionSurface, .preparing)
        XCTAssertEqual(runtime.sessionChipStatement, .readingCatalogue)

        loader.setActivePreset(.lastClicked)
        await waitForPageSource(.legacyPage, in: runtime.presentation)
        XCTAssertNil(
            runtime.sessionChipStatement,
            "another selection's chip is the legacy runway's"
        )
        // The runway's denominator is `0` here and that is the lane's own answer, not the session's: this
        // store never called `start()` (which stamps `startupTotalSourceCount` from the bundle's catalogue
        // manifest) and it has no registry sources either — the empty catalogue is what keeps the session
        // from starting and publishing while this half runs. What the assertion is for is the lane.
        XCTAssertEqual(
            CompactFeedDisplay.forSurface(session: runtime.sessionChipStatement, loader: loader)
                .content(readyPulse: false),
            .figures(
                counter: "· 1/0",
                articles: "· 0 of \(loader.startupItemsTarget) articles for your first screen",
                isComplete: false,
                label: "1 of 0 sources verified"
            )
        )

        // Back on the selection the session owns, the chip is the session's again.
        loader.setActivePreset(.everything)
        await waitForPageSource(.sessionSnapshot, in: runtime.presentation)
        XCTAssertEqual(runtime.sessionChipStatement, .readingCatalogue)
    }

    // MARK: - The exposure signal: the session's on the surface it owns, the legacy store's everywhere

    /// The reader scrolling a `v2Full` screen past a card is the one exposure signal this build has, and
    /// on the surface the session owns it is the session's: one observation reaches the boundary and
    /// nothing is written to the legacy read state under an id that names no row.
    ///
    /// The runtime's own diagnostic is where the intent becomes observable at the boundary
    /// (`visibility-samples` counts the `.cardVisibility` intents it received), and the legacy store's own
    /// read set is where it must not become observable at all: `FeedStore.markAsSeen` is the write the
    /// screen used to make, and it takes the id it is given verbatim.
    func testACardEnteringTheViewportOnTheSessionSurfaceReachesTheSessionAndNotTheLegacyStore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "exposure-v2full"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        XCTAssertEqual(runtime.decision.mode, .v2Full)

        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        runtime.attach(loader: loader)
        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        let card = MainFeedCardBridge.value(
            item: makeItem(id: "a"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        _ = runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [card])
        )
        XCTAssertEqual(runtime.presentation.pageSource, .sessionSnapshot)
        // The id the screen passes is the one the row it draws carries — the bridge's display id, not a
        // legacy item id.
        let drawn = try XCTUnwrap(runtime.presentation.sections.first?.rows.first)
        XCTAssertEqual(drawn.item.id, "card:\(card.id)")

        runtime.cardBecameVisible(itemID: drawn.item.id)

        XCTAssertTrue(
            runtime.diagnostics.contains("visibility-samples=1"),
            "the session's surface reports the row to the session: \(runtime.diagnostics)"
        )
        XCTAssertTrue(
            store.consumedItemIDs.isEmpty,
            "a runtime row's display id names no feed_item row and never reaches the legacy read state"
        )
    }

    /// The write is unchanged in every mode whose runtime owns no acquisition — including the one with a
    /// `FeedScreenStore` in the path, where a store is not a session that owns a surface: the entry point
    /// is the legacy call there, with the same id the screen passed before it existed.
    func testEveryModeThatOwnsNoAcquisitionKeepsTheLegacyReadStateWrite() {
        for (name, request) in [
            ("exposure-legacy", nil),
            ("exposure-v2presentation", RequestedFeatures(shadow: false, v2UI: true, v2Network: false)),
        ] as [(String, RequestedFeatures?)] {
            let defaults = makeDefaults(name: name)
            if let request { RuntimeModeLaunch.request(request, in: defaults) }
            let runtime = MainFeedRuntime.launch(defaults: defaults, arguments: [])
            defer { runtime.stop() }
            XCTAssertFalse(runtime.ownsAcquisition, name)

            let store = FeedStore.empty()
            let loader = FeedLoader(store: store)
            runtime.attach(loader: loader)
            XCTAssertEqual(runtime.presentation.pageSource, .legacyPage, name)

            runtime.cardBecameVisible(itemID: "legacy-item")

            XCTAssertEqual(store.consumedItemIDs, ["legacy-item"], name)
            XCTAssertTrue(
                runtime.diagnostics.contains("visibility-samples=0"),
                "\(name): no exposure observation is sent outside the session's surface"
            )
        }
    }

    /// The session owns one selection. On any other selection the page is that selection's legacy page,
    /// and a row's visibility there is the legacy read-state write: the session is not told about a card
    /// while a page it does not own is on screen. Coming back, the same entry point reports to the session
    /// again — with a display id that still reaches no legacy write.
    func testNoExposureObservationIsSentForAPageTheSessionDoesNotOwn() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Same reason as `dod2-selection`: this test reaches another selection by switching the preset, which
        // is a no-op when the persisted value is already the target. This is the test the read-state slice
        // measured failing when its own new test ran before it.
        let previousPreset = Settings.activePreset
        Settings.activePreset = .everything
        defer { Settings.activePreset = previousPreset }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "exposure-other-selection"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        runtime.attach(loader: loader)
        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        let card = MainFeedCardBridge.value(
            item: makeItem(id: "a"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        _ = runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [card])
        )
        XCTAssertEqual(runtime.presentation.pageSource, .sessionSnapshot)

        // Another selection, and that selection's own content: the id below is its row's, not a display id.
        loader.setActivePreset(.lastClicked)
        await waitForPageSource(.legacyPage, in: runtime.presentation)
        store.loadBookmarkFeed(items: [makeItem(id: "other-surface-item")])
        await waitForDrawnItem("other-surface-item", in: runtime.presentation)

        runtime.cardBecameVisible(itemID: "other-surface-item")

        XCTAssertEqual(store.consumedItemIDs, ["other-surface-item"])
        XCTAssertTrue(
            runtime.diagnostics.contains("visibility-samples=0"),
            "the session is not told where the reader is on a page it does not own: \(runtime.diagnostics)"
        )

        // Back on the selection the session owns, its snapshot is the page again and the report is the
        // session's.
        loader.setActivePreset(.everything)
        await waitForPageSource(.sessionSnapshot, in: runtime.presentation)
        runtime.cardBecameVisible(itemID: "card:\(card.id)")

        XCTAssertTrue(runtime.diagnostics.contains("visibility-samples=1"), runtime.diagnostics)
        XCTAssertEqual(
            store.consumedItemIDs,
            ["other-surface-item"],
            "the display id did not reach the legacy read state on the way back either"
        )
    }

    // MARK: - The open: the session's durable read on its surface, the legacy write everywhere else

    /// The reader opening a card is the session's durable read on the surface the session owns, and the
    /// id that row carries never reaches the legacy read state.
    ///
    /// `read-intents` is where the runtime states that the open left the boundary for the session's read
    /// path (the same instrument `visibility-samples` is for the visibility signal), and the legacy
    /// store's own read set is where the write the screen used to make must not appear at all:
    /// `FeedStore.markAsClicked` takes the id it is given verbatim, and the id a runtime row carries is
    /// the display id the bridge synthesizes (`card:<card id>`), which names no `feed_item` row.
    func testACardOpenedOnTheSessionSurfaceReachesTheSessionReadPathAndNotTheLegacyStore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "open-v2full"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        XCTAssertEqual(runtime.decision.mode, .v2Full)

        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        runtime.attach(loader: loader)
        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        let card = MainFeedCardBridge.value(
            item: makeItem(id: "a"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        _ = runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [card])
        )
        XCTAssertEqual(runtime.presentation.pageSource, .sessionSnapshot)
        let drawn = try XCTUnwrap(runtime.presentation.sections.first?.rows.first)
        XCTAssertEqual(drawn.item.id, "card:\(card.id)")

        runtime.opened(itemID: drawn.item.id)

        XCTAssertTrue(
            runtime.diagnostics.contains("read-intents=1"),
            "the session's surface routes the open to the session's read path: \(runtime.diagnostics)"
        )
        XCTAssertTrue(
            store.readItemIDs.isEmpty,
            "a runtime row's display id names no feed_item row and never reaches the legacy read state"
        )
        XCTAssertTrue(store.consumedItemIDs.isEmpty)
        XCTAssertTrue(store.clickedItemIDs.isEmpty)
    }

    /// The write is unchanged on every page the session does not own — another selection's legacy page in
    /// the acquiring mode included. There the open is the legacy store's own call with the id that page's
    /// row carries, exactly as it was before the read path existed.
    ///
    /// The foreign page is the page `MainFeedPresentation.followLegacyPage` publishes for a selection the
    /// session's plan was not built for — the same call with the same value, stated directly instead of
    /// through a preset change, which is the idiom the legacy-page tests in this file already use and
    /// which leaves the process-global active preset alone.
    func testEveryPageTheSessionDoesNotOwnKeepsTheLegacyOpenWrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = MainFeedRuntime.launch(
            applicationSupportDirectory: directory,
            defaults: makeDefaults(name: "open-other-surface"),
            arguments: [RuntimeModeLaunch.v2UIArgument, RuntimeModeLaunch.v2NetworkArgument]
        )
        defer { runtime.stop() }
        let store = FeedStore.empty()
        let loader = FeedLoader(store: store)
        runtime.attach(loader: loader)
        let sessionKey = try XCTUnwrap(runtime.presentation.sessionContextKey)
        let card = MainFeedCardBridge.value(
            item: makeItem(id: "a"),
            ordinal: 0,
            presentation: nil,
            band: .card
        ).card
        _ = runtime.presentation.applySnapshot(
            makeSnapshot(contextKey: sessionKey, sequence: 1, cards: [card])
        )
        XCTAssertEqual(runtime.presentation.pageSource, .sessionSnapshot)

        // That selection's own content: the id below is its row's, not a display id.
        runtime.presentation.publish(makePage(items: [makeItem(id: "other-surface-item")]))
        XCTAssertEqual(runtime.presentation.pageSource, .legacyPage)

        runtime.opened(itemID: "other-surface-item")

        XCTAssertEqual(store.readItemIDs, ["other-surface-item"])
        XCTAssertEqual(store.clickedItemIDs, ["other-surface-item"])
        XCTAssertTrue(
            runtime.diagnostics.contains("read-intents=0"),
            "an open on a page the session does not own is the legacy store's own write: \(runtime.diagnostics)"
        )
    }

    /// A launch whose runtime owns no acquisition keeps the entry point's own legacy call, with the id
    /// the screen passed: there is no session to confirm a read against, so the legacy store stays the
    /// only owner of read state.
    func testEveryModeThatOwnsNoAcquisitionKeepsTheLegacyOpenWrite() {
        for (name, request) in [
            ("open-legacy", nil),
            ("open-v2presentation", RequestedFeatures(shadow: false, v2UI: true, v2Network: false)),
        ] as [(String, RequestedFeatures?)] {
            let defaults = makeDefaults(name: name)
            if let request { RuntimeModeLaunch.request(request, in: defaults) }
            let runtime = MainFeedRuntime.launch(defaults: defaults, arguments: [])
            defer { runtime.stop() }
            XCTAssertFalse(runtime.ownsAcquisition, name)

            let store = FeedStore.empty()
            let loader = FeedLoader(store: store)
            runtime.attach(loader: loader)
            XCTAssertEqual(runtime.presentation.pageSource, .legacyPage, name)

            runtime.opened(itemID: "legacy-item")

            XCTAssertEqual(store.readItemIDs, ["legacy-item"], name)
            XCTAssertEqual(store.clickedItemIDs, ["legacy-item"], name)
            XCTAssertTrue(
                runtime.diagnostics.contains("read-intents=0"),
                "\(name): no open is routed to a session's read path"
            )
        }
    }

    // MARK: - Offline: the presentation carries no URL and cannot fetch

    func testPublishedCardsCarryNoURLAndNoLoadingMedia() {
        let items = [
            makeItem(id: "a", url: "https://example.com/a"),
            makeItem(id: "y", url: "https://www.youtube.com/watch?v=x1"),
            makeItem(id: "p", url: "https://example.com/p", audioURL: "https://example.com/p.mp3"),
        ]
        let presentation = makePresentation()
        let snapshot = presentation.publish(makePage(items: items))

        for card in snapshot.cards {
            XCTAssertFalse(card.title.contains("http"), "a card title is text, never a URL")
            switch card.media {
            case .local(let digest):
                XCTAssertFalse(digest.contains("://"), "a local asset is identified by a digest")
            case .placeholder(let reason):
                XCTAssertFalse(reason.contains("://"), "a placeholder reason is a kind, not a URL")
            case .none:
                break
            }
        }
    }

    func testUnresolvedImageNeverBecomesAFetch() {
        // The render path is fed by values only: `CardMediaSlot` has no URL case, so an image the
        // pipeline has not resolved becomes a reserved frame or no slot — never a download. This is
        // the structural half of the offline proof; the process-level half blocks every URLSession
        // request and is recorded in the report.
        let item = makeItem(id: "a", url: "https://example.com/a", imageURL: "https://example.com/a.jpg")
        let presentation = FeedCardPresentation(
            item: item,
            media: .placeholder,
            layout: .hero,
            isRead: false,
            isBookmarked: false
        )
        let cardBand = MainFeedCardBridge.value(item: item, ordinal: 0, presentation: presentation, band: .card)
        XCTAssertEqual(cardBand.mediaSlot, .none,
                       "the card band reserves a hero only for local bytes or an episode")
        XCTAssertEqual(cardBand.card.layout, .textOnly)

        let listBand = MainFeedCardBridge.value(item: item, ordinal: 0, presentation: presentation, band: .list)
        XCTAssertEqual(listBand.mediaSlot, .empty,
                       "the row band keeps the frame and draws no stand-in asset")
        XCTAssertNil(listBand.mediaSlot.localImage)
        XCTAssertEqual(listBand.card.media, .none)
    }

    // MARK: - Helpers

    private func makeDefaults(name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "com.feedmine.tests.\(name)")!
        defaults.removePersistentDomain(forName: "com.feedmine.tests.\(name)")
        return defaults
    }

    private func makePresentation(
        recording recorder: IntentRecorder = IntentRecorder()
    ) -> MainFeedPresentation {
        let store = FeedScreenStore { intent in recorder.record(intent) }
        return MainFeedPresentation(
            store: store,
            sessionStamp: SessionStamp(42),
            contexts: SurfaceContextAdapters(editionSeed: 1_000)
        )
    }

    private func makeRuntime(
        router: MainFeedIntentRouter = MainFeedIntentRouter(),
        presentation: MainFeedPresentation,
        probe: ReplenishmentProbe = ReplenishmentProbe()
    ) -> MainFeedRuntime {
        MainFeedRuntime.testing(router: router, presentation: presentation) { lastOrdinal, ordinalCount in
            await probe.replenish(
                viewportLastVisibleOrdinal: lastOrdinal,
                publishedOrdinalCount: ordinalCount
            )
        }
    }

    private func makePage(items: [FeedItem]) -> MainFeedPage {
        let section = FeedLoader.DateSection(
            id: "ordered-results",
            title: "",
            items: items,
            showsHeader: false
        )
        return MainFeedPage(
            sections: [section],
            cards: [],
            band: .card,
            contextKey: "main-feed|preset=everything|box=-"
        )
    }

    private func makeItem(
        id: String,
        url: String = "https://example.com/a",
        imageURL: String? = nil,
        audioURL: String? = nil,
        duration: TimeInterval? = nil,
        excerpt: String = "Excerpt",
        sourceURL: String = "https://example.com/feed"
    ) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Test Source",
            sourceURL: sourceURL,
            category: "News",
            title: "Title \(id)",
            excerpt: excerpt,
            url: url,
            imageURL: imageURL,
            publishedAt: Date(),
            audioURL: audioURL,
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

    private func makeSnapshot(
        contextKey: String,
        sequence: UInt64,
        cards: [CardPresentation],
        stamp: SessionStamp = SessionStamp(4_242)
    ) -> FeedPresentationSnapshot {
        FeedPresentationSnapshot(
            sessionStamp: stamp,
            sequence: sequence,
            contextKey: contextKey,
            editionID: nil,
            editorialRevision: nil,
            renderEnvironment: .unspecified,
            cards: cards
        )
    }

    /// Waits for the presentation's page source to reach a value.
    ///
    /// The observation that follows a selection change fires on the write and rebuilds one main-actor
    /// turn later, so the assertion cannot be made on the same turn. The bound is generous and the loop
    /// leaves as soon as the value lands.
    private func waitForPageSource(
        _ expected: MainFeedPageSource,
        in presentation: MainFeedPresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if presentation.pageSource == expected { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(presentation.pageSource, expected, "the page did not follow the selection", file: file, line: line)
    }

    /// Waits until one item id is among the rows the page draws. Same reason as `waitForPageSource`: the
    /// observation that follows the legacy page rebuilds one main-actor turn later.
    private func waitForDrawnItem(
        _ itemID: String,
        in presentation: MainFeedPresentation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if presentation.sections.contains(where: { $0.rows.contains { $0.item.id == itemID } }) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the page never drew \(itemID)", file: file, line: line)
    }

    /// A legacy startup runway with one of three sources fetched, through the store's own two calls
    /// (`FeedStoreTests` uses the same pair): the counters the loading chrome read before the
    /// session-owned surface existed.
    private func makeLegacyRunway(on store: FeedStore) {
        store.configureStartupProgress(targetSourceCount: 3)
        store.recordStartupFetchProgress(
            FeedFetchResult(
                source: FeedSource(
                    title: "Legacy Source",
                    url: "https://example.com/legacy",
                    category: "News",
                    region: "global"
                ),
                items: [],
                outcome: .notModified
            )
        )
    }

    /// The legacy catalogue the chip's second branch counts: four enabled sources. Four rather than one so
    /// the denominator is larger than the runway's target below — the chip's own fold
    /// (`max(startupTotalSourceCount, sourceCount)`) has to answer `4`, not `3`, on that lane.
    private func makeLegacyCatalogue(on store: FeedStore) {
        store.registry.sources = (1...4).map { index in
            FeedSource(
                title: "Legacy \(index)",
                url: "https://example.com/\(index)",
                category: "News",
                region: "global"
            )
        }
    }

    /// The legacy page's own empty-surface inputs, made non-trivial: two sources with one toggled off, and
    /// the loading state whose branches the legacy wording is built from. These are the properties
    /// `FeedEmptyDisplay`'s legacy lane read off the loader before the surface the session owns existed.
    private func makeLegacyEmptyPage(on store: FeedStore) {
        store.registry.sources = [
            FeedSource(title: "Legacy One", url: "https://example.com/one", category: "News", region: "global"),
            FeedSource(title: "Legacy Two", url: "https://example.com/two", category: "News", region: "global"),
        ]
        store.registry.toggleSource("https://example.com/two")
        store.display.setLoadingState(.initial)
    }

    /// A runtime database directory of this test's own: `launch` composes the acquiring runtime into it.
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("main-feed-surface-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Records the intents a store forwards, so a test can assert what the screen asked for.
@MainActor
final class IntentRecorder {
    struct Viewport: Equatable {
        let firstVisibleOrdinal: Int
        let lastVisibleOrdinal: Int
        let anchor: FeedWindowAnchor?
    }

    private(set) var viewports: [Viewport] = []

    func record(_ intent: FeedSessionIntent) {
        if case .viewportChanged(let first, let last, let anchor) = intent {
            viewports.append(Viewport(firstVisibleOrdinal: first, lastVisibleOrdinal: last, anchor: anchor))
        }
    }
}

/// Stands in for the legacy replenishment the runtime schedules.
actor ReplenishmentProbe {
    private(set) var count = 0
    private(set) var lastOrdinal: Int?
    private(set) var lastCount: Int?

    func replenish(viewportLastVisibleOrdinal: Int, publishedOrdinalCount: Int) {
        count += 1
        lastOrdinal = viewportLastVisibleOrdinal
        lastCount = publishedOrdinalCount
    }

    func waitForObservations(_ expected: Int) async {
        for _ in 0..<200 where count < expected {
            await Task.yield()
        }
    }
}
