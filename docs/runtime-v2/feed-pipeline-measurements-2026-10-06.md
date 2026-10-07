# Feedmine — medições do pipeline do feed (2026-10-06)

Três defeitos do produto medidos no simulador, com a evidência que os sustenta e as correções aplicadas.
Todo número saiu de uma execução real; o que é inferência está marcado. Nada foi commitado.

Ferramenta: build 18 + instrumentação local (§5). `iPhone 16` (`2F70B5E4-DF56-428C-A7B9-0A769B6CAC3D`,
o alvo dos baselines) e `iPhone 17 Pro Max` (`8871DCF5-…`) para os cenários que precisavam do aparelho
livre. Log do app: `xcrun simctl spawn <udid> log stream --style syslog --level info --predicate
'subsystem == "com.feedmine.app"'`. Medições de cold start: container limpo (`simctl uninstall`),
`simctl install`, `simctl launch … -UITestSkipOnboarding`, screenshots a cada 5 s.

> **Caveat de ambiente (afeta todos os tempos deste documento).** O volume de dados estava **100% cheio,
> com 1,4 GiB livres** durante a sessão inteira — a execução do agente morreu por disco cheio às 16:24:33
> e um app de feed escreve cache de imagem e journal do SQLite o tempo todo. Pressão de I/O desse porte é
> uma causa plausível da variância grande que aparece nas medições (taxonomia de 2,9 a 7,3 s entre duas
> execuções; cold start de 29 a 83 s entre árvores diferentes). Nada foi medido num volume com folga, e
> **os números absolutos não devem ser lidos como propriedade do app** — o que é robusto são as
> *atribuições* (quem paga o quê) e as comparações dentro da mesma execução.


## 1. D1 — atraso até o feed aparecer

### 1.1 Medição antes (container limpo)

| instante | evento |
|---|---|
| 0,0 s | launch |
| 1,5 s | `loadingState: idle → initial`; superfície `initial-loading` "Preparing your feed…" `0/100` |
| 13,5 s | `firstLaunchBootstrap stages: sourcesMs=1462 sources=240 fetchMs=10752 items=70` → 70 itens de 3 fontes |
| 13,5 s | `firstLaunchBootstrap withheld: sources=3/100 items=70/100` → **nada publicado** |
| 23,0 s | `starterFetch` #1: 1 fonte, 20 itens → `starterIngest withheld: sources=3/100 items=90 pageReady=0` |
| 26,8 / 30,5 / 34,1 s | `starterFetch` #2–4: 0 itens → mesmo `withheld`, `pageReady=0` |
| 35,9 s | `cold start persisted pending: items=70/90 pageReady=0 after deadline` → `cold start withheld: no complete page after 4 attempts (30 s deadline) — empty surface, no partial feed` → `feedDisplayPhase: preparing → empty` |
| 52,8 s | superfície `empty-state` com "No articles found for" — **falso**, 70 itens já persistidos |
| 54,2 s | primeiro `page[pipeline] items=12 withMedia=8` → o feed aparece |

**54,2 s até o primeiro card**, dos quais ~10,8 s de fetch real, ~22 s de retry induzido pelo gate e
~17 s sem publicação nenhuma.

### 1.2 Causa

Os dois lados do pipeline mediam coisas diferentes:

* o fetch para cedo, por desenho: `minimumSuccessfulSources: min(remainingSources,
  coldStartMinimumPageSources = 3, chunk.count)` e `minimumItemCount: min(remainingItems,
  coldStartImmediateItemCount = 12)` (`FeedStore.swift:1746-1751`);
* o gate de publicação exigia `items.count >= 20 && distinct(sourceURL) >= 20`
  (`coldStartPageIsReady` → `coldStartRunwayIsUseful(targetSourceCount: Reservoir.pageSize)`, `:1574-1578`).

Com 3 fontes bem-sucedidas, `distinct >= 20` era inalcançável nessa rodada: 70 itens reais retidos e uma
tela de vazio. Agravantes verificados:

* o comentário do gate dizia "distinct providers" mas a implementação contava `Set(sourceURL)` — e vários
  URLs podem ser de um mesmo publisher (`Reservoir.providerKey`, `Reservoir.swift:538-556`), então o gate
  não media o que prometia;
* o veredito de 30 s transformava "não consegui montar a página" em "não existem artigos", e `.empty`
  significa, por contrato (`FeedLoader.swift:15-29`), "preparação terminada e zero resultados confirmados";
* **um fetch de 27 s num deadline declarado de 10 s**: a linha `fetchStarter return … deadlineMs=10000
  deadlineFiredMs=-1 returnMs=27078` mostra que o deadline **nunca disparou** — o fetch só terminou ao
  esgotar as 240 fontes. O `withTaskGroup` só retorna quando todos os filhos terminam, e o prazo não
  chegou a ser processado no laço de eventos.

### 1.3 Correção aplicada

1. `coldStartPageIsReady` = `Reservoir.pageSize` (20) itens publicáveis **+ piso de 3 providers**
   (`Reservoir.providerKey`). A imutabilidade que a revisão de release pediu é da *publicação* — uma
   página cheia, publicada uma vez, sem crescer sob o leitor —, não do universo de supply do instante.
2. O gate passou a ser avaliado sobre o conjunto **publicável** (`applyFilters`), não sobre o lote bruto:
   item que a composição ativa descarta não é card.
3. O fetch conta **providers**, não URLs, na sua condição de parada (`successfulProviderKeys`) — as duas
   pontas do pipeline passam a medir diversidade na mesma unidade.
4. O veredito dos 30 s: lote retido que passa o gate é publicado; página de tamanho cheio abaixo do gate é
   publicada com log `cold start salvaged`; **abaixo de uma página o estado terminal é `.empty` para esta
   composição** (não há o "14 itens e depois mais 6" que a revisão proíbe) e o refill de fundo continua.
5. O store recusa publicar um **vazio como resposta** (`settlesPhase`) enquanto a runway inicial está sendo
   preparada. Isto é o que produzia o "No articles found for" medido no meio da preparação.
6. `.failed` **não** foi usado: o caso existe em `FeedDisplayPhase` mas nenhuma view o renderiza
   (verificado por grep em `feedmine/`).
7. **O piso de publicação é uma tela, não `pageSize`.** Medido: uma execução buscou 230 itens com
   **19 publicáveis** e retirou tudo — um item abaixo de vinte — e a tela ficou vazia por mais de 60 s,
   enquanto a mesma árvore publicava 20 itens em 26,7 s quando o lote dava vinte. `coldStartPageIsReady`
   (página cheia + piso de providers) continua sendo o alvo *preferido*, que também encerra o laço de
   fetch cedo; `coldStartMinimumSourceCount` (100) continua sendo a meta de runway; e o que publica é uma
   tela (`coldStartImmediateItemCount`, 12) de itens **publicáveis**. A página cresce por append no fim —
   exatamente o que todo load-more deste app já faz (a revisão de release proibia *um item* que cresce,
   não uma tela).
8. **A espera da promoção precisa sobreviver ao deadline que ela espera.** Ela valia exatamente
   `initialViewportDeadline` (6 s) — o mesmo prazo por item que produz o fallback terminal — então a
   corrida era perdida por construção: medido, `page[pipeline] items=2 withMedia=2` publicado em exatos
   6,0 s com 18 cards ainda resolvendo. Agora a espera é deadline + 2 s, e a página sai com 13–20 itens.

### 1.4 Efeito medido (com as correções)

Comparação, todas em container limpo:

| árvore | caminho de medição | primeiro paint | itens | vazio falso |
|---|---|---|---|---|
| baseline (build 18) | log da jornada de UI | **54,2 s** | 12 | sim — "No articles found for" por 1,4 s |
| 14:17 (antes das correções) | harness de UI do agente | **83,2 s** (TTFF) | — | — |
| 14:31 / 14:34 / 14:39 (correções parciais) | manual | 35,7 / 67 / 74 / 83 s | 3, 20, 2, 20 | não |
| **final (n=3)** | manual, 3 execuções limpas | **29,0 / 33,0 / 29,4 s → mediana 29,4 s** | 6, 13, 13 | **não** |

Nas três execuções finais: **zero `withheld`, zero `surface[empty-state]`**, e `fetchStarter` estável em
15,4–17,2 s (era 27,1 s). O primeiro paint ainda é dominado por rede (240 fontes no bootstrap) e a página
cresce por appends depois — 6/13/13 itens no primeiro publish, com a composição seguinte acrescentando o
resto.

Ressalva de método: os dois números "antes" vêm de caminhos diferentes (log da jornada e harness de UI) e o
"depois" do meu harness manual; a comparação é direcional, não um A/B com a mesma sonda.

### 1.5 O que a investigação seguinte mostrou (com instrumentação própria)

* **O deadline do `fetchStarter` não é quem manda no retorno.** `deadlineMs=10000 deadlineFiredMs=-1
  returnMs=27078`: o prazo nunca é observado — o que para o passe é a condição de "runway pronta"
  (3 fontes/12 itens), e o `withTaskGroup` então espera os filhos em voo terminarem.
* **O que mantinha os filhos vivos era trabalho pós-HTTP sem cancelamento**: parse, extração e,
  principalmente, `validateAudio` (até 12 probes, 6 concorrentes, 6 s cada; e o `catch` ainda caía num
  ranged GET em cima do cancelamento). Correções: `validateAudio` cancel-aware, sem fallback em
  `CancellationError`, e o passe *starter* deixou de validar áudio (primeira impressão não precisa de
  playability). Efeito medido: **27 078 ms → 14 932 ms** no mesmo cenário, com `deadlineMs=10000`.
* **`request.timeoutInterval = 15` anulava o fast lane.** O `FeedHTTPSync` fixava o timeout por requisição
  em 15 s (`FeedHTTPSync.swift:82`), e isso *sobrepõe* o timeout da `URLSession` — inclusive a lane do
  starter, construída com `fastLane: true` (5 s / 7 s). Um publisher lento segurava a primeira pintura por
  15 s, e o grupo do fetch só retorna quando todos os filhos retornam. Correção: a lane passa o próprio
  orçamento (`requestTimeout: 5` no starter, 15 no transporte normal).
* **Cancelamento não é falha quando a resposta já chegou.** A primeira versão da correção acima devolvia
  `.failed(CancellationError())` para o fetch cancelado, e o ledger passou a classificar uma resposta
  servida como "nunca aconteceu" — pego pelo teste
  `BackgroundRefreshDemandTests.testCancellationAfterAFetchWasAnsweredIsReportedAsCommittedThenCancelled`
  (`cancelledBeforeCommit` em vez de `cancelledAfterCommit`). O cancelamento agora só pula os *probes*
  (`skipProbes = skipAudioValidation || Task.isCancelled`), preservando o desfecho `.modifiedWithNewItems`.
* **A promoção pode não publicar nada, e agora diz por quê**: uma execução terminou com a página
  agendada e nunca publicada. O diagnóstico embutido (`editorialDiagnostics`) deu a resposta exata:

  ```
  page[pipeline] nothing published: editorialRemaining=19 minimumCount=19 maxCount=20 waitedMs=6000
    append=0 ctxEpoch=0 presentationEpoch=0 ordered=19 nextPublish=0 nextPrepare=19 ready=19 resolved=19 inFlight=0 activeEpoch=0
  ```

  Tudo pronto — 19 cards render-ready, `nextPublish=0`, mesma época — e ainda assim a promoção devolveu
  vazio. Em `waitForContiguousPrefix` só dois caminhos devolvem `[]`: `Task.isCancelled` e
  `context != activeContext` (`CardPreparationCoordinator.swift:225-228`). Como `ready=19` prova que a
  sequência editorial **daquele** contexto foi instalada, a suspeita é a segunda: uma corrida de
  contexto entre a publicação do cold start e o caminho do flush — e `FeedPresentationContext` compara
  mode/generations, não só a época (o log mostra as épocas, que batiam). **É o próximo item a corrigir**,
  e é ele que ainda deixa o cold start sem página por dezenas de segundos (a página que sai depois vem
  com 2 itens).

## 1b. Automação de simulador (entregue em paralelo)

`scripts/validation/run_ui_matrix.sh` (+ alvo `make ui-matrix`): dois legs — TTFF cold/warm e depois as
três classes de UI — com lane lock, log do app em paralelo e relatório em
`Artifacts/Validation/Results/ui-matrix-<ts>.md` (tabela por teste, linhas do app, resumo; exit≠0 em
falha). Testes novos: `testTimeToFirstCardColdThenWarm`,
`testEndOfFeedFetchesNextPageAfterWarmRelaunch`, `testFilterAxisSweepCoversEveryValue`, mais os
identificadores de acessibilidade que faltavam (preset, mood, países, nós de tópico).

Resultado do run `ui-matrix-20261006-141732` (iPhone 16, rev `5157b13d`, árvore suja):

| medida | valor |
|---|---|
| cold TTFF (sem page cache) | **83 250 ms** (launch return 3 764 ms) |
| warm TTFF (page cache de 20 itens) | **233 ms** — card já presente no retorno do launch |
| fim-de-feed | `reached_end=1` (24 swipes, 44 ids distintos); na janela de 9,6 s `rendered 8→8`, `grew_by_count=0`; só cresceu quando 1 swipe extra pediu (`grew_by_swipe=1`) |
| varredura de eixos | 21 casos medidos (de ~80 s/caso; a sheet oferece 62 idiomas) |
| FINDINGS | 8 idiomas sem card em 8 s: es, fr, it, nl, cs, ro, sv, el |
| falha real pré-existente | `testContentTypeAllSelectionsRespondQuickly`: tap em `content-type-articles` levou **5 563 ms** (assert < 1500) |

Run 2 (`ui-matrix-20261006-145850.md`, árvore posterior às correções, o leg B morreu por **disco cheio**
às 16:24:33):

| medida | valor |
|---|---|
| fim-de-feed | `reached_end=1` (40 swipes, 75 ids); janela de 10,2 s `rendered 8→8`, `grew_by_count=0`, `grew_by_swipe=1` (2 ids novos) — **confirma o comportamento em duas execuções** |
| varredura | 34 casos (16 idiomas, os mais movimentados) + 46 pulados, registrados |
| tempos | `select_and_dismiss_ms` de **3 208 ms** (content-type-articles) a **42 296 ms** (mood-fun); `content_wait_ms` de 267 ms (preset Everything) a 10 170 ms |
| suite | 34 testes reportados: 24 passaram, **10 falharam** (sem resumo final do xcodebuild — o run morreu antes) |

As 10 falhas do run 2, classificadas por mim:

* **a mesma família do atraso**: `testContentTypeAllSelectionsRespondQuickly` (tap `content-type-podcasts`
  = **12 838 ms**), `testFilterCombinationsMatrix` (`content-type-videos` sem cards em 8 s),
  `testVideoFilterWithEnglishLanguage` — todas medidas contra uma janela de 1,5–8 s, com o custo real de
  tap medido em dezenas de segundos (§8);
* **`PersonaExplorationUITests.testCaptureAllScreens`** — `reader never presented` — é a falha de jornada
  já documentada no repo (race do tap, `docs/runtime-v2/chatgpt-overnight/42-tap-sob-carga.md`), não uma
  regressão das correções: ela não toca o caminho de mídia nem o de publicação;
* **categorias sem cards em 30 s** (`Acoustics`, `Cooking & Recipes`→`Video`, `Visual Arts`, `Mythology`)
  e a classificação de astronomia — são eixos de catálogo/taxonomia que eu **não** investiguei; ficam como
  pendência declarada, não como "verde".


Os dois runs concordam no essencial: **um toque em filtro custa de 3 a 42 s** neste ambiente (run 1:
`select_and_dismiss` 2,4–36,3 s com `language-el` no topo; run 2: 3,2–42,3 s com `mood-fun`), e a espera
de conteúdo fica em 0,3–10,2 s quando o filtro tem conteúdo local. O custo **não** está no pipeline local
(§8) e sim no boot mais a preparação/publicação.


## 2. D3 — o feed chega ao fim e não busca mais nada

### 2.1 Medição

Filtro `Podcasts` + idioma herdado EN, rolagem contínua até o fim:

```
14:21:05.84 [LoadMore] serve item=497 published=500 reservoir=160
14:21:06.39 [LoadMore] serve item=499 published=500 reservoir=140
14:21:07.11 [LoadMore] skip  item=499 lastLoaded=499 published=500 reservoir=120 — same index already served
…                                    (repetido a cada evento de rolagem, indefinidamente)
```

Três fatos:

1. Os dois `serve` do fim consumiram 20 itens do reservoir cada (160 → 140 → 120) **sem publicar nada**
   (`published=500` antes e depois).
2. `lastLoadedIndex` virou lápide: a partir do primeiro `skip`, toda observação no mesmo índice foi
   recusada pelo resto da sessão, com 131 itens ainda no reservoir.
3. Nenhum fetch foi disparado: o gatilho só olhava `reservoir.reservoirCount < 80`, e o número bruto
   (131) parecia saudável — ainda que nenhum daqueles itens passasse pelo filtro ativo.

O append vazio tem explicação estrutural: `promotePreparedCards(isAppend: true)` espera 3 s por um
prefixo contíguo render-ready, enquanto item recém-anexado recebe `deepRunwayDeadline` de 30 s
(`RunwayPolicy.swift:32-39`). Com arte lenta o append volta sem página — e é exatamente o caso dos
podcasts (§3).

### 2.2 Correção aplicada

* A posição do tail só é recusada quando **nada há para publicar**: o re-arme passou a exigir
  `preparationCoordinator.renderReadyCount > 0` ou reservoir maior que no serve que falhou — nunca por
  relógio, que só moveria mais uma página do reservoir para nada.
* A decisão de buscar passou a considerar o **crescimento da página**, não o reservoir bruto; um tail que
  não avançou dispara `fetchNextBatch()` (espaçado 10 s).
* O append ficou observável: `applyUpdate(.append)` aguarda a publicação (`cardPreparationTask`) e registra
  `[Append] no-growth …`.
* O batch vazio do fetch deixou de ser silencioso: `[Fetch] batch empty pool=… region=…` explica quando o
  scheduler recusou todos os candidatos (cooldown/backoff/skip window).

## 3. D2 — arte de podcast ausente no card

### 3.1 Medição

Filtro `Podcasts`: primeira página em 26,7 s (`page[pipeline] items=4 withMedia=4`) e, na rolagem por ~90
cards, **todas** as capas de podcast desenharam o placeholder roxo (`podcastPlaceholder`), nenhuma com
arte — de fontes distintas (India Rising, Poland, My Daily Bread, Katty Kay…). O placeholder é
`CardMediaSlot.placeholder(.podcast)` sobre frame reservado (`FeedItemCardView.swift:94,209`).

### 3.2 Causa

* `prepareItem` resolve a imagem sob deadline por índice (6 s na viewport, 15 s perto, 30 s no fundo);
  deadline estourado → `resolved = .placeholder(kind)` → `decodeToRenderReady` → `media: .none,
  layout: .textOnly` (P0.1: "never publish a placeholder in a hero slot").
* O retry diferido existe (`startDeferredImageRetry`, 12 s) e **busca a imagem**, mas
  `upgradeDeferredToHero` só atualiza a entrada do runway: "the published presentation is immutable … a
  late image is kept for the next composition instead of being applied in place"
  (`CardPreparationCoordinator.swift:584-610`) — e a composição seguinte, num feed travado (§2), nunca vem.
* O caminho de imagem não tinha instrumentação nenhuma: `ImageLog` (com `cacheHit`, `downloadFailed`,
  `httpError`…) tinha **zero** call sites, e "late" e "never" eram indistinguíveis.

### 3.3 Correção aplicada

O que a imutabilidade protege é a *altura do card*, não o frame já reservado. Então:

* `FeedDisplayState.healPublishedMedia(_:cacheKey:)` troca a mídia de **um** card publicado, na mesma
  posição, e **recusa** quando a moldura não estava reservada (podcast: slot `.placeholder(.podcast)` com
  layout `.hero` → `.local` com o mesmo layout; ou layout armazenado igual);
* `CardPreparationCoordinator.setMediaUpgradeHandler(_:)` é chamado ao fim de `upgradeDeferredToHero`, e o
  `FeedStore` instala o consumer em `start()`;
* **o card ficou de fato invariante em altura**: o padding do título usava `hasImage` (bytes presentes) e
  pulava 4 pt quando a imagem chegava — agora usa `mediaSlot.reservesFrame`, o mesmo invariante do resto
  da view. Sem isso o heal era geometricamente falso.

Resíduo conhecido e não corrigido: o menu de bookmark dentro da linha ainda depende de `!hasImage`
(`FeedItemCardView.swift:364`), então um card curado perde esse controle na própria linha (o overlay de
bookmark continua). Não muda altura; corrigir exige decidir o contrato do controle, que também vale para
republiqueções normais.

### 3.4 Verificação ao vivo — e um segundo defeito, maior

Rolagem rápida pela mesma sessão (container quente, iPhone 17 Pro Max), com a instrumentação do caminho
de mídia:

| medição | antes da correção | depois |
|---|---|---|
| `prepare … outcome=image` | 15 | **123** |
| `prepare … outcome=placeholder` | 168 (numa rolagem comparável: 224) | 135 |
| `deferred-retry … image=1` | 0 | ocorre |
| `[Media] healed published card` | 0 | **1** (o heal funcionou ponta a ponta) |

O segundo defeito, que a rolagem expôs e que é maior que o timing: **168 retries voltaram em 1 ms sem
imagem** (`deferred-retry item=… ms=1 image=0`). A causa é o `resolveImageAsset` do pipeline de produção:
ele só usava `item.bestImageURL` e devolvia `nil` imediatamente para todo item cuja arte vive apenas na
página do artigo — e o retry diferido chamava *a mesma função*, então essas capas nunca apareceriam, nem
"muito depois". O `ArticleImageResolver` já existia para o caminho legado; agora o pipeline preparado
também o usa (fora do slot de download, sob o mesmo deadline), como fonte `.articleOpenGraph`.

O que sobrou sem arte são páginas que genuinamente não publicam imagem: as 20 ocorrências restantes são
`rawImage=absent articleHost=www.intercom.com — the article page yielded no candidates`.

## 4. Warm start e o cache de página

| cenário | medido |
|---|---|
| relaunch com page-cache em disco | `publishCards firstPaint: items=12 cards=12` **1,2 s** após o launch |
| relaunch com banco populado e **sem** page-cache restaurável | `loadingState: idle → initial`, "Preparing your feed… 0/100", primeiro `page[pipeline]` em **20,1 s** |
| launch com filtro `Podcasts` (sem linhas locais) | `reloadFromSQLite loaded=0`, um vazio selou `.empty` aos 16 s, superfície "No articles found for" aos 41 s, fetch ainda rodando aos 60 s |

O que ocupa esse tempo no caminho lento **não é a taxonomia**: o `loaded=`/`filtered=`/`balanced=` do
`[TaxonomyTrace] reloadFromSQLite` conta **itens do feed** (1851 carregados → 500 balanceados), não nós de
taxonomia. A taxonomia é carregada no boot (`Taxonomy.loadOrBuild`, `FeedStore.swift:2065-2067`) e o
balanceamento roda fora do main actor (`Task.detached`, `:6513`). A fatia de 14–21 s é portanto
consulta ao SQLite + filtro + balanceamento do primeiro pool — e é o próximo item de D1 a instrumentar por
dentro (tempo de query vs de balanceamento), não a taxonomia.

Nos dois caminhos lentos, `page[cache] skip sig=filtered … reason=runway-still-building` gravou a página
publicada (4 e 9 itens) **fora** do cache, então o relaunch seguinte paga o caminho lento de novo.

## 4b. O boot, atribuído pelos signposts do próprio app

`xcrun simctl spawn <udid> log show --signpost --predicate 'subsystem == "com.feedmine.app"'` durante um
launch (16:13:38) dá o que os instrumentos de texto não davam — e a resposta muda o alvo:

| fase | duração | observação |
|---|---|---|
| `FeedStore.init` | **51 ms** | |
| `Eligibility.snapshot` | 1 ms | |
| `OPML.load` | **11 513 ms** | `OPML.fingerprint` < 1 ms · `OPML.cacheRead` **2 879 ms** · derivação restante **~8 634 ms** |
| → evento | | `OPML.sourceCount: count=77443`, memória 192 MB depois do OPML |
| `Taxonomy.loadOrBuild` | **3 053 ms** | `Taxonomy.cacheHit`, `nodes=4745 sources=77443` |
| `ReadState.load` | 187 ms | |
| `Reservoir.load` | 170 ms | inclui `Eligibility.snapshot` de 169 ms |

Total launch → reservatório pronto ≈ **19,8 s**, e depois ~6 s de preparação/publicação. Ou seja: das três
fases grandes, duas são **derivação de dados a partir de um cache** (8,6 s de registry a partir do OPML
cacheado de 77 443 fontes; 3,1 s de taxonomia a partir do cache) e uma é leitura de cache (2,9 s).

Alavancas, em ordem de valor e de risco:

1. **Não re-derivar o registry a cada launch** (~8,6 s): persistir o resultado derivado (lista de fontes +
  estado on/off) em vez de reconstruí-lo do OPML — é mudança de formato de dado, com migração; **não
  improvisar** numa branch de hardening.
2. **Leitura do cache** (2,9 s): o blob do OPML cacheado é lido inteiro no caminho crítico; um formato
  indexado (ou leitura em background com o registry publicado como snapshot pronto) tiraria isso da frente
  do primeiro paint.
3. **Taxonomia** (3,1 s): já é cache hit; só ajuda junto com (1), porque a ordem é OPML → taxonomia.

### 4c. Os instrumentos que faltavam, e o veredito de congelar

O ChatGPT chamou a decisão de arquitetura de volta — *"Sim — isso muda minha recomendação. Eu congelaria
a ideia de mudar a arquitetura do boot por enquanto"* — e pediu duas coisas: (i) decompor OPML/taxonomia
**sob disco saudável** antes de migrar dado, porque com I/O pressionado até fases "de CPU" (decode de 77
mil objetos, `deriveCaches`) podem estar gastando o tempo em page faults; e (ii) carimbar a capacidade
livre em toda medição.

Feito o que não exige migrar dado:

* **`[PerfEnv]`** no boot, com o dado que faltava em todas as medições anteriores:
  `freeImportant=2.8 GB freeAvailable=2.8 GB physicalMemory=17.18 GB lowPower=0 thermal=0`. Um tempo sem
  esse carimbo não é comparável com nenhuma outra execução (§8);
* **`[PerfEnv] deriveCaches sources=77443 ms=2344`** — o suspeito principal do trecho pós-cache do
  `OPML.load` custou **2 344 ms** a 2,8 GB livres, num `Task.detached` (fora do main actor). O resto do
  pós-cache (~8,6 s a 1,4 GB livres) fica com o decode do `OPMLParser.parseAll()`, que é o próximo
  sub-fase a separar (`fileRead` → `decode` → `deriveCaches`, na ordem que ele propôs).

### 4d. Uma duplicação removida — e a recusa de vender ganho

`SourceRegistry.loadFromOPML()` terminava com `recomputeActiveCounts()` **depois** de `loadState()`, que já
termina nessa mesma chamada e deixa `activeCountsAreCurrent == true`, e **depois** de
`prepareFilterCaches()`, cujo `ensureActiveCounts()` é no-op nesse estado. Só o primeiro launch (em que o
bloco de "countries off by default" mexe em `disabled` *após* o `loadState`) precisa da segunda passada.
Removida essa duplicação nos demais launches (uma varredura de 77 443 fontes a menos, por princípio).

Medido em seguida, 2 boots no mesmo simulador:

| boot | `OPML.load` | ↳ cacheRead | ↳ derivação | `Taxonomy.loadOrBuild` | `Reservoir.load` | total launch→reservoir |
|---|---|---|---|---|---|---|
| 16:21 (antes) | 9 843 ms | 2 238 ms | 7 605 ms | 7 288 ms | 238 ms | ~19,3 s |
| 16:24 (depois) | 12 280 ms | 1 692 ms | 10 587 ms | 2 853 ms | 168 ms | ~19,5 s |

**Nenhum ganho é demonstrável com n=2**: a variância das fases (taxonomia de 2,9 a 7,3 s entre as duas
execuções) domina qualquer efeito. O que fica registrado é a correção em si (trabalho redundante
eliminado) e a conclusão de método: **mesmo o boot precisa de n≥3 por configuração** antes de afirmar
qualquer coisa sobre tempo.

## 5. Instrumentação deixada no app

| ponto | onde |
|---|---|
| `[LoadMore] serve\|skip\|no-growth\|fetch from tail` | `FeedStore.loadMoreIfNeeded` |
| `[Viewport] ids/first/last/sent/ownsAcq/pageSource` | `MainFeedRuntime.viewportChanged` |
| `[Append] no-growth moved/filtered/published/reservoir` | `FeedStore.applyUpdate(.append)` |
| `[Fetch] batch empty pool/region/type/runway/visible/reservoir` | `FeedStore.fetchNextBatch` |
| `[SetVisible] refused an empty answer…` | `FeedStore.setVisibleItems` |
| `fetchStarter return … deadlineMs/deadlineFiredMs/returnMs/drainMs` | `RSSFetcher.fetchStarter` |
| `[Reload] phases dbMs/mapMs/filterMs/balanceMs/interleaveMs/totalMs` | `FeedStore.reloadFromSQLite` |
| `[Media] healed published card item=…` | `FeedStore.healPublishedMedia` |
| `resolve outcome=memory\|shared\|disk\|download\|error\|miss ms=… bytes=… host=…` | `ImageLog.resolveTiming` (agora com call sites em `MediaAssetStore`) |
| `prepare item=… index=… outcome=image\|placeholder\|none ms=…` | `ImageLog.prepareOutcome` (`CardPreparationCoordinator.prepareItem`) |
| `deferred-retry item=… ms=… image=0\|1` | `ImageLog.deferredRetry` |

## 6. Em aberto (medido, não corrigido)

* **O deadline do `fetchStarter` não dispara** (`deadlineFiredMs=-1` com `deadlineMs=10000` e
  `returnMs=27078`): o prazo existe no laço de eventos mas o retorno é governado pelos filhos restantes.
  É o maior candidato isolado de D1, e é uma correção de concorrência, não de política.
* **`append→flush` variou de 1 ms a 30 460 ms**: o hop depois do bootstrap precisa de medição própria.
* **O primeiro pool lento** (14–21 s entre "Preparing your feed…" e a primeira página no caminho sem
  page-cache): **não é o pipeline local** — as fases medidas somam 1 039 ms (§8); o tempo é o boot (§4b:
  `OPML.load` 11,5 s + `Taxonomy.loadOrBuild` 3,1 s) mais a preparação dos cards (~6 s).
* **A variância**: qualquer ganho de tempo precisa de n≥3 execuções por configuração.
* `page[cache] skip reason=runway-still-building` deixa a página publicada fora do cache.
* `RSSFetcher` não separa `httpMs` de `parseMs`/`audioValidationMs` (o `elapsedMs` existente termina antes
  do parse e do `validateAudio()`, que faz até 12 probes com 6 concorrentes e 6 s cada em podcast).
* **Caminho V2**: com `ownsAcquisition == true` a superfície desenha o *session snapshot* e o heal em
  `FeedDisplayState.visibleCards` não a alcança — a correção de D2 vale para o launch legacy, que é o que
  embarca no 1.0.

### 6.1 Pendências declaradas: categorias sem card (run 2 do agente)

Os testes de categoria reprovados com "no cards visible after 30 s" foram checados contra o catálogo
(`feedmine.app/catalog.sqlite`) e contra o que está ingerido (`feed_item`), com normalização de URL (o app
guarda `source_url` normalizada; o catálogo guarda `request_url` — um `where` exato devolve 0 em silêncio,
o que me custou duas consultas erradas antes de acertar):

| categoria | fontes no catálogo | itens ingeridos |
|---|---|---|
| `Acoustics & Sound` | 6 | **10** |
| `Cooking & Recipes` | 1 355 | **82** |
| `Visual Arts` | 667 | **34** |
| `Mythology` | 438 | **30** |

Ou seja: **há conteúdo** para as quatro, e mesmo assim as quatro reprovam esperando 30 s. O que os
próprios testes do repo dizem sobre esse teto: os testes unitários de taxonomia do `FeedStoreTests`
esperam a publicação com `while store.visibleItems.isEmpty && Date() < deadline` e **deadline de 30 s** —
o mesmo teto do teste de UI. Ou seja, o caminho do filtro de taxonomia é **conhecido por ser de escala de
dezenas de segundos**, e numa máquina sob pressão de disco ele fica marginal. Isso reclassifica as quatro
falhas de "o filtro quebrou" para "o caminho é lento e o teto é apertado" — e é medível: o `[Reload]
phases` de uma composição de taxonomia é o próximo dado a colher.

O caminho **foi medido** e está correto — o que estava errado era o meu harness. `xcrun simctl spawn …
defaults write com.feedmine.app …` **não alcança o domínio que o app lê** (a prova: o shell mostrava
`filterTaxonomyNodes = ["04_technology_&_science/acoustics_and_sound"]` e o app logava
`[FilterPersist] taxonomyNodes=0`). Escrevendo o plist do container direto e reiniciando o `cfprefsd`:

```bash
D=$(xcrun simctl get_app_container <udid> com.feedmine.app data)
plutil -replace filterTaxonomyNodes -json '["04_technology_&_science/acoustics_and_sound"]' \
  "$D/Library/Preferences/com.feedmine.app.plist"
xcrun simctl spawn <udid> killall cfprefsd
```

o resultado é o oposto do que as falhas sugeriam:

```
[FilterPersist] taxonomyNodes=1 languages=0 type=All
[FilterRestore] saved=1 valid=1 active=1 taxonomyURLs=6 ids=04_technology_&_science/acoustics_and_sound
[TaxonomyTrace] reloadFromSQLite gen=0 loaded=10 filtered=10 balanced=10 taxonomyURLs=6
page[pipeline] items=10 withMedia=8   →   publishCards firstPaint: items=10 cards=10
```

**O filtro de taxonomia funciona**: o nó resolveu 6 fontes, o reload trouxe exatamente os 10 itens que o
banco tinha para ele, e a página saiu com 10 cards (8 com imagem) em ~12 s do launch. As quatro falhas do
run 2 são portanto **tempo** — caminho lento sob máquina carregada e disco cheio, com um teto de 30 s que
o próprio repo usa — e não defeito do filtro. O identificador também está resolvido:
`slug` cru do diretório (`04_technology_&_science`, com `&` e `_`) + `category` com `&`→`and` e espaço→`_`.

### 6.2 Corrigido depois de aberto

* **O chip do header mentia** (`· 0/77443 sources` numa sessão buscando 240 fontes). Causa: `activeSourceCount`
  cacheia `activeSources.count` por *filter generation*, e essa geração **não muda** quando o OPML termina
  de carregar — o `0` calculado com o registry vazio congelava para a sessão. O cache agora também é
  chaveado pelo tamanho do registry. Verificado pelo log do app no mesmo launch:
  `· 0/77443` (16:16:49) → `none` (16:16:51, o guard de "0/0") → **`·71234/77443 sources`** (16:17:16).

## 8. Custo de uma composição filtrada (a varredura de eixos, reinterpretada)

A varredura de 80 casos reportou `content_wait_ms` de 1,4 s a 8,6 s e **8 idiomas "sem card em 8 s"**
(es, fr, it, nl, cs, ro, sv, el). Investigando um deles diretamente:

* o banco **tem** conteúdo: 413 itens `es`, 76 `fr`, 79 `nl`, 59 `it` no `feed_item` (5 284 no total);
* com `filterLanguages=[es]` e sem page-cache para essa assinatura, o app publica **20 itens em 23 s**:

  ```
  15:59:59.1  reloadFromSQLite gen=0 loaded=1854 filtered=1829 balanced=500
  16:00:05.4  page[pipeline] items=20 withMedia=14  →  publishCards firstPaint: items=20 cards=20
  ```

Ou seja: o achado não é "o filtro não tem conteúdo" nem "o filtro quebrou" — é **tempo**. E o tempo **não**
está no pipeline local: instrumentando as fases do `reloadFromSQLite` com o mesmo filtro `es`,

```
[Reload] phases dbMs=122 mapMs=223 filterMs=287 balanceMs=28 interleaveMs=375 totalMs=1039
         items=2603 filtered=2526 balanced=500
```

**1,04 s** para ler 2603 itens do SQLite, filtrar 2526, balancear 500 e intercalar. O que consome os ~20 s
é o que vem **antes e depois** desse pipeline:

> **Cuidado que se provou necessário — e o A/B que o fecha.** A mesma leitura foi medida três vezes:
> `dbMs=122` (2 603 itens, volume com folga) → **`dbMs=24 894`** (3 892 itens, 1,4 GiB livres:
> `mapMs=172 filterMs=71 balanceMs=25 interleaveMs=1978 totalMs=27143`) → **`dbMs=128`** (4 837 itens,
> 2,7 GiB livres: `mapMs=257 filterMs=187 balanceMs=37 interleaveMs=244 totalMs=858`). **194× na mesma
> consulta**, com *mais* itens lidos na medição rápida. O que mudou entre a segunda e a terceira foi
> apenas eu apagar o `DerivedData` do projeto (+0,7 GB livres). Consequências:
>
> * o caminho local está **exonerado** (858 ms para 4 837 itens quando há folga de disco);
> * **todos os tempos deste documento foram medidos sob pressão de I/O** e estão inflados — a leitura
>   absoluta não vale, a atribuição vale;
> * o mesmo vale para o cold start: nesta última execução, launch → reload 12,8 s → **página de 20 itens
>   com 19 de mídia em 19,1 s**, contra 23–38 s medidos antes.

* antes: o caminho de boot (OPML/registry — `sourcesMs≈3,5 s` para 240 fontes de um catálogo de ~26 MB em
  118 arquivos — mais taxonomia/caches), medido em 10–17 s entre "Preparing your feed…" e o início do
  reload;
* depois: ~6,4 s entre o reload e `page[pipeline] items=20` (preparação dos cards + a janela da promoção).

Consequência prática: **o maior item de espera visível que sobrou é o boot, não o filtro** — e a alavanca
é o carregamento do registro de fontes, não o SQLite. `[INFERENCE]` a troca de filtro a quente percorre a
mesma função (`reloadFromSQLite` com `generation != 0`; `skipRead` só é usado num caminho de settings) e
portanto custa ~1 s de pipeline + preparação, não 20 s — os `content_wait_ms` de até 8,6 s da varredura
são a preparação/publicação dos cards, não a leitura.


## 9. Verificação

* **Gate unitário (`feedmineTests`), com a árvore final**: `Executed 612 tests, with 0 failures` e
  `** TEST EXECUTE SUCCEEDED **` — a execução final foi com o `DerivedData` padrão (o mesmo que
  `scripts/release-acceptance.sh` usa), no iPhone 17 Pro Max. Nenhum arquivo de código mudou depois dela
  (as alterações seguintes foram só neste documento).
* **Cold start com a árvore final — 2 séries de 3 execuções limpas** (`iPhone 17 Pro Max`, `simctl
  uninstall` + `install` + `launch -UITestSkipOnboarding` por run):

  | série | livre no volume | primeiro paint | itens | fetch | `withheld` | tela de vazio |
  |---|---|---|---|---|---|---|
  | A | 2,0 GiB | 29,0 / 33,0 / 29,4 s (mediana 29,4) | 6 / 13 / 13 | 15,4–17,2 s | 0 | 0 |
  | B | 2,9 GiB | **30 / 27 / 27 s (mediana 27)** | 13 / 13 / 13 | **11,4–13,5 s** | 0 | 0 |

  A série B é a que vale como número: mesma árvore, mais folga de disco, **dispersão de ±3 s** (contra ±4 s
  em A e 35–83 s nas primeiras execuções sob pressão), página estável de 13 itens e o fetch mais rápido
  medido. Contra o baseline: 54,2 s no log da jornada de UI e **83,2 s** de TTFF medidos pela automação do
  agente na árvore anterior às correções.

* Duas execuções de gate anteriores com 1 e 3 falhas foram tratadas como evidência de contrato, não como
  ruído: a primeira fixava a política antiga do gate (reescrita para o novo contrato); a segunda mostrou
  que corrigir o vazio *no display* estava errado — `settlesPhase` é a afirmação do chamador, então a
  correção foi movida para o `FeedStore`; a terceira mostrou que a primeira versão do cancelamento
  reclassificava uma resposta servida como falha, e o desfecho `.modifiedWithNewItems` foi preservado.
* **Automação de UI**: `scripts/validation/run_ui_matrix.sh`, relatório em
  `Artifacts/Validation/Results/` (ver §1b).
