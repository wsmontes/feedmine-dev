import Foundation
import GRDB

/// The runtime database: location, configuration and lifecycle.
///
/// Only one logical writer, WAL and foreign keys on every connection (plan §6, ADR-004 D4).
/// The schema authority is the migrator; PR-03 adds the remaining tables. This type deliberately
/// does not reuse the catalogue's rebuild behaviour (`SQLiteCatalogStore` writes a temp file and
/// replaces the database), because runtime tables are durable and must never be replaced by a
/// catalogue rebuild.
public struct RuntimeDatabaseLocation: Sendable, Hashable {
    /// `Application Support/Feedmine/RuntimeV2/` in the app; any directory in tests.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationSupport(_ applicationSupportDirectory: URL) -> Self {
        Self(directory: applicationSupportDirectory
            .appendingPathComponent("Feedmine", isDirectory: true)
            .appendingPathComponent("RuntimeV2", isDirectory: true))
    }

    /// The single name used by every component (plan §6). Do not spell it differently anywhere.
    public var databaseURL: URL {
        directory.appendingPathComponent("runtime-v2.sqlite", isDirectory: false)
    }
}

public enum RuntimeDatabaseError: Error, Equatable, Sendable {
    case couldNotCreateDirectory(String)
    case open(String)
    case transaction(String)
    /// A storage failure carrying SQLite's own result code.
    ///
    /// ADR-004 D9 requires a full disk to be told apart from every other write refusal: the disk-full
    /// path keeps the previous state usable and reclaims space, while a constraint violation is a
    /// caller error that retrying will repeat. Reporting both as "the transaction failed" is the state
    /// that made that distinction unimplementable.
    case storage(code: Int, message: String)
}

/// Owns the GRDB pool for `runtime-v2.sqlite`.
public final class RuntimeDatabase: Sendable {
    public let location: RuntimeDatabaseLocation
    public let pool: DatabasePool

    /// Opens (creating if needed) the runtime database at `location` and applies `migrator`.
    ///
    /// - Throws: `RuntimeDatabaseError` when the directory cannot be created or the database
    ///   cannot be opened or migrated. A failure never falls back to an in-memory database: a
    ///   durable state store that silently loses its contents is worse than a controlled failure.
    public init(
        location: RuntimeDatabaseLocation,
        migrator: DatabaseMigrator = RuntimeMigrations.current,
        fileManager: FileManager = .default
    ) throws {
        self.location = location

        do {
            try fileManager.createDirectory(
                at: location.directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RuntimeDatabaseError.couldNotCreateDirectory("\(error)")
        }

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { database in
            // Foreign keys are per-connection in SQLite; GRDB's flag only applies to the
            // connections it opens itself, so the pragma is stated explicitly as well.
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        do {
            self.pool = try DatabasePool(path: location.databaseURL.path, configuration: configuration)
            var migrator = migrator
            migrator.eraseDatabaseOnSchemaChange = false
            try migrator.migrate(pool)
        } catch {
            throw RuntimeDatabaseError.open("\(error)")
        }
    }

    /// One write transaction. Schema and mutators added by later PRs use this entry point so a
    /// single logical writer is preserved.
    public func write<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try pool.write(body)
        } catch let error as RuntimeDatabaseError {
            throw error
        } catch let error as DatabaseError {
            // A database failure is wrapped so callers can tell storage problems from their own
            // errors, and SQLite's result code travels with it so the disk-full path is reachable
            // (ADR-004 D9). Any other error was thrown by the body on purpose and keeps its type: the
            // type of a typed rejection must not be lost inside a string (ADR-006 D5).
            throw RuntimeDatabaseError.storage(code: Int(error.resultCode.rawValue), message: "\(error)")
        } catch {
            throw error
        }
    }

    /// Read access. Reads may run concurrently with the writer under WAL.
    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.read(body)
    }

    /// Flushes the write-ahead log into the database file.
    ///
    /// ADR-004 D3 requires a WAL-aware copy before any file may be called a backup, and D8 makes
    /// checkpointing part of maintenance rather than collection: this never deletes `-wal`/`-shm`
    /// while a connection holds them, it folds their committed frames into the main file. It runs
    /// outside a transaction because SQLite refuses `wal_checkpoint` inside one.
    @discardableResult
    public func checkpointWAL(mode: WALCheckpointMode = .truncate) throws -> Int {
        try pool.writeWithoutTransaction { database in
            try Int.fetchOne(database, sql: "PRAGMA wal_checkpoint(\(mode.sql))") ?? 0
        }
    }

    public enum WALCheckpointMode: String, Sendable, CaseIterable {
        case passive
        case full
        case truncate
        case restart

        var sql: String { rawValue.uppercased() }
    }
}

/// Derived compatibility metadata. It describes the schema for diagnostics and for the
/// compatibility window in ADR-004; it is not an independent migration counter.
///
/// The GRDB migrator remains the single schema authority: a value here can never disagree with
/// `grdb_migrations` because nothing in the runtime decides compatibility from it (ADR-004 D4).
public enum RuntimeMetadata {
    public static let schemaVersionKey = "runtime_schema_version"
    /// Which runtime schema this database holds (`runtime-v2`).
    public static let schemaNameKey = "schema_name"
    public static let schemaName = "runtime-v2"

    public static func read(_ database: Database, key: String = schemaVersionKey) throws -> String? {
        try String.fetchOne(
            database,
            sql: "SELECT value FROM runtime_metadata WHERE key = ?",
            arguments: [key]
        )
    }

    public static func write(
        _ database: Database,
        value: String,
        forKey key: String = schemaVersionKey
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO runtime_metadata (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value]
        )
    }
}
