import XCTest
import GRDB
import FeedDomain
@testable import FeedStorage

/// PR-05, storage half: the execution plan and the examined-row count of the supply read.
///
/// Plan §8 states the requirement directly — "`LIMIT 96` limita resultado, não necessariamente custo:
/// provar plano de execução e linhas examinadas" — so these tests do not estimate the cost: they run a
/// real fixture of ten and a hundred thousand `selection_supply` rows, read the published
/// `EXPLAIN QUERY PLAN` and let SQLite count the rows of the primary-key window each page consumed.
final class SelectionQueryPlanTests: RuntimeV2TestCase {
    private let repository = SelectionSupplyRepository()

    /// Builds a large supply in one transaction.
    ///
    /// The distribution is expressed as SQL over the 1-based row number `n` so a fixture can shape a
    /// biased supply without a hundred thousand Swift iterations. Every statement keeps the schema's
    /// foreign keys intact: identities, records, revisions, memberships and the supply projection are
    /// written in dependency order.
    @discardableResult
    func insertBulkSupply(
        rows: Int,
        sourceKeys: [String],
        providerKeys: [String],
        sourceIndexExpression: String,
        providerIndexExpression: String
    ) throws -> [EditorialSourceKey] {
        var keys: [EditorialSourceKey] = []
        try database.write { database in
            try database.execute(sql: """
                CREATE TEMP TABLE bulk_plan (
                    n INTEGER PRIMARY KEY, source_index INTEGER NOT NULL, provider_index INTEGER NOT NULL
                )
                """)
            try database.execute(sql: "CREATE TEMP TABLE bulk_source (idx INTEGER PRIMARY KEY, source_id INTEGER NOT NULL)")
            try database.execute(sql: "CREATE TEMP TABLE bulk_provider (idx INTEGER PRIMARY KEY, provider_id INTEGER NOT NULL)")
            defer {
                try? database.execute(sql: "DROP TABLE bulk_source")
                try? database.execute(sql: "DROP TABLE bulk_provider")
                try? database.execute(sql: "DROP TABLE bulk_plan")
            }

            for (index, key) in sourceKeys.enumerated() {
                try database.execute(sql: """
                    INSERT INTO source (editorial_key, canonicalization_version, display_title, created_at)
                    VALUES (?, 1, ?, 0)
                    """, arguments: [key, key])
                try database.execute(
                    sql: "INSERT INTO bulk_source (idx, source_id) VALUES (?, ?)",
                    arguments: [index, database.lastInsertedRowID]
                )
            }
            for (index, key) in providerKeys.enumerated() {
                try database.execute(sql: """
                    INSERT INTO provider (connector_namespace, provider_key, display_name, created_at)
                    VALUES ('connector.bulk', ?, ?, 0)
                    """, arguments: [key, key])
                try database.execute(
                    sql: "INSERT INTO bulk_provider (idx, provider_id) VALUES (?, ?)",
                    arguments: [index, database.lastInsertedRowID]
                )
            }

            try database.execute(sql: """
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < ?)
                INSERT INTO bulk_plan (n, source_index, provider_index)
                SELECT n, \(sourceIndexExpression), \(providerIndexExpression) FROM seq
                """, arguments: [rows])

            try database.execute(sql: """
                INSERT INTO external_identity (
                    connector_namespace, scope_key, key_kind, external_key, key_digest,
                    origin_record_id, identity_confidence, first_observed_at, last_observed_at
                )
                SELECT 'connector.bulk', 'scope-bulk', 'object', CAST('bulk-' || n AS BLOB),
                       zeroblob(16), NULL, 'high', 0, 0
                FROM bulk_plan
                """)
            try database.execute(sql: """
                INSERT INTO origin_record (
                    connector_namespace, scope_key, primary_identity_id, availability,
                    first_observed_at, last_observed_at
                )
                SELECT 'connector.bulk', 'scope-bulk', n, 'available', 0, 0 FROM bulk_plan
                """)
            // Both tables are filled from `bulk_plan` in the same order, so identity `n` owns record `n`
            // (`primary_identity_id = n` above). The backfill is therefore a plain assignment scoped to
            // the fixture's own identities: a correlated subquery here would scan `origin_record` once
            // per row, because `primary_identity_id` carries no index.
            try database.execute(sql: """
                UPDATE external_identity SET origin_record_id = id
                WHERE id IN (SELECT n FROM bulk_plan)
                """)
            try database.execute(sql: """
                INSERT INTO origin_revision (
                    origin_record_id, external_version_key, payload_digest, headline, summary,
                    authored_at, observed_at, created_at, identity_confidence
                )
                SELECT n, NULL, CAST('bulk-digest-' || n AS BLOB), 'Headline ' || n, NULL, NULL,
                       1700000000000 + n, 0, 'high'
                FROM bulk_plan
                """)
            try database.execute(sql: """
                UPDATE origin_record SET current_revision_id = (
                    SELECT id FROM origin_revision WHERE origin_revision.origin_record_id = origin_record.id
                )
                """)
            try database.execute(sql: """
                INSERT INTO source_membership (
                    origin_record_id, source_id, membership_kind, first_observed_at, last_observed_at
                )
                SELECT p.n, s.source_id, 'editorial', 0, 0
                FROM bulk_plan p JOIN bulk_source s ON s.idx = p.source_index
                """)
            try database.execute(sql: """
                INSERT INTO provider_attribution (
                    origin_revision_id, provider_id, attribution_role, created_at
                )
                SELECT r.id, pv.provider_id, 'primary', 0
                FROM bulk_plan p
                JOIN origin_revision r ON r.origin_record_id = p.n
                JOIN bulk_provider pv ON pv.idx = p.provider_index
                """)
            try database.execute(sql: """
                INSERT INTO selection_supply (
                    origin_record_id, origin_revision_id, source_id, observed_at, published_at_claim
                )
                SELECT p.n, r.id, s.source_id, 1700000000000 + p.n, NULL
                FROM bulk_plan p
                JOIN origin_revision r ON r.origin_record_id = p.n
                JOIN bulk_source s ON s.idx = p.source_index
                """)
        }
        for key in sourceKeys {
            keys.append(try EditorialSourceKey(catalogIdentity: key, canonicalizationVersion: 1))
        }
        return keys
    }

    private func readPool(
        sourceSelection: [SourceSelection],
        budget: SelectionBudget
    ) throws -> (candidates: [SupplyCandidate], examinedRows: Int, steps: Int, plan: [String]) {
        var cursor: Int64?
        var candidates: [SupplyCandidate] = []
        var examined = 0
        var steps = 0
        var plan: [String] = []
        while steps < budget.maxScanSteps {
            let windowRows = budget.scanRowsPerStep * (1 << steps)
            let page = try repository.page(
                SupplyPageRequest(
                    sourceSelection: sourceSelection,
                    after: cursor,
                    windowRows: windowRows
                ),
                in: database
            )
            steps += 1
            examined += page.examinedRows
            plan = page.queryPlan
            candidates.append(contentsOf: page.candidates)
            if candidates.count >= budget.poolLimit { break }
            guard let next = page.nextCursor, !page.exhausted else { break }
            cursor = next
        }
        return (Array(candidates.prefix(budget.poolLimit)), examined, steps, plan)
    }

    // MARK: - The access path

    func testQueryPlanSeeksTheSupplyPrimaryKey() throws {
        let keys = try insertBulkSupply(
            rows: 10_000,
            sourceKeys: ["bulk-main", "bulk-second", "bulk-third", "bulk-fourth", "bulk-paused"],
            providerKeys: ["p1", "p2", "p3", "p4"],
            sourceIndexExpression: "CASE WHEN n % 10 = 0 THEN 4 ELSE n % 4 END",
            providerIndexExpression: "n % 4"
        )
        let selection = keys.enumerated().map { index, key in
            SourceSelection(sourceKey: key, enabled: index < 4)
        }
        let plan = try repository.page(
            SupplyPageRequest(sourceSelection: selection, after: nil, windowRows: 1536),
            in: database
        ).queryPlan
        print("EXPLAIN QUERY PLAN:\n\(plan.joined(separator: "\n"))")
        XCTAssertTrue(
            plan.contains { $0.contains("SEARCH s USING INTEGER PRIMARY KEY") },
            "the page must seek the supply primary key: \(plan)"
        )
        XCTAssertFalse(
            plan.contains { $0.contains("SCAN s") },
            "an unqualified scan of selection_supply would make the window meaningless: \(plan)"
        )
    }

    // MARK: - Bounded pool, measured

    func testBoundedPoolOnBiasedTenThousandRowSupplyReportsExaminedRows() throws {
        let total = 10_000
        let keys = try insertBulkSupply(
            rows: total,
            sourceKeys: ["bulk-main", "bulk-second", "bulk-third", "bulk-fourth", "bulk-paused"],
            providerKeys: ["p1", "p2", "p3", "p4"],
            sourceIndexExpression: "CASE WHEN n % 10 = 0 THEN 4 ELSE n % 4 END",
            providerIndexExpression: "n % 4"
        )
        XCTAssertEqual(try repository.totalSupplyRows(in: database), total)
        // One source in ten is paused, and it is spread through the whole key range: the walk cannot
        // rely on a clean prefix.
        let selection = keys.enumerated().map { index, key in
            SourceSelection(sourceKey: key, enabled: index < 4)
        }

        let pool = try readPool(sourceSelection: selection, budget: .initial)
        let distinctProviders = Set(pool.candidates.map(\.quotaKey))
        print("""
            biased supply: rows=\(total) picked=\(pool.candidates.count) \
            examinedRows=\(pool.examinedRows) steps=\(pool.steps) \
            distinctQuotaKeys=\(distinctProviders.count)
            """)
        XCTAssertEqual(pool.candidates.count, SelectionBudget.initial.poolLimit)
        XCTAssertEqual(pool.steps, 1, "a bounded first step already fills the pool")
        XCTAssertEqual(pool.examinedRows, SelectionBudget.initial.scanRowsPerStep)
        XCTAssertLessThan(
            pool.examinedRows,
            total,
            "the walk stops early instead of reading the whole supply"
        )
        XCTAssertEqual(distinctProviders.count, 4)
        XCTAssertFalse(pool.candidates.contains { $0.sourceKey.catalogIdentity == "bulk-paused" })
    }

    func testBoundedPoolOnHundredThousandRowSupplyStaysBounded() throws {
        let total = 100_000
        let keys = try insertBulkSupply(
            rows: total,
            sourceKeys: ["bulk-main", "bulk-second", "bulk-third", "bulk-fourth", "bulk-paused"],
            providerKeys: ["p1", "p2", "p3", "p4"],
            sourceIndexExpression: "CASE WHEN n % 20 = 0 THEN 4 ELSE n % 4 END",
            providerIndexExpression: "n % 4"
        )
        XCTAssertEqual(try repository.totalSupplyRows(in: database), total)
        let selection = keys.enumerated().map { index, key in
            SourceSelection(sourceKey: key, enabled: index < 4)
        }

        let pool = try readPool(sourceSelection: selection, budget: .initial)
        print("""
            hundred-thousand supply: rows=\(total) picked=\(pool.candidates.count) \
            examinedRows=\(pool.examinedRows) steps=\(pool.steps)
            """)
        XCTAssertEqual(pool.candidates.count, SelectionBudget.initial.poolLimit)
        XCTAssertEqual(pool.steps, 1)
        XCTAssertEqual(pool.examinedRows, SelectionBudget.initial.scanRowsPerStep)
        XCTAssertLessThan(pool.examinedRows, total)
        XCTAssertTrue(pool.plan.contains { $0.contains("SEARCH s USING INTEGER PRIMARY KEY") })
    }

    /// A dominant prefix: one source owns the first 9000 rows. A repository walk that only wants a full
    /// pool still pays one bounded window, and the pool it hands back holds one quota key — which is why
    /// the engine keeps walking for diversity, bounded by the scan budget
    /// (`SelectionEngineTests.testPoolIsBoundedAndReportsTheMeasuredReadCost` measures that case).
    func testBoundedPoolOnADominantPrefixIsStillBounded() throws {
        let total = 10_000
        try insertBulkSupply(
            rows: total,
            sourceKeys: ["bulk-dominant", "bulk-tail"],
            providerKeys: ["dominant", "tail"],
            sourceIndexExpression: "CASE WHEN n <= 9000 THEN 0 ELSE 1 END",
            providerIndexExpression: "CASE WHEN n <= 9000 THEN 0 ELSE 1 END"
        )
        let dominant = try EditorialSourceKey(catalogIdentity: "bulk-dominant", canonicalizationVersion: 1)
        let tail = try EditorialSourceKey(catalogIdentity: "bulk-tail", canonicalizationVersion: 1)

        let pool = try readPool(
            sourceSelection: [
                SourceSelection(sourceKey: dominant, enabled: true),
                SourceSelection(sourceKey: tail, enabled: true),
            ],
            budget: .initial
        )
        let distinctProviders = Set(pool.candidates.map(\.quotaKey))
        print("""
            dominant supply: rows=\(total) picked=\(pool.candidates.count) \
            examinedRows=\(pool.examinedRows) steps=\(pool.steps) \
            distinctQuotaKeys=\(distinctProviders.count)
            """)
        XCTAssertEqual(pool.candidates.count, SelectionBudget.initial.poolLimit)
        XCTAssertEqual(pool.examinedRows, SelectionBudget.initial.scanRowsPerStep)
        XCTAssertEqual(pool.steps, 1)
        XCTAssertLessThan(pool.examinedRows, total)
        XCTAssertEqual(
            distinctProviders.count,
            1,
            "a pool read that ignores diversity holds the dominant provider only, which the engine's quota and diversity target exist to fix"
        )
    }
}
