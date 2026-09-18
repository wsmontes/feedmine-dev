# Runtime V2 — the empty surface on the surface the session owns

Deliverable of the residual named in [`loading-progress-report.md`](loading-progress-report.md) §6 item 7 and
§3 of [`baseline.md`](baseline.md) §8.32 (gap 3, "the loading progress and empty-surface wording, which still
read the legacy store's counters"), and of the plan's §17 DoD item "UI de feed recebe exclusivamente
snapshots/intents da boundary de sessão". It is the second half of that residual: §8.37 did the loading
chrome, this does the empty surface. Measured on this tree; nothing was deleted, and
`legacy`/`mirroredShadow`/`v2Presentation` — and the empty surface on every selection the session's plan was
not built for — keep the source of truth they had.

**State: on the surface the runtime owns, the empty surface is built from the runtime's own statement, and
the legacy loader's properties are not read there at all. Every legacy path renders what it rendered before
the slice, from the same properties, computed in one place.**

## 1. What the empty surface read, and what reads it now

`FeedEmptyStateView` is the screen's no-feed surface on both lanes: `sessionFeedContent`'s `.empty` case and
`legacyFeedContent`'s `.ready`/`.empty`/`.failed` cases. Before this slice it read the legacy loader directly,
in six properties, and the *mode* it was given decided which of them mattered:

| Legacy property | Before, inside `FeedEmptyStateView` | After, on the surface the session owns | After, everywhere else |
|---|---|---|---|
| `loader.loadingState` | the refresh spinner; the `.generic` `.initial`/`.refreshing` icon and title branches; whether the action buttons are drawn at all (`.initial`/`.refreshing` hide them) | not read | verbatim |
| `loader.sourceCount` | the `.generic` "Fetching articles from \(sourceCount) sources." description | not read | verbatim |
| `loader.fetchErrorCount` | the `.generic` "Couldn't load feeds" title, the "All N sources failed to load…" description and the `wifi.slash` icon (with `totalFetched == 0`) | not read | verbatim |
| `loader.totalFetched` | the same two `.generic` branches' second condition | not read | verbatim |
| `loader.sources` | the `.generic` "No sources found" title, the "Add .opml files…" description and the `folder.badge.questionmark` icon | not read | verbatim |
| `loader.disabledSourceIDs` | the "Tip: N sources are disabled" line under "Refresh Now" | not read | verbatim |

Plus one legacy read that is not a property: the legacy `mode` itself (`FeedScreen.emptyMode`, `:75-105`),
which reads `activePreset`, `selectedNodeNames`, `sources`, `isGlobalFeedsEnabled`, `isAnyCountryEnabled`,
`hasActiveFilters`, `items`, `loadingState`, `isUrgentFetching`, `isPreparingFilteredComposition` and
`emptyStateFetchedCount`. That is `legacyFeedContent`'s own input and is unchanged: the session's variant
comes from `MainFeedSessionSurface.empty`, not from it.

Why the read was wrong on the session's surface: in the acquiring mode `LegacyAcquisitionGate` refuses the
legacy engine's requests (`RSSFetcher.performFetch:131`, `baseline.md` §8.26), so `fetchErrorCount` and
`totalFetched` describe an acquisition this launch never performs, and the page the store holds for this
selection is the cached one. `「All N sources failed to load」` with a legacy N is the shape of the wrongness;
a `v2Full` launch whose session published an empty edition would have shown the legacy page's loading or
error wording for it.

The six properties are now read in exactly one place: `FeedEmptyDisplay.forSurface(session:mode:loader:)`
(`FeedEmptyStateView.swift`), and only in its `.legacy` branch. `FeedScreen.swift:192-201` passes
`runtime.sessionEmptyStatement`; the four legacy call sites (`:224`, `:228`, `:232`) pass no statement, and an
absent statement is what selects the `.legacy` lane. The layout above it (icon, title, description, the
progress line, the buttons) is untouched; what changed is what fills each of them.

## 2. The runtime's own statement

`FeedEmptyStatement` (`MainFeedRuntime.swift:148-186`) is the statement, and it is a value of the runtime's
facts with no `FeedLoader` in signature or scope:

| Case | Facts |
|---|---|
| `mode` | the variant the session states: `MainFeedSessionSurface.empty` produces `.generic` (a published edition with no cards) and `.noSourcesEnabled` (this launch had no catalogue). It never produces the legacy page's `.fetching`/`.noResults`, which are its filters' answers |
| `acquisition` | `MainFeedLoadingStatement` — the loading surface's own value — so the two surfaces cannot describe one launch's acquisition differently |

`FeedEmptyStatement.forSession(surface:state:report:)` mirrors `MainFeedSessionSurface.forSession`: no
`FeedLoader` parameter, so the answer cannot be the legacy page's loading state or its source count.
`MainFeedRuntime.sessionEmptyStatement` (`:255-262`) is non-nil exactly when `sessionSurface` is
`.empty(…)` — the same value the loading statement is guarded by — and nil in every other mode and on every
other selection.

`FeedEmptyDisplay` is the lane as a value, the structure §8.37 established for the loading chrome:

```swift
enum FeedEmptyDisplay: Equatable {
    case session(FeedEmptyStatement)          // no legacy counter is in it
    case legacy(FeedEmptyLegacyFacts)         // the six properties, as values
}
```

`FeedEmptyLegacyFacts` carries the mode plus the six properties materialized by `forSurface`; every
string in the layout is computed from the value, and the session's case cannot reach a legacy property at
all — the layout would have to switch on `.legacy` to see one.

## 3. What the surface says, and why each line is honest

| Session state | Title | Description | Where the legacy page prints "Fetched N of M sources…" | Icon | Refresh spinner | "Refresh Now" / tip |
|---|---|---|---|---|---|---|
| `.empty(.noSourcesEnabled)` | "No sources enabled" | "Enable some countries or topics in Filters to start seeing content." | nothing | `globe.americas.fill` | none | "Open Filters" |
| `.empty(.generic)` | "No articles yet" | the circadian message (the legacy fallback) | the runtime's acquisition line | `newspaper.fill` | none | "Refresh Now", no tip |
| legacy page | the five legacy `.generic` branches, in the same order | the four legacy `.generic` branches, in the same order | "`fetched` of `total` sources…" | the five legacy icons | on `loadingState == .refreshing` | the legacy gating and the legacy tip |

* **The variant is the session's, and it is the same wording the legacy lane used where no figure was
  involved.** `.noSourcesEnabled`'s title and description read no loader on either lane, so the session's
  copy is byte-identical to the legacy one. `.generic` on the session's lane is a published edition with no
  cards, and "No articles yet" is the one branch of the legacy `.generic` wording that states no legacy
  figure — the circadian message below it reads `CircadianEngine`, not the loader.
* **Where the legacy wording owed a count, the runtime's own acquisition line takes the slot.** The legacy
  `.generic` description said "Fetching articles from N sources." while its page was loading; N was
  `loader.sourceCount`, the legacy store's catalogue, which the runtime cannot state. The session's lane
  states its own acquisition instead — `32 of 71,234 sources watched`, `· N refused` — which is
  `MainFeedLoadingStatement`'s wording through `FeedLoadingDisplay.session(_:).detail`, the single source of
  that sentence, so the empty and loading surfaces of one launch cannot state it differently. The line is
  drawn where the legacy `.fetching` variant draws its own count, **not** in the description: the count is
  the same kind of fact, and the description keeps the sentence that needs no figure.
* **"Filtering articles…", "Couldn't load feeds" and "All N sources failed to load…" are dropped on the
  session's lane, and that is a decision, not an omission.** Each was a statement about *the legacy page*:
  its filter composition in flight, and its fetch errors against a target this launch never advances. The
  runtime states no filter composition and no fetch failures, so the lane says what it can — the session
  published an edition with no cards — rather than borrowing a figure from the engine the gate refuses.
* **The refresh spinner is not drawn on the session's lane.** The legacy surface showed it while
  `loadingState == .refreshing`. "A refresh is in flight" is not readable in the app layer today:
  `MainFeedRuntime.refreshTask` is a task handle that is never cleared. §8.37 named the same gap for
  "Refresh in flight" and stated it as absent rather than guessed; this lane does the same and draws nothing.
* **`showActions` is always true on the session's lane.** The legacy surface hid its buttons while its own
  work was in flight (`loadingState == .initial`/`.refreshing`). The session's lane is a settling statement —
  a published edition, or nothing to acquire from — and it states no work in flight to hide them for.
* **The disabled-source tip is not drawn on the session's lane.** It read `loader.disabledSourceIDs.count`.
  The runtime's plan is built from the loader's selectors but carries no toggled-off count, so the lane
  states nothing. Named here rather than invented.
* **No number is invented anywhere on the session's lane.** The two figures it can state are the catalogue it
  was offered and how many sources the acquisition owner took on, both already in
  `MainFeedLoadingStatement`; the loading slice's own cross-check applies unchanged — the measured launch
  watched 32 of 71,234 and its episode line says `targets=32`.

## 4. Proof

`MainFeedRuntimeV2Tests`, the two this slice adds:

* `testTheSessionEmptySurfaceStatesTheRuntimesOwnAcquisitionAndNotTheLegacyPage` — on a `v2Full` launch whose
  session published an empty edition, with a **non-trivial legacy page** (two sources with one toggled off,
  `loadingState == .initial`, through the store's own `registry`/`display`), the screen is handed
  `FeedEmptyStatement(mode: .generic, acquisition: .readingCatalogue)`; `FeedEmptyDisplay.forSurface` is
  `.session(statement)` with `source == "session"`, title "No articles yet", icon `newspaper.fill`,
  `isRefreshing == false`, no tip, and the acquisition line "Waiting for the source catalogue". The same
  loader on the lane that still owns it is `.legacy(…)` — the **whole value pinned**, every legacy property
  accounted for — with title "Loading your feed...", description "Fetching articles from 2 sources.",
  `antenna.radiowaves.left.and.right`, no actions and "Tip: 1 source is disabled". A started session's
  statement (`.acquiring(catalogueSources: 118, watched: 32/1 refused)`) states a line carrying 32 and 118 and
  not the legacy count sentence; the `.noSourcesEnabled` variant states title/description/icon/`Open Filters`
  and no line and no tip.
* `testEveryModeAndEverySelectionThatOwnsNoSessionKeepsTheLegacyEmptySurface` — `legacy`, `mirroredShadow`
  and `v2Presentation` all resolve to their own decision, own no acquisition, state
  `sessionEmptyStatement == nil`, and render the legacy lane verbatim (the pinned facts, the loading title,
  "Fetching articles from 2 sources.", the disabled tip, no actions); in `v2Full` on `.lastClicked` it is nil
  again with the empty store's page ("No sources found"), and back on the session's selection the statement
  is the session's again.

Legacy paths unchanged: `legacyFeedContent` still constructs `FeedEmptyStateView(mode: emptyMode)` (and
`mode: .generic` for `.failed`) with no statement, so its variant, its icon, its title, its description, its
progress line, its buttons and its tip are the expressions they were — now evaluated inside
`FeedEmptyDisplay`'s `.legacy` branch, from the same six properties, read at the same moment (the view's own
`display` computed property). The session's case carries no legacy counter, so the lane is a value and not a
conditional read.

## 5. What remains legacy on that surface, named

1. **The legacy lane's mode is still the legacy page's.** `FeedScreen.emptyMode` (`:75-105`) reads eleven
   loader properties and `TaxonomyStore.shared` to choose between `.noSourcesEnabled`, `.fetching`,
   `.noResults` and `.generic`. That is correct for `legacyFeedContent` — it *is* that page's variant — and
   it is why the session's lane does not use it. A selection the session's plan was not built for keeps it.
2. **The disabled-source tip is dropped on the session's lane** (§3), because the runtime states no
   toggled-off count. Closing it needs a runtime fact, not a wording change.
3. **The refresh spinner is dropped on the session's lane** (§3): "refresh in flight" is still not readable
   in the app layer (§8.37 §3, same gap).
4. **The `.fetching`/`.noResults` variants are unreachable on the session's lane** and are kept in
   `FeedEmptyMode` because the legacy lane uses them. If a later slice gives the session a filtered
   composition of its own, the variant belongs to `MainFeedSessionSurface`, not to `FeedEmptyMode`.
5. **`FeedEmptyMode.fetching(topic:fetched:total:)` still carries legacy counters in its case** — it is the
   legacy lane's shape. The session never produces it, and `FeedEmptyDisplay`'s session branch never reads
   its figures.
6. **The surface's own log line gained a lane marker on both lanes.** `surface[empty-state] appear` now reads
   `source=session|legacy title=…` (`FeedEmptyStateView.swift`), the way §8.37 did for
   `surface[initial-loading]`. It is diagnostics, not rendering: the legacy lane's view output is unchanged,
   and this is the only difference a legacy path sees. The two `Text` producers that moved from
   `LocalizedStringKey` literals to `String(localized:)` (the `Fetched N of M sources…` progress line and the
   disabled-source tip) both resolve to keys the catalog does not carry, so both render the source text with
   the same substitutions as before — pinned by the legacy-lane assertions in the test above.
7. **The view's refresh fallback is still the legacy action.** `onRefresh` nil means `loader.refresh()`
   (`FeedEmptyStateView.swift`), which is what a legacy page's button has always done. It is not reachable
   on the session's lane — its only call site passes `{ await runtime.refresh() }` — and it is an action
   rather than a counter: no property of the legacy loader is read on the session's lane. Named so the claim
   is not overstated.

## 6. Gates

Runs were taken one at a time.

`swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm`:

```
	 Executed 495 tests, with 0 failures (0 unexpected) in 8.242 (8.269) seconds
```

`bash scripts/validation/run_runtime_v2_tests.sh`:

```
destination (discovered): id=2F70B5E4-DF56-428C-A7B9-0A769B6CAC3D
=== 1/2 package core on the macOS host (swift test) ===
   exit=0 executed=495 failures=0
   PASS: 495 package tests, 0 failures

=== 2/2 app suite through TestPlans/FeedMine-RuntimeV2.xctestplan ===
   purged 4 local package module(s) that a changed source would have kept stale
   exit=0 passed=601 failed=0
   PASS: 601 app tests, 0 failures

Runtime V2 test gate: PASS
```

601 = the 599 the read-state slice left plus this slice's two (`MainFeedRuntimeV2Tests`), and the app half is
the one that compiled and ran this slice's source changes. The package count is unchanged at 495 because no
package source is touched by this slice (`FeedEmptyStatement` is app-side, in
`feedmine/RuntimeV2/MainFeedRuntime.swift`; `FeedEmptyDisplay` is in `feedmine/Views/FeedEmptyStateView.swift`).
The `purged 4` line is the gate's stale-module purge doing its job after the test target changed; the run
before this one, on the same sources except the `mirroredShadow` case in the legacy-lane test, printed
`purged 0` and `passed=601` too.
