import CryptoKit
import Foundation
import FeedDomain

/// Terminal media decision for one card, in the container the screen is showing.
///
/// This is the renderer's whole media contract: bytes that are already local, a deterministic
/// placeholder, or a reserved-but-empty frame. There is no `.loading` and there is no URL, so a card
/// that has no local asset draws a placeholder instead of starting a download (plan §10).
enum CardMediaSlot: Equatable {
    /// No slot at all: the card collapses to text.
    case none
    /// The frame is reserved to keep the surface stable, and nothing is drawn in it. The prepared
    /// pipeline reserved this frame while it resolved; drawing a stand-in asset was judged worse than
    /// an empty frame, and this case keeps that decision.
    case empty
    /// Bytes already local. The cache key is the asset's identity, never a URL.
    case local(RenderImage)
    /// The deterministic placeholder for one content kind.
    case placeholder(PlaceholderKind)

    /// Whether the container must reserve the slot's frame. A card that shows the same card twice
    /// with and without a reserved frame would change every layout below it.
    var reservesFrame: Bool { self != .none }

    var localImage: RenderImage? {
        if case .local(let image) = self { return image }
        return nil
    }

    /// Equality is by the asset's identity (its cache key) and the image instance, the same rule
    /// `RenderReadyMedia` uses: two slots holding the same bytes must compare equal so a card is not
    /// invalidated by a value copy.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.empty, .empty):
            return true
        case (.local(let a), .local(let b)):
            return a.cacheKey == b.cacheKey && a.image === b.image
        case (.placeholder(let a), .placeholder(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// One card as the renderer receives it: the V2 presentation plus the local bytes it points at.
struct MainFeedCardValue {
    let card: CardPresentation
    let mediaSlot: CardMediaSlot
}

/// The one place a legacy `FeedItem` becomes a V2 card (plan §14 PR-13).
///
/// Card chrome used to be inferred inside the views: `FeedItemView` decided audio-vs-reader from
/// `item.isDirectAudioLink`, `FeedItemCardView` chose its placeholder asset and badges from
/// `item.isYouTube`/`isPodcast`/`isForum` and `item.sectionDayOffset`, and `FeedItemRowView` repeated
/// the same sniffing. That inference is a decision about the content, so it belongs to the boundary
/// that turns acquired content into presentation — here — and never to a view.
///
/// This bridge is the legacy adapter, and it is deliberately the only thing that reads the legacy
/// inference (`isYouTube`/`isForum`/`isPodcast`/`isDirectAudioLink`/`hasPotentialImage`). When the
/// runtime composes its own cards (PR-14/PR-15), nothing calls it any more.
enum MainFeedCardBridge {

    /// The chrome for one item, decided once.
    ///
    /// The badge rules mirror the legacy `sourceRow` exactly: a podcast always carries its badge (and
    /// its duration), a video carries the video badge, and the recency badge is shown only when the
    /// card is neither — which is why a video card is never also "New".
    static func affordances(for item: FeedItem) -> CardPresentation.Affordances {
        let isYouTube = item.isYouTube
        let isPodcast = item.isPodcast

        let placeholder: CardPresentation.Affordances.Placeholder
        if isYouTube {
            placeholder = .video
        } else if isPodcast {
            placeholder = .podcast
        } else if item.isForum {
            placeholder = .forum
        } else {
            placeholder = .article
        }

        let overlay: CardPresentation.Affordances.Overlay?
        if isYouTube {
            overlay = .play
        } else if isPodcast {
            overlay = .headphones
        } else {
            overlay = nil
        }

        var badges: [CardPresentation.Affordances.Badge] = []
        if isPodcast { badges.append(.podcast) }
        if isYouTube {
            badges.append(.video)
        } else if !isPodcast && item.sectionDayOffset == 0 {
            badges.append(.new)
        }

        let tap: CardPresentation.Affordances.Tap
        if item.isDirectAudioLink {
            tap = .playAudio
        } else if isPodcast {
            tap = .openReaderOrPlayAudioFromMedia
        } else {
            tap = .openReader
        }

        return CardPresentation.Affordances(
            placeholder: placeholder,
            overlay: overlay,
            badges: badges,
            durationLabel: isPodcast ? item.durationFormatted : nil,
            tap: tap
        )
    }

    /// The media slot for one card in the container the screen is showing.
    ///
    /// The two legacy rules are not the same rule and must not be collapsed: the card band reserves a
    /// hero for an image *or* a podcast episode, while the row band also reserves a thumbnail for an
    /// item whose image the pipeline has not resolved yet (`hasPotentialImage`), and in that case
    /// draws nothing rather than a stand-in.
    static func mediaSlot(
        for item: FeedItem,
        presentation: FeedCardPresentation?,
        band: FeedLoader.FeedLayout,
        placeholderKind: PlaceholderKind
    ) -> CardMediaSlot {
        if let presentation, case .image(let image) = presentation.media {
            return .local(RenderImage(cacheKey: item.id, image: image))
        }
        switch band {
        case .card:
            return item.isPodcast ? .placeholder(.podcast) : .none
        case .list:
            guard item.hasPotentialImage || item.isPodcast else { return .none }
            if item.isPodcast && !item.hasPotentialImage { return .placeholder(.podcast) }
            // No presentation at all means a surface that skipped the pipeline (search, onboarding,
            // source and collection lists): those draw the content-type placeholder while they wait.
            if presentation == nil { return .placeholder(placeholderKind) }
            return .empty
        }
    }

    /// The V2 card and the slot the current band draws for it, built from one decision pass.
    static func value(
        item: FeedItem,
        ordinal: Int,
        presentation: FeedCardPresentation?,
        band: FeedLoader.FeedLayout
    ) -> MainFeedCardValue {
        let affordances = affordances(for: item)
        let slot = mediaSlot(
            for: item,
            presentation: presentation,
            band: band,
            placeholderKind: placeholderKind(affordances.placeholder)
        )

        let layout: CardPresentation.Layout
        switch slot {
        case .none:
            layout = .textOnly
        case .empty, .local, .placeholder:
            layout = band == .list ? .thumbnail : .hero
        }

        let media: CardPresentation.Media
        switch slot {
        case .none:
            media = .none
        case .empty:
            // The frame is reserved and there is nothing to fill it with: no bytes and, because a
            // stand-in was rejected, no placeholder either.
            media = .none
        case .local(let image):
            media = .local(assetDigest: image.cacheKey)
        case .placeholder(let kind):
            media = .placeholder(reason: kind.rawValue)
        }

        let card = CardPresentation(
            id: cardID(forLegacyItemID: item.id),
            absoluteOrdinal: ordinal,
            title: item.title,
            subtitle: item.excerpt.isEmpty ? nil : item.excerpt,
            media: media,
            layout: layout,
            isBookmarked: item.isBookmarked,
            isRead: item.isRead,
            affordances: affordances
        )
        return MainFeedCardValue(card: card, mediaSlot: slot)
    }

    /// The V2 card and the slot for one item of a surface that publishes without a page ordinal
    /// (source detail, collection detail, onboarding preview).
    ///
    /// Those surfaces are PR-14's; until they move, they state their items through the same bridge, so
    /// no view has to infer anything from the item itself.
    static func card(
        item: FeedItem,
        presentation: FeedCardPresentation?,
        band: FeedLoader.FeedLayout
    ) -> MainFeedCardValue {
        value(item: item, ordinal: 0, presentation: presentation, band: band)
    }

    static func placeholderKind(
        _ placeholder: CardPresentation.Affordances.Placeholder
    ) -> PlaceholderKind {
        switch placeholder {
        case .article: return .article
        case .video: return .video
        case .podcast: return .podcast
        case .forum: return .forum
        }
    }

    /// The bridge's card identity for a legacy item.
    ///
    /// A `PublicationCardID` is allocated by the runtime and lives in the runtime database
    /// (ADR-003); this bridge has neither, so it carries a *deterministic alias* over the legacy id
    /// instead of an allocation: the same item keeps the same card identity across relaunches,
    /// refreshes and editions, which is what the card-identity contract requires (ADR-001), and the
    /// legacy id remains the real key everywhere else. The digest is opaque — it is never reversed and
    /// never compared to another id space — and the runtime replaces it with a real allocation when it
    /// owns publication (PR-14).
    static func cardID(forLegacyItemID id: String) -> PublicationCardID {
        let digest = SHA256.hash(data: Data(id.utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(8) { value = (value << 8) | UInt64(byte) }
        // `PublicationCardID` reserves zero and rejects negatives, so the alias is clamped into
        // `1 ... Int64.max`; the digest is 63 bits wide, so a collision needs a SHA-256 collision.
        let mapped = Int64(bitPattern: value & 0x7FFF_FFFF_FFFF_FFFF)
        let raw = mapped == 0 ? 1 : mapped
        do {
            return try PublicationCardID(raw)
        } catch {
            preconditionFailure("alias \(raw) is inside the allocatable range and cannot be refused")
        }
    }
}
