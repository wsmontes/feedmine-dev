import Foundation
import XCTest

/// Scroll behaviour of the feed timeline: content actually moves, content survives, chrome stays live.
///
/// WHAT IS MEASURED, AND WHY IT IS DEFENSIBLE
/// - `testScroll_FeedTimeline` attaches `XCTOSSignpostMetric.scrollDecelerationMetric` (the platform's
///   scroll-frame instrument; its hitch/duration statistics land in the `.xcresult`) and keeps the
///   measured block to the gesture alone, so the accessibility snapshot is not billed to it.
/// - Everything else here is an *invariant*, because the previous versions asserted only that
///   `app.exists` — a blank, frozen or fully-reset feed satisfied that. The invariants are: the
///   visible card identifier set changes when the user scrolls, no two visible cards share an
///   identifier, and the header control stays reachable.
/// - The wall-clock budget (15 s for a 2-swipe measured session) is a catastrophic-regression guard
///   for a DEBUG build on simulator/device, not a device baseline; device baselines live in the plan.
///
/// CONTRACT FACTS USED BY THE QUERIES: the feed is `ScrollView { LazyVStack { FeedItemView } }`
/// (`FeedScreen.swift:936-961`) — there is no collection view to wait for — and cards publish
/// `feed-item-<language>-<id>` (`FeedItemView.swift:82`).
///
/// `-fixture-profile` seeds nothing today (`TestConfiguration.swift:139` is its only reader), so
/// content is whatever the app persisted or fetched and the content precondition waits up to
/// `UIWaits.launchTimeout` (60 s); measured cold starts reach first content in 27–30 s
/// (`docs/runtime-v2/feed-pipeline-measurements-2026-10-06.md` §9, series B).
@MainActor
final class ScrollPerformanceTests: XCTestCase {

    let app = XCUIApplication()

    /// Catastrophic-only guard for one measured 2-swipe session.
    private static let measuredSessionBudget: TimeInterval = 15.0

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - PERF-UI: Scroll stability

    func testScroll_FeedTimeline() {
        app.launchArguments = AppLauncher.performanceArguments(fixtureProfile: "typical", fixtureSeed: 42001)
        app.launch()

        let before = FeedSurface.requireCards(app)
        let scroll = FeedSurface.requireScrollView(app)

        let options = XCTMeasureOptions()
        options.iterationCount = 2
        let started = Date()
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            scroll.swipeUp()
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, Self.measuredSessionBudget,
                          "2-swipe measured session took \(elapsed)s (> \(Self.measuredSessionBudget)s)")

        let after = FeedSurface.visibleCardIDs(app)
        XCTAssertFalse(after.isEmpty,
                       "feed rendered zero cards after scrolling. Observed: \(AppSurface.observed(app))")
        FeedSurface.assertUniqueIDs(after, "measured scroll")
        XCTAssertNotEqual(after, before,
                          "two page swipes left the visible card set/order unchanged — "
                          + "before=\(before) after=\(after)")
        XCTAssertTrue(AppSurface.element(app, ScreenID.moreMenu).exists,
                      "feed chrome is unreachable after scrolling")
    }

    // MARK: - PERF-UI-CON-001: Scroll during refresh

    func testScroll_DuringRefresh() {
        app.launchArguments = AppLauncher.performanceArguments(fixtureProfile: "typical", fixtureSeed: 42002)
        app.launch()

        let before = FeedSurface.requireCards(app)
        let scroll = FeedSurface.requireScrollView(app)

        // Scroll while refresh may be happening (the app refreshes on its own schedule).
        for _ in 0..<3 {
            scroll.swipeUp()
            Thread.sleep(forTimeInterval: 0.2)
        }

        let after = FeedSurface.visibleCardIDs(app)
        XCTAssertFalse(after.isEmpty,
                       "refresh+scroll emptied the feed. Observed: \(AppSurface.observed(app))")
        FeedSurface.assertUniqueIDs(after, "scroll during refresh")
        XCTAssertNotEqual(Set(after), Set(before),
                          "scroll during refresh did not change the visible card set — "
                          + "before=\(before) after=\(after)")
        XCTAssertTrue(AppSurface.element(app, ScreenID.moreMenu).exists,
                      "feed chrome is unreachable after scroll during refresh")
    }

    // MARK: - PERF-UI-CON-006: Background/foreground

    func testBackgroundForeground() {
        app.launchArguments = AppLauncher.performanceArguments(fixtureProfile: "typical", fixtureSeed: 42003)
        app.launch()

        let before = FeedSurface.requireCards(app)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.0)
        app.activate()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                      "app never returned to the foreground")

        // State preservation, not "some element exists": the anchor card must still be on screen.
        let after = FeedSurface.visibleCardIDs(app)
        XCTAssertTrue(after.contains(before[0]),
                      "feed lost its anchor card '\(before[0])' across background/resume — "
                      + "before=\(before) after=\(after)")
        XCTAssertTrue(AppSurface.element(app, ScreenID.moreMenu).exists,
                      "feed chrome is not reachable after resume")
    }
}
