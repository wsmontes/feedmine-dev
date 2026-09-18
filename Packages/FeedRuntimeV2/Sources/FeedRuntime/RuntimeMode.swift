import Foundation

/// The four valid runtime modes (plan §13).
///
/// An arbitrary combination of features is not a mode: shadow on with network on and UI off, for
/// example, has no owner and no authority. Invalid combinations must fail in tests and resolve to
/// `legacy` with a recorded reason in a distribution build.
public enum RuntimeMode: String, CaseIterable, Sendable {
    /// Legacy acquires and displays; Runtime V2 is absent.
    case legacy
    /// Legacy acquires and displays; V2 observes and compares in isolation.
    case mirroredShadow
    /// Legacy acquires; the bridge supplies V2, and V2 renders.
    case v2Presentation
    /// V2 acquires and renders.
    case v2Full

    public var runsShadow: Bool { self == .mirroredShadow }

    /// Whether Runtime V2 renders the feed.
    public var usesV2Presentation: Bool { self == .v2Presentation || self == .v2Full }

    /// Whether Runtime V2 performs acquisition. Only one owner per target may be true.
    public var ownsAcquisition: Bool { self == .v2Full }
}

/// How the requested feature flags were resolved into a mode.
public struct RuntimeModeResolution: Equatable, Sendable {
    public let requested: RequestedFeatures
    public let mode: RuntimeMode
    /// Non-nil when the request was invalid and had to be resolved to a safe mode.
    public let rejection: String?

    public var isExact: Bool { rejection == nil }
}

public struct RequestedFeatures: Equatable, Sendable {
    public let shadow: Bool
    public let v2UI: Bool
    public let v2Network: Bool

    public init(shadow: Bool, v2UI: Bool, v2Network: Bool) {
        self.shadow = shadow
        self.v2UI = v2UI
        self.v2Network = v2Network
    }
}

public enum RuntimeModeResolver {
    /// Maps a feature request onto a valid mode.
    ///
    /// - Parameter modeChangeAllowedAtLaunchOnly: the plan forbids live transfer between modes
    ///   until an explicit handoff with cancellation/drain/leases exists; the resolver records the
    ///   request but the caller must apply it on the next launch.
    public static func resolve(_ features: RequestedFeatures) -> RuntimeModeResolution {
        switch (features.shadow, features.v2UI, features.v2Network) {
        case (false, false, false):
            return RuntimeModeResolution(requested: features, mode: .legacy, rejection: nil)
        case (true, false, false):
            return RuntimeModeResolution(requested: features, mode: .mirroredShadow, rejection: nil)
        case (false, true, false):
            return RuntimeModeResolution(requested: features, mode: .v2Presentation, rejection: nil)
        case (false, true, true):
            return RuntimeModeResolution(requested: features, mode: .v2Full, rejection: nil)
        default:
            return RuntimeModeResolution(
                requested: features,
                mode: .legacy,
                rejection: "invalid feature combination shadow=\(features.shadow) "
                    + "v2UI=\(features.v2UI) v2Network=\(features.v2Network); resolved to legacy"
            )
        }
    }
}
