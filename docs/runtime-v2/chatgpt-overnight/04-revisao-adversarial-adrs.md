> **AVISO (auditoria local, 2026-10-05):** 21 das afirmações deste documento foram marcadas ERRADO por revisão independente com acesso ao repositório — o autor leu como "contradição com o ADR" o que os próprios ADRs já escopam. Veredito item a item em `12-errata.md` §1; a falsificação do próprio autor está em `08-falsificacao-defeitos.md`, que a auditoria confirmou como correta em R1–R5 e R7–R9. **Não use este arquivo isoladamente para bloquear um freeze.**

START]]

# Revisão adversarial dos sete ADRs contra o checkout `70f7b06b`

**Base factual:** working tree de 2026-10-05 + `rollout.md`/`baseline.md` fornecidos.  
**Escopo:** defeitos demonstráveis do texto normativo frente ao estado real; ausência de implementação, por si só, não invalida uma decisão arquitetural, exceto quando o ADR deixa a coexistência ambígua ou permite comportamento incorreto no checkout atual.

# A. CONTRADIÇÕES VERIFICÁVEIS / DEFEITOS ACIONÁVEIS

## R1 — `PublicationCardID` está sendo usado como conceito mais amplo do que o checkout suporta

- **ADR:** ADR-001 D2
- **AFIRMAÇÃO:** “Occurrence identity is `PublicationCardID`.”
- **FATO:** no Main Feed atual, `MainFeedRow.id = item.id`; `PreparedFeedCard.id = item.id`; e `MainFeedCardBridge.cardID(forLegacyItemID:)` produz apenas um alias SHA-256 truncado, não uma row de `published_card`. (`feedmine/RuntimeV2/MainFeedPresentationPipeline.swift:13-18`; `feedmine/Models/PreparedFeedCard.swift:103-119`; `feedmine/RuntimeV2/MainFeedCardBridge.swift:206-224`)
- **FATO adicional:** o `PublicationCardID` real somente é alocado dentro da transaction de `PublicationRepository`, via `db.lastInsertedRowID`. (`Packages/FeedRuntimeV2/Sources/FeedStorage/Publication/PublicationRepository.swift:948`; `rollout.md:343-349`)
- **SEVERIDADE:** **BLOQUEADOR**
- **CORREÇÃO MÍNIMA:** restringir explicitamente D2 a **runtime-published occurrences**. Registrar que `FeedItem.id` e o alias do bridge são identidades de coexistência e jamais podem entrar como `PublicationCardID` em persistence, exposure ou actions.

---

## R2 — O ADR-001 não pode tratar o anchor de runtime como se o persisted-position atual já obedecesse a ele

- **ADR:** ADR-001 D17
- **AFIRMAÇÃO:** “Anchors are ordinal-based.”
- **FATO:** shipping code ainda persiste `lastVisibleItemID` em `@AppStorage("lastScrollItemID")`; o próprio rollout marca a migração para `PublicationCardID + absoluteOrdinal + relative offset` como **Partial**. (`FeedScreen.swift:15,1233,1348`; `rollout.md:49`)
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** acrescentar cláusula de coexistência: D17 governa editions runtime; restore legacy continua item-keyed até o publication/session cutover. Proibir a interpretação de que `lastScrollItemID` satisfaz D17.

---

## R3 — ADR-003 define a ponte, mas não fecha o evento que cria a identidade de runtime

- **ADR:** ADR-003 D2 / D18
- **AFIRMAÇÕES:** “The catalog ID is a different type, aliased, never converted.” / “Legacy bridges are the only legacy identity path.”
- **FATO:** `legacy_source_map` existe e `RuntimeSourceRegistry` aloca `FeedDomain.SourceID` corretamente, mas stock launch resolve `.legacy`, não compõe runtime DB; por isso Source Detail não consegue produzir `HistoryScope.source(SourceID)` e recusa `runtimeIdentityUnavailable(.source)`. (`RuntimeMigrations.swift:414-423`; `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/SourceRegistry.swift:30-65`; `Packages/FeedRuntimeV2/Sources/FeedRuntime/RuntimeMode.swift:57-79`; `feedmine/RuntimeV2/RuntimeCompositionRoot.swift:74-120`; `rollout.md:118,155,338-342`)
- **SEVERIDADE:** **BLOQUEADOR**
- **CORREÇÃO MÍNIMA:** incorporar ao ADR-003 o fechamento normativo já decidido no Adendo A: `missing mapping → ensure/allocate transactionally → mapping persistido → SourceID`; bootstrap híbrido e recusa somente quando identidade durável não puder ser estabelecida.

---

## R4 — “Only legacy identity path” precisa ser explicitamente limitado ao boundary runtime

- **ADR:** ADR-003 D18
- **AFIRMAÇÃO:** “Legacy bridges are the only legacy identity path.”
- **FATO:** o checkout ainda possui numerosos usos legítimos do legado em que URL normalizada **é** identidade: `FeedSource.id`, `SourceReference.id`, registry, scheduler, taxonomy, import pipeline, FeedStore e `source_identity` persistido. (`feedmine/Models/FeedSource.swift:14,125`; `feedmine/FeedEngine/SourceRegistry.swift:124`; `feedmine/Services/UserStateStore.swift:330,336,390,937,1411,1419`; demais consumidores inventariados em D1)
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** escrever “inside FeedDomain/FeedStorage/runtime bridges”. O ADR não deve sugerir que coexistência legacy viola D18; o que é proibido é essa identidade URL-derived atravessar a fronteira como runtime identity.

---

## R5 — D10 é correto para novos ingressos, mas não é retroativamente satisfazível pelos itens persistidos

- **ADR:** ADR-003 D10
- **AFIRMAÇÃO:** “An RSS/Atom GUID is not a URL.”
- **FATO:** o GUID bruto só existe durante parsing/`ShadowParsedEntry`; `FeedItem` não possui campo GUID e `feed_item` persiste somente o hash `FeedItem.id`. (`feedmine/Models/FeedItem.swift:5-24,394-402`; `feedmine/Services/RSSFetcher.swift:1050-1076`; `feedmine/Services/FeedStore.swift:8392-8425`)
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** acrescentar regra de migração: novos ingressos capturam GUID antes de `FeedItem.generateID`; histórico existente entra via `legacy_item_id` opaco/low-confidence e nunca por GUID “reconstruído”.

---

## R6 — A autoridade de bookmarks precisa excluir explicitamente as tabelas antigas de `feedmine.sqlite`

- **ADR:** ADR-004 D1
- **AFIRMAÇÃO:** “Authority per database.”
- **FATO:** existem `bookmark_list`/`bookmark_item` antigas em `feedmine.sqlite`, porém `FeedStore` atualmente delega operações para `BookmarkStore`, cuja autoridade está em `user.sqlite`. (`feedmine/Services/FeedStore.swift:7703-7737,7849-7869`; `feedmine/Services/BookmarkStore.swift:6-11`; `feedmine/Services/UserStateStore.swift:209-233`)
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** a tabela de autoridade do ADR-004 deve declarar expressamente `user.sqlite.bookmark_*` como autoridade e `feedmine.sqlite.bookmark_*` como schema legado não autoritativo.

---

## R7 — “Media speculation is not acquisition” conflita com o fetcher legacy se o escopo não for explicitado

- **ADR:** ADR-005 D17
- **AFIRMAÇÃO:** “Media speculation is not acquisition.”
- **FATO:** o `RSSFetcher` legacy ainda executa audio probing dentro do seu fluxo de fetch. (`feedmine/Services/RSSFetcher.swift:499-533`)
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** declarar que D17 rege o **connector/runtime V2 admission boundary**, enquanto o probe legacy é dívida de coexistência até retirement. Sem essa frase, o texto descreve falsamente o checkout inteiro.

---

## R8 — Exposure baseada em `PublicationCardID` não é segura enquanto o bridge fabrica aliases

- **ADR:** ADR-007 D3
- **AFIRMAÇÃO:** “Exposure continuity is anchored to `PublicationCardID`, not to the SwiftUI view.”
- **FATO:** presentations do caminho compatibility podem carregar card IDs derivados de `FeedItem.id`, enquanto o ID publicado real não existe sem publication transaction. (`feedmine/RuntimeV2/MainFeedCardBridge.swift:191,206-224`; `rollout.md:343-349`)
- **FATO adicional:** baseline registrou caminhos em que `card:<PublicationCardID>` não nomeia row alguma de `feed_item`, fazendo write virar silent no-op. (`baseline.md:1168,1259-1264`)
- **SEVERIDADE:** **BLOQUEADOR**
- **CORREÇÃO MÍNIMA:** ADR-007 deve dizer explicitamente que D3 só entra em vigor para cards vindos de `published_card`. Cards compatibility continuam no mecanismo legacy e não alimentam ExposureStore como se fossem ocorrências publicadas.

---

## R9 — Hot restoration descrita por ADR-007 ainda não possui a identidade persistida necessária

- **ADR:** ADR-007 D4
- **AFIRMAÇÃO:** “Window eviction and restoration have one defined rule.”
- **FATO:** o runtime pretende continuidade por `PublicationCardID` dentro da mesma edition, mas persisted scroll position ainda é `lastVisibleItemID`; o rollout classifica a restauração runtime como parcial. (`FeedScreen.swift:1233,1348`; `rollout.md:49`)
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** separar “window restoration dentro de uma session/edition viva” de “cold/warm persisted scroll restore”. D4 pode congelar o primeiro; não deve alegar que o segundo já está resolvido.

---

# B. AFIRMAÇÕES NÃO VERIFICÁVEIS COM OS FATOS DISPONÍVEIS

Não há evidência suficiente nesta rodada para marcar os itens abaixo como corretos ou incorretos. Isso é **dívida de verificação**, não contradição.

| ADR | Decisões não verificáveis pelos fatos fornecidos |
|---|---|
| **ADR-001** | D1 append-only/single-writer; D3 token/single-flight/tail CAS; D4-D16 payload/media/assets/actions. A existência de `PublicationRepository` foi provada, mas não esses invariantes completos. |
| **ADR-002** | D1, D3-D12. Não foram fornecidos serializers de `ContextKey`, fingerprinting, revision comparison, clock/draft starvation nem warm-restore implementation suficiente. |
| **ADR-003** | D4-D9, D11-D17 e D19 em sua implementação completa. Há evidência parcial de tipos/bridges, mas não dos constraints e conflict flows integrais. |
| **ADR-004** | D2-D6 e D8-D12 em detalhe. Os três bancos/migrators e bookmark snapshot existem, porém backup/file protection, GC, recovery e rollback matrix não foram apresentados. |
| **ADR-005** | D1-D16 e D18-D20 para o connector V2. Os fatos descrevem principalmente `RSSFetcher` legacy e não provam o contrato completo do connector runtime. |
| **ADR-006** | D1-D14. Nenhum trecho factual fornecido nesta rodada demonstra `TargetStamp`, checkpoint CAS, `SupplyGeneration`, stale-write rejection ou transaction coordinator. |
| **ADR-007** | D1-D2, D5-D15. Há alguns call sites de Exposure/intent em `baseline.md`, mas não evidence suficiente para validar thresholds, idempotency, retention, tombstones ou monotonic clock. |

**Regra de sign-off:** esses itens não devem receber “implementation verified” em Gate 0 sem evidência adicional; isso não impede, sozinho, que uma decisão arquitetural seja congelada.

# C. REFERÊNCIAS DE ARQUIVO/TESTE POSSIVELMENTE DESATUALIZADAS

## R10 — Linha citada de `BookmarkStore.swift` está desatualizada

- **ADR:** ADR-003 D18
- **CITAÇÃO informada do ADR:** `BookmarkStore.swift:128-134`.
- **FATO atual:** operações relevantes de bookmark estão em `BookmarkStore.swift:231-252`; pin/hydration relacionado aparece em `:432-435`. (`feedmine/Services/BookmarkStore.swift:231-252,432-435`)
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** atualizar a referência para os line ranges atuais ou, preferivelmente, citar símbolo (`BookmarkStore.toggle...` / snapshot writer) em vez de linha volátil.

## R11 — Referência de allocation de `PublicationRepository` precisa ser auditada

- **ADR/ecossistema documental:** ADR-001 / rollout references.
- **FATO:** `rollout.md:120` aponta `PublicationRepository.swift:94`, enquanto a mesma documentação depois identifica a alocação real de `PublicationCardID` em `PublicationRepository.swift:948`.
- **SEVERIDADE:** **CORREÇÃO**
- **CORREÇÃO MÍNIMA:** procurar nos sete ADRs qualquer referência a `PublicationRepository.swift:94` para allocation e atualizar para o símbolo `performCommit`/allocation da row, evitando dependência de line number.

## Testes

Nenhum **nome de teste citado pelos ADRs** foi fornecido nesta rodada em quantidade suficiente para provar que está desatualizado.

O único teste concretamente confirmado no checkout é `BackgroundRefreshDemandTests.testBackgroundDemandIssuesNoRequestForEndpointsAnotherProducerHolds` (`rollout.md:451`); não há evidência fornecida de que um ADR cite nome diferente para essa prova.

# VEREDITO POR ADR

| ADR | Veredito | Motivo |
|---|---|---|
| **ADR-001** | **NÃO PODE** | D2 precisa distinguir `PublicationCardID` real do alias do bridge, e D17 precisa reconhecer explicitamente o persisted-position legacy ainda ativo. |
| **ADR-002** | **PODE CONGELAR** | Nenhuma contradição foi demonstrada pelos fatos fornecidos; várias decisões ainda carecem de verificação de implementação, mas isso não invalida o modelo normativo. |
| **ADR-003** | **NÃO PODE** | D2/D18 deixam sem fechamento o evento/bootstrap de alocação para catalog Sources; o checkout prova que isso bloqueia Source Surface. O Adendo A deve ser incorporado. |
| **ADR-004** | **PODE CONGELAR** | O checkout confirma a separação real de autoridades; requer apenas esclarecer que as bookmark tables de `feedmine.sqlite` são legado não autoritativo. |
| **ADR-005** | **PODE CONGELAR** | Nenhuma contradição do connector V2 foi provada; D17 precisa apenas explicitar que o probe atual pertence ao caminho legacy de coexistência. |
| **ADR-006** | **PODE CONGELAR** | Nenhum fato fornecido contradiz as decisões; conformance do writer/checkpoint continua não verificada. |
| **ADR-007** | **NÃO PODE** | D3/D4 dependem de uma identidade publicada que o shipping bridge ainda não possui; há evidência de silent no-op e persisted restoration ainda parcial. |
