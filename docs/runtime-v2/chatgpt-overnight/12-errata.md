> **AVISO (auditoria local, 2026-10-05):** as âncoras declaradas "verbatim" neste arquivo **não** coincidem exatamente com o texto dos arquivos-alvo (verificação linha a linha reprovou 3 de 6). As correções foram reemitidas com âncoras exatas em `16-substituicoes.md` e **já estão aplicadas** em `01-plano-de-migracao.md`, `02-identidade-source-runtime.md` e `07b-anexo-corrigido.md`. Este arquivo fica como histórico dos vereditos, não como instrução de edição.

START]]

# Round 12 — Errata contra revisão independente

## 1. Veredito para cada achado

| # | Achado da revisão independente | Veredito | Motivo factual |
|---:|---|---|---|
| 1 | Round 4 R1 tratou ADR-001 D2 × bridge legacy como contradição/BLOQUEADOR. | **ACEITO** | D2 governa occurrence publicada; `MainFeedCardBridge` é compatibility debt. O fato atual não contradiz a decisão normativa. |
| 2 | R1 citou `MainFeedCardBridge.swift:206-224`; função está em `:234-245`, chamada em `:188`. | **ACEITO** | A referência estava errada; a substância “há alias determinístico” permanece verdadeira. |
| 3 | R2/R9 citaram `FeedScreen.swift:1233,1348` e inferiram contradição de restore. | **ACEITO** | As linhas estavam erradas e ADR-001/007 descrevem o modelo runtime, não afirmam que o restore legacy atual já o implementa. |
| 4 | R3 chamou missing Source allocation de contradição/BLOQUEADOR. | **ACEITO** | ADR-003 D2 explicitamente dizia lookup persistido que falha se não houver mapping. Era lacuna/política a melhorar, não contradição do ADR. |
| 5 | R4 leu D18 como proibição global das identidades legacy URL-based. | **ACEITO** | ADR-003 é sobre a boundary Runtime V2; coexistência dentro do legacy não viola D18. |
| 6 | R5 tratou perda histórica de GUID como contradição de D10. | **ACEITO** | D10 governa tratamento de external identity pelo Runtime V2; GUID já perdido é limitação de migração. |
| 7 | R6 disse que ADR-004 ainda precisava declarar `user.sqlite` autoridade de bookmarks. | **ACEITO** | ADR-004 D1 já diz literalmente `user.sqlite` = bookmarks/bookmark lists/etc.; `feedmine.sqlite` = legacy content cache/read-click columns (`ADR-004.md:17-24`). |
| 8 | R7 disse que ADR-005 D17 conflita com probing do `RSSFetcher`. | **ACEITO** | D17 já cita o probing legacy e diz que a connector boundary **MUST NOT inherit it** (`ADR-005.md:80`). |
| 9 | R8 chamou bridge alias × ADR-007 D3 de BLOQUEADOR. | **ACEITO** | D3 especifica exposure do runtime por `PublicationCardID`; alias compatibility é dívida de implementação, não contradição normativa. |
| 10 | R9 disse que ADR-007 D4 alegava persisted restore resolvido. | **ACEITO** | D4 é explicitamente eviction/re-materialization **na mesma edition** (`ADR-007.md:28`). |
| 11 | R11/P0.x/A7 trataram `PublicationRepository.swift:948` como allocation de card. | **ACEITO** | O insert do card está em `:1009-1041`; `PublicationCardID(db.lastInsertedRowID)` está em `:1042`. `performCommit` começa em `:903`. |
| 12 | Round 8 refutou R1-R5, R7-R9. | **ACEITO** | Essa falsificação é consistente com a leitura direta dos ADRs acima. |
| 13 | Round 8 deixou R11 INDETERMINADO. | **ACEITO** | Foi erro meu: o repo era verificável. O resultado correto é **CONFIRMADO como erro de traceability**, não indeterminado e não bloqueador arquitetural. |
| 14 | Gate 0 P0.4/P0.7/P0.8 propagou `PublicationRepository.swift:948`. | **ACEITO** | Todas essas referências devem apontar para `:1009-1042`, especificamente allocation em `:1042`. |
| 15 | Round 5 e Round 6 usaram numerações incompatíveis de PR. | **ACEITO** | Round 5 chamou bootstrap de PR-00; Round 6 redefiniu PR-00 como Gate/documentação. São identificadores incompatíveis. A consolidação posterior vence. |
| 16 | Round 6 PR-02 usou `feedmine/RuntimeV2/RuntimeMigrations.swift`. | **ACEITO** | Path real: `Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift`. |
| 17 | Round 6 PR-05 usou `feedmine/Models/AppSettings.swift`. | **ACEITO** | Path real: `feedmine/Services/AppSettings.swift`. |
| 18 | Round 10 afirmou “ADR-003: nenhum teste AUSENTE”. | **PARCIAL** | A afirmação foi factual e claramente errada como **auditoria literal de nomes**: 21/22 identificadores citados não existem literalmente. Isso não prova que 21 comportamentos estejam sem teste, pois o próprio ADR aponta mapping/contract-matrix e nomes podem divergir. |
| 19 | Round 10 afirmou “0 casos (c)”. | **PARCIAL** | O absoluto estava errado: `unknownFutureSchemaFailsControlled` possui cobertura semântica parcial em `MigrationTests.swift:232` sob outro nome. Ainda é necessário comparar a asserção completa antes de declarar o criterion totalmente coberto. |
| 20 | Round 1 disse que normalization “remove porta”. | **ACEITO** | `OPMLParser.swift:719-723` remove somente portas default; porta não-default permanece. |
| 21 | Round 1/7 disseram que “§16 do ADR-003 delegava a migração”. | **ACEITO** | ADR-003 não possui §16. A única menção é a **plan §16** na traceability, e essa seção do plano é SLO/observability/rollout, não delegação do plano migratório. |
| 22 | Round 1 M5 disse que tipos/encoding dos `filter*` não estavam disponíveis. | **ACEITO** | `AppSettings.swift:65-92` explicita `String?`, `[String]`, `String`, `Bool` e `TimeInterval`. |
| 23 | Round 2 A7 citou allocation em `PublicationRepository.swift:948`. | **ACEITO** | Allocation real em `:1042`; decisão (“ID nasce na transaction de publication”) continua correta. |
| 24 | Round 7 intitulou o conteúdo como “§17” que substitui delegação de uma §16 inexistente. | **ACEITO** | A premissa estrutural era falsa. O conteúdo pode continuar como anexo normativo, mas não como sucessor/substituto de “§16 do ADR”. |
| 25 | Outras citações de linha: collision `SQLiteCatalogStore :186-196`, bridge `:206-224`. | **ACEITO** | Collision está em `SQLiteCatalogStore.swift:216-217`; bridge card ID em `MainFeedCardBridge.swift:234-245`, chamada `:188`. São erratas de evidência, não mudanças normativas. |

Não há achado da revisão independente que eu consiga **REJEITAR** com os fatos disponíveis.

---

# 2. Errata normativa pronta para colar

## Correção 01-A — documento que contém o handoff de migração

- **ARQUIVO:** `01-plano-de-migracao.md`
- **ÂNCORA:** `migração delegada pela §16 do ADR-003`
- **SUBSTITUIR POR:** `migração requerida pelo handoff do plano revisado em docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md, especialmente §5/§5.1–§5.2, e pelas obrigações de bridge de ADR-003 D18`
- **MOTIVO:** ADR-003 não possui §16; atribuir a delegação a essa seção é factual e estruturalmente falso.

## Correção 01-B — normalização de porta

- **ARQUIVO:** `01-plano-de-migracao.md`
- **ÂNCORA:** `remove www, porta e trailing slash`
- **SUBSTITUIR POR:** `remove www e trailing slash; omite apenas portas default (HTTP 80 / HTTPS 443) e preserva portas não-default`
- **MOTIVO:** `OPMLParser.swift:719-723` preserva uma porta quando ela não é a default do scheme.

## Correção 01-C — tipos dos filtros

- **ARQUIVO:** `01-plano-de-migracao.md`
- **ÂNCORA:** `não há tipo/encoding de cada filter*; isso impede qualquer tradução de formato`
- **SUBSTITUIR POR:** `os tipos persistidos dos filtros são conhecidos em AppSettings.swift:65-92: filterRegion = String?, filterTaxonomyNodes/filterLanguages = [String], filterContentType/filterMood = String, filterAutoExpire = Bool e filterSetAt = TimeInterval; qualquer migração deve preservar esses tipos e defaults`
- **MOTIVO:** o checkout já fornece o contrato de tipos que o artefato declarou ausente.

## Correção 02-A — allocation de `PublicationCardID`

- **ARQUIVO:** `02-identidade-source-runtime.md`
- **ÂNCORA:** `PublicationCardID nasce na transaction de publicação em PublicationRepository.performCommit, PublicationRepository.swift:948`
- **SUBSTITUIR POR:** `PublicationCardID nasce na transaction de publicação em PublicationRepository.performCommit (início em PublicationRepository.swift:903); o published_card é inserido em :1009-1041 e o ID é criado de db.lastInsertedRowID em :1042.`
- **MOTIVO:** `:948` não é o ponto de allocation.

## Correção 07-A — título do anexo

- **ARQUIVO:** `07-anexo-section16.md`
- **ÂNCORA:** `## §17. Plano de migração normativo (anexo)`
- **SUBSTITUIR POR:** `## Normative migration plan (appendix)`
- **MOTIVO:** o ADR não possui seções numeradas §16/§17; criar “§17” perpetua uma estrutura inexistente.

## Correção 07-B — objeto do anexo

- **ARQUIVO:** `07-anexo-section16.md`
- **ÂNCORA:** `Esta seção é o plano normativo de migração delegado pela §16.`
- **SUBSTITUIR POR:** `Este anexo incorpora no ADR-003 o handoff de migração requerido pelo plano revisado e pelas decisões de coexistência/legacy bridge de D18; ele não substitui nenhuma seção numerada do ADR.`
- **MOTIVO:** não existe §16 em ADR-003 e a menção a `plan §16` do arquivo trata de outro assunto.

## Correção 07-C — edição que pressupunha §16

- **ARQUIVO:** `07-anexo-section16.md`
- **ÂNCORA:** `## Edição 2 — remover da §16 a afirmação de que o plano detalhado ainda está ausente`
- **SUBSTITUIR POR:** `## Edição 2 — nenhuma edição de “§16” é aplicável. Inserir o anexo antes de ## Traceability e manter intactas as referências existentes ao plan §16, pois elas tratam de renderer network/SLO-rollout e não do plano de migração.`
- **MOTIVO:** a âncora proposta não existe no ADR.

## Correção 04-A — R6

- **ARQUIVO:** `04-revisao-adversarial-adrs.md`
- **ÂNCORA:** `## R6 — A autoridade de bookmarks precisa excluir explicitamente as tabelas antigas de feedmine.sqlite`
- **SUBSTITUIR POR:** `## R6 — REFUTADO. ADR-004 D1 já fixa user.sqlite como autoridade de bookmarks, bookmark lists, collections, durable history, aliases e bookmark snapshots, enquanto feedmine.sqlite é explicitamente legacy content cache/read-click state. A coexistência de tabelas antigas não cria segunda autoridade.`
- **MOTIVO:** `ADR-004.md:17-24` já contém a distinção que R6 disse faltar.

## Correção 04-B — R11

- **ARQUIVO:** `04-revisao-adversarial-adrs.md`
- **ÂNCORA:** `## R11 — Referência de allocation de PublicationRepository precisa ser auditada`
- **SUBSTITUIR POR:** `## R11 — CORREÇÃO DE TRACEABILITY. rollout.md mantém referências obsoletas (:94 e :948); no checkout auditado performCommit começa em PublicationRepository.swift:903, o INSERT de published_card ocupa :1009-1041 e PublicationCardID(db.lastInsertedRowID) está em :1042. Não há defeito normativo de allocation demonstrado.`
- **MOTIVO:** a revisão acertou que havia line drift, mas errou ao apresentar `:948` como linha real.

## Correção 08-A — R6

- **ARQUIVO:** `08-falsificacao-defeitos.md`
- **ÂNCORA:** `| **R6** | **INDETERMINADO** |`
- **SUBSTITUIR POR:** `| **R6** | **REFUTADO** | ADR-004 D1 já nomeia user.sqlite como autoridade de bookmarks e feedmine.sqlite como legacy content cache/read-click state; a existência das tabelas antigas não demonstra autoridade dupla. | **NOTA** |`
- **MOTIVO:** o texto necessário para resolver a dúvida estava no próprio ADR.

## Correção 08-B — R11

- **ARQUIVO:** `08-falsificacao-defeitos.md`
- **ÂNCORA:** `| **R11** | **INDETERMINADO** |`
- **SUBSTITUIR POR:** `| **R11** | **CONFIRMADO** | Há referências de linha obsoletas em rollout.md, mas a allocation real é PublicationRepository.swift:1042 dentro de performCommit (:903+); é defeito de traceability, não de arquitetura. | **CORREÇÃO** |`
- **MOTIVO:** o repo permite resolver o fato; não era indeterminado.

## Correção 05-A — linha de allocation no Gate 0

- **ARQUIVO:** `05-checklist-gate0.md`
- **ÂNCORA:** `PublicationRepository.swift:948`
- **SUBSTITUIR POR:** `PublicationRepository.swift:1009-1042 (allocation de PublicationCardID em :1042)`
- **MOTIVO:** corrigir P0.4, P0.7, P0.8 e qualquer ocorrência equivalente no §2.

## Correção 05-B — numeração de PR

- **ARQUIVO:** `05-checklist-gate0.md`
- **ÂNCORA:** `| **PR-00** | Bootstrap de runtime/migration coordinator em launch legacy; migrations V2 podem existir sem ligar UI/network V2.`
- **SUBSTITUIR POR:** `| **Slice bootstrap** | Bootstrap de runtime/migration coordinator em launch legacy; a numeração autoritativa de PR é a do backlog consolidado posterior, não esta tabela.`
- **MOTIVO:** evita dois artefatos atribuírem `PR-00` a trabalhos diferentes.

## Correção 06-A — path de migrations

- **ARQUIVO:** `06-registro-backlog.md`
- **ÂNCORA:** `feedmine/RuntimeV2/RuntimeMigrations.swift`
- **SUBSTITUIR POR:** `Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift`
- **MOTIVO:** o primeiro path não existe.

## Correção 06-B — path de AppSettings

- **ARQUIVO:** `06-registro-backlog.md`
- **ÂNCORA:** `feedmine/Models/AppSettings.swift`
- **SUBSTITUIR POR:** `feedmine/Services/AppSettings.swift`
- **MOTIVO:** esse é o path real.

## Correção 10-A — ADR-003 na auditoria literal

- **ARQUIVO:** `10-lacuna-testes.md`
- **ÂNCORA:** `| **ADR-003** | — | Nenhum teste AUSENTE reportado pela auditoria. | **Sem lacuna ausente nesta auditoria.** |`
- **SUBSTITUIR POR:** `| **ADR-003** | 21 dos 22 identificadores citados não resolvem como nomes literais de teste na auditoria independente | O ADR afirma que os critérios estão implemented/pinned, mas também declara mapping por contract-matrix/baseline | **TRACEABILITY A AUDITAR** — ausência literal do nome não prova ausência semântica do teste; mapear cada criterion para o XCTest real antes de afirmar cobertura ou bloqueio. |`
- **MOTIVO:** meu inventário estava incompleto e confundia auditoria de identificador com auditoria de comportamento.

## Correção 10-B — categoria (c)

- **ARQUIVO:** `10-lacuna-testes.md`
- **ÂNCORA:** `- **0 testes (c):** a auditoria fornecida não mostra nenhum dos 16 AUSENTES como coberto sob outro nome.`
- **SUBSTITUIR POR:** `- **Categoria (c) não pode ser zerada por auditoria nominal apenas.** Pelo menos unknownFutureSchemaFailsControlled possui cobertura semântica parcial em MigrationTests.swift:232 sob outro nome; cada AUSENTE precisa de comparação de assertions antes de ser classificado como comportamento realmente sem teste.`
- **MOTIVO:** um identificador ausente não equivale automaticamente a comportamento ausente.

## Correção transversal — referências de linha

- **ARQUIVO:** todos os artefatos desta série que repetem essas referências.
- **ÂNCORA:** `MainFeedCardBridge.swift:206-224`
- **SUBSTITUIR POR:** `MainFeedCardBridge.swift:234-245 (chamada em :188)`
- **MOTIVO:** line drift confirmado.

- **ARQUIVO:** todos os artefatos desta série que repetem essa referência.
- **ÂNCORA:** `SQLiteCatalogStore.swift:186-196`
- **SUBSTITUIR POR:** `SQLiteCatalogStore.swift:216-217`
- **MOTIVO:** é o ponto real do throw de collision no checkout auditado.

---

# 3. Sobreviventes — bloqueadores reais por ADR

- **ADR-001 — NENHUM.** Os antigos R1/R2 eram falsos positivos; nomes de testes não resolvidos exigem traceability/semantic audit, mas os fatos fornecidos não provam violação da decisão.
- **ADR-002 — NENHUM.** A auditoria nominal de testes não prova que os comportamentos estejam ausentes; nenhuma contradição normativa sobreviveu.
- **ADR-003 — NENHUM.** R3/R4/R5 foram refutados e D1 já fecha R6 em outro ADR; há dívida de traceability dos nomes de teste e a política `missing → ensure/allocate` pode ser adotada por amendment, mas não há contradição bloqueadora demonstrada.
- **ADR-004 — NENHUM.** R6 é refutado pela tabela de authority já existente; `unknownFutureSchema...` requer completar o mapa de cobertura, não demonstra quebra do contrato.
- **ADR-005 — NENHUM.** D17 já diferencia explicitamente o probing legacy da connector boundary V2.
- **ADR-006 — NENHUM.** Os testes citados como future tests são dívida de conformidade/implementação, não evidência de contradição do ADR.
- **ADR-007 — NENHUM.** R8/R9 eram confusão entre compatibility implementation e semântica runtime; a lacuna nominal de tombstone-history ainda precisa de mapeamento semântico, não é bloqueador provado.

**BLOQUEADORES normativos comprovados sobreviventes: 0.** Correções de texto/traceability devem ser feitas antes do sign-off para que o material assinado não contenha afirmações factuais sabidamente falsas.

# 4. Lição

Os falsos positivos vieram principalmente de comparar uma **arquitetura-alvo** com dívida de implementação legacy como se o ADR alegasse conformidade atual, e de transformar line drift/nome de teste em falha semântica.  
Regra: antes de chamar algo de contradição, provar três coisas separadamente — **mesmo escopo, mesma autoridade e mesma afirmação temporal** — e auditar comportamento de teste, não apenas seu identificador.
