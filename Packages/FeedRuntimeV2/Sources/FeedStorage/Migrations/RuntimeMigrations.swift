import Foundation
import GRDB

/// Schema authority for the runtime database.
///
/// Migrations are append-only: a shipped migration is never rewritten, because rewriting one
/// leaves databases in the field at a schema the new code no longer describes (ADR-004 D11).
/// `PR-03` adds the identity, acquisition and canonical groups plus the `selection_supply`
/// projection; publication, media and session tables belong to later PRs (plan §6).
public enum RuntimeMigrations {
    /// Migrations owned by this package. Later PRs append here; they never rewrite old ones.
    public static var current: DatabaseMigrator { migrator(through: nil) }

    /// The identifiers this build knows how to apply, in order.
    ///
    /// A database whose `grdb_migrations` names one of these that this build does not have is a
    /// database from a *newer* build: the migration was applied by code this build does not contain.
    /// ADR-004 D9 makes that a controlled failure, and detecting it needs the known set, not the
    /// applied set.
    public static var knownMigrationIdentifiers: [String] { steps.map(\.identifier) }

    /// The migration set a shipped build applied, ending at `identifier` inclusive.
    ///
    /// PR-16's upgrade rehearsal needs the schema *as it was in the field*, not as it is today: a
    /// database written by the supported release must migrate forward without losing a row, and the
    /// only honest fixture for that is the shipped set itself. Later slices keep appending to
    /// `steps`; this accessor keeps naming a historical set instead of a copy of it, so the fixture
    /// cannot drift away from the migrations that were actually shipped.
    ///
    /// - Precondition: `identifier` names a registered step. An unknown identifier is a programming
    ///   error in a test fixture, not a schema decision.
    public static func through(_ identifier: String) -> DatabaseMigrator {
        precondition(
            steps.contains { $0.identifier == identifier },
            "unknown migration identifier '\(identifier)'"
        )
        return migrator(through: identifier)
    }

    private static func migrator(through last: String?) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for step in steps {
            migrator.registerMigration(step.identifier, migrate: step.migrate)
            if step.identifier == last { break }
        }
        return migrator
    }

    private struct MigrationStep: Sendable {
        let identifier: String
        let migrate: @Sendable (Database) throws -> Void
    }

    /// Every migration in shipping order. `current` registers all of them; `through(_:)` stops early.
    private static let steps: [MigrationStep] = [
        MigrationStep(identifier: "v1_runtime_metadata") { database in
            try database.execute(sql: """
                CREATE TABLE runtime_metadata (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """)
        },

        MigrationStep(identifier: "v2_runtime_schema") { database in
            try database.execute(sql: Self.runtimeSchema)
            try RuntimeMetadata.write(
                database,
                value: RuntimeMetadata.schemaName,
                forKey: RuntimeMetadata.schemaNameKey
            )
        },

        // PR-04: the runtime's own projection of durable user state, with its own watermark.
        // It is deliberately not a copy of `user.sqlite`: only what the runtime must know, plus the
        // revision that lets a reader detect what changed between two projections (plan §6).
        MigrationStep(identifier: "v3_user_state_projection") { database in
            try database.execute(sql: """
                CREATE TABLE user_state_projection (
                    kind TEXT NOT NULL,
                    subject_id TEXT NOT NULL,
                    wanted INTEGER NOT NULL CHECK (wanted IN (0, 1)),
                    last_operation_id TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK (revision > 0),
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (kind, subject_id)
                )
                """)
            try database.execute(sql: """
                CREATE TABLE user_state_watermark (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    revision INTEGER NOT NULL CHECK (revision >= 0),
                    updated_at REAL
                )
                """)
            try database.execute(sql: """
                INSERT INTO user_state_watermark (id, revision, updated_at) VALUES (1, 0, NULL)
                """)
        },

        // PR-06: the publication aggregate plus the minimal local media commit (ADR-001).
        // It is appended, never folded into `v2_runtime_schema`: a database already in the field has
        // v2 applied, and rewriting an applied migration would leave it at a schema this code no
        // longer describes (ADR-004 D11).
        MigrationStep(identifier: "v4_publication_schema") { database in
            try database.execute(sql: Self.publicationSchema)
        },

        // PR-07: session cursor and exposure history (plan §6, ADR-002 D8, ADR-007 D7/D10/D12).
        // Appended for the same reason as v4: a database in the field already has the earlier
        // migrations applied, and rewriting one leaves it at a schema this code no longer describes.
        MigrationStep(identifier: "v5_session_and_exposure") { database in
            try database.execute(sql: Self.sessionSchema)
        },

        // PR-16: retention policy and the durable account of each GC run (ADR-004 D8, plan §10).
        //
        // Appended for the same reason as v4 and v5. Two facts are structural:
        //
        // * `retention_policy` is keyed by the class names of ADR-004's D8 table, and an *absent* row
        //   means "this class has no declared limit" — which the coordinator reports as skipped rather
        //   than reading as unlimited. `durable_user_state` can never be given a row: D8 marks the
        //   user's own rows as never quota-evicted, and a knob for them would be the bug it forbids;
        // * `gc_run` is the record that a run happened, and `gc_run_class` is its per-class result.
        //   An in-memory report cannot answer "did GC run, when, in which mode, and what did it take"
        //   after a relaunch, and D8 requires GC state to be durable.
        MigrationStep(identifier: "v6_retention_schema") { database in
            try database.execute(sql: Self.retentionSchema)
        },

        // The reader's own list membership, projected for the selection (2026-09-18, baseline §8.58).
        //
        // `user_state_projection` is one row per subject and carries no list, because a subject's
        // *wanted* state is not per list: one bookmark can sit in the default list and in two boxes at
        // once. A box's content is that list's membership — `bookmark_item(list_id, item_id)` in the
        // authority — so a selection restricted to one box needs the same relation here. Appended for
        // the same reason as v4-v6: a database in the field already has the earlier migrations applied,
        // and rewriting one leaves it at a schema this code no longer describes (ADR-004 D11).
        MigrationStep(identifier: "v7_user_list_membership") { database in
            try database.execute(sql: """
                CREATE TABLE user_list_membership (
                    list_key          TEXT    NOT NULL CHECK (length(list_key) > 0),
                    subject_id        TEXT    NOT NULL CHECK (length(subject_id) > 0),
                    wanted            INTEGER NOT NULL CHECK (wanted IN (0, 1)),
                    last_operation_id TEXT    NOT NULL,
                    revision          INTEGER NOT NULL CHECK (revision > 0),
                    updated_at        REAL    NOT NULL,
                    PRIMARY KEY (list_key, subject_id)
                )
                """)
        },
    ]

    // MARK: - v2: identity, acquisition, canonical and the selection projection

    /// Every statement of `v2_runtime_schema`, in dependency order.
    ///
    /// Local row identifiers are positive `Int64` with `CHECK (id > 0)`, so `0` stays the reserved
    /// "none" value (ADR-003 D3). External keys are stored as full bytes with a non-unique digest
    /// index beside them: the digest prunes a lookup and never decides identity (ADR-003 D8).
    private static let runtimeSchema = """
        -- MARK: - Acquisition group (ADR-006)
        -- The target is operational work, not editorial identity (ADR-003 D7). Its id is the opaque
        -- text `AcquisitionTargetID`, so it is deliberately not a local row identifier.
        CREATE TABLE acquisition_target (
            id                 TEXT    PRIMARY KEY,
            connector_kind     TEXT    NOT NULL,
            generation         INTEGER NOT NULL DEFAULT 1 CHECK (generation > 0),
            binding_revision   INTEGER NOT NULL CHECK (binding_revision > 0),
            lease_epoch        INTEGER NOT NULL DEFAULT 0 CHECK (lease_epoch >= 0),
            state              TEXT    NOT NULL CHECK (state IN ('active','disabled','revoked')),
            configuration_blob BLOB,
            last_success_at    INTEGER,
            last_attempt_at    INTEGER,
            failure_class      TEXT,
            CHECK (length(id) > 0)
        );

        -- One row per target: the CAS predicate of ADR-006 D5 reads and writes only here.
        CREATE TABLE connector_checkpoint (
            target_id            TEXT    PRIMARY KEY REFERENCES acquisition_target(id),
            checkpoint_revision  INTEGER NOT NULL DEFAULT 0 CHECK (checkpoint_revision >= 0),
            checkpoint_blob      BLOB,
            serialization_schema INTEGER NOT NULL CHECK (serialization_schema > 0),
            connector_version    TEXT    NOT NULL CHECK (length(connector_version) > 0),
            updated_at           INTEGER NOT NULL
        );

        -- One row per admitted batch: a replay is answered from here, never from memory (D2).
        CREATE TABLE admission_batch (
            batch_id            TEXT    PRIMARY KEY,
            target_id           TEXT    NOT NULL REFERENCES acquisition_target(id),
            target_generation   INTEGER NOT NULL CHECK (target_generation > 0),
            binding_revision    INTEGER NOT NULL CHECK (binding_revision > 0),
            lease_epoch         INTEGER NOT NULL CHECK (lease_epoch >= 0),
            fingerprint         TEXT    NOT NULL CHECK (length(fingerprint) = 64),
            checkpoint_expected INTEGER NOT NULL CHECK (checkpoint_expected >= 0),
            checkpoint_written  INTEGER CHECK (checkpoint_written IS NULL OR checkpoint_written >= 0),
            observation_count   INTEGER NOT NULL CHECK (observation_count >= 0),
            result              TEXT    NOT NULL CHECK (result IN (
                                    'admitted','replayed','duplicate','staleTarget','staleCheckpoint',
                                    'batchConflict','identityConflict','invalidObservation')),
            receipt_blob        BLOB    NOT NULL,
            committed_at        INTEGER NOT NULL,
            CHECK (length(batch_id) > 0)
        );
        CREATE INDEX idx_admission_batch_target ON admission_batch (target_id, committed_at);

        -- Opaque connector payload, kept for audit and identity proof (plan §7).
        CREATE TABLE connector_evidence (
            id         INTEGER PRIMARY KEY CHECK (id > 0),
            batch_id   TEXT    NOT NULL REFERENCES admission_batch(batch_id),
            kind       TEXT    NOT NULL,
            digest     TEXT    NOT NULL CHECK (length(digest) > 0),
            bytes      BLOB,
            created_at INTEGER NOT NULL,
            UNIQUE (batch_id, digest)
        );

        -- MARK: - Identity group (ADR-003 D1-D8, D18)
        CREATE TABLE source (
            id                       INTEGER PRIMARY KEY CHECK (id > 0),
            editorial_key            TEXT    NOT NULL,
            canonicalization_version INTEGER NOT NULL CHECK (canonicalization_version > 0),
            display_title            TEXT    NOT NULL,
            kind                     TEXT,
            created_at               INTEGER NOT NULL,
            CHECK (length(editorial_key) > 0),
            UNIQUE (editorial_key, canonicalization_version)
        );

        CREATE TABLE provider (
            id                  INTEGER PRIMARY KEY CHECK (id > 0),
            connector_namespace TEXT    NOT NULL CHECK (length(connector_namespace) > 0),
            provider_key        TEXT    NOT NULL CHECK (length(provider_key) > 0),
            display_name        TEXT    NOT NULL,
            created_at          INTEGER NOT NULL,
            UNIQUE (connector_namespace, provider_key)
        );

        CREATE TABLE source_binding_runtime (
            id                  INTEGER PRIMARY KEY CHECK (id > 0),
            source_id           INTEGER NOT NULL REFERENCES source(id),
            connector_namespace TEXT    NOT NULL,
            binding_key         TEXT    NOT NULL,
            generation          INTEGER NOT NULL DEFAULT 1 CHECK (generation >= 1),
            enabled             INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
            config_json         TEXT    NOT NULL DEFAULT '{}',
            created_at          INTEGER NOT NULL,
            updated_at          INTEGER NOT NULL,
            CHECK (length(connector_namespace) > 0),
            CHECK (length(binding_key) > 0),
            UNIQUE (connector_namespace, binding_key)
        );
        CREATE INDEX idx_source_binding_source ON source_binding_runtime (source_id, enabled);

        -- The logical external object and its immutable representations. The two tables reference
        -- each other, so the record is created after the identity row and the identity row is
        -- backfilled inside the admitting transaction (ADR-003 schema note).
        CREATE TABLE origin_record (
            id                  INTEGER PRIMARY KEY CHECK (id > 0),
            connector_namespace TEXT    NOT NULL,
            scope_key           TEXT    NOT NULL,
            primary_identity_id INTEGER NOT NULL REFERENCES external_identity(id),
            availability        TEXT    NOT NULL DEFAULT 'available' CHECK (availability IN (
                                    'available','updated','removed','revoked','unknown')),
            current_revision_id INTEGER,
            first_observed_at   INTEGER NOT NULL,
            last_observed_at    INTEGER NOT NULL,
            CHECK (last_observed_at >= first_observed_at),
            -- The current pointer can only name a revision of this very record.
            FOREIGN KEY (id, current_revision_id) REFERENCES origin_revision(origin_record_id, id)
        );

        -- Payload columns are immutable after insert (ADR-004 D5, I-06): a semantically different
        -- value exists only as a new revision. The trigger is installed below.
        CREATE TABLE origin_revision (
            id                     INTEGER PRIMARY KEY CHECK (id > 0),
            origin_record_id       INTEGER NOT NULL REFERENCES origin_record(id),
            external_version_key   BLOB,
            payload_digest         BLOB    NOT NULL CHECK (length(payload_digest) > 0),
            headline               TEXT,
            summary                TEXT,
            body_text              TEXT,
            authored_at            INTEGER,
            modified_at            INTEGER,
            observed_at            INTEGER NOT NULL,
            primary_link           TEXT,
            search_projection      TEXT,
            identity_confidence    TEXT    NOT NULL DEFAULT 'high' CHECK (identity_confidence IN ('high','low')),
            fallback_scheme_version INTEGER CHECK (
                                    fallback_scheme_version IS NULL OR fallback_scheme_version > 0),
            created_at             INTEGER NOT NULL,
            CHECK (identity_confidence <> 'low' OR fallback_scheme_version IS NOT NULL),
            -- Parent key of every composite reference to a revision of one specific record.
            UNIQUE (origin_record_id, id)
        );
        CREATE INDEX idx_origin_revision_record ON origin_revision (origin_record_id, created_at, id);
        -- Non-unique on purpose: a divergent payload under an already-used version key must be
        -- *detected* (ADR-003 D11), and a UNIQUE rule here would abort instead of recording.
        CREATE INDEX idx_origin_revision_version ON origin_revision (origin_record_id, external_version_key);

        -- One row per opaque key. Uniqueness is over the namespace, the scope, the key kind and the
        -- full key bytes; the digest index beside it is auxiliary and never decides identity (D8).
        CREATE TABLE external_identity (
            id                     INTEGER PRIMARY KEY CHECK (id > 0),
            connector_namespace    TEXT    NOT NULL,
            scope_key              TEXT    NOT NULL,
            key_kind               TEXT    NOT NULL CHECK (key_kind IN ('object','version')),
            external_key           BLOB    NOT NULL CHECK (length(external_key) > 0),
            key_digest             BLOB    NOT NULL,
            origin_record_id       INTEGER REFERENCES origin_record(id),
            identity_confidence    TEXT    NOT NULL DEFAULT 'high' CHECK (identity_confidence IN ('high','low')),
            fallback_scheme_version INTEGER CHECK (
                                    fallback_scheme_version IS NULL OR fallback_scheme_version > 0),
            first_observed_at      INTEGER NOT NULL,
            last_observed_at       INTEGER NOT NULL,
            CHECK (last_observed_at >= first_observed_at),
            CHECK (identity_confidence <> 'low' OR fallback_scheme_version IS NOT NULL),
            UNIQUE (connector_namespace, scope_key, key_kind, external_key)
        );
        CREATE INDEX idx_external_identity_digest
            ON external_identity (connector_namespace, scope_key, key_kind, key_digest);

        -- Divergence and ambiguity are recorded, never resolved by overwrite (D11, D12).
        CREATE TABLE identity_conflict (
            id                       INTEGER PRIMARY KEY CHECK (id > 0),
            connector_namespace      TEXT    NOT NULL,
            scope_key                TEXT    NOT NULL,
            conflict_kind            TEXT    NOT NULL CHECK (conflict_kind IN (
                                        'version_payload_divergence','ambiguous_alias','digest_collision',
                                        'key_kind_mismatch','legacy_map_conflict')),
            existing_origin_record_id INTEGER REFERENCES origin_record(id),
            existing_identity_id     INTEGER REFERENCES external_identity(id),
            incoming_external_key    BLOB    NOT NULL CHECK (length(incoming_external_key) > 0),
            incoming_key_digest      BLOB    NOT NULL,
            detail_json              TEXT    NOT NULL DEFAULT '{}',
            detected_at              INTEGER NOT NULL,
            resolved_at              INTEGER,
            CHECK (resolved_at IS NULL OR resolved_at >= detected_at)
        );
        CREATE INDEX idx_identity_conflict_key
            ON identity_conflict (connector_namespace, scope_key, conflict_kind, detected_at);

        -- MARK: - Canonical group (plan §6): memberships, attributions, relations, media, offers
        CREATE TABLE source_membership (
            origin_record_id         INTEGER NOT NULL REFERENCES origin_record(id),
            source_id                INTEGER NOT NULL REFERENCES source(id),
            membership_kind          TEXT    NOT NULL CHECK (length(membership_kind) > 0),
            evidence_target_id       TEXT    REFERENCES acquisition_target(id),
            evidence_binding_namespace TEXT,
            evidence_binding_key     TEXT,
            evidence_binding_generation INTEGER CHECK (
                                        evidence_binding_generation IS NULL OR evidence_binding_generation >= 1),
            first_observed_at        INTEGER NOT NULL,
            last_observed_at         INTEGER NOT NULL,
            CHECK (last_observed_at >= first_observed_at),
            PRIMARY KEY (origin_record_id, source_id, membership_kind)
        );

        CREATE TABLE provider_attribution (
            id                 INTEGER PRIMARY KEY CHECK (id > 0),
            origin_revision_id INTEGER NOT NULL REFERENCES origin_revision(id),
            provider_id        INTEGER NOT NULL REFERENCES provider(id),
            attribution_role   TEXT    NOT NULL CHECK (attribution_role IN ('primary','publisher','contributor')),
            evidence_key       TEXT,
            created_at         INTEGER NOT NULL,
            UNIQUE (origin_revision_id, provider_id, attribution_role)
        );

        -- Only the four promoted relations are canonical; the object may be an identity the runtime
        -- knows or a record it resolved, never an invented one (ADR-003 D14).
        CREATE TABLE content_relation (
            id                         INTEGER PRIMARY KEY CHECK (id > 0),
            subject_origin_record_id   INTEGER NOT NULL REFERENCES origin_record(id),
            relation                   TEXT    NOT NULL CHECK (relation IN ('replyTo','repostOf','quoteOf','references')),
            object_external_identity_id INTEGER REFERENCES external_identity(id),
            object_origin_record_id    INTEGER REFERENCES origin_record(id),
            created_at                 INTEGER NOT NULL,
            CHECK (object_external_identity_id IS NOT NULL OR object_origin_record_id IS NOT NULL),
            UNIQUE (subject_origin_record_id, relation, object_external_identity_id),
            UNIQUE (subject_origin_record_id, relation, object_origin_record_id)
        );

        CREATE TABLE media_candidate (
            id                 INTEGER PRIMARY KEY CHECK (id > 0),
            origin_record_id   INTEGER NOT NULL,
            origin_revision_id INTEGER NOT NULL,
            role               TEXT    NOT NULL CHECK (role IN ('image','thumbnail','poster','audio','video','waveform')),
            resource_url       TEXT    NOT NULL CHECK (length(resource_url) > 0),
            media_type_hint    TEXT,
            pixel_width        INTEGER CHECK (pixel_width IS NULL OR pixel_width > 0),
            pixel_height       INTEGER CHECK (pixel_height IS NULL OR pixel_height > 0),
            position           INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
            created_at         INTEGER NOT NULL,
            UNIQUE (origin_revision_id, role, position),
            -- A candidate can only belong to the record whose revision it names.
            FOREIGN KEY (origin_record_id, origin_revision_id) REFERENCES origin_revision(origin_record_id, id)
        );

        CREATE TABLE interaction_offer (
            id                 INTEGER PRIMARY KEY CHECK (id > 0),
            origin_record_id   INTEGER NOT NULL,
            origin_revision_id INTEGER NOT NULL,
            offer_kind         TEXT    NOT NULL CHECK (length(offer_kind) > 0),
            handle             TEXT,
            position           INTEGER NOT NULL DEFAULT 0 CHECK (position >= 0),
            created_at         INTEGER NOT NULL,
            UNIQUE (origin_revision_id, offer_kind, position),
            FOREIGN KEY (origin_record_id, origin_revision_id) REFERENCES origin_revision(origin_record_id, id)
        );

        -- MARK: - Legacy bridges (ADR-003 D18)
        CREATE TABLE legacy_source_map (
            catalog_source_key       TEXT    NOT NULL CHECK (length(catalog_source_key) > 0),
            catalog_source_id        INTEGER NOT NULL CHECK (catalog_source_id > 0),
            canonicalization_version INTEGER NOT NULL CHECK (canonicalization_version > 0),
            runtime_source_id        INTEGER NOT NULL REFERENCES source(id),
            legacy_url               TEXT    NOT NULL,
            mapped_at                INTEGER NOT NULL,
            PRIMARY KEY (catalog_source_key, canonicalization_version)
        );
        CREATE INDEX idx_legacy_source_map_id ON legacy_source_map (catalog_source_id, canonicalization_version);

        CREATE TABLE legacy_item_map (
            legacy_item_id    TEXT    PRIMARY KEY CHECK (length(legacy_item_id) > 0),
            legacy_source_url TEXT    NOT NULL,
            origin_record_id  INTEGER REFERENCES origin_record(id),
            origin_revision_id INTEGER REFERENCES origin_revision(id),
            confidence        TEXT    NOT NULL CHECK (confidence IN ('high','low','unresolved')),
            mapped_at         INTEGER NOT NULL
        );

        -- MARK: - Projections (plan §6): one supply row per selectable record, one monotone counter
        CREATE TABLE supply_generation (
            id    INTEGER PRIMARY KEY CHECK (id = 1),
            value INTEGER NOT NULL DEFAULT 0 CHECK (value >= 0)
        );
        INSERT INTO supply_generation (id, value) VALUES (1, 0);

        CREATE TABLE selection_supply (
            origin_record_id   INTEGER PRIMARY KEY REFERENCES origin_record(id),
            origin_revision_id INTEGER NOT NULL,
            source_id          INTEGER REFERENCES source(id),
            observed_at        INTEGER NOT NULL,
            published_at_claim INTEGER,
            eligibility_blob   BLOB,
            -- Supply always names the current revision of its own record, in one snapshot.
            FOREIGN KEY (origin_record_id, origin_revision_id) REFERENCES origin_revision(origin_record_id, id)
        );

        -- Reconstructible search projection over the current revision of each record.
        CREATE VIRTUAL TABLE origin_search USING fts5(projection);

        -- MARK: - Append-only guard (ADR-004 D5, ADR-006 invariant 4, I-06)
        CREATE TRIGGER trg_origin_revision_append_only
        BEFORE UPDATE ON origin_revision
        BEGIN
            SELECT RAISE(ABORT, 'origin_revision payload is append-only');
        END;
        """

    // MARK: - v4: the publication aggregate (ADR-001)

    /// The published log and the minimal local media commit, exactly as ADR-001 fixes them.
    ///
    /// Three facts are structural, not conventional:
    ///
    /// * the only `ON DELETE CASCADE` edge in the aggregate is `published_asset_ref → published_card`
    ///   (a card and its references are one purge unit). There is deliberately **no foreign key at all**
    ///   from `published_card` to `origin_record`/`origin_revision`, so canonical eviction or an
    ///   authorized purge cannot cascade into published history (INV-6, ADR-004 invariant 3);
    /// * a card can only point at a segment of its *own* edition: the composite foreign key needs the
    ///   `(edition_id, segment_id)` parent key, which is why that unique index exists;
    /// * the two `UNIQUE` constraints per edition (`absolute_ordinal` and `publication_card_id`) are the
    ///   guarantee that survives two coordinator instances or a crash-restarted one, where the
    ///   coordinator's single-flight map does not (ADR-006 D14, INV-5).
    private static let publicationSchema = """
        -- One immutable composition for one context. Append-only: rows are inserted, and the only
        -- updates any code performs are this row's tail/version/state/activation columns.
        CREATE TABLE feed_edition (
            edition_id                 INTEGER PRIMARY KEY CHECK (edition_id > 0),
            context_key                TEXT    NOT NULL CHECK (length(context_key) > 0),
            editorial_revision         TEXT    NOT NULL CHECK (length(editorial_revision) = 64),
            publication_schema_version INTEGER NOT NULL CHECK (publication_schema_version > 0),
            epoch                      INTEGER NOT NULL CHECK (epoch > 0),
            seed                       BLOB    NOT NULL CHECK (length(seed) > 0),
            state                      TEXT    NOT NULL CHECK (state IN ('draft','active','superseded','purged')),
            successor_of_edition_id    INTEGER REFERENCES feed_edition(edition_id),
            tail_segment_ordinal       INTEGER NOT NULL DEFAULT -1 CHECK (tail_segment_ordinal >= -1),
            tail_absolute_ordinal      INTEGER NOT NULL DEFAULT -1 CHECK (tail_absolute_ordinal >= -1),
            version                    INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
            created_at_ms              INTEGER NOT NULL,
            activated_at_ms            INTEGER,
            CHECK (activated_at_ms IS NULL OR activated_at_ms >= created_at_ms),
            CHECK (state <> 'active' OR activated_at_ms IS NOT NULL)
        );

        -- The active-edition pointer per context. The swap is a single UPDATE of `state`; SQLite
        -- refuses a second active edition for the same context, so a refresh storm cannot leave two
        -- visible editions (ADR-001 D7, INV-14).
        CREATE UNIQUE INDEX idx_feed_edition_active
            ON feed_edition (context_key) WHERE state = 'active';

        -- An immutable slice of an edition, in editorial order.
        CREATE TABLE feed_segment (
            segment_id             INTEGER PRIMARY KEY CHECK (segment_id > 0),
            edition_id             INTEGER NOT NULL REFERENCES feed_edition(edition_id),
            segment_ordinal        INTEGER NOT NULL CHECK (segment_ordinal >= 0),
            absolute_ordinal_start INTEGER NOT NULL CHECK (absolute_ordinal_start >= 0),
            absolute_ordinal_end   INTEGER NOT NULL CHECK (absolute_ordinal_end >= absolute_ordinal_start),
            policy_revision        TEXT    NOT NULL CHECK (length(policy_revision) = 64),
            seed                   BLOB    NOT NULL CHECK (length(seed) > 0),
            committed_at_ms        INTEGER NOT NULL,
            UNIQUE (edition_id, segment_ordinal)
        );

        -- Required parent key of the composite foreign key below: a card cannot point at another
        -- edition's segment.
        CREATE UNIQUE INDEX idx_feed_segment_edition_segment
            ON feed_segment (edition_id, segment_id);

        -- The frozen payload. Every column a renderer needs, plus the copied canonical identity that is
        -- deliberately *not* a foreign key (plan §6, INV-2).
        CREATE TABLE published_card (
            publication_card_id        INTEGER PRIMARY KEY CHECK (publication_card_id > 0),
            edition_id                 INTEGER NOT NULL,
            segment_id                 INTEGER NOT NULL,
            absolute_ordinal           INTEGER NOT NULL CHECK (absolute_ordinal >= 0),
            origin_record_id           INTEGER NOT NULL CHECK (origin_record_id > 0),
            origin_revision_id         INTEGER NOT NULL CHECK (origin_revision_id > 0),
            source_id                  INTEGER,
            provider_id                INTEGER,
            source_display_name        TEXT,
            provider_display_name      TEXT,
            title                      TEXT,
            primary_text               TEXT,
            published_at_ms            INTEGER,
            published_at_kind          TEXT    NOT NULL CHECK (published_at_kind IN
                                           ('authored','modified','observed','none')),
            observation_at_ms          INTEGER NOT NULL,
            primary_action_kind        TEXT    CHECK (primary_action_kind IS NULL OR primary_action_kind IN
                                           ('externalURL','localContentDetail','mediaPlayback','thread','connectorAction')),
            primary_action_reference   TEXT,
            interaction_summary        TEXT,
            render_contract_version    INTEGER NOT NULL CHECK (render_contract_version > 0),
            render_kind                TEXT    NOT NULL CHECK (render_kind IN ('hero','thumb','textOnly')),
            render_media_slot          TEXT    NOT NULL CHECK (render_media_slot IN
                                           ('none','primary','poster','thumbnail','waveform')),
            render_aspect_ratio        REAL,
            payload_digest             TEXT    NOT NULL CHECK (length(payload_digest) = 64),
            publication_schema_version INTEGER NOT NULL CHECK (publication_schema_version > 0),
            UNIQUE (edition_id, absolute_ordinal),
            UNIQUE (edition_id, publication_card_id),
            -- A date is either declared (and its kind says which date it is) or absent: no column is
            -- ever filled with a date the revision did not declare (ADR-003 D17, Blueprint §35).
            CHECK (published_at_ms IS NULL OR published_at_kind <> 'none'),
            CHECK (published_at_ms IS NOT NULL OR published_at_kind = 'none'),
            CHECK ((primary_action_kind IS NULL) = (primary_action_reference IS NULL)),
            FOREIGN KEY (edition_id, segment_id)
                REFERENCES feed_segment (edition_id, segment_id)
                ON DELETE RESTRICT
        );
        CREATE INDEX idx_published_card_window ON published_card (edition_id, absolute_ordinal);

        -- One immutable asset version: identity is (content_digest, recipe_version). No URL appears as
        -- identity, as a cache key or as a revalidation input anywhere (INV-8).
        CREATE TABLE asset_version (
            asset_version_id INTEGER PRIMARY KEY CHECK (asset_version_id > 0),
            content_digest   TEXT    NOT NULL CHECK (length(content_digest) = 64),
            byte_count       INTEGER NOT NULL CHECK (byte_count > 0),
            mime_type        TEXT    NOT NULL CHECK (length(mime_type) > 0),
            pixel_width      INTEGER CHECK (pixel_width IS NULL OR pixel_width > 0),
            pixel_height     INTEGER CHECK (pixel_height IS NULL OR pixel_height > 0),
            recipe_version   INTEGER NOT NULL CHECK (recipe_version > 0),
            storage_class    TEXT    NOT NULL CHECK (storage_class IN ('published','cached')),
            relative_path    TEXT,
            durability_state TEXT    NOT NULL CHECK (durability_state IN ('committed','bytes_removed','missing')),
            created_at_ms    INTEGER NOT NULL,
            UNIQUE (content_digest, recipe_version),
            CHECK (durability_state <> 'committed' OR relative_path IS NOT NULL)
        );

        -- A card and its references are one purge unit; the bytes themselves are shared and pinned.
        CREATE TABLE published_asset_ref (
            publication_card_id INTEGER NOT NULL
                REFERENCES published_card(publication_card_id) ON DELETE CASCADE,
            slot                TEXT    NOT NULL CHECK (slot IN
                                    ('primary','alternate','poster','thumbnail','waveform')),
            asset_version_id    INTEGER NOT NULL
                REFERENCES asset_version(asset_version_id) ON DELETE RESTRICT,
            role                TEXT    NOT NULL CHECK (role IN
                                    ('image','thumbnail','poster','audio','video','waveform')),
            render_slot         TEXT    NOT NULL CHECK (render_slot IN
                                    ('none','primary','poster','thumbnail','waveform')),
            aspect_ratio        REAL,
            PRIMARY KEY (publication_card_id, slot, asset_version_id)
        );
        CREATE INDEX idx_published_asset_ref_asset
            ON published_asset_ref (asset_version_id, publication_card_id);

        -- What preparation decided for one candidate. The reference is *logical*: canonical supply is
        -- evictable, so this table may not carry a foreign key to it.
        CREATE TABLE media_preparation (
            media_preparation_id INTEGER PRIMARY KEY CHECK (media_preparation_id > 0),
            origin_revision_id   INTEGER NOT NULL CHECK (origin_revision_id > 0),
            candidate_key        TEXT    NOT NULL CHECK (length(candidate_key) > 0),
            role                 TEXT    NOT NULL CHECK (role IN
                                    ('image','thumbnail','poster','audio','video','waveform')),
            state                TEXT    NOT NULL CHECK (state IN
                                    ('pending','in_flight','prepared','placeholder','failed','no_media')),
            asset_version_id     INTEGER REFERENCES asset_version(asset_version_id) ON DELETE RESTRICT,
            placeholder_recipe   TEXT,
            decision_revision    INTEGER NOT NULL,
            updated_at_ms        INTEGER NOT NULL,
            UNIQUE (origin_revision_id, candidate_key, role),
            CHECK (state <> 'prepared' OR asset_version_id IS NOT NULL)
        );
        """

    // MARK: - v5: session cursor and exposure history (ADR-002 D8, ADR-007)

    /// The cursor and the exposure log, appended by PR-07.
    ///
    /// Four decisions are structural here rather than conventional:
    ///
    /// * `session_checkpoint` names a *card of its own edition* through the composite foreign key, so a
    ///   cursor can never point at another edition's ordinal;
    /// * `exposure_fact` is keyed by `fact_key` with a `UNIQUE` index, which is the whole idempotency
    ///   rule of ADR-007 D7: a replayed flush conflicts and writes nothing;
    /// * `history_projection` has deliberately **no** foreign key to `published_card`: it is the
    ///   retention root that policy reads, and ADR-007 D10 forbids pruning it with the fact log;
    /// * every fact carries the `policy_version` that produced it, so tuning a threshold never rewrites
    ///   the meaning of a recorded fact.
    private static let sessionSchema = """
        -- The cursor of one surface: context, edition, card, ordinal and offset (ADR-002 D8).
        CREATE TABLE session_checkpoint (
            context_key                 TEXT    PRIMARY KEY CHECK (length(context_key) > 0),
            edition_id                  INTEGER NOT NULL REFERENCES feed_edition(edition_id)
                                            ON DELETE RESTRICT,
            publication_card_id         INTEGER NOT NULL,
            absolute_ordinal            INTEGER NOT NULL CHECK (absolute_ordinal >= 0),
            anchor_offset_fraction      REAL    NOT NULL
                                            CHECK (anchor_offset_fraction >= -1.0
                                                AND anchor_offset_fraction <= 1.0),
            render_environment_revision TEXT    NOT NULL
                                            CHECK (length(render_environment_revision) > 0),
            policy_version              TEXT    NOT NULL CHECK (length(policy_version) > 0),
            updated_at_ms               INTEGER NOT NULL CHECK (updated_at_ms >= 0),
            -- A cursor names a published card of the edition it points at, never a bare ordinal.
            FOREIGN KEY (edition_id, publication_card_id)
                REFERENCES published_card (edition_id, publication_card_id)
                ON DELETE RESTRICT
        );

        -- The versioned knobs. Changing one creates a row; no historical fact is ever reinterpreted.
        CREATE TABLE exposure_policy (
            policy_version       TEXT    PRIMARY KEY CHECK (length(policy_version) > 0),
            min_visible_fraction REAL    NOT NULL
                                     CHECK (min_visible_fraction > 0.0 AND min_visible_fraction <= 1.0),
            min_dwell_ms         INTEGER NOT NULL CHECK (min_dwell_ms >= 0),
            coalesce_window_ms   INTEGER NOT NULL CHECK (coalesce_window_ms BETWEEN 50 AND 100),
            flush_fact_count     INTEGER NOT NULL CHECK (flush_fact_count > 0),
            flush_interval_ms    INTEGER NOT NULL CHECK (flush_interval_ms > 0),
            created_at_ms        INTEGER NOT NULL CHECK (created_at_ms >= 0)
        );

        -- One row per fact. `fact_key` is the idempotency key of ADR-007 D7.
        CREATE TABLE exposure_fact (
            fact_id              INTEGER PRIMARY KEY CHECK (fact_id > 0),
            fact_key             TEXT    NOT NULL CHECK (length(fact_key) > 0),
            edition_id           INTEGER NOT NULL,
            card_id              INTEGER NOT NULL,
            origin_record_id     INTEGER,
            origin_revision_id   INTEGER,
            event_type           TEXT    NOT NULL CHECK (event_type IN (
                                     'viewportEntered','centerCrossed','viewportLeft',
                                     'seen','opened','read','bookmarked','bookmarkRemoved')),
            scope                TEXT    NOT NULL CHECK (scope IN (
                                     'main','source','bookmark','search','collection','smartFeed')),
            scope_ref            TEXT    NOT NULL DEFAULT '',
            visit_ordinal        INTEGER NOT NULL DEFAULT 0 CHECK (visit_ordinal >= 0),
            boot_session_id      TEXT    NOT NULL CHECK (length(boot_session_id) > 0),
            observed_at_ms       INTEGER NOT NULL CHECK (observed_at_ms >= 0),
            wall_clock_ms        INTEGER,
            dwell_ms             INTEGER CHECK (dwell_ms IS NULL OR dwell_ms >= 0),
            max_visible_fraction REAL    CHECK (max_visible_fraction IS NULL
                                     OR (max_visible_fraction >= 0.0 AND max_visible_fraction <= 1.0)),
            direction            INTEGER CHECK (direction IS NULL OR direction IN (-1, 0, 1)),
            close_reason         TEXT    CHECK (close_reason IS NULL OR close_reason IN
                                     ('leftViewport','windowEvicted','background','sessionEnd',
                                      'editionSwap')),
            policy_version       TEXT    NOT NULL REFERENCES exposure_policy(policy_version),
            user_state_op_id     TEXT,
            -- H-01: a seen fact carries observed dwell; nothing infers it later.
            CHECK (event_type <> 'seen' OR dwell_ms IS NOT NULL),
            CHECK (event_type <> 'centerCrossed' OR direction IS NOT NULL),
            CHECK (event_type <> 'viewportLeft' OR close_reason IS NOT NULL),
            -- Interval facts belong to a visit; a durable fact belongs to the edition, not a visit.
            CHECK (event_type IN ('viewportEntered','viewportLeft','centerCrossed','seen')
                OR visit_ordinal = 0),
            CHECK (event_type NOT IN ('read','bookmarked','bookmarkRemoved')
                OR (user_state_op_id IS NOT NULL AND length(user_state_op_id) > 0)),
            -- A fact names a card of the edition it claims: the same composite key as the checkpoint.
            FOREIGN KEY (edition_id, card_id)
                REFERENCES published_card (edition_id, publication_card_id)
                ON DELETE RESTRICT
        );
        CREATE UNIQUE INDEX ux_exposure_fact_key ON exposure_fact (fact_key);
        CREATE INDEX ix_exposure_fact_card ON exposure_fact (card_id, edition_id, event_type);
        CREATE INDEX ix_exposure_fact_scope ON exposure_fact (scope, scope_ref, observed_at_ms);

        -- What policy reads. Rebuildable only additively: no delete path exists for a projection row.
        CREATE TABLE history_projection (
            scope               TEXT    NOT NULL CHECK (length(scope) > 0),
            scope_ref           TEXT    NOT NULL DEFAULT '',
            card_id             INTEGER NOT NULL,
            edition_id          INTEGER,
            first_seen_at_ms    INTEGER,
            last_seen_at_ms     INTEGER,
            opened_at_ms        INTEGER,
            read_at_ms          INTEGER,
            read_cleared_at_ms  INTEGER,
            bookmarked_at_ms    INTEGER,
            center_crossed_at_ms INTEGER,
            visit_count         INTEGER NOT NULL DEFAULT 0 CHECK (visit_count >= 0),
            last_visit_ordinal  INTEGER NOT NULL DEFAULT 0 CHECK (last_visit_ordinal >= 0),
            policy_version      TEXT    NOT NULL,
            user_state_revision INTEGER NOT NULL DEFAULT 0 CHECK (user_state_revision >= 0),
            PRIMARY KEY (scope, scope_ref, card_id)
        );
        CREATE INDEX ix_history_projection_scope ON history_projection (scope, scope_ref, last_seen_at_ms);

        -- The declared policy per knob (ADR-007 D12). An absent row is refused, never assumed.
        CREATE TABLE history_policy (
            scope          TEXT    NOT NULL CHECK (length(scope) > 0),
            scope_ref      TEXT    NOT NULL DEFAULT '',
            policy_kind    TEXT    NOT NULL CHECK (policy_kind IN
                               ('apply_seen','show_overlay','auto_exclude')),
            policy_value   INTEGER NOT NULL CHECK (policy_value IN (0, 1)),
            policy_version TEXT    NOT NULL CHECK (length(policy_version) > 0),
            PRIMARY KEY (scope, scope_ref, policy_kind)
        );
        """

    // MARK: - v6: retention policy and the GC account (ADR-004 D8)

    /// The declared limits per retention class, and the durable record of each run.
    ///
    /// The knobs are deliberately nullable and have no default row: ADR-004's numeric budgets are
    /// fixed by measurement on the minimum device, so a build that has not measured one must not
    /// behave as if it had. Null means "no limit of this kind declared", and an absent *row* means
    /// "no policy for this class", which the coordinator reports as a skipped class rather than
    /// reading as unlimited collection.
    ///
    /// `gc_run.mode` carries the two collection strategies of D8 (`mark_sweep`, and periodic
    /// `refcount_reconcile`), and `gc_run_class` is the per-class result, so a later reconciliation
    /// can be compared with the sweep it audits. Neither table carries a migration counter: the
    /// migrator stays the only schema authority (D4), and the cursors `last_gc_revision` /
    /// `last_purge_revision` live in `runtime_metadata`.
    private static let retentionSchema = """
        -- One row per class that has a declared limit. `class` is the D8 vocabulary; the coordinator
        -- refuses a row for a class D8 marks "never collected".
        CREATE TABLE retention_policy (
            class           TEXT    PRIMARY KEY,
            max_age_seconds INTEGER CHECK (max_age_seconds IS NULL OR max_age_seconds >= 0),
            max_bytes       INTEGER CHECK (max_bytes IS NULL OR max_bytes >= 0),
            max_editions    INTEGER CHECK (max_editions IS NULL OR max_editions > 0),
            -- A declared row with no limit at all is the "unlimited" case D8 rejects; a caller that
            -- wants no limit omits the row instead.
            CHECK (max_age_seconds IS NOT NULL OR max_bytes IS NOT NULL OR max_editions IS NOT NULL)
        );

        -- One row per run, completed or aborted. An aborted run keeps its row so a crash during GC is
        -- visible instead of looking like a run that never happened.
        CREATE TABLE gc_run (
            id          INTEGER PRIMARY KEY,
            started_at_ms INTEGER NOT NULL,
            finished_at_ms INTEGER,
            mode        TEXT    NOT NULL CHECK (mode IN ('mark_sweep', 'refcount_reconcile')),
            outcome     TEXT    NOT NULL CHECK (outcome IN ('completed', 'aborted')),
            detail      TEXT,
            CHECK (outcome <> 'completed' OR finished_at_ms IS NOT NULL)
        );

        -- What one run did per class. `protected` is the count of objects the run refused to take
        -- because a retention root still pins them, and `skipped` says why a class was not collected
        -- at all; both are recorded so a class that stopped being collected is visible in the account.
        CREATE TABLE gc_run_class (
            run_id          INTEGER NOT NULL REFERENCES gc_run(id) ON DELETE CASCADE,
            class           TEXT    NOT NULL,
            collected       INTEGER NOT NULL DEFAULT 0 CHECK (collected >= 0),
            protected       INTEGER NOT NULL DEFAULT 0 CHECK (protected >= 0),
            freed_bytes     INTEGER NOT NULL DEFAULT 0 CHECK (freed_bytes >= 0),
            orphans_collected INTEGER NOT NULL DEFAULT 0 CHECK (orphans_collected >= 0),
            skipped         TEXT,
            PRIMARY KEY (run_id, class)
        );
        CREATE INDEX ix_gc_run_class_run ON gc_run_class (run_id);
        """
}
