Você recebeu os fatos do checkout (D1–D4) e produziu o PLANO DE MIGRAÇÃO. Agora uma decisão normativa.

[[ROUND 2 — DECISÃO: IDENTIDADE DE RUNTIME PARA SOURCES DE CATÁLOGO]]

Fatos novos, lidos do working tree agora:

### rollout.md — superfícies e identidade (linhas com decisão aberta)
26:| Main feed **(rewritten by PR-13, 2026-09-17 — see §2.1)** | The legacy loader for section text, phases and actions (`@Environment(FeedLoader.self)`, `FeedScreen.swift:7`) **plus** the launch runtime for the presentation (`@Environment(MainFeedRuntime.self)`, `FeedScreen.swift:10`). The rows are `runtime.presentation.sections` (`FeedScreen.swift:865`), whose cards are V2 `CardPresentation`s (`feedmine/RuntimeV2/MainFeedPresentationPipeline.swift:77`) built once by `MainFeedCardBridge` (`feedmine/RuntimeV2/MainFeedCardBridge.swift:65`); in `v2Presentation` every page also goes through `FeedScreenStore` | Yes, via `FeedStore` — unchanged by PR-13 |
28:| Source detail | `FeedItemView` built from locally constructed `FeedCardPresentation` (`CollectionManagementView.swift:373,522-611`), mapped through `MainFeedCardBridge.card(item:presentation:band:)` (`MainFeedCardBridge.swift:151`) | Yes — `FeedStore.loadSourceContent:7050` → `fetcher.fetch` |
33:| Onboarding preview / Welcome samples | `FeedItemCardView` with static/preview presentations, mapped through `MainFeedCardBridge` (`FeedComposerScene.swift:82`, `WelcomeScene.swift:152`) | Yes — `curatedOnboardingItems:6350` |
50:| Card protocol branching in views | gone from the Main Feed: `FeedItemCardView`/`FeedItemRowView`/`FeedItemView` read `CardPresentation.affordances` and `CardMediaSlot`; the inference lives once in `MainFeedCardBridge.affordances(for:)` (`MainFeedCardBridge.swift:72`), `mediaSlot(for:presentation:band:)` (`:128`) | Presentation must arrive complete; views must not infer protocol from the URL (PR-13) | **Replaced** for the Main Feed, the source/collection lists and the onboarding preview. `FeedItem.isYouTube/isForum/isPodcast/isDirectAudioLink` (`FeedItem.swift:90,93,185,191`) still have consumers outside the card views: `isTimeless`/sorting in the store, the content-type filter match (`FeedLoader.swift:101-107`) and `AudioPlayerManager` |
68:| Source detail | `FeedStore` | `FeedStore.loadSourceContent` | one endpoint | `sharedFeedEngine` | `source(SourceID)` | 300 s |
117:| Main Feed, bookmark list, Smart Feed, collections | acquisition legacy, presentation V2 — **superseded in `v2Full` by §2.4.1**: the runtime owns acquisition for the session's selection, and a selection the session does not own keeps its own legacy page | PR-13/PR-14 closed the demand arbiter without a second owner, and PR-15 closed the one place a second *tree* still existed (the BGTask path, P9). V2 owning acquisition itself is still not taken: it needs a canonical→presentation path first, or the owner swap either shows the reader nothing or double-fetches (baseline §8.20) |
118:| Source detail | acquisition legacy + demand arbitrated; **plan not resolved** | its `HistoryScope` is `.source(SourceID)`, a runtime identity, and ADR-003 D2/D18 forbid deriving one from a catalogue id or a URL. No shipping mode composes a runtime database, so there is no allocated `SourceID` to name. `FeedSurfacePlanError.runtimeIdentityUnavailable(.source)` is the refusal, asserted by test |
120:| Card identity in the bridge | **unowned by PR-14** | `MainFeedCardBridge.cardID` is a deterministic alias over the legacy item id; ADR-003 allocates card ids in the publication transaction (`FeedStorage/Publication/PublicationRepository.swift:94`) and a durable allocation needs the runtime to own publication (PR-15). See §7 |
155:| `source` | its own legacy page; the plan is **refused** (`FeedSurfacePlanError.runtimeIdentityUnavailable(.source)`) | an allocated runtime `SourceID` for the surface's source. ADR-003 D2/D18 forbid deriving one from a catalogue id or a URL, so this is an **identity decision** — the runtime allocating identities for catalogue sources — and not a wiring one | a decision, then wiring |
166:`MainFeedCardBridge.cardID` builds from a legacy item id — the entry §2.4 lists as unowned, and the reason
287:| Smart Feed / Collections / Source / What's New / content sweep / persistent searches / last clicked / onboarding | each called `FeedStore` directly | **PR-14: done as far as acquisition is single-owned** — a `ResolvedFeedPlan` per surface comes from `FeedSurfaceCatalog` and the app's `SurfaceContextAdapters`; every producer claims the shared demand ledger before it fetches, and no secondary surface owns a transport. The Source surface's plan still needs an allocated runtime identity, and PR-15 moves ownership itself to `AcquisitionCoordinator` (§2.4, §7) |
288:| Background | **PR-15: done.** The registration is real (`BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes = [audio, fetch]`, registered at launch), and the handler runs one bounded demand through the process's single `FeedStore` — claimed on the same `SourceDemandLedger` the foreground uses, budgeted from injected device conditions, with the task completed exactly once on the success, failure and expiration paths. The second tree (P9) is gone; the demand is bounded by the budget and by its own deadline |
293:Rule that must hold after each PR: **no surface may start its own feed acquisition.** The inventory above is the checklist for "enumerate and disable legacy producers" in plan §13/PR-15.
336:  PR-15 must not read "the row exists" as "the surface ships".
337:- `BackgroundRefreshService` is confirmed dead and deleted (§3). **Background feed refresh now runs, implemented by PR-15** (baseline §8.16): the identifier is permitted in `Info.plist`, `UIBackgroundModes` carries `fetch`, and registration happens in `FeedmineEntryPoint.main():19` before the app builds its transports. A launch log shows `smart-feed background refresh registered id=com.feedmine.app.smart-feed-refresh permitted=com.feedmine.app.smart-feed-refresh`.
338:- **The Source surface's plan is not migrated**: `HistoryScope.source(SourceID)` needs an allocated
341:  refuses with `FeedSurfacePlanError.runtimeIdentityUnavailable(.source)`; the surface's *demand* is
342:  arbitrated and its history is preserved by its own query in the meantime (§2.4). Owner: PR-15.
343:- **The card identity in `MainFeedCardBridge` is an alias, and PR-15 does not close it either.** ADR-003
344:  allocates `PublicationCardID` in the publication transaction — `PublicationRepository.commit` →
346:  write transaction, with no standalone allocator — and the bridge has no runtime database, so it carries a
347:  deterministic SHA-256 alias over the legacy item id. PR-15 measured that runtime-owned publication needs the
349:  than half-closed: a durable allocation is a publication-slice change, not a different hash. Owner:
351:- **The BGTask path's second tree is gone** (PR-15, P9 closed): the handler takes the process's one owner
369:  It is now the *first* thing an ingestion slice needs, because PR-15 measured that `v2Presentation`/`v2Full`
372:**The standing of those four, corrected 2026-09-18** (baseline §8.53, with the routes traced rather than inferred). **Bookmarking is closed**, and by the shipped binary, not just at the store level: a bookmark taken in `v2Full` by a driven tap survives installing build 17 over that container, in both stores, resolving through the path build 17's hydration reads (§8.50). **The BGTask is narrower than "fetches nothing"**: the demand's route is `FeedLoader.runBackgroundRefresh` → `FeedStore.runBackgroundRefreshDemand` (`FeedLoader.swift:1278` → `FeedStore.swift:5768`), i.e. the legacy path the gate refuses in `v2Full`, while the runtime acquires only inside a session composition (`V2Acquisition.acquire(for:reason:)`, whose `reason` is a `FeedSessionCompositionReason`) and a session is composed when the screen attaches — so what is actually missing is one unowned wiring (and the purpose it would use, `backgroundMaintenance`, already exists in the plan's table). **Date sectioning is deliberate rather than lost**: `MainFeedPresentationPipeline`'s own doc refuses to invent "Today"/"This Week" headers, because that would be a second grouping rule beside `FeedLoader`'s — whether the runtime's feed should group by day is a product question. **Media is contract-acceptable**: matrix row 22 asks for text plus a thumbnail/poster *or* a deterministic placeholder, and the placeholder carries its reason (`MainFeedCardBridge` → `CardPresentation.Media.placeholder(reason:)`); what is missing is acquiring image bytes, a slice nobody has taken. Still genuinely open from that bullet: a source disabled after its content was admitted stays selectable until PR-17's revalidation, and a canonical search hit carries no read/bookmark overlay, so a runtime result renders unread and un-saved (baseline §8.29).
385:  rather than the removal itself — the card-identity entry is one of those (a durable `PublicationCardID` is allocated
451:| P9 BGTask tree vs foreground tree | **closed by PR-15**: the handler no longer builds `loader ?? FeedLoader()`. It is given the process's one owner, and with none it completes as unsuccessful and logs why rather than building a second `FeedStore`/`RSSFetcher`/OPML tree. The demand claims its endpoints on the same ledger, so a URL the foreground holds is `shared` and issues no request: `SourceDemandLedger.Counters.sharedRefills`, the transport's request log and `RSSFetcher.fetchAttemptCount()` are the observables (`BackgroundRefreshDemandTests.testBackgroundDemandIssuesNoRequestForEndpointsAnotherProducerHolds`) |

### rollout.md §7 (contexto do card identity)
## 7. Open items

Facts PR-14 settled, and what is left open with the owner named:

- `What's New` is enumerated: `FeedSurfaceCatalog` has a `whatsNew` row (owner, entry point, history
  scope, refill window) and `ContextKey.Surface.whatsNew` / `HistoryScope.whatsNew` exist. It still has
  **no view in the tree**; whether the surface is rebuilt or retired remains a product decision, and
  PR-15 must not read "the row exists" as "the surface ships".
- `BackgroundRefreshService` is confirmed dead and deleted (§3). **Background feed refresh now runs, implemented by PR-15** (baseline §8.16): the identifier is permitted in `Info.plist`, `UIBackgroundModes` carries `fetch`, and registration happens in `FeedmineEntryPoint.main():19` before the app builds its transports. A launch log shows `smart-feed background refresh registered id=com.feedmine.app.smart-feed-refresh permitted=com.feedmine.app.smart-feed-refresh`.
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
- **The BGTask path's second tree is gone** (PR-15, P9 closed): the handler takes the process's one owner
  (`FeedmineApp`'s loader), creates one bounded demand through it, and completes the task exactly once on the
  success, failure and expiration paths. Baseline §8.20 has the launch evidence and the two defects the run
  exposed.
- **Content search reads the canonical FTS** (PR-14 item 2, clause two, landed). Clause three landed earlier —
  the online sweep is `demandOnlineContent`, an explicit separate demand, and the local FTS is not its
  implicit trigger — and the index behind the local search now follows the mode: `origin_search` over
  `runtime-v2.sqlite` in a launch whose runtime owns acquisition (`v2Full`), the legacy `feed_item_fts` over

### ADR-003 D2 / D10 / D18 (texto normativo)
**D2 — The catalog ID is a different type, aliased, never converted.** The app-level `FeedEngine.SourceID` (`UInt32`, `Identities.swift:32-37`) is and remains the *catalog* identity. Bridges refer to it as `CatalogSourceID`; there is no `init` on `FeedDomain.SourceID` taking a `CatalogSourceID`, no `UInt32`/`UInt64` narrowing on the path, and no computation of a runtime ID from a URL digest. The only translation is a persisted lookup in `legacy_source_map` (D18), which fails when no mapping exists.

**D3 — Local row IDs are positive `Int64` with a checked encoding.** Every runtime table that stores a local identity uses `INTEGER PRIMARY KEY` in the positive `Int64` range, allocated by SQLite/GRDB, with `CHECK (id > 0)` so `0` stays reserved and unreachable. Legacy values enter through a checked conversion that throws on `0`, negatives and out-of-range values; truncating casts of the kind found at `SQLiteCatalogStore.swift:812-813` are forbidden in `FeedDomain`, `FeedStorage` and the bridges (Technical Architecture §8).
**D10 — An RSS/Atom GUID is not a URL.** A GUID is stored, compared and replayed as an opaque byte string, even when it is spelled like a URI. Runtime V2 does not rewrite its scheme, strip or sort its query parameters, merge hosts, percent-decode/normalize it, or resolve it relative to the feed. `OPMLParser.normalizeURL` remains legitimate for *source/fetch* URL identity (`FeedSource.swift:14`) and the contract tests that pin it remain valid; it is never applied to an external object key.

**D11 — Version collisions are auditable conflicts, never overwrites.** If an admitted observation carries an `externalVersionKey` already attached to another revision of the same record with a divergent payload digest, the stored revision is preserved unchanged, the incoming revision is either admitted under its own version key or rejected, and an `identity_conflict` row of kind `version_payload_divergence` records both digests. A failed/aborted insert is the detection point, not an error to swallow.
**D18 — Legacy bridges are the only legacy identity path.** `legacy_source_map` maps catalog source identity (key + id + canonicalization version) to a runtime source; `legacy_item_map` maps the legacy TEXT item id to an `origin_record`/`origin_revision` with an explicit confidence. While the coexistence window of ADR-004 holds, runtime IDs are never used as the bookmark key: bookmarks keep the legacy durable key and snapshots (plan §5.2, `BookmarkStore.swift:128-134`).

**D19 — No array index and no batch ordinal is an identity.** Nothing durable keys on array position, row order, batch order or viewport index. Ordinals exist only inside an acquisition batch or a published edition, are regenerated per batch/edition, and always accompany a real identity (`PublicationCardID`, `OriginRecordID`, durable action key — ADR-001/004/007).


[[TAREFA]]

Produza o documento normativo que fecha a identidade de runtime para sources de catálogo, como ADENDO ao ADR-003 (não um ADR novo). Decida — não ofereça opções.

Cada item abaixo é uma subseção com DECISÃO / CONSEQUÊNCIA / TESTE:

A1. Como um source de catálogo ganha um `SourceID` de runtime sem derivá-lo da URL nem do id de catálogo (D2/D18)? Qual é o evento de alocação e quem o dispara?
A2. O que substitui a recusa `runtimeIdentityUnavailable(.source)` no SurfacePlan, e sob qual condição exata a recusa continua sendo a resposta correta.
A3. Bootstrap de usuário existente (catálogo com centenas de sources, banco de runtime ainda ausente): alocação em lote, preguiçosa ou híbrida? Custo por launch, idempotência e resumibilidade (diga qual estado intermediário é permitido).
A4. Concorrência: `RuntimeSourceRegistry.sourceID` faz INSERT … ON CONFLICT DO NOTHING + SELECT. Isso é atômico o bastante? Se não, qual a correção mínima e qual teste prova.
A5. `legacy_source_map` com PK `(catalog_source_key, canonicalization_version)`: o que a version significa, quando muda, e o que acontece com as linhas antigas quando muda.
A6. Falha e degradação: quando a linha do mapa não existe (`missingSourceMapping`), a superfície degrada para legacy, recusa, ou aloca? Regra única, sem exceções por superfície.
A7. A relação desta decisão com ADR-002 (Context & Revision Model) e com a ordem de gates já fixada: o que precisa estar congelado antes.

Formato: markdown, máximo ~2500 palavras, denso, citando path:line dos fatos.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; em seguida o documento completo em markdown dentro de UM bloco de código; a última linha é exatamente [[DELIVERABLE-END]]; nada depois disso; sem canvas/Document; sem resumo; sem perguntas soltas.
