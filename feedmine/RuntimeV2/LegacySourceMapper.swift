import Foundation
import FeedConnectorSyndication
import FeedDomain

/// Runtime V2 bridge for source identity (plan §5, ADR-003 D2/D4/D6/D18).
///
/// The catalogue's identity never becomes a runtime identity by derivation. This mapper builds the
/// durable *values* the runtime stores; the only translation from a catalogue id to a runtime
/// `SourceID` is `LegacySourceMap.runtimeSource(forCatalogSource:canonicalizationVersion:)`, a
/// persisted lookup that fails when no row exists. There is deliberately no function here that
/// takes a URL or a digest and returns a `SourceID`, because that is the legacy defect
/// (`FeedEngine/Identities.swift:32-37`, `CatalogIdentity.swift:20-21`) ADR-003 D2 rejects.
enum LegacySourceMapper {

    /// The app target already declares a `SourceID` (`FeedEngine/Identities.swift:32-37`), a `UInt32`
    /// derived from a URL digest. Runtime identity is a different type in a different namespace
    /// (ADR-003 D2), so every bridge refers to it through this alias instead of by bare name — and
    /// there is no conversion between the two.
    typealias RuntimeSourceID = FeedDomain.SourceID

    /// Connector namespace for feeds acquired over HTTP as RSS/Atom.
    ///
    /// It is the connector's own namespace, taken from the connector rather than spelled here: the
    /// objects, the bindings and the checkpoints of a syndication source all live in one namespace, and
    /// a second spelling would make the shadow lane's objects and the production lane's objects two
    /// identities for one source (ADR-003 D8).
    static let syndicationNamespace = SyndicationNamespace.connector

    /// Canonicalization version recorded in the catalogue metadata for `SourceKey`.
    ///
    /// Callers that read the metadata pass the real version. The default exists for callers that
    /// only hold a source, and it is a single constant so a source cannot silently acquire a
    /// different version than its neighbours in the same catalogue.
    static let defaultCanonicalizationVersion = 1

    public enum BridgeError: Error, Equatable, Sendable {
        /// The connector-owned configuration could not be encoded. Returning an empty configuration
        /// would silently drop the endpoint, so this is an error.
        case unencodableBindingConfiguration(String)
    }

    /// Catalogue identity as the runtime sees it.
    struct CatalogIdentity: Hashable, Sendable {
        /// Durable catalogue key (`SourceKey`, `FeedEngine/Identities.swift:20`).
        let key: String
        /// Compact catalogue id. `0` is the catalogue's `SourceID.none` and is never a source.
        let compactID: CatalogSourceID
        /// The app-level identity string (`Models/FeedSource.swift:9-11`). Recorded as evidence in
        /// `legacy_source_map.legacy_url`; never used to decide identity.
        let normalizedURL: String
    }

    // MARK: - Catalogue identity

    static func catalogIdentity(
        key: String,
        normalizedURL: String,
        compactID: CatalogSourceID
    ) -> CatalogIdentity {
        CatalogIdentity(key: key, compactID: compactID, normalizedURL: normalizedURL)
    }

    /// Bridges a `FeedSource`, whose `id` is the normalized fetch URL.
    static func catalogIdentity(for source: FeedSource, compactID: CatalogSourceID) -> CatalogIdentity {
        CatalogIdentity(key: source.id, compactID: compactID, normalizedURL: source.id)
    }

    // MARK: - Durable key and mapping

    static func editorialKey(
        for identity: CatalogIdentity,
        canonicalizationVersion: Int = defaultCanonicalizationVersion
    ) throws -> EditorialSourceKey {
        try EditorialSourceKey(
            catalogIdentity: identity.key,
            canonicalizationVersion: canonicalizationVersion
        )
    }

    static func mapping(
        for identity: CatalogIdentity,
        runtimeSourceID: RuntimeSourceID,
        canonicalizationVersion: Int = defaultCanonicalizationVersion,
        mappedAt: Date
    ) throws -> LegacySourceMapping {
        LegacySourceMapping(
            editorialKey: try editorialKey(for: identity, canonicalizationVersion: canonicalizationVersion),
            catalogSourceID: identity.compactID,
            runtimeSourceID: runtimeSourceID,
            legacyURL: identity.normalizedURL,
            mappedAt: mappedAt
        )
    }

    /// The only catalogue id → runtime source translation there is.
    static func runtimeSourceID(
        for identity: CatalogIdentity,
        canonicalizationVersion: Int = defaultCanonicalizationVersion,
        in map: LegacySourceMap
    ) throws -> RuntimeSourceID {
        try map.runtimeSource(
            forCatalogSource: identity.compactID,
            canonicalizationVersion: canonicalizationVersion
        )
    }

    // MARK: - Binding

    /// Declarative binding for one source.
    ///
    /// The binding key comes from the durable editorial key, not from the endpoint: an endpoint
    /// change must advance `generation` on the same binding, not create a second one (D6).
    static func binding(
        for identity: CatalogIdentity,
        runtimeSourceID: RuntimeSourceID,
        endpoint: String,
        generation: UInt64 = 1
    ) throws -> SourceBinding {
        try SourceBinding(
            key: SourceBindingKey(namespace: syndicationNamespace, bindingKey: identity.key),
            sourceID: runtimeSourceID,
            configurationJSON: try configuration(endpoint: endpoint),
            generation: generation
        )
    }

    /// Endpoint (or connector configuration) change: same source, same binding, generation + 1.
    static func bindingAfterEndpointChange(
        _ existing: SourceBinding,
        endpoint: String
    ) throws -> SourceBinding {
        try existing.advanced(to: try configuration(endpoint: endpoint))
    }

    /// Scope for the objects this source observes.
    ///
    /// The scope is the source, so the same GUID published by two feeds is two objects — which is
    /// what ADR-003 D8 requires and what a global key space would get wrong.
    static func objectScope(for identity: CatalogIdentity) -> ExternalScopeKey {
        ExternalScopeKey(namespace: syndicationNamespace, scopeKey: "source:\(identity.key)")
    }

    /// Connector-owned configuration. Opaque to the core: it is stored and never parsed.
    static func configuration(endpoint: String) throws -> String {
        let object: [String: String] = ["endpoint": endpoint]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            throw BridgeError.unencodableBindingConfiguration(endpoint)
        }
        return json
    }
}
