import Foundation
import XCTest
import FeedDomain
@testable import FeedConnectorSyndication

/// The translator is tested directly, byte-for-byte on synthetic documents: never through a real
/// HTTP call and never only through the connector (plan §12, §14 PR-11).
final class SyndicationTranslatorTests: XCTestCase {
    private let scope = ExternalScopeKey(
        namespace: SyndicationNamespace.connector,
        scopeKey: "source-1"
    )

    private func translate(
        _ document: String,
        maxItems: Int = 200,
        previous: [String: SyndicationRepresentationStamp] = [:]
    ) throws -> SyndicationTranslation {
        let result = SyndicationTranslator().translate(
            data: Data(document.utf8),
            scope: scope,
            observedAt: TestFixtures.observedAt,
            maxItems: maxItems,
            previousRepresentations: previous
        )
        return try result.get()
    }

    private func versionText(of item: SyndicationTranslatedItem) -> String? {
        item.observation.versionKey.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    // MARK: - RSS

    func testRSSItemsBecomeCanonicalObservations() throws {
        let translation = try translate(TestFixtures.rssTwoItems)

        XCTAssertEqual(translation.documentKind, .rss)
        XCTAssertEqual(translation.declaredItemCount, 2)
        XCTAssertTrue(translation.rejections.isEmpty)
        XCTAssertFalse(translation.truncatedByItemCeiling)
        XCTAssertTrue(translation.consumedWholeDocument)

        let first = translation.items[0]
        XCTAssertEqual(String(decoding: first.observation.externalKey.bytes, as: UTF8.self), "tag:example.com,2026:first")
        XCTAssertEqual(first.observation.payload.headline, "First")
        XCTAssertEqual(first.observation.payload.link?.absoluteString, "https://example.com/first")
        XCTAssertEqual(first.observation.payload.excerpt, "First excerpt")
        XCTAssertEqual(first.observation.payload.observedAt, TestFixtures.observedAt)
        XCTAssertEqual(versionText(of: first), "2026-09-14T10:00:00Z")
        XCTAssertEqual(first.identityRequest.confidence, .high)
        XCTAssertNil(first.identityRequest.fallbackSchemeVersion)
        XCTAssertEqual(first.observation.precedence, .makeCurrent(expectedRevision: nil))

        // No declaration of a modified time in RSS: `modifiedAt` stays empty rather than repeating
        // the authored date or the observation time (ADR-003 D17).
        XCTAssertEqual(first.observation.payload.authoredAt, try TestFixtures.instant("2026-09-14T10:00:00Z"))
        XCTAssertNil(first.observation.payload.modifiedAt)
    }

    /// The non-negotiable property: a GUID that is spelled like a URL is a byte string, not a URL.
    func testGUIDSpelledLikeAURLIsPassedThroughByteIdentical() throws {
        let translation = try translate(TestFixtures.rssTwoItems)
        let second = translation.items[1]

        XCTAssertEqual(
            String(decoding: second.observation.externalKey.bytes, as: UTF8.self),
            TestFixtures.urlSpelledGUID
        )
        XCTAssertEqual(second.observation.externalKey.bytes, Data(TestFixtures.urlSpelledGUID.utf8))
        XCTAssertEqual(second.observation.externalKey.keyKind, .object)

        // The query is still in the key and the declared link is a different value: the key was not
        // replaced by, resolved against or normalised into the payload link (ADR-003 D10).
        XCTAssertTrue(
            String(decoding: second.observation.externalKey.bytes, as: UTF8.self).contains("utm_source=feed&id=2")
        )
        XCTAssertEqual(second.observation.payload.link?.absoluteString, "https://example.com/second")

        // Two items whose GUIDs differ must resolve to different objects, whatever the spelling.
        XCTAssertNotEqual(translation.items[0].observation.externalKey, second.observation.externalKey)
    }

    func testMissingGUIDFallsBackToTheDeclaredLink() throws {
        let translation = try translate(TestFixtures.rssWithoutGUID, maxItems: 1)
        let item = translation.items[0]

        XCTAssertEqual(
            String(decoding: item.observation.externalKey.bytes, as: UTF8.self),
            "https://example.com/link-only"
        )
        // The declared link is a declared identity: full confidence, no fallback scheme (D16).
        XCTAssertEqual(item.identityRequest.confidence, .high)
        XCTAssertNil(item.identityRequest.fallbackSchemeVersion)
    }

    func testItemWithoutIdentifierOrLinkUsesTheVersionedLowConfidenceScheme() throws {
        let translation = try translate(TestFixtures.rssWithoutAnyIdentifier)
        XCTAssertEqual(translation.items.count, 2)

        for item in translation.items {
            XCTAssertEqual(item.identityRequest.confidence, .low)
            XCTAssertEqual(item.identityRequest.fallbackSchemeVersion, FallbackIdentityScheme.currentVersion)
            XCTAssertEqual(item.observation.externalKey.keyKind, .object)
        }

        // Same title and same date, different content: the disambiguator keeps them apart, so two
        // pieces of content never share one identity by accident (ADR-003 D16).
        XCTAssertNotEqual(
            translation.items[0].observation.externalKey,
            translation.items[1].observation.externalKey
        )

        // The same document always derives the same fallback keys: the derivation is stable, not
        // seeded per process.
        let again = try translate(TestFixtures.rssWithoutAnyIdentifier)
        XCTAssertEqual(translation.items[0].observation.externalKey, again.items[0].observation.externalKey)
        XCTAssertEqual(translation.items[1].observation.externalKey, again.items[1].observation.externalKey)
    }

    func testMissingHeadlineOrLinkIsAdmissibleAndNeverSynthesized() throws {
        let withoutHeadline = try translate(TestFixtures.rssWithoutHeadline, maxItems: 1).items[0]
        XCTAssertNil(withoutHeadline.observation.payload.headline)
        XCTAssertEqual(withoutHeadline.observation.payload.link?.absoluteString, "https://example.com/sparse")
        // The declared GUID is still the identity: a missing headline never invents one, and never
        // demotes the item to the fallback scheme.
        XCTAssertEqual(String(decoding: withoutHeadline.observation.externalKey.bytes, as: UTF8.self), "sparse-1")
        XCTAssertEqual(withoutHeadline.identityRequest.confidence, .high)

        let withoutLink = try translate(TestFixtures.rssWithoutLink, maxItems: 1).items[0]
        XCTAssertEqual(withoutLink.observation.payload.headline, "Linkless")
        XCTAssertNil(withoutLink.observation.payload.link)
        XCTAssertEqual(String(decoding: withoutLink.observation.externalKey.bytes, as: UTF8.self), "linkless-1")
    }

    func testEnclosureBecomesASecondaryLinkAndNotADomainField() throws {
        let translation = try translate(TestFixtures.rssWithEnclosure, maxItems: 1)
        let item = translation.items[0]

        XCTAssertEqual(item.secondaryLinks, [SyndicationSecondaryLink(
            relation: .enclosure,
            url: "https://cdn.example.com/audio/episode-one.mp3",
            mediaType: "audio/mpeg",
            byteLength: 1234
        )])
        // The canonical link stays the declared `<link>`; the enclosure never displaces it and never
        // becomes a synthesised payload field.
        XCTAssertEqual(item.observation.payload.link?.absoluteString, "https://example.com/episode-one")
    }

    func testDeclaredButUnparsableDateIsNotSubstituted() throws {
        let translation = try translate(TestFixtures.rssUnparsableDate, maxItems: 1)
        let item = translation.items[0]

        // The element is there but declares no instant: no date is invented, and the observation time
        // is not substituted for either field (ADR-003 D17).
        XCTAssertNil(item.observation.payload.authoredAt)
        XCTAssertNil(item.observation.payload.modifiedAt)
        XCTAssertNil(item.observation.payload.modifiedAt)
        XCTAssertEqual(item.observation.payload.observedAt, TestFixtures.observedAt)
        // No declared version either, so the representation is matched by payload instead.
        XCTAssertNil(item.observation.versionKey)
        XCTAssertNil(item.representation.declaredVersion)
    }

    func testUnchangedRepresentationIsDuplicateAndChangedContentIsCurrent() throws {
        let original = TestFixtures.rssSingleItem(
            pubDate: "Mon, 14 Sep 2026 10:00:00 GMT",
            title: "Same title",
            description: "Same content"
        )
        let first = try translate(original)
        XCTAssertEqual(first.items[0].observation.precedence, .makeCurrent(expectedRevision: nil))
        let stamps = first.observedRepresentations
        XCTAssertEqual(stamps.count, 1)

        // Byte-identical document under the same checkpoint: an unchanged representation.
        let second = try translate(original, previous: stamps)
        XCTAssertEqual(second.items[0].observation.precedence, .duplicate)

        // Same declared version, changed payload: NOT a duplicate. Admission records the divergence
        // instead of the change being dropped (ADR-003 D11).
        let divergence = try translate(
            TestFixtures.rssSingleItem(
                pubDate: "Mon, 14 Sep 2026 10:00:00 GMT",
                title: "Same title",
                description: "Changed content"
            ),
            previous: stamps
        )
        XCTAssertEqual(divergence.items[0].observation.precedence, .makeCurrent(expectedRevision: nil))

        // Changed declared version: a new representation, and an older one is never ordered away.
        let newer = try translate(
            TestFixtures.rssSingleItem(
                pubDate: "Tue, 15 Sep 2026 10:00:00 GMT",
                title: "Same title",
                description: "Same content"
            ),
            previous: stamps
        )
        XCTAssertEqual(newer.items[0].observation.precedence, .makeCurrent(expectedRevision: nil))

        // A declared version that goes backwards is still a *different* declaration: the connector
        // cannot order two version keys, so comparing them only ever answers "not the same", never
        // "older". The run therefore asks for current again instead of inventing history (D9).
        let backwards = try translate(
            original,
            previous: newer.observedRepresentations
        )
        XCTAssertEqual(backwards.items[0].observation.precedence, .makeCurrent(expectedRevision: nil))
    }

    // MARK: - Atom

    func testAtomUpdateIsTheDeclaredVersionKeyAndIsNeverAssumedOrdered() throws {
        let translation = try translate(TestFixtures.atomEntry)
        let item = translation.items[0]

        XCTAssertEqual(translation.documentKind, .atom)
        XCTAssertEqual(String(decoding: item.observation.externalKey.bytes, as: UTF8.self), "urn:uuid:entry-1")
        XCTAssertEqual(versionText(of: item), "2026-09-14T10:00:00Z")
        XCTAssertEqual(item.observation.payload.excerpt, "Atom summary")
        XCTAssertEqual(item.observation.payload.body, "<p>Body</p>")
        XCTAssertEqual(item.observation.payload.link?.absoluteString, "https://example.com/atom-first")

        // `atom:published` is the authored date and `atom:updated` the modified one; neither is
        // substituted for the other and neither is turned into a version key of the other's element.
        let authored: String? = item.observation.payload.authoredAt.map(SyndicationTranslator.versionText)
        let modified: String? = item.observation.payload.modifiedAt.map(SyndicationTranslator.versionText)
        XCTAssertEqual(authored, "2026-09-13T09:00:00Z")
        XCTAssertEqual(modified, "2026-09-14T10:00:00Z")

        // An appearance and an update both start from the same declaration: `updated`.
        let update = try translate(TestFixtures.atomEntry(
            updated: "2026-09-20T10:00:00Z",
            title: "Atom first",
            summary: "Updated"
        ))
        XCTAssertEqual(versionText(of: update.items[0]), "2026-09-20T10:00:00Z")

        // A declared version older than the one already recorded is still a current request: the
        // connector never orders two version keys, so it never emits `historicalOnly` (ADR-003 D9).
        let older = try translate(
            TestFixtures.atomEntry(updated: "2026-09-01T10:00:00Z", title: "Atom first", summary: "Older"),
            previous: update.observedRepresentations
        )
        XCTAssertEqual(older.items[0].observation.precedence, .makeCurrent(expectedRevision: nil))
        XCTAssertNotEqual(older.items[0].observation.precedence, .historicalOnly)
    }

    func testAtomEnclosureAndSecondAlternateBecomeSecondaryLinks() throws {
        let translation = try translate(TestFixtures.atomEntry)
        let item = translation.items[0]

        XCTAssertEqual(item.secondaryLinks, [
            SyndicationSecondaryLink(
                relation: .alternate,
                url: "https://example.com/atom-first?amp=1",
                mediaType: "text/html",
                byteLength: nil
            ),
            SyndicationSecondaryLink(
                relation: .enclosure,
                url: "https://cdn.example.com/atom.mp3",
                mediaType: "audio/mpeg",
                byteLength: 999
            ),
        ])
    }

    // MARK: - The D12 distinguisher

    func testEmptyItemWithoutIdentityMaterialIsRejectedNotInvented() throws {
        let translation = try translate(TestFixtures.rssWithEmptyItem)

        XCTAssertEqual(translation.declaredItemCount, 1)
        XCTAssertTrue(translation.items.isEmpty)
        XCTAssertEqual(translation.rejections.count, 1)
        XCTAssertEqual(translation.rejections[0].index, 0)
        // A declared item that carries nothing is recorded, never silently dropped, and it blocks
        // validator confirmation because the document was not consumed (ADR-005 D12).
        XCTAssertFalse(translation.consumedWholeDocument)
    }

    func testEmptyRecognizedDocumentIsDistinguishedFromAnUnmappableOne() throws {
        let declaresMetadata = try translate(TestFixtures.rssEmptyChannel)
        XCTAssertTrue(declaresMetadata.items.isEmpty)
        XCTAssertTrue(declaresMetadata.rejections.isEmpty)
        XCTAssertEqual(declaresMetadata.declaredItemCount, 0)
        // A valid document with no observations: the connector can tell, so its validator may be
        // confirmed (ADR-005 D12).
        XCTAssertTrue(declaresMetadata.consumedWholeDocument)

        let declaresNothing = try translate(TestFixtures.rssBareChannel)
        XCTAssertTrue(declaresNothing.items.isEmpty)
        XCTAssertTrue(declaresNothing.rejections.isEmpty)
        XCTAssertFalse(declaresNothing.declaresFeedMetadata)
        // Nothing at all is not distinguishable from "the entries could not be mapped": no
        // confirmation (ADR-005 D12).
        XCTAssertFalse(declaresNothing.consumedWholeDocument)
    }

    func testItemCeilingTruncatesAndBlocksConfirmation() throws {
        let translation = try translate(TestFixtures.rssTwoItems, maxItems: 1)

        XCTAssertEqual(translation.items.count, 1)
        XCTAssertEqual(translation.declaredItemCount, 2)
        XCTAssertTrue(translation.truncatedByItemCeiling)
        XCTAssertFalse(translation.consumedWholeDocument)
    }

    // MARK: - Refusals

    func testParseFailuresProduceNoTranslation() {
        for document in [TestFixtures.notAFeed, TestFixtures.truncatedFeed] {
            let result = SyndicationTranslator().translate(
                data: Data(document.utf8),
                scope: scope,
                observedAt: TestFixtures.observedAt,
                maxItems: 200
            )
            switch result {
            case .success:
                XCTFail("a document that is not a feed must not translate")
            case .failure(let error):
                guard case .parseFailure = error else {
                    return XCTFail("expected a parse failure, got \(error)")
                }
                XCTAssertFalse(error.reason.isEmpty)
            }
        }
    }

    func testJSONFeedIsRefusedAsAnUnsupportedDocumentKind() {
        let result = SyndicationTranslator().translate(
            data: Data(TestFixtures.jsonFeed.utf8),
            scope: scope,
            observedAt: TestFixtures.observedAt,
            maxItems: 200
        )
        switch result {
        case .success:
            XCTFail("JSON Feed is not translated by this connector")
        case .failure(let error):
            XCTAssertEqual(error, .unsupportedDocumentKind("json"))
        }
    }
}
