import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// PR-05, storage half: the concrete `selection_supply` read.
///
/// Every test runs against a real on-disk runtime database (`RuntimeV2TestCase`), because the read is
/// SQL and the access path is part of the contract.
final class SelectionSupplyRepositoryTests: RuntimeV2TestCase {
    private let repository = SelectionSupplyRepository()

    private func sourceKey(_ identity: String, version: Int = 1) throws -> EditorialSourceKey {
        try EditorialSourceKey(catalogIdentity: identity, canonicalizationVersion: version)
    }

    // MARK: - Keyset pagination

    func testPageWalksTheSupplyInKeysetOrderWithoutRepeatingRows() throws {
        let source = try ensureSource("catalog:one")
        for index in 0..<5 {
            try insertSupplyRow(
                objectKey: "item-\(index)",
                sourceIDs: [source],
                publishedAtClaim: 1_700_000_000_000 + Int64(index),
                observedAt: 1_700_000_000_000 + Int64(index)
            )
        }

        var cursor: Int64?
        var keys: [String] = []
        var pages = 0
        var examined = 0
        while true {
            let page = try repository.page(
                SupplyPageRequest(
                    sourceSelection: [SourceSelection(sourceKey: try sourceKey("catalog:one"), enabled: true)],
                    after: cursor,
                    windowRows: 2
                ),
                in: database
            )
            pages += 1
            examined += page.examinedRows
            keys.append(contentsOf: page.candidates.map(\.stableKey.canonical))
            guard let next = page.nextCursor, !page.exhausted else { break }
            cursor = next
            XCTAssertGreaterThan(pages, 0)
        }

        XCTAssertEqual(keys.count, 5, "every row is read exactly once")
        XCTAssertEqual(Set(keys).count, 5, "a keyset page never repeats a row")
        XCTAssertEqual(examined, 5, "the walk examines each supply row once")
        XCTAssertEqual(pages, 3, "two-row windows over five rows")
    }

    func testPageExaminesAtMostItsWindow() throws {
        let source = try ensureSource("catalog:window")
        for index in 0..<7 {
            try insertSupplyRow(objectKey: "window-\(index)", sourceIDs: [source], observedAt: 1000 + Int64(index))
        }

        let page = try repository.page(
            SupplyPageRequest(
                sourceSelection: [SourceSelection(sourceKey: try sourceKey("catalog:window"), enabled: true)],
                after: nil,
                windowRows: 3
            ),
            in: database
        )
        XCTAssertEqual(page.examinedRows, 3)
        XCTAssertEqual(page.candidates.count, 3)
        XCTAssertFalse(page.exhausted)
        XCTAssertEqual(try repository.totalSupplyRows(in: database), 7)
    }

    // MARK: - Hard eligibility in SQL

    func testDisabledSourceExcludesBothSoleAndMixedMemberships() throws {
        let enabled = try ensureSource("catalog:enabled")
        let disabled = try ensureSource("catalog:disabled")
        try insertSupplyRow(objectKey: "only-enabled", sourceIDs: [enabled], observedAt: 1000)
        try insertSupplyRow(objectKey: "only-disabled", sourceIDs: [disabled], observedAt: 1000)
        try insertSupplyRow(objectKey: "mixed", sourceIDs: [enabled, disabled], observedAt: 1000)

        let selection = [
            SourceSelection(sourceKey: try sourceKey("catalog:enabled"), enabled: true),
            SourceSelection(sourceKey: try sourceKey("catalog:disabled"), enabled: false),
        ]
        let page = try repository.page(
            SupplyPageRequest(sourceSelection: selection, after: nil, windowRows: 10),
            in: database
        )
        XCTAssertEqual(page.candidates.map(\.stableKey.canonical).count, 1)
        XCTAssertEqual(page.candidates.first?.sourceKey, try sourceKey("catalog:enabled"))
    }

    func testAnEmptySelectionAdmitsEveryRecordWithAMembership() throws {
        let first = try ensureSource("catalog:first")
        let second = try ensureSource("catalog:second")
        try insertSupplyRow(objectKey: "first", sourceIDs: [first], observedAt: 1000)
        try insertSupplyRow(objectKey: "second", sourceIDs: [second], observedAt: 1000)

        let page = try repository.page(
            SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 10),
            in: database
        )
        XCTAssertEqual(page.candidates.count, 2)
    }

    func testUnavailableRecordIsNotSupply() throws {
        let source = try ensureSource("catalog:availability")
        try insertSupplyRow(objectKey: "available", sourceIDs: [source], observedAt: 1000)
        try insertSupplyRow(
            objectKey: "revoked",
            sourceIDs: [source],
            observedAt: 1000,
            availability: "revoked"
        )
        let page = try repository.page(
            SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 10),
            in: database
        )
        XCTAssertEqual(page.candidates.count, 1)
    }

    /// A plan whose cards are the reader's saved subjects reads only the records those subjects name.
    ///
    /// The cards of a bookmark box exist in no source selection: they are `user_state_projection` rows
    /// the reader's own action wrote, and `legacy_item_map` names the canonical record each subject is.
    /// Until this scope existed the engine's only read was a source selection over the whole supply, so
    /// a session started for such a surface would have composed the feed under the surface's title —
    /// the failure `rollout.md` §2.5 warns a surface moved too early produces.
    func testASavedSubjectsScopeReadsOnlyTheSavedRecords() throws {
        let source = try ensureSource("catalog:scope")
        let saved = try insertSupplyRow(objectKey: "saved", sourceIDs: [source], observedAt: 1000)
        try insertSupplyRow(objectKey: "unsaved", sourceIDs: [source], observedAt: 1001)
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO user_state_projection (
                    kind, subject_id, wanted, last_operation_id, revision, updated_at
                ) VALUES (?, ?, 1, 'op-save', 1, 0)
                """, arguments: [SubjectKind.bookmark.rawValue, "legacy-saved"])
            try database.execute(sql: """
                INSERT INTO legacy_item_map (
                    legacy_item_id, legacy_source_url, origin_record_id, origin_revision_id,
                    confidence, mapped_at
                ) VALUES (?, 'https://feeds.example.test/tech.xml', ?, ?, 'high', 0)
                """, arguments: ["legacy-saved", saved.recordID, saved.revisionID])
        }

        let unscoped = try repository.page(
            SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 10),
            in: database
        )
        XCTAssertEqual(unscoped.candidates.count, 2, "without a scope the supply reads as it did")

        let scoped = try repository.page(
            SupplyPageRequest(
                sourceSelection: [],
                subjectSelection: .savedSubjects(kind: .bookmark, listKey: nil),
                after: nil,
                windowRows: 10
            ),
            in: database
        )
        XCTAssertEqual(
            scoped.candidates.map(\.originRecordID.rawValue),
            [saved.recordID],
            "only the record the saved subject resolves to"
        )

        // A removal is projected as `wanted = 0` rather than as a deleted row (ADR-004 D7), and it has
        // to leave the page for the same reason it leaves the reader's list.
        try database.write { database in
            try database.execute(
                sql: "UPDATE user_state_projection SET wanted = 0 WHERE subject_id = 'legacy-saved'"
            )
        }
        let afterRemoval = try repository.page(
            SupplyPageRequest(
                sourceSelection: [],
                subjectSelection: .savedSubjects(kind: .bookmark, listKey: nil),
                after: nil,
                windowRows: 10
            ),
            in: database
        )
        XCTAssertTrue(afterRemoval.candidates.isEmpty, "an unsaved subject stops selecting its record")
    }

    /// A list nobody has saved into matches nothing rather than everything.
    ///
    /// The case used to be "a scope the storage cannot honour"; with the list key projected it is simply
    /// an empty membership, and the distinction matters — the honest failure is an empty page, never the
    /// whole supply under a box's title (`rollout.md` §2.5, `baseline.md` §8.58).
    func testAListNobodySavedIntoMatchesNothing() throws {
        let source = try ensureSource("catalog:unhonourable")
        try insertSupplyRow(objectKey: "present", sourceIDs: [source], observedAt: 1000)

        let page = try repository.page(
            SupplyPageRequest(
                sourceSelection: [],
                subjectSelection: .savedSubjects(kind: .bookmark, listKey: "box-nobody-saved-into"),
                after: nil,
                windowRows: 10
            ),
            in: database
        )
        XCTAssertTrue(page.candidates.isEmpty)
        XCTAssertEqual(page.examinedRows, 1, "the window still bounds the cost")
        XCTAssertTrue(page.exhausted)
    }

    /// A box selects that list's membership — not every saved card.
    ///
    /// This is the distinction §8.58 measured: `selectedBookmarkListID`'s setter loads
    /// `bookmarkedItems(listID:)`, so a box holds what was filed into it, and a card saved into another
    /// list must not appear. Before the list key was projected, the runtime's only saved-subject
    /// selection was the whole saved set, which for a named box is a different set of cards.
    func testABoxSelectsItsOwnMembershipAndNotEverySavedCard() throws {
        let source = try ensureSource("catalog:boxes")
        let inBox = try insertSupplyRow(objectKey: "in-box", sourceIDs: [source], observedAt: 1000)
        let inOtherBox = try insertSupplyRow(objectKey: "in-other-box", sourceIDs: [source], observedAt: 1001)
        try insertSupplyRow(objectKey: "unsaved", sourceIDs: [source], observedAt: 1002)

        let projections = UserStateProjectionStore(database: database)
        // Both cards are saved: the whole-set projection has both, and only the membership says which
        // box each is filed under.
        for (index, row) in [inBox, inOtherBox].enumerated() {
            try projections.apply(
                kind: .bookmark,
                subjectID: "legacy-\(index)",
                wanted: true,
                operationID: "op-save-\(index)",
                at: Date(timeIntervalSince1970: 0)
            )
            try database.write { database in
                try database.execute(sql: """
                    INSERT INTO legacy_item_map (
                        legacy_item_id, legacy_source_url, origin_record_id, origin_revision_id,
                        confidence, mapped_at
                    ) VALUES (?, 'https://example.test/feed.xml', ?, ?, 'high', 0)
                    """, arguments: ["legacy-\(index)", row.recordID, row.revisionID])
            }
        }
        try projections.applyListMembership(
            listKey: "box-a",
            subjectID: "legacy-0",
            wanted: true,
            operationID: "op-file-0",
            at: Date(timeIntervalSince1970: 0)
        )
        try projections.applyListMembership(
            listKey: "box-b",
            subjectID: "legacy-1",
            wanted: true,
            operationID: "op-file-1",
            at: Date(timeIntervalSince1970: 0)
        )

        func box(_ listKey: String) throws -> [Int64] {
            try repository.page(
                SupplyPageRequest(
                    sourceSelection: [],
                    subjectSelection: .savedSubjects(kind: .bookmark, listKey: listKey),
                    after: nil,
                    windowRows: 10
                ),
                in: database
            ).candidates.map(\.originRecordID.rawValue)
        }

        XCTAssertEqual(try box("box-a"), [inBox.recordID], "the box holds what was filed into it")
        XCTAssertEqual(try box("box-b"), [inOtherBox.recordID])

        let wholeSet = try repository.page(
            SupplyPageRequest(
                sourceSelection: [],
                subjectSelection: .savedSubjects(kind: .bookmark, listKey: nil),
                after: nil,
                windowRows: 10
            ),
            in: database
        )
        XCTAssertEqual(
            wholeSet.candidates.map(\.originRecordID.rawValue).sorted(),
            [inBox.recordID, inOtherBox.recordID].sorted(),
            "without a list key the selection is every saved card"
        )

        // A removal is a membership write of 0, not a deleted row (ADR-004 D7), and it leaves the box.
        try projections.applyListMembership(
            listKey: "box-a",
            subjectID: "legacy-0",
            wanted: false,
            operationID: "op-unfile-0",
            at: Date(timeIntervalSince1970: 1)
        )
        XCTAssertTrue(try box("box-a").isEmpty, "an unfiled subject stops selecting its record")
    }

    // MARK: - Projections the read model carries

    func testTheCandidateCarriesDurableFacetsAndAFallbackSortDate() throws {
        let source = try ensureSource("catalog:facets")
        let provider = try ensureProvider(key: "publisher-a")
        try insertSupplyRow(
            objectKey: "facet-item",
            sourceIDs: [source],
            providerID: provider,
            headline: "Headline text",
            summary: "Summary text",
            observedAt: 1_700_000_500_000,
            mediaRoles: [.image, .audio]
        )

        let candidate = try XCTUnwrap(
            try repository.page(
                SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 10),
                in: database
            ).candidates.first
        )
        XCTAssertEqual(candidate.stableKey.namespace.rawValue, "connector.test")
        XCTAssertEqual(candidate.stableKey.scopeKey, "feed-1")
        XCTAssertEqual(candidate.providerKey?.providerKey, "publisher-a")
        XCTAssertEqual(candidate.mediaRoles, [.audio, .image])
        XCTAssertTrue(candidate.filterText.contains("Headline text"))
        XCTAssertTrue(candidate.filterText.contains("Summary text"))
        // ADR-003 D17: no authored date means the observation time stands in, reported as a fallback.
        XCTAssertTrue(candidate.sortDateIsFallback)
        XCTAssertEqual(candidate.sortDate.timeIntervalSince1970, 1_700_000_500)
        XCTAssertEqual(candidate.sortDatePolicyVersion, SortDatePolicy.currentVersion)
    }

    func testClusterEdgesAreDurableAndOnlySyndicationVerbs() throws {
        let source = try ensureSource("catalog:cluster")
        let original = try insertSupplyRow(objectKey: "original", sourceIDs: [source], observedAt: 1000)
        let repost = try insertSupplyRow(objectKey: "repost", sourceIDs: [source], observedAt: 1001)
        let reply = try insertSupplyRow(objectKey: "reply", sourceIDs: [source], observedAt: 1002)
        try insertRelation(subject: repost.recordID, verb: "repostOf", object: original.recordID)
        try insertRelation(subject: reply.recordID, verb: "replyTo", object: original.recordID)

        let page = try repository.page(
            SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 10),
            in: database
        )
        XCTAssertEqual(page.candidates.count, 3)
        XCTAssertEqual(page.clusterEdges.count, 1)
        let edge = try XCTUnwrap(page.clusterEdges.first)
        XCTAssertEqual(edge.verb, .repostOf)
        XCTAssertEqual(edge.subject.canonical, page.candidates[1].stableKey.canonical)
        XCTAssertEqual(edge.object.canonical, page.candidates[0].stableKey.canonical)
    }

    func testAnEdgeWhoseObjectIsNotInThePageIsDropped() throws {
        let source = try ensureSource("catalog:half-edge")
        let first = try insertSupplyRow(objectKey: "first", sourceIDs: [source], observedAt: 1000)
        let second = try insertSupplyRow(objectKey: "second", sourceIDs: [source], observedAt: 1001)
        try insertRelation(subject: second.recordID, verb: "repostOf", object: first.recordID)

        // A page of one row cannot resolve the edge: the grouping is pool-local and never invents a
        // member it did not read.
        let page = try repository.page(
            SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 1),
            in: database
        )
        XCTAssertEqual(page.candidates.count, 1)
        XCTAssertTrue(page.clusterEdges.isEmpty)
    }

    // MARK: - Evidence independence (I-03)

    func testSelectionReadIsIndependentOfConnectorEvidence() throws {
        let source = try ensureSource("catalog:evidence")
        try insertSupplyRow(
            objectKey: "evidence-item",
            sourceIDs: [source],
            headline: "Text",
            publishedAtClaim: 1_700_000_100_000,
            observedAt: 1_700_000_000_000
        )
        let request = SupplyPageRequest(sourceSelection: [], after: nil, windowRows: 10)
        let before = try repository.page(request, in: database)

        try insertConnectorEvidence(batchID: "batch-1", digest: "a", bytes: Data(repeating: 0xAB, count: 256))
        try insertConnectorEvidence(batchID: "batch-2", digest: "b", bytes: nil)
        let after = try repository.page(request, in: database)

        XCTAssertEqual(before.candidates, after.candidates)
        XCTAssertEqual(before.clusterEdges, after.clusterEdges)
        XCTAssertEqual(try rowCount("connector_evidence"), 2)
    }

    /// The dependency half of the same proof: no file on the selection path mentions evidence, a wire
    /// format or a JSON decoder in code. Comments are stripped first, because the doc comments do name
    /// what the path refuses to read.
    func testSelectionPathNamesNoEvidenceOrProtocolInput() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directories = [
            "Sources/FeedDomain/Plans",
            "Sources/FeedRuntime/Selection",
            "Sources/FeedStorage/Selection",
        ]
        let forbidden = [
            "connector_evidence",
            "evidence_blob",
            "JSONDecoder",
            "JSONSerialization",
            "FeedKit",
            "FeedConnectorSyndication",
        ]

        var scanned = 0
        for directory in directories {
            let base = packageRoot.appendingPathComponent(directory, isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
            XCTAssertFalse(files.isEmpty, "\(directory) must contain sources")
            for file in files {
                scanned += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in source.components(separatedBy: .newlines).enumerated() {
                    let code = line.components(separatedBy: "//").first ?? ""
                    for token in forbidden {
                        XCTAssertFalse(
                            code.contains(token),
                            "\(file.lastPathComponent):\(number + 1) names '\(token)' in code"
                        )
                    }
                }
            }
        }
        // The invariant is the scan above: no file in the selection path may name connector
        // evidence, a blob, or a protocol parser. This guard only exists so the scan cannot pass by
        // covering nothing, and the per-directory `files.isEmpty` assertions already do that job.
        // An exact count would re-break on every legitimate addition — PR-14 added the per-surface
        // planning pair (`FeedDomain/Plans/FeedSurfacePlans.swift`,
        // `FeedRuntime/Selection/FeedSurfacePlanning.swift`), which are members of these paths by
        // design and which passed the token scan. So assert the floor, and assert by name that the
        // files the selection path is built from are still the ones being scanned.
        XCTAssertGreaterThanOrEqual(scanned, 7, "the three selection paths must all contribute sources")
        let required = [
            "Sources/FeedDomain/Plans/SelectionDraft.swift",
            "Sources/FeedRuntime/Selection/SelectionEngine.swift",
            "Sources/FeedStorage/Selection/SelectionSupplyRepository.swift",
        ]
        for relative in required {
            let path = packageRoot.appendingPathComponent(relative)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path.path),
                "\(relative) is part of the selection path and must exist to be scanned"
            )
        }
    }
}
