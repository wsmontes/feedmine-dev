import Foundation
import FeedDomain
import FeedStorage

/// The canonical content index as the app's local content search reads it (plan §14 PR-14, clause two:
/// *Search de conteúdo usa FTS canônica*).
///
/// This is the read half of the index Admission writes: `origin_search` over `runtime-v2.sqlite`,
/// queried through `CanonicalSearchRepository` and mapped onto the value the search list already
/// renders. It exists only when the launch's runtime owns acquisition — `RuntimeCompositionRoot`
/// composes the acquiring runtime for `v2Full` and for nothing else — so its presence *is* the answer
/// to "which index does this launch's search read".
///
/// What the canonical schema does not carry, and where the value comes from instead:
///
/// * **language and region**: `origin_revision` has no language, and a canonical record cannot be
///   given one by guessing. The legacy reader takes both from the *source* (`FeedItem.language` is the
///   OPML/feed code), so this mapping reads the same source through the registry — the same catalogue
///   entry the launch acquired from — rather than inventing a per-item answer. A record whose source
///   the registry does not know is mapped with no language, which is what the legacy reader would do
///   for the same unknown source.
/// * **the item id**: the bridge's durable legacy id (`legacy_item_map`, ADR-003 D18) when one exists,
///   so read state, bookmarks and the online sweep's source priority address the subject the legacy
///   database knows. Content only V2 has ever seen has no such id and gets a canonical one that cannot
///   collide with a legacy item id.
/// * **read/bookmark overlays**: not part of this read. The runtime's own projection
///   (`user_state_projection`, PR-04) is the authority for a runtime card's overlay, and mapping it
///   onto a search row is the card-identity slice's work, not an index switch's. A canonical hit is
///   therefore returned un-stamped, and the gap is named in the report.
@MainActor
final class CanonicalContentSearch {
    private let database: RuntimeDatabase
    private let registry: SourceRegistry
    private let repository = CanonicalSearchRepository()

    init(database: RuntimeDatabase, registry: SourceRegistry) {
        self.database = database
        self.registry = registry
    }

    /// The rows the canonical index matched, in the order it returns them (newest first).
    ///
    /// The index is the authority for *what matches*: the FTS query and the projection it searches are
    /// the definition of the content scope, and there is no second substring pass to disagree with it.
    /// The legacy path carries such a pass because its FTS table physically holds several scopes and
    /// the query's column filter and the in-Swift check have to be kept in step; `origin_search` has
    /// one column and one scope, so a re-check could only remove rows the index deliberately matched.
    func items(matching match: String, limit: Int) async -> [FeedItem] {
        let hits: [CanonicalSearchHit]
        do {
            hits = try await repository.search(match, limit: limit, in: database)
        } catch {
            Log.db.error("canonical content search failed: \(error.localizedDescription)")
            return []
        }
        return hits.map(item(for:))
    }

    /// One canonical hit in the shape the search list renders.
    private func item(for hit: CanonicalSearchHit) -> FeedItem {
        let source = catalogueSource(for: hit)
        return FeedItem(
            id: hit.legacyItemID ?? Self.canonicalItemIDPrefix + String(hit.originRecordID.rawValue),
            sourceTitle: source?.title ?? hit.sourceTitle ?? "",
            sourceURL: source?.url ?? hit.legacySourceURL ?? hit.sourceKey ?? "",
            category: source?.category ?? "",
            title: hit.headline ?? hit.summary ?? "",
            excerpt: FeedTextSanitizer.displayExcerpt(hit.summary ?? hit.bodyExcerpt ?? ""),
            url: hit.primaryLink ?? "",
            imageURL: hit.imageURL,
            publishedAt: hit.authoredAt ?? hit.observedAt,
            audioURL: hit.audioURL,
            region: source?.region ?? "global",
            language: source?.language
        )
    }

    /// The catalogue source a hit belongs to, resolved through the registry the launch acquires from.
    ///
    /// Two candidate identities, in the order that survives the composition that actually ships:
    ///
    /// 1. the source's durable key — `FeedSource.id`, the normalized fetch URL the catalogue keys on,
    ///    which is what `V2Acquisition` records as `source.editorial_key` and what the runtime's own
    ///    `source` row holds;
    /// 2. `legacy_source_map.legacy_url`, the bridge row ADR-003 D18 defines, which the acquiring
    ///    composition now writes on the production path (it records the catalogue's own compact id).
    ///
    /// The registry is the validator, not the guess: a key the registry does not know as a source URL
    /// is skipped, so a composition that keyed its sources by something else cannot turn that value into
    /// a source address. The bridge row stays second on its merits, not because it is absent: candidate
    /// 1 is the identity the runtime allocated and keyed its source by, while the bridge's `legacy_url`
    /// is the address the *catalogue* knew the source by and is stored as evidence (ADR-003 D18).
    private func catalogueSource(for hit: CanonicalSearchHit) -> FeedSource? {
        for candidate in [hit.sourceKey, hit.legacySourceURL] {
            if let candidate, let source = registry.source(forURL: candidate) {
                return source
            }
        }
        return nil
    }

    /// The namespace of an id no legacy row owns. A legacy item id is a hex digest
    /// (`FeedItem.generateID`), so this prefix cannot name one.
    static let canonicalItemIDPrefix = "origin:"
}
