import XCTest
@testable import FeedDomain
@testable import FeedUIBridge

@MainActor
final class FeedScreenStoreTests: XCTestCase {
    private func snapshot(
        sequence: UInt64,
        stamp: UInt64 = 1,
        context: String = "main",
        cardID: Int64 = 1
    ) throws -> FeedPresentationSnapshot {
        FeedPresentationSnapshot(
            sessionStamp: SessionStamp(stamp),
            sequence: sequence,
            contextKey: context,
            editionID: try EditionID(1),
            editorialRevision: nil,
            renderEnvironment: .unspecified,
            cards: [
                CardPresentation(
                    id: try PublicationCardID(cardID),
                    absoluteOrdinal: Int(cardID - 1),
                    title: "first",
                    subtitle: nil,
                    media: .placeholder(reason: "not prepared"),
                    layout: .textOnly,
                    isBookmarked: false,
                    isRead: false
                )
            ]
        )
    }

    func testOlderSequenceIsRejected() throws {
        let store = FeedScreenStore(intentHandler: { _ in })
        XCTAssertTrue(store.apply(try snapshot(sequence: 2)))
        XCTAssertFalse(store.apply(try snapshot(sequence: 1)))
        XCTAssertEqual(store.latest?.sequence, 2)
    }

    func testSnapshotFromAnOlderSessionIsRejected() throws {
        let store = FeedScreenStore(intentHandler: { _ in })
        XCTAssertTrue(store.apply(try snapshot(sequence: 5, stamp: 2)))
        XCTAssertFalse(store.apply(try snapshot(sequence: 99, stamp: 1)))
        XCTAssertEqual(store.latest?.sessionStamp, SessionStamp(2))
    }

    func testNewestSequenceIsAppliedAndObserversSeeIt() throws {
        let store = FeedScreenStore(intentHandler: { _ in })
        var observed: [UInt64] = []
        let token = store.observe { observed.append($0.sequence) }

        XCTAssertTrue(store.apply(try snapshot(sequence: 1)))
        XCTAssertTrue(store.apply(try snapshot(sequence: 2)))
        XCTAssertEqual(observed, [1, 2])

        store.removeObserver(token)
        XCTAssertTrue(store.apply(try snapshot(sequence: 3)))
        XCTAssertEqual(observed, [1, 2], "a removed observer must not be called again")
    }

    func testTeardownReleasesStateAndStopsDelivery() throws {
        let store = FeedScreenStore(intentHandler: { _ in })
        XCTAssertTrue(store.apply(try snapshot(sequence: 1)))
        store.teardown()

        XCTAssertNil(store.latest)
        XCTAssertNil(store.contextKey)
        XCTAssertTrue(store.apply(try snapshot(sequence: 1, stamp: 9)), "after teardown the store starts clean")
    }

    func testIntentsAreForwardedUnchanged() throws {
        var received: [FeedSessionIntent] = []
        let store = FeedScreenStore { received.append($0) }
        _ = store.apply(try snapshot(sequence: 1))

        store.send(.viewportChanged(firstVisibleOrdinal: 0, lastVisibleOrdinal: 5, anchor: nil))
        store.send(.centerCrossed(cardID: try PublicationCardID(1), direction: 1))
        store.send(.refresh)

        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(
            received[0],
            .viewportChanged(firstVisibleOrdinal: 0, lastVisibleOrdinal: 5, anchor: nil)
        )
        XCTAssertEqual(received[2], .refresh)
    }

    // MARK: - PR-07: the store is the last place a stale result is stopped

    /// A snapshot for the context the screen no longer expects never paints, whatever its sequence.
    /// The counter is the observability the plan asks for (`stale rejection` in §16).
    func testSnapshotForAnUnexpectedContextIsRejectedAndCounted() throws {
        let store = FeedScreenStore(intentHandler: { _ in })
        XCTAssertTrue(store.apply(try snapshot(sequence: 1, context: "main")))

        store.expect(contextKey: "source|alpha|SourceFeedPlan")
        XCTAssertFalse(
            store.apply(try snapshot(sequence: 2, context: "main")),
            "the previous context's snapshot must not paint the new screen"
        )
        XCTAssertEqual(store.rejectedSnapshotCount, 1)
        XCTAssertEqual(store.latest?.sequence, 1, "the visible state is untouched")
        XCTAssertEqual(store.contextKey, "main")

        XCTAssertTrue(store.apply(try snapshot(sequence: 2, context: "source|alpha|SourceFeedPlan")))
        XCTAssertEqual(store.contextKey, "source|alpha|SourceFeedPlan")
    }

    func testEveryStaleSnapshotIsCountedSeparately() throws {
        let store = FeedScreenStore(intentHandler: { _ in })
        XCTAssertTrue(store.apply(try snapshot(sequence: 3, stamp: 2)))
        XCTAssertFalse(store.apply(try snapshot(sequence: 9, stamp: 1)))
        XCTAssertFalse(store.apply(try snapshot(sequence: 2, stamp: 2)))
        XCTAssertFalse(store.apply(try snapshot(sequence: 3, stamp: 2)))
        XCTAssertEqual(store.rejectedSnapshotCount, 3)
        XCTAssertEqual(store.lastAppliedSequence, 3)
    }

    /// The viewport callback carries the anchor the renderer holds and performs no work itself.
    func testSendViewportForwardsTheAnchorWithoutDoingWork() throws {
        var received: [FeedSessionIntent] = []
        let store = FeedScreenStore { received.append($0) }
        let anchor = try FeedWindowAnchor(
            editionID: try EditionID(1),
            cardID: try PublicationCardID(4),
            absoluteOrdinal: 3,
            offsetFraction: 0.25
        )

        store.sendViewport(firstVisibleOrdinal: 3, lastVisibleOrdinal: 6, anchor: anchor)

        XCTAssertEqual(
            received,
            [.viewportChanged(firstVisibleOrdinal: 3, lastVisibleOrdinal: 6, anchor: anchor)]
        )
    }

    func testTeardownAlsoForgetsTheExpectedContext() throws {
        let store = FeedScreenStore(intentHandler: { _ in })
        store.expect(contextKey: "other|scope|Plan")
        XCTAssertFalse(store.apply(try snapshot(sequence: 1)))
        store.teardown()

        XCTAssertTrue(store.apply(try snapshot(sequence: 1)))
        XCTAssertEqual(store.contextKey, "main")
    }
}
