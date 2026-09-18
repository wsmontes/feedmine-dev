import Foundation
import GRDB
import FeedDomain

/// The concrete read repository for `selection_supply` (plan §3: repositories are concrete types in
/// `FeedStorage`, not a protocol per repository; plan §8: hard eligibility first, bounded pool after).
///
/// The read is deliberately narrow. It touches only the canonical projection —
/// `selection_supply`, `origin_record`, `origin_revision`, `external_identity`,
/// `source_membership`/`source`, `provider_attribution`/`provider`, `media_candidate` and the
/// syndication rows of `content_relation` — plus, and only when the plan's surface has a user-state
/// scope, the two durable-state tables that scope resolves through (`user_state_projection` and the
/// `legacy_item_map` alias). It never reads `connector_evidence`, a raw payload or a protocol DTO.
/// The evidence can be deleted without changing a single candidate (plan §7, I-03).
///
/// Access path: the supply table's only index is its primary key, so the page is a keyset walk over
/// `origin_record_id`. A page fixes a *window* of rows (`windowRows`) before it evaluates hard
/// eligibility inside that window, so the rows a page may examine are bounded by construction and the
/// bound is measurable; `LIMIT` alone would bound the result and not the cost, which plan §8
/// explicitly refuses to hand-wave.

public enum SelectionSupplyError: Error, Equatable, Sendable {
    case nonPositiveWindow(Int)
    /// The query's eligibility predicate admitted a record whose membership rows do not satisfy the
    /// same predicate in Swift. The two must agree; a disagreement is a bug, never a silent drop.
    case membershipPredicateDisagreement(OriginRecordID)
}

/// One bounded read of the supply projection.
public struct SupplyPageRequest: Hashable, Sendable {
    /// The plan's source selection in durable keys. An empty list means "every source the record is a
    /// member of", and any entry with `enabled == false` always excludes the record.
    public let sourceSelection: [SourceSelection]
    /// The plan's subject selection, when its cards are the reader's own saved rows rather than a
    /// source's supply. `nil` is the page this engine produced before the selection existed: every
    /// record the source selection admits.
    public let subjectSelection: SubjectSelection?
    /// Exclusive keyset cursor over `selection_supply.origin_record_id`; `nil` starts at the beginning.
    public let after: Int64?
    /// How many supply rows this page may examine. The window is what bounds the cost *and* the result:
    /// the page returns every eligible candidate inside it, because a result cap would silently drop
    /// eligible rows and make a diverse pool impossible to assemble in the next step.
    public let windowRows: Int

    public init(
        sourceSelection: [SourceSelection],
        subjectSelection: SubjectSelection? = nil,
        after: Int64?,
        windowRows: Int
    ) {
        self.sourceSelection = sourceSelection
        self.subjectSelection = subjectSelection
        self.after = after
        self.windowRows = windowRows
    }
}

public struct SupplyPage: Sendable {
    public let candidates: [SupplyCandidate]
    /// Declared syndication edges among this page's candidates, in durable keys.
    public let clusterEdges: [SupplyClusterEdge]
    /// Cursor for the next page; `nil` when the supply is exhausted.
    public let nextCursor: Int64?
    /// Rows of `selection_supply` in the window this page consumed, counted by SQLite.
    public let examinedRows: Int
    /// True when the supply's key range ended inside this window: the next page would read nothing.
    public let exhausted: Bool
    /// `EXPLAIN QUERY PLAN` of the eligibility query, verbatim.
    public let queryPlan: [String]

    public init(
        candidates: [SupplyCandidate],
        clusterEdges: [SupplyClusterEdge],
        nextCursor: Int64?,
        examinedRows: Int,
        exhausted: Bool,
        queryPlan: [String]
    ) {
        self.candidates = candidates
        self.clusterEdges = clusterEdges
        self.nextCursor = nextCursor
        self.examinedRows = examinedRows
        self.exhausted = exhausted
        self.queryPlan = queryPlan
    }
}

public struct SelectionSupplyRepository: Sendable {
    /// Where the candidate-query measurement goes (plan §16: "candidate query", with the dataset and
    /// its size recorded). `nil` means no diagnostics.
    private let metrics: RuntimeMetricsRecorder?

    public init(metrics: RuntimeMetricsRecorder? = nil) {
        self.metrics = metrics
    }

    /// One page. Hard eligibility (an existing current-revision supply row, an available record and the
    /// plan's source enablement) is decided in SQL, inside the page's own key window, so a page cannot be
    /// filled with rows the plan may not use and it cannot cost more than the window it declares.
    public func page(_ request: SupplyPageRequest, in database: RuntimeDatabase) throws -> SupplyPage {
        guard request.windowRows > 0 else { throw SelectionSupplyError.nonPositiveWindow(request.windowRows) }

        let started = ProcessInfo.processInfo.systemUptime
        let after = request.after ?? 0
        let sql = Self.eligibilitySQL(for: request)
        let page = try database.read { database in
            // The window is fixed first: it is what bounds the page's cost.
            let windowIDs = try Int64.fetchAll(database, sql: """
                SELECT origin_record_id FROM selection_supply
                WHERE origin_record_id > ?
                ORDER BY origin_record_id
                LIMIT ?
                """, arguments: [after, request.windowRows])
            guard let windowEnd = windowIDs.last else {
                let plan = try Self.queryPlan(database, sql: sql, arguments: Self.arguments(
                    for: request,
                    after: after,
                    windowEnd: after
                ))
                return SupplyPage(
                    candidates: [],
                    clusterEdges: [],
                    nextCursor: nil,
                    examinedRows: 0,
                    exhausted: true,
                    queryPlan: plan
                )
            }

            let arguments = Self.arguments(for: request, after: after, windowEnd: windowEnd)
            let plan = try Self.queryPlan(database, sql: sql, arguments: arguments)
            let rows = try Row.fetchAll(database, sql: sql, arguments: arguments)

            var records: [(row: Row, recordID: Int64, revisionID: Int64)] = []
            for row in rows {
                records.append((row, row["origin_record_id"], row["origin_revision_id"]))
            }
            let recordIDs = records.map(\.recordID)
            let revisionIDs = records.map(\.revisionID)

            let memberships = try Self.memberships(recordIDs: recordIDs, in: database)
            let providers = try Self.primaryProviders(revisionIDs: revisionIDs, in: database)
            let mediaRoles = try Self.mediaRoles(revisionIDs: revisionIDs, in: database)

            var candidates: [SupplyCandidate] = []
            for record in records {
                let recordID = try OriginRecordID(record.recordID)
                guard let keys = memberships[record.recordID],
                      let sourceKey = Self.chosenSource(keys: keys, selection: request.sourceSelection)
                else {
                    throw SelectionSupplyError.membershipPredicateDisagreement(recordID)
                }
                let observedAt = AdmissionTimestamp.date(milliseconds: record.row["observed_at"])
                let publishedAtClaim: Int64? = record.row["published_at_claim"]
                candidates.append(
                    SupplyCandidate(
                        stableKey: SupplyStableKey(
                            namespace: ConnectorNamespace(record.row["connector_namespace"]),
                            scopeKey: record.row["scope_key"],
                            objectKeyBytes: record.row["external_key"]
                        ),
                        originRecordID: recordID,
                        originRevisionID: try OriginRevisionID(record.revisionID),
                        payloadDigestHex: record.row["payload_digest_hex"],
                        sourceKey: sourceKey,
                        providerKey: providers[record.revisionID],
                        mediaRoles: mediaRoles[record.revisionID] ?? [],
                        filterText: Self.filterText(
                            headline: record.row["headline"],
                            summary: record.row["summary"]
                        ),
                        observedAt: observedAt,
                        sortDate: publishedAtClaim.map(AdmissionTimestamp.date(milliseconds:)) ?? observedAt,
                        sortDateIsFallback: publishedAtClaim == nil,
                        sortDatePolicyVersion: SortDatePolicy.currentVersion
                    )
                )
            }

            let edges = try Self.clusterEdges(recordIDs: recordIDs, in: database)
            var candidatesByRecord: [Int64: SupplyStableKey] = [:]
            for candidate in candidates {
                candidatesByRecord[candidate.originRecordID.rawValue] = candidate.stableKey
            }
            let resolvedEdges = edges.compactMap { edge -> SupplyClusterEdge? in
                guard let subject = candidatesByRecord[edge.subject],
                      let object = candidatesByRecord[edge.object]
                else { return nil }
                return SupplyClusterEdge(subject: subject, object: object, verb: edge.verb)
            }

            return SupplyPage(
                candidates: candidates,
                clusterEdges: resolvedEdges,
                nextCursor: windowEnd,
                examinedRows: windowIDs.count,
                exhausted: windowIDs.count < request.windowRows,
                queryPlan: plan
            )
        }
        if let metrics {
            // The identifier is the window the query was declared for, and the outcome carries the size
            // of the dataset it read: §16 asks for the candidate query "with the dataset and its size
            // recorded", because a p95 without them measures nothing.
            let elapsed = Double(ProcessInfo.processInfo.systemUptime - started) * 1_000
            let outcome = "rows=\(page.candidates.count) examined=\(page.examinedRows) window=\(request.windowRows)"
            Task {
                await metrics.record(
                    OperationSample(
                        operation: .selectionQuery,
                        operationID: "selection-page-after-\(after)",
                        durationMilliseconds: elapsed,
                        outcome: outcome
                    )
                )
            }
        }
        return page
    }

    /// The monotone supply counter, read beside the pool. It is an audit input, never an
    /// `EditorialRevision` input (ADR-002 D4: a `SupplyGeneration` increment never invalidates a plan).
    public func supplyGeneration(in database: RuntimeDatabase) throws -> UInt64 {
        try database.read { database in
            try UInt64.fetchOne(database, sql: "SELECT value FROM supply_generation WHERE id = 1") ?? 0
        }
    }

    /// Every supply row, for diagnostics and for the examined-rows measurement of a whole walk.
    public func totalSupplyRows(in database: RuntimeDatabase) throws -> Int {
        try database.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM selection_supply") ?? 0
        }
    }

    // MARK: - SQL

    /// The eligibility query. `plan_sources` carries the plan's durable source selection, so source
    /// enablement is decided without ever naming a local `source_id`.
    static func eligibilitySQL(for request: SupplyPageRequest) -> String {
        let hasEnabled = request.sourceSelection.contains { $0.enabled }
        var parts: [String] = []
        var cte = ""
        if request.sourceSelection.isEmpty {
            // No declared selection: every record with a membership is a candidate, and there is no
            // `plan_sources` relation to consult.
            parts.append("""
                EXISTS (SELECT 1 FROM source_membership m
                        WHERE m.origin_record_id = s.origin_record_id)
                """)
        } else {
            let values = Array(repeating: "(?, ?, ?)", count: request.sourceSelection.count)
                .joined(separator: ", ")
            cte = "WITH plan_sources(editorial_key, canonicalization_version, enabled) AS (VALUES \(values))\n"
            if hasEnabled {
                parts.append("""
                    EXISTS (SELECT 1 FROM source_membership m
                            JOIN source src ON src.id = m.source_id
                            JOIN plan_sources ps ON ps.editorial_key = src.editorial_key
                                AND ps.canonicalization_version = src.canonicalization_version
                            WHERE m.origin_record_id = s.origin_record_id AND ps.enabled = 1)
                    """)
            } else {
                parts.append("""
                    EXISTS (SELECT 1 FROM source_membership m
                            WHERE m.origin_record_id = s.origin_record_id)
                    """)
            }
            // A source the plan declares disabled never contributes, even when another membership would
            // admit the record: the declaration is hard eligibility (plan §8).
            parts.append("""
                NOT EXISTS (SELECT 1 FROM source_membership m
                            JOIN source src ON src.id = m.source_id
                            JOIN plan_sources ps ON ps.editorial_key = src.editorial_key
                                AND ps.canonicalization_version = src.canonicalization_version
                            WHERE m.origin_record_id = s.origin_record_id AND ps.enabled = 0)
                """)
        }
        if let selection = request.subjectSelection {
            switch selection {
            case .savedSubjects(_, .some(_)):
                // One box's membership, and not every saved card: a box holds what was filed into it
                // (baseline §8.58). Both branches carry exactly one placeholder, so the argument order
                // below cannot diverge from the SQL — and the value that fills it is read there, from
                // the request itself, which is why neither branch binds it here.
                parts.append("""
                    EXISTS (SELECT 1 FROM user_list_membership m
                            JOIN legacy_item_map lim ON lim.legacy_item_id = m.subject_id
                            WHERE m.list_key = ? AND m.wanted = 1
                              AND lim.origin_record_id = s.origin_record_id)
                    """)
            case .savedSubjects(_, .none):
                // The reader's own saved subjects, resolved to canonical records through the durable
                // alias. `wanted = 1` is the live projection: a removal writes 0 rather than deleting
                // the row (ADR-004 D7).
                parts.append("""
                    EXISTS (SELECT 1 FROM user_state_projection p
                            JOIN legacy_item_map lim ON lim.legacy_item_id = p.subject_id
                            WHERE p.kind = ? AND p.wanted = 1
                              AND lim.origin_record_id = s.origin_record_id)
                    """)
            }
        }
        let predicates = parts.map { "  AND \($0)" }.joined(separator: "\n")
        return """
            \(cte)SELECT s.origin_record_id, s.origin_revision_id, s.observed_at, s.published_at_claim,
                   r.connector_namespace, r.scope_key, i.external_key,
                   lower(hex(rev.payload_digest)) AS payload_digest_hex,
                   rev.headline, rev.summary
            FROM selection_supply s
            JOIN origin_record r ON r.id = s.origin_record_id
            JOIN origin_revision rev ON rev.id = s.origin_revision_id
            JOIN external_identity i ON i.id = r.primary_identity_id
            WHERE s.origin_record_id > ?
              AND s.origin_record_id <= ?
              AND r.availability = 'available'
            \(predicates)
            ORDER BY s.origin_record_id
            """
    }

    static func arguments(
        for request: SupplyPageRequest,
        after: Int64,
        windowEnd: Int64
    ) -> StatementArguments {
        var arguments: [(any DatabaseValueConvertible)?] = []
        if !request.sourceSelection.isEmpty {
            for selection in request.sourceSelection {
                arguments.append(selection.sourceKey.catalogIdentity)
                arguments.append(selection.sourceKey.canonicalizationVersion)
                arguments.append(selection.enabled ? 1 : 0)
            }
        }
        arguments.append(after)
        arguments.append(windowEnd)
        // The selection's own placeholder is the last one in the statement: the predicates are appended
        // after the two keyset bounds, so its argument binds after them. Both branches of a saved-subject
        // selection carry exactly one placeholder — the list key for a box, the kind for the whole set.
        if case .savedSubjects(let kind, let listKey) = request.subjectSelection {
            arguments.append(listKey ?? kind.rawValue)
        }
        return StatementArguments(arguments)
    }

    static func queryPlan(_ database: Database, sql: String, arguments: StatementArguments) throws -> [String] {
        try Row.fetchAll(database, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
            .map { row in row["detail"] }
    }

    // MARK: - Secondary projections

    /// Every membership of the page's records, in durable key order, so the chosen source never
    /// depends on the order rows came back in.
    static func memberships(recordIDs: [Int64], in database: Database) throws -> [Int64: [EditorialSourceKey]] {
        guard !recordIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(database, sql: """
            SELECT m.origin_record_id, src.editorial_key, src.canonicalization_version
            FROM source_membership m
            JOIN source src ON src.id = m.source_id
            WHERE m.origin_record_id IN (\(placeholders))
            ORDER BY m.origin_record_id, src.editorial_key, src.canonicalization_version
            """, arguments: StatementArguments(recordIDs))
        var result: [Int64: [EditorialSourceKey]] = [:]
        for row in rows {
            let recordID: Int64 = row["origin_record_id"]
            let key = try EditorialSourceKey(
                catalogIdentity: row["editorial_key"],
                canonicalizationVersion: row["canonicalization_version"]
            )
            result[recordID, default: []].append(key)
        }
        return result
    }

    /// The source a candidate is attributed to: the first of the record's memberships, in durable key
    /// order, that satisfies the plan's selection. Deterministic across databases.
    static func chosenSource(
        keys: [EditorialSourceKey],
        selection: [SourceSelection]
    ) -> EditorialSourceKey? {
        guard let first = keys.first else { return nil }
        guard !selection.isEmpty else { return first }
        let hasEnabled = selection.contains { $0.enabled }
        for key in keys {
            let declared = selection.first {
                $0.sourceKey.catalogIdentity == key.catalogIdentity
                    && $0.sourceKey.canonicalizationVersion == key.canonicalizationVersion
            }
            if let declared {
                if !declared.enabled { continue }
                return key
            }
            if !hasEnabled { return key }
        }
        return nil
    }

    /// The revision's primary attribution, when it declares one. Several primary providers can exist
    /// under `UNIQUE (origin_revision_id, provider_id, attribution_role)`, so the pick is ordered by
    /// the durable provider key rather than by `provider_id`.
    static func primaryProviders(revisionIDs: [Int64], in database: Database) throws -> [Int64: ProviderStableKey] {
        guard !revisionIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: revisionIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(database, sql: """
            SELECT pa.origin_revision_id, p.connector_namespace, p.provider_key
            FROM provider_attribution pa
            JOIN provider p ON p.id = pa.provider_id
            WHERE pa.origin_revision_id IN (\(placeholders))
              AND pa.attribution_role = 'primary'
            ORDER BY pa.origin_revision_id, p.connector_namespace, p.provider_key
            """, arguments: StatementArguments(revisionIDs))
        var result: [Int64: ProviderStableKey] = [:]
        for row in rows {
            let revisionID: Int64 = row["origin_revision_id"]
            guard result[revisionID] == nil else { continue }
            result[revisionID] = ProviderStableKey(
                namespace: ConnectorNamespace(row["connector_namespace"]),
                providerKey: row["provider_key"]
            )
        }
        return result
    }

    static func mediaRoles(revisionIDs: [Int64], in database: Database) throws -> [Int64: [MediaRole]] {
        guard !revisionIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: revisionIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(database, sql: """
            SELECT DISTINCT origin_revision_id, role FROM media_candidate
            WHERE origin_revision_id IN (\(placeholders))
            ORDER BY origin_revision_id, role
            """, arguments: StatementArguments(revisionIDs))
        var result: [Int64: [MediaRole]] = [:]
        for row in rows {
            let revisionID: Int64 = row["origin_revision_id"]
            guard let role = MediaRole(rawValue: row["role"]) else { continue }
            result[revisionID, default: []].append(role)
        }
        return result
    }

    /// The declared syndication edges among the page's records (ADR-003 D13). Both endpoints must be in
    /// the page: the grouping is pool-local and never invents a member it did not read.
    static func clusterEdges(
        recordIDs: [Int64],
        in database: Database
    ) throws -> [(subject: Int64, object: Int64, verb: SupplyClusterEdge.Verb)] {
        guard !recordIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: recordIDs.count).joined(separator: ", ")
        let verbs = SupplyClusterEdge.Verb.allCases.map(\.rawValue)
        let verbPlaceholders = Array(repeating: "?", count: verbs.count).joined(separator: ", ")
        let arguments = StatementArguments(
            (verbs as [(any DatabaseValueConvertible)?]) + (recordIDs as [(any DatabaseValueConvertible)?])
                + (recordIDs as [(any DatabaseValueConvertible)?])
        )
        let rows = try Row.fetchAll(database, sql: """
            SELECT c.subject_origin_record_id, c.object_origin_record_id, c.relation
            FROM content_relation c
            WHERE c.relation IN (\(verbPlaceholders))
              AND c.subject_origin_record_id IN (\(placeholders))
              AND c.object_origin_record_id IN (\(placeholders))
            ORDER BY c.subject_origin_record_id, c.object_origin_record_id, c.relation
            """, arguments: arguments)
        return rows.compactMap { row in
            guard let verb = SupplyClusterEdge.Verb(rawValue: row["relation"]) else { return nil }
            return (row["subject_origin_record_id"], row["object_origin_record_id"], verb)
        }
    }

    static func filterText(headline: String?, summary: String?) -> String {
        var parts: [String] = []
        if let headline { parts.append(headline) }
        if let summary { parts.append(summary) }
        return parts.joined(separator: "\n")
    }
}
