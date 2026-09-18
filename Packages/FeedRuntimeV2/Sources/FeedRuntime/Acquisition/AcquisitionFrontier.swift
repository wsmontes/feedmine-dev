import Foundation
import FeedDomain

/// One unit of acquisition work: an endpoint plus connector-owned, versioned configuration plus a
/// generation (ADR-005 D5).
///
/// It is operational work, not editorial identity. Nothing here is derived from, or compared
/// against, a Source or a catalogue row, and Selection, Publication or Presentation never read the
/// connector kind: a target may serve several Sources and several targets may serve one binding
/// (ADR-005 D5, D10; plan §19 #5).
public struct AcquisitionTarget: Hashable, Sendable {
    /// The identity of the work. Opaque text, never a Source id and never a normalised URL used as
    /// editorial identity (ADR-003 D7).
    public let id: AcquisitionTargetID
    /// The connector that owns this target's configuration. Recorded for registration and
    /// diagnostics; the acquisition layer never branches on it (ADR-005 D2).
    public let connectorKind: String
    /// Operational validity of the work; a revocation or configuration change advances it
    /// (ADR-005 D6, D10).
    public let generation: UInt64
    /// The binding revision the target currently serves (ADR-006 D1).
    public let bindingRevision: UInt64

    public init(
        id: AcquisitionTargetID,
        connectorKind: String,
        generation: UInt64 = 1,
        bindingRevision: UInt64 = 1
    ) {
        self.id = id
        self.connectorKind = connectorKind
        self.generation = generation
        self.bindingRevision = bindingRevision
    }
}

/// Which part of the frontier one item sits in (ADR-005 D7; Blueprint §82, §84).
public enum FrontierWorkClass: String, Hashable, Sendable, CaseIterable {
    /// Work the current demand needs next.
    case head
    /// Work already running under a live lease.
    case active
    /// Work kept eligible without being needed yet. It is the first to leave the runnable window
    /// when the budget shrinks (ADR-005 D9: `speculative` is the first category cancelled).
    case exploration
}

/// The hard bound on how much of the frontier may be runnable at once, whatever the catalogue holds
/// (ADR-005 D7; `invariant 12`, `I-19`).
public struct FrontierBound: Hashable, Sendable {
    public let head: Int
    public let active: Int
    public let exploration: Int

    /// The defaults are the same order of magnitude as the purpose table's target budgets; the
    /// purpose's own target budget is what actually caps a plan (ADR-005 D7, D9).
    public init(head: Int = 4, active: Int = 4, exploration: Int = 2) {
        self.head = max(0, head)
        self.active = max(0, active)
        self.exploration = max(0, exploration)
    }

    /// The most work one plan may draw from the frontier.
    public var runnable: Int { head + active + exploration }
}

/// Why the frontier cannot run work although supply exists. Exhaustion and degradation are distinct
/// reported states, never a silent empty plan (ADR-005 D8; plan §19 #37).
public enum FrontierDegradation: Hashable, Sendable {
    /// The purpose could not pay for the next unit of work (ADR-005 D9).
    case budgetStop(AcquisitionPurpose)
    /// The purpose's time budget or the caller's deadline passed (ADR-005 D9).
    case deadlineReached
    /// The source reported a transport failure. No retry loop lives here: the next demand decides.
    case transportFailure(AcquisitionTargetID)
    /// The stream reported a discontinuity; the durable checkpoint stays the resume point.
    case streamDisconnected(AcquisitionTargetID)
    /// Work exists but the target was revoked or disabled and its lease epoch moved.
    case revokedTargets(Int)
    /// The plan described work against a configuration that is no longer current (ADR-005 D10).
    case bindingChanged(AcquisitionTargetID)
    /// The durable target row could not be read.
    case unknownTarget(AcquisitionTargetID)
    /// No connector is composed for the target.
    case missingSource(AcquisitionTargetID)
    /// The target state could not be read.
    case storageFailure(AcquisitionTargetID)
}

/// What the runtime can say about the frontier right now.
public enum AcquisitionFrontierState: Hashable, Sendable {
    case work(eligible: Int, runnable: Int)
    /// No eligible work at all: supply ended (ADR-005 D8).
    case exhausted
    /// Supply exists, policy prevented fetching it (ADR-005 D8).
    case degraded(FrontierDegradation)
}

/// One runnable item, with its position in the demand's ranking.
public struct FrontierItem: Hashable, Sendable {
    public let target: AcquisitionTarget
    /// Lower runs sooner. It is the item's position among eligible targets, never a catalogue row
    /// position or a URL-derived key (ADR-005 D7).
    public let rank: Int
    public let workClass: FrontierWorkClass
}

/// A finite set of acquisition work, classified by work rather than by URL (ADR-005 D7).
///
/// It is a value type rebuilt from durable target state plus current demand: catalogue growth raises
/// eligibility, while the number of runnable items stays bounded by `bound` and by the purpose
/// budget table. Nothing here holds a per-source resource, so a large catalogue cannot become a
/// large number of actors or connections (plan §20.3; `invariant 12`).
public struct AcquisitionFrontier: Sendable {
    public let bound: FrontierBound

    /// Every eligible target in demand order. Deterministic: the order is the target id, so two
    /// runs over the same catalogue plan the same work.
    private var ordered: [AcquisitionTarget] = []
    /// Targets with a live lease (ADR-005 D6).
    private var running: Set<AcquisitionTargetID> = []
    /// Targets whose source reported the end of its stream, with the binding revision that ended.
    private var finished: [AcquisitionTargetID: UInt64] = [:]
    private var purpose: AcquisitionPurpose?
    private var cap: Int = 0
    private var degradation: FrontierDegradation?

    public init(bound: FrontierBound = FrontierBound()) {
        self.bound = bound
    }

    /// Rebuilds the frontier from the eligible catalogue and the current demand.
    ///
    /// A new demand is a new attempt, so an earlier degradation is cleared. A target that finished
    /// under an older binding revision becomes eligible again: a configuration change is new work
    /// (ADR-005 D8, D10).
    public mutating func rebuild(
        catalogue: [AcquisitionTarget],
        demand: AcquisitionDemand,
        budget: PurposeBudget
    ) {
        purpose = demand.purpose
        degradation = nil
        cap = max(0, min(bound.runnable, budget.targets))
        ordered = catalogue.sorted { $0.id.rawValue < $1.id.rawValue }
        for (targetID, revision) in finished {
            guard let current = catalogue.first(where: { $0.id == targetID }) else { continue }
            if current.bindingRevision != revision {
                finished.removeValue(forKey: targetID)
            }
        }
    }

    // MARK: - Lease reporting

    /// Records that the target is running under a lease.
    public mutating func markRunning(_ targetID: AcquisitionTargetID) {
        running.insert(targetID)
    }

    /// Records that the target no longer runs: the last lease was released, and any other context's
    /// interest is untouched (ADR-005 D6).
    public mutating func markStopped(_ targetID: AcquisitionTargetID) {
        running.remove(targetID)
    }

    /// Records that the source has no more work for this plan. The target does not re-enter the
    /// runnable window, so planning cannot loop on it, and no history is touched (ADR-005 D8).
    public mutating func markFinished(_ targetID: AcquisitionTargetID, bindingRevision: UInt64) {
        running.remove(targetID)
        finished[targetID] = bindingRevision
    }

    /// Records an explicit degradation. It stays until a new demand rebuilds the frontier.
    public mutating func markDegraded(_ reason: FrontierDegradation) {
        degradation = reason
    }

    // MARK: - Reads

    public var degradationReason: FrontierDegradation? { degradation }

    /// Targets the source already ended, for one binding revision. Diagnostics only.
    public var finishedCount: Int { finished.count }

    public var eligibleCount: Int {
        ordered.reduce(0) { $0 + (finished[$1.id] == nil ? 1 : 0) }
    }

    public var head: [FrontierItem] { classification().head }
    public var active: [FrontierItem] { classification().active }
    public var exploration: [FrontierItem] { classification().exploration }

    /// The work window, in rank order: what the planner may turn into bounded work.
    public var runnableItems: [FrontierItem] {
        let classes = classification()
        return (classes.head + classes.active + classes.exploration).sorted { $0.rank < $1.rank }
    }

    public var runnableCount: Int { runnableItems.count }

    public var state: AcquisitionFrontierState {
        let eligible = eligibleCount
        if runnableCount > 0 { return .work(eligible: eligible, runnable: runnableCount) }
        if let degradation { return .degraded(degradation) }
        if eligible == 0 { return .exhausted }
        if let purpose { return .degraded(.budgetStop(purpose)) }
        return .exhausted
    }

    // MARK: - Classification

    private func classification() -> (head: [FrontierItem], active: [FrontierItem], exploration: [FrontierItem]) {
        var head: [FrontierItem] = []
        var active: [FrontierItem] = []
        var exploration: [FrontierItem] = []
        var rank = 0
        var considered = 0
        for target in ordered {
            if finished[target.id] != nil { continue }
            let itemRank = rank
            rank += 1
            considered += 1
            if considered > cap { break }
            if running.contains(target.id) {
                // A running target that overflows the active window keeps running; the frontier only
                // stops planning more work for this demand.
                guard active.count < bound.active else { continue }
                active.append(FrontierItem(target: target, rank: itemRank, workClass: .active))
            } else if head.count < bound.head {
                head.append(FrontierItem(target: target, rank: itemRank, workClass: .head))
            } else if exploration.count < bound.exploration {
                exploration.append(FrontierItem(target: target, rank: itemRank, workClass: .exploration))
            }
        }
        return (head, active, exploration)
    }
}
