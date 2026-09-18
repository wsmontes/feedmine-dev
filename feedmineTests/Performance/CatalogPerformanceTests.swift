import XCTest
@testable import feedmine

/// Component performance tests for catalog insert throughput and search.
/// Uses deterministic fixtures with iteration-safe measure blocks.
@MainActor
final class CatalogPerformanceTests: XCTestCase {

    // MARK: - PERF-CAT-001: Bulk insert

    func testBulkInsert_1K() async throws {
        // Raw timing — measure() blocks with async persistFetchedItems are too
        // slow on simulator for multiple iterations. The curve tests give better data.
        let store = try! FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 1_000, seed: 42)
        let start = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(items)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertEqual(persisted.count, 1_000, "All 1K items must persist")
        XCTAssertLessThan(elapsed, 10_000, "1K insert took \(String(format: "%.0f", elapsed))ms — exceeds 10s budget")
    }

    func testBulkInsert_2K() async throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let expectation = self.expectation(description: "insert")
            Task {
                let store = try! FeedStore(inMemory: true)
                let items = makeFixtureItems(count: 2_000, seed: 42)
                let persisted = await store.persistFetchedItems(items)
                XCTAssertGreaterThan(persisted.count, 0)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 60.0)
        }
    }

    // MARK: - PERF-CAT-004: Search

    func testSearchCommonTerm_10K() async throws {
        let store = try FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 10_000, seed: 42)
        _ = await store.persistFetchedItems(items)

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            let expectation = self.expectation(description: "search")
            Task {
                let results = await store.searchEngine.search(
                    "Technology", region: nil, category: nil
                )
                XCTAssertFalse(results.isEmpty, "Must find Technology items in 10K")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10.0)
        }
    }

    // MARK: - PERF-CAT-008: Pagination (real SQLite query)

    func testPaginatedRead_Real() async throws {
        let store = try FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 10_000, seed: 42)
        _ = await store.persistFetchedItems(items)

        // Force a real timeline composition instead of reading the cached array
        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "paginate")
            Task {
                // This triggers actual SQLite query and Reservoir interleave
                _ = await store.search(
                    "Technology",
                    includeSources: true,
                    includeContents: true,
                    demandOnlineContent: true
                )
                let visible = store.visibleItems
                XCTAssertFalse(visible.isEmpty, "Timeline must have content after recomposition")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 30.0)
        }
    }
}
