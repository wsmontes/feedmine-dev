import FeedDomain
import Foundation

/// A decoded bitmap in a platform-neutral form: RGBA8, row-major, premultiplied, top-left origin.
///
/// Keeping the pixels as `Data` is what lets `FeedMedia` hand a materialized image to the renderer
/// without pulling `UIKit` (or any platform image type) into the module, and lets a test prove the
/// decode contract without a real image framework.
public struct DecodedImage: Sendable, Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let bytesPerRow: Int
    public let pixels: Data

    public init(pixelWidth: Int, pixelHeight: Int, bytesPerRow: Int, pixels: Data) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    /// What this representation costs in memory.
    public var byteCount: Int { pixels.count }
}

/// Which retention class an entry belongs to (plan §10).
///
/// The classes are monotonic: a decoded-only entry becomes an unpublished download when its bytes
/// are published, and a published asset when a retained publication references it. Eviction order
/// is cheapest-to-recover first, and only pins protect an entry from every path.
public enum MediaCacheClass: String, Hashable, Sendable, CaseIterable {
    /// A decoded bitmap with no durable bytes of its own. Freely evictable.
    case decoded
    /// Downloaded bytes no retained publication references yet. Evictable under quota.
    case downloaded
    /// Bytes referenced by a retained publication or an offline bookmark. Protected by pins.
    case published

    fileprivate var rank: Int {
        switch self {
        case .decoded: return 0
        case .downloaded: return 1
        case .published: return 2
        }
    }
}

/// Which durable fact holds an asset pin. A pin is the only thing that protects bytes from
/// collection (ADR-004 D8, ADR-001 D13); the vocabulary matches `asset_pin.owner_kind`.
public enum MediaPinKind: String, Hashable, Sendable, Codable, CaseIterable {
    case edition
    case draft
    case bookmark
    case decodeSession
    case diagnostic
}

/// One holder of one asset: `(kind, ownerID)`.
public struct MediaPinOwner: Hashable, Sendable, CustomStringConvertible {
    public let kind: MediaPinKind
    public let ownerID: String

    public init(kind: MediaPinKind, ownerID: String) {
        self.kind = kind
        self.ownerID = ownerID
    }

    public var description: String { "\(kind.rawValue):\(ownerID)" }
}

/// The retention knobs. There is deliberately no default: ADR-004 leaves the numeric budgets to
/// measurement (its `OPEN` items), so the composition must state them.
public struct MediaCacheLimits: Sendable, Equatable {
    /// Memory budget for decoded bitmaps.
    public let decodedBytes: Int
    /// Quota for downloaded bytes that no retained publication references.
    public let unpublishedBytes: Int
    /// Age after which an unpinned entry is no longer retained. `nil` keeps entries until a size
    /// limit evicts them.
    public let unpublishedMaxAge: TimeInterval?

    public init(decodedBytes: Int, unpublishedBytes: Int, unpublishedMaxAge: TimeInterval? = nil) {
        self.decodedBytes = decodedBytes
        self.unpublishedBytes = unpublishedBytes
        self.unpublishedMaxAge = unpublishedMaxAge
    }
}

/// What one trim or collection call changed.
public struct MediaEvictionReport: Sendable, Equatable {
    public let freedBytes: Int
    /// Entries the call emptied or removed, least-recently-used first.
    public let evicted: [AssetVersionID]
    /// Entries the call would have taken but for an active pin. Never a subset of `evicted`.
    public let protectedByPin: [AssetVersionID]

    public init(freedBytes: Int, evicted: [AssetVersionID], protectedByPin: [AssetVersionID]) {
        self.freedBytes = freedBytes
        self.evicted = evicted
        self.protectedByPin = protectedByPin
    }

    public static let none = MediaEvictionReport(freedBytes: 0, evicted: [], protectedByPin: [])
}

/// How much each class currently holds.
public struct MediaCacheBreakdown: Sendable, Equatable {
    public let decodedBitmapBytes: Int
    public let unpublishedBytes: Int
    public let publishedBytes: Int
    public let entryCount: Int

    public init(decodedBitmapBytes: Int, unpublishedBytes: Int, publishedBytes: Int, entryCount: Int) {
        self.decodedBitmapBytes = decodedBitmapBytes
        self.unpublishedBytes = unpublishedBytes
        self.publishedBytes = publishedBytes
        self.entryCount = entryCount
    }
}

/// The materialization cache with the three eviction classes of plan §10.
///
/// - decoded bitmaps are freely evictable (losing one changes no published identity, INV-10);
/// - downloaded bytes that no publication references are evictable under quota, least recently
///   used first;
/// - an entry with an active pin is never collected by any path, and the pinned state is exposed so
///   GC can respect it (ADR-004 D8).
///
/// Eviction order comes from an internal access sequence, so it is deterministic and needs no wall
/// clock; the injected clock only stamps entries so age-based retention can compare them.
public actor DecodedImageCache {
    /// Reclaims durable bytes. `FileSystemMediaAssetStore.reclaim` is the production implementation;
    /// without one the cache accounts the bytes it released but has no store to delete from.
    public typealias Reclaimer = @Sendable ([AssetVersionID]) async -> Int

    private struct Entry {
        var descriptor: MediaAssetDescriptor
        var evictionClass: MediaCacheClass
        var decoded: DecodedImage?
        var pins: Set<MediaPinOwner>
        var storedAt: Date
        var order: UInt64
    }

    private let limits: MediaCacheLimits
    private let clock: any EditorialClock
    private let reclaim: Reclaimer?
    private var entries: [AssetVersionID: Entry] = [:]
    private var nextOrder: UInt64 = 0

    public init(limits: MediaCacheLimits, clock: any EditorialClock, reclaim: Reclaimer? = nil) {
        self.limits = limits
        self.clock = clock
        self.reclaim = reclaim
    }

    // MARK: storing

    /// Records a decoded bitmap. A new entry starts in the freely evictable class; an existing
    /// entry keeps the class its bytes have already earned.
    @discardableResult
    public func storeDecoded(_ image: DecodedImage, descriptor: MediaAssetDescriptor) -> Int {
        let id = descriptor.assetVersionID
        var entry = entries[id] ?? Entry(
            descriptor: descriptor,
            evictionClass: .decoded,
            decoded: nil,
            pins: [],
            storedAt: clock.now,
            order: nextOrder
        )
        nextOrder += 1
        entry.descriptor = descriptor
        entry.decoded = image
        entry.order = nextOrder
        entries[id] = entry
        return image.byteCount
    }

    /// Registers bytes that were downloaded but that no retained publication references yet.
    @discardableResult
    public func registerUnpublished(_ descriptor: MediaAssetDescriptor) -> Int {
        let id = descriptor.assetVersionID
        var entry = entries[id] ?? Entry(
            descriptor: descriptor,
            evictionClass: .downloaded,
            decoded: nil,
            pins: [],
            storedAt: clock.now,
            order: nextOrder
        )
        nextOrder += 1
        entry.descriptor = descriptor
        entry.evictionClass = Self.promote(entry.evictionClass, to: .downloaded)
        entry.order = nextOrder
        entries[id] = entry
        return descriptor.byteCount
    }

    /// Marks the asset as referenced by a retained publication. From here on it is only collectable
    /// once every pin is released.
    @discardableResult
    public func markPublished(_ id: AssetVersionID) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.evictionClass = Self.promote(entry.evictionClass, to: .published)
        entries[id] = entry
        return true
    }

    // MARK: pins

    /// Pins an asset for a durable owner (publication, draft, offline bookmark, decode session).
    ///
    /// Pinning an unregistered asset is refused: a pin must protect bytes that exist, and it must
    /// never resurrect an identity.
    @discardableResult
    public func pin(_ id: AssetVersionID, owner: MediaPinOwner) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.pins.insert(owner)
        entries[id] = entry
        return true
    }

    @discardableResult
    public func unpin(_ id: AssetVersionID, owner: MediaPinOwner) -> Bool {
        guard var entry = entries[id] else { return false }
        entry.pins.remove(owner)
        entries[id] = entry
        return true
    }

    public func isPinned(_ id: AssetVersionID) -> Bool {
        guard let entry = entries[id] else { return false }
        return !entry.pins.isEmpty
    }

    public func pinnedOwners(_ id: AssetVersionID) -> Set<MediaPinOwner> {
        entries[id]?.pins ?? []
    }

    // MARK: reading

    public func decoded(_ id: AssetVersionID) -> DecodedImage? {
        guard var entry = entries[id] else { return nil }
        nextOrder += 1
        entry.order = nextOrder
        entries[id] = entry
        return entry.decoded
    }

    public func descriptor(_ id: AssetVersionID) -> MediaAssetDescriptor? {
        entries[id]?.descriptor
    }

    public func evictionClass(_ id: AssetVersionID) -> MediaCacheClass? {
        entries[id]?.evictionClass
    }

    /// Registered identities, ordered by identity for stable output.
    public func registeredIDs() -> [AssetVersionID] {
        entries.keys.sorted { $0.description < $1.description }
    }

    public func breakdown() -> MediaCacheBreakdown {
        var decodedBytes = 0
        var unpublished = 0
        var published = 0
        for entry in entries.values {
            decodedBytes += entry.decoded?.byteCount ?? 0
            switch entry.evictionClass {
            case .decoded: break
            case .downloaded: unpublished += entry.descriptor.byteCount
            case .published: published += entry.descriptor.byteCount
            }
        }
        return MediaCacheBreakdown(
            decodedBitmapBytes: decodedBytes,
            unpublishedBytes: unpublished,
            publishedBytes: published,
            entryCount: entries.count
        )
    }

    // MARK: eviction

    /// The memory-warning path: every decoded bitmap goes, whatever class its bytes are in, because
    /// a bitmap is re-derivable and its loss changes no published identity (INV-10). Pinned entries
    /// are left alone.
    @discardableResult
    public func discardDecodedCache() -> MediaEvictionReport {
        var freed = 0
        var evicted: [AssetVersionID] = []
        var protected: [AssetVersionID] = []
        for id in orderedIDs() {
            guard var entry = entries[id], let image = entry.decoded else { continue }
            guard entry.pins.isEmpty else {
                protected.append(id)
                continue
            }
            freed += image.byteCount
            entry.decoded = nil
            // An entry that was nothing but a bitmap has nothing left to describe; one that also
            // holds durable bytes keeps its identity and dimensions (ADR-001 D14).
            if entry.evictionClass == .decoded {
                entries[id] = nil
            } else {
                entries[id] = entry
            }
            evicted.append(id)
        }
        return MediaEvictionReport(freedBytes: freed, evicted: evicted, protectedByPin: protected)
    }

    /// Evicts unpublished downloads, least recently used first, until the quota is met. Published
    /// bytes and pinned entries are never touched.
    @discardableResult
    public func trimUnpublishedDownloads() async -> MediaEvictionReport {
        var held = unpublishedBytes()
        var freed = 0
        var evicted: [AssetVersionID] = []
        var protected: [AssetVersionID] = []
        for id in orderedIDs() {
            guard held > limits.unpublishedBytes else { break }
            guard let entry = entries[id], entry.evictionClass == .downloaded else { continue }
            guard entry.pins.isEmpty else {
                protected.append(id)
                continue
            }
            held -= entry.descriptor.byteCount
            freed += await release([id])
            evicted.append(id)
        }
        return MediaEvictionReport(freedBytes: freed, evicted: evicted, protectedByPin: protected)
    }

    /// The quota path: decoded bitmaps are trimmed to the memory budget and unpublished downloads to
    /// their quota, both least recently used first.
    @discardableResult
    public func trimToLimits() async -> MediaEvictionReport {
        var freed = 0
        var evicted: [AssetVersionID] = []
        var protected: [AssetVersionID] = []
        var decodedBytes = decodedBitmapBytes()
        for id in orderedIDs() where decodedBytes > limits.decodedBytes {
            guard var entry = entries[id], let image = entry.decoded else { continue }
            guard entry.pins.isEmpty else {
                protected.append(id)
                continue
            }
            decodedBytes -= image.byteCount
            freed += image.byteCount
            entry.decoded = nil
            if entry.evictionClass == .decoded {
                entries[id] = nil
            } else {
                entries[id] = entry
            }
            evicted.append(id)
        }
        let downloads = await trimUnpublishedDownloads()
        return Self.merged([MediaEvictionReport(freedBytes: freed, evicted: evicted, protectedByPin: protected), downloads])
    }

    /// Age-based retention, run before any collection. `asOf` is explicit so a test states the
    /// passage of time instead of sleeping through it.
    @discardableResult
    public func evictExpired(asOf now: Date) async -> MediaEvictionReport {
        guard let maxAge = limits.unpublishedMaxAge else { return .none }
        var expired: [AssetVersionID] = []
        var protected: [AssetVersionID] = []
        for id in orderedIDs() {
            guard let entry = entries[id] else { continue }
            guard entry.pins.isEmpty else {
                protected.append(id)
                continue
            }
            if now.timeIntervalSince(entry.storedAt) > maxAge {
                expired.append(id)
            }
        }
        let freed = await release(expired)
        return MediaEvictionReport(freedBytes: freed, evicted: expired, protectedByPin: protected)
    }

    /// GC. Collects every unpinned entry — including published bytes whose references were released
    /// — and never touches a pinned one.
    @discardableResult
    public func collectUnpinnedEntries() async -> MediaEvictionReport {
        var collectable: [AssetVersionID] = []
        var protected: [AssetVersionID] = []
        for id in orderedIDs() {
            guard let entry = entries[id] else { continue }
            if entry.pins.isEmpty {
                collectable.append(id)
            } else {
                protected.append(id)
            }
        }
        let freed = await release(collectable)
        return MediaEvictionReport(freedBytes: freed, evicted: collectable, protectedByPin: protected)
    }

    // MARK: internals

    private func orderedIDs() -> [AssetVersionID] {
        entries
            .sorted { left, right in left.value.order < right.value.order }
            .map(\.key)
    }

    private func decodedBitmapBytes() -> Int {
        entries.values.reduce(0) { $0 + ($1.decoded?.byteCount ?? 0) }
    }

    private func unpublishedBytes() -> Int {
        entries.values.reduce(0) { total, entry in
            entry.evictionClass == .downloaded ? total + entry.descriptor.byteCount : total
        }
    }

    private func release(_ ids: [AssetVersionID]) async -> Int {
        var accounted = 0
        for id in ids {
            accounted += entries[id]?.descriptor.byteCount ?? 0
            entries[id] = nil
        }
        guard let reclaim else { return accounted }
        return await reclaim(ids)
    }

    private static func promote(_ current: MediaCacheClass, to target: MediaCacheClass) -> MediaCacheClass {
        current.rank >= target.rank ? current : target
    }

    /// One report out of several, without repeating an entry a path already reported.
    private static func merged(_ reports: [MediaEvictionReport]) -> MediaEvictionReport {
        var freed = 0
        var evicted: [AssetVersionID] = []
        var protected: [AssetVersionID] = []
        for report in reports {
            freed += report.freedBytes
            for id in report.evicted where !evicted.contains(id) { evicted.append(id) }
            for id in report.protectedByPin where !protected.contains(id) { protected.append(id) }
        }
        return MediaEvictionReport(freedBytes: freed, evicted: evicted, protectedByPin: protected)
    }
}
