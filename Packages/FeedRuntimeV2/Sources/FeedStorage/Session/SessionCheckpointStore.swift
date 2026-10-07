import Foundation
import GRDB
import FeedDomain

/// The session cursor's only persistence (ADR-002 D8, ADR-007 `session_checkpoint`).
///
/// A checkpoint is what makes a warm restore possible without Selection, catalog or network: it names
/// the edition that was visible, the card the reader was on, how far past that card they had scrolled
/// and the render environment and history policy in force. Restoring reads this row and the published
/// rows and nothing else.
///
/// The row is keyed by `context_key`, so one surface cannot overwrite another surface's cursor, and a
/// composite foreign key makes the anchor name a card of its own edition.
public enum SessionCheckpointError: Error, Equatable, Sendable {
    case malformedContextKey(String)
    case malformedEditionID(Int64)
    case malformedCardID(Int64)
    case malformedRenderEnvironment(String)
}

public struct SessionCheckpointStore: Sendable {
    private let database: RuntimeDatabase

    public init(database: RuntimeDatabase) {
        self.database = database
    }

    /// Writes (or replaces) the cursor of one context.
    ///
    /// - Returns: `true` when the stored cursor changed. A repeat write of the same cursor is a no-op
    ///   rather than a new row, which is what keeps a milestone flush idempotent.
    @discardableResult
    public func save(_ checkpoint: SessionCheckpoint) throws -> Bool {
        try database.write { db in
            let existing = try Self.load(db, contextKey: checkpoint.context.canonicalSerialization)
            if let existing, existing == checkpoint { return false }
            try db.execute(
                sql: """
                    INSERT INTO session_checkpoint (
                        context_key, edition_id, publication_card_id, absolute_ordinal,
                        anchor_offset_fraction, render_environment_revision, policy_version, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(context_key) DO UPDATE SET
                        edition_id = excluded.edition_id,
                        publication_card_id = excluded.publication_card_id,
                        absolute_ordinal = excluded.absolute_ordinal,
                        anchor_offset_fraction = excluded.anchor_offset_fraction,
                        render_environment_revision = excluded.render_environment_revision,
                        policy_version = excluded.policy_version,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    checkpoint.context.canonicalSerialization,
                    checkpoint.editionID.rawValue,
                    checkpoint.anchor.cardID.rawValue,
                    checkpoint.anchor.absoluteOrdinal,
                    checkpoint.anchor.offsetFraction,
                    checkpoint.renderEnvironmentRevision.canonicalSerialization,
                    checkpoint.policyVersion,
                    checkpoint.updatedAtMs,
                ]
            )
            // The text this context used before fields were escaped is retired with the write: one
            // context keeping two rows would leave the cursor depending on which row a read finds first.
            let legacy = checkpoint.context.legacySerialization
            if legacy != checkpoint.context.canonicalSerialization {
                try db.execute(
                    sql: "DELETE FROM session_checkpoint WHERE context_key = ?",
                    arguments: [legacy]
                )
            }
            return true
        }
    }

    /// Reads the cursor of one context, or `nil` when the surface has never been visited.
    ///
    /// A row written before context fields were escaped under a different text is still this context's
    /// row: this lookup asked for the context, so the requested context — not the ambiguous split of the
    /// stored text — is what the checkpoint belongs to (ADR-002 D1; V2-12).
    public func load(context: ContextKey) throws -> SessionCheckpoint? {
        try database.read { db in
            if let current = try Self.load(db, contextKey: context.canonicalSerialization) {
                return current
            }
            let legacy = context.legacySerialization
            guard legacy != context.canonicalSerialization,
                  let stored = try Self.load(db, contextKey: legacy)
            else { return nil }
            return SessionCheckpoint(
                context: context,
                editionID: stored.editionID,
                anchor: stored.anchor,
                renderEnvironmentRevision: stored.renderEnvironmentRevision,
                policyVersion: stored.policyVersion,
                updatedAtMs: stored.updatedAtMs
            )
        }
    }

    @discardableResult
    public func clear(context: ContextKey) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM session_checkpoint WHERE context_key = ?",
                arguments: [context.canonicalSerialization]
            )
            var cleared = db.changesCount > 0
            // A row left under the pre-escape text is this context's row too (V2-12).
            let legacy = context.legacySerialization
            if legacy != context.canonicalSerialization {
                try db.execute(
                    sql: "DELETE FROM session_checkpoint WHERE context_key = ?",
                    arguments: [legacy]
                )
                cleared = cleared || db.changesCount > 0
            }
            return cleared
        }
    }

    public func storedCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_checkpoint") ?? 0
        }
    }

    // MARK: - Row mapping

    private static func load(_ db: Database, contextKey: String) throws -> SessionCheckpoint? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM session_checkpoint WHERE context_key = ?",
            arguments: [contextKey]
        ) else { return nil }
        return try decode(row)
    }

    private static func decode(_ row: Row) throws -> SessionCheckpoint {
        let contextKey: String = row["context_key"]
        let editionRaw: Int64 = row["edition_id"]
        let cardRaw: Int64 = row["publication_card_id"]
        let renderEnvironment: String = row["render_environment_revision"]

        guard let context = decodeContext(contextKey) else {
            throw SessionCheckpointError.malformedContextKey(contextKey)
        }
        guard editionRaw > 0 else { throw SessionCheckpointError.malformedEditionID(editionRaw) }
        guard cardRaw > 0 else { throw SessionCheckpointError.malformedCardID(cardRaw) }
        guard let environment = decodeRenderEnvironment(renderEnvironment) else {
            throw SessionCheckpointError.malformedRenderEnvironment(renderEnvironment)
        }
        let editionID = try EditionID(editionRaw)
        let cardID = try PublicationCardID(cardRaw)
        let ordinal: Int = row["absolute_ordinal"]
        let fraction: Double = row["anchor_offset_fraction"]
        let anchor = try FeedWindowAnchor(
            editionID: editionID,
            cardID: cardID,
            absoluteOrdinal: ordinal,
            offsetFraction: fraction
        )
        return SessionCheckpoint(
            context: context,
            editionID: editionID,
            anchor: anchor,
            renderEnvironmentRevision: environment,
            policyVersion: row["policy_version"],
            updatedAtMs: row["updated_at_ms"]
        )
    }

    /// A stored `context_key`, read back.
    ///
    /// The escaped form is tried first: every field is escaped there, so the split is exact. A row
    /// written before that is read with the bounded split the previous build used — the best reading
    /// available for text that was itself ambiguous, and one a lookup by context replaces with the
    /// context it was asked for (V2-12).
    private static func decodeContext(_ text: String) -> ContextKey? {
        if let context = ContextKey(canonicalText: text) { return context }
        let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let surface = ContextKey.Surface(rawValue: String(parts[0])) else { return nil }
        return try? ContextKey(
            surface: surface,
            scopeKey: String(parts[1]),
            planIdentity: String(parts[2])
        )
    }

    private static func decodeRenderEnvironment(_ text: String) -> RenderEnvironmentRevision? {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5, let scale = Int(parts[4]) else { return nil }
        return try? RenderEnvironmentRevision(
            layoutWidthClass: String(parts[0]),
            dynamicTypeSize: String(parts[1]),
            localeIdentifier: String(parts[2]),
            textDirection: String(parts[3]),
            displayScale: scale
        )
    }
}
