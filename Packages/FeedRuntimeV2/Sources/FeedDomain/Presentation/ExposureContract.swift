import Foundation

/// The exposure contract of ADR-007, as values the runtime and storage share.
///
/// Everything an exposure decision needs is here and nothing reads a clock or a database: the policy
/// is versioned, the observation is a small telemetry value, the fact carries its own idempotency key
/// and the monotonic clock is a port. `ExposureTracker` (runtime) is the only type that turns
/// observations into facts, and `FeedStorage` is the only type that writes them.

/// Monotonic time and its boot-session qualifier (ADR-007 D15).
///
/// Dwell arithmetic never reads `Date()`: a wall clock can move backwards, and a fact has to be
/// comparable with another fact recorded on the same boot. An implementation that observes an uptime
/// reset mints a new `bootSessionID`; arithmetic across two ids is invalid by construction.
public protocol MonotonicClock: Sendable {
    /// Monotonic milliseconds. Never a wall-clock reading.
    func nowMillis() -> Int64
    /// Identifies the boot session the reading belongs to.
    var bootSessionID: String { get }
}

public enum ExposureContractError: Error, Equatable, Sendable {
    case nonPositivePolicyValue(String, Int)
    case visibleFractionOutOfRange(Double)
    case visibleFractionThresholdOutOfRange(Double)
    case coalesceWindowOutOfRange(Int)
    case directionOutOfRange(Int)
    case negativeVisitOrdinal(Int)
    case seenRequiresDwell
    case centerCrossedRequiresDirection
    case viewportLeftRequiresCloseReason
    case intervalCloseCarriesForeignVisitor(String)
    case visitOrdinalOnlyForIntervalFacts(ExposureEventType, Int)
    case durableFactRequiresOperationID(ExposureEventType)
}

/// The versioned knobs that produced a fact (ADR-007 D1/D2/D9).
///
/// The initial values are a hypothesis: changing one creates a *new* policy version and never
/// rewrites a fact recorded under the old one. `coalesceWindowMs` is bounded to the 50–100 ms band
/// the architecture fixes, because the window is what quantizes credited dwell (ADR-007 H-06).
public struct ExposurePolicy: Hashable, Sendable, CustomStringConvertible {
    public static let baselineVersion = "exposure-v1"

    /// 50% of the card visible for 1000 ms, coalesced at 75 ms, flushed at 20 facts or 500 ms.
    public static let baseline = ExposurePolicy(
        uncheckedVersion: baselineVersion,
        minVisibleFraction: 0.5,
        minDwellMs: 1000,
        coalesceWindowMs: 75,
        flushFactCount: 20,
        flushIntervalMs: 500
    )

    public let version: String
    public let minVisibleFraction: Double
    public let minDwellMs: Int
    public let coalesceWindowMs: Int
    public let flushFactCount: Int
    public let flushIntervalMs: Int

    public init(
        version: String,
        minVisibleFraction: Double,
        minDwellMs: Int,
        coalesceWindowMs: Int,
        flushFactCount: Int,
        flushIntervalMs: Int
    ) throws {
        guard !version.isEmpty else {
            throw ExposureContractError.nonPositivePolicyValue("version", 0)
        }
        guard minVisibleFraction > 0.0, minVisibleFraction <= 1.0 else {
            throw ExposureContractError.visibleFractionThresholdOutOfRange(minVisibleFraction)
        }
        guard minDwellMs >= 0 else {
            throw ExposureContractError.nonPositivePolicyValue("minDwellMs", minDwellMs)
        }
        guard coalesceWindowMs >= 50, coalesceWindowMs <= 100 else {
            throw ExposureContractError.coalesceWindowOutOfRange(coalesceWindowMs)
        }
        guard flushFactCount > 0 else {
            throw ExposureContractError.nonPositivePolicyValue("flushFactCount", flushFactCount)
        }
        guard flushIntervalMs > 0 else {
            throw ExposureContractError.nonPositivePolicyValue("flushIntervalMs", flushIntervalMs)
        }
        self.version = version
        self.minVisibleFraction = minVisibleFraction
        self.minDwellMs = minDwellMs
        self.coalesceWindowMs = coalesceWindowMs
        self.flushFactCount = flushFactCount
        self.flushIntervalMs = flushIntervalMs
    }

    private init(
        uncheckedVersion version: String,
        minVisibleFraction: Double,
        minDwellMs: Int,
        coalesceWindowMs: Int,
        flushFactCount: Int,
        flushIntervalMs: Int
    ) {
        self.version = version
        self.minVisibleFraction = minVisibleFraction
        self.minDwellMs = minDwellMs
        self.coalesceWindowMs = coalesceWindowMs
        self.flushFactCount = flushFactCount
        self.flushIntervalMs = flushIntervalMs
    }

    public var description: String {
        "exposure-policy:\(version) visible>=\(minVisibleFraction) dwell>=\(minDwellMs)ms "
            + "coalesce=\(coalesceWindowMs)ms flush=\(flushFactCount)/\(flushIntervalMs)ms"
    }
}

/// One viewport observation submitted by the renderer (ADR-007 D2).
///
/// Deliberately tiny: it names the card, the fraction of its area that was visible and whether this
/// sample is an entry edge, a plain sample or a left edge. It carries no image, no offset in points
/// and no request: a viewport submission performs no acquisition (ADR-007 H-16).
public struct ViewportObservation: Hashable, Sendable {
    public enum Edge: String, Hashable, Sendable, CaseIterable {
        case entered
        case sample
        case left
    }

    public let cardID: PublicationCardID
    public let visibleFraction: Double
    public let edge: Edge
    /// `-1`, `0` or `1`: which way the card moved across the viewport, if it moved at all.
    public let direction: Int

    public init(
        cardID: PublicationCardID,
        visibleFraction: Double,
        edge: Edge,
        direction: Int = 0
    ) throws {
        guard visibleFraction >= 0.0, visibleFraction <= 1.0 else {
            throw ExposureContractError.visibleFractionOutOfRange(visibleFraction)
        }
        guard direction >= -1, direction <= 1 else {
            throw ExposureContractError.directionOutOfRange(direction)
        }
        self.cardID = cardID
        self.visibleFraction = visibleFraction
        self.edge = edge
        self.direction = direction
    }
}

/// The distinct fact types of ADR-007 D5. None is inferred from another.
public enum ExposureEventType: String, Hashable, Sendable, CaseIterable {
    case viewportEntered
    case centerCrossed
    case viewportLeft
    case seen
    case opened
    case read
    case bookmarked
    case bookmarkRemoved

    /// Whether the fact belongs to one visit and may repeat under a new `visit_ordinal`.
    public var isIntervalScoped: Bool {
        switch self {
        case .viewportEntered, .viewportLeft, .seen, .centerCrossed: return true
        case .opened, .read, .bookmarked, .bookmarkRemoved: return false
        }
    }
}

/// Why an interval ended (ADR-007's `close_reason`).
public enum ExposureCloseReason: String, Hashable, Sendable, CaseIterable {
    case leftViewport
    case windowEvicted
    case background
    case sessionEnd
    case editionSwap
}

/// One exposure fact, with the idempotency key that makes replay a no-op (ADR-007 D7).
public struct ExposureFact: Hashable, Sendable {
    public let factKey: String
    public let editionID: EditionID
    public let cardID: PublicationCardID
    public let originRecordID: OriginRecordID?
    public let originRevisionID: OriginRevisionID?
    public let type: ExposureEventType
    public let scope: HistoryScope
    public let visitOrdinal: Int
    public let bootSessionID: String
    public let observedAtMs: Int64
    public let wallClockMs: Int64?
    public let dwellMs: Int64?
    public let maxVisibleFraction: Double?
    public let direction: Int?
    public let closeReason: ExposureCloseReason?
    public let policyVersion: String
    /// The durable user-state operation id that owns a `read`/`bookmarked` fact.
    public let userStateOperationID: String?

    public init(
        type: ExposureEventType,
        editionID: EditionID,
        cardID: PublicationCardID,
        originRecordID: OriginRecordID? = nil,
        originRevisionID: OriginRevisionID? = nil,
        scope: HistoryScope,
        visitOrdinal: Int = 0,
        bootSessionID: String,
        observedAtMs: Int64,
        wallClockMs: Int64? = nil,
        dwellMs: Int64? = nil,
        maxVisibleFraction: Double? = nil,
        direction: Int? = nil,
        closeReason: ExposureCloseReason? = nil,
        policyVersion: String,
        userStateOperationID: String? = nil
    ) throws {
        guard visitOrdinal >= 0 else {
            throw ExposureContractError.negativeVisitOrdinal(visitOrdinal)
        }
        guard type.isIntervalScoped || visitOrdinal == 0 else {
            throw ExposureContractError.visitOrdinalOnlyForIntervalFacts(type, visitOrdinal)
        }
        if let direction {
            guard direction >= -1, direction <= 1 else {
                throw ExposureContractError.directionOutOfRange(direction)
            }
        }
        if let maxVisibleFraction {
            guard maxVisibleFraction >= 0.0, maxVisibleFraction <= 1.0 else {
                throw ExposureContractError.visibleFractionOutOfRange(maxVisibleFraction)
            }
        }
        switch type {
        case .seen:
            // H-01: a seen fact without observed dwell would be an invented exposure.
            guard let dwellMs, dwellMs >= 0 else { throw ExposureContractError.seenRequiresDwell }
        case .centerCrossed:
            guard direction != nil else { throw ExposureContractError.centerCrossedRequiresDirection }
        case .viewportLeft:
            guard closeReason != nil else {
                throw ExposureContractError.viewportLeftRequiresCloseReason
            }
        case .viewportEntered:
            guard closeReason == nil else {
                throw ExposureContractError.intervalCloseCarriesForeignVisitor(type.rawValue)
            }
        case .opened, .read, .bookmarked, .bookmarkRemoved:
            guard dwellMs == nil, closeReason == nil else {
                throw ExposureContractError.intervalCloseCarriesForeignVisitor(type.rawValue)
            }
        }
        if type == .read || type == .bookmarked || type == .bookmarkRemoved {
            guard let userStateOperationID, !userStateOperationID.isEmpty else {
                throw ExposureContractError.durableFactRequiresOperationID(type)
            }
        }
        self.type = type
        self.editionID = editionID
        self.cardID = cardID
        self.originRecordID = originRecordID
        self.originRevisionID = originRevisionID
        self.scope = scope
        self.visitOrdinal = visitOrdinal
        self.bootSessionID = bootSessionID
        self.observedAtMs = observedAtMs
        self.wallClockMs = wallClockMs
        self.dwellMs = dwellMs
        self.maxVisibleFraction = maxVisibleFraction
        self.direction = direction
        self.closeReason = closeReason
        self.policyVersion = policyVersion
        self.userStateOperationID = userStateOperationID
        self.factKey = Self.key(
            type: type,
            editionID: editionID,
            cardID: cardID,
            scope: scope,
            visitOrdinal: visitOrdinal,
            direction: direction,
            userStateOperationID: userStateOperationID
        )
    }

    /// ADR-007 D7, verbatim: the key is the deduplication rule, so it is built in exactly one place.
    public static func key(
        type: ExposureEventType,
        editionID: EditionID,
        cardID: PublicationCardID,
        scope: HistoryScope,
        visitOrdinal: Int,
        direction: Int?,
        userStateOperationID: String?
    ) -> String {
        let scopeText = scope.canonicalName
        let scopeRef = scope.scopeRef
        switch type {
        case .viewportEntered, .viewportLeft, .seen:
            return "edition:\(editionID.rawValue)|card:\(cardID.rawValue)|scope:\(scopeText)"
                + "|ref:\(scopeRef)|visit:\(visitOrdinal)|event:\(type.rawValue)"
        case .centerCrossed:
            return "edition:\(editionID.rawValue)|card:\(cardID.rawValue)|scope:\(scopeText)"
                + "|ref:\(scopeRef)|visit:\(visitOrdinal)|event:\(type.rawValue)"
                + "|dir:\(direction ?? 0)"
        case .opened:
            return "edition:\(editionID.rawValue)|card:\(cardID.rawValue)|scope:\(scopeText)"
                + "|ref:\(scopeRef)|event:\(type.rawValue)"
        case .read, .bookmarked, .bookmarkRemoved:
            return "card:\(cardID.rawValue)|event:\(type.rawValue)"
                + "|source:\(userStateOperationID ?? "")"
        }
    }
}

/// The canonical text of a scope in a fact key, and the reference that makes it unique per surface.
extension HistoryScope {
    public var canonicalName: String {
        switch self {
        case .main: return "main"
        case .source: return "source"
        case .bookmark: return "bookmark"
        case .search: return "search"
        case .collection: return "collection"
        case .smartFeed: return "smartFeed"
        case .whatsNew: return "whatsNew"
        case .onboarding: return "onboarding"
        case .persistentSearch: return "persistentSearch"
        case .lastClicked: return "lastClicked"
        }
    }

    /// The durable scope reference: a source id, a list key, a collection key, a smart feed key.
    public var scopeRef: String {
        switch self {
        case .main, .search, .whatsNew, .onboarding, .lastClicked: return ""
        case let .source(sourceID): return "\(sourceID.rawValue)"
        case let .bookmark(listKey): return listKey ?? ""
        case let .collection(key), let .smartFeed(key), let .persistentSearch(key): return key
        }
    }
}

/// The ADR-007 D12 matrix as an executable rule.
///
/// Two independent conditions must hold before a fact removes a card from a surface: the surface
/// declares that it applies `seen`, and the fact was recorded *in that same scope*. A `seen` fact in
/// Main therefore cannot hide a card in Bookmark, Source or Search, which is what
/// `mainExposureDoesNotHideBookmarkOrSourceHistory` pins.
public struct HistoryScopeRules: Hashable, Sendable {
    public let policy: HistoryPolicy

    public init(policy: HistoryPolicy) {
        self.policy = policy
    }

    /// Whether a card seen in `factScope` is excluded from this policy's surface.
    public func excludes(cardSeenIn factScope: HistoryScope) -> Bool {
        policy.applySeen && factScope == policy.scope && policy.scope.allowsSeenExclusion
    }

    /// Whether this surface displays a recorded state as an overlay without excluding the card.
    ///
    /// A surface that does not apply `seen` (`applySeen = false`) must still be able to *show* it, and
    /// a surface that does apply `seen` shows the overlay of its own scope and of any durable
    /// read/bookmark fact, which is never inferred from another surface's `seen` (ADR-007 D12).
    public func showsOverlay(forCardRecordedIn factScope: HistoryScope) -> Bool {
        guard policy.showOverlay else { return false }
        return !policy.applySeen || factScope == policy.scope
    }
}
