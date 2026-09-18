# Runtime V2 — Rollout, surfaces and acquisition ownership

Deliverable of PR-00 in [`docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md`](../superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md).

**Status: proposed material, measured at `b5c2f59c`.** The mode table is the plan's §13 proposal; the inventories below are facts about the base commit, each with `path:line` evidence. Cross-references to ADRs point at proposals, not approved decisions.

## 1. Runtime modes (proposal)

Four valid launch modes instead of free flags (plan §13). Anything else is a defect: in tests it must fail with a diagnostic; in a distribution build it must resolve to `legacy` and log the reason.

| Mode | shadow | UI V2 | network V2 | Authority |
|---|---:|---:|---:|---|
| `legacy` | 0 | 0 | 0 | Legacy acquires and displays; V2 absent |
| `mirroredShadow` | 1 | 0 | 0 | Legacy acquires and displays; V2 observes and compares in isolation |
| `v2Presentation` | 0 | 1 | 0 | Legacy acquires; the bridge feeds V2 as production supply |
| `v2Full` | 0 | 1 | 1 | V2 acquires and displays |

Mode is chosen at launch; live transfer is out of scope until an explicit handoff with cancellation/drain/leases exists. `v2Presentation` is not a shadow mode: Admission failures there must have durable retry/receipt or verifiable replay, because they feed the UI.

## 2. Feed-content surfaces at the base commit

The main feed, the bookmark list, Smart Feed, Collections and curated presets are **one surface**: the same `feedScrollView` inside `FeedScreen.swift`, switched by `loader.selectedBookmarkListID` / preset (`FeedScreen.swift:447,853`; PR-13 moved both lines).

| Surface | Data contract today | Acquires? |
|---|---|---|
| Main feed **(rewritten by PR-13, 2026-09-17 — see §2.1)** | The legacy loader for section text, phases and actions (`@Environment(FeedLoader.self)`, `FeedScreen.swift:7`) **plus** the launch runtime for the presentation (`@Environment(MainFeedRuntime.self)`, `FeedScreen.swift:10`). The rows are `runtime.presentation.sections` (`FeedScreen.swift:865`), whose cards are V2 `CardPresentation`s (`feedmine/RuntimeV2/MainFeedPresentationPipeline.swift:77`) built once by `MainFeedCardBridge` (`feedmine/RuntimeV2/MainFeedCardBridge.swift:65`); in `v2Presentation` every page also goes through `FeedScreenStore` | Yes, via `FeedStore` — unchanged by PR-13 |
| Bookmark list / collection / Smart Feed / curated preset | same view, different `loader` selection; the same rewritten row contract | Yes, via `FeedStore` (`refreshSmartFeed:6868`, `loadCollectionPresetFeed:4132`, `loadLastClickedFeed`) |
| Source detail | `FeedItemView` built from locally constructed `FeedCardPresentation` (`CollectionManagementView.swift:373,522-611`), mapped through `MainFeedCardBridge.card(item:presentation:band:)` (`MainFeedCardBridge.swift:151`) | Yes — `FeedStore.loadSourceContent:7050` → `fetcher.fetch` |
| Collection detail | `FeedItemView` with no presentation (`CollectionManagementView.swift:657`) | Yes — `loadSourceCollectionContent:7134` |
| Search (local) | `searchContentRow` (`FeedScreen.swift:789-793`) over `SearchEngine` results | No — local SQLite/`feed_item` FTS |
| Search (content sweep) | hidden catalogue scan | Yes — `runRemoteSearchSweep:3559` |
| What's New | loader hooks exist; no card surface in the tree (`WhatsNewCarousel.swift` is absent, referenced only by a stale string catalogue) | Yes — `refreshWhatsNew:4435` → `fetchWhatsNewBoosters` |
| Onboarding preview / Welcome samples | `FeedItemCardView` with static/preview presentations, mapped through `MainFeedCardBridge` (`FeedComposerScene.swift:82`, `WelcomeScene.swift:152`) | Yes — `curatedOnboardingItems:6350` |
| Reader | `WKWebView.load(URLRequest)` (`ArticleReaderView.swift:84,92`) | Yes — its own request |
| Audio | `AVPlayerItem(url:)` (`AudioPlayerManager.swift:290`) | Yes — its own stream |
| Share card image | `renderCardAsImage(item:)` via `ImageRenderer` (`ShareCardImageView.swift:100`) | No |
| Export | `ExportView.swift:14` bookmarked items | No |

**Still acquiring through legacy after PR-13: every row above.** PR-13 changed what the Main Feed *draws from*, not who fetches: the only network producers in the modes PR-13 ships are still `FeedStore`'s (`rollout.md` §3), and no surface was migrated to an acquisition owner. `v2Presentation` composes no ingestion either — `RuntimeCompositionRoot.compose` keeps returning `.legacyOnly` for it (`feedmine/RuntimeV2/RuntimeCompositionRoot.swift:102-113`), so the mirror is installed only under `mirroredShadow`.

### 2.1 Main feed contract that PR-13 replaced (state after PR-13)

| Behaviour | Site after PR-13 | Requirement | State |
|---|---|---|---|
| Position signal | `.onScrollTargetVisibilityChange` on the scroll surface (`FeedScreen.swift:924`) → `MainFeedRuntime.viewportChanged` (`MainFeedRuntime.swift:182`) | A bounded viewport observation instead of per-card appearance | **Replaced** |
| Load-more trigger | The same observation; the last visible ordinal travels as `FeedSessionIntent.viewportChanged` and the effect is `FeedLoader.loadMoreIfNeeded(viewportLastVisibleOrdinal:publishedOrdinalCount:)` (`FeedLoader.swift:777`) → `FeedStore.loadMoreIfNeeded` (`FeedStore.swift:2921`), scheduled by the runtime (`MainFeedRuntime.swift:266`), never awaited by the scroll callback | Scroll emits an observation only; replenishment is scheduled asynchronously | **Replaced in both modes.** What the observation cannot yet do is drive a *runtime* runway: the package's `RunwayController` has no production ports (`Sources/FeedRuntime/Runway/RunwayController.swift`), which nobody owns in PR-13's slice |
| Exposure | unchanged: `.onScrollVisibilityChange(threshold: 0.5)` → `loader.markAsSeen` (`FeedScreen.swift:893`) | Dwell-based exposure with an injectable clock | **Open** — no session is composed, so PR-13 kept the legacy signal and reports it as debt |
| Scroll geometry | preserved `.onScrollGeometryChange` → `handleScrollOffset` (`FeedScreen.swift:927`), plus the visibility observation above | Preserve; add anchor compensation for window shifts | **Preserved**; anchor compensation is still absent (the runtime reports an anchor, nothing consumes it) |
| Persisted position | `lastVisibleItemID` from the observation (`FeedScreen.swift:15,1233`), written to `@AppStorage("lastScrollItemID")` on background (`FeedScreen.swift:1348`) | Restore `PublicationCardID + absoluteOrdinal + relative offset` | **Partial** — the anchor is built (`MainFeedPresentation.viewportAnchor`) and travels as an intent, but no `SessionCheckpoint` is persisted: that store belongs to the session, which is not composed |
| Card protocol branching in views | gone from the Main Feed: `FeedItemCardView`/`FeedItemRowView`/`FeedItemView` read `CardPresentation.affordances` and `CardMediaSlot`; the inference lives once in `MainFeedCardBridge.affordances(for:)` (`MainFeedCardBridge.swift:72`), `mediaSlot(for:presentation:band:)` (`:128`) | Presentation must arrive complete; views must not infer protocol from the URL (PR-13) | **Replaced** for the Main Feed, the source/collection lists and the onboarding preview. `FeedItem.isYouTube/isForum/isPodcast/isDirectAudioLink` (`FeedItem.swift:90,93,185,191`) still have consumers outside the card views: `isTimeless`/sorting in the store, the content-type filter match (`FeedLoader.swift:101-107`) and `AudioPlayerManager` |


### 2.3 The support matrix after PR-14 (2026-09-18)

PR-14 registered the per-surface plans and the matrix is executable: it lives in
`Packages/FeedRuntimeV2/Sources/FeedDomain/Plans/FeedSurfacePlans.swift` as
`FeedSurfaceCatalog`, it is validated by `FeedRuntimeTests/FeedSurfaceMatrixTests`, and the app's
adapters read the rows (`feedmine/RuntimeV2/SurfaceContextAdapters.swift`) instead of restating them.

**No secondary surface has its own feed engine.** `sharedFeedEngine` below means the process's one
`FeedStore` → `RSSFetcher` pair, and every such surface claims a URL through
`SourceDemandLedger` before it asks for it, so a resource another surface is already refilling is
shared rather than fetched twice.

| Surface | Owner | Entry point | What it fetches | Acquisition | History scope | Refill window |
|---|---|---|---|---|---|---|
| Main Feed | `FeedStore` | `FeedLoader.start` / `refreshIfStale` / `loadMoreIfNeeded` | the enabled set, in bounded batches | `sharedFeedEngine` | `main` (applies `seen`) | own staleness policy (900 s) |
| Source detail | `FeedStore` | `FeedStore.loadSourceContent` | one endpoint | `sharedFeedEngine` | `source(SourceID)` | 300 s |
| Source collection | `FeedStore` | `FeedStore.loadSourceCollectionContent` | its members | `sharedFeedEngine` | `collection(key:)` | 300 s |
| Bookmarks | `FeedStore` | `FeedStore.loadBookmarkFeed` | nothing: locally retained content | `sharedFeedEngine` | `bookmark(listKey:)` | — |
| Search (content) | `FeedStore` | `FeedStore.search` → `SearchEngine.unifiedSearch` → `CanonicalContentSearch` (`v2Full`) / legacy `feed_item_fts` | the canonical `origin_search` over `runtime-v2.sqlite` when the launch composes the acquiring runtime, the legacy `feed_item_fts` over `feedmine.sqlite` otherwise — see §2.4 | `localContentSearch` | `search` | — |
| Search (online sweep) | `FeedStore` | `FeedStore.runRemoteSearchSweep` | eligible endpoints, chunks of 32 | `explicitOnlineContentDemand` | `search` | — |
| Search (sources) | `SQLiteCatalogRepository` | `CatalogBrowserViewModel.loadRoot` | the local catalogue file, read-only | `localCatalogueQuery` | none (composes no cards) | — |
| Smart feed | `FeedStore` | `FeedStore.refreshSmartFeed` | the smart feed's sources | `sharedFeedEngine` | `smartFeed(key:)` | own refresh policy |
| Persistent search | `FeedStore` | `FeedStore.matchPersistentSearches` | nothing: matches admitted content | `localContentSearch` | `persistentSearch(key:)` | — |
| Last clicked | `FeedStore` | `FeedStore.loadLastClickedFeed` | locally retained clicked items | `sharedFeedEngine` | `lastClicked` | 300 s |
| What's New | `FeedStore` | `FeedStore.refreshWhatsNew` | up to 30 shuffled enabled sources | `sharedFeedEngine` | `whatsNew` (own baseline) | 900 s |
| Onboarding showcase | `FeedStore` | `FeedStore.curatedOnboardingItems` | the starter set for the selected languages | `sharedFeedEngine` | `onboarding` | 900 s |

The `HistoryScope` column is what ADR-007 D12 says, enforced by `FeedPlanResolver`: `applySeen` is
derived from the scope (`HistoryScope.allowsSeenExclusion`) and a plan that declares otherwise is
refused, so "a card seen in Main does not disappear from Bookmark, Source, Search, What's New, the
onboarding showcase or the click history" is a resolver answer and not a convention
(`FeedSurfaceCatalog.excludes`, exercised by `testMainExposureDoesNotHideBookmarkOrSourceHistory` in the
package's `SelectionEngineTests`/`SessionCheckpointTests` and, under its own name,
`testMainExposureDoesNotHideTheOtherSurfacesHistory` in the app's `SurfacePlanMigrationTests`).

### 2.4.1 The state after the owner swap and the boundary slice (2026-09-18)

§2.3 and §2.4 are the snapshot PR-14 produced. Two facts changed after them, and reading §2.4 as current
would now be wrong on both:

* **The Main Feed's acquisition is the runtime's, in `v2Full`.** The owner swap landed before PR-17's gate:
  `MainFeedRuntime.ownsAcquisition` (`composition?.full != nil`) is true in that mode, and the device launch
  measured it — `legacy-gate=closed legacy-requests-refused=0`, `episode=1 purpose=activeRunway targets=32
  pulls=1`, `composition … decision=published edition=edition:3 cards=12` (`baseline.md` §8.32, verbatim).
  "Acquisition legacy, presentation V2" is no longer the state for that selection.
* **Presentation is per *selection*, not per mode.** A launch's session owns one selection; in `v2Full` a
  bookmark box, a Smart Feed, the last-clicked history, a collection or a curated preset draws **its own**
  legacy page — not the Main Feed's snapshot, which is what it used to draw (§8.31, §8.32). Its local reads
  work; its *fetches* are refused by the gate, so what it draws is the content the store already holds.

| Surface, in `v2Full` | Acquisition | Presentation | Phase and emptiness |
|---|---|---|---|
| the selection the session's plan was built for (`main`) | the runtime (`RunwayController` episodes; `targets=`, `pulls=`) | the session's snapshots | the session's own statements (`MainFeedSessionSurface`: `.preparing` / `.content` / `.empty(FeedEmptyMode)`) |
| every other selection (bookmark box, Smart Feed, last-clicked, collection, curated) | refused: the gate closes fetches | **its own** legacy page | the legacy loader's own page (`feedDisplayPhase`) |
| `search`'s local content half | n/a (a local read) | the canonical `origin_search` index | legacy |
| `legacy`, `mirroredShadow`, `v2Presentation` | legacy, unchanged | legacy, unchanged | legacy, unchanged |

The mechanism, the tests that pin it and the gaps it leaves are in §8.32 and
`feed-session-boundary-report.md`.

### 2.4 What is still legacy on the surfaces (PR-14's honest remainder)

| Surface | State | Why |
|---|---|---|
| Main Feed, bookmark list, Smart Feed, collections | acquisition legacy, presentation V2 — **superseded in `v2Full` by §2.4.1**: the runtime owns acquisition for the session's selection, and a selection the session does not own keeps its own legacy page | PR-13/PR-14 closed the demand arbiter without a second owner, and PR-15 closed the one place a second *tree* still existed (the BGTask path, P9). V2 owning acquisition itself is still not taken: it needs a canonical→presentation path first, or the owner swap either shows the reader nothing or double-fetches (baseline §8.20) |
| Source detail | acquisition legacy + demand arbitrated; **plan not resolved** | its `HistoryScope` is `.source(SourceID)`, a runtime identity, and ADR-003 D2/D18 forbid deriving one from a catalogue id or a URL. No shipping mode composes a runtime database, so there is no allocated `SourceID` to name. `FeedSurfacePlanError.runtimeIdentityUnavailable(.source)` is the refusal, asserted by test |
| Source collection | acquisition legacy + demand arbitrated; plan resolved as `collection(key:)` | the collection's identity is its own durable string key |
| Card identity in the bridge | **unowned by PR-14** | `MainFeedCardBridge.cardID` is a deterministic alias over the legacy item id; ADR-003 allocates card ids in the publication transaction (`FeedStorage/Publication/PublicationRepository.swift:94`) and a durable allocation needs the runtime to own publication (PR-15). See §7 |
| Reader, audio, image download | allowed explicit-action network, unchanged | rollout §3 and plan §10: they are separate categories, not feed acquisition |
| Content search's index | **landed** (PR-14 item 2, clause two) | the local content search reads the canonical `origin_search` exactly when the launch's runtime owns acquisition, and the legacy `feed_item_fts` otherwise. The read path is `CanonicalSearchRepository` (`Packages/FeedRuntimeV2/Sources/FeedStorage/Selection/`), mapped by `feedmine/RuntimeV2/CanonicalContentSearch.swift`, installed by `MainFeedRuntime.startSession` → `FeedStore.useCanonicalContentSearch` (removed again by `MainFeedRuntime.stop`). The mode decides the index; there is no fallback between the two. What a canonical hit does **not** carry yet: a read/bookmark overlay (the runtime's `user_state_projection` is not projected onto a search row — the card-identity slice's work), a legacy item id unless `legacy_item_map` has one (`origin:<recordID>` otherwise), and results for a reader whose runtime has admitted nothing yet — the canonical index is the answer there, and empty is the honest one. Saved/bookmark search stays on the legacy hydration path, because a bookmark is keyed by a legacy item id in `user.sqlite` (ADR-004 D6) and that join is a different authority. Owner: the card-identity slice for the overlay; PR-17's revalidation for the rest |


### 2.5 The plan per surface — DoD15's remaining half (2026-09-18)

§17's DoD15 asks that every surface use the same runtime, and its own note says how it closes: "with PR-17
plus **a plan per surface**". §2.3, §2.4 and §2.4.1 are the *state*, and §8.31 measured it per surface; this
is the plan, and it is short because the mechanism is already per selection.

**The comparison already exists.** `MainFeedPresentationPipeline.followLegacyPage` (`:225-231`) reads the
context key of the page the loader published and answers with the session's snapshot **iff that key equals the
session's** (`page.contextKey == sessionContextKey`), and with the legacy page otherwise. Nothing in it is per
mode or per surface name: a surface that draws the session's selection gets the session.

**What is single is the session's key.** `beginSession(contextKey:)` (`:191-197`) sets one
`sessionContextKey`, claimed at `attach` for the Main Feed (`MainFeedRuntime.swift:455-461`, its plan from
`SurfaceContextAdapters.mainFeed(loader:)`). The package underneath is not single: `FeedSession.compose`,
`.restore` and `.page` each take a `ContextKey` per call (`FeedSession.swift:26, 371, 486, 516`), and the
adapters can already state a secondary surface's plan — `secondaryInputs(loader:scopeKey:planIdentity:)`
inherits the reader's filters, so a card cannot be filtered out of a sheet and left in the feed.

So the step that unblocks the secondary surfaces is **one app-side lifecycle change**: let a selection whose
context resolves start and stop its own session, instead of only the single one claimed at `attach`.
Acquisition is not part of it — the runway's targets are process-wide (one owner per target) and do not
restart per selection; what is per selection is composition.

| Surface | Route today | What moving it needs | Cost shape |
|---|---|---|---|
| `main` | the session's snapshots (§2.4.1) | — | done |
| `bookmarks` | its own legacy page (`bookmark(listKey:)` resolves) | the lifecycle step, the render overlay (§8.29: a canonical hit carries no read/bookmark overlay) **and** the content path — a session composes from the runtime's canonical supply, while a bookmark box's cards are the reader's saved legacy rows, and the two meet only when one card has one durable `PublicationCardID` (§2.4's unowned row) | one step plus an unowned lane |
| `smartFeed` | its own legacy page (`smartFeed(key:)` resolves) | the lifecycle step and the same content path: its cards are legacy rows too | one step plus the same lane |
| `lastClicked` | its own legacy page (`lastClicked` resolves) | the lifecycle step, the same content path, and the overlay for the same reason | one step plus the same lane |
| `sourceCollection` | its own legacy page (`collection(key:)` resolves) | the lifecycle step and the same content path (its members' cards are legacy rows) | one step plus the same lane |
| `source` | its own legacy page; the plan is **refused** (`FeedSurfacePlanError.runtimeIdentityUnavailable(.source)`) | an allocated runtime `SourceID` for the surface's source. ADR-003 D2/D18 forbid deriving one from a catalogue id or a URL, so this is an **identity decision** — the runtime allocating identities for catalogue sources — and not a wiring one | a decision, then wiring |
| `search` (local content) | the canonical `origin_search` index in `v2Full` (§8.29) | the overlay, and one screen reading two databases (`Saved` still answers from `feed_item_fts`) | the card-identity lane |
| `persistentSearch` | matched locally; **no view consumes it** | nothing until a view exists | none today |
| `whatsNew` | a fetch path; **no view** | nothing until a view exists | none today |
| `onboarding` | the curated showcase's legacy page | a session composed before onboarding completes, or a decision that this surface stays outside the runtime | lifecycle question |
| `catalogueBrowse` | a read-only local catalogue query that composes no cards | nothing: the catalogue says it has no editorial plan, and `context(_:inputs:)` throws for a surface that composes no cards | correctly outside |

The line worth reading twice: **the surfaces that already share the runtime's selection need only wiring, and
the ones whose content is legacy-retained need the card-identity lane first.** A session composes from the
runtime's canonical supply; a bookmark box, a Smart Feed and the click history draw cards the legacy store
holds, and the two meet only when one card has one durable `PublicationCardID` rather than the alias
`MainFeedCardBridge.cardID` builds from a legacy item id — the entry §2.4 lists as unowned, and the reason
§2.4 warns that moving a surface too early "shows the reader nothing". So "all surfaces use the same runtime"
is **one lifecycle step, one content path and two decisions** — not eleven migrations, and not wiring alone.

**Verified 2026-09-18 against this tree, claim by claim** (the audit that tried to falsify this section and could
not): (a) `MainFeedPage` is constructed in exactly one place, `MainFeedPresentationPipeline.followLegacyPage`, and
its `contextKey` is minted by `SurfaceContextAdapters.mainFeed(loader:)` — so the selection the runtime can
observe today is one screen's, exactly as this section says, and the "lifecycle step" is not something the four
secondary rows get for free by being listed in the table; (b) the content path is real and *unstarted*, not merely
unowned: `Selection/` (`EditorialSequencer`, `FeedPlanResolver`, `FeedSurfacePlanning`, `SelectionEngine`) contains
**zero** occurrences of `bookmark` or `listKey`, and the supply query is
`SelectionSupplyRepository.page(SupplyPageRequest(sourceSelection:after:windowRows:))` — a source selection over
canonical supply, with no bookmark dimension; (c) the scope vocabulary is nevertheless complete —
`FeedSurfaceCatalog.plan(for:)` returns `HistoryScope.bookmark(listKey:)`, `.collection(key:)`, `.smartFeed(key:)`
and `.lastClicked` — so the gap is the query, not the identity of the scope; and (d) the projections the plan
reads are the revision inputs (`PlanProjections.catalog` / `.userState`, ADR-002 D6), not a card selector, which is
why filling them is not the same work as teaching Selection the scope. The first concrete step is therefore (b): a
scope-aware selection that turns one of those scopes into the canonical cards the plan reads, built on the two
things the app already writes — `UserStateProjectionStore.savedSubjects()` and the `legacy_item_map` alias that
resolves each saved subject to its `origin_record`/`origin_revision`. Until that exists, starting a session for
`bookmarks` would compose an empty page, which is the failure §2.4 warns about.

**And the first half of (b) now exists, with one design constraint measured the hard way (2026-09-18, baseline
§8.56).** `SupplyPageRequest` carries a `SupplyRecordScope` — `.savedSubjects(kind:)`, resolved inside the query
as one indexed join over `user_state_projection` and the `legacy_item_map` alias, plus `.noRecords` for a scope
the storage cannot honour (a named bookmark list, until the list key is projected). Wiring it from the plan's
`HistoryPolicy.scope` was **tried and reverted**: a `HistoryScope` is an eligibility rule — what a `seen`
elsewhere may hide from this surface (ADR-007 D12) — not a selector of the reader's saved cards, and
`SelectionEngineTests.testMainExposureDoesNotHideBookmarkOrSourceHistory` failed in one run to say so. The scope
must therefore be an explicit input the plan carries, which is the next step: the storage half is in place and
tested; what is missing is the plan's own selection field and the surface that reads it.

**And that field landed the same day (baseline §8.57).** `FeedPlan.subjectSelection` is a plan input the caller
states — `FeedSurfaceCatalog.Inputs.subjectSelection` — it is serialized into the revision (scheme **2**), and the
engine passes it straight into the query. The audit's correction above is why it is an input and not a
surface-derived value: the catalogue's `bookmarks` row and the app's bookmark box share a name and nothing else,
and a test requires the former to compose the whole supply. What remains for the surface is the screen: a
bookmark box composing through the session instead of drawing its own legacy page.

**And the order this section gives for that surface is wrong, measured 2026-09-18 (baseline §8.58).** A box's
content is *that list's membership* — `FeedLoader.selectedBookmarkListID`'s setter loads
`bookmarkedItems(listID:)` — and the runtime's projection carries no list key, so a session started for a box
today would compose every saved card, whatever list it is in. The order is therefore **(1)** project the list key
(the app write plus a migration for a new durable column), **(2)** the screen, **(3)** the lifecycle step above —
which is the same step whether one box or all of them are drawn. The runtime is not the blocker: §8.56 and §8.57
cleared its half, and nothing in it changes for the projection to be added.

**Step (1) landed the same day (baseline §8.59).** `v7_user_list_membership` projects the membership keyed
`(list_key, subject_id)` — a second table rather than a column, because a subject's *wanted* state is not per
list — with `UserStateProjectionStore.applyListMembership` writing it idempotently against the same watermark,
and `SubjectSelection.savedSubjects(kind:listKey:)` reading it. A box now selects its own membership and not
every saved card, with a test for each. What is left is the app's *write* (nothing calls it in production yet:
the session's bookmark intent carries no list, so the box has to reach the write from the view that knows it)
and then the screen.

**The write landed too, the same day (baseline §8.60).** `UserStateBridge.setBookmarked` writes the membership for
the list the store chose — one spelling of a list key, `UserStateBridge.listKey(for:)` — and
`reconcileListMemberships` runs at launch so a bookmark taken before the projection existed is still in its box
rather than missing from a page that looks right. What remains for this surface **is the screen**: a box
composing through the session instead of drawing its own legacy page.

**The screen landed too, the same day (baseline §8.61).** `SurfaceContextAdapters` states the box's selection,
the presentation reports a move off the session's selection, and `MainFeedRuntime.adoptSelectionIfNeeded` adopts
**only the box dimension** — a preset move keeps its legacy page, because a Smart Feed's cards are legacy rows
and a session for one would compose the canonical supply under a title that promised them. Closing a box adopts
the unboxed feed back. What remains for this section is its *proof on the surface*: a UI launch with a box open,
since the adoption path has no in-suite seam once the runtime owns a composition — and its failure mode is the
legacy fallback, so the change can fail into today's behaviour but not into a wrong page.

Line numbers are this tree's, read on 2026-09-18; §2.2's discipline applies.

### 2.2 `path:line` drift PR-13 introduced

PR-13 added ten lines to `FeedStore.loadMoreIfNeeded` (`FeedStore.swift:2911-2920`), so **every `FeedStore.swift` line after 2911 in this document is now ten lines low**: §3 cites `refreshNow:2879` (before the edit, so unchanged) but also `refreshSmartFeed:6868`, `runRemoteSearchSweep:3559`, `refreshWhatsNew:4435`, `curatedOnboardingItems:6350`, `loadSourceContent:7050`, `loadSourceCollectionContent:7134` and the rest of its `FeedStore` rows, which each move by +10. `FeedScreen.swift` moved as well (the runtime environment, the row contract and the viewport observation) and `FeedLoader.swift` moved by -1, both re-stated at their current lines in §2 and §2.1 above. Re-verifying the §3 citations belongs to whoever next edits that section.

**The drift, re-anchored 2026-09-18 (the boundary and loading slices moved `FeedScreen.swift` again).**
Measured on this tree, and dated on purpose — a line number is true for the tree it was read from and
nothing else: `FeedScreen.swift` — `surfaceContentCount :113`, `sessionFeedContent :181`,
`legacyFeedContent :205`, the split itself `:134-138` (`if let session = runtime.sessionSurface`), the
`legacyPageFallback` condition `:1000`, `noteViewport :1327`, `updateBadge :1406`,
`InitialFeedLoadingView :2000`, the per-card exposure site now `runtime.cardBecameVisible(itemID:)`, and
`FeedLoadingDisplay.forSurface` the only reader of the five legacy runway counters; `MainFeedRuntime.swift`
— `MainFeedLoadingStatement :99-146`, `sessionLoadingStatement :207`, `sessionSurface :222` (which now also
answers for `pageSource == .none` so the first frame is the session's lane, not the runway's). The
`FeedStore.swift` rows in §3 still carry PR-13's +10, unchanged by this.

## 3. Network producers at the base commit

Complete list of sites in `feedmine/**` that start outbound I/O (search terms: `URLSession`, `dataTask`, `.data(from:`, `.bytes(for:`, `URLRequest(`, `import FeedKit`, `FeedParser`, `AVPlayer`, `WKWebView.load`). Feed acquisition funnels through one actor pair; the rest are separate transports.

| Site | Owner | Role | Reached from |
|---|---|---|---|
| `FeedHTTPSync.swift:16-30,82,96-104,153` | `FeedHTTPSync` (actor) | Conditional-GET transport, 304 handling, validator extraction | `RSSFetcher` |
| `RSSFetcher.swift:41-64,75,110,165,234,503,523` | `RSSFetcher` (actor) | FeedKit parsing, batch/starter fetch, inline audio probes | All feed paths |
| `FeedStore.swift` (many) | `FeedStore` (MainActor) | Every acquisition decision: bootstrap `:1612`, progressive `:5374`, background drip `:5636`, `refreshNow:2879`, `refreshIfStale:2957`, `shakeToRefresh:7419`, smart feed `:6868`, background smart feed `:5613`, What's New `:4435`, onboarding `:6350`, content sweep `:3559`, taxonomy batch `:4946`, `toggleSource:3988`, `seedRegion:6255`, Source `:7050`, collection `:7134` | Launch, refresh, background demand (`runBackgroundRefreshDemand`, `FeedStore.swift:5750`), UI toggles |
| `CatalogUpdateService.swift:304-315,408,451` | `URLSessionCatalogUpdateTransport` | Remote catalogue manifest/payload | `FeedLoader.start():734`; disabled in release (`CatalogReleasePolicy.remoteUpdatesEnabled = false`, `:29`) |
| `ImportPipeline.swift:38-45,220,288-289,314-319` | `ImportPipeline` (actor) | Feed/OPML import probes and bounded downloads | UI import |
| `URLResolver.swift:17,21,212,232,500-501` | free function + `URLResolver` (actor) | URL classification probes, iTunes lookup | Add-feed UI |
| `MediaAssetStore.swift:32-39` (+ `downloadImageData`) | `MediaAssetStore` (actor) | Bounded image download during card preparation | Feed render pipeline |
| `ImageCache.swift:165-184,227,842-849,927` | `ImageCache`, `ArticleImageResolver`, `CachedAsyncImage` | Article HTML fetch and image download | Render fallback, MiniPlayerBar, share, onboarding |
| `ImageLoader.swift:56,86-95` | `ImageLoader` (static session) | Image network hop for the prepared pipeline and the retry queue | Card preparation, `ImageResolutionQueue` |
| `ImagePrefetcher.swift:9-16,64` | `ImagePrefetcher` (actor) | Legacy background prefetch | Only when the prepared pipeline is off |
| `SourceManagementView.swift:265-269` | view | "Test sources" probe with its own session | Manual UI |
| `ArticleReaderView.swift:84,92` | `ArticleReaderCoordinator` | Reader load | Manual UI |
| `AudioPlayerManager.swift:290` | `AudioPlayerManager` (MainActor) | Episode stream | Manual UI |
| `feedmineApp.swift:5-181` (scheduler), `feedmine/RuntimeV2/BackgroundRefresh.swift` (the seam and the budget), `FeedmineEntryPoint.swift:19` (registration) | `SmartFeedBackgroundScheduler` | BGTask registration at launch, before the app builds its transports; the handler creates one bounded demand through the process's single acquisition owner and completes the task exactly once. It builds no loader, store or fetcher of its own — that second tree was P9 | Background |

Retry/backoff today: no feed-level retry loop in `RSSFetcher` (successive scheduler passes only); image retries live in `ImageResolutionQueue` with exponential backoff (`:55-88`). Validators are persisted in `source_health` (`FeedStore.saveSourceHealthBatch:1264-1310`) and consumed by `AdaptiveScheduler.shouldUseConditionalGet:208-210`.

`BackgroundRefreshService.refreshSmartFeeds:29-31` had no caller outside its own definition and the
file was in **no target** (`grep -n BackgroundRefreshService feedmine.xcodeproj/project.pbxproj`
returned nothing), so it never compiled and could not have been acquiring anything. Confirmed and
deleted by PR-14; that is why no pbxproj entry had to be removed with it. `FeedLoader.prefetcher`, the
second dead `ImagePrefetcher` (no reader of `.prefetcher` anywhere in `feedmine/`), was deleted in the
same slice — the live one is `FeedStore.prefetcher`.

## 4. Ownership plan (single owner per target)

| Scope | Today | Target |
|---|---|---|
| Main feed acquisition | `FeedStore` on the main actor, many entry points | `AcquisitionCoordinator` in `FeedRuntime`, one owner per `acquisition_target` |
| Smart Feed / Collections / Source / What's New / content sweep / persistent searches / last clicked / onboarding | each called `FeedStore` directly | **PR-14: done as far as acquisition is single-owned** — a `ResolvedFeedPlan` per surface comes from `FeedSurfaceCatalog` and the app's `SurfaceContextAdapters`; every producer claims the shared demand ledger before it fetches, and no secondary surface owns a transport. The Source surface's plan still needs an allocated runtime identity, and PR-15 moves ownership itself to `AcquisitionCoordinator` (§2.4, §7) |
| Background | **PR-15: done.** The registration is real (`BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes = [audio, fetch]`, registered at launch), and the handler runs one bounded demand through the process's single `FeedStore` — claimed on the same `SourceDemandLedger` the foreground uses, budgeted from injected device conditions, with the task completed exactly once on the success, failure and expiration paths. The second tree (P9) is gone; the demand is bounded by the budget and by its own deadline |
| Images/media | `MediaAssetStore` + `ImageLoader` + `CachedAsyncImage` + `ImagePrefetcher` | `FeedMedia` behind `ImageBroker`, download before publication, no network in the renderer (PR-08) |
| Remote catalogue | `CatalogUpdateService` (release-disabled) | Unchanged by the runtime; catalogue stays read-only to V2 |
| Reader and audio | own transports | Allowed explicit-action network, recorded as a separate category (§10 of the plan) |

Rule that must hold after each PR: **no surface may start its own feed acquisition.** The inventory above is the checklist for "enumerate and disable legacy producers" in plan §13/PR-15.

### 4.1 Where the shadow's second mirror level must hook

Measured while preparing PR-12: `RSSFetcher` parses first and maps second — `FeedParser(data:).parse()` at `RSSFetcher.swift:110` produces the FeedKit entries, which are then turned into `FeedItem` (whose id is a SHA-256 over `sourceURL|guid_or_link|title|timestamp`, `Models/FeedItem.swift:394-402`, and which does **not** keep the raw GUID).

So the two mirror levels have two different, non-interchangeable capture points:

| Level | What it can prove | Capture point |
|---|---|---|
| 1 — `FeedItem` + source + outcome | canonicalization and presentation semantics, with `legacyItemID` as an alias; it cannot prove RSS/Atom identity fidelity, because the GUID is already gone | the persistence/admission convergence point (after mapping) |
| 2 — envelope with the original identity | the translator and the identity rules themselves (opaque GUID preserved byte-identical, Atom `updated` as version key) | **inside `RSSFetcher`, between the parse and the mapping**, under budget and short retention — never a second fetch |

Anything that needs the raw GUID must hook before mapping; hooking after it re-derives an identity that the wire format already provided, which ADR-003 D10 forbids.


## 5. Shadow requirements (PR-12)

- Two mirror levels: (1) `FeedItem` + source + outcome, preserving `legacyItemID` as an alias and never fabricating a GUID; (2) the envelope with the original parsed identity (GUID/Atom id, or the response bytes the legacy path already fetched, under budget and short retention). No second fetch.
- Mirroring only `persistFetchedItems.actualNew` is insufficient: it loses updates, duplicates, 304 and empty-but-relevant results. Coverage must be measured per source and per batch at the convergence point of the acquisition paths.
- Shadow writes no exposure, bookmark or user cursor, triggers no media download or extra probe, and uses local assets or placeholders. It measures CPU/RSS/DB/WAL/bytes and disables itself when over budget.
- Under `mirroredShadow` a bounded queue may drop work, provided drops are counted and comparisons for that interval are invalidated.
- Evidence available for the comparator: `FeedMetrics` signposts (`com.apple.app/FeedEngine` subsystem, `#if DEBUG || INSTRUMENTATION`) at `FeedStore.swift:716,1120,1890,1904,1962,1983,1811,1899,1900,1917-1925,2028-2029,2281` and `FEED_FIRST_SCREEN`-style UI intervals at `FeedScreen.swift:1290-1298`. `FeedMineSignposts` (22 semantic intervals) is **not** in the app target today.

## 6. Rollback

Rollback is a mode change, not a rollback of user data. Before any promotion to `v2Full`, all of the following must be demonstrated on a real device and recorded:

| Requirement | Why it is not optional here |
|---|---|
| `v2Full` → `legacy` after relaunch, with bookmarks, collections and read state intact | `user.sqlite` remains the authority (baseline §7.2); the runtime must not become the only place an intention exists |
| Content acquired only by V2 remains hydratable in legacy | legacy hydration reads `feedmine.sqlite.feed_item`; bookmarks whose rows are gone already degrade silently (`BookmarkStore.swift:117-131`) |
| No double acquisition after the switch | legacy producers run from launch, refresh, Source, Search, Smart Feed, retries and background (`rollout.md` §3) |
| The V2 database is left intact for diagnosis and re-entry | re-entering V2 without re-adopting the catalogue |
| Tested binary versions are recorded | plan §13: do not promise compatibility with "any old binary" |

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
  `feedmine.sqlite` everywhere else. The two tests that pinned the swap's arrival point
  (`SurfacePlanMigrationTests.testLocalContentSearchIssuesNoOnlineDemand`,
  `testContentSearchStatesWhetherItDemandsTheNetwork`) are re-stated against the new source with their meaning
  intact, and the mode-dependent answer is visible in four tests plus an end-to-end one
  (`OwnerSwapAcquisitionTests.testTheLocalContentSearchReturnsTheAdmittedCanonicalContent`). What is still
  open, in §2.4's words: no read/bookmark overlay on a canonical hit, no legacy item id unless the bridge has
  one, no local results for a `v2Full` reader whose runtime has admitted nothing, and saved-bookmark search on
  the legacy hydration path by design. Report: `pr-14-canonical-search-report.md`.
- The four-mode table needs to state what `v2Presentation` does when Admission fails permanently — the plan
  requires durable retry/receipt; the surface-level fallback (legacy content vs empty state) is not yet decided.
  It is now the *first* thing an ingestion slice needs, because PR-15 measured that `v2Presentation`/`v2Full`
  cannot be composed without that answer (baseline §8.20).
- **The owner swap landed** (report: `owner-swap-report.md`; baseline §8.25), and the user-state gap it reported is closed: **bookmarking a runtime card now works and survives a rollback.** A bookmark in `v2Full` is written to `user.sqlite` (the authority: `user_operation` pending→applied, `bookmark_item` keyed by a legacy item id, `bookmark_snapshot`), projected into `runtime-v2.sqlite` (`user_state_projection` + `user_state_watermark`) and into `feedmine.sqlite` in the shape the legacy reader hydrates (`feed_item` via `ON CONFLICT(id) DO NOTHING` for the acted-on card only, plus the legacy retention pin), with `legacy_item_map` as the durable alias — and the guard against removing legacy early was the reason for the delay (baseline §8.25, and the reverse-direction binary repeat — the one proof that was still missing — was run on 2026-09-18 with the shipped binary: a tap driven by a UI test in `v2Full` wrote the bookmark, and installing build 17 (`FeedmineGitSHA 4df951c4`) over that container left both rows intact in both stores and both resolving through the path build 17's hydration reads, §8.50).
**The standing of those four, corrected 2026-09-18** (baseline §8.53, with the routes traced rather than inferred). **Bookmarking is closed**, and by the shipped binary, not just at the store level: a bookmark taken in `v2Full` by a driven tap survives installing build 17 over that container, in both stores, resolving through the path build 17's hydration reads (§8.50). **The BGTask is narrower than "fetches nothing"**: the demand's route is `FeedLoader.runBackgroundRefresh` → `FeedStore.runBackgroundRefreshDemand` (`FeedLoader.swift:1278` → `FeedStore.swift:5768`), i.e. the legacy path the gate refuses in `v2Full`, while the runtime acquires only inside a session composition (`V2Acquisition.acquire(for:reason:)`, whose `reason` is a `FeedSessionCompositionReason`) and a session is composed when the screen attaches — so what is actually missing is one unowned wiring (and the purpose it would use, `backgroundMaintenance`, already exists in the plan's table). **Date sectioning is deliberate rather than lost**: `MainFeedPresentationPipeline`'s own doc refuses to invent "Today"/"This Week" headers, because that would be a second grouping rule beside `FeedLoader`'s — whether the runtime's feed should group by day is a product question. **Media is contract-acceptable**: matrix row 22 asks for text plus a thumbnail/poster *or* a deterministic placeholder, and the placeholder carries its reason (`MainFeedCardBridge` → `CardPresentation.Media.placeholder(reason:)`); what is missing is acquiring image bytes, a slice nobody has taken. Still genuinely open from that bullet: a source disabled after its content was admitted stays selectable until PR-17's revalidation, and a canonical search hit carries no read/bookmark overlay, so a runtime result renders unread and un-saved (baseline §8.29).

— The original entry, kept because the reasoning is what a reader needs:
- **The owner swap is a slice with no plan item, and several entries above wait on it.** PR-17's gate is "um
  único runtime ativo e nenhuma superfície órfã", but reading the plan's own item lists shows nothing that
  *makes V2 acquire*: PR-16's three items are GC/recovery/SLOs and PR-17's three are inventory/removal/revalidation.
  Measured (baseline §8.21): `Sources/**` has no production `HTTPTransport` (only `ScriptedTransport`/`SpyHTTPTransport`),
  the only legacy→`AcquisitionObservation` converter is the parity lane's `ShadowInputBridge` — which always emits
  `precedence: .makeCurrent`, fills no `memberships`/`mediaCandidates` and never proposes a checkpoint — and
  `RuntimeCompositionRoot.compose` returns `.legacyOnly` for the acquiring modes by construction
  (`RuntimeCompositionRoot.swift:64-67`, message at `:110-111`). The seam is located in baseline §8.23 and briefed at
  `local://owner-swap-spec.md`. Consequence for this file: the entries above that read "Owner: PR-16/PR-17" should be
  read as **owner: the owner-swap slice** wherever the blocker is the missing canonical→presentation composition
  rather than the removal itself — the card-identity entry is one of those (a durable `PublicationCardID` is allocated
  in the publication transaction, so it needs a production composer, not a different hash).

- **The pilot's preconditions are now written down** (`pilot-plan.md`): the plan's §22 asks to define an
  observation window, the devices and the sample *before* a pilot, and §16 forbids fixing budgets before a
  minimum-device baseline. That file fixes the procedure — promotion gates, device classes and why, the
  scenario sample with what each row may and may not claim, and how each §16 measure is read with the
  instrument that exists — and deliberately fixes no number.

### The decisions the owner holds, with the evidence each one needs (2026-09-18)

Four things are stopped on a decision rather than on work, and each has its evidence written down so the
decision can be made from the record:

1. **PR-17 item 2, the legacy removal.** The plan's §22 and §1 make an irreversible removal the owner's call.
   What the record supplies: the window proof and its level (`baseline.md` §8.13.1, §8.28), the fact that
   `simctl` cannot inject a tap, which §8.28 recorded as making the reverse direction of the window proof not
   repeatable in this environment and which §8.50 then ran anyway with the shipped binary — three of those four
   grounds are true and none decided the outcome, because XCUITest drives the accessibility layer rather than
   `simctl` and the mode is selectable by launch argument, so the obstacle was one missing
   `accessibilityIdentifier` and one UI test (§8.50), and the second-paradigm proof that the plan requires to hold before the removal
   (§8.25's clean install, §8.28's upgrade, and the package-level proof that stays green). The re-run *after*
   the removal is what keeps DoD18 open.
2. **The legacy-visible read state.** §8.36 splits it, §8.39 implements the runtime half, and the measured
   cost of the other half is arithmetic: the unread badge is `items.count - readItemIDs.count` over a globally
   loaded `is_read = 1` set, so a row V2 inserts subtracts from the visible page's count **even when it is not
   in `items`** — the badge can read zero with unread legacy items on screen. A rollback to build 17 loses the
   reader's read state without it (`read-state-report.md` §5).
   **Sharpened 2026-09-18 by measuring the code as it stands: that arithmetic is the cost of *taking* the
   decision, not a miscount that is live today.** The runtime's read path deliberately does not perform the
   legacy half — `V2FullRuntime:101-105` states it and the reason ("taking it silently would change what the
   legacy page contains and what the unread badge counts") — and the user-state projection inserts its
   `feed_item` rows with `is_read = 0` (`UserStateBridge:153`), so neither side can move `readItemIDs` while the
   decision is open. The legacy half still runs verbatim for a page the session does not own
   (`MainFeedRuntime:726-730`: "a legacy row's open still writes `feed_item.is_read`, in the acquiring mode
   included, because that page is that store's"). Adding the legacy-visible read state is what would make the
   badge's arithmetic matter; not adding it is what loses the reader's read state on a rollback.
3. **The CI's red on `main`.** §8.22: one job failed on `-testPlan` against a scheme with no plans (already
   fixed in the uncommitted work), the other on a real Swift 6 error under the runner's Xcode 16.4 in
   `ArticleReaderView.swift:78-80`. This machine has **only** 26.6 (verified: `xcodebuild -version`, and the
   only simulator runtime is iOS 26.5), so validating either fix — correcting the code or pinning the
   toolchain in the workflow — needs a push. §8.22.2 and §8.40 also changed that workflow, which has the same
   limitation: it only runs on GitHub.
4. **DoD20's numbers.** Instrumentation is landed and the methodology is fixed (`pilot-plan.md` §4); the
   figures need a Release build on the minimum device, which is not in this environment (§8.24, §16).

DoD15 ("all surfaces use the same runtime") is *not* on this list because the plan itself places its closing
with PR-17: moving the remaining surfaces is that PR's work, not a separate track.

### 7.1 The twelve duplicate-demand pairs, dispositioned

Numbered as in the acquisition map handed to PR-14 (`'/Users/wagnermontes/.omp/agent/sessions/-Documents-GitHub-feedmine/2026-09-18T03-29-57-957Z_01a0b290-52c5-771b-b2ca-776aaa6935b3/local/recon-acquisition.md'` §3). "Closed" means
the demand now goes through `SourceDemandLedger`, so a URL another surface is refilling is `shared`
(counted in `SourceDemandLedger.counters.sharedRefills`) and a URL refilled inside the surface's
declared window is `servedFresh` (counted in `.freshSkips`).

| Pair | Disposition |
|---|---|
| P1 onboarding showcase vs startup bootstrap | closed: both claim `.onboardingShowcase` / `.bootstrap`; the showcase passes the matrix window, so the same starter endpoints are shared |
| P2 What's New booster vs progressive fetch | closed: the booster claims `.whatsNewBooster` over the enabled set and fetches only `grant.led`; `WhatsNewManager` shuffles the granted subset |
| P3 search sweep vs slow drip vs progressive | closed: three purposes (`.searchSweep`, `.backgroundDrip`, `.progressiveFetch`) on one ledger |
| P4 random 5-source drip vs everything else | closed: the drip claims `.backgroundDrip`, so a random sample that lands on an endpoint another producer holds performs no request |
| P5 two `refreshIfStale` triggers | closed: `FeedLoader.refreshIfStale()` is single-flight (`staleRefreshRunCount` counts runs, not calls) |
| P6 source view re-fetching what Main holds | closed: `.sourceDetail` with the matrix's 300 s window — a recent refill is served locally, no request |
| P7 collection view re-fetching all members | closed: `.collectionDetail`, same window, only `grant.led` fetched |
| P8 search endpoints not excluded from the feed's fetches | closed by the same ledger: the sweep and the backdrop draw from one pool and one in-flight map |
| P9 BGTask tree vs foreground tree | **closed by PR-15**: the handler no longer builds `loader ?? FeedLoader()`. It is given the process's one owner, and with none it completes as unsuccessful and logs why rather than building a second `FeedStore`/`RSSFetcher`/OPML tree. The demand claims its endpoints on the same ledger, so a URL the foreground holds is `shared` and issues no request: `SourceDemandLedger.Counters.sharedRefills`, the transport's request log and `RSSFetcher.fetchAttemptCount()` are the observables (`BackgroundRefreshDemandTests.testBackgroundDemandIssuesNoRequestForEndpointsAnotherProducerHolds`) |
| P10 duplicate bookmark hydration | closed: the second `refreshBookmarkState()` in `FeedScreen.startScreen` is gone; `FeedLoader.start()` already awaited one |
| P11 taxonomy rebuild from ten call sites | closed: `TaxonomyStore.build` coalesces concurrent builds of the same inputs (`buildRunCount` counts builds performed); differing inputs still start a new build |
| P12 smart-feed BG re-enqueue from three places | closed: `SmartFeedBackgroundScheduler.schedule()` keeps at most one pending `BGAppRefreshTaskRequest` — `pendingScheduleCount` counts submissions that reached `BGTaskScheduler`, and the flag is cleared by the handler or a failed submit. Note the consequence: because `BGTaskScheduler` exposes no readable pending state, the app's own flag is the record, so further `schedule()` calls in the same process are no-ops until the handler runs. The three call sites are unchanged |

