import Foundation
import FeedDomain

/// What the legacy path persisted for one item, as the comparison sees it.
///
/// The projection is deliberately small: the legacy item id, the source and the two fields the
/// runtime also stores (headline and link). Nothing about the user travels here — no read state, no
/// bookmark, no exposure.
struct ShadowLegacyItem: Equatable, Sendable {
    let legacyItemID: String
    let sourceURL: String
    let title: String
    let url: String
    let publishedAt: Date

    init(item: FeedItem) {
        self.legacyItemID = item.id
        self.sourceURL = item.sourceURL
        self.title = item.title
        self.url = item.url
        self.publishedAt = item.publishedAt
    }

    init(legacyItemID: String, sourceURL: String, title: String, url: String, publishedAt: Date) {
        self.legacyItemID = legacyItemID
        self.sourceURL = sourceURL
        self.title = title
        self.url = url
        self.publishedAt = publishedAt
    }
}

/// Why the shadow has nothing to compare for an item. This is the distinction the plan requires:
/// a gap in coverage is not a defect of the runtime.
enum ShadowMirrorGap: Equatable, Sendable {
    /// The shadow never saw an outcome for this source at all.
    case sourceNeverCovered
    /// The shadow observed this source and this item was not among what it mirrored.
    case itemMissingInCoveredSource
}

/// Which field the two sides disagreed on.
enum ShadowComparedField: String, Equatable, Sendable {
    case headline
    case link
}

/// A disagreement between the legacy side and the runtime's canonical state.
enum ShadowDivergence: Equatable, Sendable {
    /// The runtime already held a different payload under the same version key and refused to
    /// overwrite it (ADR-003 D11): the two sides genuinely disagree about that representation.
    case versionPayloadDivergence(legacyItemID: String)
    /// One version key was claimed by two records; neither moved (ADR-003 D12).
    case ambiguousAlias(legacyItemID: String)
    /// The runtime's current payload for the item is not what the legacy path persisted.
    case contentMismatch(legacyItemID: String, field: ShadowComparedField)

    var kind: String {
        switch self {
        case .versionPayloadDivergence: return "version_payload_divergence"
        case .ambiguousAlias: return "ambiguous_alias"
        case .contentMismatch(let _, let field): return "content_mismatch.\(field.rawValue)"
        }
    }
}

/// The answer for one legacy item.
enum ShadowVerdict: Equatable, Sendable {
    /// The runtime holds the same identity with the same headline and link.
    case matched
    /// The shadow has no counterpart. Not a divergence: nothing to disagree with.
    case notMirrored(ShadowMirrorGap)
    /// Both sides exist and disagree.
    case divergence(ShadowDivergence)
    /// The interval lost work or the shadow switched itself off, so its comparison is not evidence.
    case invalidInterval(ShadowIntervalID)

    var isDivergence: Bool {
        if case .divergence = self { return true }
        return false
    }

    var isInvalidInterval: Bool {
        if case .invalidInterval = self { return true }
        return false
    }
}

struct ShadowComparisonCounters: Equatable, Sendable {
    var matched = 0
    var notMirrored = 0
    var divergences = 0
    var invalidIntervalItems = 0
}

/// The comparison of one interval's legacy data against what the runtime canonicalized.
struct ShadowComparisonReport: Equatable, Sendable {
    /// One verdict per legacy item id.
    let verdicts: [String: ShadowVerdict]
    let counters: ShadowComparisonCounters
    /// Divergences by type, so a report can be read without walking every item.
    let divergencesByKind: [String: Int]
    /// Conflicts the runtime audited that no mirrored item could be attributed to. They are still
    /// divergences; they simply do not name a legacy id.
    let unattributedConflicts: [ShadowIdentityConflict]
    /// Coverage and cost of the intervals the comparison drew on.
    let coverage: ShadowCounters

    func verdict(forLegacyItemID legacyItemID: String) -> ShadowVerdict? {
        verdicts[legacyItemID]
    }
}

/// Compares what the legacy path persisted with what the runtime canonicalized (plan §13, PR-12).
///
/// The comparator is pure: the legacy side arrives as values and the runtime side as a
/// `ShadowCoverageReport` the bridge read back from the database. It never reads the legacy database
/// itself and never writes anything.
///
/// The three outcomes are kept apart on purpose:
/// - **`notMirrored`**: the shadow has no counterpart for the item. Either the shadow never covered
///   the source, or it covered it and did not mirror that item. Both are gaps in the shadow, not
///   defects of the runtime.
/// - **`divergence`**: the runtime holds something for the item and it disagrees with the legacy
///   side — a conflict it audited, or a current payload that is not what was persisted.
/// - **`invalidInterval`**: the interval dropped work or the shadow switched itself off, so nothing
///   in it may be called a divergence. A lossy interval must never make the runtime look wrong.
struct ShadowComparator {
    init() {}

    func compare(legacy: [ShadowLegacyItem], coverage: ShadowCoverageReport) -> ShadowComparisonReport {
        let invalidIntervals = coverage.invalidIntervals
        var verdicts: [String: ShadowVerdict] = [:]
        var counters = ShadowComparisonCounters()
        var divergencesByKind: [String: Int] = [:]
        var attributedConflicts: Set<Int> = []

        for item in legacy {
            let verdict = verdict(
                for: item,
                coverage: coverage,
                invalidIntervals: invalidIntervals,
                attributedConflicts: &attributedConflicts
            )
            verdicts[item.legacyItemID] = verdict
            switch verdict {
            case .matched:
                counters.matched += 1
            case .notMirrored:
                counters.notMirrored += 1
            case .divergence(let divergence):
                counters.divergences += 1
                divergencesByKind[divergence.kind, default: 0] += 1
            case .invalidInterval:
                counters.invalidIntervalItems += 1
            }
        }

        let unattributed = coverage.conflicts.enumerated()
            .filter { !attributedConflicts.contains($0.offset) }
            .map(\.element)
        for conflict in unattributed {
            divergencesByKind[conflict.kind, default: 0] += 1
        }
        counters.divergences += unattributed.count

        return ShadowComparisonReport(
            verdicts: verdicts,
            counters: counters,
            divergencesByKind: divergencesByKind,
            unattributedConflicts: unattributed,
            coverage: coverage.counters
        )
    }

    private func verdict(
        for item: ShadowLegacyItem,
        coverage: ShadowCoverageReport,
        invalidIntervals: Set<ShadowIntervalID>,
        attributedConflicts: inout Set<Int>
    ) -> ShadowVerdict {
        guard let mirrored = coverage.mirrored[item.legacyItemID] else {
            // Nothing was mirrored for this item. The interval that covered the source decides
            // whether the gap is a plain miss or a comparison that cannot be trusted.
            if let interval = coverage.interval(covering: item.sourceURL) {
                return invalidIntervals.contains(interval)
                    ? .invalidInterval(interval)
                    : .notMirrored(.itemMissingInCoveredSource)
            }
            return .notMirrored(.sourceNeverCovered)
        }

        // A conflict the runtime audited is its own evidence and does not depend on the shadow
        // having been complete, so it is checked before the interval's validity.
        if let conflict = matchingConflict(for: mirrored, in: coverage, attributedConflicts: &attributedConflicts) {
            switch conflict.kind {
            case "ambiguous_alias":
                return .divergence(.ambiguousAlias(legacyItemID: item.legacyItemID))
            default:
                return .divergence(.versionPayloadDivergence(legacyItemID: item.legacyItemID))
            }
        }

        if invalidIntervals.contains(mirrored.interval) {
            return .invalidInterval(mirrored.interval)
        }

        guard mirrored.recordID != nil else {
            return .notMirrored(.itemMissingInCoveredSource)
        }
        if let headline = mirrored.currentHeadline, headline != item.title {
            return .divergence(.contentMismatch(legacyItemID: item.legacyItemID, field: .headline))
        }
        if let link = mirrored.currentLink, link != item.url {
            return .divergence(.contentMismatch(legacyItemID: item.legacyItemID, field: .link))
        }
        return .matched
    }

    /// The conflict the runtime recorded for this very identity: same scope and the record the
    /// contradiction names. Attribution is by the record the runtime allocated, never by a digest and
    /// never by the legacy id (ADR-003 D8).
    private func matchingConflict(
        for mirrored: ShadowMirroredItem,
        in coverage: ShadowCoverageReport,
        attributedConflicts: inout Set<Int>
    ) -> ShadowIdentityConflict? {
        guard let recordID = mirrored.recordID else { return nil }
        for (index, conflict) in coverage.conflicts.enumerated()
        where conflict.scopeDescription == mirrored.scopeKey
            && conflict.existingRecordID == recordID {
            attributedConflicts.insert(index)
            return conflict
        }
        return nil
    }
}
