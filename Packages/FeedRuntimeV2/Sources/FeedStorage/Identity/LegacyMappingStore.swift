import Foundation
import GRDB
import FeedDomain

/// Durable home of the legacy bridges of ADR-003 D18.
///
/// The in-memory value layer (`LegacySourceMap`, `LegacyItemMap`) owns reconciliation and conflict
/// detection; this store only persists rows and reads them back, so the catalogue rebuild path of
/// PR-04 and the app bridges have exactly one way in and one way out.
public struct LegacyMappingStore: Sendable {
    public init() {}

    /// Inserts a mapping if the durable key is free. An existing row is never re-pointed here: a
    /// rebuild that contests an established mapping is recorded as a conflict by the mapper, and a
    /// silent overwrite would re-point a source behind the caller's back (ADR-003 D18).
    public func recordSourceMapping(_ mapping: LegacySourceMapping, in database: RuntimeDatabase) throws {
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO legacy_source_map (
                    catalog_source_key, catalog_source_id, canonicalization_version,
                    runtime_source_id, legacy_url, mapped_at
                ) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [
                mapping.editorialKey.catalogIdentity,
                Int64(mapping.catalogSourceID.rawValue),
                mapping.editorialKey.canonicalizationVersion,
                Int64(mapping.runtimeSourceID.rawValue),
                mapping.legacyURL,
                AdmissionTimestamp.milliseconds(mapping.mappedAt),
            ])
        }
    }

    public func sourceMapping(
        for editorialKey: EditorialSourceKey,
        in database: RuntimeDatabase
    ) throws -> LegacySourceMapping? {
        try database.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT catalog_source_id, runtime_source_id, legacy_url, mapped_at
                FROM legacy_source_map
                WHERE catalog_source_key = ? AND canonicalization_version = ?
                """, arguments: [editorialKey.catalogIdentity, editorialKey.canonicalizationVersion])
            else { return nil }
            let catalogSourceID: Int64 = row["catalog_source_id"]
            let runtimeSourceID: Int64 = row["runtime_source_id"]
            let mappedAt: Int64 = row["mapped_at"]
            return LegacySourceMapping(
                editorialKey: editorialKey,
                catalogSourceID: CatalogSourceID(UInt32(catalogSourceID)),
                runtimeSourceID: try SourceID(UInt64(runtimeSourceID)),
                legacyURL: row["legacy_url"],
                mappedAt: AdmissionTimestamp.date(milliseconds: mappedAt)
            )
        }
    }

    /// Inserts or replaces one legacy item mapping. The legacy id is the primary key, and the
    /// confidence travels with it, so a later resolution replaces the previous answer for the same
    /// legacy id instead of accumulating rows nobody can order (ADR-003 D18).
    public func recordItemMapping(_ mapping: LegacyItemMapping, in database: RuntimeDatabase) throws {
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO legacy_item_map (
                    legacy_item_id, legacy_source_url, origin_record_id, origin_revision_id,
                    confidence, mapped_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(legacy_item_id) DO UPDATE SET
                    legacy_source_url = excluded.legacy_source_url,
                    origin_record_id = excluded.origin_record_id,
                    origin_revision_id = excluded.origin_revision_id,
                    confidence = excluded.confidence,
                    mapped_at = excluded.mapped_at
                """, arguments: [
                mapping.legacyItemID,
                mapping.legacySourceURL,
                mapping.record?.rawValue,
                mapping.revision?.rawValue,
                mapping.confidence.rawValue,
                AdmissionTimestamp.milliseconds(mapping.mappedAt),
            ])
        }
    }

    public func itemMapping(
        forLegacyItemID legacyItemID: String,
        in database: RuntimeDatabase
    ) throws -> LegacyItemMapping? {
        try database.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT legacy_source_url, origin_record_id, origin_revision_id, confidence, mapped_at
                FROM legacy_item_map WHERE legacy_item_id = ?
                """, arguments: [legacyItemID]) else { return nil }
            let recordID: Int64? = row["origin_record_id"]
            let revisionID: Int64? = row["origin_revision_id"]
            let confidenceName: String = row["confidence"]
            let mappedAt: Int64 = row["mapped_at"]
            return LegacyItemMapping(
                legacyItemID: legacyItemID,
                legacySourceURL: row["legacy_source_url"],
                record: try recordID.map { try OriginRecordID($0) },
                revision: try revisionID.map { try OriginRevisionID($0) },
                confidence: MappingConfidence(rawValue: confidenceName) ?? .unresolved,
                mappedAt: AdmissionTimestamp.date(milliseconds: mappedAt)
            )
        }
    }
}
