import FeedDomain
import Foundation
import XCTest
@testable import FeedMedia

/// The three eviction classes of plan §10 and the pin rule that outranks all of them.
final class DecodedImageCacheTests: XCTestCase {
    private let clock = MediaClock(now: MediaInstant.epoch)

    private func digest(_ text: String) -> ContentDigest {
        ContentDigest.sha256(Data(text.utf8))
    }

    private func makeCache(
        decodedBytes: Int = 1 << 20,
        unpublishedBytes: Int = 1 << 20,
        maxAge: TimeInterval? = nil,
        reclaim: DecodedImageCache.Reclaimer? = nil
    ) -> DecodedImageCache {
        DecodedImageCache(
            limits: MediaCacheLimits(
                decodedBytes: decodedBytes,
                unpublishedBytes: unpublishedBytes,
                unpublishedMaxAge: maxAge
            ),
            clock: clock,
            reclaim: reclaim
        )
    }

    // MARK: classes

    func testADecodedEntryIsFreelyEvictable() async {
        let cache = makeCache()
        let id = AssetVersionID(contentDigest: digest("one"), recipeVersion: .sourceBytes)
        let bitmap = MediaFixture.bitmap(width: 10, height: 5)

        await cache.storeDecoded(bitmap, descriptor: MediaFixture.descriptor(digest: digest("one"), byteCount: 400))
        await expectEqual(cache.evictionClass(id), .decoded)
        await expectEqual(cache.breakdown().decodedBitmapBytes, bitmap.byteCount)

        let report = await cache.discardDecodedCache()

        XCTAssertEqual(report.freedBytes, bitmap.byteCount)
        XCTAssertEqual(report.evicted, [id])
        XCTAssertEqual(report.protectedByPin, [])
        await expectNil(cache.decoded(id))
        await expectEqual(cache.registeredIDs(), [], "an entry with nothing but a bitmap has nothing left to describe")
    }

    func testDiscardingDecodedMaterialKeepsIdentityAndDimensions() async {
        let cache = makeCache()
        let id = AssetVersionID(contentDigest: digest("one"), recipeVersion: .sourceBytes)
        let descriptor = MediaFixture.descriptor(
            digest: digest("one"),
            byteCount: 900,
            pixelWidth: 600,
            pixelHeight: 200
        )
        await cache.registerUnpublished(descriptor)
        await cache.storeDecoded(MediaFixture.bitmap(width: 600, height: 200), descriptor: descriptor)

        _ = await cache.discardDecodedCache()

        await expectNil(cache.decoded(id))
        await expectEqual(cache.descriptor(id), descriptor, "identity and layout survive the bitmap")
        await expectEqual(cache.evictionClass(id), .downloaded)
    }

    func testUnpublishedDownloadsAreEvictedUnderQuotaLeastRecentlyUsedFirst() async {
        let released = ReleasedBytes(perEntry: 40)
        let cache = makeCache(unpublishedBytes: 100, reclaim: { ids in await released.record(ids) })
        var ids: [AssetVersionID] = []
        for name in ["one", "two", "three"] {
            let descriptor = MediaFixture.descriptor(digest: digest(name), byteCount: 40)
            await cache.registerUnpublished(descriptor)
            ids.append(descriptor.assetVersionID)
        }
        await expectEqual(cache.breakdown().unpublishedBytes, 120)

        let report = await cache.trimUnpublishedDownloads()

        XCTAssertEqual(report.evicted, [ids[0]], "the least recently used entry goes first")
        XCTAssertEqual(report.freedBytes, 40)
        await expectEqual(cache.breakdown().unpublishedBytes, 80)
        await expectNotNil(cache.descriptor(ids[1]))
        await expectNotNil(cache.descriptor(ids[2]))
        await expectEqual(released.reclaimed, [ids[0]])
    }

    func testTrimToLimitsHonoursBothQuotas() async {
        let cache = makeCache(decodedBytes: 8, unpublishedBytes: 40)
        let withBitmap = MediaFixture.descriptor(digest: digest("one"), byteCount: 40)
        let withoutBitmap = MediaFixture.descriptor(digest: digest("two"), byteCount: 40)
        await cache.registerUnpublished(withBitmap)
        await cache.registerUnpublished(withoutBitmap)
        await cache.storeDecoded(MediaFixture.bitmap(width: 2, height: 2), descriptor: withBitmap)
        await expectEqual(cache.breakdown().decodedBitmapBytes, 16)

        let report = await cache.trimToLimits()

        await expectNil(cache.decoded(withBitmap.assetVersionID), "the memory budget wins over the bitmap")
        await expectNotNil(cache.descriptor(withBitmap.assetVersionID))
        await expectNil(cache.descriptor(withoutBitmap.assetVersionID), "the quota wins over the older download")
        XCTAssertEqual(report.freedBytes, 16 + 40)
        XCTAssertEqual(Set(report.evicted), [withBitmap.assetVersionID, withoutBitmap.assetVersionID])
        await expectEqual(cache.breakdown().unpublishedBytes, 40)
    }

    func testAgeRetentionUsesTheStatedInstant() async {
        let cache = makeCache(maxAge: 600)
        let id = AssetVersionID(contentDigest: digest("one"), recipeVersion: .sourceBytes)
        await cache.registerUnpublished(MediaFixture.descriptor(digest: digest("one"), byteCount: 40))

        await expectEqual(cache.evictExpired(asOf: MediaInstant.at(599)).evicted, [])
        await expectEqual(cache.evictExpired(asOf: MediaInstant.at(600)).evicted, [], "the boundary is inclusive")
        await expectEqual(cache.evictExpired(asOf: MediaInstant.at(601)).evicted, [id])
        await expectEqual(cache.registeredIDs(), [])
    }

    // MARK: pins

    func testAPinnedEntrySurvivesEveryEvictionPathAndBecomingCollectableAfterUnpinning() async {
        let released = ReleasedBytes(perEntry: 800)
        let cache = makeCache(decodedBytes: 0, unpublishedBytes: 0, maxAge: 1, reclaim: { ids in await released.record(ids) })
        let id = AssetVersionID(contentDigest: digest("one"), recipeVersion: .sourceBytes)
        let descriptor = MediaFixture.descriptor(digest: digest("one"), byteCount: 800, pixelWidth: 600, pixelHeight: 200)
        let bitmap = MediaFixture.bitmap(width: 600, height: 200)
        await cache.registerUnpublished(descriptor)
        await cache.storeDecoded(bitmap, descriptor: descriptor)
        let owner = MediaPinOwner(kind: .bookmark, ownerID: "bookmark-1")
        await expectTrue(cache.pin(id, owner: owner))
        await expectTrue(cache.isPinned(id))

        let discarded = await cache.discardDecodedCache()
        let quota = await cache.trimToLimits()
        let downloads = await cache.trimUnpublishedDownloads()
        let expired = await cache.evictExpired(asOf: MediaInstant.at(1_000_000))
        let collected = await cache.collectUnpinnedEntries()

        for report in [discarded, quota, downloads, expired, collected] {
            XCTAssertEqual(report.freedBytes, 0, "a pinned entry releases nothing")
            XCTAssertEqual(report.evicted, [], "a pinned entry is never evicted")
            XCTAssertEqual(report.protectedByPin, [id], "and the caller is told why")
        }
        await expectEqual(cache.descriptor(id), descriptor)
        await expectEqual(cache.decoded(id), bitmap, "even the freely evictable bitmap is protected")
        await expectEqual(released.reclaimed, [])

        await expectTrue(cache.unpin(id, owner: owner))
        await expectFalse(cache.isPinned(id))
        let afterUnpin = await cache.collectUnpinnedEntries()
        XCTAssertEqual(afterUnpin.evicted, [id])
        XCTAssertEqual(afterUnpin.freedBytes, 800)
        await expectEqual(cache.registeredIDs(), [])
    }

    func testTheLastPinReleaseIsWhatMakesAnEntryCollectable() async {
        let cache = makeCache()
        let id = AssetVersionID(contentDigest: digest("one"), recipeVersion: .sourceBytes)
        await cache.registerUnpublished(MediaFixture.descriptor(digest: digest("one"), byteCount: 10))
        let edition = MediaPinOwner(kind: .edition, ownerID: "edition-7")
        let bookmark = MediaPinOwner(kind: .bookmark, ownerID: "bookmark-9")
        await cache.pin(id, owner: edition)
        await cache.pin(id, owner: bookmark)
        await expectEqual(cache.pinnedOwners(id), [edition, bookmark])

        await cache.unpin(id, owner: edition)

        await expectTrue(cache.isPinned(id))
        await expectEqual(cache.collectUnpinnedEntries().evicted, [])
        await cache.unpin(id, owner: bookmark)
        await expectEqual(cache.collectUnpinnedEntries().evicted, [id])
    }

    func testPinningAnUnregisteredAssetIsRefusedSoAPinCannotResurrectIdentity() async {
        let cache = makeCache()
        let id = AssetVersionID(contentDigest: digest("missing"), recipeVersion: .sourceBytes)

        await expectFalse(cache.pin(id, owner: MediaPinOwner(kind: .edition, ownerID: "edition-1")))
        await expectFalse(cache.isPinned(id))
        await expectEqual(cache.registeredIDs(), [])
    }

    func testGCNeverRemovesPinnedPublishedBytes() async {
        let cache = makeCache()
        let id = AssetVersionID(contentDigest: digest("one"), recipeVersion: .sourceBytes)
        let owner = MediaPinOwner(kind: .edition, ownerID: "edition-1")
        await cache.registerUnpublished(MediaFixture.descriptor(digest: digest("one"), byteCount: 64))
        await expectTrue(cache.markPublished(id))
        await expectEqual(cache.evictionClass(id), .published)
        await cache.pin(id, owner: owner)

        await expectEqual(cache.collectUnpinnedEntries().evicted, [])
        await expectEqual(cache.descriptor(id)?.byteCount, 64)

        await cache.unpin(id, owner: owner)
        let afterRelease = await cache.collectUnpinnedEntries()

        XCTAssertEqual(afterRelease.evicted, [id])
        await expectEqual(cache.breakdown().publishedBytes, 0)
    }

    func testPublishingDoesNotDemoteAnEntryAndStoringDoesNotEither() async {
        let cache = makeCache()
        let id = AssetVersionID(contentDigest: digest("one"), recipeVersion: .sourceBytes)
        let descriptor = MediaFixture.descriptor(digest: digest("one"), byteCount: 64)
        await cache.registerUnpublished(descriptor)
        await expectEqual(cache.evictionClass(id), .downloaded)

        await cache.markPublished(id)
        await cache.registerUnpublished(descriptor)
        await cache.storeDecoded(MediaFixture.bitmap(width: 2, height: 2), descriptor: descriptor)

        await expectEqual(cache.evictionClass(id), .published, "the class is monotonic")
    }

    func testBreakdownCountsEachClassSeparately() async {
        let cache = makeCache()
        let published = AssetVersionID(contentDigest: digest("published"), recipeVersion: .sourceBytes)
        await cache.registerUnpublished(MediaFixture.descriptor(digest: digest("downloaded"), byteCount: 10))
        await cache.registerUnpublished(MediaFixture.descriptor(digest: digest("published"), byteCount: 90))
        await cache.markPublished(published)
        await cache.storeDecoded(
            MediaFixture.bitmap(width: 4, height: 1),
            descriptor: MediaFixture.descriptor(digest: digest("published"), byteCount: 90)
        )

        let breakdown = await cache.breakdown()

        XCTAssertEqual(breakdown.unpublishedBytes, 10)
        XCTAssertEqual(breakdown.publishedBytes, 90)
        XCTAssertEqual(breakdown.decodedBitmapBytes, 16)
        XCTAssertEqual(breakdown.entryCount, 2)
    }
}

/// Records what a reclaimer was asked to release, and reports the bytes each entry held.
private actor ReleasedBytes {
    private(set) var reclaimed: [AssetVersionID] = []
    private let perEntry: Int

    init(perEntry: Int) {
        self.perEntry = perEntry
    }

    func record(_ ids: [AssetVersionID]) -> Int {
        reclaimed.append(contentsOf: ids)
        return ids.count * perEntry
    }
}
