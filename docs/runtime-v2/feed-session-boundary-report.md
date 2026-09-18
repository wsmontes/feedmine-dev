# Runtime V2 — the feed screen's source of truth, per surface

Deliverable of the plan's §17 DoD item **"UI de feed recebe exclusivamente snapshots/intents da boundary
de sessão"** ([`2026-09-17-feedmine-runtime-v2-revised.md`](../superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md) §17),
measured on this tree. It is not PR-17's removal item: nothing was deleted, and `legacy`/`mirroredShadow`
keep the source of truth they had.

**State: the item's item is met for the surface the runtime owns, and the split is per surface rather
than per mode.** In `v2Full` the Main Feed's selection (§2, below) draws the session's snapshots and
nothing else — its phase, its emptiness and its empty surface are the session's own statements. Every
other selection — a bookmark box, a Smart Feed, the last-clicked history, a collection, a curated preset
— draws *its own* legacy page, which is what it drew before and what it still has, because the gate
closes fetches and not local reads. In `legacy`, `mirroredShadow` and `v2Presentation` nothing changed.

## 1. What the screen read, and what it reads now

The three sites the orchestrator measured, and the decision around them:

| Site (before) | Before | After (`v2Full`, the session's selection) | After (every other selection, and every other mode) |
|---|---|---|---|
| `FeedScreen.swift:116-122` — the content branch | `switch loader.feedDisplayPhase` chose the surface, with `loader.items` deciding "empty or not" in three of its cases | `runtime.sessionSurface` (`MainFeedRuntime.sessionSurface` → `MainFeedSessionSurface.forSession`): `.preparing` / `.content` / `.empty(FeedEmptyMode)` from the session's own publication | the same `switch`, moved verbatim into `legacyFeedContent` (`FeedScreen.swift:202-221`) |
| `FeedScreen.swift:181-200` — the empty state | `FeedEmptyStateView(mode: emptyMode)`, where `emptyMode` reads the loader's filters, preset, taxonomy and fetch counters | `FeedEmptyStateView(mode: mode)`, the variant the runtime states; the empty surface's refresh is the runtime's (`onRefresh: { await runtime.refresh() }`) | unchanged, including `emptyMode` (`FeedScreen.swift:70-105`) and its legacy refresh |
| `FeedScreen.swift:955` (was `:911`) — the second source inside the scroll view | `if runtime.presentation.sections.isEmpty && !loader.items.isEmpty` — the legacy page could put `EmptyFilterView` on a surface the session owned | the same condition, parameterized: `legacyPageFallback && presentation.sections.isEmpty`, and the session's branch passes `legacyPageFallback: false` | unchanged: the legacy branch passes `!loader.items.isEmpty` |
| `FeedScreen.swift:114` — the "first useful content" metric | `loader.items.count` (in `v2Full`: the cached legacy page) | `runtime.presentation.ordinalCount`, the cards the reader's page actually has | `loader.items.count`, unchanged |
| `FeedScreen.swift:147-158` — shake to refresh; `FeedEmptyStateView.swift:98-107` — "Refresh Now" | `loader.shakeToRefresh()` / `loader.refresh()` — in `v2Full` both are refused by `LegacyAcquisitionGate`, i.e. dead controls | `runtime.refresh()` (the session's own refresh) | `loader.shakeToRefresh()` / `loader.refresh()`, unchanged |

Every other read of `loader` in `FeedScreen.swift` is classified below. The inventory was taken over the
whole file (`grep -n "loader\."`), not only the three measured sites.

The same decision, per mode:

| Mode | Content (the rows) | Phase and emptiness | Empty surface |
|---|---|---|---|
| `legacy`, `mirroredShadow` | `runtime.presentation.sections`, mapped from the legacy page (`publish`) | `loader.feedDisplayPhase` + `loader.items` | `emptyMode` from the loader's filters and counters |
| `v2Presentation` (store in the path) | same as above, and the page is also applied to the store | same | same |
| `v2Full`, the session's selection | the session's snapshots only (`applySnapshot` → `materialize`) | `runtime.sessionSurface` (session state + `snapshot.cards`) | `MainFeedSessionSurface.empty(...)` |
| `v2Full`, any other selection | that selection's own legacy page (`followLegacyPage` → `publish`) | `loader.feedDisplayPhase` + `loader.items` for that page | `emptyMode` |

**Needed by a surface the runtime does not own, or by a mode in which the legacy page *is* the page —
unchanged, and deliberately so.** The selectors and everything derived from them: `activePreset`
(`:76-77`, `:364-372`, `:461`, `:533-575`, `:1086`, `:1187-1213`), `selectedBookmarkListID`
(`:509-513`, `:924-928`), `selectedRegion`/`selectedContentType`/`selectedMood`/`selectedNodeIDs`/
`selectedLanguages` (`:458-467`, the filter lens), `activeFilterCount` (`:434`, `:883`), `sources`
(`:79`), `hasActiveFilters`/`items`/`loadingState`/`emptyStateFetchedCount`/`isPreparingFilteredComposition`/
`isUrgentFetching` (`:82-101`, `emptyMode`), `filteredItems`/`activeSources` (`:1105-1110`, the
"collect these sources" and Smart Feed creation actions), the source-management and collection sheets
(`:1136-1242`), the header chrome (`CompactFeedStatus` `:1586-1650`, `CompactErrorBanner` `:1655-1665`,
`CompactDebugInfo` `:1519-1537`), the lifecycle and demand calls (`:243`, `:316-322`, `:1407-1441`), and
the search panel (`unifiedSearchPanel`, `:765-830`) — the one surface whose content half already moved
and which this slice did not touch: it is the first branch (`:116`) and in `v2Full` it still reads the
canonical index through `CanonicalContentSearch`, installed by `MainFeedRuntime.startSession`
(`MainFeedRuntime.swift:305-312`) and removed by `stop()`.

**Note on line numbers.** Every `FeedScreen.swift:N` citation above is as of the tree this slice was
measured on. Two slices have edited that file since (the exposure signal, then the loading lane), and a
third edit is this slice's own; re-measured now, the anchors are `surfaceContentCount` at `:113`,
`sessionFeedContent` at `:181`, `legacyFeedContent` at `:205`, the `legacyPageFallback` condition at
`:1000`, `noteViewport` at `:1327`, `updateBadge` at `:1406` and `InitialFeedLoadingView` at `:2000`
(the exposure site is `runtime.cardBecameVisible(itemID:)`). `MainFeedRuntime.swift` moved as well:
`MainFeedLoadingStatement` at `:99-146` is the loading slice's, `sessionLoadingStatement` at `:207` and
`sessionSurface` at `:222` are this slice's. Read the citations by the symbol they name, not by the
number: the same discipline `rollout.md` §2.2 records, and the reason the sites above are quoted with
their code.

The bookmark-box header inside `feedScrollView` (`:924-928`) is a legacy read that cannot fire on the
session's selection: a box selection *is* a different context key, so the session does not own it.

## 2. The split is per surface, not per mode alone

A launch's session owns **one selection**, not the screen. The context key is the preset and the
bookmark box (`SurfaceContextAdapters.mainFeedInputs`, `SurfaceContextAdapters.swift:126-142`) and the
session's plan is the `.main` plan for the key it was attached with; a reader who taps a bookmark box, a
Smart Feed or a collection moves to a key the session's plan was not built for.

Making the screen read "the session" purely by mode would have made a wrongness structural: with the
rows always coming from `runtime.presentation.sections`, those selections used to show the Main Feed's
rows under their own header. The rule now is that a page states its own context key and the screen draws
the page for the selection it is on:

* `MainFeedPresentation.beginSession(contextKey:)` — the runtime claims the selection the session's plan
  was built for, *before* the legacy page is followed (`MainFeedRuntime.attach`,
  `MainFeedRuntime.swift:295`). Claiming it first is what keeps the cached legacy page from being
  drawn for a surface the session is about to own.
* `MainFeedPresentation.followLegacyPage(_:)` — every legacy publication states its key
  (`selectionContextKey`); the page for the session's key is declined and the session's own last
  snapshot is drawn again instead (`restoreSessionPage`), and every other key's page is materialized as
  it always was.
* `MainFeedPresentation.applySnapshot(_:)` — a snapshot is materialized only while the screen is on the
  session's selection; otherwise it is retained, so a snapshot arriving while the reader is on a bookmark
  box does not replace that page, and coming back draws it again.
* `MainFeedPresentation.pageSource` (`none` / `legacyPage` / `sessionSnapshot`) is the fact the screen's
  branch reads; `MainFeedRuntime.sessionSurface` is the session's surface for that selection — from the
  first frame on, since a launch whose runtime owns acquisition is about to claim the selection
  `attach` will claim, and it is the legacy page's `nil` for every other selection and every other mode.

Two consequences that are stated rather than hidden:

* in the acquiring mode the legacy page is **not** applied to the `FeedScreenStore` while a session
  exists (`MainFeedPresentation.publish`): the store carries one session's stream, the legacy page does
  not share its sequence space, and a page consumed there could refuse the session's next snapshot as
  older than the applied one;
* `restoreSessionPage` draws only on a real transition (`pageSource != .sessionSnapshot`), and
  `MainFeedRuntime.viewportChanged` ignores an observation whose page is another selection's. Both exist
  for the same reason: the legacy page keeps mutating in this mode, and an unconditional rebuild of
  `sections` re-renders the screen, which re-fires the scroll surface's visibility observation, which
  drives the next composition — the successor-edition loop (`baseline.md` §8.25.1).

## 3. What the snapshot had to gain: nothing. What is recorded as a gap

No field was added to `FeedPresentationSnapshot`. The three questions the screen asks are answerable from
what it already carries (`cards` and the session's own state), and the rest is named here:

| What the session-owned surface still needs | Where it comes from | Disposition |
|---|---|---|
| Which phase the feed is in | `presentation.snapshot == nil` → `.preparing`; cards present → `.content`; a published edition with no cards → `.empty` | in the snapshot already (`cards`) |
| Whether the launch has nothing to acquire from | `MainFeedSessionState.noCatalogue` (set by `startSession` when `Loader.enabledSources` is empty) → `.empty(.noSourcesEnabled)` | the runtime's own statement, typed instead of the log string it used to be |
| Exposure (the session's own fact) | `loader.markAsSeen(row.item.id)` on the per-card `onScrollVisibilityChange` (`FeedScreen.swift:966` then; `runtime.cardBecameVisible(itemID:)` now) | **gap at the time of this slice, closed by the following one** (`exposure-intent-report.md`). Read state's authority is `feed_item.consumed_at` in `feedmine.sqlite` (`FeedStore.markAsSeen:3938-3948`, read by `UserStateStore.cachedItems:884-886`) — *not* `user.sqlite`, which is the bookmark authority; the wording this row first carried was wrong and is corrected here. The measured shape of the defect: the display id (`card:<PublicationCardID>`) matched **zero** rows, so the durable write was a silent no-op and only the in-memory `consumedItemIDs` recorded a display id. The exposure slice routes the signal through the runtime and guards it on `presentation.pageSource == .sessionSnapshot`, not on the row's card lookup — `cardByItemID` is populated for legacy pages too, so the lookup alone would have routed legacy rows to the session. The durable read state stays a named policy decision (its §6). |
| Position | `loader.noteViewport(lastVisibleOrdinal:)` (`:1306`), the cold-start restore (`:1079`, `!loader.items.isEmpty` + `@AppStorage("lastScrollItemID")`) | **gap.** On the session's surface those ordinals are the session's; the persisted id is a display id a rebuild does not preserve. The session builds an anchor and travels it, nothing persists it (`rollout.md` §2.1: the checkpoint is the session's). |
| The acquisition progress the loading surface shows | `InitialFeedLoadingView` reads the legacy runway (`startupFetchedSourceCount`/`startupTargetSourceCount`/`startupRunwayReady`/`startupRecentSourceNames`/`hasPreviouslyLoadedContent`) | **gap at the time of this slice, closed by the slice that followed** (`loading-progress-report.md`): `MainFeedLoadingStatement` is built from the session state plus `V2AcquisitionReport.watched/refused`, `FeedLoadingDisplay.forSurface(session:loader:)` is the only place the runway counters are read (its `.runway` branch), and the session's lane states no fraction. This slice closed the last two pieces of it: the first frame no longer paints the legacy lane (below), and what is left of it is named by that report — the header chip `CompactFeedStatus` still counts the runway (residual 1, a different element), the empty surface's wording is untouched (residual 3 in mine), and `lastSummary` is declared and never assigned. |
| The empty surface's words | `FeedEmptyStateView`'s `.generic` branch reads `loadingState`/`sourceCount`/`fetchErrorCount`/`totalFetched`/`sources`/`disabledSourceIDs` (`FeedEmptyStateView.swift:157-226`) | **gap**: the *variant* is the boundary's (`.empty(.noSourcesEnabled)` or `.empty(.generic)`), the generic variant's *wording* is still the legacy store's, because the snapshot carries no acquisition counters and the runtime exposes no composition-in-flight signal to the app layer. Measured shape in `v2Full`: the legacy store settles at `.idle` with no fetch errors (its requests are refused and not counted as attempts), so the generic variant renders "No articles yet" / the circadian line — which is the right surface, from the wrong source. |
| The source a row belongs to | `loader.sourceReference(for: row.item)` (`:958-959`, "View Source" / "Add Source to Collection") | **gap**: a runtime row's item is synthesized with `sourceURL: ""`, and the card carries `sourceTitle` but no source identity; ADR-003 D2/D18 forbid deriving one. |
| The unread count | `updateBadge()` (`:1386`), `CompactDebugInfo.unread` (`:1519`) — `loader.items.count - loader.readItemIDs.count` | **gap**: in the acquiring mode that counts the cached legacy page. The snapshot's cards are a window, not a total unread, so switching the number would be a different lie. |
| Filters and taxonomy re-planning the session | `FilterSheetView`/`TaxonomyChipBar` write the legacy selectors | **gap** (pre-existing): the context key is the preset and the box, the plan is resolved at attach, and `MainFeedRuntime.handle(.switchContext:)` only logs — so in the acquiring mode a filter change reaches the legacy store's own pages (and every other selection), not the session's. The brief keeps filters legacy in this mode by design; re-planning is the context-switch slice's work. |

## 4. What the legacy store is still doing in the acquiring mode

It is not the screen's source of truth for the session's selection, and it is still doing all of this:

* **hydration** — `BookmarkStore` over `user.sqlite` joins `bookmark_item.item_id` to
  `feedmine.sqlite.feed_item`; that join is the only hydration build 17 has (ADR-004 D6/D12,
  `owner-swap-report.md`);
* **filters and taxonomy** — `FilterSheetView`, `TaxonomyChipBar`, `TaxonomyStore`, `ContentFilterStore`
  are the only owners; the runtime's plan *reads* them at attach and never writes them;
* **its own pages** — the cached page for the session's selection (declined by the presentation, kept for
  the store's own use) and, as §2 shows, the live pages of every other selection;
* **durable user state** — `RuntimeCardUserActions` writes a runtime card's bookmark through the legacy
  `BookmarkStore`/`user.sqlite` and projects the legacy content row, which is what makes it survive a
  rollback (`durable-user-actions-report.md`);
* **the acquisition gate** — `RSSFetcher.performFetch:131` refuses every legacy fetch in this mode, which
  is why the local reads above are the whole of what remains reachable;
* **the canonical search install** — `MainFeedRuntime.startSession` hands `CanonicalContentSearch` to
  `FeedLoader`, so the local content search reads the index Admission fills (PR-14 clause two).

Proven reachable in this mode, as the audit asked: `FeedLoader.selectedBookmarkListID`'s setter
(`FeedLoader.swift:578-597`) → `FeedStore.bookmarkedItems(listID:)` (a local `user.sqlite` read) →
`FeedStore.loadBookmarkFeed(items:)` (`FeedStore.swift:231-241`) → `display.setVisibleItems` →
`FeedLoader.items`/`dateSections`; and `FeedLoader.setActivePreset` (`FeedLoader.swift:1040`) →
`FeedStore.setPreset` (`FeedStore.swift:4180`) → `loadLastClickedFeed` (`FeedStore.swift:4359`, a
`db.read`) / `loadSmartFeedFeed` / `loadCollectionPresetFeed`. None of them passes
`RSSFetcher.performFetch:131`, the one gate. `MainFeedRuntimeV2Tests.testThePageFollowsTheSelectionRatherThanTheMode`
asserts the observable consequence: after a selection change the page source is the legacy page, that
selection's own content is what the page draws, and the session's card is not in it.

## 5. Proof

* `MainFeedRuntimeV2Tests.testAV2FullLaunchDrawsTheSessionSurfaceForTheSelectionItsPlanWasBuiltFor` —
  a real `v2Full` launch (launch arguments, a runtime database in a temporary directory) whose loader
  page is made non-empty (`FeedStore.loadBookmarkFeed`, which caches nothing: `shouldCache` is false for
  a non-`.main` mode, `FeedStore.swift:2526`). With the legacy page present the state the screen consumes
  is `.preparing`, then `.empty(.generic)`, then `.content` — and the drawn rows are the snapshot's
  `card:` rows, never the legacy page's item. This is the observable that the `:911` fallback is not
  taken: the condition could be true there and the surface state does not consult it.
* The first frame is the session's lane, not the legacy one: `testAV2FullLaunchDrawsTheSessionSurfaceForTheSelectionItsPlanWasBuiltFor`
  asserts `sessionSurface == .preparing` **before** `attach` in a `v2Full` launch. Verified to fail
  pre-fix (verbatim: `XCTAssertEqual failed: ("nil") is not equal to ("Optional(feedmine.MainFeedSessionSurface.preparing)") - the first frame is the session's, not the legacy lane`)
  and to pass after it; a `v2Full` launch painted the legacy startup runway for 7.3 ms of every launch
  before the fix (`loading-progress-report.md` §4).
* `MainFeedRuntimeV2Tests.testThePageFollowsTheSelectionRatherThanTheMode` — the per-surface split.
* `MainFeedRuntimeV2Tests.testEveryModeThatOwnsNoAcquisitionKeepsTheLegacyPage` — `legacy` and
  `v2Presentation` (a `FeedScreenStore` in the path) both keep `pageSource == .legacyPage`, no session
  key and `session=none`.
* `MainFeedRuntimeV2Tests.testTheSessionSurfaceStatesOnlyTheSessionsOwnPublication` — the mapping table,
  over the whole `snapshot × session state` product. The function it tests takes no `FeedLoader`: this is
  the structural half of "cannot read the legacy page".
* Legacy paths unchanged, by construction and by suite: the `legacyFeedContent` switch is the code that
  was there, and `legacy`/`mirroredShadow`/`v2Presentation` still materialize the legacy page into the
  store (`MainFeedPresentation.publish`) and send their intents to the legacy store
  (`FeedEmptyStateView`'s default refresh, `ShakeDetector`'s `loader.shakeToRefresh`,
  `surfaceContentCount`'s `loader.items.count`).
  `RuntimeV2ShadowTests` (shadow), `SurfacePlanMigrationTests` and `RuntimeV2UserStateBridgeTests` are
  the suites that pin those modes and the canonical-search swap; all stayed green.

Observable in production: `MainFeedPresentation` logs `runtime-v2 page-source=<none|legacy-page|session-snapshot> selection=<context key>`
whenever the source changes — the mode line is logged at launch, before anything is attached, so this is
the line that says which page the screen ended up drawing from.

### 5.1 The `v2Full` launch, observed (iPhone 16 simulator, this tree)

The app built by the plan gate was installed and launched with
`xcrun simctl launch <udid> com.feedmine.app -RuntimeV2UI -RuntimeV2Network -UITestSkipOnboarding`, and
the screen captured 75 s in. The app's own log (`subsystem == "com.feedmine.app"`), verbatim:

```
runtime-v2 mode=v2Full request(shadow=false v2UI=true v2Network=true) source=launchArguments presentation=v2-snapshots composed=full(directory=RuntimeV2) center-crossings=0 visibility-samples=0 rejected-snapshots=0 legacy-gate=closed legacy-requests-refused=0
runtime-v2 page-source=session-snapshot selection=main|preset=everything|box=-|MainFeedPlan
surface[initial-loading] appear label=Preparing your feed...
runtime-v2 v2Full snapshot edition=edition:1 cards=9 sequence=1 context=main|preset=everything|box=-|MainFeedPlan
surface[initial-loading] disappear
runtime-v2 v2Full snapshot edition=edition:2 cards=9 sequence=2 context=…
runtime-v2 v2Full snapshot edition=edition:2 cards=9 sequence=3 context=…
```

What it shows, and why each part matters:

* `page-source=session-snapshot` — the surface claims the session at attach time, ~180 ms into the
  launch, and **no `page-source=legacy-page` line appears in the whole launch**: the legacy page never
  became the page, not even for the interval before the catalogue arrives. That is the item's own claim,
  observable rather than argued.
* `surface[initial-loading] appear label=Preparing your feed...` — while the session composes, the screen
  shows the session's `.preparing` surface. There is no `surface[empty-state]` line and no
  `EmptyFilterView`: the legacy cached page and the `:911` guidance are not what a `v2Full` reader sees
  before the first snapshot.
* the screenshot shows the session's cards (the two ICC articles with their relative times and empty
  placeholder media — the swap's named gaps) and **not** a legacy page; the header's
  `·71,234/77,43 sources` chip is the legacy startup chrome of gap 3 below, visible as such.
* three snapshots in ~40 s (one cold edition and two successor publications, 9 cards each) — the
  successor loop stays bounded with the legacy observation now armed in this mode, which is the thing
  §2's two guards exist for.

The per-selection half of §2 was not driven on a device: `simctl` has no touch injection (the limit
`baseline.md` §8.28 records), and the unit test above is what proves it.

## 6. Gates

All three measured on the final tree, one app-plan run at a time.

`swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm`:

```
	 Executed 493 tests, with 0 failures (0 unexpected) in 9.839 (9.868) seconds
```

`bash scripts/verify-runtime-v2-boundaries.sh`:

```
boundary gate: 77 source files, 156 imports, root=/Users/wagnermontes/Documents/GitHub/feedmine/Packages/FeedRuntimeV2
PASS: module boundaries match the plan
```

`xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd`:

```
Test Suite 'All tests' passed at 2026-09-18 04:20:32.602.
	 Executed 590 tests, with 0 failures (0 unexpected) in 114.443 (114.608) seconds
** TEST SUCCEEDED **
```

590 = the 586 the source-bridge slice left plus this slice's four
(`MainFeedRuntimeV2Tests`: 21 in the class, 17 of them pre-existing).

**After this slice, measured on the tree it left behind.** The exposure slice (`exposure-intent-report.md`
§5) reports package **494 / 0** and app plan **593 / 0**; the loading-progress slice
(`loading-progress-report.md` §5) reports package **494 / 0** and app plan **595 / 0**. This slice then
re-opened for the first-frame fix those reports handed back to it, and measured the tree itself:

```
	 Executed 494 tests, with 0 failures (0 unexpected) in 9.808 (9.840) seconds
boundary gate: 77 source files, 156 imports, root=/Users/wagnermontes/Documents/GitHub/feedmine/Packages/FeedRuntimeV2
PASS: module boundaries match the plan
Test Suite 'All tests' passed at 2026-09-18 05:05:15.854.
	 Executed 595 tests, with 0 failures (0 unexpected) in 115.867 (116.029) seconds
** TEST SUCCEEDED **
```

The first block in §6 is this slice's own tree, kept as the measurement it was; the second is the tree as
this slice last measured it. Later slices land on top of both — the exposure and loading slices came after
this slice, and the read-state slice is in flight as this is written — so neither block is a standing
state of the tree: the record for the tree as a whole is the orchestrator's final validation, and the
per-slice numbers belong to each slice's own report.

## 7. Gaps left, and who owns them

None of these is covered by a legacy read on the session-owned surface; each is named with its owner.

1. **Exposure and the durable read state** — *closed by the following slice* (`exposure-intent-report.md`):
   the visibility signal crosses the boundary, keyed on `presentation.pageSource == .sessionSnapshot`. Two
   corrections to what this report first said, both measured there: read state's authority is
   `feed_item.consumed_at` in `feedmine.sqlite` (`FeedStore.markAsSeen:3938-3948`), not `user.sqlite`, so
   the per-edition-id misattribution hazard this report named did not arise — the display id matched zero
   rows and the durable write was simply absent; and the guard cannot be the row's card lookup, because
   `cardByItemID` is populated for legacy pages too. What remains is the durable read state itself: a named
   policy decision in that report's §6.
2. **Position and the persisted anchor.** Owner: the session-checkpoint slice (`rollout.md` §2.1).
3. **The loading surface's progress** — *closed by the slice that followed* (`loading-progress-report.md`),
   in two halves: its own (`MainFeedLoadingStatement` + the `FeedLoadingDisplay` lane decision) and this
   boundary's (the first frame now draws the session's lane, below). What it names as still legacy on that
   screen, and what this slice leaves standing: the header chip `CompactFeedStatus` counts the runway while
   the runtime watched 32 and admitted 0; `lastSummary` is declared and never assigned; the `.acquiring`
   copy is a 28–50 ms window behind the catalogue read. **The empty surface's wording** remains the legacy
   store's (my §3 row), untouched by either slice — a different surface from the loading lane.
4. **A runtime row cannot name its source**, so "View Source" / "Add Source to Collection" has nothing to
   resolve. Owner: the card-identity work (a source key on the card).
5. **The unread badge.** Owner: whoever gives the runtime a total-unread statement, if it ever should.
6. **Filters and taxonomy do not re-plan the session.** Owner: the context-switch slice; the mode keeps
   them legacy by the brief's own words, and `MainFeedRuntime.handle(.switchContext:)` is the seam that
   only logs today.
7. **The per-selection switch was not driven on a device**, only in the unit test: `simctl` cannot inject
   a tap, and the bookmark-box / Smart Feed controls carry no accessibility identifier a UI test could
   target (`baseline.md` §8.28). The `page-source=` log line is what an operator driving a device by hand
   should read to confirm it in the field. The launch itself *was* observed (§5.1).
