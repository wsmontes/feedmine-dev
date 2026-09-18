import Foundation
import GRDB

struct SearchTerm: Identifiable, Equatable, Hashable, Sendable {
    let text: String
    let isExcluded: Bool

    init?(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Only a LEADING hyphen means exclusion. Internal hyphens in terms such
        // as "post-punk", "e-mail", and "Jean-Michel" remain ordinary text.
        if trimmed.hasPrefix("-") {
            let excludedText = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !excludedText.isEmpty else { return nil }
            self.text = excludedText
            self.isExcluded = true
        } else {
            self.text = trimmed
            self.isExcluded = false
        }
    }

    init?(text: String, isExcluded: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.text = trimmed
        self.isExcluded = isExcluded
    }

    var id: String {
        "\(isExcluded ? "-" : "+")\(SearchExpression.normalized(text))"
    }

    var displayText: String {
        isExcluded ? "-\(text)" : text
    }
}

struct SearchExpression: Equatable, Hashable, Sendable {
    let requiredTerms: [String]
    let excludedTerms: [String]

    static let empty = SearchExpression(requiredTerms: [], excludedTerms: [])

    init(terms: [SearchTerm]) {
        self.init(
            requiredTerms: terms.filter { !$0.isExcluded }.map(\.text),
            excludedTerms: terms.filter(\.isExcluded).map(\.text)
        )
    }

    init(requiredTerms: [String], excludedTerms: [String]) {
        self.requiredTerms = Self.uniqueTerms(requiredTerms)
        self.excludedTerms = Self.uniqueTerms(excludedTerms)
    }

    /// Compatibility parser for existing one-line searches and previously
    /// saved Smart Feeds. Each whitespace-delimited word keeps the old AND
    /// semantics; only a hyphen at the beginning of a word makes it negative.
    init(legacyQuery: String) {
        let terms = legacyQuery
            .split(whereSeparator: \.isWhitespace)
            .compactMap { SearchTerm(input: String($0)) }
        self.init(terms: terms)
    }

    var terms: [SearchTerm] {
        requiredTerms.compactMap { SearchTerm(text: $0, isExcluded: false) }
            + excludedTerms.compactMap { SearchTerm(text: $0, isExcluded: true) }
    }

    var isEmpty: Bool {
        requiredTerms.isEmpty && excludedTerms.isEmpty
    }

    /// A negative-only query would mean "download everything except…", which
    /// is not a bounded search. At least one positive tag starts the search.
    var canSearch: Bool {
        !requiredTerms.isEmpty
    }

    var displayQuery: String {
        terms.map(\.displayText).joined(separator: " ")
    }

    func matches(_ text: String) -> Bool {
        let searchable = Self.normalized(text)
        return requiredTerms.allSatisfy {
            searchable.contains(Self.normalized($0))
        } && excludedTerms.allSatisfy {
            !searchable.contains(Self.normalized($0))
        }
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { raw in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            return seen.insert(normalized(term)).inserted ? term : nil
        }
    }
}

struct SourceSearchResult: Equatable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let feedURL: String
    let siteURL: String?
    let displayHost: String?
    let mediaKind: MediaKind
    let language: String?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let qualityScore: Int?
    let defaultEnabled: Bool

    var sourceReference: SourceReference {
        SourceReference(
            title: title,
            feedURL: feedURL,
            siteURL: siteURL,
            displayHost: displayHost,
            mediaKind: mediaKind,
            language: language,
            sourceDescription: sourceDescription,
            tags: tags,
            nature: nature,
            activity: activity,
            qualityScore: qualityScore,
            defaultEnabled: defaultEnabled
        )
    }
}

struct UnifiedSearchResults: Equatable, Sendable {
    var sources: [SourceSearchResult]
    var savedItems: [FeedItem]
    var localItems: [FeedItem]

    static let empty = UnifiedSearchResults(sources: [], savedItems: [], localItems: [])
    var isEmpty: Bool { sources.isEmpty && savedItems.isEmpty && localItems.isEmpty }
}

@MainActor
final class SearchEngine {
    let db: DatabaseQueue
    private let userDB: DatabaseQueue?
    private var catalogDB: DatabaseQueue?

    /// The canonical content index, present exactly when the launch's runtime owns acquisition
    /// (`v2Full`), installed through `FeedStore.useCanonicalContentSearch`. Nil in every other mode:
    /// the runtime database is then either not populated (`legacy`) or not the search's authority
    /// (`mirroredShadow`), and the legacy `feed_item_fts` stays the index with content in it.
    var canonicalContentSearch: CanonicalContentSearch?

    /// The result bound of the canonical read, matching the legacy read's own bound so switching
    /// source cannot silently change how many local results a search can show.
    static let localContentLimit = 180
    /// How many of them the search list shows.
    static let localContentResultCount = 100

    init(db: DatabaseQueue, userDB: DatabaseQueue? = nil, catalogURL: URL? = nil) {
        self.db = db
        self.userDB = userDB
        if let catalogURL {
            var configuration = Configuration()
            configuration.readonly = true
            self.catalogDB = try? DatabaseQueue(path: catalogURL.path, configuration: configuration)
        } else {
            self.catalogDB = nil
        }
    }

    /// Switch source search to a newly activated local catalog. Existing
    /// searches retain their queue until they finish; subsequent searches use
    /// the new snapshot.
    func replaceCatalog(at catalogURL: URL?) {
        guard let catalogURL else {
            catalogDB = nil
            return
        }
        var configuration = Configuration()
        configuration.readonly = true
        catalogDB = try? DatabaseQueue(path: catalogURL.path, configuration: configuration)
    }

    /// Search is intentionally tiered by user value:
    /// 1. content-analyzed sources and their tags;
    /// 2. items explicitly saved by the user;
    /// 3. everything still present in the local content index — the canonical `origin_search` in a
    ///    launch whose runtime owns acquisition, the legacy `feed_item_fts` in every other mode —
    ///    including previously opened items, without the old 30-day search cutoff.
    func unifiedSearch(
        _ query: String,
        includeSources: Bool = true,
        includeContents: Bool = true
    ) async -> UnifiedSearchResults {
        await unifiedSearch(
            SearchExpression(legacyQuery: query),
            includeSources: includeSources,
            includeContents: includeContents
        )
    }

    func unifiedSearch(
        _ expression: SearchExpression,
        includeSources: Bool = true,
        includeContents: Bool = true
    ) async -> UnifiedSearchResults {
        guard expression.canSearch, includeSources || includeContents else {
            return .empty
        }

        let sourceResults = includeSources ? await searchSources(expression) : []
        let savedIDs = includeContents ? await loadBookmarkedIDs() : []
        let savedRecords = includeContents
            ? await searchSavedRecords(expression, itemIDs: savedIDs)
            : []
        let localItems = includeContents
            ? await localContentItems(expression, excluding: savedIDs)
            : []
        return UnifiedSearchResults(
            sources: sourceResults,
            savedItems: savedRecords.prefix(40).map {
                $0.toFeedItem().stamped(
                    readItemIDs: $0.isRead ? [$0.id] : [],
                    bookmarkItemIDs: [$0.id]
                )
            },
            localItems: localItems
        )
    }

    /// The local content half of a search: the canonical index when the launch's runtime owns
    /// acquisition, the legacy `feed_item_fts` otherwise.
    ///
    /// The two are an either/or by construction, not a fallback. `canonicalContentSearch` is installed
    /// by the composition that also closes the legacy producers (plan §14 PR-14 clause two), so the mode
    /// that reads `origin_search` is exactly the mode that fills it; `legacy` never populates a runtime
    /// database, and a shadow launch has no authority to search. Falling back on an empty canonical
    /// index would answer from a database no producer in that mode is refreshing.
    private func localContentItems(
        _ expression: SearchExpression,
        excluding savedIDs: Set<String>
    ) async -> [FeedItem] {
        if let canonicalContentSearch {
            let items = await canonicalContentSearch.items(
                matching: Self.canonicalContentFTSQuery(for: expression),
                limit: Self.localContentLimit
            )
            return Array(items.filter { !savedIDs.contains($0.id) }.prefix(Self.localContentResultCount))
        }
        let records = await searchLocalRecords(expression)
        return Array(
            records
                .filter { !savedIDs.contains($0.id) }
                .prefix(Self.localContentResultCount)
                .map {
                    $0.toFeedItem().stamped(
                        readItemIDs: $0.isRead ? [$0.id] : [],
                        bookmarkItemIDs: []
                    )
                }
        )
    }

    private func searchSavedRecords(
        _ expression: SearchExpression,
        itemIDs: Set<String>
    ) async -> [FeedItemRecord] {
        guard !itemIDs.isEmpty else { return [] }
        let match = Self.contentFTSQuery(for: expression)
        let allIDs = Array(itemIDs)
        let records: [FeedItemRecord] = (try? await db.read { db in
            var matches: [FeedItemRecord] = []
            // Stay below SQLite's bound-variable limit even for large bookmark libraries.
            for start in stride(from: 0, to: allIDs.count, by: 400) {
                let chunk = Array(allIDs[start..<min(start + 400, allIDs.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                matches.append(contentsOf: try FeedItemRecord.fetchAll(db, sql: """
                    SELECT fi.*
                    FROM feed_item fi
                    JOIN feed_item_fts ON feed_item_fts.rowid = fi.rowid
                    WHERE feed_item_fts MATCH ? AND fi.id IN (\(placeholders))
                    ORDER BY fi.published_at DESC
                    LIMIT 40
                    """, arguments: StatementArguments([match] + chunk)))
            }
            return Array(matches.sorted { $0.publishedAt > $1.publishedAt }.prefix(40))
        }) ?? []
        return records.filter {
            expression.matches([$0.title, $0.excerpt].joined(separator: " "))
        }
    }

    private func loadBookmarkedIDs() async -> Set<String> {
        guard let userDB else { return [] }
        return (try? await userDB.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item"))
        }) ?? []
    }

    private func searchLocalRecords(_ expression: SearchExpression) async -> [FeedItemRecord] {
        let match = Self.contentFTSQuery(for: expression)
        let records: [FeedItemRecord] = (try? await db.read { db in
            try FeedItemRecord.fetchAll(db, sql: """
                SELECT fi.*
                FROM feed_item fi
                JOIN feed_item_fts ON feed_item_fts.rowid = fi.rowid
                WHERE feed_item_fts MATCH ?
                ORDER BY fi.published_at DESC
                LIMIT 180
                """, arguments: [match])
        }) ?? []
        return records.filter {
            expression.matches([$0.title, $0.excerpt].joined(separator: " "))
        }.sorted { lhs, rhs in
            let lhsHistory = lhs.openedAt != nil || lhs.isRead
            let rhsHistory = rhs.openedAt != nil || rhs.isRead
            if lhsHistory != rhsHistory { return lhsHistory }
            return lhs.publishedAt > rhs.publishedAt
        }
    }

    private func searchSources(_ expression: SearchExpression) async -> [SourceSearchResult] {
        guard let catalogDB else { return [] }
        let match = Self.ftsQuery(
            requiredTerms: expression.requiredTerms,
            excludedTerms: expression.excludedTerms
        )
        let results: [SourceSearchResult] = (try? await catalogDB.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    s.id, s.title, s.request_url, s.site_url, s.display_host,
                    s.media_kind, s.language, s.description, s.tags, s.nature,
                    s.activity, s.quality_score, s.default_enabled
                FROM catalog_source_fts
                JOIN catalog_source s ON s.id = catalog_source_fts.rowid
                WHERE catalog_source_fts MATCH ?
                ORDER BY
                    bm25(catalog_source_fts, 9.0, 2.5, 6.0, 1.0, 1.0, 1.0, 3.0),
                    s.default_enabled DESC,
                    s.quality_score DESC,
                    s.title COLLATE NOCASE
                LIMIT 200
                """, arguments: [match])
            return rows.map { row in
                let rawTags: String? = row["tags"]
                let kindValue: String = row["media_kind"]
                let enabled: Int = row["default_enabled"] ?? 1
                return SourceSearchResult(
                    id: row["id"],
                    title: row["title"],
                    feedURL: row["request_url"],
                    siteURL: row["site_url"],
                    displayHost: row["display_host"],
                    mediaKind: MediaKind(rawValue: kindValue) ?? .text,
                    language: row["language"],
                    sourceDescription: row["description"],
                    tags: (rawTags ?? "").split(separator: ",").map(String.init),
                    nature: row["nature"],
                    activity: row["activity"],
                    qualityScore: row["quality_score"],
                    defaultEnabled: enabled != 0
                )
            }
        }) ?? []
        return results.filter { result in
            expression.matches([
                result.title,
                result.feedURL,
                result.siteURL ?? "",
                result.displayHost ?? "",
                result.sourceDescription ?? "",
                result.tags.joined(separator: " "),
                result.nature ?? "",
                result.activity ?? "",
            ].joined(separator: " "))
        }
    }

    private static func ftsQuery(
        requiredTerms: [String],
        excludedTerms: [String]
    ) -> String {
        let escapedTerms = requiredTerms
            .map { term in
                "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
        let exclusions = excludedTerms.map { term in
            "NOT \"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return escapedTerms.isEmpty
            ? "\"\""
            : (escapedTerms + exclusions).joined(separator: " ")
    }

    /// The content scope is deliberately limited to article title + excerpt.
    /// Source title/category live in the same physical FTS table for legacy
    /// reasons, but belong exclusively to the Sources search scope.
    private static func contentFTSQuery(for expression: SearchExpression) -> String {
        let query = ftsQuery(
            requiredTerms: expression.requiredTerms,
            excludedTerms: expression.excludedTerms
        )
        return "{title excerpt} : (\(query))"
    }

    /// The `MATCH` string for the canonical content index (plan §14 PR-14 clause two).
    ///
    /// `origin_search` has a single column — the current revision's `search_projection`, which
    /// Admission builds from the headline, the summary and the body — so the query needs no scope
    /// prefix. That is the whole difference from `contentFTSQuery`: one physical table carrying several
    /// scopes needs the filter, one column holding one scope must not have it.
    static func canonicalContentFTSQuery(for expression: SearchExpression) -> String {
        ftsQuery(requiredTerms: expression.requiredTerms, excludedTerms: expression.excludedTerms)
    }

    // Legacy entry points remain for persistent-search callers and tests.
    func search(_ query: String, region: String?, category: String?) async -> [FeedItem] {
        let unified = await unifiedSearch(query)
        let results = unified.savedItems + unified.localItems
        return results.filter { item in
            (region == nil || item.region == region) && (category == nil || item.category == category)
        }
    }

    func search(_ query: String, region: String?, taxonomyNodeIDs: Set<String>) async -> [FeedItem] {
        let unified = await unifiedSearch(query)
        let results = unified.savedItems + unified.localItems
        return results.filter { item in
            guard region == nil || item.region == region else { return false }
            guard !taxonomyNodeIDs.isEmpty else { return true }
            return taxonomyNodeIDs.contains { nodeID in
                TaxonomyStore.shared.isFeedInSubtree(feedURL: item.sourceURL, nodeID: nodeID)
            }
        }
    }
}
