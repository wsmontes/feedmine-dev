import Foundation
import FeedDomain
import FeedStorage

/// Local Selection: hard eligibility, a bounded pool, editorial ranking and deterministic tie-breaks
/// (plan §8).
///
/// The engine reads supply through the concrete repository and evaluates *only* the values its plan's
/// revision fingerprints: the same supply snapshot, the same projections, the same plan, the same clock
/// and the same versions produce the same draft byte for byte, in this process or another one. Nothing
/// here reads a connector, evidence, a wire format or a raw payload.
///
/// Hard eligibility never relaxes. `blockedStableKeys`, a disabled source, a mandatory content filter,
/// a content restriction and the plan's own `seen` exclusion remove a candidate from the pool; there is
/// no code path that admits one of them back. Relaxation exists only for preferences marked `soft`, and
/// every relaxation is recorded on the choice that used it.

public enum SelectionError: Error, Equatable, Sendable {
    /// The plan's revision cannot be reproduced from the plan and the projections the engine is about
    /// to evaluate. Evaluating anyway would mean deciding with inputs the revision does not name.
    case revisionNotReproducible(expected: String, recomputed: String)
}

public struct SelectionEngine: Sendable {
    private let repository: SelectionSupplyRepository

    public init(repository: SelectionSupplyRepository = SelectionSupplyRepository()) {
        self.repository = repository
    }

    /// Selects the candidate pool for one plan.
    ///
    /// - Parameters:
    ///   - plan: the resolved plan; its `sourceSelection`, budget and history policy drive the read.
    ///   - projections: the plan-relevant catalog and user-state projections the revision was computed
    ///     from. The engine refuses to run when they no longer reproduce the revision.
    ///   - seed: per-edition randomness for the declared exploration weight, carried into the draft.
    public func draft(
        plan: ResolvedFeedPlan,
        projections: PlanProjections,
        seed: Data,
        in database: RuntimeDatabase
    ) throws -> SelectionDraft {
        let recomputed = try FeedPlanResolver.recomputedRevision(of: plan, projections: projections)
        guard recomputed == plan.editorialRevision else {
            throw SelectionError.revisionNotReproducible(
                expected: plan.editorialRevision.digest,
                recomputed: recomputed.digest
            )
        }
        let walk = try walk(plan: plan, projections: projections, seed: seed, in: database)
        return Self.assemble(
            plan: plan,
            seed: seed,
            walk: walk,
            supplyGeneration: try repository.supplyGeneration(in: database)
        )
    }

    // MARK: - The bounded walk

    struct Kept {
        let candidate: SupplyCandidate
        let score: SelectionScore
        let orderKey: SelectionOrderKey
        /// The soft rules this candidate did not satisfy, sorted and ready for the choice.
        let relaxations: [RelaxationReason]
    }

    enum Verdict {
        case rejected
        case strict(Kept)
        /// Admissible only under relaxation: it failed a preference marked `soft`.
        case soft(Kept)
    }

    struct Walk {
        var strict: [Kept] = []
        var soft: [Kept] = []
        var quotaKeys: Set<QuotaKey> = []
        var clusterEdges: [SupplyClusterEdge] = []
        var pages = 0
        var steps = 0
        var examinedRows = 0
        var stepWindowRows: [Int] = []
        var exhausted = false
        var scanBudgetReached = false
        var queryPlan: [String] = []
    }

    private func walk(
        plan: ResolvedFeedPlan,
        projections: PlanProjections,
        seed: Data,
        in database: RuntimeDatabase
    ) throws -> Walk {
        let budget = plan.budget
        var walk = Walk()
        var cursor: Int64? = nil
        let excludedKeys = Set(
            plan.historyPolicy.applySeen ? projections.userState.exclusionKeys : []
        )

        while walk.steps < budget.maxScanSteps {
            let windowRows = budget.scanRowsPerStep * (1 << walk.steps)
            let page = try repository.page(
                SupplyPageRequest(
                    sourceSelection: plan.plan.sourceSelection,
                    subjectSelection: plan.plan.subjectSelection,
                    after: cursor,
                    windowRows: windowRows
                ),
                in: database
            )
            walk.steps += 1
            walk.pages += 1
            walk.examinedRows += page.examinedRows
            walk.stepWindowRows.append(windowRows)
            if !page.queryPlan.isEmpty { walk.queryPlan = page.queryPlan }
            cursor = page.nextCursor
            // The probe window did not fill: the supply ends inside this window, so there is nothing
            // further to read and the walk stops now.
            let windowEnded = page.exhausted
            walk.clusterEdges.append(contentsOf: page.clusterEdges)

            for candidate in page.candidates {
                switch Self.evaluate(
                    candidate,
                    plan: plan,
                    excludedKeys: excludedKeys,
                    seed: seed
                ) {
                case .rejected:
                    continue
                case let .strict(kept):
                    walk.strict.append(kept)
                    walk.quotaKeys.insert(kept.candidate.quotaKey)
                case let .soft(kept):
                    walk.soft.append(kept)
                }
            }
            if walk.soft.count > budget.poolLimit {
                walk.soft = Array(walk.soft.prefix(budget.poolLimit))
            }
            // The supply is exhausted only when the key range ended *and* the pool is still short: a range
            // that ends with more candidates than the pool limit is a filled pool, not an exhausted feed.
            walk.exhausted = windowEnded
                && (walk.strict.count + walk.soft.count) < budget.poolLimit

            if windowEnded { break }
            let material = walk.strict.count + walk.soft.count
            if material >= budget.poolLimit && walk.quotaKeys.count >= budget.diversityTarget { break }
            if walk.strict.count >= budget.poolLimit && walk.quotaKeys.count >= budget.diversityTarget { break }
        }
        walk.scanBudgetReached = !walk.exhausted && walk.steps >= budget.maxScanSteps
        return walk
    }

    // MARK: - Eligibility and scoring

    /// Hard eligibility first, then preferences. A rejected candidate is gone for this draft; there is
    /// no second chance for a hard rule (plan §8).
    static func evaluate(
        _ candidate: SupplyCandidate,
        plan: ResolvedFeedPlan,
        excludedKeys: Set<SupplyStableKey>,
        seed: Data
    ) -> Verdict {
        let body = plan.plan
        if body.blockedStableKeys.contains(candidate.stableKey) { return .rejected }
        if excludedKeys.contains(candidate.stableKey) { return .rejected }
        guard satisfiesRestrictions(candidate, body) else { return .rejected }
        guard satisfiesMandatoryFilters(candidate, body) else { return .rejected }

        var relaxations: [RelaxationReason] = []
        for filter in body.contentFilters where !filter.isMandatory {
            guard matchesAnyKeyword(filter, candidate: candidate) else { continue }
            relaxations.append(RelaxationReason(kind: .softFilter, policyID: filter.filterID))
        }

        var matched: [String] = []
        for preference in body.preferences.preferences {
            if satisfies(preference.facet, candidate: candidate) {
                matched.append(preference.preferenceID)
            } else {
                switch preference.relaxation {
                case .hard:
                    return .rejected
                case .soft:
                    relaxations.append(
                        RelaxationReason(kind: .softPreference, policyID: preference.preferenceID)
                    )
                }
            }
        }

        let bonus = body.preferences.preferences
            .filter { matched.contains($0.preferenceID) }
            .reduce(0) { $0 + $1.weight }
        let exploration = EditorialBias.value(
            seed: seed,
            stableKey: candidate.stableKey.canonical,
            weight: body.exploration.weight
        )
        let score = SelectionScore(
            preferenceBonus: bonus,
            explorationBonus: exploration,
            matchedPreferences: matched,
            isExploration: exploration > 0
        )
        let kept = Kept(
            candidate: candidate,
            score: score,
            orderKey: SelectionOrderKey(
                score: score.normalized,
                sortDate: candidate.sortDate,
                stableKey: candidate.stableKey
            ),
            relaxations: relaxations.sorted()
        )
        return relaxations.isEmpty ? .strict(kept) : .soft(kept)
    }

    static func satisfiesMandatoryFilters(_ candidate: SupplyCandidate, _ plan: FeedPlan) -> Bool {
        for filter in plan.contentFilters where filter.isMandatory {
            if matchesAnyKeyword(filter, candidate: candidate) { return false }
        }
        return true
    }

    static func matchesAnyKeyword(_ filter: ContentFilter, candidate: SupplyCandidate) -> Bool {
        let text = candidate.searchableText
        return filter.keywords.contains { text.contains($0.lowercased()) }
    }

    static func satisfiesRestrictions(_ candidate: SupplyCandidate, _ plan: FeedPlan) -> Bool {
        let text = candidate.searchableText
        for restriction in plan.contentRestrictions.restrictions {
            switch restriction.kind {
            case let .forbiddenKeyword(keyword):
                if text.contains(keyword.lowercased()) { return false }
            case let .requiredMediaRole(role):
                if !candidate.mediaRoles.contains(role) { return false }
            case let .forbiddenMediaRole(role):
                if candidate.mediaRoles.contains(role) { return false }
            case .requiresDeclaredAuthoredDate:
                if candidate.sortDateIsFallback { return false }
            }
        }
        return true
    }

    static func satisfies(_ facet: PreferenceFacet, candidate: SupplyCandidate) -> Bool {
        switch facet {
        case let .mediaRole(role):
            return candidate.mediaRoles.contains(role)
        case let .source(key):
            return candidate.sourceKey == key
        case let .provider(key):
            return candidate.providerKey == key
        case let .keyword(text):
            return candidate.searchableText.contains(text.lowercased())
        }
    }

    // MARK: - Pool assembly

    /// The pool: the quota is a composition rule for the *prefix*, so the first pass admits at most
    /// `providerQuota` cards per provider/cluster key, and the second pass admits the overflow — still
    /// strictly eligible. Only when those cannot fill the pool do soft preferences relax, and every
    /// admitted relaxation is recorded on the choice.
    static func assemble(
        plan: ResolvedFeedPlan,
        seed: Data,
        walk: Walk,
        supplyGeneration: UInt64
    ) -> SelectionDraft {
        let poolLimit = plan.budget.poolLimit
        let ordered = walk.strict.sorted { $0.orderKey < $1.orderKey }
        var quotaUsed: [QuotaKey: Int] = [:]
        var pool: [SelectionChoice] = []
        var overflow: [Kept] = []

        for kept in ordered {
            let key = kept.candidate.quotaKey
            if quotaUsed[key, default: 0] < plan.budget.providerQuota {
                quotaUsed[key, default: 0] += 1
                pool.append(choice(kept, reasons: []))
            } else {
                overflow.append(kept)
            }
            if pool.count == poolLimit { break }
        }

        let strictChoiceCount = walk.strict.count
        var quotaAdmitted = 0
        if pool.count < poolLimit {
            for kept in overflow.sorted(by: { $0.orderKey < $1.orderKey }) {
                pool.append(choice(kept, reasons: [
                    RelaxationReason(kind: .providerQuota, policyID: kept.candidate.quotaKey.canonical),
                ]))
                quotaAdmitted += 1
                if pool.count == poolLimit { break }
            }
        }
        if pool.count < poolLimit {
            for kept in walk.soft.sorted(by: { $0.orderKey < $1.orderKey }) {
                pool.append(choice(kept, reasons: kept.relaxations))
                if pool.count == poolLimit { break }
            }
        }

        let clusters = clusters(for: pool, edges: walk.clusterEdges)
        var clusterKeys: [SupplyStableKey: SupplyStableKey] = [:]
        for cluster in clusters {
            for member in cluster.members {
                clusterKeys[member] = cluster.key(for: member)
            }
        }
        let orderedPool = pool
            .map { choice in
                SelectionChoice(
                    candidate: choice.candidate,
                    score: choice.score,
                    orderKey: choice.orderKey,
                    clusterKey: clusterKeys[choice.stableKey] ?? choice.stableKey,
                    relaxationReasons: choice.relaxationReasons
                )
            }
            .sorted { $0.orderKey < $1.orderKey }

        return SelectionDraft(
            context: plan.context,
            editorialRevision: plan.editorialRevision,
            algorithmVersion: plan.plan.algorithmVersion,
            selectionSchemaVersion: plan.plan.selectionSchemaVersion,
            supplyGeneration: supplyGeneration,
            seed: seed,
            choices: orderedPool,
            clusters: clusters,
            readReport: SelectionReadReport(
                poolLimit: poolLimit,
                pages: walk.pages,
                steps: walk.steps,
                examinedRows: walk.examinedRows,
                stepWindowRows: walk.stepWindowRows,
                supplyExhausted: walk.exhausted,
                scanBudgetReached: walk.scanBudgetReached,
                queryPlan: walk.queryPlan
            ),
            strictChoiceCount: strictChoiceCount,
            supplyExhausted: walk.exhausted
        )
    }

    static func choice(_ kept: Kept, reasons: [RelaxationReason]) -> SelectionChoice {
        SelectionChoice(
            candidate: kept.candidate,
            score: kept.score,
            orderKey: kept.orderKey,
            clusterKey: kept.candidate.stableKey,
            relaxationReasons: reasons
        )
    }

    /// Pool-local clustering over the declared syndication edges (ADR-003 D13). The grouping is a
    /// relation: the records keep their own identity and revisions, and dropping the edges splits it.
    static func clusters(for pool: [SelectionChoice], edges: [SupplyClusterEdge]) -> [SupplyCluster] {
        guard !edges.isEmpty else { return [] }
        let members = Set(pool.map(\.stableKey))
        var parent: [SupplyStableKey: SupplyStableKey] = [:]
        for key in members { parent[key] = key }

        func find(_ key: SupplyStableKey) -> SupplyStableKey {
            var current = key
            while let next = parent[current], next != current {
                current = next
            }
            return current
        }

        for edge in edges where members.contains(edge.subject) && members.contains(edge.object) {
            let left = find(edge.subject)
            let right = find(edge.object)
            guard left != right else { continue }
            // The smaller durable key always wins, so the representative is stable.
            if left < right {
                parent[right] = left
            } else {
                parent[left] = right
            }
        }

        var grouped: [SupplyStableKey: [SupplyStableKey]] = [:]
        for key in members {
            grouped[find(key), default: []].append(key)
        }
        return grouped
            .filter { $0.value.count > 1 }
            .map { SupplyCluster(members: $0.value) }
            .sorted { lhs, rhs in
                (lhs.representative ?? lhs.members[0]) < (rhs.representative ?? rhs.members[0])
            }
    }
}
