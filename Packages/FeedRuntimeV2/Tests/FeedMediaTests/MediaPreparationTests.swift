import FeedDomain
import Foundation
import XCTest
@testable import FeedMedia

/// Runs one preparation while the calling actor is the main actor, so a test can prove the decode
/// did not happen there. A free function, because an `XCTestCase` method would have to send
/// `self` across isolation.
@MainActor
private func prepareOnTheMainActor(
    _ preparation: MediaPreparation,
    request: MediaPreparationRequest
) async -> Error? {
    do {
        _ = try await preparation.prepare(request)
        return nil
    } catch {
        return error
    }
}

/// The preparation pipeline: every step, every typed failure, and the budget gate that must refuse
/// before a decode is ever attempted (plan §10, plan §14 PR-08).
final class MediaPreparationTests: XCTestCase {
    private var temporaryDirectories: [TemporaryDirectory] = []

    override func tearDown() {
        for directory in temporaryDirectories { directory.remove() }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeTemporaryDirectory() throws -> TemporaryDirectory {
        let directory = try TemporaryDirectory()
        temporaryDirectories.append(directory)
        return directory
    }

    // MARK: budget boundaries, all refused before decode

    func testPayloadOneByteOverTheCeilingIsRejectedBeforeDecode() async {
        let fixture = MediaPipelineFixture()
        let body = Data(repeating: 0x41, count: MediaBudget.current.maxCompressedBytes + 1)
        await fixture.transport.respond(with: body)

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: body))
        }

        XCTAssertEqual(error as? MediaPreparationError, .budgetRejected(.tooManyBytes(body.count)))
        XCTAssertEqual(fixture.decoder.decodeCount, 0)
        await expectEqual(fixture.publisher.publishedCount, 0)
    }

    func testDimensionOverTheCeilingIsRejectedBeforeDecode() async {
        let decoder = SpyImageDecoder(metadata: ImageMetadata(pixelWidth: 12_001, pixelHeight: 100))
        let fixture = MediaPipelineFixture(decoder: decoder)
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: body))
        }

        XCTAssertEqual(error as? MediaPreparationError, .budgetRejected(.dimensionTooLarge(12_001)))
        XCTAssertEqual(fixture.decoder.inspectCount, 1)
        XCTAssertEqual(fixture.decoder.decodeCount, 0)
    }

    func testMorePixelsThanTheCeilingIsRejectedBeforeDecode() async {
        let decoder = SpyImageDecoder(metadata: ImageMetadata(pixelWidth: 9_000, pixelHeight: 9_000))
        let fixture = MediaPipelineFixture(decoder: decoder)
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: body))
        }

        XCTAssertEqual(error as? MediaPreparationError, .budgetRejected(.tooManyPixels(81_000_000)))
        XCTAssertEqual(fixture.decoder.decodeCount, 0)
    }

    func testEmptyPayloadIsRejectedBeforeAnyInspection() async {
        let fixture = MediaPipelineFixture()
        await fixture.transport.respond(with: Data())

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: Data()))
        }

        XCTAssertEqual(error as? MediaPreparationError, .budgetRejected(.empty))
        XCTAssertEqual(fixture.decoder.inspectCount, 0)
        XCTAssertEqual(fixture.decoder.decodeCount, 0)
    }

    func testZeroDimensionIsRejectedBeforeDecode() async {
        let decoder = SpyImageDecoder(metadata: ImageMetadata(pixelWidth: 0, pixelHeight: 100))
        let fixture = MediaPipelineFixture(decoder: decoder)
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: body))
        }

        XCTAssertEqual(error as? MediaPreparationError, .budgetRejected(.zeroDimension))
        XCTAssertEqual(fixture.decoder.decodeCount, 0)
    }

    // MARK: validation and corruption

    func testBytesWhoseDigestDiffersFromTheExpectedOneAreRefusedAndNothingIsPublished() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        let corrupted = Data("image-bytez".utf8)
        await fixture.transport.respond(with: corrupted)
        let request = MediaFixture.request(body: body)

        let error = await awaitError { try await fixture.preparation.prepare(request) }

        XCTAssertEqual(
            error as? MediaPreparationError,
            .digestMismatch(expected: ContentDigest.sha256(body), actual: ContentDigest.sha256(corrupted))
        )
        await expectEqual(fixture.publisher.publishedCount, 0)
        await expectEqual(fixture.cache.registeredIDs(), [])
    }

    func testByteCountMismatchIsRefused() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body, expectedByteCount: body.count + 1)

        let error = await awaitError { try await fixture.preparation.prepare(request) }

        XCTAssertEqual(
            error as? MediaPreparationError,
            .byteCountMismatch(expected: body.count + 1, actual: body.count)
        )
        await expectEqual(fixture.publisher.publishedCount, 0)
    }

    func testUndecodablePayloadIsATypedFailure() async {
        let decoder = SpyImageDecoder(inspectFailure: .undecodablePayload)
        let fixture = MediaPipelineFixture(decoder: decoder)
        let body = Data("not-an-image".utf8)
        await fixture.transport.respond(with: body)

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: body))
        }

        XCTAssertEqual(error as? MediaPreparationError, .undecodablePayload)
        await expectEqual(fixture.publisher.publishedCount, 0)
    }

    func testADecodeThatIgnoresTheDownsampleTargetViolatesTheContract() async {
        let decoder = SpyImageDecoder(
            metadata: ImageMetadata(pixelWidth: 600, pixelHeight: 200),
            decodeWidthOverride: 600
        )
        let fixture = MediaPipelineFixture(decoder: decoder)
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: body, targetWidth: 300))
        }

        XCTAssertEqual(
            error as? MediaPreparationError,
            .decodeContractViolation("downsample to 300 produced width 600")
        )
        await expectEqual(fixture.publisher.publishedCount, 0)
    }

    // MARK: transport

    func testNonSuccessStatusIsATypedFailure() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body, status: 503)

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: body))
        }

        XCTAssertEqual(error as? MediaPreparationError, .httpStatus(503))
        XCTAssertEqual(fixture.decoder.inspectCount, 0)
    }

    func testTransportFailureIsATypedFailure() async {
        let fixture = MediaPipelineFixture()
        await fixture.transport.fail(with: .status(-1))

        let error = await awaitError {
            try await fixture.preparation.prepare(MediaFixture.request(body: Data("image-bytes".utf8)))
        }

        XCTAssertEqual(error as? MediaPreparationError, .transport(.status(-1)))
    }

    func testNonImageRoleIsRefusedWithoutTouchingTheTransport() async {
        let fixture = MediaPipelineFixture()

        let error = await awaitError {
            try await fixture.preparation.prepare(
                MediaFixture.request(body: Data("audio-bytes".utf8), role: .audio)
            )
        }

        XCTAssertEqual(error as? MediaPreparationError, .unsupportedMediaRole(.audio))
        await expectEqual(fixture.transport.callCount, 0)
    }

    // MARK: deadline and cancellation

    func testAnExpiredDeadlineNeverTouchesTheTransport() async {
        let fixture = MediaPipelineFixture()

        let error = await awaitError {
            try await fixture.preparation.prepare(
                MediaFixture.request(body: Data("image-bytes".utf8), deadline: MediaInstant.at(-1))
            )
        }

        XCTAssertEqual(error as? MediaPreparationError, .deadlineExceeded)
        await expectEqual(fixture.transport.callCount, 0)
    }

    func testTheDeadlineBecomesTheRequestTimeout() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        _ = await awaitValue {
            try await fixture.preparation.prepare(
                MediaFixture.request(body: body, deadline: MediaInstant.at(30))
            )
        }

        let calls = await fixture.transport.recordedCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.timeout ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(calls.first?.method, "GET")
        XCTAssertEqual(calls.first?.url, MediaFixture.mediaURL)
    }

    func testCancelledPreparationStopsWorkAndPublishesNothing() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        await fixture.transport.hold()

        let task = Task { try await fixture.preparation.prepare(MediaFixture.request(body: body)) }
        await fixture.transport.waitForCalls(1)
        task.cancel()
        await fixture.transport.release()

        let error = await awaitError { try await task.value }

        XCTAssertEqual(error as? MediaPreparationError, .cancelled)
        await expectEqual(fixture.publisher.publishedCount, 0)
        await expectEqual(fixture.cache.registeredIDs(), [])
    }

    func testACancelledPreparationLeavesNoFileBehindInTheStore() async throws {
        let directory = try makeTemporaryDirectory()
        let store = FileSystemMediaAssetStore(rootDirectory: directory.url)
        let transport = SpyHTTPTransport()
        let body = Data("image-bytes".utf8)
        await transport.respond(with: body)
        await transport.hold()
        let cache = DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1 << 20, unpublishedBytes: 1 << 20),
            clock: MediaClock(now: MediaInstant.epoch),
            reclaim: { await store.reclaim($0) }
        )
        let preparation = MediaPreparation(
            transport: transport,
            budget: .current,
            decoder: SpyImageDecoder(),
            store: store,
            cache: cache,
            clock: MediaClock(now: MediaInstant.epoch)
        )

        let task = Task { try await preparation.prepare(MediaFixture.request(body: body)) }
        await transport.waitForCalls(1)
        task.cancel()
        await transport.release()
        let error = await awaitError { try await task.value }

        XCTAssertEqual(error as? MediaPreparationError, .cancelled)
        XCTAssertEqual(directory.fileNames(), [])
        await expectEqual(cache.registeredIDs(), [])
    }

    // MARK: the accepted path

    func testAcceptedPayloadIsPublishedUnderItsDigestAndDownsampled() async {
        let decoder = SpyImageDecoder(metadata: ImageMetadata(pixelWidth: 600, pixelHeight: 200, mimeType: "image/png"))
        let fixture = MediaPipelineFixture(decoder: decoder)
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body, targetWidth: 300)

        let prepared = await awaitValue { try await fixture.preparation.prepare(request) }

        guard let prepared else { return }
        XCTAssertEqual(prepared.descriptor.assetVersionID, request.assetVersionID)
        XCTAssertEqual(prepared.descriptor.byteCount, body.count)
        XCTAssertEqual(prepared.descriptor.mimeType, "image/png")
        XCTAssertEqual(prepared.descriptor.aspectRatio, 3)
        XCTAssertEqual(prepared.downsampleTarget, 300)
        XCTAssertEqual(prepared.decoded.pixelWidth, 300)
        XCTAssertFalse(prepared.servedFromLocalAsset)
        XCTAssertEqual(fixture.decoder.lastDownsampleTarget, 300)
        await expectEqual(fixture.publisher.bytes(for: request.assetVersionID), body)
        await expectEqual(fixture.cache.evictionClass(request.assetVersionID), .downloaded)
        await expectEqual(fixture.cache.descriptor(request.assetVersionID), prepared.descriptor)
        await expectNotNil(fixture.cache.decoded(request.assetVersionID))
    }

    func testASecondPreparationOfTheSameAssetNeverDownloadsAgain() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body)

        let first = await awaitValue { try await fixture.preparation.prepare(request) }
        let second = await awaitValue { try await fixture.preparation.prepare(request) }

        guard let first, let second else { return }
        XCTAssertFalse(first.servedFromLocalAsset)
        XCTAssertTrue(second.servedFromLocalAsset, "the bytes were already published under this digest")
        await expectEqual(fixture.transport.callCount, 1)
        XCTAssertEqual(fixture.decoder.decodeCount, 2, "the local path re-materializes pixels without downloading")
    }

    /// Contract matrix row #32 (ADR-006, ADR-004): work whose caller is gone, and work that is never
    /// published, may leave at most a quota-bound cache entry — never published or pinned state.
    func testStalePreparationLeavesOnlyAQuotaBoundDownload() async {
        let fixture = MediaPipelineFixture(
            limits: MediaCacheLimits(decodedBytes: 0, unpublishedBytes: 0)
        )
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body)

        guard let prepared = await awaitValue({ try await fixture.preparation.prepare(request) }) else {
            return
        }
        let id = prepared.descriptor.assetVersionID

        await expectEqual(fixture.cache.evictionClass(id), .downloaded)
        await expectFalse(fixture.cache.isPinned(id), "preparation pins nothing; a publication does")

        let collected = await fixture.cache.collectUnpinnedEntries()

        await expectEqual(collected.evicted, [id])
        await expectEqual(fixture.publisher.storedCount, 0)
        await expectEqual(fixture.transport.callCount, 1)
    }

    func testLocallyStoredBytesThatDoNotMatchTheirIdentityAreReplacedInsteadOfServed() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaFixture.request(body: body)
        let first = await awaitValue { try await fixture.preparation.prepare(request) }
        XCTAssertNotNil(first)

        // The file is still filed under the digest, but it no longer holds those bytes.
        await fixture.publisher.replaceBytes(for: request.assetVersionID, with: Data("rotted-bytes".utf8))
        let second = await awaitValue { try await fixture.preparation.prepare(request) }

        XCTAssertNotNil(second)
        XCTAssertEqual(second?.servedFromLocalAsset, false, "corrupt bytes are refetched, never served")
        await expectEqual(fixture.transport.callCount, 2)
        await expectEqual(fixture.publisher.bytes(for: request.assetVersionID), body)
    }

    func testTheMediaTypeHintWinsOverTheDecoderReport() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)
        let request = MediaPreparationRequest(
            url: MediaFixture.mediaURL,
            expectedDigest: ContentDigest.sha256(body),
            mediaTypeHint: "image/webp",
            deadline: MediaInstant.at(60)
        )

        let result = await awaitValue { try await fixture.preparation.prepare(request) }

        XCTAssertEqual(result?.descriptor.mimeType, "image/webp")
    }

    // MARK: inertness

    func testDecodeDoesNotRunOnTheMainActor() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        let error = await prepareOnTheMainActor(
            fixture.preparation,
            request: MediaFixture.request(body: body)
        )

        XCTAssertNil(error)
        XCTAssertEqual(fixture.decoder.decodeRanOnMainThread, false)
    }

    func testDownloadsAndDecodesGoThroughTheInjectedLimiter() async {
        let fixture = MediaPipelineFixture()
        let body = Data("image-bytes".utf8)
        await fixture.transport.respond(with: body)

        _ = await awaitValue {
            try await fixture.preparation.prepare(MediaFixture.request(body: body))
        }

        XCTAssertEqual(fixture.limiter.downloadPermits, 1)
        XCTAssertEqual(fixture.limiter.decodePermits, 1)
    }

    // MARK: the real decoder and the real store

    func testTheProductionDecoderReadsHeadersDecodesAndDownsamples() throws {
        let decoder = ImageIODecoder()

        let metadata = try decoder.inspect(MediaFixture.pngBytes)
        XCTAssertEqual(metadata.pixelWidth, 6)
        XCTAssertEqual(metadata.pixelHeight, 4)
        XCTAssertEqual(metadata.mimeType, "image/png")

        let full = try decoder.decode(MediaFixture.pngBytes, downsampleTo: nil)
        XCTAssertEqual(full.pixelWidth, 6)
        XCTAssertEqual(full.pixelHeight, 4)
        XCTAssertEqual(full.pixels.count, full.bytesPerRow * full.pixelHeight)

        let downsampled = try decoder.decode(MediaFixture.pngBytes, downsampleTo: 3)
        XCTAssertEqual(downsampled.pixelWidth, 3)
        XCTAssertEqual(downsampled.pixelHeight, 2)
    }

    func testTheFileSystemStoreIsContentAddressedIdempotentAndReclaimable() async throws {
        let directory = try makeTemporaryDirectory()
        let store = FileSystemMediaAssetStore(rootDirectory: directory.url)
        let bytes = MediaFixture.pngBytes
        let descriptor = MediaFixture.descriptor(
            digest: ContentDigest.sha256(bytes),
            byteCount: bytes.count,
            pixelWidth: 6,
            pixelHeight: 4
        )
        let id = descriptor.assetVersionID
        let hex = id.contentDigest.hex
        let relative = "\(hex.prefix(2))/\(hex.dropFirst(2).prefix(2))/\(hex)_r1"

        XCTAssertEqual(store.relativePath(for: id), relative, "identity, not a URL, is the path")
        let beforePublish = try await store.localBytes(for: id)
        XCTAssertNil(beforePublish)

        try await store.publish(bytes, descriptor: descriptor)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: id).path))
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: id)), bytes)
        let afterPublish = try await store.localBytes(for: id)
        XCTAssertEqual(afterPublish, bytes)
        XCTAssertEqual(directory.fileNames(), [relative], "no temporary file survived the publish")

        // Republishing one identity is a no-op: the destination is already that asset.
        try await store.publish(bytes, descriptor: descriptor)
        XCTAssertEqual(directory.fileNames(), [relative])

        let released = await store.reclaim([id])
        XCTAssertEqual(released, bytes.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: id).path))
        let afterReclaim = try await store.localBytes(for: id)
        XCTAssertNil(afterReclaim)
    }

    func testEndToEndPreparationWithTheRealDecoderAndStore() async throws {
        let directory = try makeTemporaryDirectory()
        let store = FileSystemMediaAssetStore(rootDirectory: directory.url)
        let transport = SpyHTTPTransport()
        await transport.respond(with: MediaFixture.pngBytes)
        let cache = DecodedImageCache(
            limits: MediaCacheLimits(decodedBytes: 1 << 20, unpublishedBytes: 1 << 20),
            clock: MediaClock(now: MediaInstant.epoch),
            reclaim: { await store.reclaim($0) }
        )
        let preparation = MediaPreparation(
            transport: transport,
            budget: .current,
            decoder: ImageIODecoder(),
            store: store,
            cache: cache,
            clock: MediaClock(now: MediaInstant.epoch)
        )

        let result = await awaitValue {
            try await preparation.prepare(MediaFixture.request(body: MediaFixture.pngBytes, targetWidth: 3))
        }

        guard let prepared = result else { return }
        XCTAssertEqual(prepared.decoded.pixelWidth, 3)
        XCTAssertEqual(prepared.decoded.pixelHeight, 2)
        XCTAssertEqual(prepared.descriptor.mimeType, "image/png")
        let published = store.fileURL(for: prepared.descriptor.assetVersionID)
        XCTAssertEqual(try Data(contentsOf: published), MediaFixture.pngBytes)
        await expectEqual(cache.evictionClass(prepared.descriptor.assetVersionID), .downloaded)
        XCTAssertEqual(directory.fileNames().count, 1)
    }

    // MARK: the digest itself

    func testSha256MatchesTheStandardVectors() {
        XCTAssertEqual(
            ContentDigest.sha256(Data()).hex,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ContentDigest.sha256(Data("abc".utf8)).hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            ContentDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)).hex,
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        // 55/56 and 64 bytes land on the padding and length-block boundaries.
        XCTAssertEqual(
            ContentDigest.sha256(Data(repeating: 0x61, count: 55)).hex,
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
        )
        XCTAssertEqual(
            ContentDigest.sha256(Data(repeating: 0x61, count: 56)).hex,
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
        )
        XCTAssertEqual(
            ContentDigest.sha256(Data(repeating: 0x61, count: 64)).hex,
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        )
    }

    func testAssetIdentityIsDigestPlusRecipeVersion() throws {
        let digest = ContentDigest.sha256(Data("abc".utf8))
        let first = AssetVersionID(contentDigest: digest, recipeVersion: .sourceBytes)
        let second = AssetVersionID(contentDigest: digest, recipeVersion: try MediaRecipeVersion(2))

        XCTAssertNotEqual(first, second, "the same bytes under another recipe are another asset")
        XCTAssertEqual(first.description, "\(digest.hex)_r1")
        XCTAssertThrowsError(try ContentDigest(bytes: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try MediaRecipeVersion(0))
    }
}
