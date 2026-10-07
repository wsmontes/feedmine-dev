import Foundation
import XCTest

/// Scroll performance of the feed timeline.
///
/// WHAT IS MEASURED, AND WHY IT IS DEFENSIBLE
/// - `XCTOSSignpostMetric.scrollDecelerationMetric` is the only per-frame metric the XCTest API
///   exposes for a scroll session: UIKit signposts a scroll view's deceleration and the metric turns
///   that into hitch/duration statistics in the `.xcresult`. It is attached with
///   `measure(metrics:options:)`; its numbers are the performance record — read them there, not here.
/// - The measured block contains **only the gesture**. Sampling the accessibility tree inside it
///   would bill the runner's snapshot cost to the measured session, so content assertions sit
///   immediately before and after the measurement.
/// - The in-test assertions are the ones the metric cannot make: content must exist before and after,
///   the visible card set must actually change, and no two visible cards may share an identifier.
/// - Budgets are catastrophic-regression guards for a DEBUG build on a simulator/device, **not** a
///   device baseline: `sessionBudget` is 20 s for a 3-swipe measured session, which a healthy build
///   finishes in a fraction of. Device baselines live in the release plan, not in this file.
///
/// PROXY NOTES (both deliberate)
/// - `XCTMemoryMetric` is not used anywhere in this suite: in a UI test it records the **test
///   runner's** footprint, so an app memory regression would pass. The app-side memory guard here is
///   the materialised-card accounting in `testScrollMemoryStability` — a `LazyVStack` window that
///   ever stops producing *new* card identifiers on a heavy fixture is the observable failure.
/// - `frame.minY` of the container is not asserted on: the feed stacks cards vertically, so the
///   container never moves and that number is uninformative. The signal is the identifier set/order.
///
/// CONTRACT FACTS USED BY THE QUERIES: the feed is `ScrollView { LazyVStack { FeedItemView } }`
/// (`FeedScreen.swift:936-961`) — never a collection view — and cards publish
/// `feed-item-<language>-<id>` (`FeedItemView.swift:82`).
///
/// `-fixture-profile`/`-fixture-seed` are still passed for the day fixtures are wired, but they seed
/// nothing today: `TestConfiguration.swift:139` parses the profile and no code reads it. Content is
/// therefore whatever the app has persisted or fetched, which is why the content precondition waits
/// up to `UIWaits.launchTimeout` (60 s) — measured cold starts on this tree reach first content in
/// 27–30 s (`docs/runtime-v2/feed-pipeline-measurements-2026-10-06.md` §9, series B).
@MainActor
final class HitchRatioTests: XCTestCase {

    let app = XCUIApplication()

    /// Catastrophic-only guard around one measured 3-swipe session, including launch and quiescence.
    private static let sessionBudget: TimeInterval = 20.0
    /// A bounded walk must see at least this many *distinct* cards, or the run proved nothing about
    /// scrolling. Five is the honest ceiling: a published page on this tree measured 6–13 items
    /// (`docs/runtime-v2/feed-pipeline-measurements-2026-10-06.md` §9, series B), so a walk across one
    /// page cannot require ten distinct cards without failing on a healthy app.
    private static let minimumDistinctCardsPerWalk = 5

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Hitch ratio during scroll with mixed content

    func testScrollHitchRatio_MixedContent() {
        app.terminate()
        AppLauncher.launchPerformance(app: app, fixtureProfile: "heavy", fixtureSeed: 42001)

        // Content first, measurement second. The old `guard timeline.exists else { return }` returned
        // green here because a `LazyVStack` feed publishes no collection view.
        let before = FeedSurface.requireCards(app)
        let scroll = FeedSurface.requireScrollView(app)

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        let started = Date()
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            scroll.swipeUp(velocity: .fast)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, Self.sessionBudget,
                          "3-swipe measured session took \(elapsed)s (> \(Self.sessionBudget)s) — "
                          + "catastrophic regression guard, not a device baseline")

        let after = FeedSurface.visibleCardIDs(app)
        XCTAssertFalse(after.isEmpty,
                       "feed rendered zero cards after the measured scroll. Observed: \(AppSurface.observed(app))")
        FeedSurface.assertUniqueIDs(after, "measured scroll")
        XCTAssertNotEqual(Set(after), Set(before),
                          "scrolling did not change the visible card set — before=\(before) after=\(after)")
        XCTAssertNotEqual(after.first, before.first,
                          "scrolling left the first visible card unchanged (\(after.first ?? "nil"))")
    }

    // MARK: - Scrolling with images

    func testScrollHitchRatio_WithImages() {
        app.terminate()
        AppLauncher.launchPerformance(app: app, fixtureProfile: "heavy", fixtureSeed: 42002)

        let before = FeedSurface.requireCards(app)
        let scroll = FeedSurface.requireScrollView(app)

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            scroll.swipeUp(velocity: .fast)
        }

        let after = FeedSurface.visibleCardIDs(app)
        XCTAssertFalse(after.isEmpty,
                       "feed rendered zero cards after the image-heavy measured scroll. "
                       + "Observed: \(AppSurface.observed(app))")
        FeedSurface.assertUniqueIDs(after, "image-heavy measured scroll")
        XCTAssertNotEqual(Set(after), Set(before),
                          "image-heavy scroll did not change the visible card set — before=\(before) after=\(after)")

        // Content breadth, sampled outside the measurement. The `heavy` profile seeds nothing today
        // (see the class doc), so whether this run decoded images is recorded by the signpost metric's
        // hitch statistics when the fetched content has them; what is asserted here is that the walk
        // materialised new cards at all, and `app.images.count` is deliberately not asserted because
        // placeholder-backed AsyncImage reads 0 and would make the assertion a coin flip.
        var seen = Set(before)
        for _ in 0..<5 {
            scroll.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.3)
            let ids = FeedSurface.visibleCardIDs(app)
            FeedSurface.assertUniqueIDs(ids, "image-heavy walk")
            seen.formUnion(ids)
        }
        XCTAssertGreaterThanOrEqual(seen.count, Self.minimumDistinctCardsPerWalk,
                                    "image-heavy walk materialised only \(seen.count) distinct cards "
                                    + "(< \(Self.minimumDistinctCardsPerWalk)) — the fixture proved nothing")
    }

    // MARK: - Scroll memory stability

    func testScrollMemoryStability() {
        app.terminate()
        AppLauncher.launchPerformance(app: app, fixtureProfile: "heavy", fixtureSeed: 42003)

        let firstWindow = FeedSurface.requireCards(app)
        let scroll = FeedSurface.requireScrollView(app)

        // Extended scroll: 20 swipes over ~40 seconds. `XCTMemoryMetric` is not usable here (it
        // measures the runner), so the app-side signal is that the LazyVStack keeps materialising
        // new cards instead of collapsing to an empty or frozen window.
        var seen = Set(firstWindow)
        for i in 0..<20 {
            if i % 2 == 0 {
                scroll.swipeUp(velocity: .fast)
            } else {
                scroll.swipeDown(velocity: .fast)
            }
            Thread.sleep(forTimeInterval: 0.3)

            let ids = FeedSurface.visibleCardIDs(app)
            FeedSurface.assertUniqueIDs(ids, "extended scroll pass \(i + 1)")
            seen.formUnion(ids)
        }

        XCTAssertGreaterThanOrEqual(seen.count, Self.minimumDistinctCardsPerWalk,
                                    "extended scroll materialised only \(seen.count) distinct cards "
                                    + "(< \(Self.minimumDistinctCardsPerWalk)) — the walk found no content breadth")
        XCTAssertFalse(FeedSurface.visibleCardIDs(app).isEmpty,
                       "feed window is empty after the extended scroll. Observed: \(AppSurface.observed(app))")
        XCTAssertTrue(AppSurface.element(app, ScreenID.moreMenu).exists,
                      "feed chrome is gone after the extended scroll — the app is not interactive")
    }
}

// MARK: - Shared surface probes (used by the Performance suites)
//
// These live here rather than in `Support/ScreenObjects.swift` because that file belongs to the
// UI-22/UI-23 slice, which was rewritten concurrently; they are `internal` to the UI test target, so
// every file in it can use them, and no `project.pbxproj` membership is needed. If the support file
// later becomes the single home for queries, move these two enums there unchanged.
//
// The feed screen publishes no collection view (`ScrollView { LazyVStack }`, `FeedScreen.swift:939`),
// so `app.collectionViews` is empty on the real feed and every "wait for the timeline" in the older
// suites timed out into a `guard … else { return }` pass. Cards are the only honest content signal.

/// Identifier-driven queries and hard preconditions.
@MainActor
enum AppSurface {

    /// First element carrying `identifier`, whatever its element type — SwiftUI containers do not map
    /// predictably onto the query class a test guesses from the view code.
    static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    /// One-line description of what is on screen, for assertion messages: a red has to say which
    /// surface the app was actually in.
    static func observed(_ app: XCUIApplication) -> String {
        let known = [
            ScreenID.initialLoading,
            ScreenID.emptyState,
            ScreenID.emptyStateTitle,
            ScreenID.filterButton,
            ScreenID.moreMenu,
        ]
        let present = known.filter { element(app, $0).exists }
        return "cards=\(FeedSurface.cards(app).count) "
            + "present=[\(present.joined(separator: ", "))] "
            + "buttons=\(app.buttons.count) staticTexts=\(app.staticTexts.count)"
    }

    /// Wait for `identifier` and fail — never return "not there" as a quiet false.
    @discardableResult
    static func require(
        _ app: XCUIApplication,
        _ identifier: String,
        timeout: TimeInterval = UIWaits.defaultTimeout,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let found = element(app, identifier)
        XCTAssertTrue(found.waitForExistence(timeout: timeout),
                      "\(what) never appeared ('\(identifier)'). Observed: \(observed(app))",
                      file: file, line: line)
        return found
    }
}

/// Feed-content queries built on the production card identifier (`feed-item-<language>-<id>`).
@MainActor
enum FeedSurface {

    /// Every feed card currently in the accessibility tree (predicate from `ScreenID`).
    static func cards(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(ScreenID.feedItemPredicate())
    }

    /// Card identifiers ordered top → bottom.
    ///
    /// The `frame.minY` sort is deliberate: the accessibility tree's order is not specified for a
    /// `LazyVStack`, and this array's order is what gives "the visible set changed" and "the order
    /// survived the refresh" their meaning. The array is asserted on — never `frame.minY` itself,
    /// which is the same for every card in a vertical stack and therefore cannot move.
    static func visibleCardIDs(_ app: XCUIApplication) -> [String] {
        cards(app)
            .allElementsBoundByIndex
            .filter { $0.exists }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.identifier)
    }

    /// Content precondition: fails — it never returns an empty success — so a run cannot be green on
    /// a screen that rendered nothing to scroll.
    ///
    /// The default 60 s is deliberate. `-fixture-profile` is parsed and read by *nothing*
    /// (`TestConfiguration.swift:139` is its only reader), so content is whatever the app last
    /// persisted or can fetch, and measured cold starts on this tree reach first content in 27–30 s
    /// (`docs/runtime-v2/feed-pipeline-measurements-2026-10-06.md` §9, series B) with TTFF measured up
    /// to 83 s on the previous tree. A shorter budget would turn "content exists" into a latency gate
    /// that fails on a healthy app.
    @discardableResult
    static func requireCards(
        _ app: XCUIApplication,
        timeout: TimeInterval = UIWaits.launchTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String] {
        let appeared = cards(app).element(boundBy: 0).waitForExistence(timeout: timeout)
        let ids = visibleCardIDs(app)
        XCTAssertTrue(appeared && !ids.isEmpty,
                      "Feed rendered zero '\(ScreenID.feedItemPrefix)*' cards within \(timeout)s. "
                      + "Observed: \(AppSurface.observed(app))",
                      file: file, line: line)
        return ids
    }

    /// Wait for a *defined* feed surface: real cards, or the empty state the app renders when it
    /// genuinely has nothing. Loading is deliberately not accepted — a run that never leaves the
    /// loading surface is a hang, not coverage.
    @discardableResult
    static func requireFeedSurface(
        _ app: XCUIApplication,
        timeout: TimeInterval = UIWaits.launchTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let found = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ OR identifier IN %@",
                        ScreenID.feedItemPrefix, [ScreenID.emptyState, ScreenID.emptyStateTitle])
        ).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: timeout),
                      "Feed never reached a defined surface (cards or empty state) within \(timeout)s. "
                      + "Observed: \(AppSurface.observed(app))",
                      file: file, line: line)
        return found
    }

    /// The feed's own scroll view (`FeedScreen.swift:939`). It carries no identifier, so the first
    /// scroll view on the feed screen is it — and its absence is a failure, not a fallback.
    @discardableResult
    static func requireScrollView(
        _ app: XCUIApplication,
        timeout: TimeInterval = UIWaits.defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: timeout),
                      "Feed scroll view never appeared. Observed: \(AppSurface.observed(app))",
                      file: file, line: line)
        return scroll
    }

    /// Two simultaneously visible cards sharing an identifier mean the identity the runtime promises
    /// is not unique — exactly the mis-tap/reorder class this suite exists for.
    static func assertUniqueIDs(
        _ ids: [String],
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(ids).count, ids.count,
                       "duplicate feed card identifiers visible together after \(context): \(ids)",
                       file: file, line: line)
    }

    /// The pull-to-refresh gesture the feed itself listens for, anchored on its scroll view.
    static func pullToRefresh(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scroll = requireScrollView(app, file: file, line: line)
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}
