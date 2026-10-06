# FeedMine V2 — Plano Normativo de Migração de Identidade

**Checkout de autoridade:** `fix/release-1.0-final-hardening` @ `70f7b06b`, working tree 2026-10-05  
**Escopo:** migração requerida por `docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md` §5.2, no parágrafo que começa com “Inventariar também lidos, clicked history, fontes importadas, fontes desabilitadas, coleções, Smart Feeds, filtros persistidos e busca persistente.”  
**Regra:** o legado permanece recuperável até cutover explicitamente aprovado. Nenhum ID V2 é derivado posicionalmente de ID legado.

# 1. CONTRADIÇÕES

- **CONFIRMA:** a identidade editorial legada é de fato URL-normalizada, não identidade FeedMine-owned: `FeedSource.id` é `OPMLParser.normalizeURL(url)` e nem é persistido. (`feedmine/Models/FeedSource.swift:14,86-96`)
- **CONFIRMA, com risco maior que o ADR explicitou:** normalização de identidade força HTTPS, remove `www`, omite apenas portas default (80 para HTTP e 443 para HTTPS), preserva portas não-default, remove trailing slash e parâmetros inclusive `token`, `auth`, `key`, `signature` e `access_token`; portanto duas acquisition targets materialmente distintas podem colapsar na mesma identidade legada. (`feedmine/Services/OPMLParser.swift:497-509,669,704,717-727,736,740-744`)
- **INVALIDA qualquer migração “UInt32 → UInt64”:** coexistem `FeedEngine.SourceID(UInt32)` derivado por digest e `FeedDomain.SourceID(UInt64)` alocado pelo runtime; o próprio V2 declara que não são conversíveis posicionalmente. (`feedmine/FeedEngine/Identities.swift:32-37`; `Packages/FeedRuntimeV2/.../RuntimeIDs.swift:5-24`)
- **CONFIRMA:** o catálogo também ancora identidade em URL canônica e digest de 32 bits; colisão é erro, não mecanismo de identidade editorial V2. (`feedmine/FeedEngine/CatalogIdentity.swift:12-26,56-61`; `feedmine/FeedEngine/SQLiteCatalogStore.swift:216-217`)
- **INVALIDA a suposição de que a ponte de migração ainda precisa ser inventada:** `legacy_source_map` e `legacy_item_map` já existem no runtime e já têm persistence APIs. (`Packages/FeedRuntimeV2/.../RuntimeMigrations.swift:414-433`; `.../LegacyMappingStore.swift:19-43,64-95`)
- **CONFIRMA a direção do ADR-003:** runtime `SourceID` já é alocado pela tabela `source`; não deriva de URL nem do digest legado. (`Packages/FeedRuntimeV2/.../SourceRegistry.swift:30-65`; `RuntimeMigrations.swift:221-230`)
- **INVALIDA reconstrução exata da identidade externa histórica:** `FeedItem.generateID` usa GUID/link/fallback, mas o GUID e a chave externa bruta não são persistidos; fica somente o SHA-256 resultante e o link normalizado do item. (`feedmine/Models/FeedItem.swift:394-402`; `feedmine/Services/RSSFetcher.swift:1050-1076`; `feedmine/Services/FeedStore.swift:8392-8425`)
- **INVALIDA dedupe histórico por GUID:** depois da persistência não há como provar que dois hashes de `FeedItem` são o mesmo objeto upstream apenas porque link/título parecem iguais. (`feedmine/Models/FeedItem.swift:394-402`; `feedmine/Services/FeedStore.swift:8392-8425`)
- **CONFIRMA que o catálogo não deve receber migração destrutiva:** `catalog.sqlite` é reconstruído em temporário e trocado atomicamente; é artefato regenerável, não user-state. (`feedmine/FeedEngine/SQLiteCatalogStore.swift:55-76,236,634-703`)
- **INVALIDA usar `feedmine.sqlite.bookmark_item` como autoridade atual:** as tabelas antigas ainda existem, mas `FeedStore` delega bookmarks ao `BookmarkStore`, cuja autoridade está em `user.sqlite`. (`feedmine/Services/FeedStore.swift:7703-7737,7849-7869`; `feedmine/Services/BookmarkStore.swift:6-11`)
- **INVALIDA qualquer hipótese de que read/seen já foi migrado ao runtime:** `is_read/opened_at/clicked_at/consumed_at` continuam em `feed_item`; `UserStateStore` e runtime não são autoridade desse estado. (`feedmine/Services/FeedStore.swift:3938-3990`; `feedmine/Services/UserStateStore.swift:884-886`; `feedmine/RuntimeV2/V2FullRuntime.swift:34-37,101-105`)
- **CONFIRMA a dívida de identidade de apresentação:** legacy `PreparedFeedCard.id` e `MainFeedRow.id` são `item.id`. (`feedmine/Models/PreparedFeedCard.swift:103-119`; `feedmine/RuntimeV2/MainFeedPresentationPipeline.swift:13-18`)
- **INVALIDA tratar o atual V2 bridge como Publication identity final:** `MainFeedCardBridge` fabrica `PublicationCardID` determinístico a partir do hash de `item.id`; isso é alias de compatibilidade, não o ID alocado da linha `published_card`. (`feedmine/RuntimeV2/MainFeedCardBridge.swift:191,203-224`; `Packages/FeedRuntimeV2/.../RuntimeMigrations.swift:481-635`)
- **CONFIRMA que a fronteira correta para identidade externa nova é antes de `FeedItem`:** `ShadowParsedEntry` ainda enxerga GUID/link crus; depois disso a informação é descartada. (`feedmine/Services/RSSFetcher.swift:1020-1127,1060-1073`)
- **INVALIDA a suposição de que uma migração ocorrerá naturalmente no próximo launch:** stock launch resolve `.legacy` e não compõe `RuntimeDatabase`; hoje runtime production/shadow só nasce por request/launch argument. (`feedmine/feedmineApp.swift:214`; `feedmine/RuntimeV2/RuntimeCompositionRoot.swift:74-120`; `Packages/FeedRuntimeV2/.../RuntimeMode.swift:57-79,129-146`)
- **CONFIRMA que rollback pode ser não destrutivo:** content DB, user DB e runtime DB têm migrators independentes; nada exige rekey do legado para introduzir o V2. (`feedmine/Services/FeedStore.swift:7823-8312`; `feedmine/Services/UserStateStore.swift:208-459`; `Packages/FeedRuntimeV2/.../RuntimeMigrations.swift:56-139`)

# 2. MAPA DE MIGRAÇÃO

## M1 — FeedSource / SourceID

**Decisão M1:** nunca converter `FeedEngine.SourceID(UInt32)` para `FeedDomain.SourceID(UInt64)`. O único vínculo permitido é mapping explícito.

**Muda**

| Elemento | Mudança |
|---|---|
| `legacy_source_map` | Continua sendo a ponte para sources provenientes do catálogo. |
| `FeedDomain.SourceID` | Continua sendo alocado por `RuntimeSourceRegistry`. |
| runtime schema | Adicionar mapping genérico para sources persistidas fora do catálogo, principalmente `imported_source`/collections. |
| Swift | Introduzir resolver `LegacySourceIdentityResolver`; entrada = persisted `source_identity`, saída = runtime `SourceID`. |

DDL novo no próximo runtime migration:

```sql
CREATE TABLE legacy_source_identity_map (
    legacy_source_identity TEXT NOT NULL,
    canonicalization_version INTEGER NOT NULL CHECK(canonicalization_version > 0),
    runtime_source_id INTEGER NOT NULL REFERENCES source(id),
    request_url TEXT,
    origin_kind TEXT NOT NULL,
    mapped_at INTEGER NOT NULL,
    PRIMARY KEY (legacy_source_identity, canonicalization_version)
);

CREATE INDEX idx_legacy_source_identity_runtime
ON legacy_source_identity_map(runtime_source_id);
Não muda: FeedSource.id, SourceReference.id, IDs UInt32 do catálogo, source_identity já persistido em user.sqlite.

Invariante: um mesmo persisted legacy identity/version resolve sempre para exatamente um runtime SourceID; mudança de endpoint não renumera o Source V2.

M2 — FeedItem / OriginRecord / OriginRevision
Decisão M2: legacy_item_map existente é a autoridade de ponte. Para histórico já persistido, feed_item.id deve ser tratado como external identity opaca de namespace legacy-feed-item; não tentar reconstruir GUID nem mesclar por heurística.

Muda

Elemento	Mudança
legacy_item_map	Backfill para todo feed_item migrado.
OriginRecord	Histórico recebe identidade opaca derivada do legacy_item_id, não de GUID reconstruído.
OriginRevision	Conteúdo atual do feed_item torna-se revision inicial do backfill.
Swift	Backfiller idempotente usando LegacyMappingStore.
Não muda: feed_item.id, geração SHA-256 legacy, rows legacy, URLs armazenadas.

Invariante: dois feed_item.id diferentes nunca são automaticamente fundidos durante backfill. Relação/dedupe futura é aditiva e reversível.

M3 — CatalogIdentity
Decisão M3: congelar a canonicalização atual como uma versão explícita de compatibilidade. Qualquer mudança futura em normalizeURL exige incremento de canonicalization_version, nunca reinterpretar mappings existentes.

Muda: chamadas que gravam legacy_source_map devem sempre fornecer versão explícita e validar conflitos antes do insert.

Não muda: catalog.sqlite, catalog_source.id, catalog_source.key, stableUInt32Digest, build→swap.

Invariante: a mesma versão do catálogo + mesma canonicalização produz o mesmo bridge mapping; catálogo continua descartável/reconstruível.

M4 — Persistence e migrations
Decisão M4: content DB e user DB não recebem rekey. Toda nova estrutura de migração entra em RuntimeMigrations.swift.

Adicionar:

CREATE TABLE legacy_item_state (
    legacy_item_id TEXT PRIMARY KEY,
    origin_record_id INTEGER,
    is_read INTEGER NOT NULL CHECK(is_read IN (0,1)),
    opened_at INTEGER,
    clicked_at INTEGER,
    consumed_at INTEGER,
    captured_at INTEGER NOT NULL,
    FOREIGN KEY(origin_record_id) REFERENCES origin_record(id)
);

CREATE TABLE legacy_migration_checkpoint (
    name TEXT PRIMARY KEY,
    completed_at INTEGER,
    migrated_count INTEGER NOT NULL DEFAULT 0,
    unresolved_count INTEGER NOT NULL DEFAULT 0
);

Não muda: feedmine.sqlite migrations v1…v25, user.sqlite v1…v11, catálogo schema 2.

Invariante: downgrade para código legacy pode ignorar o runtime DB e continuar usando os bancos antigos.

M5 — Referências duráveis do usuário
Decisão M5: durante a janela de migração, user.sqlite permanece autoridade de bookmarks/imported sources e feedmine.sqlite permanece autoridade do read-state legacy. Migração é copy/bridge, nunca move/delete.

Muda

copiar feed_item.is_read/opened_at/clicked_at/consumed_at para legacy_item_state;
resolver bookmark_item.item_id através de legacy_item_map;
preservar bookmark_snapshot literalmente;
mapear imported_source.source_identity via legacy_source_identity_map;
V2 deve ler os atuais filter* de AppSettings até existir substituto equivalente.
Não muda: PKs de bookmark_item, bookmark_snapshot, imported_source; chaves atuais de UserDefaults.

Invariante: V2 desligado depois da migração apresenta exatamente o mesmo estado legacy existente antes dela.

Fato suficiente para preservação tipada: `feedmine/Services/AppSettings.swift:65-92` expõe `filterRegion: String?`, `filterTaxonomyNodes: [String]`, `filterContentType: String`, `filterAutoExpire: Bool`, `filterSetAt: TimeInterval`, `filterLanguages: [String]` e `filterMood: String`. A migração deve preservar esses tipos e seus valores sem rekey ou tradução destrutiva. Portanto nenhuma tradução de filtros é autorizada nesta fase.

M6 — Identidade de apresentação
Decisão M6: legacy continua identificado por item.id; V2 publicado usa o PublicationCardID realmente armazenado em published_card.

Muda

MainFeedRow passa a suportar identidade discriminada, por exemplo:
enum MainFeedRowID: Hashable { case legacy(String); case publication(PublicationCardID) };
rows V2 recebem .publication(realPublishedCardID);
MainFeedCardBridge.cardID(forLegacyItemID:) é marcado como compatibility-only e não pode persistir/mintar identidade editorial.
Não muda: FeedItemCardView legacy nem caches PreparedFeedCard enquanto surface está em modo legacy.

Invariante: um card já publicado mantém o mesmo PublicationCardID independentemente de alteração ou reingestão do Origin.

M7 — Fronteira RSS
Decisão M7: para novos itens, a identidade externa V2 deve ser capturada no ponto onde ShadowParsedEntry ainda possui GUID/link crus, antes de FeedItem.generateID destruir essa informação.

Muda

shadow/admission adapter consome os valores crus já disponíveis em RSSFetcher;
AcquisitionBatch/equivalente recebe external object/version identity antes de FeedItem;
backfill histórico continua usando namespace opaco legacy-feed-item.
Não muda: FeedHTTPSync, FeedKit, redirects, validators, 20MB cap, retry behavior, audio probe, nem legacy persistence nesta fatia.

Invariante: habilitar shadow/V2 não cria um segundo HTTP fetch para o mesmo request legacy.

M8 — Compatibilidade de release
Decisão M8: introduzir um bootstrap de migração do runtime em stock .legacy, sem ativar V2 UI nem V2 network.

Muda

feedmineApp.swift/composition adiciona LegacyMigrationCoordinator;
coordinator pode criar/abrir o production RuntimeDatabase, executar runtime migrations e backfills;
falha da migração mantém o app em legacy;
cutover para V2 é flag separado e posterior.
Não muda: resolução default .legacy, acquisition ownership, legacy UI/network.

Invariante: primeira instalação atualizada pode preparar V2 sem alterar a experiência do usuário; rollback do app continua abrindo os dados legacy.

3. FATIAS EXECUTÁVEIS
PR-00 — Migration bootstrap
Pré-requisito: nenhum.
Alvos: feedmineApp.swift, RuntimeCompositionRoot.swift, novo LegacyMigrationCoordinator, RuntimeMigrations.swift; tabelas legacy_source_identity_map, legacy_item_state, legacy_migration_checkpoint.
Teste: MigrationBootstrapTests.testStockLegacyLaunchCreatesMigrationRuntimeWithoutEnablingV2UIOrNetwork.
Rollback: remover chamada do coordinator; runtime DB extra permanece ignorável. Nenhum banco legacy alterado.

PR-01 — Source bridge completo
Pré-requisito: PR-00.
Alvos: LegacyMappingStore, RuntimeSourceRegistry, legacy_source_map, legacy_source_identity_map, readers de catalog_source, source_collection_member, imported_source.
Teste: LegacySourceMigrationTests.testCatalogImportedAndCollectionIdentitiesResolveToStableRuntimeSourceIDs.
Rollback: desabilitar backfill; legacy continua autoritativo. Conflito de mapping bloqueia cutover, nunca sobrescreve silenciosamente.

PR-02 — Historical item backfill
Pré-requisito: PR-01.
Alvos: feed_item, Origin repository existente, legacy_item_map.
Teste: LegacyItemMigrationTests.testBackfillIsIdempotentAndNeverMergesDistinctLegacyItemIDs.
Rollback: desativar uso dos mappings. Mappings incorretos exigem migration corretiva; ON CONFLICT DO NOTHING proíbe “consertar” silenciosamente.

PR-03 — Durable-state capture
Pré-requisito: PR-02.
Alvos: feed_item.is_read/opened_at/clicked_at/consumed_at, legacy_item_state, bookmark_item, bookmark_snapshot, imported_source.
Teste: LegacyStateMigrationTests.testReadClickConsumeAndBookmarksSurviveLegacyFeedItemDeletion.
Rollback: runtime snapshot ignorado; nenhuma row user/content é removida.

PR-04 — Exact identity for new RSS ingress
Pré-requisito: PR-02.
Alvos: RSSFetcher.swift no ponto ShadowParsedEntry, V2 acquisition adapter, legacy_item_map.
Teste: SyndicationIdentityMigrationTests.testRawGuidOrLinkReachesAdmissionBeforeLegacyHashing.
Rollback: desligar shadow admission; legacy fetch/persist permanece byte-for-byte no mesmo caminho.

PR-05 — Publication-card identity cutover interno
Pré-requisito: PR-02 + publication tables já existentes.
Alvos: MainFeedCardBridge.swift, MainFeedPresentationPipeline.swift, MainFeedRow, runtime publication repository.
Teste: PublicationIdentityMigrationTests.testV2RowUsesPersistedPublishedCardIDAndLegacyRowUsesItemID.
Rollback: V2 UI flag off; legacy row identity permanece intacta.

PR-06 — Migration audit gate
Pré-requisito: PR-01…PR-05.
Alvos: migration diagnostics/checkpoint.

Métricas obrigatórias: sources total/mapped/conflicted; items total/mapped; bookmark item mapped/unmapped; snapshots present/missing; read-state captured; imported sources mapped; filter compatibility status.

Teste: MigrationAuditTests.testCutoverFailsWhenAnyDurableReferenceWouldBeLost.
Rollback: audit only; zero mutation adicional.

PR-07 — Controlled V2 enablement
Pré-requisito: PR-06 verde + decisões humanas aplicáveis fechadas.
Alvos: mecanismo já existente de RuntimeModeLaunch.request/flags; nenhuma nova rede paralela.
Teste: ReleaseUpgradeTests.testUpgradeToV2AndReturnToLegacyPreservesAllUserState.
Rollback: remover stored request/flag e voltar .legacy; não executar down-migration em user/content DB.

4. RISCO DE PERDA DE DADOS
Estado	Risco exato	Mitigação normativa	Status
user.sqlite.bookmark_item	item_id é hash legacy e não tem FK cross-DB; V2 pode não conseguir resolver origin, ou pode rekeyar e “sumir” com bookmark.	Nunca rekey/delete. Resolver via legacy_item_map; quando não houver mapping, manter bookmark legacy e usar snapshot.	BLOQUEADOR se o cutover tornar um bookmark existente inacessível.
user.sqlite.bookmark_snapshot	Regenerar snapshot usando current revision pode alterar título/URL/excerpt/media ou eliminar conteúdo já capturado.	Preservar a row literalmente; snapshot é evidência durável, não cache regenerável.	BLOQUEADOR para qualquer overwrite destrutivo.
feed_item.is_read	Estado vive na mesma row sujeita a retention/expurgo; runtime não possui autoridade equivalente.	Copiar para legacy_item_state antes do cutover; migration idempotente.	BLOQUEADOR enquanto estado existente não estiver capturado.
feed_item.clicked_at	Merge heurístico de dois legacy IDs pode mover timestamp para item errado ou descartá-lo.	Mapping 1:1 por legacy_item_id; nunca dedupe durante migration.	BLOQUEADOR para merge destrutivo.
feed_item.consumed_at	V2 pode interpretar ausência como “não consumido” depois que legacy row for expurgada.	Snapshot explícito; ausência de row histórica não deve ser convertida em evento negativo.	BLOQUEADOR enquanto rows existentes não forem capturadas.
user.sqlite.imported_source	legacy_source_map atual exige identidade de catálogo; imported source pode não ter catalog_source_id. Além disso source_identity normalizada pode ter removido credenciais da request URL.	legacy_source_identity_map específico para persisted identity + preservar request_url; nenhuma deduplicação adicional baseada em URL.	BLOQUEADOR se uma source importada enabled não resolver no V2.
UserDefaults filter*	Troca de modelo de filtro pode fazer preferências parecerem resetadas mesmo que bytes permaneçam. O payload fornecido não inclui tipos/encoding.	Não renomear nem traduzir keys nesta fase; V2 deve ter adapter de compatibilidade. Cutover exige teste com valores reais.	BLOQUEADOR se V2 ignorar ou reinterpretar filtro persistido.
Limite de recuperação: read/click/consume já apagados por retenção antes desta migração não podem ser reconstruídos dos fatos disponíveis. A migração é obrigada a preservar o que ainda existe; é proibido inventar histórico perdido.

5. DECISÕES HUMANAS
H1 — Política de ativação pública
[PRECISA DE HUMANO]

Qual release muda o default de .legacy para V2?

A. Release atual prepara/backfill apenas; V2 continua desabilitado por default.
B. Mesmo release prepara e ativa V2 após audit local verde.
C. Ativação staged em release posterior/flag controlada.
Até decisão: A.

H2 — Janela de rollback legacy
[PRECISA DE HUMANO]

Por quanto tempo o código/storage legacy deve permanecer operacional depois do primeiro cutover V2?

A. um release público completo;
B. dois releases;
C. até atingir critério quantitativo de migração/telemetria definido.
Nenhuma remoção legacy antes dessa decisão.

H3 — Retenção futura de read/click/consume
[PRECISA DE HUMANO]

Hoje esses dados desaparecem quando feed_item é expurgado. No V2 eles devem sobreviver por quanto tempo?

A. apenas enquanto o conteúdo estiver retido;
B. janela temporal definida;
C. indefinidamente como histórico do usuário.
legacy_item_state é snapshot de migração e não decide sozinho a política final.

H4 — Colisões da canonicalização legacy
[PRECISA DE HUMANO]

Quando duas acquisition URLs distintas reduzem ao mesmo source_identity legacy porque parâmetros de autenticação/assinatura são removidos:

A. preservar o único Source legacy e tratar URLs distintas como bindings;
B. permitir revisão/manual split em dois Sources V2;
C. criar split automático quando request URLs forem diferentes.
Até decisão: A para migração automática; nenhum split heurístico.

H5 — Critério de bloqueio para referências não resolvidas
[PRECISA DE HUMANO]

No momento do cutover, o que fazer se houver durable references não resolvidas?

A. exigir zero unresolved para todos os usuários;
B. permitir V2 somente para instalações com zero unresolved;
C. permitir fallback legacy por item/source individual.
A migração proíbe qualquer opção que simplesmente descarte a referência.
```