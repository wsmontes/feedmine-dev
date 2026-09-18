import XCTest
import GRDB
import FeedDomain
import FeedStorage
import FeedRuntime

/// Shared fixtures for the PR-10 acquisition tests.
///
/// Every test gets a real on-disk runtime database in `$TMPDIR` (WAL, foreign keys on), an injected
/// clock that never moves and a temporary directory removed in teardown: nothing here sleeps, reads
/// `Date()` or touches the network.

/// A clock that never moves.
struct FixtureClock: EditorialClock {
    let now: Date
}

enum FixtureInstant {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func seconds(_ offset: TimeInterval) -> Date {
        epoch.addingTimeInterval(offset)
    }
}

/// The namespace every fixture connector uses. A connector's namespace is its own scope, never an
/// editorial Source identity (ADR-003 D8).
enum FixtureScope {
    static let namespace = ConnectorNamespace("fixture.connector")

    static func key(_ scopeKey: String = "fixture-feed") -> ExternalScopeKey {
        ExternalScopeKey(namespace: namespace, scopeKey: scopeKey)
    }
}

enum FixtureConnectorError: Error, Equatable, Sendable {
    case transport(String)
    case misconfigured(String)
}

/// A relation a fixture observation claims.
struct FixtureRelation: Hashable, Sendable {
    let verb: ContentRelation.Verb
    let object: String
}

/// Everything a fixture observation carries beyond its identity.
///
/// The shape is shared by both fixtures on purpose: the second paradigm has to be the same content
/// delivered through a different connector, not different content that happens to be admitted.
struct FixtureObservationShape: Hashable, Sendable {
    var memberships: [SourceID] = []
    var relations: [FixtureRelation] = []
    var offerKinds: [String] = []
    var mediaRoles: [MediaRole] = []
    var providerKey: String?
    var excerpt: String?
    /// Body text of this many bytes: the knob that makes a batch cost real bytes against a purpose's
    /// byte budget.
    var bodyPadding: Int = 0

    static let plain = FixtureObservationShape()
}

/// The version rule both fixtures use: the n-th emission of one object is that object's version `n`.
///
/// A version key identifies a *representation*, so it is unique in the connector's scope across
/// objects as well — two objects may never share one, and the key embeds the object it belongs to.
/// Every fixture connector decides precedence from its own protocol knowledge; the runtime never
/// interprets the key (ADR-003 D9, ADR-006 D3).
enum FixtureVersioning {
    static func versionKey(object: String, emission: Int) -> String { "\(object)#r\(emission)" }

    /// The version key of a representation the connector knows is older than the current one. It is
    /// deliberately not a parseable number of the same series: a version key is opaque, and only the
    /// connector's instruction makes it historical (ADR-003 D9).
    static func olderVersionKey(object: String) -> String { "\(object)#r-anterior" }
}

/// One fixture connector's emission counter per external object.
struct FixtureVersionLadder: Sendable {
    private var emissions: [String: Int] = [:]

    mutating func next(for object: String) -> String {
        let emission = (emissions[object] ?? 0) + 1
        emissions[object] = emission
        return FixtureVersioning.versionKey(object: object, emission: emission)
    }
}

/// Batch identity shared by both fixtures.
///
/// The same content delivered by a finite connector and by a streaming connector produces the same
/// batch id, the same proposed checkpoint and the same evidence, so the canonical state both runs
/// leave behind can be compared row by row. That comparison is the second-paradigm proof.
enum FixtureBatchIdentity {
    static let connectorVersion = "fixture.connector.v1"

    static func batchID(target: AcquisitionTargetID, generation: UInt64, sequence: Int) -> String {
        "\(target.rawValue)#\(generation)#batch-\(sequence)"
    }

    static func checkpointToken(sequence: Int) -> Data {
        Data("batch-\(sequence)".utf8)
    }

    /// A deterministic digest of the observation body. Admission computes its own fingerprint (the
    /// runtime cannot trust a value it cannot recompute), so this one only has to be stable across
    /// the two fixtures, which is why it is an explicit algorithm rather than `hashValue`.
    static func fingerprint(of observations: [AcquisitionObservation]) -> String {
        var material = Data()
        for observation in observations {
            material.append(observation.externalKey.bytes)
            material.append(Data([0]))
            material.append(observation.versionKey?.bytes ?? Data())
            material.append(Data([0]))
            material.append(Data((observation.payload.headline ?? "").utf8))
        }
        return FNV1a64.hex(material)
    }

    /// One audit record per observation. It is opaque evidence: nothing downstream decodes it, and
    /// deleting it would change no selection or publication output (ADR-005 D1).
    static func evidence(for batchID: String, observations: [AcquisitionObservation]) -> [ConnectorEvidence] {
        observations.enumerated().map { pair in
            let material = Data("\(batchID)|\(pair.offset)".utf8) + pair.element.externalKey.bytes
            return ConnectorEvidence(
                kind: .parsedEntry,
                digest: FNV1a64.hex(material),
                bytes: pair.element.externalKey.bytes
            )
        }
    }

    /// The checkpoint the fixtures propose for one batch of the sequence. It is what a test compares
    /// the durable checkpoint against without hand-building the schema version and connector version.
    static func proposedCheckpoint(sequence: Int) throws -> ConnectorCheckpoint {
        try ConnectorCheckpoint(
            blob: checkpointToken(sequence: sequence),
            serializationSchema: 1,
            connectorVersion: connectorVersion
        )
    }

    /// The one batch builder both fixtures use, and the one a test can use to predict what a page
    /// costs before it is pulled.
    ///
    /// It takes every stamp field from the request: the connector cannot know the binding revision,
    /// the lease epoch or the checkpoint revision a batch is produced against, and it must not
    /// invent them (ADR-006 D1).
    static func makeBatch(
        sequence: Int,
        observations: [AcquisitionObservation],
        request: AcquisitionPull,
        advanceCheckpoint: Bool = true
    ) throws -> AcquisitionBatch {
        let batchID = batchID(
            target: request.targetID,
            generation: request.generation,
            sequence: sequence
        )
        return AcquisitionBatch(
            batchID: batchID,
            fingerprint: fingerprint(of: observations),
            targetID: request.targetID,
            generation: request.generation,
            observations: observations,
            evidence: evidence(for: batchID, observations: observations),
            bindingRevision: request.bindingRevision,
            leaseEpoch: request.leaseEpoch,
            expectedCheckpointRevision: request.checkpointRevision,
            nextCheckpoint: try advanceCheckpoint ? proposedCheckpoint(sequence: sequence) : nil
        )
    }
}

/// Fixture-local FNV-1a. No `Hasher`, no `hashValue`: Swift seeds those per process, and a fixture
/// that produced different bytes every launch could not prove that two runs agree.
enum FNV1a64 {
    static func hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// The runtime tables that ingest content. Two runs over the same content must leave these
/// byte-identical; a refusal must leave them untouched.
enum RuntimeTableSet {
    static let canonical: [String] = [
        "acquisition_target",
        "connector_checkpoint",
        "admission_batch",
        "connector_evidence",
        "source",
        "provider",
        "origin_record",
        "origin_revision",
        "external_identity",
        "identity_conflict",
        "source_membership",
        "provider_attribution",
        "content_relation",
        "media_candidate",
        "interaction_offer",
        "selection_supply",
        "supply_generation",
    ]
}

class AcquisitionTestCase: XCTestCase {
    private(set) var directory: URL!
    private(set) var database: RuntimeDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr10-\(UUID().uuidString)", isDirectory: true)
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

    /// A second database inside this test's directory, so teardown removes it too.
    func freshDatabase(named name: String) throws -> RuntimeDatabase {
        try RuntimeDatabase(location: RuntimeDatabaseLocation(
            directory: directory.appendingPathComponent(name, isDirectory: true)
        ))
    }

    // MARK: - Collaborators

    var clock: FixtureClock { FixtureClock(now: FixtureInstant.epoch) }

    var engine: AdmissionEngine { AdmissionEngine(clock: clock) }

    var targetStore: AcquisitionTargetStore { AcquisitionTargetStore(clock: clock) }

    func deadline(_ offset: TimeInterval = 60) -> Date {
        FixtureInstant.seconds(offset)
    }

    // MARK: - Durable fixtures

    @discardableResult
    func registerTarget(
        _ identifier: String = "target-1",
        connectorKind: String = "fixture",
        bindingRevision: UInt64 = 1,
        in database: RuntimeDatabase? = nil
    ) throws -> AcquisitionTargetSnapshot {
        try targetStore.register(
            AcquisitionTargetID(identifier),
            connectorKind: connectorKind,
            connectorVersion: FixtureBatchIdentity.connectorVersion,
            bindingRevision: bindingRevision,
            in: database ?? self.database
        )
    }

    /// One editorial source row: a membership can only claim a source the runtime owns.
    @discardableResult
    func insertSource(
        _ editorialKey: String,
        title: String = "Fixture Source",
        in database: RuntimeDatabase? = nil
    ) throws -> SourceID {
        try (database ?? self.database).write { database in
            try database.execute(sql: """
                INSERT INTO source (editorial_key, canonicalization_version, display_title, created_at)
                VALUES (?, 1, ?, 0)
                """, arguments: [editorialKey, title])
            return try SourceID(UInt64(database.lastInsertedRowID))
        }
    }

    /// The operational target derived from the durable row. `bindingRevision` can be overridden to
    /// build a *stale* catalogue on purpose.
    func acquisitionTarget(
        _ identifier: String = "target-1",
        connectorKind: String = "fixture",
        bindingRevision: UInt64? = nil,
        in database: RuntimeDatabase? = nil
    ) throws -> AcquisitionTarget {
        let snapshot = try XCTUnwrap(
            try targetStore.snapshot(for: AcquisitionTargetID(identifier), in: database ?? self.database)
        )
        return AcquisitionTarget(
            id: snapshot.targetID,
            connectorKind: connectorKind,
            generation: snapshot.generation,
            bindingRevision: bindingRevision ?? snapshot.bindingRevision
        )
    }

    func targetSnapshot(_ identifier: String = "target-1") throws -> AcquisitionTargetSnapshot {
        try XCTUnwrap(try targetStore.snapshot(for: AcquisitionTargetID(identifier), in: database))
    }

}

// The observation fixture is a free function: the fixture connectors are actors in this same test
// module and build their own observations through it.

/// One translated observation, built the same way by every fixture.
///
/// It is deliberately not a member of the test case: the fixture connectors are actors and build
/// their observations themselves, and a test that hands a fixture into a hook cannot capture an
/// XCTestCase at all.
func fixtureObservation(
    object: String,
    version: String?,
    precedence: PrecedenceInstruction = .makeCurrent(expectedRevision: nil),
    shape: FixtureObservationShape = .plain,
    headline: String? = nil,
    scope: ExternalScopeKey = FixtureScope.key(),
    observedAt: Date = FixtureInstant.epoch
) throws -> AcquisitionObservation {
        let provider: ProviderClaim?
        if let providerKey = shape.providerKey {
            provider = try ProviderClaim(
                namespace: scope.namespace,
                providerKey: providerKey,
                displayName: "Fixture Provider",
                role: .primary
            )
        } else {
            provider = nil
        }
        return AcquisitionObservation(
            externalKey: try ExternalObjectKey(scope: scope, text: object),
            versionKey: try version.map { try ExternalVersionKey(scope: scope, text: $0) },
            precedence: precedence,
            payload: ObservationPayload(
                headline: headline ?? object,
                link: URL(string: "https://fixture.invalid/\(object)"),
                excerpt: shape.excerpt,
                body: shape.bodyPadding > 0 ? String(repeating: "x", count: shape.bodyPadding) : nil,
                authoredAt: nil,
                modifiedAt: nil,
                observedAt: observedAt
            ),
            provider: provider,
            memberships: try shape.memberships.map { sourceID in
                try MembershipClaim(sourceID: sourceID, membershipKind: "fixture")
            },
            relations: try shape.relations.map { relation in
                RelationClaim(
                    verb: relation.verb,
                    target: try ExternalObjectKey(scope: scope, text: relation.object)
                )
            },
            mediaCandidates: try shape.mediaRoles.enumerated().map { pair in
                try MediaCandidateClaim(
                    role: pair.element,
                    resourceURL: "https://fixture.invalid/media/\(object)/\(pair.offset)",
                    position: pair.offset
                )
            },
            interactionOffers: try shape.offerKinds.enumerated().map { pair in
                try InteractionOfferClaim(kind: pair.element, handle: "fixture://\(pair.element)", position: pair.offset)
            }
        )
}

extension AcquisitionTestCase {
    // MARK: - Reads used as evidence

    /// Every canonical table, in a deterministic order, with every column spelled out. Two runs that
    /// ingested the same content must produce the same lines; a refusal must leave them identical.
    ///
    /// - Parameter tables: which tables to dump. A refusal test excludes `acquisition_target`,
    ///   because the revocation it observed is *recorded* there; everything Admission owns, the
    ///   checkpoint included, must be untouched.
    func dump(
        _ tables: [String] = RuntimeTableSet.canonical,
        in database: RuntimeDatabase? = nil
    ) throws -> [String] {
        try (database ?? self.database).read { database in
            var lines: [String] = []
            for table in tables where table != "origin_search" {
                let rows = try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY 1")
                lines.append("\(table)=\(rows.count)")
                for row in rows {
                    let cells = Array(zip(row.columnNames, row.databaseValues))
                        .map { "\($0.0)=\($0.1)" }
                        .joined(separator: ",")
                    lines.append("  \(cells)")
                }
            }
            if tables.contains("origin_search") {
                let search = try Row.fetchAll(database, sql: "SELECT rowid, projection FROM origin_search ORDER BY rowid")
                lines.append("origin_search=\(search.count)")
                for row in search {
                    lines.append("  rowid=\(row["rowid"] as Int64),projection=\(row["projection"] as String? ?? "")")
                }
            }
            return lines
        }
    }

    /// The tables a refusal must leave byte-identical. `acquisition_target` is excluded because the
    /// revocation is recorded there, and `origin_search` is a projection of `origin_revision`.
    static let contentTables = RuntimeTableSet.canonical.filter { $0 != "acquisition_target" }

    func rowCount(_ table: String, in database: RuntimeDatabase? = nil) throws -> Int {
        Int(try scalar("SELECT COUNT(*) FROM \(table)", in: database))
    }

    func string(_ sql: String, in database: RuntimeDatabase? = nil) throws -> String? {
        try (database ?? self.database).read { database in
            try String.fetchOne(database, sql: sql)
        }
    }

    func scalar(_ sql: String, in database: RuntimeDatabase? = nil) throws -> Int64 {
        try (database ?? self.database).read { database in
            try Int64.fetchOne(database, sql: sql) ?? 0
        }
    }

    /// The durable checkpoint revision of one target. A missing row fails the test instead of
    /// reading as zero: "no checkpoint at all" and "checkpoint at the origin" are different facts.
    func checkpointRevision(
        _ identifier: String = "target-1",
        in database: RuntimeDatabase? = nil
    ) throws -> UInt64 {
        let value = try (database ?? self.database).read { database in
            try Int64.fetchOne(
                database,
                sql: "SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = ?",
                arguments: [identifier]
            )
        }
        return UInt64(try XCTUnwrap(value, "no connector_checkpoint row for target \(identifier)"))
    }

    func storedCheckpoint(_ identifier: String = "target-1") throws -> ConnectorCheckpoint? {
        try targetSnapshot(identifier).checkpoint
    }
}

/// A slot for a task started from inside a connector hook.
///
/// A hook cannot capture the test case (XCTestCase is not `Sendable`), so anything the hook has to
/// start or observe travels through a small actor like this one.
actor TaskSlot {
    private var task: Task<AcquisitionRunSummary, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func start(_ operation: @escaping @Sendable () async -> AcquisitionRunSummary) {
        task = Task { await operation() }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    /// Waits until the hook started the task, then waits for its result.
    func value() async -> AcquisitionRunSummary? {
        while task == nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        return await task?.value
    }
}

/// Cancels a run once the test has handed the task over. The hook that triggers the cancellation may
/// run before the test holds the handle, so the hook waits for it instead of racing it.
actor CancellationSlot {
    private var task: Task<AcquisitionRunSummary, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold(_ task: Task<AcquisitionRunSummary, Never>) {
        self.task = task
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func cancelNow() async {
        while task == nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        task?.cancel()
    }
}

/// Records values observed from inside a hook.
actor ValueProbe<Value: Sendable> {
    private var values: [Value] = []

    func record(_ value: Value) {
        values.append(value)
    }

    func recorded() -> [Value] { values }
}
