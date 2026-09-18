import CoreGraphics
import FeedDomain
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Asset identity

/// Error of a malformed digest or recipe version.
public enum MediaIdentityError: Error, Equatable, Sendable {
    /// A SHA-256 digest is exactly 32 bytes.
    case invalidDigestLength(Int)
    /// A recipe version is a positive persisted value (ADR-001 D12).
    case nonPositiveRecipeVersion(Int)
}

/// The SHA-256 digest of the exact bytes of an asset.
///
/// This is the only identity an asset has (ADR-001 D12): a URL is never a cache key, because a
/// server can swap the bytes behind a stable URL. The digest is over the bytes as received, before
/// any transformation.
public struct ContentDigest: Hashable, Sendable, CustomStringConvertible {
    /// SHA-256 produces 32 bytes.
    public static let byteCount = 32

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw MediaIdentityError.invalidDigestLength(bytes.count)
        }
        self.bytes = bytes
    }

    /// The digest of `bytes`.
    public static func sha256(_ bytes: Data) -> ContentDigest {
        ContentDigest(validated: SHA256.digest(bytes))
    }

    /// Internal: the output of `SHA256.digest`, which is 32 bytes by construction.
    init(validated bytes: Data) {
        self.bytes = bytes
    }

    public var hex: String {
        var text = String()
        text.reserveCapacity(Self.byteCount * 2)
        for byte in bytes {
            text.append(Self.hexDigits[Int(byte >> 4)])
            text.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return text
    }

    public var description: String { "sha256:\(hex)" }

    private static let hexDigits: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
    ]
}

/// The version of the transformation recipe that produced an asset's bytes (ADR-001 D12).
///
/// `AssetVersionID` is `(contentDigest, recipeVersion)`, so changing the recipe produces a new
/// asset version even when the source bytes are unchanged, and never a silently different image
/// under an old identity.
public struct MediaRecipeVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) throws {
        guard rawValue > 0 else {
            throw MediaIdentityError.nonPositiveRecipeVersion(rawValue)
        }
        self.rawValue = rawValue
    }

    /// The identity recipe: the bytes exactly as downloaded, with no transformation applied.
    public static let sourceBytes = MediaRecipeVersion(validated: 1)

    /// Internal: a literal that the type itself already validated.
    init(validated rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: MediaRecipeVersion, rhs: MediaRecipeVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "recipe:\(rawValue)" }
}

/// Identity of one immutable asset version: the digest of its bytes and the recipe that produced
/// them (ADR-001 D12).
public struct AssetVersionID: Hashable, Sendable, CustomStringConvertible {
    public let contentDigest: ContentDigest
    public let recipeVersion: MediaRecipeVersion

    public init(contentDigest: ContentDigest, recipeVersion: MediaRecipeVersion) {
        self.contentDigest = contentDigest
        self.recipeVersion = recipeVersion
    }

    public var description: String { "\(contentDigest.hex)_r\(recipeVersion.rawValue)" }
}

/// What a renderer knows about an asset it was handed: the asset identity plus the dimensions and
/// media type it must lay out.
///
/// The dimensions travel with the identity so a placeholder keeps the published layout even when
/// the decoded bytes are gone (ADR-001 D14, D15).
public struct MediaAssetIdentity: Hashable, Sendable {
    public let assetVersionID: AssetVersionID
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let mimeType: String?

    public init(
        assetVersionID: AssetVersionID,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        mimeType: String? = nil
    ) {
        self.assetVersionID = assetVersionID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mimeType = mimeType
    }

    /// The published aspect ratio, when the dimensions are known. `nil` means the layout has no
    /// ratio to preserve and the renderer must use its own slot default.
    public var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// The durable description of an asset version: identity, byte count and dimensions.
///
/// It survives eviction of the bytes (ADR-001 D14): `byteCount == 0` records "the bytes were
/// deliberately removed or are not known", never "the asset does not exist".
public struct MediaAssetDescriptor: Hashable, Sendable {
    public let identity: MediaAssetIdentity
    public let byteCount: Int

    public init(identity: MediaAssetIdentity, byteCount: Int) {
        self.identity = identity
        self.byteCount = byteCount
    }

    public var assetVersionID: AssetVersionID { identity.assetVersionID }
    public var contentDigest: ContentDigest { identity.assetVersionID.contentDigest }
    public var recipeVersion: MediaRecipeVersion { identity.assetVersionID.recipeVersion }
    public var pixelWidth: Int? { identity.pixelWidth }
    public var pixelHeight: Int? { identity.pixelHeight }
    public var mimeType: String? { identity.mimeType }
    public var aspectRatio: Double? { identity.aspectRatio }
}

// MARK: - Decoding port

/// Container metadata, read before any decode (the legacy `MediaAssetStore` protects itself the
/// same way: inspect first, then decide).
public struct ImageMetadata: Sendable, Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let mimeType: String?

    public init(pixelWidth: Int, pixelHeight: Int, mimeType: String? = nil) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mimeType = mimeType
    }
}

/// Why a payload could not be turned into pixels.
public enum ImageDecodingError: Error, Equatable, Sendable {
    /// The container header could not be read, or carries no image.
    case undecodablePayload
    /// The decoder ran, but the bitmap it produced does not satisfy the decoded-image contract.
    case invalidBitmap(String)
}

/// The decode effect, injected so a test can prove that a rejected payload was never decoded
/// (plan §14 PR-08) and so the platform framework stays behind a port.
///
/// Both methods are synchronous on purpose: they are pure CPU work, and `MediaPreparation` runs
/// them on a detached task so no caller actor — least of all the main actor — carries the cost.
public protocol ImageDecoding: Sendable {
    /// Reads the container header without decoding pixels.
    func inspect(_ bytes: Data) throws -> ImageMetadata

    /// Decodes the pixels, downsampling to `downsampleTo` when it is not `nil`.
    func decode(_ bytes: Data, downsampleTo targetWidth: Int?) throws -> DecodedImage
}

/// The production decoder: ImageIO, which is also what the legacy store uses.
///
/// It never `UIImage`/`UIKit` — the bytes come out as a platform-neutral `DecodedImage` — so the
/// type stays usable from a host test and from any future non-UI consumer.
public struct ImageIODecoder: ImageDecoding {
    public init() {}

    public func inspect(_ bytes: Data) throws -> ImageMetadata {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageDecodingError.undecodablePayload
        }
        var mimeType: String?
        if let type = CGImageSourceGetType(source) as String? {
            mimeType = UTType(type)?.preferredMIMEType
        }
        return ImageMetadata(pixelWidth: width, pixelHeight: height, mimeType: mimeType)
    }

    public func decode(_ bytes: Data, downsampleTo targetWidth: Int?) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            throw ImageDecodingError.undecodablePayload
        }
        let image: CGImage?
        if let targetWidth {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetWidth,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw ImageDecodingError.undecodablePayload }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageDecodingError.invalidBitmap("could not draw into an RGBA context") }
        return DecodedImage(
            pixelWidth: width,
            pixelHeight: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(buffer)
        )
    }
}

// MARK: - Work limiter port

/// Bounds how many downloads and decodes run at once.
///
/// `FeedRuntime`'s `ResourceGovernor` implements the same two methods, but it cannot see
/// `FeedMedia` (plan §3), so the composition root wires the governor in as the limiter. The default
/// implementation admits everything, which is what the deterministic tests want.
public protocol MediaWorkLimiter: Sendable {
    func withDownloadPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
    func withDecodePermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T
}

/// Admits every caller immediately. Used when no governor is composed.
public struct UnboundedMediaWorkLimiter: MediaWorkLimiter {
    public init() {}

    public func withDownloadPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await body()
    }

    public func withDecodePermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await body()
    }
}

// MARK: - Durable bytes port

/// Where validated asset bytes live.
///
/// The implementation owns atomicity: a caller that fails or is cancelled must leave no partially
/// written asset behind, and an asset that `publish` accepted must survive a crash (ADR-001 D11,
/// ADR-004 D10). Bytes are addressed by `AssetVersionID`, never by URL.
public protocol MediaAssetPublishing: Sendable {
    /// The bytes already published under this identity, or `nil` when they are not local.
    func localBytes(for id: AssetVersionID) async throws -> Data?

    /// Durably publishes bytes under an identity the caller already derived from them.
    ///
    /// Publishing the same identity twice is a no-op, not an error.
    func publish(_ bytes: Data, descriptor: MediaAssetDescriptor) async throws

    /// Deletes bytes and returns how many bytes that released.
    func reclaim(_ ids: [AssetVersionID]) async -> Int
}

/// The content-addressed asset store: `Assets/ab/cd/<sha256>_r<recipe>` (ADR-004 D1).
///
/// Write to a temporary file, validate, `fsync` it, move it to its immutable destination and
/// `fsync` the containing directory, so a reference created afterwards can never name bytes that
/// were not durable first.
public struct FileSystemMediaAssetStore: MediaAssetPublishing {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// The path of an asset relative to the root, sharded so one directory never holds every asset.
    public func relativePath(for id: AssetVersionID) -> String {
        let hex = id.contentDigest.hex
        let first = String(hex.prefix(2))
        let second = String(hex.dropFirst(2).prefix(2))
        return "\(first)/\(second)/\(hex)_r\(id.recipeVersion.rawValue)"
    }

    public func fileURL(for id: AssetVersionID) -> URL {
        rootDirectory.appendingPathComponent(relativePath(for: id), isDirectory: false)
    }

    public func localBytes(for id: AssetVersionID) async throws -> Data? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    public func publish(_ bytes: Data, descriptor: MediaAssetDescriptor) async throws {
        let destination = fileURL(for: descriptor.assetVersionID)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The destination is content-addressed, so a file already there is this asset. This is the
        // idempotent path that keeps a repeated preparation from writing (or downloading) twice.
        if FileManager.default.fileExists(atPath: destination.path) { return }

        let temporary = directory.appendingPathComponent(".pending-\(UUID().uuidString)")
        try bytes.write(to: temporary, options: [.atomic])
        guard Self.fsyncPath(temporary.path) else {
            try? FileManager.default.removeItem(at: temporary)
            throw MediaStorageError.durabilityFailed(temporary.path)
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // Another writer published the same identity first: the destination is the asset.
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
            return
        }
        _ = Self.fsyncPath(directory.path)
    }

    public func reclaim(_ ids: [AssetVersionID]) async -> Int {
        var released = 0
        for id in ids {
            let url = fileURL(for: id)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            released += size
        }
        return released
    }

    /// `fsync` a file or directory. A directory has no content to flush; the call makes the entries
    /// it holds — the rename that published the asset — durable.
    static func fsyncPath(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        return fsync(descriptor) == 0
    }
}

/// Failures of the durable store that the preparation pipeline reports as a publication failure.
public enum MediaStorageError: Error, Equatable, Sendable {
    case durabilityFailed(String)
}

// MARK: - Request and result

/// One preparation request: where the bytes are, what they must be, and what the renderer needs.
public struct MediaPreparationRequest: Hashable, Sendable {
    public let url: URL
    /// The digest the downloaded bytes must have. A mismatch is a typed failure, never a silent
    /// substitution of different bytes under the same card (ADR-001 D12).
    public let expectedDigest: ContentDigest
    /// Optional exact byte count, checked with the digest.
    public let expectedByteCount: Int?
    public let recipeVersion: MediaRecipeVersion
    public let role: MediaRole
    /// The width the renderer will draw at; `nil` decodes at the source resolution.
    public let targetWidth: Int?
    public let mediaTypeHint: String?
    public let deadline: Date

    public init(
        url: URL,
        expectedDigest: ContentDigest,
        expectedByteCount: Int? = nil,
        recipeVersion: MediaRecipeVersion = .sourceBytes,
        role: MediaRole = .image,
        targetWidth: Int? = nil,
        mediaTypeHint: String? = nil,
        deadline: Date
    ) {
        self.url = url
        self.expectedDigest = expectedDigest
        self.expectedByteCount = expectedByteCount
        self.recipeVersion = recipeVersion
        self.role = role
        self.targetWidth = targetWidth
        self.mediaTypeHint = mediaTypeHint
        self.deadline = deadline
    }

    public var assetVersionID: AssetVersionID {
        AssetVersionID(contentDigest: expectedDigest, recipeVersion: recipeVersion)
    }
}

/// The durable, immutable result of one preparation.
public struct PreparedMedia: Sendable, Equatable {
    public let descriptor: MediaAssetDescriptor
    public let decoded: DecodedImage
    /// The downsample target the budget accepted, `nil` when the source was already small enough.
    public let downsampleTarget: Int?
    /// `true` when this call never touched the network because the bytes were already published.
    public let servedFromLocalAsset: Bool

    public init(
        descriptor: MediaAssetDescriptor,
        decoded: DecodedImage,
        downsampleTarget: Int?,
        servedFromLocalAsset: Bool
    ) {
        self.descriptor = descriptor
        self.decoded = decoded
        self.downsampleTarget = downsampleTarget
        self.servedFromLocalAsset = servedFromLocalAsset
    }
}

/// Every way a preparation can fail, typed so a caller can tell a policy refusal from a transport
/// failure from a corruption (plan §14 PR-08).
public enum MediaPreparationError: Error, Equatable, Sendable {
    /// The role is not something this pipeline materializes (images, thumbnails, posters).
    case unsupportedMediaRole(MediaRole)
    /// The request itself is malformed (missing scheme, non-positive target width).
    case invalidRequest(String)
    case cancelled
    case deadlineExceeded
    case transport(HTTPTransportError)
    case httpStatus(Int)
    /// The payload was refused by `MediaBudget` before any decode.
    case budgetRejected(MediaRejection)
    /// The header could not be read, or the payload could not be decoded.
    case undecodablePayload
    /// The decoder produced a bitmap that violates the accepted contract (zero, oversized, or
    /// wider than the accepted downsample target).
    case decodeContractViolation(String)
    case digestMismatch(expected: ContentDigest, actual: ContentDigest)
    case byteCountMismatch(expected: Int, actual: Int)
    case publicationFailed(String)
}

// MARK: - The pipeline

/// Turns a request into a durable, immutable asset: bounded download, budget inspection, decode off
/// the calling actor, downsample, digest and size validation, publication under the digest.
///
/// Nothing here runs on the renderer path. The only caller that may reach the network is an
/// explicit `prepare` (plan §10, I-02).
public struct MediaPreparation: Sendable {
    private let transport: any HTTPTransport
    private let budget: MediaBudget
    private let decoder: any ImageDecoding
    private let store: any MediaAssetPublishing
    private let cache: DecodedImageCache
    private let clock: any EditorialClock
    private let limiter: any MediaWorkLimiter

    public init(
        transport: any HTTPTransport,
        budget: MediaBudget,
        decoder: any ImageDecoding,
        store: any MediaAssetPublishing,
        cache: DecodedImageCache,
        clock: any EditorialClock,
        limiter: any MediaWorkLimiter = UnboundedMediaWorkLimiter()
    ) {
        self.transport = transport
        self.budget = budget
        self.decoder = decoder
        self.store = store
        self.cache = cache
        self.clock = clock
        self.limiter = limiter
    }

    public func prepare(_ request: MediaPreparationRequest) async throws -> PreparedMedia {
        try Self.validate(request)
        try Self.checkCancellation()
        guard clock.now < request.deadline else { throw MediaPreparationError.deadlineExceeded }

        // Bytes already published under this identity are never re-downloaded. The destination is
        // content-addressed, so a local payload that does not match the identity it is filed under is
        // corruption: drop it and fetch instead of serving bytes that are not this asset.
        if let local = try await store.localBytes(for: request.assetVersionID) {
            if Self.matches(local, request: request) {
                let prepared = try await materialize(local, request: request, servedFromLocalAsset: true)
                await register(prepared)
                return prepared
            }
            _ = await store.reclaim([request.assetVersionID])
        }

        let bytes = try await limiter.withDownloadPermit { try await self.download(request) }
        let prepared = try await materialize(bytes, request: request, servedFromLocalAsset: false)
        try Self.validate(bytes: bytes, against: request)
        try Self.checkCancellation()
        guard clock.now < request.deadline else { throw MediaPreparationError.deadlineExceeded }
        do {
            try await store.publish(bytes, descriptor: prepared.descriptor)
        } catch let error as MediaPreparationError {
            throw error
        } catch {
            throw MediaPreparationError.publicationFailed(String(describing: error))
        }
        // Registering is deliberately unconditional: once the bytes are durable, the cache must
        // know about them, or the entry becomes an orphan that no pin can protect.
        await register(prepared)
        return prepared
    }

    // MARK: steps

    /// Bounded download: the deadline becomes the request timeout, the byte ceiling is enforced
    /// before the payload is handed on, and the transport is the injected port.
    private func download(_ request: MediaPreparationRequest) async throws -> Data {
        let remaining = request.deadline.timeIntervalSince(clock.now)
        guard remaining > 0 else { throw MediaPreparationError.deadlineExceeded }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: remaining)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(request.mediaTypeHint ?? "image/*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: urlRequest)
        } catch let error as HTTPTransportError {
            throw MediaPreparationError.transport(error)
        } catch {
            throw MediaPreparationError.transport(.transport(String(describing: error)))
        }
        try Self.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw MediaPreparationError.httpStatus(response.statusCode)
        }
        return data
    }

    private func materialize(
        _ bytes: Data,
        request: MediaPreparationRequest,
        servedFromLocalAsset: Bool
    ) async throws -> PreparedMedia {
        guard !bytes.isEmpty else { throw MediaPreparationError.budgetRejected(.empty) }
        guard bytes.count <= budget.maxCompressedBytes else {
            // Refuse before spending a decode on a payload that can never be accepted.
            throw MediaPreparationError.budgetRejected(.tooManyBytes(bytes.count))
        }

        let step = try await limiter.withDecodePermit { [self] in
            try await decodeStep(bytes, request: request)
        }

        let identity = MediaAssetIdentity(
            assetVersionID: request.assetVersionID,
            pixelWidth: step.metadata.pixelWidth,
            pixelHeight: step.metadata.pixelHeight,
            mimeType: request.mediaTypeHint ?? step.metadata.mimeType ?? "application/octet-stream"
        )
        return PreparedMedia(
            descriptor: MediaAssetDescriptor(identity: identity, byteCount: bytes.count),
            decoded: step.decoded,
            downsampleTarget: step.downsampleTo,
            servedFromLocalAsset: servedFromLocalAsset
        )
    }

    /// One decode step: header inspection, the budget gate that must refuse before a single pixel is
    /// decoded, the decode itself, and the contract on the bitmap it produced.
    private func decodeStep(
        _ bytes: Data,
        request: MediaPreparationRequest
    ) async throws -> (downsampleTo: Int?, decoded: DecodedImage, metadata: ImageMetadata) {
        let metadata = try await decodeOffCallingActor { try self.decoder.inspect(bytes) }
        let acceptance = budget.inspect(
            byteCount: bytes.count,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            targetWidth: request.targetWidth
        )
        switch acceptance {
        case .rejected(let reason):
            throw MediaPreparationError.budgetRejected(reason)
        case .accepted(let downsampleTo):
            let decoded = try await decodeOffCallingActor {
                try self.decoder.decode(bytes, downsampleTo: downsampleTo)
            }
            try Self.validate(decoded: decoded, downsampleTo: downsampleTo)
            return (downsampleTo, decoded, metadata)
        }
    }

    private func register(_ prepared: PreparedMedia) async {
        await cache.registerUnpublished(prepared.descriptor)
        await cache.storeDecoded(prepared.decoded, descriptor: prepared.descriptor)
    }

    /// Decode and inspection are CPU work, so they run on a detached task: no caller actor —
    /// least of all the main actor — carries the cost (plan §10).
    private func decodeOffCallingActor<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        do {
            return try await Task.detached(priority: .utility) { try work() }.value
        } catch let error as MediaPreparationError {
            throw error
        } catch {
            throw MediaPreparationError.undecodablePayload
        }
    }

    // MARK: validation

    private static func validate(_ request: MediaPreparationRequest) throws {
        switch request.role {
        case .image, .thumbnail, .poster:
            break
        case .audio, .video, .waveform:
            throw MediaPreparationError.unsupportedMediaRole(request.role)
        }
        guard request.url.scheme != nil else {
            throw MediaPreparationError.invalidRequest("url has no scheme: \(request.url)")
        }
        if let targetWidth = request.targetWidth, targetWidth < 1 {
            throw MediaPreparationError.invalidRequest("target width \(targetWidth) is not positive")
        }
    }

    /// The size half of "validate digest and byte count" (ADR-001 D11): the bytes must be exactly
    /// what the connector claimed.
    private static func matches(_ bytes: Data, request: MediaPreparationRequest) -> Bool {
        guard ContentDigest.sha256(bytes) == request.expectedDigest else { return false }
        if let expected = request.expectedByteCount, expected != bytes.count { return false }
        return true
    }

    private static func validate(bytes: Data, against request: MediaPreparationRequest) throws {
        let actual = ContentDigest.sha256(bytes)
        guard actual == request.expectedDigest else {
            throw MediaPreparationError.digestMismatch(expected: request.expectedDigest, actual: actual)
        }
        if let expected = request.expectedByteCount, expected != bytes.count {
            throw MediaPreparationError.byteCountMismatch(expected: expected, actual: bytes.count)
        }
    }

    private static func validate(decoded: DecodedImage, downsampleTo: Int?) throws {
        guard decoded.pixelWidth > 0, decoded.pixelHeight > 0 else {
            throw MediaPreparationError.decodeContractViolation(
                "decoded to \(decoded.pixelWidth)x\(decoded.pixelHeight)"
            )
        }
        guard decoded.pixels.count >= decoded.bytesPerRow * decoded.pixelHeight,
              decoded.bytesPerRow >= decoded.pixelWidth * 4
        else {
            throw MediaPreparationError.decodeContractViolation("bitmap geometry is inconsistent")
        }
        if let downsampleTo, decoded.pixelWidth > downsampleTo {
            throw MediaPreparationError.decodeContractViolation(
                "downsample to \(downsampleTo) produced width \(decoded.pixelWidth)"
            )
        }
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw MediaPreparationError.cancelled }
    }
}

// MARK: - SHA-256

/// SHA-256 over the exact bytes of an asset.
///
/// Implemented here because the module boundary allows `FeedMedia` only
/// `Foundation`/`FeedDomain`/`ImageIO`/`CoreGraphics`/`UniformTypeIdentifiers`, so CryptoKit and
/// CommonCrypto are out of reach — and a borrowed fingerprint is not good enough: this digest
/// *names* bytes (ADR-001 D12), while `FeedDomain`'s fingerprint only detects that two payloads
/// diverge.
enum SHA256 {
    static func digest(_ bytes: Data) -> Data {
        var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        var schedule = [UInt32](repeating: 0, count: 64)
        var tail = Data()

        bytes.withUnsafeBytes { raw in
            var offset = 0
            while raw.count - offset >= 64 {
                compress(&state, raw, at: offset, schedule: &schedule)
                offset += 64
            }
            tail.append(contentsOf: raw[offset...])
        }

        let bitLength = UInt64(bytes.count) * 8
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        tail.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                compress(&state, raw, at: offset, schedule: &schedule)
                offset += 64
            }
        }

        var digest = Data(capacity: ContentDigest.byteCount)
        for word in state {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    private static func compress(
        _ state: inout [UInt32],
        _ raw: UnsafeRawBufferPointer,
        at offset: Int,
        schedule: inout [UInt32]
    ) {
        for index in 0..<16 {
            schedule[index] = UInt32(
                bigEndian: raw.loadUnaligned(fromByteOffset: offset + index * 4, as: UInt32.self)
            )
        }
        for index in 16..<64 {
            let first = schedule[index - 15]
            let second = schedule[index - 2]
            let s0 = rotr(first, 7) ^ rotr(first, 18) ^ (first >> 3)
            let s1 = rotr(second, 17) ^ rotr(second, 19) ^ (second >> 10)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for index in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ choose &+ Self.roundConstants[index] &+ schedule[index]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
        0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
        0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
        0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
        0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}
