import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// PR-06, publication persistence: the frozen payload, the tail compare-and-swap, the append-only
/// aggregate's constraints and the crash points around a commit (plan §9, ADR-001, ADR-006 D14).
///
/// Every test runs against a real on-disk database in `$TMPDIR` with WAL and foreign keys on, and the
/// migration expectations come from a freshly migrated database rather than from a pinned list.
final class PublicationRepositoryTests: RuntimeV2TestCase {
    struct PublishedEdition {
        let source: Int64
        let context: ContextKey
        let edition: EditionSnapshot
        let rows: [SupplyRow]
        let receipt: SegmentCommitReceipt
    }

    // MARK: - Fixtures

    /// One canonical record and one card frozen for it.
    private func card(
        edition: EditionSnapshot,
        record: SupplyRow,
        absoluteOrdinal: Int,
        segmentOrdinal: Int = 0,
        title: String,
        primaryText: String,
        sourceDisplayName: String,
        sourceID: Int64,
        publishedAt: Date?,
        revisionTag: String,
        providerID: Int64? = nil,
        providerDisplayName: String? = nil,
        media: PublishedMediaSet = .none,
        assetReferences: [PublishedAssetRefRecord] = []
    ) throws -> CardInsertRecord {
        CardInsertRecord(
            frozen: try frozenCard(
                edition: edition,
                segmentOrdinal: segmentOrdinal,
                absoluteOrdinal: absoluteOrdinal,
                record: record,
                title: title,
                primaryText: primaryText,
                sourceDisplayName: sourceDisplayName,
                providerDisplayName: providerDisplayName,
                sourceID: sourceID,
                providerID: providerID,
                publishedAt: publishedAt,
                publishedAtKind: publishedAt == nil ? .none : .authored,
                media: media,
                revisionTag: revisionTag
            ),
            assetReferences: assetReferences
        )
    }

    /// Publishes `cardCount` canonical records as the first (activating) segment of a new edition.
    @discardableResult
    private func publishEdition(
        revisionTag: String = "revision-a",
        epoch: Int64 = 1,
        cardCount: Int = 2,
        media: PublishedMediaSet = .none,
        in database: RuntimeDatabase? = nil
    ) throws -> PublishedEdition {
        let database = database ?? self.database
        let source = try ensureSource("catalog:alpha", displayTitle: "Alpha", in: database)
        let rows = try (0..<cardCount).map { index in
            try insertSupplyRow(
                objectKey: "item-\(index)",
                sourceIDs: [source],
                headline: "Headline \(index)",
                summary: "Excerpt \(index)",
                publishedAtClaim: TestInstant.epochMilliseconds,
                observedAt: TestInstant.epochMilliseconds,
                in: database
            )
        }
        let context = try planContext()
        let edition = try openDraft(context: context, revisionTag: revisionTag, epoch: epoch, in: database)
        let cards = try rows.enumerated().map { index, row in
            try card(
                edition: edition,
                record: row,
                absoluteOrdinal: index,
                title: "Headline \(index)",
                primaryText: "Excerpt \(index)",
                sourceDisplayName: "Alpha",
                sourceID: source,
                publishedAt: TestInstant.epoch,
                revisionTag: revisionTag,
                media: media
            )
        }
        let receipt = try publish(
            repositories(in: database),
            token: edition.token,
            cards: cards,
            activation: .activate(successorOf: nil),
            pinned: try rows.map { try OriginRevisionID($0.revisionID) }
        )
        return PublishedEdition(
            source: source,
            context: context,
            edition: edition,
            rows: rows,
            receipt: receipt
        )
    }

    // MARK: - Restoration

    /// `compatibleEditionRestoresWithoutSelection` (plan §19 #17; ADR-002 D8 R1–R3).
    ///
    /// A stored edition restores from its own rows after the canonical supply it was published from has
    /// been evicted entirely: no Selection, no catalog, no network.
    func testCompatibleEditionRestoresWithoutSelection() throws {
        let published = try publishEdition()
        let repository = repositories()
        let before = try repository.cards(in: published.edition.editionID)

        try evictCanonical()
        XCTAssertEqual(try rowCount("origin_record"), 0, "the fixture really removed canonical state")
        XCTAssertEqual(try rowCount("origin_revision"), 0)
        XCTAssertEqual(try rowCount("selection_supply"), 0)
        XCTAssertEqual(try rowCount("supply_generation"), 1, "the supply counter was not reset")

        let outcome = try repository.restore(context: published.context)
        guard case let .restored(edition, records) = outcome else {
            return XCTFail("a compatible edition must restore, got \(outcome)")
        }
        XCTAssertEqual(edition.editionID, published.edition.editionID)
        XCTAssertEqual(edition.state, .active)
        XCTAssertEqual(edition.publicationSchemaVersion, PublicationSchema.currentVersion)
        XCTAssertEqual(records.map(\.payload), before.map(\.payload), "the payloads are byte-identical")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.payload.title, "Headline 0")
        XCTAssertEqual(records.first?.payload.origin.sourceDisplayName, "Alpha")
        XCTAssertEqual(records.first?.payload.publishedAtKind, .authored)
        XCTAssertEqual(records.last?.payload.absoluteOrdinal, 1)

        XCTAssertEqual(try rowCount("origin_record"), 0, "restoring canonical state is not a write path")
        XCTAssertEqual(
            try repository.restore(context: try planContext("another-scope")),
            .noEdition(try planContext("another-scope")),
            "another context has no edition"
        )
    }

    /// `passiveCatalogChangeDoesNotSwapVisibleEdition` (plan §19 #18; ADR-002 D9, INV-15).
    func testPassiveCatalogChangeDoesNotSwapVisibleEdition() throws {
        let published = try publishEdition()
        let repository = repositories()
        let before = try publicationDump()

        try applyPassiveCatalogChange(record: published.rows[0])
        try setSupplyGeneration(3)
        XCTAssertEqual(try scalar("SELECT value FROM supply_generation WHERE id = 1"), 3)

        let active = try repository.activeEdition(for: published.context)
        XCTAssertEqual(active?.editionID, published.edition.editionID)
        XCTAssertEqual(active?.editorialRevision, published.edition.editorialRevision)
        XCTAssertEqual(active?.epoch, published.edition.epoch, "the publication epoch is unchanged")
        XCTAssertEqual(active?.tail, published.receipt.tail, "the tail did not move")
        XCTAssertEqual(active?.state, .active)
        XCTAssertEqual(try repository.activeEditions().count, 1, "exactly one visible edition")
        XCTAssertEqual(try publicationDump(), before, "no published byte changed")
    }

    /// `upstreamAndCatalogEditsLeavePublishedPayloadUnchanged` (plan §19 #19; ADR-001 D4, INV-1/INV-3).
    func testUpstreamAndCatalogEditsLeavePublishedPayloadUnchanged() throws {
        let published = try publishEdition()
        let repository = repositories()
        let cardID = published.receipt.cardIDs[0]
        let before = try cardRows()
        let payloadBefore = try XCTUnwrap(try repository.card(cardID)?.payload)

        // A revision payload is immutable by trigger, not by convention (ADR-004 D5, I-06).
        assertConstraintFailure(
            "UPDATE origin_revision SET headline = 'hacked'",
            containing: "append-only"
        )

        // Everything an upstream or catalog edit is allowed to do: a newer revision becomes current, the
        // catalog renames the source and the provider, the binding and target generations advance.
        try applyPassiveCatalogChange(record: published.rows[0])

        XCTAssertEqual(try cardRows(), before, "every frozen column is byte-identical")
        let payloadAfter = try XCTUnwrap(try repository.card(cardID)?.payload)
        XCTAssertEqual(payloadAfter, payloadBefore)
        XCTAssertEqual(payloadAfter.origin.sourceDisplayName, "Alpha", "the frozen attribution, not the rename")
        XCTAssertEqual(payloadAfter.origin.originRevisionID.rawValue, published.rows[0].revisionID)
        XCTAssertEqual(payloadAfter.origin.originRecordID.rawValue, published.rows[0].recordID)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM published_card WHERE title = 'hacked'"),
            0
        )
    }

    /// `revisionEvictionDoesNotBreakPublishedCard` (plan §19 #20; ADR-001 D5, INV-2/INV-6).
    func testRevisionEvictionDoesNotBreakPublishedCard() throws {
        let published = try publishEdition()
        let repository = repositories()
        let before = try repository.cards(in: published.edition.editionID).map(\.payload)

        try evictCanonical()
        XCTAssertEqual(try rowCount("origin_revision"), 0)

        let outcome = try repository.restore(context: published.context)
        guard case let .restored(_, records) = outcome else {
            return XCTFail("the card must survive eviction of its revision, got \(outcome)")
        }
        XCTAssertEqual(records.map(\.payload), before)
        XCTAssertEqual(records[0].payload.origin.originRevisionID.rawValue, published.rows[0].revisionID)
        XCTAssertEqual(try rowCount("published_card"), 2, "no cascade removed the card")
        XCTAssertEqual(try rowCount("feed_segment"), 1)
        try assertPublicationIntegrity()
    }

    /// `publicationFreezesExactRevisionAndAttribution` (ADR-001 named test; D4, D12).
    func testPublicationFreezesExactRevisionAndAttribution() throws {
        let source = try ensureSource("catalog:alpha", displayTitle: "Alpha")
        let provider = try ensureProvider(key: "pia")
        let row = try insertSupplyRow(
            objectKey: "item-0",
            sourceIDs: [source],
            providerID: provider,
            headline: "Headline",
            summary: "Excerpt",
            publishedAtClaim: TestInstant.epochMilliseconds,
            observedAt: TestInstant.epochMilliseconds
        )
        let context = try planContext()
        let edition = try openDraft(context: context, revisionTag: "revision-a")

        // One published asset, referenced by identity: digest plus recipe version, never a URL.
        let digest = String(repeating: "ab", count: 32)
        let media = PublishedMediaSet(
            primary: PublishedMediaRef(
                contentDigest: digest,
                recipeVersion: 1,
                pixelWidth: 600,
                pixelHeight: 200,
                mimeType: "image/png"
            ),
            alternates: [],
            placeholder: nil
        )
        let asset = try AssetVersionRecord(
            commit: PublishedAssetCommit(
                contentDigest: digest,
                byteCount: 73,
                recipeVersion: 1,
                mimeType: "image/png",
                pixelWidth: 600,
                pixelHeight: 200,
                relativePath: "ab/cd/\(digest)_r1"
            ),
            createdAt: TestInstant.epoch
        )
        let record = try card(
            edition: edition,
            record: row,
            absoluteOrdinal: 0,
            title: "Headline",
            primaryText: "Excerpt",
            sourceDisplayName: "Alpha",
            sourceID: source,
            publishedAt: TestInstant.epoch,
            revisionTag: "revision-a",
            providerID: provider,
            providerDisplayName: "pia",
            media: media,
            assetReferences: [
                PublishedAssetRefRecord(
                    slot: .primary,
                    role: .image,
                    renderSlot: .primary,
                    contentDigest: digest,
                    recipeVersion: 1,
                    aspectRatio: 3.0
                )
            ]
        )
        let receipt = try publish(
            repositories(),
            token: edition.token,
            cards: [record],
            activation: .activate(successorOf: nil),
            assets: [asset],
            pinned: [try OriginRevisionID(row.revisionID)]
        )

        let stored = try XCTUnwrap(try repositories().card(receipt.cardIDs[0]))
        XCTAssertEqual(stored.payload.cardID, receipt.cardIDs[0])
        XCTAssertEqual(stored.payload.origin.originRecordID.rawValue, row.recordID)
        XCTAssertEqual(stored.payload.origin.originRevisionID.rawValue, row.revisionID)
        XCTAssertEqual(stored.payload.origin.sourceID, try SourceID(UInt64(source)))
        XCTAssertEqual(stored.payload.origin.providerID, try ProviderID(UInt64(provider)))
        XCTAssertEqual(stored.payload.origin.sourceDisplayName, "Alpha")
        XCTAssertEqual(stored.payload.origin.providerDisplayName, "pia")
        XCTAssertEqual(stored.payload.publishedAtKind, PublishedTimestampKind.authored)
        XCTAssertEqual(stored.payload.publishedAt, TestInstant.epoch)
        XCTAssertEqual(stored.payload.segmentOrdinal, 0)
        XCTAssertEqual(stored.payload.absoluteOrdinal, 0)
        XCTAssertEqual(stored.payload.editorialRevision, try editorialRevision("revision-a"))

        // The exact media version is frozen on the card, and the row that carries it is the reference.
        XCTAssertEqual(stored.payload.media.primary?.contentDigest, digest)
        XCTAssertEqual(stored.payload.media.primary?.recipeVersion, 1)
        XCTAssertEqual(stored.payload.media.primary?.aspectRatio, 3.0)
        XCTAssertEqual(stored.payload.renderContract.kind, RenderKind.hero)
        XCTAssertEqual(stored.payload.renderContract.mediaSlot, MediaSlot.primary)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM published_asset_ref r JOIN asset_version a USING (asset_version_id) WHERE a.content_digest = '\(digest)'"),
            1
        )
        XCTAssertEqual(try string("SELECT mime_type FROM asset_version"), "image/png")
        XCTAssertEqual(try string("SELECT relative_path FROM asset_version"), "ab/cd/\(digest)_r1")
        let version = try XCTUnwrap(
            try repositories().assetVersion(contentDigest: digest, recipeVersion: 1)
        )
        XCTAssertEqual(version.durability, .committed, "the bytes were committed before the reference")
        XCTAssertEqual(version.storageClass, .published)
        XCTAssertEqual(version.relativePath, "ab/cd/\(digest)_r1")
        XCTAssertEqual(version.pixelWidth, 600)
        XCTAssertNil(
            try repositories().assetVersion(contentDigest: digest, recipeVersion: 7),
            "a recipe version is part of the identity"
        )

        // Reproducible from the row alone: the stored digest is what the payload recomputes to.
        XCTAssertEqual(stored.payloadDigest, stored.payload.frozenDigest())
        try assertPublicationIntegrity()
    }

    /// `publicationSchemaVersionIsIndependentOfSelectionAndEditorialRevision` (ADR-001 named test; D9).
    func testPublicationSchemaVersionIsIndependentOfSelectionAndEditorialRevision() throws {
        let first = try publishEdition(revisionTag: "revision-a", epoch: 1, cardCount: 1)
        let successor = try openDraft(
            context: first.context,
            revisionTag: "revision-b",
            epoch: 2,
            successorOf: first.edition.editionID
        )
        let row = try insertSupplyRow(
            objectKey: "item-9",
            sourceIDs: [first.source],
            headline: "Successor",
            observedAt: TestInstant.epochMilliseconds
        )
        let receipt = try publish(
            repositories(),
            token: successor.token,
            cards: [
                try card(
                    edition: successor,
                    record: row,
                    absoluteOrdinal: 0,
                    title: "Successor",
                    primaryText: "Excerpt",
                    sourceDisplayName: "Alpha",
                    sourceID: first.source,
                    publishedAt: nil,
                    revisionTag: "revision-b"
                )
            ],
            activation: .activate(successorOf: first.edition.editionID),
            pinned: [try OriginRevisionID(row.revisionID)]
        )
        XCTAssertTrue(receipt.activated)

        let repository = repositories()
        let firstEdition = try XCTUnwrap(try repository.edition(first.edition.editionID))
        let secondEdition = try XCTUnwrap(try repository.edition(successor.editionID))
        XCTAssertNotEqual(
            firstEdition.editorialRevision.digest,
            secondEdition.editorialRevision.digest,
            "the fixture really moved the editorial revision"
        )
        XCTAssertEqual(firstEdition.publicationSchemaVersion, PublicationSchema.currentVersion)
        XCTAssertEqual(secondEdition.publicationSchemaVersion, PublicationSchema.currentVersion)
        XCTAssertEqual(PublicationSchema.supportedVersions, [1])
        XCTAssertEqual(firstEdition.state, .superseded, "the previous edition is retained, not rewritten")
        XCTAssertEqual(
            try repository.card(first.receipt.cardIDs[0])?.payload.publicationSchemaVersion,
            PublicationSchema.currentVersion
        )
        XCTAssertEqual(
            try repository.card(first.receipt.cardIDs[0])?.payload.editorialRevision,
            firstEdition.editorialRevision,
            "the card keeps the revision its edition published under"
        )

        // R2 answers to the publication schema alone. A restore that supports only an unrelated version
        // is refused even though the editorial revision is this build's current one.
        XCTAssertEqual(
            try repository.restore(
                context: first.context,
                supportedSchemaVersions: [PublicationSchema.currentVersion + 7]
            ),
            .unsupportedPublicationSchemaVersion(PublicationSchema.currentVersion)
        )
        try assertPublicationIntegrity()
    }

    /// `unknownPublicationSchemaVersionRefusesRestore` (ADR-001 named test; D9, INV-13).
    func testUnknownPublicationSchemaVersionRefusesRestore() throws {
        let published = try publishEdition()
        let repository = repositories()

        try database.write { db in
            try db.execute(
                sql: "UPDATE feed_edition SET publication_schema_version = 99",
                arguments: []
            )
        }

        XCTAssertEqual(
            try repository.restore(context: published.context),
            .unsupportedPublicationSchemaVersion(99),
            "an unknown schema is a controlled refusal, not a permissive decode"
        )

        // A build that does support the version reads exactly the same rows, which is what makes the
        // refusal a version statement rather than a data statement.
        let outcome = try repository.restore(
            context: published.context,
            supportedSchemaVersions: [PublicationSchema.currentVersion, 99]
        )
        guard case let .restored(edition, records) = outcome else {
            return XCTFail("a supported version must restore, got \(outcome)")
        }
        XCTAssertEqual(edition.publicationSchemaVersion, 99)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.payload.title, "Headline 0")
    }

    /// R3: an intact-looking row whose payload no longer recomputes is reported, never served.
    func testTamperedPayloadIsReportedAsCorrupted() throws {
        let published = try publishEdition()
        let repository = repositories()

        try database.write { db in
            try db.execute(sql: "UPDATE published_card SET title = 'tampered' WHERE absolute_ordinal = 1")
        }

        guard case let .payloadCorrupted(cardID, reason) = try repository.restore(context: published.context) else {
            return XCTFail("a payload that no longer matches its digest must not be served")
        }
        XCTAssertEqual(cardID, published.receipt.cardIDs[1])
        XCTAssertTrue(reason.contains("recomputed"), "the refusal names what changed: \(reason)")
    }

    /// `publicationTablesForbidCascadeFromOrigin` (ADR-001 named test; D5, ADR-004).
    func testPublicationTablesForbidCascadeFromOrigin() throws {
        _ = try publishEdition()
        XCTAssertEqual(try rowCount("published_card"), 2)

        let foreignKeys = try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(published_card)")
        }
        // A composite key reports one row per column, so both rows must name the card's own segment.
        XCTAssertEqual(foreignKeys.count, 2, "the composite key of (edition_id, segment_id)")
        for row in foreignKeys {
            let referenced = row["table"] as String? ?? ""
            XCTAssertEqual(referenced, "feed_segment")
            XCTAssertEqual(row["on_delete"] as String?, "RESTRICT")
            XCTAssertNotEqual(referenced, "origin_record")
            XCTAssertNotEqual(referenced, "origin_revision")
        }

        // The only cascade edge in the aggregate is the card and its references: the purge unit.
        var cascades: [String] = []
        for table in Self.publicationTables {
            let rows = try database.read { db in
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
            }
            for row in rows where (row["on_delete"] as String?) == "CASCADE" {
                cascades.append("\(table)→\(row["table"] as String? ?? "")")
            }
        }
        XCTAssertEqual(cascades, ["published_asset_ref→published_card"])

        // A logical reference to canonical supply is fine to store, but a foreign key to it is not.
        let preparationKeys = try database.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(media_preparation)")
        }
        XCTAssertEqual(preparationKeys.map { $0["table"] as String? ?? "" }, ["asset_version"])
    }

    /// The verification SQL of the spec: integrity, foreign keys and the uniqueness the append path
    /// depends on, checked against the schema itself rather than against the repository's validation.
    func testSchemaForbidsDuplicateOrdinalsAndForeignSegments() throws {
        let published = try publishEdition()
        try assertPublicationIntegrity(label: "after two cards")

        let insert = """
            INSERT INTO published_card (
                edition_id, segment_id, absolute_ordinal, origin_record_id, origin_revision_id,
                published_at_kind, observation_at_ms, render_contract_version, render_kind,
                render_media_slot, payload_digest, publication_schema_version
            ) VALUES (?, ?, ?, 1, 1, 'none', 0, 1, 'textOnly', 'none', ?, 1)
            """
        let editionID = published.edition.editionID.rawValue
        let segmentID = published.receipt.segmentID.rawValue
        let digest = String(repeating: "cd", count: 32)

        assertUniqueFailure(insert, [editionID, segmentID, 1, digest])

        // A card cannot point at a segment of another edition: the composite foreign key needs both.
        let otherContext = try planContext("other-scope")
        let otherEdition = try openDraft(context: otherContext, revisionTag: "revision-b", epoch: 1)
        assertForeignKeyFailure(insert, [otherEdition.editionID.rawValue, segmentID, 0, digest])

        // The occurrence identity is global, so a card id cannot be reused by another edition either.
        assertForeignKeyFailure(insert, [otherEdition.editionID.rawValue, segmentID, 5, digest])

        // A segment ordinal is unique inside its edition.
        assertUniqueFailure(
            """
            INSERT INTO feed_segment (
                edition_id, segment_ordinal, absolute_ordinal_start, absolute_ordinal_end,
                policy_revision, seed, committed_at_ms
            ) VALUES (?, 0, 0, 0, ?, x'00', 0)
            """,
            [editionID, published.edition.editorialRevision.digest]
        )

        // A card with an ordinal that is not contiguous is refused by the schema's uniqueness, and a
        // negative one by the CHECK.
        assertCheckFailure(insert, [editionID, segmentID, -1, digest])
    }

    // MARK: - Crash points

    /// A commit that dies between the segment and the cards leaves nothing: the transaction is atomic,
    /// and the reopened database shows the edition exactly as the composition found it.
    func testCommitInterruptedAfterSegmentInsertLeavesNothingBehind() throws {
        let source = try ensureSource("catalog:alpha", displayTitle: "Alpha")
        let row = try insertSupplyRow(
            objectKey: "item-0",
            sourceIDs: [source],
            headline: "Headline",
            observedAt: TestInstant.epochMilliseconds
        )
        let context = try planContext()
        let edition = try openDraft(context: context, revisionTag: "revision-a")
        let before = try publicationDump()

        let interrupted = PublicationRepository(
            database: database,
            faults: PublicationRepository.Faults(point: .afterSegmentInsert)
        )
        XCTAssertThrowsError(
            try publish(
                interrupted,
                token: edition.token,
                cards: [
                    try card(
                        edition: edition,
                        record: row,
                        absoluteOrdinal: 0,
                        title: "Headline",
                        primaryText: "Excerpt",
                        sourceDisplayName: "Alpha",
                        sourceID: source,
                        publishedAt: nil,
                        revisionTag: "revision-a"
                    )
                ],
                activation: .activate(successorOf: nil),
                pinned: [try OriginRevisionID(row.revisionID)]
            )
        ) { error in
            XCTAssertTrue(
                "\(error)".contains(PublicationRepository.interruptionProbe),
                "the injected crash must surface, got \(error)"
            )
        }

        XCTAssertEqual(try publicationDump(), before, "a rolled-back commit changed nothing")

        let reopened = try reopenDatabase()
        try assertPublicationIntegrity(in: reopened, label: "after the crash")
        XCTAssertEqual(try rowCount("feed_segment", in: reopened), 0)
        XCTAssertEqual(try rowCount("published_card", in: reopened), 0)
        XCTAssertEqual(try rowCount("feed_edition", in: reopened), 1)
        XCTAssertEqual(try string("SELECT state FROM feed_edition", in: reopened), "draft")
        XCTAssertEqual(try scalar("SELECT version FROM feed_edition", in: reopened), 0)
        XCTAssertEqual(try scalar("SELECT tail_segment_ordinal FROM feed_edition", in: reopened), -1)
        XCTAssertEqual(try scalar("SELECT tail_absolute_ordinal FROM feed_edition", in: reopened), -1)
        XCTAssertEqual(try repositories(in: reopened).activeEditions().count, 0)

        // The crash consumed nothing: the same token still commits, and the retry produces the whole
        // segment — never a half-written one.
        let receipt = try publish(
            repositories(in: reopened),
            token: edition.token,
            cards: [
                try card(
                    edition: edition,
                    record: row,
                    absoluteOrdinal: 0,
                    title: "Headline",
                    primaryText: "Excerpt",
                    sourceDisplayName: "Alpha",
                    sourceID: source,
                    publishedAt: nil,
                    revisionTag: "revision-a"
                )
            ],
            activation: .activate(successorOf: nil),
            pinned: [try OriginRevisionID(row.revisionID)]
        )
        XCTAssertTrue(receipt.activated)
        XCTAssertEqual(try rowCount("feed_segment", in: reopened), 1)
        XCTAssertEqual(try rowCount("published_card", in: reopened), 1)
        XCTAssertEqual(try repositories(in: reopened).activeEditions().count, 1)
        try assertPublicationIntegrity(in: reopened, label: "after the retry")
    }

    /// `failedRefreshKeepsPreviousEditionVisible`, storage half: a successor whose activation never
    /// committed leaves the previous edition active and the single visible one (ADR-001 D7, INV-14).
    func testInterruptedActivationKeepsThePreviousEditionVisible() throws {
        let published = try publishEdition(cardCount: 2)
        let activeBefore = try repositories().activeEdition(for: published.context)

        let successor = try openDraft(
            context: published.context,
            revisionTag: "revision-a",
            epoch: 2,
            successorOf: published.edition.editionID
        )
        let row = try insertSupplyRow(
            objectKey: "item-9",
            sourceIDs: [published.source],
            headline: "Successor",
            observedAt: TestInstant.epochMilliseconds
        )
        let interrupted = PublicationRepository(
            database: database,
            faults: PublicationRepository.Faults(point: .beforeActivation)
        )
        XCTAssertThrowsError(
            try publish(
                interrupted,
                token: successor.token,
                cards: [
                    try card(
                        edition: successor,
                        record: row,
                        absoluteOrdinal: 0,
                        title: "Successor",
                        primaryText: "Excerpt",
                        sourceDisplayName: "Alpha",
                        sourceID: published.source,
                        publishedAt: nil,
                        revisionTag: "revision-a"
                    )
                ],
                activation: .activate(successorOf: published.edition.editionID),
                pinned: [try OriginRevisionID(row.revisionID)]
            )
        )

        let reopened = try reopenDatabase()
        let repository = repositories(in: reopened)
        XCTAssertEqual(try repository.activeEditions().count, 1)
        XCTAssertEqual(try repository.activeEdition(for: published.context), activeBefore)
        XCTAssertEqual(try rowCount("feed_segment", in: reopened), 1, "the failed successor left no segment")
        XCTAssertEqual(try string("SELECT state FROM feed_edition WHERE edition_id = 2", in: reopened), "draft")
        guard case let .restored(edition, records) = try repository.restore(context: published.context) else {
            return XCTFail("the previous edition must stay restorable")
        }
        XCTAssertEqual(edition.editionID, published.edition.editionID)
        XCTAssertEqual(records.count, 2)
        try assertPublicationIntegrity(in: reopened, label: "after the failed refresh")
    }

    // MARK: - The tail compare-and-swap

    /// The CAS itself, at the storage boundary: a token whose version, tail, epoch or revision moved
    /// commits nothing, and the refusal names which one moved.
    func testStaleTokenCommitsNothing() throws {
        let published = try publishEdition(cardCount: 1)
        let repository = repositories()
        /// The token a composition captured before the first segment existed: it names tail `-1`.
        let stale = published.edition.token
        let current = try repository.token(for: published.edition.editionID)

        let row = try insertSupplyRow(
            objectKey: "item-9",
            sourceIDs: [published.source],
            headline: "Second segment",
            observedAt: TestInstant.epochMilliseconds
        )
        /// The composition the winner commits: it was captured against the tail the winner holds.
        let winner = try card(
            edition: published.edition,
            record: row,
            absoluteOrdinal: current.tail.nextAbsoluteOrdinal,
            segmentOrdinal: current.tail.nextSegmentOrdinal,
            title: "Second segment",
            primaryText: "Excerpt",
            sourceDisplayName: "Alpha",
            sourceID: published.source,
            publishedAt: nil,
            revisionTag: "revision-a"
        )
        /// The composition a second writer built against the older tail. It is discarded, never fitted
        /// into the moved tail: the loser's card starts at the ordinal its own token named.
        let loser = try card(
            edition: published.edition,
            record: row,
            absoluteOrdinal: stale.tail.nextAbsoluteOrdinal,
            segmentOrdinal: stale.tail.nextSegmentOrdinal,
            title: "Second segment",
            primaryText: "Excerpt",
            sourceDisplayName: "Alpha",
            sourceID: published.source,
            publishedAt: nil,
            revisionTag: "revision-a"
        )
        let receipt = try publish(
            repository,
            token: current,
            cards: [winner],
            pinned: [try OriginRevisionID(row.revisionID)]
        )
        XCTAssertEqual(receipt.segmentOrdinal, 1)

        let before = try publicationDump()
        XCTAssertThrowsError(
            try publish(
                repository,
                token: stale,
                cards: [loser],
                pinned: [try OriginRevisionID(row.revisionID)]
            )
        ) { error in
            guard case let PublicationFailure.tailMismatch(expected, actual) = error else {
                return XCTFail("expected a tail mismatch, got \(error)")
            }
            XCTAssertEqual(expected, stale.tail)
            XCTAssertEqual(actual, receipt.tail, "the refusal reports the tail the winner left")
        }
        XCTAssertEqual(try publicationDump(), before, "the loser committed nothing")

        // A token from another epoch, an edition whose revision moved and a superseded edition are each
        // refused by name, and none of them writes.
        let wrongEpoch = PublicationToken(
            editionID: stale.editionID,
            epoch: stale.epoch + 1,
            editorialRevision: stale.editorialRevision,
            tail: stale.tail
        )
        XCTAssertThrowsError(
            try publish(repository, token: wrongEpoch, cards: [loser])
        ) { error in
            XCTAssertEqual(
                error as? PublicationFailure,
                .staleEpoch(expected: stale.epoch + 1, actual: stale.epoch)
            )
        }

        let otherRevision = PublicationToken(
            editionID: stale.editionID,
            epoch: stale.epoch,
            editorialRevision: try editorialRevision("revision-b"),
            tail: stale.tail
        )
        XCTAssertThrowsError(
            try publish(repository, token: otherRevision, cards: [loser])
        ) { error in
            guard case .editorialRevisionChanged = error as? PublicationFailure else {
                return XCTFail("expected a revision change, got \(error)")
            }
        }
        XCTAssertEqual(try publicationDump(), before)
        try assertPublicationIntegrity()
    }

    /// A pinned revision that lost hard eligibility between composition and commit is refused, and the
    /// refusal rolls the segment back: no card is published for content the plan may no longer use.
    func testRevokedEligibilityAtCommitCommitsNothing() throws {
        let published = try publishEdition(cardCount: 1)
        let repository = repositories()
        let row = try insertSupplyRow(
            objectKey: "item-9",
            sourceIDs: [published.source],
            headline: "Second segment",
            observedAt: TestInstant.epochMilliseconds
        )
        // The record is revoked after the composition priced it: eligibility is decided at commit.
        try database.write { db in
            try db.execute(
                sql: "UPDATE origin_record SET availability = 'revoked' WHERE id = ?",
                arguments: [row.recordID]
            )
        }

        let before = try publicationDump()
        let revoked = PublicationFailure.eligibilityRevoked(
            originRevisionID: try OriginRevisionID(row.revisionID)
        )
        XCTAssertThrowsError(
            try publish(
                repository,
                token: try repository.token(for: published.edition.editionID),
                cards: [
                    try card(
                        edition: published.edition,
                        record: row,
                        absoluteOrdinal: 1,
                        segmentOrdinal: 1,
                        title: "Second segment",
                        primaryText: "Excerpt",
                        sourceDisplayName: "Alpha",
                        sourceID: published.source,
                        publishedAt: nil,
                        revisionTag: "revision-a"
                    )
                ],
                pinned: [try OriginRevisionID(row.revisionID)]
            )
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, revoked)
        }
        XCTAssertEqual(try publicationDump(), before)
    }

    /// A successor is only activated once its first segment is durable, in the same transaction.
    func testActivationRequiresASegmentAndSwapsAtomically() throws {
        let published = try publishEdition(cardCount: 1)

        // An empty segment is not expressible: the repository refuses before touching the database.
        let successor = try openDraft(
            context: published.context,
            revisionTag: "revision-a",
            epoch: 2,
            successorOf: published.edition.editionID
        )
        XCTAssertThrowsError(
            try publish(repositories(), token: successor.token, cards: [], activation: .activate(successorOf: published.edition.editionID))
        ) { error in
            XCTAssertEqual(error as? PublicationFailure, .emptySequence(successor.editionID))
        }
        XCTAssertEqual(try string("SELECT state FROM feed_edition WHERE edition_id = 2"), "draft")
        XCTAssertEqual(try repositories().activeEditions().count, 1)

        // The successor's first segment commits and the pointer moves in the same transaction.
        let row = try insertSupplyRow(
            objectKey: "item-9",
            sourceIDs: [published.source],
            headline: "Successor",
            observedAt: TestInstant.epochMilliseconds
        )
        let receipt = try publish(
            repositories(),
            token: successor.token,
            cards: [
                try card(
                    edition: successor,
                    record: row,
                    absoluteOrdinal: 0,
                    title: "Successor",
                    primaryText: "Excerpt",
                    sourceDisplayName: "Alpha",
                    sourceID: published.source,
                    publishedAt: nil,
                    revisionTag: "revision-a"
                )
            ],
            activation: .activate(successorOf: published.edition.editionID),
            pinned: [try OriginRevisionID(row.revisionID)]
        )
        XCTAssertTrue(receipt.activated)
        let segments = try repositories().segments(in: successor.editionID)
        XCTAssertEqual(segments.map(\.segmentOrdinal), [0], "the swap happened with the first segment")
        XCTAssertEqual(segments.first?.absoluteOrdinalStart, 0)
        XCTAssertEqual(segments.first?.absoluteOrdinalEnd, 0)
        XCTAssertEqual(segments.first?.policyRevision, successor.editorialRevision.digest)
        XCTAssertEqual(try string("SELECT state FROM feed_edition WHERE edition_id = 2"), "active")
        XCTAssertEqual(try string("SELECT state FROM feed_edition WHERE edition_id = 1"), "superseded")
        XCTAssertEqual(try repositories().activeEditions().count, 1)
        XCTAssertEqual(
            try repositories().activeEdition(for: published.context)?.editionID,
            successor.editionID
        )
        // The previous edition keeps its own history: it is superseded, never rewritten.
        XCTAssertEqual(try repositories().cards(in: published.edition.editionID).count, 1)
        try assertPublicationIntegrity()
    }
}
