import Foundation
import FeedDomain
import FeedKit

/// What the wire declares about who published a representation, and which media it carries.
///
/// Both are derived from what the document *declares* and from nothing else:
///
/// * the provider is the item's own `<source url="…">`/`atom:source` when the document declares one,
///   otherwise the channel's own site link or title — the strings the document shipped, never a host
///   parsed out of an item link;
/// * a media candidate comes from an `<enclosure>` with its declared MIME type, or a Media RSS
///   `<media:content>` with its declared `medium`/`type`, or a `<media:thumbnail>`, or an
///   `itunes:image`. An element that declares neither a type nor a medium yields no candidate: the
///   connector does not invent a role from a URL's extension, which is the inference ADR-003 D14 and
///   plan §6 keep out of the canonical layer. Such an element is still kept as connector evidence by
///   the translator, so nothing is silently dropped.
///
/// Nothing here decides identity, admission or publication: every value produced is a claim, and
/// Admission decides what a claim means (ADR-003 D5, D15).
public enum SyndicationAttribution {
    /// The provider key space. It is the connector's own namespace, so two connectors cannot collide on
    /// a provider key and the core never interprets the key (ADR-003 D5).
    public static let providerNamespace = SyndicationNamespace.connector

    /// The structural role a declared media type or Media RSS `medium` names, or `nil` when the
    /// declaration is not about media this runtime models.
    ///
    /// `medium` is the Media RSS vocabulary and wins when it is present, because it is a declaration
    /// about the resource's kind rather than a MIME spelling of it. An unrecognised `medium` yields no
    /// role instead of falling through to the MIME type: a document that says `medium="document"` has
    /// said what it is, and a `type="application/pdf"` must not turn it into an image.
    public static func mediaRole(mediaType: String?, medium: String?) -> MediaRole? {
        if let medium = normalized(medium) {
            switch medium {
            case "image": return .image
            case "audio": return .audio
            case "video": return .video
            case "document", "text", "data": return nil
            default: return nil
            }
        }
        guard let type = normalized(mediaType) else { return nil }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("image/") { return .image }
        return nil
    }

    // MARK: - RSS

    /// The channel as the provider of everything it declares.
    ///
    /// The key is the channel's own site link, and the display name its title — both as declared. A
    /// channel that declares neither a link nor a title states no provider, and the observations carry
    /// none: an attribution invented out of the target's endpoint would be the connector's own guess
    /// about a publisher (ADR-003 D5).
    static func feedProvider(_ feed: RSSFeed) -> ProviderClaim? {
        provider(key: feed.link, displayName: feed.title)
    }

    static func feedProvider(_ feed: AtomFeed) -> ProviderClaim? {
        provider(key: feed.id ?? selfLink(of: feed.links), displayName: feed.title)
    }

    /// The provider of one item: the `<source>` it declares, else the channel.
    ///
    /// RSS 2.0's `<source>` element names the channel an item came from, with its URL as an attribute
    /// and its title as the element's value — a declared attribution, which is why it wins over the
    /// feed the runtime happened to fetch.
    static func itemProvider(_ item: RSSFeedItem, fallback: ProviderClaim?) -> ProviderClaim? {
        provider(key: item.source?.attributes?.url, displayName: item.source?.value) ?? fallback
    }

    static func itemProvider(_ entry: AtomFeedEntry, fallback: ProviderClaim?) -> ProviderClaim? {
        guard let source = entry.source else { return fallback }
        return provider(key: source.id, displayName: source.title) ?? fallback
    }

    static func mediaCandidates(_ item: RSSFeedItem) -> [MediaCandidateClaim] {
        var candidates: [MediaCandidateClaim] = []
        if let enclosure = item.enclosure?.attributes {
            append(
                role: mediaRole(mediaType: enclosure.type, medium: nil),
                url: enclosure.url,
                mediaTypeHint: enclosure.type,
                pixelWidth: nil,
                pixelHeight: nil,
                to: &candidates
            )
        }
        append(contentsOf: item.media, to: &candidates)
        if let href = item.iTunes?.iTunesImage?.attributes?.href {
            append(role: .poster, url: href, mediaTypeHint: nil, pixelWidth: nil, pixelHeight: nil, to: &candidates)
        }
        return candidates
    }

    static func mediaCandidates(_ entry: AtomFeedEntry) -> [MediaCandidateClaim] {
        var candidates: [MediaCandidateClaim] = []
        for link in entry.links ?? [] where relation(of: link) == "enclosure" {
            append(
                role: mediaRole(mediaType: link.attributes?.type, medium: nil),
                url: link.attributes?.href,
                mediaTypeHint: link.attributes?.type,
                pixelWidth: nil,
                pixelHeight: nil,
                to: &candidates
            )
        }
        append(contentsOf: entry.media, to: &candidates)
        return candidates
    }

    // MARK: - Media RSS

    private static func append(
        contentsOf media: MediaNamespace?,
        to candidates: inout [MediaCandidateClaim]
    ) {
        guard let media else { return }
        for content in media.mediaContents ?? [] {
            append(
                role: mediaRole(mediaType: content.attributes?.type, medium: content.attributes?.medium),
                url: content.attributes?.url,
                mediaTypeHint: content.attributes?.type,
                pixelWidth: positive(content.attributes?.width),
                pixelHeight: positive(content.attributes?.height),
                to: &candidates
            )
        }
        for thumbnail in media.mediaThumbnails ?? [] {
            append(
                role: .thumbnail,
                url: thumbnail.attributes?.url,
                mediaTypeHint: nil,
                pixelWidth: positive(Int(thumbnail.attributes?.width ?? "")),
                pixelHeight: positive(Int(thumbnail.attributes?.height ?? "")),
                to: &candidates
            )
        }
    }

    /// Appends one candidate unless the role is unknown, the URL empty, or the same (role, URL) pair
    /// was already declared. `position` numbers the role's candidates in declaration order, which is
    /// what the schema's `UNIQUE (origin_revision_id, role, position)` expects.
    private static func append(
        role: MediaRole?,
        url: String?,
        mediaTypeHint: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        to candidates: inout [MediaCandidateClaim]
    ) {
        guard let role, let url, !url.isEmpty else { return }
        if candidates.contains(where: { $0.role == role && $0.resourceURL == url }) { return }
        let position = candidates.reduce(0) { $0 + ($1.role == role ? 1 : 0) }
        guard let candidate = try? MediaCandidateClaim(
            role: role,
            resourceURL: url,
            mediaTypeHint: mediaTypeHint,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            position: position
        ) else { return }
        candidates.append(candidate)
    }

    // MARK: - Small helpers

    private static func provider(key: String?, displayName: String?) -> ProviderClaim? {
        guard let key = trimmed(key) else { return nil }
        guard let claim = try? ProviderClaim(
            namespace: providerNamespace,
            providerKey: key,
            displayName: trimmed(displayName) ?? key,
            // `primary`, not `publisher`. Admission stores either, but Selection reads a candidate's
            // provider key from the **primary** attribution alone
            // (`SelectionSupplyRepository.primaryProviders:368`), and a quota counts that key. A
            // `.publisher` claim would be written and then never read: the content would lose the
            // attribution the document declared, which is exactly what the end-to-end test caught.
            role: .primary
        ) else { return nil }
        return claim
    }

    /// An Atom feed's own address, which is its `rel="self"` link, or failing that its `alternate`.
    private static func selfLink(of links: [AtomFeedLink]?) -> String? {
        let links = links ?? []
        for relation in ["self", "alternate"] {
            if let href = links.first(where: { normalized($0.attributes?.rel) == relation })?.attributes?.href {
                return href
            }
        }
        return nil
    }

    private static func relation(of link: AtomFeedEntryLink) -> String {
        (link.attributes?.rel ?? "alternate").lowercased()
    }

    private static func normalized(_ value: String?) -> String? {
        trimmed(value)?.lowercased()
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
