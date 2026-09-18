import Foundation

/// One endpoint, one refill, shared by every demand that wants it in the same window.
///
/// `AcquisitionCoordinator` already keeps exactly one refill in flight per target and lets a second
/// demand share it (PR-10, `AcquisitionCoordinator.refill`). The legacy acquisition path the app
/// still runs has no such rule: its producers — the cold-start bootstrap, the progressive fetch, the
/// background drip, the remote search sweep, the What's New booster, the onboarding showcase, the
/// source detail and the collection detail — each call `RSSFetcher` directly, so two of them can be
/// fetching the same endpoint at the same time, and a secondary surface can re-fetch what the Main
/// Feed fetched minutes ago. The reconciliation is in `docs/runtime-v2/rollout.md` §4 (single owner
/// per target) and its measured twelve pairs are in the acquisition map handed to PR-14.
///
/// This ledger is that rule as a value, for the path the app actually executes: **no secondary
/// surface issues a fetch for a resource another surface is already acquiring.** It is a value type
/// on purpose — `FeedStore` is `@MainActor`, so the decision is taken on one actor and is a
/// synchronous mutation, while the producers interleave across `await`, which is exactly the window
/// the ledger closes.
///
/// Three answers per endpoint, and only the first two are interchangeable with the coordinator's:
///
/// - `led` — nothing else is refilling it: this demand performs the refill and pays for it.
/// - `shared` — another demand is refilling it right now: this demand performs no request.
/// - `servedFresh` — nothing is in flight, but it was refilled within the caller's freshness window:
///   the caller serves what is already admitted locally and performs no request. This is what keeps
///   the source and collection surfaces from re-fetching an endpoint the Main Feed just fetched.
public struct SourceDemandLedger: Sendable {

    /// Which producer is asking. The purpose is recorded with the refill, so a shared refill can be
    /// attributed to the demand that performed it rather than to the one that joined.
    public enum Purpose: String, Hashable, Sendable, CaseIterable {
        case bootstrap
        case progressiveFetch
        case backgroundDrip
        case searchSweep
        case whatsNewBooster
        case onboardingShowcase
        case sourceDetail
        case collectionDetail
        case smartFeed
        case importRefresh
        case regionSeed
        case sourceToggle
        case coverageMining
    }

    /// What one demand may do, per endpoint, in the order the endpoints were asked for.
    public struct Grant: Equatable, Sendable {
        /// Refill these: no other demand holds them and no fresh result exists.
        public let led: [String]
        /// Another demand is already refilling these: issue no request.
        public let shared: [String]
        /// Nothing is in flight, but these were refilled inside the freshness window: issue no
        /// request and serve the local result.
        public let servedFresh: [String]

        public var isEmpty: Bool { led.isEmpty && shared.isEmpty && servedFresh.isEmpty }

        public init(led: [String] = [], shared: [String] = [], servedFresh: [String] = []) {
            self.led = led
            self.shared = shared
            self.servedFresh = servedFresh
        }
    }

    /// Observable counts, so a closure of one of the twelve pairs is evidence (a count) and not an
    /// assertion of intent.
    public struct Counters: Equatable, Sendable {
        /// Demands submitted, one per `demand(_:purpose:atMs:freshnessWindowMs:)` call.
        public var demands = 0
        /// Endpoints this ledger let a demand refill.
        public var ledRefills = 0
        /// Endpoints a demand wanted while another demand already held them.
        public var sharedRefills = 0
        /// Endpoints satisfied from a refill inside the freshness window.
        public var freshSkips = 0
    }

    /// Endpoint → the purpose refilling it. Non-empty means in flight.
    private var inFlight: [String: Purpose] = [:]
    /// Endpoint → the last time a refill of it succeeded.
    private var refilledAtMs: [String: Int64] = [:]

    public private(set) var counters = Counters()

    public init() {}

    /// How many endpoints are being refilled right now. A balanced caller returns this to zero;
    /// a nonzero value after a run is a leaked claim, not a cache.
    public var inFlightCount: Int { inFlight.count }

    public func isInFlight(_ endpoint: String) -> Bool { inFlight[endpoint] != nil }

    public func lastRefillAtMs(_ endpoint: String) -> Int64? { refilledAtMs[endpoint] }

    /// Asks to refill `endpoints`.
    ///
    /// - Parameter freshnessWindowMs: when non-nil, an endpoint whose last successful refill is at
    ///   most this many milliseconds old is answered as `servedFresh` instead of `led`. Pass nil to
    ///   demand a refill regardless of recency (the bootstrap, the search sweep and the background
    ///   drip need current bytes, not the last page).
    public mutating func demand(
        _ endpoints: [String],
        purpose: Purpose,
        atMs: Int64,
        freshnessWindowMs: Int64? = nil
    ) -> Grant {
        counters.demands += 1
        var led: [String] = []
        var shared: [String] = []
        var servedFresh: [String] = []
        var seen = Set<String>()
        for endpoint in endpoints where !endpoint.isEmpty && seen.insert(endpoint).inserted {
            if inFlight[endpoint] != nil {
                shared.append(endpoint)
                counters.sharedRefills += 1
                continue
            }
            if let window = freshnessWindowMs, window > 0,
               let last = refilledAtMs[endpoint],
               atMs >= last,
               atMs - last <= window {
                servedFresh.append(endpoint)
                counters.freshSkips += 1
                continue
            }
            led.append(endpoint)
            inFlight[endpoint] = purpose
            counters.ledRefills += 1
        }
        return Grant(led: led, shared: shared, servedFresh: servedFresh)
    }

    /// Ends the refills this demand led. `succeeded` names the endpoints whose result was actually
    /// admitted: only those become fresh, so a failed refill does not suppress the next attempt.
    ///
    /// Endpoints this demand did not lead (shared or servedFresh) are ignored.
    public mutating func finish(_ endpoints: [String], atMs: Int64, succeeded: Set<String>) {
        for endpoint in endpoints {
            inFlight.removeValue(forKey: endpoint)
            if succeeded.contains(endpoint) {
                refilledAtMs[endpoint] = atMs
            }
        }
    }

    /// The whole-led-set form, for a producer that cannot attribute an outcome per endpoint.
    public mutating func finish(_ grant: Grant, atMs: Int64, succeeded: Bool) {
        finish(grant.led, atMs: atMs, succeeded: succeeded ? Set(grant.led) : [])
    }

    /// Drops an endpoint's recency, so the next demand refills it however recent the last one was.
    /// Used when the local result was invalidated (a source re-enabled, a cache cleared).
    public mutating func forget(_ endpoint: String) {
        refilledAtMs.removeValue(forKey: endpoint)
    }
}
