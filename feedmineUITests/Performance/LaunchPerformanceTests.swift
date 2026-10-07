import Foundation
import XCTest

/// Launch performance for the three launch lanes the app actually has (clean, with fixture data,
/// offline) plus resume-from-background.
///
/// WHAT IS MEASURED, AND WHY IT IS DEFENSIBLE
/// - Every launch here is measured with `XCTApplicationLaunchMetric`, which is the platform's own
///   cold-launch instrument (it terminates the app between iterations itself). Its numbers are the
///   record to compare across runs — read them in the `.xcresult`, not here.
/// - `coldLaunchBudget` (10 s) is an in-test guard for *catastrophic* regression only, and the number
///   is deliberately loose because `Date()` around `app.launch()` also bills the XCUITest automation
///   handshake and a DEBUG build on a shared simulator. Treat a red as "launch is broken", not as
///   "launch is 20 % slower"; that comparison is what the metric's baseline is for.
/// - `testLaunch_ResumeFromBackground` has no launch to instrument (the app is already running), so it
///   uses `XCTClockMetric` around the foreground transition and asserts the feed's own content
///   survived — the previous version only asserted `runningForeground`, which a blank screen satisfies.
///
/// CONTRACT FACTS USED BY THE QUERIES: the feed is `ScrollView { LazyVStack { FeedItemView } }`
/// (`FeedScreen.swift:936-961`), never a collection view, and cards publish
/// `feed-item-<language>-<id>` (`FeedItemView.swift:82`). The chrome (`filter-button`,
/// `FeedScreen.swift:921`) is the only surface shared by every state, so a launch lane that cannot
/// have content asserts the chrome *and* a named terminal surface instead of "some element exists".
///
/// CONTENT IS NOT SEEDED BY `-fixture-profile`: `TestConfiguration.swift:139` parses it and nothing
/// reads it, so content is whatever the app last persisted or can fetch. `surfaceTimeout` is 60 s
/// because measured cold starts on this tree reach first content in 27–30 s
/// (`docs/runtime-v2/feed-pipeline-measurements-2026-10-06.md` §9, series B) with TTFF measured up to
/// 83 s on the previous tree — the wait is a content gate, not a launch-latency gate (that is what
/// `XCTApplicationLaunchMetric` is for).
@MainActor
final class LaunchPerformanceTests: XCTestCase {

    let app = XCUIApplication()

    /// Catastrophic-regression guard for a cold launch (DEBUG build, simulator/device, XCUITest).
    private static let coldLaunchBudget: TimeInterval = 10.0
    /// Bounded wait for the surface a lane is expected to reach (see the class doc for why 60 s).
    private static let surfaceTimeout: TimeInterval = UIWaits.launchTimeout

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Measurement helpers

    /// Cold-launch measurement: `XCTApplicationLaunchMetric` owns the timing, and it launches the app
    /// inside the block (it terminates it between iterations).
    private func measureColdLaunches(iterations: Int = 3) {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        app.terminate()
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
        }
    }

    /// One extra cold launch timed by the test itself, so a regression has an in-test failure and not
    /// only a number in the report.
    @discardableResult
    private func timedColdLaunch() -> TimeInterval {
        app.terminate()
        let started = Date()
        app.launch()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, Self.coldLaunchBudget,
                          "cold launch took \(elapsed)s (> \(Self.coldLaunchBudget)s budget) — "
                          + "catastrophic regression guard, not a device baseline")
        return elapsed
    }

    // MARK: - PERF-UI-LAUNCH-001: Clean launch

    func testLaunch_CleanInstall() {
        // No fixture: this lane is the clean-install lane, so zero cards is a legal outcome and is
        // therefore not asserted. What is asserted is the launch budget and the feed chrome.
        app.launchArguments = AppLauncher.performanceArguments(fixtureProfile: nil)
        measureColdLaunches()
        timedColdLaunch()

        AppSurface.require(app, ScreenID.filterButton, timeout: Self.surfaceTimeout,
                           "feed chrome after a clean launch")
    }

    // MARK: - PERF-UI-LAUNCH-003: Launch with data

    func testLaunch_WithFixtureData() {
        app.launchArguments = AppLauncher.performanceArguments(fixtureProfile: "typical", fixtureSeed: 42)
        measureColdLaunches()
        timedColdLaunch()

        // The old version stopped at "a filter button or a timeline exists". Nothing seeds content
        // (`-fixture-profile` is parsed and read by nothing — see the class doc), so the launch must
        // still end in real cards from whatever the app has cached or fetched, and failing here is
        // the point: a launch lane with no content is not a launch lane that passed.
        let cards = FeedSurface.requireCards(app, timeout: Self.surfaceTimeout)
        FeedSurface.assertUniqueIDs(cards, "fixture-data launch")
    }

    // MARK: - PERF-UI-LAUNCH-004: Offline launch

    func testLaunch_Offline() {
        // Offline with no fixture and no persisted data cannot produce cards; the contract this test
        // owns is "does not hang": the launch must end in a *defined* surface (cards from cache or the
        // empty state the app renders for a failed pipeline), not sit on the loading surface.
        app.launchArguments = AppLauncher.performanceArguments(fixtureProfile: nil, networkProfile: "offline")
        measureColdLaunches()
        timedColdLaunch()

        FeedSurface.requireFeedSurface(app, timeout: Self.surfaceTimeout)
    }

    // MARK: - PERF-UI-LAUNCH-006: Resume from background

    func testLaunch_ResumeFromBackground() {
        AppLauncher.launchPerformance(app: app, fixtureProfile: "typical", fixtureSeed: 42)
        let before = FeedSurface.requireCards(app, timeout: Self.surfaceTimeout)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 5)
        }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                      "app never returned to runningForeground after resume")

        // A foreground app that lost its feed is not a successful resume: the same anchor card must
        // still be on screen and the chrome must be interactive.
        let after = FeedSurface.visibleCardIDs(app)
        XCTAssertTrue(after.contains(before[0]),
                      "feed lost its anchor card '\(before[0])' across background/resume — "
                      + "before=\(before) after=\(after)")
        XCTAssertTrue(AppSurface.element(app, ScreenID.moreMenu).exists,
                      "feed chrome is not reachable after resume")
    }
}
