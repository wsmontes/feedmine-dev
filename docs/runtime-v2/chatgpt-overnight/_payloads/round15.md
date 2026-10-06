[[ROUND 15 — PR-00: A MIGRAÇÃO ADITIVA CONCRETA]]

Fatos novos, do checkout (o pacote `Packages/FeedRuntimeV2`, storage do runtime):

### RuntimeMigrations.swift — identificadores e forma das funções
20:    public static var knownMigrationIdentifiers: [String] { steps.map(\.identifier) }
32:    public static func through(_ identifier: String) -> DatabaseMigrator {
43:            migrator.registerMigration(step.identifier, migrate: step.migrate)
50:        let identifier: String
51:        let migrate: @Sendable (Database) throws -> Void
54:    /// Every migration in shipping order. `current` registers all of them; `through(_:)` stops early.

### DDL existente de source / legacy_source_map / legacy_item_map
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


### RuntimeMetadata keys
142:    public static let schemaVersionKey = "runtime_schema_version"
144:    public static let schemaNameKey = "schema_name"
145:    public static let schemaName = "runtime-v2"
147:    public static func read(_ database: Database, key: String = schemaVersionKey) throws -> String? {
158:        forKey key: String = schemaVersionKey


[[TAREFA]]

Escreva a especificação executável do primeiro passo de código do seu plano: a migração aditiva que o PR-00 precisa, no molde exato do arquivo `Migrations/RuntimeMigrations.swift` (mesmo estilo de identificador das migrações existentes, seguindo a numeração já usada).

Entregue, nesta ordem:

1. IDENTIFICADOR E POSIÇÃO — o identificador da nova migração (no estilo dos existentes), de qual migração ela depende, e por que a posição é essa.

2. DDL — o SQL completo, tabela por tabela, aditivo (nada de ALTER destrutivo, nada de rekey). Toda tabela com PK explícito, as colunas com tipo e nullability, os índices, e as FKs se houver. Inclua os `CHECK` que as invariantes do ADR-003 exigem (id positivo, versão > 0).

3. INVARIANTES QUE O DDL FAZ CUMPRIR — uma linha por invariante, dizendo qual cláusula a garante.

4. IDEMPOTÊNCIA — como a migração se comporta se rodar duas vezes, e onde exatamente o `ON CONFLICT`/`IF NOT EXISTS` entra. Se a idempotência depender do runner, diga qual linha do runner (`knownMigrationIdentifiers` / `through`) a garante.

5. TESTE QUE PROVA — nome do teste, arquivo de teste onde entra, o arranjo (banco vazio, banco já migrado, banco com linha em conflito) e a asserção que o torna falso se a migração regredir.

6. O QUE ESTA MIGRAÇÃO NÃO FAZ — três linhas, para o implementador não inventar escopo.

Não escreva código Swift. SQL sim, completo.

Formato: markdown, máximo ~2000 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
