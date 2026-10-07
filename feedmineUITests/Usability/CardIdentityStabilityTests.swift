import Foundation
import UIKit
import XCTest

/// Card identity stability test — verifies that card identifiers remain stable across refresh,
/// insert-at-top, and navigation. Directly addresses the mis-tap/reorder user pain point from project memory.
///
/// Identity is `feed-item-<language>-<id>`: `FeedItemView.swift` sets
/// `"feed-item-\(item.language ?? "und")-\(item.id)"` as the card's accessibility identifier, and `feed-item-`
/// is the prefix the release suite already queries by (`PersonaExplorationUITests`, `identifier BEGINSWITH`).
/// No view has ever set `timeline.card.*`; the old
/// capture prefix matched nothing, and its `guard`-and-return guards turned that emptiness into a pass —
/// so every case here fails instead when the feed holds no card.
///
/// The feed is a `ScrollView` + `LazyVStack`, not a collection view (`FeedScreen.swift`, `feedScrollView`), and cards
/// are the only thing on it that identifies content. Content is whatever the store last persisted: the
/// `-fixture-profile` argument is parsed (`TestConfiguration.swift:139`) but read by nothing, so it seeds
/// no data — these tests assert over the page the app actually has, and fail when it has none.
@MainActor
final class CardIdentityStabilityTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        if testRun?.failureCount ?? 0 > 0 {
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            attachment.name = "failure-\(name)"
            add(attachment)
        }
    }

    // MARK: - Refresh

    /// Cards present after launch must survive a pull-to-refresh with their identities and their relative
    /// order intact. Losing cards, losing all of them, or reordering any of them fails.
    func testCardOrderStableAfterRefresh() {
        launchFeed(profile: "typical")

        let before = waitForSettledCards(context: "before refresh")
        pullToRefresh()
        let after = waitForSettledCards(context: "after refresh")

        assertIdentityPreserved(before: before, after: after, context: "after refresh")
    }

    // MARK: - Navigation

    /// Tapping a card opens the reader for that card's source, and coming back keeps the page it left.
    func testCardContextPreservedAfterNavigation() {
        launchFeed(profile: "typical")

        let before = waitForSettledCards(context: "before navigation")
        let card = cards().firstMatch
        guard card.exists else {
            XCTFail("A card must be on screen to navigate from; the feed holds none (expected identifiers beginning with '\(ScreenID.feedItemPrefix)').")
            return
        }
        let cardID = card.identifier
        let sourceTitle = sourceTitle(of: card)
        guard !sourceTitle.isEmpty else { return }  // sourceTitle(of:) already failed

        card.tap()

        // The reader names the article's source in its navigation bar (`ArticleReaderView.swift:12`), so a
        // tap that opened a different article — or opened nothing — is visible right here.
        let readerBar = app.navigationBars.firstMatch
        XCTAssertTrue(
            readerBar.waitForExistence(timeout: UIWaits.extendedTimeout),
            "Tapping card '\(cardID)' must present the reader (FeedScreen.swift presents `ArticleReaderView` from its `articleItem` sheet)"
        )
        let presentedTitle = readerBar.identifier.isEmpty ? readerBar.label : readerBar.identifier
        XCTAssertEqual(
            presentedTitle, sourceTitle,
            "Tapping card '\(cardID)' (label '\(card.label)') must open the reader for its own source; the reader is showing '\(presentedTitle)'"
        )

        // Leave the reader by its own control: the leading toolbar button is its dismiss button
        // (`ArticleReaderView.swift:18-26`), not "whatever button happens to be first on screen".
        let dismiss = readerBar.buttons.element(boundBy: 0)
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: UIWaits.defaultTimeout),
            "The reader must expose its dismiss control in its navigation bar"
        )
        dismiss.tap()

        XCTAssertTrue(
            app.buttons[ScreenID.filterButton].waitForExistence(timeout: UIWaits.extendedTimeout),
            "Dismissing the reader must return to the feed (feed chrome: filter-button, FeedScreen.swift)"
        )

        let after = waitForSettledCards(context: "after returning from the reader")
        assertIdentityPreserved(before: before, after: after, context: "after returning from the reader")
    }

    // MARK: - Scroll

    /// Scrolling to the bottom of the page and back must not lose the cards it started with.
    func testScrollDoesNotLoseCards() {
        launchFeed(profile: "heavy")

        let before = waitForSettledCards(context: "before scrolling")

        for _ in 0..<5 { app.swipeUp() }
        let deep = visibleCardIDs()
        XCTAssertFalse(
            deep.isEmpty,
            "The feed must still hold cards after scrolling down; before scrolling it held \(before)"
        )

        // One swipe more than went up: at five pages down the surplus swipe is a no-op at the top.
        for _ in 0..<6 { app.swipeDown() }
        let after = waitForSettledCards(context: "after scrolling back up")
        assertIdentityPreserved(before: before, after: after, context: "after scrolling down and back")
    }

    // MARK: - Helpers

    /// Launch the feed and require its readiness marker — the header alone is not content.
    private func launchFeed(profile: String) {
        app.terminate()
        AppLauncher.launch(app: app, fixtureProfile: profile, fixtureSeed: 42, showOnboarding: false, locale: "en")
        XCTAssertTrue(
            app.buttons[ScreenID.filterButton].waitForExistence(timeout: UIWaits.extendedTimeout),
            "The feed must be ready before card identity can be measured (feed chrome: filter-button, FeedScreen.swift)"
        )
    }

    /// All cards the current page holds, in the order they are drawn.
    private func cards() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(ScreenID.feedItemPredicate())
    }

    /// The identifiers of the visible cards, top-to-bottom. Order is read off the rendered frames rather
    /// than off the element-a list, so a card the layout moved is a card the list reports moved.
    private func visibleCardIDs() -> [String] {
        let elements = cards().allElementsBoundByIndex.filter { $0.exists }
        let ordered = elements
            .map { (frame: $0.frame, identifier: $0.identifier) }
            .sorted { lhs, rhs in
                if abs(lhs.frame.minY - rhs.frame.minY) > 0.5 { return lhs.frame.minY < rhs.frame.minY }
                return lhs.frame.minX < rhs.frame.minX
            }
            .map { $0.identifier }

        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    /// The page with content, awaited — and failed on, never substituted by "the app is still functional".
    /// A page does not exist until it holds at least one card; the header is drawn in every state, so
    /// returning from here with an empty list is exactly the false green this test replaces.
    private func waitForSettledCards(context: String) -> [String] {
        let ids = waitForSettledCardIDs(timeout: UIWaits.extendedTimeout)
        XCTAssertFalse(
            ids.isEmpty,
            "\(context): the feed holds no card (looked for identifiers beginning with '\(ScreenID.feedItemPrefix)'). An empty page is a failure of this test's precondition, not a reason to pass."
        )
        return ids
    }

    /// Poll until the page has stopped changing for `stableSamples` consecutive samples, then return the
    /// settled sample. Bounded and convergent — the same sampling shape `PersonaExplorationUITests` uses
    /// (a bounded `usleep` poll loop) rather than a fixed sleep charged to every run. The sample is taken
    /// over a window (default
    /// ~1.2 s of no change) rather than on the first pair that agrees, so a page that is still filling
    /// cannot be mistaken for a settled one.
    private func waitForSettledCardIDs(timeout: TimeInterval, stableSamples: Int = 8) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var last = visibleCardIDs()
        var stable = 0
        while Date() < deadline {
            usleep(150_000)
            let next = visibleCardIDs()
            if next == last {
                stable += 1
                if stable >= stableSamples { return next }
            } else {
                stable = 0
                last = next
            }
        }
        return last
    }

    /// Pull the page down from the body of the feed to trigger its `.refreshable` (`FeedScreen.swift`,
    /// `feedScrollView`). The drag starts below the compact header so it lands on the scroll view, not the
    /// header buttons.
    private func pullToRefresh() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.15, thenDragTo: end)
    }

    /// Every card seen before must still be on the page, in the same relative order. The page may grow at
    /// its ends and only at its ends: a refresh legitimately publishes newer articles above the ones
    /// already read ("insert at top"), and a feed may append more of the page below. A card missing, a
    /// survivor that moved relative to another survivor, or a new card landing *between* two survivors —
    /// the page growing in its middle — fails.
    private func assertIdentityPreserved(before: [String], after: [String], context: String) {
        let missing = before.filter { !after.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "\(context): card(s) \(missing) are gone. Before: \(before). After: \(after). Losing cards — or all of them — is the instability this test exists to catch."
        )

        let common = Set(before).intersection(after)
        let beforeCommon = before.filter { common.contains($0) }
        let afterCommon = after.filter { common.contains($0) }
        XCTAssertEqual(
            beforeCommon, afterCommon,
            "\(context): the surviving cards changed their relative order. Before: \(beforeCommon). After: \(afterCommon)."
        )

        let added = after.filter { !before.contains($0) }
        if !added.isEmpty,
           let firstSurvivor = after.firstIndex(where: { before.contains($0) }),
           let lastSurvivor = after.lastIndex(where: { before.contains($0) }) {
            for id in added {
                guard let index = after.firstIndex(of: id) else { continue }
                XCTAssertTrue(
                    index < firstSurvivor || index > lastSurvivor,
                    "\(context): the new card '\(id)' landed between two cards that were already on the page — the page grew in its middle. After: \(after)."
                )
            }
        }
    }

    /// The source name a card states. `FeedItemView.swift` builds the card's label as
    /// `"<title> from <sourceTitle>"`, and `ArticleReaderView.swift:12` titles the reader with that same
    /// `sourceTitle` — which is what makes "the right article opened" assertable from here.
    private func sourceTitle(of card: XCUIElement) -> String {
        let label = card.label
        guard let range = label.range(of: " from ", options: .backwards) else {
            XCTFail("Card '\(card.identifier)' must state its source in its label (FeedItemView.swift builds \"<title> from <sourceTitle>\"); it reads '\(label)'")
            return ""
        }
        return String(label[range.upperBound...])
    }
}
