import Foundation

/// What the publication froze about *how* one card lays out (ADR-001 D15, plan §9).
///
/// The contract is part of the published payload: a later catalog edit, a different window width, a
/// different Dynamic Type size or a different locale changes materialisation only. It names a kind, a
/// media slot, an aspect ratio and a text style; it never names a pixel size, a font or a device.

/// The layout family of a published card.
public enum RenderKind: String, Hashable, Sendable, CaseIterable {
    /// Media-driven card with a full-width lead slot.
    case hero
    /// Card with a secondary media slot beside the text.
    case thumb
    /// Text only. A card in this family needs no media bytes and no network to render.
    case textOnly
}

/// Where a render contract expects media to be drawn.
///
/// Deliberately distinct from `PublishedAssetSlot`: a *reference* occupies one of
/// `primary/alternate/poster/thumbnail/waveform`, while a *layout* either draws one of
/// `primary/poster/thumbnail/waveform` or draws nothing at all.
public enum MediaSlot: String, Hashable, Sendable, CaseIterable {
    case none
    case primary
    case poster
    case thumbnail
    case waveform

    /// Whether a card in this slot needs media bytes to draw its layout.
    public var drawsMedia: Bool { self != .none }
}

/// The text emphasis of a card, frozen with the contract.
///
/// ADR-001's sketch carries this as a stored field; the schema stores `render_kind`,
/// `render_media_slot` and `render_aspect_ratio` only, so the token is *derived* from the kind. That
/// keeps INV-2 true without an extra column: the whole contract is reconstructible from the row.
public enum TextStyleToken: String, Hashable, Sendable, CaseIterable {
    case headline
    case compact

    public init(for kind: RenderKind) {
        switch kind {
        case .hero, .textOnly: self = .headline
        case .thumb: self = .compact
        }
    }
}

/// The frozen render contract of one published card (ADR-001 D15, INV-12).
public struct RenderContract: Hashable, Sendable {
    /// Bumped only when a stored field changes meaning, never because the render environment moved.
    public static let currentVersion = 1

    public let version: Int
    public let kind: RenderKind
    public let mediaSlot: MediaSlot
    public let aspectRatio: Double?

    public init(version: Int, kind: RenderKind, mediaSlot: MediaSlot, aspectRatio: Double?) {
        self.version = version
        self.kind = kind
        self.mediaSlot = mediaSlot
        self.aspectRatio = aspectRatio
    }

    /// The text emphasis this contract implies. Derived, never stored separately.
    public var textStyle: TextStyleToken { TextStyleToken(for: kind) }

    /// Whether a renderer can draw this card with no media bytes and no network.
    public var isTextOnly: Bool { kind == .textOnly && mediaSlot == .none }

    /// The deterministic contract for one card's media set.
    ///
    /// A published primary asset lays out as a hero; any other committed slot lays out beside the
    /// text; a declared slot whose bytes were never prepared keeps its geometry through the
    /// deterministic placeholder (ADR-001 D14); and a card with nothing renderable declared is text
    /// only, which is the offline path of plan §10 (`offlineCardDoesNotRequireRemotePlaybackAsset`).
    public static func resolved(media: PublishedMediaSet) -> RenderContract {
        if let primary = media.primary {
            return RenderContract(
                version: currentVersion,
                kind: .hero,
                mediaSlot: .primary,
                aspectRatio: primary.aspectRatio
            )
        }
        if let reference = media.references.first {
            return RenderContract(
                version: currentVersion,
                kind: .thumb,
                mediaSlot: reference.renderSlot,
                aspectRatio: reference.media.aspectRatio
            )
        }
        if let placeholder = media.placeholder {
            return RenderContract(
                version: currentVersion,
                kind: placeholder.slot == .primary ? .hero : .thumb,
                mediaSlot: placeholder.slot,
                aspectRatio: placeholder.aspectRatio
            )
        }
        return RenderContract(version: currentVersion, kind: .textOnly, mediaSlot: .none, aspectRatio: nil)
    }
}
