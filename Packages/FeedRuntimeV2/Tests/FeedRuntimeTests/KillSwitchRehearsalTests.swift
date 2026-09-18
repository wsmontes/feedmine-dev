import XCTest
import Foundation
import GRDB
@testable import FeedDomain
@testable import FeedRuntime
@testable import FeedStorage

/// The kill-switch rehearsal: switching Runtime V2 off, and back on, must not cost durable state.
///
/// The flip itself is a launch decision the app makes (baseline §8.13.1 observed the `mode=legacy`
/// relaunch on a device, with the seeded user rows identical before and after). What this rehearsal
/// covers is the half this package owns: the mode table is exhaustive and single-owner, a legacy run
/// writes nothing, and the state a V2 run left is unchanged and re-adoptable when the switch returns.
final class KillSwitchRehearsalTests: XCTestCase {
    private var directory: URL!
    private var database: RuntimeDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr16-killswitch-\(UUID().uuidString)", isDirectory: true)
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

    /// Every durable table whose contents a mode flip must not touch, as one comparable value.
    private func fingerprint() throws -> String {
        let tables = [
            "feed_edition", "feed_segment", "published_card", "asset_version",
            "session_checkpoint", "exposure_fact", "history_projection",
            "user_state_projection", "user_state_watermark", "legacy_item_map",
            "origin_record", "origin_revision", "acquisition_target", "connector_checkpoint",
        ]
        return try database.read { db in
            var lines: [String] = []
            for table in tables {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1")
                lines.append("\(table)=\(rows.count)")
                for row in rows {
                    lines.append(Array(zip(row.columnNames, row.databaseValues))
                        .map { "\($0.0)=\($0.1)" }
                        .joined(separator: ","))
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    func testTheKillSwitchLeavesDurableStateIntactAndReversible() throws {
        let repository = PublicationRepository(database: database)
        let context = try SessionFixture.context("main")
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
        let checkpoints = SessionCheckpointStore(database: database)
        try checkpoints.save(
            SessionCheckpoint(
                context: context,
                editionID: draft.editionID,
                anchor: try FeedWindowAnchor(
                    editionID: draft.editionID,
                    cardID: receipt.cardIDs[0],
                    absoluteOrdinal: 0,
                    offsetFraction: 0.25
                ),
                renderEnvironmentRevision: try SessionFixture.renderEnvironment(),
                policyVersion: "policy-1",
                updatedAtMs: 0
            )
        )
        try UserStateProjectionStore(database: database).apply(
            kind: .bookmark,
            subjectID: "legacy-saved",
            wanted: true,
            operationID: "op-1",
            at: SessionFixture.instant
        )
        let before = try fingerprint()

        // The kill switch: a legacy launch is an exact mode that owns neither acquisition nor UI.
        let off = RuntimeModeResolver.resolve(
            RequestedFeatures(shadow: false, v2UI: false, v2Network: false)
        )
        XCTAssertEqual(off.mode, .legacy)
        XCTAssertTrue(off.isExact, "turning everything off is valid, not a rejected combination")
        XCTAssertFalse(off.mode.ownsAcquisition)
        XCTAssertFalse(off.mode.usesV2Presentation)
        XCTAssertFalse(off.mode.runsShadow)
        XCTAssertEqual(
            RuntimeMode.allCases.filter(\.ownsAcquisition),
            [.v2Full],
            "switching the switch cannot leave two acquisition owners"
        )
        XCTAssertEqual(try fingerprint(), before, "a legacy run writes nothing into the runtime database")

        // And it is reversible: the switch goes back on and the same rows answer.
        let on = RuntimeModeResolver.resolve(
            RequestedFeatures(shadow: false, v2UI: true, v2Network: false)
        )
        XCTAssertEqual(on.mode, .v2Presentation)
        XCTAssertTrue(on.mode.usesV2Presentation)
        let restored = try repository.restore(context: context)
        guard case let .restored(edition, records) = restored else {
            return XCTFail("the edition a V2 run published must still restore: \(restored)")
        }
        XCTAssertEqual(edition.editionID, draft.editionID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try checkpoints.load(context: context)?.anchor.offsetFraction, 0.25)
        XCTAssertEqual(
            try UserStateProjectionStore(database: database).savedSubjects(kind: .bookmark),
            ["legacy-saved"]
        )
        XCTAssertEqual(try fingerprint(), before, "a restore reads; it does not rewrite")
    }
}
