import UIKit

/// Pre-downloads images into ImageCache so CachedAsyncImage renders instantly.
/// Deduplicates in-flight requests via the shared ``ImageDownloadTracker`` and
/// caps concurrent downloads at 16.
actor ImagePrefetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 60 * 1024 * 1024)
        self.session = URLSession(configuration: config)
    }

    /// Prefetch with priority ordering: priorityURLs download first, then the rest.
    /// Deduplicates against in-flight URLs and cache.
    func prefetch(urls: [String], priorityURLs: [String] = []) async {
        let all = (priorityURLs + urls).compactMap { URL(string: $0) }
        guard !all.isEmpty else { return }

        // Filter out cached or already-in-flight (shared tracker so cards
        // can also wait).  Uses nonisolated static checks to avoid MainActor
        // hops per URL.
        var toFetch: [URL] = []
        for url in all {
            if ImageCache.hasCachedImageData(for: url) { continue }
            if await ImageCache.isDownloadInFlight(for: url) { continue }
            if toFetch.contains(url) { continue }
            toFetch.append(url)
        }
        guard !toFetch.isEmpty else { return }

        // Ownership handshake, not just a de-duplication hint: `registerDownload`
        // answers `false` when another path (a card's resolution, another
        // prefetch) already holds the URL. Downloading anyway sent a second
        // request for the same bytes, and the unconditional unregister in
        // `download(_:)` cleared the *other* owner's mark, which let a third
        // caller start a duplicate it was meant to avoid. Only the URLs this
        // call registered are kept — and only they are unregistered later.
        var owned: [URL] = []
        for url in toFetch {
            if await ImageCache.registerDownload(for: url) { owned.append(url) }
        }
        guard !owned.isEmpty else { return }

        // Sliding-window concurrency: keep up to `maxConcurrent` downloads in
        // flight and refill each freed slot immediately. The previous fixed
        // batches of 8 waited for the slowest download in each batch (up to the
        // 20s resource timeout) before starting the next batch, so one slow
        // image stalled the rest. Every URL is still processed, so download()'s
        // defer clears it from inFlightURLs.
        let maxConcurrent = 16
        await withTaskGroup(of: Void.self) { group in
            var iterator = owned.makeIterator()
            var started = 0
            while started < maxConcurrent, let url = iterator.next() {
                group.addTask { await self.download(url) }
                started += 1
            }
            while await group.next() != nil {
                if let url = iterator.next() {
                    group.addTask { await self.download(url) }
                }
            }
        }
    }

    /// Only ever called for URLs this prefetch registered (see `prefetch(urls:)`),
    /// so the `defer` removes a mark this call owns.
    private func download(_ url: URL) async {
        defer { Task { await ImageCache.unregisterDownload(for: url) } }
        for candidate in ImageURLCandidates.candidates(for: url) {
            do {
                let data = try await downloadBounded(candidate)
                guard UIImage(data: data) != nil else { continue }
                // Cache fallback bytes under the requested URL so the view's
                // normal memory/disk lookup finds them.
                await ImageCache.shared.setImage(data: data, for: url)
                return
            } catch {
                continue
            }
        }
    }

    /// Ceiling for one prefetched body. The resolution path (`MediaAssetStore`)
    /// already refuses to buffer more than this; a page-supplied URL must not
    /// get an unbounded buffer just because this call is only a prefetch.
    private static let maxImageBytes = 12_000_000

    private enum PrefetchError: Error {
        case badStatus
        case tooLarge
    }

    /// Stream the body and stop at the ceiling instead of buffering whatever the
    /// response announces.
    private func downloadBounded(_ url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw PrefetchError.badStatus
        }
        var data = Data()
        for try await chunk in bytes {
            data.append(chunk)
            if data.count >= Self.maxImageBytes { throw PrefetchError.tooLarge }
        }
        return data
    }

    /// Resolve article-page artwork (Open Graph / Twitter / srcset) and cache
    /// it under the article URL so CachedAsyncImage finds it on first render.
    /// Returns true if an image was found and cached, false if none available.
    @discardableResult
    func prefetchArticleImage(for articleURL: URL) async -> Bool {
        let candidates = await ArticleImageResolver.shared.imageURLs(
            for: articleURL,
            replacing: nil
        )
        guard let best = await ImageUpgradePolicy.firstDisplayable(
            from: candidates,
            session: session
        ) else { return false }
        await ImageCache.shared.setImage(data: best.data, for: articleURL)
        return true
    }
}
