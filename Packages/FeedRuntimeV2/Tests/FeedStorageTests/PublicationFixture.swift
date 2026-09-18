import Foundation
import GRDB
import XCTest
import FeedDomain
@testable import FeedStorage

/// Fixtures for the PR-06 publication tests.
///
/// Rows are written through the real repository, so every assertion is about behaviour on a real
/// on-disk database (WAL, foreign keys on) rather than about a mock: the tail compare-and-swap, the
/// composite foreign key and the frozen payload are all decided by SQLite. The only direct SQL is the
/// canonical fixture (`SelectionFixture`), the passive edits a test performs on it, and the eviction that
/// stands in for authorized retention.
extension TestInstant {
    /// The fixture's fixed instant in the runtime's persisted unit.
    static var epochMilliseconds: Int64 { PublishedCardPayload.milliseconds(epoch) }
}

extension RuntimeV2TestCase {
    // MARK: - Revision and context

    /// A deterministic, well-formed editorial revision digest: 64 lowercase hex characters.
    func revisionDigest(_ tag: String) -> String {
        let hex = tag.utf8.map { String(format: "%02x", $0) }.joined()
        return String((hex + String(repeating: "0", count: 64)).prefix(64))
    }

    func editorialRevision(_ tag: String) throws -> EditorialRevision {
        try EditorialRevision(
            schemeVersion: EditorialRevision.currentSchemeVersion,
            digest: revisionDigest(tag)
        )
    }

    func planContext(_ scopeKey: String = "main") throws -> ContextKey {
        try ContextKey(surface: .main, scopeKey: scopeKey, planIdentity: "MainFeedPlan")
    }

    // MARK: - Editions

    func repositories(in database: RuntimeDatabase? = nil) -> PublicationRepository {
        PublicationRepository(database: database ?? self.database)
    }

    func openDraft(
        context: ContextKey,
        revisionTag: String,
        epoch: Int64 = 1,
        seed: String = "edition-seed",
        successorOf: EditionID? = nil,
        schemaVersion: Int = PublicationSchema.currentVersion,
        in database: RuntimeDatabase? = nil
    ) throws -> EditionSnapshot {
        try repositories(in: database).beginEdition(
            context: context,
            editorialRevision: try editorialRevision(revisionTag),
            epoch: epoch,
            seed: Data(seed.utf8),
            publicationSchemaVersion: schemaVersion,
            successorOf: successorOf,
            at: TestInstant.epoch
        )
    }

    // MARK: - Cards

    /// A frozen card for a canonical revision this fixture inserted.
    func frozenCard(
        edition: EditionSnapshot,
        segmentOrdinal: Int,
        absoluteOrdinal: Int,
        record: SupplyRow,
        title: String? = "Headline",
        primaryText: String? = "An excerpt",
        sourceDisplayName: String? = "Source",
        providerDisplayName: String? = nil,
        sourceID: Int64? = nil,
        providerID: Int64? = nil,
        publishedAt: Date? = nil,
        publishedAtKind: PublishedTimestampKind = .none,
        observationAt: Date = TestInstant.epoch,
        media: PublishedMediaSet = .none,
        primaryAction: FeedPrimaryAction? = nil,
        interactionSummary: String? = nil,
        revisionTag: String = "revision-a"
    ) throws -> PublishedCardPayload.Frozen {
        let source: SourceID? = sourceID.flatMap { try? SourceID(UInt64($0)) }
        let provider: ProviderID? = providerID.flatMap { try? ProviderID(UInt64($0)) }
        return PublishedCardPayload.Frozen(
            editionID: edition.editionID,
            segmentOrdinal: segmentOrdinal,
            absoluteOrdinal: absoluteOrdinal,
            origin: PublishedOrigin(
                originRecordID: try OriginRecordID(record.recordID),
                originRevisionID: try OriginRevisionID(record.revisionID),
                sourceID: source,
                providerID: provider,
                sourceDisplayName: sourceDisplayName,
                providerDisplayName: providerDisplayName
            ),
            title: title,
            primaryText: primaryText,
            publishedAt: publishedAt,
            publishedAtKind: publishedAtKind,
            observationAt: observationAt,
            media: media,
            primaryAction: primaryAction,
            interactionSummary: interactionSummary,
            renderContract: RenderContract.resolved(media: media),
            editorialRevision: try editorialRevision(revisionTag),
            publicationSchemaVersion: edition.publicationSchemaVersion
        )
    }

    @discardableResult
    func publish(
        _ repository: PublicationRepository,
        token: PublicationToken,
        cards: [CardInsertRecord],
        activation: SegmentActivation = .append,
        segmentOrdinal: Int? = nil,
        absoluteOrdinalStart: Int? = nil,
        assets: [AssetVersionRecord] = [],
        preparations: [MediaPreparationRecord] = [],
        pinned: [OriginRevisionID] = [],
        attempt: Int = 1
    ) throws -> SegmentCommitReceipt {
        try repository.commit(
            SegmentCommitRequest(
                token: token,
                segmentOrdinal: segmentOrdinal ?? token.tail.nextSegmentOrdinal,
                absoluteOrdinalStart: absoluteOrdinalStart ?? token.tail.nextAbsoluteOrdinal,
                segmentSeed: Data("segment-seed".utf8),
                policyRevision: token.editorialRevision.digest,
                committedAt: TestInstant.seconds(1),
                activation: activation,
                cards: cards,
                assets: assets,
                mediaPreparations: preparations,
                pinnedRevisions: pinned
            ),
            attempt: attempt
        )
    }

    // MARK: - Canonical edits and eviction

    /// Everything a passive catalog, binding or endpoint change does to canonical state, without
    /// touching a single published row.
    func applyPassiveCatalogChange(record: SupplyRow? = nil, in database: RuntimeDatabase? = nil) throws {
        try (database ?? self.database).write { db in
            try db.execute(sql: "UPDATE supply_generation SET value = value + 1 WHERE id = 1")
            if let record {
                try db.execute(sql: """
                    INSERT INTO origin_revision (
                        origin_record_id, external_version_key, payload_digest, headline, observed_at,
                        created_at, identity_confidence
                    ) VALUES (?, NULL, ?, 'A newer headline', ?, 0, 'high')
                    """, arguments: [
                        record.recordID,
                        Data("newer-digest".utf8),
                        PublishedCardPayload.milliseconds(TestInstant.seconds(9)),
                    ])
                let newer = db.lastInsertedRowID
                try db.execute(
                    sql: "UPDATE origin_record SET current_revision_id = ?, availability = 'updated' WHERE id = ?",
                    arguments: [newer, record.recordID]
                )
                try db.execute(
                    sql: "UPDATE selection_supply SET origin_revision_id = ? WHERE origin_record_id = ?",
                    arguments: [newer, record.recordID]
                )
            }
            try db.execute(sql: "UPDATE source SET display_title = 'Renamed source'")
            try db.execute(sql: "UPDATE provider SET display_name = 'Renamed provider'")
            try db.execute(sql: "UPDATE source_binding_runtime SET generation = generation + 1")
            try db.execute(sql: "UPDATE acquisition_target SET binding_revision = binding_revision + 1")
        }
    }

    /// Authorized removal of canonical supply: the eviction path that must leave published cards intact
    /// (ADR-001 INV-6, ADR-004 invariant 3).
    func evictCanonical(in database: RuntimeDatabase? = nil) throws {
        try (database ?? self.database).write { db in
            // `origin_record` and `external_identity` reference each other, so both pointers are
            // cleared before either row goes: a real purge has to do exactly this, and doing it in any
            // other order is what SQLite's foreign keys refuse.
            try db.execute(sql: "UPDATE origin_record SET current_revision_id = NULL")
            try db.execute(sql: "UPDATE external_identity SET origin_record_id = NULL")
            try db.execute(sql: "DELETE FROM selection_supply")
            try db.execute(sql: "DELETE FROM origin_search")
            try db.execute(sql: "DELETE FROM media_candidate")
            try db.execute(sql: "DELETE FROM provider_attribution")
            try db.execute(sql: "DELETE FROM content_relation")
            try db.execute(sql: "DELETE FROM source_membership")
            try db.execute(sql: "DELETE FROM legacy_item_map")
            try db.execute(sql: "DELETE FROM origin_revision")
            try db.execute(sql: "DELETE FROM origin_record")
            try db.execute(sql: "DELETE FROM external_identity")
        }
    }

    // MARK: - Reads used as evidence

    /// The publication tables a refusal or a passive change must leave byte-identical.
    static let publicationTables = [
        "feed_edition",
        "feed_segment",
        "published_card",
        "published_asset_ref",
        "asset_version",
        "media_preparation",
    ]

    func publicationDump(in database: RuntimeDatabase? = nil) throws -> [String] {
        try dump(Self.publicationTables, in: database)
    }

    func cardRows(in database: RuntimeDatabase? = nil) throws -> [Row] {
        try (database ?? self.database).read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM published_card ORDER BY absolute_ordinal, publication_card_id")
        }
    }

    /// Verification SQL: `PRAGMA integrity_check`, `PRAGMA foreign_key_check` and the two uniqueness
    /// rules the append path depends on.
    func assertPublicationIntegrity(in database: RuntimeDatabase? = nil, label: String = "") throws {
        let report = try PublicationRepository(database: database ?? self.database).integrityReport()
        XCTAssertTrue(report.isHealthy, "\(label): \(report.summary)")
    }

    /// Closes this test's pool and opens the database from disk again, as the next launch of the
    /// process would. The returned handle is the one every assertion about durable state must use.
    func reopenDatabase() throws -> RuntimeDatabase {
        try database.pool.close()
        return try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
    }
}
