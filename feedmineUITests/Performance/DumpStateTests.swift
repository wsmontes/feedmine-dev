import Foundation
import XCTest

/// MANUAL DIAGNOSTIC PROBE — NOT A GATE. This file must not run in CI.
///
/// What it is: a way to look at the app's accessibility tree at 60 s / 90 s / 120 s after launch, to
/// answer questions like "did the feed ever leave the loading surface", "how many cells are
/// materialised", "what does the progress label say" while a device run is being watched by hand.
///
/// What it is not: an assertion about any of that. It has no expectations, so it can only be read by a
/// human looking at stdout — which is why each probe now *skips* instead of silently "passing". The
/// 60/90/120 s sleeps are kept (they are the probe's whole point) and are exactly why an
/// unconditional `XCTSkip` is the right guard here: without it, adding this file to a test plan would
/// park the whole suite for three and a half minutes per run.
///
/// To use it: delete the `try XCTSkip(...)` line of the probe you want (and run only that test).
@MainActor
final class DumpStateTests: XCTestCase {

    func testDumpAt60s() throws {
        try XCTSkip("probe manual: não é gate de CI")
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 60)
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let loading = texts.filter { $0.contains("Loading") || $0.contains("/100") || $0.contains("%") }
        print("=== 60s: collViews=\(app.collectionViews.count) cells=\(app.collectionViews.firstMatch.cells.count) loading=\(loading) ===")
    }

    func testDumpAt120s() throws {
        try XCTSkip("probe manual: não é gate de CI")
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 120)
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let loading = texts.filter { $0.contains("Loading") || $0.contains("/100") || $0.contains("%") }
        print("=== 120s: collViews=\(app.collectionViews.count) cells=\(app.collectionViews.firstMatch.cells.count) loading=\(loading) ===")
        // Check for content
        let hasContent = app.collectionViews.firstMatch.cells.count > 0 || app.collectionViews.firstMatch.otherElements.count > 0
        print("=== 120s: hasContent=\(hasContent) buttons=\(app.buttons.count) ===")
    }

    func testDumpAt90s() throws {
        try XCTSkip("probe manual: não é gate de CI")
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 90)
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let loading = texts.filter { $0.contains("Loading") || $0.contains("/100") || $0.contains("%") }
        let hasContent = app.collectionViews.firstMatch.cells.count > 0
        print("=== 90s: collViews=\(app.collectionViews.count) cells=\(app.collectionViews.firstMatch.cells.count) hasContent=\(hasContent) loading=\(loading) ===")
    }
}
