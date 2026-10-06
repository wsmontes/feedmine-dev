# 1. PROMPT DE CONTINUIDADE

Você está retomando o trabalho de arquitetura/migração do **FeedMine Runtime V2**. Trabalhe a partir do checkout real; fatos do repositório vencem qualquer documento anterior.

**Estado atual em 5 linhas**
1. Os sete ADRs existem em `docs/runtime-v2/adrs/ADR-001.md` … `ADR-007.md` e continuam com status **“Proposed — freeze pending sign-off (Gate 0 not complete)”**.
2. A identidade runtime de Source está decidida: `FeedDomain.SourceID` é alocado pelo runtime; `CatalogSourceID` nunca é convertido/derivado; missing mapping deve executar `ensure/allocate`.
3. A identidade de card está decidida: compatibility aliases derivados de `FeedItem.id` **não são** `PublicationCardID`; somente publication persistida aloca esse ID.
4. A falsificação do Round 8 derrubou todos os BLOQUEADORES originalmente encontrados no Round 4; restaram apenas correção documental e verificações não bloqueadoras.
5. Nenhum freeze foi autorizado ainda; mudanças devem continuar aditivas, rollback-safe e sem trocar shipping default para V2.

**Artefatos normativos produzidos nesta sequência**
- `Plano normativo de migração` — Round 1.
- `ADR-003 — Adendo A: identidade de runtime do Source` — Round 2.
- `ADR-003 — Adendo C: identidade de card / publication` — Round 3.
- `Revisão adversarial dos sete ADRs contra o checkout real` — Round 4.
- `FeedMine Runtime V2 — Gate 0 Freeze Checklist` — Round 5.
- `FeedMine Runtime V2 — Consolidação de Decisões, Conflitos e Backlog` — Round 6.
- `§17. Plano de migração normativo (anexo)` para `ADR-003.md` — Round 7.
- `Round 8 — Falsificação da revisão adversarial` — Round 8.

**Decisão aberta**
A decisão humana imediata é **aprovar ou não o Gate 0 e congelar conjuntamente os sete ADRs**. Até essa aprovação, não altere o Status para Accepted/Frozen e não faça cutover de runtime.

**Primeira coisa a fazer**
Abra `docs/runtime-v2/adrs/ADR-003.md`, incorpore o §17 e as correções de Source identity compatíveis com o Adendo A; depois faça o PR-00 documental/schema-only descrito abaixo. Não implemente UI cutover, publication ownership ou V2-owned network no PR-00.

---

# 2. CHECKLIST DE PR-00 PARA UM AGENTE COM ACESSO AO REPO

**Escopo de PR-00:** fechar a documentação necessária ao Gate 0 e introduzir somente schema/migrations **aditivas** de bridge. Nenhuma surface muda de owner; shipping continua legacy.

| # | Arquivo | Edição | Verificação | Condição de parada |
|---:|---|---|---|---|
| 1 | `docs/runtime-v2/adrs/ADR-003.md` | Inserir `§17. Plano de migração normativo (anexo)` com M1–M8, slices, data-loss matrix, rollback e pendências humanas. | `git diff --check -- docs/runtime-v2/adrs/ADR-003.md` | Pare se a §16 existente tiver semântica incompatível com o anexo; não “harmonize” silenciosamente. |
| 2 | `docs/runtime-v2/adrs/ADR-003.md` | Corrigir D2/D18 para que catalog ID seja alias persistido e **missing mapping execute ensure/allocation**, não cast/URL derivation. | `git grep -nE 'SourceID.*(UInt32|stableUInt32Digest|normalizeURL)|missingSourceMapping' docs/runtime-v2/adrs/ADR-003.md` + revisão manual dos matches | Pare se houver duas regras normativas diferentes para missing mapping. |
| 3 | `docs/runtime-v2/adrs/ADR-001.md` e `ADR-007.md` | Tornar explícito que bridge/legacy card identity não é `PublicationCardID`; D2/D3 aplicam-se a ocorrências realmente publicadas. | `git grep -n 'PublicationCardID' docs/runtime-v2/adrs/ADR-001.md docs/runtime-v2/adrs/ADR-007.md` | Pare se qualquer texto permitir hash/legacy item id como publication identity. |
| 4 | `docs/runtime-v2/adrs/ADR-004.md` | Declarar `user.sqlite` como autoridade de bookmarks durante coexistência; tabelas homônimas legacy não recuperam autoridade. | `git grep -nE 'bookmark|user.sqlite|feedmine.sqlite' docs/runtime-v2/adrs/ADR-004.md` | Pare se duas databases forem declaradas simultaneamente authoritative para o mesmo bookmark fact. |
| 5 | `docs/runtime-v2/adrs/ADR-005.md` | Delimitar “media speculation is not acquisition” ao contrato Runtime V2; probing existente em legacy é coexistência, não exceção permanente. | `git grep -nE 'Media speculation|prob|legacy|coexist' docs/runtime-v2/adrs/ADR-005.md` | Pare se o texto legitimar media probing dentro do connector V2. |
| 6 | `docs/runtime-v2/baseline.md` e `docs/runtime-v2/rollout.md` | Sincronizar fatos: remover “open” somente onde a decisão normativa foi fechada; manter implementação futura como não-landed. | `git diff --check -- docs/runtime-v2/baseline.md docs/runtime-v2/rollout.md` | Pare se uma edição transformar uma decisão em alegação de implementação sem prova. |
| 7 | `Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift` | Adicionar/confirmar migration aditiva de `legacy_source_map` com `(catalog_source_key, canonicalization_version)` como chave, `catalog_source_id > 0`, `runtime_source_id` FK/positivo, `legacy_url`, `mapped_at`. Não dropar/rekey nenhuma tabela. | `swift test --package-path Packages/FeedRuntimeV2 --filter FeedStorageTests` | Pare se a migration precisar apagar/recriar dados existentes, renumerar Source IDs ou tocar PK legacy. |
| 8 | `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceMapMigrationTests.swift` *(criar se não existir)* | Criar teste de migration repetida: aplicar migrations duas vezes ao mesmo DB e provar schema/dados idênticos e mapping preservado. Teste nomeado: `testLegacySourceMapMigrationIsIdempotent`. | `swift test --package-path Packages/FeedRuntimeV2 --filter LegacySourceMapMigrationTests/testLegacySourceMapMigrationIsIdempotent` | Pare se a segunda execução criar row adicional, mudar `runtime_source_id` ou falhar por estado já migrado. |
| 9 | Mesmo teste | Provar que duas canonicalization versions podem coexistir e que versão antiga não é sobrescrita. Teste: `testLegacySourceMapPreservesPreviousCanonicalizationVersion`. | `swift test --package-path Packages/FeedRuntimeV2 --filter LegacySourceMapMigrationTests/testLegacySourceMapPreservesPreviousCanonicalizationVersion` | Pare se upgrade fizer `UPDATE` destrutivo do mapping anterior. |
| 10 | Testes de storage existentes | Provar que `0` e valores inválidos não entram como runtime local IDs e que catalog `UInt32` não é aceito implicitamente como runtime Source. | `swift test --package-path Packages/FeedRuntimeV2 --filter FeedStorageTests` | Pare em qualquer truncating/widening conversion que transforme catalog ID diretamente em runtime ID. |
| 11 | `feedmineTests/CatalogIdentityContractTests.swift` | Manter os contratos legacy de URL normalization intactos; PR-00 não deve mudar comportamento de catálogo/fetch. | `xcodebuild test -only-testing:feedmineTests/CatalogIdentityContractTests` usando o mesmo project/workspace, scheme e destination já adotados pelo repo | Pare se o único modo de passar for alterar canonicalização legacy. |
| 12 | `feedmineTests/CardActionBoundaryTests.swift` e/ou teste boundary equivalente | Fixar por teste que compatibility card identifier não satisfaz API que requer `PublicationCardID`. | `xcodebuild test -only-testing:feedmineTests/CardActionBoundaryTests` usando a configuração de teste existente do repo | Pare se corrigir o teste exigir gerar “publication ID” por hash. |
| 13 | `feedmineTests/BackgroundRefreshDemandTests.swift` | Garantir que PR-00 não reabre segunda árvore de acquisition/background work. | `xcodebuild test -only-testing:feedmineTests/BackgroundRefreshDemandTests` usando a configuração existente do repo | Pare se o PR introduzir network/runtime ownership novo. |
| 14 | Todo PR | Confirmar que só houve docs, schema aditivo e testes; nenhuma ativação V2. | `git diff --stat && git diff --check && git status --short` | Pare se aparecer remoção/rekey de `feedmine.sqlite`/`user.sqlite`, mudança do shipping default, UI cutover ou novo acquisition owner. |
| 15 | Status dos sete ADRs | **Não** trocar Status durante a implementação do PR. | **PARADA: HUMANO** | Gate 0 precisa de sign-off humano conjunto. Só depois disso o status pode ser alterado conforme a convenção escolhida pelo repositório. |

### Definition of Done do PR-00

PR-00 pode ser submetido quando:

- `legacy_source_map` é schema aditivo e migration-idempotent;
- nenhuma identity runtime é derivada/cast do catalog ID;
- Adendos A/C estão refletidos nos ADRs relevantes;
- nenhum dado legacy é rekeyed ou apagado;
- testes de package e app relevantes estão verdes;
- shipping continua `.legacy`;
- os sete ADRs continuam **Proposed** até sign-off humano.

---

# 3. AS DECISÕES HUMANAS COM RECOMENDAÇÃO

## H1 — Gate 0 deve ser aprovado agora?

**Pergunta fechada:** com PR-00 verde e as correções normativas incorporadas, os sete ADRs podem ser congelados como conjunto?

**Opções**
- **A. APROVAR:** congelar os sete ADRs e exigir amendment explícito para mudança semântica posterior.
- **B. REJEITAR:** manter todos Proposed e registrar qual decisão normativa específica ainda não está fechada.

**Recomendação:** **A**, desde que PR-00 prove as migrations aditivas e não reste contradição normativa; Round 8 eliminou os bloqueadores da revisão anterior.

**Sem decisão:** status permanece **Proposed**; agente pode adicionar testes/instrumentação/migrations reversíveis, mas não declara freeze nem faz cutover.

---

## H2 — Quando V2 vira shipping default?

**Opções**
- **A. Prepare-only:** migrar/backfill primeiro; default continua legacy.
- **B. Cutover no mesmo release após audit local verde.**
- **C. Rollout staged/feature-gated em release posterior.**

**Recomendação:** **C** — separa correctness da migração do risco de product/runtime cutover e preserva rollback observável.

**Sem decisão:** agente segue **A**; tudo é preparado, nada ativa V2 por default.

---

## H3 — Quanto tempo o rollback legacy permanece suportado?

**Opções**
- **A. Uma release pública completa.**
- **B. Duas releases.**
- **C. Até critério quantitativo explícito de migration/runtime stability.**

**Recomendação:** **C**, com mínimo prático de uma release completa; remover legacy por calendário apenas é menos seguro que remover após evidência.

**Sem decisão:** legacy storage/read paths não são removidos. PR de deletion/cleanup fica bloqueado.

---

## H4 — Qual retenção de `read/click/open/consume` após content eviction?

**Opções**
- **A. Expira junto com o conteúdo.**
- **B. Janela independente e limitada.**
- **C. Retenção indefinida.**

**Recomendação:** **B** — preserva continuidade comportamental sem tornar interaction history permanentemente crescente.

**Sem decisão:** agente pode migrar/copiar os fatos existentes, mas **não** implementar GC que os descarte.

---

## H5 — O produto mantém `What's New` como surface V2?

**Opções**
- **A. Sim:** implementar um FeedPlan/surface próprio.
- **B. Não:** remover do roadmap/runtime V2.

**Recomendação:** **B**, salvo requisito real de produto; não introduzir surface sem usuário/caso de uso confirmado.

**Sem decisão:** não implementar nem remover contratos existentes; fica fora do critical path de release.

---

## H6 — O feed V2 preserva agrupamento temporal visível?

**Opções**
- **A. Preservar comportamento equivalente ao produto atual.**
- **B. Feed contínuo sem agrupamento temporal.**
- **C. Definir nova política posteriormente.**

**Recomendação:** **A** para o primeiro cutover — minimizar mudança simultânea de arquitetura e UX facilita comparação/rollback.

**Sem decisão:** preservar comportamento visual atual; não usar migration/runtime rewrite para redesenhar a experiência.

---

## Regra default para qualquer decisão humana ainda aberta

Na ausência de decisão explícita, o agente escolhe sempre o caminho **mais aditivo, reversível e compatível com legacy**:

`documentar → migrar/copy → medir → auditar → manter legacy owner`

e nunca:

`assumir → rekey → apagar → ativar V2`.