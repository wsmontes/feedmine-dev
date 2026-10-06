# Registro de defeitos — Feedmine 1.0 (code review)

Fonte: revisão própria (OMP) + 4 revisores locais independentes + worker com acesso ao repo.
Cada linha: severidade, local exato, o que está errado, por que importa ao usuário, correção mínima.
Regra: nenhum achado sem linha lida. O que não foi verificado está marcado.

## Achados do OMP (lidos por mim, no HEAD 70f7b06b)

| ID | Sev | Local | O que está errado | Impacto no usuário | Correção mínima |
|---|---|---|---|---|---|
| OMP-1 | ALTO | `feedmine/Services/FeedStore.swift:1776-1779` | `let storedItemCount = (try? db.read { COUNT(*) FROM feed_item }) ?? 0` converte **falha de leitura em zero**; `guard storedItemCount == 0` trata isso como "instalação nova" e então reescreve `activeLanguages`, `Settings.filterLanguages` e `Settings.hasInitializedLanguageDefault = true` (linhas 1782-1785) | Um erro transitório do SQLite no launch (busy/WAL/corrupção) **sobrescreve as preferências de idioma e filtros** de quem já usava o app | Separar falha de vazio: `do { count = try db.read {...} } catch { Log.db.error(...); return nil }`; só seguir quando a leitura **teve sucesso e deu 0** |
| OMP-2 | MÉDIO | `feedmine/Services/FeedStore.swift:1183` | `try? db.write { ... INSERT bookmark_list 'Favorites' ... }` engole a falha de escrita — enquanto o bloco imediatamente acima (1177-1181) **registra** o erro da migração | Lista "Favorites" pode não existir e o código a jusante assume que existe; falha invisível em diagnóstico | Trocar por `do/catch` com `Log.db.error` e uma flag de estado; não engolir escrita de dado do usuário |
| OMP-3 | MÉDIO | `feedmine/Services/FeedStore.swift` — `try? await Task.sleep(...)` em ~14 pontos (1053, 2282, 2287, 3028, 3102, 3416, 4459, 4834, 5049, 5212, 5216, 5239, ...) | `sleep` lança em cancelamento; `try?` engole e o laço **continua trabalhando** depois do cancelamento, porque não há `Task.isCancelled` | Trabalho de fundo que devia morrer segue rodando e mexendo em estado (churn em teardown/troca de filtro) | `do { try await Task.sleep(...) } catch { return }` ou `guard !Task.isCancelled else { return }` |
| OMP-4 | INFO | `try!` 14× (`ImageCache.swift:422-442`, `RSSFetcher.swift:1389-1417`) e `fatalError()` 1× (`ShakeHandler.swift:21`) | **Verificado benigno**: regex com padrão literal compilado uma vez e `required init?(coder:)`. Não é defeito | — | nenhuma |
| OMP-5 | ALTO (latente) | `feedmine/RuntimeV2/UserStateBridge.swift:368-379,409-410,429` | Leituras com `(try? await ...) ?? []` fazem erro transitório parecer "nada pendente"; `try? await bookmarks.markOperation(..., .applied)` conta como aplicado sem garantir o estado durável | O laço de reconciliação de bookmarks pode reportar **0 pendentes / tudo aplicado** enquanto a projeção está atrasada; a recuperação deixa de acontecer em silêncio. Hoje o launch é `.legacy`, então o impacto é **latente** — vira defeito do usuário quando a lane V2 for ligada | Separar falha de vazio nas leituras (do/catch + log + abortar o ciclo) e só contar `applied` depois do `markOperation` ter sucesso |
| OMP-6 | MÉDIO | `feedmine/Services/FeedStore.swift:1967 + 1773-1795` vs `:2030-2041` | **Duas políticas concorrentes para o idioma de primeira execução.** A de `startFirstLaunchBootstrapIfNeeded` (chamada em `:1967`, antes de `registry.loadFromOPML()`) grava `activeLanguages = [deviceLang]`, `Settings.filterLanguages = [deviceLang]` e `hasInitializedLanguageDefault = true` de forma **síncrona e sem checar se o idioma existe no catálogo**. A segunda (:2030) checa `availableLangs.contains(lang)` — mas é **inalcançável no caminho comum**, porque a flag já está true | Nondeterminismo de dono + checagem de disponibilidade morta. Impacto medido: `activeLanguages` filtra de verdade (`AdaptiveScheduler.swift:95-99` pula fontes; `FeedLoader.swift:106` descarta itens, inclusive os de idioma ausente/indefinido — 27 741 entradas `und` no corpus). **Não consegui repro de feed vazio**: o catálogo cobre ~100 idiomas (ja 440, ko 105, hi 194…), então o dano realista é feed **mais raso** para locales de cauda longa | Fazer **um** dono: o bootstrap deixa de persistir idioma/filtro (usa o idioma só para as fontes que busca) e a decisão fica com o bloco pós-registry, que já tem a checagem `availableLangs` |



## Correções aplicadas (não commitadas) — HEAD 70f7b06b + worktree

| Defeito | Arquivo | Correção | Prova |
|---|---|---|---|
| OMP-1 | `feedmine/Services/FeedStore.swift:1775-1786` | `try? db.read { COUNT(*) }` → `do/catch` com `Log.db.error` e retorno antecipado: falha de leitura não é mais tratada como banco vazio (não sobrescreve idioma/filtros) | pendente de build |
| CR-02 | `feedmine/Services/AudioPlayerManager.swift:364-368` e `:469-475` | `currentTime` só recebe `time.seconds` quando `isFinite`; `formatTime` ganha `guard t.isFinite else { return "0:00" }` — `Int(NaN)` não aborta mais | pendente de build |
| P-02 | `feedmine/Services/FeedStore.swift:4796-4810` | antes do `record.update(db)` do refresh, o record carrega o estado do leitor da linha existente (`fetchOne(db, key:)`) — um refresh de entrada Atom não desmarca mais o que foi lido/consumido | **teste novo**: `feedmineTests/FeedStoreTests.swift` → `testAtomEntryRefreshPreservesReaderState` (falha antes, passa depois) |
| S-01 | `feedmine/Views/FeedItemCardView.swift:515-523` | "Open in Safari" só abre quando o scheme é `http`/`https`; link de terceiro não roteia para outro app | pendente de build |

Não aplicados (registrados para decisão): P-01 (`initError` escrito e nunca lido; fallback in-memory silencioso mascara falha de init — precisa de superfície de UI), P-03, P-04, S-02 (fail-open da assinatura do catálogo), S-03..S-07, CR-01 (vetor exige `+inf`; verificar `att.durationInSeconds`), OMP-2..OMP-6.


## Prova executada (2026-10-06, simulador iPhone 16, `.build-dd`)

**P-02 ganhou prova de regressão nos dois sentidos** (`xcodebuild test -only-testing:feedmineTests/FeedStoreTests/testAtomEntryRefreshPreservesReaderState`):

- **Com a correção**: `Test Case ... passed (0.194 seconds)` → `** TEST SUCCEEDED **` (job bg_137).
- **Sem a correção** (preservação temporariamente removida): `XCTAssertEqual failed: Optional(0) is not equal to Optional(1) - an Atom refresh must not un-read the item` e `XCTAssertNotNil failed - an Atom refresh must keep the consume stamp` → `** TEST FAILED **` (job bg_138).
- Correção restaurada e teste re-executado para confirmar que a restauração é exata.

Isso confirma o defeito como **reproduzível** (não é leitura estilística): o refresh de entrada Atom realmente grava `is_read = 0` e `consumed_at = NULL`.

Os outros quatro consertos (OMP-1, CR-02 ×2, S-01) **compilam no alvo do app** — o build da suíte de testes constrói o app inteiro — mas não têm teste dedicado; a verificação deles é a compilação + leitura da linha.


## Correções preparadas (aguardando janela de build — a barra de aceitação está compilando)

Não editei durante a execução de `release-acceptance.sh`: as três gates dela têm de medir **a mesma árvore**, e um edit no meio invalidaria a evidência.

| Defeito | Local | Correção preparada | Fundamento |
|---|---|---|---|
| C-04 (verificado) | `RSSFetcher.swift:137-140` + `AdaptiveScheduler.swift:311-312` | (1) novo caso `cancelled` em `FeedFetchOutcome` (`Models/FetchOutcome.swift`) no mesmo espírito documentado de `.legacyProducerClosed`; (2) `RSSFetcher` devolve `.cancelled` em vez de `.failed(CancellationError())`; (3) `AdaptiveScheduler` ignora `.cancelled` como ignora `.legacyProducerClosed` | Um cancelamento (app em background, troca de filtro) **hoje incrementa o contador de falhas** e empurra a fonte para backoff de até **86 400 s (24 h)** — o app "para de atualizar" sem nada de errado com o feed. O próprio arquivo já documenta que dobrar um pedido recusado em `.failed` "penalizaria a fonte por uma requisição que o modo recusou fazer"; cancelamento é o mesmo caso e foi esquecido |
| P-03 (verificado) | `Packages/FeedRuntimeV2/.../Retention/RetentionPolicy.swift:282` | `subjects.formUnion(try authority.savedBookmarkSubjects())` — propagar em vez de engolir | O comentário acima da linha diz que a união é **deliberada** porque "um subject que a autoridade tem e a projeção não é um bookmark que existe"; o `try?` derruba exatamente essa metade quando a leitura falha → GC pode purgar edição com bookmark. Latente para o 1.0 (lane V2) |
| S-02 (verificado) | `CatalogUpdateService.swift:51,119-121` | tornar o canal remoto **fechado** quando `publicKeyHex` está vazio (recusar a atualização em vez de "verificação passa") | Fail-open: hoje a verificação retorna cedo e aceita o manifesto; o comentário diz que o canal remoto não é usado no 1.0 — o código deve *recusar*, não *aceitar* |

### Avaliado e *não* aplicado de propósito

- **C-06** (`MediaAssetStore.resolve`, `MediaAssetStore.swift:52-58`): verificado por leitura — com uma task em voo para a mesma chave, o segundo chamador faz `try? await task.value` numa **task compartilhada**, e o `await` não observa o cancelamento de quem espera; quem foi cancelado continua esperando a resolução alheia (página inicial truncada, slot do limiter preso). **Não é one-liner**: o conserto correto é um helper que corra cancelamento × task compartilhada (sem cancelar a task dos outros) e um teste próprio. Remendar aqui — por exemplo cancelando a task compartilhada — quebraria os demais chamadores. Fica registrado para entrar com desenho, não com pressa.

### S-02 — tentado, **revertido** pela própria barra (decisão de produto, não conserto)

Apliquei o fail-closed no `CatalogUpdateService.verifySignature` (canal remoto sem `publicKeyHex` passaria a `throw`) e re-executei `release-acceptance.sh`. Resultado: **`== BAR FALHOU ==`** com 3 testes vermelhos em três gates consecutivos:

- `CatalogUpdateServiceTests.testManifestValidatesWithEmptyKeyAndEmptySignature`
- `testManifestDecodesWithoutSignatureField`
- `testChecksumFailureKeepsBundledSnapshotActive`

Os testes **pinam o comportamento deliberado**: o comentário do próprio arquivo diz que *"Release 1.0 does not use the remote update channel in production. The empty key therefore remains a development-only concern until that channel is explicitly re-enabled in a later release."* Aceitar manifesto sem assinatura **enquanto a chave está vazia** é a política documentada — não um descuido.

**Revertido.** Trocar essa política é decisão de produto/segurança do dono (há três testes que a fixam), não um conserto que eu deva empurrar. O achado do revisor de segurança continua **válido como recomendação**: se o canal remoto for algum dia ligado, a verificação tem de ser obrigatória — e, no estado atual, ligar o canal sem provisionar a chave aceita manifesto não assinado.

Lição de método registrada: foi a **barra de produto** que pegou isto, não a leitura. Um conserto que muda política aparece como teste vermelho — e é aí que se para e se devolve a decisão.

## Segunda leva de consertos (2026-10-06, worktree — 10 no total)

| # | Defeito | Arquivo | Correção | Verificação |
|---|---|---|---|---|
| 8 | **CR-01** (vetor de crash remoto) | `feedmine/Models/FeedItem.swift:226-229` | `durationFormatted` passa a exigir `d.isFinite`: `d >= 60` é falso para NaN mas **verdadeiro para +inf**, e `Int(inf)` aborta — a duração vem de metadados do feed | leitura da linha + build |
| 9 | **C-07** (dedup de download quebrada) | `feedmine/Services/ImageCache.swift:918-923` | honra o retorno de `registerDownload` (que é `false` quando outro download já registrou o URL): só quem registrou desregistra, em vez de derrubar a marca do download alheio no `defer` e liberar um terceiro para baixar de novo | leitura da assinatura + doc do método + build |
| 10 | **OMP-2** | `feedmine/Services/FeedStore.swift:1182-1198` | `try? db.write` da lista "Favorites" vira `do/catch` com `Log.db.error` (o bloco logo acima já registrava o próprio erro — era inconsistente engolir este) | build |

Observação de plano: CR-01 só vira crash com `duration = +inf`, que `extractDuration` (Int) não produz — o vetor exige um feed cujo campo de duração venha como número não-finito (`att.durationInSeconds`, FeedKit). Mantive a correção porque é uma guarda de uma linha num formatador que **também** é chamado com valores derivados do player, e porque `Int(_:)` abortando por dado de rede é a classe de defeito que não se quer embarcar.

## Barra com os 10 consertos — e a flakiness documentada pelo próprio repo (2026-10-06)

Execução `== acceptance bar start 05:14:33 ==`: `build-erros: 0`; **gate 1 = 609/0** e **gate 2 = 609/0** verdes; **gate 3 = 609 com 1 falha** em `MainFeedRuntimeV2Tests.testViewportReplenishmentUsesTheObservationAndNothingElse`; jornada **17/17**.

Verifiquei antes de chamar de flaky:

1. rodei o teste **isolado 3×** → passa sempre (0,007 / 0,013 / 0,009 s);
2. **o repo documenta a classe**: `docs/runtime-v2/baseline.md:1462` — *"(1) `MainFeedRuntimeV2Tests` has a **latent order dependence**"* — e `:1502` — *"The suite's own defect: a latent order dependence"*. É o mesmo achado 10 que a barra imprime como aberto ("green under 30s deadline tolerance") e que faz o próprio repo registrar o gate **por execução**, não como propriedade;
3. meus 10 consertos não tocam o caminho de viewport/replenishment (memória de leitura, cancelamento de tempo de áudio, contagem de itens, scheme de link, folga de retenção, formatação de duração, dedup de download, lista padrão).

Conclusão: falha de **ordem/estado entre testes**, não regressão. A barra completa já tinha fechado `BAR OK` com 7 dos consertos; com 10, as duas primeiras gates ficaram verdes e a terceira caiu na classe documentada.

### C-02 — verificado e **reclassificado para latente (código morto)**

`feedmine/Services/Reservoir.swift:236 shakeReshuffle()` **não é chamada em lugar nenhum do repo** (grep só encontra a definição). O defeito é real — ela captura `reservoir` por valor, interleaveia fora do main e depois **atribui** `self.reservoir = result`, descartando o que tiver sido anexado durante a janela — mas hoje é inalcançável. Não removi o código (não é meu); fica registrado como armadilha para quem for ligá-lo.

## Terceira leva — CR-08 (crescimento sem limite no caminho que embarca)

`feedmine/Services/ImageCache.swift` (`actor ArticleImageResolver`): `resolved`, `misses` e `htmlByteCounts` são chaveados por **toda URL de artigo já vista** e nunca eram podados — `misses` tinha TTL para *leitura*, mas as entradas expiradas ficavam para sempre, e `resetMiss(for:)` só removia uma por vez. O corpo da requisição já era limitado (`session.bytes` + `maxHTMLBytes`), então o defeito era só de memória: uma sessão longa acumulava três dicionários proporcionais ao número de artigos abertos.

**Correção:** `maxTrackedArticles = 256` + `pruneIfNeeded()` (poda os três mapas para o teto) chamado na entrada de `imageURLs(for:replacing:)`, que é o único caminho que cresce. Poda descarta chaves arbitrárias — é cache, então o efeito de descartar é re-resolver, não perder dado do usuário.

Verificação: bar de produto (compilação do alvo + 3×609).

### Segunda classe de flake, medida: o passo do reader na jornada

A barra com o fix #11 (CR-08) fechou **gate 1/2/3 = 609/0** mas a **jornada** deu `15/17 ausentes=[03-article-reader 04-article-scrolled]` → `BAR FALHOU`. Antes de culpar o prune, rodei `scripts/release-journey.sh` **isolado duas vezes**: `17/17`, `JORNADA OK`, exit 0 nas duas.

Por que é flake e não o meu código:
1. o mesmo código de 11 consertos dá 17/17 isolado, e a barra anterior (10 consertos, sem o prune) já tinha dado 17/17;
2. as superfícies ausentes são exatamente as do **corpo do artigo renderizado em WebView** — o próprio `PersonaExplorationUITests.swift:80-84` distingue isso e imprime `reader_blank=1` / `"reader presented but its body never rendered"`, ou seja, o teste já modela a dependência de rede/tempo;
3. o prune só evicta entradas de cache acima de 256 — não tem como impedir o corpo do artigo de renderizar.

Consequência prática: **a barra de produto é sensível a conteúdo/rede em dois passos** (o reader da jornada e a classe deadline-budget dos unit gates). O repo já registra isso para os gates ("recorded per run rather than as a standing property"); a novidade é a mesma natureza aparecer na jornada. Quem for usar isto como critério de release deve rodar o bar e, em caso de falha isolada, repetir **o passo** — não aceitar como verde nem tratar como regressão.

### CR-08 — tentado, revertido: **um fix de cache não se paga se coincide com falha de gate de produto**

Apliquei o teto de 256 entradas + `pruneIfNeeded()` no `ArticleImageResolver` e rodei a barra. Resultado, cronológico:

| Execução | Código | Unit gates | Jornada |
|---|---|---|---|
| 05:38 | 10 consertos (sem o prune) | 609/0 ×3 | **17/17** ✓ |
| 05:42 | 11 (+ prune) | 609/0 ×3 | **15/17** — ausentes `03-article-reader`, `04-article-scrolled` |
| 06:02 | 11 (+ prune) | 609/0 ×3 | **15/17** — as mesmas duas |
| jornada isolada ×2 | 11 (+ prune) | — | **17/17** em ambas |

A correlação é fraca (1 passa antes, 2 falham depois; e isolada passa), mas o prune é o **único delta**, e o passo que falha é o corpo do artigo em WebView — exatamente onde uma evicção de cache mudaria o tempo de prontidão do card. Como CR-08 é crescimento de memória (qualidade), **não vale** um conserto que coincide com falha de gate de produto: revertido (helper e chamada removidos, sem deixar código morto meu) e a barra re-executada para o teste decisivo — se a jornada voltar a 17/17 sem o prune, fica fora; se continuar em 15/17, o prune está exonerado e o problema é o passo do reader **depois dos três unit gates**, que passa a ser um achado próprio (e o mais interessante da noite, porque significa que a própria barra contamina a jornada).

**Não aplicado até o teste fechar.** O que fica escrito: um candidato rejeitado com o motivo medido, em vez de um conserto teimoso.

**Teste decisivo (06:14, sem o prune, 10 consertos):** gate 1/2 = 609/0; gate 3 = 1 falha na **classe documentada** (`FeedComposerPreviewTests.testPreviewPerformance`, 15,2 s contra budget de 1,5 s — o mesmo teste que `docs/release/1.0-checklist.md:329` já registra como *"passes standalone in 0.361 s"*); **JORNADA = 17/17**. 

Placar do prune, dentro da barra: **sem = 2/2 jornada 17/17; com = 2/2 jornada 15/17**. Amostra pequena, mas o padrão aponta na mesma direção e o custo de manter é maior que o benefício: **CR-08 fica fora do trabalho**, registrado como *tentado e rejeitado com medição*.

**Achado próprio que sobra:** a jornada falha no passo do reader **quando roda depois dos três unit gates**, e passa isolada. Vale investigar um dia (a barra limpa o contêiner entre gates, mas algo entre gates e jornada degrada o passo do artigo); por ora, quem usar a barra como critério deve repetir o *passo* que falhou, não o bar inteiro, e nunca tratar falha isolada como verde nem como regressão.

## Quarta leva — os corpos de rede sem teto (CR-03, CR-09), pela convenção que já existia

O repo **já tinha** o mecanismo: `URLResolver.swift` declara `DownloadLimit` (tetos por tipo: HTML de descoberta 256 KB, probe de feed 64 KB, import OPML 10 MB) e um `boundedDownload(from:maxBytes:session:)` que checa `Content-Length` **antes** do primeiro byte e streama com corte. O defeito era **uso inconsistente**: o próprio arquivo bypassava o helper na linha do iTunes Lookup, e o `ImageLoader` baixava imagem com `session.data` sem teto.

| # | Defeito | Arquivo | Correção |
|---|---|---|---|
| 11 | CR-09 | `URLResolver.swift:501` | a resposta do iTunes Lookup passa a usar `boundedDownload` (`DownloadLimit.lookupJSON` = 1 MB) — era o único ponto do arquivo fora da convenção |
| 12 | CR-03 | `ImageLoader.swift:56` | a imagem do feed passa a usar `boundedDownload` (`DownloadLimit.image` = 12 MB), em vez de `session.data` bufferizando o corpo inteiro |

Mudanças de apoio: `DownloadLimit` e `boundedDownload` deixaram de ser `private` (mesmo módulo, um mecanismo só) e ganharam os dois tetos novos. Não inventei um segundo mecanismo de corte: reusar o existente é o que mantém a convenção verificável.

Verificação: bar de produto — **atenção ao precedente do CR-08**: se a jornada degradar (o caminho de imagem é exercitado por ela), estes dois também voltam atrás.

### CR-03 — tentado e rejeitado; CR-09 — mantido (veredito da barra)

Apliquei os dois tetos (CR-09 no iTunes Lookup, CR-03 no download de imagem) e rodei a barra: gates 609/0 ×3, mas **jornada 15/17** (ausentes `03-article-reader`, `04-article-scrolled`). Revertendo **só o CR-03** (o teto de imagem), a mesma barra fechou **`BAR OK 06:51:11`** com **jornada 17/17**.

Placar dentro da barra — sempre o mesmo par de superfícies do reader:

| Mudança no caminho de imagem | Jornada na barra |
|---|---|
| nenhuma (10 consertos) | 17/17 (05:38), 17/17 (06:14) |
| + prune (CR-08) | 15/17 (05:42), 15/17 (06:02) |
| + teto de imagem (CR-03) | 15/17 (06:27) |
| teto de imagem revertido | **17/17 (06:39)** ✓ |

3/3 de falha quando eu mexo no caminho de imagem, 3/3 de passe quando não mexo — padrão consistente **dentro da barra**. As jornadas isoladas passavam com o prune (17/17 ×2), o que diz que a degradação precisa do estado/pressão acumulados pelos três unit gates, e que qualquer perturbação de tempo no caminho de imagem a inclina.

**Decisão:** CR-03 fica **fora** — é robustez contra feed hostil, não bloqueia publicar, e o custo é justamente o risco que a barra existe para pegar. CR-09 **fica** (não é caminho de imagem; a barra verde de 06:39 e 06:51 o inclui): o iTunes Lookup deixa de ser o único ponto do arquivo fora da convenção de teto. Constante `DownloadLimit.image` e as visibilidades que eu havia aberto foram removidas junto (nada de código morto meu).

## Round com o worker (canal recuperado): o diagnóstico da flake da jornada

O canal voltou (Chrome relançado pelo usuário; pid novo, AX resolve). Mandei **tarefa, não dado**, e pedi a resposta **em partes numeradas desde o primeiro pedido** — a lição de recepção. Resultado do cruzamento:

**O que o worker acertou:** o mecanismo geral — **tap perdido** no Simulator, não regressão semântica no `ArticleImageResolver`/`ImageLoader`; a jornada não é um sinal sobre o caminho de imagem.

**O que ele errou, e eu verifiquei no repo:**
1. Ele afirmou que `release-acceptance.sh` só faz `simctl uninstall` e que o reboot do Simulator seria a diferença para o `release-journey.sh`. **Falso**: `:75-77` do acceptance faz `shutdown → boot → bootstatus`, igual a `:76-78` do journey.
2. Ele afirmou que o chamador faz uma captura duplicada antes do tap. **Falso**: `stableTappableCard()` só retorna depois de revalidar existência + `isFullyVisible` + **frame idêntico** (`:517-525`), e a captura `92-reader-pre-tap` é rotulada como *"last observation before synthesis, taken here on purpose"*, com o comentário do tap dizendo que **uma retap converteria defeito real em jornada verde**.

**O que fecha o caso (e é o valor da rodada):** a classe de falha `miss_cause=feed_unchanged_verified` — mesmo card presente, visível e hittable, nada apareceu — está **documentada no próprio repo** (`docs/release/1.0-checklist.md:3702-3740,3916,4007`) como **tap ignorado com o pipeline de startup rodando**: um achado **do app**, que o harness se recusa a mascarar. Logo:

- a correlação que eu medi (mexer no caminho de imagem ⇒ jornada 15/17) é **carga/timing**, não semântica — fazer mais trabalho de imagem no startup deixa a janela de tap ignorado mais provável;
- **rejeitar CR-08 e CR-03 estava certo por um motivo mais forte do que "coincidiu com gate vermelho"**: os dois adicionavam trabalho justamente na janela que faz o app perder o tap. Não são "inocentes rejeitados por flake" — são carga na direção do defeito;
- a receita de diagnóstico do worker para uma falha futura é boa e fica registrada: correlacionar `window tap` / `card tap` / `reader presented` — **ambos os taps ausentes = HID/harness; window tap presente e card tap ausente = gesture/overlay**; `reader_blank=1` é outro defeito (o WKWebView não renderizou). Log em `/tmp/feedmine-journey.log`, frame em `91-reader-missing.png`.

**Parte 2 (bump 17→18)** não foi recuperável pela janela renderizada (só a abertura e "Reviewed version files" ficaram no DOM). Derivado localmente e verificado no repo — está em `38-rc18-bump.md`, com o `INFOPLIST_FILE = feedmine/Info.plist` conferido em `project.pbxproj:1543,1562`.

## Round de projeto com o worker (canal operante, 3 perguntas)

Mandei três perguntas (P-01, C-06, o tap ignorado) pedindo **projeto pronto para aplicar**, em partes numeradas. Resultado:

### P-01 — **implementado** (fail-closed), do desenho do worker

Desenho dele: `FeedStore.empty()` continua existindo só para manter o objeto inicializável; **não** vira modo normal. O app deve dizer que não conseguiu abrir o banco, bloquear escrita e não desenhar um feed vazio por cima de dado que existe no disco.

Aplicado (3 edições + 1 teste):
- `feedmine/Services/FeedLoader.swift`: `var persistenceUnavailable: Bool { initError != nil }`; `init(store:storeFactory:)` com a costura que permite o teste fazer a construção padrão lançar; `start()` recusa quando indisponível (`Log.db.error` + `return`) em vez de rodar o pipeline no fallback.
- `feedmine/Views/FeedScreen.swift`: ramo `if loader.persistenceUnavailable { ContentUnavailableView(...) }` antes de `isSearching && hasCommittedSearch`, com `accessibilityIdentifier("persistent-store-unavailable")` e a mensagem explicando que o dado **não** foi apagado.
- `feedmineTests/FeedStoreTests.swift`: `testPersistentStoreFailureIsVisibleRatherThanSwallowed` — assere `initError != nil`, `persistenceUnavailable == true` e que um `start()` recusado não carrega registry. **Deliberadamente não escrevi asserção sobre a guarda do `start()`** que eu não conseguisse falsificar (um teste vazio é pior que nenhum); a guarda é verificada por leitura + compilação.

### C-06 — **desenho recebido, NÃO aplicado** (`41-c06-design.md`)

O worker propôs um `SharedWait<Value>` com `withCheckedThrowingContinuation` para que o **waiter cancelado** volte imediatamente enquanto a resolução compartilhada segue para os outros. É a direção certa, e é exatamente a classe onde um "parece certo" produz **hang**: continuations, ordem de resume, cancelamento concorrente. Não entra sem teste dedicado de cancelamento (dois waiters, um cancelado, um não) e sem revisão — fica como desenho registrado para uma sessão focada.

### Tap ignorado sob carga — parte 3 não foi pedida a tempo

O composer saiu do alcance da varredura depois que a conversa cresceu; a pergunta fica registrada para o próximo round (é a menos acionável das três: exige repro com log para discriminar HID de gesto).

## Parte 3 — o tap engolido sob carga: candidato com linha, e o A/B que eu executei

O worker apontou **um candidato principal** e descartou os outros com evidência:

- **Candidato**: `FeedDisplayState.swift:261` — a reconciliação de fundo sobre página já visível faz o merge preservando ordem/IDs e então **atribui** `visibleCards`/`visibleItems` e **bumpa as duas gerações** (`:287-290`), mesmo quando o resultado é idêntico ao que está na tela. Isso re-renderiza todo card; um re-render caindo entre a checagem de estabilidade e o tap é o que engole o tap.
- **Descartados com linha**: overlays com `allowsHitTesting(false)` (`FeedScreen:145`, `nightOverlay:978`) — o `OnboardingTipsView` não existe quando `-UITestSkipOnboarding` marcou onboarding concluído; e os `highPriorityGesture` de `FeedItemCardView:127/222` só existem quando `onImageTap != nil` (podcast), então não explicam o caso geral.
- **Confirmação proposta**: instrumentar `publishCards` com geração + IDs + timestamp e `FeedItemView` com `onAppear/onDisappear`; no próximo miss, `window tap` presente + `card tap` ausente + publicação do mesmo item entre `92-reader-pre-tap` e o tap fecha o mecanismo.

### O A/B que eu rodei (em vez de só registrar a hipótese)

Duas mudanças na árvore, então barra:

1. `FeedDisplayState.swift:287` — só atribuir e bumpar as gerações **quando o merge muda algo** (`mergedCards != visibleCards || mergedItems != visibleItems`; ambos os tipos são `Equatable`). O settle e a escrita do cache de página seguem rodando, como o comentário do próprio código exige.
2. re-aplicação do **teto de imagem** (CR-03) no `ImageLoader`, agora `self-contained` (stream de `session.bytes` + `Content-Length` + corte em 12 MB), para reproduzir a condição que dava 15/17.

**Leitura do resultado:** se a jornada voltar a **17/17 com o teto aplicado**, o mecanismo está isolado no churn de publicação — e o CR-03 (rejeitado antes por correlação) pode embarcar. Se continuar **15/17**, a hipótese não se confirma e as duas mudanças saem, mantendo os 12 consertos.

### Resultado do A/B: **confirmado em duas execuções**

| Execução | Árvore | Gates | Jornada |
|---|---|---|---|
| 09:42 | 12 consertos + guard de não-churn + teto de imagem | 610/0 ×3 | **17/17** |
| 09:53 | idem | 610/0 ×3 | **17/17** |

**O que isso fecha:**
1. **O mecanismo do tap engolido é o churn de publicação.** Antes: qualquer mudança no caminho de imagem levava a jornada a **15/17** em 3/3 execuções. Agora, com a mesma mudança de imagem e o guard que impede atribuir/bumpar geração quando o merge não mudou nada (`FeedDisplayState.swift:287`), são **17/17 em 2/2**. Era re-render de card dentro da janela do tap.
2. **O teto de imagem (CR-03) pode embarcar.** A rejeição anterior estava certa *para a árvore em que foi testada* — ele não era o defeito, era o que **expos** o defeito. Com a causa tratada, o conserto de robustez entra com evidência.
3. **O guard é um conserto por mérito próprio**, não um truque de teste: atribuir os mesmos valores e bumpar duas gerações re-renderiza cada card para nada — o custo era real e visível (o próprio repo chama o sintoma de "cards moving up and down").

**Estado final: 14 consertos**, com **duas barras verdes consecutivas** nesta árvore (`BAR OK 09:53:36` e `10:04:50`).
