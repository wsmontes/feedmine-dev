import Foundation

/// Why the runway is asking for one more page (plan §12).
public enum RunwayRefillPurpose: String, Hashable, Sendable {
    /// The next page is content the reader will reach by continuing to scroll. It runs as ordinary
    /// work: resource pressure lowers its concurrency, but never cancels it (PR-08).
    case readerDemand
    /// The runway predicts the reader may reach the tail. It is registered as speculative work with
    /// `ResourceGovernor.startSpeculative`, so a memory warning cancels it before anything the reader
    /// is waiting for (plan §14 PR-08).
    case prefetch

    public var isSpeculative: Bool { self == .prefetch }
}

/// The two-state visual pressure. Deliberately a state and not a number: the estimator reports the
/// number, and the hysteresis band decides which state it means.
public enum RunwayPressureLevel: String, Hashable, Sendable {
    case comfortable
    case strained
}

/// What stopped one refill, and therefore what the edition's tail is worth afterwards (plan §19 #37).
///
/// The stop is reported by the refill itself, not inferred: an empty page is `exhausted`, a page that
/// filled its item/byte budget is `itemBudget`/`byteBudget`, and a cancelled or failed refill says so
/// instead of pretending nothing happened.
public enum RunwayRefillStop: String, Hashable, Sendable {
    case delivered
    case itemBudget
    case byteBudget
    /// The supply behind this context ran out. The tail is honest and the edition keeps its history.
    case exhausted
    case cancelled
    case failed

    /// Whether the refill committed anything the tail may advance over.
    public var advancedTheTail: Bool {
        switch self {
        case .delivered, .itemBudget, .byteBudget: return true
        case .exhausted, .cancelled, .failed: return false
        }
    }
}

/// A policy that would make the runway oscillate, stall or promise more than it can buffer is refused
/// at construction. These are shape constraints, not tuning: the numbers themselves are stated by the
/// composition (ResourceLimits' rule in ADR-004).
public enum RunwayPolicyError: Error, Equatable, Sendable {
    case floorOrCeilingOutOfRange(floor: Double, ceiling: Double)
    case hysteresisBandIsNotOrdered(escalation: Double, deescalation: Double)
    case nonPositiveSpeedSaturation(Double)
    case distanceHorizonIsNotOrdered(comfortable: Int, demand: Int)
    case latencyWindowIsNotUsable(referenceMilliseconds: Double, toleranceMilliseconds: Double)
    case weightsDoNotSumToOne(Double)
    case reversalDiscountOutOfRange(Double)
    case nonPositiveLimit(String, Int)
    case bufferBudgetBelowOneRefill(String)
}

/// The runway's thresholds, weights and buffers (plan §12).
///
/// Everything here is a number, and every decision the runway makes is a pure function of these
/// numbers plus the clock: no policy reads the device, the network or the database.
public struct RunwayPolicy: Hashable, Sendable {
    /// The pressure the estimate never falls below. A reader at the very head of an edition still
    /// reports the floor, so "no pressure" is a real, stated value instead of a zero that could also
    /// mean "not measured".
    public let floor: Double
    /// The pressure the estimate never exceeds. The ceiling is below 1 on purpose: pressure is a
    /// request for work, never a claim that the runway is broken.
    public let ceiling: Double
    /// From this estimate up, the level becomes `strained`.
    public let escalationThreshold: Double
    /// Down to this estimate, a `strained` level stays `strained`. The gap to `escalationThreshold` is
    /// the hysteresis band that a threshold-riding fling cannot oscillate through.
    public let deescalationThreshold: Double
    /// The scroll speed, in points per second, at which the speed term saturates.
    public let speedSaturation: Double
    /// Cards of runway at which the distance term reaches zero.
    public let comfortableDistance: Int
    /// Cards of runway at or below which the refill is reader demand instead of a prefetch.
    public let demandDistance: Int
    /// The replenishment latency, in milliseconds, at which the latency term starts to rise.
    public let referenceLatencyMilliseconds: Double
    /// The latency, in milliseconds, above `referenceLatencyMilliseconds` at which that term saturates.
    public let latencyToleranceMilliseconds: Double
    public let speedWeight: Double
    public let distanceWeight: Double
    public let latencyWeight: Double
    /// Multiplier applied to the *speed* term while the reader is moving back towards the head: a
    /// reversal is not a consumption of runway, so it lowers pressure without erasing the distance.
    public let reversalDiscount: Double
    /// How many recent replenishment latencies the p95 is computed over. Bounded, never a growing log.
    public let latencySampleLimit: Int
    /// Items one refill may deliver.
    public let itemLimitPerRefill: Int
    /// Bytes one refill may deliver.
    public let byteLimitPerRefill: Int
    /// Items that may be outstanding across every edition at once (the refill buffer, plan §12).
    public let bufferItemBudget: Int
    /// Bytes that may be outstanding across every edition at once.
    public let bufferByteBudget: Int
    /// How many times one tail checkpoint may be retried before the edition is reported degraded.
    public let maximumRefillAttempts: Int
    /// How long one refill may run before its own deadline.
    public let refillDeadlineMilliseconds: Int

    public init(
        floor: Double,
        ceiling: Double,
        escalationThreshold: Double,
        deescalationThreshold: Double,
        speedSaturation: Double,
        comfortableDistance: Int,
        demandDistance: Int,
        referenceLatencyMilliseconds: Double,
        latencyToleranceMilliseconds: Double,
        speedWeight: Double,
        distanceWeight: Double,
        latencyWeight: Double,
        reversalDiscount: Double,
        latencySampleLimit: Int,
        itemLimitPerRefill: Int,
        byteLimitPerRefill: Int,
        bufferItemBudget: Int,
        bufferByteBudget: Int,
        maximumRefillAttempts: Int,
        refillDeadlineMilliseconds: Int
    ) throws {
        guard floor >= 0, ceiling <= 1, floor <= ceiling else {
            throw RunwayPolicyError.floorOrCeilingOutOfRange(floor: floor, ceiling: ceiling)
        }
        guard deescalationThreshold >= 0, escalationThreshold <= 1,
              deescalationThreshold < escalationThreshold
        else {
            throw RunwayPolicyError.hysteresisBandIsNotOrdered(
                escalation: escalationThreshold,
                deescalation: deescalationThreshold
            )
        }
        guard speedSaturation > 0 else {
            throw RunwayPolicyError.nonPositiveSpeedSaturation(speedSaturation)
        }
        guard demandDistance >= 0, demandDistance <= comfortableDistance, comfortableDistance > 0 else {
            throw RunwayPolicyError.distanceHorizonIsNotOrdered(
                comfortable: comfortableDistance,
                demand: demandDistance
            )
        }
        guard referenceLatencyMilliseconds >= 0, latencyToleranceMilliseconds > 0 else {
            throw RunwayPolicyError.latencyWindowIsNotUsable(
                referenceMilliseconds: referenceLatencyMilliseconds,
                toleranceMilliseconds: latencyToleranceMilliseconds
            )
        }
        let weights = speedWeight + distanceWeight + latencyWeight
        guard speedWeight >= 0, distanceWeight >= 0, latencyWeight >= 0, abs(weights - 1) <= 0.0001 else {
            throw RunwayPolicyError.weightsDoNotSumToOne(weights)
        }
        guard reversalDiscount >= 0, reversalDiscount <= 1 else {
            throw RunwayPolicyError.reversalDiscountOutOfRange(reversalDiscount)
        }
        for (name, value) in [
            ("latencySampleLimit", latencySampleLimit),
            ("itemLimitPerRefill", itemLimitPerRefill),
            ("byteLimitPerRefill", byteLimitPerRefill),
            ("bufferItemBudget", bufferItemBudget),
            ("bufferByteBudget", bufferByteBudget),
            ("maximumRefillAttempts", maximumRefillAttempts),
            ("refillDeadlineMilliseconds", refillDeadlineMilliseconds),
        ] where value <= 0 {
            throw RunwayPolicyError.nonPositiveLimit(name, value)
        }
        // A buffer smaller than one refill could never admit anything, which would report every
        // edition as exhausted while supply exists.
        guard bufferItemBudget >= itemLimitPerRefill else {
            throw RunwayPolicyError.bufferBudgetBelowOneRefill("items")
        }
        guard bufferByteBudget >= byteLimitPerRefill else {
            throw RunwayPolicyError.bufferBudgetBelowOneRefill("bytes")
        }

        self.floor = floor
        self.ceiling = ceiling
        self.escalationThreshold = escalationThreshold
        self.deescalationThreshold = deescalationThreshold
        self.speedSaturation = speedSaturation
        self.comfortableDistance = comfortableDistance
        self.demandDistance = demandDistance
        self.referenceLatencyMilliseconds = referenceLatencyMilliseconds
        self.latencyToleranceMilliseconds = latencyToleranceMilliseconds
        self.speedWeight = speedWeight
        self.distanceWeight = distanceWeight
        self.latencyWeight = latencyWeight
        self.reversalDiscount = reversalDiscount
        self.latencySampleLimit = latencySampleLimit
        self.itemLimitPerRefill = itemLimitPerRefill
        self.byteLimitPerRefill = byteLimitPerRefill
        self.bufferItemBudget = bufferItemBudget
        self.bufferByteBudget = bufferByteBudget
        self.maximumRefillAttempts = maximumRefillAttempts
        self.refillDeadlineMilliseconds = refillDeadlineMilliseconds
    }

    /// The plan's starting point (§12): three terms that sum to one, a hysteresis band of 0.2, and a
    /// buffer of two refills. The numbers are tunable; the shape they must keep is the one `init`
    /// validates.
    public static let baseline = RunwayPolicy(
        uncheckedFloor: 0.05,
        ceiling: 0.95,
        escalationThreshold: 0.60,
        deescalationThreshold: 0.40,
        speedSaturation: 4_000,
        comfortableDistance: 24,
        demandDistance: 8,
        referenceLatencyMilliseconds: 150,
        latencyToleranceMilliseconds: 600,
        speedWeight: 0.35,
        distanceWeight: 0.40,
        latencyWeight: 0.25,
        reversalDiscount: 0.25,
        latencySampleLimit: 64,
        itemLimitPerRefill: 24,
        byteLimitPerRefill: 2 * 1024 * 1024,
        bufferItemBudget: 48,
        bufferByteBudget: 4 * 1024 * 1024,
        maximumRefillAttempts: 3,
        refillDeadlineMilliseconds: 10_000
    )

    private init(
        uncheckedFloor floor: Double,
        ceiling: Double,
        escalationThreshold: Double,
        deescalationThreshold: Double,
        speedSaturation: Double,
        comfortableDistance: Int,
        demandDistance: Int,
        referenceLatencyMilliseconds: Double,
        latencyToleranceMilliseconds: Double,
        speedWeight: Double,
        distanceWeight: Double,
        latencyWeight: Double,
        reversalDiscount: Double,
        latencySampleLimit: Int,
        itemLimitPerRefill: Int,
        byteLimitPerRefill: Int,
        bufferItemBudget: Int,
        bufferByteBudget: Int,
        maximumRefillAttempts: Int,
        refillDeadlineMilliseconds: Int
    ) {
        self.floor = floor
        self.ceiling = ceiling
        self.escalationThreshold = escalationThreshold
        self.deescalationThreshold = deescalationThreshold
        self.speedSaturation = speedSaturation
        self.comfortableDistance = comfortableDistance
        self.demandDistance = demandDistance
        self.referenceLatencyMilliseconds = referenceLatencyMilliseconds
        self.latencyToleranceMilliseconds = latencyToleranceMilliseconds
        self.speedWeight = speedWeight
        self.distanceWeight = distanceWeight
        self.latencyWeight = latencyWeight
        self.reversalDiscount = reversalDiscount
        self.latencySampleLimit = latencySampleLimit
        self.itemLimitPerRefill = itemLimitPerRefill
        self.byteLimitPerRefill = byteLimitPerRefill
        self.bufferItemBudget = bufferItemBudget
        self.bufferByteBudget = bufferByteBudget
        self.maximumRefillAttempts = maximumRefillAttempts
        self.refillDeadlineMilliseconds = refillDeadlineMilliseconds
    }

    // MARK: decisions

    /// Clamps one raw estimate into `floor ... ceiling`.
    public func clamp(_ raw: Double) -> Double {
        min(max(raw, floor), ceiling)
    }

    /// Applies the hysteresis band. The two thresholds are never the same point, so a fling that rides
    /// a threshold cannot make the level flap: entering needs `escalationThreshold`, leaving needs
    /// `deescalationThreshold`.
    public func level(previous: RunwayPressureLevel, estimate: Double) -> RunwayPressureLevel {
        switch previous {
        case .strained:
            return estimate <= deescalationThreshold ? .comfortable : .strained
        case .comfortable:
            return estimate >= escalationThreshold ? .strained : .comfortable
        }
    }

    /// Whether this pressure is worth a refill at all. A reversal can leave the level `strained`
    /// (hysteresis) while the reader has more than `comfortableDistance` cards ahead: nothing to do.
    public func wantsRefill(distance: Int, level: RunwayPressureLevel) -> Bool {
        if distance <= demandDistance { return true }
        return level == .strained && distance <= comfortableDistance
    }

    /// Demand when the reader is about to reach the tail; a cancelable prefetch otherwise.
    public func refillPurpose(distance: Int, level: RunwayPressureLevel) -> RunwayRefillPurpose {
        distance <= demandDistance ? .readerDemand : .prefetch
    }

    /// Whether one more refill of this size fits in the outstanding buffer (plan §12's byte/item bound).
    public func bufferAdmits(
        outstandingItems: Int,
        outstandingBytes: Int,
        itemLimit: Int,
        byteLimit: Int
    ) -> Bool {
        guard itemLimit > 0, byteLimit > 0 else { return false }
        return outstandingItems + itemLimit <= bufferItemBudget
            && outstandingBytes + byteLimit <= bufferByteBudget
    }
}
