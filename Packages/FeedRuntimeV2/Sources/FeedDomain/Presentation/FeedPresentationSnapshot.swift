import Foundation

/// The presentation vocabulary shared by the session and the feed screen (plan §11, ADR-002 D7/D12).
///
/// These value types live in `FeedDomain`, not in `FeedUIBridge`, and that placement is a decision
/// rather than a move for tidiness: `FeedRuntime` *produces* snapshots and may not import the UI
/// bridge (`FeedUIBridge → FeedRuntime` is the only direction the boundary table allows), so the
/// same vocabulary declared in the bridge would have to be duplicated in the runtime. One definition
/// is the single visual authority: the session fills a `FeedPresentationSnapshot`, `FeedScreenStore`
/// applies it and the renderer draws it.
///
/// A snapshot carries what a renderer needs and nothing else: no canonical record, no wire payload,
/// no view index used as identity. Media travels as an identity plus a layout decision, never as an
/// image, and a card whose bytes are not materialized is drawn from a deterministic placeholder
/// without touching the network (plan §10).

/// Identity of a session generation. Results produced for another stamp are discarded (plan §11).
///
/// The stamp is what makes a late result harmless: an effect, a checkpoint or an exposure flush that
/// carries a stamp older than the current session cannot be attached to the visible state
/// (ADR-007 D11).
public struct SessionStamp: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "session:\(rawValue)" }
}

public enum PresentationContractError: Error, Equatable, Sendable {
    case emptyRenderEnvironmentField(String)
    case nonPositiveDisplayScale(Int)
    case anchorOffsetOutOfRange(Double)
    case anchorOrdinalNegative(Int)
}

/// What changes how the *same* edition materializes (ADR-002 D7).
///
/// It is deliberately not an editorial input and never part of an edition's identity: a Dynamic Type
/// change, a rotation or a locale change re-materializes the same `PublicationCardID`s and must not
/// re-run Selection, which is exactly what `dynamicTypePreservesEditionAndCardIDs` pins.
/// Serialization order is the declaration order, so a persisted value compares across launches.
public struct RenderEnvironmentRevision: Hashable, Sendable, CustomStringConvertible {
    public let layoutWidthClass: String
    public let dynamicTypeSize: String
    public let localeIdentifier: String
    public let textDirection: String
    public let displayScale: Int

    public init(
        layoutWidthClass: String,
        dynamicTypeSize: String,
        localeIdentifier: String,
        textDirection: String,
        displayScale: Int
    ) throws {
        for (name, value) in [
            ("layoutWidthClass", layoutWidthClass),
            ("dynamicTypeSize", dynamicTypeSize),
            ("localeIdentifier", localeIdentifier),
            ("textDirection", textDirection),
        ] where value.isEmpty {
            throw PresentationContractError.emptyRenderEnvironmentField(name)
        }
        guard displayScale > 0 else {
            throw PresentationContractError.nonPositiveDisplayScale(displayScale)
        }
        self.layoutWidthClass = layoutWidthClass
        self.dynamicTypeSize = dynamicTypeSize
        self.localeIdentifier = localeIdentifier
        self.textDirection = textDirection
        self.displayScale = displayScale
    }

    /// The revision a test or a preview starts from; production reads the live environment once.
    public static let unspecified = RenderEnvironmentRevision(
        uncheckedWidthClass: "-",
        dynamicTypeSize: "-",
        localeIdentifier: "-",
        textDirection: "-",
        displayScale: 1
    )

    /// Compile-time constant initializer: validation would have to fail, and a constant is not
    /// allowed to trap (no force unwraps in library code).
    private init(
        uncheckedWidthClass layoutWidthClass: String,
        dynamicTypeSize: String,
        localeIdentifier: String,
        textDirection: String,
        displayScale: Int
    ) {
        self.layoutWidthClass = layoutWidthClass
        self.dynamicTypeSize = dynamicTypeSize
        self.localeIdentifier = localeIdentifier
        self.textDirection = textDirection
        self.displayScale = displayScale
    }

    public var canonicalSerialization: String {
        "\(layoutWidthClass)|\(dynamicTypeSize)|\(localeIdentifier)|\(textDirection)|\(displayScale)"
    }

    public var description: String { "render-env:\(canonicalSerialization)" }
}

/// Where the reader is, in identities rather than in pixels (plan §11, ADR-007 `session_checkpoint`).
///
/// The anchor is the pair `PublicationCardID` + `absoluteOrdinal` plus how far the card was scrolled
/// past, expressed as a fraction of its height. Both scalars and no array position: a window that
/// re-materializes a different set of rows must still find the same card at the same offset, which an
/// index could never prove.
public struct FeedWindowAnchor: Hashable, Sendable, CustomStringConvertible {
    public let editionID: EditionID
    public let cardID: PublicationCardID
    public let absoluteOrdinal: Int
    /// How much of the anchor card is above the viewport top, in `-1.0 ... 1.0`.
    public let offsetFraction: Double

    public init(
        editionID: EditionID,
        cardID: PublicationCardID,
        absoluteOrdinal: Int,
        offsetFraction: Double
    ) throws {
        guard absoluteOrdinal >= 0 else {
            throw PresentationContractError.anchorOrdinalNegative(absoluteOrdinal)
        }
        guard offsetFraction >= -1.0, offsetFraction <= 1.0 else {
            throw PresentationContractError.anchorOffsetOutOfRange(offsetFraction)
        }
        self.editionID = editionID
        self.cardID = cardID
        self.absoluteOrdinal = absoluteOrdinal
        self.offsetFraction = offsetFraction
    }

    /// The anchor that sits at the top of a card. Cannot fail: the offset is fixed at zero and the
    /// ordinal comes from a stored `absolute_ordinal`, which the schema constrains to be non-negative.
    public static func top(of cardID: PublicationCardID, ordinal: Int, editionID: EditionID) -> FeedWindowAnchor {
        FeedWindowAnchor(
            uncheckedEditionID: editionID,
            cardID: cardID,
            absoluteOrdinal: ordinal,
            offsetFraction: 0
        )
    }

    private init(
        uncheckedEditionID editionID: EditionID,
        cardID: PublicationCardID,
        absoluteOrdinal: Int,
        offsetFraction: Double
    ) {
        self.editionID = editionID
        self.cardID = cardID
        self.absoluteOrdinal = absoluteOrdinal
        self.offsetFraction = offsetFraction
    }

    /// The same position under a successor edition (ADR-007 D8: a new edition restarts the namespace).
    public func replacingEdition(_ editionID: EditionID) throws -> FeedWindowAnchor {
        try FeedWindowAnchor(
            editionID: editionID,
            cardID: cardID,
            absoluteOrdinal: absoluteOrdinal,
            offsetFraction: offsetFraction
        )
    }

    public var description: String {
        "anchor:\(cardID)@\(absoluteOrdinal) offset=\(offsetFraction)"
    }
}

/// The whole visual state of one feed screen (plan §11).
///
/// `sequence` is monotonic per session; the store rejects a snapshot that is not newer. Old
/// snapshots are not merged and not replayed: the stream is latest-state, and durable intents travel
/// on their own path.
public struct FeedPresentationSnapshot: Hashable, Sendable {
    public let sessionStamp: SessionStamp
    /// Monotonic per session; the store rejects anything not newer.
    public let sequence: UInt64
    public let contextKey: String
    public let editionID: EditionID?
    public let editorialRevision: EditorialRevision?
    public let renderEnvironment: RenderEnvironmentRevision
    public let cards: [CardPresentation]

    public init(
        sessionStamp: SessionStamp,
        sequence: UInt64,
        contextKey: String,
        editionID: EditionID?,
        editorialRevision: EditorialRevision?,
        renderEnvironment: RenderEnvironmentRevision,
        cards: [CardPresentation]
    ) {
        self.sessionStamp = sessionStamp
        self.sequence = sequence
        self.contextKey = contextKey
        self.editionID = editionID
        self.editorialRevision = editorialRevision
        self.renderEnvironment = renderEnvironment
        self.cards = cards
    }
}

public struct CardPresentation: Hashable, Sendable, Identifiable {
    public enum Media: Hashable, Sendable {
        /// Bytes are already local and pinned; the digest is the identity, not the URL.
        case local(assetDigest: String)
        /// A deterministic placeholder must be drawn; no network is allowed to fill it.
        case placeholder(reason: String)
        case none
    }

    public enum Layout: Hashable, Sendable {
        case hero
        case thumbnail
        case textOnly

        public init(_ kind: RenderKind) {
            switch kind {
            case .hero: self = .hero
            case .thumb: self = .thumbnail
            case .textOnly: self = .textOnly
            }
        }
    }

    /// The chrome a card draws, decided by the producer (plan §14 PR-13).
    ///
    /// What was inferred inside the views — from the item's URL shape, its source string or the
    /// presence of an audio enclosure — is a runtime decision, and this is where it is stated: which
    /// placeholder the media slot fills, which badge the source row carries, which glyph overlays the
    /// media slot, which duration the card shows, and what a tap means. A renderer draws these cases;
    /// it never inspects data to recover them, so a new protocol, a new source host or a new enclosure
    /// shape cannot change a card's behaviour by accident.
    ///
    /// The cases name decisions, not assets or copy: labels, colours and image names stay in the
    /// renderer.
    public struct Affordances: Hashable, Sendable {
        /// Which deterministic placeholder the media slot draws. Naming a file is the renderer's job;
        /// choosing the kind is the producer's.
        public enum Placeholder: String, Hashable, Sendable {
            case article
            case video
            case podcast
            case forum
        }

        /// The glyph drawn on top of a filled media slot.
        public enum Overlay: Hashable, Sendable {
            case play
            case headphones
        }

        /// A badge on the source row. `new` is the recency badge; it is never deduced by the renderer.
        public enum Badge: Hashable, Sendable {
            case video
            case podcast
            case new
        }

        /// What a tap does, on the card and on its media slot.
        public enum Tap: Hashable, Sendable {
            /// The card opens the reader and the media slot is inert.
            case openReader
            /// The whole card plays audio: the link is itself the audio.
            case playAudio
            /// A text tap opens the reader; the media slot plays audio.
            case openReaderOrPlayAudioFromMedia
        }

        public let placeholder: Placeholder
        public let overlay: Overlay?
        public let badges: [Badge]
        /// The duration to show, already formatted, when the card's media carries one.
        public let durationLabel: String?
        public let tap: Tap

        public init(
            placeholder: Placeholder,
            overlay: Overlay?,
            badges: [Badge],
            durationLabel: String?,
            tap: Tap
        ) {
            self.placeholder = placeholder
            self.overlay = overlay
            self.badges = badges
            self.durationLabel = durationLabel
            self.tap = tap
        }

        /// The chrome of a producer that has no protocol information to state: the neutral
        /// placeholder, no badge, no overlay, and a tap that opens the reader.
        ///
        /// This is a decision, not a gap — "draw nothing protocol-specific" — and a renderer that
        /// receives it must not fill the blank by looking at the data.
        public static let undecided = Affordances(
            placeholder: .article,
            overlay: nil,
            badges: [],
            durationLabel: nil,
            tap: .openReader
        )
    }

    public let id: PublicationCardID
    public let absoluteOrdinal: Int
    public let title: String
    public let subtitle: String?
    public let media: Media
    public let layout: Layout
    public let isBookmarked: Bool
    public let isRead: Bool
    /// Defaulted so a producer that has no protocol decision yet states it explicitly (`.undecided`)
    /// instead of being blocked from publishing a card.
    public let affordances: Affordances
    /// The instant the revision declared for this card, when it declared one. `nil` means the document
    /// declared no date: a producer never substitutes the observation time for it (ADR-001 D4).
    public let publishedAt: Date?
    /// The source's display name as the revision froze it, for the line the renderer draws under the
    /// title. `nil` when the revision was attributed to no source.
    public let sourceTitle: String?
    /// The address a tap opens, when the revision's primary action is an external URL.
    ///
    /// `nil` is a statement, not a gap: a revision that declared no action publishes no address, and a
    /// view never synthesizes one (Blueprint §11). A card whose action is not an external URL (a local
    /// detail, published bytes) carries none either, and the renderer must not invent one from the data.
    public let link: URL?

    public init(
        id: PublicationCardID,
        absoluteOrdinal: Int,
        title: String,
        subtitle: String?,
        media: Media,
        layout: Layout,
        isBookmarked: Bool,
        isRead: Bool,
        affordances: Affordances = .undecided,
        publishedAt: Date? = nil,
        sourceTitle: String? = nil,
        link: URL? = nil
    ) {
        self.id = id
        self.absoluteOrdinal = absoluteOrdinal
        self.title = title
        self.subtitle = subtitle
        self.media = media
        self.layout = layout
        self.isBookmarked = isBookmarked
        self.isRead = isRead
        self.affordances = affordances
        self.publishedAt = publishedAt
        self.sourceTitle = sourceTitle
        self.link = link
    }
}

/// Small, explicit intents. Scroll reports a viewport; it does not request a fetch (I-20).
///
/// Every case is a value the UI can build without knowing the runtime: no selection, no network and no
/// decode is reachable from here. `viewportChanged` carries the anchor the renderer currently holds,
/// which is the only way the cursor survives eviction without a second source of truth.
public enum FeedSessionIntent: Equatable, Sendable {
    case viewportChanged(
        firstVisibleOrdinal: Int,
        lastVisibleOrdinal: Int,
        anchor: FeedWindowAnchor?
    )
    /// One card's visibility, as the renderer observes it: the fraction of its area on screen and
    /// whether this is an entry edge, a plain sample or a left edge (ADR-007 D2).
    ///
    /// This is telemetry, not a request: it is coalesced by the tracker and never starts a fetch, a
    /// decode or a composition (invariant H-16). `onAppear` is deliberately not modelled here.
    case cardVisibility(ViewportObservation)
    /// Center crossing is a weaker fact than dwell and is reported on both edges (ADR-007 D5).
    case centerCrossed(cardID: PublicationCardID, direction: Int)
    /// The reader opened one card: the explicit primary action ADR-007 D5 records as `opened` and the
    /// explicit reader session that grants `read`.
    ///
    /// The operation id is the app's, exactly as `toggleBookmark`'s is: the `read` fact D7 keys by the
    /// durable user-state operation that owns it, so it cannot be minted by whoever happens to run the
    /// effect, and a retry of the same operation is a no-op in every store it reaches.
    case opened(cardID: PublicationCardID, operationID: String)
    case toggleBookmark(cardID: PublicationCardID, wanted: Bool, operationID: String)
    case refresh
    case switchContext(ContextKey)
}

/// The cursor of one surface, as it survives a relaunch (ADR-002's `session_checkpoint`).
///
/// It records where the reader was — context, edition, card, ordinal, offset — plus the render
/// environment and policy version that were in force, so a restore can tell "the same position under
/// the same rules" from "a position that has to be re-materialized". It is never a pixel offset and
/// never an array index: a re-materialized window finds the same card or reports that it cannot.
public struct SessionCheckpoint: Hashable, Sendable, CustomStringConvertible {
    public let context: ContextKey
    public let editionID: EditionID
    public let anchor: FeedWindowAnchor
    public let renderEnvironmentRevision: RenderEnvironmentRevision
    /// The history policy version whose exclusion rules were in force.
    public let policyVersion: String
    public let updatedAtMs: Int64

    /// The anchor's edition is the checkpoint's edition: two sources for one fact would be a defect.
    public init(
        context: ContextKey,
        editionID: EditionID,
        anchor: FeedWindowAnchor,
        renderEnvironmentRevision: RenderEnvironmentRevision,
        policyVersion: String,
        updatedAtMs: Int64
    ) {
        self.context = context
        self.editionID = editionID
        self.anchor = anchor.editionID == editionID
            ? anchor
            : (try? anchor.replacingEdition(editionID)) ?? anchor
        self.renderEnvironmentRevision = renderEnvironmentRevision
        self.policyVersion = policyVersion
        self.updatedAtMs = updatedAtMs
    }

    public var description: String {
        "checkpoint:\(context.canonicalSerialization) \(editionID) \(anchor)"
    }
}
