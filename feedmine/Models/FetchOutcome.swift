import Foundation

// MARK: - HTTP-level outcome (from FeedHTTPSync)

enum HTTPOutcome: Sendable {
    case notModified
    case success(Data)
    case throttled(until: Date)
    case failed(Error)
}

/// Returned by FeedHTTPSync.fetch() — raw HTTP result before parsing.
struct FetchHTTPResult: Sendable {
    let data: Data?
    let outcome: HTTPOutcome
    let updatedValidators: HTTPValidators
    let canonicalURL: String?
}

// MARK: - Feed-level outcome (from RSSFetcher)

enum FeedFetchOutcome: Sendable, Equatable {
    case notModified
    case modifiedWithNewItems([FeedItem], validators: HTTPValidators)
    case modifiedWithoutNewItems(validators: HTTPValidators)
    case failed(Error)
    case throttled(until: Date)
    /// The request was never made: this process's mode owns acquisition, so the legacy producers are
    /// closed (`LegacyAcquisitionGate`).
    ///
    /// It is deliberately not `.failed`: nothing went wrong, no endpoint was contacted, and a failure
    /// here would write a source-health penalty and move the adaptive backoff for a request that does
    /// not exist. It is deliberately not `.notModified` either, which would claim the endpoint
    /// confirmed a baseline nobody asked about. It is its own state, and every consumer either ignores
    /// it or counts it as a closed producer.
    case legacyProducerClosed

    /// True if the outcome is a failure (network/parse error).
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    // Equatable conformance for .failed (Error is not Equatable)
    static func == (lhs: FeedFetchOutcome, rhs: FeedFetchOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.notModified, .notModified): return true
        case (.modifiedWithNewItems(let lItems, _), .modifiedWithNewItems(let rItems, _)):
            return lItems == rItems
        case (.modifiedWithoutNewItems, .modifiedWithoutNewItems): return true
        case (.failed, .failed): return true  // approximate — errors aren't Equatable
        case (.throttled(let lDate), .throttled(let rDate)): return lDate == rDate
        case (.legacyProducerClosed, .legacyProducerClosed): return true
        default: return false
        }
    }
}
