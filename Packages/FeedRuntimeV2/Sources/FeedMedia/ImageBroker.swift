import FeedDomain
import Foundation

/// The deterministic recipe for the stand-in a renderer draws when the bytes are not materialized.
///
/// It is derived from the asset identity and the published dimensions only, so the same card always
/// gets the same placeholder, with the same aspect ratio, in every process and on every device
/// (plan §10: "placeholder determinístico"; ADR-001 D14: layout survives the loss of bytes).
public struct PlaceholderRecipe: Hashable, Sendable {
    /// Version of the placeholder recipe, independent of the asset's own recipe (ADR-001 D9).
    public static let currentVersion = 1

    public let recipeVersion: Int
    public let aspectRatio: Double?
    /// Deterministic from the digest and recipe version; never `Hasher`, which is seeded per process.
    public let seed: UInt64

    public init(
        assetVersionID: AssetVersionID,
        aspectRatio: Double?,
        recipeVersion: Int = PlaceholderRecipe.currentVersion
    ) {
        self.recipeVersion = recipeVersion
        self.aspectRatio = aspectRatio
        self.seed = Self.seed(for: assetVersionID)
    }

    private static func seed(for id: AssetVersionID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.contentDigest.bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash ^ UInt64(bitPattern: Int64(id.recipeVersion.rawValue))
    }
}

/// What the renderer gets: local pixels, or the deterministic placeholder.
public enum MaterializedImage: Sendable, Equatable {
    case image(DecodedImage)
    case placeholder(PlaceholderRecipe)

    public var decodedImage: DecodedImage? {
        if case let .image(image) = self { return image }
        return nil
    }

    public var placeholderRecipe: PlaceholderRecipe? {
        if case let .placeholder(recipe) = self { return recipe }
        return nil
    }

    public var isPlaceholder: Bool { decodedImage == nil }
}

/// The single entry point a renderer may call for media.
///
/// It answers from local materialization only: it starts no network work, performs no blocking disk
/// I/O and waits for no download, so a card whose bytes were never fetched renders immediately as
/// its deterministic placeholder ("renderer network = 0", plan §10, I-02). Network work happens only
/// through `prepare`, which is a separate, explicit call, and it is coalesced per asset so two
/// callers that ask for the same asset cause one transport call and one decode (single-flight).
public actor ImageBroker {
    /// What makes two preparation requests the same piece of work: the asset version plus the size
    /// the caller needs. Requests that differ only in target width still share the downloaded bytes,
    /// because the durable store is content-addressed.
    public struct PreparationKey: Hashable, Sendable {
        public let assetVersionID: AssetVersionID
        public let targetWidth: Int?

        public init(assetVersionID: AssetVersionID, targetWidth: Int?) {
            self.assetVersionID = assetVersionID
            self.targetWidth = targetWidth
        }
    }

    private let preparation: MediaPreparation
    private let cache: DecodedImageCache
    private var inFlight: [PreparationKey: Task<PreparedMedia, Error>] = [:]
    private var coalescedRequests = 0

    public init(preparation: MediaPreparation, cache: DecodedImageCache) {
        self.preparation = preparation
        self.cache = cache
    }

    /// The renderer path. Zero transport calls, zero decode, zero blocking I/O: either the bitmap is
    /// already materialized locally, or the caller draws the placeholder.
    public func materializedImage(for identity: MediaAssetIdentity) async -> MaterializedImage {
        if let image = await cache.decoded(identity.assetVersionID) {
            return .image(image)
        }
        return .placeholder(
            PlaceholderRecipe(
                assetVersionID: identity.assetVersionID,
                aspectRatio: identity.aspectRatio
            )
        )
    }

    /// Prepares a published asset for presentation using only durable local bytes.
    ///
    /// This is intentionally separate from `prepare`: it has no URL and therefore cannot cross the
    /// network boundary. A warm launch calls it before exposing a card whose publication names local
    /// media, so the renderer later hits the decoded cache synchronously from its point of view.
    public func prewarmLocal(_ identity: MediaAssetIdentity) async -> MaterializedImage {
        if let image = await cache.decoded(identity.assetVersionID) {
            return .image(image)
        }
        if let image = try? await preparation.materializeLocal(identity) {
            return .image(image)
        }
        return .placeholder(
            PlaceholderRecipe(
                assetVersionID: identity.assetVersionID,
                aspectRatio: identity.aspectRatio
            )
        )
    }

    /// The only media path that may download. Concurrent requests for the same asset and size share
    /// one preparation.
    public func prepare(_ request: MediaPreparationRequest) async throws -> PreparedMedia {
        let key = PreparationKey(
            assetVersionID: request.assetVersionID,
            targetWidth: request.targetWidth
        )
        if let existing = inFlight[key] {
            coalescedRequests += 1
            return try await existing.value
        }
        let task = Task { try await preparation.prepare(request) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// How many preparations this broker is currently coalescing. Introspection for the governor and
    /// for tests; it is never consulted on the render path.
    public var inFlightPreparationCount: Int { inFlight.count }

    /// How many callers joined an in-flight preparation instead of starting one. Single-flight
    /// telemetry: it is what makes "two requests, one download" observable.
    public var coalescedRequestCount: Int { coalescedRequests }

    /// The publication boundary: the asset is now referenced by a retained publication, so its bytes
    /// move to the protected class and the publication holds the pin (ADR-001 D13, ADR-004 D8).
    ///
    /// PR-06 consumes this when a segment commits.
    public func markPublished(_ id: AssetVersionID, pinnedBy owner: MediaPinOwner) async {
        await cache.markPublished(id)
        await cache.pin(id, owner: owner)
    }
}
