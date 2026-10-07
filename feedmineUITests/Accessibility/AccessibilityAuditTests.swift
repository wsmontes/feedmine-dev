import Foundation
import XCTest

/// Accessibility audit tests for FeedMine's main screens and states.
///
/// Uses XCUIApplication.performAccessibilityAudit (available in Xcode 15+) to automatically detect
/// accessibility issues on each screen.
///
/// `performAccessibilityAudit()` audits whatever is frontmost, so every test here navigates to the surface
/// it declares and asserts that surface by an identifier production actually sets before auditing it.
/// The version this replaces audited the wrong screen four times over: `Catalog` probed a tab bar this app
/// has never had (and audited the feed), `Settings` opened the more-menu and audited the menu, `Loading`
/// and `FreshInstall` audited onboarding, and `FilterSheet` audited the feed twice when no sheet appeared.
/// A surface that cannot be reached now fails — or skips with its precondition named — and never passes by
/// auditing something else. Every audit attaches a screenshot of the surface it audited.
@MainActor
final class AccessibilityAuditTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true  // Collect all issues, not just first
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

    // MARK: - Main feed / timeline

    /// Audit the main timeline screen after onboarding is complete.
    func testAccessibilityAudit_MainTimeline() throws {
        AppLauncher.launchAccessibility(app: app, locale: "en", showOnboarding: false)

        try audit(surface: "timeline", requiring: element(ScreenID.filterButton))
    }

    /// Audit the onboarding welcome screen.
    func testAccessibilityAudit_Onboarding() throws {
        AppLauncher.launchAccessibility(app: app, locale: "en", showOnboarding: true)

        try audit(surface: "onboarding", requiring: element(ScreenID.welcomeShape))
    }

    // MARK: - Catalog

    /// Audit the catalog browser.
    ///
    /// There is no tab bar and no `catalog` screen id: the catalog is `CatalogExploreView`, titled
    /// "Catalog" at its root (`CatalogBrowserViewModel.swift:95`, `CatalogExploreView.swift:23`), presented
    /// from the debug bar, which the compact header draws only under `showDebugBar` (FeedScreen.swift).
    /// That bar is reached, with no production change, by its own toggle: a triple tap on the feed status
    /// chip — the "secret gesture" the chip carries (`FeedScreen.swift`).
    func testAccessibilityAudit_Catalog() throws {
        AppLauncher.launchAccessibility(app: app, locale: "en", showOnboarding: false)
        XCTAssertTrue(
            element(ScreenID.filterButton).waitForExistence(timeout: UIWaits.extendedTimeout),
            "The feed must be ready before the catalog can be opened (feed chrome: filter-button, FeedScreen.swift)"
        )

        // Toggle the developer debug bar only if it is not already up — the flag persists in UserDefaults
        // across launches, so a previous run can have left it on — then take its catalog entry. Without the
        // entry the catalog screen cannot be presented at all, and auditing the feed instead is the defect
        // being fixed here.
        let exploreCatalog = app.buttons[ScreenID.catalogExploreLabel]
        if !exploreCatalog.exists {
            let statusChip = app.staticTexts[ScreenID.feedStatusChipLabel]
            XCTAssertTrue(
                statusChip.waitForExistence(timeout: UIWaits.defaultTimeout),
                "The feed status chip ('\(ScreenID.feedStatusChipLabel)') must be on screen to toggle the debug bar — it is the toggle's only handle — and the catalog entry is not already present"
            )
            statusChip.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        }
        XCTAssertTrue(
            exploreCatalog.waitForExistence(timeout: UIWaits.defaultTimeout),
            "The debug bar's '\(ScreenID.catalogExploreLabel)' entry (FeedScreen.swift, `showDebugBar` branch) must appear after the status chip's triple-tap toggle; the catalog has no other entry point, so without it this audit cannot be run against the catalog."
        )
        exploreCatalog.tap()

        try audit(surface: "catalog", requiring: app.navigationBars[ScreenID.catalogTitle])
    }

    // MARK: - Filter sheet

    /// Audit the content filter sheet.
    func testAccessibilityAudit_FilterSheet() throws {
        AppLauncher.launchAccessibility(app: app, locale: "en", showOnboarding: false)

        let filterButton = element(ScreenID.filterButton)
        XCTAssertTrue(
            filterButton.waitForExistence(timeout: UIWaits.extendedTimeout),
            "filter-button must be reachable before the filter sheet can be presented (FeedScreen.swift)"
        )
        filterButton.tap()

        // The sheet is proved by its own control, not by "a sheet/button/nav title appeared somewhere":
        // `filter-done` is the sheet's Done button (FilterSheetView.swift:242).
        try audit(surface: "filter-sheet", requiring: element(ScreenID.filterDone))
    }

    // MARK: - Settings

    /// Audit the settings sheet.
    func testAccessibilityAudit_Settings() throws {
        AppLauncher.launchAccessibility(app: app, locale: "en", showOnboarding: false)
        XCTAssertTrue(
            element(ScreenID.filterButton).waitForExistence(timeout: UIWaits.extendedTimeout),
            "The feed must be ready before settings can be opened (feed chrome: filter-button, FeedScreen.swift)"
        )

        let moreMenu = element(ScreenID.moreMenu)
        XCTAssertTrue(
            moreMenu.waitForExistence(timeout: UIWaits.defaultTimeout),
            "more-menu must exist on the feed screen (FeedScreen.swift, the compact header's `Menu`)"
        )
        moreMenu.tap()

        // The menu is only the way in: Settings itself is the sheet whose navigation bar is titled
        // "Settings" (SettingsSheetView.swift:272), entered by the menu's own "Settings" item
        // (FeedScreen.swift).
        let settingsEntry = app.buttons["Settings"]
        XCTAssertTrue(
            settingsEntry.waitForExistence(timeout: UIWaits.defaultTimeout),
            "The more-menu must offer its 'Settings' item (FeedScreen.swift) — auditing the open menu is not auditing Settings"
        )
        settingsEntry.tap()

        try audit(surface: "settings", requiring: app.navigationBars[ScreenID.settingsTitle])
    }

    // MARK: - RTL locale (Arabic)

    /// Verify app remains operable in right-to-left locale.
    func testAccessibilityAudit_ArabicLocale() throws {
        AppLauncher.launchAccessibility(app: app, locale: "ar", showOnboarding: false)

        // The locale is the variable here, so the surface is held constant: the feed, proved by the one
        // identifier every feed state carries, rather than by "some button exists".
        try audit(surface: "timeline-rtl", requiring: element(ScreenID.filterButton))
    }

    // MARK: - Loading state

    /// Audit the startup loading chrome.
    ///
    /// The surface is `initial-feed-loading` (`InitialFeedLoadingView`, FeedScreen.swift). It exists
    /// only while the feed is preparing, so this launch refuses every request at the process boundary
    /// (`-network-profile offline` installs `OfflineNetworkGuard`), leaving nothing that could bring the
    /// phase to an end while the audit runs.
    func testAccessibilityAudit_LoadingState() throws {
        AppLauncher.launchAccessibility(app: app, locale: "en", showOnboarding: false, networkProfile: "offline")

        let loading = element(ScreenID.initialLoading)
        guard loading.waitForExistence(timeout: UIWaits.defaultTimeout) else {
            throw XCTSkip("""
            initial-feed-loading is not on screen and cannot be induced from here: `XCUIApplication.launch()` returns only once \
            the app is idle, and with every request refused the run reaches the empty/offline surface before the harness can look. \
            The loader exposes no delay hook and no launch argument holds the preparing phase, so the loading chrome is not \
            reachable at audit time. Auditing whatever replaced it would report on a different screen.
            """)
        }

        try audit(surface: "loading", requiring: loading)
    }

    // MARK: - Empty state

    /// Audit the empty feed a fresh install opens on.
    ///
    /// The surface is `feed-empty-state` (`FeedEmptyStateView`, FeedEmptyStateView.swift:358) — what a feed
    /// with nothing to show draws, and what onboarding leaves behind on a first run.
    func testAccessibilityAudit_FreshInstall() throws {
        AppLauncher.launchAccessibility(app: app, locale: "en", showOnboarding: false, networkProfile: "offline")

        let empty = element(ScreenID.emptyState)
        guard empty.waitForExistence(timeout: UIWaits.extendedTimeout) else {
            throw XCTSkip("""
            feed-empty-state is not on screen and cannot be induced from here: the harness cannot empty the store. \
            `-fixture-profile empty` is parsed by TestConfiguration (TestConfiguration.swift:139) and consumed by nothing, so a \
            previous run's cached page survives the launch and the feed draws content. Auditing that page would report on the \
            timeline, not on a fresh install.
            """)
        }

        try audit(surface: "empty-state", requiring: empty)
    }

    // MARK: - Audit plumbing

    /// The one place an audit happens.
    ///
    /// The declared surface must be on screen — proved by an identifier production sets for it — before the
    /// audit runs; the surface's screenshot is attached under its own name. If the surface is not there the
    /// audit is **not** run: `continueAfterFailure` is on, so an `XCTAssert` alone would fall through into
    /// auditing the wrong screen, which is precisely the failure this file was rewritten to remove.
    private func audit(surface: String, requiring element: XCUIElement) throws {
        guard element.waitForExistence(timeout: UIWaits.extendedTimeout) else {
            XCTFail("Refusing to audit '\(surface)': its surface ('\(element.identifier)') is not on screen, so the audit would land on whatever replaced it.")
            return
        }

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "audit-\(surface)"
        attachment.lifetime = .keepAlways
        add(attachment)

        try app.performAccessibilityAudit()
    }

    /// Match on identifier across every descendant, in whichever element type the view produced it:
    /// `feed-empty-state` is a plain `VStack` and `initial-feed-loading` a combined `GeometryReader`, so
    /// guessing `otherElements`/`staticTexts` here would trade a wrong screen for a wrong query.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
