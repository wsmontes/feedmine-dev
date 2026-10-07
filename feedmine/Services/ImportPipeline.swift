import Foundation

// MARK: - Import Models

enum ImportItemStatus: Sendable {
    case imported
    case duplicate
    case invalid(String)
    case unreachable
}

struct ImportItemResult: Sendable {
    let url: String
    let title: String?
    let status: ImportItemStatus
}

struct ImportResult: Sendable {
    let items: [ImportItemResult]
    var importedCount: Int { items.filter { if case .imported = $0.status { return true }; return false }.count }
    var duplicateCount: Int { items.filter { if case .duplicate = $0.status { return true }; return false }.count }
    var invalidCount: Int { items.filter { if case .invalid = $0.status { return true }; return false }.count }
    var unreachableCount: Int { items.filter { if case .unreachable = $0.status { return true }; return false }.count }
}

actor ImportPipeline {
    private let session: URLSession
    private let injectedProbe: (@Sendable (String) async -> ProbeResult)?

    private enum BoundedDownloadError: Error {
        case nonHTTP
        case badStatus(Int)
        case tooLarge(limit: Int)
    }

    init(probe: (@Sendable (String) async -> ProbeResult)? = nil) {
        self.injectedProbe = probe
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/json, text/xml, */*"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    func ingest(
        urls: [String],
        category: String = "Imported",
        existingURLs: Set<String>
    ) async -> (result: ImportResult, sources: [FeedSource]) {
        var results: [ImportItemResult] = []
        var newSources: [FeedSource] = []
        var seenIdentities = existingURLs
        var toProbe: [(identity: String, requestURL: String, rawURL: String)] = []

        for rawURL in urls {
            let identity = OPMLParser.normalizeURL(rawURL)
            let request = OPMLParser.requestURL(rawURL)
            if seenIdentities.contains(identity) {
                results.append(ImportItemResult(url: rawURL, title: nil, status: .duplicate))
                continue
            }
            seenIdentities.insert(identity)
            guard URL(string: request) != nil else {
                results.append(ImportItemResult(url: rawURL, title: nil, status: .invalid("Malformed URL")))
                continue
            }
            toProbe.append((identity, request, rawURL))
        }

        let probeResults: [(rawURL: String, requestURL: String, probe: ProbeResult)] = await withTaskGroup(of: (String, String, ProbeResult).self) { group in
            var collected: [(String, String, ProbeResult)] = []
            var running = 0

            for item in toProbe {
                if running >= 5 {
                    if let result = await group.next() {
                        collected.append(result)
                        running -= 1
                    }
                }
                let request = item.requestURL
                let rawURL = item.rawURL
                group.addTask {
                    let probe = await self.probeFeed(url: request)
                    return (rawURL, request, probe)
                }
                running += 1
            }

            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (rawURL, requestURL, probe) in probeResults {
            switch probe {
            case .success(let title):
                let kind = Self.detectMediaKind(url: requestURL, title: title)
                let source = FeedSource(
                    title: title ?? Self.titleFromURL(requestURL),
                    url: requestURL,
                    category: category,
                    region: "imported",
                    mediaKind: kind
                )
                newSources.append(source)
                results.append(ImportItemResult(url: rawURL, title: title, status: .imported))
            case .invalid(let reason):
                results.append(ImportItemResult(url: rawURL, title: nil, status: .invalid(reason)))
            case .unreachable:
                results.append(ImportItemResult(url: rawURL, title: nil, status: .unreachable))
            }
        }

        return (ImportResult(items: results), newSources)
    }

    func ingest(
        opmlData: Data,
        fileName: String,
        existingURLs: Set<String>,
        validate: Bool = true
    ) async -> (result: ImportResult, sources: [FeedSource]) {
        let parser = XMLParser(data: opmlData)
        let delegate = OPMLImportDelegate(fallbackCategory: fileName.capitalized)
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil else {
            let error = parser.parserError?.localizedDescription ?? "malformed OPML"
            return (ImportResult(items: [
                ImportItemResult(url: fileName, title: nil, status: .invalid("OPML parse error: \(error)"))
            ]), [])
        }

        let parsedSources = delegate.sources

        if !validate {
            var results: [ImportItemResult] = []
            var newSources: [FeedSource] = []
            var seen = existingURLs
            for source in parsedSources {
                let identity = OPMLParser.normalizeURL(source.url)
                let fetchURL = OPMLParser.requestURL(source.url)
                guard !fetchURL.isEmpty,
                      let parsed = URL(string: fetchURL),
                      let scheme = parsed.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      parsed.host != nil else {
                    results.append(ImportItemResult(url: source.url, title: source.title,
                                                    status: .invalid("Invalid or unsupported URL")))
                    continue
                }
                if seen.contains(identity) {
                    Log.import_.info("Dropped duplicate URL in OPML: \(identity)")
                    results.append(ImportItemResult(url: source.url, title: source.title, status: .duplicate))
                } else {
                    seen.insert(identity)
                    let kind = Self.detectMediaKind(url: fetchURL, title: source.title)
                    let corrected = FeedSource(
                        title: source.title,
                        url: fetchURL,
                        category: source.category,
                        region: "imported",
                        mediaKind: kind
                    )
                    newSources.append(corrected)
                    results.append(ImportItemResult(url: source.url, title: source.title, status: .imported))
                }
            }
            return (ImportResult(items: results), newSources)
        }

        var dedupedRequestURLs: [String] = []
        var results: [ImportItemResult] = []
        var seenIdentities = existingURLs
        var metadataByIdentity: [String: (title: String, category: String)] = [:]
        for source in parsedSources {
            let identity = OPMLParser.normalizeURL(source.url)
            guard seenIdentities.insert(identity).inserted else {
                results.append(ImportItemResult(url: source.url, title: source.title, status: .duplicate))
                continue
            }
            let request = OPMLParser.requestURL(source.url)
            dedupedRequestURLs.append(request)
            if metadataByIdentity[identity] == nil {
                metadataByIdentity[identity] = (source.title, source.category)
            }
        }
        let (probeResult, sources) = await ingest(
            urls: dedupedRequestURLs,
            category: fileName.capitalized,
            existingURLs: existingURLs
        )
        let mergedItems = results + probeResult.items
        let corrected = sources.map { source -> FeedSource in
            let identity = OPMLParser.normalizeURL(source.url)
            guard let original = metadataByIdentity[identity] else { return source }
            return FeedSource(
                title: original.title.isEmpty ? source.title : original.title,
                url: source.url,
                category: original.category.isEmpty ? source.category : original.category,
                region: "imported",
                mediaKind: source.mediaKind
            )
        }
        return (ImportResult(items: mergedItems), corrected)
    }

    func ingest(
        opmlURL: URL,
        existingURLs: Set<String>,
        validate: Bool = true
    ) async -> (result: ImportResult, sources: [FeedSource])? {
        do {
            let (data, _) = try await boundedData(from: opmlURL, maxBytes: Self.opmlImportMaxBytes)
            let fileName = opmlURL.deletingPathExtension().lastPathComponent
            return await ingest(opmlData: data, fileName: fileName, existingURLs: existingURLs, validate: validate)
        } catch BoundedDownloadError.tooLarge(let limit) {
            return (ImportResult(items: [
                ImportItemResult(
                    url: opmlURL.absoluteString,
                    title: nil,
                    status: .invalid("OPML too large (limit \(limit) bytes)")
                )
            ]), [])
        } catch {
            return (ImportResult(items: [
                ImportItemResult(url: opmlURL.absoluteString, title: nil, status: .unreachable)
            ]), [])
        }
    }

    // MARK: - Media Kind Detection

    static func detectMediaKind(url: String, title: String?) -> MediaKind {
        let lower = url.lowercased()
        if lower.contains("youtube.com/feeds") || lower.contains("youtube.com/channel") {
            return .video
        }
        let podcastPatterns = ["/podcast", "/episodes", "/audio", "anchor.fm", "feeds.buzzsprout",
                               "feeds.simplecast", "feeds.megaphone", "rss.art19", "feeds.transistor",
                               "feeds.acast", "feeds.libsyn", "pinecast.com", "omny.fm",
                               "podcasts.apple.com", "podbean.com/feed"]
        if podcastPatterns.contains(where: { lower.contains($0) }) {
            return .audio
        }
        if let t = title?.lowercased() {
            if t.contains("podcast") || t.contains("episode") { return .audio }
            if t.contains("youtube") || t.contains("video") { return .video }
        }
        return .text
    }

    static func titleFromURL(_ url: String) -> String {
        guard let parsed = URL(string: url),
              let host = parsed.host else { return url }
        var name = host
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "feeds.", with: "")
            .replacingOccurrences(of: "rss.", with: "")
        if let first = name.first {
            name = String(first).uppercased() + name.dropFirst()
        }
        return name
    }

    // MARK: - Feed Probe

    enum ProbeResult: Sendable {
        case success(title: String?)
        case invalid(String)
        case unreachable
    }

    private static let feedProbeMaxBytes = 64_000
    private static let opmlImportMaxBytes = 10_000_000

    /// Streams at most `maxBytes` into memory. A declared Content-Length over
    /// the ceiling is rejected before the body is consumed; chunked/unknown
    /// length responses are stopped the moment the ceiling would be crossed.
    /// Because callers persist only after this returns, cancellation/errors
    /// cannot leave a partial OPML or probe file behind.
    ///
    /// - Parameter allowTruncation: when `true` a body over `maxBytes` is not an
    ///   error — the transfer stops at the ceiling and the caller gets the prefix
    ///   read so far. The feed probe uses this: whether a document is a feed is
    ///   decided by its envelope (first bytes), so a valid feed larger than the
    ///   probe budget must not be reported as invalid — the same URL worked when
    ///   the catalogue fetched it and failed when the user imported it (S09). The
    ///   OPML path keeps the hard ceiling: a truncated OPML is not an OPML.
    private func boundedData(from url: URL, maxBytes: Int, allowTruncation: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw BoundedDownloadError.nonHTTP
        }
        guard (200...299).contains(http.statusCode) else {
            throw BoundedDownloadError.badStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(maxBytes), !allowTruncation {
            throw BoundedDownloadError.tooLarge(limit: maxBytes)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(maxBytes, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxBytes else {
                if allowTruncation { break }
                throw BoundedDownloadError.tooLarge(limit: maxBytes)
            }
            data.append(byte)
        }
        return (data, http)
    }

    private func probeFeed(url: String) async -> ProbeResult {
        if let injected = injectedProbe { return await injected(url) }
        guard let feedURL = URL(string: url) else { return .invalid("Malformed URL") }

        do {
            let (data, http) = try await boundedData(
                from: feedURL,
                maxBytes: Self.feedProbeMaxBytes,
                allowTruncation: true
            )
            guard data.looksLikeFeedData else {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("html") {
                    return .invalid("HTML page, not a feed")
                }
                return .invalid("Unrecognized format")
            }
            let isJSON = data.first == 0x7B
            let title = Self.extractTitle(from: data, isJSON: isJSON)
            return .success(title: title)
        } catch {
            return .unreachable
        }
    }

    private static func extractTitle(from data: Data, isJSON: Bool) -> String? {
        if isJSON {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["title"] as? String {
                return title
            }
            return nil
        }
        let str = String(data: data.prefix(2000), encoding: .utf8) ?? ""
        if let range = str.range(of: "<title>"),
           let end = str[range.upperBound...].range(of: "</title>") {
            let title = String(str[range.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.hasPrefix("<![CDATA[") && title.hasSuffix("]]>") {
                return String(title.dropFirst(9).dropLast(3))
            }
            return title.isEmpty ? nil : title
        }
        return nil
    }
}

private final class OPMLImportDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    let fallbackCategory: String
    var sources: [FeedSource] = []
    private var categoryStack: [String] = []
    private var outlinePushStack: [Bool] = []

    init(fallbackCategory: String) {
        self.fallbackCategory = fallbackCategory
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "outline" else { return }
        if let xmlUrl = attributes["xmlUrl"] ?? attributes["xmlurl"] {
            let title = attributes["title"] ?? attributes["text"] ?? ""
            let category = categoryStack.last ?? fallbackCategory
            sources.append(FeedSource(title: title, url: xmlUrl, category: category, region: "imported"))
            outlinePushStack.append(false)
        } else {
            let groupName = attributes["text"] ?? attributes["title"] ?? fallbackCategory
            categoryStack.append(groupName)
            outlinePushStack.append(true)
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard element == "outline" else { return }
        let didPushCategory = outlinePushStack.popLast() ?? false
        if didPushCategory, !categoryStack.isEmpty {
            categoryStack.removeLast()
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        categoryStack.removeAll()
        outlinePushStack.removeAll()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        sources.removeAll()
        categoryStack.removeAll()
        outlinePushStack.removeAll()
    }
}

extension Data {
    var looksLikeFeedData: Bool {
        let prefix = String(prefix(500).compactMap { $0 < 128 ? Character(UnicodeScalar($0)) : nil })
        return prefix.contains("<rss") || prefix.contains("<feed") || prefix.contains("<RDF")
            || prefix.trimmingCharacters(in: .whitespaces).hasPrefix("{")
    }
}
