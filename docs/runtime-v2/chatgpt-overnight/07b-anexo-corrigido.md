## Plano de migração normativo (anexo)

**Origem do handoff:** este anexo cumpre `docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md` §5.2, em especial o parágrafo que começa com **“Inventariar também lidos, clicked history, fontes importadas, fontes desabilitadas, coleções, Smart Feeds, filtros persistidos e busca persistente.”**

Este anexo define como identidades e estado persistido do runtime legacy coexistem e migram para Runtime V2. Ele não altera a definição de Source, Origin, Provider, Binding ou Target deste ADR; não substitui nenhuma seção anterior; e não autoriza, por si só, freeze, cutover de UI, mudança de acquisition owner ou remoção de dados legacy.

### 1.1 M1 — Source runtime é alocada; nunca convertida do catálogo

**Muda:** a resolução de uma Source de catálogo para Runtime V2 passa por uma identidade runtime alocada e por mapping durável.

**Não muda:** `FeedEngine.SourceID` continua sendo a identidade compacta do catálogo legacy. A canonicalização legacy continua existindo para seu próprio domínio.

**Invariante:** `FeedDomain.SourceID` nunca é produzido por widening cast, digest, URL normalizada, catalog row order ou `CatalogSourceID`.

O fluxo normativo é:

```text
catalog source
    ↓
EditorialSourceKey(catalog identity, canonicalization version)
    ↓
lookup legacy_source_map
    ↓ missing
allocate/ensure runtime SourceID
    +
persist legacy_source_map
    ↓
return durable runtime SourceID
legacy_source_map já existe no runtime e já participa de paths de produção; este plano não propõe recriá-lo ou criar um segundo bridge para Sources de catálogo.

O ensure deve ser atomicamente idempotente: allocation de source, confirmação do row resultante, validação de conflito e gravação de legacy_source_map devem formar uma única operação transacional lógica. Chamadas concorrentes para a mesma chave devem convergir para o mesmo runtime SourceID.

A colisão do catálogo continua sendo erro explícito no legado (SQLiteCatalogStore.swift:216-217); ela não autoriza reaproveitar o valor compacto como runtime identity.

1.2 M2 — FeedItem.id histórico é uma chave opaca de migração
Muda: Runtime V2 resolve um item legacy exclusivamente através de legacy_item_map ou registra que a resolução não é conhecida.

Não muda: feed_item.id não é rekeyed, reescrito ou reinterpretado.

Invariante: nenhum GUID/Atom id histórico é reconstruído a partir de FeedItem.id, URL, título, timestamp ou similaridade.

O bridge é:

legacy FeedItem.id
    ↓
legacy_item_map
    ↓
OriginRecordID
OriginRevisionID?
confidence
legacy_item_map já existe e é usado; a migração é de cobertura e reconciliação, não de criação de uma nova namespace.

Quando a evidência histórica não for suficiente:

preservar o legacy item;
persistir unresolved/confidence apropriada;
não fundir Origins;
não inventar GUID;
não descartar referência durável.
Uma referência durável do usuário que permaneça unresolved é bloqueadora para o cutover da superfície que precisa dela.

1.3 M3 — canonicalization_version versiona a chave legacy, não a Source runtime
Muda: cada mapping dependente de canonicalização é interpretado em conjunto com sua canonicalization_version.

Não muda: mappings antigos continuam válidos e runtime SourceID não é renumerado quando a canonicalização muda.

Invariante: uma mudança de algoritmo nunca re-ponta silenciosamente uma Source existente.

Para uma nova versão:

preservar mappings anteriores;
estabelecer continuidade com o mesmo runtime SourceID somente quando a evidência for inequívoca;
permitir nova linha de mapping para a nova versão;
em ambiguidade, registrar/refusar associação automática;
nunca inferir continuidade apenas porque duas URLs “parecem iguais”.
A normalização legacy omite apenas portas default — HTTP 80 e HTTPS 443; portas não-default permanecem na identidade (OPMLParser.swift:719-723).

1.4 M4 — Migração é aditiva; nenhuma PK legacy é reescrita
Muda: Runtime V2 adiciona mappings, projections e estado necessário à coexistência.

Não muda: as PKs e chaves duráveis de feedmine.sqlite, user.sqlite e catálogo permanecem intactas durante a compatibility window.

Invariante: rollback não depende de reconstruir o estado legacy a partir de IDs runtime.

Enquanto rollback legacy estiver suportado:

feed_item.id permanece intacto;
bookmark item keys permanecem intactas;
imported-source identity permanece intacta;
collection memberships permanecem intactas;
nenhuma tabela legacy passa a usar runtime integer ID como sua única referência;
migrations são append-only;
erase-on-schema-change é proibido.
runtime-v2.sqlite pode ser reconstruível onde ADR-004 assim define; dados duráveis do usuário não podem depender dessa reconstrução para sobreviver semanticamente.

1.5 M5 — Estado durável do usuário é bridged/copied antes da troca de owner
Muda: antes de uma superfície tornar-se V2-owned, todo estado durável relevante deve possuir uma representação ou bridge verificável.

Não muda: a autoridade legacy permanece disponível durante a compatibility window; migração não implica delete da origem.

Invariante: nenhum estado do usuário pode desaparecer por causa da troca de identidade ou do ciclo de retention de feed_item.

Os oito insumos explicitamente pedidos pelo plano §5.2 são:

lidos;
clicked history;
fontes importadas;
fontes desabilitadas;
coleções;
Smart Feeds;
filtros persistidos;
busca persistente.
Bookmarks e bookmark snapshots também são durability roots já exigidos pelo próprio §5.2.

Os filtros possuem tipos conhecidos em feedmine/Services/AppSettings.swift:65-92:

filterRegion: String?;
filterTaxonomyNodes: [String];
filterContentType: String;
filterAutoExpire: Bool;
filterSetAt: TimeInterval;
filterLanguages: [String];
filterMood: String.
Qualquer outro encoding ou default necessário à migração e não demonstrado no checkout deve ser registrado como:

[INDETERMINADO — requer leitura de feedmine/Services/AppSettings.swift]

A sequência é sempre:

legacy authority
    ↓
resolve durable subject/identity
    ↓
copy / bridge / project
    ↓
verify
    ↓
permit ownership change
Nunca:

move → delete legacy → tentar reconstruir
Não existe commit transacional implícito entre user.sqlite e runtime-v2.sqlite; operações cross-DB devem permanecer idempotentes/replayable conforme ADR-004.

1.6 M6 — Compatibility card identity não é PublicationCardID
Muda: qualquer boundary V2 que exige uma ocorrência publicada deve receber o ID persistido da publication real.

Não muda: uma superfície ainda legacy-owned pode continuar identificando suas próprias rows pelo legacy item ID enquanto não houve cutover.

Invariante: hash/alias derivado de FeedItem.id nunca é promovido a persisted publication identity.

O compatibility bridge ainda possui cardID(forLegacyItemID:) em MainFeedCardBridge.swift:234-245, chamado em :188. Esse valor é compatibility identity.

O caminho runtime válido é:

legacy identity/evidence
    ↓
OriginRecord + OriginRevision
    ↓
publication transaction
    ↓
INSERT published_card
    ↓
PublicationCardID
    ↓
presentation / actions / exposure
Na implementação auditada, o published_card é inserido em PublicationRepository.swift:1009-1041, e PublicationCardID(db.lastInsertedRowID) é criado em :1042.

Dentro da mesma Edition, rerender/rematerialization mantém a identidade publicada conforme ADR-001/ADR-007. Uma successor Edition pode criar novas occurrences segundo o contrato de publication.

1.7 M7 — Novos ingressos preservam external identity antes da redução legacy
Muda: novos ingressos destinados ao Runtime V2 devem capturar GUID/Atom id/link/evidência antes que o modelo FeedItem descarte parte dessa informação.

Não muda: itens históricos cujo GUID bruto já foi perdido continuam opacos; esta regra não tenta repará-los retroativamente.

Invariante: external object identity fornecida por connector é armazenada como evidência opaca segundo ADR-003, não normalizada como Source URL.

Para syndication:

RSS GUID é opaco;
Atom id é opaco;
link é evidência separada;
GUID que parece URL continua sendo GUID;
OPMLParser.normalizeURL não transforma external object key;
fallback sem identidade forte é explícito, versionado e low-confidence.
O caminho mirrored/shadow pode reutilizar aquisição local existente, mas não deve criar uma segunda árvore de network requests apenas para obter a mesma evidência.

1.8 M8 — Bootstrap não é cutover
Muda: o runtime pode migrar schema, criar mappings, executar backfill limitado e medir cobertura antes de ser owner da superfície.

Não muda: stock launch, UI owner e acquisition owner não mudam apenas porque o runtime DB está preparado.

Invariante: bootstrap deve ser resumable, bounded e reversível enquanto a compatibility window estiver aberta.

Para Source mappings:

fazer batch limitado no bootstrap;
completar lazy/on-demand com `LegacySourceIdentityResolver` (D20–D21);
aceitar cobertura parcial durante a migração;
tratar missing mapping como trabalho a assegurar;
recusar apenas quando mapping durável e não disputado não puder ser estabelecido.
Bootstrap sozinho não pode:

tornar V2 Main Feed default;
iniciar acquisition concorrente com o owner atual;
tornar runtime DB autoridade única de bookmarks;
apagar feedmine.sqlite ou user.sqlite;
converter compatibility card aliases em PublicationCardID.
1.9 Ordem obrigatória das fatias
Ordem	Fatia	Pré-requisito	Prova mínima	Rollback
0	Bootstrap/storage readiness	ADR contracts revisados; migrations atuais íntegras	MigrationTests + boundary gate; runtime DB abre/reabre sem alterar bancos legacy	Desligar bootstrap/runtime composition; legacy permanece íntegro
1	Atomic Source ensure	Fatia 0	teste que prova chamadas repetidas/concorrentes → um SourceID + um mapping. Nome exato normativo: `missingLegacySourceMappingAllocatesAndPersistsExactlyOnce`, em `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (`criar`).	Remover caller do ensure; mappings já válidos permanecem
2	Legacy item/Origin backfill	Source identity resolvível	feedmineTests/LegacyIdentityMapperTests.swift + prova de replay idempotente/unresolved sem merge	Desativar backfill; nenhum feed_item.id foi alterado
3	Durable user-state bridge	Fatias 1–2	feedmineTests/RuntimeV2UserStateBridgeTests conforme contrato do ADR-004; provar restart legacy após estado criado/projetado pelo V2	Voltar leituras à autoridade legacy; não apagar projections para diagnóstico
4	Raw identity capture para novos ingressos	Origin bridge estável	prova de GUID opaco/não-normalizado e zero duplicate network ownership. Teste exato adicional: [INDETERMINADO — requer leitura de Packages/FeedRuntimeV2/Tests/FeedConnectorSyndicationTests/]	Remover handoff para V2; RSS legacy continua igual
5	Migration audit	Fatias 1–4	relatório determinístico de mapped / allocatable / unresolved / conflicted / durable-reference-at-risk	Remover apenas o gate/reporting; dados permanecem
6	Card identity separation	Origins migráveis + audit sem perda	CardActionBoundaryTests.swift e teste explícito de alias≠publication ID; nome exato [INDETERMINADO — requer leitura de feedmineTests/CardActionBoundaryTests.swift]	Voltar à apresentação compatibility sem ativar publication ownership
7	Publication/presentation handoff	Fatias 5–6	publication tests devem provar PublicationCardID persistido, actions/history por esse ID, same-edition continuity e rollback	Desativar V2 presentation; preservar runtime DB
8	Controlled cutover	audit verde + decisão humana de release	upgrade + cold launch + rollback suite; nenhuma durable reference at risk	Retornar shipping default para legacy enquanto compatibility window estiver aberta
9	Legacy removal	fim humano da rollback window	migration/release matrix completa	Antes de delete shipping: revert do PR; depois de data removal, rollback exige migration própria
A ordem não pode ser invertida: uma fatia não deve criar durable references para uma identidade que a fatia anterior ainda não consegue resolver de forma estável.

1.10 Riscos de perda de dados e critérios bloqueadores
Estado/tabela	Risco	Regra de preservação	BLOQUEADOR
catalog_source / catalog Source identity	Cast/re-derivation produzir outra runtime Source após rebuild	legacy_source_map + canonicalization version; nunca cast/digest	SIM se uma Source necessária puder apontar para runtime ID diferente
runtime-v2.sqlite.legacy_source_map	Allocation e mapping em commits separados deixarem Source órfã ou mapping disputado	ensure transacional/idempotente; mapping existente nunca é re-point silenciosamente	SIM
feedmine.sqlite.feed_item	Retention apagar conteúdo enquanto user state ainda depende exclusivamente do row	mapear/bridgear durable references antes de trocar owner; não inventar GUID	SIM quando houver referência durável dependente
runtime-v2.sqlite.legacy_item_map	Merge heurístico ou perda de unresolved reference	legacy ID opaco; confidence explícita; nenhum merge por similaridade	SIM para durable references
user.sqlite.bookmark_item	Rekey para runtime integer quebrar bookmark/rollback	preservar legacy durable key durante coexistência	SIM
bookmark_snapshot	Bookmark sobreviver sem dados suficientes para reabrir/renderizar	preservar snapshot mínimo exigido por ADR-004/plan §5.2	SIM
legacy read/click/consume state	estado parecer “novo/não lido” após cutover	project/bridge antes da troca de owner; retention posterior depende de política humana	SIM para cutover se estado necessário não puder ser representado
imported sources	perder request URL/identity/configuração ao criar runtime Source	manter row legacy e associação aditiva	SIM se Source importada desaparecer/mudar
disabled sources	V2 readmitir Source desabilitada	migrar eligibility/disabled state explicitamente	SIM
collections	memberships não resolverem após canonicalization/source migration	manter chave legacy + mapping runtime	SIM quando coleção ativa perder item/source
Smart Feeds	contexto não poder ser reproduzido	preservar definição e dependências usadas pelo contexto	SIM se superfície continuar shipping
filtros persistidos	startup V2 mudar seleção silenciosamente	preservar tipos/defaults de AppSettings.swift:65-92 e mapear todos os campos usados	SIM se contexto efetivo mudar
busca persistente	query/scope persistido desaparecer no cutover	[INDETERMINADO — requer leitura de feedmine/Services/UserStateStore.swift]	SIM se existir estado durável shipping sem representação V2
source health / HTTP validators	refetch adicional ou cadence diferente	operacional/reconstruível salvo requisito contrário	NÃO, exceto se outra decisão tornar esse estado durável
published_card + exposure/history	compatibility alias virar publication FK/fact key	somente PublicationCardID alocado pela publication transaction	SIM para qualquer surface V2-owned
runtime DB inteiro	migration destrutiva impedir rollback/recovery	migrations append-only; sem erase-on-schema-change	SIM
O audit deve distinguir no mínimo:

mapped
unmapped-but-allocatable
unresolved
conflicted
durable-reference-at-risk
durable-reference-at-risk > 0 bloqueia o cutover da superfície afetada.

1.11 Rollback e ponto de não retorno
Até o primeiro cutover de uma superfície:

migração é aditiva;
chaves legacy permanecem;
V2 pode ser desligado sem converter dados de volta;
nenhum delete de user state é permitido.
Depois que uma superfície torna-se V2-owned, rollback continua suportado enquanto os dados e readers legacy exigidos pela compatibility window forem preservados.

A remoção de tabelas, readers, bridges ou dados legacy é uma decisão/release gate posterior. Ela é o primeiro ponto em que rollback pode deixar de ser trivial e não deve ser confundida com “migration complete”.

1.12 Pendências exclusivamente humanas
H1 — Freeze dos sete ADRs
Opções:

aprovar os sete conjuntamente;
rejeitar e registrar a decisão normativa ainda aberta.
Sem decisão: todos permanecem Proposed; trabalho aditivo e testes podem continuar, mas nenhuma decisão é tratada como congelada.

H2 — Quando Runtime V2 vira shipping default
Opções:

prepare-only e cutover posterior;
cutover no mesmo release condicionado ao migration audit;
rollout staged/feature-gated.
Sem decisão: shipping permanece legacy.

H3 — Duração da compatibility/rollback window
Opções:

número fixo de releases;
critério quantitativo explícito de estabilidade/migration coverage.
Sem decisão: manter bancos/readers/bridges legacy necessários; legacy removal permanece bloqueado.

H4 — Retenção de longo prazo de read/click/open/consume
Opções:

expirar junto ao conteúdo;
janela independente limitada;
retenção indefinida.
Sem decisão: preservar os fatos existentes; GC não pode descartá-los.

Essas são decisões humanas porque mudam política de produto/release ou a promessa de retenção. Não permanecem abertas:

catalog ID → runtime ID: não converter;
missing Source mapping: ensure/allocate;
identidade ambígua: não auto-merge;
GUID histórico ausente: não reconstruir;
user-state migration: não rekey destrutivo;
compatibility card alias → PublicationCardID: proibido;
durable reference unresolved → descarte: proibido.