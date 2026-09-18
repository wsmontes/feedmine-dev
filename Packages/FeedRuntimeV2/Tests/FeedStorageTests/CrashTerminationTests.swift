import Darwin
import Foundation
import GRDB
import XCTest
import FeedDomain
import FeedMedia
@testable import FeedStorage

/// The crash class of plan §15.1: **an auxiliary process terminated** between commit, checkpoint and
/// file write; reopen and validate.
///
/// The plan disqualifies the substitute already in the tree — an exception thrown inside a transaction
/// proves rollback but "does not substitute for a termination test" — so these tests do the real thing:
/// a child process (`FeedStorageProbe`, a test helper executable in this package) reaches one boundary,
/// announces it on stdout, and holds. The parent then waits for that announcement, **asserts the child
/// is still running**, sends `SIGKILL`, and asserts the signal is what ended it. Only then does it
/// reopen the database and validate.
///
/// Proving the death is the point: a test that spawned a process which had already exited, or that
/// merely observed an exit code, would pass for the same reason a thrown exception passes, which is the
/// reason the plan rejected that shape.
final class CrashTerminationTests: RuntimeV2TestCase {
    private enum ProbeError: Error {
        case notBuilt(String)
        case neverReachedBoundary(String)
    }

    /// The probe lives beside the test bundle: one products directory per SwiftPM build.
    private static var probeExecutableURL: URL {
        Bundle(for: CrashTerminationTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("FeedStorageProbe", isDirectory: false)
    }

    private struct Probe {
        let process: Process
        let output: Pipe
        let boundary: String
    }

    // MARK: - Running the auxiliary process

    private func launchProbe(_ boundary: String, in directory: URL) throws -> Probe {
        let executable = Self.probeExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            XCTFail("the probe executable is missing at \(executable.path)")
            throw ProbeError.notBuilt(executable.path)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = [boundary, directory.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()

        let probe = Probe(process: process, output: stdout, boundary: boundary)
        let marker = try waitForBoundary(probe)
        return Probe(
            process: probe.process,
            output: probe.output,
            boundary: marker
        )
    }

    /// Reads stdout until the boundary line arrives. `availableData` blocks, so a probe that dies
    /// before reaching the boundary ends the read with EOF and the caller's assertion fails with what
    /// little the child managed to print.
    private func waitForBoundary(_ probe: Probe, timeout: TimeInterval = 60) throws -> String {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = probe.output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let text = String(data: buffer, encoding: .utf8), text.contains("BOUNDARY") {
                return text
            }
        }
        throw ProbeError.neverReachedBoundary(String(data: buffer, encoding: .utf8) ?? "")
    }

    /// Kills the child and **proves** it died from the signal: still running when it was sent, an
    /// uncaught signal as the reason, and `SIGKILL` as the status.
    @discardableResult
    private func killAndProveDeath(
        _ probe: Probe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int32 {
        XCTAssertTrue(
            probe.process.isRunning,
            "\(probe.boundary): the process must be alive at the boundary, not already finished",
            file: file,
            line: line
        )
        kill(probe.process.processIdentifier, SIGKILL)
        probe.process.waitUntilExit()
        XCTAssertEqual(
            probe.process.terminationReason,
            .uncaughtSignal,
            "\(probe.boundary): the process must have been terminated by a signal",
            file: file,
            line: line
        )
        XCTAssertEqual(
            probe.process.terminationStatus,
            Int32(SIGKILL),
            "\(probe.boundary): SIGKILL is what killed it",
            file: file,
            line: line
        )
        return Int32(SIGKILL)
    }

    private func assertDatabaseIsConsistent(in database: RuntimeDatabase) throws {
        XCTAssertEqual(
            try database.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") },
            "ok"
        )
        XCTAssertTrue(
            try database.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty,
            "a killed process leaves no dangling reference behind"
        )
    }

    // MARK: - Boundaries

    func testAProcessKilledAfterCommitKeepsTheCommittedStateAndNothingAfterIt() throws {
        let location = freshLocation(named: "after-commit")
        let probe = try launchProbe("commit", in: location.directory)
        XCTAssertTrue(probe.boundary.contains("BOUNDARY commit"), probe.boundary)
        XCTAssertTrue(probe.boundary.contains("checkpoint=1"), probe.boundary)

        killAndProveDeath(probe)

        let reopened = try RuntimeDatabase(location: location)
        // The commit is durable: content, checkpoint, supply and the batch row are all there.
        XCTAssertEqual(try rowCount("origin_record", in: reopened), 1)
        XCTAssertEqual(try rowCount("origin_revision", in: reopened), 1)
        XCTAssertEqual(try rowCount("admission_batch", in: reopened), 1)
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-probe'", in: reopened),
            1
        )
        XCTAssertEqual(try scalar("SELECT value FROM supply_generation WHERE id = 1", in: reopened), 1)
        // And the lost response is recoverable from durable state, which is what the kill interrupted.
        let receipt = try AdmissionLedger().receipt(forBatchID: "batch-commit", in: reopened)
        XCTAssertEqual(receipt?.batchID, "batch-commit")
        XCTAssertEqual(receipt?.checkpointRevision, 1)
        try assertDatabaseIsConsistent(in: reopened)
    }

    func testAProcessKilledHoldingAnOpenTransactionLeavesTheLastCommittedCheckpoint() throws {
        let location = freshLocation(named: "at-checkpoint")
        let probe = try launchProbe("checkpoint", in: location.directory)
        XCTAssertTrue(probe.boundary.contains("BOUNDARY checkpoint"), probe.boundary)
        XCTAssertTrue(
            probe.boundary.contains("committed_checkpoint=1") && probe.boundary.contains("uncommitted_checkpoint=2"),
            "the child really was holding a second, uncommitted transaction: \(probe.boundary)"
        )

        killAndProveDeath(probe)

        let reopened = try RuntimeDatabase(location: location)
        // The first batch survives in full.
        XCTAssertEqual(try rowCount("admission_batch", in: reopened), 1)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM origin_revision WHERE headline = 'Probe committed'", in: reopened),
            1
        )
        // The second batch leaves nothing: not its record, not its batch row, and above all not its
        // checkpoint advance — a checkpoint never runs ahead of content that committed.
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM origin_revision WHERE headline = 'Probe held'", in: reopened),
            0
        )
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM admission_batch WHERE batch_id = 'batch-2'", in: reopened),
            0
        )
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-probe'", in: reopened),
            1,
            "the checkpoint must not have advanced past the content that committed"
        )
        XCTAssertEqual(try scalar("SELECT value FROM supply_generation WHERE id = 1", in: reopened), 1)
        XCTAssertEqual(try rowCount("external_identity", in: reopened), 1)
        try assertDatabaseIsConsistent(in: reopened)
    }

    func testAProcessKilledBetweenTheTemporaryFileAndTheMoveLeavesACollectableOrphan() throws {
        let location = freshLocation(named: "at-file-write")
        let probe = try launchProbe("fileWrite", in: location.directory)
        XCTAssertTrue(probe.boundary.contains("BOUNDARY fileWrite"), probe.boundary)
        XCTAssertTrue(
            probe.boundary.contains("bytes=4096") && probe.boundary.contains("temporary=.pending-"),
            "the child reported the file it wrote: \(probe.boundary)"
        )
        let digest = try XCTUnwrap(
            probe.boundary
                .split(separator: " ")
                .first { $0.hasPrefix("asset=") }?
                .dropFirst("asset=".count)
        )
        let digestHex = String(digest)

        killAndProveDeath(probe)

        let root = location.directory.appendingPathComponent("Assets", isDirectory: true)
        let store = LocalAssetStore(rootDirectory: root)
        // The bytes were written and no row names them: an orphan by construction, never a reference
        // to bytes that were never committed (ADR-004 D10, INV-7).
        XCTAssertEqual(try store.orphanTemporaryFiles().count, 1)
        XCTAssertEqual(try store.storedBytes(for: try Self.identity(digestHex: digestHex)), nil)
        let reopened = try RuntimeDatabase(location: location)
        XCTAssertEqual(
            try scalar("SELECT COUNT(*) FROM asset_version WHERE content_digest = '\(digestHex)'", in: reopened),
            0,
            "a reference to bytes the move never placed is what the commit order exists to prevent"
        )
        try assertDatabaseIsConsistent(in: reopened)

        // And the leftover is collectable by the store's own reclaim path, with no bookkeeping first.
        XCTAssertGreaterThan(store.collectOrphanTemporaryFiles(), 0)
        XCTAssertEqual(try store.orphanTemporaryFiles(), [])
        XCTAssertEqual(try rowCount("asset_version", in: reopened), 0)
    }

    private static func identity(digestHex: String) throws -> AssetVersionID {
        var bytes = Data()
        var index = digestHex.startIndex
        while index < digestHex.endIndex {
            let next = digestHex.index(index, offsetBy: 2)
            guard let byte = UInt8(digestHex[index..<next], radix: 16) else {
                throw ProbeError.neverReachedBoundary("the child's digest was not hex: \(digestHex)")
            }
            bytes.append(byte)
            index = next
        }
        return AssetVersionID(
            contentDigest: try ContentDigest(bytes: bytes),
            recipeVersion: .sourceBytes
        )
    }
}
