import CryptoKit
import Darwin
import Foundation
import GRDB
import FeedDomain
import FeedStorage

// MARK: - Level 2: the parsed entry, before the legacy mapping erased its identity

/// One parsed entry exactly as `RSSFetcher` sees it between the parse and the mapping to `FeedItem`
/// (`docs/runtime-v2/rollout.md` §4.1).
///
/// This is the only point where the original GUID/Atom id still exists: `FeedItem` keeps a SHA-256
/// (`Models/FeedItem.swift:394-402`) and never the raw key, so an identity re-derived later would be
/// a guess. A URL-shaped GUID travels here verbatim — nothing normalizes it (ADR-003 D10).
struct ShadowParsedEntry: Equatable, Sendable {
    /// The legacy alias this entry became, so both mirror levels refer to one item.
    let legacyItemID: String
    let sourceURL: String
    let guid: String?
    let link: String?
    /// The headline the legacy mapper kept (already sanitized and truncated), so the comparison is
    /// between equal things rather than between a raw title and a projected one.
    let title: String?
    let publishedAt: Date?
    /// The Atom `updated` instant, used as the representation's version key.
    let updatedAt: Date?
    let excerpt: String?
    let audioURL: String?
}

// MARK: - Level 1: the FeedItem, its source and the outcome

/// Every outcome the shadow covers. Mirroring only `actualNew` loses updates, duplicates, 304s and
/// empty results that carry meaning (plan §13).
enum ShadowOutcomeKind: String, CaseIterable, Sendable {
    case newItems
    case withoutNewItems
    case notModified
    case throttled
    case failed

    /// `nil` when there is nothing to mirror.
    ///
    /// A fetch the mode's gate refused never reached the network, so the legacy path produced no
    /// outcome at all: giving it a mirror kind would put an observation in the shadow's coverage
    /// numbers for a source nobody asked.
    init?(_ outcome: FeedFetchOutcome) {
        switch outcome {
        case .modifiedWithNewItems: self = .newItems
        case .modifiedWithoutNewItems: self = .withoutNewItems
        case .notModified: self = .notModified
        case .throttled: self = .throttled
        case .failed: self = .failed
        case .legacyProducerClosed: return nil
        }
    }
}

/// What the legacy path produced for one source in one fetch: the items, the source and the outcome.
struct ShadowFetchMirror: Sendable {
    let sourceURL: String
    let sourceTitle: String
    let outcome: ShadowOutcomeKind
    let items: [FeedItem]
}

/// The one thing `RSSFetcher` is allowed to know about the shadow.
///
/// Both methods are synchronous and non-throwing on purpose: the parse path only fills a bounded
/// queue, so the cost it can add is bounded by that queue's capacity. Admission happens later, off
/// the parse path, in `drain()`.
protocol ShadowMirrorSink: AnyObject, Sendable {
    /// Level 2 capture point: between the parse and the mapping.
    func mirrorParsedEntry(_ entry: ShadowParsedEntry)
    /// Level 1 capture point: items + source + outcome together.
    func mirrorFetch(_ mirror: ShadowFetchMirror)
}

// MARK: - Intervals, drops and counters

/// One bounded run of mirroring. Work dropped inside it invalidates it: a comparison over an
/// interval the shadow knowingly under-covered is not evidence (plan §13).
struct ShadowIntervalID: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var description: String { "interval:\(rawValue)" }
}

/// Which capture point produced an item's identity.
enum ShadowMirrorLevel: String, Sendable {
    /// The parsed entry: the identity is the GUID/Atom id the wire format declared.
    case parsedEntry
    /// Only the `FeedItem` exists: the identity comes from the link or from the versioned fallback.
    /// The GUID is already gone, so this level cannot prove RSS/Atom identity fidelity.
    case legacyItem
}

enum ShadowDropReason: Equatable, Sendable {
    case queueFull
    /// The queue's item budget, not its outcome count, would have been exceeded.
    case queueItems
    /// A source holding parsed entries had to give way, so the entry map stays bounded.
    case pendingSourceOverflow
    case entryBudgetExceeded
    /// The shadow switched itself off; later work is dropped the same way.
    case shadowDisabled(ShadowBudgetBreach)

    var diagnostic: String {
        switch self {
        case .queueFull: return "queueFull"
        case .queueItems: return "queueItems"
        case .pendingSourceOverflow: return "pendingSourceOverflow"
        case .entryBudgetExceeded: return "entryBudgetExceeded"
        case .shadowDisabled(let breach): return "disabled:\(breach.rawValue)"
        }
    }
}

/// What the shadow did with one unit of work.
enum ShadowEnqueueResult: Equatable, Sendable {
    case queued
    case dropped(ShadowDropReason)
}

/// Coverage and cost of one interval. No content and no user data travel in it.
struct ShadowIntervalCoverage: Equatable, Sendable {
    let id: ShadowIntervalID
    let startedAt: Date
    /// Sources whose outcome this interval observed: coverage is measured per source and per batch,
    /// not per item (plan §13).
    var sources: Set<String> = []
    var outcomes: [ShadowOutcomeKind: Int] = [:]
    var mirroredBatches = 0
    var mirroredItems = 0
    /// Items whose identity came from the parsed entry (level 2).
    var itemsFromParsedEntry = 0
    /// Items whose identity had to come from the `FeedItem` alone (level 1).
    var itemsWithoutParsedEntry = 0
    var admittedRevisionCount = 0
    var duplicateAdmissions = 0
    var refusedAdmissions = 0
    var droppedWork = 0
    var droppedReasons: [String: Int] = [:]
    /// The quantity that stopped the shadow, when one did. A stop always names its cause.
    var budgetStop: ShadowBudgetBreach?
    /// True once admission refused every batch in `refusalStallThreshold` consecutive drains: the
    /// shadow stopped observing, so nothing in this interval may be called agreement.
    var admissionStalled = false
    /// Memory the process gained since the shadow was composed, as measured in this interval. Recorded
    /// because plan §13 asks for RSS to be measured; it is never a ceiling (see `ShadowBudget`).
    var residentGrowthBytes = 0
    var mirroredBytes = 0
    /// Alias rows (`legacy_item_map`) the shadow could not write. The canonical content is committed;
    /// only the durable alias index is incomplete, which is never a divergence of the runtime.
    var failedAliasWrites = 0

    /// A comparison over this interval is not evidence: the shadow dropped work, stopped itself, or
    /// stopped being admitted what it mirrored.
    var isInvalid: Bool { droppedWork > 0 || budgetStop != nil || admissionStalled }
}

// MARK: - Budget

/// What the shadow is allowed to cost (plan §13: CPU/RSS/DB/WAL/bytes measured; over budget the
/// shadow switches itself off and records why).
///
/// Every breaching quantity is charged to the shadow and nothing else: mirrored bytes and the shadow
/// database are its own, and CPU is measured around its own calls. Process-wide figures are not
/// ceilings: a ceiling that fires because another agent made the machine busy would switch the shadow
/// off for something it never caused, and a shadow that stops looking is a false-negative generator.
/// Resident growth is therefore **measured and reported per interval** as plan §13 asks, and never
/// sets `budgetStop`.
struct ShadowBudget: Equatable, Sendable {
    /// Outstanding outcomes. Measured fan-out (2026-09-18): the shipped catalogue holds 13,549
    /// distinct sources (`feedmine/Resources/Feeds/*/*.opml`) and one launch runs several passes over
    /// them — `fetchAll` with 5 in flight, `fetchStarter` with 15, plus progressive and background
    /// passes — with `drain()` running every 500 ms. Arrivals are bounded by the catalogue and the
    /// network, not by a small constant, so this is derived: 512 is the 15-wide starter window
    /// refilling ~34 times inside one drain interval, far beyond any arrival rate observed here.
    var queueCapacity = 512
    /// What actually bounds the queue: one fetch can carry thousands of items, so a count of outcomes
    /// is not a size. 4,096 items is a few MB of queued `FeedItem` values — the bound exists because
    /// the item count, not the outcome count, is what a shadow can be starved of memory by.
    var maximumQueuedItems = 4_096
    /// Sources that may hold parsed entries between the parse and the outcome hook. The map is the
    /// unbounded vector: a path that parses without ever producing an outcome would add one entry per
    /// call, so the number of sources is bounded and the oldest is dropped first.
    var maximumSourcesWithPendingEntries = 16
    /// One feed's entry count. Chosen to exceed any feed this app ships or fetches: the legacy parser
    /// already holds the whole document in memory, so a bigger feed is a problem before the shadow
    /// sees it, and the shadow must not drop entries for a feed the legacy path would keep.
    var maximumPendingEntriesPerSource = 4_096
    /// A **floor** on the bytes one interval's mirrored items keep alive, not a measurement of them:
    /// it sums the string and `Data` payloads the shadow can attribute (legacy id, source, scope,
    /// identity bytes, headline, link) and excludes allocator rounding, dictionary/array overhead and
    /// the values themselves — call the true figure about twice this for short strings. Derived from
    /// the measured catalogue: a 13,549-source launch admitting 10,000 items in one interval is ~2 MB
    /// on this floor, so 8 MiB is ~4x headroom on the floor alone. If it is wrong, the shadow stops
    /// itself naming `mirroredBytes` and the interval is invalid rather than compared.
    var maximumMirroredBytesPerInterval = 8 * 1024 * 1024
    /// The shadow database plus its WAL. Deliberately **not** derived, and it is the weakest number
    /// here: nothing prunes the shadow database yet (retention is PR-16's), and one full-catalogue
    /// refresh writes on the order of 13,549 sources x entries x ~1 KB. Treat this as the point where
    /// a long shadow run stops, with the cause named, not as a measured ceiling.
    var maximumDatabaseBytes = 512 * 1024 * 1024
    /// CPU spent **during the shadow's own drain call**. This is a window over a process-wide counter
    /// (`getrusage`), not a per-component one: what another thread does in the few milliseconds a
    /// drain takes is counted here too. Airtight accounting would have to count what the shadow owns
    /// (rows admitted, bytes hashed, bytes retained) instead of a clock of the process's.
    var maximumCPUMillisecondsPerInterval: Double = 1_000
    /// Consecutive drains in which every batch was refused. Past this, the shadow is not observing and
    /// says so: an admission failure that presents as a coverage gap is a false negative.
    var refusalStallThreshold = 3
    /// Rows the conflict read may return, and ids per payload query. Report paths must not grow with
    /// the shadow: what is not read is reported as truncated.
    var maximumReportedConflicts = 500
    var payloadQueryChunkSize = 500
    /// How many intervals keep their per-item detail, and how long an interval lasts. Retention is
    /// short on purpose: a long-running shadow must not accumulate per-item state forever.
    var retainedIntervals = 4
    var intervalDuration: TimeInterval = 60

    static let standard = ShadowBudget()
}

/// Which quantity the shadow exceeded. Every one of them is the shadow's own: bytes it holds and
/// admits, the database it writes, CPU spent inside its own calls. A process-wide figure is measured
/// and reported but never listed here, because it is not the shadow's cost (plan §13).
enum ShadowBudgetBreach: String, Equatable, Sendable {
    case mirroredBytes
    case databaseBytes
    case cpu
}

/// One measurement of what the process costs right now.
struct ShadowResourceReading: Equatable, Sendable {
    let residentBytes: Int
    let cpuMilliseconds: Double

    /// A process that costs nothing: the reading a test scripts to keep the budget out of the way.
    static let zero = ShadowResourceReading(residentBytes: 0, cpuMilliseconds: 0)
}

/// Injected so a test can put the shadow over budget without making the test process large.
protocol ShadowResourceMeasuring: Sendable {
    func reading() -> ShadowResourceReading
}

/// The real measurement: resident size from `task_info`, CPU from `getrusage`.
struct SystemShadowResourceMeasuring: ShadowResourceMeasuring {
    init() {}

    func reading() -> ShadowResourceReading {
        ShadowResourceReading(
            residentBytes: Self.residentBytes(),
            cpuMilliseconds: Self.cpuMilliseconds()
        )
    }

    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size)
    }

    static func cpuMilliseconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return (seconds(usage.ru_utime) + seconds(usage.ru_stime)) * 1_000
    }
}

// MARK: - The shadow's read side

/// One item the shadow mirrored, as the comparator needs it. `identityBytes` is the key the wire
/// format declared, kept only while its interval is retained.
struct ShadowMirroredItem: Equatable, Sendable {
    let legacyItemID: String
    let sourceURL: String
    /// The scope the identity lives in, so a conflict can be attributed to the right source.
    let scopeKey: String
    let interval: ShadowIntervalID
    let level: ShadowMirrorLevel
    let identityBytes: Data
    let identityConfidence: MappingConfidence
    /// `nil` when the runtime has no record for the item (Admission refused it).
    let recordID: Int64?
    let revisionID: Int64?
    /// What the runtime holds as the record's current payload, read back from the database.
    var currentHeadline: String?
    var currentLink: String?
}

/// A divergence the runtime itself audited, read back from `identity_conflict`.
struct ShadowIdentityConflict: Equatable, Sendable {
    let kind: String
    let namespace: String
    let scopeKey: String
    /// The record the contradiction belongs to, as the runtime stored it. The row keeps the offending
    /// *version* key bytes rather than the object key, so the record is what identifies the item.
    ///
    /// Known limit: for `ambiguous_alias` this column names the *other* record, so that kind can be
    /// attributed to the wrong item — it still appears as a counted, unattributed conflict. Exact
    /// per-item alias attribution would need the incoming object key in `identity_conflict`.
    let existingRecordID: Int64?
    let detectedAt: Date

    /// The same spelling `ExternalScopeKey.description` uses, so a conflict and a mirrored item can
    /// be compared without either side re-deriving a scope.
    var scopeDescription: String { "\(namespace):\(scopeKey)" }
}

struct ShadowCounters: Equatable, Sendable {
    var mirroredBatches = 0
    var mirroredItems = 0
    var itemsFromParsedEntry = 0
    var itemsWithoutParsedEntry = 0
    var droppedWork = 0
    var skippedWhileDisabled = 0
    var admissions = 0
    var duplicateAdmissions = 0
    var refusedAdmissions = 0
    /// Times the durable legacy alias could not be written. Counted, never silently discarded.
    var failedAliasWrites = 0
    /// Non-nil once the shadow switched itself off; it never switches back on in a session.
    var disabledReason: String?
    /// Non-nil once admission refused every batch for `refusalStallThreshold` drains in a row.
    var admissionStall: String?

    /// The kinds of divergence the runtime audited, by kind. Comparable across intervals because it
    /// counts the runtime's own conflict rows, not the comparator's opinion.
    var auditedDivergences: [String: Int] = [:]
}

/// Everything the comparator is allowed to see, with no content beyond what it compares.
struct ShadowCoverageReport: Equatable, Sendable {
    let intervals: [ShadowIntervalCoverage]
    let mirrored: [String: ShadowMirroredItem]
    let conflicts: [ShadowIdentityConflict]
    /// True when the conflict read hit `maximumReportedConflicts`: the list is a prefix, and a
    /// divergence count that reads a bounded prefix must say so.
    let conflictsTruncated: Bool
    let counters: ShadowCounters

    var invalidIntervals: Set<ShadowIntervalID> {
        Set(intervals.filter(\.isInvalid).map(\.id))
    }

    func interval(_ id: ShadowIntervalID) -> ShadowIntervalCoverage? {
        intervals.first { $0.id == id }
    }

    /// The interval that observed this source, when one did.
    func interval(covering sourceURL: String) -> ShadowIntervalID? {
        intervals
            .filter { $0.sources.contains(sourceURL) }
            .max(by: { $0.id < $1.id })?
            .id
    }
}

/// What one `drain()` did.
struct ShadowDrainReport: Equatable, Sendable {
    let admitted: Int
    let duplicates: Int
    let refused: Int
    let mirroredItems: Int
    let budgetBreach: ShadowBudgetBreach?
}

// MARK: - The bridge

/// Mirrors what the legacy path already acquired into the runtime's Admission (plan §13, PR-12).
///
/// Three properties are structural rather than promised:
/// - **No second fetch.** The bridge holds no transport and loads nothing: it takes the values the
///   legacy path already produced.
/// - **No user state.** It writes canonical content through Admission and legacy aliases through
///   `LegacyMappingStore`. It never touches `user.sqlite`, exposure, bookmarks or cursors.
/// - **Bounded cost.** Work crosses a bounded queue; drops are counted and invalidate their interval;
///   measured CPU/RSS/database bytes switch the shadow off and record the reason.
final class ShadowInputBridge: ShadowMirrorSink, @unchecked Sendable {
    let database: RuntimeDatabase
    let targetID: AcquisitionTargetID
    let budget: ShadowBudget

    private let admission: AdmissionEngine
    private let targets: AcquisitionTargetStore
    private let mappings: LegacyMappingStore
    private let measuring: any ShadowResourceMeasuring
    private let clock: @Sendable () -> Date
    /// Batch ids must not collide with an earlier launch, or Admission would answer `duplicate` for a
    /// body it has never seen.
    private let sessionToken = UUID().uuidString

    private struct Work {
        let mirror: ShadowFetchMirror
        let entries: [ShadowParsedEntry]
        let interval: ShadowIntervalID
    }

    /// One planned observation: everything its batch needs, plus what the comparator will be told.
    private struct PlannedObservation {
        let legacyItemID: String
        let item: FeedItem
        let level: ShadowMirrorLevel
        let identity: ExternalIdentityRef
        let payload: ObservationPayload
        let versionKey: ExternalVersionKey?
        let material: LegacyItemMapper.Material
    }

    private let lock = NSLock()
    private var queue: [Work] = []
    /// Items the queue currently holds: what actually bounds the queue's memory.
    private var queuedItems = 0
    private var pendingEntries: [String: [ShadowParsedEntry]] = [:]
    /// Insertion order of `pendingEntries`, so the oldest source can give way when the map is full.
    private var pendingEntryOrder: [String] = []
    /// Consecutive drains in which every batch was refused.
    private var consecutiveRefusals = 0
    private var admissionStall: String?
    private var intervalCounter: UInt64 = 0
    private var activeInterval: ShadowIntervalID
    private var coverage: [ShadowIntervalID: ShadowIntervalCoverage] = [:]
    private var mirrored: [String: ShadowMirroredItem] = [:]
    private var counters = ShadowCounters()
    private var sequence = 0
    private var disabledBreach: ShadowBudgetBreach?
    /// Resident size when the shadow was composed: the budget bounds its growth, not the absolute
    /// figure, because the process shares memory with everything that is not the shadow.
    private var residentBaseline: Int

    private static let intervalZero = ShadowIntervalID(rawValue: 0)

    init(
        database: RuntimeDatabase,
        targetID: AcquisitionTargetID,
        budget: ShadowBudget = .standard,
        measuring: any ShadowResourceMeasuring = SystemShadowResourceMeasuring(),
        clock: @escaping @Sendable () -> Date = Date.init,
        admission: AdmissionEngine = AdmissionEngine(),
        targets: AcquisitionTargetStore = AcquisitionTargetStore(),
        mappings: LegacyMappingStore = LegacyMappingStore()
    ) {
        self.database = database
        self.targetID = targetID
        self.budget = budget
        self.measuring = measuring
        self.clock = clock
        self.admission = admission
        self.targets = targets
        self.mappings = mappings
        self.activeInterval = Self.intervalZero
        self.residentBaseline = measuring.reading().residentBytes
        self.coverage[Self.intervalZero] = ShadowIntervalCoverage(
            id: Self.intervalZero,
            startedAt: clock()
        )
    }

    var isDisabled: Bool { disabledReason != nil }

    var disabledReason: String? { locked { counters.disabledReason } }

    /// Non-nil once admission has refused every batch for `refusalStallThreshold` drains in a row.
    var admissionStallReason: String? { locked { admissionStall } }

    var isAdmissionStalled: Bool { admissionStallReason != nil }

    // MARK: - Intervals

    /// Starts a new interval. Work dropped in an earlier one keeps invalidating that one.
    @discardableResult
    func beginInterval() -> ShadowIntervalID {
        locked {
            intervalCounter += 1
            let id = ShadowIntervalID(rawValue: intervalCounter)
            activeInterval = id
            var interval = ShadowIntervalCoverage(id: id, startedAt: clock())
            // A stall is a property of the shadow, not of one interval: every interval it knows about
            // while it is stalled is one it was not observing.
            interval.admissionStalled = admissionStall != nil
            coverage[id] = interval
            pruneRetention()
            return id
        }
    }

    /// Ends the active interval once it is older than `intervalDuration`. Without this the per-item
    /// detail of a long-running shadow would never be pruned, and a drop would keep invalidating a
    /// window that no longer exists. Work already enqueued keeps its own interval.
    private func rotateIntervalIfExpired() {
        let now = clock()
        let expired: Bool = locked {
            guard let current = coverage[activeInterval] else { return false }
            return now.timeIntervalSince(current.startedAt) >= budget.intervalDuration
        }
        guard expired else { return }
        beginInterval()
    }

    /// Keeps the last `retainedIntervals` intervals, dropping the per-item detail of older ones.
    private func pruneRetention() {
        guard coverage.count > budget.retainedIntervals else { return }
        let doomed = Set(coverage.keys.sorted().prefix(coverage.count - budget.retainedIntervals))
        for id in doomed { coverage.removeValue(forKey: id) }
        mirrored = mirrored.filter { !doomed.contains($0.value.interval) }
    }

    // MARK: - The capture points (called from RSSFetcher)

    func mirrorParsedEntry(_ entry: ShadowParsedEntry) {
        locked {
            guard disabledBreach == nil else {
                counters.skippedWhileDisabled += 1
                return
            }
            var entries = pendingEntries[entry.sourceURL] ?? []
            guard entries.count < budget.maximumPendingEntriesPerSource else {
                recordDrop(.entryBudgetExceeded)
                return
            }
            if entries.isEmpty, pendingEntries.count >= budget.maximumSourcesWithPendingEntries {
                // The map is the unbounded vector: a path that parses without producing an outcome
                // would add a source per call. The oldest pending source gives way — it is the one
                // whose outcome is least likely to still be coming.
                guard let oldest = pendingEntryOrder.first else {
                    recordDrop(.pendingSourceOverflow)
                    return
                }
                pendingEntries.removeValue(forKey: oldest)
                pendingEntryOrder.removeFirst()
                recordDrop(.pendingSourceOverflow)
            }
            if entries.isEmpty { pendingEntryOrder.append(entry.sourceURL) }
            entries.append(entry)
            pendingEntries[entry.sourceURL] = entries
        }
    }

    func mirrorFetch(_ mirror: ShadowFetchMirror) {
        _ = enqueue(mirror)
    }

    @discardableResult
    func enqueue(_ mirror: ShadowFetchMirror) -> ShadowEnqueueResult {
        locked {
            if let breach = disabledBreach {
                counters.skippedWhileDisabled += 1
                return .dropped(.shadowDisabled(breach))
            }
            guard queue.count < budget.queueCapacity else {
                recordDrop(.queueFull)
                return .dropped(.queueFull)
            }
            // A count of outcomes is not a size: one fetch can carry thousands of items.
            guard queuedItems + mirror.items.count <= budget.maximumQueuedItems else {
                recordDrop(.queueItems)
                return .dropped(.queueItems)
            }
            let entries = pendingEntries.removeValue(forKey: mirror.sourceURL) ?? []
            if !entries.isEmpty, let index = pendingEntryOrder.firstIndex(of: mirror.sourceURL) {
                pendingEntryOrder.remove(at: index)
            }
            queuedItems += mirror.items.count
            queue.append(Work(mirror: mirror, entries: entries, interval: activeInterval))
            return .queued
        }
    }

    /// Counts one dropped unit of work and invalidates the interval it belonged to.
    private func recordDrop(_ reason: ShadowDropReason) {
        counters.droppedWork += 1
        guard var intervalCoverage = coverage[activeInterval] else { return }
        intervalCoverage.droppedWork += 1
        intervalCoverage.droppedReasons[reason.diagnostic, default: 0] += 1
        coverage[activeInterval] = intervalCoverage
    }

    // MARK: - Admission

    /// Admits every queued unit of work, off the parse path.
    @discardableResult
    func drain() -> ShadowDrainReport {
        rotateIntervalIfExpired()
        let work: [Work] = locked {
            let pending = queue
            queue.removeAll(keepingCapacity: true)
            queuedItems -= pending.reduce(0) { $0 + $1.mirror.items.count }
            return pending
        }
        guard !work.isEmpty else {
            return ShadowDrainReport(
                admitted: 0, duplicates: 0, refused: 0, mirroredItems: 0, budgetBreach: locked { disabledBreach }
            )
        }

        do {
            _ = try ensureTarget()
        } catch {
            // Without its target row nothing can be admitted: the work is refused, never silently lost.
            locked {
                counters.refusedAdmissions += work.count
                coverage[activeInterval]?.refusedAdmissions += work.count
                recordRefusalWave(
                    admitted: 0,
                    refused: work.count,
                    reason: "target unavailable: \(error)",
                    auditedOnly: false
                )
            }
            return ShadowDrainReport(
                admitted: 0, duplicates: 0, refused: work.count, mirroredItems: 0, budgetBreach: nil
            )
        }

        var admitted = 0
        var duplicates = 0
        var refused = 0
        var mirroredItems = 0
        var lastRefusal: String?
        var refusals: [AdmissionResult] = []
        let cpuBefore = measuring.reading().cpuMilliseconds
        for item in work {
            switch admit(item) {
            case .admitted: admitted += 1
            case .duplicate: duplicates += 1
            case .refused(let result):
                refused += 1
                lastRefusal = Self.describe(result)
                refusals.append(result)
            }
            mirroredItems += item.mirror.items.count
        }
        let cpuSpent = measuring.reading().cpuMilliseconds - cpuBefore
        locked {
            recordRefusalWave(
                admitted: admitted + duplicates,
                refused: refused,
                reason: lastRefusal,
                auditedOnly: !refusals.isEmpty && refusals.allSatisfy(Self.isAuditedVerdict)
            )
        }
        return ShadowDrainReport(
            admitted: admitted,
            duplicates: duplicates,
            refused: refused,
            mirroredItems: mirroredItems,
            budgetBreach: checkBudget(cpuSpent: cpuSpent)
        )
    }

    private enum AdmissionOutcome {
        case admitted
        case duplicate
        case refused(AdmissionResult)
    }

    /// Sustained refusals mean the shadow is no longer being admitted what it mirrors, which must not
    /// read as agreement. Called with the lock held.
    ///
    /// An *audited* refusal is not a stall: `identityConflict` means the runtime refused to overwrite a
    /// divergent representation (ADR-003 D11) and `batchConflict` means it recognised a reused batch
    /// id. Both are the runtime working correctly, and counting them here would report the shadow as
    /// blind exactly when it found something.
    ///
    /// Both directions of mis-classification make this lane untrustworthy, and they are mirror images:
    /// a health signal that stays quiet when the shadow is blind is the false negative the budget's
    /// host-RSS tripwire used to produce, and a health signal that fires on a healthy verdict is a
    /// false alarm that would make a busy, *divergent* feed look like a broken shadow. When this rule
    /// grows, keep the question it answers: "was the shadow admitted what it mirrored?" — not "did any
    /// batch get refused?".
    private func recordRefusalWave(admitted: Int, refused: Int, reason: String?, auditedOnly: Bool) {
        guard refused > 0, admitted == 0 else {
            consecutiveRefusals = 0
            return
        }
        guard !auditedOnly else { return }
        consecutiveRefusals += 1
        guard consecutiveRefusals >= budget.refusalStallThreshold else { return }
        let description = reason ?? "admission refused every batch"
        admissionStall = description
        counters.admissionStall = description
        coverage[activeInterval]?.admissionStalled = true
    }

    /// True when every refusal in the wave was a verdict about content rather than a failure to admit.
    private static func isAuditedVerdict(_ result: AdmissionResult) -> Bool {
        switch result {
        case .identityConflict, .batchConflict: return true
        case .admitted, .duplicate, .staleTarget, .staleCheckpoint, .invalidObservation, .storageFailure:
            return false
        }
    }

    private static func describe(_ result: AdmissionResult) -> String {
        switch result {
        case .admitted: return "admitted"
        case .duplicate: return "duplicate"
        case .batchConflict: return "batchConflict"
        case .staleTarget: return "staleTarget"
        case .staleCheckpoint: return "staleCheckpoint"
        case .identityConflict: return "identityConflict"
        case .invalidObservation: return "invalidObservation"
        case .storageFailure: return "storageFailure"
        }
    }

    private func admit(_ work: Work) -> AdmissionOutcome {
        guard let snapshot = try? targets.snapshot(for: targetID, in: database) else {
            return .refused(.storageFailure(reason: "shadow target snapshot unavailable"))
        }

        let scope = Self.scope(forSourceURL: work.mirror.sourceURL)
        var planned: [PlannedObservation] = []
        var seenItemIDs: Set<String> = []
        for item in work.mirror.items where !seenItemIDs.contains(item.id) {
            seenItemIDs.insert(item.id)
            let entry = work.entries.first { $0.legacyItemID == item.id }
            guard let observation = plan(item: item, entry: entry, scope: scope) else { continue }
            planned.append(observation)
        }

        let observations: [AcquisitionObservation] = planned.compactMap { observation in
            try? AcquisitionObservation(
                externalKey: observation.identity.key,
                versionKey: observation.versionKey,
                precedence: .makeCurrent(expectedRevision: currentRevision(for: observation.identity.key)),
                payload: observation.payload,
                identityConfidence: observation.identity.confidence,
                fallbackSchemeVersion: observation.identity.fallbackSchemeVersion
            )
        }

        let batch = AcquisitionBatch(
            batchID: "shadow-\(sessionToken)-\(nextSequence())",
            fingerprint: "\(work.mirror.sourceURL)|\(work.mirror.outcome.rawValue)|"
                + "\(work.mirror.items.count)|\(work.entries.count)",
            targetID: targetID,
            generation: snapshot.generation,
            observations: observations,
            evidence: Self.evidence(for: planned),
            bindingRevision: snapshot.bindingRevision,
            leaseEpoch: snapshot.leaseEpoch,
            expectedCheckpointRevision: snapshot.checkpointRevision,
            // The shadow resumes nothing: it observes what the legacy path already fetched.
            nextCheckpoint: nil
        )

        let result = admission.admit(batch, in: database)
        let outcome: AdmissionOutcome
        var admittedRevisionCount = 0
        switch result {
        case .admitted(let receipt):
            outcome = .admitted
            admittedRevisionCount = receipt.admittedRevisionCount
        case .duplicate:
            outcome = .duplicate
        default:
            outcome = .refused(result)
        }

        // Read back what the runtime made of the work: the comparator compares the runtime's state,
        // never the shadow's intention.
        var records: [String: ShadowMirroredItem] = [:]
        var failedAliasWrites = 0
        for observation in planned {
            let readBack = readBackIdentity(observation.identity.key)
            if let recordID = readBack.recordID, let revisionID = readBack.revisionID,
               let record = try? OriginRecordID(recordID), let revision = try? OriginRevisionID(revisionID) {
                // A failed alias write leaves the content committed and the durable alias missing. It
                // is counted rather than swallowed: a later session would otherwise read this item as
                // "not mirrored", which is a gap in the shadow and must never look like one.
                do {
                    try mappings.recordItemMapping(
                        LegacyItemMapper.mapping(
                            legacyItemID: observation.legacyItemID,
                            legacySourceURL: observation.item.sourceURL,
                            record: record,
                            revision: revision,
                            material: observation.material,
                            mappedAt: clock()
                        ),
                        in: database
                    )
                } catch {
                    failedAliasWrites += 1
                }
            }
            records[observation.legacyItemID] = ShadowMirroredItem(
                legacyItemID: observation.legacyItemID,
                sourceURL: observation.item.sourceURL,
                scopeKey: observation.identity.key.scope.description,
                interval: work.interval,
                level: observation.level,
                identityBytes: observation.identity.key.bytes,
                identityConfidence: observation.material.isLowConfidence ? .low : .high,
                recordID: readBack.recordID,
                revisionID: readBack.revisionID,
                currentHeadline: nil,
                currentLink: nil
            )
        }

        let retainedBytes = records.values.reduce(0) { $0 + Self.retainedBytes(of: $1) }
        locked {
            counters.mirroredBatches += 1
            counters.mirroredItems += planned.count
            counters.admissions += 1
            let fromParsedEntry = records.values.filter { $0.level == .parsedEntry }.count
            let fromLegacyItem = records.values.filter { $0.level == .legacyItem }.count
            counters.itemsFromParsedEntry += fromParsedEntry
            counters.itemsWithoutParsedEntry += fromLegacyItem
            // Per interval as well as in total: the interval is the unit a report is read in, and a
            // level's coverage is only meaningful for the batch of work it describes.
            coverage[work.interval]?.itemsFromParsedEntry += fromParsedEntry
            coverage[work.interval]?.itemsWithoutParsedEntry += fromLegacyItem
            switch outcome {
            case .admitted:
                coverage[work.interval]?.admittedRevisionCount += admittedRevisionCount
            case .duplicate:
                counters.duplicateAdmissions += 1
                coverage[work.interval]?.duplicateAdmissions += 1
            case .refused:
                counters.refusedAdmissions += 1
                coverage[work.interval]?.refusedAdmissions += 1
            }
            coverage[work.interval]?.sources.insert(work.mirror.sourceURL)
            coverage[work.interval]?.outcomes[work.mirror.outcome, default: 0] += 1
            coverage[work.interval]?.mirroredBatches += 1
            coverage[work.interval]?.mirroredItems += planned.count
            coverage[work.interval]?.mirroredBytes += retainedBytes
            counters.failedAliasWrites += failedAliasWrites
            coverage[work.interval]?.failedAliasWrites += failedAliasWrites
            for (legacyItemID, record) in records { mirrored[legacyItemID] = record }
        }
        return outcome
    }

    /// Plans one observation. Level 2 wins when the entry exists: it carries the identity the wire
    /// format declared. Level 1 falls back to the link, or to the versioned low-confidence key.
    ///
    /// Known limit: the entry's link is the URL the legacy path persisted (the trimmed declared link,
    /// or the enclosure URL when a podcast item has no link), not the raw `<link>` text. The GUID is
    /// preserved byte-identically (D10); a link-only item's key is the legacy URL rather than the wire
    /// bytes, which is what keeps levels 1 and 2 agreeing about the same item.
    private func plan(
        item: FeedItem,
        entry: ShadowParsedEntry?,
        scope: ExternalScopeKey
    ) -> PlannedObservation? {
        let level: ShadowMirrorLevel = entry == nil ? .legacyItem : .parsedEntry
        let material = LegacyItemMapper.material(
            guid: entry?.guid,
            link: entry?.link ?? item.url,
            title: entry?.title ?? item.title,
            publishedAt: entry?.publishedAt ?? item.publishedAt,
            disambiguator: LegacyItemMapper.fallbackDisambiguator(legacyItemID: item.id)
        )
        guard let identity = try? LegacyItemMapper.identity(for: material, scope: scope) else {
            return nil
        }
        let updatedAt = entry?.updatedAt ?? item.updatedAt
        return PlannedObservation(
            legacyItemID: item.id,
            item: item,
            level: level,
            identity: identity,
            payload: ObservationPayload(
                headline: entry?.title ?? item.title,
                link: URL(string: entry?.link ?? item.url),
                excerpt: entry?.excerpt ?? item.excerpt,
                body: nil,
                authoredAt: entry?.publishedAt ?? item.publishedAt,
                modifiedAt: updatedAt,
                observedAt: clock()
            ),
            versionKey: (try? Self.versionKey(for: updatedAt, scope: scope)) ?? nil,
            material: material
        )
    }

    // MARK: - Read back from the runtime

    private struct ReadBack {
        let recordID: Int64?
        let revisionID: Int64?
    }

    /// The record and current revision the runtime holds for a key. Read-only: the shadow never
    /// writes canonical state outside Admission.
    private func readBackIdentity(_ key: ExternalObjectKey) -> ReadBack {
        let row = (try? database.read { database in
            try Row.fetchOne(database, sql: """
                SELECT identity.origin_record_id, record.current_revision_id
                FROM external_identity AS identity
                LEFT JOIN origin_record AS record ON record.id = identity.origin_record_id
                WHERE identity.connector_namespace = ? AND identity.scope_key = ?
                  AND identity.key_kind = 'object' AND identity.external_key = ?
                """, arguments: [key.scope.namespace.rawValue, key.scope.scopeKey, key.bytes])
        }) ?? nil
        guard let row else { return ReadBack(recordID: nil, revisionID: nil) }
        let recordID: Int64? = row["origin_record_id"]
        let revisionID: Int64? = row["current_revision_id"]
        return ReadBack(recordID: recordID, revisionID: revisionID)
    }

    /// The revision the CAS must expect: the one the runtime holds as current for this key, so an
    /// update moves the pointer and a duplicate does not.
    private func currentRevision(for key: ExternalObjectKey) -> OriginRevisionID? {
        guard let revisionID = readBackIdentity(key).revisionID else { return nil }
        return try? OriginRevisionID(revisionID)
    }

    private func ensureTarget() throws -> AcquisitionTargetSnapshot {
        if let snapshot = try targets.snapshot(for: targetID, in: database) { return snapshot }
        return try targets.register(
            targetID,
            connectorKind: "syndication",
            connectorVersion: "shadow-1",
            in: database
        )
    }

    private func nextSequence() -> Int {
        locked {
            sequence += 1
            return sequence
        }
    }

    // MARK: - Budget

    private func checkBudget(cpuSpent: Double) -> ShadowBudgetBreach? {
        if let disabledBreach { return disabledBreach }
        let reading = measuring.reading()
        let databaseBytes = Self.databaseBytes(in: database.location.directory)
        let (mirroredBytes, interval) = locked {
            (coverage[activeInterval]?.mirroredBytes ?? 0, activeInterval)
        }
        let residentGrowth = reading.residentBytes - residentBaseline

        let breach: ShadowBudgetBreach?
        if mirroredBytes > budget.maximumMirroredBytesPerInterval {
            breach = .mirroredBytes
        } else if databaseBytes > budget.maximumDatabaseBytes {
            breach = .databaseBytes
        } else if cpuSpent > budget.maximumCPUMillisecondsPerInterval {
            breach = .cpu
        } else {
            breach = nil
        }

        locked {
            // The measurement is recorded whether or not it breached, and a stop names both the
            // quantity and the interval: a reader has to know what to raise.
            coverage[interval]?.residentGrowthBytes = residentGrowth
            guard let breach else { return }
            disabledBreach = breach
            counters.disabledReason = "shadow disabled in \(interval): \(breach.rawValue) over budget"
            coverage[interval]?.budgetStop = breach
        }
        return breach
    }

    /// A floor for what one mirrored item keeps alive: the string and `Data` payloads that can be
    /// attributed to it. Allocator rounding, the dictionaries that hold it and the value itself are
    /// excluded, so the real figure is larger — this is deliberately a floor rather than a proxy
    /// silently read as a measurement.
    static func retainedBytes(of item: ShadowMirroredItem) -> Int {
        item.legacyItemID.utf8.count
            + item.sourceURL.utf8.count
            + item.scopeKey.utf8.count
            + item.identityBytes.count
            + (item.currentHeadline?.utf8.count ?? 0)
            + (item.currentLink?.utf8.count ?? 0)
    }

    /// `runtime-v2.sqlite` plus its WAL and shared-memory files, in the shadow's own directory.
    static func databaseBytes(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("runtime-v2.sqlite") }
            .reduce(into: 0) { total, name in
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(name).path
                )
                total += (attributes?[.size] as? Int) ?? 0
            }
    }

    // MARK: - The comparator's input

    /// Reads back what the runtime holds for everything this session mirrored. Reads only.
    func coverageReport() -> ShadowCoverageReport {
        let snapshot: (intervals: [ShadowIntervalCoverage], items: [String: ShadowMirroredItem], counters: ShadowCounters) = locked {
            (self.coverage.values.sorted { $0.id < $1.id }, self.mirrored, self.counters)
        }
        var items = snapshot.items

        let payloads = currentPayloads(for: Set(items.values.compactMap(\.recordID)))
        for (legacyItemID, item) in items {
            guard let recordID = item.recordID, let payload = payloads[recordID] else { continue }
            items[legacyItemID]?.currentHeadline = payload.headline
            items[legacyItemID]?.currentLink = payload.link
        }

        var counters = snapshot.counters
        let (conflicts, conflictsTruncated) = identityConflicts()
        counters.auditedDivergences = Dictionary(grouping: conflicts, by: \.kind).mapValues(\.count)
        return ShadowCoverageReport(
            intervals: snapshot.intervals,
            mirrored: items,
            conflicts: conflicts,
            conflictsTruncated: conflictsTruncated,
            counters: counters
        )
    }

    /// What the runtime holds as current for each record, in bounded queries. The id set is bounded
    /// by retention (four intervals of mirrored items); the statement length is bounded separately, so
    /// neither the count nor the SQL grows without limit.
    private func currentPayloads(for recordIDs: Set<Int64>) -> [Int64: (headline: String?, link: String?)] {
        guard !recordIDs.isEmpty else { return [:] }
        let ids = Array(recordIDs)
        let chunkSize = max(1, budget.payloadQueryChunkSize)
        var result: [Int64: (headline: String?, link: String?)] = [:]
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = ids[start..<min(start + chunkSize, ids.count)]
            let rows = (try? database.read { database in
                try Row.fetchAll(database, sql: """
                    SELECT record.id AS record_id, revision.headline, revision.primary_link
                    FROM origin_record AS record
                    LEFT JOIN origin_revision AS revision ON revision.id = record.current_revision_id
                    WHERE record.id IN (\(chunk.map { String($0) }.joined(separator: ",")))
                    """)
            }) ?? []
            for row in rows {
                let recordID: Int64 = row["record_id"]
                result[recordID] = (row["headline"], row["primary_link"])
            }
        }
        return result
    }

    /// The most recent conflicts, never the whole table: a report path whose cost grows with the
    /// shadow is not a diagnostic. `truncated` says the list is a prefix, because a divergence count
    /// read from a prefix must not look complete. Called with no lock held.
    private func identityConflicts() -> (conflicts: [ShadowIdentityConflict], truncated: Bool) {
        let limit = budget.maximumReportedConflicts
        let rows = (try? database.read { database in
            try Row.fetchAll(database, sql: """
                SELECT conflict_kind, connector_namespace, scope_key, existing_origin_record_id, detected_at
                FROM identity_conflict ORDER BY id DESC LIMIT \(limit + 1)
                """)
        }) ?? []
        let truncated = rows.count > limit
        let recent = rows.prefix(limit)
        let conflicts = recent.map { row in
            let detectedAt: Int64 = row["detected_at"]
            let recordID: Int64? = row["existing_origin_record_id"]
            return ShadowIdentityConflict(
                kind: row["conflict_kind"],
                namespace: row["connector_namespace"],
                scopeKey: row["scope_key"],
                existingRecordID: recordID,
                detectedAt: Date(timeIntervalSince1970: Double(detectedAt) / 1000)
            )
        }
        return (conflicts, truncated)
    }

    // MARK: - Helpers

    /// The scope of the objects one source observes. The durable key is the legacy normalized source
    /// URL, exactly as the catalogue names it (`FeedSource.id`), and the scope derivation itself is
    /// the package bridge's — never re-derived here.
    static func scope(forSourceURL sourceURL: String) -> ExternalScopeKey {
        let key = OPMLParser.normalizeURL(sourceURL)
        return LegacySourceMapper.objectScope(
            for: LegacySourceMapper.catalogIdentity(
                key: key,
                normalizedURL: key,
                // The shadow observes the legacy path, not the catalogue, so it holds no compact
                // catalogue id: zero is the catalogue's `none`, and `objectScope` never reads it.
                compactID: CatalogSourceID(0)
            )
        )
    }

    /// The Atom `updated` instant as the representation's version key, in epoch milliseconds so the
    /// same instant always encodes to the same bytes.
    ///
    /// Known limit, recorded rather than hidden: the wire text of `updated` is not what is stored, its
    /// millisecond value is. Two updates of one item inside the same millisecond therefore share a
    /// version key and their differing payloads are reported as `version_payload_divergence` — a false
    /// divergence, narrow (a publisher would have to emit two different bodies for one millisecond)
    /// but real. Storing the declared text would remove it and lose the "same instant, two spellings"
    /// collapse that makes the key stable.
    static func versionKey(for updatedAt: Date?, scope: ExternalScopeKey) throws -> ExternalVersionKey? {
        guard let updatedAt else { return nil }
        let milliseconds = Int64((updatedAt.timeIntervalSince1970 * 1000).rounded())
        return try ExternalVersionKey(scope: scope, text: String(milliseconds))
    }

    /// One evidence row per batch, with no retained bytes: what the shadow saw, not the feed body.
    private static func evidence(for planned: [PlannedObservation]) -> [ConnectorEvidence] {
        guard !planned.isEmpty else { return [] }
        var material = Data()
        for observation in planned {
            material.append(Data(observation.legacyItemID.utf8))
            material.append(observation.identity.key.bytes)
        }
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return [ConnectorEvidence(kind: .parsedEntry, digest: digest, bytes: nil)]
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
