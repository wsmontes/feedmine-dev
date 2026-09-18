import Foundation

/// Backward-compatible status for code that only needs a simple pass/fail signal.
enum FeedFetchStatus: Sendable, Equatable, CaseIterable {
    case success
    case empty
    case failed
}

struct FeedFetchResult: Sendable {
    let source: FeedSource
    let items: [FeedItem]
    let outcome: FeedFetchOutcome
    /// Wall-clock response time in milliseconds (HTTP + parse).
    /// Nil for pre-existing results that weren't timed.
    var elapsedMs: Double?

    /// Convenience status for backward compatibility during migration.
    var status: FeedFetchStatus {
        switch outcome {
        case .modifiedWithNewItems: return .success
        case .modifiedWithoutNewItems: return .empty
        case .notModified: return .success  // not a failure
        case .failed: return .failed
        case .throttled: return .failed     // temporary block → treat as failed
        case .legacyProducerClosed: return .empty  // no request was made and nothing came back
        }
    }
}
