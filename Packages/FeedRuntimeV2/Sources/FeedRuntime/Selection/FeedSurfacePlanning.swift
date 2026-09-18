import Foundation
import FeedDomain

/// Resolution of the per-surface plans (plan §14 PR-14 item 1).
///
/// `FeedSurfaceCatalog` in `FeedDomain` owns the matrix as data: which surface resolves which
/// `ContextKey`, which `HistoryScope` it reads, and which acquisition it may use. Resolution needs the
/// resolver, which lives here, so this extension is the one place a surface's declared plan becomes a
/// `ResolvedFeedPlan` — and the ADR-007 D12 matrix is enforced by the resolver rather than by
/// convention.
extension FeedSurfaceCatalog {

    /// The surface's plan in resolved form. A surface whose row declares no context
    /// (`catalogueBrowse`) has no plan and is refused, not approximated.
    public static func resolvedPlan(
        _ surface: FeedSurface,
        inputs: Inputs,
        clock: any EditorialClock,
        runtimeSourceID: SourceID? = nil,
        projections: PlanProjections = .empty
    ) throws -> ResolvedFeedPlan {
        let plan = try plan(surface, inputs: inputs, runtimeSourceID: runtimeSourceID)
        return try FeedPlanResolver(clock: clock).resolve(plan, projections: projections)
    }

    /// Whether a card seen in `factScope` removes it from `surface`, computed through the surface's
    /// own resolved plan.
    ///
    /// This is the executable form of ADR-007 D12 for one pair, so a surface cannot answer the
    /// question with a rule of its own: the answer comes from the history policy the resolver
    /// accepted for that surface.
    public static func excludes(
        _ surface: FeedSurface,
        cardSeenIn factScope: HistoryScope,
        inputs: Inputs,
        clock: any EditorialClock,
        runtimeSourceID: SourceID? = nil
    ) throws -> Bool {
        let resolved = try resolvedPlan(
            surface,
            inputs: inputs,
            clock: clock,
            runtimeSourceID: runtimeSourceID
        )
        return HistoryScopeRules(policy: resolved.historyPolicy).excludes(cardSeenIn: factScope)
    }
}
