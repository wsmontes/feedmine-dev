# LEIA PRIMEIRO — trabalho noturno ChatGPT ⇄ Feedmine

Executor: agente OMP local (acesso ao checkout + à janela do Chrome do usuário).
Worker: ChatGPT, conversa do projeto **Feedmine** (`chatgpt.com/g/g-p-6a584059c8f0819180f2f1d07b1ccbbe-feedmine`, conversa "Continuar trabalho Feedmine").
Noite de 2026-10-05. **Nada foi commitado. Nenhum ADR existente foi modificado.**

## Correção de premissa — 2026-10-06 (leia antes de usar o loop)

Os 23 rounds desta pasta foram desenhados com **três medições erradas minhas**, corrigidas no dia seguinte com prova:

|Premissa que eu usei|O que é verdade|Como foi provado|
|---|---|---|
|O worker é cego: eu preciso colar todo fato do repo|**A conversa tem acesso ao GitHub do projeto** — lê e desenvolve; não roda teste/Xcode|pedi para transcrever verbatim a linha 25 de `ADR-003.md`, arquivo que nunca lhe enviei; ele acertou (e informou que o ref `fix/release-1.0-final-hardening` dá 404 no remoto — o que ele vê é o commit `70f7b06b`)|
|Teto de ~2 400 caracteres por prompt|**≥ 20 000 caracteres numa única mensagem**; o paste grande vira *anexo de texto colado* e a submissão é pelo **botão `Send`** (não pelo `Return`); o valor do textarea fica vazio — quem valida pelo textarea conclui erradamente que falhou|enviei 20 472 chars: chip `button "Show in text field"` apareceu, clique em `Send`, mensagem submetida|
|Eu sou o gargalo: todo o trabalho passa pelo meu contexto|O chat **não consome os meus tokens** e é modelo mais capaz — o certo é mandar **tarefa, não dado**, e usar a inversão (ele me diz o que fazer)|round 24: com uma instrução de 1 322 chars e nenhum dado colado, ele leu ADRs+baseline+rollout+package e devolveu um plano executável (ver `24-tarefa-do-chat.md`)|

Nada do trabalho anterior ficou inútil (as auditorias continuam válidas), mas o desenho do loop estava errado: **os rounds seguintes devem mandar a tarefa e deixar o worker ler o repositório**. Paralelismo em 2–3 abas é possível; trocar de conversa depois de ~10 iterações.



|Etapa|Mecanismo|Limite medido|
|---|---|---|
|Enviar|clipboard + ⌘V no composer + Return|**~2 400 caracteres por mensagem**; acima disso o paste não submete|
|Esperar|sonda do botão de ação do composer (`Stop` = gerando; `Start Voice` = ocioso)|1 chamada de ferramenta por round; **0 token de modelo durante a espera**|
|Extrair|clique no corpo → ⌘A → ⌘C → corte entre `[[DELIVERABLE-START]]` e `[[DELIVERABLE-END]]` → arquivo|a copia só o que está renderizado (~25 KB); rolar para cima e recapturar quando o documento é maior|
|Contexto|todo o texto vai para disco; o executor só vê bytes/início/fim|—|

Canvas/Document **não existe** nessa conversa (o ChatGPT respondeu que não tem a ferramenta) — daí o contrato por marcadores.

## Entregáveis

|Arquivo|O que é|Estado|
|---|---|---|
|`01-plano-de-migracao.md`|Plano normativo de migração: CONTRADIÇÕES, M1–M8, fatias, risco por tabela, decisões humanas|20,4 KB — **corrigido e verificado** (5 substituições + 1 citação)|
|`02-identidade-source-runtime.md`|Adendo A: como um source de catálogo ganha `SourceID` de runtime sem derivá-lo (A1–A7)|13,5 KB — **corrigido** (citação `:948` → `:1009-1042`)|
|`03-fronteira-card-identity.md`|Adendo C: fronteira da identidade de card / PR-15 (C1–C6)|12,3 KB — não auditado linha a linha|
|`04-revisao-adversarial-adrs.md`|Defeitos R1..Rn nos sete ADRs|13,5 KB — **com aviso de cabeçalho**: 21 afirmações marcadas ERRADO pela auditoria|
|`05-checklist-gate0.md`|Checklist de freeze dos 7 ADRs|14,4 KB|
|`06-registro-backlog.md`|Registro de decisões + conflitos internos + backlog PR-00..PR-09|17,0 KB|
|`07-anexo-section16.md`|Anexo v1 (premissa falsa: "§16 do ADR-003")|histórico — substituído por `07b`|
|`07b-anexo-corrigido.md`|Anexo corrigido, para colar no ADR-003|17,4 KB — **título corrigido** (sem numeração inventada)|
|`08-falsificacao-defeitos.md`|O worker tentando derrubar a própria lista de defeitos|5,7 KB — auditoria **confirma** que ele acertou ao refutar R1–R5, R7–R9|
|`09-handoff-kit.md`|Prompt de continuidade + checklist PR-00 + decisões humanas com recomendação|12,1 KB|
|`10-lacuna-de-testes.md`|Lacuna entre os testes que os ADRs citam e os que existem|11,4 KB|
|`11-plano-executavel.yaml`|Backlog em YAML executável v1|histórico|
|`11b-plano-executavel-corrigido.yaml`|YAML executável corrigido|23,6 KB — **valida**: 17 passos, 7 pré-condições, 4 decisões humanas, rollback em todos, 0 referência inexistente|
|`12-errata.md`|Veredito achado-a-achado + correções|17,1 KB — **com aviso de cabeçalho** (as âncoras originais não eram verbatim)|
|`15-pr00-migracao-aditiva.md`|Especificação do PR-00: identificador da migração, DDL aditivo, idempotência, teste|9,2 KB|
|`16-substituicoes.md`|As 6 substituições mecânicas que eu apliquei|2,8 KB|
|`17-mapa-plano-vs-adr003.md`|Mapa M1–M8 → D1–D19: o que o plano já está decidido, o que é novo, o que conflita|6,3 KB — **achado bloqueador (ver abaixo)**|
|`18-emenda-adr003.md`|Emenda normativa ao ADR-003 (D20+): resolução de mapping ausente + lifecycle de `canonicalization_version`|9,5 KB — **resolve o bloqueador**|
|`19-testes-pr00-corrigidos.md`|Seção de testes do PR-00 reescrita: elimina redundância com `MigrationTests.swift:39-40,104-121` e `RuntimeSchemaTests.swift:233-241,552-585` e substitui o teste que passava trivialmente|4,7 KB|
|`20-rastreabilidade-d20-d23.md`|Linhas da tabela `## Traceability` para D20–D23, com ids de invariante e PR responsável|4,4 KB|
|`21-edicoes-no-adr003.md`|As substituições que a auditoria exigiu no texto vigente do ADR (D2, edge case, faixa D1–D19)|5,8 KB|
|`22-d21-final.md`|Redação final do D21 (conflito detectado + evidência durável) e o ajuste do INV-M4|2,1 KB|
|`23-correcoes-de-composicao.md`|As 4 correções que a revisão do documento **aplicado** exigiu: bloco de compatibilidade sem referência a texto removido, heading dos testes qualificado, célula de invariantes corrigida, anexo §1.9 e o termo `ensureRuntimeSourceIdentity`|5,6 KB|
|`_apply/`|Aplicador da emenda + anexo + substituições, com dry-run, backup e pós-condições — **testado ponta a ponta numa cópia**|—|
|`31-pacote-appstore.md`|**Pacote de submissão** (worker com acesso ao repo): metadados pt-BR/en-US dentro dos limites da Apple, tabela de App Privacy justificada por arquivo:linha, bullets da política de privacidade, lista de screenshots e a ordem do que é humano|7,4 KB|
|`32/33/34-pacote-parte*.md`|As três partes como recebidas (a janela renderizada da conversa não sustenta documento longo — ver `_index.md`)|2,9 + 2,3 + 1,8 KB|
|`_review/`|Revisão de código: 4 relatórios independentes + registro priorizado + índice + prova de regressão|~90 KB|
|`35-privacy-policy-draft.md`|Rascunho da política de privacidade **pronto para publicar**, descrevendo o que o executável faz (conferido no código) — remoção do bloqueador de submissão|3,0 KB|
|`36-patch-privacy-row.md`|Patch exato da linha "Privacy Policy" em Settings, com a **âncora verbatim conferida** (`SettingsSheetView.swift:261-270`) e a ordem de verificação|2,9 KB|
|`37-jornada-diagnostico.md`|Diagnóstico do worker (canal recuperado) sobre a falha da jornada no passo do reader — com as duas correções que eu verifiquei contra o repo|1,7 KB|
|`38-rc18-bump.md`|**Procedimento do bump 17→18** e prova do archive, derivado e verificado localmente (`INFOPLIST_FILE` conferido no pbxproj; o script exige árvore limpa e imprime o pairing build↔SHA)|3,1 KB|

`_digests/` (4 recortes factuais do working tree), `_payloads/` (tudo que foi enviado), `_raw/` (capturas da página).

## Fatos verificados no repo (não são palavras do worker)

- **Testes citados pelos 7 ADRs:** 355 citações auditadas → **256 existem, 82 renomeadas, 17 ausentes**. Segundo auditor independente nos 17: **15 realmente ausentes**, 1 coberto por outro teste (`budgetStopMidPageKeepsResumableCheckpoint` → `testPurposeBudgetStopsAcquisitionWithoutLosingCheckpoint`, `AcquisitionCoordinatorTests.swift:332`), 1 parcialmente coberto (`unknownFutureSchemaFailsControlled`, `MigrationTests.swift:232`).
- **`ADR-003` não tem §16.** Seções reais: `ADR-003.md:9,21,61,71,357,382,402,431`. A única menção a "§16" (`:454`) refere-se ao **§16 do plano** (`docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md:645`, "SLOs, observabilidade e critérios de rollout"). A tese "a §16 do ADR delega a migração" era falsa — nasceu na primeira resposta do ChatGPT e eu a propaguei nos prompts seguintes até a auditoria derrubá-la.
- **21 afirmações da "revisão adversarial" (04) são ERRADO**, com evidência: o worker leu como contradição coisas que os ADRs já escopam (ADR-001:30; ADR-003:25,41,57; ADR-005:80; ADR-007:26,28).
- **Segurança da migração:** nenhuma proposta altera `feed_item.id`, nem rekey/move/delete de dado do usuário — todas aditivas.
- `legacy_source_map` / `legacy_item_map` **já existem e são usados em produção** (`ShadowInputBridge.swift:789`, `UserStateBridge.swift:170`).
- **Fundamentação:** 78 caminhos distintos citados; 1 inexistente e é **arquivo proposto** (`LegacyMigrationCoordinator.swift`), não citação falsa.
- `AppSettings.swift:65-92` **expõe** os tipos dos filtros; `OPMLParser.swift:719-723` remove **só** portas default — duas correções aplicadas no `01`.

## O achado mais consequente (`17-mapa-plano-vs-adr003.md`)

- **M1 conflita com o D2 vigente do ADR-003.** O plano propõe `missing mapping → alocar SourceID de runtime → persistir de forma atômica`. O D2 torna a resolução normativa: a tradução catálogo → runtime é um **lookup persistido** em `legacy_source_map`, e ausência de linha é resultado terminal, não gatilho de criação. Implementar M1 como está **exige emenda do ADR-003** — é BLOQUEADOR de Gate 0 para essa parte.
- **Cinco dos oito M's são contratos novos** (M3–M6, M8) que o ADR-003 não decide; M2 e M7 (e boa parte de M1) são implementação direta de D1–D19.
- **Veredito:** híbrido. O objeto mínimo que falta **não** é um ADR de identidade inteiro — é uma emenda ao ADR-003 limitada a (a) resolução de mapping ausente e (b) lifecycle de `canonicalization_version`. Persistência/user-state/card/rollout devem ser cobertos pelos ADRs que já têm esses domínios, não por ampliação artificial do ADR-003.

## Aplicação: pronta, não executada (`_apply/`)

A emenda ao ADR-003 só entra depois da sua decisão — e quando entrar, é um comando:

```bash
cd docs/runtime-v2/chatgpt-overnight/_apply
./apply-adr003.sh                                   # dry-run: valida âncoras, imprime o plano, não escreve
ADR_PATH=/tmp/ADR-copy.md ./apply-adr003.sh --apply  # ensaia numa cópia
./apply-adr003.sh --apply                            # aplica no ADR de verdade (com backup)
```

Três estágios: (1) 3 substituições pontuais no texto vigente (frase do D2, bullet de edge case de canonicalization, faixa `D1–D19`→`D1–D23`); (2) D20–D23 e as subseções da emenda nas seções de destino do ADR — com a subseção de testes renomeada para `### D20–D23 acceptance tests` e as 4 linhas de rastreabilidade de D20–D23 inseridas na tabela; (3) o anexo no fim, como seção nomeada. Dry-run por padrão, backup automático, âncoras verificadas (exatamente uma ocorrência), pós-condições que abortam a escrita em vez de gravar resultado inconsistente. Ensaio final: 45 001 → 74 185 bytes, 454 → 822 linhas, nenhuma seção original perdida, ADR de verdade intocado.

**Veredito da verificação independente sobre o resultado aplicado: APTO PARA REVISÃO HUMANA** — 4/4 defeitos de composição resolvidos, nenhum problema novo. O auditor reprovou a primeira versão; as correções estão embutidas no aplicador.

## Code review do app (2026-10-06) — como foi feito e o que mudou

Descoberta que reorganizou o trabalho: **o projeto no ChatGPT tem acesso ao GitHub** (lê e escreve código; não roda teste/Xcode), **aceita ≥20 000 caracteres num único prompt** (paste grande vira anexo e a submissão é pelo botão `Send`, não pelo `Enter`), o modelo é mais capaz e **não consome token do OMP**. Logo: **mande tarefa, não dado**; e o OMP fica com o que é local (build, teste, apply).

### Frentes rodadas em paralelo

|Frente|Quem|Resultado|
|---|---|---|
|persistência/integridade|revisor local|1 BLOQUEADOR + 4 ALTO + 5 MÉDIO + 4 BAIXO (`_review/cr-persistence.md`)|
|concorrência/isolamento|revisor local (9 fatias)|1 BLOQUEADOR + 9 ALTO + 22 MÉDIO + 7 BAIXO (`_review/cr-concurrency.md`)|
|crash/robustez|revisor local|3 BLOQUEADOR + 12 ALTO (`_review/cr-crash.md`)|
|segurança/privacidade|revisor local|2 ALTO + 6 MÉDIO (`_review/cr-security.md`)|
|preferências/primeira execução|worker (repo)|em finalização|
|caminho crítico da jornada|worker (repo)|em finalização|
|achados próprios|OMP (leitura direta)|6 (`_review/defeitos.md`), 1 já corrigido|

### Verificação própria (não aceitei nenhum achado sem ler a linha)

- **OMP-1** — `FeedStore.swift:1776`: `(try? db.read { COUNT(*) }) ?? 0` fazia *falha de leitura* virar *instalação nova* e sobrescrevia idioma/filtros do usuário. **Corrigido** (`do/catch` + `Log.db.error` + retorno).
- **CR-02** — `AudioPlayerManager.swift:364`: `currentTime = time.seconds` sem `isFinite` (o código guarda `duration` mas não o tempo corrente); `Int(NaN)` aborta. **Corrigido** (guard + `formatTime` defensivo).
- **P-02** — `FeedStore.swift:4797`: `FeedItemRecord(from:)` zera `isRead/openedAt/clickedAt/consumedAt` e `record.update(db)` grava todas as colunas → **um refresh de entrada Atom desmarcava o que o leitor já tinha lido**. **Corrigido** (carrega o estado do leitor da linha existente) + **teste novo** `testAtomEntryRefreshPreservesReaderState` (falha antes, passa depois).
- **S-01** — `FeedItemCardView.swift:516`: `open(url)` sem checagem de scheme. **Corrigido** (só `http`/`https`).
- **P-01** — `initError` é escrito em `FeedLoader.swift:680` e **nunca lido em lugar nenhum**: numa falha de init o app segue com store in-memory, o usuário vê os dados "apagados" e o que ele salvar vai para um banco descartável. **Registrado, não corrigido** (exige superfície de UI).
- **C-01** (BLOQUEADOR do revisor de concorrência) — **verificado**: a FK `exposure_fact (edition_id, card_id) → published_card ON DELETE RESTRICT` existe (`RuntimeMigrations.swift:704-707`) e o `catch` de `attemptFlush` (`FeedSession.swift:722-724`) **só incrementa estatística**: o lote permanece, a falha é determinística e o histórico só sai por overflow. **Latente para o 1.0**, porque a lane V2 não é a que embarca (launch = `.legacy`).
- **OMP-6** — duas políticas concorrentes para o idioma de primeira execução (`FeedStore.swift:1967+1773-1795` vs `:2030-2041`), com a checagem de disponibilidade **inalcançável**. Severidade calibrada para MÉDIO: o catálogo cobre ~100 idiomas, então **não consegui repro de feed vazio** — o dano realista é feed mais raso em locales de cauda longa.

**Honestidade de severidade:** `try!` (14) e `fatalError` (1) foram inspecionados e são **benignos** (regex com padrão literal, `required init?(coder:)`, fallback in-memory intencional). Não inflacionei nada para "parecer rigoroso".

### Estado das correções

**14 defeitos corrigidos em 11 arquivos + 2 testes novos; nenhum commit.** Compilação: o primeiro build reprovou minha própria correção (`record` era `let` num struct) — corrigido e re-buildado. Estado final desta árvore: **duas barras verdes consecutivas** — **`BAR OK 09:53:36`** e **`BAR OK 10:04:50`**, ambas com **610 testes, 0 falhas ×3** e jornada **17/17**. Antes dos dois últimos consertos: `BAR OK 09:37:27` (610/0 ×3 + 17/17) e `BAR OK 07:03:09` / `06:51:11` (609/0 ×3 + 17/17).

**Dois candidatos foram tentados e rejeitados com medição — e um deles re-entrou depois.** O critério foi a barra, não o meu gosto:

| Candidato | O que era | Veredito |
|---|---|---|
| CR-08 (prune de cache) | `ArticleImageResolver` acumulava três dicionários chaveados por toda URL de artigo | **fora** — jornada 15/17 nas duas execuções com ele, 17/17 nas duas sem |
| CR-03 (teto de imagem) | `ImageLoader` baixava o corpo inteiro da imagem do feed sem teto | **rejeitado na hora, re-entrou depois**: ver abaixo |

Placar dentro da barra antes do conserto 13: **3/3 falhas quando eu mexia no caminho de imagem, 3/3 passes quando não mexia** — sempre as mesmas duas superfícies (`03-article-reader`, `04-article-scrolled`). O diagnóstico do worker isolou a causa no **churn de publicação** (`FeedDisplayState:287` atribuía os mesmos valores e bumpava duas gerações, re-renderizando todo card na janela do tap). Com o conserto 13 aplicado, o CR-03 re-entrou e a barra fechou **17/17 duas vezes com o teto aplicado**: a rejeição estava certa *para a árvore em que foi testada* — o teto não era o defeito, era o que o expunha.

| # | Defeito | Arquivo | Correção |
|---|---|---|---|
| 1 | OMP-1 | `FeedStore.swift` | falha de leitura não é mais "instalação nova" |
| 2-3 | CR-02 | `AudioPlayerManager.swift` | `currentTime` só recebe valor finito; `formatTime` defensivo |
| 4 | P-02 | `FeedStore.swift` | refresh de entrada Atom preserva o estado do leitor (**com teste provado nos dois sentidos**) |
| 5 | S-01 | `FeedItemCardView.swift` | "Open in Safari" só abre `http`/`https` |
| 6 | C-04 | `AdaptiveScheduler.swift` | cancelamento não conta como falha de fonte (não empurra para backoff de até 24 h) |
| 7 | P-03 | `RetentionPolicy.swift` | falha ao ler os bookmarks da autoridade **propaga** em vez de encolher o conjunto protegido |
| 8 | CR-01 | `FeedItem.swift` | `durationFormatted` exige `d.isFinite`: `d >= 60` é falso para NaN mas **verdadeiro para +inf**, e `Int(inf)` aborta |
| 9 | C-07 | `ImageCache.swift` | honra o retorno de `registerDownload`: só quem registrou desregistra, em vez de derrubar a marca do download alheio |
| 10 | OMP-2 | `FeedStore.swift` | `try? db.write` da lista "Favorites" vira `do/catch` com log (o bloco acima já registrava o próprio erro) |
| 11 | CR-09 | `URLResolver.swift` | o iTunes Lookup era o **único** ponto do arquivo fora da convenção de teto: passa a usar o `boundedDownload` que já existia (`DownloadLimit.lookupJSON` = 1 MB) |
| 12 | **P-01** | `FeedLoader.swift` + `FeedScreen.swift` | **fail-closed**: `persistenceUnavailable` derivado de `initError` (que era escrito e **nunca lido**), `start()` recusa rodar o pipeline no fallback in-memory, e a tela mostra `ContentUnavailableView` ("Your feed data couldn’t be opened… your saved data has not been deleted") em vez de desenhar um feed vazio sobre dado que existe no disco. Costura `storeFactory` no init para o teste poder fazer a construção padrão lançar. Teste: `testPersistentStoreFailureIsVisibleRatherThanSwallowed` |
| 13 | **tap engolido** (do diagnóstico do worker) | `FeedDisplayState.swift:287` | a reconciliação de fundo atribuía `visibleCards`/`visibleItems` e **bumpava as duas gerações mesmo quando o merge não mudava nada** — re-render de todo card. Passa a atribuir só quando muda (`!=`, ambos `Equatable`); o settle e a escrita do cache de página seguem rodando |
| 14 | **CR-03** (re-entrou depois do 13) | `ImageLoader.swift` | teto de 12 MB no corpo da imagem do feed: `session.bytes` + checagem de `Content-Length` + corte, em vez de `session.data` bufferizando o corpo inteiro |

**S-02 foi tentado e revertido — e a lição vale mais que o conserto.** Apliquei o fail-closed na verificação da assinatura do catálogo e a **barra de produto reprovou**: `== BAR FALHOU ==`, com 3 testes vermelhos em três gates consecutivos (`testManifestValidatesWithEmptyKeyAndEmptySignature`, `testManifestDecodesWithoutSignatureField`, `testChecksumFailureKeepsBundledSnapshotActive`). Os testes pinam uma **política deliberada e documentada** ("o canal remoto não é usado no 1.0; a chave vazia é assunto de desenvolvimento"). Trocar política é decisão do dono, não conserto meu: revertido, 7/7 testes verdes de novo. O achado segue **aberto como recomendação** — se o canal remoto for ligado, a verificação tem de ser obrigatória.



## Gates executados (evidência, não declaração) — 2026-10-06

| Gate | Comando | Resultado |
|---|---|---|
| fronteiras do pacote | `bash scripts/validation/test_runtime_v2_boundaries.sh` | **8 passed, 0 failed**, pacote real exit 0 |
| suite Runtime V2 | `bash scripts/validation/run_runtime_v2_tests.sh` | **package 501/0** + **app plan 608/0** → `Runtime V2 test gate: PASS` (188 s) |
| **bar de produto** | `bash scripts/release-acceptance.sh` | **`== BAR OK 05:38:41 ==`** com os **10 consertos**: `build-erros: 0`; **gate 1/2/3 = 609 testes, 0 falhas** cada; **`JORNADA superficies-obrigatorias=17/17 ausentes=[]`** (671 s). Antes: `BAR OK 04:13:26` com 5 consertos e `BAR OK 04:49:47` com 7 |
| smoke | `bash scripts/validation/run_smoke.sh` | iniciado e **encerrado por mim** para liberar a toolchain a favor da verificação dos consertos — **não é verde nem vermelho: incompleto** |
| performance em device | `run_performance.sh device` | não executado (exige device físico) |

Notas honestas: o próprio bar imprime que um achado segue aberto — *"gate N [green under 30s deadline tolerance, finding 10 (injected clock / suspension points) STILL OPEN]"*. E a contagem do bar é **609** onde o baseline registrava 608 — a diferença é o teste novo que eu acrescentei (`testAtomEntryRefreshPreservesReaderState`), o que também prova que ele está no alvo.

### Sobre a flakiness do bar (medida, não suposta)

A barra foi executada três vezes. Na segunda tentativa (com 8 consertos) falhou por **mudança de política** (S-02, ver acima — revertido). Na terceira (com 7 consertos), gate 1 = **609 testes, 0 falhas**, e as outras duas gates caíram em **dois testes diferentes** (`ContentDistributionTests.testMediaTypesAreSpreadNotClustered`, `FeedComposerPreviewTests.testPreviewPerformance`).

Investiguei em vez de chamar de flaky:

- o próprio repo documenta essa classe (`docs/release/1.0-checklist.md:329`): *"`FeedComposerPreviewTests.testPreviewPerformance` measured 3.61 s against its 1.5 s budget and passes standalone in 0.361 s"*, e o finding 10 diz que *"the gate is recorded per run rather than as a standing property"*;
- rodei os dois testes **isolados 3×**: ambos passam sempre, e o `testPreviewPerformance` faz **0,34–0,35 s** isolado contra **17,5 s** in-suite;
- nenhum deles exercita o caminho que eu toquei (o de distribuição monta 300 itens sintéticos sem passar por `recordFetch`).

Conclusão: é a **classe deadline-budget documentada**, não regressão dos consertos. A ressalva fica registrada porque um "verde" da barra é propriedade *daquela execução* — e o repo já diz isso por escrito.

Uma quarta execução, já com **10 consertos**, caiu em gate 3 com **um** teste diferente: `MainFeedRuntimeV2Tests.testViewportReplenishmentUsesTheObservationAndNothingElse`. Verifiquei antes de opinar: passa **isolado 3×** (0,007/0,013/0,009 s) e o próprio `docs/runtime-v2/baseline.md:1462,1502` documenta *"`MainFeedRuntimeV2Tests` has a **latent order dependence**"* / *"The suite's own defect: a latent order dependence"*. A execução seguinte, com os **mesmos 10 consertos**, fechou `BAR OK` com 3×609/0 — o que confirma a leitura: é ordem entre testes, não o código que eu toquei.





## Bloqueadores de submissão verificados (2026-10-06)

Levantados pelo worker com acesso ao repo e **conferidos por mim** no código:

1. **Não existe link de política de privacidade dentro do app.** Verificado: `feedmine/Views/SettingsSheetView.swift:243-271` tem Versão/Fontes/Re-watch Intro e a seção Feedback com "Send Feedback" (mailto) e "FeedKit on GitHub" — **nenhuma linha de Privacy Policy**. O grep de "privacy" no app só encontra anotações de log e um `privacyNote` de UI (`CuratedFeedInspectorView.swift:305`). O `docs/AppStoreSubmission.md:40` já registra: *"Publish the privacy-policy URL. The site route exists in source but must be deployed before it can be supplied to Apple."* → **precisa da URL publicada + uma linha nova em Settings** (patch trivial, mas não aplico com URL inexistente: viraria link morto no build que vai à Apple).
2. **O mesmo número de build cobre dois binários** (17), verificado em `Info.plist`/`project.yml` — publicar a árvore atual exige 18.
3. **App Privacy / metadados / screenshots / testadores** — só no App Store Connect (humano).
4. **Review Notes para conteúdo de terceiro**: o app agrega RSS/sites/podcasts/vídeos; o worker recomenda explicar no campo de notas que é um leitor e que as URLs são de terceiros — risco de reprovação por "conteúdo de terceiros sem direito".

O pacote pronto para revisar/colar está em **`31-pacote-appstore.md`** (metadados pt-BR/en-US dentro dos limites da Apple, tabela de App Privacy justificada por arquivo, bullets da política, lista de screenshots e a ordem do que é humano).



## O que só você decide

**Decisão nova, a de maior risco (verificada por mim):** qual binário é o 1.0.
- O build **17** já enviado à Apple saiu do commit `4df951c4`.
- A árvore atual (`70f7b06b`) está **2 commits à frente** e ainda declara `CFBundleVersion = 17` (`feedmine/Info.plist` e `project.yml`) — **o mesmo número cobre dois binários diferentes**; publicar a árvore atual exige subir para 18.
- Orientação do worker, que eu endosso: **não bloquear a publicação por Runtime V2/ADR-003** — o launch sem request continua `.legacy`, então a arquitetura V2 não é pré-requisito do 1.0.

Quatro decisões anteriores, com recomendação e caminho-padrão, em `09-handoff-kit.md` §3 e em `11b-plano-executavel-corrigido.yaml` (`human_decisions`): identidade de runtime para sources de catálogo; fronteira da identidade de card (PR-15); o que fazer com as provas ausentes; e o critério de aborto do Gate 0.

## Próxima ação recomendada

**Para publicar (o objetivo atual):**
1. Decidir o RC: build 17 como está, ou subir para 18 e provar a árvore atual.
2. Provar o RC escolhido: `scripts/release-acceptance.sh` (bar de produto: 3 execuções consecutivas de `feedmineTests` + jornada 17/17) e, se for build novo, `scripts/release-testflight.sh --dry-run` (exige árvore limpa → precisa da sua autorização para commitar o candidato).
3. Fechar o App Store Connect: privacy policy URL, App Privacy, metadados, screenshots do RC, testadores — mais o dogfood em device (jornada manual do checklist).

**Para o trabalho de arquitetura (não bloqueia a publicação):**
4. Ler **`18-emenda-adr003.md`** — é a peça que desbloqueia: sem ela, M1 não pode ser implementado sob o D2 vigente.
5. Ler `07b-anexo-corrigido.md` — o artefato pensado para colar no repo (seção nova **nomeada**; o ADR não usa numeração de seção).
6. Rodar `11b-plano-executavel-corrigido.yaml` como checklist, usando a seção de testes de `19-testes-pr00-corrigidos.md` em vez da original do `15`.

**Correções de código já aplicadas (worktree, sem commit):** 5 defeitos em `FeedStore.swift`, `AudioPlayerManager.swift`, `FeedItemCardView.swift` + o teste novo em `feedmineTests/FeedStoreTests.swift`. Revise com `git diff`; se aprovar, commit é decisão sua.

## Ressalvas

- Tudo aqui são **rascunhos do worker**, auditados por modelos, não assinados por humano.
- Cobertura de auditoria real: **auditorias A e B concluídas** sobre `03/05/06/09/10/15` (além de `01/02/07/11/12` antes). Correções aplicadas e verificadas: no `01/02/07b` (5 substituições de conteúdo + 1 citação de linha), no `03` e `05` (citações `MainFeedCardBridge.swift:234-247`, `PublicationRepository.swift:1042`, `FeedScreen.swift:1337,1452`), no `06/09` (3 caminhos de arquivo: `FeedStorage/Migrations/`, `FeedDomain/Identity/`, PR-02 explícito) e a seção de testes do `15` reemitida em `19`. Comandos SPM/Xcode citados no `09` foram validados (targets `FeedStorageTests` e `feedmineTests` existem). `04/12/16` mantêm o texto original de propósito, com aviso de cabeçalho.
- **Verificação do documento aplicado:** duas rodadas. A primeira reprovou a composição (4 defeitos: referência a texto já substituído, heading duplicado, célula de invariantes inconsistente, nome de teste marcado como indeterminado); os quatro foram corrigidos e a segunda rodada deu **4/4 RESOLVIDO — APTO PARA REVISÃO HUMANA**, sem problema novo.
- Pendências conhecidas: `05` P0.2 referencia "tabela §19 do plano" (a auditoria apontou possível troca por §4 — **não confirmado**, não corrigido); `LegacySourceMapMigrationTests.swift` e demais arquivos de teste propostos ainda **não existem** (marcados `criar`).
- Chrome sinalizou "High memory usage" durante a noite (conversa longa). O estado está todo em disco.
