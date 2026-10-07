import Foundation
import XCTest

/// Concurrent refresh + scroll — covers the P0 risk "a refresh reordering visible content abruptly,
/// losing the position or blocking the interface".
///
/// WHAT IS ASSERTED, AND WHY IT IS DEFENSIBLE
/// - Every test starts from `FeedSurface.requireCards`, so a run that rendered nothing fails instead
///   of passing on the header. The previous versions asserted `app.exists` / `filter-button.exists`,
///   which a wiped or frozen feed satisfies.
/// - The P0 contract is checked as an *order* invariant, not as a count: the cards that are visible
///   before the refresh and still visible after it must appear in the same relative order, and the
///   pre-refresh anchor card must not be pushed away. The old `count >= before/2` tolerance accepted
///   losing half the feed — and counted `otherElements`, which includes chrome.
/// - No new waits: the gestures and the 0.4 s / 3.0 s pauses are the ones this file already used.
///
/// CONTRACT FACTS USED BY THE QUERIES: the feed is `ScrollView { LazyVStack { FeedItemView } }`
/// (`FeedScreen.swift:936-961`), never a collection view, and cards publish
/// `feed-item-<language>-<id>` (`FeedItemView.swift:82`).
///
/// `-fixture-profile` seeds nothing today (`TestConfiguration.swift:139` is its only reader), so
/// content is whatever the app persisted or fetched and the content precondition waits up to
/// `UIWaits.launchTimeout` (60 s); measured cold starts reach first content in 27–30 s
/// (`docs/runtime-v2/feed-pipeline-measurements-2026-10-06.md` §9, series B).
@MainActor
final class ConcurrentRefreshTests: XCTestCase {

    let app = XCUIApplication()

    /// A 5-pass scroll+refresh session must still have materialised this many distinct cards.
    private static let minimumDistinctCardsPerSession = 3

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - P0: Refresh + scroll without reorder

    func testRefreshDuringScrollDoesNotCrash() {
        app.terminate()
        AppLauncher.launch(app: app, fixtureProfile: "heavy", fixtureSeed: 42, showOnboarding: false, locale: "en")

        let before = FeedSurface.requireCards(app)
        let scroll = FeedSurface.requireScrollView(app)

        // Scroll while pulling to refresh
        var seen = Set(before)
        for i in 0..<5 {
            if i % 2 == 0 {
                scroll.swipeUp(velocity: .fast)
            } else {
                // Pull-to-refresh gesture
                scroll.swipeDown(velocity: .slow)
            }
            Thread.sleep(forTimeInterval: 0.4)

            let ids = FeedSurface.visibleCardIDs(app)
            FeedSurface.assertUniqueIDs(ids, "scroll+refresh pass \(i + 1)")
            XCTAssertFalse(ids.isEmpty,
                           "feed emptied during scroll+refresh pass \(i + 1). "
                           + "Observed: \(AppSurface.observed(app))")
            seen.formUnion(ids)
        }

        XCTAssertGreaterThanOrEqual(seen.count, Self.minimumDistinctCardsPerSession,
                                    "scroll+refresh session materialised only \(seen.count) distinct cards "
                                    + "(< \(Self.minimumDistinctCardsPerSession))")
        XCTAssertTrue(AppSurface.element(app, ScreenID.filterButton).exists,
                      "feed header is gone after concurrent scroll+refresh — the feed is not interactive")
    }

    // MARK: - Card order preserved during refresh

    func testCardCountStableAfterQuickRefresh() {
        app.terminate()
        AppLauncher.launch(app: app, fixtureProfile: "typical", fixtureSeed: 42, showOnboarding: false, locale: "en")

        let before = FeedSurface.requireCards(app)
        FeedSurface.pullToRefresh(app)
        Thread.sleep(forTimeInterval: 3.0)

        let after = FeedSurface.requireCards(app)
        FeedSurface.assertUniqueIDs(after, "quick refresh")

        let beforeSet = Set(before)
        let afterSet = Set(after)
        let survivorsInBeforeOrder = before.filter { afterSet.contains($0) }
        let survivorsInAfterOrder = after.filter { beforeSet.contains($0) }

        XCTAssertFalse(survivorsInBeforeOrder.isEmpty,
                       "quick refresh wiped every previously visible card — before=\(before) after=\(after)")
        XCTAssertEqual(survivorsInAfterOrder, survivorsInBeforeOrder,
                       "quick refresh reordered the cards that stayed visible — "
                       + "before=\(before) after=\(after)")
        XCTAssertTrue(afterSet.contains(before[0]),
                      "quick refresh pushed the anchor card '\(before[0])' out of view — after=\(after)")
    }

    // MARK: - Quick navigation during refresh

    func testNavigationDuringRefresh() {
        app.terminate()
        AppLauncher.launch(app: app, fixtureProfile: "typical", fixtureSeed: 42, showOnboarding: false, locale: "en")

        let before = FeedSurface.requireCards(app)

        // Open the filter sheet while refresh may be happening — the sheet must actually present, or
        // the test is auditing/navigating something else (the old version continued silently).
        AppSurface.require(app, ScreenID.filterButton, timeout: UIWaits.extendedTimeout,
                           "filter button").tap()
        let done = AppSurface.require(app, ScreenID.filterDone, timeout: 15, "filter sheet")
        done.tap()

        // Back to the feed — same content anchor, same chrome.
        let after = FeedSurface.requireCards(app)
        XCTAssertTrue(after.contains(before[0]),
                      "feed lost its anchor card '\(before[0])' across filter navigation — after=\(after)")
        XCTAssertTrue(AppSurface.element(app, ScreenID.filterButton).exists,
                      "filter button is unreachable after returning from the filter sheet")
    }
}
