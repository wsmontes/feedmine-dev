import Foundation
import XCTest

// MARK: - Screen element identifiers

/// Accessibility identifiers used across FeedMine UI tests.
///
/// These are the strings production actually carries, each with the view that owns it — the view name is
/// the anchor, not a line number, because these files move under the tests. A constant here that no view
/// sets is worse than no constant at all: the query for it matches nothing, and every guard written around
/// that emptiness passes — which is how `timeline.card.*`, `search.field` and `player.mini` (none of which
/// any view has ever set) turned into green tests over empty lists.
///
/// When a view's identifier changes, this file changes with it.
enum ScreenID {
    // MARK: Feed screen (`FeedScreen`)

    /// The feed's own marker — `filter-button` is drawn in every feed state.
    static let filterButton = "filter-button"
    /// The compact header's more menu.
    static let moreMenu = "more-menu"
    /// Search entry in the compact header.
    static let searchButton = "search-button"
    /// Bookmark boxes entry in the compact header.
    static let bookmarkBoxesButton = "bookmark-boxes-button"
    /// The unified search field once search is open.
    static let searchField = "unified-search-field"
    /// The unified search results surface.
    static let searchResults = "unified-search-results"

    // MARK: Feed cards

    /// Cards are `feed-item-<language>-<id>`: `FeedItemView` sets
    /// `"feed-item-\(item.language ?? "und")-\(item.id)"`. There is no `timeline.card.*` identifier.
    static let feedItemPrefix = "feed-item-"

    /// The exact identifier of one card, as `FeedItemView` builds it.
    static func feedItemID(language: String, itemID: String) -> String { "feed-item-\(language)-\(itemID)" }

    /// Matches every card on the page, whatever its language and id.
    static func feedItemPredicate() -> NSPredicate {
        NSPredicate(format: "identifier BEGINSWITH %@", feedItemPrefix)
    }

    /// A search result's source row (`FeedScreen`).
    static func searchSourceResult(_ sourceID: String) -> String { "source-result-\(sourceID)" }

    /// A source's own feed view (`CollectionManagementView`, `SourceFeedView`).
    static func sourceFeed(_ sourceID: String) -> String { "source-feed-\(sourceID)" }

    /// The bookmark button inside a card (`FeedItemCardView`).
    static let cardBookmark = "card.bookmark"

    /// A row of the bookmark boxes list (`BookmarkBoxesView`).
    static let bookmarkBoxRow = "bookmarkBox.row"

    // MARK: Feed states

    /// The startup loading chrome (`InitialFeedLoadingView`, drawn by `FeedScreen` while it prepares).
    static let initialLoading = "initial-feed-loading"

    /// The ready-but-empty surface (`FeedEmptyStateView`).
    static let emptyState = "feed-empty-state"

    /// The empty surface's title (`FeedEmptyStateView`).
    static let emptyStateTitle = "feed-empty-title"

    // MARK: Filter sheet (`FilterSheetView`)

    static let filterDone = "filter-done"
    static let filterClearAll = "filter-clear-all"
    static let filterPresetPicker = "preset-picker"

    // MARK: Onboarding (2-stage Welcome → Composer flow)

    static let welcomeShape = "welcome-shape"
    static let welcomeBroad = "welcome-broad"
    static let composerOpenFeed = "composer-open-feed"
    static let composerReset = "composer-reset"
    static let composerStartBroad = "composer-start-broad"

    // MARK: Story duel identifiers — preserved for P2 "Tune with examples"

    static let duelTopCard = "duel-top-card"
    static let duelFinish = "duel-finish"

    // MARK: Sheet titles (these sheets have no identifier of their own; the navigation bar carries the title)

    /// `SettingsSheetView`'s navigation title.
    static let settingsTitle = "Settings"

    /// The catalog browser's root level name (`CatalogBrowserViewModel.currentNodeName`), rendered as
    /// `CatalogExploreView`'s navigation title.
    static let catalogTitle = "Catalog"

    /// The debug bar's catalog entry, an accessibility *label* rather than an identifier (`FeedScreen`).
    /// The catalog browser has no other entry point.
    static let catalogExploreLabel = "Explore Catalog"

    /// The feed status chip's own text (`CompactFeedStatus`) — the element that carries the developer
    /// debug bar's triple-tap toggle.
    static let feedStatusChipLabel = "Feedmine"
}

// MARK: - UI Wait Helpers

enum UIWaits {
    /// Default timeout for UI element appearance.
    static let defaultTimeout: TimeInterval = 10.0

    /// Extended timeout for operations involving network or large data.
    static let extendedTimeout: TimeInterval = 30.0

    /// Launch/onboarding timeout — can be slow on first run.
    static let launchTimeout: TimeInterval = 60.0

    /// Wait for an element to exist, failing with a descriptive message.
    @discardableResult
    static func waitFor(
        _ element: XCUIElement,
        timeout: TimeInterval = defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let exists = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(
            exists,
            "Expected '\(element.identifier)' (\(element.elementType)) to exist within \(timeout)s",
            file: file, line: line
        )
        return element
    }

    /// Wait for an element to become hittable.
    @discardableResult
    static func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(
            result == .completed,
            "Expected '\(element.identifier)' to be hittable within \(timeout)s",
            file: file, line: line
        )
        return element
    }

    /// Wait for an element to disappear.
    static func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval = defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(
            result == .completed,
            "Expected '\(element.identifier)' to disappear within \(timeout)s",
            file: file, line: line
        )
    }
}

// MARK: - Failure Attachments

enum FailureAttachments {
    /// Attach diagnostic information when a UI test fails.
    static func attachDiagnostics(
        app: XCUIApplication,
        name: String = "failure-diagnostics"
    ) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = "\(name)-screenshot"
        XCTContext.runActivity(named: "Attach failure diagnostics") { activity in
            activity.add(attachment)
        }
    }
}
