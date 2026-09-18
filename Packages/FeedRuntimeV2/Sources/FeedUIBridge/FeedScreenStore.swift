import Foundation
import FeedDomain

/// Observable state for one feed screen.
///
/// Holds the newest snapshot only: snapshots are a latest-value stream, while durable intents and
/// actions travel on their own reliable path (plan §11). The presentation vocabulary itself lives in
/// `FeedDomain/Presentation` so the session and the screen cannot drift apart.
///
/// The store is the last place a stale result can be stopped before it paints, so it rejects on three
/// rules and counts every rejection: an older session stamp, an older sequence within the same
/// session, and a snapshot for a context the screen no longer expects (a context switch that raced the
/// previous context's composition).
@MainActor
public final class FeedScreenStore {
    public private(set) var latest: FeedPresentationSnapshot?
    public private(set) var contextKey: String?
    /// The newest sequence that was applied, for observability (plan §16).
    public private(set) var lastAppliedSequence: UInt64?
    /// Rejected snapshots: stale stamp, stale sequence or unexpected context.
    public private(set) var rejectedSnapshotCount: Int = 0

    private var lastApplied: (stamp: SessionStamp, sequence: UInt64)?
    private var expectedContextKey: String?
    private var observers: [UUID: @MainActor (FeedPresentationSnapshot) -> Void] = [:]
    private let intentHandler: @MainActor (FeedSessionIntent) -> Void

    public init(intentHandler: @escaping @MainActor (FeedSessionIntent) -> Void) {
        self.intentHandler = intentHandler
    }

    /// Declares the context the screen now expects, before the switch's snapshot can arrive.
    ///
    /// The store does not adopt a snapshot for another context on its own: a context switch is an
    /// explicit intent, and the *newest* applied state must always belong to the screen the user is
    /// on (ADR-002 D12).
    public func expect(contextKey: String) {
        expectedContextKey = contextKey
    }

    /// Applies a snapshot if it is newer than the current one for the same session and context.
    ///
    /// - Returns: `true` when the snapshot became the visible state.
    @discardableResult
    public func apply(_ snapshot: FeedPresentationSnapshot) -> Bool {
        if let expectedContextKey, snapshot.contextKey != expectedContextKey {
            rejectedSnapshotCount += 1
            return false
        }
        if let lastApplied {
            guard snapshot.sessionStamp >= lastApplied.stamp else {
                rejectedSnapshotCount += 1
                return false
            }
            if snapshot.sessionStamp == lastApplied.stamp, snapshot.sequence <= lastApplied.sequence {
                rejectedSnapshotCount += 1
                return false
            }
        }
        lastApplied = (snapshot.sessionStamp, snapshot.sequence)
        lastAppliedSequence = snapshot.sequence
        latest = snapshot
        contextKey = snapshot.contextKey
        for observer in observers.values { observer(snapshot) }
        return true
    }

    @discardableResult
    public func observe(_ body: @escaping @MainActor (FeedPresentationSnapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = body
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    /// The reliable intent path: a small value the session reduces, never work done here.
    public func send(_ intent: FeedSessionIntent) {
        intentHandler(intent)
    }

    /// Reports the viewport with the anchor the renderer currently holds.
    ///
    /// The callback performs no selection, no fetch and no decode: it emits one observation, which is
    /// what the scroll path is allowed to do (plan §11, ADR-007 H-16).
    public func sendViewport(
        firstVisibleOrdinal: Int,
        lastVisibleOrdinal: Int,
        anchor: FeedWindowAnchor? = nil
    ) {
        intentHandler(.viewportChanged(
            firstVisibleOrdinal: firstVisibleOrdinal,
            lastVisibleOrdinal: lastVisibleOrdinal,
            anchor: anchor
        ))
    }

    /// Called when the screen goes away: no subscribers, no retained snapshot.
    public func teardown() {
        observers.removeAll()
        latest = nil
        lastApplied = nil
        lastAppliedSequence = nil
        contextKey = nil
        expectedContextKey = nil
    }
}
