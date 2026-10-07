import Foundation
import XCTest

@MainActor
final class FeedmineUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestSkipOnboarding",
        ]
        app.launch()
    }

    func testCuratedOnboardingCreatesAnInspectableFeedFromRealStories() {
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestShowOnboarding",
        ]
        app.launch()

        // Welcome screen — two-stage flow: Welcome → Composer
        let shape = app.buttons["welcome-shape"]
        XCTAssertTrue(shape.waitForExistence(timeout: 40), "Curated onboarding must appear")
        shape.tap()

        // Composer screen — save the (default neutral) recipe
        let openFeed = app.buttons["composer-open-feed"]
        XCTAssertTrue(openFeed.waitForExistence(timeout: 30), "Composer must appear")
        openFeed.tap()

        let filterButton = app.buttons["filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(
            Int(filterButton.value as? String ?? "") ?? 0,
            0,
            "Finishing onboarding must persist and activate the Curated Feed"
        )
    }

    // MARK: - Acoustics (4 feeds, topic)

    func testAcousticsFilterShowsAcousticsCards() {
        selectTaxonomyCategory(
            searchTerm: "Acoustics",
            expectedKeywords: ["Acoustics Today", "Audio Engineering", "acoustics.org"],
            forbiddenSources: ["CNN", "BBC News", "Daring Fireball", "MacStories"],
            screenshotName: "acoustics-verified"
        )
    }

    // MARK: - Duplicate-name taxonomy category

    func testMythologyCategoryPrefersEditorialTopicOverCountryDuplicates() {
        selectTaxonomyCategory(
            searchTerm: "Mythology & Folklore",
            expectedKeywords: ["American Folklore Society", "Folklore"],
            forbiddenSources: ["CNN", "BBC News", "Snopes"],
            screenshotName: "mythology-editorial-topic-verified"
        )
    }

    func testFactCheckingCategoryOwnsMisinformationSources() {
        selectTaxonomyCategory(
            searchTerm: "Fact-Checking & Media Literacy",
            expectedKeywords: ["Snopes", "Conspiracy Watch"],
            forbiddenSources: ["Myths Your Teacher Hated", "Freaky Folklore"],
            screenshotName: "fact-checking-editorial-topic-verified"
        )
    }

    // MARK: - Humor topic category

    func testHumorCategoryShowsCards() {
        // Comedy and performance sources share one content-derived category.
        selectTaxonomyCategory(
            searchTerm: "Comedy & Performance",
            expectedKeywords: ["comedy", "funny", "humor"],
            forbiddenSources: ["CNN", "BBC News", "Daring Fireball"],
            screenshotName: "podcast-verified"
        )
    }

    // MARK: - Video/YouTube category

    func testVideoCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Cooking & Recipes",
            expectedKeywords: ["Sorted Food", "cooking", "recipe"],
            forbiddenSources: ["CNN", "BBC News", "MacStories"],
            screenshotName: "video-verified"
        )
    }

    // MARK: - Country-based category

    func testCountryCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Algeria",
            expectedKeywords: ["Algeria", "algerie", "Echorouk"],
            forbiddenSources: ["This Day in History"],
            screenshotName: "country-verified"
        )
    }

    // MARK: - Many-feeds category

    func testManyFeedsCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Visual Arts",
            expectedKeywords: ["photography", "photo", "camera"],
            forbiddenSources: ["CNN", "BBC News"],
            screenshotName: "many-feeds-verified"
        )
    }

    // MARK: - Clear filters restores normal feed

    func testClearFiltersRestoresFullFeed() {
        waitForAppReady()

        // Apply a filter so we can verify it's cleared
        openFilterAndSelectTopic(searchTerm: "Acoustics")
        dismissTopicsAndFilter()
        sleep(5)
        _ = app.cells.firstMatch.waitForExistence(timeout: 20)
        let beforeClear = app.cells.count
        print("Cells with Acoustics filter: \(beforeClear)")

        // Open filter and tap "Clear All Filters"
        let filterButton = app.buttons["filter-button"]
        filterButton.tap()
        sleep(2)
        _ = app.buttons["filter-done"].waitForExistence(timeout: 5)
        let clearBtn = app.buttons["Clear All Filters"]
        XCTAssertTrue(clearBtn.exists, "Clear All Filters button must be visible")
        clearBtn.tap()
        // clearAllFilters() calls dismiss() internally
        sleep(3)

        // After clear, the filter badge on the button should be gone
        // (activeCount == 0 means no badge circle with number)
        // Verify the filter button still exists (sheet dismissed successfully)
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5),
                      "App should return to feed after clearing filters")

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = "clear-filters-verified"
        add(attachment)

        let cards = waitForFeedItemIdentifiers(timeout: 20)
        XCTAssertFalse(cards.isEmpty, "Clearing filters must restore feed cards")
    }

    func testContentTypeFilterTapsRespondImmediately() {
        waitForAppReady()
        let filterButton = app.buttons["filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 3))

        let id = "content-type-videos"
        let button = app.buttons[id]
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 2), "Missing \(id) filter")
        if (button.value as? String) == "selected" {
            button.tap()
        }
        let start = CFAbsoluteTimeGetCurrent()
        button.tap()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 1.3, "\(id) filter tap blocked the UI for \(elapsed)s")
        app.buttons["filter-done"].tap()
        XCTAssertTrue(filterButton.waitForExistence(timeout: 3))
    }

    func testUnifiedSearchFindsAndOpensContentAnalyzedSource() {
        let searchButton = app.buttons["search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 45), "Search button must be available")
        searchButton.tap()

        let field = app.textFields["unified-search-field"]
        var didOpenSearch = field.waitForExistence(timeout: 15)
        if !didOpenSearch, searchButton.exists {
            // The first tap can coincide with the initial taxonomy publication
            // on slower simulators. Retry the idempotent presentation action
            // once instead of turning startup load into a false UI failure.
            searchButton.tap()
            didOpenSearch = field.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(didOpenSearch, "Unified search field must open")
        guard didOpenSearch else { return }
        field.tap()
        field.typeText("astronomy")
        field.typeText("\n")

        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 12),
                      "Content-analyzed source tier must be first")
        let astronomySource = app.staticTexts["Astronomy Magazine"].firstMatch
        XCTAssertTrue(astronomySource.waitForExistence(timeout: 8),
                      "Astronomy source should be found from catalog tags/descriptions")
        astronomySource.tap()

        XCTAssertTrue(app.navigationBars["Astronomy Magazine"].waitForExistence(timeout: 8),
                      "Tapping a source should open its complete source feed")
        XCTAssertTrue(app.buttons["Add source to collection"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "astronomy")).firstMatch.exists,
            "Source feed should expose its content-derived astronomy tag"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "currently exposed by the feed")).firstMatch.exists,
            "Source view should explain the honest RSS history boundary"
        )

        // A source result can be put into a reusable many-to-many playlist
        // without enabling or moving its catalog/OPML entry.
        app.buttons["Add source to collection"].tap()
        let collectionName = "Astronomy reading \(Int(Date().timeIntervalSince1970))"
        let collectionField = app.textFields["Collection name"]
        for _ in 0..<8 where !collectionField.exists {
            app.swipeUp()
        }
        XCTAssertTrue(collectionField.waitForExistence(timeout: 5))
        collectionField.tap()
        collectionField.typeText(collectionName)
        app.buttons["Create Collection"].tap()
        XCTAssertTrue(app.staticTexts[collectionName].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "unified-search-astronomy-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAddFeedListsCollectionsCreatedInSourceCollections() {
        let moreMenu = app.buttons["more-menu"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 45), "More menu must be available")
        moreMenu.tap()
        app.buttons["Source Collections"].tap()

        XCTAssertTrue(app.navigationBars["Source Collections"].waitForExistence(timeout: 8))
        app.buttons["Create source collection"].tap()
        let collectionName = "URL imports \(Int(Date().timeIntervalSince1970))"
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(collectionName)
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[collectionName].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        XCTAssertTrue(moreMenu.waitForExistence(timeout: 5))
        moreMenu.tap()
        app.buttons["Add Feed"].tap()

        let picker = app.buttons["add-feed-collection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.tap()
        let collectionOption = app.buttons[collectionName]
        XCTAssertTrue(
            collectionOption.waitForExistence(timeout: 5),
            "A real source collection must be offered by Add Feed"
        )
        collectionOption.tap()
        XCTAssertTrue(
            (picker.value as? String)?.contains(collectionName) == true
                || picker.label.contains(collectionName),
            "The personal collection must be selected as the URL destination"
        )
    }

    func testRecoveredDormantAstronomySourceIsSearchableButNotAutoEnabled() {
        let searchButton = app.buttons["search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 45), "Search button must be available")
        searchButton.tap()

        let field = app.textFields["unified-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Unified search field must open")
        guard field.exists else { return }
        field.tap()
        field.typeText("Turk Astronomi")
        field.typeText("\n")

        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 12))
        let recoveredSource = app.staticTexts["Türk Astronomi Derneği (TAD)"].firstMatch
        XCTAssertTrue(
            recoveredSource.waitForExistence(timeout: 8),
            "A recovered source must be discoverable through its analyzed catalog metadata"
        )
        recoveredSource.tap()

        XCTAssertTrue(
            app.navigationBars["Türk Astronomi Derneği (TAD)"].waitForExistence(timeout: 8),
            "The recovered source result must open its exact source view"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "astronomy")).firstMatch.exists,
            "The source must retain its content-derived astronomy classification"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Dormant in the automatic feed")
            ).firstMatch.exists,
            "Dormant current-sensitive sources must remain searchable without auto-enabling them"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "recovered-dormant-astronomy-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLongPressCardOpensThatExactSource() {
        waitForAppReady()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "A feed card is required for source navigation")
        guard card.exists else { return }

        card.press(forDuration: 1.2)
        let viewSource = app.buttons["View Source"]
        XCTAssertTrue(viewSource.waitForExistence(timeout: 5), "Long press must offer direct source navigation")
        viewSource.tap()

        XCTAssertTrue(app.buttons["Add source to collection"].waitForExistence(timeout: 8),
                      "The exact source feed should open from the card menu")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "currently exposed by the feed")).firstMatch.exists,
            "The source screen should be content-first and disclose feed history limits"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "long-press-view-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    /// Full flow: wait for app, open filter, search topic, select it, verify results.
    private func selectTaxonomyCategory(
        searchTerm: String,
        expectedKeywords: [String],
        forbiddenSources: [String],
        screenshotName: String,
        allowEmptyCards: Bool = false
    ) {
        waitForAppReady()
        openFilterAndSelectTopic(searchTerm: searchTerm)
        dismissTopicsAndFilter()

        // Wait for cards and verify
        print("Waiting for cards after selecting '\(searchTerm)'...")
        let cardIdentifiers = waitForFeedItemIdentifiers(timeout: 30)
        let cardsExist = !cardIdentifiers.isEmpty
        print("Total visible cards: \(cardIdentifiers.count)")

        let allTexts = app.staticTexts

        // Verify expected keywords
        var foundExpected = expectedKeywords.isEmpty
        for kw in expectedKeywords {
            if allTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", kw)).firstMatch.exists {
                foundExpected = true
                break
            }
        }

        // Collect diagnostics
        var labels: [String] = []
        for i in 0..<min(cardIdentifiers.count, 5) {
            labels.append(cardIdentifiers[i])
        }

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = screenshotName
        add(attachment)

        if !allowEmptyCards {
            XCTAssertTrue(cardsExist,
                          "No cards visible for '\(searchTerm)' after 30 seconds. Cards: \(labels)")
            XCTAssertTrue(foundExpected,
                          "No \(searchTerm) card found. Cards: \(labels)")
        }

        // Verify no leakage
        for source in forbiddenSources {
            let match = allTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", source)).firstMatch
            XCTAssertFalse(match.exists,
                          "Non-\(searchTerm) source '\(source)' leaked into filtered feed!")
        }
    }

    /// Waits for app to load, opens filter, searches for and selects a topic.
    private func openFilterAndSelectTopic(searchTerm: String) {
        let filterButton = app.buttons["filter-button"]
        guard filterButton.waitForExistence(timeout: 40) else {
            XCTFail("App failed to load — filter button not found")
            return
        }
        sleep(8)  // Let progressive fetch settle

        // Open filter
        filterButton.tap()
        sleep(2)

        // Ensure sheet is visible
        let doneButton = app.buttons["Done"]
        let filterDone = app.buttons["filter-done"]
        let sheetVisible = doneButton.waitForExistence(timeout: 5) ||
                           filterDone.waitForExistence(timeout: 5)
        if !sheetVisible {
            filterButton.tap()
            sleep(2)
            guard doneButton.waitForExistence(timeout: 5) || filterDone.waitForExistence(timeout: 5) else {
                XCTFail("Filter sheet did not open")
                return
            }
        }

        // Find and tap Browse Topics
        sleep(1)
        let browsePred = NSPredicate(format: "label CONTAINS[c] %@", "Browse Topics")
        var foundBrowse = false
        for _ in 0..<8 {
            let btn = app.buttons.element(matching: browsePred)
            let text = app.staticTexts.element(matching: browsePred)
            if btn.exists { btn.tap(); foundBrowse = true; break }
            else if text.exists { text.tap(); foundBrowse = true; break }
            app.swipeUp()
            usleep(500_000)
        }
        guard foundBrowse else {
            XCTFail("Browse Topics not found")
            return
        }

        sleep(1)

        // Wait for search field and search
        let searchField = app.textFields["search-topics"]
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Topics search field did not appear")
            return
        }
        searchField.tap()
        sleep(1)
        searchField.typeText(searchTerm)
        sleep(2)
        searchField.typeText("\n")
        usleep(300_000)

        // Tap search result
        let resultPred = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "taxonomy-node-", searchTerm
        )
        let resultBtn = app.buttons.matching(resultPred).firstMatch
        guard resultBtn.waitForExistence(timeout: 5) else {
            XCTFail("'\(searchTerm)' not found in search results")
            return
        }
        let searchShot = XCTAttachment(screenshot: app.screenshot())
        searchShot.name = "topic-search-\(searchTerm)"
        searchShot.lifetime = .deleteOnSuccess
        add(searchShot)
        XCTAssertTrue(resultBtn.isHittable,
                      "Topic result is not hittable: \(resultBtn.identifier), \(resultBtn.label)")
        resultBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertGreaterThan(
            Int(app.buttons["topics-done"].value as? String ?? "") ?? 0,
            0,
            "Topic selection must update immediately after tapping '\(resultBtn.label)' (\(resultBtn.identifier))"
        )
        sleep(1)
    }

    /// Dismisses Topics view and Filter sheet.
    private func dismissTopicsAndFilter() {
        let topicsDone = app.buttons["topics-done"]
        if topicsDone.exists { topicsDone.tap() }
        else {
            let doneBtn = app.buttons["Done"]
            if doneBtn.exists { doneBtn.tap() }
        }
        sleep(1)

        let selectedTopicCount = Int(app.buttons["browse-topics"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(selectedTopicCount, 0,
                             "Topic selection must remain active after leaving the topic browser")

        let filterDoneBtn = app.buttons["filter-done"]
        if filterDoneBtn.exists { filterDoneBtn.tap() }
        else {
            let doneBtn = app.buttons["Done"]
            if doneBtn.exists { doneBtn.tap() }
        }
        sleep(2)

        let activeFilterCount = Int(app.buttons["filter-button"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(activeFilterCount, 0,
                             "Topic selection must remain active after dismissing filters")
    }

    /// Wait for app to finish initial loading.
    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("App failed to load")
            return
        }
        sleep(8)
    }

    private func waitForFeedItemIdentifiers(timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let identifiers = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .allElementsBoundByIndex
                .map(\.identifier)
            if !identifiers.isEmpty { return identifiers }
            usleep(100_000)
        } while Date() < deadline
        return []
    }

    /// Captura a tela atual para inspeção do contador de sources no header.
    func testCaptureHeaderScreenshot() {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "header-counter"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    // MARK: - Interactive Persona Script Harness

    /// Reads /tmp/feedmine-script.json, executes each action, saves screenshots.
    /// Actions: tap(id), tapLabel(text), tapFirst(prefix), typeText(id,text), swipeUp, swipeDown,
    ///          press(id,duration), scrollTo(id), wait(seconds), relaunch, dismiss, screenshot(id)
    ///
    /// The script is written *outside* the suite, so the harness keeps its two failure modes apart instead of
    /// folding both into a green run:
    ///  * no script on disk — the harness has nothing to execute, so the case `XCTSkip`s with the path. The old
    ///    shape printed "❌ Failed to read script" and returned, and xcodebuild still reported **passed**
    ///    (`Artifacts/Validation/Logs/Smoke-20261006-034304.log:5014` → `:5016`).
    ///  * a script that declares no action, an action whose target never appears, an action of an unknown type —
    ///    `XCTFail`: a declared step that did not run is not evidence. The old shape printed "⚠️ … not found" per
    ///    miss and still ended on "✅ Script complete — N actions executed".
    ///  * every step that *does* run must show the transition it promises: the screen changes, a typed field holds
    ///    the text, a relaunch comes back on its feed, a screenshot file exists. An ignored tap counted as a step.
    func testExecuteInteractiveScript() throws {
        let scriptPath = "/tmp/feedmine-script.json"
        let screenshotDir = "/tmp/feedmine-interactive"

        // Ensure screenshot directory exists
        let fm = FileManager.default
        if !fm.fileExists(atPath: screenshotDir) {
            try? fm.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: scriptPath)) else {
            throw XCTSkip("interactive script precondition: no readable script at \(scriptPath) — nothing to execute")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = json["actions"] as? [[String: Any]] else {
            XCTFail("\(scriptPath) is not a JSON object with an \"actions\" array — nothing was executed")
            return
        }
        guard !actions.isEmpty else {
            XCTFail("\(scriptPath) declares 0 actions — a run that executes no step is not evidence")
            return
        }

        print("📜 Executing \(actions.count) interactive actions...")

        var executed = 0
        for (index, action) in actions.enumerated() {
            let type = action["type"] as? String ?? ""
            let step = "[\(index + 1)/\(actions.count)] \(type)"
            print("  \(step): \(action["id"] as? String ?? action["text"] as? String ?? "")")

            switch type {
            case "tap":
                guard let targetId = action["id"] as? String else {
                    XCTFail("\(step) has no \"id\" — nothing was executed"); continue
                }
                let button = app.buttons[targetId].firstMatch
                var element: XCUIElement?
                if button.waitForExistence(timeout: 5) {
                    element = button
                } else {
                    // Try as any element type
                    let anyElement = app.descendants(matching: .any)[targetId].firstMatch
                    element = anyElement.waitForExistence(timeout: 3) ? anyElement : nil
                }
                guard let element else {
                    XCTFail("\(step) '\(targetId)': nothing with that identifier in the tree after 8 s (app_state=\(app.state.rawValue))")
                    continue
                }
                let before = observeScreen(target: element)
                element.tap()
                executed += 1
                assertStepLanded(step: step, target: targetId, before: before, after: observeScreen(target: element), typed: nil)

            case "tapLabel":
                guard let label = action["text"] as? String else {
                    XCTFail("\(step) has no \"text\" — nothing was executed"); continue
                }
                let predicate = NSPredicate(format: "label CONTAINS[c] %@", label)
                let labelButton = app.buttons.matching(predicate).firstMatch
                var element: XCUIElement? = labelButton.waitForExistence(timeout: 3) ? labelButton : nil
                if element == nil {
                    // Try static texts
                    let textElement = app.staticTexts.matching(predicate).firstMatch
                    if textElement.waitForExistence(timeout: 3) { element = textElement }
                }
                guard let element else {
                    XCTFail("\(step) \"\(label)\": no button or static text with that label after 6 s")
                    continue
                }
                let before = observeScreen(target: element)
                element.tap()
                executed += 1
                assertStepLanded(step: step, target: label, before: before, after: observeScreen(target: element), typed: nil)

            case "tapFirst":
                // Tap the first element matching a prefix
                guard let prefix = action["id"] as? String else {
                    XCTFail("\(step) has no \"id\" — nothing was executed"); continue
                }
                let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
                let element = app.descendants(matching: .any).matching(predicate).firstMatch
                guard element.waitForExistence(timeout: 5) else {
                    XCTFail("\(step) prefix '\(prefix)': no element in the tree after 5 s (app_state=\(app.state.rawValue))")
                    continue
                }
                let before = observeScreen(target: element)
                element.tap()
                executed += 1
                assertStepLanded(step: step, target: prefix, before: before, after: observeScreen(target: element), typed: nil)

            case "typeText":
                guard let fieldId = action["id"] as? String, let text = action["text"] as? String else {
                    XCTFail("\(step) needs both \"id\" and \"text\" — nothing was executed"); continue
                }
                let textField = app.textFields[fieldId].firstMatch
                var field: XCUIElement?
                if textField.waitForExistence(timeout: 5) {
                    field = textField
                } else {
                    // Try search fields
                    let searchField = app.searchFields[fieldId].firstMatch
                    field = searchField.waitForExistence(timeout: 3) ? searchField : nil
                }
                guard let field else {
                    XCTFail("\(step) '\(fieldId)': no text or search field with that identifier after 8 s")
                    continue
                }
                let before = observeScreen(target: field)
                field.tap()
                usleep(300_000)
                field.typeText(text)
                usleep(200_000)
                executed += 1
                assertStepLanded(step: step, target: fieldId, before: before, after: observeScreen(target: field), typed: text)

            case "swipeUp", "swipeDown":
                // No transition assertion: a swipe at the end of a list is a legitimate no-op.
                if type == "swipeUp" { app.swipeUp() } else { app.swipeDown() }
                executed += 1
                usleep(500_000)

            case "press":
                guard let targetId = action["id"] as? String else {
                    XCTFail("\(step) has no \"id\" — nothing was executed"); continue
                }
                let duration = action["duration"] as? Double ?? 1.0
                let element = app.descendants(matching: .any)[targetId].firstMatch
                guard element.waitForExistence(timeout: 5) else {
                    XCTFail("\(step) '\(targetId)': no element with that identifier after 5 s")
                    continue
                }
                let before = observeScreen(target: element)
                element.press(forDuration: duration)
                executed += 1
                assertStepLanded(step: step, target: targetId, before: before, after: observeScreen(target: element), typed: nil)

            case "scrollTo":
                // Scroll until element is visible, then tap
                guard let targetId = action["id"] as? String else {
                    XCTFail("\(step) has no \"id\" — nothing was executed"); continue
                }
                var element: XCUIElement?
                for _ in 0..<8 {
                    let candidate = app.buttons[targetId].firstMatch
                    if candidate.exists && candidate.isHittable {
                        element = candidate
                        break
                    }
                    app.swipeUp()
                    usleep(300_000)
                }
                guard let element else {
                    XCTFail("\(step) '\(targetId)': never became hittable in 8 swipes (app_state=\(app.state.rawValue))")
                    continue
                }
                let before = observeScreen(target: element)
                element.tap()
                executed += 1
                assertStepLanded(step: step, target: targetId, before: before, after: observeScreen(target: element), typed: nil)

            case "wait":
                let seconds = action["seconds"] as? Double ?? 2.0
                executed += 1
                usleep(UInt32(seconds * 1_000_000))

            case "relaunch":
                app.terminate()
                usleep(1_000_000)
                app.launchArguments = [
                    "-AppleLanguages", "(en)",
                    "-UITestResetFilters", "-UITestSkipOnboarding",
                ]
                app.launch()
                executed += 1
                // "Relaunch" promises the app comes back on its feed; the old `_ = …waitForExistence(timeout: 45)`
                // swallowed a launch that never reached its own chrome.
                guard app.buttons["filter-button"].waitForExistence(timeout: 45) else {
                    XCTFail("\(step): the app never came back — no `filter-button` within 45 s (app_state=\(app.state.rawValue))")
                    continue
                }
                let cardPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-")
                guard app.descendants(matching: .any).matching(cardPredicate).firstMatch.waitForExistence(timeout: 30) else {
                    XCTFail("\(step): the app came back but showed no `feed-item-` card within 30 s")
                    continue
                }
                usleep(3_000_000)

            case "dismiss":
                // Common dismiss patterns. The old fallback tapped `app.buttons.firstMatch`, which on the feed screen
                // is a card: the rest of the script then ran against a reader nobody asked for.
                let dismissControl = ["filter-done", "Done", "done-button"]
                    .map { app.buttons[$0].firstMatch }
                    .first { $0.exists }
                guard let dismissControl else {
                    XCTFail("\(step): no dismiss control found — looked for filter-done / Done / done-button (app_state=\(app.state.rawValue))")
                    continue
                }
                let before = observeScreen(target: dismissControl)
                dismissControl.tap()
                executed += 1
                usleep(500_000)
                assertStepLanded(step: step, target: dismissControl.identifier, before: before, after: observeScreen(target: dismissControl), typed: nil)

            case "screenshot":
                let shotName = action["id"] as? String ?? "step-\(index)"
                let screenshot = app.screenshot()
                let png = screenshot.pngRepresentation
                let path = "\(screenshotDir)/\(shotName).png"
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    executed += 1
                    print("    📸 Saved: \(shotName).png")
                } catch {
                    XCTFail("\(step): the screenshot this step promises was not written to \(path) — \(error)")
                }

            default:
                XCTFail("\(step): unknown action type '\(type)' — nothing was executed (known: tap, tapLabel, tapFirst, typeText, swipeUp, swipeDown, press, scrollTo, wait, relaunch, dismiss, screenshot)")
            }
        }

        // Final screenshot always
        let finalShot = app.screenshot()
        let png2 = finalShot.pngRepresentation
        let path2 = "\(screenshotDir)/final.png"
        do {
            try png2.write(to: URL(fileURLWithPath: path2))
            print("    📸 Final screenshot saved")
        } catch {
            XCTFail("the harness promises a final screenshot at \(path2) — \(error)")
        }

        XCTAssertEqual(executed, actions.count,
                       "\(actions.count) actions declared, \(executed) executed — every declared step must land")
        print("✅ Script complete — \(executed)/\(actions.count) actions executed")
    }

    /// One sample of what is on screen, cheap enough to take around every step: the identifiers in the
    /// accessibility tree, how many presentation containers (sheet / navigation bar / web view / alert) are up, and
    /// the acted-on element's own state. A chip that flips to `selected` changes none of the identifiers, and a card
    /// tap opens a sheet without changing the card's, so the three together are what distinguishes "the step
    /// landed" from "the tap was ignored" — the class of silent pass UI-28 names.
    private struct ScreenObservation {
        let identifiers: [String]
        let containers: Int
        let targetState: String
    }

    private func observeScreen(target: XCUIElement?) -> ScreenObservation {
        let identifiers = app.descendants(matching: .any).allElementsBoundByIndex.map(\.identifier).sorted()
        let containers = app.sheets.count + app.navigationBars.count + app.webViews.count + app.alerts.count
        let targetState: String
        if let target, target.exists {
            targetState = "\(target.value as? String ?? "")|\(target.label)|\(target.isSelected)"
        } else {
            targetState = "absent"
        }
        return ScreenObservation(identifiers: identifiers, containers: containers, targetState: targetState)
    }

    /// A step that executed must leave the screen it promised: the tree changed, a container appeared or went, or
    /// the element it acted on changed its own state. `typed` carries the text a `typeText` step promises to leave
    /// in its field. The message names the step, so a run with several misses is readable.
    private func assertStepLanded(
        step: String,
        target: String,
        before: ScreenObservation,
        after: ScreenObservation,
        typed: String?
    ) {
        let changed = after.identifiers != before.identifiers
            || after.containers != before.containers
            || after.targetState != before.targetState
        guard changed else {
            XCTFail("\(step) '\(target)' executed but changed nothing on screen (elements=\(before.identifiers.count), containers=\(before.containers), target_state=\(before.targetState)) — the step promised a transition")
            return
        }
        if let typed, !after.targetState.localizedCaseInsensitiveContains(typed) {
            XCTFail("\(step) '\(target)' typed \"\(typed)\" but the field reads \(after.targetState) — the text never landed")
        }
    }
}
