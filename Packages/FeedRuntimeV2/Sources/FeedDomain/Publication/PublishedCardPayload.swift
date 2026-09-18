import Foundation

/// What one published card freezes (ADR-001 D4, D5, D12, D14, D16; plan §9).
///
/// The payload is self-sufficient: text, chosen attribution/membership, timestamp with its epistemic
/// kind, media identity, primary action, interaction summary and the render contract all travel with
/// the card, plus the copied revision identity and `PublicationSchemaVersion`. No mandatory join to
/// `origin_record` or `origin_revision` is permitted at restore, render or window materialisation, so
/// canonical eviction or an authorized purge leaves every published card readable (INV-2, INV-6).

// MARK: - Attribution and membership

/// The attribution the publication chose, copied rather than referenced (ADR-001 D4).
///
/// `sourceID`/`providerID` are the runtime's own identities; the display names are the values as they
/// read at publication time, so renaming a source or a provider never rewrites a published card
/// (ADR-003 D5: the provider is attribution, the source is editorial grouping).
public struct PublishedOrigin: Hashable, Sendable {
    public let originRecordID: OriginRecordID
    public let originRevisionID: OriginRevisionID
    public let sourceID: SourceID?
    public let providerID: ProviderID?
    public let sourceDisplayName: String?
    public let providerDisplayName: String?

    public init(
        originRecordID: OriginRecordID,
        originRevisionID: OriginRevisionID,
        sourceID: SourceID? = nil,
        providerID: ProviderID? = nil,
        sourceDisplayName: String? = nil,
        providerDisplayName: String? = nil
    ) {
        self.originRecordID = originRecordID
        self.originRevisionID = originRevisionID
        self.sourceID = sourceID
        self.providerID = providerID
        self.sourceDisplayName = sourceDisplayName
        self.providerDisplayName = providerDisplayName
    }
}

// MARK: - Timestamps

/// Which date the payload's timestamp actually is (ADR-003 D17, Blueprint §35).
///
/// `none` means the revision declared no date and the payload refuses to synthesize one; the card
/// then sorts by `observationAt`, which is always the local observation time.
public enum PublishedTimestampKind: String, Hashable, Sendable, CaseIterable {
    case authored
    case modified
    case observed
    case none
}

// MARK: - Media identity

/// The slot an asset reference occupies on a card.
public enum PublishedAssetSlot: String, Hashable, Sendable, CaseIterable {
    case primary
    case alternate
    case poster
    case thumbnail
    case waveform
}

/// The identity of one immutable asset version: the digest of its exact bytes plus the recipe that
/// produced them (ADR-001 D12).
///
/// There is deliberately no URL and no local row id here: a URL is never an identity (a server can
/// swap the bytes behind a stable one), and the row id is a storage detail of one database. The
/// identity is comparable across databases, which is what makes "the same card keeps the same media"
/// provable.
public struct PublishedMediaRef: Hashable, Sendable, CustomStringConvertible {
    /// Lowercase hex SHA-256 over the exact bytes as committed, before any transformation.
    public let contentDigest: String
    /// Version of the transformation recipe that produced the bytes.
    public let recipeVersion: Int
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let mimeType: String

    public init(
        contentDigest: String,
        recipeVersion: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        mimeType: String
    ) {
        self.contentDigest = contentDigest
        self.recipeVersion = recipeVersion
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.mimeType = mimeType
    }

    /// The published aspect ratio; `nil` when the dimensions are unknown, in which case the renderer
    /// uses its slot default instead of inventing a ratio.
    public var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    /// The identity as text: `digest_r<recipe>`. Never a URL.
    public var reference: String { "\(contentDigest)_r\(recipeVersion)" }

    public var description: String { reference }
}

/// One reference from a card to an asset version, with the role and the slot it was chosen for.
public struct PublishedAssetReference: Hashable, Sendable {
    public let slot: PublishedAssetSlot
    public let role: MediaRole
    public let renderSlot: MediaSlot
    public let media: PublishedMediaRef

    public init(slot: PublishedAssetSlot, role: MediaRole, renderSlot: MediaSlot, media: PublishedMediaRef) {
        self.slot = slot
        self.role = role
        self.renderSlot = renderSlot
        self.media = media
    }
}

/// The deterministic stand-in a renderer draws when bytes were never prepared or were removed
/// (ADR-001 D14, ADR-004 D10).
///
/// The seed derives from the copied revision identity and the slot — durable, database-comparable
/// values — never from a URL and never from a per-process hash, so the same card always lays out the
/// same way (`Swift.Hasher` is seeded per process and would not survive a relaunch).
public struct PublishedPlaceholder: Hashable, Sendable {
    /// The placeholder recipe's own version, independent of the asset's recipe (ADR-001 D9).
    public static let currentRecipeVersion = 1

    public let recipeVersion: Int
    public let slot: MediaSlot
    public let aspectRatio: Double?
    public let seed: UInt64

    public init(
        originRevisionID: OriginRevisionID,
        slot: MediaSlot,
        aspectRatio: Double?,
        recipeVersion: Int = currentRecipeVersion
    ) {
        self.recipeVersion = recipeVersion
        self.slot = slot
        self.aspectRatio = aspectRatio
        self.seed = Self.seed(originRevisionID: originRevisionID, slot: slot)
    }

    /// FNV-1a over the revision identity and the slot: deterministic across launches and devices.
    static func seed(originRevisionID: OriginRevisionID, slot: MediaSlot) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var material = Data(String(originRevisionID.rawValue).utf8)
        material.append(0x00)
        material.append(Data(slot.rawValue.utf8))
        for byte in material {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// The media set of one published card: an integral primary asset, secondary references and, when a
/// renderable slot was declared but its bytes were never prepared, a deterministic placeholder.
public struct PublishedMediaSet: Hashable, Sendable {
    public let primary: PublishedMediaRef?
    public let alternates: [PublishedAssetReference]
    /// `nil` when a real asset fills the card's media slot; never a second choice beside `primary`.
    public let placeholder: PublishedPlaceholder?

    public static let none = PublishedMediaSet(primary: nil, alternates: [], placeholder: nil)

    public init(
        primary: PublishedMediaRef?,
        alternates: [PublishedAssetReference],
        placeholder: PublishedPlaceholder?
    ) {
        self.primary = primary
        self.alternates = alternates.sorted { lhs, rhs in
            lhs.slot.rawValue == rhs.slot.rawValue
                ? lhs.media.reference < rhs.media.reference
                : lhs.slot.rawValue < rhs.slot.rawValue
        }
        self.placeholder = placeholder
    }

    /// Every reference the card holds, primary first then the sorted alternates.
    public var references: [PublishedAssetReference] {
        var all: [PublishedAssetReference] = []
        if let primary {
            all.append(
                PublishedAssetReference(slot: .primary, role: .image, renderSlot: .primary, media: primary)
            )
        }
        all.append(contentsOf: alternates)
        return all
    }

    /// Whether the card needs media bytes at all: text-only cards render with zero network.
    public var requiresMediaBytes: Bool { primary != nil }
}

// MARK: - Actions

/// Opaque handle of a connector-offered action (ADR-001 D16, Blueprint §50).
public struct ActionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw PublicationPayloadError.emptyActionID }
        self.rawValue = rawValue
    }

    public var description: String { "action:\(rawValue)" }
}

/// Handle of a conversation the card may open. Opaque: the runtime never parses it.
public struct InteractionHandle: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw PublicationPayloadError.emptyInteractionHandle }
        self.rawValue = rawValue
    }

    public var description: String { "thread:\(rawValue)" }
}

public enum PublicationPayloadError: Error, Equatable, Sendable {
    case emptyActionID
    case emptyInteractionHandle
    case emptyMediaCandidateKey
    case malformedActionReference(kind: FeedPrimaryAction.Kind, reference: String)
    case malformedTimestampMilliseconds(Int64)
}

/// The primary action a card carries, frozen as a handle rather than a protocol branch.
///
/// Absence of an action is valid, and a URL is never synthesized to satisfy a view: a revision with no
/// link and no offer publishes no action (plan §19 additional decisions, Blueprint §11).
public enum FeedPrimaryAction: Hashable, Sendable {
    case externalURL(URL)
    case localContentDetail(PublicationCardID)
    /// Playback of already published bytes, named by the asset reference text (never by a URL).
    case mediaPlayback(String)
    case thread(InteractionHandle)
    case connectorAction(ActionID)

    /// The closed vocabulary the stored `primary_action_kind` column may hold.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case externalURL
        case localContentDetail
        case mediaPlayback
        case thread
        case connectorAction
    }

    public var kind: Kind {
        switch self {
        case .externalURL: return .externalURL
        case .localContentDetail: return .localContentDetail
        case .mediaPlayback: return .mediaPlayback
        case .thread: return .thread
        case .connectorAction: return .connectorAction
        }
    }

    /// The frozen handle exactly as it is stored in `primary_action_reference`.
    public var reference: String {
        switch self {
        case let .externalURL(url): return url.absoluteString
        case let .localContentDetail(cardID): return cardID.description
        case let .mediaPlayback(assetReference): return assetReference
        case let .thread(handle): return handle.rawValue
        case let .connectorAction(actionID): return actionID.rawValue
        }
    }

    /// Rebuilds the action from the two stored columns. A reference that no longer parses is a
    /// malformed payload, never a silently dropped action (INV-2).
    public static func decode(kind: Kind, reference: String) throws -> FeedPrimaryAction {
        switch kind {
        case .externalURL:
            guard let url = URL(string: reference), url.scheme != nil else {
                throw PublicationPayloadError.malformedActionReference(kind: kind, reference: reference)
            }
            return .externalURL(url)
        case .localContentDetail:
            guard reference.hasPrefix("card:"),
                  let raw = Int64(reference.dropFirst("card:".count))
            else {
                throw PublicationPayloadError.malformedActionReference(kind: kind, reference: reference)
            }
            return .localContentDetail(try PublicationCardID(raw))
        case .mediaPlayback:
            guard !reference.isEmpty else {
                throw PublicationPayloadError.malformedActionReference(kind: kind, reference: reference)
            }
            return .mediaPlayback(reference)
        case .thread:
            return .thread(try InteractionHandle(reference))
        case .connectorAction:
            return .connectorAction(try ActionID(reference))
        }
    }
}

// MARK: - The payload

/// Everything one published card renders, frozen at publication (ADR-001 D4, D5).
///
/// The payload is split from the occurrence identity on purpose. `PublicationCardID` is allocated by
/// the runtime when the card row is inserted, so a composition cannot know it while it freezes the
/// payload — and a canonical serialization may never contain a local row id, or two databases built
/// from the same fixture could not compare byte for byte (plan §5.1, ADR-002 D3). The digest is
/// therefore taken over the frozen content alone, and the identity travels beside it.
public struct PublishedCardPayload: Hashable, Sendable {
    /// The frozen content, without the runtime identity.
    public struct Frozen: Hashable, Sendable {
        public let editionID: EditionID
        public let segmentOrdinal: Int
        public let absoluteOrdinal: Int
        public let origin: PublishedOrigin
        public let title: String?
        public let primaryText: String?
        public let publishedAt: Date?
        public let publishedAtKind: PublishedTimestampKind
        public let observationAt: Date
        public let media: PublishedMediaSet
        public let primaryAction: FeedPrimaryAction?
        public let interactionSummary: String?
        public let renderContract: RenderContract
        /// The editorial revision the composition ran under, copied into the card (ADR-002 D2).
        public let editorialRevision: EditorialRevision
        public let publicationSchemaVersion: Int

        public init(
            editionID: EditionID,
            segmentOrdinal: Int,
            absoluteOrdinal: Int,
            origin: PublishedOrigin,
            title: String?,
            primaryText: String?,
            publishedAt: Date?,
            publishedAtKind: PublishedTimestampKind,
            observationAt: Date,
            media: PublishedMediaSet,
            primaryAction: FeedPrimaryAction?,
            interactionSummary: String?,
            renderContract: RenderContract,
            editorialRevision: EditorialRevision,
            publicationSchemaVersion: Int = PublicationSchema.currentVersion
        ) {
            self.editionID = editionID
            self.segmentOrdinal = segmentOrdinal
            self.absoluteOrdinal = absoluteOrdinal
            self.origin = origin
            self.title = title
            self.primaryText = primaryText
            self.publishedAt = publishedAt
            self.publishedAtKind = publishedAtKind
            self.observationAt = observationAt
            self.media = media
            self.primaryAction = primaryAction
            self.interactionSummary = interactionSummary
            self.renderContract = renderContract
            self.editorialRevision = editorialRevision
            self.publicationSchemaVersion = publicationSchemaVersion
        }

        /// The date the card sorts and displays by. A missing declared date falls back to the
        /// observation time, which `publishedAtKind` states rather than disguising as an authored one.
        public var sortDate: Date { publishedAt ?? observationAt }

        /// The semantic serialization of the frozen payload.
        ///
        /// Every stored payload column participates — except `publication_card_id`, which is the
        /// runtime's local allocation — and nothing else does: no `asset_version` row id, no media URL,
        /// no render environment. A restore recomputes the digest of these bytes to prove the payload is
        /// intact (ADR-002 D8 R3).
        public func canonicalSerialization() -> Data {
            var writer = CanonicalSerialization()
            writer.integer("editionID", editionID.rawValue)
            writer.integer("segmentOrdinal", Int64(segmentOrdinal))
            writer.integer("absoluteOrdinal", Int64(absoluteOrdinal))
            writer.integer("originRecordID", origin.originRecordID.rawValue)
            writer.integer("originRevisionID", origin.originRevisionID.rawValue)
            writer.integer("sourceID", origin.sourceID.map { Int64($0.rawValue) } ?? -1)
            writer.integer("providerID", origin.providerID.map { Int64($0.rawValue) } ?? -1)
            writer.string("sourceDisplayName", origin.sourceDisplayName ?? "")
            writer.string("providerDisplayName", origin.providerDisplayName ?? "")
            writer.string("title", title ?? "")
            writer.string("primaryText", primaryText ?? "")
            writer.integer("publishedAtMs", publishedAt.map(Self.milliseconds) ?? -1)
            writer.string("publishedAtKind", publishedAtKind.rawValue)
            writer.integer("observationAtMs", Self.milliseconds(observationAt))
            writer.string("media", media.canonicalElement())
            writer.string("actionKind", primaryAction?.kind.rawValue ?? "")
            writer.string("actionReference", primaryAction?.reference ?? "")
            writer.string("interactionSummary", interactionSummary ?? "")
            writer.integer("renderContractVersion", Int64(renderContract.version))
            writer.string("renderKind", renderContract.kind.rawValue)
            writer.string("renderMediaSlot", renderContract.mediaSlot.rawValue)
            writer.string("renderAspectRatio", renderContract.aspectRatio.map { String($0) } ?? "")
            writer.integer("editorialRevisionScheme", Int64(editorialRevision.schemeVersion))
            writer.string("editorialRevision", editorialRevision.digest)
            writer.integer("publicationSchemaVersion", Int64(publicationSchemaVersion))
            return writer.data
        }

        /// Lowercase hex SHA-256 of `canonicalSerialization()`, stored beside the card row.
        public func frozenDigest() -> String { EditorialSHA256.hex(of: canonicalSerialization()) }

        /// Milliseconds since the Unix epoch, the runtime's only persisted time representation.
        public static func milliseconds(_ date: Date) -> Int64 {
            Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        }

        public static func date(milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
    }

    /// The occurrence identity: the SwiftUI identity of this card (ADR-001 D2).
    public let cardID: PublicationCardID
    public let frozen: Frozen

    public init(cardID: PublicationCardID, frozen: Frozen) {
        self.cardID = cardID
        self.frozen = frozen
    }

    // The frozen fields, forwarded so a caller reads a card rather than a card and a box.
    public var editionID: EditionID { frozen.editionID }
    public var segmentOrdinal: Int { frozen.segmentOrdinal }
    public var absoluteOrdinal: Int { frozen.absoluteOrdinal }
    public var origin: PublishedOrigin { frozen.origin }
    public var title: String? { frozen.title }
    public var primaryText: String? { frozen.primaryText }
    public var publishedAt: Date? { frozen.publishedAt }
    public var publishedAtKind: PublishedTimestampKind { frozen.publishedAtKind }
    public var observationAt: Date { frozen.observationAt }
    public var media: PublishedMediaSet { frozen.media }
    public var primaryAction: FeedPrimaryAction? { frozen.primaryAction }
    public var interactionSummary: String? { frozen.interactionSummary }
    public var renderContract: RenderContract { frozen.renderContract }
    public var editorialRevision: EditorialRevision { frozen.editorialRevision }
    public var publicationSchemaVersion: Int { frozen.publicationSchemaVersion }
    public var sortDate: Date { frozen.sortDate }

    /// Lowercase hex SHA-256 of the frozen content, exactly as the card row stores it.
    public func frozenDigest() -> String { frozen.frozenDigest() }

    public static func milliseconds(_ date: Date) -> Int64 { Frozen.milliseconds(date) }
    public static func date(milliseconds: Int64) -> Date { Frozen.date(milliseconds: milliseconds) }
}


/// The media set as one canonical element of the payload digest.
extension PublishedMediaSet {
    func canonicalElement() -> String {
        var writer = CanonicalSerialization()
        writer.string("primary", primary?.reference ?? "")
        writer.integer("primaryWidth", Int64(primary?.pixelWidth ?? -1))
        writer.integer("primaryHeight", Int64(primary?.pixelHeight ?? -1))
        writer.string("primaryMime", primary?.mimeType ?? "")
        writer.list("alternates", alternates.map { reference in
            CanonicalSerialization.element { element in
                element.string("slot", reference.slot.rawValue)
                element.string("role", reference.role.rawValue)
                element.string("renderSlot", reference.renderSlot.rawValue)
                element.string("reference", reference.media.reference)
                element.integer("width", Int64(reference.media.pixelWidth ?? -1))
                element.integer("height", Int64(reference.media.pixelHeight ?? -1))
                element.string("mime", reference.media.mimeType)
            }
        })
        writer.string("placeholderSlot", placeholder?.slot.rawValue ?? "")
        writer.string("placeholderRecipeVersion", String(placeholder?.recipeVersion ?? 0))
        writer.string("placeholderAspectRatio", placeholder?.aspectRatio.map { String($0) } ?? "")
        writer.string("placeholderSeed", String(placeholder?.seed ?? 0))
        return String(decoding: writer.data, as: UTF8.self)
    }
}

// MARK: - Composition input

/// One media candidate as the canonical group declares it, without its URL.
///
/// The publication path never sees a resource URL: a URL is not an identity and not a cache key
/// (ADR-001 D12), and the minimal publication path needs only the declared role, the position that
/// keyes the candidate and the declared geometry.
public struct DeclaredMediaCandidate: Hashable, Sendable {
    public let role: MediaRole
    public let position: Int
    public let mediaTypeHint: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        role: MediaRole,
        position: Int,
        mediaTypeHint: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.role = role
        self.position = position
        self.mediaTypeHint = mediaTypeHint
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// The connector-scoped locator identity of one candidate: role plus declared position.
    ///
    /// Deliberately not the URL and not the row id: the key must survive a server swapping bytes
    /// behind a stable URL (ADR-001 D12) and a database rebuilt from the same feed.
    public var candidateKey: String { "\(role.rawValue)#\(position)" }

    /// The declared aspect ratio, when the connector declared both dimensions.
    public var declaredAspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// One capability the revision offers, without the protocol that produced it.
public struct DeclaredInteractionOffer: Hashable, Comparable, Sendable {
    public let kind: String
    public let handle: String?
    public let position: Int

    public init(kind: String, handle: String?, position: Int) {
        self.kind = kind
        self.handle = handle
        self.position = position
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.position == rhs.position ? lhs.kind < rhs.kind : lhs.position < rhs.position
    }
}

/// The canonical content one revision of one record holds, read at composition time so the publication
/// can freeze it.
///
/// This is a *read* of `origin_record`/`origin_revision` plus the canonical group: it is what the
/// composition freezes, and it is why a later catalog or attribution edit cannot rewrite the card.
public struct PublicationCardContent: Hashable, Sendable {
    public let originRecordID: OriginRecordID
    public let originRevisionID: OriginRevisionID
    public let sourceID: SourceID?
    public let providerID: ProviderID?
    public let sourceDisplayName: String?
    public let providerDisplayName: String?
    public let headline: String?
    public let summary: String?
    public let bodyText: String?
    public let primaryLink: String?
    public let authoredAt: Date?
    public let modifiedAt: Date?
    public let observedAt: Date
    public let mediaCandidates: [DeclaredMediaCandidate]
    public let offers: [DeclaredInteractionOffer]

    public init(
        originRecordID: OriginRecordID,
        originRevisionID: OriginRevisionID,
        sourceID: SourceID? = nil,
        providerID: ProviderID? = nil,
        sourceDisplayName: String? = nil,
        providerDisplayName: String? = nil,
        headline: String? = nil,
        summary: String? = nil,
        bodyText: String? = nil,
        primaryLink: String? = nil,
        authoredAt: Date? = nil,
        modifiedAt: Date? = nil,
        observedAt: Date,
        mediaCandidates: [DeclaredMediaCandidate] = [],
        offers: [DeclaredInteractionOffer] = []
    ) {
        self.originRecordID = originRecordID
        self.originRevisionID = originRevisionID
        self.sourceID = sourceID
        self.providerID = providerID
        self.sourceDisplayName = sourceDisplayName
        self.providerDisplayName = providerDisplayName
        self.headline = headline
        self.summary = summary
        self.bodyText = bodyText
        self.primaryLink = primaryLink
        self.authoredAt = authoredAt
        self.modifiedAt = modifiedAt
        self.observedAt = observedAt
        self.mediaCandidates = mediaCandidates
        self.offers = offers.sorted()
    }

    /// The attribution as the payload freezes it.
    public var publishedOrigin: PublishedOrigin {
        PublishedOrigin(
            originRecordID: originRecordID,
            originRevisionID: originRevisionID,
            sourceID: sourceID,
            providerID: providerID,
            sourceDisplayName: sourceDisplayName,
            providerDisplayName: providerDisplayName
        )
    }

    /// The text the card displays: the headline as the title, the excerpt as the primary text, and the
    /// body only as the primary text when there is no excerpt.
    public var cardTitle: String? { headline }

    public var cardPrimaryText: String? {
        if let summary, !summary.isEmpty { return summary }
        return bodyText
    }

    /// The declared date and its epistemic kind. A missing date is `none`, never a synthesized one.
    public var declaredTimestamp: (date: Date?, kind: PublishedTimestampKind) {
        if let authoredAt { return (authoredAt, .authored) }
        if let modifiedAt { return (modifiedAt, .modified) }
        return (nil, .none)
    }

    /// The frozen primary action, or `nil` when the revision offers nothing executable.
    public func primaryAction() throws -> FeedPrimaryAction? {
        if let primaryLink, let url = URL(string: primaryLink), url.scheme != nil {
            return .externalURL(url)
        }
        if let offer = offers.first(where: { $0.handle != nil }) {
            return .connectorAction(try ActionID(offer.handle ?? offer.kind))
        }
        if let offer = offers.first {
            return .connectorAction(try ActionID(offer.kind))
        }
        return nil
    }

    /// A stable summary of what the card offers, sorted so two databases agree byte for byte.
    public var interactionSummary: String? {
        let kinds = offers.map(\.kind).reduce(into: Set<String>()) { $0.insert($1) }.sorted()
        return kinds.isEmpty ? nil : kinds.joined(separator: ",")
    }
}
