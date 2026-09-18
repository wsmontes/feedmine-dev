import FeedDomain
import Foundation
import XCTest
@testable import FeedMedia

/// The renderer-facing contract: zero network, a deterministic placeholder, and single-flight
/// preparation (plan §10, plan §14 PR-08).
final class ImageBrokerTests: XCTestCase {
    private func identity(
        _ text: String,
        pixelWidth: Int? = 600,
        pixelHeight: Int? = 400,
        recipeVersion: MediaRecipeVersion = .sourceBytes
    ) -> MediaAssetIdentity {
        MediaAssetIdentity(
            assetVersionID: AssetVersionID(
                contentDigest: ContentDigest.sha256(Data(text.utf8)),
                recipeVersion: recipeVersion
            ),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            mimeType: "image/png"
        )
    }

    // MARK: renderer network = 0

    /// Contract matrix row #22 (I-02): a card whose bytes were never fetched renders immediately.
    func testOfflineCardDoesNotRequireRemotePlaybackAsset() async {
        let fixture = MediaPipelineFixture()

        let materialized = await fixture.broker.materializedImage(for: identity("asset-a"))

        guard case let .placeholder(recipe) = materialized else {
            return XCTFail("expected the deterministic placeholder")
        }
        XCTAssertEqual(recipe.aspectRatio, 1.5, "the published layout survives")
        XCTAssertEqual(recipe.recipeVersion, PlaceholderRecipe.currentVersion)
        await expectEqual(fixture.transport.callCount, 0)
        XCTAssertEqual(fixture.decoder.decodeCount, 0)
        await expectEqual(fixture.publisher.publishedCount, 0)
    }

    func testThePlaceholderIsDeterministicAcrossInstances() async {
        let first = MediaPipelineFixture()
        let second = MediaPipelineFixture()
        let asset = identity("asset-a")

        let one = await first.broker.materializedImage(for: asset).placeholderRecipe
        let two = await second.broker.materializedImage(for: asset).placeholderRecipe
        let other = await second.broker.materializedImage(for: identity("asset-b")).placeholderRecipe

        XCTAssertEqual(one, two, "same identity, same placeholder, in any process")
        XCTAssertNotEqual(one?.seed, other?.seed)
    }

    func testAPlaceholderWithoutKnownDimensionsHasNoAspectRatioToPreserve() async {
        let fixture = MediaPipelineFixture()

        let recipe = await fixture.broker
            .materializedImage(for: identity("asset-a", pixelWidth: nil, pixelHeight: nil))
            .placeholderRecipe

        XCTAssertNil(recipe?.aspectRatio)
    }

    func testTheRenderPathReturnsTheMaterializedBitmapOnceItExists() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body)

        let prepared = await awaitValue { try await fixture.broker.prepare(request) }
        guard let prepared else { return }
        let materialized = await fixture.broker.materializedImage(for: prepared.descriptor.identity)

        XCTAssertEqual(materialized.decodedImage, prepared.decoded)
        XCTAssertFalse(materialized.isPlaceholder)
    }

    func testPrewarmLocalMaterializesDurableBytesWithoutNetwork() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = LocalAssetStore(rootDirectory: directory.url)
        let body = MediaFixture.pngBytes
        let digest = ContentDigest.sha256(body)
        let identity = MediaAssetIdentity(
            assetVersionID: AssetVersionID(contentDigest: digest, recipeVersion: .sourceBytes),
            pixelWidth: 6,
            pixelHeight: 4,
            mimeType: "image/png"
        )
        let descriptor = MediaAssetDescriptor(identity: identity, byteCount: body.count)
        _ = try store.commit(bytes: body, expecting: descriptor)

        let transport = SpyHTTPTransport()
        let clock = MediaClock(now: MediaInstant.epoch)
        let cache = DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1 << 20, unpublishedBytes: 1 << 20),
            clock: clock,
            reclaim: { await store.reclaim($0) }
        )
        let preparation = MediaPreparation(
            transport: transport,
            budget: .current,
            decoder: ImageIODecoder(),
            store: store,
            cache: cache,
            clock: clock
        )
        let broker = ImageBroker(preparation: preparation, cache: cache)

        let materialized = await broker.prewarmLocal(identity)

        XCTAssertNotNil(materialized.decodedImage)
        await expectEqual(transport.callCount, 0)
        await expectNotNil(cache.decoded(identity.assetVersionID))
    }

    // MARK: single-flight

    func testTwoConcurrentPreparationsOfTheSameAssetCauseOneTransportCallAndOneDecode() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        await fixture.transport.hold()
        let request = MediaFixture.request(body: body)

        let first = Task { try await fixture.broker.prepare(request) }
        await fixture.transport.waitForCalls(1)
        let second = Task { try await fixture.broker.prepare(request) }

        var joined = false
        for _ in 0 ..< 10_000 {
            if await fixture.broker.coalescedRequestCount == 1 {
                joined = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(joined, "the second request must join the in-flight preparation")
        await expectEqual(fixture.transport.callCount, 1, "one transport call while both callers wait")
        await expectEqual(fixture.broker.inFlightPreparationCount, 1)

        await fixture.transport.release()
        let firstResult = await awaitValue { try await first.value }
        let secondResult = await awaitValue { try await second.value }

        XCTAssertEqual(firstResult, secondResult, "the coalesced callers share one result")
        await expectEqual(fixture.transport.callCount, 1)
        XCTAssertEqual(fixture.decoder.decodeCount, 1)
        await expectEqual(fixture.publisher.publishedCount, 1)
        await expectEqual(fixture.broker.inFlightPreparationCount, 0)
    }

    func testASecondWidthReusesThePublishedBytesWithoutAnotherDownload() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        let wide = await awaitValue {
            try await fixture.broker.prepare(MediaFixture.request(body: body, targetWidth: 300))
        }
        let narrow = await awaitValue {
            try await fixture.broker.prepare(MediaFixture.request(body: body, targetWidth: 150))
        }

        guard let wide, let narrow else { return }
        XCTAssertFalse(wide.servedFromLocalAsset)
        XCTAssertTrue(narrow.servedFromLocalAsset, "the bytes are content-addressed, so the width is free")
        XCTAssertEqual(narrow.decoded.pixelWidth, 150)
        await expectEqual(fixture.transport.callCount, 1)
    }

    func testAFailedPreparationIsNotCached() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: Data("different-bytes".utf8))

        let failure = await awaitError {
            try await fixture.broker.prepare(MediaFixture.request(body: body))
        }
        XCTAssertEqual(
            failure as? MediaPreparationError,
            .digestMismatch(
                expected: ContentDigest.sha256(body),
                actual: ContentDigest.sha256(Data("different-bytes".utf8))
            )
        )

        await fixture.transport.respond(with: body)
        let recovered = await awaitValue {
            try await fixture.broker.prepare(MediaFixture.request(body: body))
        }

        XCTAssertNotNil(recovered, "a refused asset is retried, never remembered as present")
        await expectEqual(fixture.transport.callCount, 2)
    }

    func testCorruptedBytesDegradeToTheSamePlaceholderWithTheSameLayout() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        let asset = identity("asset-a")
        let expected = await fixture.broker.materializedImage(for: asset).placeholderRecipe
        await fixture.transport.respond(with: Data("corrupted-bytes".utf8))

        _ = await awaitError { try await fixture.broker.prepare(MediaFixture.request(body: body)) }
        let afterCorruption = await fixture.broker.materializedImage(for: asset)

        XCTAssertEqual(afterCorruption.placeholderRecipe, expected)
        XCTAssertEqual(afterCorruption.placeholderRecipe?.aspectRatio, 1.5)
        XCTAssertTrue(afterCorruption.isPlaceholder)
        await expectEqual(fixture.publisher.publishedCount, 0)
    }

    // MARK: the publication boundary

    /// Contract matrix row #21 (ADR-001 D13/D14, ADR-004 D8): eviction of the decoded cache never
    /// changes a published asset, and its bytes stay reproducible offline.
    func testDecodedEvictionPreservesExactPublishedAsset() async {
        let fixture = MediaPipelineFixture(
            limits: MediaCacheLimits(decodedBytes: 0, unpublishedBytes: 0, unpublishedMaxAge: 0)
        )
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body, targetWidth: 300)
        guard let prepared = await awaitValue({ try await fixture.broker.prepare(request) }) else { return }
        let id = prepared.descriptor.assetVersionID
        await fixture.broker.markPublished(id, pinnedBy: MediaPinOwner(kind: .edition, ownerID: "edition-1"))

        // Every eviction path runs against zero budgets; none of them may take a published asset.
        _ = await fixture.cache.discardDecodedCache()
        _ = await fixture.cache.trimToLimits()
        _ = await fixture.cache.evictExpired(asOf: MediaInstant.at(1_000_000_000))
        _ = await fixture.cache.collectUnpinnedEntries()

        await expectEqual(fixture.cache.descriptor(id), prepared.descriptor)
        await expectEqual(fixture.cache.evictionClass(id), .published)
        await expectTrue(fixture.cache.isPinned(id))
        await expectEqual(fixture.publisher.bytes(for: id), body)
        await expectEqual(
            fixture.broker.materializedImage(for: prepared.descriptor.identity).decodedImage,
            prepared.decoded
        )

        // Re-materializing from the retained bytes reproduces the same asset with no network.
        guard let again = await awaitValue({ try await fixture.broker.prepare(request) }) else { return }
        XCTAssertTrue(again.servedFromLocalAsset)
        XCTAssertEqual(again.decoded, prepared.decoded)
        await expectEqual(fixture.transport.callCount, 1)
        await expectEqual(again.descriptor, prepared.descriptor)
    }

    func testMarkingAnAssetPublishedProtectsItUntilThePublicationReleasesIt() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body)
        let prepared = await awaitValue { try await fixture.broker.prepare(request) }
        guard let prepared else { return }
        let id = prepared.descriptor.assetVersionID
        let owner = MediaPinOwner(kind: .edition, ownerID: "edition-1")

        await fixture.broker.markPublished(id, pinnedBy: owner)

        await expectEqual(fixture.cache.evictionClass(id), .published)
        await expectTrue(fixture.cache.isPinned(id))
        let collected = await fixture.cache.collectUnpinnedEntries()
        XCTAssertEqual(collected.evicted, [])
        XCTAssertEqual(collected.freedBytes, 0)
        await expectEqual(fixture.publisher.storedCount, 1)

        await fixture.cache.unpin(id, owner: owner)
        let afterRelease = await fixture.cache.collectUnpinnedEntries()

        XCTAssertEqual(afterRelease.evicted, [id])
        await expectEqual(fixture.publisher.storedCount, 0)
        await expectTrue(fixture.broker.materializedImage(for: prepared.descriptor.identity).isPlaceholder)
    }
}
