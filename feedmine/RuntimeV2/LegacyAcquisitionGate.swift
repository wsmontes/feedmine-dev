import Foundation

/// Whether the legacy path may issue feed requests in this process (plan §13).
///
/// In `v2Full` the runtime owns acquisition, so the legacy producers are **turned off
/// conditionally** — not deleted, and not rewritten: `legacy` and `mirroredShadow` keep them exactly
/// as they were, because ADR-004 D12's rollback window stays open until PR-17 removes what is retired.
///
/// The gate lives outside the legacy store for the same reason `ShadowMirrorRegistry` does: the
/// producer is a `FeedStore` built by `FeedLoaderProvider.shared` before any screen exists, with no
/// reference to the launch decision and no constructor parameter to thread one through. Installation
/// happens once, at launch, in `RuntimeCompositionRoot.compose`.
///
/// The check sits in exactly one place — `RSSFetcher.fetch`, the only feed transport in the app — so
/// every one of the store's twenty-odd producers (bootstrap, progressive fill, drip, coverage mining,
/// the flush pipeline, refresh, stale refresh, replenishment, shake, the urgent batch, the smart-feed
/// maintenance loop, the search sweep, the import refill, the source and collection surfaces, the
/// region seed, What's New and the onboarding showcase) stops issuing requests without one line
/// changing in `FeedStore`. A gate per producer would be twenty chances to miss one, and the failure
/// mode of missing one is a double fetch — the thing the mode exists to prevent.
///
/// It refuses *requests*, not work. Everything the legacy store does that is not a fetch — OPML
/// loading, taxonomy, hydration, filter restoration, cached-page publication, the image queue — keeps
/// running, because the legacy path is still the owner of every surface this slice did not move.
enum LegacyAcquisitionGate {
    private static let lock = NSLock()
    /// Guarded by `lock`: written once at launch, read on the fetch path.
    nonisolated(unsafe) private static var closed = false
    /// Guarded by `lock`: the refusals since launch, which is how a reader proves the producers were
    /// closed rather than merely idle.
    nonisolated(unsafe) private static var refusals = 0

    /// `true` when the process's mode owns acquisition through the runtime, so no legacy producer may
    /// issue a feed request.
    static var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// How many feed requests the legacy path declined to issue. Counted at the refusal, so a source
    /// that never reached its fetch (because the gate closed before it was scheduled) is not counted.
    static var refusedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return refusals
    }

    /// Closes the legacy producers. Idempotent: a second launch in one process keeps the count.
    static func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// Reopens them. Tests use it to leave the process as they found it; a launch never reopens a
    /// closed gate, because the mode is decided once (plan §13).
    static func open() {
        lock.lock()
        closed = false
        lock.unlock()
    }

    /// Answers whether a feed request may proceed, counting the refusal when it may not.
    static func allowsFeedRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard closed else { return true }
        refusals += 1
        return false
    }
}
