import Foundation
import FeedConnectorSyndication
import FeedDomain
import FeedRuntime
import FeedStorage

/// One source the acquisition owner can fetch, as the app's catalogue states it.
///
/// It carries no runtime identity: the owner resolves the durable `SourceID`, the binding and the
/// target itself, because allocation belongs to `FeedStorage` and the catalogue knows only its own
/// key (ADR-003 D2, D3). What it carries besides that key is the catalogue's own compact id, because
/// the bridge row the composition writes (`legacy_source_map`) is keyed by it, and the value must
/// come from the catalogue rather than be derived from the runtime.
struct V2AcquisitionSourceDescriptor: Hashable, Sendable {
    /// The catalogue's durable key (`FeedSource.id`, the normalized fetch URL).
    let catalogKey: String
    /// The catalogue's compact id for that key — the app-level `SourceID`, the catalog compiler's
    /// digest of the key, not a runtime one (ADR-003 D2). It is what `legacy_source_map` records so a
    /// later lookup by catalogue id translates to the runtime source.
    let compactID: CatalogSourceID
    /// The endpoint as the catalogue states it. A target's endpoint is operational configuration, not
    /// editorial identity (ADR-005 D5).
    let endpoint: URL
    let title: String
}

/// What composing the owner did, so a launch can report it rather than assert it.
struct V2AcquisitionReport: Equatable, Sendable {
    var watched: Int = 0
    var registered: Int = 0
    var reused: Int = 0
    var refused: [String] = []
}

/// What the owner has done since launch. Counts only, never content (plan §16).
struct V2AcquisitionCounters: Equatable, Sendable {
    var episodes: Int = 0
    var pulls: Int = 0
    var admittedBatches: Int = 0
    var admittedObservations: Int = 0
    var duplicateBatches: Int = 0
    var refusedBatches: Int = 0
    var lastStop: String = "none"
}

/// The connectors one acquisition owner has composed.
///
/// `AcquisitionSourceResolver` is a synchronous closure taken once at composition, so it has to read a
/// registry that is filled afterwards: this box is the smallest thing that does that without a second
/// actor (a closure cannot `await`) and without process-wide state (two launches must not share one).
/// The lock is the same technique `ShadowMirrorRegistry` uses for the same reason.
private final class ConnectorRegistry: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var sources: [AcquisitionTargetID: any AcquisitionSource] = [:]

    func store(_ source: any AcquisitionSource, for targetID: AcquisitionTargetID) {
        lock.lock()
        defer { lock.unlock() }
        sources[targetID] = source
    }

    func source(for targetID: AcquisitionTargetID) -> (any AcquisitionSource)? {
        lock.lock()
        defer { lock.unlock() }
        return sources[targetID]
    }
}

/// The process's acquisition owner for a launch whose mode owns acquisition (plan §13, §14).
///
/// It is thin on purpose. `AcquisitionCoordinator` owns the coordination — leases, one refill in
/// flight per target, budgets, the frontier — `AdmissionEngine` decides validity, and
/// `SyndicationConnector` owns the wire. What this type adds is the composition the runtime cannot do
/// for itself:
///
/// * it resolves each catalogue source to its durable `SourceID` (`SourceRegistry`), registers the
///   acquisition target that Admission validates stamps against (`AcquisitionTargetStore`), and
///   composes that target's connector with the enrollment that makes its content a member of the
///   source — without which the content is admitted and *invisible*, because Selection's eligibility
///   predicate requires a membership;
/// * it turns one composition into one bounded episode: a purpose (bootstrap or active runway), a
///   demand, a deadline from the purpose's own budget, and a fresh accounting window;
/// * it exposes what the episode did, so "the runtime acquired" is a number and not a claim.
///
/// It is an actor because the counters and the registered catalogue are shared mutable state; the
/// connector and the coordinator are `Sendable` values it holds.
actor V2Acquisition: FeedCompositionAcquiring {
    /// How many of the catalogue's sources one launch watches.
    /// The purpose budgets already bound how much one episode may *fetch* (four targets for the
    /// bootstrap), so this is not the fetch bound — it is the bound on how much target state one launch
    /// registers, allocates and holds connectors for. It is deliberately larger than one episode so
    /// successive demands walk through the catalogue instead of refetching the same four sources, and
    /// it is deliberately finite so a catalogue of thirteen thousand sources is not thirteen thousand
    /// `source` rows, targets and connectors built on the launch path.
    static let launchWindow = 32

    private let database: RuntimeDatabase
    private let coordinator: AcquisitionCoordinator
    private let targetStore = AcquisitionTargetStore()
    private let sources = RuntimeSourceRegistry()
    private let mappings = LegacyMappingStore()
    private let clock: any EditorialClock
    private let budgets: AcquisitionBudgetTable
    private let transport: any HTTPTransport
    private let limits: SyndicationHTTPLimits
    /// The composed connectors, held so a later demand reuses the same instance (and the same host
    /// gate) instead of rebuilding one per episode.
    private let connectors = ConnectorRegistry()

    private var catalogue: [AcquisitionTarget] = []
    private var counters = V2AcquisitionCounters()

    init(
        database: RuntimeDatabase,
        transport: any HTTPTransport,
        clock: any EditorialClock,
        budgets: AcquisitionBudgetTable = .baseline,
        limits: SyndicationHTTPLimits = SyndicationHTTPLimits()
    ) {
        self.database = database
        self.clock = clock
        self.budgets = budgets
        self.transport = transport
        self.limits = limits
        let connectors = self.connectors
        // The resolver is a compile-time mapping taken where the runtime is composed: the acquisition
        // layer never looks a connector up by matching a protocol string (ADR-005 D2).
        self.coordinator = AcquisitionCoordinator(
            resolver: AcquisitionSourceResolver { target in connectors.source(for: target.id) },
            budgets: budgets,
            targetStore: targetStore,
            clock: clock
        )
    }

    // MARK: - Composition

    /// Watches the sources this launch will acquire from.
    ///
    /// Every step here is durable and idempotent, so a relaunch reuses what the last one registered
    /// instead of creating a second source, target or binding for the same catalogue key.
    func watch(_ descriptors: [V2AcquisitionSourceDescriptor]) -> V2AcquisitionReport {
        var report = V2AcquisitionReport()
        var targets: [AcquisitionTarget] = []
        for descriptor in descriptors.prefix(Self.launchWindow) {
            do {
                let composed = try compose(descriptor, report: &report)
                targets.append(composed.target)
                connectors.store(composed.source, for: composed.target.id)
            } catch {
                // A source whose identity cannot be stated is reported and skipped: refusing the whole
                // launch because one catalogue entry is malformed would take the feed down with it.
                report.refused.append("\(descriptor.catalogKey): \(error)")
            }
        }
        report.watched = targets.count
        catalogue = targets
        return report
    }

    private func compose(
        _ descriptor: V2AcquisitionSourceDescriptor,
        report: inout V2AcquisitionReport
    ) throws -> (target: AcquisitionTarget, source: any AcquisitionSource) {
        let identity = LegacySourceMapper.catalogIdentity(
            key: descriptor.catalogKey,
            normalizedURL: descriptor.catalogKey,
            compactID: descriptor.compactID
        )
        let editorialKey = try LegacySourceMapper.editorialKey(for: identity)
        let sourceID = try sources.sourceID(
            for: editorialKey,
            displayTitle: descriptor.title,
            kind: LegacySourceMapper.syndicationNamespace.rawValue,
            in: database
        )
        // The bridge row is what makes the mapping durable for every other reader (ADR-003 D18): a
        // rebuild, a rollback or a diagnosis resolves the same catalogue key to the same runtime source.
        // `catalog_source_id` is the catalogue's own compact id — the column D2's only translation
        // (`LegacySourceMap.runtimeSource(forCatalogSource:)`) looks the runtime source up by — so a
        // placeholder id would make the row useless, and the schema's `> 0` check refuses one anyway.
        let mapping = try LegacySourceMapper.mapping(
            for: identity,
            runtimeSourceID: sourceID,
            mappedAt: clock.now
        )
        do {
            try mappings.recordSourceMapping(mapping, in: database)
        } catch {
            // A durability write that failed is never swallowed: with the row missing, a later lookup by
            // catalogue id answers `missingSourceMapping` for a source this launch is acquiring from.
            // The refusal names the ids the row was to be keyed by — never a URL (§16) — and refuses the
            // source, the way every other failed composition step here does, instead of acquiring content
            // behind a bridge that does not exist.
            Log.feed.error(
                "runtime-v2 source-bridge-write-failed catalogSourceID=\(mapping.catalogSourceID.rawValue) canonicalizationVersion=\(mapping.editorialKey.canonicalizationVersion) runtimeSourceID=\(sourceID.rawValue) error=\(String(describing: error))"
            )
            throw error
        }
        let binding = try LegacySourceMapper.binding(
            for: identity,
            runtimeSourceID: sourceID,
            endpoint: descriptor.endpoint.absoluteString
        )
        let enrollment = try SyndicationSourceEnrollment(
            sourceID: sourceID,
            binding: binding.key,
            bindingGeneration: binding.generation
        )

        let targetID = AcquisitionTargetID("syndication:source:\(sourceID.rawValue)")
        let snapshot: AcquisitionTargetSnapshot
        if let existing = try targetStore.snapshot(for: targetID, in: database) {
            snapshot = existing
            report.reused += 1
        } else {
            snapshot = try targetStore.register(
                targetID,
                connectorKind: SyndicationNamespace.connector.rawValue,
                connectorVersion: SyndicationNamespace.connector.rawValue,
                bindingRevision: binding.generation,
                configurationBlob: Data(binding.configurationJSON.utf8),
                in: database
            )
            report.registered += 1
        }

        let syndicationTarget = SyndicationTarget(
            targetID: targetID,
            endpoint: descriptor.endpoint,
            generation: snapshot.generation,
            scope: LegacySourceMapper.objectScope(for: identity)
        )
        let ingredient = SyndicationAcquisitionIngredient(
            target: syndicationTarget,
            transport: transport,
            enrollment: enrollment,
            limits: limits,
            backoff: SyndicationBackoffPolicy(),
            clock: clock
        )
        let source = SyndicationAcquisitionSource(
            ingredient: ingredient,
            hostGate: SyndicationHostGateStore()
        )
        return (
            AcquisitionTarget(
                id: targetID,
                connectorKind: SyndicationNamespace.connector.rawValue,
                generation: snapshot.generation,
                bindingRevision: snapshot.bindingRevision
            ),
            source
        )
    }

    // MARK: - Acquisition

    /// One bounded episode for one composition (ADR-005 D6, D8, D9).
    ///
    /// A cold composition bootstraps; a refresh or a replenishment serves the runway in front of the
    /// viewport. The purpose is what carries the budget: a bootstrap may spend four targets and
    /// twenty-five seconds, a runway two and fifteen, and neither may exceed its own table row.
    func acquire(
        for plan: ResolvedFeedPlan,
        reason: FeedSessionCompositionReason,
        at: Date
    ) async -> AcquisitionRunSummary? {
        guard !catalogue.isEmpty else { return nil }
        let purpose = Self.purpose(for: reason)
        let budget = budgets[purpose]
        // One window per episode: usage is counted per purpose per window, and a composition is the
        // window (ADR-005 D9).
        await coordinator.resetUsage(for: purpose)
        let demand = AcquisitionDemand(
            purpose: purpose,
            holderID: plan.context.canonicalSerialization,
            deficit: SupplyDeficit(items: plan.budget.cardLimit),
            deadline: at.addingTimeInterval(budget.timeLimit.isFinite ? budget.timeLimit : 20)
        )
        let summary = await coordinator.run(demand, catalogue: catalogue, in: database)
        counters.episodes += 1
        let episodeNumber = counters.episodes
        let targetCount = catalogue.count
        // Two numbers, because they answer different questions and used to share one label: `catalogue` is how
        // many targets this launch registered (`launchWindow`), `budgetTargets` is how many this *episode* may
        // fetch (`PurposeBudget.targets` for the resolved purpose). The line said `targets=` for the first,
        // which reads as the second — the distinction `launchWindow`'s own doc draws ("this is not the fetch
        // bound"). The catalogue count stays in the line because the registration statement's `watched=` is
        // the same quantity and comparing them is how both were shown to be one launch's.
        Log.feed.info(
            "runtime-v2 episode=\(episodeNumber) purpose=\(purpose.rawValue) reason=\(reason.rawValue) catalogue=\(targetCount) budgetTargets=\(budget.targets) pulls=\(summary.pulls) admitted=\(summary.admittedBatches) observations=\(summary.admittedObservations) stop=\(Self.describe(summary.stop))"
        )
        counters.pulls += summary.pulls
        counters.admittedBatches += summary.admittedBatches
        counters.admittedObservations += summary.admittedObservations
        counters.duplicateBatches += summary.duplicateBatches
        counters.refusedBatches += summary.refusedBatches
        counters.lastStop = Self.describe(summary.stop)
        return summary
    }

    func currentCounters() -> V2AcquisitionCounters { counters }

    /// The frontier's own answer to "is there more work", for diagnostics.
    func frontierState() async -> String { String(describing: await coordinator.frontierState) }

    static func purpose(for reason: FeedSessionCompositionReason) -> AcquisitionPurpose {
        switch reason {
        case .cold, .contextSwitch: return .bootstrap
        case .refresh, .replenishment: return .activeRunway
        }
    }

    /// The stop reason as text. Names and numbers only: a stop reason never carries a URL (plan §16).
    static func describe(_ stop: AcquisitionStopReason) -> String {
        switch stop {
        case .planCompleted: return "planCompleted"
        case .satisfied: return "satisfied"
        case .exhausted: return "exhausted"
        case .degraded(let reason): return "degraded(\(reason))"
        case .budgetStop(let purpose): return "budgetStop(\(purpose.rawValue))"
        case .deadlineReached: return "deadlineReached"
        case .refused(let result): return "refused(\(result))"
        case .transportFailure: return "transportFailure"
        case .cancelled: return "cancelled"
        }
    }
}

extension V2AcquisitionSourceDescriptor {
    /// The catalogue's enabled sources as acquisition work.
    ///
    /// The catalogue key is `FeedSource.id` — the normalized fetch URL the whole app already agrees
    /// on — and the endpoint is the source's own URL. A source whose URL cannot be parsed states no
    /// work and is dropped here rather than registered as a target that could never be fetched.
    ///
    /// The compact id comes from the catalogue's own derivation, `CatalogIdentity.sourceID(for:)` —
    /// the function whose result `SQLiteCatalogStore` inserts as `catalog_source.id` — applied to the
    /// same key the descriptor carries. Nothing here derives a runtime id: the runtime allocates its
    /// own, and `legacy_source_map` is the only place the two meet (ADR-003 D2).
    static func descriptors(for sources: [FeedSource]) -> [V2AcquisitionSourceDescriptor] {
        sources.compactMap { source in
            guard let endpoint = URL(string: source.url) else { return nil }
            return V2AcquisitionSourceDescriptor(
                catalogKey: source.id,
                compactID: CatalogSourceID(CatalogIdentity.sourceID(for: SourceKey(source.id)).rawValue),
                endpoint: endpoint,
                title: source.title
            )
        }
    }
}
