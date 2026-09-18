import FeedDomain
import Foundation
import XCTest
@testable import FeedMedia

/// The media half of retention: `MediaRetentionCollector` is where `FeedStorage`'s coordinator meets
/// the two collectors PR-08 shipped.
///
/// The port exists because the coordinator may not see `FeedMedia` (plan §3). What these tests pin is
/// therefore the *mapping*: that the adapter runs the limits before the sweep, that a pin still stops
/// both, that the identity spelling of an asset survives the hop between the database and the media
/// module, and that the orphan-file path is `LocalAssetStore.collectOrphanTemporaryFiles()` rather
/// than a new one.
final class MediaRetentionCollectorTests: XCTestCase {
    private let clock = MediaClock(now: MediaInstant.epoch)

    private func digest(_ text: String) -> ContentDigest {
        ContentDigest.sha256(Data(text.utf8))
    }

    private func makeStore(_ root: URL, interruption: LocalAssetStore.Interruption? = nil) -> LocalAssetStore {
        LocalAssetStore(rootDirectory: root, interruption: interruption)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedmedia-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testCollectUnpinnedMediaTrimsToTheQuotaBeforeSweeping() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        // One byte of quota, two kilobytes held: the limit has to run, not just the sweep.
        let cache = DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1, unpublishedBytes: 1),
            clock: clock,
            reclaim: { ids in await store.reclaim(ids) }
        )
        await cache.storeDecoded(
            MediaFixture.bitmap(width: 80, height: 40),
            descriptor: MediaFixture.descriptor(digest: digest("decoded"), byteCount: 12_800)
        )
        await cache.registerUnpublished(
            MediaFixture.descriptor(digest: digest("download"), byteCount: 900)
        )
        await cache.registerUnpublished(
            MediaFixture.descriptor(digest: digest("download-2"), byteCount: 700)
        )

        let collector = MediaRetentionCollector(cache: cache, assets: store)
        let outcome = await collector.collectUnpinnedMedia()

        XCTAssertEqual(outcome.collected, 3, "the bitmap and both downloads went")
        XCTAssertGreaterThan(outcome.freedBytes, 0)
        let remaining = await cache.registeredIDs()
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(outcome.protectedByPin, 0)
    }

    func testAPinnedEntrySurvivesTheLimitsAndTheSweep() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let cache = DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1, unpublishedBytes: 1),
            clock: clock,
            reclaim: { ids in await store.reclaim(ids) }
        )
        let held = AssetVersionID(contentDigest: digest("held"), recipeVersion: .sourceBytes)
        await cache.registerUnpublished(
            MediaFixture.descriptor(digest: digest("held"), byteCount: 4_096)
        )
        await cache.pin(held, owner: MediaPinOwner(kind: .bookmark, ownerID: "legacy-saved"))

        let collector = MediaRetentionCollector(cache: cache, assets: store)
        let outcome = await collector.collectUnpinnedMedia()

        XCTAssertEqual(outcome.collected, 0)
        XCTAssertEqual(outcome.protectedByPin, 1, "the pin is reported, never silently kept")
        let remaining = await cache.registeredIDs()
        let stillPinned = await cache.isPinned(held)
        XCTAssertEqual(remaining, [held])
        XCTAssertTrue(stillPinned)
    }

    func testCollectAssetBytesSpeaksTheDatabaseSpellingOfAnIdentity() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let bytes = Data(repeating: 0x5A, count: 128)
        let contentDigest = ContentDigest.sha256(bytes)
        let descriptor = MediaAssetDescriptor(
            identity: MediaAssetIdentity(
                assetVersionID: AssetVersionID(contentDigest: contentDigest, recipeVersion: .sourceBytes),
                pixelWidth: 8,
                pixelHeight: 8,
                mimeType: "image/png"
            ),
            byteCount: bytes.count
        )
        _ = try store.commit(bytes: bytes, expecting: descriptor)
        let id = descriptor.assetVersionID
        XCTAssertTrue(store.contains(id))

        let collector = MediaRetentionCollector(cache: DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1, unpublishedBytes: 1),
            clock: clock
        ), assets: store)
        // The identity as `asset_version` stores it: lowercase digest hex plus recipe.
        let key = MediaAssetKey(contentDigestHex: contentDigest.hex, recipeVersion: 1)
        let outcome = await collector.collectAssetBytes([key])

        XCTAssertEqual(outcome.collected, 1)
        XCTAssertEqual(outcome.freedBytes, bytes.count)
        XCTAssertFalse(store.contains(id), "the files are gone")
        XCTAssertEqual(MediaAssetKey(id), key, "and the two spellings name the same asset")
    }

    func testAnUnreadableIdentityIsReportedRatherThanDropped() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root)
        let collector = MediaRetentionCollector(cache: DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1, unpublishedBytes: 1),
            clock: clock
        ), assets: store)

        // A digest that is not a SHA-256, and a recipe of zero: rows this class can hold and the media
        // identity cannot. They are counted as protected so a caller sees them.
        let outcome = await collector.collectAssetBytes([
            MediaAssetKey(contentDigestHex: "not-a-digest", recipeVersion: 1),
            MediaAssetKey(contentDigestHex: digest("x").hex, recipeVersion: 0),
        ])

        XCTAssertEqual(outcome.collected, 0)
        XCTAssertEqual(outcome.protectedByPin, 2)
    }

    func testOrphanTemporaryFilesAreCollectedThroughTheStoresOwnPath() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The interruption writes the temporary file and stops before the immutable move: exactly the
        // orphan a killed commit leaves, which `collectOrphanTemporaryFiles()` reclaims.
        let interrupted = makeStore(root, interruption: .beforeMove)
        let bytes = Data(repeating: 0x11, count: 64)
        let descriptor = MediaAssetDescriptor(
            identity: MediaAssetIdentity(
                assetVersionID: AssetVersionID(
                    contentDigest: ContentDigest.sha256(bytes),
                    recipeVersion: .sourceBytes
                ),
                pixelWidth: nil,
                pixelHeight: nil,
                mimeType: "image/png"
            ),
            byteCount: bytes.count
        )
        XCTAssertThrowsError(try interrupted.commit(bytes: bytes, expecting: descriptor))
        XCTAssertEqual(try interrupted.orphanTemporaryFiles().count, 1)

        let store = makeStore(root)
        let collector = MediaRetentionCollector(cache: DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1, unpublishedBytes: 1),
            clock: clock
        ), assets: store)
        let outcome = await collector.collectOrphanAssetFiles()

        XCTAssertEqual(outcome.collected, 1)
        XCTAssertEqual(outcome.orphansCollected, 1)
        XCTAssertEqual(outcome.freedBytes, bytes.count)
        XCTAssertEqual(try store.orphanTemporaryFiles(), [], "the store's own reclaim path ran")
    }
}
