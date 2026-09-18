import XCTest
import Foundation
import GRDB
@testable import FeedDomain
@testable import FeedRuntime
@testable import FeedStorage

/// Plan §16's warm-restore rule: a restore that needs no network, no Selection and no catalogue refresh
/// is a warm start, and **a launch with no compatible edition is classified cold/recovery** instead of
/// being folded into the warm-start distribution.
///
/// The rule's first half was proven on a device at PR-13 close (baseline §8.13.1: the offline launch
/// published a populated feed from cache). This file covers the second half, which was the gap: every way
/// a restore can fail to find a compatible edition is classified, and none of them is silently a warm
/// start.
final class StartupClassificationTests: XCTestCase {
    private var directory: URL!
    private var database: RuntimeDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr16-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
    }

    override func tearDownWithError() throws {
        database = nil
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    private var repository: PublicationRepository { PublicationRepository(database: database) }

    /// Publishes one active edition, optionally with a schema version a newer build wrote.
    @discardableResult
    private func publishActiveEdition(
        scopeKey: String = "main",
        storedSchemaVersion: Int? = nil
    ) throws -> (context: ContextKey, edition: EditionSnapshot, cardID: PublicationCardID) {
        let context = try SessionFixture.context(scopeKey)
        let revision = try SessionFixture.revision("revision-a")
        let draft = try repository.beginEdition(
            context: context,
            editorialRevision: revision,
            epoch: 1,
            seed: Data("edition-seed".utf8),
            successorOf: nil,
            at: SessionFixture.instant
        )
        let card = CardInsertRecord(
            frozen: try PublishedCardPayload.Frozen(
                editionID: draft.editionID,
                segmentOrdinal: 0,
                absoluteOrdinal: 0,
                origin: PublishedOrigin(
                    originRecordID: try OriginRecordID(1),
                    originRevisionID: try OriginRevisionID(1),
                    sourceID: nil,
                    providerID: nil,
                    sourceDisplayName: "Source",
                    providerDisplayName: nil
                ),
                title: "Card 0",
                primaryText: "Excerpt 0",
                publishedAt: SessionFixture.instant,
                publishedAtKind: .authored,
                observationAt: SessionFixture.instant,
                media: .none,
                primaryAction: nil,
                interactionSummary: nil,
                renderContract: RenderContract.resolved(media: .none),
                editorialRevision: revision,
                publicationSchemaVersion: PublicationSchema.currentVersion
            ),
            assetReferences: []
        )
        let receipt = try repository.commit(
            SegmentCommitRequest(
                token: try repository.token(for: draft.editionID),
                segmentOrdinal: 0,
                absoluteOrdinalStart: 0,
                segmentSeed: Data("segment-seed".utf8),
                policyRevision: revision.digest,
                committedAt: SessionFixture.instant,
                activation: .activate(successorOf: nil),
                cards: [card],
                assets: [],
                mediaPreparations: [],
                pinnedRevisions: []
            )
        )
        if let storedSchemaVersion {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE feed_edition SET publication_schema_version = ?",
                    arguments: [storedSchemaVersion]
                )
            }
        }
        return (context, try XCTUnwrap(try repository.edition(draft.editionID)), receipt.cardIDs[0])
    }

    private func makeSession(context: ContextKey) throws -> FeedSession {
        FeedSession(
            state: FeedSessionState(
                stamp: SessionStamp(1),
                context: context,
                historyScope: .main,
                historyPolicy: try HistoryPolicy(
                    scope: .main,
                    applySeen: true,
                    showOverlay: true,
                    autoExclude: true,
                    version: 1
                ),
                renderEnvironment: try SessionFixture.renderEnvironment(),
                windowConfiguration: .baseline
            ),
            repository: repository,
            checkpoints: SessionCheckpointStore(database: database),
            facts: ExposureFactStore(database: database),
            composer: SpySessionComposer(),
            userActions: SpyUserActions(),
            clock: TestMonotonicClock(),
            editorialClock: TestEditorialClock(now: SessionFixture.instant)
        )
    }

    func testAStoredEditionIsClassifiedAsAWarmRestore() async throws {
        let published = try publishActiveEdition()
        let session = try makeSession(context: published.context)

        _ = await session.start()
        await session.drainPendingWork()

        let started = await session.currentStartupReport()
        let report = try XCTUnwrap(started)
        XCTAssertEqual(report.classification, .warmRestore)
        XCTAssertEqual(report.editionID, published.edition.editionID)
        XCTAssertEqual(report.restoredCardCount, 1)
    }

    func testNoCompatibleEditionIsColdRecoveryNotAWarmStart() async throws {
        // Nothing has ever been published for this context: the canonical shape of "no compatible
        // edition", and the one §16 says must not enter the warm-start distribution.
        let session = try makeSession(context: try SessionFixture.context("main"))

        _ = await session.start()
        await session.drainPendingWork()

        let started = await session.currentStartupReport()
        let report = try XCTUnwrap(started)
        XCTAssertEqual(report.classification, .coldRecovery)
        XCTAssertNil(report.editionID)
        XCTAssertTrue(report.reason.contains("no compatible edition"), report.reason)
    }

    func testAnEditionFromANewerBuildIsColdRecovery() async throws {
        let published = try publishActiveEdition(storedSchemaVersion: 99)
        let session = try makeSession(context: published.context)

        _ = await session.start()
        await session.drainPendingWork()

        let started = await session.currentStartupReport()
        let report = try XCTUnwrap(started)
        XCTAssertEqual(report.classification, .coldRecovery)
        XCTAssertTrue(report.reason.contains("99"), report.reason)
    }

    func testAnEditionWhosePayloadNoLongerRecomputesIsColdRecovery() async throws {
        let published = try publishActiveEdition()
        try database.write { db in
            try db.execute(sql: "UPDATE published_card SET title = 'tampered'")
        }
        let session = try makeSession(context: published.context)

        _ = await session.start()
        await session.drainPendingWork()

        let started = await session.currentStartupReport()
        let report = try XCTUnwrap(started)
        XCTAssertEqual(report.classification, .coldRecovery)
        XCTAssertTrue(report.reason.contains("no longer recomputes"), report.reason)
    }

    func testNoStartupReportExistsBeforeTheSessionOpens() async throws {
        let session = try makeSession(context: try SessionFixture.context("main"))
        let before = await session.currentStartupReport()
        XCTAssertNil(before, "no launch has happened yet")

        _ = await session.start()
        await session.drainPendingWork()
        let after = await session.currentStartupReport()
        XCTAssertNotNil(after)
    }
}
