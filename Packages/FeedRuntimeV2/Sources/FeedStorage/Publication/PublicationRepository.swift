import Foundation
import GRDB
import FeedDomain

/// The publication aggregate's only persistence (ADR-001, ADR-006 D14; plan §9).
///
/// This type owns every write to `feed_edition`, `feed_segment`, `published_card`,
/// `published_asset_ref`, `asset_version` and `media_preparation`, and `PublicationCoordinator` is its
/// only caller. There is no other insert path in the module: connectors, Selection, `MediaPreparation`
/// and the renderer have no API that reaches these tables (I-04, I-10, INV-4).
///
/// The integrity of an append does not depend on the caller being alone. The commit transaction
/// re-reads the tail through a conditional `UPDATE`, so a stale token commits nothing even when two
/// coordinator instances, or a crash-restarted one, race for the same tail; and the schema's two
/// `UNIQUE` constraints per edition hold whatever SQL reaches the table (ADR-006 D14, INV-5).

/// A storage failure that is not a typed publication refusal.
public enum PublicationStorageError: Error, Equatable, Sendable {
    /// A stored row cannot be interpreted as the value the schema describes.
    case corruptedRow(String)
    /// A fault injected to prove the crash points ADR-001's edge cases name. Never thrown in production.
    case interrupted(String)
}

/// Which asset classes an `asset_version` row belongs to (ADR-004 D8).
public enum PublishedAssetStorageClass: String, Hashable, Sendable, CaseIterable {
    /// Bytes published by a retained edition; protected by the references that name them.
    case published
    /// Bytes for candidates that were never published; evictable by quota.
    case cached
}

/// Whether an asset version's bytes hold (ADR-001 D14).
public enum PublishedAssetDurability: String, Hashable, Sendable, CaseIterable {
    case committed
    /// Bytes were deliberately removed; digest, size, mime type and dimensions survive.
    case bytesRemoved = "bytes_removed"
    /// Bytes were never written, or are unreachable.
    case missing
}

/// One immutable asset version to insert with the segment that references it.
public struct AssetVersionRecord: Hashable, Sendable {
    public let commit: PublishedAssetCommit
    public let storageClass: PublishedAssetStorageClass
    public let durability: PublishedAssetDurability
    public let createdAt: Date

    public init(
        commit: PublishedAssetCommit,
        storageClass: PublishedAssetStorageClass = .published,
        durability: PublishedAssetDurability = .committed,
        createdAt: Date
    ) throws {
        if durability == .committed, commit.relativePath.isEmpty {
            throw PublicationStorageError.corruptedRow("a committed asset version needs a path")
        }
        self.commit = commit
        self.storageClass = storageClass
        self.durability = durability
        self.createdAt = createdAt
    }
}

/// One reference from a card to an asset version, resolved by identity inside the transaction.
public struct PublishedAssetRefRecord: Hashable, Sendable {
    public let slot: PublishedAssetSlot
    public let role: MediaRole
    public let renderSlot: MediaSlot
    public let contentDigest: String
    public let recipeVersion: Int
    public let aspectRatio: Double?

    public init(
        slot: PublishedAssetSlot,
        role: MediaRole,
        renderSlot: MediaSlot,
        contentDigest: String,
        recipeVersion: Int,
        aspectRatio: Double?
    ) {
        self.slot = slot
        self.role = role
        self.renderSlot = renderSlot
        self.contentDigest = contentDigest
        self.recipeVersion = recipeVersion
        self.aspectRatio = aspectRatio
    }
}

/// One frozen card and the asset references it holds.
///
/// The record carries `PublishedCardPayload.Frozen` rather than a payload: the occurrence identity is
/// allocated by the database in the very transaction that inserts the card, and the canonical
/// serialization deliberately excludes it (plan §5.1).
public struct CardInsertRecord: Hashable, Sendable {
    public let frozen: PublishedCardPayload.Frozen
    public let assetReferences: [PublishedAssetRefRecord]

    public init(frozen: PublishedCardPayload.Frozen, assetReferences: [PublishedAssetRefRecord]) {
        self.frozen = frozen
        self.assetReferences = assetReferences.sorted { lhs, rhs in
            lhs.slot.rawValue == rhs.slot.rawValue
                ? lhs.contentDigest < rhs.contentDigest
                : lhs.slot.rawValue < rhs.slot.rawValue
        }
    }
}

/// What preparation decided for one candidate (ADR-001's `media_preparation`).
public struct MediaPreparationRecord: Hashable, Sendable {
    public enum State: String, Hashable, Sendable, CaseIterable {
        case pending
        case inFlight = "in_flight"
        case prepared
        case placeholder
        case failed
        case noMedia = "no_media"
    }

    public let originRevisionID: OriginRevisionID
    public let candidateKey: String
    public let role: MediaRole
    public let state: State
    /// Present exactly when the state is `prepared`; the asset version it names must be in the commit.
    public let contentDigest: String?
    public let recipeVersion: Int?
    public let placeholderRecipe: String?
    public let decisionRevision: Int64
    public let updatedAt: Date

    public init(
        originRevisionID: OriginRevisionID,
        candidateKey: String,
        role: MediaRole,
        state: State,
        contentDigest: String? = nil,
        recipeVersion: Int? = nil,
        placeholderRecipe: String? = nil,
        decisionRevision: Int64,
        updatedAt: Date
    ) {
        self.originRevisionID = originRevisionID
        self.candidateKey = candidateKey
        self.role = role
        self.state = state
        self.contentDigest = contentDigest
        self.recipeVersion = recipeVersion
        self.placeholderRecipe = placeholderRecipe
        self.decisionRevision = decisionRevision
        self.updatedAt = updatedAt
    }
}

/// How the committed segment relates to the visible edition (ADR-001 D7).
public enum SegmentActivation: Hashable, Sendable {
    /// Append to the edition that is already active.
    case append
    /// The successor's first segment: build it, then swap the active edition in the same transaction.
    case activate(successorOf: EditionID?)
}

/// One append: everything the transaction needs, validated before it starts.
public struct SegmentCommitRequest: Sendable {
    public let token: PublicationToken
    public let segmentOrdinal: Int
    public let absoluteOrdinalStart: Int
    public let segmentSeed: Data
    /// The editorial revision the segment's cards were composed under (ADR-001's `policy_revision`).
    public let policyRevision: String
    public let committedAt: Date
    public let activation: SegmentActivation
    public let cards: [CardInsertRecord]
    public let assets: [AssetVersionRecord]
    public let mediaPreparations: [MediaPreparationRecord]
    /// The exact canonical revisions the composition pinned; each must still be hard-eligible at commit.
    public let pinnedRevisions: [OriginRevisionID]

    public init(
        token: PublicationToken,
        segmentOrdinal: Int,
        absoluteOrdinalStart: Int,
        segmentSeed: Data,
        policyRevision: String,
        committedAt: Date,
        activation: SegmentActivation,
        cards: [CardInsertRecord],
        assets: [AssetVersionRecord],
        mediaPreparations: [MediaPreparationRecord],
        pinnedRevisions: [OriginRevisionID]
    ) {
        self.token = token
        self.segmentOrdinal = segmentOrdinal
        self.absoluteOrdinalStart = absoluteOrdinalStart
        self.segmentSeed = segmentSeed
        self.policyRevision = policyRevision
        self.committedAt = committedAt
        self.activation = activation
        self.cards = cards
        self.assets = assets
        self.mediaPreparations = mediaPreparations
        self.pinnedRevisions = pinnedRevisions
    }

    /// The tail this commit leaves behind, when it wins.
    public var resultingTail: EditionTail {
        EditionTail(
            segmentOrdinal: segmentOrdinal,
            absoluteOrdinal: absoluteOrdinalStart + cards.count - 1,
            version: token.tail.version + 1
        )
    }
}

/// The durable outcome of one append.
public struct SegmentCommitReceipt: Hashable, Sendable {
    public let editionID: EditionID
    public let segmentID: SegmentID
    public let segmentOrdinal: Int
    public let absoluteOrdinalStart: Int
    public let absoluteOrdinalEnd: Int
    public let cardIDs: [PublicationCardID]
    public let tail: EditionTail
    public let activated: Bool
}

// MARK: - Read models

/// One edition row.
public struct EditionSnapshot: Hashable, Sendable {
    public let editionID: EditionID
    public let contextKey: String
    public let editorialRevision: EditorialRevision
    public let publicationSchemaVersion: Int
    public let epoch: Int64
    public let seed: Data
    public let state: EditionState
    public let successorOfEditionID: EditionID?
    public let tail: EditionTail
    public let createdAt: Date
    public let activatedAt: Date?

    public var token: PublicationToken {
        PublicationToken(
            editionID: editionID,
            epoch: epoch,
            editorialRevision: editorialRevision,
            tail: tail
        )
    }
}

/// One segment row.
public struct SegmentSnapshot: Hashable, Sendable {
    public let segmentID: SegmentID
    public let editionID: EditionID
    public let segmentOrdinal: Int
    public let absoluteOrdinalStart: Int
    public let absoluteOrdinalEnd: Int
    public let policyRevision: String
    public let seed: Data
    public let committedAt: Date
}

/// One published card as it was frozen, with the identity of its storage row.
public struct PublishedCardRecord: Hashable, Sendable {
    public let payload: PublishedCardPayload
    public let segmentID: SegmentID
    /// The stored digest of the payload's canonical serialization (ADR-002 D8 R3).
    public let payloadDigest: String
}

/// One asset version row.
public struct AssetVersionSnapshot: Hashable, Sendable {
    public let assetVersionID: Int64
    public let contentDigest: String
    public let byteCount: Int
    public let mimeType: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let recipeVersion: Int
    public let storageClass: PublishedAssetStorageClass
    public let relativePath: String?
    public let durability: PublishedAssetDurability
    public let createdAt: Date
}

/// One media preparation row.
public struct MediaPreparationSnapshot: Hashable, Sendable {
    public let originRevisionID: OriginRevisionID
    public let candidateKey: String
    public let role: MediaRole
    public let state: MediaPreparationRecord.State
    public let contentDigest: String?
    public let recipeVersion: Int?
    public let placeholderRecipe: String?
    public let decisionRevision: Int64
    public let updatedAt: Date
}

/// The verification SQL the publication aggregate is checked with.
///
/// ADR-004 D9/D11 require `PRAGMA integrity_check` and `foreign_key_check` on a real database, and the
/// plan requires the two uniqueness rules of the append path to be checked rather than assumed. This is
/// the production diagnostic; the tests assert on it instead of re-deriving the same SQL per target.
public struct PublicationIntegrityReport: Hashable, Sendable {
    public let integrityCheck: String
    public let danglingForeignKeyCount: Int
    public let duplicateAbsoluteOrdinals: Int
    public let duplicateSegmentOrdinals: Int
    /// References that resolve to no asset version. Always zero: `published_asset_ref` is the only
    /// record of a published asset, and a reference to bytes that were never committed is INV-7.
    public let unresolvedAssetReferences: Int

    public var isHealthy: Bool {
        integrityCheck == "ok"
            && danglingForeignKeyCount == 0
            && duplicateAbsoluteOrdinals == 0
            && duplicateSegmentOrdinals == 0
            && unresolvedAssetReferences == 0
    }

    public var summary: String {
        "integrity_check=\(integrityCheck) foreign_keys=\(danglingForeignKeyCount) "
            + "duplicate_absolute_ordinals=\(duplicateAbsoluteOrdinals) "
            + "duplicate_segment_ordinals=\(duplicateSegmentOrdinals) "
            + "unresolved_asset_refs=\(unresolvedAssetReferences)"
    }
}

/// Whether a stored edition can be restored, and why not when it cannot (ADR-002 D8 R1–R3).
public enum EditionRestoreOutcome: Sendable, Equatable {
    case restored(EditionSnapshot, [PublishedCardRecord])
    case noEdition(ContextKey)
    /// R2: the publication schema is outside this build's supported set. A controlled refusal, never a
    /// permissive decode (ADR-001 D9, INV-13).
    case unsupportedPublicationSchemaVersion(Int)
    /// R3: an intact-looking row whose payload no longer recomputes to its stored digest, or whose
    /// action handle no longer decodes.
    case payloadCorrupted(cardID: PublicationCardID, reason: String)
}

// MARK: - Repository

public struct PublicationRepository: Sendable {
    /// The fault points ADR-001's edge cases name. Production never arms one: the transaction is
    /// atomic, so an interrupted commit leaves nothing behind, and this seam is how a test proves that
    /// instead of killing the process.
    public enum Interruption: String, Hashable, Sendable, CaseIterable {
        /// After `feed_segment` was inserted, before any card: the "crash between segment and cards" case.
        case afterSegmentInsert
        /// After every card and reference was inserted, before the activation swap.
        case beforeActivation
        /// A storage failure at commit time: the transaction rolls back, and a bounded retry may run.
        case storageFailureAtCommit
    }

    /// A fault arming one interruption on one commit attempt.
    ///
    /// It names the attempt so a one-shot failure and a successful retry can both be observed without
    /// a mutable flag in the repository (which must stay a `Sendable` value).
    public struct Faults: Hashable, Sendable {
        public let point: Interruption
        /// The commit attempt that fails; later attempts behave normally.
        public let attempt: Int

        public init(point: Interruption, attempt: Int = 1) {
            self.point = point
            self.attempt = attempt
        }
    }

    public static let interruptionProbe = "publicationCommitInterrupted"
    public static let storageFailureProbe = "publicationCommitStorageFailure"

    private let database: RuntimeDatabase
    private let faults: Faults?
    /// Where a commit's duration goes (plan §16). `nil` means no diagnostics.
    private let metrics: RuntimeMetricsRecorder?

    /// Where this repository's database lives. A diagnostic that has to name the failing database (a
    /// captured failure, a quarantine report) reads it here instead of carrying a second copy of a path.
    public var location: RuntimeDatabaseLocation { database.location }

    public init(database: RuntimeDatabase, faults: Faults? = nil, metrics: RuntimeMetricsRecorder? = nil) {
        self.database = database
        self.faults = faults
        self.metrics = metrics
    }

    /// Convenience for the single-fault case.
    public init(database: RuntimeDatabase, interruption: Interruption) {
        self.init(database: database, faults: Faults(point: interruption))
    }

    // MARK: - Edition lifecycle

    /// Creates a draft edition with epoch `epoch`. A draft is not history yet: it becomes visible only
    /// when its first segment commits with `.activate`.
    public func beginEdition(
        context: ContextKey,
        editorialRevision: EditorialRevision,
        epoch: Int64,
        seed: Data,
        publicationSchemaVersion: Int = PublicationSchema.currentVersion,
        successorOf: EditionID?,
        at: Date
    ) throws -> EditionSnapshot {
        guard epoch > 0 else {
            throw PublicationFailure.invalidComposition("epoch must be positive")
        }
        guard !seed.isEmpty else {
            throw PublicationFailure.invalidComposition("the edition seed must not be empty")
        }
        let editionID = try database.write { db -> EditionID in
            try db.execute(sql: """
                INSERT INTO feed_edition (
                    context_key, editorial_revision, publication_schema_version, epoch, seed, state,
                    successor_of_edition_id, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, 'draft', ?, ?)
                """, arguments: [
                context.canonicalSerialization,
                editorialRevision.digest,
                publicationSchemaVersion,
                epoch,
                seed,
                successorOf?.rawValue,
                PublicationTimestamp.milliseconds(at),
            ])
            return try EditionID(db.lastInsertedRowID)
        }
        guard let snapshot = try edition(editionID) else {
            throw PublicationStorageError.corruptedRow("the edition just inserted is not readable")
        }
        return snapshot
    }

    /// Removes a draft that never committed a segment. It refuses to touch anything else: a draft with
    /// history is not a draft, and committed segments are immutable (INV-1).
    @discardableResult
    public func discardUncommittedEdition(_ editionID: EditionID) throws -> Bool {
        try database.write { db in
            let segments = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM feed_segment WHERE edition_id = ?",
                arguments: [editionID.rawValue]
            ) ?? 0
            guard segments == 0 else { return false }
            try db.execute(
                sql: "DELETE FROM feed_edition WHERE edition_id = ? AND state = 'draft'",
                arguments: [editionID.rawValue]
            )
            return db.changesCount > 0
        }
    }

    // MARK: - Writes: the single append path

    /// Appends one immutable segment, its cards, its asset versions and its asset references.
    ///
    /// The transaction is the contract:
    ///
    /// 1. a conditional `UPDATE` of the edition is the first statement, so it both validates the token
    ///    and takes the write lock — a token whose tail, version, epoch, revision or state moved
    ///    affects zero rows and commits nothing;
    /// 2. every pinned revision is re-checked for hard eligibility inside the same transaction;
    /// 3. the segment, cards, asset versions and references are inserted;
    /// 4. only then does a successor swap the active edition, so the UI can never observe a dismantled
    ///    edition (ADR-001 D7, INV-14).
    public func commit(_ request: SegmentCommitRequest, attempt: Int = 1) throws -> SegmentCommitReceipt {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try validate(request)
            let receipt = try database.write { db in
                try Self.performCommit(db, request: request, faults: faults, attempt: attempt)
            }
            recordCommit(request, attempt: attempt, started: started, outcome: "published")
            return receipt
        } catch {
            recordCommit(request, attempt: attempt, started: started, outcome: "refused")
            throw error
        }
    }

    /// One commit's measurement (plan §16), tagged with the edition and the epoch it ran under and with
    /// the attempt it was. A commit that needed a second attempt is the retry counter, counted where the
    /// attempt is known rather than inferred from a duration.
    private func recordCommit(
        _ request: SegmentCommitRequest,
        attempt: Int,
        started: Double,
        outcome: String
    ) {
        guard let metrics else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        Task {
            await metrics.record(
                OperationSample(
                    operation: .publicationCommit,
                    operationID: "edition-\(request.token.editionID.rawValue)-segment-\(request.segmentOrdinal)",
                    editionID: request.token.editionID.rawValue,
                    epoch: request.token.epoch,
                    durationMilliseconds: elapsed,
                    outcome: "\(outcome) attempt=\(attempt)"
                )
            )
            if attempt > 1 {
                await metrics.count(.publicationRetry)
            }
        }
    }

    // MARK: - Reads

    public func edition(_ editionID: EditionID) throws -> EditionSnapshot? {
        try database.read { db in
            try Self.edition(db, editionID)
        }
    }

    public func token(for editionID: EditionID) throws -> PublicationToken {
        guard let snapshot = try edition(editionID) else {
            throw PublicationFailure.editionNotFound(editionID)
        }
        return snapshot.token
    }

    /// The one visible edition for a context, when there is one (the active-edition pointer).
    public func activeEdition(for context: ContextKey) throws -> EditionSnapshot? {
        try database.read { db in
            try Self.editionRow(
                db,
                sql: """
                    SELECT * FROM feed_edition
                    WHERE context_key = ? AND state = 'active'
                    """,
                arguments: [context.canonicalSerialization]
            ).map(Self.snapshot(of:))
        }
    }

    /// The newest edition for a context: the active one, or the newest draft when a refresh is in
    /// flight. Never returns a superseded edition as if it were visible.
    public func latestEdition(for context: ContextKey) throws -> EditionSnapshot? {
        try database.read { db in
            try Self.editionRow(
                db,
                sql: """
                    SELECT * FROM feed_edition
                    WHERE context_key = ? AND state IN ('active','draft')
                    ORDER BY epoch DESC, edition_id DESC LIMIT 1
                    """,
                arguments: [context.canonicalSerialization]
            ).map(Self.snapshot(of:))
        }
    }

    /// Every edition that currently claims to be visible. There is at most one per context, and this
    /// is how a test proves it (INV-14).
    public func activeEditions() throws -> [EditionSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM feed_edition WHERE state = 'active' ORDER BY context_key, edition_id"
            ).map(Self.snapshot(of:))
        }
    }

    public func segments(in editionID: EditionID) throws -> [SegmentSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM feed_segment WHERE edition_id = ? ORDER BY segment_ordinal",
                arguments: [editionID.rawValue]
            ).map(Self.segmentSnapshot(of:))
        }
    }

    /// Every card of an edition in window order, rebuilt from its own rows.
    public func cards(in editionID: EditionID) throws -> [PublishedCardRecord] {
        try database.read { db in
            try Self.cards(db, editionID: editionID)
        }
    }

    /// What this context has already published, oldest first, over its most recent `editions` editions
    /// (`active` and `superseded`: a purged edition has left the log).
    ///
    /// The sequencer's repetition window is the only reader (ADR-007 D13), and it is why the read
    /// exists: a composition that cannot see what it published last time repeats it, and a reader who
    /// refreshes five times would be shown the same page five times over.
    ///
    /// It reads the card rows and the record's primary identity — never a payload — so a card whose
    /// payload a later build cannot decode still contributes its occurrence.
    public func publishedOccurrences(
        for context: ContextKey,
        editions: Int
    ) throws -> PublishedHistory {
        guard editions > 0 else { return .empty }
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                WITH recent(edition_id) AS (
                    SELECT edition_id FROM feed_edition
                    WHERE context_key = ? AND state IN ('active', 'superseded')
                    ORDER BY edition_id DESC
                    LIMIT ?
                )
                SELECT card.edition_id, card.absolute_ordinal, card.observation_at_ms,
                       identity.connector_namespace, identity.scope_key, identity.external_key
                FROM published_card AS card
                JOIN recent ON recent.edition_id = card.edition_id
                JOIN origin_record AS record ON record.id = card.origin_record_id
                JOIN external_identity AS identity ON identity.id = record.primary_identity_id
                ORDER BY card.edition_id ASC, card.absolute_ordinal ASC
                """, arguments: [context.canonicalSerialization, editions])
        }
        var occurrences: [PublishedOccurrence] = []
        occurrences.reserveCapacity(rows.count)
        for row in rows {
            let editionID: Int64 = row["edition_id"]
            let ordinal: Int = row["absolute_ordinal"]
            let observedAt: Int64 = row["observation_at_ms"]
            occurrences.append(PublishedOccurrence(
                stableKey: SupplyStableKey(
                    namespace: ConnectorNamespace(row["connector_namespace"]),
                    scopeKey: row["scope_key"],
                    objectKeyBytes: row["external_key"]
                ),
                editionID: try EditionID(editionID),
                ordinal: ordinal,
                publishedAt: AdmissionTimestamp.date(milliseconds: observedAt)
            ))
        }
        return PublishedHistory(occurrences: occurrences)
    }

    public func card(_ cardID: PublicationCardID) throws -> PublishedCardRecord? {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.*, s.segment_ordinal AS segment_ordinal,
                           e.editorial_revision AS edition_editorial_revision
                    FROM published_card c
                    JOIN feed_segment s ON s.edition_id = c.edition_id AND s.segment_id = c.segment_id
                    JOIN feed_edition e ON e.edition_id = c.edition_id
                    WHERE c.publication_card_id = ?
                    """,
                arguments: [cardID.rawValue]
            )
            guard let row = rows.first else { return nil }
            return try Self.cardRecord(db, row: row)
        }
    }

    /// R1–R3 of ADR-002 D8: a valid edition restores from durable rows alone — no Selection, no
    /// catalog, no network — and reports a controlled refusal when it cannot.
    public func restore(
        context: ContextKey,
        supportedSchemaVersions: Set<Int> = PublicationSchema.supportedVersions
    ) throws -> EditionRestoreOutcome {
        try database.read { db in
            guard let row = try Self.editionRow(
                db,
                sql: "SELECT * FROM feed_edition WHERE context_key = ? AND state = 'active'",
                arguments: [context.canonicalSerialization]
            ) else {
                return .noEdition(context)
            }
            let edition = try Self.snapshot(of: row)
            guard supportedSchemaVersions.contains(edition.publicationSchemaVersion) else {
                return .unsupportedPublicationSchemaVersion(edition.publicationSchemaVersion)
            }
            let records = try Self.cards(db, editionID: edition.editionID)
            for record in records {
                // R2 answers to the edition's version; the card's own version is part of the frozen
                // payload, so a card whose version was written inconsistently fails the digest below
                // rather than passing an equality check the digest already covers.
                let recomputed = record.payload.frozenDigest()
                guard recomputed == record.payloadDigest else {
                    return .payloadCorrupted(
                        cardID: record.payload.cardID,
                        reason: "payload digest \(record.payloadDigest) but recomputed \(recomputed)"
                    )
                }
            }
            return .restored(edition, records)
        }
    }

    /// The canonical content one revision holds, read so the composition can freeze it.
    ///
    /// This is the *only* read of canonical state on the publication path, and it happens before the
    /// commit. It reads no connector evidence, no protocol payload and no URL: a media candidate is
    /// named by role and position, which is what the published payload is allowed to know.
    public func cardContent(originRevisionID: OriginRevisionID) throws -> PublicationCardContent? {
        try database.read { db in
            guard let revision = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, origin_record_id, headline, summary, body_text, primary_link,
                           authored_at, modified_at, observed_at
                    FROM origin_revision WHERE id = ?
                    """,
                arguments: [originRevisionID.rawValue]
            ) else { return nil }
            let recordID: Int64 = revision["origin_record_id"]
            guard let originRecordID = try? OriginRecordID(recordID) else {
                throw PublicationStorageError.corruptedRow("revision \(originRevisionID) has no record")
            }

            let source = try Row.fetchOne(db, sql: """
                SELECT s.id AS source_id, s.display_title
                FROM selection_supply supply
                JOIN source s ON s.id = supply.source_id
                WHERE supply.origin_record_id = ?
                """, arguments: [recordID])
                ?? Row.fetchOne(db, sql: """
                    SELECT s.id AS source_id, s.display_title
                    FROM source_membership m
                    JOIN source s ON s.id = m.source_id
                    WHERE m.origin_record_id = ?
                    ORDER BY s.id LIMIT 1
                    """, arguments: [recordID])

            let provider = try Row.fetchOne(db, sql: """
                SELECT p.id AS provider_id, p.display_name
                FROM provider_attribution a
                JOIN provider p ON p.id = a.provider_id
                WHERE a.origin_revision_id = ? AND a.attribution_role = 'primary'
                ORDER BY p.id LIMIT 1
                """, arguments: [originRevisionID.rawValue])

            let media = try Row.fetchAll(db, sql: """
                SELECT role, position, media_type_hint, pixel_width, pixel_height
                FROM media_candidate WHERE origin_revision_id = ? ORDER BY position, id
                """, arguments: [originRevisionID.rawValue]).map { row in
                DeclaredMediaCandidate(
                    role: MediaRole(rawValue: row["role"]) ?? .image,
                    position: row["position"],
                    mediaTypeHint: row["media_type_hint"],
                    pixelWidth: row["pixel_width"],
                    pixelHeight: row["pixel_height"]
                )
            }

            let offers = try Row.fetchAll(db, sql: """
                SELECT offer_kind, handle, position FROM interaction_offer
                WHERE origin_revision_id = ? ORDER BY position, id
                """, arguments: [originRevisionID.rawValue]).map { row in
                DeclaredInteractionOffer(
                    kind: row["offer_kind"],
                    handle: row["handle"],
                    position: row["position"]
                )
            }

            return PublicationCardContent(
                originRecordID: originRecordID,
                originRevisionID: originRevisionID,
                sourceID: (source?["source_id"] as Int64?).flatMap { try? SourceID(UInt64($0)) },
                providerID: (provider?["provider_id"] as Int64?).flatMap { try? ProviderID(UInt64($0)) },
                sourceDisplayName: source?["display_title"],
                providerDisplayName: provider?["display_name"],
                headline: revision["headline"],
                summary: revision["summary"],
                bodyText: revision["body_text"],
                primaryLink: revision["primary_link"],
                authoredAt: (revision["authored_at"] as Int64?).map(PublicationTimestamp.date),
                modifiedAt: (revision["modified_at"] as Int64?).map(PublicationTimestamp.date),
                observedAt: PublicationTimestamp.date(revision["observed_at"]),
                mediaCandidates: media,
                offers: offers
            )
        }
    }

    public func mediaPreparations(originRevisionID: OriginRevisionID) throws -> [MediaPreparationSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*, a.content_digest AS asset_content_digest,
                           a.recipe_version AS asset_recipe_version
                    FROM media_preparation m
                    LEFT JOIN asset_version a ON a.asset_version_id = m.asset_version_id
                    WHERE m.origin_revision_id = ?
                    ORDER BY m.candidate_key, m.role
                    """,
                arguments: [originRevisionID.rawValue]
            ).map { row in
                MediaPreparationSnapshot(
                    originRevisionID: originRevisionID,
                    candidateKey: row["candidate_key"],
                    role: MediaRole(rawValue: row["role"]) ?? .image,
                    state: MediaPreparationRecord.State(rawValue: row["state"]) ?? .pending,
                    contentDigest: row["asset_content_digest"],
                    recipeVersion: row["asset_recipe_version"],
                    placeholderRecipe: row["placeholder_recipe"],
                    decisionRevision: row["decision_revision"],
                    updatedAt: PublicationTimestamp.date(row["updated_at_ms"])
                )
            }
        }
    }

    public func assetVersion(contentDigest: String, recipeVersion: Int) throws -> AssetVersionSnapshot? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM asset_version WHERE content_digest = ? AND recipe_version = ?
                    """,
                arguments: [contentDigest, recipeVersion]
            ).map(Self.assetSnapshot(of:))
        }
    }

    /// The publication aggregate's verification SQL, measured by SQLite rather than assumed.
    public func integrityReport() throws -> PublicationIntegrityReport {
        try database.read { db in
            PublicationIntegrityReport(
                integrityCheck: try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown",
                danglingForeignKeyCount: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
                duplicateAbsoluteOrdinals: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM (
                        SELECT edition_id, absolute_ordinal FROM published_card
                        GROUP BY edition_id, absolute_ordinal HAVING COUNT(*) > 1
                    )
                    """) ?? 0,
                duplicateSegmentOrdinals: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM (
                        SELECT edition_id, segment_ordinal FROM feed_segment
                        GROUP BY edition_id, segment_ordinal HAVING COUNT(*) > 1
                    )
                    """) ?? 0,
                unresolvedAssetReferences: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM published_asset_ref r
                    LEFT JOIN asset_version a ON a.asset_version_id = r.asset_version_id
                    WHERE a.asset_version_id IS NULL
                    """) ?? 0
            )
        }
    }

    /// Asset versions no card references: the orphans a crash before commit leaves behind, which GC may
    /// collect and which are never adopted retroactively (ADR-001 D11, ADR-004 D10).
    public func unreferencedAssetVersionIDs() throws -> [Int64] {
        try database.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT a.asset_version_id FROM asset_version a
                LEFT JOIN published_asset_ref r ON r.asset_version_id = a.asset_version_id
                WHERE r.asset_version_id IS NULL
                ORDER BY a.asset_version_id
                """)
        }
    }

    // MARK: - Validation

    private func validate(_ request: SegmentCommitRequest) throws {
        guard !request.cards.isEmpty else {
            throw PublicationFailure.emptySequence(request.token.editionID)
        }
        guard request.segmentOrdinal == request.token.tail.nextSegmentOrdinal else {
            throw PublicationFailure.invalidComposition(
                "segment ordinal \(request.segmentOrdinal) does not follow the token's tail"
            )
        }
        guard request.absoluteOrdinalStart == request.token.tail.nextAbsoluteOrdinal else {
            throw PublicationFailure.invalidComposition(
                "absolute ordinal \(request.absoluteOrdinalStart) does not follow the token's tail"
            )
        }
        guard request.policyRevision == request.token.editorialRevision.digest else {
            throw PublicationFailure.invalidComposition("the segment's policy revision is not the token's")
        }
        guard !request.segmentSeed.isEmpty else {
            throw PublicationFailure.invalidComposition("the segment seed must not be empty")
        }
        for (offset, card) in request.cards.enumerated() {
            guard card.frozen.absoluteOrdinal == request.absoluteOrdinalStart + offset else {
                throw PublicationFailure.invalidComposition(
                    "card ordinals must be contiguous from \(request.absoluteOrdinalStart)"
                )
            }
            guard card.frozen.editionID == request.token.editionID else {
                throw PublicationFailure.invalidComposition("a card names another edition")
            }
            guard card.frozen.segmentOrdinal == request.segmentOrdinal else {
                throw PublicationFailure.invalidComposition("a card names another segment ordinal")
            }
            guard card.frozen.publicationSchemaVersion == PublicationSchema.currentVersion else {
                throw PublicationFailure.unsupportedPublicationSchemaVersion(
                    card.frozen.publicationSchemaVersion
                )
            }
        }
    }

    // MARK: - The transaction

    private static func performCommit(
        _ db: Database,
        request: SegmentCommitRequest,
        faults: Faults?,
        attempt: Int
    ) throws -> SegmentCommitReceipt {
        /// Whether the armed fault belongs to this attempt.
        func interrupted(_ point: Interruption) -> Bool {
            faults?.point == point && faults?.attempt == attempt
        }

        let token = request.token
        let resulting = request.resultingTail

        // Step 1: the compare-and-swap. This is the first statement of the transaction on purpose: it
        // takes the write lock and validates edition, state, epoch, revision, tail and version at once,
        // so a token that moved commits zero rows instead of racing a read.
        let activationPredicate = activationAllows(request.activation)
        try db.execute(sql: """
            UPDATE feed_edition
               SET tail_segment_ordinal = ?, tail_absolute_ordinal = ?, version = version + 1
             WHERE edition_id = ? AND version = ? AND epoch = ? AND editorial_revision = ?
               AND tail_segment_ordinal = ? AND tail_absolute_ordinal = ?
               AND \(activationPredicate)
            """, arguments: [
            resulting.segmentOrdinal,
            resulting.absoluteOrdinal,
            token.editionID.rawValue,
            token.tail.version,
            token.epoch,
            token.editorialRevision.digest,
            token.tail.segmentOrdinal,
            token.tail.absoluteOrdinal,
        ])
        guard db.changesCount == 1 else {
            let refusal = try classify(db, token: token, activation: request.activation)
            throw refusal
        }

        // Step 2: eligibility of every pinned revision, inside the same transaction.
        let revoked = try ineligible(db, request.pinnedRevisions)
        if let first = revoked.first {
            throw PublicationFailure.eligibilityRevoked(originRevisionID: first)
        }

        // Step 3: the immutable segment.
        try db.execute(sql: """
            INSERT INTO feed_segment (
                edition_id, segment_ordinal, absolute_ordinal_start, absolute_ordinal_end,
                policy_revision, seed, committed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
            token.editionID.rawValue,
            request.segmentOrdinal,
            request.absoluteOrdinalStart,
            resulting.absoluteOrdinal,
            request.policyRevision,
            request.segmentSeed,
            PublicationTimestamp.milliseconds(request.committedAt),
        ])
        let segmentID = try SegmentID(db.lastInsertedRowID)

        if interrupted(.afterSegmentInsert) {
            throw PublicationStorageError.interrupted(interruptionProbe)
        }

        // Step 4: asset versions. Identity is (digest, recipe), so an identity an earlier edition
        // already committed is reused rather than duplicated — the bytes are the same bytes.
        var assetIDs: [AssetIdentity: Int64] = [:]
        for asset in request.assets {
            let identity = AssetIdentity(
                digest: asset.commit.contentDigest,
                recipeVersion: asset.commit.recipeVersion
            )
            if let existing = try Int64.fetchOne(db, sql: """
                SELECT asset_version_id FROM asset_version
                WHERE content_digest = ? AND recipe_version = ?
                """, arguments: [identity.digest, identity.recipeVersion]) {
                assetIDs[identity] = existing
                continue
            }
            try db.execute(sql: """
                INSERT INTO asset_version (
                    content_digest, byte_count, mime_type, pixel_width, pixel_height, recipe_version,
                    storage_class, relative_path, durability_state, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                identity.digest,
                asset.commit.byteCount,
                asset.commit.mimeType,
                asset.commit.pixelWidth,
                asset.commit.pixelHeight,
                identity.recipeVersion,
                asset.storageClass.rawValue,
                asset.commit.relativePath,
                asset.durability.rawValue,
                PublicationTimestamp.milliseconds(asset.createdAt),
            ])
            assetIDs[identity] = db.lastInsertedRowID
        }

        // Step 5: the cards, each with its own frozen payload and digest.
        var cardIDs: [PublicationCardID] = []
        for card in request.cards {
            let payload = card.frozen
            try db.execute(sql: """
                INSERT INTO published_card (
                    edition_id, segment_id, absolute_ordinal, origin_record_id, origin_revision_id,
                    source_id, provider_id, source_display_name, provider_display_name, title,
                    primary_text, published_at_ms, published_at_kind, observation_at_ms,
                    primary_action_kind, primary_action_reference, interaction_summary,
                    render_contract_version, render_kind, render_media_slot, render_aspect_ratio,
                    payload_digest, publication_schema_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                payload.editionID.rawValue,
                segmentID.rawValue,
                payload.absoluteOrdinal,
                payload.origin.originRecordID.rawValue,
                payload.origin.originRevisionID.rawValue,
                payload.origin.sourceID.map { Int64($0.rawValue) },
                payload.origin.providerID.map { Int64($0.rawValue) },
                payload.origin.sourceDisplayName,
                payload.origin.providerDisplayName,
                payload.title,
                payload.primaryText,
                payload.publishedAt.map(PublicationTimestamp.milliseconds),
                payload.publishedAtKind.rawValue,
                PublicationTimestamp.milliseconds(payload.observationAt),
                payload.primaryAction?.kind.rawValue,
                payload.primaryAction?.reference,
                payload.interactionSummary,
                payload.renderContract.version,
                payload.renderContract.kind.rawValue,
                payload.renderContract.mediaSlot.rawValue,
                payload.renderContract.aspectRatio,
                payload.frozenDigest(),
                payload.publicationSchemaVersion,
            ])
            let cardID = try PublicationCardID(db.lastInsertedRowID)
            cardIDs.append(cardID)

            for reference in card.assetReferences {
                let identity = AssetIdentity(
                    digest: reference.contentDigest,
                    recipeVersion: reference.recipeVersion
                )
                guard let assetVersionID = assetIDs[identity] else {
                    throw PublicationStorageError.corruptedRow(
                        "card references an asset version this commit does not carry: \(identity)"
                    )
                }
                try db.execute(sql: """
                    INSERT INTO published_asset_ref (
                        publication_card_id, slot, asset_version_id, role, render_slot, aspect_ratio
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    cardID.rawValue,
                    reference.slot.rawValue,
                    assetVersionID,
                    reference.role.rawValue,
                    reference.renderSlot.rawValue,
                    reference.aspectRatio,
                ])
            }
        }

        // Step 6: what preparation decided, so a later edition reuses the decision instead of redoing it.
        for preparation in request.mediaPreparations {
            let assetVersionID: Int64?
            if let digest = preparation.contentDigest, let recipe = preparation.recipeVersion {
                guard let resolved = assetIDs[
                    AssetIdentity(digest: digest, recipeVersion: recipe)
                ] else {
                    throw PublicationStorageError.corruptedRow(
                        "a prepared candidate names an asset version this commit does not carry"
                    )
                }
                assetVersionID = resolved
            } else {
                assetVersionID = nil
            }
            try db.execute(sql: """
                INSERT INTO media_preparation (
                    origin_revision_id, candidate_key, role, state, asset_version_id,
                    placeholder_recipe, decision_revision, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(origin_revision_id, candidate_key, role) DO UPDATE SET
                    state = excluded.state,
                    asset_version_id = excluded.asset_version_id,
                    placeholder_recipe = excluded.placeholder_recipe,
                    decision_revision = excluded.decision_revision,
                    updated_at_ms = excluded.updated_at_ms
                """, arguments: [
                preparation.originRevisionID.rawValue,
                preparation.candidateKey,
                preparation.role.rawValue,
                preparation.state.rawValue,
                assetVersionID,
                preparation.placeholderRecipe,
                preparation.decisionRevision,
                PublicationTimestamp.milliseconds(preparation.updatedAt),
            ])
        }

        // Step 7: the swap. The successor's segment is already durable, so the pointer can only move to
        // an edition that has content, in one transaction (ADR-001 D7).
        var activated = false
        if case let .activate(successorOf) = request.activation {
            let contextKey = try String.fetchOne(
                db,
                sql: "SELECT context_key FROM feed_edition WHERE edition_id = ?",
                arguments: [token.editionID.rawValue]
            )
            guard let contextKey else {
                throw PublicationFailure.editionNotFound(token.editionID)
            }
            if let successorOf {
                let previous = try edition(db, successorOf)
                guard previous?.contextKey == contextKey else {
                    throw PublicationFailure.invalidComposition(
                        "the successor names an edition of another context"
                    )
                }
            }
            if let existingRaw = try Int64.fetchOne(db, sql: """
                SELECT edition_id FROM feed_edition
                WHERE context_key = ? AND state = 'active' AND edition_id <> ?
                """, arguments: [contextKey, token.editionID.rawValue]) {
                let existing = try EditionID(existingRaw)
                if let successorOf, successorOf != existing {
                    throw PublicationFailure.invalidComposition(
                        "another edition became active while the successor was being built"
                    )
                }
                try db.execute(
                    sql: "UPDATE feed_edition SET state = 'superseded' WHERE edition_id = ?",
                    arguments: [existing.rawValue]
                )
            }
            if interrupted(.beforeActivation) {
                throw PublicationStorageError.interrupted(interruptionProbe)
            }
            try db.execute(sql: """
                UPDATE feed_edition SET state = 'active', activated_at_ms = ?
                WHERE edition_id = ? AND state = 'draft'
                """, arguments: [
                PublicationTimestamp.milliseconds(request.committedAt),
                token.editionID.rawValue,
            ])
            activated = db.changesCount == 1
        }

        if interrupted(.storageFailureAtCommit) {
            // A storage-level failure, not a refusal: the transaction rolls back and the caller's
            // bounded retry may run with the same token.
            throw RuntimeDatabaseError.transaction(storageFailureProbe)
        }

        return SegmentCommitReceipt(
            editionID: token.editionID,
            segmentID: segmentID,
            segmentOrdinal: request.segmentOrdinal,
            absoluteOrdinalStart: request.absoluteOrdinalStart,
            absoluteOrdinalEnd: resulting.absoluteOrdinal,
            cardIDs: cardIDs,
            tail: resulting,
            activated: activated
        )
    }

    /// Whether the edition's current state may perform this activation (ADR-001 D7).
    private static func activationAllows(_ activation: SegmentActivation) -> String {
        switch activation {
        case .append: return "state = 'active'"
        case .activate: return "state = 'draft'"
        }
    }

    /// Whether the requested kind of append is legal for a state (ADR-001 D7).
    private static func activationAllows(_ activation: SegmentActivation, state: EditionState) -> Bool {
        switch activation {
        case .append: return state == .active
        case .activate: return state == .draft
        }
    }

    /// Why a zero-row compare-and-swap failed, in the order the invariants are checked.
    private static func classify(
        _ db: Database,
        token: PublicationToken,
        activation: SegmentActivation
    ) throws -> PublicationFailure {
        guard let row = try editionRow(
            db,
            sql: "SELECT * FROM feed_edition WHERE edition_id = ?",
            arguments: [token.editionID.rawValue]
        ) else {
            return .editionNotFound(token.editionID)
        }
        let edition = try snapshot(of: row)
        // The order is the order of specificity: a stale epoch is reported before a stale revision, a
        // stale revision before a moved tail, and the state last. Two writers that captured the same tail
        // are therefore reported as a tail conflict — the state change the winner caused is a consequence
        // of that same commit, not a second failure.
        guard edition.epoch == token.epoch else {
            return .staleEpoch(expected: token.epoch, actual: edition.epoch)
        }
        guard edition.editorialRevision == token.editorialRevision else {
            return .editorialRevisionChanged(
                expected: token.editorialRevision.digest,
                actual: edition.editorialRevision.digest
            )
        }
        guard edition.tail == token.tail else {
            return .tailMismatch(expected: token.tail, actual: edition.tail)
        }
        guard edition.state.acceptsAppend, activationAllows(activation, state: edition.state) else {
            return .editionNotActive(token.editionID, state: edition.state)
        }
        // Unreachable: the compare-and-swap predicate is exactly the conjunction checked above, so a
        // zero-row result with every field matching would be a lie. Reported as corruption, never as a
        // refusal the caller could retry.
        throw PublicationStorageError.corruptedRow("a compare-and-swap failed with a matching token")
    }

    private static func ineligible(_ db: Database, _ revisions: [OriginRevisionID]) throws -> [OriginRevisionID] {
        var revoked: [OriginRevisionID] = []
        var checked = Set<Int64>()
        for revision in revisions where checked.insert(revision.rawValue).inserted {
            let eligible = try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM origin_revision r
                JOIN origin_record o ON o.id = r.origin_record_id
                JOIN selection_supply s
                  ON s.origin_record_id = r.origin_record_id AND s.origin_revision_id = r.id
                WHERE r.id = ? AND o.availability = 'available'
                """, arguments: [revision.rawValue]) ?? 0
            if eligible == 0 { revoked.append(revision) }
        }
        return revoked
    }

    // MARK: - Row mapping

    private struct AssetIdentity: Hashable {
        let digest: String
        let recipeVersion: Int
    }

    private static func editionRow(
        _ db: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> Row? {
        try Row.fetchOne(db, sql: sql, arguments: arguments)
    }

    private static func edition(_ db: Database, _ editionID: EditionID) throws -> EditionSnapshot? {
        try editionRow(
            db,
            sql: "SELECT * FROM feed_edition WHERE edition_id = ?",
            arguments: [editionID.rawValue]
        ).map(snapshot(of:))
    }

    private static func snapshot(of row: Row) throws -> EditionSnapshot {
        guard let editionID = try? EditionID(row["edition_id"]) else {
            throw PublicationStorageError.corruptedRow("feed_edition.edition_id")
        }
        let digest: String = row["editorial_revision"]
        guard let state = EditionState(rawValue: row["state"]) else {
            throw PublicationStorageError.corruptedRow("feed_edition.state = \(row["state"] as String)")
        }
        let revision: EditorialRevision
        do {
            // ADR-001's `feed_edition` stores the digest alone, so the scheme is this build's. A row
            // whose digest is malformed is corruption, not a revision to compare.
            revision = try EditorialRevision(
                schemeVersion: EditorialRevision.currentSchemeVersion,
                digest: digest
            )
        } catch {
            throw PublicationStorageError.corruptedRow("feed_edition.editorial_revision")
        }
        let successor: EditionID? = (row["successor_of_edition_id"] as Int64?)
            .flatMap { try? EditionID($0) }
        return EditionSnapshot(
            editionID: editionID,
            contextKey: row["context_key"],
            editorialRevision: revision,
            publicationSchemaVersion: row["publication_schema_version"],
            epoch: row["epoch"],
            seed: row["seed"],
            state: state,
            successorOfEditionID: successor,
            tail: EditionTail(
                segmentOrdinal: row["tail_segment_ordinal"],
                absoluteOrdinal: row["tail_absolute_ordinal"],
                version: row["version"]
            ),
            createdAt: PublicationTimestamp.date(row["created_at_ms"]),
            activatedAt: (row["activated_at_ms"] as Int64?).map(PublicationTimestamp.date)
        )
    }

    private static func segmentSnapshot(of row: Row) throws -> SegmentSnapshot {
        guard let segmentID = try? SegmentID(row["segment_id"]),
              let editionID = try? EditionID(row["edition_id"])
        else {
            throw PublicationStorageError.corruptedRow("feed_segment identifier")
        }
        return SegmentSnapshot(
            segmentID: segmentID,
            editionID: editionID,
            segmentOrdinal: row["segment_ordinal"],
            absoluteOrdinalStart: row["absolute_ordinal_start"],
            absoluteOrdinalEnd: row["absolute_ordinal_end"],
            policyRevision: row["policy_revision"],
            seed: row["seed"],
            committedAt: PublicationTimestamp.date(row["committed_at_ms"])
        )
    }

    /// Every card of an edition, rebuilt from the card row, its segment and its asset references.
    private static func cards(_ db: Database, editionID: EditionID) throws -> [PublishedCardRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.*, s.segment_ordinal AS segment_ordinal,
                   e.editorial_revision AS edition_editorial_revision
            FROM published_card c
            JOIN feed_segment s ON s.edition_id = c.edition_id AND s.segment_id = c.segment_id
            JOIN feed_edition e ON e.edition_id = c.edition_id
            WHERE c.edition_id = ?
            ORDER BY c.absolute_ordinal
            """, arguments: [editionID.rawValue])
        return try rows.map { try cardRecord(db, row: $0) }
    }

    private static func cardRecord(_ db: Database, row: Row) throws -> PublishedCardRecord {
        guard let cardID = try? PublicationCardID(row["publication_card_id"]),
              let editionID = try? EditionID(row["edition_id"]),
              let segmentID = try? SegmentID(row["segment_id"]),
              let originRecordID = try? OriginRecordID(row["origin_record_id"]),
              let originRevisionID = try? OriginRevisionID(row["origin_revision_id"])
        else {
            throw PublicationStorageError.corruptedRow("published_card identifier")
        }
        guard let timestampKind = PublishedTimestampKind(rawValue: row["published_at_kind"]) else {
            throw PublicationStorageError.corruptedRow("published_card.published_at_kind")
        }
        guard let renderKind = RenderKind(rawValue: row["render_kind"]) else {
            throw PublicationStorageError.corruptedRow("published_card.render_kind")
        }
        guard let mediaSlot = MediaSlot(rawValue: row["render_media_slot"]) else {
            throw PublicationStorageError.corruptedRow("published_card.render_media_slot")
        }
        guard let revision = try? EditorialRevision(
            schemeVersion: EditorialRevision.currentSchemeVersion,
            digest: row["edition_editorial_revision"]
        ) else {
            throw PublicationStorageError.corruptedRow("published_card.edition revision")
        }

        let action: FeedPrimaryAction?
        if let kindRaw: String = row["primary_action_kind"],
           let reference: String = row["primary_action_reference"],
           let kind = FeedPrimaryAction.Kind(rawValue: kindRaw) {
            do {
                action = try FeedPrimaryAction.decode(kind: kind, reference: reference)
            } catch {
                throw PublicationStorageError.corruptedRow(
                    "published_card.primary_action_reference = \(reference)"
                )
            }
        } else {
            action = nil
        }

        let references = try Row.fetchAll(db, sql: """
            SELECT r.slot, r.role, r.render_slot, a.content_digest, a.recipe_version,
                   a.pixel_width, a.pixel_height, a.mime_type
            FROM published_asset_ref r
            JOIN asset_version a ON a.asset_version_id = r.asset_version_id
            WHERE r.publication_card_id = ?
            ORDER BY r.slot, a.content_digest
            """, arguments: [cardID.rawValue]).map { reference -> PublishedAssetReference in
            let digest: String = reference["content_digest"]
            let recipe: Int = reference["recipe_version"]
            return PublishedAssetReference(
                slot: PublishedAssetSlot(rawValue: reference["slot"]) ?? .alternate,
                role: MediaRole(rawValue: reference["role"]) ?? .image,
                renderSlot: MediaSlot(rawValue: reference["render_slot"]) ?? .none,
                media: PublishedMediaRef(
                    contentDigest: digest,
                    recipeVersion: recipe,
                    pixelWidth: reference["pixel_width"],
                    pixelHeight: reference["pixel_height"],
                    mimeType: reference["mime_type"]
                )
            )
        }

        let declaredSlot = mediaSlot
        let aspectRatio: Double? = row["render_aspect_ratio"]
        let primary = references.first { $0.slot == .primary }
        let alternates = references.filter { $0.slot != .primary }
        let placeholder: PublishedPlaceholder?
        if primary == nil, alternates.isEmpty, declaredSlot.drawsMedia {
            placeholder = PublishedPlaceholder(
                originRevisionID: originRevisionID,
                slot: declaredSlot,
                aspectRatio: aspectRatio
            )
        } else {
            placeholder = nil
        }

        let frozen = PublishedCardPayload.Frozen(
            editionID: editionID,
            segmentOrdinal: row["segment_ordinal"],
            absoluteOrdinal: row["absolute_ordinal"],
            origin: PublishedOrigin(
                originRecordID: originRecordID,
                originRevisionID: originRevisionID,
                sourceID: (row["source_id"] as Int64?).flatMap { try? SourceID(UInt64($0)) },
                providerID: (row["provider_id"] as Int64?).flatMap { try? ProviderID(UInt64($0)) },
                sourceDisplayName: row["source_display_name"],
                providerDisplayName: row["provider_display_name"]
            ),
            title: row["title"],
            primaryText: row["primary_text"],
            publishedAt: (row["published_at_ms"] as Int64?).map(PublicationTimestamp.date),
            publishedAtKind: timestampKind,
            observationAt: PublicationTimestamp.date(row["observation_at_ms"]),
            media: PublishedMediaSet(
                primary: primary?.media,
                alternates: alternates,
                placeholder: placeholder
            ),
            primaryAction: action,
            interactionSummary: row["interaction_summary"],
            renderContract: RenderContract(
                version: row["render_contract_version"],
                kind: renderKind,
                mediaSlot: mediaSlot,
                aspectRatio: aspectRatio
            ),
            editorialRevision: revision,
            publicationSchemaVersion: row["publication_schema_version"]
        )
        return PublishedCardRecord(
            payload: PublishedCardPayload(cardID: cardID, frozen: frozen),
            segmentID: segmentID,
            payloadDigest: row["payload_digest"]
        )
    }

    private static func assetSnapshot(of row: Row) throws -> AssetVersionSnapshot {
        guard let storageClass = PublishedAssetStorageClass(rawValue: row["storage_class"]),
              let durability = PublishedAssetDurability(rawValue: row["durability_state"])
        else {
            throw PublicationStorageError.corruptedRow("asset_version storage columns")
        }
        return AssetVersionSnapshot(
            assetVersionID: row["asset_version_id"],
            contentDigest: row["content_digest"],
            byteCount: row["byte_count"],
            mimeType: row["mime_type"],
            pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"],
            recipeVersion: row["recipe_version"],
            storageClass: storageClass,
            relativePath: row["relative_path"],
            durability: durability,
            createdAt: PublicationTimestamp.date(row["created_at_ms"])
        )
    }
}

/// Timestamps are integer milliseconds since the Unix epoch everywhere in the runtime (ADR-002 D3).
///
/// One implementation, in the domain payload, so storage and publication cannot disagree about how a
/// date becomes a column.
public enum PublicationTimestamp {
    public static func milliseconds(_ date: Date) -> Int64 {
        PublishedCardPayload.milliseconds(date)
    }

    public static func date(_ milliseconds: Int64) -> Date {
        PublishedCardPayload.date(milliseconds: milliseconds)
    }
}
