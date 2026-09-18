import Foundation
import FeedDomain

/// Why work is being done. Each purpose carries its own limits and its own cancellation rank, and
/// every request is attributed to exactly one purpose (ADR-005 D9; plan §20.3; `invariant 10`).
public enum AcquisitionPurpose: String, Hashable, Sendable, CaseIterable {
    /// A reader is waiting for this content. It keeps its limits under pressure and is never
    /// preempted by a lower purpose.
    case userInitiated
    /// Filling a first page. It ends at the minimum publication gate without waiting for the
    /// catalogue (ADR-005 D8).
    case bootstrap
    /// Serving a bounded supply deficit in front of the viewport.
    case activeRunway
    /// Warm-up that is nice to have. It is the first category cancelled under pressure and its
    /// budget may be zero (ADR-005 D9).
    case speculative
    /// Maintenance inside a background window. It must not start work without a resumable
    /// checkpoint.
    case backgroundMaintenance

    /// The purpose's budget in the baseline table.
    public var budget: PurposeBudget { AcquisitionBudgetTable.baseline[self] }
}

/// The limits one purpose has for one window: targets, requests, bytes, unique hosts, open
/// connections and wall clock (ADR-005 D9; `invariant 10`).
///
/// The numbers are tuning baselines, not contracts: ADR-005 D9 derives them from the technical
/// baseline of 4 active targets, 2 HTTP operations per host and 2 media transfers, and every one of
/// them is counted per purpose.
public struct PurposeBudget: Hashable, Sendable {
    public let targets: Int
    public let requests: Int
    public let bytes: Int
    public let hosts: Int
    public let connections: Int
    public let timeLimit: TimeInterval
    /// 1 is shed first, 5 last (ADR-005 D9). It is not a quality ranking.
    public let cancellationOrder: Int

    public init(
        targets: Int,
        requests: Int,
        bytes: Int,
        hosts: Int,
        connections: Int,
        timeLimit: TimeInterval,
        cancellationOrder: Int
    ) {
        self.targets = max(0, targets)
        self.requests = max(0, requests)
        self.bytes = max(0, bytes)
        self.hosts = max(0, hosts)
        self.connections = max(0, connections)
        self.timeLimit = max(0, timeLimit)
        self.cancellationOrder = cancellationOrder
    }

    /// A budget nothing can be done with: the zero budget `speculative` may carry.
    public static func zero(cancellationOrder: Int = 1) -> PurposeBudget {
        PurposeBudget(
            targets: 0, requests: 0, bytes: 0, hosts: 0, connections: 0,
            timeLimit: 0, cancellationOrder: cancellationOrder
        )
    }
}

/// The purpose budget table (ADR-005 D9 is its normative copy).
public struct AcquisitionBudgetTable: Hashable, Sendable {
    private let budgets: [AcquisitionPurpose: PurposeBudget]

    /// Starts from the baseline table and replaces the purposes given.
    public init(_ overrides: [AcquisitionPurpose: PurposeBudget] = [:]) {
        var table = Self.baselineNumbers
        for (purpose, budget) in overrides { table[purpose] = budget }
        self.budgets = table
    }

    /// A purpose with no entry has no budget at all, so nothing can be charged to it.
    public subscript(purpose: AcquisitionPurpose) -> PurposeBudget {
        budgets[purpose] ?? .zero()
    }

    public static let baseline = AcquisitionBudgetTable()

    private static let mebibyte = 1024 * 1024

    // Baseline of ADR-005 D9 / plan §20.3: 4 active targets, 2 HTTP operations per host and 2 media
    // transfers are the technical baseline these numbers derive from.
    private static let baselineNumbers: [AcquisitionPurpose: PurposeBudget] = [
        .userInitiated: PurposeBudget(
            targets: 4, requests: 24, bytes: 24 * mebibyte, hosts: 8, connections: 4,
            timeLimit: 20, cancellationOrder: 5
        ),
        .bootstrap: PurposeBudget(
            targets: 4, requests: 64, bytes: 48 * mebibyte, hosts: 16, connections: 4,
            timeLimit: 25, cancellationOrder: 4
        ),
        .activeRunway: PurposeBudget(
            targets: 2, requests: 8, bytes: 12 * mebibyte, hosts: 4, connections: 2,
            timeLimit: 15, cancellationOrder: 3
        ),
        .speculative: PurposeBudget(
            targets: 1, requests: 2, bytes: 4 * mebibyte, hosts: 2, connections: 1,
            timeLimit: 10, cancellationOrder: 1
        ),
        // `backgroundMaintenance` has no purpose-wide time limit of its own: the caller's deadline is
        // the remaining BGTask window (ADR-005 D9).
        .backgroundMaintenance: PurposeBudget(
            targets: 2, requests: 8, bytes: 8 * mebibyte, hosts: 2, connections: 1,
            timeLimit: .infinity, cancellationOrder: 2
        ),
    ]
}

/// What a purpose has already spent in its window.
///
/// Operations, bytes, unique hosts, redirects and open connections are counted per purpose
/// (ADR-005 D9, `invariant 10`). Redirects are counted by the connector that follows them; the
/// acquisition layer cannot see individual hops through an opaque configuration (D5).
public struct PurposeUsage: Hashable, Sendable {
    public var targets: Int
    public var requests: Int
    public var bytes: Int
    public var hosts: Int
    public var connections: Int

    public init(targets: Int = 0, requests: Int = 0, bytes: Int = 0, hosts: Int = 0, connections: Int = 0) {
        self.targets = targets
        self.requests = requests
        self.bytes = bytes
        self.hosts = hosts
        self.connections = connections
    }

    public static let zero = PurposeUsage()

    /// Whether the purpose can still afford one more request and one more byte.
    ///
    /// The runtime asks this before every pull. A budget stop is a normal outcome: it leaves the
    /// durable checkpoint where the work resumes (ADR-005 D9; `invariant 11`).
    public func hasRequestAndByteRoom(in budget: PurposeBudget) -> Bool {
        requests < budget.requests && bytes < budget.bytes
    }

    /// What is left of `budget`, or `nil` when the purpose cannot pay for one more unit of work.
    ///
    /// Every dimension has to have room for one more unit: one target, one request, one byte, one
    /// host and one connection. The byte dimension therefore stops the purpose at the last byte
    /// rather than overshooting it.
    public func remaining(in budget: PurposeBudget) -> PurposeBudget? {
        let targets = budget.targets - self.targets
        let requests = budget.requests - self.requests
        let bytes = budget.bytes - self.bytes
        let hosts = budget.hosts - self.hosts
        let connections = budget.connections - self.connections
        guard targets > 0, requests > 0, bytes > 0, hosts > 0, connections > 0 else { return nil }
        return PurposeBudget(
            targets: targets,
            requests: requests,
            bytes: bytes,
            hosts: hosts,
            connections: connections,
            timeLimit: budget.timeLimit,
            cancellationOrder: budget.cancellationOrder
        )
    }
}

/// How many more sequenceable items the context wants (ADR-005 D6).
public struct SupplyDeficit: Hashable, Sendable {
    public let items: Int

    public init(items: Int) {
        self.items = max(0, items)
    }
}

/// The demand's urgency. Higher runs sooner; it orders holders within one purpose when the runtime
/// has to shed work, and it never becomes an editorial quality score (ADR-005 D9, D18).
public struct DemandPriority: Hashable, Sendable, Comparable {
    public let urgency: Int

    public init(urgency: Int) {
        self.urgency = urgency
    }

    public static func < (lhs: DemandPriority, rhs: DemandPriority) -> Bool {
        lhs.urgency < rhs.urgency
    }
}

/// What a context asks for. Demand, not "start this target", is what the planner issues
/// (ADR-005 D6).
public struct AcquisitionDemand: Hashable, Sendable {
    public let purpose: AcquisitionPurpose
    /// The context, plan or edition that owns this interest. Releasing this holder's lease must not
    /// revoke another holder's interest in a shared target (ADR-005 D6, `invariant 4`).
    public let holderID: String
    public let priority: DemandPriority
    public let deficit: SupplyDeficit
    /// The caller's own deadline. The purpose may stop earlier (ADR-005 D9).
    public let deadline: Date

    public init(
        purpose: AcquisitionPurpose,
        holderID: String,
        priority: DemandPriority = DemandPriority(urgency: 0),
        deficit: SupplyDeficit,
        deadline: Date
    ) {
        self.purpose = purpose
        self.holderID = holderID
        self.priority = priority
        self.deficit = deficit
        self.deadline = deadline
    }
}

/// One holder's interest in one target, for one purpose.
///
/// It is coordination state, not durable state: the durable representation of "this target is in
/// use" is the target's own row and its lease epoch, which is what a late stream fails against
/// (ADR-005 D6; ADR-006 D1).
public struct AcquisitionLease: Hashable, Sendable {
    public let targetID: AcquisitionTargetID
    public let holderID: String
    public let purpose: AcquisitionPurpose
    public let priority: DemandPriority
    /// The generation observed when the lease was taken (ADR-005 D6).
    public let generation: UInt64
    public let bindingRevision: UInt64

    public init(
        targetID: AcquisitionTargetID,
        holderID: String,
        purpose: AcquisitionPurpose,
        priority: DemandPriority = DemandPriority(urgency: 0),
        generation: UInt64,
        bindingRevision: UInt64
    ) {
        self.targetID = targetID
        self.holderID = holderID
        self.purpose = purpose
        self.priority = priority
        self.generation = generation
        self.bindingRevision = bindingRevision
    }

    /// Lease identity as the runtime coordinates it: one holder may hold one lease per purpose on a
    /// target (ADR-005 D6, schema `UNIQUE (target_id, holder_id, purpose)`).
    public func sharesIdentity(with other: AcquisitionLease) -> Bool {
        targetID == other.targetID && holderID == other.holderID && purpose == other.purpose
    }
}

/// One bounded unit of work for one target.
public struct AcquisitionWorkItem: Hashable, Sendable {
    public let target: AcquisitionTarget
    public let workClass: FrontierWorkClass
    public let lease: AcquisitionLease
    /// The bound the connector and Admission both check: an oversized batch is split or stopped,
    /// never emitted (ADR-005 D4).
    public let limit: AcquisitionLimit
    /// How many observations this item may contribute to the deficit.
    public let observationBudget: Int

    public init(
        target: AcquisitionTarget,
        workClass: FrontierWorkClass,
        lease: AcquisitionLease,
        limit: AcquisitionLimit,
        observationBudget: Int
    ) {
        self.target = target
        self.workClass = workClass
        self.lease = lease
        self.limit = limit
        self.observationBudget = observationBudget
    }
}

/// Why a plan carries no work. A budget stop is a normal outcome, not an error: it leaves the durable
/// checkpoint where the work can resume (ADR-005 D9, `invariant 11`).
public enum AcquisitionPlanStop: Hashable, Sendable {
    /// The deficit is already met.
    case satisfied
    /// No eligible target has more work.
    case exhausted
    /// Supply exists but policy prevented fetching it.
    case degraded(FrontierDegradation)
    /// The purpose cannot pay for one more unit of work.
    case budgetStop(AcquisitionPurpose)
    /// The purpose's time budget or the caller's deadline passed.
    case deadlineReached
}

/// The bounded work one demand resolves into.
public struct AcquisitionPlan: Hashable, Sendable {
    public let purpose: AcquisitionPurpose
    public let holderID: String
    public let deadline: Date
    public let work: [AcquisitionWorkItem]
    public let stop: AcquisitionPlanStop?

    public init(
        purpose: AcquisitionPurpose,
        holderID: String,
        deadline: Date,
        work: [AcquisitionWorkItem],
        stop: AcquisitionPlanStop?
    ) {
        self.purpose = purpose
        self.holderID = holderID
        self.deadline = deadline
        self.work = work
        self.stop = stop
    }

    public var isStopped: Bool { stop != nil }
}

/// What one batch costs against a purpose's byte budget.
///
/// A batch has no byte count of its own, so the cost is derived from what it carries. The fixed
/// per-observation overhead is deliberate: this is the bound the purpose is charged, not a
/// measurement of what SQLite ends up storing.
public enum AcquisitionByteAccounting {
    public static func bytes(of batch: AcquisitionBatch) -> Int {
        var total = 0
        for observation in batch.observations {
            total += 64
            total += observation.externalKey.bytes.count
            total += observation.versionKey?.bytes.count ?? 0
            total += observation.payload.headline?.utf8.count ?? 0
            total += observation.payload.excerpt?.utf8.count ?? 0
            total += observation.payload.body?.utf8.count ?? 0
            total += observation.payload.link?.absoluteString.utf8.count ?? 0
        }
        for evidence in batch.evidence {
            total += evidence.bytes?.count ?? 0
        }
        return total
    }
}

/// Resolves a demand into bounded work: at most one item per runnable target, never more targets
/// than the purpose may pay for, and never anything at all when the deficit is met or the frontier
/// has nothing to offer.
///
/// The planner is a value type and touches nothing outside its arguments: usage comes in, a plan
/// goes out. That is what keeps a budget stop deterministic and testable with an injected clock.
public struct AcquisitionPlanner: Sendable {
    public let budgets: AcquisitionBudgetTable
    /// The observation ceiling one pull may not exceed (ADR-005 D4).
    public let itemCeiling: Int
    /// The byte ceiling one pull may not exceed (ADR-005 D4).
    public let byteCeiling: Int

    public init(
        budgets: AcquisitionBudgetTable = .baseline,
        itemCeiling: Int = 64,
        byteCeiling: Int = 4 * 1024 * 1024
    ) {
        self.budgets = budgets
        self.itemCeiling = max(1, itemCeiling)
        self.byteCeiling = max(1, byteCeiling)
    }

    public func plan(
        demand: AcquisitionDemand,
        frontier: AcquisitionFrontier,
        usage: PurposeUsage,
        now: Date
    ) -> AcquisitionPlan {
        let budget = budgets[demand.purpose]
        let deadline = min(now.addingTimeInterval(budget.timeLimit), demand.deadline)
        func stopped(_ reason: AcquisitionPlanStop) -> AcquisitionPlan {
            AcquisitionPlan(
                purpose: demand.purpose,
                holderID: demand.holderID,
                deadline: deadline,
                work: [],
                stop: reason
            )
        }

        guard demand.deficit.items > 0 else { return stopped(.satisfied) }
        // A purpose that cannot pay for one more unit of work is a budget stop, whatever else is
        // true: a zero budget is a policy answer, not an expired clock (ADR-005 D9).
        guard let remaining = usage.remaining(in: budget) else {
            return stopped(.budgetStop(demand.purpose))
        }
        guard now < deadline else { return stopped(.deadlineReached) }
        switch frontier.state {
        case .exhausted:
            return stopped(.exhausted)
        case .degraded(let reason):
            return stopped(.degraded(reason))
        case .work:
            break
        }

        let runnable = frontier.runnableItems
        // Never more targets than the deficit needs, and never more than the purpose can pay for.
        // One work item spends one target, one request, one host and one connection, so every one of
        // those dimensions caps the plan (ADR-005 D9; `invariant 10`).
        let wanted = min(demand.deficit.items, runnable.count)
        let count = min(
            wanted,
            remaining.targets,
            remaining.requests,
            remaining.hosts,
            remaining.connections
        )
        guard count > 0 else {
            return stopped(runnable.isEmpty ? .exhausted : .budgetStop(demand.purpose))
        }

        let window = runnable.prefix(count)
        let bytesPerItem = max(1, min(remaining.bytes / count, byteCeiling))
        let itemsPerItem = max(1, min((demand.deficit.items + count - 1) / count, itemCeiling))
        let limit = AcquisitionLimit(maxItems: itemsPerItem, maxBytes: bytesPerItem, deadline: deadline)
        let work = window.map { item in
            AcquisitionWorkItem(
                target: item.target,
                workClass: item.workClass,
                lease: AcquisitionLease(
                    targetID: item.target.id,
                    holderID: demand.holderID,
                    purpose: demand.purpose,
                    priority: demand.priority,
                    generation: item.target.generation,
                    bindingRevision: item.target.bindingRevision
                ),
                limit: limit,
                observationBudget: itemsPerItem
            )
        }
        return AcquisitionPlan(
            purpose: demand.purpose,
            holderID: demand.holderID,
            deadline: deadline,
            work: work,
            stop: work.isEmpty ? .exhausted : nil
        )
    }
}
