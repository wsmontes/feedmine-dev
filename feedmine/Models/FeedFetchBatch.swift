import Foundation

struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int      // sources that produced new items
    let failedSourceCount: Int       // sources that failed (network/parse)
    let emptySourceCount: Int        // sources with zero items but 200 OK
    let notModifiedCount: Int        // sources that returned 304
    let throttledCount: Int          // sources that returned 429/503
    /// Sources whose request the legacy producers refused to make because this process's mode owns
    /// acquisition. They are counted here and deliberately absent from `sourceOutcomes`: a request that
    /// was never issued is neither a success nor a failure, and the demand ledger must not treat it as
    /// a refill that happened.
    var gatedSourceCount: Int = 0
    /// Per-source outcome, keyed by source URL.
    let sourceOutcomes: [String: FeedFetchOutcome]
}
