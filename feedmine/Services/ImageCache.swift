import SwiftUI
import OSLog

enum ImageURLCandidates {
    nonisolated static func candidates(for url: URL) -> [URL] {
        guard url.host?.lowercased() == "img.youtube.com",
              url.path.hasSuffix("/sddefault.jpg") else { return [url] }
        let fallback = url.absoluteString.replacingOccurrences(
            of: "/sddefault.jpg",
            with: "/hqdefault.jpg"
        )
        guard let fallbackURL = URL(string: fallback), fallbackURL != url else { return [url] }
        return [url, fallbackURL]
    }
}

enum ImageUpgradePolicy {
    nonisolated static let maxDownloadBytes = 4 * 1024 * 1024

    nonisolated static func needsUpgrade(_ size: CGSize) -> Bool {
        size.width < 480 || size.height < 240
    }

    nonisolated static func isMaterialImprovement(candidate: CGSize, over current: CGSize) -> Bool {
        candidate.width >= 480
        && candidate.height >= 240
        && candidate.width * candidate.height >= current.width * current.height * 4
    }

    nonisolated static func imagePixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    static func firstImprovement(
        from candidates: [URL],
        over currentSize: CGSize,
        session: URLSession
    ) async -> (url: URL, data: Data)? {
        for candidate in candidates {
            do {
                let (bytes, response) = try await session.bytes(from: candidate)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) { continue }
                let expected = response.expectedContentLength
                if expected > maxDownloadBytes { continue }

                var data = Data()
                data.reserveCapacity(expected > 0 ? min(Int(expected), maxDownloadBytes) : 256 * 1024)
                var exceededLimit = false
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maxDownloadBytes {
                        exceededLimit = true
                        break
                    }
                }
                guard !exceededLimit,
                      let size = imagePixelSize(data),
                      isMaterialImprovement(candidate: size, over: currentSize) else { continue }
                return (candidate, data)
            } catch {
                continue
            }
        }
        return nil
    }

    static func firstDisplayable(
        from candidates: [URL],
        session: URLSession
    ) async -> (url: URL, data: Data)? {
        for candidate in candidates {
            do {
                let (bytes, response) = try await session.bytes(from: candidate)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) { continue }
                let expected = response.expectedContentLength
                if expected > maxDownloadBytes { continue }

                var data = Data()
                data.reserveCapacity(expected > 0 ? min(Int(expected), maxDownloadBytes) : 256 * 1024)
                var exceededLimit = false
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > maxDownloadBytes {
                        exceededLimit = true
                        break
                    }
                }
                guard !exceededLimit, let size = imagePixelSize(data) else { continue }
                let shortSide = min(size.width, size.height)
                let longSide = max(size.width, size.height)
                guard shortSide >= 180, longSide >= 480 else { continue }
                return (candidate, data)
            } catch {
                continue
            }
        }
        return nil
    }
}

// MARK: - Image Pipeline Logging

enum ImageLog {
    private static let logger = Logger(subsystem: "com.feedmine.app", category: "images")

    static func cacheHit(_ url: URL, source: String) {
        logger.debug("Cache hit: \(url.lastPathComponent, privacy: .public) from \(source, privacy: .public)")
    }
    static func cacheMiss(_ url: URL) {
        logger.debug("Cache miss: \(url.lastPathComponent, privacy: .public)")
    }
    static func downloadFailed(_ url: URL, error: Error) {
        logger.warning("Download failed: \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
    }
    static func downloadSuccess(_ url: URL, size: Int) {
        logger.debug("Download OK: \(url.lastPathComponent, privacy: .public) — \(size) bytes")
    }
    static func httpError(_ url: URL, status: Int) {
        // Log host + hash only — absoluteString may carry tokens, signed
        // parameters, or campaign identifiers that should never appear in
        // plaintext logs (even local ones).
        logger.warning("HTTP \(status): host=\(url.host ?? "?", privacy: .public) path=\(url.path, privacy: .private(mask: .hash))")
    }
    static func invalidImage(_ url: URL, reason: String) {
        logger.warning("Invalid image: \(url.lastPathComponent, privacy: .public) — \(reason, privacy: .public)")
    }
    static func downsampleFailed(_ url: URL) {
        logger.error("Downsample failed: \(url.lastPathComponent, privacy: .public)")
    }
    static func diskWriteFailed(_ url: URL) {
        logger.error("Disk write failed: \(url.lastPathComponent, privacy: .public)")
    }
    static func articleResolveFailed(_ url: URL, reason: String) {
        logger.warning("Article resolve failed: \(url.host ?? "?", privacy: .public) — \(reason, privacy: .public)")
    }
    static func articleResolveSuccess(_ url: URL, imageCount: Int) {
        logger.debug("Article resolve OK: \(url.host ?? "?", privacy: .public) — \(imageCount) images")
    }
    static func prefetchFailed(_ url: URL, reason: String) {
        logger.warning("Prefetch failed: \(url.lastPathComponent, privacy: .public) — \(reason, privacy: .public)")
    }
    static func trackerLeak(_ url: URL) {
        logger.warning("Download tracker leak: \(url.lastPathComponent, privacy: .public) — entry timed out")
    }
    static func retry(_ url: URL, attempt: Int) {
        logger.debug("Retry \(attempt): \(url.lastPathComponent, privacy: .public)")
    }
    static func allFailed(_ urls: [URL]) {
        logger.error("All image candidates failed: \(urls.map { $0.lastPathComponent }.joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Timing (the media path used to have none)

    /// One resolution, with where it came from and what it cost. Without this the media path could not
    /// answer "late" vs "never": a card that missed its deadline and a card never asked for looked alike.
    static func resolveTiming(url: URL?, outcome: String, ms: Int, bytes: Int) {
        logger.info("resolve outcome=\(outcome, privacy: .public) ms=\(ms) bytes=\(bytes) host=\(url?.host ?? "?", privacy: .public)")
    }

    /// A published card whose image missed the deadline and was retried later. `ms` is measured from the
    /// deferred retry's start; the card only shows the image at the next composition (see
    /// `FeedDisplayState`), which is the delay the reader reports.
    static func deferredRetry(itemID: String, ms: Int, gotImage: Bool) {
        logger.info("deferred-retry item=\(itemID, privacy: .private(mask: .hash)) ms=\(ms) image=\(gotImage ? 1 : 0)")
    }

    /// What a card was published with, and how long that decision took.
    static func prepareOutcome(itemID: String, outcome: String, ms: Int, index: Int) {
        logger.info("prepare item=\(itemID, privacy: .private(mask: .hash)) index=\(index) outcome=\(outcome, privacy: .public) ms=\(ms)")
    }
}

/// Finds article artwork only when a visible card has already proven that its
/// feed image is too small. Requests are bounded and deduplicated, so normal
/// images never cause an article-page fetch.
actor ArticleImageResolver {
    static let shared = ArticleImageResolver()

    private let session: URLSession
    private var resolved: [String: [URL]] = [:]
    private var misses: [String: Date] = [:]       // TTL-based, not permanent
    private var inFlightKeys: Set<String> = []
    private var activeRequests = 0
    private var htmlByteCounts: [String: Int] = [:]
    private static let maxHTMLBytes = 192 * 1024
    private static let maxConcurrentRequests = 4
    private static let missTTL: TimeInterval = 300  // 5 minutes — retry after expiry

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6
            config.timeoutIntervalForResource = 8
            config.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: config)
        }
    }

    nonisolated static func canResolve(_ articleURL: URL) -> Bool {
        guard ["http", "https"].contains(articleURL.scheme?.lowercased() ?? ""),
              let host = articleURL.host?.lowercased() else { return false }
        // Google News RSS links render an aggregator shell with Google logos,
        // not publisher artwork. Fetching it wastes bandwidth and creates the
        // repeated-image failure this resolver is meant to prevent.
        return host != "news.google.com"
    }

    /// Clear the miss cache for a specific article URL so the next
    /// ``imageURLs(for:replacing:)`` call re-fetches the page instead of
    /// returning early due to the 300-second miss TTL. Called by
    /// ``ImageResolutionQueue`` before each retry attempt.
    func resetMiss(for articleURL: URL) {
        misses.removeValue(forKey: articleURL.absoluteString)
    }

    func imageURLs(for articleURL: URL, replacing currentURL: URL? = nil) async -> [URL] {
        let key = articleURL.absoluteString
        if let cached = resolved[key] { return cached.filter { $0 != currentURL } }
        guard !(misses[key].map { Date().timeIntervalSince($0) < Self.missTTL } ?? false),
              Self.canResolve(articleURL) else { return [] }

        while inFlightKeys.contains(key) || activeRequests >= Self.maxConcurrentRequests {
            if Task.isCancelled { return [] }
            try? await Task.sleep(for: .milliseconds(25))
            if let cached = resolved[key] { return cached.filter { $0 != currentURL } }
            if (misses[key].map { Date().timeIntervalSince($0) < Self.missTTL } ?? false) { return [] }
        }

        activeRequests += 1
        inFlightKeys.insert(key)
        defer {
            activeRequests -= 1
            inFlightKeys.remove(key)
        }
        do {
            var request = URLRequest(url: articleURL)
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.setValue("feedmine/1.0 image-enrichment", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                misses[key] = Date()
                return []
            }
            let contentType = response.mimeType?.lowercased() ?? ""
            guard contentType.isEmpty || contentType.contains("html") else {
                misses[key] = Date()
                return []
            }

            var data = Data()
            data.reserveCapacity(Self.maxHTMLBytes)
            for try await byte in bytes {
                data.append(byte)
                if data.count >= Self.maxHTMLBytes { break }
            }
            htmlByteCounts[key] = data.count
            let html = String(decoding: data, as: UTF8.self)
            let responseURL = response.url ?? articleURL
            let candidates = Self.articleImageURLs(in: html, baseURL: responseURL)
                .filter { $0 != currentURL }
            guard !candidates.isEmpty else {
                misses[key] = Date()
                return []
            }
            resolved[key] = candidates
            return candidates
        } catch {
            misses[key] = Date()
            return []
        }
    }

    func htmlByteCount(for articleURL: URL) -> Int? {
        htmlByteCounts[articleURL.absoluteString]
    }

    nonisolated static func articleImageURLs(in html: String, baseURL: URL) -> [URL] {
        let metaTags = metaTagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var ranked: [(priority: Int, url: URL)] = []
        for tagMatch in metaTags {
            guard let tagRange = Range(tagMatch.range, in: html) else { continue }
            let tag = String(html[tagRange])
            var attributes: [String: String] = [:]
            for match in metaAttributeRegex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let nameRange = Range(match.range(at: 1), in: tag),
                      let valueRange = Range(match.range(at: 2), in: tag) else { continue }
                attributes[String(tag[nameRange]).lowercased()] = decodeHTMLEntities(String(tag[valueRange]))
            }
            let property = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
            let priority: Int
            switch property {
            case "og:image", "og:image:url", "og:image:secure_url": priority = 0
            case "twitter:image", "twitter:image:src": priority = 1
            default: continue
            }
            guard let content = attributes["content"],
                  let url = URL(string: content, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            ranked.append((priority, url))
        }
        let metaURLs = ranked.sorted { $0.priority < $1.priority }.map(\.url)
        let responsiveCandidates = responsiveImageCandidates(in: html, baseURL: baseURL)
        var ordered: [URL] = []
        for metaURL in metaURLs {
            if let responsive = preferredResponsiveVariant(for: metaURL, candidates: responsiveCandidates) {
                ordered.append(responsive)
            }
            ordered.append(metaURL)
        }
        // Some publishers omit social metadata but expose a useful responsive
        // hero in the article body. Prefer the smallest declared variant that
        // comfortably covers an iPhone card, avoiding multi-megapixel originals.
        let standaloneResponsive = responsiveCandidates
            .filter { $0.width >= 720 && $0.width <= 1_600 }
            .sorted { $0.width < $1.width }
        ordered.append(contentsOf: standaloneResponsive.map(\.url))
        ordered.append(contentsOf: jsonLDImageURLs(in: html, baseURL: baseURL))
        if metaURLs.isEmpty && standaloneResponsive.isEmpty {
            ordered.append(contentsOf: plainImageURLs(in: html, baseURL: baseURL))
        }
        var seen = Set<String>()
        return ordered.compactMap { url in
            guard !isLikelyDecorative(url) else { return nil }
            return seen.insert(url.absoluteString).inserted ? url : nil
        }
    }

    private nonisolated static func jsonLDImageURLs(in html: String, baseURL: URL) -> [URL] {
        jsonImageRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: html) else { return nil }
            let value = decodeHTMLEntities(String(html[valueRange]))
                .replacingOccurrences(of: #"\/"#, with: "/")
            return URL(string: value, relativeTo: baseURL)?.absoluteURL
        }
    }

    private nonisolated static func plainImageURLs(in html: String, baseURL: URL) -> [URL] {
        imageTagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { tagMatch in
            guard let tagRange = Range(tagMatch.range, in: html) else { return nil }
            let tag = String(html[tagRange])
            let attributes = imageSourceAttributeRegex.matches(
                in: tag,
                range: NSRange(tag.startIndex..., in: tag)
            ).compactMap { match -> (String, String)? in
                guard let nameRange = Range(match.range(at: 1), in: tag),
                      let valueRange = Range(match.range(at: 2), in: tag) else { return nil }
                return (String(tag[nameRange]).lowercased(), String(tag[valueRange]))
            }
            let preferredNames = ["data-lazy-src", "data-original", "data-src", "src"]
            guard let rawValue = preferredNames.lazy.compactMap({ name in
                attributes.first(where: { $0.0 == name })?.1
            }).first else { return nil }
            let value = decodeHTMLEntities(rawValue)
            return URL(string: value, relativeTo: baseURL)?.absoluteURL
        }
    }

    private nonisolated static func isLikelyDecorative(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased()
        // Narrow markers: only match tiny site identity images, not article artwork.
        // "logo" is too aggressive — many CDNs serve article heroes at /logo/ paths.
        let markers = [
            "favicon", "sprite", "avatar", "emoji", "tracking",
            "spacer", "pixel.gif", "count.gif", "doubleclick", "analytics",
        ]
        // "logo" only when combined with tiny dimensions or site-identity paths
        if value.contains("logo") {
            if value.contains("site-logo") || value.contains("header-logo")
                || value.contains("footer-logo") || value.contains("nav-logo") { return true }
            // Check for tiny dimension patterns like /logo-32x32.png
            if let r = try? Regex(#"[-._](1[6-9]|2[0-9]|3[0-2])x\1"#), value.contains(r) { return true }
            return false  // /logo/ paths without tiny dims are likely article artwork
        }
        return markers.contains(where: value.contains)
    }

    private nonisolated static func responsiveImageCandidates(
        in html: String,
        baseURL: URL
    ) -> [(url: URL, width: Int)] {
        imageTagRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).flatMap { tagMatch -> [(url: URL, width: Int)] in
            guard let tagRange = Range(tagMatch.range, in: html) else { return [] }
            let tag = String(html[tagRange])
            guard let srcsetMatch = srcsetAttributeRegex.firstMatch(
                in: tag,
                range: NSRange(tag.startIndex..., in: tag)
            ), let valueRange = Range(srcsetMatch.range(at: 1), in: tag) else { return [] }
            let srcset = decodeHTMLEntities(String(tag[valueRange]))
            return srcset.split(separator: ",").compactMap { entry in
                let parts = entry.split(whereSeparator: \Character.isWhitespace)
                guard parts.count >= 2,
                      let url = URL(string: String(parts[0]), relativeTo: baseURL)?.absoluteURL else { return nil }
                let descriptor = parts[1]
                if descriptor.last == "w", let width = Int(descriptor.dropLast()) {
                    return (url, width)
                }
                // Density descriptor: "2x" → assume 1x = 480px, so 2x = 960px
                if descriptor.last == "x", let density = Double(descriptor.dropLast()) {
                    return (url, Int(480 * density))
                }
                return nil
            }
        }
    }

    private nonisolated static func preferredResponsiveVariant(
        for metaURL: URL,
        candidates: [(url: URL, width: Int)]
    ) -> URL? {
        let identity = imageIdentity(metaURL)
        let related = candidates.filter { imageIdentity($0.url) == identity }.sorted { $0.width < $1.width }
        guard let preferred = related.first(where: { $0.width >= 960 }) ?? related.last,
              preferred.width >= 720,
              preferred.width <= 1_600 else { return nil }
        return preferred.url
    }

    private nonisolated static func imageIdentity(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(
            of: #"-\d+x\d+$"#,
            with: "",
            options: .regularExpression
        )
    }

    private nonisolated static func decodeHTMLEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private static let metaTagRegex = try! NSRegularExpression(
        pattern: #"<meta\b[^>]*>"#,
        options: .caseInsensitive
    )
    private static let metaAttributeRegex = try! NSRegularExpression(
        pattern: #"\b(property|name|content)\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )
    private static let imageTagRegex = try! NSRegularExpression(
        pattern: #"<(?:img|source)\b[^>]*>"#,
        options: .caseInsensitive
    )
    private static let srcsetAttributeRegex = try! NSRegularExpression(
        pattern: #"\b(?:srcset|data-srcset)\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )
    private static let imageSourceAttributeRegex = try! NSRegularExpression(
        pattern: #"\s(data-lazy-src|data-original|data-src|src)\s*=\s*["']([^"']+)["']"#,
        options: .caseInsensitive
    )
    private static let jsonImageRegex = try! NSRegularExpression(
        pattern: #"["'](?:image|thumbnailUrl)["']\s*:\s*["'](https?:\\?/\\?/[^"']+)["']"#,
        options: .caseInsensitive
    )
}

// MARK: - Download Deduplication

/// Lightweight global actor that tracks which image URLs are currently being
/// downloaded — used by both ``ImagePrefetcher`` and ``CachedAsyncImage`` to
/// avoid racing on the same URL.  When a caller finds its URL already in-flight
/// it waits (briefly) for the cache to be populated instead of starting a
/// duplicate network request.
private actor ImageDownloadTracker {
    private var inFlight: Set<URL> = []

    /// Returns `true` if this call registered the URL; `false` if another
    /// download is already in progress.
    func register(_ url: URL) -> Bool {
        if inFlight.contains(url) { return false }
        inFlight.insert(url)
        return true
    }

    func unregister(_ url: URL) {
        inFlight.remove(url)
    }

    func contains(_ url: URL) -> Bool {
        inFlight.contains(url)
    }
}

private let downloadTracker = ImageDownloadTracker()

// MARK: - ImageCache

/// Two-tier image cache: fast NSCache memory lookup, persistent disk fallback.
/// Images are downsampled via ImageIO before caching — full-res originals never
/// touch memory. Disk cache stores downsampled JPEGs; cold launches decode cheap.
/// Disk cache is capped at 100 MB; oldest files are evicted when exceeded.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL
    private let fileManager = FileManager.default
    private var diskCacheSize: Int = 0
    private static let maxDiskCacheSize = 100 * 1024 * 1024  // 100 MB

    /// Target max pixel dimension for cached images. At 800px we cover
    /// 2× Retina on all iPhones for card-width display (~390 pt × 2 = 780 px).
    nonisolated static let downsampleMaxDimension: CGFloat = 800

    private init() {
        memoryCache.countLimit = 200
        /// 200 MB fits ~80-100 downsampled images (800 px max dimension,
        /// ~2-3 MB each at 4 bytes/pixel), comfortably covering the
        /// 100-item prefetch batch so images survive in memory until their
        /// cards scroll into view.
        memoryCache.totalCostLimit = 200 * 1024 * 1024  // 200 MB

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Warm memory cache off the main actor — disk I/O + decode must not
        // compete with first render. Only the final setObject hops to MainActor.
        Task.detached(priority: .utility) { [weak self] in
            await self?.warmMemoryCache()
        }
    }

    // MARK: - Downsampling

    /// Decode image data at the target pixel dimension using ImageIO.
    /// Thread-safe — can be called from any queue.
    nonisolated static func downsample(data: Data, to maxDimension: CGFloat = downsampleMaxDimension) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Public

    /// Raw image data from disk cache — safe to call from any queue.
    nonisolated func cachedImageData(for url: URL) -> Data? {
        let key = cacheKey(for: url)
        let fileURL = diskCacheURL.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// Nonisolated static check — used by ImagePrefetcher actor to avoid
    /// MainActor hops per URL.
    nonisolated static func hasCachedImageData(for url: URL) -> Bool {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let diskURL = caches.appendingPathComponent("ImageCache", isDirectory: true)
        let key = cacheKeyForURL(url)
        let fileURL = diskURL.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: Download Deduplication Helpers

    /// Returns `true` when another caller (prefetcher or another card) is
    /// already downloading this URL.  Callers should wait briefly rather
    /// than starting a duplicate network request.
    nonisolated static func isDownloadInFlight(for url: URL) async -> Bool {
        await downloadTracker.contains(url)
    }

    /// Register a URL as in-flight so other callers (cards) can wait for
    /// it rather than starting a duplicate download.  Always follow with
    /// ``unregisterDownload(for:)`` in a `defer` block.
    /// Returns `false` if another download is already registered.
    @discardableResult
    nonisolated static func registerDownload(for url: URL) async -> Bool {
        await downloadTracker.register(url)
    }

    /// Remove a URL previously registered with ``registerDownload(for:)``.
    nonisolated static func unregisterDownload(for url: URL) async {
        await downloadTracker.unregister(url)
    }

    /// Wait up to *deadline* for an in-flight download of `url` to finish
    /// and populate the cache.  Returns the cached image on success, `nil`
    /// if the download didn't finish in time.
    func waitForInFlightDownload(of url: URL, until deadline: Date) async -> UIImage? {
        repeat {
            if await !downloadTracker.contains(url) {
                // No longer tracked — poll cache one last time
                return await diskImage(for: url)
            }
            if let cached = await diskImage(for: url) {
                return cached
            }
            try? await Task.sleep(for: .milliseconds(120))
        } while Date() < deadline
        return nil
    }

    /// Synchronous memory-cache lookup — safe to call from `body` without
    /// the `.task` round-trip. Returns `nil` for disk-only or uncached images;
    /// callers fall back to ``diskImage(for:)`` for the full two-tier lookup.
    func memoryImage(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)
        return memoryCache.object(forKey: key as NSString)
    }

    /// Synchronous disk-cache read + promote to memory.  Called from
    /// `CachedAsyncImage.body` when the image is on disk but not yet in
    /// NSCache so the image renders in the same frame as the card — no
    /// async `.task` round-trip, no visible placeholder flash.
    /// Blocks the calling thread for ~2-5 ms (50 KB downsampled JPEG);
    /// after promotion the image is in NSCache and subsequent renders
    /// avoid this cost entirely.
    func diskImageSync(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)
        let fileURL = diskCacheURL.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let img = UIImage(data: data) else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        memoryCache.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }

    func diskImage(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        if let img = memoryCache.object(forKey: key as NSString) { return img }
        let fileURL = diskCacheURL.appendingPathComponent(key)
        guard let img = await Task.detached(operation: {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let img = UIImage(data: data) else { return nil as UIImage? }
            return img
        }).value else { return nil }
        // Promote to memory so subsequent synchronous lookups hit NSCache
        // instead of repeating the disk read.
        let cost = Int(img.size.width * img.size.height * 4)
        memoryCache.setObject(img, forKey: key as NSString, cost: cost)
        return img
    }

    /// Legacy path — stores at whatever resolution the caller provides.
    func setImage(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        let fileURL = diskCacheURL.appendingPathComponent(key)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            do {
                try data.write(to: fileURL, options: .atomic)
                await self.didWriteToDisk(bytes: data.count)
            } catch { /* disk full */ }
        }
    }

    /// Store raw image data with automatic downsampling. The CPU-intensive
    /// downsample runs off the main actor; only the NSCache write hops back.
    @discardableResult
    func setImage(data: Data, for url: URL, maxDimension: CGFloat = downsampleMaxDimension) async -> UIImage? {
        let key = cacheKey(for: url)

        // Downsample off the main actor — this is the expensive part
        let task = Task.detached(priority: .utility) {
            Self.downsample(data: data, to: maxDimension)
        }
        guard let downsampled = await task.value else { return nil }

        let cost = Int(downsampled.size.width * downsampled.size.height * 4)
        memoryCache.setObject(downsampled, forKey: key as NSString, cost: cost)

        // Write downsampled JPEG to disk — NOT original data.
        // Awaited so the file is guaranteed to exist on disk when this
        // method returns; subsequent launches find it via diskImageSync.
        let fileURL = diskCacheURL.appendingPathComponent(key)
        await Task.detached(priority: .utility) { [weak self] in
            guard let self,
                  let jpeg = downsampled.jpegData(compressionQuality: 0.85) else { return }
            do {
                try jpeg.write(to: fileURL, options: .atomic)
                await self.didWriteToDisk(bytes: jpeg.count)
            } catch { /* disk full */ }
        }.value
        return downsampled
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        diskCacheSize = 0
    }

    func evict(url: URL) {
        let key = cacheKey(for: url) as NSString
        memoryCache.removeObject(forKey: key)
        let fileURL = diskCacheURL.appendingPathComponent(key as String)
        if fileManager.fileExists(atPath: fileURL.path) {
            let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
            try? fileManager.removeItem(at: fileURL)
            diskCacheSize = max(0, diskCacheSize - size)
        }
    }

    // MARK: - Private

    private nonisolated func cacheKey(for url: URL) -> String {
        "img_\(Self.stableHash(url.absoluteString))"
    }

    /// Duplicated key logic for the static hasCachedImageData path.
    private nonisolated static func cacheKeyForURL(_ url: URL) -> String {
        "img_\(stableHash(url.absoluteString))"
    }

    /// FNV-1a 64-bit — deterministic across launches, unlike String.hashValue.
    private nonisolated static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Two-phase warm: disk I/O + downsample off MainActor, NSCache insert on MainActor.
    /// Phase 1: enumerate all files to compute true disk usage (not just the 50 newest).
    /// Phase 2: warm the 50 most-recent images into the memory cache.
    private func warmMemoryCache() async {
        let (preloaded, totalDiskSize): (
            [(key: String, image: UIImage, byteCount: Int)],
            Int
        ) = await Task.detached {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: self.diskCacheURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey,
                                                                     .totalFileAllocatedSizeKey],
                options: .skipsHiddenFiles
            ) else { return ([], 0) }

            // Phase 1: sum the true disk usage of ALL files.
            // Using totalFileAllocatedSize when available (iOS 14+) because it
            // accounts for block-rounding overhead; fall back to fileSize.
            var totalBytes = 0
            for fileURL in files {
                if let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                    totalBytes += values.totalFileAllocatedSize ?? values.fileSize ?? 0
                }
            }

            // Phase 2: warm only the 50 most-recent images into memory.
            let sorted = files.sorted { url1, url2 in
                let d1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d1 > d2
            }

            var result: [(key: String, image: UIImage, byteCount: Int)] = []
            result.reserveCapacity(50)
            for fileURL in sorted {
                guard result.count < 50,
                      let data = try? Data(contentsOf: fileURL),
                      let img = Self.downsample(data: data) else { continue }
                result.append((fileURL.lastPathComponent, img, data.count))
            }
            return (result, totalBytes)
        }.value

        // Insert into NSCache on MainActor
        for entry in preloaded {
            let cost = Int(entry.image.size.width * entry.image.size.height * 4)
            memoryCache.setObject(entry.image, forKey: entry.key as NSString, cost: cost)
        }

        // Use the real total, not just the warmed subset
        diskCacheSize = totalDiskSize

        // If the true size already exceeds the limit at startup (e.g. after an
        // upgrade that fixed this very bug), evict immediately.
        if diskCacheSize > Self.maxDiskCacheSize {
            await evictToTarget()
        }
    }

    /// Evict oldest files until disk usage falls below 80% of the cap.
    private func evictToTarget() async {
        let target = Self.maxDiskCacheSize * 8 / 10
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let sorted = files.sorted { url1, url2 in
            let d1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d1 < d2
        }

        var freed = 0
        for fileURL in sorted {
            guard diskCacheSize - freed > target else { break }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                freed += size
            }
            try? fileManager.removeItem(at: fileURL)
            // Also evict from memory cache
            memoryCache.removeObject(forKey: fileURL.lastPathComponent as NSString)
        }
        diskCacheSize = max(0, diskCacheSize - freed)
    }

    /// Called after every successful disk write. Increments the running total
    /// and triggers eviction if the cap is exceeded.
    private func didWriteToDisk(bytes: Int) {
        diskCacheSize += bytes
        guard diskCacheSize > Self.maxDiskCacheSize else { return }
        Task { await evictToTarget() }
    }
}

/// Image view that checks memory cache → disk cache → network.
/// Images are downsampled via ImageIO before caching — full-res originals
/// never touch memory or MainActor.
struct CachedAsyncImage: View {
    let url: URL?
    var articleURL: URL?
    var onResult: ((Bool) -> Void)?

    init(url: URL?, articleURL: URL? = nil, onResult: ((Bool) -> Void)? = nil) {
        self.url = url
        self.articleURL = articleURL
        self.onResult = onResult
    }

    @State private var loadedImage: UIImage?
    @State private var didAttempt = false
    @State private var loadFailed = false
    @State private var retryCount = 0
    /// Drives the crossfade from placeholder → loaded image. Always 0 initially;
    /// sync memory-cache hits bypass it (forced to 1 in the body branch); async
    /// loads animate from 0 → 1 so network/dsk images fade in gracefully.
    @State private var imageOpacity: Double = 0

    private nonisolated static let minImageDimension: CGFloat = 4

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024)
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config)
    }()

    var body: some View {
        Group {
            if let image = loadedImage
                ?? url.flatMap({ ImageCache.shared.memoryImage(for: $0) }) {
                Image(uiImage: image)
                    .resizable()
                    .opacity(loadedImage == nil ? 1 : imageOpacity)
            } else if !didAttempt {
                Color.clear
                    .task(id: retryCount) { await load() }
            } else {
                Color.clear
            }
        }
        .onChange(of: (url ?? articleURL)?.absoluteString ?? "") { _, _ in
            loadedImage = nil; didAttempt = false; loadFailed = false; retryCount = 0
            imageOpacity = 0
        }
        .onAppear {
            if loadFailed && retryCount < 3 {
                loadFailed = false; didAttempt = false; retryCount += 1
            }
        }
    }

    private func didLoadImage(_ image: UIImage) {
        // Set opacity FIRST so the body ternary evaluates to 1 when
        // loadedImage fires — no invisible first frame before the animation.
        withAnimation(.easeOut(duration: 0.5)) { imageOpacity = 1 }
        loadedImage = image
    }

    private func load() async {
        guard let cacheURL = url ?? articleURL,
              url != nil || articleURL.map(ArticleImageResolver.canResolve) == true else {
            didAttempt = true; loadFailed = true; onResult?(false)
            return
        }
        // Tier 1 + 2: memory + disk
        if let cached = await ImageCache.shared.diskImage(for: cacheURL) {
            guard isValidImage(cached) else {
                ImageCache.shared.evict(url: cacheURL)
                didAttempt = true; loadFailed = true; onResult?(false)
                return
            }
            didLoadImage(cached); onResult?(true)
            if let url {
                await improveImageIfNeeded(cached, originalURL: url)
            }
            return
        }
        // Before starting a network download, check whether the prefetcher
        // (or another card) is already downloading this URL.  When it is,
        // wait briefly for the cache to be populated instead of starting a
        // duplicate request — the user sees a single seamless transition.
        if await ImageCache.isDownloadInFlight(for: cacheURL) {
            let deadline = Date().addingTimeInterval(3.0)
            if let cached = await ImageCache.shared.waitForInFlightDownload(of: cacheURL, until: deadline) {
                didLoadImage(cached); onResult?(true)
                if let url {
                    await improveImageIfNeeded(cached, originalURL: url)
                }
                return
            }
            // The in-flight download didn't complete in time — fall through
            // and start our own.
        }
        // Register this download so other cards and the prefetcher skip it. Only the
        // caller that actually registered it may unregister: `registerDownload` returns
        // false when another download already holds the URL, and unregistering that one
        // would let a third caller start a duplicate it was meant to avoid.
        let ownsDownload = await ImageCache.registerDownload(for: cacheURL)
        defer { if ownsDownload { Task { await ImageCache.unregisterDownload(for: cacheURL) } } }
        // Tier 3: network. YouTube's sddefault thumbnail is absent for some
        // videos, so hqdefault is tried before the card is marked failed.
        if let url {
            for candidate in ImageURLCandidates.candidates(for: url) {
                for attempt in 0..<2 {
                    do {
                        let (data, response) = try await Self.session.data(from: candidate)
                        if let http = response as? HTTPURLResponse,
                           !(200...299).contains(http.statusCode) { break }
                        guard Self.isValidImageData(data) else { break }
                        if let downsampled = await ImageCache.shared.setImage(data: data, for: cacheURL) {
                            didLoadImage(downsampled); onResult?(true)
                            await improveImageIfNeeded(downsampled, originalURL: url)
                            return
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
        // A missing or broken feed image gets one bounded article-metadata
        // lookup. The downloaded artwork is cached under the article URL when
        // there was no feed URL, so subsequent renders and launches are cheap.
        if let articleURL,
           let replacement = await loadArticleImage(articleURL: articleURL, replacing: url),
           let downsampled = await ImageCache.shared.setImage(data: replacement.data, for: cacheURL) {
            didLoadImage(downsampled); onResult?(true)
            return
        }
        didAttempt = true
        loadFailed = true
        onResult?(false)
    }

    private func loadArticleImage(
        articleURL: URL,
        replacing currentURL: URL?
    ) async -> (url: URL, data: Data)? {
        let candidates = await ArticleImageResolver.shared.imageURLs(
            for: articleURL,
            replacing: currentURL
        )
        return await ImageUpgradePolicy.firstDisplayable(from: candidates, session: Self.session)
    }

    private func improveImageIfNeeded(_ current: UIImage, originalURL: URL) async {
        guard let articleURL,
              ImageUpgradePolicy.needsUpgrade(current.size) else { return }
        let candidates = await ArticleImageResolver.shared.imageURLs(
            for: articleURL,
            replacing: originalURL
        )
        guard let improvement = await ImageUpgradePolicy.firstImprovement(
            from: candidates,
            over: current.size,
            session: Self.session
        ), let downsampled = await ImageCache.shared.setImage(
            data: improvement.data,
            for: originalURL
        ) else { return }
        didLoadImage(downsampled)
    }

    private func isValidImage(_ image: UIImage) -> Bool {
        image.size.width >= Self.minImageDimension
        && image.size.height >= Self.minImageDimension
    }

    /// Metadata-only validation — reads dimensions from header without
    /// decoding pixels. Safe to call on MainActor during scroll.
    private nonisolated static func isValidImageData(_ data: Data) -> Bool {
        guard let size = imagePixelSize(data) else { return false }
        return size.width >= minImageDimension && size.height >= minImageDimension
    }

    private nonisolated static func imagePixelSize(_ data: Data) -> CGSize? {
        ImageUpgradePolicy.imagePixelSize(data)
    }
}
