import XCTest
import GRDB
import FeedDomain
import FeedRuntime
import FeedStorage

/// Shared fixtures for the PR-05 selection tests.
///
/// Every test gets a real on-disk runtime database in `$TMPDIR` (WAL, foreign keys on) and a fixed
/// injected clock; nothing here reads `Date()`, sleeps or opens a socket, and teardown removes the
/// temporary directory.
///
/// Supply is built through the real Admission path rather than by inserting canonical rows by hand: the
/// selection engine is the unit under test and it must see the projection Admission actually produces.
/// The only direct SQL is the `source` row (no public API allocates one yet) and the states Admission
/// cannot reach (a revoked record, a split cluster, the row counts a test compares).
struct SelectionClock: EditorialClock {
    let now: Date
}

enum SelectionInstant {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func offset(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// One content item a fixture admits.
struct SelectionFeedObject {
    var objectKey: String
    var scopeKey: String = "feed-1"
    var versionKey: String?
    var headline: String? = "Headline"
    var summary: String?
    var authoredAt: Date?
    var observedAt: Date = SelectionInstant.epoch
    var provider: (namespace: String, key: String)?
    var mediaRoles: [MediaRole] = []
    /// `(verb, targetObjectKey)` pairs; resolved against records admitted earlier in the same batch.
    var relations: [(verb: String, target: String)] = []
}

/// One runtime database with the collaborators a fixture needs to admit supply into it.
struct SelectionRuntime {
    let database: RuntimeDatabase
    let targetStore: AcquisitionTargetStore
    let admissionEngine: AdmissionEngine
    let targetID: AcquisitionTargetID
}

class SelectionTestCase: XCTestCase {
    private(set) var directory: URL!
    private(set) var primary: SelectionRuntime!
    /// The instant the injected clock reports. Tests move it explicitly; nothing moves on its own.
    var clockDate: Date = SelectionInstant.epoch
    private var batchCounter = 0

    var database: RuntimeDatabase { primary.database }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("feedruntime-pr05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        primary = try makeRuntime(database: database, named: "target-selection")
    }

    override func tearDownWithError() throws {
        primary = nil
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Collaborators

    var clock: SelectionClock { SelectionClock(now: clockDate) }
    var resolver: FeedPlanResolver { FeedPlanResolver(clock: clock) }
    var engine: SelectionEngine { SelectionEngine() }
    var sequencer: EditorialSequencer { EditorialSequencer() }

    @discardableResult
    func makeRuntime(database: RuntimeDatabase, named target: String) throws -> SelectionRuntime {
        let store = AcquisitionTargetStore(clock: clock)
        let engine = AdmissionEngine(clock: clock)
        let targetID = AcquisitionTargetID(target)
        _ = try store.register(
            targetID,
            connectorKind: "fixture",
            connectorVersion: "fixture.test",
            in: database
        )
        return SelectionRuntime(
            database: database,
            targetStore: store,
            admissionEngine: engine,
            targetID: targetID
        )
    }

    /// A second, independent runtime database inside this test's temporary directory, so teardown
    /// removes it too.
    func makeSecondary(named name: String) throws -> SelectionRuntime {
        let location = RuntimeDatabaseLocation(
            directory: directory.appendingPathComponent(name, isDirectory: true)
        )
        return try makeRuntime(database: try RuntimeDatabase(location: location), named: "target-\(name)")
    }

    // MARK: - Sources

    /// A durable editorial key. Sources are the plan's unit of selection, so tests name them the way a
    /// plan does.
    func sourceKey(_ catalogIdentity: String, version: Int = 1) throws -> EditorialSourceKey {
        try EditorialSourceKey(catalogIdentity: catalogIdentity, canonicalizationVersion: version)
    }

    /// Creates the `source` row and returns its runtime id. `source` has no public allocation API yet,
    /// so the fixture writes the row the runtime schema defines.
    @discardableResult
    func insertSource(
        _ catalogIdentity: String,
        version: Int = 1,
        displayTitle: String = "Source",
        into runtime: SelectionRuntime? = nil
    ) throws -> SourceID {
        let raw = try fixtureRuntime(runtime).database.write { database -> Int64 in
            try database.execute(sql: """
                INSERT INTO source (editorial_key, canonicalization_version, display_title, created_at)
                VALUES (?, ?, ?, 0)
                """, arguments: [catalogIdentity, version, displayTitle])
            return database.lastInsertedRowID
        }
        return try SourceID(UInt64(raw))
    }

    /// The runtime a fixture helper works against: the caller's, or this test's primary database.
    private func fixtureRuntime(_ candidate: SelectionRuntime?) -> SelectionRuntime {
        candidate ?? primary
    }

    // MARK: - Admission fixtures

    @discardableResult
    func admit(
        _ objects: [SelectionFeedObject],
        source: SourceID,
        into runtime: SelectionRuntime? = nil,
        scopeKey: String = "feed-1",
        namespace: String = "connector.test",
        batchID: String? = nil
    ) throws -> AdmissionReceipt {
        let runtime: SelectionRuntime = runtime ?? primary
        batchCounter += 1
        let identifier = batchID ?? "batch-\(batchCounter)"
        let scope = ExternalScopeKey(namespace: ConnectorNamespace(namespace), scopeKey: scopeKey)
        let observations = try objects.map { object -> AcquisitionObservation in
            let objectScope = object.scopeKey == scopeKey
                ? scope
                : ExternalScopeKey(namespace: ConnectorNamespace(namespace), scopeKey: object.scopeKey)
            let relations = try object.relations.map { relation in
                RelationClaim(
                    verb: ContentRelation.Verb(rawValue: relation.verb) ?? .repostOf,
                    target: try ExternalObjectKey(scope: objectScope, text: relation.target)
                )
            }
            let media = try object.mediaRoles.enumerated().map { position, role in
                try MediaCandidateClaim(
                    role: role,
                    resourceURL: "https://example.test/\(object.objectKey)",
                    position: position
                )
            }
            return AcquisitionObservation(
                externalKey: try ExternalObjectKey(scope: objectScope, text: object.objectKey),
                versionKey: try object.versionKey.map {
                    try ExternalVersionKey(scope: objectScope, text: $0)
                },
                precedence: .makeCurrent(expectedRevision: nil),
                payload: ObservationPayload(
                    headline: object.headline,
                    link: nil,
                    excerpt: object.summary,
                    body: nil,
                    authoredAt: object.authoredAt,
                    modifiedAt: nil,
                    observedAt: object.observedAt
                ),
                provider: try object.provider.map { provider in
                    try ProviderClaim(
                        namespace: ConnectorNamespace(provider.namespace),
                        providerKey: provider.key,
                        displayName: provider.key,
                        role: .primary
                    )
                },
                memberships: [try MembershipClaim(sourceID: source, membershipKind: "editorial")],
                relations: relations,
                mediaCandidates: media,
                interactionOffers: []
            )
        }
        let snapshot = try XCTUnwrap(
            try runtime.targetStore.snapshot(for: runtime.targetID, in: runtime.database)
        )
        let batch = AcquisitionBatch(
            batchID: identifier,
            fingerprint: String(repeating: "0", count: 64),
            targetID: snapshot.targetID,
            generation: snapshot.generation,
            observations: observations,
            bindingRevision: snapshot.bindingRevision,
            leaseEpoch: snapshot.leaseEpoch,
            expectedCheckpointRevision: snapshot.checkpointRevision,
            nextCheckpoint: try ConnectorCheckpoint(
                blob: Data(identifier.utf8),
                serializationSchema: 1,
                connectorVersion: "fixture.test"
            )
        )
        let result = runtime.admissionEngine.admit(batch, in: runtime.database)
        guard case let .admitted(receipt) = result else {
            XCTFail("fixture admission refused: \(result)")
            throw XCTSkip("fixture admission refused")
        }
        return receipt
    }

    /// Admits `count` items from one source, named `<prefix>-0`...`<prefix>-<count-1>`.
    @discardableResult
    func admitItems(
        _ count: Int,
        prefix: String,
        source: SourceID,
        provider: (namespace: String, key: String)? = nil,
        mediaRoles: [MediaRole] = [],
        authoredAt: (Int) -> Date? = { _ in nil },
        into runtime: SelectionRuntime? = nil
    ) throws -> AdmissionReceipt {
        let objects = (0..<count).map { index in
            SelectionFeedObject(
                objectKey: "\(prefix)-\(index)",
                summary: nil,
                authoredAt: authoredAt(index),
                observedAt: SelectionInstant.offset(Double(index)),
                provider: provider,
                mediaRoles: mediaRoles
            )
        }
        return try admit(objects, source: source, into: runtime)
    }

    func stableKey(_ objectKey: String, scopeKey: String = "feed-1", namespace: String = "connector.test") -> SupplyStableKey {
        SupplyStableKey(
            namespace: ConnectorNamespace(namespace),
            scopeKey: scopeKey,
            objectKeyBytes: Data(objectKey.utf8)
        )
    }

    func recordID(
        _ objectKey: String,
        scopeKey: String = "feed-1",
        namespace: String = "connector.test",
        in runtime: SelectionRuntime? = nil
    ) throws -> Int64 {
        try fixtureRuntime(runtime).database.read { database in
            try XCTUnwrap(
                try Int64.fetchOne(database, sql: """
                    SELECT o.id FROM external_identity e
                    JOIN origin_record o ON o.primary_identity_id = e.id
                    WHERE e.connector_namespace = ? AND e.scope_key = ? AND e.external_key = ?
                    """, arguments: [namespace, scopeKey, Data(objectKey.utf8)]),
                "no record for \(objectKey)"
            )
        }
    }

    /// A state Admission does not produce yet: content the upstream removed or revoked (ADR-003 D13).
    func setAvailability(_ availability: String, objectKey: String, in runtime: SelectionRuntime? = nil) throws {
        let recordID = try recordID(objectKey, in: runtime)
        try fixtureRuntime(runtime).database.write { database in
            try database.execute(
                sql: "UPDATE origin_record SET availability = ? WHERE id = ?",
                arguments: [availability, recordID]
            )
        }
    }

    /// Drops every declared relation: the reversible half of ADR-003 D13 (`ContentEquivalence.split()` at
    /// the persistence boundary). Nothing else is touched.
    func dropAllRelations(in runtime: SelectionRuntime? = nil) throws {
        try fixtureRuntime(runtime).database.write { database in
            try database.execute(sql: "DELETE FROM content_relation")
        }
    }

    /// Row counts of the tables selection must never write. `[String: Int]` is compared as a value, so it
    /// decides no order.
    func tableCounts(in runtime: SelectionRuntime? = nil) throws -> [String: Int] {
        try fixtureRuntime(runtime).database.read { database in
            var counts: [String: Int] = [:]
            for table in [
                "origin_record",
                "origin_revision",
                "external_identity",
                "selection_supply",
                "source_membership",
                "content_relation",
                "supply_generation",
            ] {
                counts[table] = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return counts
        }
    }

    // MARK: - Plans

    /// A plan whose declared policy versions always match its embedded values. Tests vary the values they
    /// care about and leave the rest at the plan's initial tuning.
    func makePlan(
        surface: ContextKey.Surface = .main,
        scopeKey: String = "main",
        planIdentity: String = "MainFeedPlan",
        sourceSelection: [SourceSelection] = [],
        contentFilters: [ContentFilter] = [],
        restrictions: ContentRestrictionPolicy = .none,
        preferences: ContentPreferencePolicy = .none,
        budget: SelectionBudget = .initial,
        historyScope: HistoryScope = .main,
        applySeen: Bool = true,
        historyPolicyVersion: Int = 1,
        repetition: RepetitionPolicy = .initial,
        clockPolicy: ClockPolicy = .fiveMinutes,
        freshness: FreshnessDemand = .any,
        exploration: ExplorationPolicy = .disabled,
        blocked: [SupplyStableKey] = [],
        subjectSelection: SubjectSelection? = nil,
        languages: [String] = [],
        taxonomyURLs: [String] = [],
        presetIdentity: String = "preset-default",
        region: String = "",
        contentType: String = "",
        mood: String = ""
    ) throws -> FeedPlan {
        let historyPolicy = try HistoryPolicy(
            scope: historyScope,
            applySeen: applySeen,
            showOverlay: true,
            autoExclude: applySeen,
            version: historyPolicyVersion
        )
        let policies = try [
            PolicyVersion(policyID: .budget, version: budget.version),
            PolicyVersion(policyID: .contentRestrictions, version: restrictions.version),
            PolicyVersion(policyID: .preferences, version: preferences.version),
            PolicyVersion(policyID: .history, version: historyPolicy.version),
            PolicyVersion(policyID: .repetition, version: repetition.version),
            PolicyVersion(policyID: .editorialClock, version: clockPolicy.version),
        ]
        return FeedPlan(
            context: try ContextKey(surface: surface, scopeKey: scopeKey, planIdentity: planIdentity),
            policies: policies,
            sourceSelection: sourceSelection,
            subjectSelection: subjectSelection,
            presetIdentity: presetIdentity,
            region: region,
            contentType: contentType,
            languages: languages,
            mood: mood,
            contentFilters: contentFilters,
            taxonomyURLs: taxonomyURLs,
            blockedStableKeys: blocked,
            contentRestrictions: restrictions,
            preferences: preferences,
            budget: budget,
            historyPolicy: historyPolicy,
            repetitionPolicy: repetition,
            clockPolicy: clockPolicy,
            freshnessDemand: freshness,
            exploration: exploration
        )
    }

    /// The catalog resolves every durable key the fixture created.
    func projections(
        catalogKeys: [EditorialSourceKey],
        exclusions: [SupplyStableKey] = []
    ) -> PlanProjections {
        PlanProjections(
            catalog: PlanCatalogProjection(resolvedSources: catalogKeys),
            userState: PlanUserStateProjection(exclusionKeys: exclusions)
        )
    }

    /// A budget with explicit limits, so a test states the composition rule it exercises.
    func makeBudget(
        cardLimit: Int,
        poolLimit: Int,
        providerQuota: Int,
        diversityTarget: Int = 2,
        maxScanSteps: Int = 3
    ) throws -> SelectionBudget {
        try SelectionBudget(
            cardLimit: cardLimit,
            oversampleFactor: 4,
            poolLimit: poolLimit,
            scanRowsPerStep: poolLimit * 16,
            maxScanSteps: maxScanSteps,
            providerQuota: providerQuota,
            diversityTarget: diversityTarget
        )
    }

    /// Resolves a plan and selects against the fixture, so a test reads like the runtime does.
    func select(
        _ plan: FeedPlan,
        projections: PlanProjections,
        seed: Data = Data("seed-0000000000000000000000000000".utf8),
        in runtime: SelectionRuntime? = nil
    ) throws -> (plan: ResolvedFeedPlan, draft: SelectionDraft) {
        let resolved = try resolver.resolve(plan, projections: projections)
        let draft = try engine.draft(
            plan: resolved,
            projections: projections,
            seed: seed,
            in: fixtureRuntime(runtime).database
        )
        return (resolved, draft)
    }
}
