import Foundation

// MARK: - URL Classification

enum URLKind: Sendable {
    case feed           // Direct RSS/Atom/JSON feed URL
    case website        // HTML page — needs feed discovery
    case youtube        // youtube.com URL (channel, video, playlist, handle)
    case github         // github.com repo or user
    case podcast        // podcasts.apple.com, spotify, anchor, etc.
    case opml           // .opml file URL
    case unknown        // Unrecognizable
}

struct ClassifiedURL: Sendable {
    let raw: String
    let url: URL
    let kind: URLKind
}

// MARK: - Input Parser

/// Extracts and classifies URLs from free-form user input.
/// Handles: single URL, multiple URLs, mixed text with URLs,
/// newline/comma/space separated lists.
enum InputParser {

    /// Parse arbitrary user input into classified URLs.
    /// Input can be: a single URL, multiple URLs separated by whitespace/newlines/commas,
    /// or prose text containing embedded URLs.
    static func parse(_ input: String) -> [ClassifiedURL] {
        let urls = extractURLs(from: input)
        return urls.compactMap { raw -> ClassifiedURL? in
            guard let url = normalize(raw) else { return nil }
            let kind = classify(url)
            return ClassifiedURL(raw: raw, url: url, kind: kind)
        }
    }

    // MARK: - URL Extraction

    /// Extract all URLs from text using NSDataDetector + regex fallback.
    private static func extractURLs(from text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        // Strategy 1: NSDataDetector (handles most URL formats)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, range: range)
            for match in matches {
                if let url = match.url?.absoluteString, seen.insert(url).inserted {
                    found.append(url)
                }
            }
        }

        // Strategy 2: Line-by-line for bare domains (site.com without http)
        // Split by common separators and check each token
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|"))
        let tokens = text.components(separatedBy: separators)
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]{}"))
            guard !trimmed.isEmpty, trimmed.contains("."), !seen.contains(trimmed) else { continue }
            // Reject email addresses (user@host) — they'd become
            // https://user@host with userinfo, creating garbage sources.
            guard !trimmed.contains("@") else { continue }
            // Add scheme if missing
            let withScheme = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: withScheme), url.host != nil, !seen.contains(withScheme) {
                seen.insert(withScheme)
                found.append(withScheme)
            }
        }

        return found
    }

    // MARK: - URL Normalization

    /// Normalizes user-supplied web locations while keeping the accepted scheme vocabulary closed.
    ///
    /// Deep links and free-form imports share this boundary. A string that already names a non-web
    /// scheme is rejected rather than being rewritten into an apparently-HTTPS string such as
    /// `https://javascript:...`. Bare domains are still supported for the add-feed UI.
    static func normalizeWebURL(_ raw: String) -> URL? {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return nil }

        if let colon = str.firstIndex(of: ":") {
            let prefix = String(str[..<colon])
            let looksLikeScheme = !prefix.isEmpty
                && prefix.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-.")).contains($0)
                }
            if looksLikeScheme {
                let scheme = prefix.lowercased()
                guard scheme == "http" || scheme == "https" else { return nil }
            }
        } else {
            // Reject email addresses — they'd become URLs with userinfo rather than feed hosts.
            if str.contains("@") && !str.contains("/") { return nil }
            str = "https://\(str)"
        }

        guard let url = URL(string: str),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    private static func normalize(_ raw: String) -> URL? {
        normalizeWebURL(raw)
    }

    // MARK: - Classification

    private static func classify(_ url: URL) -> URLKind {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let fullURL = url.absoluteString.lowercased()

        // OPML
        if path.hasSuffix(".opml") || path.hasSuffix(".opml.xml") {
            return .opml
        }

        // YouTube
        if host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be" || host.hasSuffix(".youtu.be") {
            return .youtube
        }

        // GitHub
        if host == "github.com" || host == "www.github.com" {
            return .github
        }

        // Podcast platforms — exact host or subdomain match only,
        // not lookalike domains.
        let podcastHosts = ["podcasts.apple.com", "itunes.apple.com",
                           "open.spotify.com", "anchor.fm",
                           "feeds.buzzsprout.com", "feeds.simplecast.com",
                           "feeds.megaphone.fm", "rss.art19.com",
                           "feeds.transistor.fm", "feeds.acast.com",
                           "feeds.libsyn.com", "pinecast.com", "omny.fm",
                           "podbean.com", "spreaker.com", "castbox.fm"]
        if podcastHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return .podcast
        }

        // Direct feed indicators
        let feedIndicators = ["/feed", "/rss", "/atom", ".xml", ".json",
                             "/feeds/", "feed.xml", "rss.xml", "atom.xml",
                             "index.xml", "/feed/"]
        if feedIndicators.contains(where: { path.contains($0) || fullURL.contains($0) }) {
            return .feed
        }

        // Content-type hints in URL
        if fullURL.contains("application/rss") || fullURL.contains("application/atom") {
            return .feed
        }

        // Default: treat as website (will attempt feed discovery)
        return .website
    }
}
