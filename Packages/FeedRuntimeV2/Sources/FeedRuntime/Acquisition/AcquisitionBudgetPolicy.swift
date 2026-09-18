import Foundation

/// How hot the device is, as `ProcessInfo.thermalState` reports it.
public enum ThermalPressure: String, CaseIterable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

/// What the network costs right now.
///
/// `lowDataMode` is the system's Low Data Mode, which iOS reports through
/// `NWPath.isConstrained`; `expensive` is a metered path (`NWPath.isExpensive`). They lower different
/// quantities — constrained lowers what may be shipped, expensive lowers what may be spent — so they
/// are separate values rather than one "bad network" flag.
public enum NetworkCost: String, CaseIterable, Sendable, Equatable {
    /// No usable path: nothing may be acquired at all.
    case unavailable
    case normal
    case lowDataMode
    case expensive
    /// Both at once: metered *and* constrained.
    case expensiveAndConstrained
}

/// The device conditions a budget is computed from (plan §14 PR-15: low power/data, thermal,
/// constrained/expensive network, memory).
///
/// These arrive as a value and are never read from the process by the policy: a budget that can only
/// be exercised by changing the physical device is a budget nobody measures, and the plan requires
/// each signal to be proven with an injected one.
public struct AcquisitionConditions: Sendable, Equatable {
    /// Low Power Mode is on.
    public var lowPowerMode: Bool
    /// The network costs money.
    public var network: NetworkCost
    /// The device's thermal state.
    public var thermal: ThermalPressure
    /// A memory warning has been received and not yet cleared.
    public var memoryPressure: Bool
    /// True while the process is allowed to spend network at all (the reader is not offline).
    public var allowsNetwork: Bool

    public init(
        lowPowerMode: Bool = false,
        network: NetworkCost = .normal,
        thermal: ThermalPressure = .nominal,
        memoryPressure: Bool = false,
        allowsNetwork: Bool = true
    ) {
        self.lowPowerMode = lowPowerMode
        self.network = network
        self.thermal = thermal
        self.memoryPressure = memoryPressure
        self.allowsNetwork = allowsNetwork
    }

    /// The conditions a healthy device on an unmetered network reports.
    public static let unrestricted = AcquisitionConditions()
}

/// Which condition changed a budget. The list travels with the answer so a reader learns *why* a
/// budget shrank instead of seeing a smaller number.
public enum AcquisitionSignal: String, CaseIterable, Sendable, Equatable {
    case lowPowerMode
    case lowDataMode
    case expensiveNetwork
    case thermalSerious
    case thermalCritical
    case memoryPressure
    case networkUnavailable

    /// Whether this signal removes speculative work entirely rather than only shrinking it.
    public var stopsSpeculativeWork: Bool {
        switch self {
        case .lowPowerMode, .lowDataMode, .thermalSerious, .thermalCritical,
             .memoryPressure, .networkUnavailable:
            return true
        case .expensiveNetwork:
            return false
        }
    }
}

/// What one demand may spend, after the conditions have been applied.
public struct AcquisitionBudget: Sendable, Equatable {
    /// Endpoints one demand may refill.
    public var sourceLimit: Int
    /// Refills in flight at once.
    public var maxConcurrency: Int
    /// Wall-clock ceiling for the whole demand.
    public var deadlineMilliseconds: Int
    /// Whether speculative (prefetch) work may start under this budget.
    public var allowsSpeculativeWork: Bool
    /// The signals that changed the baseline, in the order they applied. Empty means the baseline
    /// stands as given.
    public var appliedSignals: [AcquisitionSignal]

    public init(
        sourceLimit: Int,
        maxConcurrency: Int,
        deadlineMilliseconds: Int,
        allowsSpeculativeWork: Bool,
        appliedSignals: [AcquisitionSignal] = []
    ) {
        self.sourceLimit = sourceLimit
        self.maxConcurrency = maxConcurrency
        self.deadlineMilliseconds = deadlineMilliseconds
        self.allowsSpeculativeWork = allowsSpeculativeWork
        self.appliedSignals = appliedSignals
    }
}

/// Derives a budget from the conditions, from a baseline the caller states.
///
/// There is deliberately no default baseline here: the numbers belong to the surface that spends them
/// (ADR-004's rule for `ResourceLimits`), and this type owns only the *shape* of the adaptation —
/// bounded, monotone (no signal ever raises a budget), floored at one source and one connection, and
/// every applied signal named.
public enum AcquisitionBudgetPolicy {
    /// Applies `conditions` to `baseline`.
    ///
    /// - Parameter baseline: what the caller would spend on an unrestricted device.
    /// - Returns: a budget that is never larger than `baseline` in any dimension and never smaller
    ///   than one source and one connection. `allowsSpeculativeWork` is false whenever any applied
    ///   signal stops speculative work; `sourceLimit` is 0 only when there is no network at all, which
    ///   is the one case where a demand must not fetch.
    public static func budget(
        baseline: AcquisitionBudget,
        conditions: AcquisitionConditions
    ) -> AcquisitionBudget {
        guard conditions.allowsNetwork, conditions.network != .unavailable else {
            return AcquisitionBudget(
                sourceLimit: 0,
                maxConcurrency: 0,
                deadlineMilliseconds: baseline.deadlineMilliseconds,
                allowsSpeculativeWork: false,
                appliedSignals: [.networkUnavailable]
            )
        }

        var budget = AcquisitionBudget(
            sourceLimit: max(1, baseline.sourceLimit),
            maxConcurrency: max(1, baseline.maxConcurrency),
            deadlineMilliseconds: max(1, baseline.deadlineMilliseconds),
            allowsSpeculativeWork: baseline.allowsSpeculativeWork
        )
        var applied: [AcquisitionSignal] = []

        func apply(_ signal: AcquisitionSignal, sources: (Int) -> Int, concurrency: (Int) -> Int) {
            budget.sourceLimit = max(1, sources(budget.sourceLimit))
            budget.maxConcurrency = max(1, concurrency(budget.maxConcurrency))
            if signal.stopsSpeculativeWork { budget.allowsSpeculativeWork = false }
            applied.append(signal)
        }

        switch conditions.network {
        case .lowDataMode:
            apply(.lowDataMode, sources: { halves($0) }, concurrency: { $0 })
        case .expensive:
            apply(.expensiveNetwork, sources: { halves($0) }, concurrency: { $0 })
        case .expensiveAndConstrained:
            apply(.expensiveNetwork, sources: { halves($0) }, concurrency: { $0 })
            apply(.lowDataMode, sources: { halves($0) }, concurrency: { $0 })
        case .unavailable, .normal:
            break
        }

        if conditions.lowPowerMode {
            apply(.lowPowerMode, sources: { halves($0) }, concurrency: { $0 })
        }
        switch conditions.thermal {
        case .nominal, .fair:
            break
        case .serious:
            apply(.thermalSerious, sources: { halves($0) }, concurrency: { min($0, 2) })
        case .critical:
            apply(.thermalCritical, sources: { quarters($0) }, concurrency: { _ in 1 })
        }
        if conditions.memoryPressure {
            apply(.memoryPressure, sources: { $0 }, concurrency: { _ in 1 })
        }

        budget.appliedSignals = applied
        return budget
    }

    /// One source at least, so a demand that is allowed to run always has work to do.
    private static func halves(_ value: Int) -> Int { max(1, value / 2) }

    /// A quarter of the baseline, floored at one source: a critical device still refreshes something.
    private static func quarters(_ value: Int) -> Int { max(1, value / 4) }
}
