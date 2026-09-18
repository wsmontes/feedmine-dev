import Foundation
import GRDB

/// The retention classes of ADR-004 D8, in the vocabulary `retention_policy.class` stores.
///
/// Two of them are not collection targets at all and are still classes here, because a run has to
/// say what it did with them: `durableUserState` is marked "never collected" by D8 — the user's own
/// rows are deleted by the user, never by quota — and `diagnostics` belongs to a file this database
/// does not own. Reporting them as skipped is what keeps "GC ran" from meaning "GC looked at
/// everything".
public enum RetentionClass: String, Hashable, Sendable, CaseIterable {
    /// In-memory and on-disk decoded bitmaps. Discardable at any moment (INV-10).
    case decodedCache = "decoded_cache"
    /// Bytes that never became a published asset: orphan temporary files and unreferenced versions.
    case unpublishedDownloads = "unpublished_downloads"
    /// Published bytes whose references were all released. Identity survives; the files do not.
    case publishedAssetBytes = "published_asset_bytes"
    /// `selection_supply` and the search projection: rebuildable from canonical supply.
    case reconstructibleProjections = "reconstructible_projections"
    /// Raw connector payload kept for audit and identity proof.
    case connectorEvidence = "connector_evidence"
    /// `origin_revision` rows no durable fact needs any more.
    case canonicalSupply = "canonical_supply"
    /// Superseded editions beyond the retained count.
    case publication = "publication"
    /// `-wal`/`-shm`: pass-through checkpoint during maintenance, never a delete while open.
    case walAndJournal = "wal_and_journal"
    /// The shadow database and counters, owned by the composition rather than by this database.
    case diagnostics = "diagnostics"
    /// The user's own rows. D8 gives this class **no knob**: declaring one is refused.
    case durableUserState = "durable_user_state"

    /// Whether D8 marks this class as never collected. A policy row for such a class is an error, not
    /// a limit: `retention_policy` would otherwise be the place where a silently quota-evicted
    /// bookmark is configured.
    public var isNeverCollected: Bool {
        self == .durableUserState
    }

    /// Whether the class is reached through the media port rather than through SQL.
    public var isMediaClass: Bool {
        self == .decodedCache || self == .unpublishedDownloads
    }

    /// Cheapest-to-recover first, which is the order D8 requires limits to run in. Two entries are
    /// ordered for a second reason: `publication` runs before `publishedAssetBytes` so bytes whose
    /// last reference this run released are collectable in the same run, and both run before
    /// `canonicalSupply`, because bytes can be fetched again while canonical rows would have to be
    /// re-admitted.
    public static let collectionOrder: [RetentionClass] = [
        .decodedCache,
        .publication,
        .unpublishedDownloads,
        .publishedAssetBytes,
        .reconstructibleProjections,
        .connectorEvidence,
        .canonicalSupply,
        .walAndJournal,
        .diagnostics,
        .durableUserState,
    ]
}

/// The declared limit of one class.
///
/// `nil` means "no limit of this kind was declared". A policy with all three `nil` is rejected at
/// declaration time (`retention_policy`'s CHECK says the same), because "declared but unlimited" is
/// exactly the state D8 forbids: a class with no limit is a class with no row.
public struct RetentionPolicy: Hashable, Sendable {
    public let retentionClass: RetentionClass
    public let maxAgeSeconds: Int64?
    public let maxBytes: Int64?
    public let maxEditions: Int?

    public init(
        retentionClass: RetentionClass,
        maxAgeSeconds: Int64? = nil,
        maxBytes: Int64? = nil,
        maxEditions: Int? = nil
    ) {
        self.retentionClass = retentionClass
        self.maxAgeSeconds = maxAgeSeconds
        self.maxBytes = maxBytes
        self.maxEditions = maxEditions
    }

    /// The age cutoff for a run at `now`.
    public func ageCutoffMilliseconds(now: Int64) -> Int64? {
        maxAgeSeconds.map { now - $0 * 1_000 }
    }
}

public enum RetentionPolicyError: Error, Equatable, Sendable {
    /// D8 marks the class never collected; a limit for it would be the bug the rule forbids.
    case classIsNeverCollected(RetentionClass)
    /// A policy with no limit at all. Omit the row instead.
    case emptyPolicy(RetentionClass)
}

/// The declared limits, read and written through the durable table.
///
/// An absent row is *not* read as unlimited: `policy(_:)` answers `nil` and the coordinator records
/// the class as skipped. That is the difference between "nobody declared a limit" and "the limit is
/// unlimited", and only the first is true here.
public struct RetentionPolicyStore: Sendable {
    private let database: RuntimeDatabase

    public init(database: RuntimeDatabase) {
        self.database = database
    }

    public func policy(_ retentionClass: RetentionClass) throws -> RetentionPolicy? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM retention_policy WHERE class = ?",
                arguments: [retentionClass.rawValue]
            ) else { return nil }
            return Self.policy(retentionClass, row)
        }
    }

    public func declaredClasses() throws -> [RetentionClass] {
        try database.read { database in
            try String.fetchAll(database, sql: "SELECT class FROM retention_policy ORDER BY class")
                .compactMap(RetentionClass.init(rawValue:))
        }
    }

    /// Declares (or replaces) one class's limits.
    ///
    /// - Throws: `RetentionPolicyError` when the class is never collected, or when the policy carries
    ///   no limit at all.
    public func declare(_ policy: RetentionPolicy) throws {
        guard !policy.retentionClass.isNeverCollected else {
            throw RetentionPolicyError.classIsNeverCollected(policy.retentionClass)
        }
        guard policy.maxAgeSeconds != nil || policy.maxBytes != nil || policy.maxEditions != nil else {
            throw RetentionPolicyError.emptyPolicy(policy.retentionClass)
        }
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO retention_policy (class, max_age_seconds, max_bytes, max_editions)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(class) DO UPDATE SET
                    max_age_seconds = excluded.max_age_seconds,
                    max_bytes = excluded.max_bytes,
                    max_editions = excluded.max_editions
                """, arguments: [
                policy.retentionClass.rawValue,
                policy.maxAgeSeconds,
                policy.maxBytes,
                policy.maxEditions,
            ])
        }
    }

    /// Removes a declaration, which returns the class to "no policy declared" rather than to
    /// "unlimited".
    @discardableResult
    public func remove(_ retentionClass: RetentionClass) throws -> Bool {
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM retention_policy WHERE class = ?",
                arguments: [retentionClass.rawValue]
            )
            return database.changesCount > 0
        }
    }

    private static func policy(_ retentionClass: RetentionClass, _ row: Row) -> RetentionPolicy {
        RetentionPolicy(
            retentionClass: retentionClass,
            maxAgeSeconds: row["max_age_seconds"],
            maxBytes: row["max_bytes"],
            maxEditions: row["max_editions"]
        )
    }
}

/// The durable facts that block collection (ADR-004 D8: "pins on a retention root block collection
/// unconditionally").
public struct RetentionRoots: Hashable, Sendable {
    /// Editions no run may purge: the active one, the checkpointed ones, and every edition holding a
    /// card reachable from a bookmark.
    ///
    /// The bookmark root is the one root this database cannot derive alone. With a
    /// `BookmarkSubjectProviding` authority attached, the reachable set is the union of the authority's
    /// saved subjects and the runtime's projection, so a projection that lags cannot open a window for
    /// a purge. Without one, the reachable set is the projection alone, and that is a stated limit
    /// rather than an assumption: it is what `RetentionCoordinator` reports in
    /// `GCRunReport.bookmarkRootSource`, and what reconciliation reports as an unmapped saved item.
    public let protectedEditions: Set<Int64>
    /// Canonical revisions a retained publication, an in-flight preparation or a durable mapping
    /// still needs.
    public let protectedRevisions: Set<Int64>
    /// Asset versions a retained publication or an in-flight preparation still names.
    public let protectedAssetVersions: Set<Int64>

    public init(
        protectedEditions: Set<Int64>,
        protectedRevisions: Set<Int64>,
        protectedAssetVersions: Set<Int64>
    ) {
        self.protectedEditions = protectedEditions
        self.protectedRevisions = protectedRevisions
        self.protectedAssetVersions = protectedAssetVersions
    }
}

/// The subjects the *authority* says the user saved.
///
/// `user.sqlite` owns bookmark rows (ADR-004 D7), and this database holds only a projection of them,
/// which can lag: the bridge writes the authoritative row first and projects afterwards. A run that
/// protected only the projection could therefore collect an edition whose bookmark exists. This port
/// is how the composition closes that window — it reads the authority and hands the subjects over, and
/// the root provider unions them with the projection instead of trusting one of the two.
public protocol BookmarkSubjectProviding: Sendable {
    func savedBookmarkSubjects() throws -> Set<String>
}

/// Where the roots come from. Injectable because reconciliation has to be provable against a set the
/// sweep *did* see: a test that hands the sweep a set with a pin missing is how "the pin was lost"
/// becomes an observable state instead of a story.
public protocol RetentionRootProviding: Sendable {
    /// Recomputes the roots from durable state.
    ///
    /// It is called **inside** the collection transaction, with the same `Database` the deletion will
    /// use, so the roots and the deletion see one snapshot: a pin committed before the transaction is
    /// honoured, and one committed after it belongs to a run that had already decided. SQLite's write
    /// lock is what makes that ordering hold — a concurrent writer waits for the transaction to finish,
    /// so no pin can appear between "the roots were read" and "the row was deleted".
    func roots(in database: Database) throws -> RetentionRoots

    /// Which world the roots came from, for the run's account.
    ///
    /// A requirement rather than only a default implementation, because a run reads it through
    /// `any RetentionRootProviding`: a description that existed only in an extension would describe
    /// every provider as the default and quietly lose the distinction it exists to make.
    var rootSourceDescription: String { get }
}

extension RetentionRootProviding {
    /// A provider that cannot describe itself says so, instead of leaving a reader to assume the
    /// strongest answer.
    public var rootSourceDescription: String { "an injected root provider" }
}

/// The production root provider: every root is derived from durable rows, never from memory.
///
/// The bookmark root is a *proxy* and is documented as one: the runtime knows a saved item as
/// `user_state_projection(kind = 'bookmark')`, whose subject is the legacy item id the bridge writes,
/// and reaches an edition through `legacy_item_map → published_card`. The authoritative bookmark
/// snapshot lives in `user.sqlite` (ADR-004 D7), so this root protects the edition whose cards the
/// runtime can still see — it never assumes there are no bookmarks.
public struct SqlRetentionRootProvider: RetentionRootProviding {
    /// The authority's saved subjects, when the composition can read them. `nil` means the run protects
    /// only what this database can see, which is the limit documented on `RetentionRoots`.
    private let authority: (any BookmarkSubjectProviding)?

    public init(authority: (any BookmarkSubjectProviding)? = nil) {
        self.authority = authority
    }

    public var rootSourceDescription: String {
        authority == nil
            ? "the runtime's own bookmark projection; user.sqlite is the authority and was not read"
            : "the authoritative saved subjects unioned with the runtime's projection"
    }

    public func roots(in database: Database) throws -> RetentionRoots {
        // The projection's subjects, plus the authority's when there is one. The union is deliberate:
        // a subject the authority has and the projection has not is a bookmark that exists, and a
        // subject the projection still has after a removal is one a purge must keep protecting until
        // the projection catches up. Neither alone is the safe set.
        var subjects = Set(
            try String.fetchAll(database, sql: """
                SELECT subject_id FROM user_state_projection WHERE kind = 'bookmark' AND wanted = 1
                """)
        )
        if let authority {
            subjects.formUnion((try? authority.savedBookmarkSubjects()) ?? [])
        }
        let savedPlaceholders = Array(repeating: "?", count: subjects.count).joined(separator: ", ")

        let editions = try Int64.fetchAll(database, sql: """
            SELECT edition_id FROM feed_edition WHERE state = 'active'
            UNION
            SELECT edition_id FROM session_checkpoint
            UNION
            SELECT c.edition_id
                FROM published_card c
                JOIN legacy_item_map m ON m.origin_record_id = c.origin_record_id
                JOIN user_state_projection p
                    ON p.kind = 'bookmark' AND p.subject_id = m.legacy_item_id
                WHERE p.subject_id IN (\(savedPlaceholders))
            UNION
            SELECT c.edition_id
                FROM published_card c
                JOIN legacy_item_map m ON m.origin_record_id = c.origin_record_id
                WHERE m.legacy_item_id IN (\(savedPlaceholders))
            """, arguments: StatementArguments(Array(subjects) + Array(subjects)))
        let revisions = try Int64.fetchAll(database, sql: """
            SELECT DISTINCT c.origin_revision_id
                FROM published_card c
                JOIN feed_edition e ON e.edition_id = c.edition_id
                WHERE e.state <> 'purged'
            UNION SELECT origin_revision_id FROM media_preparation
                WHERE state IN ('pending','in_flight')
            UNION SELECT origin_revision_id FROM legacy_item_map
                WHERE origin_revision_id IS NOT NULL
            UNION SELECT current_revision_id FROM origin_record
                WHERE current_revision_id IS NOT NULL
            """)
        let assets = try Int64.fetchAll(database, sql: """
            SELECT DISTINCT r.asset_version_id
                FROM published_asset_ref r
                JOIN published_card c ON c.publication_card_id = r.publication_card_id
                JOIN feed_edition e ON e.edition_id = c.edition_id
                WHERE e.state <> 'purged'
            UNION SELECT asset_version_id FROM media_preparation
                WHERE asset_version_id IS NOT NULL
            """)
        return RetentionRoots(
            protectedEditions: Set(editions),
            protectedRevisions: Set(revisions),
            protectedAssetVersions: Set(assets)
        )
    }
}
