import XCTest
@testable import FeedMedia

final class MediaBudgetTests: XCTestCase {
    func testCurrentBudgetMatchesTheLegacyStoreLimits() {
        XCTAssertEqual(MediaBudget.current.maxCompressedBytes, 12 * 1024 * 1024)
        XCTAssertEqual(MediaBudget.current.maxDimension, 12_000)
        XCTAssertEqual(MediaBudget.current.maxPixels, 50_000_000)
    }

    func testOversizedCompressedPayloadIsRejectedBeforeDecode() {
        let acceptance = MediaBudget.current.inspect(
            byteCount: 12 * 1024 * 1024 + 1,
            pixelWidth: 100,
            pixelHeight: 100
        )
        XCTAssertEqual(acceptance, .rejected(.tooManyBytes(12 * 1024 * 1024 + 1)))
    }

    func testBoundaryValuesAreAccepted() {
        XCTAssertTrue(MediaBudget.current.inspect(
            byteCount: 12 * 1024 * 1024,
            pixelWidth: 12_000,
            pixelHeight: 1
        ).isAccepted, "the limits themselves are allowed")
    }

    func testTooManyPixelsIsRejectedEvenWhenEachDimensionIsLegal() {
        let acceptance = MediaBudget.current.inspect(
            byteCount: 1024,
            pixelWidth: 9_000,
            pixelHeight: 9_000
        )
        XCTAssertEqual(acceptance, .rejected(.tooManyPixels(81_000_000)))
    }

    func testEmptyOrDimensionlessPayloadIsRejected() {
        XCTAssertEqual(MediaBudget.current.inspect(byteCount: 0, pixelWidth: 10, pixelHeight: 10), .rejected(.empty))
        XCTAssertEqual(MediaBudget.current.inspect(byteCount: 10, pixelWidth: 0, pixelHeight: 10), .rejected(.zeroDimension))
    }

    func testDownsamplingIsRequestedOnlyWhenTheImageIsWiderThanTheTarget() {
        XCTAssertEqual(
            MediaBudget.current.inspect(byteCount: 1024, pixelWidth: 2000, pixelHeight: 1000, targetWidth: 600),
            .accepted(downsampleTo: 600)
        )
        XCTAssertEqual(
            MediaBudget.current.inspect(byteCount: 1024, pixelWidth: 400, pixelHeight: 200, targetWidth: 600),
            .accepted(downsampleTo: nil)
        )
    }
}
