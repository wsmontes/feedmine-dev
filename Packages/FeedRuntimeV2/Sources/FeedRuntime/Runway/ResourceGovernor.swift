import FeedDomain
import Foundation

/// The resource knobs the runtime runs under.
///
/// There is deliberately no `.standard`: the numeric budgets are ADR-004 `OPEN` items that close by
/// measurement, so the composition states them instead of inheriting invented defaults. What the
/// governor guarantees is the *shape* — bounded concurrency, a disk ceiling, and a lower floor that
/// pressure drops to.
public struct ResourceLimits: Sendable, Equatable {
    /// How many downloads may run at once.
    public let downloadConcurrency: Int
    /// How many decodes may run at once.
    public let decodeConcurrency: Int
    /// The download concurrency a memory warning drops to.
    public let pressureDownloadConcurrency: Int
    /// The decode concurrency a memory warning drops to.
    public let pressureDecodeConcurrency: Int
    /// How many bytes of media the runtime may keep on disk.
    public let diskBudgetBytes: Int

    public init(
        downloadConcurrency: Int,
        decodeConcurrency: Int,
        pressureDownloadConcurrency: Int,
        pressureDecodeConcurrency: Int,
        diskBudgetBytes: Int
    ) {
        self.downloadConcurrency = downloadConcurrency
        self.decodeConcurrency = decodeConcurrency
        self.pressureDownloadConcurrency = pressureDownloadConcurrency
        self.pressureDecodeConcurrency = pressureDecodeConcurrency
        self.diskBudgetBytes = diskBudgetBytes
    }
}

/// The media caches the governor is allowed to shrink.
///
/// `FeedRuntime` cannot see `FeedMedia` (plan §3), so these are closures the composition root wires
/// to `DecodedImageCache` — `discardDecodedMaterial` to `discardDecodedCache`,
/// `trimUnpublishedDownloads` to `trimUnpublishedDownloads`, `runRetentionCollection` to
/// `evictExpired(asOf:)` followed by `collectUnpinnedEntries`. Each returns the bytes it released.
///
/// None of them may ever release a pinned entry: the cache enforces that, and these handlers only
/// ask for the classes it may take.
public struct MediaCachePressureHandlers: Sendable {
    /// Drops decoded bitmaps. Freely evictable; losing one changes no published identity.
    public let discardDecodedMaterial: @Sendable () async -> Int
    /// Evicts downloaded bytes that no retained publication references, under quota, LRU first.
    public let trimUnpublishedDownloads: @Sendable () async -> Int
    /// Runs retention (age) and collects unpinned entries. Never a pinned one.
    public let runRetentionCollection: @Sendable (Date) async -> Int

    public init(
        discardDecodedMaterial: @escaping @Sendable () async -> Int,
        trimUnpublishedDownloads: @escaping @Sendable () async -> Int,
        runRetentionCollection: @escaping @Sendable (Date) async -> Int
    ) {
        self.discardDecodedMaterial = discardDecodedMaterial
        self.trimUnpublishedDownloads = trimUnpublishedDownloads
        self.runRetentionCollection = runRetentionCollection
    }

    /// A handler set that frees nothing. For a runtime with no media cache composed.
    public static let none = MediaCachePressureHandlers(
        discardDecodedMaterial: { 0 },
        trimUnpublishedDownloads: { 0 },
        runRetentionCollection: { _ in 0 }
    )
}

/// Which kind of pressure was applied. They are not the same event: memory pressure discards
/// re-derivable material and stops speculative work, disk pressure reclaims durable bytes.
public enum ResourcePressure: Sendable, Equatable {
    case memory
    case disk
}

/// What one pressure application did.
public struct ResourcePressureOutcome: Sendable, Equatable {
    public let pressure: ResourcePressure
    public let discardedDecodedBytes: Int
    public let trimmedUnpublishedBytes: Int
    public let collectedBytes: Int
    public let cancelledSpeculativeWork: Int
    /// The concurrency in force after the call.
    public let downloadConcurrency: Int
    public let decodeConcurrency: Int

    public init(
        pressure: ResourcePressure,
        discardedDecodedBytes: Int,
        trimmedUnpublishedBytes: Int,
        collectedBytes: Int,
        cancelledSpeculativeWork: Int,
        downloadConcurrency: Int,
        decodeConcurrency: Int
    ) {
        self.pressure = pressure
        self.discardedDecodedBytes = discardedDecodedBytes
        self.trimmedUnpublishedBytes = trimmedUnpublishedBytes
        self.collectedBytes = collectedBytes
        self.cancelledSpeculativeWork = cancelledSpeculativeWork
        self.downloadConcurrency = downloadConcurrency
        self.decodeConcurrency = decodeConcurrency
    }

    public var freedBytes: Int {
        discardedDecodedBytes + trimmedUnpublishedBytes + collectedBytes
    }
}

/// Handle of one speculative piece of media work.
public struct SpeculativeWorkID: Hashable, Sendable {
    public let rawValue: UInt64
}

/// Bounds concurrent media work and responds to pressure.
///
/// The app calls `applyMemoryPressure` from the memory-warning path and `enforceDiskBudget` from
/// maintenance; Runway schedules prefetch through `startSpeculative`, so a memory warning can stop
/// work that nothing visible needs (plan §14 PR-08). Its download and decode permits have the same
/// shape as `FeedMedia.MediaWorkLimiter`, which is how the composition root wires this governor in
/// as the media limiter.
public actor ResourceGovernor {
    private struct PermitGate {
        var limit: Int
        var inUse = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let limits: ResourceLimits
    private let clock: any EditorialClock
    private let mediaCache: MediaCachePressureHandlers
    private var downloadGate: PermitGate
    private var decodeGate: PermitGate
    private var underPressure = false
    private var speculative: [SpeculativeWorkID: Task<Void, Never>] = [:]
    private var nextSpeculativeID: UInt64 = 0

    public init(
        limits: ResourceLimits,
        clock: any EditorialClock,
        mediaCache: MediaCachePressureHandlers = .none
    ) {
        self.limits = limits
        self.clock = clock
        self.mediaCache = mediaCache
        // A bound below one would strand every caller forever, so the effective bound is never zero.
        self.downloadGate = PermitGate(limit: max(1, limits.downloadConcurrency))
        self.decodeGate = PermitGate(limit: max(1, limits.decodeConcurrency))
    }

    // MARK: state

    /// The download concurrency currently in force.
    public var downloadConcurrency: Int { downloadGate.limit }
    /// The decode concurrency currently in force.
    public var decodeConcurrency: Int { decodeGate.limit }
    public var isUnderPressure: Bool { underPressure }
    public var speculativeWorkCount: Int { speculative.count }
    public var downloadsInFlight: Int { downloadGate.inUse }
    public var decodesInFlight: Int { decodeGate.inUse }

    // MARK: bounded concurrency

    /// Runs one download under the download permit. Fewer than `downloadConcurrency` run at once,
    /// and a memory warning lowers that bound for everything dispatched afterwards.
    public func withDownloadPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquireDownload()
        do {
            let value = try await body()
            releaseDownload()
            return value
        } catch {
            releaseDownload()
            throw error
        }
    }

    /// Runs one decode under the decode permit, bounded the same way.
    public func withDecodePermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquireDecode()
        do {
            let value = try await body()
            releaseDecode()
            return value
        } catch {
            releaseDecode()
            throw error
        }
    }

    // MARK: pressure

    /// A memory warning: discard everything re-derivable, shrink the queues, and cancel speculative
    /// work that nothing visible is waiting for.
    ///
    /// It never collects published bytes: only unpinned entries can be collected at all, and the
    /// publication's own pins are what keep them.
    public func applyMemoryPressure() async -> ResourcePressureOutcome {
        underPressure = true
        downloadGate.limit = max(1, min(downloadGate.limit, limits.pressureDownloadConcurrency))
        decodeGate.limit = max(1, min(decodeGate.limit, limits.pressureDecodeConcurrency))

        let discarded = await mediaCache.discardDecodedMaterial()
        let trimmed = await mediaCache.trimUnpublishedDownloads()
        let cancelled = await cancelSpeculativeWork()

        return ResourcePressureOutcome(
            pressure: .memory,
            discardedDecodedBytes: discarded,
            trimmedUnpublishedBytes: trimmed,
            collectedBytes: 0,
            cancelledSpeculativeWork: cancelled,
            downloadConcurrency: downloadGate.limit,
            decodeConcurrency: decodeGate.limit
        )
    }

    /// The warning is over: speculative work may be scheduled again and the configured bounds apply.
    public func endMemoryPressure() {
        underPressure = false
        downloadGate.limit = max(1, limits.downloadConcurrency)
        decodeGate.limit = max(1, limits.decodeConcurrency)
        pump(&downloadGate)
        pump(&decodeGate)
    }

    /// Maintains the disk ceiling: retention and collection of unpinned entries run *before* any
    /// collection, and stop as soon as they stop releasing bytes — never looping against a full disk.
    public func enforceDiskBudget(usedBytes: Int) async -> ResourcePressureOutcome {
        var remaining = usedBytes
        var collected = 0
        var trimmed = 0
        while remaining > limits.diskBudgetBytes {
            let retained = await mediaCache.runRetentionCollection(clock.now)
            let downloads = await mediaCache.trimUnpublishedDownloads()
            guard retained + downloads > 0 else { break }
            collected += retained
            trimmed += downloads
            remaining -= retained + downloads
        }
        return ResourcePressureOutcome(
            pressure: .disk,
            discardedDecodedBytes: 0,
            trimmedUnpublishedBytes: trimmed,
            collectedBytes: collected,
            cancelledSpeculativeWork: 0,
            downloadConcurrency: downloadGate.limit,
            decodeConcurrency: decodeGate.limit
        )
    }

    // MARK: speculative work

    /// Starts work that no visible card is waiting for, so pressure can cancel it.
    ///
    /// `body` must honour cancellation: `cancelSpeculativeWork` waits for the tasks it cancelled.
    public func startSpeculative(_ body: @escaping @Sendable () async -> Void) -> SpeculativeWorkID {
        nextSpeculativeID += 1
        let id = SpeculativeWorkID(rawValue: nextSpeculativeID)
        let task = Task.detached(priority: .utility) { [weak self] in
            await body()
            await self?.finishedSpeculative(id)
        }
        speculative[id] = task
        return id
    }

    /// Cancels every speculative task and waits for them to stop. Returns how many were cancelled.
    public func cancelSpeculativeWork() async -> Int {
        let tasks = speculative
        speculative.removeAll()
        guard !tasks.isEmpty else { return 0 }
        for task in tasks.values { task.cancel() }
        for task in tasks.values { await task.value }
        return tasks.count
    }

    // MARK: internals

    private func finishedSpeculative(_ id: SpeculativeWorkID) {
        speculative[id] = nil
    }

    private func acquireDownload() async {
        if downloadGate.inUse < downloadGate.limit {
            downloadGate.inUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            downloadGate.waiters.append(continuation)
        }
    }

    private func releaseDownload() {
        downloadGate.inUse -= 1
        pump(&downloadGate)
    }

    private func acquireDecode() async {
        if decodeGate.inUse < decodeGate.limit {
            decodeGate.inUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            decodeGate.waiters.append(continuation)
        }
    }

    private func releaseDecode() {
        decodeGate.inUse -= 1
        pump(&decodeGate)
    }

    /// Hands permits to queued callers, never dispatching past the current limit: a lowered limit
    /// takes effect for everything that has not started yet.
    private func pump(_ gate: inout PermitGate) {
        while gate.inUse < gate.limit, !gate.waiters.isEmpty {
            gate.inUse += 1
            let waiter = gate.waiters.removeFirst()
            waiter.resume()
        }
    }
}
