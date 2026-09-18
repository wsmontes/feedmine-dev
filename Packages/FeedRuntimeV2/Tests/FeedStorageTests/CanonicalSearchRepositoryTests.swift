import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// The canonical content index as a reader's local search reads it (plan §14 PR-14, clause two:
/// *Search de conteúdo usa FTS canônica*).
///
/// Every fact here is produced by the real write path — `AdmissionEngine` fills the index inside the
/// transaction that makes a revision current — so the read is exercised against the same shape
/// production writes, not against rows a test inserted to fit the query.
final class CanonicalSearchRepositoryTests: RuntimeV2TestCase {
    private let repository = CanonicalSearchRepository()

    // MARK: - What a hit carries

    func testSearchReturnsTheAdmittedContentWithItsSourceLinkAndMedia() async throws {
        try registerTarget()
        let source = try insertSource(editorialKey: "catalog:deep-sky", displayTitle: "Deep Sky Notes")
        let membership = try MembershipClaim(sourceID: source, membershipKind: "editorial")
        let image = try MediaCandidateClaim(
            role: .image,
            resourceURL: "https://cdn.example.test/sky.jpg",
            mediaTypeHint: "image/jpeg"
        )
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [
                    try observation(
                        object: "item-1",
                        version: "v1",
                        headline: "Night sky observing",
                        excerpt: "A guide to stargazing",
                        body: "Body about telescopes",
                        link: "https://example.test/sky",
                        authoredAt: TestInstant.seconds(-600),
                        memberships: [membership],
                        media: [image],
                        observedAt: TestInstant.seconds(1)
                    )
                ]
            )
        )
        // The bridge rows the acquisition composition writes for the same source and item
        // (ADR-003 D18), which is what makes the result addressable by the legacy reader.
        let editorialKey = try EditorialSourceKey(
            catalogIdentity: "catalog:deep-sky",
            canonicalizationVersion: 1
        )
        try LegacyMappingStore().recordSourceMapping(
            LegacySourceMapping(
                editorialKey: editorialKey,
                catalogSourceID: CatalogSourceID(77),
                runtimeSourceID: source,
                legacyURL: "https://example.test/feed.xml",
                mappedAt: TestInstant.epoch
            ),
            in: database
        )
        try LegacyMappingStore().recordItemMapping(
            LegacyItemMapping(
                legacyItemID: "legacy-sky",
                legacySourceURL: "https://example.test/feed.xml",
                record: try OriginRecordID(1),
                revision: try OriginRevisionID(1),
                confidence: .high,
                mappedAt: TestInstant.epoch
            ),
            in: database
        )

        let hits = try await repository.search("stargazing", in: database)

        XCTAssertEqual(hits.count, 1, "the projection the admitted revision wrote is what matched")
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.originRecordID.rawValue, 1)
        XCTAssertEqual(hit.originRevisionID.rawValue, 1)
        XCTAssertEqual(hit.headline, "Night sky observing")
        XCTAssertEqual(hit.summary, "A guide to stargazing")
        XCTAssertEqual(hit.bodyExcerpt, "Body about telescopes")
        XCTAssertEqual(hit.primaryLink, "https://example.test/sky")
        XCTAssertEqual(hit.authoredAt, TestInstant.seconds(-600))
        XCTAssertEqual(hit.observedAt, TestInstant.seconds(1))
        XCTAssertEqual(hit.sourceTitle, "Deep Sky Notes")
        XCTAssertEqual(hit.sourceKey, "catalog:deep-sky")
        XCTAssertEqual(hit.legacySourceURL, "https://example.test/feed.xml")
        XCTAssertEqual(hit.legacyItemID, "legacy-sky")
        XCTAssertEqual(hit.imageURL, "https://cdn.example.test/sky.jpg")
        XCTAssertNil(hit.audioURL)
    }

    /// The hit is the record's *current* revision: after a newer revision becomes current the index
    /// answers with the new text and the superseded term matches nothing.
    func testSearchFollowsTheCurrentRevisionAndForgetsTheSupersededOne() async throws {
        try registerTarget()
        try admitRequiringSuccess(
            try batch(
                id: "batch-1",
                expectedCheckpoint: 0,
                observations: [try observation(object: "item-1", version: "v1", headline: "Alpha", body: "first only")]
            )
        )
        let alpha = try await repository.search("Alpha", in: database)
        XCTAssertEqual(alpha.map(\.headline), ["Alpha"])

        try admitRequiringSuccess(
            try batch(
                id: "batch-2",
                expectedCheckpoint: 1,
                observations: [
                    try observation(
                        object: "item-1",
                        version: "v2",
                        precedence: .makeCurrent(expectedRevision: try OriginRevisionID(1)),
                        headline: "Beta",
                        body: "second only"
                    )
                ]
            )
        )

        let beta = try await repository.search("Beta", in: database)
        XCTAssertEqual(beta.map(\.headline), ["Beta"])
        let superseded = try await repository.search("Alpha", in: database)
        XCTAssertTrue(superseded.isEmpty)
    }

    // MARK: - Bounds

    func testSearchOrdersNewestFirstAndHonoursItsLimit() async throws {
        try registerTarget()
        var observations: [AcquisitionObservation] = []
        for index in 0..<3 {
            observations.append(
                try observation(
                    object: "item-\(index)",
                    version: "v1",
                    headline: "Common term \(index)",
                    authoredAt: TestInstant.seconds(TimeInterval(index * 60))
                )
            )
        }
        try admitRequiringSuccess(
            try batch(id: "batch-1", expectedCheckpoint: 0, observations: observations)
        )

        let all = try await repository.search("Common", in: database)
        XCTAssertEqual(all.map(\.headline), ["Common term 2", "Common term 1", "Common term 0"])

        let limited = try await repository.search("Common", limit: 2, in: database)
        XCTAssertEqual(limited.map(\.headline), ["Common term 2", "Common term 1"])
    }

    func testSearchRejectsANonPositiveLimit() throws {
        try database.read { database in
            XCTAssertThrowsError(try repository.search("anything", limit: 0, in: database)) { error in
                XCTAssertEqual(error as? CanonicalSearchError, .nonPositiveLimit(0))
            }
        }
    }
}
