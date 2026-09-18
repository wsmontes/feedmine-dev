import Foundation
import GRDB
import FeedDomain

/// The read surface of the canonical content index (plan §14 PR-14: *Search de conteúdo usa FTS
/// canônica*; §6: the projections are reconstructible and one row per selectable record).
///
/// The index is `origin_search`, an FTS5 table with a single `projection` column whose rowid is the
/// `origin_record_id`. Admission fills it inside the transaction that makes a revision current
/// (`AdmissionEngine.refreshSupply`), so the index describes *what is current now* and never what once
/// was: a revision that stops being current loses its row. That property is the reason a reader's
/// content search can be served from here at all — the legacy `feed_item_fts` is a different index
/// over a different database, and reading it in a mode whose runtime owns acquisition answers from
/// content nobody is refreshing.
///
/// The projection is text only: the headline, the summary and the body of the current revision.
/// Everything a card needs beyond that — the source it belongs to, the address a tap opens, its media,
/// and the legacy item id a bookmark is keyed by — lives in the canonical tables beside it, so this
/// repository joins them rather than inventing a second, presentation-shaped copy of the record. It
/// never reads `connector_evidence` or a wire payload (plan §7, I-03).
///
/// The read is bounded: `limit` is a result cap and the only cap on cost, because the query is an FTS
/// `MATCH` over an index that exists precisely to make that lookup cheap. It is not a supply walk; the
/// bounded-pool rules of plan §8 apply to Selection, not to a term lookup.

/// One canonical record the index matched, with the fields a reader's result needs.
public struct CanonicalSearchHit: Sendable, Equatable {
    public let originRecordID: OriginRecordID
    public let originRevisionID: OriginRevisionID
    public let headline: String?
    public let summary: String?
    /// The current revision's body, truncated: a search result shows an excerpt, and a full body per
    /// hit would make a 180-row read ship whatever the publisher wrote.
    public let bodyExcerpt: String?
    public let primaryLink: String?
    /// The declared authored date, when the observation claimed one. Always present as an instant
    /// because the runtime records what it observed: a record with no date claim sorts and reads by
    /// `observedAt` instead of pretending a date it does not have.
    public let authoredAt: Date?
    public let observedAt: Date
    public let sourceID: SourceID?
    public let sourceTitle: String?
    /// The source's durable catalogue key (`source.editorial_key`). In this app's composition it is
    /// `FeedSource.id`, the normalized fetch URL the catalogue keys on — which is how a reader's
    /// source filters and source metadata are resolved for a canonical hit.
    public let sourceKey: String?
    /// The legacy URL the record's source maps to (`legacy_source_map`), which is the identity the
    /// legacy reader knows this source by (ADR-003 D18). Absent when no bridge row exists.
    public let legacySourceURL: String?
    /// The legacy item id the bridge resolved for this record, when one exists. Absent for content
    /// only V2 has ever seen.
    public let legacyItemID: String?
    public let imageURL: String?
    public let audioURL: String?
}

public enum CanonicalSearchError: Error, Equatable, Sendable {
    case nonPositiveLimit(Int)
}

public struct CanonicalSearchRepository: Sendable {
    public init() {}

    /// One lookup in the canonical index, inside a caller's own database access.
    ///
    /// Taking a `Database` rather than a `RuntimeDatabase` is deliberate: the same SQL serves the
    /// synchronous pool read a test drives and the asynchronous read a main-actor caller needs, and
    /// duplicating it for the two would let them drift.
    public func search(
        _ match: String,
        limit: Int = CanonicalSearchRepository.defaultLimit,
        in database: Database
    ) throws -> [CanonicalSearchHit] {
        guard limit > 0 else { throw CanonicalSearchError.nonPositiveLimit(limit) }
        let rows = try Row.fetchAll(database, sql: """
            SELECT origin_search.rowid AS origin_record_id,
                   r.current_revision_id AS origin_revision_id,
                   rev.headline, rev.summary,
                   substr(rev.body_text, 1, \(Self.bodyExcerptCharacters)) AS body_excerpt,
                   rev.primary_link, rev.authored_at, rev.observed_at
            FROM origin_search
            JOIN origin_record r ON r.id = origin_search.rowid
            JOIN origin_revision rev ON rev.id = r.current_revision_id
            WHERE origin_search MATCH ?
              AND r.availability = 'available'
            ORDER BY COALESCE(rev.authored_at, rev.observed_at) DESC, origin_search.rowid DESC
            LIMIT ?
            """, arguments: [match, limit])
        guard !rows.isEmpty else { return [] }

        let recordIDs: [Int64] = rows.map { $0["origin_record_id"] }
        let sources = try Self.sources(recordIDs: recordIDs, in: database)
        let legacyItems = try Self.legacyItems(recordIDs: recordIDs, in: database)
        let media = try Self.media(recordIDs: recordIDs, in: database)

        return try rows.map { row in
            let recordID: Int64 = row["origin_record_id"]
            let revisionID: Int64 = row["origin_revision_id"]
            let authoredAt: Int64? = row["authored_at"]
            let observedAt: Int64 = row["observed_at"]
            let source = sources[recordID]
            let legacyItem = legacyItems[recordID]
            return CanonicalSearchHit(
                originRecordID: try OriginRecordID(recordID),
                originRevisionID: try OriginRevisionID(revisionID),
                headline: row["headline"],
                summary: row["summary"],
                bodyExcerpt: row["body_excerpt"],
                primaryLink: row["primary_link"],
                authoredAt: authoredAt.map(AdmissionTimestamp.date(milliseconds:)),
                observedAt: AdmissionTimestamp.date(milliseconds: observedAt),
                sourceID: source?.sourceID,
                sourceTitle: source?.displayTitle,
                sourceKey: source?.editorialKey,
                legacySourceURL: source?.legacyURL,
                legacyItemID: legacyItem?.itemID,
                imageURL: media[recordID]?.imageURL,
                audioURL: media[recordID]?.audioURL
            )
        }
    }

    /// One lookup as a read of the runtime database.
    ///
    /// Asynchronous on purpose: the pool's async read releases the calling executor while the query
    /// runs, and the caller of a local search is the main actor. A synchronous pool read from there
    /// would put the FTS lookup — and the file I/O behind it — on the thread that draws (baseline
    /// §8.5: main-actor work is this app's measured responsiveness defect class).
    public func search(
        _ match: String,
        limit: Int = CanonicalSearchRepository.defaultLimit,
        in database: RuntimeDatabase
    ) async throws -> [CanonicalSearchHit] {
        try await database.pool.read { database in
            try search(match, limit: limit, in: database)
        }
    }

    /// The default result cap, matching the bound the legacy content read used so a mode change does
    /// not silently change how many results a reader's search can show.
    public static let defaultLimit = 180

    /// How much of a body a result may carry. The projection is what the result *searches*; the
    /// excerpt is only what it *shows*.
    static let bodyExcerptCharacters = 600

    // MARK: - Secondary projections

    /// The source a record is a member of, and the legacy URL that source maps to.
    ///
    /// Several memberships per record are possible; the read is ordered by the runtime source id so
    /// the answer never depends on row order, and the first is the one the legacy reader would have
    /// seen. A source with no bridge row has no legacy URL, and the hit says so instead of guessing one.
    struct SourceClaim {
        let sourceID: SourceID
        let displayTitle: String
        let editorialKey: String
        let legacyURL: String?
    }

    static func sources(recordIDs: [Int64], in database: Database) throws -> [Int64: SourceClaim] {
        let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(database, sql: """
            SELECT m.origin_record_id, src.id AS source_id, src.display_title, src.editorial_key,
                   (SELECT lsm.legacy_url FROM legacy_source_map lsm
                    WHERE lsm.runtime_source_id = m.source_id
                    ORDER BY lsm.canonicalization_version, lsm.catalog_source_key
                    LIMIT 1) AS legacy_url
            FROM source_membership m
            JOIN source src ON src.id = m.source_id
            WHERE m.origin_record_id IN (\(placeholders))
            ORDER BY m.origin_record_id, src.id
            """, arguments: StatementArguments(recordIDs))
        var result: [Int64: SourceClaim] = [:]
        for row in rows {
            let recordID: Int64 = row["origin_record_id"]
            guard result[recordID] == nil else { continue }
            result[recordID] = SourceClaim(
                sourceID: try SourceID(UInt64(row["source_id"] as Int64)),
                displayTitle: row["display_title"],
                editorialKey: row["editorial_key"],
                legacyURL: row["legacy_url"]
            )
        }
        return result
    }

    /// The legacy item id the bridge resolved for a record (ADR-003 D18), when one exists.
    struct LegacyItemClaim {
        let itemID: String
        let sourceURL: String?
    }

    static func legacyItems(recordIDs: [Int64], in database: Database) throws -> [Int64: LegacyItemClaim] {
        let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(database, sql: """
            SELECT origin_record_id, legacy_item_id, legacy_source_url
            FROM legacy_item_map
            WHERE origin_record_id IN (\(placeholders))
            ORDER BY origin_record_id, legacy_item_id
            """, arguments: StatementArguments(recordIDs))
        var result: [Int64: LegacyItemClaim] = [:]
        for row in rows {
            let recordID: Int64 = row["origin_record_id"]
            guard result[recordID] == nil else { continue }
            result[recordID] = LegacyItemClaim(
                itemID: row["legacy_item_id"],
                sourceURL: row["legacy_source_url"]
            )
        }
        return result
    }

    /// The current revision's media, one image and one audio candidate per record.
    ///
    /// Reading candidates rather than a resolved asset is deliberate (plan §10): a search result is a
    /// decision-free view of canonical content, and which bytes are local is the media slice's answer.
    /// The join on `origin_record.current_revision_id` is what keeps a previous revision's candidates
    /// out of a result, which the append-only history would otherwise leave behind.
    struct MediaClaim {
        let imageURL: String?
        let audioURL: String?
    }

    static func media(recordIDs: [Int64], in database: Database) throws -> [Int64: MediaClaim] {
        let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(database, sql: """
            SELECT m.origin_record_id, m.role, m.resource_url
            FROM media_candidate m
            JOIN origin_record r
                ON r.id = m.origin_record_id AND r.current_revision_id = m.origin_revision_id
            WHERE m.origin_record_id IN (\(placeholders))
            ORDER BY m.origin_record_id,
                     CASE m.role WHEN 'image' THEN 0 WHEN 'thumbnail' THEN 1
                                 WHEN 'poster' THEN 2 ELSE 3 END,
                     m.position
            """, arguments: StatementArguments(recordIDs))
        var images: [Int64: String] = [:]
        var audios: [Int64: String] = [:]
        for row in rows {
            let recordID: Int64 = row["origin_record_id"]
            let role: String = row["role"]
            if role == MediaRole.audio.rawValue {
                if audios[recordID] == nil { audios[recordID] = row["resource_url"] }
            } else if images[recordID] == nil {
                images[recordID] = row["resource_url"]
            }
        }
        var result: [Int64: MediaClaim] = [:]
        for recordID in Set(images.keys).union(audios.keys) {
            result[recordID] = MediaClaim(imageURL: images[recordID], audioURL: audios[recordID])
        }
        return result
    }
}
