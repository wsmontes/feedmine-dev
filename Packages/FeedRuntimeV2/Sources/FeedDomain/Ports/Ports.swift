import Foundation

/// External effects the runtime does not own. These are the only abstractions in the domain that
/// exist to be replaced (plan §3): persistence uses concrete `FeedStorage` repositories, not a
/// protocol per repository.

/// Injectable time. Editorial decisions that must be reproducible take the clock as an input
/// rather than reading `Date()` (plan §8).
public protocol EditorialClock: Sendable {
    var now: Date { get }
}

/// The system clock, monotonic enough for scheduling and editorial buckets.
public struct SystemEditorialClock: EditorialClock {
    public init() {}
    public var now: Date { Date() }
}

/// Outbound HTTP, injected so editorial and rendering paths can be proven free of network
/// (plan §3, I-02).
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Equatable, Sendable {
    case notHTTP
    case status(Int)
    case transport(String)
}

/// A connector: an external effect that turns a target into canonical observations.
///
/// Implementations live in `FeedConnectorSyndication` (or a fake under test); nothing downstream
/// may know which wire format produced the batch (plan §7, I-03).
public protocol FeedConnector: Sendable {
    /// Identifier of the target this connector serves. Used for stamps, not for identity.
    var targetID: AcquisitionTargetID { get }

    /// Runs one bounded acquisition for the target and returns a batch for Admission, or throws
    /// for transport-level failure. Blocking work happens on the caller's executor; the connector
    /// must not perform database writes.
    func acquire(limit: AcquisitionLimit) async throws -> AcquisitionBatch
}

/// Hard bounds for one acquisition run. Budgets are policy, not best effort (plan §20.3, I-19).
public struct AcquisitionLimit: Hashable, Sendable {
    public let maxItems: Int
    public let maxBytes: Int
    public let deadline: Date

    public init(maxItems: Int, maxBytes: Int, deadline: Date) {
        self.maxItems = maxItems
        self.maxBytes = maxBytes
        self.deadline = deadline
    }
}

// MARK: - Retention

/// The identity of one media asset version in the spelling the *database* uses.
///
/// `asset_version` stores `(content_digest TEXT, recipe_version INTEGER)`, and `FeedMedia` spells the
/// same identity `(ContentDigest, MediaRecipeVersion)`. The retention port speaks the database's
/// spelling because the coordinator that decides what may be collected lives in `FeedStorage` and
/// may not see `FeedMedia` (plan §3): the translation happens in the media-side implementation,
/// exactly once, where both spellings are visible.
public struct MediaAssetKey: Hashable, Sendable, CustomStringConvertible {
    /// Lowercase hex of the SHA-256 digest of the exact bytes.
    public let contentDigestHex: String
    /// The transformation recipe that produced those bytes.
    public let recipeVersion: Int

    public init(contentDigestHex: String, recipeVersion: Int) {
        self.contentDigestHex = contentDigestHex
        self.recipeVersion = recipeVersion
    }

    public var description: String { "\(contentDigestHex)_r\(recipeVersion)" }
}

/// What one collection call released. Counts and bytes only, never content: a retention run is
/// reported in the same terms whatever it collected (plan §16).
public struct MediaCollectionOutcome: Hashable, Sendable {
    /// Entries or files the call removed.
    public let collected: Int
    /// Objects the call would have taken but for an active pin. Never a subset of `collected`.
    public let protectedByPin: Int
    /// Bytes released, as the implementation's own bookkeeping reports them.
    public let freedBytes: Int
    /// Files that turned out to be temporary leftovers of an interrupted commit, when the call is
    /// the one that looks for them.
    public let orphansCollected: Int

    public init(collected: Int, protectedByPin: Int, freedBytes: Int, orphansCollected: Int = 0) {
        self.collected = collected
        self.protectedByPin = protectedByPin
        self.freedBytes = freedBytes
        self.orphansCollected = orphansCollected
    }

    public static let none = MediaCollectionOutcome(collected: 0, protectedByPin: 0, freedBytes: 0)

    public static func + (lhs: Self, rhs: Self) -> Self {
        MediaCollectionOutcome(
            collected: lhs.collected + rhs.collected,
            protectedByPin: lhs.protectedByPin + rhs.protectedByPin,
            freedBytes: lhs.freedBytes + rhs.freedBytes,
            orphansCollected: lhs.orphansCollected + rhs.orphansCollected
        )
    }
}

/// The media half of retention (plan §10, ADR-004 D8).
///
/// `FeedStorage`'s `RetentionCoordinator` decides *across* classes what may be collected and in what
/// order; the two collectors that already know how to touch media stay where they are
/// (`DecodedImageCache.collectUnpinnedEntries()`, `LocalAssetStore.collectOrphanTemporaryFiles()`)
/// and are reached through this port. A run without a port reports the media classes as skipped
/// rather than pretending it collected them.
public protocol RetentionMediaCollecting: Sendable {
    /// The decoded-cache path: every entry no durable fact pins, through the cache's own quotas.
    func collectUnpinnedMedia() async -> MediaCollectionOutcome

    /// The bytes path: the named asset versions whose references are gone. Identity survives; only
    /// the files are removed (ADR-001 D14, ADR-004 D10).
    func collectAssetBytes(_ keys: [MediaAssetKey]) async -> MediaCollectionOutcome

    /// Temporary files an interrupted commit left behind, which no card can ever reference.
    func collectOrphanAssetFiles() async -> MediaCollectionOutcome
}
