import Foundation
import FeedDomain

/// The bounded materialization window of one feed screen (plan §11, ADR-007 D4).
///
/// Two bounds, deliberately different and both asserted as counts/bytes rather than as behaviour:
///
/// * **light references** — at most `maximumReferences` (baseline 72) rows, each a few scalars plus a
///   height and a byte estimate. A reference is not a decoded object;
/// * **decoded materialization** — a smaller set of rows, chosen nearest the viewport, whose
///   cumulative byte estimate stays inside `decodedByteBudget`.
///
/// Eviction here removes *presentation references only*. Nothing in this type writes to
/// `published_card`: a window shift can never remove published history, and the session pages the row
/// back by `absoluteOrdinal`.
///
/// The anchor is the reading position (`PublicationCardID` + `absoluteOrdinal` + fraction of the card
/// scrolled past). It is never an array index, it is pinned while it is set, and every shift reports
/// how much height was inserted or removed *before* it, so a renderer can move its content offset by
/// exactly that amount and keep the anchor visually where it was.
public struct FeedWindowConfiguration: Hashable, Sendable {
    /// The plan's starting point: 72 light references.
    public static let baselineReferenceLimit = 72
    public static let baselineDecodedByteBudget = 12 * 1024 * 1024

    public static let baseline = FeedWindowConfiguration(
        uncheckedMaximumReferences: baselineReferenceLimit,
        decodedByteBudget: baselineDecodedByteBudget,
        margin: 8
    )

    public let maximumReferences: Int
    public let decodedByteBudget: Int
    /// How many references beyond the viewport are kept on each side.
    public let margin: Int

    public init(maximumReferences: Int, decodedByteBudget: Int, margin: Int) throws {
        guard maximumReferences > 0 else {
            throw FeedWindowError.nonPositiveReferenceLimit(maximumReferences)
        }
        guard decodedByteBudget > 0 else {
            throw FeedWindowError.nonPositiveByteBudget(decodedByteBudget)
        }
        guard margin >= 0 else { throw FeedWindowError.negativeMargin(margin) }
        self.maximumReferences = maximumReferences
        self.decodedByteBudget = decodedByteBudget
        self.margin = margin
    }

    private init(uncheckedMaximumReferences maximumReferences: Int, decodedByteBudget: Int, margin: Int) {
        self.maximumReferences = maximumReferences
        self.decodedByteBudget = decodedByteBudget
        self.margin = margin
    }
}

public enum FeedWindowError: Error, Equatable, Sendable {
    case nonPositiveReferenceLimit(Int)
    case nonPositiveByteBudget(Int)
    case negativeMargin(Int)
}

/// One light reference: identity, order and the two costs of materializing it.
public struct FeedWindowReference: Hashable, Sendable, Identifiable {
    public let cardID: PublicationCardID
    public let absoluteOrdinal: Int
    public let editionID: EditionID
    /// Estimated row height in points. Only used to tell a renderer how much the content moved.
    public let estimatedHeight: Double
    /// Estimated bytes of the materialized card (text plus pinned media). Only used for the bound.
    public let decodedByteEstimate: Int

    public init(
        cardID: PublicationCardID,
        absoluteOrdinal: Int,
        editionID: EditionID,
        estimatedHeight: Double,
        decodedByteEstimate: Int
    ) {
        self.cardID = cardID
        self.absoluteOrdinal = absoluteOrdinal
        self.editionID = editionID
        self.estimatedHeight = estimatedHeight
        self.decodedByteEstimate = max(0, decodedByteEstimate)
    }

    public var id: PublicationCardID { cardID }
}

/// What one window change did, in the terms a renderer needs to correct its content offset.
public struct FeedWindowAdjustment: Hashable, Sendable {
    public let evictedCardIDs: [PublicationCardID]
    public let insertedBeforeAnchorHeight: Double
    public let removedBeforeAnchorHeight: Double
    /// Points to add to the content offset: `insertedBeforeAnchor - removedBeforeAnchor`.
    public let heightCompensationDelta: Double
    public let anchor: FeedWindowAnchor?
    public let materializationChanged: Bool

    public static let none = FeedWindowAdjustment(
        evictedCardIDs: [],
        insertedBeforeAnchorHeight: 0,
        removedBeforeAnchorHeight: 0,
        heightCompensationDelta: 0,
        anchor: nil,
        materializationChanged: false
    )
}

public struct FeedWindow: Sendable, Equatable {
    public struct Viewport: Hashable, Sendable, CustomStringConvertible {
        public let firstVisibleOrdinal: Int
        public let lastVisibleOrdinal: Int

        public init(firstVisibleOrdinal: Int, lastVisibleOrdinal: Int) {
            self.firstVisibleOrdinal = min(firstVisibleOrdinal, lastVisibleOrdinal)
            self.lastVisibleOrdinal = max(firstVisibleOrdinal, lastVisibleOrdinal)
        }

        public func contains(ordinal: Int) -> Bool {
            ordinal >= firstVisibleOrdinal && ordinal <= lastVisibleOrdinal
        }

        public var description: String { "viewport:\(firstVisibleOrdinal)...\(lastVisibleOrdinal)" }
    }

    public let configuration: FeedWindowConfiguration
    public private(set) var references: [FeedWindowReference]
    public private(set) var viewport: Viewport?
    public private(set) var anchor: FeedWindowAnchor?
    /// Accumulated height compensation the renderer still owes the content offset.
    public private(set) var heightCompensation: Double
    /// How many references this window has evicted over its life. Observability, not content.
    public private(set) var evictionCount: Int

    public init(configuration: FeedWindowConfiguration = .baseline) {
        self.configuration = configuration
        self.references = []
        self.viewport = nil
        self.anchor = nil
        self.heightCompensation = 0
        self.evictionCount = 0
    }

    // MARK: - Bounds

    public var referenceCount: Int { references.count }

    /// The subset that may be decoded right now: nearest the viewport, inside the byte budget.
    public var materializedCardIDs: [PublicationCardID] {
        var accumulated = 0
        var result: [PublicationCardID] = []
        for reference in orderedByViewportDistance() {
            if reference.decodedByteEstimate > 0,
               accumulated + reference.decodedByteEstimate > configuration.decodedByteBudget {
                continue
            }
            accumulated += reference.decodedByteEstimate
            result.append(reference.cardID)
        }
        return result
    }

    public var materializedByteCount: Int {
        var accumulated = 0
        for reference in orderedByViewportDistance() {
            if reference.decodedByteEstimate > 0,
               accumulated + reference.decodedByteEstimate > configuration.decodedByteBudget {
                continue
            }
            accumulated += reference.decodedByteEstimate
        }
        return accumulated
    }

    public var materializedCount: Int { materializedCardIDs.count }

    public var anchorIsMaterialized: Bool {
        guard let anchor else { return false }
        return references.contains { $0.cardID == anchor.cardID }
    }

    public func reference(forCardID cardID: PublicationCardID) -> FeedWindowReference? {
        references.first { $0.cardID == cardID }
    }

    public func contains(cardID: PublicationCardID) -> Bool {
        references.contains { $0.cardID == cardID }
    }

    public var tailOrdinal: Int? { references.last?.absoluteOrdinal }

    // MARK: - Materialization

    /// Establishes the window from a full set of references (a restored edition, a fresh composition).
    ///
    /// This is the baseline: nothing was inserted or removed before the anchor, so the accumulated
    /// compensation resets to zero. Everything the capacity does not allow (or the byte budget cannot
    /// hold) is simply not retained — never deleted from the publication.
    @discardableResult
    public mutating func materialize(
        _ candidates: [FeedWindowReference],
        viewport: Viewport,
        anchor: FeedWindowAnchor?
    ) -> FeedWindowAdjustment {
        let kept = Self.trim(
            merge(references: [], inserts: candidates),
            viewport: viewport,
            anchorCardID: anchor?.cardID,
            capacity: configuration.maximumReferences,
            margin: configuration.margin
        )
        let changed = kept.map(\.cardID) != references.map(\.cardID)
        references = kept
        self.viewport = viewport
        self.anchor = anchor
        heightCompensation = 0
        evictionCount = 0
        return FeedWindowAdjustment(
            evictedCardIDs: [],
            insertedBeforeAnchorHeight: 0,
            removedBeforeAnchorHeight: 0,
            heightCompensationDelta: 0,
            anchor: anchor,
            materializationChanged: changed
        )
    }

    /// Moves the viewport, optionally materializing refs that were only now read from storage.
    ///
    /// The anchor is not recomputed here: it changes only when the caller states a new one (from the
    /// renderer's observation or from a checkpoint), which is what makes "não perde a âncora" provable
    /// across eviction and re-materialization.
    @discardableResult
    public mutating func shift(
        to viewport: Viewport,
        inserting inserts: [FeedWindowReference] = []
    ) -> FeedWindowAdjustment {
        let previous = references
        let merged = merge(references: previous, inserts: inserts)
        let kept = Self.trim(
            merged,
            viewport: viewport,
            anchorCardID: anchor?.cardID,
            capacity: configuration.maximumReferences,
            margin: configuration.margin
        )

        let keptIDs = Set(kept.map(\.cardID))
        let previousIDs = Set(previous.map(\.cardID))
        let removed = previous.filter { !keptIDs.contains($0.cardID) }
        let inserted = kept.filter { !previousIDs.contains($0.cardID) }
        let anchorOrdinal = anchor?.absoluteOrdinal ?? Int.min

        let removedAbove = removed
            .filter { $0.absoluteOrdinal < anchorOrdinal }
            .reduce(0.0) { $0 + $1.estimatedHeight }
        let insertedAbove = inserted
            .filter { $0.absoluteOrdinal < anchorOrdinal }
            .reduce(0.0) { $0 + $1.estimatedHeight }
        let delta = insertedAbove - removedAbove

        heightCompensation += delta
        evictionCount += removed.count
        references = kept
        self.viewport = viewport

        return FeedWindowAdjustment(
            evictedCardIDs: removed.map(\.cardID),
            insertedBeforeAnchorHeight: insertedAbove,
            removedBeforeAnchorHeight: removedAbove,
            heightCompensationDelta: delta,
            anchor: anchor,
            materializationChanged: keptIDs != previousIDs
        )
    }

    /// States where the reader is. The anchor is preserved across every shift until this is called.
    public mutating func setAnchor(_ anchor: FeedWindowAnchor?) {
        self.anchor = anchor
    }

    /// Drops the presentation objects while keeping the cursor (eviction, teardown of the renderer).
    ///
    /// This is exactly the operation ADR-007 D4 describes: eviction alone produces no fact and no
    /// removed history, and the anchor survives it.
    @discardableResult
    public mutating func releaseMaterializedContent() -> FeedWindowAdjustment {
        let removed = references
        references = []
        viewport = nil
        evictionCount += removed.count
        return FeedWindowAdjustment(
            evictedCardIDs: removed.map(\.cardID),
            insertedBeforeAnchorHeight: 0,
            removedBeforeAnchorHeight: 0,
            heightCompensationDelta: 0,
            anchor: anchor,
            materializationChanged: !removed.isEmpty
        )
    }

    // MARK: - Internals

    /// The distance of an ordinal from the viewport, in cards. Zero inside the viewport.
    private func distance(of reference: FeedWindowReference) -> Int {
        guard let viewport else { return reference.absoluteOrdinal }
        if viewport.contains(ordinal: reference.absoluteOrdinal) { return 0 }
        if reference.absoluteOrdinal < viewport.firstVisibleOrdinal {
            return viewport.firstVisibleOrdinal - reference.absoluteOrdinal
        }
        return reference.absoluteOrdinal - viewport.lastVisibleOrdinal
    }

    private func orderedByViewportDistance() -> [FeedWindowReference] {
        references.sorted {
            let left = distance(of: $0)
            let right = distance(of: $1)
            if left != right { return left < right }
            if $0.absoluteOrdinal != $1.absoluteOrdinal { return $0.absoluteOrdinal < $1.absoluteOrdinal }
            return $0.cardID.rawValue < $1.cardID.rawValue
        }
    }

    private func merge(
        references: [FeedWindowReference],
        inserts: [FeedWindowReference]
    ) -> [FeedWindowReference] {
        var byCardID: [PublicationCardID: FeedWindowReference] = [:]
        for reference in references { byCardID[reference.cardID] = reference }
        for reference in inserts where byCardID[reference.cardID] == nil {
            byCardID[reference.cardID] = reference
        }
        return byCardID.values.sorted {
            if $0.absoluteOrdinal != $1.absoluteOrdinal { return $0.absoluteOrdinal < $1.absoluteOrdinal }
            return $0.cardID.rawValue < $1.cardID.rawValue
        }
    }

    /// Keeps the rows inside the viewport margin and the anchor row, then fills to capacity.
    private static func trim(
        _ candidates: [FeedWindowReference],
        viewport: Viewport,
        anchorCardID: PublicationCardID?,
        capacity: Int,
        margin: Int
    ) -> [FeedWindowReference] {
        func distance(_ reference: FeedWindowReference) -> Int {
            if viewport.contains(ordinal: reference.absoluteOrdinal) { return 0 }
            if reference.absoluteOrdinal < viewport.firstVisibleOrdinal {
                return viewport.firstVisibleOrdinal - reference.absoluteOrdinal
            }
            return reference.absoluteOrdinal - viewport.lastVisibleOrdinal
        }
        func isPinned(_ reference: FeedWindowReference) -> Bool {
            viewport.contains(ordinal: reference.absoluteOrdinal) || reference.cardID == anchorCardID
        }

        let lower = viewport.firstVisibleOrdinal - margin
        let upper = viewport.lastVisibleOrdinal + margin
        let inRange = candidates.filter {
            isPinned($0) || ($0.absoluteOrdinal >= lower && $0.absoluteOrdinal <= upper)
        }
        let ordered = inRange.sorted {
            let left = distance($0)
            let right = distance($1)
            if left != right { return left < right }
            if $0.absoluteOrdinal != $1.absoluteOrdinal { return $0.absoluteOrdinal < $1.absoluteOrdinal }
            return $0.cardID.rawValue < $1.cardID.rawValue
        }
        let pinned = ordered.filter(isPinned)
        let rest = ordered.filter { !isPinned($0) }
        var kept = Array(pinned.prefix(capacity))
        if kept.count < capacity {
            kept.append(contentsOf: rest.prefix(capacity - kept.count))
        }
        return kept.sorted {
            if $0.absoluteOrdinal != $1.absoluteOrdinal { return $0.absoluteOrdinal < $1.absoluteOrdinal }
            return $0.cardID.rawValue < $1.cardID.rawValue
        }
    }
}
