import Foundation
import GRDB
import XCTest
import FeedDomain
@testable import FeedStorage

/// The property/replay class of plan §15.1: a failing seed is **captured**, and the capture is replayed
/// by a command rather than reconstructed by hand (baseline §8.11 records that the seeds existed and
/// nothing wrote out the one that failed).
///
/// The failure used here is one the runtime really detects: an edition whose stored payload no longer
/// recomputes to its digest, which `PublicationRepository.restore` refuses as `payloadCorrupted`. Its
/// seed is the reproduction key, so the artifact carries it together with the exact inputs the check
/// read.
final class FailureSeedReplayTests: RuntimeV2TestCase {
    /// Where an artifact is written.
    ///
    /// `FEEDMINE_SEED_CAPTURE_DIR` keeps it somewhere the replay command can be pointed at, which is what
    /// makes the command runnable by hand: without it the artifact lives in this test's temporary
    /// directory and is removed with it.
    private func captureDirectory() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["FEEDMINE_SEED_CAPTURE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return directory.appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// A published edition whose stored payload no longer matches its digest: the refusal the artifact
    /// captures, produced the way the runtime produces it.
    private func publishThenTamper() throws -> (
        context: ContextKey,
        edition: EditionSnapshot,
        cardID: PublicationCardID
    ) {
        let source = try ensureSource("catalog:alpha")
        let row = try insertSupplyRow(objectKey: "one", sourceIDs: [source], observedAt: 0)
        let context = try planContext()
        let draft = try openDraft(context: context, revisionTag: "rev-1")
        let card = CardInsertRecord(
            frozen: try frozenCard(
                edition: draft,
                segmentOrdinal: 0,
                absoluteOrdinal: 0,
                record: row,
                title: "Headline"
            ),
            assetReferences: []
        )
        let receipt = try publish(
            repositories(),
            token: draft.token,
            cards: [card],
            activation: .activate(successorOf: nil),
            pinned: [try OriginRevisionID(row.revisionID)]
        )
        try database.write { db in
            try db.execute(sql: "UPDATE published_card SET title = 'tampered'")
        }
        return (context, draft, receipt.cardIDs[0])
    }

    /// Bundles the failing database next to the artifact when the caller asked for a durable capture
    /// directory. A captured failure that names a database the test already deleted cannot be replayed,
    /// and the plan asks for the command that *replays* it — so the artifact carries what it names, and
    /// the copy is WAL-consistent (ADR-004 D3: the database with its `-wal`/`-shm` companions).
    private func bundleDatabaseIfRequested(into captureDirectory: URL) throws -> String {
        guard ProcessInfo.processInfo.environment["FEEDMINE_SEED_CAPTURE_DIR"] != nil else {
            return directory.path
        }
        let bundled = captureDirectory.appendingPathComponent("database", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for companion in ["runtime-v2.sqlite", "runtime-v2.sqlite-wal", "runtime-v2.sqlite-shm"] {
            let source = directory.appendingPathComponent(companion)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = bundled.appendingPathComponent(companion)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return bundled.path
    }

    private func capture(
        _ manifest: (context: ContextKey, edition: EditionSnapshot, cardID: PublicationCardID),
        observed: String = "payloadCorrupted",
        detail: String = "payload digest mismatch"
    ) throws -> URL {
        let captureDirectory = try captureDirectory()
        let failure = CapturedFailure(
            check: .editionRestoreIsReproducible,
            observedAtMilliseconds: 1_700_000_000_000,
            databasePath: try bundleDatabaseIfRequested(into: captureDirectory),
            surface: manifest.context.surface.rawValue,
            scopeKey: manifest.context.scopeKey,
            planIdentity: manifest.context.planIdentity,
            editionID: manifest.edition.editionID.rawValue,
            epoch: manifest.edition.epoch,
            seed: manifest.edition.seed,
            editorialRevision: manifest.edition.editorialRevision.digest,
            publicationSchemaVersion: manifest.edition.publicationSchemaVersion,
            cardIdentities: ["\(manifest.cardID.rawValue)"],
            expected: "restored",
            observed: observed,
            detail: detail
        )
        return try FailureSeedCapture(directory: captureDirectory).record(failure)
    }

    // MARK: - Capture

    func testACapturedFailureIsReproducedFromItsArtifact() throws {
        let artifact = try capture(try publishThenTamper())

        let failure = try FailureSeedCapture.load(artifact)
        XCTAssertEqual(failure.check, .editionRestoreIsReproducible)
        XCTAssertEqual(failure.observed, "payloadCorrupted")
        XCTAssertEqual(failure.seed, Data("edition-seed".utf8), "the artifact holds the key the run used")

        let outcome = try FailureSeedReplay().replay(failure)

        XCTAssertTrue(outcome.isReproduced, outcome.summary)
        XCTAssertTrue(outcome.summary.contains("payloadCorrupted"), outcome.summary)
    }

    func testTheReplayNamesTheSeedItUsedAndRefusesAnArtifactThatDoesNotDescribeTheEdition() throws {
        let artifact = try capture(try publishThenTamper())

        // Rewriting the seed is what a hand-reconstructed failure looks like: the artifact no longer
        // names the edition's own key, and the replay must say so instead of "reproducing" anything.
        let raw = try Data(contentsOf: artifact)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        var rewritten = object
        rewritten["seedBase64"] = Data("a-seed-that-never-ran".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: rewritten).write(to: artifact)

        let outcome = try FailureSeedReplay().replay(try FailureSeedCapture.load(artifact))

        XCTAssertFalse(outcome.isReproduced)
        XCTAssertTrue(outcome.summary.contains("recorded seed is not the edition's seed"), outcome.summary)
    }

    func testTheArtifactCarriesNoURLAndNoPublishedContent() throws {
        let artifact = try capture(try publishThenTamper())

        let text = try String(contentsOf: artifact, encoding: .utf8)

        XCTAssertFalse(text.contains("http"), "an artifact is left next to a run's diagnostics: no URLs")
        XCTAssertFalse(text.contains("Headline"), "no payload text")
        XCTAssertFalse(text.contains("tampered"), "no payload text")
        XCTAssertFalse(text.contains("example.test"), "no connector or media locator")
        XCTAssertTrue(text.contains("edition_restore_is_reproducible"), "the artifact names the check")
        XCTAssertTrue(text.contains(Data("edition-seed".utf8).base64EncodedString()), "and the seed")
    }

    func testTheReplayCommandNamesTheArtifactThePackageAndTheTestThatReplaysIt() throws {
        let artifact = try capture(try publishThenTamper())

        let command = FailureSeedCapture.replayCommand(artifact: artifact)

        XCTAssertTrue(command.hasPrefix("FEEDMINE_REPLAY_SEED=\(artifact.path) "), command)
        XCTAssertTrue(command.contains("swift test"), command)
        XCTAssertTrue(command.contains("--package-path Packages/FeedRuntimeV2"), command)
        XCTAssertTrue(
            command.contains("--filter FeedStorageTests.FailureSeedReplayTests"),
            "the filter has to select tests, and a filter that selects none exits 0: \(command)"
        )
    }

    /// The command's target: it replays the artifact the environment names, and a freshly captured one
    /// when there is none, so the path is exercised in every run instead of only by hand.
    func testTheArtifactTheEnvironmentNamesIsReplayed() throws {
        let named = ProcessInfo.processInfo.environment[FailureSeedCapture.environmentKey]
        let artifact = try named.map { URL(fileURLWithPath: $0) } ?? capture(try publishThenTamper())

        let outcome = try FailureSeedReplay().replay(try FailureSeedCapture.load(artifact))

        XCTAssertTrue(outcome.isReproduced, "\(outcome.summary) — artifact \(artifact.path)")
    }

    func testAnArtifactFromAFutureSchemaIsRefusedRatherThanDecodedOptimistically() throws {
        let artifact = try capture(try publishThenTamper())
        let raw = try Data(contentsOf: artifact)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var rewritten = object
        rewritten["schemaVersion"] = CapturedFailure.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: rewritten).write(to: artifact)

        XCTAssertThrowsError(try FailureSeedCapture.load(artifact)) { error in
            XCTAssertEqual(
                error as? FailureSeedError,
                .unsupportedSchemaVersion(CapturedFailure.currentSchemaVersion + 1)
            )
        }
    }
}
