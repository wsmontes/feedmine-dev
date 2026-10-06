[[ROUND 12 — ERRATA CONTRA REVISÃO INDEPENDENTE]]

Um revisor independente (modelo de outra família, com acesso direto ao repositório) auditou os seus artefatos desta conversa, afirmando cada veredito com path:line. Os resultados estão abaixo. Não aceite nada por educação: verifique cada item contra os fatos que você já recebeu (D1–D4 + os fatos deste round) e decida.

### Revisão local independente (modelo de outra família, com acesso ao repo) — vereditos ERRADO
Formato: | artefato | afirmação | veredito | evidência path:linha |
| Artefato | Afirmação (citada) | Veredito | Evidência path:linha | Impacto se ERRADO |
| 04 R1 | "ADR-001 D2 é amplo demais; `MainFeedRow.id = item.id`, `PreparedFeedCard.id = item.id`, bridge gera alias — **BLOQUEADOR**" | ERRADO (não há contradição com o ADR) | `docs/runtime-v2/adrs/ADR-001.md:30` — D2 diz textualmente que "Array posi
| 04 R1 (citação) | alias em `MainFeedCardBridge.swift:206-224` | ERRADO (linha) | `feedmine/RuntimeV2/MainFeedCardBridge.swift:234` (função `cardID(forLegacyItemID:)`, corpo 234-245); chamada em `:188` | Referência imprecisa; não altera a substância (a
| 04 R2 / R9 | "`FeedScreen.swift:15,1233,1348` persiste `lastVisibleItemID`; D17/D4 contraditos" | ERRADO (linhas 1233/1348 não contêm o fato; e não há contradição) | Real: `feedmine/Views/FeedScreen.swift:15` (`@State lastVisibleItemID`), `:56` (`@AppS
| 04 R3 | "ADR-003 D2/D18 não fecham allocation de catalog Source — **BLOQUEADOR**" | ERRADO (não há contradição; é lacuna de política) | `docs/runtime-v2/adrs/ADR-003.md:25` (D2: "persisted lookup in `legacy_source_map` ... which fails when no mappin
| 04 R4 | "D18 ('only legacy identity path') é mais amplo que o checkout" | ERRADO (leitura não é obrigada) | `ADR-003.md:57`; ADR-003 é integralmente sobre identidade Runtime V2 (`ADR-003.md:1,57`); usos legados em `feedmine/Models/FeedSource.swift:14` | 
| 04 R5 | "D10 não é retroativamente satisfazível; GUID perdido" | ERRADO (como contradição) | `ADR-003.md:41` (D10 enuncia a regra do runtime); perda de GUID no histórico é limitação de migração, não contradição | Nenhum bloqueador; item pertenc
| 04 R6 | "ADR-004 precisa excluir explicitamente as tabelas antigas de bookmark de `feedmine.sqlite`" | ERRADO (a tabela de autoridade já decide) | `ADR-004.md:17` (D1) e `:19-24` (tabela): `user.sqlite` = "bookmarks, bookmark lists, ..."; `feedmine.sqlite` 
| 04 R7 | "D17 conflita com o fetcher legacy" | ERRADO (o ADR já explicita o escopo) | `ADR-005.md:80` — D17 cita literalmente `validateAudio`/`probeAudio` do fetcher legacy e diz "the connector boundary MUST NOT inherit it"; `feedmine/Services/RSSFetcher.s
| 04 R8 | "ADR-007 D3 não é seguro enquanto o bridge fabrica aliases — **BLOQUEADOR**" | ERRADO (não há contradição com D3) | `ADR-007.md:26` (D3 normativo); alias é dívida de implementação: `MainFeedCardBridge.swift:234-245`; `baseline.md:1168` | 
| 04 R9 | "D4 alega restore já resolvido" | ERRADO | `ADR-007.md:28` — D4 trata eviction/re-materialização "at the same edition"; não afirma que o persisted restore legacy o satisfaz | Nenhum bloqueador. |
| 04 R11 | "rollout aponta `PublicationRepository.swift:94` e a alocação real é `:948`" | ERRADO (alocação real é `:1042`) | `rollout.md:120` (cita `:94`); `rollout.md:344-345` (cita `:948` como `PublicationCardID(db.lastInsertedRowID)`); checkout: `:948
| 08 R1-R5, R7, R8, R9 | REFUTADO (não há contradição normativa) | CONFIRMADO | Mesmas evidências acima (`ADR-001:30,60`; `ADR-003:25,41,57`; `ADR-005:80`; `ADR-007:26,28`) | Se ERRADO, o freeze seria bloqueado indevidamente. A leitura direta confirma a r
| 08 R11 | INDETERMINADO ("fatos de `rollout.md:120` não fornecidos") | ERRADO (os fatos eram acessíveis no repo e a linha citada como alocação está errada) | `rollout.md:120` e `:344-345` legíveis; alocação em `PublicationRepository.swift:1042` | Não
| 05 P0.8 | "allocation real: `PublicationRepository.swift:948`" | ERRADO | Real: `Packages/FeedRuntimeV2/Sources/FeedStorage/Publication/PublicationRepository.swift:1042`; `:948` = insert de `feed_segment` | Propaga citação falsa para PR-00..PR-09 e para o 
| 05 P0.4 / P0.7 / §2 | `PublicationRepository.swift:948` como ponto de alocação | ERRADO (mesma causa) | `PublicationRepository.swift:948` vs `:1042` | Mesma propagação; a decisão normativa não muda, mas a evidência de aceite está errada. |
| 05 §4 vs 06 §3 | Numeração PR conflitante entre os dois artefatos | ERRADO (inconsistência interna do conjunto) | `05-checklist-gate0.md:65` (PR-00 = "Bootstrap de runtime/migration coordinator em launch legacy") vs `06-registro-backlog.md:51` (PR-00 = 
| 06 PR-02 | Alvo `feedmine/RuntimeV2/RuntimeMigrations.swift` | ERRADO (path não existe) | Real: `Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift`; o próprio 06 §4.6 usa o path correto (`06-registro-backlog.md:91`) | Alvo inv�
| 06 PR-05 | Alvo `feedmine/Models/AppSettings.swift` | ERRADO (path não existe) | Real: `feedmine/Services/AppSettings.swift` | Mesmo caso: alvo citado não existe no path indicado. |
| 10 §1 | "ADR-003: nenhum teste AUSENTE; sem lacuna nesta auditoria" | ERRADO | `ADR-003.md:406` faz a mesma afirmação "implemented and pinned by real tests"; dos 22 nomes listados em `ADR-003.md:409-431`, 21 estão ausentes como identificador literal (só
| 10 §1 | "(c) 0 testes cobertos sob outro nome" | ERRADO (parcialmente) | `unknownFutureSchemaFailsControlled` (ADR-004:310) tem metade coberta por `Packages/FeedRuntimeV2/Tests/FeedStorageTests/MigrationTests.swift:232` (`testAnUnknownMigrationRecordNeverEr

### Achados da revisão de identidade (artefatos 01/02/07)
| Artefato | Afirmação (citada) | Veredito | Evidência path:linha | Impacto se ERRADO |
| 01 §1 | A normalização de identidade remove `www`, **porta** e trailing slash | ERRADO (porta) | `feedmine/Services/OPMLParser.swift:704` (www), `:726-727` (trailing slash), mas `:719-723` **mantém** portas não-default na identidade (`authority += ":\(p
| 01 §1 (escopo) | "migração delegada pela §16 do ADR-003" | ERRADO | `docs/runtime-v2/adrs/ADR-003.md` não possui §16: headings em `:9,:21,:61,:71,:357,:382,:402,:431`; o único "§16" é `:454` referindo `plan §16`, que é "SLOs, observabilidade e cri
| 01 M5 | "não há tipo/encoding de cada `filter*`; isso impede qualquer tradução de formato" | ERRADO | `feedmine/Services/AppSettings.swift:65-92` expõe os tipos: `String?`, `[String]`, `String`, `Bool`, `TimeInterval` (`filterRegion`, `filterTaxonomyNod
| 02 A7 | `PublicationCardID` nasce na transaction de publicação em `PublicationRepository.performCommit`, `PublicationRepository.swift:948` | ERRADO (linha) | `performCommit` inicia em `Packages/FeedRuntimeV2/Sources/FeedStorage/Publication/PublicationRepos

### Fatos confirmados que corrigem premissas
- ADR-003 NÃO tem seção §16: headings em ADR-003.md:9,21,61,71,357,382,402,431. A única menção a '§16' está em ADR-003.md:454 e se refere ao §16 do PLANO (docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md:645, 'SLOs, observabilidade e critérios de rollout'). Portanto 'a §16 do ADR-003 delega a migração' é FALSO.
- ADR-003.md:454 verbatim: | Blueprint §105 / plan §16 (renderer network = 0) | D7, D15 (identity rows carry no protocol payload) | 10, 16 | PR-03, PR-11 | proposed |
- legacy_source_map e legacy_item_map JÁ existem e são usados em produção: ShadowInputBridge.swift:789, UserStateBridge.swift:170 (rev. de identidade).
- Nenhuma proposta de 01/02/07 altera feed_item.id nem exige rekey/move/delete de dados do usuário (verificado).
- AppSettings.swift:65-92 expõe os tipos dos filtros (String?/[String]/String/Bool/TimeInterval) — o artefato afirmou que não estavam disponíveis.
- OPMLParser.swift:719-723 omite apenas portas DEFAULT (443/80); porta não-default permanece na identidade — o artefato disse que a porta é removida.
- Alocação de PublicationCardID: PublicationRepository.swift:1009-1042 (performCommit começa em :903). rollout.md:120 cita :94 e rollout.md:344-345 cita :948 — ambos obsoletos.
- MainFeedCardBridge.cardID(forLegacyItemID:) corpo em :234-245; chamada em :188 (o artefato citou :206-224).
- SQLiteCatalogStore: o throw de colisão está em :216-217 (o artefato citou :186-196).


[[TAREFA]]

1. PARA CADA ACHADO: veredito ACEITO / REJEITADO / PARCIAL, com o motivo em uma linha, usando apenas fatos. Se REJEITAR, cite o fato que sustenta a rejeição. Os cinco achados de identidade (ADR-003 sem §16; PublicationCardID :1009-1042; AppSettings.swift:65-92; porta não-default; citações de linha) têm de ser tratados um a um.

2. ERRATA NORMATIVA — o texto de correção dos pontos em que você errou, pronto para colar, um bloco por correção, no formato: ARQUIVO, ÂNCORA verbatim (o texto atual do seu artefato), SUBSTITUIR POR, MOTIVO.
   - em `01-plano-de-migracao.md`: a frase que atribui a delegação à "§16 do ADR-003" — a correção tem de nomear o documento certo;
   - em `02-identidade-source-runtime.md`: a citação de `PublicationRepository.swift:948` no item A7;
   - em `07-anexo-section16.md`: o título e o objeto do anexo (ele não substitui uma §16 que não existe no ADR) e as âncoras que dependiam dessa premissa;
   - em `04-revisao-adversarial-adrs.md` e `08-falsificacao-defeitos.md`: os defeitos que a revisão independente marcou como ERRADO e que a sua própria falsificação não derrubou.

3. SOBREVIVENTES — para cada um dos sete ADRs, com a lista já falsificada e auditada: existe algum BLOQUEADOR real? Nomeie-o ou escreva NENHUM, uma linha por ADR.

4. LIÇÃO — no máximo três linhas sobre que tipo de leitura produziu falso positivo na sua revisão adversarial, e a regra que evita repetir.

Formato: markdown, máximo ~2500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
