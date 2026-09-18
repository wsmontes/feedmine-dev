import Foundation
import FeedDomain
import FeedKit

/// RSS and Atom → canonical observations. This is the only place in the runtime that decodes a
/// syndication wire format (plan §7, §12; ADR-005 D1, D20).
///
/// `FeedKit` is not `Sendable`. A parser is created *and* consumed inside `translate`, on the
/// worker that owns the call, and only `Sendable` DTOs leave it: no parser, no FeedKit model and no
/// closure crosses the boundary, and no `@unchecked Sendable` conformance is used to make one pass
/// (ADR-005 D20, `invariant 16`).

/// Which document this translation came from.
public enum SyndicationDocumentKind: String, Hashable, Sendable, Codable {
    case rss
    case atom
}

public enum SyndicationTranslationError: Error, Equatable, Sendable {
    /// The bytes are not a feed this connector can read. The validator must not be confirmed for
    /// them (ADR-005 D12).
    case parseFailure(reason: String)
    /// A document FeedKit recognized but this connector does not translate (JSON Feed). It is a
    /// distinct case from a parse failure so a caller can tell "wrong format" from "broken bytes".
    case unsupportedDocumentKind(String)

    public var reason: String {
        switch self {
        case .parseFailure(let reason): return reason
        case .unsupportedDocumentKind(let kind): return "unsupported document kind '\(kind)'"
        }
    }
}

/// Why one declared item produced no observation.
public struct SyndicationItemFailure: Error, Equatable, Sendable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// One declared item the connector could not turn into an observation, with the reason. It is
/// recorded rather than silently dropped (ADR-005 "a feed whose items all lack external IDs still
/// emits observations … never a connector-local silent drop") and it blocks validator confirmation
/// (D12).
public struct SyndicationItemRejection: Hashable, Sendable {
    public let index: Int
    public let reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

/// A link the domain has no canonical field for. Enclosures and additional alternates are kept as
/// connector records (they reach Admission as `ConnectorEvidence`, which is removable without
/// changing selection or publication: ADR-005 D1, `invariant 2`) and no new FeedDomain type is
/// invented for them.
public struct SyndicationSecondaryLink: Hashable, Sendable {
    public enum Relation: String, Hashable, Sendable, Codable {
        case enclosure
        case alternate
    }

    public let relation: Relation
    /// Exactly as declared; never resolved against the feed's base URL and never rewritten.
    public let url: String
    public let mediaType: String?
    public let byteLength: Int64?

    public init(relation: Relation, url: String, mediaType: String? = nil, byteLength: Int64? = nil) {
        self.relation = relation
        self.url = url
        self.mediaType = mediaType
        self.byteLength = byteLength
    }
}

public struct SyndicationTranslatedItem: Hashable, Sendable {
    /// What Admission stores: protocol-free canonical content.
    public let observation: AcquisitionObservation
    /// The same item as an identity request, so the declared confidence and the fallback scheme
    /// version travel with it — `AcquisitionObservation` has no field for either (ADR-003 D16).
    public let identityRequest: IdentityResolutionRequest
    /// The slot this item occupies in the checkpoint's representation record.
    public let slot: String
    public let representation: SyndicationRepresentationStamp
    public let secondaryLinks: [SyndicationSecondaryLink]

    public init(
        observation: AcquisitionObservation,
        identityRequest: IdentityResolutionRequest,
        slot: String,
        representation: SyndicationRepresentationStamp,
        secondaryLinks: [SyndicationSecondaryLink]
    ) {
        self.observation = observation
        self.identityRequest = identityRequest
        self.slot = slot
        self.representation = representation
        self.secondaryLinks = secondaryLinks
    }
}

public struct SyndicationTranslation: Hashable, Sendable {
    public let documentKind: SyndicationDocumentKind
    public let items: [SyndicationTranslatedItem]
    public let rejections: [SyndicationItemRejection]
    /// How many items the parsed document declared, including any left untranslated by the ceiling.
    public let declaredItemCount: Int
    /// `true` when the item ceiling cut the document short: the observations are not the whole
    /// document, so no validator may be confirmed for this body (ADR-005 D12, D4).
    public let truncatedByItemCeiling: Bool
    /// Whether the document carried recognizable feed-level metadata. Combined with an empty item
    /// list this is what separates "valid document, no observations" from "document whose
    /// observations could not be extracted" (ADR-005 D12).
    public let declaresFeedMetadata: Bool
    public init(
        documentKind: SyndicationDocumentKind,
        items: [SyndicationTranslatedItem],
        rejections: [SyndicationItemRejection],
        declaredItemCount: Int,
        truncatedByItemCeiling: Bool,
        declaresFeedMetadata: Bool
    ) {
        self.documentKind = documentKind
        self.items = items
        self.rejections = rejections
        self.declaredItemCount = declaredItemCount
        self.truncatedByItemCeiling = truncatedByItemCeiling
        self.declaresFeedMetadata = declaresFeedMetadata
    }

    public var observations: [AcquisitionObservation] { items.map(\.observation) }

    /// The representation record a confirmed baseline stores: one entry per translated object.
    public var observedRepresentations: [String: SyndicationRepresentationStamp] {
        var map: [String: SyndicationRepresentationStamp] = [:]
        for item in items where map[item.slot] == nil {
            map[item.slot] = item.representation
        }
        return map
    }

    /// `true` only when this run consumed everything the document declared.
    ///
    /// This is the connector's half of ADR-005 D12: a validator may be confirmed only for a body the
    /// runtime actually consumed. A parse failure never reaches this type, a document whose items
    /// could not be extracted has `rejections`, a truncated body never reaches the translator, and a
    /// document that declares nothing at all — no items and no feed metadata — is not distinguishable
    /// from one whose entries could not be mapped, so it does not confirm either.
    public var consumedWholeDocument: Bool {
        guard !truncatedByItemCeiling, rejections.isEmpty else { return false }
        if declaredItemCount == 0 && !declaresFeedMetadata { return false }
        return true
    }
}

public struct SyndicationTranslator: Sendable {
    /// Hard ceiling on observations produced from one document; a caller may ask for fewer.
    public let maxItems: Int
    public let identity: SyndicationIdentity

    public init(maxItems: Int = 500, identity: SyndicationIdentity = SyndicationIdentity()) {
        self.maxItems = maxItems
        self.identity = identity
    }

    public func translate(
        data: Data,
        scope: ExternalScopeKey,
        observedAt: Date,
        maxItems requestedItems: Int,
        previousRepresentations: [String: SyndicationRepresentationStamp] = [:],
        enrollment: SyndicationSourceEnrollment? = nil
    ) -> Result<SyndicationTranslation, SyndicationTranslationError> {
        let parser = FeedParser(data: data)
        let feed: Feed
        switch parser.parse() {
        case .success(let parsed): feed = parsed
        case .failure(let error): return .failure(.parseFailure(reason: Self.reason(for: error)))
        }

        let ceiling = min(requestedItems, maxItems)
        switch feed {
        case .rss(let rss):
            return .success(translate(
                rss: rss,
                scope: scope,
                observedAt: observedAt,
                ceiling: ceiling,
                previous: previousRepresentations,
                enrollment: enrollment
            ))
        case .atom(let atom):
            return .success(translate(
                atom: atom,
                scope: scope,
                observedAt: observedAt,
                ceiling: ceiling,
                previous: previousRepresentations,
                enrollment: enrollment
            ))
        case .json:
            // A recognized document this connector does not translate. It is refused explicitly so
            // the caller cannot mistake it for "no observations today".
            return .failure(.unsupportedDocumentKind("json"))
        @unknown default:
            return .failure(.unsupportedDocumentKind("unknown"))
        }
    }

    // MARK: - RSS

    private func translate(
        rss: RSSFeed,
        scope: ExternalScopeKey,
        observedAt: Date,
        ceiling: Int,
        previous: [String: SyndicationRepresentationStamp],
        enrollment: SyndicationSourceEnrollment?
    ) -> SyndicationTranslation {
        // FeedKit leaves `items` nil when the document declared no `<item>` element at all.
        let declared = rss.items ?? []
        let declaresFeedMetadata = rss.title != nil || rss.link != nil || rss.description != nil
            || rss.language != nil || rss.copyright != nil || rss.generator != nil
            || rss.image != nil || rss.pubDate != nil || rss.lastBuildDate != nil
        let channelProvider = SyndicationAttribution.feedProvider(rss)

        var items: [SyndicationTranslatedItem] = []
        var rejections: [SyndicationItemRejection] = []
        let slice = declared.prefix(max(ceiling, 0))
        for (index, item) in slice.enumerated() {
            let parsed = ParsedItem(
                declaredIdentifier: item.guid?.value,
                declaredLink: item.link,
                headline: item.title ?? item.dublinCore?.dcTitle,
                excerpt: item.description ?? item.dublinCore?.dcDescription,
                body: item.content?.contentEncoded,
                authoredAt: item.pubDate ?? item.dublinCore?.dcDate,
                modifiedAt: nil,
                // RSS 2.0 declares one instant per item; `dc:date` is used only when the core element
                // declared none, and it is never substituted for the observation time.
                declaredVersionAt: item.pubDate ?? item.dublinCore?.dcDate,
                secondaryLinks: Self.enclosureLinks(item),
                provider: SyndicationAttribution.itemProvider(item, fallback: channelProvider),
                mediaCandidates: SyndicationAttribution.mediaCandidates(item)
            )
            switch assemble(
                parsed,
                scope: scope,
                observedAt: observedAt,
                previous: previous,
                enrollment: enrollment
            ) {
            case .success(let translated): items.append(translated)
            case .failure(let failure): rejections.append(SyndicationItemRejection(index: index, reason: failure.reason))
            }
        }

        return SyndicationTranslation(
            documentKind: .rss,
            items: items,
            rejections: rejections,
            declaredItemCount: declared.count,
            truncatedByItemCeiling: declared.count > slice.count,
            declaresFeedMetadata: declaresFeedMetadata
        )
    }

    private static func enclosureLinks(_ item: RSSFeedItem) -> [SyndicationSecondaryLink] {
        guard let attributes = item.enclosure?.attributes,
              let url = attributes.url, !url.isEmpty
        else { return [] }
        return [SyndicationSecondaryLink(
            relation: .enclosure,
            url: url,
            mediaType: attributes.type,
            byteLength: attributes.length
        )]
    }

    // MARK: - Atom

    private func translate(
        atom: AtomFeed,
        scope: ExternalScopeKey,
        observedAt: Date,
        ceiling: Int,
        previous: [String: SyndicationRepresentationStamp],
        enrollment: SyndicationSourceEnrollment?
    ) -> SyndicationTranslation {
        let declared = atom.entries ?? []
        let declaresFeedMetadata = atom.title != nil || atom.id != nil || atom.updated != nil
            || atom.links != nil || atom.subtitle != nil
        let feedProvider = SyndicationAttribution.feedProvider(atom)

        var items: [SyndicationTranslatedItem] = []
        var rejections: [SyndicationItemRejection] = []
        let slice = declared.prefix(max(ceiling, 0))
        for (index, entry) in slice.enumerated() {
            let links = entry.links ?? []
            let alternates = links.filter { Self.relation(of: $0) == "alternate" }
            let parsed = ParsedItem(
                declaredIdentifier: entry.id,
                declaredLink: alternates.first?.attributes?.href,
                headline: entry.title,
                excerpt: entry.summary?.value,
                body: entry.content?.value,
                authoredAt: entry.published,
                modifiedAt: entry.updated,
                // `atom:updated` is the representation's declared version; `atom:published` is used
                // only when the entry declared no update. Neither is ever assumed ordered (D9).
                declaredVersionAt: entry.updated ?? entry.published,
                secondaryLinks: Self.secondaryLinks(alternates: alternates, links: links),
                provider: SyndicationAttribution.itemProvider(entry, fallback: feedProvider),
                mediaCandidates: SyndicationAttribution.mediaCandidates(entry)
            )
            switch assemble(
                parsed,
                scope: scope,
                observedAt: observedAt,
                previous: previous,
                enrollment: enrollment
            ) {
            case .success(let translated): items.append(translated)
            case .failure(let failure): rejections.append(SyndicationItemRejection(index: index, reason: failure.reason))
            }
        }

        return SyndicationTranslation(
            documentKind: .atom,
            items: items,
            rejections: rejections,
            declaredItemCount: declared.count,
            truncatedByItemCeiling: declared.count > slice.count,
            declaresFeedMetadata: declaresFeedMetadata
        )
    }

    /// Atom link relation: an absent `rel` means `alternate`.
    private static func relation(of link: AtomFeedEntryLink) -> String {
        (link.attributes?.rel ?? "alternate").lowercased()
    }

    private static func secondaryLinks(
        alternates: [AtomFeedEntryLink],
        links: [AtomFeedEntryLink]
    ) -> [SyndicationSecondaryLink] {
        var secondary: [SyndicationSecondaryLink] = []
        for link in alternates.dropFirst() {
            guard let href = link.attributes?.href, !href.isEmpty else { continue }
            secondary.append(SyndicationSecondaryLink(
                relation: .alternate,
                url: href,
                mediaType: link.attributes?.type,
                byteLength: link.attributes?.length
            ))
        }
        for link in links where relation(of: link) == "enclosure" {
            guard let href = link.attributes?.href, !href.isEmpty else { continue }
            secondary.append(SyndicationSecondaryLink(
                relation: .enclosure,
                url: href,
                mediaType: link.attributes?.type,
                byteLength: link.attributes?.length
            ))
        }
        return secondary
    }

    // MARK: - Assembly

    private struct ParsedItem {
        let declaredIdentifier: String?
        let declaredLink: String?
        let headline: String?
        let excerpt: String?
        let body: String?
        let authoredAt: Date?
        let modifiedAt: Date?
        let declaredVersionAt: Date?
        let secondaryLinks: [SyndicationSecondaryLink]
        /// The attribution the document declared for this item, if any (ADR-003 D5).
        let provider: ProviderClaim?
        /// The media the document declared this item carries (plan §6).
        let mediaCandidates: [MediaCandidateClaim]
    }

    private func assemble(
        _ parsed: ParsedItem,
        scope: ExternalScopeKey,
        observedAt: Date,
        previous: [String: SyndicationRepresentationStamp],
        enrollment: SyndicationSourceEnrollment?
    ) -> Result<SyndicationTranslatedItem, SyndicationItemFailure> {
        // A missing headline or a missing link is admissible input and is never synthesized
        // (ADR-003 D16/D17): `link` stays nil unless the document declared one.
        let link = parsed.declaredLink.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let payload = ObservationPayload(
            headline: parsed.headline,
            link: link,
            excerpt: parsed.excerpt,
            body: parsed.body,
            authoredAt: parsed.authoredAt,
            modifiedAt: parsed.modifiedAt,
            observedAt: observedAt
        )

        let identityRef: ExternalIdentityRef
        do {
            identityRef = try identity.resolve(
                scope: scope,
                declaredIdentifier: parsed.declaredIdentifier,
                declaredLink: parsed.declaredLink,
                payload: payload
            )
        } catch let error as SyndicationIdentityError {
            return .failure(SyndicationItemFailure(Self.describe(error)))
        } catch {
            return .failure(SyndicationItemFailure(String(describing: error)))
        }

        let declaredVersion = parsed.declaredVersionAt.map(Self.versionText)
        var versionKey: ExternalVersionKey?
        if let declaredVersion {
            do {
                versionKey = try ExternalVersionKey(scope: scope, text: declaredVersion)
            } catch let error as ExternalIdentityError {
                return .failure(SyndicationItemFailure(Self.describe(.keyRejected(error))))
            } catch {
                return .failure(SyndicationItemFailure(String(describing: error)))
            }
        }

        let identityRequest: IdentityResolutionRequest
        if identityRef.confidence == .low {
            guard let schemeVersion = identityRef.fallbackSchemeVersion else {
                return .failure(SyndicationItemFailure("a low-confidence identity must name its fallback scheme"))
            }
            do {
                identityRequest = IdentityResolutionRequest(
                    key: identityRef.key,
                    versionKey: versionKey,
                    payload: payload,
                    fallbackScheme: try FallbackIdentityScheme(version: schemeVersion)
                )
            } catch {
                return .failure(SyndicationItemFailure(Self.describe(.invalidFallbackSchemeVersion(schemeVersion))))
            }
        } else {
            identityRequest = IdentityResolutionRequest(
                key: identityRef.key,
                versionKey: versionKey,
                payload: payload
            )
        }

        let representation = SyndicationRepresentationStamp(declaredVersion: declaredVersion, payload: payload)
        let slot = SyndicationFingerprint.slot(of: identityRef.key)
        let observation = AcquisitionObservation(
            externalKey: identityRef.key,
            versionKey: versionKey,
            precedence: representation.precedence(from: previous[slot]),
            payload: payload,
            provider: parsed.provider,
            memberships: enrollment.map { [$0.claim] } ?? [],
            mediaCandidates: parsed.mediaCandidates
        )
        return .success(SyndicationTranslatedItem(
            observation: observation,
            identityRequest: identityRequest,
            slot: slot,
            representation: representation,
            secondaryLinks: parsed.secondaryLinks
        ))
    }

    /// The wire format's declared instant, rendered in one fixed form (ISO 8601, UTC, second
    /// precision). FeedKit normalizes a declared date element into a `Date`; the connector keeps the
    /// declared *value* and never substitutes the observation time — an element the format does not
    /// parse to a date declares no version at all, and the representation is then matched by payload.
    static func versionText(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func describe(_ error: SyndicationIdentityError) -> String {
        switch error {
        case .emptyScopeKey: return "empty scope key"
        case .noIdentityMaterial: return "the item declared no identifier, no link and no content"
        case .invalidFallbackSchemeVersion(let version): return "invalid fallback scheme version \(version)"
        case .keyRejected(let rejection): return "identity key rejected: \(rejection)"
        case .identityFailure(let reason): return "identity failure: \(reason)"
        }
    }

    /// The parser's own description. It never contains the payload, so no feed content and no query
    /// string can leak into a diagnostic (ADR-005 D14).
    private static func reason(for error: ParserError) -> String {
        error.localizedDescription
    }
}
