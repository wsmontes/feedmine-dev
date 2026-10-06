# FeedMine Runtime V2 — Consolidação de Decisões, Conflitos e Backlog

**Base:** artefatos produzidos nos Rounds 1–5, reconciliados pelos fatos do checkout `70f7b06b`.  
**Regra de precedência:** fato de checkout > decisão normativa mais recente > decisão normativa anterior > hipótese de implementação.

# 1. REGISTRO DE DECISÕES

| ID | Decisão | Origem | Status | Bloqueio atual |
|---|---|---|---|---|
| **D-01** | `FeedDomain.SourceID` é alocado pelo runtime; nunca derivado de URL, digest ou `CatalogSourceID`. | Adendo A | **FECHADA** | Incorporar formalmente no ADR-003. |
| **D-02** | Para Source de catálogo: mapping ausente → `ensure/allocate`; só recusa se identidade durável não puder ser estabelecida ou estiver disputada. | Adendo A | **FECHADA** | Implementação + texto ADR-003. |
| **D-03** | Bootstrap de Sources existentes é híbrido: batch limitado por launch + lazy allocation on-demand. | Adendo A | **FECHADA** | Implementação. |
| **D-04** | Allocation de `source` + lookup + gravação do bridge constituem uma única operação transacional lógica. | Adendo A | **FECHADA** | Ajustar `SourceRegistry`/mapping path. |
| **D-05** | `canonicalization_version` versiona apenas o algoritmo de chave legacy; linhas antigas permanecem imutáveis e coexistem. | Adendo A | **FECHADA** | Testes de upgrade/ambiguidade. |
| **D-06** | `legacy_item_map` é a única ponte legacy item → Origin; missing mapping em caminho V2 é admitido/mapeado localmente antes de publicar. | Adendo C | **FECHADA** | Implementação do ensure local. |
| **D-07** | Itens históricos sem GUID persistido usam `legacy_item_id` como identidade opaca; nenhum GUID é reconstruído e nenhum merge heurístico ocorre. | Plano + Revisão | **FECHADA** | Backfill. |
| **D-08** | Estado durável legacy é preservado copy/bridge-first; bookmarks/imported sources/read-state não são rekeyed nem apagados durante coexistência. | Plano | **FECHADA** | Migration/audit. |
| **D-09** | `PublicationCardID` real pertence exclusivamente à publication transaction; bridge hash não é publication identity. | Adendo C | **FECHADA** | Incorporar ADR-001/007 + implementation. |
| **D-10** | O alias SHA-256 atual pode existir apenas como compatibility identity; deve ser tipicamente distinto de `PublicationCardID`. | Adendo C | **FECHADA** | Slice de separação de tipos. |
| **D-11** | Dentro da mesma Edition o `PublicationCardID` sobrevive a rerender/eviction/rematerialização; successor Edition pode remintar cards. | Adendo C | **FECHADA** | Publication/session path. |
| **D-12** | `legacy_item_map` missing não autoriza fallback identitário nem card sintético; falha de admission recusa o card no caminho V2. | Adendo C | **FECHADA** | Implementação. |
| **D-13** | PR-15 já está fechado no seu escopo de single acquisition owner/BGTask; não será reaberto para “resolver” card identity. | Adendo C + Gate | **FECHADA** | Nenhum. |
| **D-14** | Main Feed compatibility, Source detail, bookmarks, Smart Feed, collections e onboarding continuam congelados no caminho legacy até cutover integral da respectiva boundary. | Adendo C | **FECHADA** | Runtime replacement completo. |
| **D-15** | Gate 0 exige incorporar os adendos A/C e corrigir ambiguidades factuais de ADR-001/003/004/005/007 antes do freeze conjunto. | Revisão + Gate | **FECHADA** | DOC-G0 + verification. |
| **D-16** | Referência durável não resolvida nunca é descartada; qualquer caminho de perda de user data bloqueia cutover. | Plano + Gate | **FECHADA** | Audit com zero perda. |
| **D-17** | Release que ativa V2 por default é decisão de produto/release. | Plano | **PENDENTE-HUMANO** | Escolha de rollout. |
| **D-18** | Duração da janela em que rollback legacy permanece suportado é decisão humana. | Plano | **PENDENTE-HUMANO** | Política de release. |
| **D-19** | Retenção futura de read/click/consume além da vida de `feed_item` é decisão de produto/privacy/storage. | Adendo A/C + Plano | **PENDENTE-HUMANO** | Política de retenção. |

# 2. CONFLITOS INTERNOS

| # | Lado anterior | Lado posterior | Vence | Razão |
|---|---|---|---|---|
| **K1** | Round 1 tratou o Source bridge como estrutura ainda a ser criada e propôs `legacy_source_identity_map` genericamente. | Fatos posteriores mostraram `legacy_source_map` já existente; Adendo A o define como ponte canônica de **catalog Source**. | **Adendo A** | Não se cria uma segunda ponte para catálogo. Uma tabela adicional só é admissível para identidades legacy que não cabem no contrato do `legacy_source_map` — por exemplo imported sources — e somente após provar necessidade. |
| **K2** | Round 1 tratou `missingSourceMapping` como possível bloqueio de migration/cutover. | Adendo A decidiu `missing → ensure/allocate`; recusa apenas após falha/disputa do ensure. | **Adendo A** | Missing é estado incompleto, não erro identitário. |
| **K3** | Round 1 deixou “como tratar colisões/aliases de Source” como decisão humana. | Adendo A fixou: carry-forward apenas quando inequívoco; ambiguidade recusa associação automática. | **Adendo A** | Segurança de identidade é invariante arquitetural, não preferência de produto. |
| **K4** | Round 1 deixou unresolved durable references como escolha humana de cutover. | Gate 0 consolidou perda/unresolved user state como **BLOQUEADOR**. | **Gate 0** | Não descartar user data é requisito de correção, não opção de rollout. |
| **K5** | Round 1 colocou publication/card migration relativamente cedo (`PR-05`). | Adendo C mostrou que publication identity depende de canonical→publication→presentation e que PR-15 não a fecha; ownership passa para slices posteriores. | **Adendo C** | Um hash melhor não resolve ownership; primeiro é preciso Origin/migration e publication real. |
| **K6** | Round 1 poderia ser lido como criação de um novo runtime storage “sidecar”. | Fatos posteriores provam que `runtime-v2` schema/migrations/production/shadow DB já existem. | **Checkout + Gate** | O trabalho é bootstrap/composição/migration sobre o runtime DB existente, não criar uma arquitetura paralela. |
| **K7** | Round 4 marcou ADR-002/004/005/006 como “PODE CONGELAR”. | Round 5 exige freeze conjunto e correções documentais em 004/005, além das dependências anteriores. | **Gate 0** | “Sem contradição própria” não significa “Gate 0 completo”; o sign-off é conjunto. |
| **K8** | Round 4 disse ADR-007 não pode congelar porque shipping bridge ainda não possui publication identity. | Adendo C/Gate esclarecem que ADR-007 pode congelar **se** D3/D4 forem explicitamente limitados a cards realmente publicados; implementação pode vir depois. | **Gate 0** | Freeze aprova contrato futuro e coexistência, não exige que shipping esteja migrado. |
| **K9** | Round 1 sugeriu `PublicationCardID`/row V2 como destino direto da identidade de apresentação. | Adendo C exige primeiro separar compatibility identity de published identity. | **Adendo C** | Evita tratar alias truncado como FK/occurrence persistida. |
| **K10** | Round 1 permitia tratar reset destrutivo como opção humana futura. | ADR-004/Gate fixam ban de erase-on-schema-change e exigem rollback proof. | **Gate 0** | Para dados de produção existentes, destructive migration deixou de ser opção válida de implementação. |

# 3. BACKLOG PR-00..PR-n

**Ordem:** primeiro congela-se o contrato; depois torna-se runtime DB disponível sem mudar comportamento; então Sources → Origins → user state → novo ingress → audit; somente então troca-se card/publication ownership e, por último, shipping default.

| PR | Objetivo | Alvos | Pré-requisito | Teste de prova | Rollback | Esforço |
|---|---|---|---|---|---|---|
| **PR-00** | Fechar Gate 0 documental. | `docs/runtime-v2/adrs/ADR-001.md`, `003.md`, `004.md`, `005.md`, `007.md`, `baseline.md`, `rollout.md` | Nenhum | revisão documental + suite atual limpa | Revert documental. | **P** |
| **PR-01** | Fixar verification baseline reproduzível e stale-module hygiene. | suites `CatalogIdentityContractTests.swift`, `CardActionBoundaryTests.swift`, `BackgroundRefreshDemandTests.swift`, demais gate suites | PR-00 | execução limpa no HEAD assinado | Sem runtime change. | **P** |
| **PR-02** | Compor runtime DB/migrations em launch legacy sem habilitar UI/network V2. | `feedmine/feedmineApp.swift`, `feedmine/RuntimeV2/RuntimeCompositionRoot.swift`, `Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift` | PR-01 | `MigrationBootstrapTests.testLegacyLaunchCanPrepareRuntimeWithoutOwningUIOrNetwork` | Desligar coordinator; legacy DBs intocados. | **M** |
| **PR-03** | Implementar `ensureRuntimeSourceIdentity`, transaction allocation+bridge e bootstrap híbrido. | `SourceRegistry.swift`, `LegacyMappingStore.swift`, `EditorialIdentity.swift`, `V2Acquisition.swift`, `RuntimeMigrations.swift` | PR-02 | `RuntimeSourceRegistryConcurrencyTests.testConcurrentEnsureReturnsOneDurableSourceIdentity` | Ignorar runtime mappings; sem rekey legacy. | **M** |
| **PR-04** | Backfill `feed_item` → Origin + `legacy_item_map`, sem merge heurístico. | `FeedStore.swift`, `LegacyMappingStore.swift`, runtime Origin storage/migrations | PR-03 | `LegacyItemMigrationTests.testBackfillIsIdempotentAndNeverMergesDistinctLegacyItemIDs` | Legacy continua autoridade; runtime rows podem ser reconstruídas. | **G** |
| **PR-05** | Capturar/bridgear bookmarks, snapshots, read/click/consume, imported sources e filtros. | `BookmarkStore.swift`, `UserStateStore.swift`, `FeedStore.swift`, `AppSettings.swift`, `RuntimeMigrations.swift` | PR-04 | `LegacyStateMigrationTests.testDurableUserStateSurvivesMigrationAndLegacyRollback` | Copy-only; remover leitura V2, nunca apagar legacy. | **G** |
| **PR-06** | Preservar GUID/link cru no novo ingress V2 antes do hashing legacy. | `RSSFetcher.swift`, `V2Acquisition.swift`, shadow/admission bridge | PR-04 | `SyndicationIdentityMigrationTests.testRawExternalKeyReachesAdmissionBeforeLegacyHashing` | Desligar shadow/admission; fetch legacy igual. | **M** |
| **PR-07** | Criar migration audit e bloquear cutover em conflicts/unresolved durable refs. | runtime diagnostics/checkpoint + migration tests | PR-03…06 | `MigrationAuditTests.testCutoverFailsWhenAnyDurableReferenceWouldBeLost` | Observabilidade apenas. | **M** |
| **PR-08** | Separar identity type de compatibility card e `PublicationCardID`. | `MainFeedCardBridge.swift`, `MainFeedPresentationPipeline.swift`, card presentation types | PR-04 + PR-00 | `CardIdentityBoundaryTests.testLegacyAliasCannotBeUsedAsPublicationCardID` | Feature path off; legacy identity intacta. | **M** |
| **PR-09** | Runtime publication real → presentation/actions/exposure usando persisted card IDs. | `PublicationRepository.swift`, `MainFeedPresentationPipeline.swift`, `CardActionBridge.swift`, `V2FullRuntime.swift` | PR-07 + PR-08 | `RuntimePresentationTests.testPublishedCardUsesPersistedPublicationCardIDWithoutLegacyHashing` | Desativar V2 presentation; preservar edition/runtime DB para diagnóstico. | **G** |
| **PR-10** | Controlled V2 cutover com audit e rollback flag. | `RuntimeMode.swift`, `RuntimeCompositionRoot.swift`, `MainFeedRuntime.swift`, `feedmineApp.swift` | PR-09 + decisão D-17 | `ReleaseUpgradeTests.testV2CutoverAndLegacyRollbackPreserveUserState` | Voltar default `.legacy`; bancos legacy ainda presentes. | **G** |
| **PR-11** | Remover caminhos/storage legacy somente após janela acordada. | Legacy FeedStore/RSS/presentation paths conforme inventory final | PR-10 + D-18 + telemetry/audit | migration matrix + clean-install/upgrade/rollback tests finais | Depois da remoção de dados legacy, rollback deixa de ser trivial; exige release gate próprio. | **G** |

**PR-15 do `rollout.md` não é renumerado nem reaberto:** é trabalho histórico já landed; o backlog acima usa numeração lógica da migração consolidada.

# 4. O QUE NÃO EXIGE HUMANO

Um agente com acesso ao repo pode executar hoje, nesta ordem:

1. **Incorporar Adendo A no contrato de identidade.**  
   Arquivo: `docs/runtime-v2/adrs/ADR-003.md`.  
   Resultado observável: D2/D18 passam a definir allocation event, bootstrap híbrido, atomic ensure e `missing → allocate`.

2. **Incorporar Adendo C nas boundaries de publication/exposure.**  
   Arquivos: `docs/runtime-v2/adrs/ADR-001.md`, `ADR-007.md`.  
   Resultado: bridge alias deixa de poder ser interpretado normativamente como `PublicationCardID`.

3. **Corrigir autoridade/coexistência.**  
   Arquivos: `ADR-004.md`, `ADR-005.md`.  
   Resultado: bookmarks autoritativos = `user.sqlite`; audio probing legacy explicitamente fora do connector V2 contract.

4. **Sincronizar documentos factuais.**  
   Arquivos: `docs/runtime-v2/baseline.md`, `docs/runtime-v2/rollout.md`.  
   Resultado: nenhuma decisão já fechada continua marcada como “open”; nenhuma implementação futura aparece como “landed”.

5. **Adicionar testes de contrato antes de mudar comportamento.**  
   Arquivos: `feedmineTests/CatalogIdentityContractTests.swift`, `CardActionBoundaryTests.swift`, `BackgroundRefreshDemandTests.swift`.  
   Resultado: catalog ID nunca converte para runtime ID; bridge alias nunca é accepted como publication row; acquisition continua single-owner.

6. **Adicionar migrations estritamente aditivas necessárias ao migration bookkeeping.**  
   Arquivo: `Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift`.  
   Resultado: runtime DB atualizado sem alterar `feedmine.sqlite`/`user.sqlite` PKs e sem erase.

7. **Tornar source ensure transacional e concorrente-safe.**  
   - Arquivos: `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/SourceRegistry.swift`, `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/LegacyMappingStore.swift`, `Packages/FeedRuntimeV2/Sources/FeedDomain/Identity/EditorialIdentity.swift`.
   Resultado: N callers concorrentes recebem um único `SourceID` + mapping durável ou todos observam falha tipada.

8. **Implementar bootstrap bounded sem ativar V2 UI/network.**  
   Arquivos: `feedmine/RuntimeV2/RuntimeCompositionRoot.swift`, `feedmine/feedmineApp.swift` e, se criado, `feedmine/RuntimeV2/LegacyMigrationCoordinator.swift`.  
   Resultado: launch legacy pode criar/migrar runtime DB e continuar apresentando/adquirindo exatamente pelo caminho legacy.

9. **Instrumentar migration coverage.**  
   Arquivos: runtime migration/diagnostics + tests.  
   Resultado observável: contadores de mapped/unmapped/conflicted Sources, items, bookmarks, read-state, imported sources e filters.

10. **Construir backfills copy-only e testes**, sem ligar cutover.  
    Arquivos: `FeedStore.swift`, `BookmarkStore.swift`, `UserStateStore.swift`, `LegacyMappingStore.swift`.  
    Resultado: runtime ganha cópias/mappings; remoção do runtime DB ainda deixa a instalação legacy íntegra.

Nenhum desses passos requer decisão de produto porque não muda o default shipping nem elimina dados/caminhos antigos.

# 5. O QUE SÓ UM HUMANO DECIDE

## H1 — Quando V2 vira default

**Opções**

- **A — Prepare-only:** release executa migration/backfill, mas continua `.legacy`.  
  **Consequência:** menor risco; exige release posterior para cutover.
- **B — Mesmo release, audit-gated:** habilita V2 somente após migration audit local verde.  
  **Consequência:** chegada mais rápida, rollback precisa estar comprovado no mesmo build.
- **C — Rollout staged em release posterior/flag.**  
  **Consequência:** maior controle operacional; coexistência dura mais.

**Bloqueia:** PR-10, não PR-00…09.

## H2 — Janela oficial de rollback legacy

- **A — 1 release público completo.**
- **B — 2 releases.**
- **C — até critério quantitativo de estabilidade/migração.**

**Consequência:** determina quando PR-11 pode começar e por quanto tempo custo de coexistência é aceito.

## H3 — Retenção de read/click/consume no V2

- **A — acompanha retenção do conteúdo.** Menor storage; histórico desaparece com o content lifecycle.
- **B — janela fixa independente.** Preserva comportamento recente com custo controlável.
- **C — histórico indefinido.** Melhor continuidade, maior custo/privacy/GC obligation.

**Consequência:** define schema/GC final; não impede copiar o estado legacy atual.

## H4 — `What's New`

- **A — reconstruir como surface runtime.**
- **B — retirar definitivamente do produto.**

**Consequência:** cria ou elimina um futuro FeedPlan/UI path. O fato de `ContextKey.Surface.whatsNew` existir não decide o produto. **Não bloqueia Gate 0 nem a migração principal.**

## H5 — Agrupamento temporal do feed runtime

- **A — preservar seções por dia/período equivalentes ao produto atual.**
- **B — feed runtime contínuo sem headers temporais.**
- **C — nova política de agrupamento a especificar.**

**Consequência:** afeta presentation/product semantics, mas não Source/Origin/Publication identity. **Não deve ser decidido implicitamente por implementação.**