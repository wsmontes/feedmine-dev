import Foundation

/// The minimal local asset commit (ADR-001 D10, D11, D12; ADR-004 D10; plan §10).
///
/// Media preparation and publication are separate phases: bytes are made durable *before* the
/// publication transaction references them, never inside it. The runtime therefore talks to bytes
/// through this port, and `FeedMedia`'s `LocalAssetStore` is its only production implementation. The
/// port deliberately carries hex and integers instead of media types, because `FeedMedia` may not
/// import `FeedRuntime` and this package's dependency direction must stay one-way.

/// One asset the caller already prepared, with the identity the media layer derived for it.
///
/// The bytes travel with the request so the store can re-derive their digest and refuse to publish
/// something other than what the composition priced: a mismatch is a typed failure, never a silent
/// substitution of different bytes under the same card (ADR-001 D12).
public struct PublishedAssetRequest: Hashable, Sendable {
    /// Connector-scoped locator identity of the candidate this asset answers for.
    public let candidateKey: String
    public let role: MediaRole
    public let bytes: Data
    /// Lowercase hex SHA-256 over the exact bytes.
    public let contentDigest: String
    public let byteCount: Int
    public let recipeVersion: Int
    public let mimeType: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        candidateKey: String,
        role: MediaRole,
        bytes: Data,
        contentDigest: String,
        recipeVersion: Int,
        mimeType: String,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) throws {
        guard !candidateKey.isEmpty else { throw PublicationPayloadError.emptyMediaCandidateKey }
        guard !bytes.isEmpty else { throw PublishedAssetCommitError.emptyBytes }
        guard ContentDigestShape.isHexDigest(contentDigest) else {
            throw PublishedAssetCommitError.invalidDigest(contentDigest)
        }
        guard recipeVersion > 0 else {
            throw PublishedAssetCommitError.invalidRecipeVersion(recipeVersion)
        }
        self.candidateKey = candidateKey
        self.role = role
        self.bytes = bytes
        self.contentDigest = contentDigest.lowercased()
        self.byteCount = bytes.count
        self.recipeVersion = recipeVersion
        self.mimeType = mimeType.isEmpty ? "application/octet-stream" : mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// The durable description of bytes that were committed before the publication transaction.
public struct PublishedAssetCommit: Hashable, Sendable {
    public let contentDigest: String
    public let byteCount: Int
    public let recipeVersion: Int
    public let mimeType: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// Where the immutable bytes live, relative to the asset root (ADR-004 D1).
    public let relativePath: String

    public init(
        contentDigest: String,
        byteCount: Int,
        recipeVersion: Int,
        mimeType: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        relativePath: String
    ) {
        self.contentDigest = contentDigest
        self.byteCount = byteCount
        self.recipeVersion = recipeVersion
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.relativePath = relativePath
    }

    /// The identity the published card freezes.
    public var mediaReference: PublishedMediaRef {
        PublishedMediaRef(
            contentDigest: contentDigest,
            recipeVersion: recipeVersion,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            mimeType: mimeType
        )
    }
}

/// Every way a local asset commit can fail, typed so a caller can tell a policy refusal from a
/// corrupt payload from a storage failure (plan §10, §14).
public enum PublishedAssetCommitError: Error, Equatable, Sendable {
    /// The bytes do not hash to the digest the composition priced.
    case digestMismatch(expected: String, actual: String)
    /// The bytes are not the length the composition priced.
    case byteCountMismatch(expected: Int, actual: Int)
    case invalidDigest(String)
    case invalidRecipeVersion(Int)
    case emptyBytes
    /// The durability step did not hold, so the asset may not be referenced.
    case durabilityFailed(String)
    case fileSystem(String)
}

/// The bytes port publication uses. It is the *only* thing publication knows about media storage.
public protocol PublishedAssetCommitting: Sendable {
    /// Makes the bytes durable and returns the description the published reference will name.
    ///
    /// A second commit of the same identity is a no-op that returns the same description, so a retry
    /// after a lost response never rewrites or duplicates bytes.
    func commit(_ request: PublishedAssetRequest) async throws -> PublishedAssetCommit
}

/// Hex-digest shape, shared by the domain and by the stores that implement the port.
public enum ContentDigestShape {
    public static let byteCount = 32

    public static func isHexDigest(_ value: String) -> Bool {
        value.count == byteCount * 2 && value.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }

    /// The canonical lowercase hex of raw digest bytes. The `FeedMedia` layer owns the hashing itself;
    /// this only renders the result, so nothing here becomes a second digest implementation.
    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

/// What one card's media will be, decided by the caller before the publication transaction.
///
/// Preparation (`MediaPreparation`, PR-08) happens outside the transaction and outside the
/// coordinator's isolated state; by the time a composition reaches the commit, each declared candidate
/// is either prepared bytes, a declared slot with no bytes (deterministic placeholder), or integral
/// media that publication does not require.
public struct PublishedCardMediaPlan: Hashable, Sendable {
    public enum Entry: Hashable, Sendable {
        case prepared(PublishedAssetRequest)
        /// A renderable slot was declared and no bytes were prepared: geometry is preserved by the
        /// deterministic placeholder (ADR-001 D14).
        case placeholder(candidateKey: String, role: MediaRole, declaredAspectRatio: Double?)
        /// Integral media (audio, video) or any other declared candidate publication does not need.
        case noMedia(candidateKey: String, role: MediaRole)
    }

    public let originRevisionID: OriginRevisionID
    public let entries: [Entry]

    public init(originRevisionID: OriginRevisionID, entries: [Entry]) {
        self.originRevisionID = originRevisionID
        self.entries = entries
    }

    /// The plan a composition uses when no media was prepared at all.
    public static func unprepared(_ content: PublicationCardContent) -> PublishedCardMediaPlan {
        PublishedCardMediaPlan(
            originRevisionID: content.originRevisionID,
            entries: content.mediaCandidates.map { candidate in
                if PublishedMediaPlacement.isRenderable(candidate.role) {
                    return .placeholder(
                        candidateKey: candidate.candidateKey,
                        role: candidate.role,
                        declaredAspectRatio: candidate.declaredAspectRatio
                    )
                }
                return .noMedia(candidateKey: candidate.candidateKey, role: candidate.role)
            }
        )
    }
}

/// Which slot a declared media role occupies, if any (plan §10).
///
/// The mapping is explicit and closed. Integral audio/video is deliberately *not* renderable: a full
/// playback download is never a publication prerequisite (ADR-001 D10), so a card whose revision only
/// declares playback media publishes text plus its own geometry and needs no network.
public enum PublishedMediaPlacement {
    public static func isRenderable(_ role: MediaRole) -> Bool {
        assetSlot(for: role) != nil
    }

    public static func assetSlot(for role: MediaRole) -> PublishedAssetSlot? {
        switch role {
        case .image: return .primary
        case .poster: return .poster
        case .thumbnail: return .thumbnail
        case .waveform: return .alternate
        case .audio, .video: return nil
        }
    }

    public static func renderSlot(for role: MediaRole) -> MediaSlot? {
        switch role {
        case .image: return .primary
        case .poster: return .poster
        case .thumbnail: return .thumbnail
        case .waveform: return .waveform
        case .audio, .video: return nil
        }
    }
}
