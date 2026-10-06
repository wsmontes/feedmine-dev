import Foundation
import CryptoKit

struct FeedItem: Identifiable, Sendable, Codable, Equatable {
    let id: String
    let sourceTitle: String
    let sourceURL: String
    let category: String
    let title: String
    let excerpt: String
    let url: String
    var imageURL: String?
    let publishedAt: Date
    let audioURL: String?
    let duration: TimeInterval?
    let region: String   // "global" | "countries/brazil/sao-paulo"
    let language: String?  // ISO 639-1 code from OPML or NLLanguageRecognizer

    // --- NEW metadata fields (all optional, NULL-able in DB) ---
    let updatedAt: Date?
    let authors: [FeedItemAuthor]?
    let itemCategories: [FeedItemCategory]?
    let rights: String?
    let attribution: FeedItemAttribution?
    let enclosures: [FeedEnclosure]?
    let languageFromFeed: String?
    let alternateLinks: [FeedAlternateLink]?

    /// Snapshot of read state at render time — avoids mass view invalidation
    /// when another item is read. Updated via FeedStore when visible items change.
    var isRead: Bool = false
    /// Snapshot of bookmark state at render time. Same rationale as isRead.
    var isBookmarked: Bool = false

    /// Pre-computed day offset from today (0 = today, 1 = yesterday, 2-7 = this
    /// week, 8+ = earlier). Set once at persistence so dateSections doesn't
    /// re-run expensive Calendar operations on every scroll-driven cache miss.
    var sectionDayOffset: Int = 0

    /// Lowercased + diacritic-folded title+excerpt for fast keyword matching.
    /// Used by content filters and smart-feed matching to avoid per-pass string
    /// normalization. Computed exactly once at initialization, then read-only —
    /// every access is O(1) instead of re-normalizing per filter pass.
    let searchableText: String

    init(id: String, sourceTitle: String, sourceURL: String, category: String,
         title: String, excerpt: String, url: String, imageURL: String?,
         publishedAt: Date, audioURL: String? = nil, duration: TimeInterval? = nil,
         region: String = "global", language: String? = nil,
         updatedAt: Date? = nil,
         authors: [FeedItemAuthor]? = nil,
         itemCategories: [FeedItemCategory]? = nil,
         rights: String? = nil,
         attribution: FeedItemAttribution? = nil,
         enclosures: [FeedEnclosure]? = nil,
         languageFromFeed: String? = nil,
         alternateLinks: [FeedAlternateLink]? = nil,
         isRead: Bool = false, isBookmarked: Bool = false,
         sectionDayOffset: Int = 0) {
        self.id = id
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.category = category
        self.title = title
        self.excerpt = excerpt
        self.url = url
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.audioURL = audioURL
        self.duration = duration
        self.region = region
        self.language = language
        self.updatedAt = updatedAt
        self.authors = authors
        self.itemCategories = itemCategories
        self.rights = rights
        self.attribution = attribution
        self.enclosures = enclosures
        self.languageFromFeed = languageFromFeed
        self.alternateLinks = alternateLinks
        self.isRead = isRead
        self.isBookmarked = isBookmarked
        self.sectionDayOffset = sectionDayOffset
        self.searchableText = (title + " " + excerpt)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    /// True if this article links to a YouTube video
    var isYouTube: Bool { youTubeVideoID != nil }

    /// True if this item comes from a forum source (Reddit)
    var isForum: Bool { sourceURL.contains("reddit.com/r/") }

    /// Extracts the YouTube video ID from the URL, if any.
    ///
    /// Validates the host against known YouTube domains (exact match or
    /// `.youtube.com` / `.youtu.be` suffix — rejects spoofed hosts like
    /// `youtube.com.evil.example`). Rejects bare-host youtu.be URLs
    /// (`"/"` is not a valid video ID) and IDs that would produce malformed
    /// thumbnail URLs.
    var youTubeVideoID: String? {
        // Fast reject before allocating URL/URLComponents: this is called per
        // item during filtering, interleaving, isTimeless, and rendering, and
        // almost no items are YouTube links. "youtu" covers youtube.com and
        // youtu.be, and the host checks below still gate real matches.
        guard url.contains("youtu") else { return nil }
        guard let parsed = URL(string: url) else { return nil }
        let host = parsed.host?.lowercased()

        // Exact host or subdomain suffix — rejects youtube.com.evil.example.
        let isYT = host == "youtube.com" || host == "youtu.be"
            || host?.hasSuffix(".youtube.com") == true
            || host?.hasSuffix(".youtu.be") == true
        guard isYT, let host else { return nil }

        // youtu.be/VIDEO_ID — single path segment after the host.
        if host.hasSuffix("youtu.be") {
            // pathComponents for "https://youtu.be/" is ["/"]; for
            // "https://youtu.be/abc123" it's ["/", "abc123"].
            // Drop the root "/" and take the first real segment.
            let segments = parsed.pathComponents.dropFirst()  // skip "/"
            guard let id = segments.first, !id.isEmpty, id != "/" else { return nil }
            // youtu.be/abc123/extra → only take the first segment.
            return id
        }

        // youtube.com/shorts/VIDEO_ID — second path component after root.
        let components = parsed.pathComponents
        if components.count >= 3 && components[1] == "shorts" {
            let id = components[2]
            guard !id.isEmpty, id != "/" else { return nil }
            return id
        }
        // youtube.com/watch?v=VIDEO_ID — query parameter.
        if let urlComponents = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
           let queryItems = urlComponents.queryItems,
           let videoID = queryItems.first(where: { $0.name == "v" })?.value,
           !videoID.isEmpty {
            return videoID
        }
        return nil
    }

    /// YouTube thumbnail URL — sddefault.jpg (640×480) is more reliable than
    /// maxresdefault (gray placeholder for non-1080p) and better than hqdefault (480×360).
    var youTubeThumbnailURL: String? {
        guard let videoID = youTubeVideoID else { return nil }
        return "https://img.youtube.com/vi/\(videoID)/sddefault.jpg"
    }

    /// Best available image URL.
    ///
    /// YouTube videos: always use the YouTube thumbnail first. Channel feeds are
    /// Atom with ``media:group/media:thumbnail`` — FeedKit never populates
    /// ``imageURL`` from that path, so the RSS image is always nil. Even when a
    /// non-YouTube feed links to a YouTube URL, the thumbnail is the best
    /// representation of the video.
    ///
    /// Non-YouTube: feed-supplied image (typically 1200×800+ article artwork)
    /// takes priority. Returns nil when neither source is available.
    var bestImageURL: String? {
        if let yt = youTubeThumbnailURL { return yt }
        if let img = imageURL, !img.isEmpty { return img }
        return nil
    }

    /// Direct article pages can often supply Open Graph or responsive artwork
    /// even when their feeds omit media or serve only thumbnails/logos.
    /// Always attempt resolution — ImageUpgradePolicy.needsUpgrade avoids
    /// wasted fetches when the feed image is already high quality.
    /// Podcasts are included so episode pages with artwork get resolved.
    var canResolveArticleImage: Bool {
        guard let articleURL = URL(string: url),
              ["http", "https"].contains(articleURL.scheme?.lowercased() ?? ""),
              articleURL.host?.lowercased() != "news.google.com" else { return false }
        return true
    }

    var hasPotentialImage: Bool {
        bestImageURL != nil || canResolveArticleImage
    }

    /// True if this item has an audio enclosure (podcast episode)
    var isPodcast: Bool { audioURL != nil }

    /// True when the article URL itself is a direct audio file — no page to open.
    /// Extracts the path extension from the URL (ignoring query strings and
    /// fragments) and lowercases it, so signed CDN URLs like
    /// `…/ep.mp3?token=abc` are correctly identified as direct audio.
    var isDirectAudioLink: Bool {
        let lower = URLComponents(string: url)?.path.lowercased()
            ?? url.lowercased()
        let audioExts: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "flac", "opus"]
        return audioExts.contains((lower as NSString).pathExtension)
    }

    /// URL that can be handed to AVFoundation. Podcast feeds occasionally
    /// publish protocol-relative or feed-relative enclosure URLs.
    var audioPlaybackURL: URL? {
        Self.resolvedMediaURL(from: audioURL, baseURL: sourceURL)
    }

    /// Atemporal content (blogs, science, tutorials) ages slowly.
    /// News and sports are time-sensitive. Used for stale cutoff and sorting.
    /// Video and podcast content is always timeless regardless of category —
    /// a sports podcast should not get a news-aggressive eviction window.
    var isTimeless: Bool {
        if isYouTube || isPodcast { return true }
        let lower = category.lowercased()
        // Check timeless categories first, then time-sensitive.
        // Word-boundary matching avoids false positives ("agriculture" ≠ "culture").
        let timelessCategories: Set<String> = [
            "blog", "science", "tech", "programming", "culture",
            "history", "design", "food", "diy", "music", "movie",
            "photography", "travel", "environment", "architecture",
        ]
        if timelessCategories.contains(where: { lower.contains($0) }) { return true }
        let timelyCategories: Set<String> = ["news", "sport"]
        if timelyCategories.contains(where: { lower.contains($0) }) { return false }
        return false
    }

    /// Formatted duration string, e.g. "34 min".
    /// Returns nil for sub-minute durations (avoiding "0 min" labels).
    var durationFormatted: String? {
        // `d >= 60` is false for NaN but TRUE for +inf, and Int(_:) traps on infinity —
        // episode durations arrive from feed metadata, so check finiteness explicitly.
        guard let d = duration, d.isFinite, d >= 60 else { return nil }
        let mins = Int(d / 60)
        if mins < 60 { return "\(mins) min" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem > 0 ? "\(hrs)h \(rem)m" : "\(hrs)h"
    }

    /// A copy with audio stripped — used when an enclosure fails playability
    /// validation, so the item is no longer treated as a podcast.
    /// Preserves read/bookmark state and sectionDayOffset so this can safely
    /// be called on already-stamped or persisted items (not just parse-time).
    /// Also removes the matching audio enclosure from `enclosures` so the
    /// persisted record stays consistent (isPodcast==false, no audio enclosure).
    func withoutAudio() -> FeedItem {
        var filteredEnclosures = enclosures
        if let stripped = audioURL {
            let resolved = Self.resolvedMediaURL(from: stripped, baseURL: sourceURL)
            filteredEnclosures = enclosures?.filter { enclosure in
                Self.resolvedMediaURL(from: enclosure.url, baseURL: sourceURL) != resolved
            }
        }
        return FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: nil, duration: nil, region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: filteredEnclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: isRead, isBookmarked: isBookmarked,
            sectionDayOffset: sectionDayOffset
        )
    }

    /// Immutable copy with region and language replaced — used by
    /// persistFetchedItems so the returned item matches exactly what
    /// was written to SQLite. Both parameters are always provided;
    /// there is no "keep current value" sentinel.
    func replacingMetadata(region: String, language: String?) -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: isRead,
            isBookmarked: isBookmarked,
            sectionDayOffset: sectionDayOffset
        )
    }

    /// Returns a copy with the sourceURL normalized via OPMLParser.normalizeURL.
    /// All hot-path comparisons (applyFilters, taxonomy matching) then use
    /// pre-normalized strings — no runtime normalization per comparison.
    var withNormalizedSourceURL: FeedItem {
        let normalized = OPMLParser.normalizeURL(sourceURL)
        guard normalized != sourceURL else { return self }
        return FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: normalized, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: isRead,
            isBookmarked: isBookmarked,
            sectionDayOffset: sectionDayOffset
        )
    }

    /// Returns a copy with the sectionDayOffset set. Used during persistence
    /// to pre-compute date sections once instead of per scroll-cache-miss.
    func withSectionDayOffset(_ offset: Int) -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region, language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: isRead, isBookmarked: isBookmarked,
            sectionDayOffset: offset
        )
    }

    /// Returns a copy with isRead/isBookmarked stamped from the given sets.
    func stamped(readItemIDs: Set<String>, bookmarkItemIDs: Set<String>) -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: readItemIDs.contains(id),
            isBookmarked: bookmarkItemIDs.contains(id),
            sectionDayOffset: sectionDayOffset
        )
    }

    /// Mutates isRead/isBookmarked in-place from the given sets.
    /// Used in hot paths (setVisibleItems) to avoid 300+ full-struct copies
    /// per scroll page on @MainActor.
    mutating func stamp(readItemIDs: Set<String>, bookmarkItemIDs: Set<String>) {
        isRead = readItemIDs.contains(id)
        isBookmarked = bookmarkItemIDs.contains(id)
    }

    static func resolvedMediaURL(from rawValue: String?, baseURL: String? = nil) -> URL? {
        guard var raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        raw = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")

        let base = baseURL.flatMap(URL.init(string:))
        if raw.hasPrefix("//") {
            raw = "\(base?.scheme ?? "https"):\(raw)"
        }

        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    /// SHA256("sourceURL|guid_or_link") — unique across feeds
    static func generateID(sourceURL: String, guid: String?, link: String?, title: String? = nil, publishedAt: Date? = nil) -> String {
        let token: String = {
            if let guid = guid, !guid.isEmpty { return guid }
            if let link = link, !link.isEmpty { return link }
            // Fallback: source + title + timestamp — imperfect but prevents data loss
            let ts = publishedAt.map { String($0.timeIntervalSince1970) } ?? "0"
            let t = title ?? "untitled"
            return "\(t)|\(ts)"
        }()
        let raw = "\(sourceURL)|\(token)"
        let data = Data(raw.utf8)
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - New metadata types

struct FeedItemAuthor: Codable, Sendable, Equatable {
    let name: String?
    let email: String?
    let uri: String?
}

struct FeedItemCategory: Codable, Sendable, Equatable {
    let term: String
    let scheme: String?
    let label: String?
}

struct FeedItemAttribution: Codable, Sendable, Equatable {
    let title: String?
    let url: String?
    let feedURL: String?
}

struct FeedEnclosure: Codable, Sendable, Equatable {
    let url: String
    let mimeType: String?
    let length: Int64?
    let duration: TimeInterval?
    let medium: String?
}

struct FeedAlternateLink: Codable, Sendable, Equatable {
    let url: String
    let mimeType: String?
    let language: String?
    let rel: String?
}

struct ParsedItemMetadata {
    let authors: [FeedItemAuthor]?
    let categories: [FeedItemCategory]?
    let rights: String?
    let attribution: FeedItemAttribution?
    let enclosures: [FeedEnclosure]?
    let language: String?
    let alternateLinks: [FeedAlternateLink]?
    let publishedAt: Date?
    let updatedAt: Date?

    init(
        authors: [FeedItemAuthor]? = nil,
        categories: [FeedItemCategory]? = nil,
        rights: String? = nil,
        attribution: FeedItemAttribution? = nil,
        enclosures: [FeedEnclosure]? = nil,
        language: String? = nil,
        alternateLinks: [FeedAlternateLink]? = nil,
        publishedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.authors = authors
        self.categories = categories
        self.rights = rights
        self.attribution = attribution
        self.enclosures = enclosures
        self.language = language
        self.alternateLinks = alternateLinks
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
    }
}
