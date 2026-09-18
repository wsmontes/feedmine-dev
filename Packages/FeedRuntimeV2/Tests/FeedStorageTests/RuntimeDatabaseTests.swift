import XCTest
import GRDB
@testable import FeedStorage

final class RuntimeDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("feedruntime-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testUsesTheSingleCanonicalFileNameUnderRuntimeV2() {
        let location = RuntimeDatabaseLocation.applicationSupport(URL(fileURLWithPath: "/app-support"))
        XCTAssertEqual(location.databaseURL.lastPathComponent, "runtime-v2.sqlite")
        XCTAssertEqual(location.directory.lastPathComponent, "RuntimeV2")
        XCTAssertEqual(location.directory.deletingLastPathComponent().lastPathComponent, "Feedmine")
    }

    func testCreatesDirectoryAndDatabaseOnFirstOpen() throws {
        let location = RuntimeDatabaseLocation(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.databaseURL.path))

        _ = try RuntimeDatabase(location: location)

        XCTAssertTrue(FileManager.default.fileExists(atPath: location.databaseURL.path))
    }

    func testWriteAheadLoggingIsOn() throws {
        let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        let mode: String = try database.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") ?? "" }
        XCTAssertEqual(mode.lowercased(), "wal")
    }

    /// Foreign keys are per connection: the guarantee must hold on the reader connection too, not
    /// only in the configuration used to open the pool.
    func testForeignKeysAreEnforcedOnWriteAndReadConnections() throws {
        let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE parent (id INTEGER PRIMARY KEY);
                CREATE TABLE child (
                    id INTEGER PRIMARY KEY,
                    parent_id INTEGER NOT NULL REFERENCES parent(id)
                )
                """)
        }

        let writerEnabled: Int = try database.write { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") ?? 0 }
        let readerEnabled: Int = try database.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") ?? 0 }
        XCTAssertEqual(writerEnabled, 1)
        XCTAssertEqual(readerEnabled, 1)

        XCTAssertThrowsError(
            try database.write { db in
                try db.execute(sql: "INSERT INTO child (id, parent_id) VALUES (1, 404)")
            },
            "a child row without its parent must be refused"
        )

        try database.write { db in
            try db.execute(sql: "INSERT INTO parent (id) VALUES (404)")
            try db.execute(sql: "INSERT INTO child (id, parent_id) VALUES (1, 404)")
        }
        let count: Int = try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM child") ?? 0 }
        XCTAssertEqual(count, 1)
    }

    func testReopeningPreservesDurableState() throws {
        let location = RuntimeDatabaseLocation(directory: directory)
        do {
            let database = try RuntimeDatabase(location: location)
            try database.write { db in
                try RuntimeMetadata.write(db, value: "1")
            }
        }

        let reopened = try RuntimeDatabase(location: location)
        let version = try reopened.read { try RuntimeMetadata.read($0) }
        XCTAssertEqual(version, "1", "durable state must survive a reopen, not be recreated")
    }

    func testMetadataWriteIsUpsertNotDuplicate() throws {
        let database = try RuntimeDatabase(location: RuntimeDatabaseLocation(directory: directory))
        try database.write { db in
            try RuntimeMetadata.write(db, value: "1")
            try RuntimeMetadata.write(db, value: "2")
        }
        let value = try database.read { try RuntimeMetadata.read($0) }
        XCTAssertEqual(value, "2")
    }

    /// A schema this build does not know must not be erased. The migrator is configured with
    /// `eraseDatabaseOnSchemaChange = false`; this test pins that configuration.
    func testOpeningAnUnrelatedDatabaseDoesNotDropItsTables() throws {
        let location = RuntimeDatabaseLocation(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: location.databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE foreign_runtime_table (id INTEGER PRIMARY KEY)")
        }

        let database = try RuntimeDatabase(location: location)

        let exists = try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE name = 'foreign_runtime_table'
                """) ?? false
        }
        XCTAssertTrue(exists, "an unknown table in the database must survive opening")
    }
}
