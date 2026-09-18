import XCTest
@testable import feedmine

/// Performance tests for timeline query and multi-source merge.
/// Uses real FeedStore.recomposeFeed() for genuine SQLite query measurement.
@MainActor
final class TimelineAssemblyPerformanceTests: XCTestCase {

    // MARK: - PERF-TIME-001: First page query (real)

    func testTimelineRecompose_5K() async throws {
        let items = makeFixtureItems(count: 5_000, seed: 555)
        let store = try! FeedStore(inMemory: true)
        _ = await store.persistFetchedItems(items)

        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "search query")
            Task {
                _ = await store.search(
                    "Technology",
                    includeSources: true,
                    includeContents: true,
                    demandOnlineContent: true
                )
                let visible = store.visibleItems
                XCTAssertFalse(visible.isEmpty, "Must produce visible timeline after search")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 30.0)
        }
    }

    // MARK: - PERF-TIME-003: Multi-source dedupe

    func testMultiSourceDedupe() async throws {
        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "multi source")
            Task {
                let store = try! FeedStore(inMemory: true)
                for sourceIdx in 0..<5 {
                    let items = makeFixtureItems(count: 200, seed: 600 + sourceIdx)
                    _ = await store.persistFetchedItems(items)
                }
                _ = await store.search(
                    "Technology",
                    includeSources: true,
                    includeContents: true,
                    demandOnlineContent: true
                )
                let visible = store.visibleItems
                XCTAssertGreaterThan(visible.count, 0, "Must have merged timeline")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 30.0)
        }
    }

    // MARK: - PERF-TIME-005: Refresh insert at top

    func testRefreshInsertAtTop() async throws {
        let existing = makeFixtureItems(count: 500, seed: 700)

        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "refresh")
            Task {
                let store = try! FeedStore(inMemory: true)
                _ = await store.persistFetchedItems(existing)
                let newItems = makeFixtureItems(count: 50, seed: 701)
                let persisted = await store.persistFetchedItems(newItems)
                XCTAssertEqual(persisted.count, 50, "All new items must persist")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 30.0)
        }
    }
}
