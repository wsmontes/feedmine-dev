import Foundation
import GRDB
import FeedDomain

/// Runtime-side projection of durable user state (plan §6 "Projeções" and §5.2).
///
/// `user.sqlite` is the authority for bookmark identity and intention (ADR-004 D1). This store holds
/// what the runtime needs to know about that state — which subjects the user saved or removed — plus
/// its own watermark, because a projection in a second database can never pretend to be a
/// transactional snapshot of the first (plan §6: "projeções do estado em outro banco carregam
/// watermark próprio").
public struct UserStateProjectionStore: Sendable {
    public struct Projection: Hashable, Sendable {
        public let kind: SubjectKind
        public let subjectID: String
        /// `true` = the user saved it, `false` = the user removed it. The removal is kept: a
        /// projection that simply forgot the row could not tell "never saved" from "removed".
        public let wanted: Bool
        public let lastOperationID: String
        public let revision: Int64
        public let updatedAt: Date
    }

    public struct Watermark: Hashable, Sendable {
        public let revision: Int64
        public let updatedAt: Date?
    }

    private let database: RuntimeDatabase

    public init(database: RuntimeDatabase) {
        self.database = database
    }

    /// Applies one operation idempotently and returns the resulting revision.
    ///
    /// Replaying the same `operationID` is a no-op that still answers with the current revision, so a
    /// caller whose response was lost can retry without a second write (plan §5.2 step 3).
    @discardableResult
    public func apply(
        kind: SubjectKind,
        subjectID: String,
        wanted: Bool,
        operationID: String,
        at: Date
    ) throws -> Int64 {
        let timestamp = at.timeIntervalSince1970
        return try database.write { db in
            let alreadyApplied = try String.fetchOne(
                db,
                sql: """
                    SELECT last_operation_id FROM user_state_projection
                    WHERE kind = ? AND subject_id = ?
                    """,
                arguments: [kind.rawValue, subjectID]
            ) == operationID
            if alreadyApplied {
                return try Self.currentRevision(db)
            }

            let revision = try Self.currentRevision(db) + 1
            try db.execute(sql: """
                INSERT INTO user_state_projection
                    (kind, subject_id, wanted, last_operation_id, revision, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, subject_id) DO UPDATE SET
                    wanted = excluded.wanted,
                    last_operation_id = excluded.last_operation_id,
                    revision = excluded.revision,
                    updated_at = excluded.updated_at
                """, arguments: [kind.rawValue, subjectID, wanted ? 1 : 0, operationID, revision, timestamp])

            try db.execute(sql: """
                INSERT INTO user_state_watermark (id, revision, updated_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, updated_at = excluded.updated_at
                """, arguments: [revision, timestamp])
            return revision
        }
    }

    /// Applies one list membership idempotently and returns the resulting revision.
    ///
    /// Separate from `apply(kind:subjectID:wanted:operationID:at:)` on purpose: a subject's *wanted*
    /// state is not per list — one bookmark can sit in the default list and in two boxes at once — so
    /// the two facts have two keys and two rows. The revision is the same watermark, because a reader
    /// detecting what changed between two projections must not see two counters.
    ///
    /// Replaying the same `operationID` for the same list and subject is a no-op that still answers
    /// with the current revision, the way its sibling does (plan §5.2 step 3).
    @discardableResult
    public func applyListMembership(
        listKey: String,
        subjectID: String,
        wanted: Bool,
        operationID: String,
        at: Date
    ) throws -> Int64 {
        let timestamp = at.timeIntervalSince1970
        return try database.write { db in
            let alreadyApplied = try String.fetchOne(
                db,
                sql: """
                    SELECT last_operation_id FROM user_list_membership
                    WHERE list_key = ? AND subject_id = ?
                    """,
                arguments: [listKey, subjectID]
            ) == operationID
            if alreadyApplied {
                return try Self.currentRevision(db)
            }

            let revision = try Self.currentRevision(db) + 1
            try db.execute(sql: """
                INSERT INTO user_list_membership
                    (list_key, subject_id, wanted, last_operation_id, revision, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(list_key, subject_id) DO UPDATE SET
                    wanted = excluded.wanted,
                    last_operation_id = excluded.last_operation_id,
                    revision = excluded.revision,
                    updated_at = excluded.updated_at
                """, arguments: [listKey, subjectID, wanted ? 1 : 0, operationID, revision, timestamp])

            try db.execute(sql: """
                INSERT INTO user_state_watermark (id, revision, updated_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, updated_at = excluded.updated_at
                """, arguments: [revision, timestamp])
            return revision
        }
    }

    public func projection(kind: SubjectKind, subjectID: String) throws -> Projection? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT wanted, last_operation_id, revision, updated_at
                    FROM user_state_projection WHERE kind = ? AND subject_id = ?
                    """,
                arguments: [kind.rawValue, subjectID]
            ).map { row in
                Projection(
                    kind: kind,
                    subjectID: subjectID,
                    wanted: row["wanted"] as Int64 == 1,
                    lastOperationID: row["last_operation_id"],
                    revision: row["revision"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }

    public func watermark() throws -> Watermark {
        try database.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT revision, updated_at FROM user_state_watermark WHERE id = 1")
            return Watermark(
                revision: (row?["revision"] as Int64?) ?? 0,
                updatedAt: (row?["updated_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// Every subject the runtime believes the user saved. This is a projection: the authority is
    /// `user.sqlite`, so a mismatch is repaired by replaying operations, never by trusting this list.
    public func savedSubjects(kind: SubjectKind = .bookmark) throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT subject_id FROM user_state_projection
                    WHERE kind = ? AND wanted = 1 ORDER BY subject_id
                    """,
                arguments: [kind.rawValue]
            )
        }
    }

    /// One list membership, when the projection has one. `nil` is "this subject was never filed into
    /// this list", which is not the same as `wanted == false`: a removal is a row that says so.
    public func listMembership(listKey: String, subjectID: String) throws -> ListMembership? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT wanted, last_operation_id, revision, updated_at
                    FROM user_list_membership WHERE list_key = ? AND subject_id = ?
                    """,
                arguments: [listKey, subjectID]
            ).map { row in
                ListMembership(
                    listKey: listKey,
                    subjectID: subjectID,
                    wanted: row["wanted"] as Int64 == 1,
                    lastOperationID: row["last_operation_id"],
                    revision: row["revision"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }

    /// One list membership as the projection holds it.
    public struct ListMembership: Hashable, Sendable {
        public let listKey: String
        public let subjectID: String
        /// `true` = filed into this list, `false` = removed from it. The removal is kept, like its
        /// whole-set sibling's (ADR-004 D7).
        public let wanted: Bool
        public let lastOperationID: String
        public let revision: Int64
        public let updatedAt: Date
    }

    private static func currentRevision(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT revision FROM user_state_watermark WHERE id = 1") ?? 0
    }
}
