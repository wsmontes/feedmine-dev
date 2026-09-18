import Foundation
import FeedDomain

/// The editorial order, its limit, the provider/cluster quota and the bounded-repetition rule
/// (plan §8, ADR-007 D13).
///
/// The sequencer never re-orders: it walks the draft's `choices` exactly as the engine ranked them
/// (normalized score, then timestamp, then stable key) and decides only *admission*. Media preparation
/// and publication preserve this order.
///
/// Repetition is bounded by a defined window and counter, and requires a *distinct* published
/// occurrence. It is forbidden outright when the plan asked for unseen content. When supply is short the
/// sequencer publishes a smaller segment and reports the shortfall: it never loops cards to fill the
/// requested count, because an honest exhaustion is better than a loop of duplicates (plan §8).
public struct EditorialSequencer: Sendable {
    public init() {}

    /// Composes the segment plan for one draft and one published history.
    ///
    /// - Parameters:
    ///   - draft: the pool, already ranked by `SelectionOrderKey`.
    ///   - history: the published occurrences the plan may look back at, oldest first. The repetition
    ///     window is the last `repetitionPolicy.window` entries of that array.
    public func sequence(
        draft: SelectionDraft,
        plan: ResolvedFeedPlan,
        history: PublishedHistory = .empty
    ) -> EditorialSequence {
        let budget = plan.budget
        let repetition = plan.repetitionPolicy
        let asksForUnseen = plan.freshnessDemand == .unseen
        let window = Array(history.occurrences.suffix(repetition.window))
        var windowCounts: [SupplyStableKey: Int] = [:]
        for occurrence in window {
            windowCounts[occurrence.stableKey, default: 0] += 1
        }
        var windowEdition: [SupplyStableKey: EditionID] = [:]
        for occurrence in window where windowEdition[occurrence.stableKey] == nil {
            windowEdition[occurrence.stableKey] = occurrence.editionID
        }

        // A cluster publishes one card unless repetition explicitly allows a distinct occurrence.
        let clusterOccurrenceAllowance = (!asksForUnseen && repetition.allowsDistinctOccurrence)
            ? repetition.limit
            : 1

        var cards: [PlannedCard] = []
        var deferredByQuota: [SelectionChoice] = []
        var quotaUsed: [QuotaKey: Int] = [:]
        var clusterUsed: [SupplyStableKey: Int] = [:]
        var repetitionsSuppressed = 0
        var unseenSuppressed = 0
        var clustersCollapsed = 0

        for choice in draft.choices {
            if cards.count == budget.cardLimit { break }

            let occurrences = windowCounts[choice.stableKey, default: 0]
            if occurrences > 0 {
                if asksForUnseen {
                    unseenSuppressed += 1
                    continue
                }
                if !repetition.allowsDistinctOccurrence || occurrences >= repetition.limit {
                    repetitionsSuppressed += 1
                    continue
                }
            }
            if clusterUsed[choice.clusterKey, default: 0] >= clusterOccurrenceAllowance {
                clustersCollapsed += 1
                continue
            }
            if quotaUsed[choice.candidate.quotaKey, default: 0] >= budget.providerQuota {
                deferredByQuota.append(choice)
                continue
            }

            quotaUsed[choice.candidate.quotaKey, default: 0] += 1
            clusterUsed[choice.clusterKey, default: 0] += 1
            cards.append(
                card(
                    ordinal: cards.count,
                    choice: choice,
                    occurrences: occurrences,
                    previousEdition: windowEdition[choice.stableKey]
                )
            )
        }

        var quotaAdmitted = 0
        if cards.count < budget.cardLimit {
            for choice in deferredByQuota {
                if cards.count == budget.cardLimit { break }
                cards.append(
                    card(
                        ordinal: cards.count,
                        choice: choice,
                        occurrences: windowCounts[choice.stableKey, default: 0],
                        previousEdition: windowEdition[choice.stableKey]
                    )
                )
                quotaAdmitted += 1
            }
        }

        let counts = EditorialSequenceCounts(
            clustersCollapsed: clustersCollapsed,
            repetitionsSuppressed: repetitionsSuppressed,
            unseenSuppressed: unseenSuppressed,
            quotaDeferred: deferredByQuota.count,
            quotaAdmitted: quotaAdmitted
        )
        return EditorialSequence(
            context: draft.context,
            editorialRevision: draft.editorialRevision,
            seed: draft.seed,
            status: Self.status(
                published: cards.count,
                requested: budget.cardLimit,
                draft: draft,
                repetitionsSuppressed: repetitionsSuppressed,
                unseenSuppressed: unseenSuppressed,
                clustersCollapsed: clustersCollapsed
            ),
            cards: cards,
            counts: counts,
            relaxations: cards.flatMap { $0.choice.relaxationReasons }
        )
    }

    private func card(
        ordinal: Int,
        choice: SelectionChoice,
        occurrences: Int,
        previousEdition: EditionID?
    ) -> PlannedCard {
        PlannedCard(
            ordinal: ordinal,
            choice: choice,
            isRepeatOccurrence: occurrences > 0,
            previousOccurrenceEdition: occurrences > 0 ? previousEdition : nil
        )
    }

    /// ADR-007 D13: a short segment is a state, reported with the reason it fell short.
    static func status(
        published: Int,
        requested: Int,
        draft: SelectionDraft,
        repetitionsSuppressed: Int,
        unseenSuppressed: Int,
        clustersCollapsed: Int
    ) -> SegmentStatus {
        guard published > 0 else { return .exhausted }
        guard published < requested else { return .complete }
        if draft.supplyExhausted {
            return .partial(.supplyExhausted(published: published, requested: requested))
        }
        if draft.readReport.scanBudgetReached {
            return .partial(.scanBudgetReached(published: published, requested: requested))
        }
        if repetitionsSuppressed + unseenSuppressed + clustersCollapsed > 0 {
            return .partial(.repetitionSuppressed(published: published, requested: requested))
        }
        return .partial(.eligibilityFiltered(published: published, requested: requested))
    }
}
