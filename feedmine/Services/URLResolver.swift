import Foundation

// MARK: - Bounded Download (P1-12)

/// Byte ceilings for user-controlled network responses.
private enum DownloadLimit {
    static let feedDiscoveryHTML = 256_000  // HTML page for feed discovery
    static let feedProbe = 64_000           // RSS/Atom/JSON feed validation
    static let opmlImport = 10_000_000      // remote OPML import
    static let lookupJSON = 1_000_000       // iTunes lookup response — JSON, tiny
}

/// Download with a byte ceiling. Streams the response body and aborts
/// as soon as `maxBytes` is exceeded — content is never fully buffered
/// before the guard. Also checks `Content-Length` ahead of transfer when
/// the header is present, rejecting oversized responses before the first
/// byte arrives.
private func boundedDownload(from url: URL, maxBytes: Int, session: URLSession = .shared) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10

    let (asyncBytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }

    // Early rejection when Content-Length is advertised and exceeds the cap.
    if let lengthStr = http.value(forHTTPHeaderField: "Content-Length"),
       let length = Int(lengthStr), length > maxBytes {
        throw URLError(.cannotParseResponse)
    }

    var data = Data()
    data.reserveCapacity(min(maxBytes, 64_000))
    for try await chunk in asyncBytes.prefix(maxBytes + 1) {
        // asyncBytes iterates Data chunks (not individual bytes) on recent OS
        // versions; the prefix ensures we read at most maxBytes+1 chunks.
        data.append(chunk)
    }
    // This would only happen on older OS versions where prefix(count:) on
    // async sequences isn't supported — a defensive fallback.
    guard data.count <= maxBytes else {
        throw URLError(.cannotParseResponse)
    }

    return (data, http)
}

// MARK: - Resolve Result

struct ResolvedFeed: Sendable {
    let feedURL: String
    let title: String?
    let sourceURL: String      // Original URL that was resolved
    let mediaKind: MediaKind
}

enum ResolveError: Sendable {
    case noFeedFound
    case unreachable
    case timeout
    case invalidURL
}

struct ResolveResult: Sendable {
    let source: ClassifiedURL
    let feeds: [ResolvedFeed]
    let error: ResolveError?

    static func success(_ source: ClassifiedURL, feeds: [ResolvedFeed]) -> ResolveResult {
        ResolveResult(source: source, feeds: feeds, error: nil)
    }
    static func failure(_ source: ClassifiedURL, _ error: ResolveError) -> ResolveResult {
        ResolveResult(source: source, feeds: [], error: error)
    }
}

// MARK: - URL Resolver

/// Resolves classified URLs into actual feed URLs.
/// Handles: websites (feed discovery), YouTube (channel/video/playlist),
/// GitHub (releases/commits), podcasts (Apple lookup), direct feeds, OPMLs.
actor URLResolver {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        self.session = URLSession(configuration: config)
    }

    /// Resolve a batch of classified URLs into feed URLs.
    /// Runs up to 5 concurrent resolutions.
    func resolveAll(_ classified: [ClassifiedURL]) async -> [ResolveResult] {
        await withTaskGroup(of: ResolveResult.self, returning: [ResolveResult].self) { group in
            var results: [ResolveResult] = []
            var started = 0
            let maxConcurrent = 5
            var iterator = classified.makeIterator()

            while started < maxConcurrent, let item = iterator.next() {
                group.addTask { await self.resolve(item) }
                started += 1
            }
            while let result = await group.next() {
                results.append(result)
                if let item = iterator.next() {
                    group.addTask { await self.resolve(item) }
                }
            }
            return results
        }
    }

    /// Resolve a single classified URL.
    func resolve(_ classified: ClassifiedURL) async -> ResolveResult {
        switch classified.kind {
        case .feed:
            // Path-based classification (.xml, /feed, /rss, .json) is a guess.
            // Probe the URL to confirm it actually serves a feed before accepting
            // it — a regular JSON API or misclassified page could otherwise be
            // added as a source and fail silently on every fetch.
            if await probeFeed(classified.url) {
                return .success(classified, feeds: [
                    ResolvedFeed(feedURL: classified.url.absoluteString, title: nil,
                                sourceURL: classified.raw, mediaKind: .text)
                ])
            }
            // Fall through to website discovery — the URL may have feed links
            return await discoverFeeds(classified)
        case .website:
            return await discoverFeeds(classified)
        case .youtube:
            return await resolveYouTube(classified)
        case .github:
            return await resolveGitHub(classified)
        case .podcast:
            return await resolvePodcast(classified)
        case .opml:
            // OPMLs are handled separately by ImportPipeline
            return .success(classified, feeds: [])
        case .unknown:
            // Try website discovery as fallback
            return await discoverFeeds(classified)
        }
    }

    /// Probe candidate feed URLs in parallel. Returns the first URL that
    /// responds with a valid feed, cancelling all remaining probes.
    // P2-14: Distinguish deadline expiry from a failed probe so the deadline
    // actually cancels the remaining search rather than continuing silently.
    private enum ProbeEvent: Sendable {
        case match(String)
        case miss
        case deadline
    }

    private func firstMatchingFeed(_ candidates: [String], maxConcurrent: Int, deadlineSeconds: Int) async -> String? {
        await withTaskGroup(of: ProbeEvent.self) { group in
            var iterator = candidates.makeIterator()
            var started = 0
            let cap = max(1, maxConcurrent)

            // Deadline task — fires once and signals the group to stop.
            group.addTask {
                try? await Task.sleep(for: .seconds(deadlineSeconds))
                return .deadline
            }

            // Prime the window
            var pending = 0
            while started < cap, let candidate = iterator.next() {
                group.addTask {
                    await self.probeFeedURL(candidate) ? .match(candidate) : .miss
                }
                started += 1
                pending += 1
            }

            while let event = await group.next() {
                switch event {
                case .match(let url):
                    group.cancelAll()
                    return url
                case .deadline:
                    group.cancelAll()
                    return nil
                case .miss:
                    pending -= 1
                    if let candidate = iterator.next() {
                        group.addTask {
                            await self.probeFeedURL(candidate) ? .match(candidate) : .miss
                        }
                        pending += 1
                    } else if pending == 0 {
                        // Every candidate has answered and none is a feed. The timeout task would otherwise
                        // hold the caller for the rest of the budget with nothing left to probe — the common
                        // case (a site with no feed) paid the full 8 s of discovery latency for no answer
                        // (S20). Cancelling here ends the group and its deadline child.
                        group.cancelAll()
                        return nil
                    }
                }
            }
            return nil
        }
    }

    // MARK: - Feed Probe

    /// Quick validation: is this URL actually serving a feed? A HEAD request
    /// with a fast timeout confirms HTTP 200 + a feed-like Content-Type before
    /// we accept the path-based guess. Falls back to a small ranged GET if the
    /// server rejects HEAD.
    private func probeFeed(_ url: URL) async -> Bool {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: head)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 405 || http.statusCode == 501 {
                return await probeFeedRanged(url)
            }
            return http.statusCode == 200 && isFeedContentType(http)
        } catch {
            return await probeFeedRanged(url)
        }
    }

    private func probeFeedRanged(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("bytes=0-511", forHTTPHeaderField: "Range")
        do {
            // Stream with bytes(for:) instead of data(for:) — servers that
            // ignore Range return the full body, and data(for:) would buffer
            // it entirely before the prefix check. bytes(for:) lets us drain
            // only the first 256 bytes (review finding).
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200...299).contains(http.statusCode) || http.statusCode == 206 else {
                return false
            }
            var data = Data()
            for try await byte in asyncBytes.prefix(256) {
                data.append(byte)
            }
            let prefix = String(data: data, encoding: .utf8) ?? ""
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<rss")
                || trimmed.hasPrefix("<feed") || trimmed.hasPrefix("<atom")
                || trimmed.hasPrefix("{")
        } catch {
            return false
        }
    }

    private nonisolated func isFeedContentType(_ response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let feedTypes = ["application/rss+xml", "application/atom+xml",
                         "application/feed+json", "application/json",
                         "application/xml", "text/xml"]
        return feedTypes.contains(where: { contentType.hasPrefix($0) })
    }

    // MARK: - Feed Discovery (Website → Feed URL)

    private func discoverFeeds(_ classified: ClassifiedURL) async -> ResolveResult {
        let url = classified.url

        // Strategy 1: Check <link rel="alternate"> in HTML
        if let htmlFeeds = await parseHTMLForFeeds(url), !htmlFeeds.isEmpty {
            return .success(classified, feeds: htmlFeeds)
        }

        // Strategy 2: Try common feed paths in parallel (max 3 concurrent).
        // Cancel remaining probes as soon as the first valid feed is found.
        let root = "\(url.scheme ?? "https")://\(url.host ?? "")"
        let commonPaths = ["/feed", "/rss", "/atom.xml", "/feed.xml", "/rss.xml",
                          "/index.xml", "/feed/", "/feeds/posts/default", "/?feed=rss2"]
        let candidates = commonPaths.map { root + $0 }

        if let firstMatch = await firstMatchingFeed(candidates, maxConcurrent: 3, deadlineSeconds: 8) {
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: firstMatch, title: nil, sourceURL: classified.raw, mediaKind: .text)
            ])
        }

        return .failure(classified, .noFeedFound)
    }

    /// Parse HTML page for <link rel="alternate" type="application/rss+xml">
    private func parseHTMLForFeeds(_ url: URL) async -> [ResolvedFeed]? {
        // P1-12: Bound HTML downloads for feed discovery.
        guard let (data, http) = try? await boundedDownload(
            from: url, maxBytes: DownloadLimit.feedDiscoveryHTML, session: session
        ), (200...299).contains(http.statusCode) else { return nil }

        guard let html = String(data: data, encoding: .utf8) else { return nil }

        var feeds: [ResolvedFeed] = []
        let pattern = #"<link[^>]+rel\s*=\s*["']alternate["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])

            // Check type is RSS/Atom
            let types = ["application/rss+xml", "application/atom+xml", "application/json", "application/feed+json"]
            guard types.contains(where: { tag.lowercased().contains($0) }) else { continue }

            // Extract href
            let hrefPattern = #"href\s*=\s*["']([^"']+)["']"#
            guard let hrefRegex = try? NSRegularExpression(pattern: hrefPattern),
                  let hrefMatch = hrefRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: tag) else { continue }
            var href = String(tag[hrefRange])

            // Resolve relative URLs using the standard URL API.
            // Handles ../feed.xml, ./rss, ?output=rss, //cdn.example.com/feed,
            // and other edge cases that string concatenation gets wrong.
            if !href.hasPrefix("http") {
                href = URL(string: href, relativeTo: url)?.absoluteString ?? href
            }

            // Extract title
            let titlePattern = #"title\s*=\s*["']([^"']+)["']"#
            var title: String?
            if let titleRegex = try? NSRegularExpression(pattern: titlePattern),
               let titleMatch = titleRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
               let titleRange = Range(titleMatch.range(at: 1), in: tag) {
                title = String(tag[titleRange])
            }

            feeds.append(ResolvedFeed(feedURL: href, title: title, sourceURL: url.absoluteString, mediaKind: .text))
        }

        return feeds.isEmpty ? nil : feeds
    }

    // MARK: - YouTube Resolver

    private func resolveYouTube(_ classified: ClassifiedURL) async -> ResolveResult {
        let url = classified.url
        let path = url.path.lowercased()
        let components = url.pathComponents

        // youtube.com/feeds/videos.xml?channel_id=X — already a feed
        if path.contains("/feeds/") {
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: url.absoluteString, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        // youtube.com/channel/UCxxxx
        if components.count >= 3, components[1].lowercased() == "channel" {
            let channelID = components[2]
            let feedURL = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        // youtube.com/playlist?list=PLxxxx
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let playlistID = queryItems.first(where: { $0.name == "list" })?.value {
            let feedURL = "https://www.youtube.com/feeds/videos.xml?playlist_id=\(playlistID)"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        // youtube.com/@handle or youtube.com/c/name or youtube.com/user/name
        // youtube.com/watch?v=xxx (resolve channel from video page)
        // All require fetching the page to extract channel ID
        if let channelID = await extractYouTubeChannelID(url) {
            let feedURL = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .video)
            ])
        }

        return .failure(classified, .noFeedFound)
    }

    /// Fetch a YouTube page and extract the channel ID from meta tags or page data.
    private func extractYouTubeChannelID(_ url: URL) async -> String? {
        // P1-12: Bound YouTube metadata downloads to 512 KB.
        guard let (data, http) = try? await boundedDownload(
            from: url, maxBytes: 512_000, session: session
        ), (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { return nil }

        // Try: <meta itemprop="channelId" content="UCxxxx">
        let metaPattern = #"<meta[^>]+itemprop\s*=\s*["']channelId["'][^>]+content\s*=\s*["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: metaPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }

        // Try: "channelId":"UCxxxx"
        let jsonPattern = #""channelId"\s*:\s*"(UC[^"]+)""#
        if let regex = try? NSRegularExpression(pattern: jsonPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }

        // Try: /channel/UCxxxx in canonical or og:url
        let canonicalPattern = #"/channel/(UC[a-zA-Z0-9_-]+)"#
        if let regex = try? NSRegularExpression(pattern: canonicalPattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }

        return nil
    }

    // MARK: - GitHub Resolver

    private func resolveGitHub(_ classified: ClassifiedURL) async -> ResolveResult {
        let components = classified.url.pathComponents
        // github.com/user/repo → releases.atom
        // github.com/user → user.atom
        guard components.count >= 2 else { return .failure(classified, .invalidURL) }

        let user = components[1]
        if components.count >= 3 {
            let repo = components[2]
            // Repo: offer releases feed
            let feedURL = "https://github.com/\(user)/\(repo)/releases.atom"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: "\(repo) releases",
                            sourceURL: classified.raw, mediaKind: .text)
            ])
        } else {
            // User profile: activity feed
            let feedURL = "https://github.com/\(user).atom"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: "\(user) activity",
                            sourceURL: classified.raw, mediaKind: .text)
            ])
        }
    }

    // MARK: - Podcast Resolver

    /// True when `host` is exactly `domain` or a subdomain of it.
    /// Avoids `host.contains(domain)` which matches lookalike hosts like
    /// `fake-podcasts.apple.com.evil.org`.
    private nonisolated func hostBelongsTo(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    private func resolvePodcast(_ classified: ClassifiedURL) async -> ResolveResult {
        let host = classified.url.host?.lowercased() ?? ""

        // Apple Podcasts: use iTunes Lookup API
        if hostBelongsTo(host, "podcasts.apple.com")
            || hostBelongsTo(host, "itunes.apple.com") {
            if let feedURL = await resolveApplePodcast(classified.url) {
                return .success(classified, feeds: [
                    ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .audio)
                ])
            }
        }

        // Anchor.fm → RSS pattern
        if hostBelongsTo(host, "anchor.fm") {
            let path = classified.url.path
            let feedURL = "https://anchor.fm\(path)/rss"
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: feedURL, title: nil, sourceURL: classified.raw, mediaKind: .audio)
            ])
        }

        // Direct podcast feed hosts (buzzsprout, simplecast, etc.) — likely already a feed
        let directFeedHosts = ["feeds.buzzsprout.com", "feeds.simplecast.com", "feeds.megaphone.fm",
                              "rss.art19.com", "feeds.transistor.fm", "feeds.acast.com",
                              "feeds.libsyn.com", "pinecast.com", "omny.fm"]
        if directFeedHosts.contains(where: { hostBelongsTo(host, $0) }) {
            return .success(classified, feeds: [
                ResolvedFeed(feedURL: classified.url.absoluteString, title: nil,
                            sourceURL: classified.raw, mediaKind: .audio)
            ])
        }

        // Fallback: try feed discovery on the page
        return await discoverFeeds(classified)
    }

    /// Resolve Apple Podcasts URL via iTunes Lookup API.
    private func resolveApplePodcast(_ url: URL) async -> String? {
        // Extract podcast ID from URL: /podcast/name/id123456
        let path = url.path
        let idPattern = #"id(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: idPattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else { return nil }
        let podcastID = String(path[range])

        // iTunes Lookup API
        guard let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(podcastID)&entity=podcast"),
              let (data, _) = try? await boundedDownload(
                  from: lookupURL, maxBytes: DownloadLimit.lookupJSON, session: session
              ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let feedURL = first["feedUrl"] as? String else { return nil }

        return feedURL
    }

    // MARK: - Probe Helper

    /// Quick check if a URL returns a valid feed (HTTP 200 + XML/JSON feed content).
    private func probeFeedURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        // P1-12: Bound feed probe downloads to prevent memory spikes from
        // large responses masquerading as feeds.
        guard let (data, http) = try? await boundedDownload(
            from: url, maxBytes: DownloadLimit.feedProbe, session: session
        ), (200...299).contains(http.statusCode) else { return false }
        return data.looksLikeFeedData
    }
}
