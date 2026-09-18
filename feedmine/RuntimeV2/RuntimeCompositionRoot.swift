import Foundation
import FeedConnectorSyndication
import FeedDomain
import FeedStorage

/// How a launch decision turned into a composed runtime (plan §13; `docs/runtime-v2/rollout.md` §1).
enum RuntimeCompositionOutcome: Equatable, Sendable {
    /// The mode runs the shadow: its own database, bridge and comparison are composed.
    case shadowComposed(databaseDirectory: URL)
    /// The mode owns acquisition and presentation: the runtime's own database, the one policy-enforcing
    /// transport, the acquisition owner and the feed session are composed.
    case fullComposed(databaseDirectory: URL)
    /// The mode was not composed. The legacy path stays the only owner of the feed, and the reason
    /// is recorded rather than left implicit.
    case legacyOnly(reason: String)
}

/// Composes Runtime V2 for a launch. Nothing here depends on a view: no SwiftUI, no `FeedLoader`.
///
/// `v2Full` composes the acquiring runtime: its own database in the production directory, one
/// `PolicyEnforcingHTTPTransport` shared by every fetch, the acquisition owner and the feed session
/// the screen draws from. `mirroredShadow` composes the shadow. `v2Presentation` still composes
/// nothing — it needs a runtime that renders from a canonical supply nobody acquires in that mode, and
/// composing half of one would create a second owner of the feed, which is exactly what the mode table
/// forbids — so it stays legacy with the reason recorded.
final class RuntimeCompositionRoot: @unchecked Sendable {
    let decision: RuntimeLaunchDecision
    let outcome: RuntimeCompositionOutcome
    /// The shadow, non-nil exactly when the mode runs one.
    let shadow: ShadowInputBridge?
    /// The shadow's database, in its own directory — never the runtime's production database.
    let shadowDatabase: RuntimeDatabase?
    /// The acquiring runtime, non-nil exactly when the mode owns acquisition.
    let full: V2FullRuntime?
    /// PR-04's bridge, composed because the runtime owns this projection. The shadow never writes
    /// through it: mirrored mode writes no exposure, bookmark or cursor (plan §13).
    let userState: UserStateBridge?

    private let lock = NSLock()
    private var drainTask: Task<Void, Never>?

    private init(
        decision: RuntimeLaunchDecision,
        outcome: RuntimeCompositionOutcome,
        shadow: ShadowInputBridge?,
        shadowDatabase: RuntimeDatabase?,
        full: V2FullRuntime?,
        userState: UserStateBridge?
    ) {
        self.decision = decision
        self.outcome = outcome
        self.shadow = shadow
        self.shadowDatabase = shadowDatabase
        self.full = full
        self.userState = userState
    }

    /// Builds the runtime this launch runs.
    ///
    /// - Parameters:
    ///   - decision: the mode resolved once at launch.
    ///   - applicationSupportDirectory: the app's Application Support directory. The shadow database
    ///     lives in `<applicationSupport>/Feedmine/RuntimeV2/shadow/`, a directory of its own, so a
    ///     shadow run can never touch the runtime's production database (plan §6).
    ///   - userState: PR-04's bridge, when the app has one to offer. Held, never invoked by the
    ///     shadow.
    ///   - budget: the shadow's cost ceiling.
    ///
    /// It is main-actor isolated because the acquiring runtime it may build is: the session it composes
    /// hands snapshots to the screen, and the screen is the main actor. Composing off the main actor
    /// would only move the hop, not remove it.
    @MainActor
    static func compose(
        decision: RuntimeLaunchDecision,
        applicationSupportDirectory: URL,
        userState: UserStateBridge? = nil,
        budget: ShadowBudget = .standard
    ) throws -> RuntimeCompositionRoot {
        if decision.mode.ownsAcquisition {
            let directory = productionDirectory(applicationSupportDirectory: applicationSupportDirectory)
            let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
            // One transport for the whole process: the connector's body reads and anything a later
            // slice fetches go through the same policy-enforcing boundary, so "every production fetch
            // passes `EndpointPolicy`" is a property of the composition and not of each caller.
            let acquisition = V2Acquisition(
                database: database,
                transport: PolicyEnforcingHTTPTransport(),
                clock: SystemEditorialClock()
            )
            return RuntimeCompositionRoot(
                decision: decision,
                outcome: .fullComposed(databaseDirectory: directory),
                shadow: nil,
                shadowDatabase: nil,
                full: V2FullRuntime(database: database, acquisition: acquisition),
                userState: userState
            )
        }

        guard decision.mode.runsShadow else {
            return RuntimeCompositionRoot(
                decision: decision,
                outcome: .legacyOnly(reason: Self.legacyReason(for: decision)),
                shadow: nil,
                shadowDatabase: nil,
                full: nil,
                userState: userState
            )
        }

        let directory = shadowDirectory(applicationSupportDirectory: applicationSupportDirectory)
        let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        let shadow = ShadowInputBridge(
            database: database,
            targetID: Self.shadowTargetID,
            budget: budget
        )
        return RuntimeCompositionRoot(
            decision: decision,
            outcome: .shadowComposed(databaseDirectory: directory),
            shadow: shadow,
            shadowDatabase: database,
            full: nil,
            userState: userState
        )
    }

    /// The runtime's production directory: the runtime database beside the shadow's, never the same.
    static func productionDirectory(applicationSupportDirectory: URL) -> URL {
        RuntimeDatabaseLocation
            .applicationSupport(applicationSupportDirectory)
            .directory
    }

    /// The shadow's own directory, beside the runtime's production one and never the same.
    static func shadowDirectory(applicationSupportDirectory: URL) -> URL {
        RuntimeDatabaseLocation
            .applicationSupport(applicationSupportDirectory)
            .directory
            .appendingPathComponent("shadow", isDirectory: true)
    }

    /// One target for the legacy syndication path the shadow observes. The shadow owns no
    /// acquisition; this identifies the work it mirrors, so Admission has a stamp to validate.
    static let shadowTargetID = AcquisitionTargetID("legacy-syndication-shadow")

    @MainActor
    private static func legacyReason(for decision: RuntimeLaunchDecision) -> String {
        if decision.rejection != nil {
            return "\(decision.diagnostic) — the refused request resolved to legacy"
        }
        switch decision.mode {
        case .legacy:
            return "runtime-v2 mode=legacy: the legacy path owns acquisition and presentation"
        case .v2Presentation:
            return "runtime-v2 mode=v2Presentation is not composed in this build (it needs a runtime "
                + "that renders from a canonical supply no mode acquires); the legacy path stays the "
                + "only owner"
        case .mirroredShadow:
            return "runtime-v2 mode=mirroredShadow composed as a shadow"
        case .v2Full:
            // Unreachable: `compose` composes the acquiring runtime for this mode before it asks for a
            // legacy reason. Stated rather than folded into another mode, because the two compose
            // different things.
            return "runtime-v2 mode=v2Full composed as the acquiring runtime"
        }
    }

    // MARK: - Installation

    /// Makes new `RSSFetcher`s observe what they already fetched.
    ///
    /// `FeedStore` owns the fetcher and is 8 293 lines long, so the shadow is installed once here
    /// instead of threading a parameter through it (PR-12 spec: keep the hooks reviewable).
    func installMirrorSink() {
        guard let shadow else { return }
        ShadowMirrorRegistry.install(shadow)
    }

    func removeMirrorSink() {
        guard let shadow else { return }
        ShadowMirrorRegistry.remove(shadow)
    }

    /// Admits queued work off the parse path. Callers that do not want a loop (tests) call the
    /// bridge directly.
    @discardableResult
    func drainShadow() -> ShadowDrainReport? {
        shadow?.drain()
    }

    /// Starts the background drain loop: `enqueue` only fills a bounded queue, and this is what
    /// calls Admission.
    func startDraining(every interval: Duration = .milliseconds(500)) {
        guard shadow != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        guard drainTask == nil else { return }
        drainTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.shadow?.drain()
            }
        }
    }

    func stopDraining() {
        lock.lock()
        let task = drainTask
        drainTask = nil
        lock.unlock()
        task?.cancel()
    }

    deinit {
        drainTask?.cancel()
    }
}

/// Where a newly created `RSSFetcher` finds the shadow.
///
/// The app builds its fetcher inside `FeedStore`, which this PR must not grow, so the sink is
/// installed once per launch instead of being threaded through the store. With no shadow mode the
/// registry stays empty and the fetcher's hooks cost one optional check each.
enum ShadowMirrorRegistry {
    private static let lock = NSLock()
    /// Guarded by `lock`: the sink is written once at launch and read on the fetch path.
    nonisolated(unsafe) private static var sink: (any ShadowMirrorSink)?

    static var current: (any ShadowMirrorSink)? {
        lock.lock()
        defer { lock.unlock() }
        return sink
    }

    static func install(_ sink: any ShadowMirrorSink) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    /// Removes the sink only when it is the one given: a sibling installation must not be removed by
    /// a root that no longer owns it.
    static func remove(_ sink: any ShadowMirrorSink) {
        lock.lock()
        if let installed = self.sink, installed === sink { self.sink = nil }
        lock.unlock()
    }
}
