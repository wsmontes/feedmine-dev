import Foundation
import XCTest
import OSLog

/// UI tests that operate the app — tapping through filter combinations,
/// measuring responsiveness, and capturing structured logs.
@MainActor
final class FeedmineFilterUITests: XCTestCase {

    let app = XCUIApplication()
    private static let ui = Logger(
        subsystem: "com.feedmine.tests.ui",
        category: "FilterOps"
    )

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = ["-AppleLanguages", "(en)", "-UITestResetFilters", "-UITestSkipOnboarding"]
        app.launch()
    }

    // MARK: - Content Type Filter Tap Responsiveness

    func testContentTypeVideoSelectionCompletesUnder1Second() {
        let log = Self.ui
        log.info("=== testContentTypeVideoSelectionResponsiveness ===")

        waitForAppReady()

        // Open filter
        app.buttons["filter-button"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5),
                      "Filter sheet must open")

        log.info("  Filter sheet open. Testing content-type-videos button...")

        let videoBtn = app.buttons["content-type-videos"]
        guard videoBtn.waitForExistence(timeout: 3) else {
            log.error("  content-type-videos button not found")
            app.buttons["filter-done"].tap()
            return
        }

        // Measure tap responsiveness
        let start = CFAbsoluteTimeGetCurrent()
        videoBtn.tap()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        log.info("  [perf] Video filter tap: \(String(format: "%.2f", elapsed))ms")
        XCTAssertLessThan(elapsed, 1500, "Video filter tap must respond under 1.5s")

        // Verify selection state updated
        let selected = app.buttons["content-type-videos"].value as? String
        log.info("  Button state after tap: \(selected ?? "nil")")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    func testContentTypeAllSelectionsRespondQuickly() {
        let log = Self.ui
        log.info("=== testAllContentTypeSelections ===")

        waitForAppReady()
        app.buttons["filter-button"].tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 5))

        let types = ["content-type-all", "content-type-articles",
                     "content-type-videos", "content-type-podcasts",
                     "content-type-forums"]

        var timings: [(String, Double)] = []
        for typeID in types {
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(300_000) }
            guard btn.waitForExistence(timeout: 3) else {
                log.warning("  Button \(typeID) not found, skipping")
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            timings.append((typeID, ms))
            log.info("  [tap] \(typeID): \(String(format: "%.2f", ms))ms")
            usleep(100_000) // let UI settle
        }

        app.buttons["filter-done"].tap()

        // Report
        let avg = timings.map(\.1).reduce(0, +) / Double(max(timings.count, 1))
        let max = timings.map(\.1).max() ?? 0
        log.info("  Summary: avg=\(String(format: "%.2f", avg))ms max=\(String(format: "%.2f", max))ms")
        attachTimingReport(
            named: "content-type-tap-timings",
            rows: timings.map { "\($0.0),\(String(format: "%.2f", $0.1))" },
            summary: "average_ms=\(String(format: "%.2f", avg)),max_ms=\(String(format: "%.2f", max))"
        )

        XCTAssertLessThan(max, 1500, "Any content type tap must be under 1.5s")
        log.info("  ✅ PASS")
    }

    // MARK: - Filter Combination: Content Type + Language

    func testVideoFilterWithEnglishLanguage() {
        let log = Self.ui
        log.info("=== testVideoFilterWithEnglishLanguage ===")

        waitForAppReady()
        openFilter()

        // Select Videos without toggling it back to All when state persisted
        // from a previous test run.
        let videoButton = app.buttons["content-type-videos"]
        XCTAssertTrue(videoButton.waitForExistence(timeout: 3))
        if (videoButton.value as? String) != "selected" {
            videoButton.tap()
        }
        XCTAssertEqual(videoButton.value as? String, "selected")
        log.info("  Selected: Videos")

        // Select English language — scroll down to language section
        swipeToSection("Language", log: log)
        let enBtn = app.buttons["language-en"]
        if enBtn.waitForExistence(timeout: 3) {
            if (enBtn.value as? String) != "selected" {
                enBtn.tap()
            }
            XCTAssertEqual(enBtn.value as? String, "selected")
            log.info("  Selected: English language")
        } else {
            XCTFail("English language button not found in filter")
        }

        // Dismiss
        app.buttons["filter-done"].tap()

        // Assert the actual metadata on visible cards, not merely their
        // presence. This catches feeds that incorrectly declare English.
        let identifiers = waitForFeedItemIdentifiers(timeout: 10)
        XCTAssertFalse(identifiers.isEmpty, "Video + English should surface cards")
        XCTAssertTrue(
            identifiers.allSatisfy { $0.hasPrefix("feed-item-en-") },
            "English-only filter leaked non-English cards: \(identifiers)"
        )
        log.info("  Visible English cards after video+en filter: \(identifiers.count)")

        // Screenshot for diagnostics
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.lifetime = .keepAlways
        att.name = "video-en-filter"
        add(att)

        // Verify filter chips show
        let chipBar = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Videos'")
        ).firstMatch
        log.info("  Filter chip visible: \(chipBar.exists)")

        log.info("  ✅ PASS")
    }

    func testArticlesFilterWithPortugueseLanguage() {
        let log = Self.ui
        log.info("=== testArticlesFilterWithPortuguese ===")

        waitForAppReady()
        openFilter()

        // Select Articles
        tapFilterButton("content-type-articles", log: log)

        // Select Portuguese
        swipeToSection("Language", log: log)
        let ptBtn = app.buttons.element(matching: NSPredicate(format: "label CONTAINS 'Português'"))
        if ptBtn.exists {
            ptBtn.tap()
            log.info("  Selected: Português")
        } else {
            log.warning("  Portuguese not found — scrolling...")
            for _ in 0..<5 { app.swipeUp(); usleep(200_000) }
            let ptBtn2 = app.buttons.element(matching: NSPredicate(format: "label CONTAINS 'Português'"))
            if ptBtn2.exists { ptBtn2.tap(); log.info("  Found Portuguese after scroll") }
        }

        app.buttons["filter-done"].tap()
        sleep(5)

        let cells = app.cells.count
        log.info("  Visible cells: \(cells)")
        log.info("  ✅ PASS")
    }

    // MARK: - Filter Switching: Rapid Toggle

    func testRapidContentTypeTogglesDontBlockUI() {
        let log = Self.ui
        log.info("=== testRapidContentTypeToggles ===")

        waitForAppReady()
        openFilter()

        let types = ["content-type-videos", "content-type-podcasts", "content-type-articles", "content-type-videos"]
        var totalMs: Double = 0

        for typeID in types {
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(200_000) }
            guard btn.exists else { continue }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            totalMs += ms
            log.info("  [rapid] \(typeID): \(String(format: "%.2f", ms))ms")
        }

        let avgMs = totalMs / Double(types.count)
        log.info("  Average toggle time: \(String(format: "%.2f", avgMs))ms")
        XCTAssertLessThan(avgMs, 1000, "Average toggle under 1s")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Dismiss + Reopen (state preservation)

    func testFilterSelectionSurvivesDismissAndReopen() {
        let log = Self.ui
        log.info("=== testFilterStatePreservation ===")

        waitForAppReady()
        openFilter()

        // Select Videos
        tapFilterButton("content-type-videos", log: log)

        // Dismiss
        app.buttons["filter-done"].tap()
        sleep(3)
        log.info("  Dismissed filter sheet with Videos selected")

        // Reopen
        openFilter()

        // Verify Videos is still selected
        let videoBtn = app.buttons["content-type-videos"]
        guard videoBtn.waitForExistence(timeout: 3) else {
            log.warning("  Video button not found on reopen")
            app.buttons["filter-done"].tap()
            return
        }

        let value = videoBtn.value as? String
        log.info("  Video button state on reopen: \(value ?? "nil")")

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Mood Filter

    func testMoodFilterSelectionRespondsQuickly() {
        let log = Self.ui
        log.info("=== testMoodFilterSelection ===")

        waitForAppReady()
        openFilter()

        // Scroll to Mood section (bottom)
        for _ in 0..<10 { app.swipeUp(); usleep(150_000) }

        // Find mood buttons
        let moodLabels = ["👻 Fun", "📰 Serious", "⚙️ Technical", "✨ Inspiring"]
        var found = false
        for label in moodLabels {
            let btn = app.buttons.element(matching: NSPredicate(format: "label CONTAINS %@", label))
            if btn.exists {
                log.info("  Found mood: \(label)")
                let start = CFAbsoluteTimeGetCurrent()
                btn.tap()
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                log.info("  [tap] \(label): \(String(format: "%.2f", ms))ms")
                found = true
                break
            }
        }

        if !found { log.warning("  No mood filter buttons found") }

        app.buttons["filter-done"].tap()
        log.info("  ✅ PASS")
    }

    // MARK: - Clear All Filters

    func testClearAllFiltersRemovesAllSelections() {
        let log = Self.ui
        log.info("=== testClearAllFilters ===")

        waitForAppReady()
        openFilter()

        // Apply video + at least one mood
        tapFilterButton("content-type-videos", log: log)

        // Find and tap Clear All
        let clearBtn = app.buttons["Clear All Filters"]
        if clearBtn.exists {
            let start = CFAbsoluteTimeGetCurrent()
            clearBtn.tap()
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log.info("  Cleared all filters in \(String(format: "%.2f", ms))ms")

            // Should dismiss the sheet
            let sheetGone = !app.buttons["filter-done"].waitForExistence(timeout: 3)
            log.info("  Sheet dismissed: \(sheetGone)")
        } else {
            log.warning("  Clear All Filters button not visible")
            app.buttons["filter-done"].tap()
        }

        sleep(3)
        log.info("  ✅ PASS")
    }

    // MARK: - Full Combination Matrix (exhaustive)

    func testFilterCombinationsMatrix() {
        let log = Self.ui
        log.info("=== testFilterCombinationsMatrix ===")

        waitForAppReady()

        let typeIDs = ["content-type-all", "content-type-articles",
                       "content-type-videos", "content-type-podcasts"]

        var results: [(String, Double, Double, Bool)] = []

        for typeID in typeIDs {
            openFilter()
            let btn = app.buttons[typeID]
            if !btn.exists { app.swipeUp(); usleep(200_000) }
            guard btn.exists else {
                app.buttons["filter-done"].tap()
                continue
            }

            let start = CFAbsoluteTimeGetCurrent()
            btn.tap()
            app.buttons["filter-done"].tap()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log.info("  [combo] \(typeID) select+dismiss: \(String(format: "%.2f", elapsed))ms")

            let waitStart = CFAbsoluteTimeGetCurrent()
            let identifiers = waitForFeedItemIdentifiers(timeout: 8)
            let contentAppeared = !identifiers.isEmpty
            let contentWait = (CFAbsoluteTimeGetCurrent() - waitStart) * 1000
            results.append((typeID, elapsed, contentWait, contentAppeared))
            log.info("    content available: \(contentAppeared) after \(String(format: "%.2f", contentWait))ms")
            log.info("    → \(identifiers.count) visible cards")
            XCTAssertTrue(contentAppeared, "\(typeID) must show cards within 8 seconds")

            // Clear for next iteration
            openFilter()
            app.buttons["filter-done"].tap()
            sleep(1)
        }

        let avg = results.map(\.1).reduce(0, +) / Double(max(results.count, 1))
        log.info("  Avg select+dismiss: \(String(format: "%.2f", avg))ms")
        attachTimingReport(
            named: "filter-matrix-timings",
            rows: results.map {
                "\($0.0),select_and_dismiss_ms=\(String(format: "%.2f", $0.1)),content_wait_ms=\(String(format: "%.2f", $0.2)),content_appeared=\($0.3)"
            },
            summary: "average_select_and_dismiss_ms=\(String(format: "%.2f", avg))"
        )

        // Screenshot of final state
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.lifetime = .keepAlways
        att.name = "filter-matrix-done"
        add(att)

        log.info("  ✅ PASS")
    }

    // MARK: - Axis sweep: every value of every filter axis

    /// One value of one filter axis. `axis` names the filter dimension, `id` is what the sweep acts on —
    /// an accessibility id for the sheet's own controls, and the visible label for the `.menu` preset picker
    /// (see `FilterSheetView`: UIKit rebuilds menu options and drops their identifiers, so the option is
    /// reached by the label a reader would tap).
    private enum AxisCase {
        case sheetControl(axis: String, id: String)
        case presetMenu(label: String)
        case country(slug: String)
        case topic(query: String)

        var axis: String {
            switch self {
            case .sheetControl(let axis, _): return axis
            case .presetMenu: return "preset"
            case .country: return "countries"
            case .topic: return "topics"
            }
        }

        var id: String {
            switch self {
            case .sheetControl(_, let id): return id
            case .presetMenu(let label): return "preset:\(label)"
            case .country(let slug): return "country-toggle-\(slug)"
            case .topic(let query): return "topic:\(query)"
            }
        }
    }

    /// How many of the sheet's languages the sweep measures (see `buildAxisCases` for the cost measurement that
    /// forced a ceiling, and note that the sweep logs the skipped tail by id).
    private let languageAxisLimit = 16

    /// Sweeps every value of every axis the filter sheet offers, one value per measurement.
    ///
    /// For each value: clear the previous value, open the sheet, select, dismiss with `filter-done`, wait for a
    /// card, and record `select_and_dismiss_ms` + `content_wait_ms` in a CSV attachment. A value whose filter
    /// legitimately surfaces nothing within 8 s is recorded as a `FINDING` with its axis id — **not** asserted
    /// away — and the sweep continues to the next value.
    ///
    /// Caveat carried by the numbers: `content_wait_ms` is time-to-the-first-*hittable* card, and a card left
    /// over from the previous composition is hittable too, so a fast time is an upper bound on the filtered
    /// page, not proof of it. The app-side `[Viewport] pageSource=` line the matrix script captures from the
    /// device log is the stronger signal for the same moment; the two are meant to be read together.
    func testFilterAxisSweepCoversEveryValue() {
        let log = Self.ui
        log.info("=== testFilterAxisSweepCoversEveryValue ===")
        waitForAppReady()
        // The preset persists in UserDefaults and `-UITestResetFilters` does not clear it, so a run that inherited
        // one would measure every other axis through it.
        ensureDefaultPreset(log: log, context: "sweep-start")

        let cases = buildAxisCases(log: log)
        print("AXISSWEEP cases=\(cases.count) values=\(cases.map(\.id).joined(separator: " "))")

        var rows: [String] = []
        var findings: [String] = []
        var unreachable: [String] = []

        for axisCase in cases {
            resetToUnfilteredBaseline(log: log)
            openFilter()
            let started = CFAbsoluteTimeGetCurrent()
            let applied = applyAxisCase(axisCase, log: log)
            // `filter-done` is tapped only when it is there. On 2026-10-06 this blind tap aborted the whole sweep
            // with `Failed to tap "filter-done" Button: No matches found` right after the topics axis came back
            // unreachable (that path leaves the sheet closed), turning one unreachable axis into a failed test.
            if app.buttons["filter-done"].exists {
                app.buttons["filter-done"].tap()
            } else {
                print("AXISSWEEP sheet-gone axis=\(axisCase.axis) id=\(axisCase.id) — re-opening to restore the baseline")
                if app.buttons["filter-button"].exists {
                    openFilter()
                    if app.buttons["filter-done"].exists { app.buttons["filter-done"].tap() }
                }
            }
            let selectAndDismissMS = (CFAbsoluteTimeGetCurrent() - started) * 1000
            if !applied {
                unreachable.append("\(axisCase.axis):\(axisCase.id)")
                findings.append("FINDING axis=\(axisCase.axis) id=\(axisCase.id) reason=control-unreachable — the sheet was open and the control was never found")
                print("AXISSWEEP unreachable axis=\(axisCase.axis) id=\(axisCase.id)")
                rows.append("\(axisCase.axis),\(axisCase.id),\(formatMS(selectAndDismissMS)),,,0")
                continue
            }

            let waitStarted = CFAbsoluteTimeGetCurrent()
            let identifiers = waitForFeedItemIdentifiers(timeout: 8)
            let contentWaitMS = (CFAbsoluteTimeGetCurrent() - waitStarted) * 1000
            let appeared = !identifiers.isEmpty
            if !appeared {
                // The control is read back after the sheet is re-opened: "selected" makes an empty feed a content
                // finding (the filter really is applied), while "not selected" would mean the selection never
                // stuck — a different defect with a different owner.
                let state = controlValueAfterReopen(axisCase, log: log)
                findings.append("FINDING axis=\(axisCase.axis) id=\(axisCase.id) reason=no-cards-within-8s select_and_dismiss_ms=\(formatMS(selectAndDismissMS)) content_wait_ms=\(formatMS(contentWaitMS)) control_after_reopen=\(state)")
                print("FINDING axis=\(axisCase.axis) id=\(axisCase.id) reason=no-cards-within-8s content_wait_ms=\(formatMS(contentWaitMS)) control_after_reopen=\(state)")
                rows.append("\(axisCase.axis),\(axisCase.id),\(formatMS(selectAndDismissMS)),\(formatMS(contentWaitMS)),0,0,\(state)")
                continue
            }
            rows.append("\(axisCase.axis),\(axisCase.id),\(formatMS(selectAndDismissMS)),\(formatMS(contentWaitMS)),\(identifiers.count),\(appeared ? 1 : 0),selected")
            log.info("  [axis] \(axisCase.axis) \(axisCase.id): select_and_dismiss=\(self.formatMS(selectAndDismissMS))ms content_wait=\(self.formatMS(contentWaitMS))ms cards=\(identifiers.count) appeared=\(appeared)")
        }

        attachTimingReport(
            named: "filter-axis-sweep-timings",
            rows: rows,
            summary: "cases=\(cases.count),no_cards=\(findings.filter { $0.contains("no-cards") }.count),unreachable=\(unreachable.count)"
        )
        // The preset axis runs last and is the one axis whose value outlives the test (see `ensureDefaultPreset`),
        // so it is put back before this test ends: the classes that run after it must not inherit an editorial
        // preset, and an editorial preset also disables pagination (`activePreset.isLastClicked` returns early).
        ensureDefaultPreset(log: log, context: "sweep-end")
        print("AXISSWEEP done cases=\(cases.count) no_cards=\(findings.filter { $0.contains("no-cards") }.count) unreachable=\(unreachable.count)")
    }

    // MARK: - End of feed (reader report: the feed reaches the end and stops fetching)

    /// Reproduces the reader report — "the feed reaches the end and does not fetch new content after closing
    /// and reopening" — against a **warm** container the script leaves in place.
    ///
    /// It relaunches (proof of the persisted page first, so a cold start cannot wear a warm label), scrolls to
    /// the last card, counts the rendered `feed-item-*` elements, and then asks whether the feed grows inside a
    /// 20 s budget. Two growth signals are accepted and each is reported separately, because they answer
    /// different questions: the rendered count growing by itself (the app appended a page the reader is already
    /// looking at), or new identifiers appearing after the reader's own "keep going" swipe inside the same
    /// window (pagination still works, but only when it is asked for). No growth by either route is the failure.
    func testEndOfFeedFetchesNextPageAfterWarmRelaunch() {
        let log = Self.ui
        log.info("=== testEndOfFeedFetchesNextPageAfterWarmRelaunch ===")
        waitForAppReady()

        // The reader's report is about the default feed, and `activePreset.isLastClicked` disables the load-more
        // path outright (`FeedStore.loadMoreIfNeeded` returns early), so the preset is normalised and reported
        // before anything is measured.
        let presetObserved = ensureDefaultPreset(log: log, context: "end-of-feed")
        print("ENDOFFEED preset_observed=\"\(presetObserved)\"")

        let persisted = pageCacheEvidence()
        print("ENDOFFEED warm_precondition=\(persisted.usable ? "verified" : "unverified") \(persisted.evidence)")
        app.terminate()
        app.launch()
        waitForAppReady()

        // Scroll to the end: swipes stop counting only after three in a row materialise no new identifier.
        var seen: [String] = []
        var swipes = 0
        var idleSwipes = 0
        while swipes < 40, idleSwipes < 3 {
            swipes += 1
            let before = seen
            app.swipeUp()
            usleep(400_000)
            for id in renderedCardIdentifiers() where !seen.contains(id) { seen.append(id) }
            if seen == before { idleSwipes += 1 } else { idleSwipes = 0 }
        }
        let reachedEnd = idleSwipes >= 3

        let before = renderedCardIdentifiers()
        let countBefore = before.count
        let lastBefore = before.last ?? "none"
        print("ENDOFFEED reached_end=\(reachedEnd ? 1 : 0) swipes=\(swipes) distinct_seen=\(seen.count) rendered_before=\(countBefore) last_visible_before=\(lastBefore)")

        // The 20 s budget, counted before/after, with up to two of the reader's own swipes inside it: a page
        // appended below the viewport is not rendered by a lazy stack, so a count-only signal can miss growth
        // that actually happened. Each signal is printed separately below.
        let windowStart = Date()
        let deadline = windowStart.addingTimeInterval(20)
        var renderedAfter = countBefore
        var grewByCount = false
        var grewBySwipe = false
        var newIDs: [String] = []
        var jiggles = 0
        var nextJiggle = Date().addingTimeInterval(6)
        while Date() < deadline {
            let ids = renderedCardIdentifiers()
            renderedAfter = ids.count
            newIDs = ids.filter { !before.contains($0) }
            if renderedAfter > countBefore { grewByCount = true; break }
            if !newIDs.isEmpty { grewBySwipe = true; break }
            if jiggles < 2, Date() >= nextJiggle {
                jiggles += 1
                nextJiggle = Date().addingTimeInterval(6)
                app.swipeUp()
                usleep(400_000)
            }
            usleep(300_000)
        }
        let windowMS = Int(Date().timeIntervalSince(windowStart) * 1000)
        let lastAfter = renderedCardIdentifiers().last ?? "none"
        print("ENDOFFEED window_ms=\(windowMS) rendered_before=\(countBefore) rendered_after=\(renderedAfter) grew_by_count=\(grewByCount ? 1 : 0) grew_by_swipe=\(grewBySwipe ? 1 : 0) jiggles=\(jiggles) new_ids=\(newIDs.count) last_visible_after=\(lastAfter)")

        XCTAssertTrue(
            grewByCount || grewBySwipe,
            "the feed must grow after the last card: rendered \(countBefore) → \(renderedAfter) in \(windowMS) ms, "
            + "\(jiggles) further swipe(s) revealed \(newIDs.count) new id(s); last visible id before=\(lastBefore) after=\(lastAfter), "
            + "reached_end=\(reachedEnd) swipes_to_end=\(swipes)"
        )
    }

    // MARK: - Time to first card (cold and warm)

    /// Prints the two numbers the reader feels: milliseconds from `launch()` returning to the first
    /// `feed-item-*`, once on a container with no persisted page (cold) and once after `app.terminate()` on a
    /// container proven to hold one (warm).
    ///
    /// The cold half only means cold if the container really is empty, so the script runs this test on its own
    /// immediately after `simctl uninstall`, and the container is read here rather than trusted: setUp's launch
    /// is terminated before it can write a page, and the precondition is printed next to the number.
    func testTimeToFirstCardColdThenWarm() {
        let log = Self.ui
        log.info("=== testTimeToFirstCardColdThenWarm ===")
        app.terminate()

        let coldPrecondition = pageCacheEvidence()
        let coldLabel = coldPrecondition.usable
            ? "page-on-disk(number-is-not-a-cold-start)"
            : (coldPrecondition.containerFound ? "verified-no-page" : "unverified-container-unreadable")
        print("READY cold_precondition=\(coldLabel) \(coldPrecondition.evidence)")

        app.launchArguments = ["-AppleLanguages", "(en)", "-UITestResetFilters", "-UITestSkipOnboarding"]
        let coldStart = Date()
        app.launch()
        let coldReturned = Date()
        let coldLaunchMS = Int(coldReturned.timeIntervalSince(coldStart) * 1000)
        let cold = firstCardLatency(afterLaunchReturn: coldReturned, budget: 150)
        print("READY cold_ttff_ms=\(cold.cardMS) cold_launch_return_ms=\(coldLaunchMS) cold_card_at_return=\(cold.atReturn ? 1 : 0) cold_first_probe_ms=\(cold.firstProbeMS)")

        // Let the cold page reach disk (the write the reopen journey gates its warm verdict on), then prove it
        // is there before the next launch is allowed to be called warm.
        sleep(8)
        let warmPrecondition = pageCacheEvidence()
        print("READY warm_precondition=\(warmPrecondition.usable ? "verified" : "unverified") \(warmPrecondition.evidence)")

        app.terminate()
        let warmStart = Date()
        app.launch()
        let warmReturned = Date()
        let warmLaunchMS = Int(warmReturned.timeIntervalSince(warmStart) * 1000)
        let warm = firstCardLatency(afterLaunchReturn: warmReturned, budget: 60)
        print("READY warm_ttff_ms=\(warm.cardMS) warm_launch_return_ms=\(warmLaunchMS) warm_card_at_return=\(warm.atReturn ? 1 : 0) warm_first_probe_ms=\(warm.firstProbeMS)")

        XCTAssertGreaterThanOrEqual(cold.cardMS, 0, "cold start never produced a card inside its budget")
        XCTAssertGreaterThanOrEqual(warm.cardMS, 0, "warm start never produced a card inside its budget")
    }

    // MARK: - Helpers

    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("App failed to load — filter button not found")
            return
        }
        // Chrome is not content. A fixed sleep(5) let the first combo (`content-type-all`) run inside the
        // cold start — first page lands ~12 s after launch on a clean install — so that combo was
        // asserting cold-start readiness inside its own 8 s window, and no fetch-branch change could move
        // it. Wait for a card; on timeout, fail loudly rather than time a measurement against an empty app.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        guard card.waitForExistence(timeout: 40) else {
            XCTFail("Feed never produced a card — combos would measure an empty app")
            return
        }
    }

    // MARK: - Prepared repository (review P1.2)

    /// A context that was prepared before must switch **from the prepared repository**, not from a fresh reload.
    ///
    /// The page cache is keyed by the composition signature, so every context the reader visits writes its own prepared
    /// page. This drives the sequence the review names for the filter-change flow — context A, context B, then back into
    /// A — and asserts what the reader observes: each switch lands on cards rather than on a waiting surface.
    ///
    /// The app-side evidence that the return was served from disk (`page[restore] … reason=filter`) is read from the
    /// device log by the release probe, because a UI test cannot read the app's log: grep for `reason=filter` after this
    /// test to confirm the path, and for its absence to catch a regression that leaves the switch merely *fast*.
    ///
    /// Timings are logged with ISO-8601 stamps so the test-side sequence and the device log can be lined up.
    func testSwitchBackIntoAPreparedContextLandsOnCards() {
        let log = Self.ui
        log.info("=== P1.2 filter-switch A → B → A at \(ISO8601DateFormatter().string(from: Date())) ===")
        waitForAppReady()

        func select(_ id: String, _ label: String) {
            log.info("  [P12] select \(label) at \(ISO8601DateFormatter().string(from: Date()))")
            openFilter()
            var chip: XCUIElement?
            for _ in 0..<6 {
                if app.buttons[id].exists { chip = app.buttons[id]; break }
                app.swipeUp()
                usleep(400_000)
            }
            guard let chip else {
                XCTFail("\(label): chip \(id) missing from an open, scrolled sheet")
                return
            }
            chip.tap()
            app.buttons["filter-done"].tap()
            let card = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 30),
                          "\(label): the switch must land on cards, not on a waiting surface")
            log.info("  [P12] \(label) landed at \(ISO8601DateFormatter().string(from: Date()))")
        }

        select("content-type-videos", "A=videos")
        // A's composition settles so its prepared page is written (the write is detached, right after publish).
        sleep(6)
        select("content-type-podcasts", "B=podcasts")
        sleep(6)
        // The return: A's page sits in the prepared repository, so this switch must not wait for a recomposition.
        select("content-type-videos", "A=videos-return")
        log.info("  ✅ PASS")
    }

    private func openFilter() {
        app.buttons["filter-button"].tap()
        _ = app.buttons["filter-done"].waitForExistence(timeout: 5)
        sleep(1)
    }

    private func tapFilterButton(_ id: String, log: Logger) {
        let btn = app.buttons[id]
        if !btn.exists {
            for _ in 0..<4 { app.swipeUp(); usleep(200_000) }
        }
        guard btn.waitForExistence(timeout: 3) else {
            log.warning("  Button \(id) not found")
            return
        }
        btn.tap()
        usleep(100_000)
    }

    private func attachTimingReport(named name: String, rows: [String], summary: String) {
        let report = (["measurement,details"] + rows + [summary]).joined(separator: "\n")
        let attachment = XCTAttachment(
            data: Data(report.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Leaves one content type selected on an **idle** app for tens of seconds. That is the only configuration
    /// where coverage mining can produce a pass: every new flush cancels `coverageMiningTask` before its first
    /// pass (it sleeps ~600 ms first), and the combo matrix changes type every ~1.8 s, so a
    /// `coverage active-audio-p0:` line cannot appear there by construction — which is why the earlier zero is an
    /// artifact and not evidence about audio.
    func testPodcastFilterIdleReachesCoverageMining() {
        waitForAppReady()
        openFilter()
        // Assert the sheet is open before tapping a control inside it: the matrix taps this same id every run,
        // so "button not found" here would mean the sheet never opened and send the reader hunting a rename
        // that did not happen.
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 10),
                      "filter sheet did not open")
        // The sheet is long: its lower controls only exist after scrolling (the journey captures both
        // `05-filter-sheet` and `06-filter-sheet-scrolled`, and the matrix swipes before tapping).
        var foundPodcasts = false
        for _ in 0..<6 {
            if app.buttons["content-type-podcasts"].exists { foundPodcasts = true; break }
            app.swipeUp()
            usleep(400_000)
        }
        XCTAssertTrue(foundPodcasts, "podcasts control missing from an open, scrolled sheet")
        app.buttons["content-type-podcasts"].tap()
        app.buttons["filter-done"].tap()
        // Liveness: the idle window must actually elapse with the type selected, or the coverage labels read
        // afterwards are about some other phase.
        let idleUntil = Date().addingTimeInterval(45)
        while Date() < idleUntil {
            usleep(1_000_000)
        }
        XCTAssertTrue(true, "idle window elapsed")
    }

    private func waitForFeedItemIdentifiers(timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // `isHittable` removes two ways this assertion used to be satisfied without the requested
            // content: an identifier left over from the previous composition and one scrolled out of the
            // viewport. It does **not** check the type — the id is `feed-item-pt-<hash>`, fixed prefix plus
            // hash, with no kind in it, and a kept page of article cards is both on screen and hittable, so
            // it would still pass. Type checking needs what the app exposes on the card surface (or a
            // comparison against the ids the app logged for that combo); until then this helper is stronger
            // than "some id exists" and still weaker than "cards of the requested type".
            let cards = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .allElementsBoundByIndex
                .filter(\.isHittable)
            let identifiers = cards.map(\.identifier)
            // Honour the budget: the deadline was only tested between iterations, so a slow tree query
            // returned late and the caller reported "content available" at 10 241 ms against an 8 s cap.
            // Returning empty past the deadline makes the number and the verdict agree.
            if !identifiers.isEmpty, Date() < deadline { return identifiers }
            usleep(100_000)
        } while Date() < deadline
        return []
    }

    private func swipeToSection(_ name: String, log: Logger) {
        for _ in 0..<8 {
            let found = app.staticTexts.containing(
                NSPredicate(format: "label == %@", name)
            ).firstMatch.exists
            if found { log.info("  Found section: \(name)"); return }
            app.swipeUp()
            usleep(150_000)
        }
        log.warning("  Section '\(name)' not found after scrolling")
    }

    // MARK: - Axis sweep helpers

    private func formatMS(_ ms: Double) -> String { String(format: "%.2f", ms) }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func buildAxisCases(log: Logger) -> [AxisCase] {
        var cases: [AxisCase] = []
        // Content type: the four values that are not the "All" reset state, which the baseline already applies.
        for id in ["content-type-articles", "content-type-videos", "content-type-podcasts", "content-type-forums"] {
            cases.append(.sheetControl(axis: "content_type", id: id))
        }
        // Mood: every case except `.all`, again the reset the baseline applies.
        for id in ["mood-serious", "mood-fun", "mood-technical", "mood-inspiring"] {
            cases.append(.sheetControl(axis: "mood", id: id))
        }
        // Language: whatever the sheet actually offers — read off the sheet, not hardcoded, because the list is
        // data-driven (`loader.availableLanguages`) and changes with the enabled registry.
        //
        // Only the busiest `languageAxisLimit` are swept, and the rest are named in the log. The sheet lists
        // languages sorted by feed count, so this is the top of its own list: measured 2026-10-06, one language
        // case costs ~30-50 s (the control sits deep in a 62-row section, so reaching it is scrolling, and each
        // row's filter change reloads the feed), which puts all 62 at over an hour — a subset that is reported is
        // worth more than a sweep that never finishes.
        let allLanguages = languagesOfferedBySheet(log: log)
        for id in allLanguages.prefix(languageAxisLimit) {
            cases.append(.sheetControl(axis: "language", id: id))
        }
        if allLanguages.count > languageAxisLimit {
            print("AXISSWEEP language_skipped=\(allLanguages.count - languageAxisLimit) of \(allLanguages.count) (limit=\(languageAxisLimit)): \(allLanguages.dropFirst(languageAxisLimit).joined(separator: " "))")
        }
        for slug in countrySlugsForSweep(log: log) {
            cases.append(.country(slug: slug))
        }
        cases.append(.topic(query: "news"))
        // Preset last: it is the one axis whose value outlives the test (the launch argument that resets filters
        // does not clear it), and `activePreset.isLastClicked` disables pagination outright — so every other axis
        // is measured before it, and the sweep restores "Everything" when it ends.
        for label in ["Everything", "Last clicked", "High Quality", "Tech & Science", "Current Events", "Evergreen", "Global Mix"] {
            cases.append(.presetMenu(label: label))
        }
        return cases
    }

    /// Re-opens the sheet and reads the control's own value, so a FINDING can say whether the filter really was
    /// applied ("selected", which makes an empty feed a content finding) or never stuck ("not selected", which
    /// would be a defect in the sheet rather than in the data).
    private func controlValueAfterReopen(_ axisCase: AxisCase, log: Logger) -> String {
        guard case .sheetControl(_, let id) = axisCase else { return "n-a-for-\(axisCase.axis)" }
        openFilter()
        let control = element(id)
        var attempts = 0
        while !control.exists, attempts < 14 {
            app.swipeUp()
            usleep(250_000)
            attempts += 1
        }
        let value = (control.value as? String) ?? (control.exists ? "no-value" : "control-missing")
        app.buttons["filter-done"].tap()
        usleep(200_000)
        log.info("  [axis] \(axisCase.id) after reopen: \(value)")
        return value
    }

    private func applyAxisCase(_ axisCase: AxisCase, log: Logger) -> Bool {
        switch axisCase {
        case .sheetControl(_, let id):
            return tapSheetControl(id)
        case .presetMenu(let label):
            return selectPreset(label: label, log: log)
        case .country(let slug):
            return toggleCountry(slug: slug, log: log)
        case .topic(let query):
            return selectTopic(query: query, log: log)
        }
    }

    /// Back to an unfiltered feed before the next value is measured, through the sheet's own "Clear All
    /// Filters" so the reset travels the path a reader would take rather than a private shortcut.
    ///
    /// No card wait here on purpose: the value being measured waits for its own card afterwards, and a wait at
    /// the baseline only doubled every case's cost (measured 2026-10-06: ~80 s per case with it, on this tree).
    private func resetToUnfilteredBaseline(log: Logger) {
        openFilter()
        let clear = element("filter-clear-all")
        if clear.exists, clear.isEnabled {
            clear.tap()
        } else {
            app.buttons["filter-done"].tap()
        }
        usleep(500_000)
    }

    /// Taps one control inside the filter sheet, scrolling the sheet until it is on screen. Returns false when
    /// the control never becomes hittable — the sweep records that as an explicit FINDING rather than throwing
    /// a "not hittable" failure that would end the value's measurement with no row of its own.
    private func tapSheetControl(_ id: String) -> Bool {
        let control = element(id)
        var attempts = 0
        while attempts < 14 {
            if control.exists, control.isHittable {
                control.tap()
                usleep(150_000)
                return true
            }
            app.swipeUp()
            usleep(250_000)
            attempts += 1
        }
        return control.exists && control.isHittable
    }

    /// Opens the `.menu` preset picker and taps the option by its visible label: UIKit rebuilds menu options
    /// from the picker's content and drops the per-option identifiers, so the label is the only handle that
    /// reaches the presented `UIMenu` (see the comment on the picker in `FilterSheetView`).
    private func selectPreset(label: String, log: Logger) -> Bool {
        let picker = element("preset-picker")
        guard picker.waitForExistence(timeout: 5), picker.isHittable else { return false }
        picker.tap()
        // The menu animates in; the item lookup below waits for it rather than racing the animation.
        usleep(700_000)
        let item = app.buttons[label]
        if item.waitForExistence(timeout: 4), item.isHittable {
            item.tap()
            usleep(300_000)
            log.info("  [preset] selected \(label)")
            return true
        }
        let byLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        if byLabel.waitForExistence(timeout: 2), byLabel.isHittable {
            byLabel.tap()
            usleep(300_000)
            log.info("  [preset] selected \(label) by label")
            return true
        }
        // Leave no menu open behind the next measurement.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        usleep(300_000)
        return false
    }

    /// Enables one country through its row's switch on the Countries screen, then goes back to the sheet.
    private func toggleCountry(slug: String, log: Logger) -> Bool {
        let link = element("countries-link")
        guard link.waitForExistence(timeout: 5), link.isHittable else { return false }
        link.tap()
        let toggle = element("country-toggle-\(slug)")
        // Scroll while searching: the Countries list is 101 rows and a lazy `List` does not build the row the
        // test wants until it is near the screen. Waiting for existence *before* scrolling is what made this axis
        // unreachable on 2026-10-06 (`Checking existence of "country-toggle-brazil"` on repeat, then
        // `AXISSWEEP unreachable`), because the row was below the fold the whole time.
        var attempts = 0
        while attempts < 14, !(toggle.exists && toggle.isHittable) {
            app.swipeUp()
            usleep(250_000)
            attempts += 1
        }
        guard toggle.exists, toggle.isHittable else {
            dismissPushedScreen()
            return false
        }
        toggle.tap()
        usleep(400_000)
        log.info("  [country] toggled \(slug)")
        dismissPushedScreen()
        return true
    }

    /// Selects one taxonomy node: searches for it (search results are always leaf-style toggles) and taps the
    /// first result, then closes the Topics screen. The browse tree's own `topic-node-*` identifiers are
    /// logged on the way, so their presence is evidence and not an assumption.
    private func selectTopic(query: String, log: Logger) -> Bool {
        let link = element("browse-topics")
        // The sheet opens at its `.medium` detent and the Topics section sits below the fold, so the link is
        // searched for while scrolling rather than waited for (the shape that made this axis unreachable on
        // 2026-10-06: `Waiting 5.0s for "browse-topics" Any to exist`, then `AXISSWEEP unreachable`).
        var linkAttempts = 0
        while linkAttempts < 10, !(link.exists && link.isHittable) {
            app.swipeUp()
            usleep(250_000)
            linkAttempts += 1
        }
        guard link.exists, link.isHittable else { return false }
        link.tap()
        guard app.buttons["topics-done"].waitForExistence(timeout: 5) else {
            dismissPushedScreen()
            return false
        }
        let nodes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "topic-node-"))
            .allElementsBoundByIndex
        print("AXISSWEEP topic_node_ids_found=\(nodes.count) sample=\(nodes.prefix(3).map(\.identifier).joined(separator: " "))")

        let field = app.textFields["search-topics"]
        guard field.waitForExistence(timeout: 5), field.isHittable else {
            app.buttons["topics-done"].tap()
            return false
        }
        // The query is taken from the tree's own first node, so the search cannot miss because a hardcoded word
        // is absent from this registry; the caller's word is the fallback.
        let derived = nodes.first
            .map { $0.label.split(separator: " ").first.map(String.init) ?? "" } ?? ""
        let candidates = [derived, query].filter { !$0.isEmpty }
        for candidate in candidates {
            field.tap()
            field.typeText(candidate)
            // The field debounces 300 ms before it filters.
            usleep(900_000)
            let result = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "taxonomy-node-"))
                .firstMatch
            if result.waitForExistence(timeout: 4), result.isHittable {
                result.tap()
                usleep(300_000)
                log.info("  [topic] selected \(result.identifier) for query '\(candidate)'")
                app.buttons["topics-done"].tap()
                return true
            }
            // Clear the field before the next candidate. Backspace is the keystroke that always works here: the
            // clear control beside the field carries no identifier of its own.
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: candidate.count))
            usleep(400_000)
        }
        app.buttons["topics-done"].tap()
        return false
    }

    /// Pops a screen pushed inside the filter sheet's own `NavigationStack` (Countries / Topics).
    private func dismissPushedScreen() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable {
            back.tap()
        } else {
            app.swipeRight()
        }
        usleep(400_000)
    }

    /// Every `language-*` value the sheet offers, read by opening it and scrolling the list to the bottom.
    /// Data-driven on purpose: hardcoding the list would silently stop covering languages the registry adds.
    private func languagesOfferedBySheet(log: Logger) -> [String] {
        openFilter()
        var found: [String] = []
        var idlePasses = 0
        for _ in 0..<16 {
            let before = found.count
            let ids = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "language-"))
                .allElementsBoundByIndex
                .map(\.identifier)
            for id in ids where !found.contains(id) { found.append(id) }
            if found.count == before { idlePasses += 1 } else { idlePasses = 0 }
            if idlePasses >= 2, !found.isEmpty { break }
            app.swipeUp()
            usleep(250_000)
        }
        app.buttons["filter-done"].tap()
        print("AXISSWEEP language_values=\(found.count) \(found.joined(separator: " "))")
        log.info("  [axis] languages offered by the sheet: \(found.count)")
        return found
    }

    /// The two busiest countries the Countries screen lists — busiest because a country with no feeds would
    /// make the axis value indistinguishable from "filter produced nothing", which is a different question.
    private func countrySlugsForSweep(log: Logger) -> [String] {
        openFilter()
        let link = element("countries-link")
        guard link.waitForExistence(timeout: 5), link.isHittable else {
            app.buttons["filter-done"].tap()
            return []
        }
        link.tap()
        var rows: [(id: String, feeds: Int)] = []
        var idlePasses = 0
        for _ in 0..<12 {
            let before = rows.count
            let elements = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "country-"))
                .allElementsBoundByIndex
            for candidate in elements {
                let id = candidate.identifier
                guard id.hasPrefix("country-"), !id.hasPrefix("country-toggle-") else { continue }
                guard !rows.contains(where: { $0.id == id }) else { continue }
                rows.append((id, feedCountFromLabel(candidate.label)))
            }
            if rows.count == before { idlePasses += 1 } else { idlePasses = 0 }
            if idlePasses >= 2, !rows.isEmpty { break }
            app.swipeUp()
            usleep(250_000)
        }
        dismissPushedScreen()
        app.buttons["filter-done"].tap()
        let chosen = rows.sorted { $0.feeds > $1.feeds }.prefix(2)
            .map { $0.id.replacingOccurrences(of: "country-", with: "") }
        print("AXISSWEEP country_rows=\(rows.count) chosen=\(chosen.joined(separator: " "))")
        log.info("  [axis] countries listed: \(rows.count), sweeping \(chosen.joined(separator: ", "))")
        return chosen
    }

    /// The last run of digits in a row's label — the "<N> feeds" count the Countries rows render.
    private func feedCountFromLabel(_ label: String) -> Int {
        var digits = ""
        var last = ""
        for scalar in label.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                digits.append(Character(scalar))
            } else {
                if !digits.isEmpty { last = digits }
                digits = ""
            }
        }
        if !digits.isEmpty { last = digits }
        return Int(last) ?? -1
    }

    // MARK: - Feed probes

    /// The active preset lives in `UserDefaults` (`Keys.activePreset`) and `-UITestResetFilters` does not clear it,
    /// so a test that selects an editorial preset changes what every later test — and every later *run* on the same
    /// container — measures. This reads the picker's own label, puts the choice back to "Everything" when something
    /// else is active, and prints what it saw so a run that inherited a preset says so.
    @discardableResult
    private func ensureDefaultPreset(log: Logger, context: String) -> String {
        openFilter()
        let picker = element("preset-picker")
        let observed = picker.exists ? picker.label : "unknown"
        var restored = false
        if !observed.contains("Everything") {
            restored = selectPreset(label: "Everything", log: log)
        }
        app.buttons["filter-done"].tap()
        usleep(300_000)
        print("PRESET \(context) observed=\"\(observed)\" restored=\(restored ? 1 : 0)")
        log.info("  [preset] \(context): observed \"\(observed)\", restored=\(restored)")
        return observed
    }

    /// Every `feed-item-*` identifier the accessibility tree currently holds, in tree order.
    private func renderedCardIdentifiers() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .allElementsBoundByIndex
            .map(\.identifier)
    }

    private struct TTFF {
        /// Milliseconds from `launch()` returning to the first `feed-item-*`; -1 when the budget expired.
        var cardMS: Int
        var atReturn: Bool
        /// Cost of the first probe itself, part of `cardMS` when the card was already there.
        var firstProbeMS: Int
    }

    private func firstCardLatency(afterLaunchReturn returned: Date, budget: TimeInterval) -> TTFF {
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        let atReturn = card.exists
        let firstProbeMS = Int(Date().timeIntervalSince(returned) * 1000)
        var cardMS = atReturn ? firstProbeMS : -1
        let deadline = returned.addingTimeInterval(budget)
        while cardMS < 0, Date() < deadline {
            if card.exists {
                cardMS = Int(Date().timeIntervalSince(returned) * 1000)
                break
            }
            usleep(50_000)
        }
        return TTFF(cardMS: cardMS, atReturn: atReturn, firstProbeMS: firstProbeMS)
    }

    private struct PageCacheEvidence {
        var containerFound: Bool
        var pageCount: Int
        /// True when a stored page actually carries items — an existing but empty file is not a warm state.
        var usable: Bool
        var evidence: String
    }

    /// Whether the app's own container holds a persisted feed page, read from the test runner.
    ///
    /// Same route as `PersonaExplorationUITests.reopenPersistedPageEvidence()`: the runner's
    /// `NSHomeDirectory()` is `<device>/data/Containers/Data/Application/<runner-uuid>`, so four
    /// `deleteLastPathComponent()` calls land on `<device>/data`, whose `Containers/Data/Application` holds the
    /// app's container — the sibling whose metadata plist names `com.feedmine.app`. Without this, a "cold"
    /// launch on a warm container (or the reverse) would carry the wrong label with no way to tell.
    private func pageCacheEvidence() -> PageCacheEvidence {
        var deviceData = URL(fileURLWithPath: NSHomeDirectory())
        for _ in 0..<4 { deviceData.deleteLastPathComponent() }
        let applications = deviceData.appendingPathComponent("Containers/Data/Application")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? []
        var appContainer: URL?
        for candidate in candidates {
            let metadata = candidate.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let fields = plist as? [String: Any],
                  (fields["MCMMetadataIdentifier"] as? String) == "com.feedmine.app" else { continue }
            appContainer = candidate
            break
        }
        guard let container = appContainer else {
            return PageCacheEvidence(
                containerFound: false,
                pageCount: 0,
                usable: false,
                evidence: "container=unreadable searched=\(applications.path) candidates=\(candidates.count)"
            )
        }
        let caches = container.appendingPathComponent("Library/Caches")
        let entries = (try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
        let pages = entries.filter { $0.lastPathComponent.hasPrefix("visible-page-cache") && $0.pathExtension == "json" }
        var usable = false
        var described: [String] = []
        for page in pages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let items = Self.pageItemCount(at: page)
            usable = usable || items > 0
            described.append("\(page.lastPathComponent){items=\(items)}")
        }
        return PageCacheEvidence(
            containerFound: true,
            pageCount: pages.count,
            usable: usable,
            evidence: "container=found pages=\(pages.count) \(described.joined(separator: " "))"
        )
    }

    private static func pageItemCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let items = fields["items"] as? [Any] else { return -1 }
        return items.count
    }
}
