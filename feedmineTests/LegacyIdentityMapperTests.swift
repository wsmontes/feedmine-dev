import XCTest
import FeedDomain
@testable import feedmine

/// PR-02 bridge tests: catalogue identity → Runtime V2 identity values.
///
/// These assert the bridge contract, not the mapper's plumbing: an endpoint change keeps the source,
/// a runtime source is only ever reached through a persisted mapping, an opaque GUID is never
/// rewritten, and an item whose raw identity the bridge never saw is recorded as unresolved.
final class LegacyIdentityMapperTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_789_000_000)

    private func identity(
        key: String = "https://example.com/feed.xml",
        normalizedURL: String? = nil,
        compact: UInt32 = 42
    ) -> LegacySourceMapper.CatalogIdentity {
        LegacySourceMapper.catalogIdentity(
            key: key,
            normalizedURL: normalizedURL ?? key,
            compactID: CatalogSourceID(compact)
        )
    }

    /// Runtime identity, spelled through the bridge alias: the app target has its own `SourceID`.
    private func runtimeSource(_ raw: UInt64) throws -> LegacySourceMapper.RuntimeSourceID {
        try FeedDomain.SourceID(raw)
    }

    // MARK: - Source identity

    func testCatalogIdentityRecordsTheNormalizedURLAsEvidence() {
        let source = FeedSource(
            title: "Example",
            url: "https://www.example.com/feed.xml?utm_source=rss",
            category: "News"
        )
        let bridged = LegacySourceMapper.catalogIdentity(for: source, compactID: CatalogSourceID(7))

        XCTAssertEqual(bridged.key, source.id)
        XCTAssertEqual(bridged.normalizedURL, source.id)
        XCTAssertEqual(bridged.compactID, CatalogSourceID(7))
        XCTAssertNotEqual(
            bridged.key,
            source.url,
            "the durable key is the canonical form (www and tracking parameters removed); the evidence is what the catalogue normalised"
        )
    }

    func testEndpointChangeKeepsSourceIdentityAndAdvancesGeneration() throws {
        let bridged = identity()
        let source = try runtimeSource(10)
        let first = try LegacySourceMapper.binding(
            for: bridged,
            runtimeSourceID: source,
            endpoint: "https://example.com/feed.xml"
        )
        let moved = try LegacySourceMapper.bindingAfterEndpointChange(
            first,
            endpoint: "https://example.com/v2/feed.xml"
        )

        XCTAssertEqual(moved.sourceID, source, "a binding change never creates a source (D6)")
        XCTAssertEqual(moved.key, first.key, "the binding key is the durable editorial key, not the endpoint")
        XCTAssertEqual(moved.generation, first.generation + 1)
        XCTAssertEqual(first.generation, 1)
        XCTAssertTrue(moved.accepts(generation: 2))
        XCTAssertFalse(moved.accepts(generation: 1), "the previous generation is stale for this binding")
    }

    func testTwoEndpointsOfOneSourceAreTwoBindingsWithOneSourceID() throws {
        let bridged = identity()
        let source = try runtimeSource(11)
        let rss = try LegacySourceMapper.binding(
            for: bridged,
            runtimeSourceID: source,
            endpoint: "https://example.com/feed.xml"
        )
        let atom = try SourceBinding(
            key: SourceBindingKey(
                namespace: LegacySourceMapper.syndicationNamespace,
                bindingKey: "\(bridged.key)#atom"
            ),
            sourceID: source,
            configurationJSON: try LegacySourceMapper.configuration(endpoint: "https://example.com/atom.xml")
        )

        XCTAssertNotEqual(rss.key, atom.key)
        XCTAssertEqual(rss.sourceID, atom.sourceID, "one editorial source can carry several bindings")
    }

    func testRuntimeSourceIsOnlyReachableThroughAPersistedMapping() throws {
        let bridged = identity(compact: 101)
        let empty = LegacySourceMap([])

        XCTAssertThrowsError(try LegacySourceMapper.runtimeSourceID(for: bridged, in: empty)) { error in
            XCTAssertEqual(
                error as? LegacyMappingError,
                .missingSourceMapping(catalogSourceID: CatalogSourceID(101), canonicalizationVersion: 1),
                "no URL digest may stand in for a missing mapping"
            )
        }

        let source = try runtimeSource(55)
        let mapping = try LegacySourceMapper.mapping(
            for: bridged,
            runtimeSourceID: source,
            mappedAt: fixedDate
        )
        let populated = LegacySourceMap([mapping])

        XCTAssertEqual(try LegacySourceMapper.runtimeSourceID(for: bridged, in: populated), source)
    }

    func testCanonicalizationVersionIsPartOfTheMapping() throws {
        let bridged = identity(compact: 102)
        let source = try runtimeSource(56)
        let versionOne = try LegacySourceMapper.mapping(
            for: bridged,
            runtimeSourceID: source,
            canonicalizationVersion: 1,
            mappedAt: fixedDate
        )
        let map = LegacySourceMap([versionOne])

        XCTAssertEqual(
            try LegacySourceMapper.runtimeSourceID(for: bridged, canonicalizationVersion: 1, in: map),
            source
        )
        XCTAssertThrowsError(
            try LegacySourceMapper.runtimeSourceID(for: bridged, canonicalizationVersion: 2, in: map),
            "a new canonicalisation version is a new key and needs its own mapping"
        )
    }

    func testCatalogRebuildReappliesPersistedMappingsAndKeepsRuntimeIDs() throws {
        let first = identity(key: "https://a.example/feed.xml", compact: 1)
        let second = identity(key: "https://b.example/feed.xml", compact: 2)
        let rows = [
            try LegacySourceMapper.mapping(for: first, runtimeSourceID: try runtimeSource(900), mappedAt: fixedDate),
            try LegacySourceMapper.mapping(for: second, runtimeSourceID: try runtimeSource(901), mappedAt: fixedDate),
        ]
        let before = LegacySourceMap(rows)

        // The catalogue was rebuilt: same durable keys, same compact ids, new rows read from storage.
        let after = LegacySourceMap(rows)

        XCTAssertEqual(try LegacySourceMapper.runtimeSourceID(for: first, in: after), try runtimeSource(900))
        XCTAssertEqual(try LegacySourceMapper.runtimeSourceID(for: second, in: after), try runtimeSource(901))
        XCTAssertEqual(before.rows.count, after.rows.count)
    }

    func testConflictingCatalogClaimIsRecordedAndNotSilentlyRepointed() throws {
        let bridged = identity(key: "https://c.example/feed.xml", compact: 3)
        let rows = [
            try LegacySourceMapper.mapping(for: bridged, runtimeSourceID: try runtimeSource(1), mappedAt: fixedDate),
            try LegacySourceMapper.mapping(for: bridged, runtimeSourceID: try runtimeSource(2), mappedAt: fixedDate),
        ]
        let map = LegacySourceMap(rows)

        XCTAssertFalse(map.conflicts.isEmpty, "two runtime sources claiming one catalogue key is a recorded conflict")
        XCTAssertTrue(
            map.isDisputed(forCatalogSource: bridged.compactID, canonicalizationVersion: 1),
            "the dispute is queryable, so a caller can refuse to act on it"
        )
        XCTAssertEqual(
            try LegacySourceMapper.runtimeSourceID(for: bridged, in: map),
            try runtimeSource(1),
            "the established mapping keeps answering; the claimed row is never applied"
        )
    }

    // MARK: - Item identity

    func testOpaqueGUIDIsNotNormalised() throws {
        let scope = LegacySourceMapper.objectScope(for: identity())
        let urlShapedGUID = "HTTPS://Example.COM/Post/1?utm_source=rss&b=2"
        let material = LegacyItemMapper.material(
            guid: urlShapedGUID,
            link: "https://example.com/post/1",
            title: "Post",
            publishedAt: fixedDate,
            disambiguator: "legacy-hash"
        )

        let key = try LegacyItemMapper.externalKey(for: material, scope: scope)
        XCTAssertEqual(String(decoding: key.bytes, as: UTF8.self), urlShapedGUID)
        XCTAssertEqual(key.keyKind, .object)
        XCTAssertEqual(LegacyItemMapper.confidence(for: material), .high)
    }

    func testSameGUIDInTwoSourcesIsTwoObjects() throws {
        let material = LegacyItemMapper.material(
            guid: "post-1",
            link: nil,
            title: nil,
            publishedAt: nil,
            disambiguator: "x"
        )
        let first = try LegacyItemMapper.externalKey(
            for: material,
            scope: LegacySourceMapper.objectScope(for: identity(key: "https://a.example/feed.xml"))
        )
        let second = try LegacyItemMapper.externalKey(
            for: material,
            scope: LegacySourceMapper.objectScope(for: identity(key: "https://b.example/feed.xml"))
        )

        XCTAssertNotEqual(first, second, "the scope is the source: a GUID is not globally unique")
    }

    func testMissingGUIDAndLinkUsesVersionedLowConfidenceFallback() throws {
        let scope = LegacySourceMapper.objectScope(for: identity())
        let material = LegacyItemMapper.material(
            guid: nil,
            link: nil,
            title: "Untitled",
            publishedAt: fixedDate,
            disambiguator: LegacyItemMapper.fallbackDisambiguator(legacyItemID: "hash-a")
        )

        let ref = try LegacyItemMapper.identity(for: material, scope: scope)
        XCTAssertEqual(ref.confidence, .low)
        XCTAssertEqual(ref.fallbackSchemeVersion, LegacyItemMapper.fallbackSchemeVersion)
        XCTAssertTrue(material.isLowConfidence)
    }

    func testFallbackKeepsTwoItemsWithTheSameTitleAndDateDistinct() throws {
        let scope = LegacySourceMapper.objectScope(for: identity())
        func key(legacyID: String) throws -> ExternalObjectKey {
            try LegacyItemMapper.externalKey(
                for: LegacyItemMapper.material(
                    guid: nil,
                    link: nil,
                    title: "Boletim",
                    publishedAt: fixedDate,
                    disambiguator: LegacyItemMapper.fallbackDisambiguator(legacyItemID: legacyID)
                ),
                scope: scope
            )
        }

        XCTAssertNotEqual(
            try key(legacyID: "hash-a"),
            try key(legacyID: "hash-b"),
            "identical title and date must not collapse two items into one record"
        )
    }

    func testAnEmptyGUIDFallsBackToTheLink() throws {
        let material = LegacyItemMapper.material(
            guid: "",
            link: "https://example.com/post/2",
            title: "Post",
            publishedAt: nil,
            disambiguator: "hash"
        )

        XCTAssertEqual(material, .link("https://example.com/post/2"))
        XCTAssertEqual(LegacyItemMapper.confidence(for: material), .high)
    }

    func testUnresolvedLegacyItemIDIsNotGuessed() throws {
        let unresolved = LegacyItemMapper.unresolvedMapping(
            legacyItemID: "hash-c",
            legacySourceURL: "https://example.com/feed.xml",
            mappedAt: fixedDate
        )
        XCTAssertNil(unresolved.record)
        XCTAssertNil(unresolved.revision)
        XCTAssertEqual(unresolved.confidence, .unresolved)

        let map = try LegacyItemMap([unresolved])
        let row = try map.mapping(forLegacyItemID: "hash-c")
        XCTAssertNil(row.record, "an unresolved row stays unresolved; it is never promoted by guesswork")

        XCTAssertThrowsError(try map.mapping(forLegacyItemID: "hash-unknown")) { error in
            XCTAssertEqual(error as? LegacyMappingError, .missingItemMapping(legacyItemID: "hash-unknown"))
        }
    }

    func testResolvedItemMappingCarriesTheConfidenceOfItsMaterial() throws {
        let high = LegacyItemMapper.mapping(
            legacyItemID: "hash-d",
            legacySourceURL: "https://example.com/feed.xml",
            record: try OriginRecordID(1),
            revision: try OriginRevisionID(1),
            material: .externalIdentifier("guid-d"),
            mappedAt: fixedDate
        )
        let low = LegacyItemMapper.mapping(
            legacyItemID: "hash-e",
            legacySourceURL: "https://example.com/feed.xml",
            record: try OriginRecordID(2),
            revision: try OriginRevisionID(2),
            material: .fallback(title: nil, publishedAt: nil, disambiguator: "hash-e"),
            mappedAt: fixedDate
        )

        XCTAssertEqual(high.confidence, .high)
        XCTAssertEqual(low.confidence, .low)
    }

    func testOneLegacyItemIDCannotPointAtTwoRecords() throws {
        let conflicting = [
            LegacyItemMapper.mapping(
                legacyItemID: "hash-f",
                legacySourceURL: "https://example.com/feed.xml",
                record: try OriginRecordID(1),
                revision: try OriginRevisionID(1),
                material: .externalIdentifier("guid-f"),
                mappedAt: fixedDate
            ),
            LegacyItemMapper.mapping(
                legacyItemID: "hash-f",
                legacySourceURL: "https://example.com/feed.xml",
                record: try OriginRecordID(2),
                revision: try OriginRevisionID(2),
                material: .externalIdentifier("guid-f"),
                mappedAt: fixedDate
            ),
        ]

        XCTAssertThrowsError(try LegacyItemMap(conflicting)) { error in
            XCTAssertEqual(error as? LegacyMappingError, .conflictingItemMapping(legacyItemID: "hash-f"))
        }
    }

    func testBindingConfigurationCarriesTheEndpointAndIsStable() throws {
        let configuration = try LegacySourceMapper.configuration(endpoint: "https://example.com/feed.xml")
        XCTAssertTrue(configuration.contains("https://example.com/feed.xml"))
        XCTAssertEqual(
            configuration,
            try LegacySourceMapper.configuration(endpoint: "https://example.com/feed.xml"),
            "the same configuration must serialise identically, or every write would look like a change"
        )
    }
}
