import Foundation
import FeedRuntime

/// Where the feature request of this launch came from.
enum RuntimeModeRequestSource: String, Sendable {
    /// Launch arguments (tests). They describe this launch only and are never persisted.
    case launchArguments
    /// The request persisted by a previous launch.
    case stored
    /// Nothing was requested: the legacy mode.
    case none
}

/// The mode this launch runs, with the reason when the request could not be honoured.
///
/// `RuntimeModeResolver` (package) owns the table; this type only carries the answer, the request
/// that produced it and the rejection, so a distribution build can log why it fell back instead of
/// running an ownerless shadow (plan §13).
struct RuntimeLaunchDecision: Equatable, Sendable {
    let mode: RuntimeMode
    let requested: RequestedFeatures
    /// Non-nil exactly when the request named no valid mode. The mode is then `legacy`.
    let rejection: String?
    let source: RuntimeModeRequestSource
    let decidedAt: Date

    var runsShadow: Bool { mode.runsShadow }
    var ownsAcquisition: Bool { mode.ownsAcquisition }

    /// One line for diagnostics: what was asked, what runs, and why they differ.
    var diagnostic: String {
        let request = "shadow=\(requested.shadow) v2UI=\(requested.v2UI) "
            + "v2Network=\(requested.v2Network)"
        guard let rejection else {
            return "runtime-v2 mode=\(mode.rawValue) request(\(request)) source=\(source.rawValue)"
        }
        return "runtime-v2 mode=\(mode.rawValue) request(\(request)) source=\(source.rawValue) "
            + "rejected=\(rejection)"
    }
}

/// Resolves the four valid Runtime V2 modes once per launch (plan §13, `docs/runtime-v2/rollout.md` §1).
///
/// The app never accepts a free combination of flags. It stores a *request* and resolves it at
/// launch through `RuntimeModeResolver` from the package; an invalid combination resolves to
/// `legacy` and the reason is recorded.
///
/// A mode change applies on the next launch, by construction: the running mode is the decision
/// persisted at launch, and writing a new request cannot change it. Live transfer between modes
/// needs an explicit handoff with cancellation, drain and leases, which does not exist yet.
enum RuntimeModeLaunch {
    static let shadowRequestKey = "runtimeV2.requested.shadow"
    static let v2UIRequestKey = "runtimeV2.requested.ui"
    static let v2NetworkRequestKey = "runtimeV2.requested.network"
    /// The decision of the last launch, so diagnostics can be read without relaunching.
    static let lastDecisionKey = "runtimeV2.lastDecision"

    static let shadowArgument = "-RuntimeV2Shadow"
    static let v2UIArgument = "-RuntimeV2UI"
    static let v2NetworkArgument = "-RuntimeV2Network"

    // MARK: - Request

    /// Persists a request for the next launch. It changes nothing about this launch.
    static func request(
        _ features: RequestedFeatures,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(features.shadow, forKey: shadowRequestKey)
        defaults.set(features.v2UI, forKey: v2UIRequestKey)
        defaults.set(features.v2Network, forKey: v2NetworkRequestKey)
    }

    /// The stored request, or `nil` when no launch ever asked for one.
    static func storedRequest(in defaults: UserDefaults = .standard) -> RequestedFeatures? {
        guard defaults.object(forKey: shadowRequestKey) != nil
            || defaults.object(forKey: v2UIRequestKey) != nil
            || defaults.object(forKey: v2NetworkRequestKey) != nil
        else { return nil }
        return RequestedFeatures(
            shadow: defaults.bool(forKey: shadowRequestKey),
            v2UI: defaults.bool(forKey: v2UIRequestKey),
            v2Network: defaults.bool(forKey: v2NetworkRequestKey)
        )
    }

    /// A request spelled as launch arguments. Presence of a flag is `true`; the flags describe one
    /// launch and are never persisted.
    static func argumentRequest(from arguments: [String]) -> RequestedFeatures? {
        let names = [shadowArgument, v2UIArgument, v2NetworkArgument]
        guard arguments.contains(where: names.contains) else { return nil }
        return RequestedFeatures(
            shadow: arguments.contains(shadowArgument),
            v2UI: arguments.contains(v2UIArgument),
            v2Network: arguments.contains(v2NetworkArgument)
        )
    }

    // MARK: - Decision

    /// Resolves this launch's mode and records it. Launch arguments win over the stored request:
    /// they exist so a test can run one launch in a mode it did not have to persist.
    @discardableResult
    static func decide(
        in defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        at: Date = Date()
    ) -> RuntimeLaunchDecision {
        let decision: RuntimeLaunchDecision
        if let features = argumentRequest(from: arguments) {
            decision = decide(features, source: .launchArguments, at: at)
        } else if let features = storedRequest(in: defaults) {
            decision = decide(features, source: .stored, at: at)
        } else {
            decision = decide(
                RequestedFeatures(shadow: false, v2UI: false, v2Network: false),
                source: .none,
                at: at
            )
        }
        record(decision, in: defaults)
        return decision
    }

    private static func decide(
        _ features: RequestedFeatures,
        source: RuntimeModeRequestSource,
        at: Date
    ) -> RuntimeLaunchDecision {
        let resolution = RuntimeModeResolver.resolve(features)
        return RuntimeLaunchDecision(
            mode: resolution.mode,
            requested: resolution.requested,
            rejection: resolution.rejection,
            source: source,
            decidedAt: at
        )
    }

    /// The mode this process runs: the decision taken at launch, never a fresh resolution. A mode
    /// request written after launch therefore takes effect on the next launch only. Before the first
    /// launch ever decided, this is `legacy`.
    static func current(in defaults: UserDefaults = .standard) -> RuntimeLaunchDecision {
        guard let record = defaults.dictionary(forKey: lastDecisionKey),
              let rawMode = record["mode"] as? String,
              let mode = RuntimeMode(rawValue: rawMode)
        else { return legacy(at: Date(timeIntervalSince1970: 0)) }

        let rejection = record["rejection"] as? String
        return RuntimeLaunchDecision(
            mode: mode,
            requested: RequestedFeatures(
                shadow: record["shadow"] as? Bool ?? false,
                v2UI: record["v2UI"] as? Bool ?? false,
                v2Network: record["v2Network"] as? Bool ?? false
            ),
            rejection: rejection,
            source: RuntimeModeRequestSource(rawValue: record["source"] as? String ?? "") ?? .none,
            decidedAt: Date(timeIntervalSince1970: record["decidedAt"] as? Double ?? 0)
        )
    }

    private static func record(_ decision: RuntimeLaunchDecision, in defaults: UserDefaults) {
        // `UserDefaults` accepts only property-list values, so an absent rejection is left out
        // instead of being stored as a boxed `Optional.none`.
        var record: [String: Any] = [
            "mode": decision.mode.rawValue,
            "shadow": decision.requested.shadow,
            "v2UI": decision.requested.v2UI,
            "v2Network": decision.requested.v2Network,
            "source": decision.source.rawValue,
            "decidedAt": decision.decidedAt.timeIntervalSince1970,
        ]
        if let rejection = decision.rejection { record["rejection"] = rejection }
        defaults.set(record, forKey: lastDecisionKey)
    }

    private static func legacy(at date: Date) -> RuntimeLaunchDecision {
        RuntimeLaunchDecision(
            mode: .legacy,
            requested: RequestedFeatures(shadow: false, v2UI: false, v2Network: false),
            rejection: nil,
            source: .none,
            decidedAt: date
        )
    }
}
