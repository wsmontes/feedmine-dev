import Foundation
import FeedDomain
import GRDB

/// Which collection strategy a run uses (ADR-004 D8: mark/sweep **or** transactional refcounts with
/// periodic reconciliation).
public enum GCRunMode: String, Hashable, Sendable, CaseIterable {
    /// Collect what no root protects.
    case markSweep = "mark_sweep"
    /// Collect nothing; re-derive every root and report the invariants a sweep would have broken.
    case refcountReconcile = "refcount_reconcile"
}

/// What one run did to one class.
public struct GCRunClassResult: Hashable, Sendable {
    public let retentionClass: RetentionClass
    public let collected: Int
    /// Objects the run refused to take because a root still pins them.
    public let protected: Int
    public let freedBytes: Int
    public let orphansCollected: Int
    /// Why the class was not collected at all. `nil` means the class was run.
    public let skipped: String?

    public init(
        retentionClass: RetentionClass,
        collected: Int = 0,
        protected: Int = 0,
        freedBytes: Int = 0,
        orphansCollected: Int = 0,
        skipped: String? = nil
    ) {
        self.retentionClass = retentionClass
        self.collected = collected
        self.protected = protected
        self.freedBytes = freedBytes
        self.orphansCollected = orphansCollected
        self.skipped = skipped
    }
}

/// The durable account of one run, as `gc_run` + `gc_run_class` hold it and as the caller reads it.
public struct GCRunReport: Hashable, Sendable {
    public let runID: Int64
    public let mode: GCRunMode
    public let startedAt: Date
    public let finishedAt: Date
    public let classes: [GCRunClassResult]
    /// Invariants a reconciliation found broken. A blocker is never fixed silently: it is reported,
    /// and `markSweep` is the mode that acts, never this one.
    public let blockers: [String]
    /// Where the bookmark root came from. Recorded with the run because it is the one root this
    /// database cannot derive alone (ADR-004 D7 makes `user.sqlite` the authority), so a run's account
    /// has to say whether the authority was read or only the runtime's projection.
    public let bookmarkRootSource: String

    public var collected: Int { classes.reduce(0) { $0 + $1.collected } }
    public var protected: Int { classes.reduce(0) { $0 + $1.protected } }
    public var freedBytes: Int { classes.reduce(0) { $0 + $1.freedBytes } }
    public var orphansCollected: Int { classes.reduce(0) { $0 + $1.orphansCollected } }

    /// Whether any class was left uncollected. A degraded run is a state to report, not a failure:
    /// a class with no declared policy is skipped *by design*, and the run says so.
    public var isDegraded: Bool { classes.contains { $0.skipped != nil } }

    public func result(for retentionClass: RetentionClass) -> GCRunClassResult? {
        classes.first { $0.retentionClass == retentionClass }
    }
}

public enum RetentionError: Error, Equatable, Sendable {
    /// A run was asked for a class D8 marks never collected.
    case refusesNeverCollectedClass(RetentionClass)
}

/// The coordinator D8 asks for: nothing else decides across classes what may be collected, in what
/// order, and nothing else records that a run happened.
///
/// It owns three decisions and delegates the rest:
///
/// * **order** — `RetentionClass.collectionOrder`, cheapest-to-recover first, with the edition purge
///   ahead of the published-bytes pass so a pin released by this run is collectable in this run;
/// * **roots** — every decision re-derives them from durable state (`RetentionRootProviding`), never
///   from a set computed earlier in the run, so a released pin is visible immediately and a lost pin
///   is visible in reconciliation;
/// * **the account** — one `gc_run` row, its per-class results, and the `last_gc_revision` /
///   `last_purge_revision` cursors in `runtime_metadata` (ADR-004 D4: the derived-metadata home, and
///   never a second migration counter).
///
/// Collection itself stays where it already works: `DecodedImageCache.collectUnpinnedEntries()` and
/// `LocalAssetStore.collectOrphanTemporaryFiles()` are reached through `RetentionMediaCollecting`,
/// and the SQL classes are collected here because they are rows in this database.
public struct RetentionCoordinator: Sendable {
    /// The `runtime_metadata` key holding the highest wall clock a run has seen. Monotonic where the
    /// wall clock is not, and the floor a rewound clock is measured against.
    public static let clockHighWaterKey = "retention_clock_high_water_ms"
    /// The cursor ADR-004 D4 names: the id of the most recent run that removed canonical supply or
    /// connector evidence.
    public static let lastPurgeRevisionKey = "last_purge_revision"
    /// The id of the most recent completed run.
    public static let lastGCRunKey = "last_gc_revision"

    public struct Options: Hashable, Sendable {
        /// Whether a run may checkpoint the WAL. Maintenance, not collection: it never deletes a file
        /// a connection holds open (D8).
        public var checkpointsWAL: Bool = true

        public init(checkpointsWAL: Bool = true) {
            self.checkpointsWAL = checkpointsWAL
        }
    }

    private let database: RuntimeDatabase
    private let media: (any RetentionMediaCollecting)?
    private let roots: any RetentionRootProviding
    private let clock: any EditorialClock
    private let options: Options
    /// Where a run's duration and its orphan count go (plan §16). `nil` means no diagnostics.
    private let metrics: RuntimeMetricsRecorder?

    public init(
        database: RuntimeDatabase,
        media: (any RetentionMediaCollecting)? = nil,
        roots: any RetentionRootProviding = SqlRetentionRootProvider(),
        clock: any EditorialClock,
        options: Options = Options(),
        metrics: RuntimeMetricsRecorder? = nil
    ) {
        self.database = database
        self.media = media
        self.roots = roots
        self.clock = clock
        self.options = options
        self.metrics = metrics
    }

    // MARK: - Running

    /// Runs one collection pass and records it.
    ///
    /// - Returns: the account of the run, which is also what the database now holds.
    /// - Throws: only a storage failure. A class that cannot be collected is a *result* of the run
    ///   (`GCRunClassResult.skipped`), not a thrown error, because a partial GC is a normal state and
    ///   must still leave its account behind.
    public func run(mode: GCRunMode = .markSweep) async throws -> GCRunReport {
        let startedAt = clock.now
        let runID = try beginRun(mode: mode, at: startedAt)
        let policies = RetentionPolicyStore(database: database)
        var results: [GCRunClassResult] = []
        var blockers: [String] = []
        do {
            let now = try effectiveNowMilliseconds()
            // Reconciliation is a property of the durable state, not of one class, so it is evaluated
            // once per run and reported beside the per-class account rather than repeated in it.
            if mode == .refcountReconcile {
                blockers = try reconcile()
            }

            for retentionClass in RetentionClass.collectionOrder {
                let declared = try policies.policy(retentionClass)
                let context = ClassContext(
                    retentionClass: retentionClass,
                    policy: declared,
                    nowMilliseconds: now.milliseconds,
                    clockRewound: now.rewound,
                    mode: mode
                )
                let outcome = try await collect(context)
                results.append(outcome.result)
                blockers.append(contentsOf: outcome.blockers)
            }

            let finishedAt = clock.now
            try finishRun(
                runID,
                at: finishedAt,
                results: results,
                blockers: blockers,
                mode: mode
            )
            let report = GCRunReport(
                runID: runID,
                mode: mode,
                startedAt: startedAt,
                finishedAt: finishedAt,
                classes: results,
                blockers: blockers,
                bookmarkRootSource: roots.rootSourceDescription
            )
            recordRun(report, startedAt: startedAt, outcome: "completed")
            return report
        } catch {
            // The run keeps its row and says it was aborted: a crash or a storage failure during GC
            // must not look like a run that never happened.
            try? abortRun(runID, at: clock.now, reason: "\(error)")
            if let metrics {
                Task {
                    await metrics.record(
                        OperationSample(
                            operation: .retentionRun,
                            operationID: "gc-run-\(runID)",
                            durationMilliseconds: 0,
                            outcome: "aborted"
                        )
                    )
                }
            }
            throw error
        }
    }

    /// One run's measurement, plus the two counters §16 names: how often GC ran, and how many orphan
    /// asset files it had to reclaim.
    private func recordRun(_ report: GCRunReport, startedAt: Date, outcome: String) {
        guard let metrics else { return }
        let elapsed = clock.now.timeIntervalSince(startedAt) * 1_000
        let classes = report.classes.filter { $0.skipped == nil }.count
        Task {
            await metrics.record(
                OperationSample(
                    operation: .retentionRun,
                    operationID: "gc-run-\(report.runID)",
                    durationMilliseconds: elapsed,
                    outcome: "\(outcome) classes=\(classes) collected=\(report.collected)"
                        + " orphans=\(report.orphansCollected)"
                )
            )
            await metrics.count(.gcRun)
            if report.orphansCollected > 0 {
                await metrics.count(.orphanAssetCollected, by: report.orphansCollected)
            }
        }
    }

    /// The most recent completed run, or `nil` when none was ever recorded.
    public func lastRun() throws -> (runID: Int64, mode: GCRunMode, finishedAt: Date)? {
        try database.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT id, mode, finished_at_ms FROM gc_run
                WHERE outcome = 'completed' AND finished_at_ms IS NOT NULL
                ORDER BY id DESC LIMIT 1
                """) else { return nil }
            let raw: String = row["mode"]
            guard let mode = GCRunMode(rawValue: raw) else { return nil }
            let finishedAt: Int64 = row["finished_at_ms"]
            return (row["id"], mode, RetentionTimestamp.date(milliseconds: finishedAt))
        }
    }

    // MARK: - Per-class context

    private struct TimeReading {
        let milliseconds: Int64
        let rewound: Bool
    }

    private struct ClassContext {
        let retentionClass: RetentionClass
        let policy: RetentionPolicy?
        let nowMilliseconds: Int64
        let clockRewound: Bool
        let mode: GCRunMode

        var ageCutoffMilliseconds: Int64? {
            policy?.ageCutoffMilliseconds(now: nowMilliseconds)
        }
    }

    private struct ClassOutcome {
        let result: GCRunClassResult
        var blockers: [String] = []
    }

    private func collect(_ context: ClassContext) async throws -> ClassOutcome {
        if context.retentionClass.isNeverCollected {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: context.retentionClass,
                    skipped: "ADR-004 D8 marks this class never collected: the user deletes it, never a quota"
                )
            )
        }
        if context.mode == .refcountReconcile {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: context.retentionClass,
                    skipped: "reconciliation collects nothing"
                )
            )
        }
        switch context.retentionClass {
        case .durableUserState:
            // Unreachable: handled above, and kept here so the switch stays exhaustive.
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .durableUserState,
                    skipped: "ADR-004 D8 marks this class never collected"
                )
            )
        case .diagnostics:
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .diagnostics,
                    skipped: "the shadow and diagnostic bytes live outside this database"
                )
            )
        case .walAndJournal:
            return try checkpointWAL(context)
        case .decodedCache, .unpublishedDownloads:
            return try await collectMedia(context)
        case .publishedAssetBytes:
            return try await collectPublishedAssetBytes(context)
        case .reconstructibleProjections:
            return try collectProjections(context)
        case .connectorEvidence:
            return try collectConnectorEvidence(context)
        case .canonicalSupply:
            return try collectCanonicalSupply(context)
        case .publication:
            return try collectSupersededEditions(context)
        }
    }

    // MARK: - Media classes

    private func collectMedia(_ context: ClassContext) async throws -> ClassOutcome {
        guard let policy = context.policy else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: context.retentionClass,
                    skipped: "no declared retention policy for this class"
                )
            )
        }
        guard let media else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: context.retentionClass,
                    skipped: "no media port attached to this run"
                )
            )
        }
        let outcome: MediaCollectionOutcome
        switch context.retentionClass {
        case .decodedCache:
            outcome = await media.collectUnpinnedMedia()
        default:
            // Unpublished downloads are bytes, not cache entries: the orphan temporary files of an
            // interrupted commit, plus the versions this database just marked unreleased.
            var combined = await media.collectOrphanAssetFiles()
            let keys = try takeUnreleasedAssets(storageClass: "cached", policy: policy, context: context)
            if !keys.isEmpty {
                combined = combined + (await media.collectAssetBytes(keys))
            }
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .unpublishedDownloads,
                    collected: combined.collected,
                    protected: combined.protectedByPin,
                    freedBytes: combined.freedBytes,
                    orphansCollected: combined.orphansCollected
                )
            )
        }
        return ClassOutcome(
            result: GCRunClassResult(
                retentionClass: .decodedCache,
                collected: outcome.collected,
                protected: outcome.protectedByPin,
                freedBytes: outcome.freedBytes,
                orphansCollected: outcome.orphansCollected
            )
        )
    }

    /// Published bytes whose every reference was released, plus the bytes of versions nothing names.
    ///
    /// Identity survives: the row stays and moves to `bytes_removed`, so a card that still names the
    /// asset renders its deterministic placeholder instead of losing its layout (ADR-001 D14,
    /// ADR-004 D10).
    private func collectPublishedAssetBytes(_ context: ClassContext) async throws -> ClassOutcome {
        guard let policy = context.policy else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .publishedAssetBytes,
                    skipped: "no declared retention policy for this class"
                )
            )
        }
        // One transaction decides and marks: the roots are read from the same snapshot the rows are
        // taken from, so a pin cannot appear between the two.
        let taken = try database.write { database -> (keys: [MediaAssetKey], blockedByPin: Int) in
            let protection = try roots.roots(in: database)
            // The roots decide what is pinned, and they are the only decision point (D8: a pin on a
            // retention root blocks collection unconditionally). The SQL below therefore names only
            // what makes a version collectable *in principle* — committed bytes no preparation is
            // holding — and leaves "is it still referenced by a retained edition" to the roots, which
            // is what makes a lost pin observable in reconciliation instead of invisible here.
            let candidates = try Row.fetchAll(database, sql: """
                SELECT a.asset_version_id, a.content_digest, a.recipe_version, a.byte_count
                FROM asset_version a
                WHERE a.durability_state = 'committed'
                  AND a.asset_version_id NOT IN (
                        SELECT asset_version_id FROM media_preparation
                        WHERE asset_version_id IS NOT NULL
                  )
                ORDER BY a.created_at_ms, a.asset_version_id
                """)
            let blockedByPin = candidates.filter { row in
                protection.protectedAssetVersions.contains(row["asset_version_id"] as Int64)
            }.count
            let selected = Self.underByteBudget(
                candidates.map { (id: $0["asset_version_id"] as Int64, bytes: $0["byte_count"] as Int64) },
                maxBytes: policy.maxBytes,
                totalBytes: try committedAssetBytes(in: database)
            ).filter { !protection.protectedAssetVersions.contains($0) }
            let eligible = candidates.filter { selected.contains($0["asset_version_id"] as Int64) }
            return (try Self.markBytesRemoved(eligible, in: database), blockedByPin)
        }
        guard let media, !taken.keys.isEmpty else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .publishedAssetBytes,
                    collected: taken.keys.count,
                    protected: taken.blockedByPin,
                    skipped: media == nil ? "no media port attached to this run" : nil
                )
            )
        }
        let outcome = await media.collectAssetBytes(taken.keys)
        return ClassOutcome(
            result: GCRunClassResult(
                retentionClass: .publishedAssetBytes,
                collected: outcome.collected,
                protected: taken.blockedByPin + outcome.protectedByPin,
                freedBytes: outcome.freedBytes
            )
        )
    }

    // MARK: - SQL classes

    private func collectProjections(_ context: ClassContext) throws -> ClassOutcome {
        guard context.policy != nil else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .reconstructibleProjections,
                    skipped: "no declared retention policy for this class"
                )
            )
        }
        // Only rows whose parent is already gone: a projection is rebuildable, so an orphan is not
        // state, and a crash between a canonical delete and its projections is exactly how one
        // appears. Supply rows carry a generation, so removing one is not silent.
        let removed = try database.write { database -> Int in
            try database.execute(sql: """
                DELETE FROM origin_search WHERE rowid NOT IN (SELECT id FROM origin_record)
                """)
            let searchRows = database.changesCount
            try database.execute(sql: """
                DELETE FROM selection_supply WHERE origin_record_id NOT IN (SELECT id FROM origin_record)
                """)
            let supplyRows = database.changesCount
            if supplyRows > 0 {
                try database.execute(sql: "UPDATE supply_generation SET value = value + 1 WHERE id = 1")
            }
            return searchRows + supplyRows
        }
        return ClassOutcome(
            result: GCRunClassResult(
                retentionClass: .reconstructibleProjections,
                collected: removed
            )
        )
    }

    private func collectConnectorEvidence(_ context: ClassContext) throws -> ClassOutcome {
        guard let policy = context.policy else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .connectorEvidence,
                    skipped: "no declared retention policy for this class"
                )
            )
        }
        guard !context.clockRewound, let cutoff = context.ageCutoffMilliseconds else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .connectorEvidence,
                    skipped: context.clockRewound
                        ? "wall clock rewound: age-based collection suspended"
                        : "no age limit declared for this class"
                )
            )
        }
        let collected = try database.write { database -> (rows: Int, bytes: Int64) in
            let bytes = try Int64.fetchOne(database, sql: """
                SELECT COALESCE(SUM(COALESCE(length(bytes), 0)), 0)
                FROM connector_evidence WHERE created_at < ?
                """, arguments: [cutoff]) ?? 0
            try database.execute(
                sql: "DELETE FROM connector_evidence WHERE created_at < ?",
                arguments: [cutoff]
            )
            var rows = database.changesCount
            var released = bytes
            // The byte limit is applied after the age limit, oldest first, and only when the class
            // still exceeds it: evidence is advisory, so it may expire ahead of supply (D8).
            if let maxBytes = policy.maxBytes {
                var held = try Int64.fetchOne(
                    database,
                    sql: "SELECT COALESCE(SUM(COALESCE(length(bytes), 0)), 0) FROM connector_evidence"
                ) ?? 0
                while held > maxBytes {
                    guard let oldest = try Row.fetchOne(database, sql: """
                        SELECT id, COALESCE(length(bytes), 0) AS bytes FROM connector_evidence
                        ORDER BY created_at, id LIMIT 1
                        """) else { break }
                    let size: Int64 = oldest["bytes"]
                    try database.execute(
                        sql: "DELETE FROM connector_evidence WHERE id = ?",
                        arguments: [oldest["id"] as Int64]
                    )
                    held -= size
                    released += size
                    rows += 1
                }
            }
            return (rows, released)
        }
        return ClassOutcome(
            result: GCRunClassResult(
                retentionClass: .connectorEvidence,
                collected: collected.rows,
                freedBytes: Int(collected.bytes)
            )
        )
    }

    /// Non-current revisions no durable fact needs, older than the declared age.
    ///
    /// Revisions, not records: a record is the identity continuity of an external object
    /// (`external_identity.origin_record_id`, `legacy_item_map`), and evicting it is a rebuild
    /// decision rather than a byte decision, so this run leaves records alone. A revision is only
    /// ever taken when it is not the current one and no card, preparation or mapping names it.
    private func collectCanonicalSupply(_ context: ClassContext) throws -> ClassOutcome {
        guard let policy = context.policy else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .canonicalSupply,
                    skipped: "no declared retention policy for this class"
                )
            )
        }
        guard !context.clockRewound, let cutoff = context.ageCutoffMilliseconds else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .canonicalSupply,
                    skipped: context.clockRewound
                        ? "wall clock rewound: age-based collection suspended"
                        : "no age limit declared for this class"
                )
            )
        }
        _ = policy
        let outcome = try database.write { database -> (rows: Int, bytes: Int64, protected: Int) in
            let protection = try roots.roots(in: database)
            let candidates = try Row.fetchAll(database, sql: """
                SELECT v.id,
                       COALESCE(length(COALESCE(v.headline, ''))
                                + length(COALESCE(v.summary, ''))
                                + length(COALESCE(v.body_text, '')), 0) AS bytes
                FROM origin_revision v
                WHERE v.created_at < ?
                  AND v.id NOT IN (SELECT current_revision_id FROM origin_record
                                   WHERE current_revision_id IS NOT NULL)
                ORDER BY v.created_at, v.id
                """, arguments: [cutoff])
            var rows = 0
            var bytes: Int64 = 0
            var protected = 0
            for candidate in candidates {
                let id: Int64 = candidate["id"]
                if protection.protectedRevisions.contains(id) {
                    protected += 1
                    continue
                }
                let size: Int64 = candidate["bytes"]
                // The revision's children are part of its payload: they go with it, in this
                // transaction, so no candidate or offer survives its revision.
                for table in ["media_candidate", "interaction_offer"] {
                    try database.execute(
                        sql: "DELETE FROM \(table) WHERE origin_revision_id = ?",
                        arguments: [id]
                    )
                }
                try database.execute(
                    sql: "DELETE FROM provider_attribution WHERE origin_revision_id = ?",
                    arguments: [id]
                )
                try database.execute(sql: "DELETE FROM origin_revision WHERE id = ?", arguments: [id])
                rows += 1
                bytes += size
            }
            return (rows, bytes, protected)
        }
        return ClassOutcome(
            result: GCRunClassResult(
                retentionClass: .canonicalSupply,
                collected: outcome.rows,
                protected: outcome.protected,
                freedBytes: Int(outcome.bytes)
            )
        )
    }

    /// Superseded editions beyond the declared count.
    ///
    /// The never-collected set is not "whatever the count excludes": the active edition, every
    /// checkpointed edition and every edition reachable from a bookmark are removed from the
    /// candidates *before* the count is applied, so a small `max_editions` can never trade a saved
    /// article for a newer edition. Purging releases the edition's asset pins, which is why the
    /// published-bytes pass runs after this one.
    private func collectSupersededEditions(_ context: ClassContext) throws -> ClassOutcome {
        guard let policy = context.policy, let maxEditions = policy.maxEditions else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .publication,
                    skipped: "no declared edition limit for this class"
                )
            )
        }
        let purged = try database.write { database -> (rows: Int, protected: Int) in
            let protection = try roots.roots(in: database)
            let candidates = try Int64.fetchAll(database, sql: """
                SELECT edition_id FROM feed_edition
                WHERE state = 'superseded'
                ORDER BY activated_at_ms DESC, edition_id DESC
                """)
            var purged = 0
            var protected = 0
            for (offset, editionID) in candidates.enumerated() {
                if protection.protectedEditions.contains(editionID) {
                    protected += 1
                    continue
                }
                guard offset >= maxEditions else { continue }
                // Order matters and the foreign keys enforce it: facts name a card of their edition,
                // cards name a segment of their edition, and the edition row stays as `purged` so the
                // successor chain keeps naming a row that exists.
                try database.execute(
                    sql: "DELETE FROM exposure_fact WHERE edition_id = ?",
                    arguments: [editionID]
                )
                try database.execute(
                    sql: "DELETE FROM published_card WHERE edition_id = ?",
                    arguments: [editionID]
                )
                try database.execute(
                    sql: "DELETE FROM feed_segment WHERE edition_id = ?",
                    arguments: [editionID]
                )
                try database.execute(
                    sql: "UPDATE feed_edition SET state = 'purged' WHERE edition_id = ?",
                    arguments: [editionID]
                )
                purged += 1
            }
            return (purged, protected)
        }
        return ClassOutcome(
            result: GCRunClassResult(
                retentionClass: .publication,
                collected: purged.rows,
                protected: purged.protected
            )
        )
    }

    private func checkpointWAL(_ context: ClassContext) throws -> ClassOutcome {
        guard context.policy != nil else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .walAndJournal,
                    skipped: "no declared retention policy for this class"
                )
            )
        }
        guard options.checkpointsWAL else {
            return ClassOutcome(
                result: GCRunClassResult(
                    retentionClass: .walAndJournal,
                    skipped: "WAL checkpointing disabled for this run"
                )
            )
        }
        try database.checkpointWAL()
        return ClassOutcome(
            result: GCRunClassResult(
                retentionClass: .walAndJournal,
                skipped: "checkpointed, never deleted: a -wal file is not a collection target while a connection holds it"
            )
        )
    }

    // MARK: - Reconciliation

    /// Re-derives every root and reports the invariants a sweep would have broken.
    ///
    /// It fixes nothing on purpose. The failure this catches is a pin nobody can see — bytes removed
    /// from under a retained card, a purged edition a bookmark points at, a saved item with no
    /// durable mapping left — and every one of those is a state the runtime must report rather than
    /// repair by guessing which side is wrong.
    private func reconcile() throws -> [String] {
        return try database.read { database -> [String] in
            let protection = try roots.roots(in: database)
            var blockers: [String] = []

            let missingBytes = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM published_asset_ref r
                JOIN published_card c ON c.publication_card_id = r.publication_card_id
                JOIN feed_edition e ON e.edition_id = c.edition_id
                WHERE e.state <> 'purged'
                  AND EXISTS (
                    SELECT 1 FROM asset_version a
                    WHERE a.asset_version_id = r.asset_version_id
                      AND a.durability_state <> 'committed'
                  )
                """) ?? 0
            if missingBytes > 0 {
                blockers.append("published bytes removed while a retained card names them: \(missingBytes)")
            }

            let danglingRefs = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM published_asset_ref r
                LEFT JOIN asset_version a ON a.asset_version_id = r.asset_version_id
                WHERE a.asset_version_id IS NULL
                """) ?? 0
            if danglingRefs > 0 {
                blockers.append("published asset references with no version row: \(danglingRefs)")
            }

            let orphanedCards = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM published_card c
                JOIN feed_edition e ON e.edition_id = c.edition_id
                LEFT JOIN origin_revision v ON v.id = c.origin_revision_id
                WHERE e.state <> 'purged' AND v.id IS NULL
                """) ?? 0
            if orphanedCards > 0 {
                blockers.append("retained cards whose canonical revision was collected: \(orphanedCards)")
            }

            let purgedRoots = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM feed_edition WHERE state = 'purged'
                """) ?? 0
            if purgedRoots > 0 {
                let purgedIDs = try Int64.fetchAll(
                    database,
                    sql: "SELECT edition_id FROM feed_edition WHERE state = 'purged'"
                )
                let hit = purgedIDs.filter { protection.protectedEditions.contains($0) }
                if !hit.isEmpty {
                    blockers.append("purged editions a root still points at: \(hit.count)")
                }
            }

            let unmappedBookmarks = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM user_state_projection p
                LEFT JOIN legacy_item_map m ON m.legacy_item_id = p.subject_id
                WHERE p.kind = 'bookmark' AND p.wanted = 1
                  AND (m.origin_record_id IS NULL
                       OR m.origin_record_id NOT IN (SELECT id FROM origin_record))
                """) ?? 0
            if unmappedBookmarks > 0 {
                blockers.append("saved items with no durable mapping to canonical content: \(unmappedBookmarks)")
            }

            return blockers
        }
    }

    // MARK: - Account

    private func beginRun(mode: GCRunMode, at date: Date) throws -> Int64 {
        try database.write { database in
            try database.execute(sql: """
                INSERT INTO gc_run (started_at_ms, mode, outcome)
                VALUES (?, ?, 'aborted')
                """, arguments: [RetentionTimestamp.milliseconds(date), mode.rawValue])
            return database.lastInsertedRowID
        }
    }

    private func finishRun(
        _ runID: Int64,
        at date: Date,
        results: [GCRunClassResult],
        blockers: [String],
        mode: GCRunMode
    ) throws {
        try database.write { database in
            for result in results {
                try database.execute(sql: """
                    INSERT INTO gc_run_class
                        (run_id, class, collected, protected, freed_bytes, orphans_collected, skipped)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    runID,
                    result.retentionClass.rawValue,
                    result.collected,
                    result.protected,
                    result.freedBytes,
                    result.orphansCollected,
                    result.skipped,
                ])
            }
            try database.execute(sql: """
                UPDATE gc_run SET finished_at_ms = ?, outcome = 'completed', detail = ? WHERE id = ?
                """, arguments: [
                RetentionTimestamp.milliseconds(date),
                blockers.isEmpty ? nil : blockers.joined(separator: "; "),
                runID,
            ])
            // D4's derived metadata: cursors, never a counter that could disagree with the migrator.
            try RuntimeMetadata.write(
                database,
                value: "\(runID)",
                forKey: Self.lastGCRunKey
            )
            let removedCanonical = results.contains {
                ($0.retentionClass == .canonicalSupply || $0.retentionClass == .connectorEvidence)
                    && $0.collected > 0
            }
            if removedCanonical {
                try RuntimeMetadata.write(
                    database,
                    value: "\(runID)",
                    forKey: Self.lastPurgeRevisionKey
                )
            }
            _ = mode
        }
    }

    private func abortRun(_ runID: Int64, at date: Date, reason: String) throws {
        try database.write { database in
            try database.execute(sql: """
                UPDATE gc_run SET finished_at_ms = ?, detail = ? WHERE id = ?
                """, arguments: [RetentionTimestamp.milliseconds(date), reason, runID])
        }
    }

    /// The clock a run decides with.
    ///
    /// The watermark is the monotonic part: it only ever moves forward, because it is written as the
    /// maximum of every wall clock a run has seen. A wall clock behind it is a rollback, and the run
    /// *suspends* age-based collection instead of deciding from it — an age computed from a rewound
    /// clock either evicts rows that were just written or keeps expired ones forever, and neither is
    /// recoverable once the rows are gone. The watermark keeps the true time, so expiry resumes as
    /// soon as the clock catches up.
    private func effectiveNowMilliseconds() throws -> TimeReading {
        let wall = RetentionTimestamp.milliseconds(clock.now)
        let stored = try database.read { database in
            try RuntimeMetadata.read(database, key: Self.clockHighWaterKey).flatMap(Int64.init)
        }
        if let stored, wall < stored {
            return TimeReading(milliseconds: stored, rewound: true)
        }
        try database.write { database in
            try RuntimeMetadata.write(
                database,
                value: "\(wall)",
                forKey: Self.clockHighWaterKey
            )
        }
        return TimeReading(milliseconds: wall, rewound: false)
    }

    // MARK: - Asset byte helpers

    private func committedAssetBytes(in database: Database) throws -> Int64 {
        try Int64.fetchOne(
            database,
            sql: "SELECT COALESCE(SUM(byte_count), 0) FROM asset_version WHERE durability_state = 'committed'"
        ) ?? 0
    }

    /// The versions this run may release, newest pressure first, marked as removed before the media
    /// side is asked to delete the files: a class that named them without marking them would let the
    /// next class in the same run name them again.
    private func takeUnreleasedAssets(
        storageClass: String,
        policy: RetentionPolicy,
        context: ClassContext
    ) throws -> [MediaAssetKey] {
        return try database.write { database -> [MediaAssetKey] in
            let protection = try roots.roots(in: database)
            let rows = try Row.fetchAll(database, sql: """
                SELECT a.asset_version_id, a.content_digest, a.recipe_version, a.byte_count
                FROM asset_version a
                WHERE a.durability_state = 'committed'
                  AND a.storage_class = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM published_asset_ref r WHERE r.asset_version_id = a.asset_version_id
                  )
                  AND a.asset_version_id NOT IN (
                    SELECT asset_version_id FROM media_preparation
                    WHERE asset_version_id IS NOT NULL
                  )
                ORDER BY a.created_at_ms, a.asset_version_id
                """, arguments: [storageClass])
            let ids = Self.underByteBudget(
                rows.map { (id: $0["asset_version_id"] as Int64, bytes: $0["byte_count"] as Int64) },
                maxBytes: policy.maxBytes,
                totalBytes: try committedAssetBytes(in: database)
            ).filter { !protection.protectedAssetVersions.contains($0) }
            return try Self.markBytesRemoved(rows.filter { ids.contains($0["asset_version_id"] as Int64) }, in: database)
        }
    }

    /// Marks the named rows as released and returns the identities the media side must delete.
    private static func markBytesRemoved(_ rows: [Row], in database: Database) throws -> [MediaAssetKey] {
        var keys: [MediaAssetKey] = []
        for row in rows {
            let id: Int64 = row["asset_version_id"]
            try database.execute(sql: """
                UPDATE asset_version SET durability_state = 'bytes_removed'
                WHERE asset_version_id = ? AND durability_state = 'committed'
                """, arguments: [id])
            keys.append(MediaAssetKey(
                contentDigestHex: row["content_digest"],
                recipeVersion: row["recipe_version"]
            ))
        }
        return keys
    }

    /// The oldest versions whose bytes bring the total under `maxBytes`. No limit declared means
    /// every candidate is eligible: the age of the class is then the only bound, and the run reports
    /// what it took.
    private static func underByteBudget(
        _ candidates: [(id: Int64, bytes: Int64)],
        maxBytes: Int64?,
        totalBytes: Int64
    ) -> [Int64] {
        guard let maxBytes else { return candidates.map(\.id) }
        var held = totalBytes
        var selected: [Int64] = []
        for candidate in candidates {
            guard held > maxBytes else { break }
            held -= candidate.bytes
            selected.append(candidate.id)
        }
        return selected
    }
}

/// Timestamps as this database stores them: epoch milliseconds on every row.
enum RetentionTimestamp {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
