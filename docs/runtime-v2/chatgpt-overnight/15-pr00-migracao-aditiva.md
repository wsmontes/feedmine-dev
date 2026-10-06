# PR-00 — especificação da migração aditiva

## 1. IDENTIFICADOR E POSIÇÃO

**Identificador novo: NENHUM.**

Com os fatos agora disponíveis, **PR-00 não deve acrescentar uma `v8_*` migration**. A premissa anterior de que era necessário criar uma migration para `legacy_source_map`/`legacy_item_map` estava errada: ambas já fazem parte de `v2_runtime_schema`, e `source` também já contém a chave editorial versionada necessária.

A cadeia existente termina em:

```text
v1_runtime_metadata
v2_runtime_schema
v3_user_state_projection
v4_publication_schema
v5_session_and_exposure
v6_retention_schema
v7_user_list_membership
v2_runtime_schema já cria:

source;
legacy_source_map;
legacy_item_map.
Portanto não existe DDL adicional demonstravelmente necessário para M1–M4 neste ponto. Inventar v8_legacy_* apenas para recriar, espelhar ou “marcar” essas estruturas criaria uma segunda representação sem requisito normativo que a justifique.

A primeira mudança de código deve usar o schema existente para implementar o atomic ensure de Source e os testes correspondentes. Se posteriormente uma necessidade concreta de novo estado persistido for demonstrada, ela deve entrar como a próxima migration append-only (v8_*) em um PR próprio.

2. DDL
Nenhum DDL novo
O DDL relevante já existente e que PR-00 deve tratar como autoridade é:

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

CREATE TABLE legacy_source_map (
    catalog_source_key       TEXT    NOT NULL CHECK (length(catalog_source_key) > 0),
    catalog_source_id        INTEGER NOT NULL CHECK (catalog_source_id > 0),
    canonicalization_version INTEGER NOT NULL CHECK (canonicalization_version > 0),
    runtime_source_id        INTEGER NOT NULL REFERENCES source(id),
    legacy_url               TEXT    NOT NULL,
    mapped_at                INTEGER NOT NULL,
    PRIMARY KEY (catalog_source_key, canonicalization_version)
);

CREATE INDEX idx_legacy_source_map_id
    ON legacy_source_map (catalog_source_id, canonicalization_version);

CREATE TABLE legacy_item_map (
    legacy_item_id     TEXT PRIMARY KEY CHECK (length(legacy_item_id) > 0),
    legacy_source_url  TEXT NOT NULL,
    origin_record_id   INTEGER REFERENCES origin_record(id),
    origin_revision_id INTEGER REFERENCES origin_revision(id),
    confidence         TEXT NOT NULL
                       CHECK (confidence IN ('high','low','unresolved')),
    mapped_at          INTEGER NOT NULL
);
Não adicionar
PR-00 não deve adicionar:

CREATE TABLE legacy_source_map_v2 (...);
CREATE TABLE legacy_item_map_v2 (...);
ALTER TABLE feed_item ...;
ALTER TABLE legacy_source_map ...;
DROP TABLE ...;
Também não deve criar uma segunda tabela de tradução de CatalogSourceID → SourceID: legacy_source_map já é essa boundary durável.

3. INVARIANTES QUE O DDL EXISTENTE FAZ CUMPRIR
Runtime Source IDs são positivos: source.id INTEGER PRIMARY KEY CHECK (id > 0) impede 0 e IDs negativos persistidos.

Canonicalization version é positiva: CHECK (canonicalization_version > 0) existe tanto em source quanto em legacy_source_map.

Uma chave editorial versionada identifica no máximo uma Source row: UNIQUE (editorial_key, canonicalization_version).

Um mapping legacy versionado possui uma única linha autoritativa: PRIMARY KEY (catalog_source_key, canonicalization_version).

O mapping só pode apontar para Source persistida: runtime_source_id ... REFERENCES source(id).

Catalog ID não pode usar zero como sentinel persistido: catalog_source_id INTEGER NOT NULL CHECK (catalog_source_id > 0).

Nenhuma chave de catálogo vazia é válida: CHECK (length(catalog_source_key) > 0).

Legacy item identity permanece textual e opaca: legacy_item_id TEXT PRIMARY KEY; não há conversão para runtime integer ID.

Item sem resolução canônica pode continuar representado: origin_record_id e origin_revision_id são nullable e confidence admite unresolved.

Duas canonicalization versions podem apontar para a mesma Runtime Source: a PK de legacy_source_map inclui a versão e runtime_source_id não é UNIQUE; isso permite continuidade explícita sem renumerar Source.

O schema não garante sozinho que uma mapping existente jamais seja re-pointed por UPDATE; essa propriedade permanece responsabilidade do writer/bridge até que exista decisão específica para torná-la constraint SQL. Não criar trigger neste PR sem esse requisito.

4. IDEMPOTÊNCIA
Migração de schema
Não existe uma nova migration para executar duas vezes.

O runner já fornece idempotência das migrations existentes:

RuntimeMigrations.knownMigrationIdentifiers
é derivado de steps.map(\.identifier), e:

migrator.registerMigration(step.identifier, migrate: step.migrate)
registra cada migration por identificador. O DatabaseMigrator aplica somente identifiers ainda não registrados em grdb_migrations.

RuntimeMigrations.through(_:) também percorre a mesma lista ordenada e interrompe no identifier solicitado; ele não cria uma segunda sequência de schema.

Portanto v2_runtime_schema não deve ganhar IF NOT EXISTS retroativamente e não deve ser reescrita. Uma database que já registrou v2_runtime_schema não executa novamente esse DDL.

Idempotência do mapping
A idempotência operacional pertence ao writer, não à migration.

Para Source mapping, o comportamento exigido é:

INSERT INTO legacy_source_map (
    catalog_source_key,
    catalog_source_id,
    canonicalization_version,
    runtime_source_id,
    legacy_url,
    mapped_at
)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (catalog_source_key, canonicalization_version) DO NOTHING;
Depois do DO NOTHING, o mesmo write transaction deve reler a row existente e verificar que ela aponta para o runtime_source_id esperado. Se divergir, o resultado é conflito/refusal — não UPDATE.

O mesmo transaction lógico deve conter a criação/lookup da source e a persistência/validação do mapping, para que crash entre essas operações não exponha um mapping parcialmente estabelecido.

Não usar INSERT OR REPLACE.

5. TESTE QUE PROVA
Teste 1 — schema já existe; nenhuma v8 é necessária
Nome: testLegacyIdentityBridgeIsAlreadyPartOfRuntimeSchema

Arquivo:
Packages/FeedRuntimeV2/Tests/FeedStorageTests/MigrationTests.swift

Arranjo:

criar banco vazio;
abrir com RuntimeMigrations.current;
confirmar aplicação até a migration corrente;
consultar sqlite_master e PRAGMA para source, legacy_source_map e legacy_item_map.
Asserções que tornam o teste falso se houver regressão:

as três tabelas existem;
source.id é PK;
legacy_source_map possui PK composta por catalog_source_key + canonicalization_version;
legacy_source_map.runtime_source_id referencia source(id);
os CHECK de IDs/version positivos continuam presentes funcionalmente, provados por inserts inválidos que falham;
legacy_item_map.origin_record_id e origin_revision_id continuam nullable;
não existe migration v8_* necessária apenas para criar essas estruturas.
Teste 2 — reabertura não reaplica schema
Nome: testLegacyIdentitySchemaReopenIsIdempotent

Arquivo:
Packages/FeedRuntimeV2/Tests/FeedStorageTests/MigrationTests.swift

Arranjo:

criar banco vazio e migrar;
inserir uma source;
inserir uma legacy_source_map;
fechar;
reabrir com RuntimeMigrations.current.
Asserção falsificadora:

a mapping continua exatamente uma;
runtime_source_id permanece igual;
a row de source permanece a mesma;
grdb_migrations não ganha uma segunda ocorrência de v2_runtime_schema;
nenhum conteúdo é recriado ou substituído.
Teste 3 — conflito não re-ponta mapping
Nome: testLegacySourceMappingConflictDoesNotRepointExistingSource

Arquivo:
Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacyMappingStoreTests.swift se esse arquivo existir; caso contrário, colocar no test target FeedStorageTests em um novo arquivo com esse nome.

Arranjo:

criar source A;
persistir (catalogKey K, version 1) → A;
criar source B;
tentar persistir (K, 1) → B pelo writer oficial.
Asserção falsificadora:

SELECT runtime_source_id
FROM legacy_source_map
WHERE catalog_source_key = K
  AND canonicalization_version = 1
continua retornando A, nunca B.

Se o writer apenas fizer ON CONFLICT DO NOTHING sem reler/verificar a divergência, o teste deve falhar: conflito silencioso não satisfaz o contrato.

6. O QUE ESTA MIGRAÇÃO NÃO FAZ
Não cria nem altera feed_item.id, não faz rekey de bookmark, imported source, collection, Smart Feed, filtro ou qualquer outro dado do usuário.

Não cria uma segunda tabela de identidade legacy/runtime: source, legacy_source_map e legacy_item_map existentes são reutilizadas; a autoridade legacy permanece durante a coexistência.

Não muda shipping mode, UI owner ou acquisition owner; PR-00 apenas prova que o schema existente suporta a migração aditiva e prepara o atomic ensure que virá no próximo passo de código.