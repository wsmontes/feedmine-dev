import Foundation

/// The one HTTP call a feed fetch makes. `RSSFetcher` sends through this rather than through a
/// concrete `FeedHTTPSync`, so a test can script and count requests without a network — `URLProtocol`
/// registration does not reach the fetcher's sessions (`docs/runtime-v2/baseline.md` §8.8.3).
protocol FeedHTTPTransport: Sendable {
    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult
}

/// The shipping transport. Its `fetch` is actor-isolated, which is what the protocol's `async`
/// requirement admits: the call hops to the actor rather than running on the caller.
extension FeedHTTPSync: FeedHTTPTransport {}

/// Actor responsible for all HTTP-level feed fetching semantics:
/// conditional GET (ETag/If-None-Match, Last-Modified/If-Modified-Since),
/// 304 Not Modified handling, Cache-Control/Expires extraction,
/// Retry-After parsing, and redirect canonical URL resolution.
actor FeedHTTPSync {
    private let session: URLSession

    /// Shared headers for all feed requests.
    private static let requestHeaders: [String: String] = [
        "User-Agent": "FeedMine/1.0 (https://feedmine.app/bot)",
        "Accept": "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml;q=0.9"
    ]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cache = URLCache(memoryCapacity: 4_194_304, diskCapacity: 20_971_520)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = true
            config.allowsCellularAccess = true
            config.httpMaximumConnectionsPerHost = 2
            config.urlCache = cache
            config.httpAdditionalHeaders = Self.requestHeaders
            self.session = URLSession(configuration: config)
        }
    }

    /// Fetch a feed with conditional GET semantics.
    /// - Parameters:
    ///   - source: The feed source to fetch.
    ///   - validators: Previously-stored HTTP validators for this source.
    /// - Returns: The HTTP result with (possibly empty) data, outcome, and updated validators.
    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult {
        guard !Task.isCancelled else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(CancellationError()),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }

        guard let originalURL = URL(string: source.url) else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(URLError(.badURL)),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }

        // Upgrade http:// → https:// automatically.
        // ATS blocks URLSession HTTP connections (NSAllowsArbitraryLoadsForMedia
        // only exempts AVFoundation). Most HTTP feeds in the catalog (Blogspot,
        // Feedburner, etc.) serve the same content over HTTPS — the catalog just
        // wasn't compiled with canonical HTTPS URLs. This upgrade makes those
        // feeds work without per-domain ATS exceptions.
        let url: URL = {
            guard originalURL.scheme == "http" else { return originalURL }
            var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url ?? originalURL
        }()

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        // Conditional GET headers
        if let etag = validators.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (asyncBytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return FetchHTTPResult(
                    data: nil,
                    outcome: .failed(URLError(.badServerResponse)),
                    updatedValidators: validators,
                    canonicalURL: nil
                )
            }

            var updated = validators
            updated.lastFetchAt = Date()

            switch httpResponse.statusCode {
            case 304:
                updated = extractValidators(from: httpResponse, into: updated)
                updated.lastOutcome = .notModified
                return FetchHTTPResult(
                    data: nil,
                    outcome: .notModified,
                    updatedValidators: updated,
                    canonicalURL: nil
                )

            case 429, 503:
                let retryAfter = parseRetryAfter(from: httpResponse)
                updated.retryAfter = retryAfter
                updated.lastOutcome = .throttled
                return FetchHTTPResult(
                    data: nil,
                    outcome: .throttled(until: retryAfter),
                    updatedValidators: updated,
                    canonicalURL: nil
                )

            case 200:
                // Redirects (301/302/307/308) are followed transparently by
                // URLSession, so only the final response reaches this branch;
                // httpResponse.url is the resolved canonical URL. Note the
                // http→https upgrade above applies to the initial request only —
                // a redirect back to http is likewise followed by URLSession.
                // Stream body with a hard ceiling to prevent a malicious or
                // misconfigured endpoint from exhausting memory. 20 MB covers
                // even the chattiest daily RSS feeds while rejecting accidental
                // non-feed responses (HTML dumps, binaries).
                // Buffered chunking: accumulate bytes into a 16 KB staging
                // buffer before appending to the main accumulator, to reduce
                // per-byte allocation overhead vs. the old element-per-await loop.
                let maxFeedBytes = 20_971_520 // 20 MB
                var accumulator = Data()
                accumulator.reserveCapacity(1_048_576) // 1 MB initial
                let chunkSize = 16_384 // 16 KB
                var buffer = Data(capacity: chunkSize)
                for try await byte in asyncBytes {
                    buffer.append(byte)
                    if buffer.count >= chunkSize {
                        guard accumulator.count + buffer.count <= maxFeedBytes else {
                            throw URLError(.dataLengthExceedsMaximum)
                        }
                        accumulator.append(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                // Flush any remaining bytes in the buffer.
                if !buffer.isEmpty {
                    guard accumulator.count + buffer.count <= maxFeedBytes else {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    accumulator.append(buffer)
                }

                updated = extractValidators(from: httpResponse, into: updated)

                let canonicalURL = httpResponse.url?.absoluteString
                return FetchHTTPResult(
                    data: accumulator,
                    outcome: .success(accumulator),
                    updatedValidators: updated,
                    canonicalURL: canonicalURL
                )

            default:
                updated.lastOutcome = .failed
                return FetchHTTPResult(
                    data: nil,
                    outcome: .failed(URLError(.badServerResponse)),
                    updatedValidators: updated,
                    canonicalURL: nil
                )
            }

        } catch is CancellationError {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(CancellationError()),
                updatedValidators: validators,
                canonicalURL: nil
            )
        } catch let error as URLError where error.code == .cancelled {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(error),
                updatedValidators: validators,
                canonicalURL: nil
            )
        } catch {
            var updated = validators
            updated.lastFetchAt = Date()
            updated.lastOutcome = .failed
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(error),
                updatedValidators: updated,
                canonicalURL: nil
            )
        }
    }

    // MARK: - Private

    /// Extract HTTP validators from a 200/304 response into the mutable validators struct.
    private func extractValidators(from response: HTTPURLResponse, into validators: HTTPValidators) -> HTTPValidators {
        var v = validators

        if let etag = response.value(forHTTPHeaderField: "ETag") {
            v.etag = etag
        }
        if let lastMod = response.value(forHTTPHeaderField: "Last-Modified") {
            v.lastModified = lastMod
        }
        if let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") {
            v.cacheControl = HTTPValidators.ParsedCacheControl.parse(cacheControl)
        }
        if let expiresStr = response.value(forHTTPHeaderField: "Expires") {
            v.expires = Self.httpDateFormatter.date(from: expiresStr)
        }

        return v
    }

    /// Parse Retry-After header: either seconds or HTTP-date.
    /// Clamped to [0, 24h] to prevent a feed from being permanently
    /// throttled by an unreasonable value (e.g. Retry-After: 9999999999).
    private func parseRetryAfter(from response: HTTPURLResponse) -> Date {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else {
            return Date().addingTimeInterval(60) // default 60s
        }

        let maxRetry: TimeInterval = 86_400 // 24 hours

        // Try seconds first
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            let clamped = min(max(0, seconds), maxRetry)
            return Date().addingTimeInterval(clamped)
        }

        // Try HTTP-date
        let formatter = Self.retryAfterDateFormatter
        if let date = formatter.date(from: header) {
            let seconds = date.timeIntervalSinceNow
            let clamped = min(max(0, seconds), maxRetry)
            return Date().addingTimeInterval(clamped)
        }

        return Date().addingTimeInterval(60) // unparseable → default 60s
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let retryAfterDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
