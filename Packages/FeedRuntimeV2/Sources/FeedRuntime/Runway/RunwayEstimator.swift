import FeedDomain
import Foundation

/// Which way the viewport moved between two observations. Derived from the ordinals, never stated by
/// the renderer: a signed velocity from the UI would be a second opinion about the same fact (plan §11).
public enum RunwayScrollDirection: String, Hashable, Sendable {
    case towardTail
    case towardHead
    case stationary
}

/// One stock, kept on its own. `isObserved` distinguishes "measured as empty" from "not measured":
/// the runway never reports availability it has not seen.
public struct RunwayStockAmount: Hashable, Sendable, CustomStringConvertible {
    public static let unobserved = RunwayStockAmount(count: 0, bytes: nil, isObserved: false)

    public let count: Int
    /// Bytes, when the stock is measured in bytes too. `nil` means the stock is only countable.
    public let bytes: Int?
    public let isObserved: Bool

    public init(count: Int, bytes: Int?, isObserved: Bool = true) {
        self.count = max(0, count)
        self.bytes = bytes
        self.isObserved = isObserved
    }

    public var isEmpty: Bool { count == 0 }

    public var description: String {
        guard isObserved else { return "unobserved" }
        guard let bytes else { return "\(count)" }
        return "\(count)/\(bytes)B"
    }
}

/// The five stocks of plan §12, deliberately not one metric.
///
/// * `canonical` — origin revisions admitted;
/// * `sequenceable` — supply rows eligible for this context (what a refill can consume);
/// * `mediaPrepared` — media decisions already prepared for those rows;
/// * `published` — cards frozen in the edition, the only stock the reader can actually reach;
/// * `decoded` — cards the window currently holds materialized.
///
/// They are never added together: a large canonical archive changes nothing about a reader's runway,
/// and a full decoded cache is not extra supply. The type states them side by side so no caller can
/// accidentally read a "total available".
public struct RunwayStocks: Hashable, Sendable {
    public let canonical: RunwayStockAmount
    public let sequenceable: RunwayStockAmount
    public let mediaPrepared: RunwayStockAmount
    public let published: RunwayStockAmount
    public let decoded: RunwayStockAmount

    public init(
        canonical: RunwayStockAmount,
        sequenceable: RunwayStockAmount,
        mediaPrepared: RunwayStockAmount,
        published: RunwayStockAmount,
        decoded: RunwayStockAmount
    ) {
        self.canonical = canonical
        self.sequenceable = sequenceable
        self.mediaPrepared = mediaPrepared
        self.published = published
        self.decoded = decoded
    }
}

/// What the reader's position and the window's bounded state say, in the cheap terms the runway
/// consumes (plan §11, §12).
///
/// It is built from the session's window — `init?(window:edition:speed:sampledAt:)` — so the runway
/// reads the one viewport authority instead of keeping its own. `speed` is a magnitude, in points per
/// second, as the renderer measures it; direction comes from the ordinals.
public struct RunwayViewportObservation: Hashable, Sendable {
    public let editionID: EditionID
    public let firstVisibleOrdinal: Int
    public let lastVisibleOrdinal: Int
    /// The last ordinal the *window* still holds a light reference for. This is the end of the runway
    /// in the reader's terms: the edition's own published tail is an offer fact (it costs a read), and
    /// conflating the two would make a trimmed window look like an exhausted edition.
    public let materializedTailOrdinal: Int
    /// Cards the window has materialized right now, and their estimated bytes.
    public let decodedCount: Int
    public let decodedBytes: Int
    public let speed: Double
    public let sampledAt: Date

    public init(
        editionID: EditionID,
        firstVisibleOrdinal: Int,
        lastVisibleOrdinal: Int,
        materializedTailOrdinal: Int,
        decodedCount: Int,
        decodedBytes: Int,
        speed: Double,
        sampledAt: Date
    ) {
        self.editionID = editionID
        self.firstVisibleOrdinal = firstVisibleOrdinal
        self.lastVisibleOrdinal = lastVisibleOrdinal
        self.materializedTailOrdinal = materializedTailOrdinal
        self.decodedCount = decodedCount
        self.decodedBytes = decodedBytes
        self.speed = speed
        self.sampledAt = sampledAt
    }

    /// Reads one observation out of the session's window. Nil when the window has no viewport yet:
    /// there is no position to describe, and inventing ordinal zero would be a second opinion.
    public init?(
        window: FeedWindow,
        edition: EditionID,
        speed: Double,
        sampledAt: Date
    ) {
        guard let viewport = window.viewport else { return nil }
        self.init(
            editionID: edition,
            firstVisibleOrdinal: viewport.firstVisibleOrdinal,
            lastVisibleOrdinal: viewport.lastVisibleOrdinal,
            materializedTailOrdinal: window.tailOrdinal ?? -1,
            decodedCount: window.materializedCount,
            decodedBytes: window.materializedByteCount,
            speed: speed,
            sampledAt: sampledAt
        )
    }

    /// Cards between the last visible ordinal and the end of the materialized window: the runway, in cards.
    public var distance: Int {
        max(0, materializedTailOrdinal - lastVisibleOrdinal)
    }
}

/// One expensive read of the offer: what a refill could still take, and what it cost to find out.
public struct RunwaySupplyRequest: Hashable, Sendable {
    public let editionID: EditionID
    public let context: ContextKey
    public let generation: UInt64
    public let observedAt: Date

    public init(editionID: EditionID, context: ContextKey, generation: UInt64, observedAt: Date) {
        self.editionID = editionID
        self.context = context
        self.generation = generation
        self.observedAt = observedAt
    }
}

/// The answer to one `RunwaySupplyRequest`, with the cost of producing it.
///
/// `examinedRows` is the measurement the plan asks for: a bounded pool read costs a stated number of
/// rows, and the runway reports it instead of hiding the query behind "it was fast".
public struct RunwaySupplyObservation: Hashable, Sendable {
    public let canonical: RunwayStockAmount
    public let sequenceable: RunwayStockAmount
    public let mediaPrepared: RunwayStockAmount
    /// Cards the edition has published. An edition fact, read with the rest of the offer.
    public let published: RunwayStockAmount
    public let supplyGeneration: UInt64
    public let examinedRows: Int

    public init(
        canonical: RunwayStockAmount,
        sequenceable: RunwayStockAmount,
        mediaPrepared: RunwayStockAmount,
        published: RunwayStockAmount,
        supplyGeneration: UInt64,
        examinedRows: Int
    ) {
        self.canonical = canonical
        self.sequenceable = sequenceable
        self.mediaPrepared = mediaPrepared
        self.published = published
        self.supplyGeneration = supplyGeneration
        self.examinedRows = max(0, examinedRows)
    }
}

/// The cheap estimate: what the last viewport observation means, term by term.
///
/// Every term is reported beside the result so a test can assert the arithmetic instead of the mood,
/// and so a future tuning can see which term carried the decision.
public struct RunwayVisualEstimate: Hashable, Sendable {
    /// The weighted sum before the direction discount and before clamping.
    public let raw: Double
    /// The value the decision uses: `raw`, discounted on a reversal, clamped to floor/ceiling.
    public let pressure: Double
    public let level: RunwayPressureLevel
    /// Whether this observation changed the level. The count of these is the oscillation evidence.
    public let levelChanged: Bool
    public let speedPressure: Double
    public let distancePressure: Double
    public let latencyPressure: Double
    public let speed: Double
    public let direction: RunwayScrollDirection
    /// Cards between the viewport and the published tail.
    public let distance: Int
    public let p95ReplenishmentLatencyMilliseconds: Double?
    public let editionID: EditionID
    public let sampledAt: Date

    public init(
        raw: Double,
        pressure: Double,
        level: RunwayPressureLevel,
        levelChanged: Bool,
        speedPressure: Double,
        distancePressure: Double,
        latencyPressure: Double,
        speed: Double,
        direction: RunwayScrollDirection,
        distance: Int,
        p95ReplenishmentLatencyMilliseconds: Double?,
        editionID: EditionID,
        sampledAt: Date
    ) {
        self.raw = raw
        self.pressure = pressure
        self.level = level
        self.levelChanged = levelChanged
        self.speedPressure = speedPressure
        self.distancePressure = distancePressure
        self.latencyPressure = latencyPressure
        self.speed = speed
        self.direction = direction
        self.distance = distance
        self.p95ReplenishmentLatencyMilliseconds = p95ReplenishmentLatencyMilliseconds
        self.editionID = editionID
        self.sampledAt = sampledAt
    }
}

/// The pure estimator behind the runway (plan §12).
///
/// Two kinds of state, and they cost very different things:
///
/// * the **cheap** state is updated by every viewport observation — the last ordinal (for direction),
///   the decoded stock the window stated, the hysteresis level, and the bounded latency window. No I/O,
///   no query, no await is reachable from `observe`;
/// * the **expensive** state is the offer: canonical, sequenceable, media-prepared and published stocks,
///   which only `apply(_ supply:)` writes, from one bounded read the controller performs on a relevant
///   change.
///
/// p95 is the nearest-rank percentile over a bounded ring of the most recent successful replenishment
/// latencies, measured with the injected clock.
public struct RunwayEstimator: Sendable {
    public private(set) var policy: RunwayPolicy
    public private(set) var level: RunwayPressureLevel = .comfortable
    /// How many times the level changed. This is the number a hysteresis test asserts is small.
    public private(set) var levelTransitions = 0
    /// How many cheap updates have run. One per viewport observation, by construction.
    public private(set) var cheapUpdates = 0
    public private(set) var lastEstimate: RunwayVisualEstimate?

    private var latencies: [Double] = []
    private var lastOrdinal: Int?
    private var lastObservation: RunwayViewportObservation?
    private var canonicalStock: RunwayStockAmount = .unobserved
    private var sequenceableStock: RunwayStockAmount = .unobserved
    private var mediaPreparedStock: RunwayStockAmount = .unobserved
    private var publishedStockAmount: RunwayStockAmount = .unobserved

    public init(policy: RunwayPolicy = .baseline) {
        self.policy = policy
    }

    // MARK: stocks

    /// The five stocks as they stand. Nothing here is ever summed.
    public var stocks: RunwayStocks {
        RunwayStocks(
            canonical: canonicalStock,
            sequenceable: sequenceableStock,
            mediaPrepared: mediaPreparedStock,
            published: publishedStockAmount,
            decoded: decodedStock
        )
    }

    private var decodedStock: RunwayStockAmount {
        guard let observation = lastObservation else { return .unobserved }
        return RunwayStockAmount(count: observation.decodedCount, bytes: observation.decodedBytes)
    }

    /// Whether an offer has been observed at all. Until it has, the runway promises nothing.
    public var hasObservedOffer: Bool { canonicalStock.isObserved || sequenceableStock.isObserved }

    // MARK: replenishment latency

    /// The bounded ring of recent replenishment latencies, oldest first.
    public var replenishmentLatencies: [Double] { latencies }

    /// Nearest-rank p95 over the samples held. `nil` until one successful replenishment is measured.
    public var p95ReplenishmentLatencyMilliseconds: Double? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// Records one measured replenishment latency. Older samples leave the window: the estimate must
    /// follow a network that just got slower, not an average of the whole session.
    public mutating func recordReplenishmentLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        latencies.append(milliseconds)
        let excess = latencies.count - policy.latencySampleLimit
        if excess > 0 { latencies.removeFirst(excess) }
    }

    // MARK: cheap update

    /// The viewport path: pure arithmetic over numbers already in hand.
    @discardableResult
    public mutating func observe(_ observation: RunwayViewportObservation) -> RunwayVisualEstimate {
        let direction = direction(for: observation)
        lastOrdinal = observation.lastVisibleOrdinal
        lastObservation = observation
        cheapUpdates += 1

        let speed = abs(observation.speed)
        let speedPressure = min(speed / policy.speedSaturation, 1)
        let distance = observation.distance
        let distancePressure = min(
            Double(policy.comfortableDistance - min(distance, policy.comfortableDistance))
                / Double(policy.comfortableDistance),
            1
        )
        let latency = p95ReplenishmentLatencyMilliseconds
        let latencyPressure: Double
        if let latency {
            latencyPressure = min(
                max((latency - policy.referenceLatencyMilliseconds) / policy.latencyToleranceMilliseconds, 0),
                1
            )
        } else {
            latencyPressure = 0
        }

        let speedTerm = policy.speedWeight * speedPressure
        let distanceTerm = policy.distanceWeight * distancePressure
        let latencyTerm = policy.latencyWeight * latencyPressure
        let raw = speedTerm + distanceTerm + latencyTerm
        // A reversal stops consuming the runway; it does not shorten it. Only the speed term is
        // discounted, so a short runway stays short while the reader backs away.
        let discountedSpeed = direction == .towardHead ? speedTerm * policy.reversalDiscount : speedTerm
        let pressure = policy.clamp(discountedSpeed + distanceTerm + latencyTerm)
        let nextLevel = policy.level(previous: level, estimate: pressure)
        let levelChanged = nextLevel != level
        if levelChanged {
            levelTransitions += 1
            level = nextLevel
        }

        let estimate = RunwayVisualEstimate(
            raw: raw,
            pressure: pressure,
            level: nextLevel,
            levelChanged: levelChanged,
            speedPressure: speedPressure,
            distancePressure: distancePressure,
            latencyPressure: latencyPressure,
            speed: speed,
            direction: direction,
            distance: distance,
            p95ReplenishmentLatencyMilliseconds: latency,
            editionID: observation.editionID,
            sampledAt: observation.sampledAt
        )
        lastEstimate = estimate
        return estimate
    }

    // MARK: expensive update

    /// Writes the offer from one bounded read. Also the place a refill's consumption of the sequenceable
    /// pool shows up, without a second query.
    public mutating func apply(_ supply: RunwaySupplyObservation) {
        canonicalStock = supply.canonical
        sequenceableStock = supply.sequenceable
        mediaPreparedStock = supply.mediaPrepared
        publishedStockAmount = supply.published
    }

    /// One refill consumed this many rows out of the sequenceable pool. Bookkeeping, not a query.
    public mutating func consumeSequenceable(items: Int) {
        guard items > 0, sequenceableStock.isObserved else { return }
        sequenceableStock = RunwayStockAmount(
            count: max(0, sequenceableStock.count - items),
            bytes: sequenceableStock.bytes,
            isObserved: true
        )
    }

    public mutating func replacePolicy(_ policy: RunwayPolicy) {
        self.policy = policy
    }

    /// Forgets everything scoped to the surface the reader left: the position, the level, the published
    /// and decoded stocks, and the offer (which is per context *and* edition). The latency window
    /// survives, because replenishment latency describes the runtime, not the surface.
    public mutating func abandonViewport() {
        lastOrdinal = nil
        lastObservation = nil
        lastEstimate = nil
        level = .comfortable
        canonicalStock = .unobserved
        sequenceableStock = .unobserved
        mediaPreparedStock = .unobserved
        publishedStockAmount = .unobserved
    }

    private func direction(for observation: RunwayViewportObservation) -> RunwayScrollDirection {
        guard let lastOrdinal, observation.editionID == lastObservation?.editionID else {
            return .stationary
        }
        if observation.lastVisibleOrdinal > lastOrdinal { return .towardTail }
        if observation.lastVisibleOrdinal < lastOrdinal { return .towardHead }
        return .stationary
    }
}
