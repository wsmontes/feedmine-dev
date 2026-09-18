import Foundation
import FeedDomain
import FeedStorage
import FeedMedia

// FeedStorageProbe — the auxiliary process PR-16's crash class needs.
//
// Plan §15.1 requires a *process* terminated between commit, checkpoint and file write, and says
// explicitly that an exception thrown inside a transaction does not substitute for it. This executable
// is that process and nothing else: it reaches one boundary, announces it on stdout, and then holds,
// so the parent can prove it was alive when the signal arrived instead of assuming it was.
//
// Three boundaries, three things the reopen must show:
//
//   commit      the write transaction committed, and nothing after it ran
//   checkpoint  one batch committed, a second one is holding an open write transaction
//   fileWrite   the temporary asset file is written and fsynced, and the immutable move never happened
//
// It is a test helper rather than a module of the architecture graph: nothing links against it, and it
// is in neither plan §3's dependency table nor the boundary gate's rules — which is why it lives under
// `Probes/` and not under `Sources/`, where the gate rightly refuses a directory no rule governs. It
// may see FeedStorage and FeedMedia together for one reason: the file-write boundary has to place the
// temporary file where `LocalAssetStore` looks for orphans, so the parent can prove the store's own
// reclaim path collects a real crash orphan.
//
// Usage: FeedStorageProbe <commit|checkpoint|fileWrite> <directory>
// It never exits on its own after reaching the boundary; the caller kills it.

private struct ProbeClock: EditorialClock {
    let now: Date
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("probe: " + message + "\n").utf8))
    exit(2)
}

/// The marker the parent waits for. One line, on stdout, flushed: a pipe that buffers would make the
/// parent's "reached the boundary" and "the process is still alive" indistinguishable.
private func announce(_ boundary: String, _ detail: String) {
    print("BOUNDARY \(boundary) \(detail)")
    fflush(stdout)
}

private func holdForever() -> Never {
    while true {
        Thread.sleep(forTimeInterval: 60)
    }
}

private let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: FeedStorageProbe <commit|checkpoint|fileWrite> <directory>")
}
private let boundary = arguments[1]
private let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
private let clock = ProbeClock(now: Date(timeIntervalSince1970: 1_700_000_000))

private let database: RuntimeDatabase
do {
    database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
} catch {
    fail("could not open the runtime database at \(directory.path): \(error)")
}

private let targetID = AcquisitionTargetID("target-probe")
private let scope = ExternalScopeKey(namespace: ConnectorNamespace("probe"), scopeKey: "feed-1")

private func registerTarget() throws -> TargetStamp {
    let store = AcquisitionTargetStore(clock: clock)
    if let existing = try store.snapshot(for: targetID, in: database) {
        return existing.stamp()
    }
    let snapshot = try store.register(
        targetID,
        connectorKind: "probe",
        connectorVersion: "probe.1",
        bindingRevision: 1,
        in: database
    )
    return snapshot.stamp()
}

private func batch(id: String, expectedCheckpoint: UInt64, object: String) throws -> AcquisitionBatch {
    let observation = AcquisitionObservation(
        externalKey: try ExternalObjectKey(scope: scope, text: object),
        versionKey: nil,
        precedence: .makeCurrent(expectedRevision: nil),
        payload: ObservationPayload(
            headline: "Probe \(object)",
            link: URL(string: "https://example.test/\(object)"),
            excerpt: nil,
            body: nil,
            authoredAt: nil,
            modifiedAt: nil,
            observedAt: clock.now
        ),
        identityConfidence: .high,
        fallbackSchemeVersion: nil,
        provider: nil,
        memberships: [],
        relations: [],
        mediaCandidates: [],
        interactionOffers: []
    )
    return AcquisitionBatch(
        batchID: id,
        fingerprint: String(repeating: "0", count: 64),
        targetID: targetID,
        generation: 1,
        observations: [observation],
        evidence: [],
        bindingRevision: 1,
        leaseEpoch: 0,
        expectedCheckpointRevision: expectedCheckpoint,
        nextCheckpoint: try ConnectorCheckpoint(
            blob: Data("checkpoint-\(id)".utf8),
            serializationSchema: 1,
            connectorVersion: "probe.1"
        )
    )
}

private func admit(_ batch: AcquisitionBatch) throws -> AdmissionReceipt {
    switch AdmissionEngine(clock: clock).admit(batch, in: database) {
    case let .admitted(receipt):
        return receipt
    case let .duplicate(batchID):
        do {
            guard let stored = try AdmissionLedger().receipt(forBatchID: batchID, in: database) else {
                fail("duplicate batch \(batchID) has no stored receipt")
            }
            return stored
        } catch {
            fail("could not read the receipt of \(batchID): \(error)")
        }
    case let .batchConflict(batchID):
        fail("batch \(batchID) conflicts with a stored body")
    case let .staleTarget(generation):
        fail("stale target generation \(generation)")
    case let .staleCheckpoint(expected, actual):
        fail("stale checkpoint: expected \(expected), stored \(actual)")
    case let .identityConflict(key):
        fail("identity conflict for \(key)")
    case let .invalidObservation(reason):
        fail("invalid observation: \(reason)")
    case let .storageFailure(reason):
        fail("storage failure: \(reason)")
    }
}

do {
    switch boundary {
    case "commit":
        let stamp = try registerTarget()
        let receipt = try admit(try batch(id: "batch-commit", expectedCheckpoint: stamp.checkpointRevision, object: "committed"))
        // The transaction has committed and nothing after it has run: no notification, no follow-up
        // write, no in-memory accounting. The parent kills the process here.
        announce(boundary, "batch=\(receipt.batchID) checkpoint=\(receipt.checkpointRevision) supply=\(receipt.supplyGeneration)")

    case "checkpoint":
        let stamp = try registerTarget()
        let committed = try admit(try batch(id: "batch-1", expectedCheckpoint: stamp.checkpointRevision, object: "committed"))
        // A second batch's work is written but not committed, holding SQLite's write lock. This is the
        // state a process is in mid-Admission, and the checkpoint advance is part of it.
        try database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
            try db.execute(sql: """
                INSERT INTO external_identity (
                    connector_namespace, scope_key, key_kind, external_key, key_digest,
                    origin_record_id, identity_confidence, first_observed_at, last_observed_at
                ) VALUES ('probe', 'feed-1', 'object', ?, zeroblob(16), NULL, 'high', 0, 0)
                """, arguments: [Data("held".utf8)])
            let identityID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO origin_record (
                    connector_namespace, scope_key, primary_identity_id, first_observed_at, last_observed_at
                ) VALUES ('probe', 'feed-1', ?, 0, 0)
                """, arguments: [identityID])
            let recordID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO origin_revision (
                    origin_record_id, payload_digest, headline, observed_at, created_at,
                    identity_confidence
                ) VALUES (?, ?, 'Probe held', 0, 0, 'high')
                """, arguments: [recordID, Data("held-digest".utf8)])
            try db.execute(sql: """
                INSERT INTO admission_batch (
                    batch_id, target_id, target_generation, binding_revision, lease_epoch, fingerprint,
                    checkpoint_expected, checkpoint_written, observation_count, result, receipt_blob,
                    committed_at
                ) VALUES ('batch-2', 'target-probe', 1, 1, 0, ?, ?, NULL, 1, 'admitted', x'00', 0)
                """, arguments: [String(repeating: "0", count: 64), committed.checkpointRevision])
            try db.execute(sql: """
                UPDATE connector_checkpoint
                SET checkpoint_revision = ?, checkpoint_blob = x'02', updated_at = 0
                WHERE target_id = 'target-probe'
                """, arguments: [committed.checkpointRevision + 1])
            let held: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-probe'"
            ) ?? -1
            announce(boundary, "committed_checkpoint=\(committed.checkpointRevision) uncommitted_checkpoint=\(held)")
            holdForever()
        }

    case "fileWrite":
        // The temporary file of an asset commit: written, fsynced, and never moved into place. The
        // store's own path helpers are what place it where its reclaim path looks.
        let assets = LocalAssetStore(rootDirectory: directory.appendingPathComponent("Assets", isDirectory: true))
        let bytes = Data(repeating: 0x7A, count: 4_096)
        let identity = AssetVersionID(
            contentDigest: ContentDigest.sha256(bytes),
            recipeVersion: .sourceBytes
        )
        let destination = assets.fileURL(for: identity)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("\(LocalAssetStore.temporaryPrefix)probe")
        try bytes.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        announce(
            boundary,
            "asset=\(identity.contentDigest.hex) recipe=1 bytes=\(bytes.count) temporary=\(temporary.lastPathComponent)"
        )

    default:
        fail("unknown boundary '\(boundary)'")
    }
} catch {
    fail("\(boundary) failed: \(error)")
}

holdForever()
