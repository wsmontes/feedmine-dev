import CryptoKit
import Foundation
import GRDB

enum CatalogCompilationInput: Sendable {
    case occurrences([CatalogSourceOccurrence])
    case opmlRoot(URL)
    case legacySources([FeedSource])

    func loadOccurrences() throws -> [CatalogSourceOccurrence] {
        switch self {
        case .occurrences(let occurrences):
            return occurrences
        case .opmlRoot(let rootURL):
            return try OPMLCatalogScanner(rootURL: rootURL).scan()
        case .legacySources(let sources):
            return sources.enumerated().map { index, source in
                CatalogSourceOccurrence.legacySource(source, sortOrder: index)
            }
        }
    }
}

struct SQLiteCatalogCompiler: CatalogCompiler {
    let input: CatalogCompilationInput
    let databaseURL: URL

    init(input: CatalogCompilationInput, databaseURL: URL) {
        self.input = input
        self.databaseURL = databaseURL
    }

    func compileFull() async throws -> CatalogCompileReport {
        try await compile(mode: .full, changedFileCount: 0, deletedFileCount: 0)
    }

    func compileIncremental(changes: [CatalogFileChange]) async throws -> CatalogCompileReport {
        // First implementation keeps publication semantics while recompiling
        // the complete fixture/corpus. A later compiler can replace this body
        // with file-fingerprint deltas behind the same protocol.
        try await compile(
            mode: .incremental,
            changedFileCount: changes.filter { $0.change != .deleted }.count,
            deletedFileCount: changes.filter { $0.change == .deleted }.count
        )
    }

    private func compile(
        mode: CatalogCompileReport.Mode,
        changedFileCount: Int,
        deletedFileCount: Int
    ) async throws -> CatalogCompileReport {
        let started = Date()
        let occurrences = try input.loadOccurrences()
        let tmpURL = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(databaseURL.lastPathComponent).tmp")

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: tmpURL)

        let dbQueue = try DatabaseQueue(path: tmpURL.path)
        try await dbQueue.write { db in
            try SQLiteCatalogSchema.create(in: db)
            try Self.writeCatalog(occurrences: occurrences, db: db)
        }
        try dbQueue.close()

        if FileManager.default.fileExists(atPath: databaseURL.path) {
            _ = try FileManager.default.replaceItemAt(databaseURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: databaseURL)
        }

        let report = try await SQLiteCatalogRepository(databaseURL: databaseURL).compileReport(
            mode: mode,
            changedFileCount: changedFileCount,
            deletedFileCount: deletedFileCount,
            elapsed: Date().timeIntervalSince(started)
        )
        return report
    }

    private static func writeCatalog(occurrences: [CatalogSourceOccurrence], db: Database) throws {
        var sourceKeyByID: [SourceID: SourceKey] = [:]
        var nodeKeyByID: [CatalogNodeID: NodeKey] = [.root: NodeKey("root")]
        var sourceCanonical: [SourceKey: CompiledSource] = [:]
        var nodes: [NodeKey: CompiledNode] = [
            NodeKey("root"): CompiledNode(id: .root, key: NodeKey("root"), parentID: nil, name: "Root", kind: .topic, language: nil)
        ]
        var placements: [CompiledPlacement] = []
        var nodeSourceSets: [CatalogNodeID: Set<SourceID>] = [:]
        var sourcePlacementCount: [SourceID: Int] = [:]

        for occurrence in occurrences {
            guard !occurrence.nodePath.isEmpty else { continue }
            let sourceKey = CatalogIdentity.sourceKey(for: occurrence.declaredURL)
            let sourceID = CatalogIdentity.sourceID(for: sourceKey)
            try register(id: sourceID, key: sourceKey, in: &sourceKeyByID)

            sourceCanonical[sourceKey] = sourceCanonical[sourceKey] ?? CompiledSource(
                id: sourceID,
                key: sourceKey,
                title: occurrence.title,
                declaredURL: occurrence.declaredURL,
                requestURL: occurrence.requestURL,
                displayHost: CatalogIdentity.displayHost(for: occurrence.declaredURL),
                mediaKind: occurrence.mediaKind,
                language: occurrence.language,
                siteURL: occurrence.siteURL,
                sourceDescription: occurrence.sourceDescription,
                tags: occurrence.tags,
                nature: occurrence.nature,
                activity: occurrence.activity,
                latestItemAt: occurrence.latestItemAt,
                qualityScore: occurrence.qualityScore,
                defaultEnabled: occurrence.defaultEnabled,
                contactEmail: occurrence.contactEmail,
                contactName: occurrence.contactName,
                contactSource: occurrence.contactSource,
                contactType: occurrence.contactType
            )

            var parentID = CatalogNodeID.root
            var pathComponents: [String] = []
            var ancestorIDs: [CatalogNodeID] = [.root]
            for inputNode in occurrence.nodePath {
                pathComponents.append(inputNode.keyComponent)
                let nodeKey = CatalogIdentity.nodeKey(pathComponents: pathComponents)
                let nodeID = CatalogIdentity.nodeID(for: nodeKey)
                try register(id: nodeID, key: nodeKey, in: &nodeKeyByID)
                if nodes[nodeKey] == nil {
                    nodes[nodeKey] = CompiledNode(
                        id: nodeID,
                        key: nodeKey,
                        parentID: parentID,
                        name: inputNode.name,
                        kind: inputNode.kind,
                        language: inputNode.language
                    )
                }
                parentID = nodeID
                ancestorIDs.append(nodeID)
            }

            let placementID = Int64(placements.count + 1)
            placements.append(CompiledPlacement(
                id: placementID,
                sourceID: sourceID,
                nodeID: parentID,
                nodeName: occurrence.nodePath.last?.name ?? "Untitled",
                opmlFile: occurrence.opmlFile,
                sortOrder: occurrence.sortOrder,
                titleOverride: occurrence.titleOverride,
                languageOverride: occurrence.languageOverride,
                mediaKindOverride: occurrence.mediaKindOverride
            ))
            sourcePlacementCount[sourceID, default: 0] += 1
            for ancestorID in ancestorIDs {
                nodeSourceSets[ancestorID, default: []].insert(sourceID)
            }
        }

        let childCounts = Dictionary(grouping: nodes.values.compactMap(\.parentID), by: { $0 })
            .mapValues(\.count)

        try insertMetadata(db: db, sourceCount: sourceCanonical.count, nodeCount: nodes.count, placementCount: placements.count)
        for source in sourceCanonical.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            try insertSource(source, db: db)
        }
        for node in nodes.values.sorted(by: nodeInsertionOrder) {
            try insertNode(
                node,
                sourceCount: nodeSourceSets[node.id]?.count ?? 0,
                childCount: childCounts[node.id] ?? 0,
                db: db
            )
        }
        for placement in placements {
            try insertPlacement(placement, db: db)
        }
        try insertFTS(
            sources: Array(sourceCanonical.values),
            placements: placements,
            nodesByID: Dictionary(uniqueKeysWithValues: nodes.values.map { ($0.id, $0) }),
            db: db
        )
        try db.execute(
            sql: "INSERT OR REPLACE INTO catalog_metadata (key, value) VALUES ('duplicate_occurrence_count', ?)",
            arguments: [placements.count - sourceCanonical.count]
        )
    }

    private static func nodeInsertionOrder(_ lhs: CompiledNode, _ rhs: CompiledNode) -> Bool {
        let lhsDepth = nodeDepth(lhs)
        let rhsDepth = nodeDepth(rhs)
        if lhsDepth != rhsDepth {
            return lhsDepth < rhsDepth
        }
        return lhs.key.rawValue < rhs.key.rawValue
    }

    private static func nodeDepth(_ node: CompiledNode) -> Int {
        if node.parentID == nil { return 0 }
        return node.key.rawValue.split(separator: "/").count
    }

    private static func register<Key: RawRepresentable>(
        id: SourceID,
        key: Key,
        in registry: inout [SourceID: Key]
    ) throws where Key.RawValue == String {
        if let existing = registry[id], existing.rawValue != key.rawValue {
            throw FeedEngineError.identityCollision(kind: "source", id: id.rawValue, existingKey: existing.rawValue, newKey: key.rawValue)
        }
        registry[id] = key
    }

    private static func register<Key: RawRepresentable>(
        id: CatalogNodeID,
        key: Key,
        in registry: inout [CatalogNodeID: Key]
    ) throws where Key.RawValue == String {
        if let existing = registry[id], existing.rawValue != key.rawValue {
            throw FeedEngineError.identityCollision(kind: "node", id: id.rawValue, existingKey: existing.rawValue, newKey: key.rawValue)
        }
        registry[id] = key
    }

    private static func insertMetadata(db: Database, sourceCount: Int, nodeCount: Int, placementCount: Int) throws {
        let catalogVersion = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded())
        let values: [(String, String)] = [
            ("schema_version", "2"),
            ("catalog_version", "\(catalogVersion)"),
            ("source_count", "\(sourceCount)"),
            ("node_count", "\(nodeCount)"),
            ("placement_count", "\(placementCount)"),
        ]
        for value in values {
            try db.execute(sql: "INSERT INTO catalog_metadata (key, value) VALUES (?, ?)", arguments: [value.0, value.1])
        }
    }

    private static func insertSource(_ source: CompiledSource, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO catalog_source
                (id, key, title, declared_url, request_url, display_host, media_kind, language,
                 site_url, description, tags, nature, activity, latest_item_at, quality_score, default_enabled,
                 contact_email, contact_name, contact_source, contact_type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                Int64(source.id.rawValue),
                source.key.rawValue,
                source.title,
                source.declaredURL,
                source.requestURL,
                source.displayHost,
                source.mediaKind.rawValue,
                source.language,
                source.siteURL,
                source.sourceDescription,
                source.tags.joined(separator: ","),
                source.nature,
                source.activity,
                source.latestItemAt,
                source.qualityScore,
                source.defaultEnabled ? 1 : 0,
                source.contactEmail,
                source.contactName,
                source.contactSource,
                source.contactType,
            ])
    }

    private static func insertNode(_ node: CompiledNode, sourceCount: Int, childCount: Int, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO catalog_node
                (id, key, parent_id, name, kind, source_count, child_count, language)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                Int64(node.id.rawValue),
                node.key.rawValue,
                node.parentID.map { Int64($0.rawValue) },
                node.name,
                node.kind.rawValue,
                sourceCount,
                childCount,
                node.language,
            ])
    }

    private static func insertPlacement(_ placement: CompiledPlacement, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO catalog_placement
                (id, source_id, node_id, node_name, opml_file, sort_order, title_override, language_override, media_kind_override)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                placement.id,
                Int64(placement.sourceID.rawValue),
                Int64(placement.nodeID.rawValue),
                placement.nodeName,
                placement.opmlFile,
                placement.sortOrder,
                placement.titleOverride,
                placement.languageOverride,
                placement.mediaKindOverride?.rawValue,
            ])
    }

    private static func insertFTS(
        sources: [CompiledSource],
        placements: [CompiledPlacement],
        nodesByID: [CatalogNodeID: CompiledNode],
        db: Database
    ) throws {
        let pathsBySourceID = Dictionary(grouping: placements, by: \.sourceID).mapValues { placements in
            placements.compactMap { nodesByID[$0.nodeID]?.key.rawValue.replacingOccurrences(of: "/", with: " ") }
                .joined(separator: " ")
        }
        for source in sources {
            try db.execute(sql: """
                INSERT INTO catalog_source_fts
                    (rowid, title, description, tags, display_host, language, media_kind, path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    Int64(source.id.rawValue),
                    source.title,
                    source.sourceDescription ?? "",
                    source.tags.joined(separator: " "),
                    source.displayHost ?? "",
                    source.language ?? "",
                    source.mediaKind.rawValue,
                    pathsBySourceID[source.id] ?? "",
                ])
        }
    }
}

actor SQLiteCatalogRepository: FeedEngineProtocol, CatalogRepository, CatalogSearch {
    private let dbQueue: DatabaseQueue

    init(databaseURL: URL, readOnly: Bool = false) throws {
        var configuration = Configuration()
        configuration.readonly = readOnly
        self.dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    }

    func browseCatalog(query: CatalogBrowseQuery, cursor: CatalogCursor?, limit: Int) async throws -> CatalogPage {
        let pageLimit = FeedEnginePageLimit.bounded(limit)
        return try await dbQueue.read { db in
            let parentID = query.parentID ?? .root
            let catalogVersion = try Self.catalogVersion(db: db)
            try Self.validateCursor(cursor, catalogVersion: catalogVersion)
            let rows = try CatalogBrowseRow.fetchAll(
                db,
                sql: Self.browseSQL(
                    includeSources: query.includeSources,
                    hasCursor: cursor != nil,
                    language: query.language
                ),
                arguments: Self.browseArguments(
                    parentID: parentID,
                    includeSources: query.includeSources,
                    language: query.language,
                    cursor: cursor,
                    limit: pageLimit + 1
                )
            )
            return try Self.page(from: rows, catalogVersion: catalogVersion, limit: pageLimit, db: db)
        }
    }

    func searchCatalog(query: CatalogSearchQuery, cursor: CatalogCursor?, limit: Int) async throws -> CatalogPage {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return CatalogPage(nodes: [], sources: [], nextCursor: nil, estimatedTotalCount: 0)
        }

        let pageLimit = FeedEnginePageLimit.bounded(limit)
        let match = Self.ftsQuery(for: text)
        return try await dbQueue.read { db in
            let catalogVersion = try Self.catalogVersion(db: db)
            try Self.validateCursor(cursor, catalogVersion: catalogVersion)
            let rows = try CatalogBrowseRow.fetchAll(
                db,
                sql: Self.searchSQL(filters: query.filters, hasCursor: cursor != nil),
                arguments: Self.searchArguments(match: match, filters: query.filters, cursor: cursor, limit: pageLimit + 1)
            )
            return try Self.page(from: rows, catalogVersion: catalogVersion, limit: pageLimit, db: db)
        }
    }

    func loadSourceDetails(sourceID: SourceID) async throws -> SourceDetails {
        try await dbQueue.read { db in
            guard let source = try CatalogSourceRecord.fetchOne(
                db,
                sql: "SELECT * FROM catalog_source WHERE id = ?",
                arguments: [Int64(sourceID.rawValue)]
            ) else {
                throw FeedEngineError.sourceNotFound(sourceID)
            }
            let placements = try SourcePlacementSummary.fetchAll(db, sql: """
                SELECT
                    p.id AS id,
                    p.node_id AS nodeID,
                    n.name AS nodeName,
                    p.opml_file AS opmlFile,
                    p.sort_order AS sortOrder,
                    p.title_override AS titleOverride,
                    p.language_override AS languageOverride,
                    p.media_kind_override AS mediaKindOverride
                FROM catalog_placement p
                JOIN catalog_node n ON n.id = p.node_id
                WHERE p.source_id = ?
                ORDER BY p.opml_file, p.sort_order, p.id
                """, arguments: [Int64(sourceID.rawValue)])
            guard let declaredURL = URL(string: source.declaredURL),
                  let requestURL = URL(string: source.requestURL) else {
                throw FeedEngineError.invalidCatalog("Invalid URL stored for source \(sourceID.rawValue)")
            }
            return SourceDetails(
                id: source.id,
                title: source.title,
                declaredURL: declaredURL,
                requestURL: requestURL,
                mediaKind: source.mediaKind,
                language: source.language,
                siteURL: source.siteURL.flatMap(URL.init(string:)),
                sourceDescription: source.sourceDescription,
                tags: source.tags,
                nature: source.nature,
                activity: source.activity,
                latestItemAt: source.latestItemAt,
                qualityScore: source.qualityScore,
                defaultEnabled: source.defaultEnabled,
                contactEmail: source.contactEmail,
                contactName: source.contactName,
                contactSource: source.contactSource,
                contactType: source.contactType,
                placements: placements
            )
        }
    }

    func loadTimeline(query: ContentQuery, cursor: TimelineCursor?, limit: Int) async throws -> TimelinePage {
        throw FeedEngineError.unsupportedTimelineRepository
    }

    func compileReport(
        mode: CatalogCompileReport.Mode,
        changedFileCount: Int,
        deletedFileCount: Int,
        elapsed: TimeInterval
    ) async throws -> CatalogCompileReport {
        try await dbQueue.read { db in
            let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog_source") ?? 0
            let nodeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog_node") ?? 0
            let placementCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalog_placement") ?? 0
            let duplicateCount = try Int.fetchOne(db, sql: "SELECT MAX(CAST(value AS INTEGER), 0) FROM catalog_metadata WHERE key = 'duplicate_occurrence_count'") ?? 0
            return CatalogCompileReport(
                mode: mode,
                catalogVersion: try Self.catalogVersion(db: db),
                sourceCount: sourceCount,
                nodeCount: nodeCount,
                placementCount: placementCount,
                aliasCount: 0,
                duplicateOccurrenceCount: duplicateCount,
                invalidSourceCount: 0,
                changedFileCount: changedFileCount,
                deletedFileCount: deletedFileCount,
                failedFileCount: 0,
                logicalDigest: try Self.logicalDigest(db: db),
                elapsed: elapsed
            )
        }
    }

    private static func page(
        from rows: [CatalogBrowseRow],
        catalogVersion: Int64,
        limit: Int,
        db: Database
    ) throws -> CatalogPage {
        let pageRows = Array(rows.prefix(limit))
        let overflow = rows.count > limit ? rows[limit - 1] : nil
        var nodes: [CatalogNodeSummary] = []
        var sources: [SourceSummary] = []

        for row in pageRows {
            switch row.entityType {
            case "node":
                if let node = try CatalogNodeRecord.fetchOne(db, sql: "SELECT * FROM catalog_node WHERE id = ?", arguments: [row.entityID]) {
                    nodes.append(node.summary)
                }
            case "source":
                if let source = try CatalogSourceRecord.fetchOne(db, sql: "SELECT * FROM catalog_source WHERE id = ?", arguments: [row.entityID]) {
                    sources.append(source.summary)
                }
            default:
                break
            }
        }

        let nextCursor = overflow.map {
            CatalogCursor(catalogVersion: catalogVersion, sortKey: $0.sortKey, entityID: UInt32($0.entityID))
        }
        return CatalogPage(nodes: nodes, sources: sources, nextCursor: nextCursor, estimatedTotalCount: nil)
    }

    /// A keyset cursor is only meaningful against the catalog version that produced it.
    ///
    /// A rebuilt catalog can reuse a sort key for a different entity, so a cursor from another
    /// version would make the page silently skip or repeat rows and return a next cursor that hides
    /// the mismatch (``Pagination.swift``): reject it before the query runs.
    private static func validateCursor(_ cursor: CatalogCursor?, catalogVersion: Int64) throws {
        guard let cursor, cursor.catalogVersion != catalogVersion else { return }
        throw FeedEngineError.invalidCatalog(
            "Stale catalog cursor: cursor version \(cursor.catalogVersion), catalog version \(catalogVersion)"
        )
    }

    private static func browseSQL(includeSources: Bool, hasCursor: Bool, language: String?) -> String {
        let cursorClause = hasCursor ? "AND (sort_key > ? OR (sort_key = ? AND entity_id > ?))" : ""
        // Same rule the search path already applies (`searchSQL`): the filter is the source's own
        // language. Nodes are deliberately left unfiltered — they are this level's navigation, and a
        // node whose own language is unknown must stay reachable so its matching children can be
        // opened at all.
        let languageClause = language == nil ? "" : "AND s.language = ?"
        let sourceUnion = includeSources ? """
            UNION ALL
            SELECT DISTINCT
                'source' AS entity_type,
                s.id AS entity_id,
                '1:' || printf('%012d', MIN(p.sort_order)) || ':' || lower(COALESCE(p.title_override, s.title)) AS sort_key
            FROM catalog_placement p
            JOIN catalog_source s ON s.id = p.source_id
            WHERE p.node_id = ?
            \(languageClause)
            GROUP BY s.id
            """ : ""

        return """
            WITH entities AS (
                SELECT
                    'node' AS entity_type,
                    n.id AS entity_id,
                    '0:' || lower(n.key) AS sort_key
                FROM catalog_node n
                WHERE n.parent_id = ?
                \(sourceUnion)
            )
            SELECT entity_type, entity_id, sort_key
            FROM entities
            WHERE 1 = 1 \(cursorClause)
            ORDER BY sort_key, entity_id
            LIMIT ?
            """
    }

    private static func browseArguments(
        parentID: CatalogNodeID,
        includeSources: Bool,
        language: String?,
        cursor: CatalogCursor?,
        limit: Int
    ) -> StatementArguments {
        var args: [any DatabaseValueConvertible] = [Int64(parentID.rawValue)]
        if includeSources {
            args.append(Int64(parentID.rawValue))
            if let language {
                args.append(language)
            }
        }
        if let cursor {
            args.append(cursor.sortKey)
            args.append(cursor.sortKey)
            args.append(Int64(cursor.entityID))
        }
        args.append(limit)
        return StatementArguments(args)
    }

    private static func searchSQL(filters: CatalogSearchFilters, hasCursor: Bool) -> String {
        let cursorClause = hasCursor ? "AND (sort_key > ? OR (sort_key = ? AND s.id > ?))" : ""
        let kindClause = filters.kind == nil ? "" : "AND EXISTS (SELECT 1 FROM catalog_placement p JOIN catalog_node n ON n.id = p.node_id WHERE p.source_id = s.id AND n.kind = ?)"
        let languageClause = filters.language == nil ? "" : "AND s.language = ?"
        let regionClause = filters.region == nil ? "" : "AND EXISTS (SELECT 1 FROM catalog_placement p JOIN catalog_node n ON n.id = p.node_id WHERE p.source_id = s.id AND n.key LIKE ?)"
        return """
            SELECT
                'source' AS entity_type,
                s.id AS entity_id,
                printf('%01d:%03d:%s', CASE WHEN s.default_enabled = 1 THEN 0 ELSE 1 END,
                       100 - COALESCE(s.quality_score, 0), lower(s.title)) AS sort_key
            FROM catalog_source_fts f
            JOIN catalog_source s ON s.id = f.rowid
            WHERE catalog_source_fts MATCH ?
            \(kindClause)
            \(languageClause)
            \(regionClause)
            \(cursorClause)
            ORDER BY sort_key, s.id
            LIMIT ?
            """
    }

    private static func searchArguments(
        match: String,
        filters: CatalogSearchFilters,
        cursor: CatalogCursor?,
        limit: Int
    ) -> StatementArguments {
        var args: [any DatabaseValueConvertible] = [match]
        if let kind = filters.kind {
            args.append(kind.rawValue)
        }
        if let language = filters.language {
            args.append(language)
        }
        if let region = filters.region {
            args.append("\(region)%")
        }
        if let cursor {
            args.append(cursor.sortKey)
            args.append(cursor.sortKey)
            args.append(Int64(cursor.entityID))
        }
        args.append(limit)
        return StatementArguments(args)
    }

    private static func ftsQuery(for text: String) -> String {
        let terms = text
            .split(whereSeparator: \.isWhitespace)
            .map { term in
                "\"\(String(term).replacingOccurrences(of: "\"", with: "\"\""))\""
            }
        return terms.isEmpty ? "\"\"" : terms.joined(separator: " ")
    }

    private static func catalogVersion(db: Database) throws -> Int64 {
        let raw = try String.fetchOne(db, sql: "SELECT value FROM catalog_metadata WHERE key = 'catalog_version'")
        return Int64(raw ?? "0") ?? 0
    }

    private static func logicalDigest(db: Database) throws -> String {
        let rows = try String.fetchAll(db, sql: """
            SELECT 's|' || id || '|' || key || '|' || title FROM catalog_source
            UNION ALL
            SELECT 'n|' || id || '|' || key || '|' || name FROM catalog_node
            UNION ALL
            SELECT 'p|' || source_id || '|' || node_id || '|' || opml_file || '|' || sort_order FROM catalog_placement
            ORDER BY 1
            """)
        let digest = SHA256.hash(data: Data(rows.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum SQLiteCatalogSchema {
    static func create(in db: Database) throws {
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try db.execute(sql: """
            CREATE TABLE catalog_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE catalog_node (
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                parent_id INTEGER REFERENCES catalog_node(id),
                name TEXT NOT NULL,
                kind INTEGER NOT NULL,
                source_count INTEGER NOT NULL DEFAULT 0,
                child_count INTEGER NOT NULL DEFAULT 0,
                language TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_catalog_node_parent_name ON catalog_node(parent_id, name COLLATE NOCASE, id)")
        try db.execute(sql: """
            CREATE TABLE catalog_source (
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                declared_url TEXT NOT NULL,
                request_url TEXT NOT NULL,
                display_host TEXT,
                media_kind TEXT NOT NULL,
                language TEXT,
                site_url TEXT,
                description TEXT,
                tags TEXT,
                nature TEXT,
                activity TEXT,
                latest_item_at TEXT,
                quality_score INTEGER,
                default_enabled INTEGER NOT NULL DEFAULT 1,
                contact_email TEXT,
                contact_name TEXT,
                contact_source TEXT,
                contact_type TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_catalog_source_title ON catalog_source(title COLLATE NOCASE, id)")
        try db.execute(sql: """
            CREATE TABLE catalog_placement (
                id INTEGER PRIMARY KEY,
                source_id INTEGER NOT NULL REFERENCES catalog_source(id) ON DELETE CASCADE,
                node_id INTEGER NOT NULL REFERENCES catalog_node(id) ON DELETE CASCADE,
                node_name TEXT NOT NULL,
                opml_file TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                title_override TEXT,
                language_override TEXT,
                media_kind_override TEXT,
                UNIQUE(source_id, node_id, opml_file, sort_order)
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_catalog_placement_node_order ON catalog_placement(node_id, sort_order, source_id)")
        try db.execute(sql: "CREATE INDEX idx_catalog_placement_source ON catalog_placement(source_id)")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE catalog_source_fts USING fts5(
                title,
                description,
                tags,
                display_host,
                language,
                media_kind,
                path
            )
            """)
    }
}

private struct CompiledSource {
    let id: SourceID
    let key: SourceKey
    let title: String
    let declaredURL: String
    let requestURL: String
    let displayHost: String?
    let mediaKind: MediaKind
    let language: String?
    let siteURL: String?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let latestItemAt: String?
    let qualityScore: Int?
    let defaultEnabled: Bool
    let contactEmail: String?
    let contactName: String?
    let contactSource: String?
    let contactType: String?
}

private struct CompiledNode {
    let id: CatalogNodeID
    let key: NodeKey
    let parentID: CatalogNodeID?
    let name: String
    let kind: CatalogNodeKind
    let language: String?
}

private struct CompiledPlacement {
    let id: Int64
    let sourceID: SourceID
    let nodeID: CatalogNodeID
    let nodeName: String
    let opmlFile: String
    let sortOrder: Int
    let titleOverride: String?
    let languageOverride: String?
    let mediaKindOverride: MediaKind?
}

private struct CatalogBrowseRow: FetchableRecord {
    let entityType: String
    let entityID: Int64
    let sortKey: String

    init(row: Row) throws {
        entityType = row["entity_type"]
        entityID = row["entity_id"]
        sortKey = row["sort_key"]
    }
}

private struct CatalogNodeRecord: FetchableRecord {
    let id: CatalogNodeID
    let name: String
    let kind: CatalogNodeKind
    let sourceCount: Int
    let childCount: Int
    let language: String?

    init(row: Row) throws {
        let rawID: Int64 = row["id"]
        let rawKind: Int = row["kind"]
        id = CatalogNodeID(rawValue: UInt32(rawID))
        name = row["name"]
        kind = CatalogNodeKind(rawValue: rawKind) ?? .topic
        sourceCount = row["source_count"]
        childCount = row["child_count"]
        language = row["language"]
    }

    var summary: CatalogNodeSummary {
        CatalogNodeSummary(id: id, name: name, kind: kind, sourceCount: sourceCount, childCount: childCount, language: language)
    }
}

private struct CatalogSourceRecord: FetchableRecord {
    let id: SourceID
    let title: String
    let declaredURL: String
    let requestURL: String
    let displayHost: String?
    let mediaKind: MediaKind
    let language: String?
    let siteURL: String?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let latestItemAt: String?
    let qualityScore: Int?
    let defaultEnabled: Bool
    let contactEmail: String?
    let contactName: String?
    let contactSource: String?
    let contactType: String?

    init(row: Row) throws {
        let rawID: Int64 = row["id"]
        id = SourceID(rawValue: UInt32(rawID))
        title = row["title"]
        declaredURL = row["declared_url"]
        requestURL = row["request_url"]
        displayHost = row["display_host"]
        mediaKind = MediaKind(rawValue: row["media_kind"]) ?? .text
        language = row["language"]
        siteURL = row["site_url"]
        sourceDescription = row["description"]
        let rawTags: String? = row["tags"]
        tags = (rawTags ?? "").split(separator: ",").map(String.init)
        nature = row["nature"]
        activity = row["activity"]
        latestItemAt = row["latest_item_at"]
        qualityScore = row["quality_score"]
        let enabled: Int = row["default_enabled"] ?? 1
        defaultEnabled = enabled != 0
        contactEmail = row["contact_email"]
        contactName = row["contact_name"]
        contactSource = row["contact_source"]
        contactType = row["contact_type"]
    }

    var summary: SourceSummary {
        SourceSummary(
            id: id, title: title, displayHost: displayHost, mediaKind: mediaKind,
            language: language, sourceDescription: sourceDescription, tags: tags,
            nature: nature, activity: activity, qualityScore: qualityScore,
            defaultEnabled: defaultEnabled,
            contactEmail: contactEmail,
            contactName: contactName,
            contactSource: contactSource,
            contactType: contactType
        )
    }
}

extension SourcePlacementSummary: FetchableRecord {
    init(row: Row) throws {
        let id: Int64 = row["id"]
        let rawNodeID: Int64 = row["nodeID"]
        let nodeName: String = row["nodeName"]
        let opmlFile: String = row["opmlFile"]
        let sortOrder: Int = row["sortOrder"]
        let titleOverride: String? = row["titleOverride"]
        let languageOverride: String? = row["languageOverride"]
        let mediaKindOverride: MediaKind?
        if let raw: String = row["mediaKindOverride"] {
            mediaKindOverride = MediaKind(rawValue: raw)
        } else {
            mediaKindOverride = nil
        }
        self.init(
            id: id,
            nodeID: CatalogNodeID(rawValue: UInt32(rawNodeID)),
            nodeName: nodeName,
            opmlFile: opmlFile,
            sortOrder: sortOrder,
            titleOverride: titleOverride,
            languageOverride: languageOverride,
            mediaKindOverride: mediaKindOverride
        )
    }
}
