import Foundation
import FeedDomain

/// Turns a plan into its resolved form: canonical effective inputs plus the revision they fingerprint
/// (ADR-002 D2–D6, plan §8).
///
/// The resolver owns three things and nothing else:
///
/// 1. **Supported versions.** A plan that declares a plan/algorithm/selection schema this build does
///    not implement is refused, never interpreted (ADR-002 D5 applies the same rule to the revision
///    scheme).
/// 2. **Policy versioning.** Every declared `(policyID, version)` must name a policy the plan actually
///    carries, and must match the version inside that policy value. A value change without a version
///    bump is therefore a plan the resolver rejects instead of a silent revision collision.
/// 3. **The ADR-007 D12 history matrix.** A plan whose surface must not apply `seen` cannot declare
///    that it does; the matrix is enforced here, not left to convention.
///
/// The clock is read once, at resolve time, and only through the injected `EditorialClock` (D10).

public enum PlanResolutionError: Error, Equatable, Sendable {
    case unsupportedPlanSchemaVersion(Int)
    case unsupportedAlgorithmVersion(Int)
    case unsupportedSelectionSchemaVersion(Int)
    case missingPolicy(PolicyID)
    case duplicatePolicy(PolicyID)
    case policyVersionMismatch(PolicyID, declared: Int, embedded: Int)
    case duplicateSourceSelection(EditorialSourceKey)
    case unresolvedSourceKey(EditorialSourceKey)
    case duplicateFilterID(String)
    case duplicateRestrictionID(String)
    case duplicatePreferenceID(String)
    case duplicateBlockedKey(SupplyStableKey)
    case historyScopeSurfaceMismatch(HistoryScope, ContextKey.Surface)
    case historyScopeNotAllowedToApplySeen(HistoryScope)
}

public struct FeedPlanResolver: Sendable {
    private let clock: any EditorialClock

    public init(clock: any EditorialClock) {
        self.clock = clock
    }

    /// Plans a caller may build without opening storage: no projection, no clock read.
    public func resolve(_ plan: FeedPlan) throws -> ResolvedFeedPlan {
        try resolve(plan, projections: .empty)
    }

    public func resolve(_ plan: FeedPlan, projections: PlanProjections) throws -> ResolvedFeedPlan {
        try Self.validate(plan, projections: projections)
        let canonical = Self.canonicalPlan(plan)
        let bucket = canonical.clockPolicy.bucket(for: clock.now)
        let digests = projections.digests(readsUserState: canonical.historyPolicy.applySeen)
        let revision = try Self.revision(
            of: canonical,
            editorialClockBucket: bucket,
            relevantCatalogDigest: digests.catalog,
            relevantUserStateDigest: digests.userState
        )
        return ResolvedFeedPlan(
            plan: canonical,
            editorialRevision: revision,
            editorialClockBucket: bucket,
            relevantCatalogDigest: digests.catalog,
            relevantUserStateDigest: digests.userState
        )
    }

    /// The revision a set of effective inputs produces. Selection recomputes it from the projections it
    /// is about to evaluate, so a plan can never be evaluated under inputs other than the ones its
    /// revision names (ADR-002 D2).
    public static func revision(
        of plan: FeedPlan,
        editorialClockBucket: Int64,
        relevantCatalogDigest: String,
        relevantUserStateDigest: String
    ) throws -> EditorialRevision {
        try EditorialRevision(
            inputs: EditorialInputs(
                plan: plan,
                relevantCatalogDigest: relevantCatalogDigest,
                relevantUserStateDigest: relevantUserStateDigest,
                editorialClockBucket: editorialClockBucket
            )
        )
    }

    /// The revision of a resolved plan, recomputed from the plan and a set of projections. `nil` when
    /// the resolved plan does not carry a reproducible revision, which only a hand-built
    /// `ResolvedFeedPlan` can produce.
    public static func recomputedRevision(
        of resolved: ResolvedFeedPlan,
        projections: PlanProjections
    ) throws -> EditorialRevision {
        let digests = projections.digests(readsUserState: resolved.plan.historyPolicy.applySeen)
        return try revision(
            of: resolved.plan,
            editorialClockBucket: resolved.editorialClockBucket,
            relevantCatalogDigest: digests.catalog,
            relevantUserStateDigest: digests.userState
        )
    }

    // MARK: - Validation

    static func validate(_ plan: FeedPlan, projections: PlanProjections) throws {
        guard plan.planSchemaVersion == SelectionContract.planSchemaVersion else {
            throw PlanResolutionError.unsupportedPlanSchemaVersion(plan.planSchemaVersion)
        }
        guard plan.algorithmVersion == SelectionContract.algorithmVersion else {
            throw PlanResolutionError.unsupportedAlgorithmVersion(plan.algorithmVersion)
        }
        guard plan.selectionSchemaVersion == SelectionContract.schemaVersion else {
            throw PlanResolutionError.unsupportedSelectionSchemaVersion(plan.selectionSchemaVersion)
        }
        try validatePolicies(plan)
        try validateUniqueness(plan)
        try validateHistoryScope(plan)
        try Self.validateSourceResolution(plan, projections: projections)
    }

    private static func validatePolicies(_ plan: FeedPlan) throws {
        let embedded: [(PolicyID, Int)] = [
            (.budget, plan.budget.version),
            (.contentRestrictions, plan.contentRestrictions.version),
            (.preferences, plan.preferences.version),
            (.history, plan.historyPolicy.version),
            (.repetition, plan.repetitionPolicy.version),
            (.editorialClock, plan.clockPolicy.version),
        ]
        var declared: [PolicyID: Int] = [:]
        for policy in plan.policies {
            guard declared[policy.policyID] == nil else {
                throw PlanResolutionError.duplicatePolicy(policy.policyID)
            }
            declared[policy.policyID] = policy.version
        }
        for policy in plan.policies where !embedded.contains(where: { $0.0 == policy.policyID }) {
            // A declared policy no value carries is not a policy this plan implements.
            throw PlanResolutionError.policyVersionMismatch(
                policy.policyID,
                declared: policy.version,
                embedded: 0
            )
        }
        for (policyID, version) in embedded {
            guard let declaredVersion = declared[policyID] else {
                throw PlanResolutionError.missingPolicy(policyID)
            }
            guard declaredVersion == version else {
                throw PlanResolutionError.policyVersionMismatch(
                    policyID,
                    declared: declaredVersion,
                    embedded: version
                )
            }
        }
    }

    private static func validateUniqueness(_ plan: FeedPlan) throws {
        var sourceKeys: [String: EditorialSourceKey] = [:]
        for selection in plan.sourceSelection {
            let slot = "\(selection.sourceKey.catalogIdentity)@\(selection.sourceKey.canonicalizationVersion)"
            if let existing = sourceKeys[slot] {
                throw PlanResolutionError.duplicateSourceSelection(existing)
            }
            sourceKeys[slot] = selection.sourceKey
        }
        var filterIDs = Set<String>()
        for filter in plan.contentFilters where !filterIDs.insert(filter.filterID).inserted {
            throw PlanResolutionError.duplicateFilterID(filter.filterID)
        }
        var restrictionIDs = Set<String>()
        for restriction in plan.contentRestrictions.restrictions
            where !restrictionIDs.insert(restriction.restrictionID).inserted {
            throw PlanResolutionError.duplicateRestrictionID(restriction.restrictionID)
        }
        var preferenceIDs = Set<String>()
        for preference in plan.preferences.preferences
            where !preferenceIDs.insert(preference.preferenceID).inserted {
            throw PlanResolutionError.duplicatePreferenceID(preference.preferenceID)
        }
        var blocked = Set<SupplyStableKey>()
        for key in plan.blockedStableKeys where !blocked.insert(key).inserted {
            throw PlanResolutionError.duplicateBlockedKey(key)
        }
    }

    private static func validateHistoryScope(_ plan: FeedPlan) throws {
        let scope = plan.historyPolicy.scope
        guard scope.surface == plan.context.surface else {
            throw PlanResolutionError.historyScopeSurfaceMismatch(scope, plan.context.surface)
        }
        // ADR-007 D12: Bookmark, Source and Search never exclude by `seen`; Main, Collection and Smart
        // Feed may, per the surface's declared policy.
        guard !plan.historyPolicy.applySeen || scope.allowsSeenExclusion else {
            throw PlanResolutionError.historyScopeNotAllowedToApplySeen(scope)
        }
    }

    private static func validateSourceResolution(_ plan: FeedPlan, projections: PlanProjections) throws {
        let resolved = Set(projections.catalog.resolvedSources.map {
            "\($0.catalogIdentity)@\($0.canonicalizationVersion)"
        })
        for selection in plan.sourceSelection {
            let slot = "\(selection.sourceKey.catalogIdentity)@\(selection.sourceKey.canonicalizationVersion)"
            guard resolved.contains(slot) else {
                throw PlanResolutionError.unresolvedSourceKey(selection.sourceKey)
            }
        }
    }

    // MARK: - Canonical form

    /// Sorting is the resolver's job: the fingerprint must not depend on the order the caller listed
    /// sources, filters, languages or taxonomy URLs in (ADR-002 D3).
    static func canonicalPlan(_ plan: FeedPlan) -> FeedPlan {
        FeedPlan(
            context: plan.context,
            planSchemaVersion: plan.planSchemaVersion,
            policies: plan.policies.sorted { $0.policyID.rawValue < $1.policyID.rawValue },
            algorithmVersion: plan.algorithmVersion,
            selectionSchemaVersion: plan.selectionSchemaVersion,
            sourceSelection: SourceSelection.canonicalOrder(plan.sourceSelection),
            subjectSelection: plan.subjectSelection,
            presetIdentity: plan.presetIdentity,
            region: plan.region,
            contentType: plan.contentType,
            languages: plan.languages.sorted(),
            mood: plan.mood,
            contentFilters: ContentFilter.canonicalOrder(plan.contentFilters),
            taxonomyURLs: plan.taxonomyURLs.sorted(),
            blockedStableKeys: plan.blockedStableKeys.sorted(),
            contentRestrictions: plan.contentRestrictions,
            preferences: plan.preferences,
            budget: plan.budget,
            historyPolicy: plan.historyPolicy,
            repetitionPolicy: plan.repetitionPolicy,
            clockPolicy: plan.clockPolicy,
            freshnessDemand: plan.freshnessDemand,
            exploration: plan.exploration
        )
    }
}
