import XCTest
@testable import FeedDomain
@testable import FeedRuntime

/// The bounded window of plan §11: how many light references it holds, how many bytes it decodes, and
/// how the cursor survives a shift, an eviction and a restore.
///
/// Every assertion is a count or a byte total where the requirement is a bound, and an identity plus a
/// compensation amount where the requirement is that the reader does not move.
final class FeedWindowTests: XCTestCase {
    private func reference(
        ordinal: Int,
        edition: EditionID,
        height: Double = 100,
        bytes: Int = 1000
    ) throws -> FeedWindowReference {
        FeedWindowReference(
            cardID: try PublicationCardID(Int64(ordinal) + 1000),
            absoluteOrdinal: ordinal,
            editionID: edition,
            estimatedHeight: height,
            decodedByteEstimate: bytes
        )
    }

    private func references(
        _ range: ClosedRange<Int>,
        edition: EditionID,
        height: Double = 100,
        bytes: Int = 1000
    ) throws -> [FeedWindowReference] {
        try range.map { try reference(ordinal: $0, edition: edition, height: height, bytes: bytes) }
    }

    private func anchor(
        ordinal: Int,
        edition: EditionID,
        fraction: Double = 0
    ) throws -> FeedWindowAnchor {
        try FeedWindowAnchor(
            editionID: edition,
            cardID: try PublicationCardID(Int64(ordinal) + 1000),
            absoluteOrdinal: ordinal,
            offsetFraction: fraction
        )
    }

    /// The plan's starting point, asserted as a count: the baseline window holds at most 72 light
    /// references, and a materialization of a thousand rows still holds 72.
    func testBaselineWindowHoldsAtMostSeventyTwoLightReferences() throws {
        let configuration = FeedWindowConfiguration.baseline
        XCTAssertEqual(configuration.maximumReferences, 72)

        let edition = try EditionID(1)
        var window = FeedWindow(configuration: configuration)
        window.materialize(
            try references(0...999, edition: edition),
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 0, lastVisibleOrdinal: 5),
            anchor: try anchor(ordinal: 0, edition: edition)
        )

        XCTAssertLessThanOrEqual(window.referenceCount, 72)
        XCTAssertLessThanOrEqual(window.evictionCount, 72)
        XCTAssertEqual(window.referenceCount, window.materializedCount, "nothing needed eviction here")
    }

    /// The decoded window is smaller than the reference window and bounded by bytes: the two bounds are
    /// different requirements and are asserted separately.
    func testDecodedWindowIsSmallerAndStaysInsideTheByteBudget() throws {
        let edition = try EditionID(1)
        // 4 MiB per card against the 12 MiB baseline budget: three fit, the fourth would exceed it.
        var window = FeedWindow(configuration: .baseline)
        window.materialize(
            try references(0...9, edition: edition, bytes: 4 * 1024 * 1024),
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 0, lastVisibleOrdinal: 2),
            anchor: try anchor(ordinal: 0, edition: edition)
        )
        XCTAssertEqual(window.materializedCount, 3)
        XCTAssertLessThanOrEqual(window.materializedByteCount, FeedWindowConfiguration.baselineDecodedByteBudget)
        XCTAssertLessThan(window.materializedCount, window.referenceCount)

        // A tiny budget keeps only what fits, and never more.
        var small = FeedWindow(
            configuration: try FeedWindowConfiguration(maximumReferences: 10, decodedByteBudget: 2500, margin: 1)
        )
        small.materialize(
            try references(0...9, edition: edition, bytes: 1000),
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 0, lastVisibleOrdinal: 9),
            anchor: nil
        )
        XCTAssertEqual(small.materializedCount, 2)
        XCTAssertLessThanOrEqual(small.materializedByteCount, 2500)
    }

    /// The named contract of plan §19 #23: a window shift in either direction keeps the same cursor and
    /// reports exactly how much height changed before it, so the renderer can compensate.
    ///
    /// Configuration: 8 references, margin 4, 100 points per row.
    func testWindowShiftPreservesAnchorInBothDirections() throws {
        let edition = try EditionID(7)
        var window = FeedWindow(
            configuration: try FeedWindowConfiguration(maximumReferences: 8, decodedByteBudget: 1_000_000, margin: 4)
        )
        let viewport = FeedWindow.Viewport(firstVisibleOrdinal: 105, lastVisibleOrdinal: 108)
        let start = try anchor(ordinal: 105, edition: edition, fraction: 0.25)

        window.materialize(
            try references(104...109, edition: edition),
            viewport: viewport,
            anchor: start
        )
        XCTAssertEqual(window.anchor, start)
        XCTAssertEqual(window.referenceCount, 6)
        XCTAssertEqual(window.heightCompensation, 0, "a fresh materialization is the baseline")

        // Direction 1 — an earlier page is read locally and its rows materialize *above* the reader.
        let backward = window.shift(to: viewport, inserting: try references(101...103, edition: edition))
        XCTAssertEqual(window.anchor, start, "the cursor is the same card at the same offset")
        XCTAssertTrue(window.anchorIsMaterialized)
        XCTAssertEqual(backward.evictedCardIDs, [], "nothing left the window: it only gained rows")
        XCTAssertEqual(backward.insertedBeforeAnchorHeight, 200, "102 and 103 sit before the anchor")
        XCTAssertEqual(backward.heightCompensationDelta, 200)
        XCTAssertEqual(window.heightCompensation, 200)
        XCTAssertLessThanOrEqual(window.referenceCount, 8)

        // Direction 2 — the reader scrolls forward; rows above the new cursor are evicted and the
        // window says by how much the content above it shrank.
        let forwardAnchor = try anchor(ordinal: 107, edition: edition, fraction: 0.5)
        window.setAnchor(forwardAnchor)
        let forward = window.shift(
            to: FeedWindow.Viewport(firstVisibleOrdinal: 107, lastVisibleOrdinal: 110)
        )
        XCTAssertEqual(window.anchor, forwardAnchor)
        XCTAssertTrue(window.anchorIsMaterialized, "the cursor row is never evicted while it is set")
        XCTAssertEqual(forward.evictedCardIDs, [try PublicationCardID(1102)], "ordinal 102 left the margin")
        XCTAssertEqual(forward.removedBeforeAnchorHeight, 100)
        XCTAssertEqual(forward.heightCompensationDelta, -100)
        XCTAssertEqual(window.heightCompensation, 100, "the running total is what the renderer still owes")
        XCTAssertLessThanOrEqual(window.referenceCount, 8)
    }

    /// Eviction and restore: the cursor is an identity, so a window that lost every presentation object
    /// finds the same card at the same offset even when the rows come back in another order.
    func testWindowEvictionAndRestoreKeepTheAnchorByIdentity() throws {
        let edition = try EditionID(9)
        var window = FeedWindow(
            configuration: try FeedWindowConfiguration(maximumReferences: 6, decodedByteBudget: 1_000_000, margin: 1)
        )
        let cursor = try anchor(ordinal: 204, edition: edition, fraction: 0.5)
        let rows = try references(200...209, edition: edition).shuffled(
            usingDeterministicPermutation: 7
        )

        window.materialize(
            rows,
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 204, lastVisibleOrdinal: 205),
            anchor: cursor
        )
        XCTAssertEqual(window.anchor, cursor)
        XCTAssertTrue(window.anchorIsMaterialized)

        // Eviction: the presentation objects go, the cursor stays.
        let materializedBefore = window.referenceCount
        let evicted = window.releaseMaterializedContent()
        XCTAssertEqual(window.referenceCount, 0)
        XCTAssertEqual(evicted.evictedCardIDs.count, materializedBefore)
        XCTAssertEqual(window.anchor, cursor, "eviction alone never moves the cursor")
        XCTAssertFalse(window.anchorIsMaterialized)
        XCTAssertEqual(window.heightCompensation, 0)

        // Restoration: a different order, the same cursor. Nothing here is an array index.
        window.materialize(
            try references(200...209, edition: edition).reversed(),
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 204, lastVisibleOrdinal: 205),
            anchor: window.anchor
        )
        XCTAssertEqual(window.anchor, cursor)
        XCTAssertTrue(window.anchorIsMaterialized, "the cursor row is materialized again")
        XCTAssertEqual(
            window.reference(forCardID: cursor.cardID)?.absoluteOrdinal,
            204,
            "the cursor is found by identity, not by array position"
        )
        XCTAssertEqual(window.viewport?.firstVisibleOrdinal, 204, "the reader resumes at the cursor")
    }

    /// The rows nearest the viewport are the ones that survive a tight capacity; the rest are evicted,
    /// which is presentation eviction only and never a removal of published content.
    func testCapacityKeepsTheRowsNearestTheViewport() throws {
        let edition = try EditionID(3)
        var window = FeedWindow(
            configuration: try FeedWindowConfiguration(maximumReferences: 3, decodedByteBudget: 1_000_000, margin: 2)
        )
        window.materialize(
            try references(2...7, edition: edition),
            viewport: FeedWindow.Viewport(firstVisibleOrdinal: 4, lastVisibleOrdinal: 5),
            anchor: nil
        )
        XCTAssertEqual(window.referenceCount, 3)
        XCTAssertEqual(
            window.references.map(\.absoluteOrdinal),
            [3, 4, 5],
            "the two viewport rows and the nearest row above them"
        )
        XCTAssertEqual(window.evictionCount, 0, "a materialization is a baseline, not an eviction")

        let adjustment = window.shift(
            to: FeedWindow.Viewport(firstVisibleOrdinal: 6, lastVisibleOrdinal: 7),
            inserting: try references(6...7, edition: edition)
        )
        XCTAssertEqual(
            adjustment.evictedCardIDs,
            [try PublicationCardID(1003), try PublicationCardID(1004)],
            "the rows the reader left behind are the ones evicted"
        )
        XCTAssertEqual(window.references.map(\.absoluteOrdinal), [5, 6, 7])
        XCTAssertEqual(window.evictionCount, 2)
        XCTAssertLessThanOrEqual(window.referenceCount, 3)
    }
}

private extension Array {
    /// A deterministic permutation: the same seed gives the same order on every machine and launch,
    /// which `shuffled()` alone does not promise (its generator is not seeded by a value).
    func shuffled(usingDeterministicPermutation seed: UInt64) -> [Element] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        var result = self
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            let target = Int(next() % UInt64(index + 1))
            result.swapAt(index, target)
        }
        return result
    }
}
