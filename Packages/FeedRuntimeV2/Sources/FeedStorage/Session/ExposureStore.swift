import Foundation
import GRDB
import FeedDomain

/// The exposure log and the projections policy reads (ADR-007 D7–D12).
///
/// Two write rules are enforced here rather than trusted:
///
/// * **idempotency** — `UNIQUE(fact_key)` decides. A replayed flush conflicts, changes no row and
///   leaves every projection untouched (a double flush can never inflate `visit_count`);
/// * **staleness** — a batch carries the session stamp it was produced under and the editions it is
///   allowed to name. A batch from another session, or one naming an edition that is neither active
///   nor checkpointed, writes zero rows (ADR-007 D11, invariant H-13).
///
/// Projections are updated inside the same transaction as the facts, so a crash can never leave a fact
/// recorded without its projection. Pruning the fact log is not implemented here, and no code path in
/// this type deletes a `history_projection` row: it is the retention root ADR-007 D10 protects.

public enum ExposureStoreError: Error, Equatable, Sendable {
    /// A policy version must be immutable: re-declaring it with different knobs is a defect, not an
    /// update (ADR-007 D1).
    case policyVersionChanged(String)
    case unreadableScope(String)
}

/// Which facts a flush is allowed to write.
public struct ExposureFlushGuard: Hashable, Sendable {
    /// The stamp that produced the batch.
    public let sessionStamp: SessionStamp
    /// The stamp the session is on now.
    public let currentSessionStamp: SessionStamp
    /// The editions that are active or checkpointed right now.
    public let acceptedEditions: Set<EditionID>

    public init(
        sessionStamp: SessionStamp,
        currentSessionStamp: SessionStamp,
        acceptedEditions: Set<EditionID>
    ) {
        self.sessionStamp = sessionStamp
        self.currentSessionStamp = currentSessionStamp
        self.acceptedEditions = acceptedEditions
    }
}

public enum ExposureRejection: Hashable, Sendable {
    case staleSession(flushed: SessionStamp, current: SessionStamp)
    case unknownEdition(EditionID)
}

public struct ExposureAppendReceipt: Hashable, Sendable {
    public let insertedFactKeys: [String]
    public let replayedFactKeys: [String]
    public let rejection: ExposureRejection?

    public var insertedCount: Int { insertedFactKeys.count }
    public var replayCount: Int { replayedFactKeys.count }
    public var isRejected: Bool { rejection != nil }
}

public struct ExposureFactStore: Sendable {
    private let database: RuntimeDatabase

    public init(database: RuntimeDatabase) {
        self.database = database
    }

    // MARK: - Policy

    /// Declares (or verifies) the policy version the facts carry.
    ///
    /// - Returns: `true` when the row was created, `false` when it already existed with the same knobs.
    @discardableResult
    public func declare(_ policy: ExposurePolicy, createdAtMs: Int64) throws -> Bool {
        try database.write { db in
            try Self.declare(policy, createdAtMs: createdAtMs, in: db)
        }
    }

    /// Appends one batch of facts and updates the projections they affect, in one transaction.
    public func append(
        _ facts: [ExposureFact],
        policy: ExposurePolicy,
        wallClockMs: Int64? = nil,
        guard flushGuard: ExposureFlushGuard? = nil
    ) throws -> ExposureAppendReceipt {
        if let flushGuard, flushGuard.sessionStamp != flushGuard.currentSessionStamp {
            return ExposureAppendReceipt(
                insertedFactKeys: [],
                replayedFactKeys: [],
                rejection: .staleSession(
                    flushed: flushGuard.sessionStamp,
                    current: flushGuard.currentSessionStamp
                )
            )
        }
        if let flushGuard, let stray = facts.first(where: { !flushGuard.acceptedEditions.contains($0.editionID) }) {
            return ExposureAppendReceipt(
                insertedFactKeys: [],
                replayedFactKeys: [],
                rejection: .unknownEdition(stray.editionID)
            )
        }
        return try database.write { db in
            let createdAt = facts.map(\.observedAtMs).min() ?? 0
            _ = try Self.declare(policy, createdAtMs: createdAt, in: db)
            var inserted: [String] = []
            var replayed: [String] = []
            for fact in facts {
                let isNew = try Self.insert(fact, wallClockMs: wallClockMs, in: db)
                if isNew {
                    inserted.append(fact.factKey)
                    try Self.project(fact, in: db)
                } else {
                    replayed.append(fact.factKey)
                }
            }
            return ExposureAppendReceipt(
                insertedFactKeys: inserted,
                replayedFactKeys: replayed,
                rejection: nil
            )
        }
    }

    public func factCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM exposure_fact") ?? 0
        }
    }

    public func fact(forKey key: String) throws -> ExposureFactRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM exposure_fact WHERE fact_key = ?",
                arguments: [key]
            ) else { return nil }
            return try ExposureFactRecord(row: row)
        }
    }

    public func policy(version: String) throws -> ExposurePolicySnapshot? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM exposure_policy WHERE policy_version = ?",
                arguments: [version]
            ) else { return nil }
            return ExposurePolicySnapshot(row: row)
        }
    }

    // MARK: - Internals

    private static func declare(
        _ policy: ExposurePolicy,
        createdAtMs: Int64,
        in db: Database
    ) throws -> Bool {
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM exposure_policy WHERE policy_version = ?",
            arguments: [policy.version]
        ) {
            let stored = ExposurePolicySnapshot(row: row)
            guard stored.minVisibleFraction == policy.minVisibleFraction,
                  stored.minDwellMs == policy.minDwellMs,
                  stored.coalesceWindowMs == policy.coalesceWindowMs,
                  stored.flushFactCount == policy.flushFactCount,
                  stored.flushIntervalMs == policy.flushIntervalMs
            else {
                throw ExposureStoreError.policyVersionChanged(policy.version)
            }
            return false
        }
        try db.execute(
            sql: """
                INSERT INTO exposure_policy (
                    policy_version, min_visible_fraction, min_dwell_ms, coalesce_window_ms,
                    flush_fact_count, flush_interval_ms, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                policy.version,
                policy.minVisibleFraction,
                policy.minDwellMs,
                policy.coalesceWindowMs,
                policy.flushFactCount,
                policy.flushIntervalMs,
                max(0, createdAtMs),
            ]
        )
        return true
    }

    private static func insert(
        _ fact: ExposureFact,
        wallClockMs: Int64?,
        in db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO exposure_fact (
                    fact_key, edition_id, card_id, origin_record_id, origin_revision_id,
                    event_type, scope, scope_ref, visit_ordinal, boot_session_id, observed_at_ms,
                    wall_clock_ms, dwell_ms, max_visible_fraction, direction, close_reason,
                    policy_version, user_state_op_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                fact.factKey,
                fact.editionID.rawValue,
                fact.cardID.rawValue,
                fact.originRecordID?.rawValue,
                fact.originRevisionID?.rawValue,
                fact.type.rawValue,
                fact.scope.canonicalName,
                fact.scope.scopeRef,
                fact.visitOrdinal,
                fact.bootSessionID,
                fact.observedAtMs,
                wallClockMs,
                fact.dwellMs,
                fact.maxVisibleFraction,
                fact.direction,
                fact.closeReason?.rawValue,
                fact.policyVersion,
                fact.userStateOperationID,
            ]
        )
        return db.changesCount > 0
    }

    /// One projection row per (scope, scope_ref, card). Read, mutate, write: the batch is bounded by the
    /// flush policy (20 facts by default), so the row-at-a-time form stays cheap and obvious.
    private static func project(_ fact: ExposureFact, in db: Database) throws {
        var record = try HistoryProjectionRecord.load(
            db,
            scope: fact.scope.canonicalName,
            scopeRef: fact.scope.scopeRef,
            cardID: fact.cardID
        ) ?? HistoryProjectionRecord(
            scope: fact.scope.canonicalName,
            scopeRef: fact.scope.scopeRef,
            cardID: fact.cardID,
            policyVersion: fact.policyVersion
        )
        record.editionID = fact.editionID
        record.policyVersion = fact.policyVersion

        switch fact.type {
        case .viewportEntered:
            // A visit is counted from its entry fact, whose `fact_key` already dedups replays.
            if fact.visitOrdinal >= record.lastVisitOrdinal {
                record.visitCount += 1
                record.lastVisitOrdinal = fact.visitOrdinal
            }
        case .seen:
            record.firstSeenAtMs = record.firstSeenAtMs ?? fact.observedAtMs
            record.lastSeenAtMs = max(record.lastSeenAtMs ?? 0, fact.observedAtMs)
        case .opened:
            record.openedAtMs = record.openedAtMs ?? fact.observedAtMs
        case .read:
            record.readAtMs = fact.observedAtMs
            record.readClearedAtMs = nil
        case .bookmarked:
            record.bookmarkedAtMs = fact.observedAtMs
        case .bookmarkRemoved:
            record.bookmarkedAtMs = nil
        case .centerCrossed:
            record.centerCrossedAtMs = max(record.centerCrossedAtMs ?? 0, fact.observedAtMs)
        case .viewportLeft:
            break
        }
        try record.save(db)
    }
}

/// One exposure fact as it was stored. The API's `ExposureFact` is the value the runtime produces;
/// this is the durable row, including the columns that exist for diagnostics only.
public struct ExposureFactRecord: Hashable, Sendable {
    public let factKey: String
    public let editionID: EditionID
    public let cardID: PublicationCardID
    public let eventType: ExposureEventType
    public let scopeName: String
    public let scopeRef: String
    public let visitOrdinal: Int
    public let bootSessionID: String
    public let observedAtMs: Int64
    public let dwellMs: Int64?
    public let maxVisibleFraction: Double?
    public let direction: Int?
    public let closeReason: ExposureCloseReason?
    public let policyVersion: String
    public let userStateOperationID: String?

    public init(row: Row) throws {
        self.factKey = row["fact_key"]
        self.editionID = try EditionID(row["edition_id"])
        self.cardID = try PublicationCardID(row["card_id"])
        let typeText: String = row["event_type"]
        guard let type = ExposureEventType(rawValue: typeText) else {
            throw ExposureStoreError.unreadableScope(typeText)
        }
        self.eventType = type
        self.scopeName = row["scope"]
        self.scopeRef = row["scope_ref"]
        self.visitOrdinal = row["visit_ordinal"]
        self.bootSessionID = row["boot_session_id"]
        self.observedAtMs = row["observed_at_ms"]
        self.dwellMs = row["dwell_ms"]
        self.maxVisibleFraction = row["max_visible_fraction"]
        self.direction = row["direction"]
        self.closeReason = (row["close_reason"] as String?).flatMap(ExposureCloseReason.init(rawValue:))
        self.policyVersion = row["policy_version"]
        self.userStateOperationID = row["user_state_op_id"]
    }
}

/// One stored policy row (ADR-007 `exposure_policy`).
public struct ExposurePolicySnapshot: Hashable, Sendable {
    public let version: String
    public let minVisibleFraction: Double
    public let minDwellMs: Int
    public let coalesceWindowMs: Int
    public let flushFactCount: Int
    public let flushIntervalMs: Int

    public init(row: Row) {
        self.version = row["policy_version"]
        self.minVisibleFraction = row["min_visible_fraction"]
        self.minDwellMs = row["min_dwell_ms"]
        self.coalesceWindowMs = row["coalesce_window_ms"]
        self.flushFactCount = row["flush_fact_count"]
        self.flushIntervalMs = row["flush_interval_ms"]
    }
}

public enum HistoryProjectionError: Error, Equatable, Sendable {
    /// ADR-007 D12: an absent policy row is refused, never assumed.
    case undeclaredPolicy(String)
}

/// One `history_projection` row: the state of one card on one surface.
public struct HistoryProjectionRecord: Hashable, Sendable {
    public let scope: String
    public let scopeRef: String
    public let cardID: PublicationCardID
    public var editionID: EditionID?
    public var firstSeenAtMs: Int64?
    public var lastSeenAtMs: Int64?
    public var openedAtMs: Int64?
    public var readAtMs: Int64?
    public var readClearedAtMs: Int64?
    public var bookmarkedAtMs: Int64?
    public var centerCrossedAtMs: Int64?
    public var visitCount: Int
    public var lastVisitOrdinal: Int
    public var policyVersion: String
    public var userStateRevision: Int64

    public init(scope: String, scopeRef: String, cardID: PublicationCardID, policyVersion: String) {
        self.scope = scope
        self.scopeRef = scopeRef
        self.cardID = cardID
        self.editionID = nil
        self.firstSeenAtMs = nil
        self.lastSeenAtMs = nil
        self.openedAtMs = nil
        self.readAtMs = nil
        self.readClearedAtMs = nil
        self.bookmarkedAtMs = nil
        self.centerCrossedAtMs = nil
        self.visitCount = 0
        self.lastVisitOrdinal = 0
        self.policyVersion = policyVersion
        self.userStateRevision = 0
    }

    init(row: Row) throws {
        self.scope = row["scope"]
        self.scopeRef = row["scope_ref"]
        self.cardID = try PublicationCardID(row["card_id"])
        self.editionID = (row["edition_id"] as Int64?).map { try? EditionID($0) } ?? nil
        self.firstSeenAtMs = row["first_seen_at_ms"]
        self.lastSeenAtMs = row["last_seen_at_ms"]
        self.openedAtMs = row["opened_at_ms"]
        self.readAtMs = row["read_at_ms"]
        self.readClearedAtMs = row["read_cleared_at_ms"]
        self.bookmarkedAtMs = row["bookmarked_at_ms"]
        self.centerCrossedAtMs = row["center_crossed_at_ms"]
        self.visitCount = row["visit_count"]
        self.lastVisitOrdinal = row["last_visit_ordinal"]
        self.policyVersion = row["policy_version"]
        self.userStateRevision = row["user_state_revision"]
    }

    static func load(
        _ db: Database,
        scope: String,
        scopeRef: String,
        cardID: PublicationCardID
    ) throws -> HistoryProjectionRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM history_projection
                WHERE scope = ? AND scope_ref = ? AND card_id = ?
                """,
            arguments: [scope, scopeRef, cardID.rawValue]
        ) else { return nil }
        return try HistoryProjectionRecord(row: row)
    }

    func save(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO history_projection (
                    scope, scope_ref, card_id, edition_id, first_seen_at_ms, last_seen_at_ms,
                    opened_at_ms, read_at_ms, read_cleared_at_ms, bookmarked_at_ms,
                    center_crossed_at_ms, visit_count, last_visit_ordinal, policy_version,
                    user_state_revision
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(scope, scope_ref, card_id) DO UPDATE SET
                    edition_id = excluded.edition_id,
                    first_seen_at_ms = excluded.first_seen_at_ms,
                    last_seen_at_ms = excluded.last_seen_at_ms,
                    opened_at_ms = excluded.opened_at_ms,
                    read_at_ms = excluded.read_at_ms,
                    read_cleared_at_ms = excluded.read_cleared_at_ms,
                    bookmarked_at_ms = excluded.bookmarked_at_ms,
                    center_crossed_at_ms = excluded.center_crossed_at_ms,
                    visit_count = excluded.visit_count,
                    last_visit_ordinal = excluded.last_visit_ordinal,
                    policy_version = excluded.policy_version,
                    user_state_revision = excluded.user_state_revision
                """,
            arguments: [
                scope,
                scopeRef,
                cardID.rawValue,
                editionID?.rawValue,
                firstSeenAtMs,
                lastSeenAtMs,
                openedAtMs,
                readAtMs,
                readClearedAtMs,
                bookmarkedAtMs,
                centerCrossedAtMs,
                visitCount,
                lastVisitOrdinal,
                policyVersion,
                userStateRevision,
            ]
        )
    }
}

/// The read side of history: the declared policy per surface and the projections policy reads.
public struct HistoryProjectionStore: Sendable {
    private let database: RuntimeDatabase

    public init(database: RuntimeDatabase) {
        self.database = database
    }

    /// Declares a surface's history policy. The matrix of ADR-007 D12 is a declaration, so the runtime
    /// never invents one for a scope it does not own.
    public func declare(_ policy: HistoryPolicy) throws {
        try database.write { db in
            let scopeRef = policy.scope.scopeRef
            for (kind, value) in [
                ("apply_seen", policy.applySeen),
                ("show_overlay", policy.showOverlay),
                ("auto_exclude", policy.autoExclude),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO history_policy (
                            scope, scope_ref, policy_kind, policy_value, policy_version
                        ) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(scope, scope_ref, policy_kind) DO UPDATE SET
                            policy_value = excluded.policy_value,
                            policy_version = excluded.policy_version
                        """,
                    arguments: [
                        policy.scope.canonicalName,
                        scopeRef,
                        kind,
                        value ? 1 : 0,
                        policy.version,
                    ]
                )
            }
        }
    }

    /// The declared policy of a scope, or `nil` when the surface never declared one.
    public func declaredPolicy(for scope: HistoryScope) throws -> HistoryPolicy? {
        try database.read { db in
            try Self.declaredPolicy(db, scope: scope)
        }
    }

    /// The projection row of one card on one surface.
    public func projection(
        scope: HistoryScope,
        cardID: PublicationCardID
    ) throws -> HistoryProjectionRecord? {
        try database.read { db in
            try HistoryProjectionRecord.load(
                db,
                scope: scope.canonicalName,
                scopeRef: scope.scopeRef,
                cardID: cardID
            )
        }
    }

    public func projectionCount(scope: HistoryScope) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM history_projection WHERE scope = ? AND scope_ref = ?
                    """,
                arguments: [scope.canonicalName, scope.scopeRef]
            ) ?? 0
        }
    }

    /// The cards this surface must not show again.
    ///
    /// Both conditions of ADR-007 D12 are applied: the surface must *declare* that it applies `seen`,
    /// and the row must belong to that same scope. A card seen in Main is therefore never excluded
    /// from Bookmark, Source or Search, whatever those surfaces display as an overlay.
    public func exclusions(scope: HistoryScope) throws -> [PublicationCardID] {
        guard let policy = try declaredPolicy(for: scope) else {
            throw HistoryProjectionError.undeclaredPolicy(scope.canonicalName)
        }
        guard HistoryScopeRules(policy: policy).excludes(cardSeenIn: scope) else { return [] }
        return try database.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT card_id FROM history_projection
                    WHERE scope = ? AND scope_ref = ? AND last_seen_at_ms IS NOT NULL
                    ORDER BY card_id
                    """,
                arguments: [scope.canonicalName, scope.scopeRef]
            ).compactMap { try? PublicationCardID($0) }
        }
    }

    /// The cards this surface holds as bookmarked. Nothing about exposure removes one: only an explicit
    /// `bookmarkRemoved` fact does (ADR-007 H-10).
    public func bookmarkedCardIDs(scope: HistoryScope) throws -> [PublicationCardID] {
        try database.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT card_id FROM history_projection
                    WHERE scope = ? AND scope_ref = ? AND bookmarked_at_ms IS NOT NULL
                    ORDER BY card_id
                    """,
                arguments: [scope.canonicalName, scope.scopeRef]
            ).compactMap { try? PublicationCardID($0) }
        }
    }

    /// Marks a card unread without removing it from history: the card keeps its `read_at_ms` and gains
    /// a `read_cleared_at_ms`, which is how "never requeues an already seen card" is expressed.
    @discardableResult
    public func clearRead(
        scope: HistoryScope,
        cardID: PublicationCardID,
        atMs: Int64
    ) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE history_projection SET read_cleared_at_ms = ?
                    WHERE scope = ? AND scope_ref = ? AND card_id = ?
                    """,
                arguments: [atMs, scope.canonicalName, scope.scopeRef, cardID.rawValue]
            )
            return db.changesCount > 0
        }
    }

    static func declaredPolicy(_ db: Database, scope: HistoryScope) throws -> HistoryPolicy? {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM history_policy WHERE scope = ? AND scope_ref = ?
                """,
            arguments: [scope.canonicalName, scope.scopeRef]
        )
        var values: [String: (Bool, Int)] = [:]
        for row in rows {
            let kind: String = row["policy_kind"]
            let value: Int = row["policy_value"]
            let version: Int = Int(row["policy_version"] as String) ?? 0
            values[kind] = (value == 1, version)
        }
        guard let applySeen = values["apply_seen"],
              let showOverlay = values["show_overlay"],
              let autoExclude = values["auto_exclude"]
        else { return nil }
        let version = max(applySeen.1, max(showOverlay.1, autoExclude.1))
        guard version > 0 else { return nil }
        return try? HistoryPolicy(
            scope: scope,
            applySeen: applySeen.0,
            showOverlay: showOverlay.0,
            autoExclude: autoExclude.0,
            version: version
        )
    }
}
