[[ROUND 3 — DECISÃO: FRONTEIRA DA IDENTIDADE DE CARD / PR-15]]

Fatos novos:

### rollout.md — card identity / PR-15 (amostra)
26:| Main feed **(rewritten by PR-13, 2026-09-17 — see §2.1)** | The legacy loader for section text, phases and actions (`@Environment(FeedLoader.self)`, `FeedScreen.swift:7`) **plus** the launch runtime for the presentation (`@Environment(MainFeedRuntime.s
28:| Source detail | `FeedItemView` built from locally constructed `FeedCardPresentation` (`CollectionManagementView.swift:373,522-611`), mapped through `MainFeedCardBridge.card(item:presentation:band:)` (`MainFeedCardBridge.swift:151`) | Yes — `FeedStore.lo
33:| Onboarding preview / Welcome samples | `FeedItemCardView` with static/preview presentations, mapped through `MainFeedCardBridge` (`FeedComposerScene.swift:82`, `WelcomeScene.swift:152`) | Yes — `curatedOnboardingItems:6350` |
49:| Persisted position | `lastVisibleItemID` from the observation (`FeedScreen.swift:15,1233`), written to `@AppStorage("lastScrollItemID")` on background (`FeedScreen.swift:1348`) | Restore `PublicationCardID + absoluteOrdinal + relative offset` | **Partial*
50:| Card protocol branching in views | gone from the Main Feed: `FeedItemCardView`/`FeedItemRowView`/`FeedItemView` read `CardPresentation.affordances` and `CardMediaSlot`; the inference lives once in `MainFeedCardBridge.affordances(for:)` (`MainFeedCardBridg
117:| Main Feed, bookmark list, Smart Feed, collections | acquisition legacy, presentation V2 — **superseded in `v2Full` by §2.4.1**: the runtime owns acquisition for the session's selection, and a selection the session does not own keeps its own legacy pag
120:| Card identity in the bridge | **unowned by PR-14** | `MainFeedCardBridge.cardID` is a deterministic alias over the legacy item id; ADR-003 allocates card ids in the publication transaction (`FeedStorage/Publication/PublicationRepository.swift:94`) and a 
151:| `bookmarks` | its own legacy page (`bookmark(listKey:)` resolves) | the lifecycle step, the render overlay (§8.29: a canonical hit carries no read/bookmark overlay) **and** the content path — a session composes from the runtime's canonical supply, whi

### rollout.md secao 7
## 7. Open items

Facts PR-14 settled, and what is left open with the owner named:

- `What's New` is enumerated: `FeedSurfaceCatalog` has a `whatsNew` row (owner, entry point, history
  scope, refill window) and `ContextKey.Surface.whatsNew` / `HistoryScope.whatsNew` exist. It still has
  **no view in the tree**; whether the surface is rebuilt or retired remains a product decision, and
  PR-15 must not read "the row exists" as "the surface ships".
- `BackgroundRefreshService` is confirmed dead and deleted (§3). **Background feed refresh now runs, implemented by PR-15** (baseline §8.16): the identifier is permitted in `Info.plist`, `UIBackgroundModes` carries `fetch`, and registration happens in `FeedmineEntryPoint.main():19` before the app 
- **The Source surface's plan is not migrated**: `HistoryScope.source(SourceID)` needs an allocated
  runtime identity, and ADR-003 D2/D18 forbid deriving one from a catalogue id or a URL. The app cannot
  produce a `SourceID` while no shipping mode composes the runtime database. `FeedSurfaceCatalog.plan`
  refuses with `FeedSurfacePlanError.runtimeIdentityUnavailable(.source)`; the surface's *demand* is
  arbitrated and its history is preserved by its own query in the meantime (§2.4). Owner: PR-15.
- **The card identity in `MainFeedCardBridge` is an alias, and PR-15 does not close it either.** ADR-003
  allocates `PublicationCardID` in the publication transaction — `PublicationRepository.commit` →
  `performCommit`, `PublicationRepository.swift:948`: `PublicationCardID(db.lastInsertedRowID)` inside the
  write transaction, with no standalone allocator — and the bridge has no runtime database, so it carries a
  deterministic SHA-256 alias over the legacy item id. PR-15 measured that runtime-owned publication needs the
  same canonical→presentation path the ingestion item needs (baseline §8.20), so this is re-declared rather
  than half-closed: a durable allocation is a publication-slice change, not a different hash. Owner:
  PR-16/PR-17.

### ADR-007 D3
**D3 — Exposure continuity is anchored to `PublicationCardID`, not to the SwiftUI view, and a rerender is not part of the interval's life.** The interval opens on a viewport entry observation for a card and closes only on a left-viewport observation, a lifecycle end, or an edition swap. View-level `onAppear`/`onDisappear` caused by rerender, window eviction and re-materialization, image material

**D4 — Window eviction and restoration have one defined rule.** Eviction alone produces no fact. If a card is evicted while its last known visible fraction was at or above the threshold, the interval is closed with `reason = windowEvicted` and dwell credited only up to the last coalesced sample before eviction; if the card is re-materialized at the same edition, `cardID` and ordinal anchor withi

### ADR-003 card/publication
59:**D19 — No array index and no batch ordinal is an identity.** Nothing durable keys on array position, row order, batch order or viewport index. Ordinals exist only inside an acquisition batch or a published edition, are regenerated per batch/edition, and 
354:- `OPEN:` which identity columns `PublishedOrigin` freezes (Blueprint §55) and whether `published_card` stores `OriginRevisionID` only or also copies key digests. Owner: ADR-001.

### baseline.md card
1168:(`card:<PublicationCardID>`), which matches **zero** rows — so the write is a silent no-op, the display id
1259:id (`card:<PublicationCardID>`) — an id that names no `feed_item` row, so the legacy write matched zero
1264:`.cardVisibility(ViewportObservation(cardID:visibleFraction:edge:))` and **returns**, so the legacy call is
1300:`ExposureTracker.read(cardID:operationID:)` (`:245`) appends it. `ExposureStore` folds those facts into
1412:**The intent is the open.** `FeedSessionIntent.opened(cardID:operationID:)`
1891:| A decision's *wording* matches the row it serves — spot-checked, because an id being present is not a meaning being present | 3 / 3 — row #12 → ADR-003 D13 ("Equivalence is a relation, not a merge": `content_entity_member` strong, `content_cluster


[[TAREFA]]

Decida a fronteira da identidade de card entre legado e runtime V2. Cada subseção com DECISÃO / CONSEQUÊNCIA / TESTE:

C1. Quem é dono da identidade de card em cada estágio: loader legado, `MainFeedCardBridge.cardID` (alias determinístico sobre o item id), publicação do runtime (`PublicationCardID` alocado em `PublicationRepository`)? Nomeie o dono por estágio e o que a troca de dono exige.
C2. O alias atual (SHA-256 do item id legado, 8 bytes, clampado em Int64) — pode continuar como identidade de apresentação? Se sim, sob qual invariante (estabilidade entre edições, colisão, reindexação). Se não, o que o substitui e em quantos slices.
C3. `legacy_item_map` (`legacy_item_id` PK) é a única ponte? O que acontece com um item que existe no feed legado e nunca foi mapeado quando a UI V2 renderiza: degrada, recusa, ou mapeia na hora?
C4. Sobrevivência do card id através de substituição de edição (edition replacement) e restauração a quente: o que precisa continuar válido e o que pode ser remintado.
C5. O conteúdo exato de PR-15: alvos (arquivos/tabelas), o que entra e o que fica de fora, e o teste nomeado que prova o fechamento.
C6. O que NÃO pode mudar agora no caminho legado (o app publica hoje com `fix/release-1.0-final-hardening`): liste as superfícies congeladas.

Formato: markdown, máximo ~2500 palavras, citando path:line.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem resumo.
