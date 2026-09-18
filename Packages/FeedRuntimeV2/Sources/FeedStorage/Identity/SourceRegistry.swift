import Foundation
import GRDB
import FeedDomain

/// Where a runtime `SourceID` comes from (ADR-003 D2, D3, D18).
///
/// `source.id` is a local row identity, not a derived value: ADR-003 forbids turning a catalogue id, a
/// URL or a digest into a `SourceID`, and the runtime's answer to "does this source exist" is a durable
/// row keyed by the *editorial* key the catalogue declared. This registry is the only allocator: it
/// inserts the row on first sight of an editorial key and reads the same identity back afterwards, so
/// two calls for one source cannot produce two sources and a relaunch cannot produce a different one.
///
/// It allocates nothing else. A `source_membership` can only claim a source the runtime already owns
/// (`AdmissionEngine.firstUnknownMembershipSource` refuses the whole batch otherwise), so a connector
/// that is to enroll any content needs this allocation to have happened first — which is why the
/// composition root resolves its sources here before it registers their acquisition targets.
public struct RuntimeSourceRegistry: Sendable {
    private let clock: any EditorialClock

    public init(clock: any EditorialClock = SystemEditorialClock()) {
        self.clock = clock
    }

    /// The durable identity of one editorial source, allocated on first use.
    ///
    /// - Parameters:
    ///   - key: the catalogue's own durable key plus its canonicalization version.
    ///   - displayTitle: the title to record with a *new* row. An existing row keeps the title it was
    ///     created with: the identity is the editorial key, and a rename is a catalogue update rather
    ///     than a new source.
    ///   - kind: an optional connector-independent classification, stored verbatim and never interpreted.
    public func sourceID(
        for key: EditorialSourceKey,
        displayTitle: String,
        kind: String? = nil,
        in database: RuntimeDatabase
    ) throws -> SourceID {
        let now = AdmissionTimestamp.milliseconds(clock.now)
        let id: Int64 = try database.write { database in
            try database.execute(sql: """
                INSERT INTO source (
                    editorial_key, canonicalization_version, display_title, kind, created_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (editorial_key, canonicalization_version) DO NOTHING
                """, arguments: [
                key.catalogIdentity,
                key.canonicalizationVersion,
                displayTitle,
                kind,
                now,
            ])
            guard let id = try Int64.fetchOne(database, sql: """
                SELECT id FROM source WHERE editorial_key = ? AND canonicalization_version = ?
                """, arguments: [key.catalogIdentity, key.canonicalizationVersion]) else {
                throw RuntimeSourceRegistryError.allocationFailed(key.catalogIdentity)
            }
            return id
        }
        return try SourceID(UInt64(id))
    }

    /// The identity already allocated for this key, or `nil`. A read: nothing is created.
    public func existingSourceID(
        for key: EditorialSourceKey,
        in database: RuntimeDatabase
    ) throws -> SourceID? {
        try database.read { database in
            guard let id = try Int64.fetchOne(database, sql: """
                SELECT id FROM source WHERE editorial_key = ? AND canonicalization_version = ?
                """, arguments: [key.catalogIdentity, key.canonicalizationVersion]) else { return nil }
            return try SourceID(UInt64(id))
        }
    }

    /// The durable key of an allocated source, or `nil` when nothing holds that id.
    ///
    /// The key is the catalogue's own identity string for the source — for a syndication source that is
    /// the normalized fetch URL the whole app already agrees on (`FeedSource.id`). It is the handle a
    /// projection holding a runtime `SourceID` wants: the `source` row is the runtime's own identity,
    /// while `legacy_source_map.legacy_url` is the legacy *evidence* of the same mapping (ADR-003 D18)
    /// and reading it would make the runtime take its identity out of a legacy bridge. The bridge row
    /// exists on the production path too — `V2Acquisition` writes it with the catalogue's own compact id
    /// — but this read does not need it: a published card's payload freezes no URL by design (ADR-002
    /// D3), and the row allocated here is the one the runtime owns regardless of what the bridge holds.
    public func editorialKey(
        for sourceID: SourceID,
        in database: RuntimeDatabase
    ) throws -> EditorialSourceKey? {
        try database.read { database in
            try Row.fetchOne(database, sql: """
                SELECT editorial_key, canonicalization_version FROM source WHERE id = ?
                """, arguments: [Int64(sourceID.rawValue)]).flatMap { row in
                try? EditorialSourceKey(
                    catalogIdentity: row["editorial_key"],
                    canonicalizationVersion: row["canonicalization_version"]
                )
            }
        }
    }
}

public enum RuntimeSourceRegistryError: Error, Equatable, Sendable {
    /// The insert did not fail but the row is not readable, which means the write and the read did not
    /// see the same transaction. Failures are never silent here: a source identity that cannot be
    /// resolved would drop every membership that names it.
    case allocationFailed(String)
}
