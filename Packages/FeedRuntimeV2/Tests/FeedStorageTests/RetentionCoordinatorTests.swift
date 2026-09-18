import Foundation
import GRDB
import os
import XCTest
import FeedDomain
@testable import FeedStorage

/// The retention coordinator (ADR-004 D8) on a real on-disk database.
///
/// Everything here runs against a migrated database in `$TMPDIR`, because the questions are SQL
/// questions: which rows a root still pins, what a purge releases, and what the run left behind. A
/// clock a test moves and a media port a test counts are the only doubles; the media collectors
/// themselves are the ones PR-08 shipped, reached through `RetentionMediaCollecting`.
final class RetentionCoordinatorTests: RuntimeV2TestCase {
    /// A clock a test moves, including backwards. `OSAllocatedUnfairLock` rather than an unchecked
    /// conformance: the mutable state is genuinely shared, so it is genuinely locked.
    final class SteppingClock: EditorialClock {
        private let state: OSAllocatedUnfairLock<Date>

        init(_ start: Date) {
            self.state = OSAllocatedUnfairLock(initialState: start)
        }

        var now: Date { state.withLock { $0 } }

        func move(to date: Date) {
            state.withLock { $0 = date }
        }
    }

    /// Counts what a run asked the media side for, keyed by the identity it named.
    actor CountingMediaPort: RetentionMediaCollecting {
        private(set) var unpinnedCalls = 0
        private(set) var orphanCalls = 0
        private(set) var requestedKeys: [MediaAssetKey] = []
        private let freedBytes: Int

        init(freedBytes: Int = 0) {
            self.freedBytes = freedBytes
        }

        func collectUnpinnedMedia() async -> MediaCollectionOutcome {
            unpinnedCalls += 1
            return MediaCollectionOutcome(collected: 1, protectedByPin: 0, freedBytes: freedBytes)
        }

        func collectAssetBytes(_ keys: [MediaAssetKey]) async -> MediaCollectionOutcome {
            requestedKeys.append(contentsOf: keys)
            return MediaCollectionOutcome(collected: keys.count, protectedByPin: 0, freedBytes: freedBytes)
        }

        func collectOrphanAssetFiles() async -> MediaCollectionOutcome {
            orphanCalls += 1
            return MediaCollectionOutcome(collected: 0, protectedByPin: 0, freedBytes: 0, orphansCollected: 0)
        }
    }

    /// A root provider that has lost the publication pin: the sweep no longer sees it.
    struct LossyRootProvider: RetentionRootProviding {
        let wrapped: any RetentionRootProviding

        func roots(in database: Database) throws -> RetentionRoots {
            let roots = try wrapped.roots(in: database)
            return RetentionRoots(
                protectedEditions: roots.protectedEditions,
                protectedRevisions: roots.protectedRevisions,
                protectedAssetVersions: []
            )
        }
    }

    /// A provider that fails, so the abort path of the run is observable rather than argued about.
    struct FailingRootProvider: RetentionRootProviding {
        struct Unavailable: Error {}

        func roots(in database: Database) throws -> RetentionRoots {
            throw Unavailable()
        }
    }

    /// The authoritative saved subjects, as `user.sqlite` would answer them. The package reads them
    /// through the port, never from the database itself, because bookmark rows belong to the app's
    /// store (ADR-004 D1).
    struct SavedSubjects: BookmarkSubjectProviding {
        let subjects: Set<String>

        func savedBookmarkSubjects() throws -> Set<String> { subjects }
    }

    /// A provider that answers only from inside a transaction.
    ///
    /// What it defends is the ordering the roots need: the set has to come from the same snapshot the
    /// deletion runs in, or a pin committed in between is invisible to a sweep that already decided.
    /// A run that read its roots in a separate snapshot fails here instead of quietly collecting what
    /// a newer pin protects.
    struct TransactionScopedRootProvider: RetentionRootProviding {
        struct OutsideTransaction: Error {}

        func roots(in database: Database) throws -> RetentionRoots {
            guard database.isInsideTransaction else { throw OutsideTransaction() }
            return try SqlRetentionRootProvider().roots(in: database)
        }
    }

    // MARK: - Fixtures

    private func declare(_ policy: RetentionPolicy, in database: RuntimeDatabase? = nil) throws {
        try RetentionPolicyStore(database: database ?? self.database).declare(policy)
    }

    private func coordinator(
        media: (any RetentionMediaCollecting)? = nil,
        roots: any RetentionRootProviding = SqlRetentionRootProvider(),
        clock: any EditorialClock,
        options: RetentionCoordinator.Options = RetentionCoordinator.Options(),
        in database: RuntimeDatabase? = nil
    ) -> RetentionCoordinator {
        RetentionCoordinator(
            database: database ?? self.database,
            media: media,
            roots: roots,
            clock: clock,
            options: options
        )
    }

    private func assetVersion(
        digest: String,
        byteCount: Int,
        recipeVersion: Int = 1,
        storageClass: PublishedAssetStorageClass = .published
    ) throws -> AssetVersionRecord {
        try AssetVersionRecord(
            commit: PublishedAssetCommit(
                contentDigest: digest,
                byteCount: byteCount,
                recipeVersion: recipeVersion,
                mimeType: "image/png",
                pixelWidth: 30,
                pixelHeight: 10,
                relativePath: "ab/cd/\(digest)_r\(recipeVersion)"
            ),
            storageClass: storageClass,
            durability: .committed,
            createdAt: TestInstant.epoch
        )
    }

    private func oneCard(
        edition: EditionSnapshot,
        ordinal: Int,
        row: SupplyRow,
        revisionTag: String,
        title: String = "Headline",
        media: PublishedMediaSet = .none,
        assetReferences: [PublishedAssetRefRecord] = []
    ) throws -> CardInsertRecord {
        CardInsertRecord(
            frozen: try frozenCard(
                edition: edition,
                segmentOrdinal: 0,
                absoluteOrdinal: ordinal,
                record: row,
                title: title,
                media: media,
                revisionTag: revisionTag
            ),
            assetReferences: assetReferences
        )
    }

    /// Activates one edition of `context` at an explicit commit instant, so the superseded order is a
    /// fact of the fixture rather than of the wall clock.
    @discardableResult
    private func activateEdition(
        context: ContextKey,
        revisionTag: String,
        epoch: Int64,
        successorOf: EditionID?,
        committedAt: Date,
        assets: [AssetVersionRecord] = [],
        pinned: [OriginRevisionID] = [],
        in database: RuntimeDatabase? = nil,
        makeCards: (EditionSnapshot) throws -> [CardInsertRecord]
    ) throws -> (edition: EditionSnapshot, receipt: SegmentCommitReceipt) {
        let draft = try openDraft(
            context: context,
            revisionTag: revisionTag,
            epoch: epoch,
            successorOf: successorOf,
            in: database
        )
        let receipt = try repositories(in: database).commit(
            SegmentCommitRequest(
                token: draft.token,
                segmentOrdinal: 0,
                absoluteOrdinalStart: 0,
                segmentSeed: Data("segment-seed".utf8),
                policyRevision: draft.editorialRevision.digest,
                committedAt: committedAt,
                activation: .activate(successorOf: successorOf),
                cards: try makeCards(draft),
                assets: assets,
                mediaPreparations: [],
                pinnedRevisions: pinned
            )
        )
        return (draft, receipt)
    }

    private func savedBookmark(subjectID: String, recordID: Int64, in database: RuntimeDatabase? = nil) throws {
        let target: RuntimeDatabase = database ?? self.database
        try UserStateProjectionStore(database: target).apply(
            kind: .bookmark,
            subjectID: subjectID,
            wanted: true,
            operationID: "op-\(subjectID)",
            at: TestInstant.epoch
        )
        try target.write { db in
            try db.execute(sql: """
                INSERT INTO legacy_item_map (
                    legacy_item_id, legacy_source_url, origin_record_id, confidence, mapped_at
                ) VALUES (?, 'https://example.test/feed', ?, 'high', 0)
                """, arguments: [subjectID, recordID])
        }
    }

    private func insertEvidence(
        batchID: String,
        bytes: Int,
        createdAtMilliseconds: Int64,
        in database: RuntimeDatabase? = nil
    ) throws {
        try (database ?? self.database).write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO acquisition_target (
                    id, connector_kind, generation, binding_revision, lease_epoch, state
                ) VALUES ('target-evidence', 'rss', 1, 1, 0, 'active')
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO admission_batch (
                    batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                    checkpoint_expected, checkpoint_written, observation_count, result, receipt_blob,
                    committed_at
                ) VALUES (?, 'target-evidence', 1, 1, 0, ?, 0, 0, 0, 'admitted', x'00', 0)
                """, arguments: [batchID, String(repeating: "0", count: 64)])
            try db.execute(sql: """
                INSERT INTO connector_evidence (batch_id, kind, digest, bytes, created_at)
                VALUES (?, 'responseBody', ?, ?, ?)
                """, arguments: [
                batchID,
                "digest-\(batchID)",
                Data(repeating: 0x41, count: bytes),
                createdAtMilliseconds,
            ])
        }
    }

    /// An extra, non-current revision of a record, so the canonical class has something to collect.
    @discardableResult
    private func insertSupersededRevision(
        of recordID: Int64,
        createdAtMilliseconds: Int64,
        in database: RuntimeDatabase? = nil
    ) throws -> Int64 {
        try (database ?? self.database).write { db in
            try db.execute(sql: """
                INSERT INTO origin_revision (
                    origin_record_id, external_version_key, payload_digest, headline, body_text,
                    observed_at, created_at, identity_confidence
                ) VALUES (?, NULL, ?, 'An older headline', 'the older body', 0, ?, 'high')
                """, arguments: [recordID, Data("older-digest".utf8), createdAtMilliseconds])
            return db.lastInsertedRowID
        }
    }

    private func insertHistoryProjection(cardID: Int64, editionID: Int64, in database: RuntimeDatabase? = nil) throws {
        try (database ?? self.database).write { db in
            try db.execute(sql: """
                INSERT INTO history_projection (
                    scope, scope_ref, card_id, edition_id, last_seen_at_ms, visit_count, policy_version
                ) VALUES ('main', '', ?, ?, 0, 3, 'policy-1')
                """, arguments: [cardID, editionID])
        }
    }

    private func durabilityState(ofAssetID id: Int64, in database: RuntimeDatabase? = nil) throws -> String? {
        try string("SELECT durability_state FROM asset_version WHERE asset_version_id = \(id)", in: database)
    }

    private func assetID(digest: String, in database: RuntimeDatabase? = nil) throws -> Int64 {
        try scalar("SELECT asset_version_id FROM asset_version WHERE content_digest = '\(digest)'", in: database)
    }

    private func editionState(_ id: EditionID, in database: RuntimeDatabase? = nil) throws -> String? {
        try string("SELECT state FROM feed_edition WHERE edition_id = \(id.rawValue)", in: database)
    }

    // MARK: - The policy surface

    func testDeclaringAPolicyForDurableUserStateIsRefused() throws {
        let store = RetentionPolicyStore(database: database)

        XCTAssertThrowsError(
            try store.declare(RetentionPolicy(retentionClass: .durableUserState, maxAgeSeconds: 86_400))
        ) { error in
            XCTAssertEqual(error as? RetentionPolicyError, .classIsNeverCollected(.durableUserState))
        }
        XCTAssertNil(
            try store.policy(.durableUserState),
            "the refused class leaves no row behind for a later read to find"
        )
        XCTAssertEqual(
            try store.declaredClasses(),
            [],
            "a refused declaration must not be stored as an unlimited policy"
        )
        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(sql: "INSERT INTO retention_policy (class) VALUES ('publication')")
            }
        )
    }

    func testADeclaredPolicyMustCarryALimitAndAnAbsentRowIsNotUnlimited() throws {
        let store = RetentionPolicyStore(database: database)

        XCTAssertThrowsError(
            try store.declare(RetentionPolicy(retentionClass: .connectorEvidence))
        ) { error in
            XCTAssertEqual(error as? RetentionPolicyError, .emptyPolicy(.connectorEvidence))
        }
        XCTAssertNil(try store.policy(.connectorEvidence), "an absent row is not an unlimited policy")

        try store.declare(RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 3_600))
        XCTAssertEqual(
            try store.policy(.connectorEvidence),
            RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 3_600)
        )
        try store.declare(RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 7_200))
        XCTAssertEqual(try store.policy(.connectorEvidence)?.maxAgeSeconds, 7_200, "a re-declaration replaces")
        XCTAssertTrue(try store.remove(.connectorEvidence))
        XCTAssertNil(try store.policy(.connectorEvidence))
        XCTAssertFalse(try store.remove(.connectorEvidence), "removing an absent declaration changes nothing")
    }

    // MARK: - The run's account

    func testEveryClassIsAccountedForAndUndeclaredClassesAreSkipped() async throws {
        try declare(RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 86_400))

        let report = try await coordinator(clock: SteppingClock(TestInstant.seconds(86_400))).run()

        XCTAssertEqual(
            report.classes.map(\.retentionClass),
            RetentionClass.collectionOrder,
            "every class is accounted for, in the order the run applies"
        )
        XCTAssertEqual(
            report.result(for: .canonicalSupply)?.skipped,
            "no declared retention policy for this class"
        )
        XCTAssertEqual(
            report.result(for: .durableUserState)?.skipped,
            "ADR-004 D8 marks this class never collected: the user deletes it, never a quota"
        )
        XCTAssertEqual(
            report.result(for: .connectorEvidence)?.collected,
            0,
            "a declared class with nothing past its limit collects nothing without being skipped"
        )
        XCTAssertNil(report.result(for: .connectorEvidence)?.skipped)
    }

    func testMediaClassesAreSkippedWithoutAPortAndReachedWithOne() async throws {
        try declare(RetentionPolicy(retentionClass: .decodedCache, maxBytes: 1_000))
        try declare(RetentionPolicy(retentionClass: .unpublishedDownloads, maxBytes: 1_000))

        let withoutPort = try await coordinator(clock: SteppingClock(TestInstant.seconds(60))).run()
        XCTAssertEqual(
            withoutPort.result(for: .decodedCache)?.skipped,
            "no media port attached to this run"
        )
        XCTAssertEqual(
            withoutPort.result(for: .unpublishedDownloads)?.skipped,
            "no media port attached to this run"
        )

        let port = CountingMediaPort(freedBytes: 512)
        let withPort = try await coordinator(
            media: port,
            clock: SteppingClock(TestInstant.seconds(120))
        ).run()

        XCTAssertEqual(withPort.result(for: .decodedCache)?.collected, 1)
        XCTAssertEqual(withPort.result(for: .decodedCache)?.freedBytes, 512)
        let unpinnedCalls = await port.unpinnedCalls
        let orphanCalls = await port.orphanCalls
        XCTAssertEqual(unpinnedCalls, 1)
        XCTAssertEqual(orphanCalls, 1, "the orphan-file path is part of the same class")
    }

    func testTheRunIsRecordedDurablyAndDedicatedCursorsFollowIt() async throws {
        try declare(RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 86_400))
        try insertEvidence(batchID: "old", bytes: 10, createdAtMilliseconds: 0)
        let clock = SteppingClock(TestInstant.seconds(2 * 86_400))

        let report = try await coordinator(clock: clock).run()

        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM gc_run WHERE outcome = 'completed'"), 1)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM gc_run_class WHERE run_id = \(report.runID)"),
            Int64(RetentionClass.allCases.count),
            "the per-class account is durable, not only in the returned report"
        )
        XCTAssertEqual(
            try string("SELECT value FROM runtime_metadata WHERE key = '\(RetentionCoordinator.lastGCRunKey)'"),
            "\(report.runID)"
        )
        XCTAssertEqual(
            try string("SELECT value FROM runtime_metadata WHERE key = '\(RetentionCoordinator.lastPurgeRevisionKey)'"),
            "\(report.runID)",
            "a run that removed evidence advances the purge cursor"
        )
        XCTAssertEqual(
            try string("SELECT value FROM runtime_metadata WHERE key = '\(RetentionCoordinator.clockHighWaterKey)'"),
            "\(RetentionTimestamp.milliseconds(clock.now))"
        )

        let reopened = try reopenDatabase()
        let last = try XCTUnwrap(coordinator(clock: clock, in: reopened).lastRun())
        XCTAssertEqual(last.runID, report.runID)
        XCTAssertEqual(last.mode, .markSweep)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM gc_run_class WHERE run_id = \(report.runID)", in: reopened),
            Int64(RetentionClass.allCases.count),
            "the account survives reopening the database"
        )
    }

    func testAFailingRunIsRecordedAsAbortedRatherThanAsNeverHavingHappened() async throws {
        try declare(RetentionPolicy(retentionClass: .publishedAssetBytes, maxBytes: 0))

        do {
            _ = try await coordinator(
                roots: FailingRootProvider(),
                clock: SteppingClock(TestInstant.seconds(60))
            ).run()
            XCTFail("the run must rethrow the failure")
        } catch is FailingRootProvider.Unavailable {
            // expected
        }

        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM gc_run WHERE outcome = 'aborted'"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM gc_run WHERE outcome = 'completed'"), 0)
        XCTAssertEqual(
            try scalar(
                "SELECT COUNT(*) FROM gc_run_class, gc_run WHERE gc_run_class.run_id = gc_run.id AND gc_run.outcome = 'aborted'"
            ),
            0,
            "an aborted run has no per-class results to be read as partial success"
        )
        XCTAssertNil(try coordinator(clock: SteppingClock(TestInstant.seconds(60))).lastRun())
    }

    // MARK: - The classes that collect

    func testOrphanSearchProjectionsAreCollectedAndRealSupplyIsNot() async throws {
        let source = try ensureSource("catalog:alpha")
        let row = try insertSupplyRow(objectKey: "kept", sourceIDs: [source], observedAt: 0)
        try declare(RetentionPolicy(retentionClass: .reconstructibleProjections, maxAgeSeconds: 1))
        // One search row for a living record and one whose record is gone. The supply table cannot
        // hold an orphan — its composite foreign key needs the record and the revision — so a search
        // row is the only projection a rebuild can leave behind.
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO origin_search (rowid, projection) VALUES (?, 'live')",
                arguments: [row.recordID]
            )
            try db.execute(sql: "INSERT INTO origin_search (rowid, projection) VALUES (424242, 'ghost')")
        }

        let report = try await coordinator(clock: SteppingClock(TestInstant.seconds(86_400))).run()

        XCTAssertEqual(report.result(for: .reconstructibleProjections)?.collected, 1)
        XCTAssertEqual(try rowCount("origin_search"), 1, "the live record keeps its projection")
        XCTAssertEqual(
            try scalar("SELECT rowid FROM origin_search"),
            row.recordID,
            "the row that survived is the one with a living record"
        )
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM selection_supply WHERE origin_record_id = \(row.recordID)"),
            1,
            "a projection with a living parent is not an orphan"
        )
    }

    /// `evidencePurgePreservesBookmarksAndHistory` — contract-matrix row 33, ADR-004 invariant 2.
    ///
    /// The fixture makes the purge *want* the edition a bookmark depends on: four editions of one
    /// context are activated in order, so three are superseded, and the declared limit keeps one. The
    /// keeper is the newest superseded edition; the older two would both go on count alone. One of them
    /// holds the card of a saved item, so it must survive, and the assertion is the *reachability* of
    /// that card — not the number of editions left.
    func testEvidencePurgePreservesBookmarksAndHistory() async throws {
        let source = try ensureSource("catalog:alpha")
        let saved = try insertSupplyRow(objectKey: "saved", sourceIDs: [source], observedAt: 0)
        let plain = try insertSupplyRow(objectKey: "plain", sourceIDs: [source], observedAt: 0)
        try savedBookmark(subjectID: "legacy-saved", recordID: saved.recordID)
        let supersededOlder = try insertSupersededRevision(
            of: plain.recordID,
            createdAtMilliseconds: 0
        )

        let context = try planContext()
        let pinnedDigest = String(repeating: "a", count: 64)
        let orphanDigest = String(repeating: "b", count: 64)
        let pinnedAsset = try assetVersion(digest: pinnedDigest, byteCount: 120)
        let orphanAsset = try assetVersion(digest: orphanDigest, byteCount: 90, storageClass: .cached)
        let savedMedia = PublishedMediaSet(
            primary: PublishedMediaRef(
                contentDigest: pinnedDigest,
                recipeVersion: 1,
                pixelWidth: 30,
                pixelHeight: 10,
                mimeType: "image/png"
            ),
            alternates: [],
            placeholder: nil
        )

        let first = try activateEdition(
            context: context,
            revisionTag: "rev-1",
            epoch: 1,
            successorOf: nil,
            committedAt: TestInstant.seconds(1)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-1", title: "First")]
        }
        let savedEdition = try activateEdition(
            context: context,
            revisionTag: "rev-2",
            epoch: 2,
            successorOf: first.edition.editionID,
            committedAt: TestInstant.seconds(2),
            assets: [pinnedAsset, orphanAsset],
            pinned: [try OriginRevisionID(saved.revisionID)]
        ) { edition in
            [
                try oneCard(
                    edition: edition,
                    ordinal: 0,
                    row: saved,
                    revisionTag: "rev-2",
                    title: "Saved article",
                    media: savedMedia,
                    assetReferences: [
                        PublishedAssetRefRecord(
                            slot: .primary,
                            role: .image,
                            renderSlot: .primary,
                            contentDigest: pinnedDigest,
                            recipeVersion: 1,
                            aspectRatio: 3.0
                        )
                    ]
                )
            ]
        }
        let keeper = try activateEdition(
            context: context,
            revisionTag: "rev-3",
            epoch: 3,
            successorOf: savedEdition.edition.editionID,
            committedAt: TestInstant.seconds(3)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-3", title: "Third")]
        }
        let active = try activateEdition(
            context: context,
            revisionTag: "rev-4",
            epoch: 4,
            successorOf: keeper.edition.editionID,
            committedAt: TestInstant.seconds(4)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-4", title: "Fourth")]
        }

        let savedCardID = savedEdition.receipt.cardIDs[0].rawValue
        try insertHistoryProjection(cardID: savedCardID, editionID: savedEdition.edition.editionID.rawValue)
        try insertEvidence(batchID: "old", bytes: 40, createdAtMilliseconds: 0)
        try insertEvidence(
            batchID: "recent",
            bytes: 40,
            createdAtMilliseconds: RetentionTimestamp.milliseconds(TestInstant.seconds(40 * 86_400))
        )

        try declare(RetentionPolicy(retentionClass: .publication, maxEditions: 1))
        try declare(RetentionPolicy(retentionClass: .canonicalSupply, maxAgeSeconds: 30 * 86_400))
        try declare(RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 30 * 86_400))
        try declare(RetentionPolicy(retentionClass: .publishedAssetBytes, maxBytes: 0))
        try declare(RetentionPolicy(retentionClass: .unpublishedDownloads, maxBytes: 0))
        try declare(RetentionPolicy(retentionClass: .decodedCache, maxBytes: 1_000))

        // The bookmark exists in the authority (which the composition reads) *and* in the runtime's
        // projection, and the purge is then asserted against the reader's card, not against the proxy.
        let port = CountingMediaPort(freedBytes: 90)
        let report = try await coordinator(
            media: port,
            roots: SqlRetentionRootProvider(
                authority: SavedSubjects(subjects: ["legacy-saved"])
            ),
            clock: SteppingClock(TestInstant.seconds(40 * 86_400))
        ).run()
        XCTAssertEqual(
            report.bookmarkRootSource,
            "the authoritative saved subjects unioned with the runtime's projection"
        )

        // The purge ran and the limit was applied: the oldest unprotected edition is gone.
        XCTAssertEqual(report.result(for: .publication)?.collected, 1)
        XCTAssertEqual(try editionState(first.edition.editionID), "purged")
        XCTAssertEqual(try editionState(keeper.edition.editionID), "superseded")
        XCTAssertEqual(try editionState(active.edition.editionID), "active")
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM published_card WHERE edition_id = \(first.edition.editionID.rawValue)"),
            0,
            "a purged edition keeps no card"
        )

        // Assert the reachability, not the count: the edition the bookmark needs was a purge candidate
        // and is still there, with its card and its frozen payload.
        XCTAssertEqual(
            try editionState(savedEdition.edition.editionID),
            "superseded",
            "an edition reachable from a bookmark is never purged"
        )
        XCTAssertGreaterThan(
            report.result(for: .publication)?.protected ?? 0,
            0,
            "the run says it refused to take a pinned edition"
        )
        let reachableCards = try scalar("""
            SELECT COUNT(*) FROM published_card c
            JOIN feed_edition e ON e.edition_id = c.edition_id
            WHERE c.origin_record_id = \(saved.recordID) AND e.state <> 'purged'
            """)
        XCTAssertEqual(reachableCards, 1, "the saved article is still published in a retained edition")
        let savedCard = try XCTUnwrap(try repositories().card(savedEdition.receipt.cardIDs[0]))
        XCTAssertEqual(savedCard.payload.title, "Saved article")
        XCTAssertEqual(savedCard.payload.media.primary?.contentDigest, pinnedDigest)
        XCTAssertEqual(
            try UserStateProjectionStore(database: database).savedSubjects(kind: .bookmark),
            ["legacy-saved"]
        )
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM legacy_item_map WHERE legacy_item_id = 'legacy-saved'"),
            1,
            "the durable mapping a rebuild re-resolves is untouched"
        )

        // The reconstructible and advisory classes really were collected.
        XCTAssertEqual(report.result(for: .canonicalSupply)?.collected, 1)
        XCTAssertEqual(
            try rowCount("origin_revision", in: database),
            2,
            "the current revision of each record stays; the superseded one went"
        )
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM origin_revision WHERE id = \(supersededOlder)"),
            0
        )
        XCTAssertEqual(report.result(for: .connectorEvidence)?.collected, 1)
        XCTAssertEqual(
            try string("SELECT batch_id FROM connector_evidence"),
            "recent",
            "only the evidence past the declared age went"
        )

        // Pins block collection unconditionally, and identity survives what was released.
        XCTAssertEqual(try durabilityState(ofAssetID: try assetID(digest: pinnedDigest)), "committed")
        XCTAssertEqual(try durabilityState(ofAssetID: try assetID(digest: orphanDigest)), "bytes_removed")
        let requestedKeys = await port.requestedKeys
        XCTAssertEqual(requestedKeys.count, 1)
        XCTAssertEqual(requestedKeys.first?.contentDigestHex, orphanDigest)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM published_asset_ref WHERE asset_version_id = \(try assetID(digest: pinnedDigest))"),
            1,
            "the retained card still names its bytes"
        )

        // History outlives the purge (ADR-007 D10: the projection is the retention root policy reads).
        XCTAssertEqual(try rowCount("history_projection"), 1)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM history_projection WHERE card_id = \(savedCardID)"),
            1
        )
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM exposure_fact WHERE edition_id = \(first.edition.editionID.rawValue)"),
            0
        )
        try assertPublicationIntegrity(label: "after the retention run")
        XCTAssertTrue(report.blockers.isEmpty, "\(report.blockers)")
    }

    func testPinsBlockCollectionUnconditionallyAndReconciliationReportsALostPin() async throws {
        let source = try ensureSource("catalog:alpha")
        let row = try insertSupplyRow(objectKey: "pinned", sourceIDs: [source], observedAt: 0)
        let digest = String(repeating: "c", count: 64)
        let asset = try assetVersion(digest: digest, byteCount: 64)
        let media = PublishedMediaSet(
            primary: PublishedMediaRef(
                contentDigest: digest,
                recipeVersion: 1,
                pixelWidth: 30,
                pixelHeight: 10,
                mimeType: "image/png"
            ),
            alternates: [],
            placeholder: nil
        )
        let context = try planContext()
        let published = try activateEdition(
            context: context,
            revisionTag: "rev-1",
            epoch: 1,
            successorOf: nil,
            committedAt: TestInstant.seconds(1),
            assets: [asset],
            pinned: [try OriginRevisionID(row.revisionID)]
        ) { edition in
            [
                try oneCard(
                    edition: edition,
                    ordinal: 0,
                    row: row,
                    revisionTag: "rev-1",
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
            ]
        }
        try declare(RetentionPolicy(retentionClass: .publishedAssetBytes, maxBytes: 0))
        let assetRow = try assetID(digest: digest)

        // With the real roots the pin holds, and reconciliation agrees the state is healthy.
        let protectedRun = try await coordinator(
            media: CountingMediaPort(),
            clock: SteppingClock(TestInstant.seconds(60))
        ).run()
        XCTAssertEqual(protectedRun.result(for: .publishedAssetBytes)?.collected, 0)
        XCTAssertGreaterThanOrEqual(protectedRun.result(for: .publishedAssetBytes)?.protected ?? 0, 1)
        XCTAssertEqual(try durabilityState(ofAssetID: assetRow), "committed")
        let healthy = try await coordinator(clock: SteppingClock(TestInstant.seconds(90)))
            .run(mode: .refcountReconcile)
        XCTAssertTrue(healthy.blockers.isEmpty, "\(healthy.blockers)")

        // A pin the sweep cannot see: the bytes go, and reconciliation is what catches that.
        let lossy = LossyRootProvider(wrapped: SqlRetentionRootProvider())
        let lossyRun = try await coordinator(
            media: CountingMediaPort(),
            roots: lossy,
            clock: SteppingClock(TestInstant.seconds(120))
        ).run()
        XCTAssertEqual(lossyRun.result(for: .publishedAssetBytes)?.collected, 1)
        XCTAssertEqual(try durabilityState(ofAssetID: assetRow), "bytes_removed")

        let reconciliation = try await coordinator(
            roots: lossy,
            clock: SteppingClock(TestInstant.seconds(150))
        ).run(mode: .refcountReconcile)

        XCTAssertEqual(reconciliation.collected, 0, "reconciliation collects nothing")
        XCTAssertEqual(reconciliation.blockers.count, 1, "\(reconciliation.blockers)")
        XCTAssertTrue(
            reconciliation.blockers.first?.contains("published bytes removed while a retained card names them") == true,
            "\(reconciliation.blockers)"
        )

        // The card keeps its identity and its frozen media reference: only the files are gone.
        let card = try XCTUnwrap(try repositories().card(published.receipt.cardIDs[0]))
        XCTAssertEqual(card.payload.media.primary?.contentDigest, digest)
    }

    /// Plan PR-16 item 1's "testar sob supply contínua": a run that meets supply *arriving*, not supply
    /// that merely exists.
    ///
    /// The three claims, and why each can fail:
    ///
    /// 1. **supply that arrives between two runs is never taken by the later one.** Rows admitted and
    ///    inserted after the first run's root derivation are age-eligible for the second run (their
    ///    timestamps are old, their arrival is new), so a run that decides from a candidate list alone
    ///    takes them. A run that re-derives its roots from durable state in the transaction that deletes
    ///    does not.
    /// 2. **a pin released inside a run becomes collectable inside that run.** The publication pass runs
    ///    before the published-bytes pass, and the bytes pass re-reads the roots *after* the purge, so the
    ///    asset the purged edition was pinning is taken by the same run that released it. A coordinator
    ///    that snapshots its roots once per run keeps it protected for a run that never comes.
    /// 3. **the account survives two runs**: two `gc_run` rows with distinct ids, per-class rows for both,
    ///    and `last_gc_revision` advancing rather than being rewritten in place.
    func testSupplyArrivingBetweenRunsIsNeverTakenAndAPinReleasedLaterIsCollectedInThatRun() async throws {
        try registerTarget()
        let source = try ensureSource("catalog:alpha")
        let first = try insertSupplyRow(objectKey: "first", sourceIDs: [source], observedAt: 0)

        // An asset a retained publication pins, so the first run has something it must refuse.
        let digest = String(repeating: "d", count: 64)
        let asset = try assetVersion(digest: digest, byteCount: 96)
        let media = PublishedMediaSet(
            primary: PublishedMediaRef(
                contentDigest: digest,
                recipeVersion: 1,
                pixelWidth: 30,
                pixelHeight: 10,
                mimeType: "image/png"
            ),
            alternates: [],
            placeholder: nil
        )
        let context = try planContext()
        let pinnedEdition = try activateEdition(
            context: context,
            revisionTag: "rev-1",
            epoch: 1,
            successorOf: nil,
            committedAt: TestInstant.seconds(1),
            assets: [asset],
            pinned: [try OriginRevisionID(first.revisionID)]
        ) { edition in
            [
                try oneCard(
                    edition: edition,
                    ordinal: 0,
                    row: first,
                    revisionTag: "rev-1",
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
            ]
        }

        try declare(RetentionPolicy(retentionClass: .publishedAssetBytes, maxBytes: 0))
        try declare(RetentionPolicy(retentionClass: .canonicalSupply, maxAgeSeconds: 30 * 86_400))
        try declare(RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 30 * 86_400))
        try declare(RetentionPolicy(retentionClass: .publication, maxEditions: 1))

        let clock = SteppingClock(TestInstant.seconds(40 * 86_400))
        let firstPort = CountingMediaPort()
        let firstRun = try await coordinator(
            media: firstPort,
            clock: clock
        ).run()

        // The pin held, and nothing of the arriving supply existed yet.
        XCTAssertEqual(try durabilityState(ofAssetID: try assetID(digest: digest)), "committed")
        XCTAssertGreaterThanOrEqual(firstRun.result(for: .publishedAssetBytes)?.protected ?? 0, 1)
        let firstRequested = await firstPort.requestedKeys
        XCTAssertEqual(firstRequested.count, 0)

        // MARK: Supply keeps arriving after the first run's root derivation.
        let admitted = try admitRequiringSuccess(
            try batch(
                id: "batch-arriving",
                expectedCheckpoint: try stamp().checkpointRevision,
                observations: [
                    try observation(object: "arriving-1"),
                    try observation(object: "arriving-2"),
                ]
            )
        )
        XCTAssertEqual(admitted.admittedRevisionCount, 2)
        // And supply that is age-eligible the moment it lands: the timestamp is old, the arrival is new.
        let arriving = try insertSupplyRow(objectKey: "arriving-3", sourceIDs: [source], observedAt: 0)
        let recordsBefore = try rowCount("origin_record", in: database)
        let revisionsBefore = try rowCount("origin_revision", in: database)
        let supplyBefore = try rowCount("selection_supply", in: database)

        // And a publication arrives too: two successors, so the edition pinning the asset becomes a
        // purge candidate under the declared edition limit.
        let keeper = try activateEdition(
            context: context,
            revisionTag: "rev-2",
            epoch: 2,
            successorOf: pinnedEdition.edition.editionID,
            committedAt: TestInstant.seconds(2)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: arriving, revisionTag: "rev-2")]
        }
        _ = try activateEdition(
            context: context,
            revisionTag: "rev-3",
            epoch: 3,
            successorOf: keeper.edition.editionID,
            committedAt: TestInstant.seconds(3)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: first, revisionTag: "rev-3")]
        }

        clock.move(to: TestInstant.seconds(80 * 86_400))
        let secondPort = CountingMediaPort(freedBytes: 96)
        let secondRun = try await coordinator(
            media: secondPort,
            clock: clock
        ).run()

        // 1. Nothing that arrived was taken: every record, revision and supply row is still there.
        XCTAssertEqual(try rowCount("origin_record", in: database), recordsBefore)
        XCTAssertEqual(try rowCount("origin_revision", in: database), revisionsBefore)
        XCTAssertEqual(try rowCount("selection_supply", in: database), supplyBefore)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM selection_supply WHERE origin_record_id = \(arriving.recordID)"),
            1,
            "a row that arrived between the runs is live supply in the second run"
        )

        // 2. The pin this run released is collected by this run, and only now.
        XCTAssertEqual(secondRun.result(for: .publication)?.collected, 1, "the older pinned edition went")
        XCTAssertEqual(try editionState(pinnedEdition.edition.editionID), "purged")
        XCTAssertEqual(try durabilityState(ofAssetID: try assetID(digest: digest)), "bytes_removed")
        let requested = await secondPort.requestedKeys
        XCTAssertEqual(requested.map(\.contentDigestHex), [digest])

        // 3. Two runs, two accounts, and the cursor advanced rather than being rewritten.
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM gc_run WHERE outcome = 'completed'"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM gc_run_class WHERE run_id = \(firstRun.runID)"),
                       Int64(RetentionClass.allCases.count))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM gc_run_class WHERE run_id = \(secondRun.runID)"),
                       Int64(RetentionClass.allCases.count))
        XCTAssertNotEqual(firstRun.runID, secondRun.runID)
        XCTAssertEqual(
            try string("SELECT value FROM runtime_metadata WHERE key = '\(RetentionCoordinator.lastGCRunKey)'"),
            "\(secondRun.runID)",
            "the cursor is the latest run, not a rewritten row"
        )
        try assertPublicationIntegrity(label: "after two runs under continuous supply")
        XCTAssertTrue(secondRun.blockers.isEmpty, "\(secondRun.blockers)")
    }

    /// The bookmark root cannot be derived from this database alone, and a lagging projection must
    /// not open a window: with the authority attached, a saved subject the projection has not seen
    /// yet still protects the edition holding its card.
    func testABookmarkTheRuntimeProjectionHasNotSeenStillProtectsItsEdition() async throws {
        let source = try ensureSource("catalog:alpha")
        let saved = try insertSupplyRow(objectKey: "saved-elsewhere", sourceIDs: [source], observedAt: 0)
        let plain = try insertSupplyRow(objectKey: "plain", sourceIDs: [source], observedAt: 0)
        let context = try planContext()

        let first = try activateEdition(
            context: context,
            revisionTag: "rev-1",
            epoch: 1,
            successorOf: nil,
            committedAt: TestInstant.seconds(1)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-1", title: "First")]
        }
        let savedEdition = try activateEdition(
            context: context,
            revisionTag: "rev-2",
            epoch: 2,
            successorOf: first.edition.editionID,
            committedAt: TestInstant.seconds(2)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: saved, revisionTag: "rev-2", title: "Saved")]
        }
        let keeper = try activateEdition(
            context: context,
            revisionTag: "rev-3",
            epoch: 3,
            successorOf: savedEdition.edition.editionID,
            committedAt: TestInstant.seconds(3)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-3", title: "Third")]
        }
        _ = try activateEdition(
            context: context,
            revisionTag: "rev-4",
            epoch: 4,
            successorOf: keeper.edition.editionID,
            committedAt: TestInstant.seconds(4)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-4", title: "Fourth")]
        }

        // The durable mapping the runtime uses exists, but the projection does not know the item yet:
        // the authority has it and the runtime has not caught up. That is the lag ADR-004 D7 allows.
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO legacy_item_map (
                    legacy_item_id, legacy_source_url, origin_record_id, confidence, mapped_at
                ) VALUES ('legacy-only-in-authority', 'https://example.test/feed', ?, 'high', 0)
                """, arguments: [saved.recordID])
        }
        XCTAssertEqual(try rowCount("user_state_projection"), 0, "the projection really has not seen it")

        try declare(RetentionPolicy(retentionClass: .publication, maxEditions: 1))

        let authority = SavedSubjects(subjects: ["legacy-only-in-authority"])
        let report = try await coordinator(
            roots: SqlRetentionRootProvider(authority: authority),
            clock: SteppingClock(TestInstant.seconds(60))
        ).run()

        XCTAssertEqual(
            try UserStateProjectionStore(database: database).savedSubjects(kind: .bookmark),
            [],
            "the lag is real: the projection still holds nothing"
        )
        XCTAssertEqual(
            report.bookmarkRootSource,
            "the authoritative saved subjects unioned with the runtime's projection"
        )
        XCTAssertEqual(
            try editionState(keeper.edition.editionID),
            "superseded",
            "the newest superseded edition is inside the retained count and stays"
        )
        XCTAssertEqual(
            try editionState(savedEdition.edition.editionID),
            "superseded",
            "the edition the authority's bookmark needs is a purge candidate and survives"
        )
        XCTAssertEqual(
            try editionState(first.edition.editionID),
            "purged",
            "the unprotected older edition is the one the limit takes"
        )
        let reachable = try scalar("""
            SELECT COUNT(*) FROM published_card c
            JOIN feed_edition e ON e.edition_id = c.edition_id
            WHERE c.origin_record_id = \(saved.recordID) AND e.state <> 'purged'
            """)
        XCTAssertEqual(reachable, 1)

        // Without the authority the same fixture loses the edition: the limit is stated, not assumed.
        let withoutAuthority = try await coordinator(
            clock: SteppingClock(TestInstant.seconds(90))
        ).run()
        XCTAssertEqual(
            withoutAuthority.bookmarkRootSource,
            "the runtime's own bookmark projection; user.sqlite is the authority and was not read"
        )
        XCTAssertEqual(
            withoutAuthority.result(for: .publication)?.collected,
            1,
            "with no authority the projection is the only bookmark root, and it knows nothing here"
        )
        XCTAssertEqual(try editionState(savedEdition.edition.editionID), "purged")
    }

    func testRootsAreReadFromTheSameTransactionThatTakesTheRows() async throws {
        let source = try ensureSource("catalog:alpha")
        let plain = try insertSupplyRow(objectKey: "plain", sourceIDs: [source], observedAt: 0)
        let old = try insertSupersededRevision(of: plain.recordID, createdAtMilliseconds: 0)
        _ = old
        try declare(RetentionPolicy(retentionClass: .canonicalSupply, maxAgeSeconds: 86_400))
        try declare(RetentionPolicy(retentionClass: .publication, maxEditions: 1))
        try declare(RetentionPolicy(retentionClass: .publishedAssetBytes, maxBytes: 0))

        let context = try planContext()
        let first = try activateEdition(
            context: context,
            revisionTag: "rev-1",
            epoch: 1,
            successorOf: nil,
            committedAt: TestInstant.seconds(1)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-1")]
        }
        _ = try activateEdition(
            context: context,
            revisionTag: "rev-2",
            epoch: 2,
            successorOf: first.edition.editionID,
            committedAt: TestInstant.seconds(2)
        ) { edition in
            [try oneCard(edition: edition, ordinal: 0, row: plain, revisionTag: "rev-2")]
        }

        let report = try await coordinator(
            roots: TransactionScopedRootProvider(),
            clock: SteppingClock(TestInstant.seconds(10 * 86_400))
        ).run()

        XCTAssertGreaterThan(report.collected, 0, "the run really collected something")
        XCTAssertEqual(report.bookmarkRootSource, "an injected root provider")
    }

    func testAgeRetentionUsesAStoredWatermarkAndSuspendsOnARewoundClock() async throws {
        try declare(RetentionPolicy(retentionClass: .connectorEvidence, maxAgeSeconds: 30 * 86_400))
        let clock = SteppingClock(TestInstant.seconds(400 * 86_400))

        // A row long past the age limit is collected, and the run stores the watermark it decided by.
        try insertEvidence(batchID: "aged", bytes: 10, createdAtMilliseconds: 0)
        let first = try await coordinator(clock: clock).run()
        XCTAssertEqual(first.result(for: .connectorEvidence)?.collected, 1)
        XCTAssertEqual(
            try string("SELECT value FROM runtime_metadata WHERE key = '\(RetentionCoordinator.clockHighWaterKey)'"),
            "\(RetentionTimestamp.milliseconds(clock.now))"
        )

        // The clock goes backwards. A run that decided from the stored watermark would evict the row
        // written during the rollback, and one that decided from the wall clock would keep expired
        // rows forever; the run does neither — it suspends, and says so.
        clock.move(to: TestInstant.seconds(1))
        try insertEvidence(batchID: "fresh", bytes: 10, createdAtMilliseconds: RetentionTimestamp.milliseconds(clock.now))
        let rewound = try await coordinator(clock: clock).run()
        XCTAssertEqual(
            rewound.result(for: .connectorEvidence)?.skipped,
            "wall clock rewound: age-based collection suspended"
        )
        XCTAssertEqual(rewound.result(for: .connectorEvidence)?.collected, 0)
        XCTAssertEqual(try rowCount("connector_evidence"), 1, "nothing is evicted by a clock that cannot date it")
        XCTAssertEqual(
            try string("SELECT value FROM runtime_metadata WHERE key = '\(RetentionCoordinator.clockHighWaterKey)'"),
            "\(RetentionTimestamp.milliseconds(TestInstant.seconds(400 * 86_400)))",
            "a rewound clock never lowers the watermark"
        )

        // Once the clock catches up, expiry resumes from the stored watermark instead of restarting.
        clock.move(to: TestInstant.seconds(500 * 86_400))
        try insertEvidence(
            batchID: "current",
            bytes: 10,
            createdAtMilliseconds: RetentionTimestamp.milliseconds(clock.now)
        )
        let resumed = try await coordinator(clock: clock).run()
        XCTAssertEqual(resumed.result(for: .connectorEvidence)?.collected, 1, "the stale row is collected")
        XCTAssertEqual(try string("SELECT batch_id FROM connector_evidence"), "current")
    }
}
