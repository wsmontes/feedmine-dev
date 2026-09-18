import Foundation
import GRDB

/// Why a database is not usable as it stands (ADR-004 D9).
///
/// The three reasons are the three ways D9 forbids a silent empty database: corruption, a full disk,
/// and a schema written by a build this one does not contain. Each one ends in a state a caller can
/// act on — read-only with the damaged file preserved, degraded with the previous state usable, or a
/// controlled refusal — never in "there was nothing here".
public enum RecoveryReason: Hashable, Sendable {
    /// `PRAGMA integrity_check` or `PRAGMA foreign_key_check` failed.
    case corruption(String)
    /// SQLite refused a write with `SQLITE_FULL`: the previous state stands and space must be reclaimed.
    case diskFull
    /// The database carries migrations this build does not contain. An older build must not read it.
    case unknownSchemaVersion(unknown: [String])
    /// A publication schema version outside this build's supported set (ADR-001 D9, INV-13).
    case incompatiblePublicationSchema(Int)

    public var summary: String {
        switch self {
        case let .corruption(detail): return "corruption: \(detail)"
        case .diskFull: return "disk full"
        case let .unknownSchemaVersion(unknown):
            return "unknown schema version: \(unknown.joined(separator: ", "))"
        case let .incompatiblePublicationSchema(version):
            return "incompatible publication schema \(version)"
        }
    }

    /// Whether the reason describes the *edition*, not the database: an edition this build cannot
    /// decode is a cold/recovery start, and the rest of the database stays readable.
    public var isEditionScoped: Bool {
        if case .incompatiblePublicationSchema = self { return true }
        return false
    }
}

/// What the inspection or the rebuild concluded.
public enum RecoveryOutcome: Hashable, Sendable {
    /// Nothing to recover: the database exists and passes its own checks, or does not exist yet.
    case healthy
    /// Durable state exists and cannot be trusted. The damaged files are preserved, not overwritten.
    case readOnly(reason: RecoveryReason, quarantined: [URL])
    /// A controlled rebuild: the damaged files were quarantined and a fresh, migrated, verified
    /// database now sits at the same location.
    case rebuilt(into: URL, quarantined: [URL], reason: RecoveryReason)
    /// A write was refused with the previous state still on disk. Reclaiming space and retrying is the
    /// caller's move; nothing was deleted to make room (ADR-004 D9).
    case degraded(reason: RecoveryReason, detail: String)

    public var isUsable: Bool {
        switch self {
        case .healthy, .rebuilt, .degraded: return true
        case .readOnly: return false
        }
    }
}

public struct RecoveryReport: Hashable, Sendable {
    public let outcome: RecoveryOutcome
    public let databaseURL: URL
    public let quarantineDirectory: URL?
    public let detail: String

    public var summary: String {
        switch outcome {
        case .healthy: return "healthy: \(detail)"
        case let .readOnly(reason, _): return "readOnly: \(reason.summary)"
        case let .rebuilt(into, _, reason): return "rebuilt into \(into.lastPathComponent): \(reason.summary)"
        case let .degraded(reason, _): return "degraded: \(reason.summary)"
        }
    }
}

public enum RecoveryError: Error, Equatable, Sendable {
    case couldNotQuarantine(String)
    case rebuildDidNotVerify(String)
}

/// The recovery paths of ADR-004 D9, as code rather than as a policy statement.
///
/// Two operations, and the difference between them is the whole decision:
///
/// * `inspect` opens the database **read-only** and reports what it finds. It never writes, never
///   erases, and never returns "healthy" for a database it could not read — a pre-existing database
///   with an unknown schema version fails in a controlled way instead of being auto-erased;
/// * `rebuild` is the *authorised* destructive step: it quarantines the damaged files (a move, so the
///   bytes survive for diagnosis) and creates a fresh database at the same location. It is never called
///   implicitly, which is what keeps "the database was empty" from being something that happens by
///   accident.
public struct RuntimeRecovery: Sendable {
    public init() {}

    /// Where quarantined files are preserved. One directory per recovery: a second corruption must not
    /// overwrite the evidence of the first.
    public func quarantineDirectory(
        for location: RuntimeDatabaseLocation,
        at date: Date
    ) -> URL {
        let stamp = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return location.directory.appendingPathComponent("quarantine-\(stamp)", isDirectory: true)
    }

    /// Opens the database read-only and reports its state.
    ///
    /// - Throws: only when the database cannot be examined at all (the directory is unreadable). A
    ///   database that is *damaged* is a result (`.readOnly`), not a thrown error.
    public func inspect(_ location: RuntimeDatabaseLocation) throws -> RecoveryReport {
        guard FileManager.default.fileExists(atPath: location.databaseURL.path) else {
            // A first launch has nothing to recover: creating the file is what `RuntimeDatabase` does.
            return RecoveryReport(
                outcome: .healthy,
                databaseURL: location.databaseURL,
                quarantineDirectory: nil,
                detail: "no database exists yet at \(location.databaseURL.lastPathComponent)"
            )
        }

        let queue: DatabaseQueue
        do {
            queue = try Self.openReadOnly(at: location.databaseURL.path)
        } catch {
            return unreadable(location, "the database could not be opened: \(error)")
        }

        do {
            let integrity: String = try queue.read {
                try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "unknown"
            }
            guard integrity == "ok" else {
                return RecoveryReport(
                    outcome: .readOnly(reason: .corruption(integrity), quarantined: []),
                    databaseURL: location.databaseURL,
                    quarantineDirectory: nil,
                    detail: "integrity_check answered \(integrity)"
                )
            }
            let dangling = try queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
            guard dangling == 0 else {
                return RecoveryReport(
                    outcome: .readOnly(reason: .corruption("\(dangling) dangling foreign key(s)"), quarantined: []),
                    databaseURL: location.databaseURL,
                    quarantineDirectory: nil,
                    detail: "foreign_key_check reported \(dangling) row(s)"
                )
            }
            let applied = try queue.read {
                try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            }
            let known = Set(RuntimeMigrations.knownMigrationIdentifiers)
            let unknown = applied.filter { !known.contains($0) }
            guard unknown.isEmpty else {
                return RecoveryReport(
                    outcome: .readOnly(reason: .unknownSchemaVersion(unknown: unknown), quarantined: []),
                    databaseURL: location.databaseURL,
                    quarantineDirectory: nil,
                    detail: "the database carries migration(s) this build does not contain: "
                        + unknown.joined(separator: ", ")
                )
            }
            return RecoveryReport(
                outcome: .healthy,
                databaseURL: location.databaseURL,
                quarantineDirectory: nil,
                detail: "integrity_check=ok foreign_keys=0 migrations=\(applied.count)"
            )
        } catch {
            return unreadable(location, "the database could not be read: \(error)")
        }
    }

    /// Quarantines the current files and builds a fresh database at the same location.
    ///
    /// - Returns: `.rebuilt` once the new database migrates and verifies. Nothing here is implicit: a
    ///   caller reaching this method has decided that the previous state is unrecoverable, and the
    ///   previous bytes are still on disk afterwards.
    @discardableResult
    public func rebuild(
        _ location: RuntimeDatabaseLocation,
        reason: RecoveryReason,
        at date: Date
    ) throws -> RecoveryReport {
        let quarantine = quarantineDirectory(for: location, at: date)
        do {
            try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        } catch {
            throw RecoveryError.couldNotQuarantine("\(error)")
        }
        var quarantined: [URL] = []
        // The database travels with its WAL companions: a copy of the `.sqlite` file alone can lose the
        // committed tail (ADR-004 D3), and that is exactly the state a corruption report is about.
        for name in Self.databaseFileNames {
            let source = location.directory.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = quarantine.appendingPathComponent(name, isDirectory: false)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                quarantined.append(destination)
            } catch {
                throw RecoveryError.couldNotQuarantine("\(error)")
            }
        }

        let database: RuntimeDatabase
        do {
            database = try RuntimeDatabase(location: location)
        } catch {
            throw RecoveryError.rebuildDidNotVerify("the fresh database did not migrate: \(error)")
        }
        let integrity = try database.read {
            try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "unknown"
        }
        let dangling = try database.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
        guard integrity == "ok", dangling == 0 else {
            throw RecoveryError.rebuildDidNotVerify(
                "integrity_check=\(integrity) foreign_keys=\(dangling)"
            )
        }
        return RecoveryReport(
            outcome: .rebuilt(into: location.databaseURL, quarantined: quarantined, reason: reason),
            databaseURL: location.databaseURL,
            quarantineDirectory: quarantine,
            detail: "\(reason.summary); \(quarantined.count) file(s) preserved in "
                + "\(quarantine.lastPathComponent)"
        )
    }

    /// Classifies a thrown storage failure.
    ///
    /// `SQLITE_FULL` is the one D9 gives a path of its own: the write is refused, the previous state is
    /// what a caller must keep serving, and the move is to reclaim space rather than to retry blindly.
    /// Every other code is answered as "not one of the named recovery paths", which is a decision too.
    public static func reason(for error: Error) -> RecoveryReason? {
        guard let databaseError = error as? DatabaseError else {
            if let runtimeError = error as? RuntimeDatabaseError,
               case let .storage(code, message) = runtimeError
            {
                return reason(forResultCode: code, message: message)
            }
            return nil
        }
        return reason(forResultCode: Int(databaseError.resultCode.rawValue), message: "\(databaseError)")
    }

    static func reason(forResultCode code: Int, message: String) -> RecoveryReason? {
        if code == Int(ResultCode.SQLITE_FULL.rawValue) {
            return .diskFull
        }
        if code == Int(ResultCode.SQLITE_CORRUPT.rawValue)
            || code == Int(ResultCode.SQLITE_NOTADB.rawValue)
        {
            return .corruption(message)
        }
        return nil
    }

    /// The report a database D9 forbids decoding is replaced by: read-only, with the reason recorded.
    public static func editionReason(for outcome: EditionRestoreOutcome) -> RecoveryReason? {
        switch outcome {
        case .restored, .noEdition:
            return nil
        case let .unsupportedPublicationSchemaVersion(version):
            return .incompatiblePublicationSchema(version)
        case let .payloadCorrupted(cardID, reason):
            return .corruption("card \(cardID.rawValue): \(reason)")
        }
    }

    static let databaseFileNames = [
        "runtime-v2.sqlite",
        "runtime-v2.sqlite-wal",
        "runtime-v2.sqlite-shm",
    ]

    /// Opens the database without write access, through `SQLITE_OPEN_READONLY`.
    ///
    /// GRDB's `Configuration.readOnly` is the *queue* flag; `DatabaseQueue(path:configuration:)` also
    /// needs the SQLite flag, and this initializer sets it. Inspection must not create a file, recover a
    /// `-wal` or migrate anything: the point is to describe what is on disk, not to change it.
    private static func openReadOnly(at path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = false
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    private func unreadable(
        _ location: RuntimeDatabaseLocation,
        _ detail: String
    ) -> RecoveryReport {
        RecoveryReport(
            outcome: .readOnly(reason: .corruption(detail), quarantined: []),
            databaseURL: location.databaseURL,
            quarantineDirectory: nil,
            detail: detail
        )
    }
}
