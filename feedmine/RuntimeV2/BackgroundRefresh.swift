import BackgroundTasks
import FeedRuntime
import Foundation

/// The BGTask surface one background refresh drives (plan §14 PR-15).
///
/// `BGAppRefreshTask` is constructed by the system and cannot be built by a test, so the contract this
/// slice has to prove — completion exactly once, expiry as real cancellation, a commit that already
/// landed staying valid — is stated against this protocol. `BGAppRefreshTask` conforms directly, so
/// the shipping path and the tested path are the same code rather than two copies of it.
@MainActor
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: BackgroundTaskHandle {}

/// The two things the scheduler asks `BGTaskScheduler` for.
///
/// Both are abstracted for the same reason: a live scheduler cannot be constructed, queried for a
/// pending request, or made to expire a task on demand, so the invariants that would otherwise only
/// hold while nothing runs are testable only through a seam.
@MainActor
protocol BackgroundTaskRegistering: AnyObject {
    /// Registers `identifier` and calls `launchHandler` on the main actor when the system launches it.
    func register(identifier: String, launchHandler: @escaping (any BackgroundTaskHandle) -> Void) -> Bool
    /// Submits one app-refresh request. Throws exactly what `BGTaskScheduler.submit` throws.
    func submitAppRefresh(identifier: String, earliestBeginDate: Date) throws
}

/// The real scheduler.
@MainActor
final class SystemBackgroundTaskScheduler: BackgroundTaskRegistering {
    func register(
        identifier: String,
        launchHandler: @escaping (any BackgroundTaskHandle) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // A processing task must never be run as an app refresh: complete it rather than hand it a
            // handler whose contract it does not satisfy.
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in launchHandler(refresh) }
        }
    }

    func submitAppRefresh(identifier: String, earliestBeginDate: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // An earliest date, not a promise: iOS chooses the actual execution time from usage, battery,
        // connectivity and system load.
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }
}

/// Whether a completion reached the system, and what the two paths did instead.
///
/// `BGTaskScheduler` treats a second `setTaskCompleted` as a programming error and a missing one as a
/// task that never finished, so the completion is forwarded by whichever path arrives first and every
/// later arrival is counted rather than forwarded. That count is what makes "exactly once" a number
/// instead of a claim.
@MainActor
final class BackgroundTaskCompletion {
    private let sink: (Bool) -> Void
    private var didComplete = false

    /// True once the system has taken the task back.
    private(set) var didExpire = false
    /// Every completion a path asked for, including the ones that were refused.
    private(set) var completionRequests = 0
    /// Completions actually handed to `setTaskCompleted`. Never exceeds one.
    private(set) var completionsForwarded = 0
    /// Completions a second path asked for after the task was already completed.
    private(set) var completionsIgnored = 0

    /// Cancels the work in flight. Set once, before the task can expire.
    var onExpire: (() -> Void)?
    var onForward: (() -> Void)?
    var onIgnore: (() -> Void)?

    init(sink: @escaping (Bool) -> Void) {
        self.sink = sink
    }

    var isCompleted: Bool { didComplete }

    /// Reports the work's outcome. The first caller wins; a later one is counted and dropped.
    func complete(success: Bool) {
        completionRequests += 1
        guard !didComplete else {
            completionsIgnored += 1
            onIgnore?()
            return
        }
        didComplete = true
        completionsForwarded += 1
        onForward?()
        sink(success)
    }

    /// The system is taking the task back. Producers are cancelled, the task is completed as
    /// unsuccessful, and the work's own completion becomes a no-op.
    ///
    /// Nothing is rolled back: content this demand already committed stays committed, which is the
    /// difference between "cancelled before commit" and "committed then cancelled".
    func expire() {
        guard !didExpire else { return }
        didExpire = true
        onExpire?()
        complete(success: false)
    }
}

/// What one background refresh may spend. Derived from the device conditions, never from a constant.
struct BackgroundRefreshDemand: Sendable, Equatable {
    let sourceLimit: Int
    let maxConcurrency: Int
    let deadline: Duration
    /// The conditions that changed the baseline, in the order they applied. Empty means none did.
    let appliedSignals: [AcquisitionSignal]

    /// Whether the demand may reach the network at all.
    var isAllowed: Bool { sourceLimit > 0 && maxConcurrency > 0 }
}

/// One bounded refill, as the store reports it.
///
/// Every field is a count the caller can assert on: the demand's whole point is that it fetches only
/// what nothing else holds, so `shared`/`servedFresh` are evidence and not diagnostics.
struct BackgroundRefreshDemandReport: Sendable, Equatable {
    /// Endpoints this demand claimed and refilled.
    var led = 0
    /// Endpoints another demand already held when the claim was made: no request was issued.
    var shared = 0
    /// Endpoints answered from a refill inside the freshness window: no request was issued.
    var servedFresh = 0
    /// Endpoints that produced a result, success or failure — one attempt each.
    var attempted = 0
    /// Endpoints whose attempt succeeded, so the ledger records them as fresh and their content is
    /// committed. This is the count that decides "cancelled before commit" from "committed then
    /// cancelled".
    var committed = 0
    /// Endpoints whose attempt failed.
    var failed = 0
    /// Items committed by this demand.
    var newItems = 0
    /// True when the demand stopped because its task was cancelled.
    var cancelled = false
    /// Smart Feed presets refreshed by this demand. Unit: presets, not endpoints — kept apart from the
    /// endpoint counts so the two are never summed by accident.
    var smartFeedsRefreshed = 0
    /// Smart Feed presets whose refresh failed. Unit: presets.
    var smartFeedsFailed = 0

    /// True when this demand committed anything at all: content, or a preset. This is what separates
    /// "cancelled before commit" from "committed then cancelled".
    var committedWork: Bool { committed > 0 || smartFeedsRefreshed > 0 }

    /// True when this demand issued no request at all because another producer held every endpoint.
    var issuedNoRequests: Bool { attempted == 0 }
}

/// What one background refresh did.
///
/// The three terminal states are distinct on purpose: a run cancelled *after* its last commit leaves
/// that content admitted, and reporting it as "cancelled before commit" would hide work that exists.
enum BackgroundRefreshOutcome: Equatable, Sendable {
    /// The demand ran to its end and its commits are durable.
    case committed(sources: Int, newItems: Int)
    /// Every endpoint the demand wanted was already being refilled: no request was issued.
    case sharedWithForeground(sources: Int)
    /// The demand fetched nothing because there was nothing to fetch, or the conditions forbade it.
    case nothingToDo(reason: String)
    /// The task was cancelled before anything was committed.
    case cancelledBeforeCommit
    /// The task was cancelled after this demand committed: the commit stays valid.
    case cancelledAfterCommit(sources: Int, newItems: Int)
    /// The demand could not run. `reason` is logged, never swallowed.
    case failed(reason: String)

    /// What the system is told. A cancellation that still committed, or a demand that found every
    /// endpoint already being refilled, is not a failure: nothing was lost by ending then.
    var isSuccess: Bool {
        switch self {
        case .committed, .sharedWithForeground, .cancelledAfterCommit:
            return true
        case .nothingToDo, .cancelledBeforeCommit, .failed:
            return false
        }
    }
}

/// The common pipeline, as the background refresh sees it.
///
/// This is the process's one acquisition owner — the same store the foreground reads from — so the
/// background task adds no tree of its own. P9 in the acquisition map is the pair this closes: the
/// handler used to build `loader ?? FeedLoader()`, a second `FeedStore`, `RSSFetcher` and OPML load.
@MainActor
protocol BackgroundRefreshOwning: AnyObject {
    func runBackgroundRefresh(_ demand: BackgroundRefreshDemand) async -> BackgroundRefreshDemandReport
}

/// The device conditions the budget is derived from, read in one place.
///
/// The values are read here and nowhere else, so the budget itself stays a pure function of a value
/// and every signal can be proved with an injected one (plan §14 PR-15).
@MainActor
enum SystemDeviceConditions {
    static func current(network: NetworkMonitor? = nil) -> AcquisitionConditions {
        let thermal: ThermalPressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }

        let connected = network?.isConnected ?? true
        // Low Data Mode is what iOS reports through `NWPath.isConstrained`; a metered path is
        // `isExpensive`. They are separate because they lower different quantities.
        let cost: NetworkCost
        if !connected { cost = .unavailable }
        else if network?.isConstrained == true && network?.isExpensive == true { cost = .expensiveAndConstrained }
        else if network?.isConstrained == true { cost = .lowDataMode }
        else if network?.isExpensive == true { cost = .expensive }
        else { cost = .normal }

        return AcquisitionConditions(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            network: cost,
            thermal: thermal,
            memoryPressure: SystemDeviceConditions.isUnderMemoryPressure,
            allowsNetwork: connected
        )
    }

    /// Set by the memory-warning path and cleared when the run ends.
    ///
    /// A memory warning has no "cleared" notification, so the flag is per background run rather than
    /// process-lifetime state: one warning means the next demand is planned as if memory were tight.
    static var isUnderMemoryPressure: Bool {
        get { memoryWarningSeen }
        set { memoryWarningSeen = newValue }
    }
    private static var memoryWarningSeen = false
}

/// The budget one background demand runs under, and the signals that shaped it.
enum BackgroundRefreshBudget {
    /// What an unrestricted device would spend on one background refresh. Small on purpose: a
    /// background window is shared with the system and the reader is not waiting for it.
    static let baseline = AcquisitionBudget(
        sourceLimit: 6,
        maxConcurrency: 2,
        deadlineMilliseconds: 25_000,
        allowsSpeculativeWork: false
    )

    static func demand(for conditions: AcquisitionConditions) -> BackgroundRefreshDemand {
        let budget = AcquisitionBudgetPolicy.budget(baseline: baseline, conditions: conditions)
        return BackgroundRefreshDemand(
            sourceLimit: budget.sourceLimit,
            maxConcurrency: budget.maxConcurrency,
            deadline: .milliseconds(budget.deadlineMilliseconds),
            appliedSignals: budget.appliedSignals
        )
    }
}

/// Where the process's one acquisition owner comes from.
///
/// The app creates its loader exactly once, here, and everything that needs it — the scene and the
/// background task — asks for the same instance. A provider rather than a handed-over reference because a
/// background launch can deliver the app-refresh task before the app has built anything (measured
/// 2026-09-18: every test-host launch delivered the task, and `FeedmineApp`'s configuration had not run
/// yet), and the answer then has to be *the* owner the foreground will later use. Besides being the only
/// way to answer early, this is what closes P9 structurally: there is no second `FeedStore`, `RSSFetcher`
/// or OPML parse to build, because the only way to obtain one is to ask for the shared one.
@MainActor
enum FeedLoaderProvider {
    private static var stored: FeedLoader?

    /// The process's loader, created on first use. Main-actor isolated, so no lock and no
    /// `nonisolated(unsafe)` state: both callers (the scene and the background task) are on the main actor.
    static var shared: FeedLoader {
        if let stored { return stored }
        let loader = FeedLoader()
        stored = loader
        return loader
    }
}

/// The process's one acquisition owner is the loader the app already holds.
///
/// The conformance is declared here rather than on the loader's own file so the background path's
/// requirement — a single owner, never a second one — is stated in the same place as the demand it
/// serves.
extension FeedLoader: BackgroundRefreshOwning {}
