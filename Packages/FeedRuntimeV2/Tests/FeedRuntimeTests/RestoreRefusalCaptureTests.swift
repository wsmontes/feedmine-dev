import XCTest
import Foundation
import GRDB
@testable import FeedDomain
@testable import FeedRuntime
@testable import FeedStorage

/// The caller half of the property/replay class: a session whose restore is refused **captures** the
/// failing input instead of leaving the refusal as a log line (plan §15.1, baseline §8.11).
///
/// The capture is a port on purpose. A composition with no diagnostic directory — every test, and the
/// shadow lane — passes `nil` and nothing is written, and the session's refusal is unchanged either way,
/// because a diagnostic that could turn a refusal into a different failure would be worse than no
/// diagnostic.
final class RestoreRefusalCaptureTests: XCTestCase {
    private var directory: URL!
    private var database: RuntimeDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr16-capture-\(UUID().uuidString)", isDirectory: true)
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

    @discardableResult
    /// Publishes one active edition. A `storedSchemaVersion` above the built one is written *after* the
    /// commit, which is how a database written by a newer build looks to this one: the write path would
    /// never produce it, and `restore` must refuse it rather than decode it optimistically.
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
        return (
            context,
            try XCTUnwrap(try repository.edition(draft.editionID)),
            receipt.cardIDs[0]
        )
    }

    private func makeSession(context: ContextKey, capture: (any FailureSeedCapturing)?) throws -> FeedSession {
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
            editorialClock: TestEditorialClock(now: SessionFixture.instant),
            failureCapture: capture
        )
    }

    func testACorruptedPayloadRefusalCapturesTheSeedAndTheExactInputs() async throws {
        let published = try publishActiveEdition()
        try database.write { db in
            try db.execute(sql: "UPDATE published_card SET title = 'tampered'")
        }
        let captureDirectory = directory.appendingPathComponent("diagnostics", isDirectory: true)
        let session = try makeSession(
            context: published.context,
            capture: FailureSeedCapture(directory: captureDirectory)
        )

        _ = await session.start()
        await session.drainPendingWork()

        let statistics = await session.currentStatistics()
        XCTAssertEqual(
            statistics.restoreRefusals,
            1,
            "the refusal still travels to the caller, unchanged by the capture"
        )
        let artifacts = try FailureSeedCapture(directory: captureDirectory).artifacts()
        XCTAssertEqual(artifacts.count, 1, "exactly one failing input, written once")
        let failure = try FailureSeedCapture.load(artifacts[0])

        XCTAssertEqual(failure.check, .editionRestoreIsReproducible)
        XCTAssertEqual(failure.observed, "payloadCorrupted")
        XCTAssertEqual(failure.expected, "restored")
        XCTAssertEqual(failure.seed, published.edition.seed)
        XCTAssertEqual(failure.editionID, published.edition.editionID.rawValue)
        XCTAssertEqual(failure.epoch, published.edition.epoch)
        XCTAssertEqual(failure.surface, "main")
        XCTAssertEqual(failure.scopeKey, published.context.scopeKey)
        XCTAssertEqual(failure.planIdentity, published.context.planIdentity)
        XCTAssertEqual(failure.cardIdentities, ["\(published.cardID.rawValue)"])
        XCTAssertEqual(failure.databasePath, directory.path)
        XCTAssertTrue(failure.detail.contains("recomputed"), failure.detail)

        // And it replays: the captured failure is not a note, it is the failing input.
        let outcome = try FailureSeedReplay().replay(failure)
        XCTAssertTrue(outcome.isReproduced, outcome.summary)
    }

    func testAnIncompatibleEditionRefusalCapturesTheEditionsSeed() async throws {
        let published = try publishActiveEdition(storedSchemaVersion: 99)
        let captureDirectory = directory.appendingPathComponent("diagnostics", isDirectory: true)
        let session = try makeSession(
            context: published.context,
            capture: FailureSeedCapture(directory: captureDirectory)
        )

        _ = await session.start()
        await session.drainPendingWork()

        let statistics = await session.currentStatistics()
        XCTAssertEqual(statistics.restoreRefusals, 1)
        let failure = try FailureSeedCapture.load(try XCTUnwrap(
            try FailureSeedCapture(directory: captureDirectory).artifacts().first
        ))
        XCTAssertEqual(failure.observed, "unsupportedPublicationSchemaVersion")
        XCTAssertEqual(failure.publicationSchemaVersion, 99)
        XCTAssertEqual(failure.seed, published.edition.seed)
        XCTAssertTrue(failure.detail.contains("99"), failure.detail)
    }

    func testWithoutACapturePortTheRefusalIsUnchangedAndNothingIsWritten() async throws {
        let published = try publishActiveEdition()
        try database.write { db in
            try db.execute(sql: "UPDATE published_card SET title = 'tampered'")
        }
        let session = try makeSession(context: published.context, capture: nil)

        _ = await session.start()
        await session.drainPendingWork()

        let statistics = await session.currentStatistics()
        XCTAssertEqual(statistics.restoreRefusals, 1)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter {
                $0.hasPrefix(FailureSeedCapture.fileNamePrefix)
            } ?? [],
            [],
            "no capture port means no diagnostic directory and no artifact"
        )
    }
}
