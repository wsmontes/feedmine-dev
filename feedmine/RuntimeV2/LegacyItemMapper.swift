import Foundation
import FeedDomain

/// Runtime V2 bridge for item identity (plan §5, ADR-003 D8/D10/D16/D18).
///
/// The legacy item id is a SHA-256 over `sourceURL|guid_or_link|title|timestamp`
/// (`Models/FeedItem.swift:394-402`) and the raw GUID is not kept anywhere in `FeedItem` (plan §2).
/// That hash is therefore *not* an external identity — it cannot be reversed — so an item whose raw
/// GUID the bridge has not seen is recorded as `unresolved` rather than guessed into a record.
///
/// The mapper's inputs are the raw parser values, so the capture point (a connector or the shadow
/// bridge) decides what "raw" means and the core never re-derives it.
enum LegacyItemMapper {

    /// What identifies the item, in the order ADR-003 D10/D16 prescribes.
    enum Material: Hashable, Sendable {
        /// The raw GUID/Atom id exactly as parsed. Never normalized, never resolved against a base
        /// URL, never stripped of query parameters.
        case externalIdentifier(String)
        /// The item link as declared, used only when there is no GUID.
        case link(String)
        /// No GUID and no usable link: versioned, low-confidence fallback (D16).
        case fallback(title: String?, publishedAt: Date?, disambiguator: String)

        var isLowConfidence: Bool {
            if case .fallback = self { return true }
            return false
        }
    }

    static let fallbackSchemeVersion = FallbackIdentityScheme.currentVersion

    /// Chooses the material. An empty GUID is treated as absent, matching the legacy generator, so
    /// the bridge cannot invent a key from an empty string.
    static func material(
        guid: String?,
        link: String?,
        title: String?,
        publishedAt: Date?,
        disambiguator: String
    ) -> Material {
        if let guid, !guid.isEmpty { return .externalIdentifier(guid) }
        if let link, !link.isEmpty { return .link(link) }
        return .fallback(title: title, publishedAt: publishedAt, disambiguator: disambiguator)
    }

    /// Disambiguator for the fallback scheme when the bridge has nothing else: the legacy id hash.
    ///
    /// It is opaque material, not an identity — two items that share a title and a date still get
    /// different keys, and the hash is never interpreted.
    static func fallbackDisambiguator(legacyItemID: String) -> String {
        legacyItemID
    }

    static func confidence(for material: Material) -> IdentityConfidence {
        material.isLowConfidence ? .low : .high
    }

    /// The full scoped key and the confidence it carries.
    static func identity(
        for material: Material,
        scope: ExternalScopeKey
    ) throws -> ExternalIdentityRef {
        switch material {
        case .externalIdentifier(let raw), .link(let raw):
            return try ExternalIdentityRef(
                key: ExternalObjectKey(scope: scope, text: raw),
                confidence: .high,
                fallbackSchemeVersion: nil
            )
        case .fallback(let title, let publishedAt, let disambiguator):
            let scheme = try FallbackIdentityScheme()
            let key = try scheme.key(
                scope: scope,
                title: title,
                authoredAt: publishedAt,
                disambiguator: disambiguator
            )
            return try ExternalIdentityRef(
                key: key,
                confidence: .low,
                fallbackSchemeVersion: scheme.version
            )
        }
    }

    static func externalKey(
        for material: Material,
        scope: ExternalScopeKey
    ) throws -> ExternalObjectKey {
        try identity(for: material, scope: scope).key
    }

    /// A resolved mapping row: the bridge saw enough to attach the legacy id to a record.
    static func mapping(
        legacyItemID: String,
        legacySourceURL: String,
        record: OriginRecordID,
        revision: OriginRevisionID,
        material: Material,
        mappedAt: Date
    ) -> LegacyItemMapping {
        LegacyItemMapping(
            legacyItemID: legacyItemID,
            legacySourceURL: legacySourceURL,
            record: record,
            revision: revision,
            confidence: material.isLowConfidence ? .low : .high,
            mappedAt: mappedAt
        )
    }

    /// A legacy id nothing has resolved. It never becomes a guessed record (D18).
    static func unresolvedMapping(
        legacyItemID: String,
        legacySourceURL: String,
        mappedAt: Date
    ) -> LegacyItemMapping {
        LegacyItemMapping.unresolved(
            legacyItemID: legacyItemID,
            legacySourceURL: legacySourceURL,
            mappedAt: mappedAt
        )
    }
}
