import Foundation
import UIKit

/// Extracted from `CachedAsyncImage.load()` — the full image resolution
/// pipeline without the view lifecycle coupling. Used by
/// `CardPreparationPipeline` to resolve images before cards are published.
///
/// Pipeline: memory cache → disk cache → wait for in-flight download →
/// network download (with retries and URL candidates) → article OG fallback.
///
/// Does NOT include `improveImageIfNeeded` — that post-insertion upgrade
/// pattern is eliminated in the new pipeline. The best available image is
/// resolved upfront.
enum ImageLoader {

    // MARK: - Public API

    /// Resolve an image through all cache + network tiers.
    /// - Parameters:
    ///   - url: The feed-supplied image URL (may be nil for text-only items).
    ///   - articleURL: The article page URL for Open Graph fallback.
    /// - Returns: A downsampled UIImage (already in NSCache), or nil if all
    ///   resolution paths failed.
    static func resolveImage(url: URL?, articleURL: URL?) async -> UIImage? {
        guard let cacheURL = url ?? articleURL,
              url != nil || articleURL.map(ArticleImageResolver.canResolve) == true else {
            return nil
        }

        // Tier 1 + 2: memory + disk cache
        if let cached = await ImageCache.shared.diskImage(for: cacheURL) {
            guard isValidImage(cached) else {
                await ImageCache.shared.evict(url: cacheURL)
                return nil
            }
            return cached
        }

        // Tier 2.5: wait for an in-flight download (prefetcher or another card)
        if await ImageCache.isDownloadInFlight(for: cacheURL) {
            let deadline = Date().addingTimeInterval(3.0)
            if let cached = await ImageCache.shared.waitForInFlightDownload(of: cacheURL, until: deadline) {
                return cached
            }
        }

        // Register this download for deduplication
        await ImageCache.registerDownload(for: cacheURL)
        defer { Task { await ImageCache.unregisterDownload(for: cacheURL) } }

        // Tier 3: network download with URL candidate fallbacks
        if let url {
            for candidate in ImageURLCandidates.candidates(for: url) {
                for attempt in 0..<2 {
                    do {
                        // The URL comes from feed metadata: stream the body and cut it at a ceiling
                        // instead of buffering an unbounded response. Same shape as URLResolver's
                        // boundedDownload — Content-Length checked first, then chunk iteration.
                        var request = URLRequest(url: candidate)
                        request.timeoutInterval = 10
                        let (asyncBytes, response) = try await session.bytes(for: request)
                        if let http = response as? HTTPURLResponse,
                           let declared = Int(http.value(forHTTPHeaderField: "Content-Length") ?? ""),
                           declared > Self.maxImageBytes {
                            break
                        }
                        var data = Data()
                        data.reserveCapacity(256_000)
                        for try await chunk in asyncBytes {
                            data.append(chunk)
                            if data.count >= Self.maxImageBytes { break }
                        }
                        if let http = response as? HTTPURLResponse,
                           !(200...299).contains(http.statusCode) { break }
                        guard isValidImageData(data) else { break }
                        if let downsampled = await ImageCache.shared.setImage(data: data, for: cacheURL) {
                            return downsampled
                        }
                        break
                    } catch {
                        if attempt == 0 {
                            try? await Task.sleep(for: .milliseconds(500))
                            continue
                        }
                    }
                }
            }
        }

        // Tier 4: article Open Graph / Twitter card fallback
        if let articleURL,
           let replacement = await loadArticleImage(articleURL: articleURL, replacing: url),
           let downsampled = await ImageCache.shared.setImage(data: replacement.data, for: cacheURL) {
            return downsampled
        }

        return nil
    }

    // MARK: - Private

    /// Ceiling for a feed-supplied image body. Generous for real artwork (which is
    /// downsampled right after) and bounded, so a hostile or broken feed cannot make the
    /// app buffer an arbitrarily large response.
    private static let maxImageBytes = 12_000_000

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 3
        config.urlCache = URLCache(memoryCapacity: 4_194_304, diskCapacity: 20_971_520)
        return URLSession(configuration: config)
    }()

    private static func isValidImage(_ image: UIImage) -> Bool {
        image.size.width >= 4 && image.size.height >= 4
    }

    private static nonisolated func isValidImageData(_ data: Data) -> Bool {
        guard data.count > 64 else { return false }
        // Quick structural check: valid JPEG, PNG, GIF, or WebP header
        let prefix = data.prefix(4)
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return true }      // JPEG
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true } // PNG
        if prefix.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true } // GIF
        if prefix.starts(with: [0x52, 0x49, 0x46, 0x46]) { return true } // WebP/RIFF
        return false
    }

    /// Fetch article page HTML, extract OG/Twitter image candidates, and
    /// download the first displayable one. Cached under the article URL
    /// so subsequent renders and launches are cheap.
    private static func loadArticleImage(
        articleURL: URL,
        replacing currentURL: URL?
    ) async -> (data: Data, source: String)? {
        guard ArticleImageResolver.canResolve(articleURL) else { return nil }
        let candidates = await ArticleImageResolver.shared.imageURLs(
            for: articleURL, replacing: currentURL
        )
        guard !candidates.isEmpty else { return nil }

        if let result = await ImageUpgradePolicy.firstDisplayable(from: candidates, session: session) {
            return (result.data, "article-og")
        }
        return nil
    }
}
