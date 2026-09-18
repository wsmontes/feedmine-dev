import FeedDomain
import Foundation
import XCTest
import os
@testable import FeedMedia

/// A clock that never moves. Determinism is the point: no test here sleeps or reads `Date()`.
struct MediaClock: EditorialClock {
    let now: Date
}

enum MediaInstant {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func at(_ offset: TimeInterval) -> Date {
        epoch.addingTimeInterval(offset)
    }
}

enum MediaFixture {
    /// A real 73-byte PNG (6x4). Small enough to keep the suite honest about not shipping image
    /// fixtures, real enough to exercise the production ImageIO decoder end to end.
    static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAYAAAAECAIAAAAiZtkUAAAAEElEQVR4nGP4DwMMcECuEAD0nSPd30chHQAAAABJRU5ErkJggg=="

    static var pngBytes: Data { Data(base64Encoded: pngBase64) ?? Data() }

    static var mediaURL: URL {
        URL(string: "https://media.example.test/a.png") ?? URL(fileURLWithPath: "/dev/null")
    }

    static func bitmap(width: Int, height: Int) -> DecodedImage {
        let bytesPerRow = width * 4
        return DecodedImage(
            pixelWidth: width,
            pixelHeight: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(repeating: 0x80, count: bytesPerRow * height)
        )
    }

    static func descriptor(
        digest: ContentDigest,
        byteCount: Int,
        pixelWidth: Int? = 600,
        pixelHeight: Int? = 200,
        mimeType: String? = "image/png"
    ) -> MediaAssetDescriptor {
        MediaAssetDescriptor(
            identity: MediaAssetIdentity(
                assetVersionID: AssetVersionID(
                    contentDigest: digest,
                    recipeVersion: .sourceBytes
                ),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                mimeType: mimeType
            ),
            byteCount: byteCount
        )
    }

    static func request(
        body: Data,
        url: URL = MediaFixture.mediaURL,
        targetWidth: Int? = nil,
        role: MediaRole = .image,
        deadline: Date = MediaInstant.at(60),
        expectedByteCount: Int? = nil,
        expectedDigest: ContentDigest? = nil
    ) -> MediaPreparationRequest {
        MediaPreparationRequest(
            url: url,
            expectedDigest: expectedDigest ?? ContentDigest.sha256(body),
            expectedByteCount: expectedByteCount,
            role: role,
            targetWidth: targetWidth,
            deadline: deadline
        )
    }
}

/// A transport that records every request, can answer a scripted response, and can be held open so a
/// test can observe the in-flight state of a preparation.
actor SpyHTTPTransport: HTTPTransport {
    struct Call: Sendable, Equatable {
        let url: URL
        let timeout: TimeInterval
        let method: String?
    }

    private var calls: [Call] = []
    private var body = Data()
    private var status = 200
    private var thrown: HTTPTransportError?
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var callWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func respond(with body: Data, status: Int = 200) {
        self.body = body
        self.status = status
    }

    func fail(with error: HTTPTransportError) {
        thrown = error
    }

    /// Holds the next call open until `release()`.
    func hold() { holding = true }

    func release() {
        holding = false
        let pending = held
        held = []
        for waiter in pending { waiter.resume() }
    }

    var callCount: Int { calls.count }
    var recordedCalls: [Call] { calls }

    /// Waits until at least `count` calls have started, without polling.
    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw HTTPTransportError.notHTTP }
        calls.append(Call(url: url, timeout: request.timeoutInterval, method: request.httpMethod))
        let satisfied = callWaiters.filter { calls.count >= $0.threshold }
        callWaiters.removeAll { calls.count >= $0.threshold }
        for waiter in satisfied { waiter.continuation.resume() }
        if holding {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                held.append(continuation)
            }
        }
        if let thrown { throw thrown }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            throw HTTPTransportError.notHTTP
        }
        return (body, response)
    }
}

/// A decoder double. `decode` is synchronous on purpose: that is the only way to observe, from
/// inside the call, whether the pipeline handed the work to a non-main actor.
final class SpyImageDecoder: ImageDecoding, Sendable {
    struct Log: Sendable {
        var inspectCount = 0
        var decodeCount = 0
        var decodeRanOnMainThread: Bool?
        var lastDownsampleTarget: Int?
    }

    private let log = OSAllocatedUnfairLock(initialState: Log())
    private let metadata: ImageMetadata
    private let decoded: DecodedImage
    private let inspectFailure: ImageDecodingError?
    private let decodeFailure: ImageDecodingError?
    private let decodeWidthOverride: Int?

    init(
        metadata: ImageMetadata = ImageMetadata(pixelWidth: 600, pixelHeight: 200, mimeType: "image/png"),
        decoded: DecodedImage = MediaFixture.bitmap(width: 600, height: 200),
        inspectFailure: ImageDecodingError? = nil,
        decodeFailure: ImageDecodingError? = nil,
        decodeWidthOverride: Int? = nil
    ) {
        self.metadata = metadata
        self.decoded = decoded
        self.inspectFailure = inspectFailure
        self.decodeFailure = decodeFailure
        self.decodeWidthOverride = decodeWidthOverride
    }

    var inspectCount: Int { log.withLock { $0.inspectCount } }
    var decodeCount: Int { log.withLock { $0.decodeCount } }
    var decodeRanOnMainThread: Bool? { log.withLock { $0.decodeRanOnMainThread } }
    var lastDownsampleTarget: Int? { log.withLock { $0.lastDownsampleTarget } }

    func inspect(_ bytes: Data) throws -> ImageMetadata {
        log.withLock { $0.inspectCount += 1 }
        if let inspectFailure { throw inspectFailure }
        return metadata
    }

    func decode(_ bytes: Data, downsampleTo targetWidth: Int?) throws -> DecodedImage {
        log.withLock {
            $0.decodeCount += 1
            $0.decodeRanOnMainThread = Thread.isMainThread
            $0.lastDownsampleTarget = targetWidth
        }
        if let decodeFailure { throw decodeFailure }
        if let decodeWidthOverride {
            return MediaFixture.bitmap(width: decodeWidthOverride, height: 10)
        }
        guard let targetWidth, targetWidth < decoded.pixelWidth else { return decoded }
        let height = max(1, decoded.pixelHeight * targetWidth / max(1, decoded.pixelWidth))
        return MediaFixture.bitmap(width: targetWidth, height: height)
    }
}

/// An in-memory stand-in for the durable store: it records what was published, can hold a publish
/// open, and reclaims the bytes the cache evicts.
actor RecordingPublisher: MediaAssetPublishing {
    private var stored: [AssetVersionID: Data] = [:]
    private var publishCount = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var failure: MediaStorageError?

    func localBytes(for id: AssetVersionID) async throws -> Data? { stored[id] }

    func publish(_ bytes: Data, descriptor: MediaAssetDescriptor) async throws {
        publishCount += 1
        if holding {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                held.append(continuation)
            }
        }
        if let failure { throw failure }
        stored[descriptor.assetVersionID] = bytes
    }

    func reclaim(_ ids: [AssetVersionID]) async -> Int {
        var released = 0
        for id in ids {
            guard let bytes = stored[id] else { continue }
            released += bytes.count
            stored[id] = nil
        }
        return released
    }

    func holdPublish() { holding = true }

    func releasePublish() {
        holding = false
        let pending = held
        held = []
        for waiter in pending { waiter.resume() }
    }

    func failPublish(with error: MediaStorageError) { failure = error }

    /// Rot the bytes filed under an identity, without changing the identity they are filed under:
    /// what a corrupted content-addressed store looks like.
    func replaceBytes(for id: AssetVersionID, with bytes: Data) {
        stored[id] = bytes
    }

    var publishedCount: Int { publishCount }
    var storedCount: Int { stored.count }
    func bytes(for id: AssetVersionID) -> Data? { stored[id] }
}

/// Counts the permits the preparation took. It is what proves a download and a decode are routed
/// through the injected limiter instead of running unthrottled.
final class RecordingLimiter: MediaWorkLimiter, Sendable {
    struct Counts: Sendable {
        var downloads = 0
        var decodes = 0
    }

    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    var downloadPermits: Int { counts.withLock { $0.downloads } }
    var decodePermits: Int { counts.withLock { $0.decodes } }

    func withDownloadPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        counts.withLock { $0.downloads += 1 }
        return try await body()
    }

    func withDecodePermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        counts.withLock { $0.decodes += 1 }
        return try await body()
    }
}

/// One assembled pipeline: a spy transport and decoder, an in-memory durable store, a real cache.
final class MediaPipelineFixture: Sendable {
    let transport: SpyHTTPTransport
    let decoder: SpyImageDecoder
    let publisher: RecordingPublisher
    let limiter: RecordingLimiter
    let cache: DecodedImageCache
    let preparation: MediaPreparation
    let broker: ImageBroker

    init(
        clock: any EditorialClock = MediaClock(now: MediaInstant.epoch),
        budget: MediaBudget = .current,
        limits: MediaCacheLimits = MediaCacheLimits(decodedBytes: 1 << 20, unpublishedBytes: 1 << 20),
        decoder: SpyImageDecoder = SpyImageDecoder(),
        transport: SpyHTTPTransport = SpyHTTPTransport(),
        publisher: RecordingPublisher = RecordingPublisher(),
        limiter: RecordingLimiter = RecordingLimiter()
    ) {
        self.transport = transport
        self.decoder = decoder
        self.publisher = publisher
        self.limiter = limiter
        let cache = DecodedImageCache(
            limits: limits,
            clock: clock,
            reclaim: { [publisher] ids in await publisher.reclaim(ids) }
        )
        self.cache = cache
        self.preparation = MediaPreparation(
            transport: transport,
            budget: budget,
            decoder: decoder,
            store: publisher,
            cache: cache,
            clock: clock,
            limiter: limiter
        )
        self.broker = ImageBroker(preparation: preparation, cache: cache)
    }
}

/// Runs an operation that must succeed and fails the test when it throws.
func awaitValue<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> T? {
    do {
        return try await operation()
    } catch {
        XCTFail("unexpected failure: \(error)", file: file, line: line)
        return nil
    }
}

/// Runs an operation that must fail and returns the error, so a test can assert on its type and
/// payload without nesting assertions inside a closure.
func awaitError<T>(
    _ operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Error? {
    do {
        _ = try await operation()
        XCTFail("expected the operation to fail", file: file, line: line)
        return nil
    } catch {
        return error
    }
}

/// A temporary directory that a test removes in teardown.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedmedia-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Every regular file under the directory, relative to it, sorted. Used to prove that a stopped
    /// preparation left nothing behind.
    func fileNames() -> [String] {
        // `temporaryDirectory` is `/var/...`, which the enumerator reports as `/private/var/...`.
        let base = url.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        var names: [String] = []
        while let entry = enumerator?.nextObject() as? URL {
            guard !entry.hasDirectoryPath else { continue }
            let path = entry.resolvingSymlinksInPath().path
            names.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path)
        }
        return names.sorted()
    }
}

// MARK: - Awaited expectations

// `XCTAssert*` takes its operands as autoclosures, and an autoclosure cannot await. Awaited
// observations are bound and asserted through these instead, which keeps the assertion readable.

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, message, file: file, line: line)
}

func expectTrue(
    _ actual: Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(actual, message, file: file, line: line)
}

func expectFalse(
    _ actual: Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(actual, message, file: file, line: line)
}

func expectNil<T>(
    _ actual: T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNil(actual, message, file: file, line: line)
}

func expectNotNil<T>(
    _ actual: T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNotNil(actual, message, file: file, line: line)
}
