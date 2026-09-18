import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// Shared fixtures for the PR-03 storage tests.
///
/// Every test gets a real on-disk database in `$TMPDIR` (WAL, foreign keys on), a fixed clock and a
/// temporary directory that is removed in teardown: this machine's temp footprint is controlled, and
/// no test may leak one behind.

/// A clock that never moves. Nothing here reads `Date()`.
struct FixedClock: EditorialClock {
    let now: Date
}

enum TestInstant {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func seconds(_ offset: TimeInterval) -> Date {
        epoch.addingTimeInterval(offset)
    }
}

class RuntimeV2TestCase: XCTestCase {
    private(set) var directory: URL!
    private(set) var database: RuntimeDatabase!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr03-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Locations

    /// A second database file, inside this test's directory so teardown removes it too.
    func freshLocation(named name: String) -> RuntimeDatabaseLocation {
        RuntimeDatabaseLocation(directory: directory.appendingPathComponent(name, isDirectory: true))
    }

    func freshDatabase(named name: String) throws -> RuntimeDatabase {
        try RuntimeDatabase(location: freshLocation(named: name))
    }

    // MARK: - Collaborators

    var fixedClock: FixedClock { FixedClock(now: TestInstant.epoch) }

    var engine: AdmissionEngine { AdmissionEngine(clock: fixedClock) }

    var targetStore: AcquisitionTargetStore { AcquisitionTargetStore(clock: fixedClock) }

    var ledger: AdmissionLedger { AdmissionLedger() }

    @discardableResult
    func registerTarget(
        _ identifier: String = "target-1",
        bindingRevision: UInt64 = 1,
        in database: RuntimeDatabase? = nil
    ) throws -> AcquisitionTargetSnapshot {
        try targetStore.register(
            AcquisitionTargetID(identifier),
            connectorKind: "rss",
            connectorVersion: "connector.test",
            bindingRevision: bindingRevision,
            in: database ?? self.database
        )
    }

    /// One editorial source row: memberships can only claim a source the runtime owns.
    @discardableResult
    func insertSource(
        editorialKey: String = "catalog:example",
        displayTitle: String = "Example",
        in database: RuntimeDatabase? = nil
    ) throws -> SourceID {
        try (database ?? self.database).write { database in
            try database.execute(sql: """
                INSERT INTO source (editorial_key, canonicalization_version, display_title, created_at)
                VALUES (?, 1, ?, 0)
                """, arguments: [editorialKey, displayTitle])
            return try SourceID(UInt64(database.lastInsertedRowID))
        }
    }

    // MARK: - Fixtures

    func testScope(_ scopeKey: String = "feed-1", namespace: String = "connector.test") -> ExternalScopeKey {
        ExternalScopeKey(namespace: ConnectorNamespace(namespace), scopeKey: scopeKey)
    }

    func observation(
        object: String,
        version: String? = nil,
        versionInScope versionScopeKey: String? = nil,
        scope scopeKey: String = "feed-1",
        namespace: String = "connector.test",
        precedence: PrecedenceInstruction = .makeCurrent(expectedRevision: nil),
        headline: String? = "Headline",
        excerpt: String? = nil,
        body: String? = nil,
        link: String? = nil,
        authoredAt: Date? = nil,
        confidence: IdentityConfidence = .high,
        fallbackSchemeVersion: Int? = nil,
        provider: ProviderClaim? = nil,
        memberships: [MembershipClaim] = [],
        relations: [RelationClaim] = [],
        media: [MediaCandidateClaim] = [],
        offers: [InteractionOfferClaim] = [],
        observedAt: Date? = nil
    ) throws -> AcquisitionObservation {
        let resolutionScope = testScope(scopeKey, namespace: namespace)
        let versionKey: ExternalVersionKey?
        if let version {
            let scope = versionScopeKey.map { testScope($0, namespace: namespace) } ?? resolutionScope
            versionKey = try ExternalVersionKey(scope: scope, text: version)
        } else {
            versionKey = nil
        }
        return AcquisitionObservation(
            externalKey: try ExternalObjectKey(scope: resolutionScope, text: object),
            versionKey: versionKey,
            precedence: precedence,
            payload: ObservationPayload(
                headline: headline,
                link: link.flatMap { URL(string: $0) },
                excerpt: excerpt,
                body: body,
                authoredAt: authoredAt,
                modifiedAt: nil,
                observedAt: observedAt ?? TestInstant.epoch
            ),
            identityConfidence: confidence,
            fallbackSchemeVersion: fallbackSchemeVersion,
            provider: provider,
            memberships: memberships,
            relations: relations,
            mediaCandidates: media,
            interactionOffers: offers
        )
    }

    /// Builds a batch. The connector's own `fingerprint` field is filled with a placeholder: the
    /// runtime computes the fingerprint it persists from the body (ADR-006 D2).
    func batch(
        id: String,
        generation: UInt64 = 1,
        bindingRevision: UInt64 = 1,
        leaseEpoch: UInt64 = 0,
        expectedCheckpoint: UInt64,
        observations: [AcquisitionObservation],
        evidence: [ConnectorEvidence] = [],
        advancesCheckpoint: Bool = true
    ) throws -> AcquisitionBatch {
        AcquisitionBatch(
            batchID: id,
            fingerprint: String(repeating: "0", count: 64),
            targetID: AcquisitionTargetID("target-1"),
            generation: generation,
            observations: observations,
            evidence: evidence,
            bindingRevision: bindingRevision,
            leaseEpoch: leaseEpoch,
            expectedCheckpointRevision: expectedCheckpoint,
            nextCheckpoint: advancesCheckpoint
                ? try ConnectorCheckpoint(
                    blob: Data(id.utf8),
                    serializationSchema: 1,
                    connectorVersion: "connector.test"
                )
                : nil
        )
    }

    @discardableResult
    func admit(_ batch: AcquisitionBatch, in database: RuntimeDatabase? = nil) -> AdmissionResult {
        engine.admit(batch, in: database ?? self.database)
    }

    /// Admits and requires that the batch was admitted, returning its receipt.
    @discardableResult
    func admitRequiringSuccess(
        _ batch: AcquisitionBatch,
        in database: RuntimeDatabase? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AdmissionReceipt {
        let result = admit(batch, in: database)
        guard case let .admitted(receipt) = result else {
            XCTFail("expected admission, got \(result)", file: file, line: line)
            throw XCTSkip("admission refused")
        }
        return receipt
    }

    /// The batch a target's next acquisition must carry: the durable stamp.
    func stamp(for identifier: String = "target-1", in database: RuntimeDatabase? = nil) throws -> TargetStamp {
        let snapshot = try XCTUnwrap(
            try targetStore.snapshot(for: AcquisitionTargetID(identifier), in: database ?? self.database)
        )
        return snapshot.stamp()
    }

    // MARK: - Reads used as evidence

    /// Every table whose contents a refusal must leave byte-identical.
    static let canonicalTables = [
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
        "connector_checkpoint",
        "admission_batch",
        "connector_evidence",
        "acquisition_target",
    ]

    func dump(_ tables: [String] = canonicalTables, in database: RuntimeDatabase? = nil) throws -> [String] {
        try (database ?? self.database).read { database in
            var lines: [String] = []
            for table in tables {
                let rows = try Row.fetchAll(database, sql: "SELECT * FROM \(table) ORDER BY 1")
                lines.append("\(table)=\(rows.count)")
                for row in rows {
                    let cells = Array(zip(row.columnNames, row.databaseValues))
                        .map { "\($0.0)=\($0.1)" }
                        .joined(separator: ",")
                    lines.append("  \(cells)")
                }
            }
            return lines
        }
    }

    func scalar(_ sql: String, in database: RuntimeDatabase? = nil) throws -> Int64 {
        try (database ?? self.database).read { database in
            try Int64.fetchOne(database, sql: sql) ?? 0
        }
    }

    func string(_ sql: String, in database: RuntimeDatabase? = nil) throws -> String? {
        try (database ?? self.database).read { database in
            try String.fetchOne(database, sql: sql)
        }
    }

    func rowCount(_ table: String, in database: RuntimeDatabase? = nil) throws -> Int {
        Int(try scalar("SELECT COUNT(*) FROM \(table)", in: database))
    }

    /// The state a transaction must leave behind when it never committed.
    func assertPreTransactionState(in database: RuntimeDatabase, label: String) throws {
        for table in ["origin_record", "origin_revision", "external_identity", "selection_supply", "admission_batch", "connector_evidence", "source_membership"] {
            XCTAssertEqual(try rowCount(table, in: database), 0, "\(label): \(table) must be empty")
        }
        XCTAssertEqual(
            try scalar("SELECT checkpoint_revision FROM connector_checkpoint WHERE target_id = 'target-1'", in: database),
            0,
            "\(label): the checkpoint must not advance without committed content"
        )
        XCTAssertEqual(
            try scalar("SELECT value FROM supply_generation WHERE id = 1", in: database),
            0,
            "\(label): the supply generation must not advance"
        )
        XCTAssertEqual(try rowCount("origin_search", in: database), 0, "\(label): no projection row")
    }

    // MARK: - Constraint helpers

    func assertConstraintFailure(
        _ sql: String,
        _ arguments: StatementArguments = [],
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try database.write { database in try database.execute(sql: sql, arguments: arguments) },
            file: file,
            line: line
        ) { error in
            XCTAssertTrue(
                "\(error)".contains(expected),
                "expected a failure containing '\(expected)', got: \(error)",
                file: file,
                line: line
            )
        }
    }

    func assertCheckFailure(
        _ sql: String,
        _ arguments: StatementArguments = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertConstraintFailure(sql, arguments, containing: "CHECK constraint failed", file: file, line: line)
    }

    func assertUniqueFailure(
        _ sql: String,
        _ arguments: StatementArguments = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertConstraintFailure(sql, arguments, containing: "UNIQUE constraint failed", file: file, line: line)
    }

    func assertForeignKeyFailure(
        _ sql: String,
        _ arguments: StatementArguments = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertConstraintFailure(sql, arguments, containing: "FOREIGN KEY constraint failed", file: file, line: line)
    }
}
