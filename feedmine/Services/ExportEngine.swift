import Foundation

// MARK: - Export Scope

enum ExportScope: String, CaseIterable, Identifiable {
    case all = "All Sources"
    case enabledOnly = "Enabled Only"
    case collection = "Collection"
    case country = "Country"
    case bookmarks = "Bookmarks"
    case fullBackup = "Full Backup"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .enabledOnly: return "checkmark.circle"
        case .collection: return "folder"
        case .country: return "globe"
        case .bookmarks: return "bookmark"
        case .fullBackup: return "arrow.down.doc"
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case opml = "OPML"
    case json = "JSON Backup"
    case csv = "CSV"
    case text = "Plain Text"
    case markdown = "Markdown"
    case html = "HTML Blogroll"
    case shareLink = "Share Link"
    case socialCard = "Social Card"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .opml: return "doc.text"
        case .json: return "curlybraces"
        case .csv: return "tablecells"
        case .text: return "list.bullet.rectangle"
        case .markdown: return "number"
        case .html: return "globe"
        case .shareLink: return "link"
        case .socialCard: return "text.bubble"
        }
    }
}

// MARK: - Full Backup Model

struct FeedmineBackup: Codable {
    let version: Int
    let exportedAt: Date
    let sources: [FeedSource]
    let contentFilters: [ContentFilter]
    let bookmarkIDs: [String]
    let settings: BackupSettings

    struct BackupSettings: Codable {
        let filterRegion: String?
        let filterTaxonomyNodes: [String]
        let filterContentType: String
        let circadianPaletteOn: Bool
        let paletteFamily: String
    }
}

// MARK: - Export Engine

enum ExportEngine {

    // MARK: - OPML

    static func opml(sources: [FeedSource], title: String = "Feedmine Export") -> Data {
        let grouped = Dictionary(grouping: sources, by: \.category)
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>\(xmlEscape(title))</title>
            <dateCreated>\(ISO8601DateFormatter().string(from: Date()))</dateCreated>
            <ownerName>Feedmine</ownerName>
          </head>
          <body>\n
        """
        for (category, feeds) in grouped.sorted(by: { $0.key < $1.key }) {
            xml += "    <outline text=\"\(xmlEscape(category))\" title=\"\(xmlEscape(category))\">\n"
            for feed in feeds.sorted(by: { $0.title < $1.title }) {
                let typeAttr = feed.mediaKind == .audio ? " type=\"audio\"" : " type=\"rss\""
                xml += "      <outline text=\"\(xmlEscape(feed.title))\" title=\"\(xmlEscape(feed.title))\" xmlUrl=\"\(xmlEscape(feed.url))\"\(typeAttr) category=\"\(xmlEscape(feed.region))\"/>\n"
            }
            xml += "    </outline>\n"
        }
        xml += """
          </body>
        </opml>\n
        """
        return Data(xml.utf8)
    }

    // MARK: - JSON Full Backup

    static func jsonBackup(
        sources: [FeedSource],
        contentFilters: [ContentFilter],
        bookmarkIDs: [String] = []
    ) -> Data {
        let backup = FeedmineBackup(
            version: 1,
            exportedAt: Date(),
            sources: sources,
            contentFilters: contentFilters,
            bookmarkIDs: bookmarkIDs,
            settings: FeedmineBackup.BackupSettings(
                filterRegion: Settings.filterRegion,
                filterTaxonomyNodes: Settings.filterTaxonomyNodes,
                filterContentType: Settings.filterContentType,
                circadianPaletteOn: Settings.circadianPaletteOn,
                paletteFamily: Settings.paletteFamily
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(backup)) ?? Data()
    }

    // MARK: - CSV

    // MARK: - CSV

    /// CSV with explicit enabled state
    static func csv(sources: [FeedSource], enabledURLs: Set<String>) -> Data {
        var lines: [String] = []
        lines.append("title,url,category,region,type,enabled")
        for source in sources.sorted(by: { $0.category < $1.category }) {
            let enabled = enabledURLs.contains(source.url)
            lines.append("\(csvEscape(source.title)),\(csvEscape(source.url)),\(csvEscape(source.category)),\(csvEscape(source.region)),\(source.mediaKind.rawValue),\(enabled)")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: - Plain Text

    static func plainText(sources: [FeedSource], title: String = "My Feeds") -> String {
        let grouped = Dictionary(grouping: sources, by: \.category)
        var lines: [String] = [title, String(repeating: "=", count: title.count), ""]
        for (category, feeds) in grouped.sorted(by: { $0.key < $1.key }) {
            lines.append("[\(category)]")
            for feed in feeds.sorted(by: { $0.title < $1.title }) {
                let typeTag = feed.mediaKind == .video ? " 🎬" : (feed.mediaKind == .audio ? " 🎙️" : "")
                lines.append("  • \(feed.title)\(typeTag)")
                lines.append("    \(feed.url)")
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("Exported from Feedmine · \(sources.count) feeds · \(grouped.count) collections")
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown

    static func markdown(sources: [FeedSource], title: String = "My Feeds") -> String {
        let grouped = Dictionary(grouping: sources, by: \.category)
        var lines: [String] = ["# \(title)", ""]
        lines.append("> \(sources.count) feeds across \(grouped.count) collections")
        lines.append("")
        for (category, feeds) in grouped.sorted(by: { $0.key < $1.key }) {
            lines.append("## \(category)")
            lines.append("")
            for feed in feeds.sorted(by: { $0.title < $1.title }) {
                let badge: String
                switch feed.mediaKind {
                case .video: badge = " `video`"
                case .audio: badge = " `podcast`"
                case .text: badge = ""
                case .forum: badge = " `forum`"
                }
                lines.append("- [\(feed.title)](\(feed.url))\(badge)")
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("*Exported from [Feedmine](https://github.com/wawasoft/feedmine) on \(formattedDate())*")
        return lines.joined(separator: "\n")
    }

    // MARK: - Social Card

    /// Generates text optimized for social media posting (Twitter/Mastodon/Threads).
    /// Concise, with emojis, under 280 characters if possible.
    static func socialCard(sources: [FeedSource], stats: SocialCardStats? = nil) -> String {
        let grouped = Dictionary(grouping: sources, by: \.category)
        let countries = Set(sources.map(\.region).filter { $0.hasPrefix("countries/") }).count
        let videoCount = sources.filter { $0.mediaKind == .video }.count
        let audioCount = sources.filter { $0.mediaKind == .audio }.count

        var parts: [String] = []
        parts.append("📡 My reading list:")
        parts.append("")

        // Stats line
        var statsLine = "📰 \(sources.count) feeds"
        if grouped.count > 3 { statsLine += " · \(grouped.count) topics" }
        if countries > 0 { statsLine += " · \(countries) 🌍" }
        parts.append(statsLine)

        // Content mix
        var mix: [String] = []
        let textCount = sources.count - videoCount - audioCount
        if textCount > 0 { mix.append("📖 \(textCount) blogs") }
        if videoCount > 0 { mix.append("🎬 \(videoCount) YouTube") }
        if audioCount > 0 { mix.append("🎙️ \(audioCount) podcasts") }
        if mix.count > 1 { parts.append(mix.joined(separator: " · ")) }

        // Top collections (max 4)
        let topCollections = grouped.sorted { $0.value.count > $1.value.count }.prefix(4)
        let collectionLine = topCollections.map { "\($0.key) (\($0.value.count))" }.joined(separator: ", ")
        parts.append(collectionLine)

        parts.append("")

        // Streak/stats if available
        if let stats {
            if stats.streak > 0 { parts.append("🔥 \(stats.streak)-day reading streak") }
            if stats.articlesRead > 0 { parts.append("📚 \(stats.articlesRead) articles read") }
        }

        parts.append("")
        parts.append("No algorithms. No ads. Just RSS.")
        parts.append("feedmine.app")

        return parts.joined(separator: "\n")
    }

    struct SocialCardStats {
        var streak: Int = 0
        var articlesRead: Int = 0
    }

    // MARK: - HTML Blogroll

    /// Generates a styled HTML page suitable for publishing as a blogroll.
    /// Self-contained: inline CSS, no external dependencies, responsive.
    static func htmlBlogroll(sources: [FeedSource], title: String = "My Blogroll", author: String = "Feedmine User") -> Data {
        let grouped = Dictionary(grouping: sources, by: \.category)
        let countries = Set(sources.map(\.region).filter { $0.hasPrefix("countries/") }).count

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(htmlEscape(title))</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
            background: #FAF8F5; color: #2c2c2c; line-height: 1.6;
            max-width: 800px; margin: 0 auto; padding: 40px 20px;
        }
        header { margin-bottom: 48px; }
        h1 { font-size: 2rem; font-weight: 700; margin-bottom: 8px; }
        .subtitle { color: #666; font-size: 0.95rem; }
        .stats { display: flex; gap: 16px; margin-top: 12px; flex-wrap: wrap; }
        .stat { background: #f0ebe4; padding: 4px 12px; border-radius: 20px; font-size: 0.8rem; color: #555; }
        .collection { margin-bottom: 40px; }
        .collection h2 { font-size: 1.2rem; font-weight: 600; margin-bottom: 16px;
            padding-bottom: 8px; border-bottom: 1px solid #e5e0da; }
        .feed { display: flex; align-items: center; gap: 12px; padding: 10px 0;
            border-bottom: 1px solid #f0ebe4; }
        .feed:last-child { border-bottom: none; }
        .feed-icon { width: 32px; height: 32px; border-radius: 6px; background: #e5e0da;
            display: flex; align-items: center; justify-content: center; font-size: 14px; flex-shrink: 0; }
        .feed-info { flex: 1; min-width: 0; }
        .feed-title { font-weight: 500; font-size: 0.95rem; }
        .feed-title a { color: inherit; text-decoration: none; }
        .feed-title a:hover { color: #E8483C; }
        .feed-url { font-size: 0.75rem; color: #999; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .badge { font-size: 0.65rem; background: #e5e0da; color: #666; padding: 2px 6px;
            border-radius: 10px; margin-left: 6px; }
        footer { margin-top: 60px; padding-top: 20px; border-top: 1px solid #e5e0da;
            font-size: 0.8rem; color: #999; text-align: center; }
        footer a { color: #E8483C; text-decoration: none; }
        @media (prefers-color-scheme: dark) {
            body { background: #1a1a1a; color: #e0e0e0; }
            .stat { background: #2a2a2a; color: #aaa; }
            .collection h2 { border-color: #333; }
            .feed { border-color: #2a2a2a; }
            .feed-icon { background: #2a2a2a; }
            .feed-url { color: #666; }
            .badge { background: #2a2a2a; color: #888; }
            footer { border-color: #333; }
        }
        </style>
        </head>
        <body>
        <header>
            <h1>\(htmlEscape(title))</h1>
            <p class="subtitle">Curated by \(htmlEscape(author)) · \(formattedDate())</p>
            <div class="stats">
                <span class="stat">📡 \(sources.count) feeds</span>
                <span class="stat">📁 \(grouped.count) collections</span>
        """
        if countries > 0 { html += "        <span class=\"stat\">🌍 \(countries) countries</span>\n" }
        let videoCount = sources.filter { $0.mediaKind == .video }.count
        let audioCount = sources.filter { $0.mediaKind == .audio }.count
        if videoCount > 0 { html += "        <span class=\"stat\">🎬 \(videoCount) YouTube</span>\n" }
        if audioCount > 0 { html += "        <span class=\"stat\">🎙️ \(audioCount) podcasts</span>\n" }
        html += """
            </div>
        </header>
        <main>\n
        """

        for (category, feeds) in grouped.sorted(by: { $0.key < $1.key }) {
            html += "<section class=\"collection\">\n"
            html += "  <h2>\(htmlEscape(category))</h2>\n"
            for feed in feeds.sorted(by: { $0.title < $1.title }) {
                let icon = feed.mediaKind == .video ? "▶️" : (feed.mediaKind == .audio ? "🎧" : "📄")
                let badge = feed.mediaKind != .text ? "<span class=\"badge\">\(feed.mediaKind.rawValue)</span>" : ""
                let domain = URL(string: feed.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? feed.url
                html += """
                  <div class="feed">
                    <div class="feed-icon">\(icon)</div>
                    <div class="feed-info">
                      <div class="feed-title"><a href="\(htmlEscape(feed.url))">\(htmlEscape(feed.title))</a>\(badge)</div>
                      <div class="feed-url">\(htmlEscape(domain))</div>
                    </div>
                  </div>\n
                """
            }
            html += "</section>\n"
        }

        html += """
        </main>
        <footer>
            <p>Generated by <a href="https://github.com/wawasoft/feedmine">Feedmine</a> — open-source RSS reader</p>
            <p>No algorithms. No ads. No accounts.</p>
        </footer>
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    // MARK: - Article Export (for bookmarks)

    static func csvArticles(items: [FeedItem]) -> Data {
        var lines: [String] = []
        lines.append("title,url,source,date,category")
        let formatter = ISO8601DateFormatter()
        for item in items.sorted(by: { $0.publishedAt > $1.publishedAt }) {
            lines.append("\(csvEscape(item.title)),\(csvEscape(item.url)),\(csvEscape(item.sourceTitle)),\(formatter.string(from: item.publishedAt)),\(csvEscape(item.category))")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func plainTextArticles(items: [FeedItem], title: String = "My Bookmarks") -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var lines: [String] = [title, String(repeating: "=", count: title.count), ""]
        lines.append("\(items.count) saved articles")
        lines.append("")
        for item in items.sorted(by: { $0.publishedAt > $1.publishedAt }) {
            lines.append("• \(item.title)")
            lines.append("  \(item.url)")
            lines.append("  \(item.sourceTitle) · \(formatter.string(from: item.publishedAt))")
            lines.append("")
        }
        lines.append("---")
        lines.append("Exported from Feedmine · \(formattedDate())")
        return lines.joined(separator: "\n")
    }

    static func markdownArticles(items: [FeedItem], title: String = "My Bookmarks") -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var lines: [String] = ["# \(title)", ""]
        lines.append("> \(items.count) saved articles")
        lines.append("")
        let grouped = Dictionary(grouping: items, by: \.category)
        for (category, articles) in grouped.sorted(by: { $0.key < $1.key }) {
            lines.append("## \(category)")
            lines.append("")
            for item in articles.sorted(by: { $0.publishedAt > $1.publishedAt }) {
                lines.append("- [\(item.title)](\(item.url)) — *\(item.sourceTitle)* · \(formatter.string(from: item.publishedAt))")
            }
            lines.append("")
        }
        lines.append("---")
        lines.append("*Exported from [Feedmine](https://github.com/wawasoft/feedmine) on \(formattedDate())*")
        return lines.joined(separator: "\n")
    }

    static func htmlArticles(items: [FeedItem], title: String = "My Bookmarks") -> Data {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(htmlEscape(title))</title>
        <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            background: #FAF8F5; color: #2c2c2c; line-height: 1.6;
            max-width: 700px; margin: 0 auto; padding: 40px 20px; }
        h1 { font-size: 1.8rem; margin-bottom: 8px; }
        .count { color: #666; margin-bottom: 32px; }
        .article { padding: 16px 0; border-bottom: 1px solid #f0ebe4; }
        .article:last-child { border-bottom: none; }
        .article-title { font-weight: 600; font-size: 1rem; }
        .article-title a { color: #2c2c2c; text-decoration: none; }
        .article-title a:hover { color: #E8483C; }
        .article-meta { font-size: 0.8rem; color: #888; margin-top: 4px; }
        .article-excerpt { font-size: 0.85rem; color: #555; margin-top: 6px; }
        footer { margin-top: 40px; font-size: 0.75rem; color: #aaa; text-align: center; }
        @media (prefers-color-scheme: dark) {
            body { background: #1a1a1a; color: #e0e0e0; }
            .article { border-color: #333; }
            .article-title a { color: #e0e0e0; }
            .article-meta { color: #666; }
            .article-excerpt { color: #999; }
        }
        </style>
        </head>
        <body>
        <h1>\(htmlEscape(title))</h1>
        <p class="count">\(items.count) saved articles</p>\n
        """
        for item in items.sorted(by: { $0.publishedAt > $1.publishedAt }) {
            let excerpt = item.excerpt.isEmpty ? "" : "<p class=\"article-excerpt\">\(htmlEscape(String(item.excerpt.prefix(200))))</p>"
            html += """
            <div class="article">
                <div class="article-title"><a href="\(htmlEscape(item.url))">\(htmlEscape(item.title))</a></div>
                <div class="article-meta">\(htmlEscape(item.sourceTitle)) · \(formatter.string(from: item.publishedAt))</div>
                \(excerpt)
            </div>\n
            """
        }
        html += """
        <footer>Exported from Feedmine · \(formattedDate())</footer>
        </body></html>
        """
        return Data(html.utf8)
    }

    // MARK: - Share Link

    /// For a single feed: generates a feedmine:// deep link.
    /// For batch: generates an OPML file URL (to be shared as attachment).
    /// Returns: either a URL (single) or a temp file URL (batch via OPML).
    static func shareLink(sources: [FeedSource]) -> ShareLinkResult {
        if sources.count == 1, let source = sources.first {
            // Single feed: deep link. Built with URLComponents/URLQueryItem rather than by concatenating a
            // percent-encoded string: `.urlQueryAllowed` keeps `&` and `=` intact, so a feed URL carrying its
            // own query split the deep link into extra parameters and the consumer's `queryItems` read back
            // only the part before the first `&`
            // (feed.example/rss?a=1&token=… → "…?a=1", round-trip false). URLQueryItem encodes each value as
            // a *value*, which is what the consumer reads back.
            var components = URLComponents()
            components.scheme = "feedmine"
            components.host = "import"
            components.queryItems = [URLQueryItem(name: "url", value: source.url)]
            let link = components.url?.absoluteString ?? "feedmine://import"
            return .text("\(source.title)\n\(link)")
        }
        // Batch: generate temp OPML file for attachment
        let data = opml(sources: sources, title: "Shared Feeds")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedmine-share-\(Int(Date().timeIntervalSince1970)).opml")
        try? data.write(to: tempURL)
        return .file(tempURL, "Share \(sources.count) feeds")
    }

    enum ShareLinkResult {
        case text(String)       // Copy/paste or share as text
        case file(URL, String)  // Share as file attachment (OPML)

        var activityItems: [Any] {
            switch self {
            case .text(let string): return [string]
            case .file(let url, _): return [url]
            }
        }
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Helpers

    private static func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: Date())
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
