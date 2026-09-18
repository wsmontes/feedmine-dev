import Foundation
import FeedDomain

/// The media half of retention, in production form (plan §10, ADR-004 D8).
///
/// This type is the opposite of a new collector: it *is* the two collectors PR-08 shipped, reached
/// through the port `FeedStorage`'s coordinator sees. `DecodedImageCache` keeps its eviction classes,
/// its quotas and its pins; `LocalAssetStore` keeps the content-addressed layout and the
/// `collectOrphanTemporaryFiles()` reclaim path. What the port adds is the order D8 requires —
/// **limits first, collection second** — and the translation between the database's spelling of an
/// asset identity and the media module's.
///
/// Ordering matters: `trimToLimits()` is the byte/age policy, `collectUnpinnedEntries()` is the
/// sweep. Running the sweep alone would collect everything unpinned at once, including bytes a
/// declared quota still allows, which is why the limits are applied first and reported with the
/// sweep rather than instead of it.
public struct MediaRetentionCollector: RetentionMediaCollecting {
    public let cache: DecodedImageCache
    public let assets: LocalAssetStore

    public init(cache: DecodedImageCache, assets: LocalAssetStore) {
        self.cache = cache
        self.assets = assets
    }

    public func collectUnpinnedMedia() async -> MediaCollectionOutcome {
        let limits = await cache.trimToLimits()
        let sweep = await cache.collectUnpinnedEntries()
        return MediaCollectionOutcome(
            collected: limits.evicted.count + sweep.evicted.count,
            protectedByPin: max(limits.protectedByPin.count, sweep.protectedByPin.count),
            freedBytes: limits.freedBytes + sweep.freedBytes
        )
    }

    public func collectAssetBytes(_ keys: [MediaAssetKey]) async -> MediaCollectionOutcome {
        var ids: [AssetVersionID] = []
        var unreadable = 0
        for key in keys {
            guard let id = Self.assetVersionID(key) else {
                // A stored digest or recipe the media identity rejects is a corrupted row, not a
                // collection: it is reported as protected so a caller sees it rather than losing it.
                unreadable += 1
                continue
            }
            ids.append(id)
        }
        let freed = assets.remove(ids)
        return MediaCollectionOutcome(collected: ids.count, protectedByPin: unreadable, freedBytes: freed)
    }

    public func collectOrphanAssetFiles() async -> MediaCollectionOutcome {
        let orphans = (try? assets.orphanTemporaryFiles())?.count ?? 0
        let freed = assets.collectOrphanTemporaryFiles()
        return MediaCollectionOutcome(
            collected: orphans,
            protectedByPin: 0,
            freedBytes: freed,
            orphansCollected: orphans
        )
    }

    /// `(digest hex, recipe)` as the media module spells it. The one place both spellings meet.
    static func assetVersionID(_ key: MediaAssetKey) -> AssetVersionID? {
        guard let digest = try? LocalAssetStore.digest(hex: key.contentDigestHex),
              let recipeVersion = try? MediaRecipeVersion(key.recipeVersion)
        else { return nil }
        return AssetVersionID(contentDigest: digest, recipeVersion: recipeVersion)
    }
}

extension MediaAssetKey {
    /// The database spelling of a media identity, for callers that hold the media one.
    public init(_ id: AssetVersionID) {
        self.init(
            contentDigestHex: id.contentDigest.hex,
            recipeVersion: id.recipeVersion.rawValue
        )
    }
}
