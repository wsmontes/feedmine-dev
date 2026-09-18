import Foundation

/// Durable editorial identity and the legacy bridge (ADR-003 D2, D4, D18).
///
/// Nothing here converts between namespaces: the catalogue identity is aliased, the runtime identity
/// is only ever reached through a persisted mapping, and a mapping lookup that has no row fails
/// loudly instead of guessing.

public enum EditorialIdentityError: Error, Equatable, Sendable {
    /// D4: the durable key is a value key, and its catalogue identity must have content.
    case emptyCatalogIdentity
    /// `CHECK (canonicalization_version > 0)`.
    case nonPositiveCanonicalizationVersion(Int)
}

/// D4: durable editorial identity — a value key, not a number.
///
/// It is persisted with the `source` row, is never reused as a foreign key, and survives a catalogue
/// rebuild: the rebuild re-applies these mappings and never reallocates runtime sources by row order
/// or by re-deriving them from a URL (D4, D19).
public struct EditorialSourceKey: Hashable, Sendable, Codable {
    /// Catalogue-owned identity of the source (`catalog_source.key`, `SQLiteCatalogStore.swift:656-658`).
    public let catalogIdentity: String
    public let canonicalizationVersion: Int

    public init(catalogIdentity: String, canonicalizationVersion: Int) throws {
        guard !catalogIdentity.isEmpty else { throw EditorialIdentityError.emptyCatalogIdentity }
        guard canonicalizationVersion > 0 else {
            throw EditorialIdentityError.nonPositiveCanonicalizationVersion(canonicalizationVersion)
        }
        self.catalogIdentity = catalogIdentity
        self.canonicalizationVersion = canonicalizationVersion
    }
}

/// D2: the app's catalogue identity (`FeedEngine.SourceID`, `UInt32`), aliased for the bridges.
///
/// It is a different namespace from `FeedDomain.SourceID` on purpose. There is no initializer, cast
/// or arithmetic path from this type to a runtime `SourceID`; the only translation is a lookup in
/// `LegacySourceMap`, which fails when no mapping exists.
public struct CatalogSourceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var description: String { "catalog-source:\(rawValue)" }
}

/// D18: how well the legacy bridge knows a mapping (`legacy_item_map.confidence`).
public enum MappingConfidence: String, Hashable, Sendable, Codable, CaseIterable {
    /// The legacy id was resolved to a runtime record and revision.
    case high
    /// The runtime record is known but the mapping is not trustworthy.
    case low
    /// Nothing was resolved. Never a guessed source and never a guessed record.
    case unresolved
}

public enum LegacyMappingError: Error, Equatable, Sendable {
    /// No mapping row exists for this catalogue identity. There is no widening fallback.
    case missingSourceMapping(catalogSourceID: CatalogSourceID, canonicalizationVersion: Int)
    /// Two mapping rows claim the same catalogue identity with different runtime sources. The
    /// rebuild is recorded as a conflict instead of silently re-pointing the mapping (D18).
    case conflictingSourceMapping(
        catalogSourceID: CatalogSourceID,
        canonicalizationVersion: Int,
        runtimeSourceIDs: [SourceID]
    )
    /// No mapping row exists for this legacy item id (D18).
    case missingItemMapping(legacyItemID: String)
    /// Two mapping rows claim the same legacy item id with different records.
    case conflictingItemMapping(legacyItemID: String)
}

/// D18: `legacy_source_map`. One row per `(catalogue key, canonicalization version)`.
public struct LegacySourceMapping: Hashable, Sendable {
    public let editorialKey: EditorialSourceKey
    public let catalogSourceID: CatalogSourceID
    public let runtimeSourceID: SourceID
    public let legacyURL: String
    public let mappedAt: Date

    public init(
        editorialKey: EditorialSourceKey,
        catalogSourceID: CatalogSourceID,
        runtimeSourceID: SourceID,
        legacyURL: String,
        mappedAt: Date
    ) {
        self.editorialKey = editorialKey
        self.catalogSourceID = catalogSourceID
        self.runtimeSourceID = runtimeSourceID
        self.legacyURL = legacyURL
        self.mappedAt = mappedAt
    }
}

/// The in-memory bridge of D18. While the catalogue owns the legacy identity, this is the only path
/// from a catalogue id to a runtime source, and from a runtime source back to the catalogue ids that
/// named it.
public struct LegacySourceMap: Sendable {
    /// One catalogue identity at one canonicalization version: the scope a mapping is looked up in.
    struct CatalogScope: Hashable, Sendable {
        let catalogSourceID: CatalogSourceID
        let canonicalizationVersion: Int
    }

    private var mappings: [EditorialSourceKey: LegacySourceMapping] = [:]
    /// Scopes two runtime sources claim. Reads refuse them: D18 records the conflict instead of
    /// letting whichever row happened to be applied last answer for the source.
    private var conflictedScopes: Set<CatalogScope> = []
    public private(set) var conflicts: [IdentityConflict] = []

    public init(_ rows: [LegacySourceMapping]) {
        for row in rows {
            if let existing = mappings[row.editorialKey], existing.runtimeSourceID != row.runtimeSourceID {
                conflicts.append(Self.conflict(
                    scope: .legacyBridge(row.editorialKey),
                    existing: existing.runtimeSourceID,
                    claimed: row.runtimeSourceID,
                    detectedAt: row.mappedAt
                ))
                conflictedScopes.insert(Self.scope(of: row))
                continue
            }
            mappings[row.editorialKey] = row
        }
    }

    /// Every mapping, ordered by durable key so a read is deterministic.
    public var rows: [LegacySourceMapping] {
        mappings.keys
            .sorted {
                ($0.catalogIdentity, $0.canonicalizationVersion)
                    < ($1.catalogIdentity, $1.canonicalizationVersion)
            }
            .compactMap { mappings[$0] }
    }

    /// D2, D4: the only translation from catalogue identity to runtime identity. A missing row is an
    /// error, never a derived or widened value.
    public func runtimeSource(
        forCatalogSource catalogSourceID: CatalogSourceID,
        canonicalizationVersion: Int
    ) throws -> SourceID {
        let matches = mappings.values.filter {
            $0.catalogSourceID == catalogSourceID
                && $0.editorialKey.canonicalizationVersion == canonicalizationVersion
        }
        let sources = Set(matches.map(\.runtimeSourceID)).sorted { $0.rawValue < $1.rawValue }
        guard sources.count <= 1 else {
            throw LegacyMappingError.conflictingSourceMapping(
                catalogSourceID: catalogSourceID,
                canonicalizationVersion: canonicalizationVersion,
                runtimeSourceIDs: sources
            )
        }
        guard let match = matches.first else {
            throw LegacyMappingError.missingSourceMapping(
                catalogSourceID: catalogSourceID,
                canonicalizationVersion: canonicalizationVersion
            )
        }
        return match.runtimeSourceID
    }

    /// The catalogue ids that name a runtime source at one canonicalization version. Several ids may
    /// legitimately name one source: that is the declared continuity of D6, and it is why this read
    /// returns a set instead of picking one.
    public func catalogSources(
        forRuntimeSource runtimeSourceID: SourceID,
        canonicalizationVersion: Int
    ) -> [CatalogSourceID] {
        mappings.values
            .filter {
                $0.runtimeSourceID == runtimeSourceID
                    && $0.editorialKey.canonicalizationVersion == canonicalizationVersion
            }
            .map(\.catalogSourceID)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Whether two runtime sources claim this catalogue identity at this canonicalization version.
    ///
    /// The read keeps answering with the *established* mapping — dropping it would break a source the
    /// catalogue merely rebuilt — and the claim is never applied (D18). Callers that must not act on a
    /// disputed identity (Admission, the rebuild of `legacy_source_map`) ask this first.
    public func isDisputed(
        forCatalogSource catalogSourceID: CatalogSourceID,
        canonicalizationVersion: Int
    ) -> Bool {
        conflictedScopes.contains(
            CatalogScope(
                catalogSourceID: catalogSourceID,
                canonicalizationVersion: canonicalizationVersion
            )
        )
    }

    /// D4, invariant 11: a catalogue rebuild re-applies persisted mappings by key.
    ///
    /// Identical rows are a no-op. A row that claims a different runtime source for an established
    /// catalogue identity is refused and recorded as a `legacyMapConflict`, so the rebuild cannot
    /// silently re-point a source; runtime sources that the rebuild does not mention stay mapped.
    public mutating func reapply(_ rebuilt: [LegacySourceMapping]) -> [IdentityConflict] {
        var recorded: [IdentityConflict] = []
        for row in rebuilt {
            guard let existing = mappings[row.editorialKey] else {
                mappings[row.editorialKey] = row
                continue
            }
            guard existing.runtimeSourceID != row.runtimeSourceID else { continue }
            let conflict = Self.conflict(
                scope: .legacyBridge(row.editorialKey),
                existing: existing.runtimeSourceID,
                claimed: row.runtimeSourceID,
                detectedAt: row.mappedAt
            )
            conflicts.append(conflict)
            recorded.append(conflict)
            conflictedScopes.insert(Self.scope(of: row))
        }
        return recorded
    }

    private static func scope(of row: LegacySourceMapping) -> CatalogScope {
        CatalogScope(
            catalogSourceID: row.catalogSourceID,
            canonicalizationVersion: row.editorialKey.canonicalizationVersion
        )
    }

    private static func conflict(
        scope: IdentityConflictScope,
        existing: SourceID,
        claimed: SourceID,
        detectedAt: Date
    ) -> IdentityConflict {
        IdentityConflict(
            kind: .legacyMapConflict,
            scope: scope,
            existingRecord: nil,
            claimingRecord: nil,
            existingSource: existing,
            claimedSource: claimed,
            incomingKeyDigest: nil,
            storedPayloadDigest: nil,
            incomingPayloadDigest: nil,
            detectedAt: detectedAt
        )
    }
}

/// D18: `legacy_item_map`. Maps the legacy TEXT item id (`FeedItem.generateID`) to a runtime record
/// and revision, with an explicit confidence.
///
/// While the ADR-004 compatibility window is open this mapping is not a bookmark key: bookmarks keep
/// the legacy durable key and their snapshot (plan §5.2, invariant 18).
public struct LegacyItemMapping: Hashable, Sendable {
    public let legacyItemID: String
    public let legacySourceURL: String
    public let record: OriginRecordID?
    public let revision: OriginRevisionID?
    public let confidence: MappingConfidence
    public let mappedAt: Date

    public init(
        legacyItemID: String,
        legacySourceURL: String,
        record: OriginRecordID?,
        revision: OriginRevisionID?,
        confidence: MappingConfidence,
        mappedAt: Date
    ) {
        self.legacyItemID = legacyItemID
        self.legacySourceURL = legacySourceURL
        self.record = record
        self.revision = revision
        self.confidence = confidence
        self.mappedAt = mappedAt
    }

    /// D18: a legacy id that nothing has resolved yet. It resolves to `unresolved` and never to a
    /// guessed record.
    public static func unresolved(
        legacyItemID: String,
        legacySourceURL: String,
        mappedAt: Date
    ) -> LegacyItemMapping {
        LegacyItemMapping(
            legacyItemID: legacyItemID,
            legacySourceURL: legacySourceURL,
            record: nil,
            revision: nil,
            confidence: .unresolved,
            mappedAt: mappedAt
        )
    }
}

/// The in-memory `legacy_item_map` of D18.
public struct LegacyItemMap: Sendable {
    private var mappings: [String: LegacyItemMapping] = [:]

    public init(_ rows: [LegacyItemMapping]) throws {
        for row in rows where !row.legacyItemID.isEmpty {
            if let existing = mappings[row.legacyItemID],
               existing.record != row.record || existing.revision != row.revision {
                throw LegacyMappingError.conflictingItemMapping(legacyItemID: row.legacyItemID)
            }
            mappings[row.legacyItemID] = row
        }
    }

    /// The mapping row for a legacy item id. A missing row is an error: an unmapped legacy id is
    /// recorded as `unresolved` by the bridge and never becomes a guessed record (D18).
    public func mapping(forLegacyItemID legacyItemID: String) throws -> LegacyItemMapping {
        guard let mapping = mappings[legacyItemID] else {
            throw LegacyMappingError.missingItemMapping(legacyItemID: legacyItemID)
        }
        return mapping
    }
}
