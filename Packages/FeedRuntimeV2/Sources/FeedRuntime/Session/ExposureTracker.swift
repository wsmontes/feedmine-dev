import Foundation
import FeedDomain

/// The only component that turns viewport telemetry into exposure facts (ADR-007 D1–D9).
///
/// The rules it implements, in the order they constrain the code:
///
/// * **D1** — `seen` requires at least `minVisibleFraction` of the card's area for at least
///   `minDwellMs` of *credited* foreground dwell. Credit starts when the fraction *reaches* the
///   threshold, not when the card appeared, so a card that was half-off-screen for a minute and then
///   fully visible for a second is credited one second. Both knobs are configuration and every fact
///   records the `policy_version` that produced it.
/// * **D2** — a viewport observation is coalesced telemetry, not a queue. A plain sample inside
///   `coalesceWindowMs` of the last accepted one is folded (and counted), while a state transition —
///   an entry edge, a threshold crossing, a left edge — is never dropped.
/// * **D3** — an interval belongs to a `PublicationCardID`, not to a SwiftUI view: `viewAppeared` and
///   `viewDisappeared` exist precisely to prove that a rerender, an image materialization or a window
///   restore produce no fact and do not restart credited dwell.
/// * **D5** — every fact type is recorded separately. `centerCrossed` is weaker than `seen`; `opened`,
///   `read` and `bookmarked` are not inferred from an interval.
/// * **D6** — recording is never on the caller's critical path: facts accumulate in memory and are
///   handed to the caller in batches, which is why no method here performs I/O.
/// * **D7/D8** — every fact carries its idempotency key, `seen` is emitted once per visit, and a
///   revisit opens a new `visit_ordinal` with its own interval rather than duplicating a `seen`.
///
/// Time is the injected monotonic clock and nothing else (D15): arithmetic across two
/// `bootSessionID` values is refused by closing the interval at the last sample of the old boot.
public struct ExposureTracker: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// Baseline 72 tracked intervals: at most one per light reference the window holds.
        public static let baselineIntervalLimit = 72

        public static let baseline = Configuration(
            uncheckedPolicy: .baseline,
            maximumTrackedIntervals: baselineIntervalLimit
        )

        public let policy: ExposurePolicy
        public let maximumTrackedIntervals: Int

        public init(policy: ExposurePolicy, maximumTrackedIntervals: Int = baselineIntervalLimit) throws {
            guard maximumTrackedIntervals > 0 else {
                throw FeedWindowError.nonPositiveReferenceLimit(maximumTrackedIntervals)
            }
            self.policy = policy
            self.maximumTrackedIntervals = maximumTrackedIntervals
        }

        private init(uncheckedPolicy policy: ExposurePolicy, maximumTrackedIntervals: Int) {
            self.policy = policy
            self.maximumTrackedIntervals = maximumTrackedIntervals
        }
    }

    /// Counters for observability (plan §16). Every one of them is a fold or a rejection, never content.
    public struct Stats: Hashable, Sendable {
        public var acceptedSamples: Int = 0
        public var coalescedSamples: Int = 0
        public var crossThresholdTransitions: Int = 0
        public var refusedIntervals: Int = 0
        public var closedIntervals: Int = 0
        public var emittedFacts: Int = 0
        public var bootSessionResets: Int = 0
        public var duplicateObservations: Int = 0
    }

    /// What one interval looks like from outside, for tests and diagnostics.
    public struct IntervalSnapshot: Hashable, Sendable {
        public let cardID: PublicationCardID
        public let visitOrdinal: Int
        public let creditedDwellMs: Int64
        public let maxVisibleFraction: Double
        public let seenRecorded: Bool
        public let isOpen: Bool
        public let startMs: Int64
        public let qualifyingStartMs: Int64?
        public let lastSampleMs: Int64
    }

    private struct Interval: Sendable {
        let cardID: PublicationCardID
        let visitOrdinal: Int
        let startMs: Int64
        let bootSessionID: String
        /// When the credited window began: the entry instant if the card entered at or above the
        /// threshold, otherwise the up-crossing instant. `nil` while the card has never qualified.
        var qualifyingStartMs: Int64?
        var lastSampleMs: Int64
        var maxVisibleFraction: Double
        var lastAbove: Bool
        var seenRecorded: Bool
        var recordedDirections: Set<Int>
        var enteredRecorded: Bool
    }

    public private(set) var editionID: EditionID
    public let scope: HistoryScope
    public let configuration: Configuration
    public private(set) var stats = Stats()

    private let clock: any MonotonicClock
    private var intervals: [PublicationCardID: Interval] = [:]
    private var visitCounts: [PublicationCardID: Int] = [:]
    private var pendingFacts: [ExposureFact] = []
    private var pendingFactKeys: Set<String> = []
    private var lastFlushMs: Int64

    public init(
        edition: EditionID,
        scope: HistoryScope,
        clock: any MonotonicClock,
        configuration: Configuration = .baseline
    ) {
        self.editionID = edition
        self.scope = scope
        self.clock = clock
        self.configuration = configuration
        self.lastFlushMs = clock.nowMillis()
    }

    public var policy: ExposurePolicy { configuration.policy }
    public var pendingFactCount: Int { pendingFacts.count }
    public var activeIntervalCount: Int { intervals.count }
    public var trackedCardCount: Int { visitCounts.count }

    public func interval(forCardID cardID: PublicationCardID) -> IntervalSnapshot? {
        guard let interval = intervals[cardID] else { return nil }
        return snapshot(of: interval, isOpen: true)
    }

    // MARK: - View lifecycle (I-15: these produce nothing on purpose)

    /// A cell appeared. Deliberately not exposure, and deliberately not an anchor: a rerender,
    /// an image materialization and a window restore all call this, and none of them is a viewport
    /// observation (ADR-007 D3, invariant H-03).
    public mutating func viewAppeared(cardID: PublicationCardID) {}

    /// A cell disappeared for a view-level reason. Same rule as `viewAppeared`: no interval is closed
    /// here, because only a *viewport* edge, a lifecycle end or an edition swap closes one.
    public mutating func viewDisappeared(cardID: PublicationCardID) {}

    // MARK: - Viewport telemetry

    /// Submits one observation, coalescing it against the last accepted sample of that card.
    public mutating func submitViewport(_ observation: ViewportObservation) {
        reconcileBootSession()
        let now = clock.nowMillis()

        if observation.edge == .left {
            close(cardID: observation.cardID, at: now, reason: .leftViewport, fraction: observation.visibleFraction)
            return
        }

        if var interval = intervals[observation.cardID] {
            guard accept(observation, interval: &interval, now: now) else {
                stats.coalescedSamples += 1
                return
            }
            intervals[observation.cardID] = interval
            if observation.visibleFraction < policy.minVisibleFraction {
                // A sample below the threshold closes the interval: the card left the viewport, whether
                // or not the renderer sent a left edge. Credit stops at this accepted sample.
                close(
                    cardID: observation.cardID,
                    at: now,
                    reason: .leftViewport,
                    fraction: observation.visibleFraction
                )
                return
            }
            credit(interval: interval)
            return
        }

        // A sample (or an entry edge) for a card with no interval opens one. Membership is bounded:
        // the window holds at most 72 references, and a tracker asked for more refuses.
        guard intervals.count < configuration.maximumTrackedIntervals else {
            stats.refusedIntervals += 1
            return
        }
        let qualifies = observation.visibleFraction >= policy.minVisibleFraction
        let visit = visitCounts[observation.cardID, default: 0]
        let interval = Interval(
            cardID: observation.cardID,
            visitOrdinal: visit,
            startMs: now,
            bootSessionID: clock.bootSessionID,
            qualifyingStartMs: qualifies ? now : nil,
            lastSampleMs: now,
            maxVisibleFraction: observation.visibleFraction,
            lastAbove: qualifies,
            seenRecorded: false,
            recordedDirections: [],
            enteredRecorded: observation.edge == .entered
        )
        intervals[observation.cardID] = interval
        visitCounts[observation.cardID] = visit
        stats.acceptedSamples += 1
        if observation.edge == .entered {
            append(
                makeFact(
                    type: .viewportEntered,
                    cardID: observation.cardID,
                    visitOrdinal: visit,
                    observedAtMs: now,
                    maxVisibleFraction: observation.visibleFraction
                )
            )
        }
        credit(interval: interval)
    }

    /// The card's center passed the viewport center. A separate, weaker fact: it grants no `seen`.
    public mutating func centerCrossed(cardID: PublicationCardID, direction: Int) {
        guard direction >= -1, direction <= 1 else { return }
        reconcileBootSession()
        guard var interval = intervals[cardID] else { return }
        if interval.recordedDirections.contains(direction) {
            stats.duplicateObservations += 1
            return
        }
        interval.recordedDirections.insert(direction)
        intervals[cardID] = interval
        append(
            makeFact(
                type: .centerCrossed,
                cardID: cardID,
                visitOrdinal: interval.visitOrdinal,
                observedAtMs: clock.nowMillis(),
                maxVisibleFraction: interval.maxVisibleFraction,
                direction: direction
            )
        )
    }

    // MARK: - Semantic facts

    /// An explicit primary action. It never blocks the reader and does not imply `read` (D5/D6).
    public mutating func opened(cardID: PublicationCardID) {
        appendDurable(type: .opened, cardID: cardID, operationID: nil)
    }

    /// An explicit mark. `read` is never inferred from dwell, and it carries the durable operation id
    /// that owns it (ADR-007 D7).
    public mutating func read(cardID: PublicationCardID, operationID: String) {
        appendDurable(type: .read, cardID: cardID, operationID: operationID)
    }

    /// A bookmark intent, owned by the durable user-state store and mirrored as a fact.
    public mutating func bookmarked(cardID: PublicationCardID, wanted: Bool, operationID: String) {
        appendDurable(
            type: wanted ? .bookmarked : .bookmarkRemoved,
            cardID: cardID,
            operationID: operationID
        )
    }

    // MARK: - Closures

    /// Presentation objects were evicted. An interval closes with `windowEvicted`, credited only up to
    /// its last sample (ADR-007 D4).
    public mutating func cardsEvicted(_ cardIDs: [PublicationCardID]) {
        reconcileBootSession()
        let now = clock.nowMillis()
        for cardID in cardIDs {
            guard intervals[cardID] != nil else { continue }
            close(cardID: cardID, at: now, reason: .windowEvicted, fraction: nil)
        }
    }

    /// Background, interruption or session end: every open interval ends, and nothing is credited
    /// beyond the last coalesced sample (ADR-007 D3/D9).
    public mutating func endIntervals(reason: ExposureCloseReason) {
        let now = clock.nowMillis()
        for cardID in intervals.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            close(cardID: cardID, at: now, reason: reason, fraction: nil)
        }
    }

    /// A successor edition takes over: intervals of the previous edition close as `editionSwap`, and
    /// the visit namespace restarts because a new edition is a new interval namespace (ADR-007 D8).
    public mutating func swapEdition(to editionID: EditionID) {
        endIntervals(reason: .editionSwap)
        visitCounts.removeAll()
        self.editionID = editionID
    }

    // MARK: - Flush policy (D9)

    /// Whether the milestone policy says a batch is due: 20 facts or 500 ms, whichever comes first.
    public func flushDue() -> Bool {
        flushDue(nowMs: clock.nowMillis())
    }

    public func flushDue(nowMs: Int64) -> Bool {
        if pendingFacts.isEmpty { return false }
        if pendingFacts.count >= policy.flushFactCount { return true }
        return nowMs - lastFlushMs >= Int64(policy.flushIntervalMs)
    }

    /// Hands over the facts a milestone owes, and nothing when the milestone has not arrived.
    public mutating func drainAtMilestone() -> [ExposureFact] {
        guard flushDue() else { return [] }
        return drain()
    }

    /// Hands over every unconfirmed fact in one batch: the caller persists them in one transaction.
    ///
    /// A crash before the caller commits loses exactly these facts and nothing else: no fact is invented
    /// to replace them, and no dwell is credited beyond the last sample (ADR-007 H-14).
    public mutating func drain() -> [ExposureFact] {
        let batch = pendingFacts
        pendingFacts.removeAll(keepingCapacity: true)
        pendingFactKeys.removeAll(keepingCapacity: true)
        lastFlushMs = clock.nowMillis()
        return batch
    }

    // MARK: - Internals

    private mutating func accept(
        _ observation: ViewportObservation,
        interval: inout Interval,
        now: Int64
    ) -> Bool {
        let isAbove = observation.visibleFraction >= policy.minVisibleFraction

        if observation.edge == .entered {
            if interval.enteredRecorded {
                stats.duplicateObservations += 1
            }
            interval.enteredRecorded = true
            if isAbove, interval.qualifyingStartMs == nil {
                interval.qualifyingStartMs = now
            }
            interval.lastAbove = isAbove
            stats.acceptedSamples += 1
            interval.lastSampleMs = now
            interval.maxVisibleFraction = max(interval.maxVisibleFraction, observation.visibleFraction)
            return true
        }

        if isAbove != interval.lastAbove {
            // A threshold crossing is a transition: coalescing may not drop it (ADR-007 D2).
            stats.crossThresholdTransitions += 1
            stats.acceptedSamples += 1
            interval.lastAbove = isAbove
            // Credit starts now, never before the moment the card actually qualified (D1). A crossing
            // *down* keeps the start: the interval is about to close and its credited dwell is measured
            // from the instant the qualifying window opened.
            if isAbove { interval.qualifyingStartMs = now }
            interval.lastSampleMs = now
            interval.maxVisibleFraction = max(interval.maxVisibleFraction, observation.visibleFraction)
            return true
        }

        guard now - interval.lastSampleMs >= Int64(policy.coalesceWindowMs) else { return false }
        stats.acceptedSamples += 1
        interval.lastSampleMs = now
        interval.maxVisibleFraction = max(interval.maxVisibleFraction, observation.visibleFraction)
        return true
    }

    /// Grants `seen` when the credited window reaches the threshold. Once per visit, so a rerender
    /// cannot duplicate it.
    private mutating func credit(interval: Interval) {
        guard !interval.seenRecorded,
              interval.lastAbove,
              let qualifyingStart = interval.qualifyingStartMs
        else { return }
        let credited = interval.lastSampleMs - qualifyingStart
        guard credited >= Int64(policy.minDwellMs) else { return }
        var updated = interval
        updated.seenRecorded = true
        intervals[interval.cardID] = updated
        append(
            makeFact(
                type: .seen,
                cardID: interval.cardID,
                visitOrdinal: interval.visitOrdinal,
                observedAtMs: interval.lastSampleMs,
                dwellMs: credited,
                maxVisibleFraction: interval.maxVisibleFraction
            )
        )
    }

    private mutating func close(
        cardID: PublicationCardID,
        at now: Int64,
        reason: ExposureCloseReason,
        fraction: Double?
    ) {
        guard let interval = intervals.removeValue(forKey: cardID) else { return }
        // Credited dwell stops at the last coalesced sample: a close never credits unsampled time,
        // and never credits time before the card reached the threshold (ADR-007 D1, H-06).
        let credited = interval.qualifyingStartMs.map { max(0, interval.lastSampleMs - $0) }
        append(
            makeFact(
                type: .viewportLeft,
                cardID: cardID,
                visitOrdinal: interval.visitOrdinal,
                observedAtMs: interval.lastSampleMs,
                dwellMs: credited,
                maxVisibleFraction: max(interval.maxVisibleFraction, fraction ?? 0),
                closeReason: reason
            )
        )
        stats.closedIntervals += 1
        visitCounts[cardID] = interval.visitOrdinal + 1
    }

    /// A reboot between two samples invalidates the arithmetic: the interval ends at the last sample
    /// of the old boot and no `seen` is granted from across the boundary (ADR-007 D15 edge case).
    private mutating func reconcileBootSession() {
        let current = clock.bootSessionID
        let stale = intervals.values.filter { $0.bootSessionID != current }
        guard !stale.isEmpty else { return }
        stats.bootSessionResets += stale.count
        for interval in stale.sorted(by: { $0.cardID.rawValue < $1.cardID.rawValue }) {
            close(cardID: interval.cardID, at: interval.lastSampleMs, reason: .background, fraction: nil)
        }
    }

    /// `opened` has no durable operation id and is idempotent per edition; `read`/`bookmarked` are
    /// keyed by the durable operation that owns them, so a replay writes nothing (ADR-007 D7).
    private mutating func appendDurable(
        type: ExposureEventType,
        cardID: PublicationCardID,
        operationID: String?
    ) {
        if type == .opened {
            let key = ExposureFact.key(
                type: .opened,
                editionID: editionID,
                cardID: cardID,
                scope: scope,
                visitOrdinal: 0,
                direction: nil,
                userStateOperationID: nil
            )
            guard !pendingFactKeys.contains(key) else {
                stats.duplicateObservations += 1
                return
            }
            append(makeFact(type: .opened, cardID: cardID, visitOrdinal: 0, observedAtMs: clock.nowMillis()))
            return
        }
        guard let operationID, !operationID.isEmpty else { return }
        let key = ExposureFact.key(
            type: type,
            editionID: editionID,
            cardID: cardID,
            scope: scope,
            visitOrdinal: 0,
            direction: nil,
            userStateOperationID: operationID
        )
        guard !pendingFactKeys.contains(key) else {
            stats.duplicateObservations += 1
            return
        }
        append(
            makeFact(
                type: type,
                cardID: cardID,
                visitOrdinal: 0,
                observedAtMs: clock.nowMillis(),
                userStateOperationID: operationID
            )
        )
    }

    private mutating func append(_ fact: ExposureFact?) {
        guard let fact else { return }
        guard pendingFactKeys.insert(fact.factKey).inserted else {
            stats.duplicateObservations += 1
            return
        }
        pendingFacts.append(fact)
        stats.emittedFacts += 1
    }

    private func makeFact(
        type: ExposureEventType,
        cardID: PublicationCardID,
        visitOrdinal: Int,
        observedAtMs: Int64,
        dwellMs: Int64? = nil,
        maxVisibleFraction: Double? = nil,
        direction: Int? = nil,
        closeReason: ExposureCloseReason? = nil,
        userStateOperationID: String? = nil
    ) -> ExposureFact? {
        try? ExposureFact(
            type: type,
            editionID: editionID,
            cardID: cardID,
            scope: scope,
            visitOrdinal: visitOrdinal,
            bootSessionID: clock.bootSessionID,
            observedAtMs: observedAtMs,
            dwellMs: dwellMs,
            maxVisibleFraction: maxVisibleFraction,
            direction: direction,
            closeReason: closeReason,
            policyVersion: policy.version,
            userStateOperationID: userStateOperationID
        )
    }

    private func snapshot(of interval: Interval, isOpen: Bool) -> IntervalSnapshot {
        IntervalSnapshot(
            cardID: interval.cardID,
            visitOrdinal: interval.visitOrdinal,
            creditedDwellMs: interval.qualifyingStartMs.map { max(0, interval.lastSampleMs - $0) } ?? 0,
            maxVisibleFraction: interval.maxVisibleFraction,
            seenRecorded: interval.seenRecorded,
            isOpen: isOpen,
            startMs: interval.startMs,
            qualifyingStartMs: interval.qualifyingStartMs,
            lastSampleMs: interval.lastSampleMs
        )
    }
}
