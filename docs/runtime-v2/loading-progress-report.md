# Runtime V2 — the loading surface's progress on the surface the session owns

Deliverable of the residual named in [`feed-session-boundary-report.md`](feed-session-boundary-report.md) §3 (row
"The acquisition progress the loading surface shows") and §7 item 3, and of the plan's §17 DoD item
"UI de feed recebe exclusivamente snapshots/intents da boundary de sessão". Measured on this tree; nothing
was deleted, and `legacy`/`mirroredShadow`/`v2Presentation` — and the acquiring mode on every selection the
session's plan was not built for — keep the source of truth they had.

**State: on the surface the runtime owns, the loading indication is now built from the runtime's own
statement, and the legacy startup runway's counters are not read there at all. Every legacy loading path
renders the same chrome it rendered before the slice, from the same counters.**

## 1. What the loading surface read, and what reads it now

`InitialFeedLoadingView`'s progress came from five legacy pieces of state, all of them the *startup
runway's* — how many source fetches the legacy engine has completed against its own target. On a `v2Full`
launch the gate refuses that engine's requests (`RSSFetcher.performFetch:131`, `baseline.md` §8.26), so the
numerator could not move: measured before the boundary follow-up described in §6 item 2, that chrome's
figure on a `v2Full` screen is `value=0/100` (`surface[initial-loading] appear source=runway … value=0/100`,
§4) — a fraction of a target that this launch's acquisition never advances. That line is no longer
reachable on a `v2Full` launch (the follow-up removed the pre-attach frame that drew it); the figure is the
record of what the surface read.

| Legacy state | Before (`InitialFeedLoadingView`) | After, on the surface the session owns | After, everywhere else |
|---|---|---|---|
| `loader.startupFetchedSourceCount` | title's first branch, the bar's fill, the `fetched/target` line, the percentage, both `.numericText()` animations, `accessibilityValue` | not read | verbatim |
| `loader.startupTargetSourceCount` | the fraction's denominator, the line, the percentage | not read | verbatim |
| `loader.startupRunwayReady` | `StartupSignalView(isReady:)`, the bar's green | not read (`isReady` is false: this surface exists only while no edition has been published) | verbatim |
| `loader.startupRecentSourceNames` | the 250 ms rotation under "Loading articles" | not read (the runtime's report carries counts, not titles) | verbatim |
| `loader.hasPreviouslyLoadedContent` | the title's second branch | not read | verbatim |

The counters are now read in exactly one place: `FeedLoadingDisplay.forSurface(session:loader:)`
(`FeedScreen.swift:1877-1893`), and only in its `.runway` branch. `FeedScreen.swift:187` passes
`runtime.sessionLoadingStatement`; `FeedScreen.swift:214` — the legacy content branch — passes nothing, and
an absent statement is what selects the `.runway` lane. The layout above it (`StartupSignalView`, the
subtitle, "Loading articles", the wave geometry) is untouched; what changed is what fills the title, where
the bar and the numbers block were, the rotation's source, and the accessibility value.

## 2. The runtime's own statement

`MainFeedLoadingStatement` (`MainFeedRuntime.swift:99-146`) is the statement, and it is a value of the
runtime's facts with no `FeedLoader` in sight:

| Case | Facts |
|---|---|
| `.readingCatalogue` | the catalogue has not been read: `MainFeedSessionState.notStarted` (this launch's bootstrap) |
| `.acquiring(catalogueSources:watched:)` | `MainFeedSessionState.acquiring(sources:)` plus `V2AcquisitionReport.watched` and `V2AcquisitionReport.refused.count` |
| `.noCatalogue` | `MainFeedSessionState.noCatalogue`; the screen draws the empty surface for it, never this one |

`MainFeedLoadingStatement.forSession(state:report:)` (`:127-144`) mirrors `MainFeedSessionSurface.forSession`:
no `FeedLoader` parameter, so the answer cannot be the runway's counters. `MainFeedRuntime.sessionLoadingStatement`
(`:203-206`) is non-nil exactly when `sessionSurface == .preparing` — i.e. exactly when this chrome is on
screen — and nil in every other mode and on every other selection. The guard is `sessionSurface`, never a
mode string and never a lookup (`cardByItemID` is populated for legacy pages too, which the exposure slice
measured). **A boundary follow-up folded after this slice** made `sessionSurface` (`:222-235`) answer
`.preparing` for `pageSource == .none` too, when the launch owns acquisition, so the first frame of a
`v2Full` launch is this surface's with this statement — see §6 item 2, which is closed by it.

**How the report reaches the screen.** `V2FullRuntime.start` gained `onWatched:`
(`V2FullRuntime.swift:226-239`), called the moment `acquisition.watch` returns. `MainFeedRuntime.startSession`'s
callback (`:407-417`) stores it and writes `sessionState = .acquiring(sources:)` in the same turn, so the
surface never states a watch that has not happened. The seam exists because the acquiring runtime is not
observable and a read taken after `start` returned would be after the first publication — the loading
surface the report is for is gone by then.

## 3. What the surface says, and why each line is honest

| Session state | Title | Where the runway printed `fetched/target` | Bar | Percentage |
|---|---|---|---|---|
| `.readingCatalogue` | "Preparing your feed…" | "Waiting for the source catalogue" | none | none |
| `.acquiring(n, watched)` | "Acquiring `watched.count` sources…" | "`watched.count` of `n` sources watched" (· "`refused` refused" when non-zero) | none | none |
| `.noCatalogue` | "No sources enabled" | "Nothing to acquire from" | none | none |
| legacy runway | the three legacy branches, in the same order | "`fetched`/`target`" | the runway's own bar | "`p`%" |

* **There is no percentage, and no bar to put one on.** The legacy chrome filled a bar and printed
  `Int(progressFraction * 100)%`, a fraction of *fetch attempts* against the legacy target. The runtime has
  no measurement for "how much of the feed is loaded", and plan §16's rule is to measure and not to invent
  "números aprovados" — so the session's lane states what the session did instead. A bar without a fraction
  would be an empty bar, i.e. a 0% claim, so the lane draws none and the statement line takes its place.
* **The title states the acquisition set, not the catalogue.** The catalogue is what the session is
  *offered*: 71,234 sources in the measured launch. What it acquires from is bounded twice —
  `V2Acquisition.launchWindow` (32 targets registered) and the purpose budgets (`bootstrap` four targets,
  `activeRunway` two; `V2Acquisition.acquire`). An earlier wording of this line said "Acquiring 71,234
  sources…" and was rejected against the runtime's own episode line for the same launch, `targets=32`: the
  surface would have claimed a job two thousand times larger than the one it started.
* **"Editions published" is not a field.** This surface *is* "no edition has been published yet"
  (`sessionSurface == .preparing`), so a zero would be a constant; the phase states it.
* **"Refresh in flight" is absent, and named as absent rather than guessed.** It is not readable in the app
  layer today: `V2FullRuntime` exposes `report`, `lastSummary`, `startupReport`, `currentCounters()` and
  `frontierState()` (the last two async); `MainFeedRuntime.refreshTask` is a task handle that is never
  cleared, so it cannot answer "in flight". It would be one flag around `V2FullRuntime.refresh()`'s two
  awaits, plus a decision about what the surface should say; until a later slice makes that decision the
  statement is silent instead of guessing.

The launch's own copy is readable after the fact: `surface[initial-loading] appear|statement source=<session|runway> label=… value=…`
(`FeedScreen.swift:2107-2125`), next to the boundary's existing `page-source=` line.

## 4. What the launch observed (iPhone 16 simulator, this tree)

App built by this slice's app-plan gate, installed and launched with
`-RuntimeV2UI -RuntimeV2Network -UITestSkipOnboarding`; read back with
`xcrun simctl spawn <udid> log show --last 90s --info --predicate 'subsystem == "com.feedmine.app" …'`.
Verbatim, the 04:53 launch:

```
runtime-v2 page-source=session-snapshot selection=main|preset=everything|box=-|MainFeedPlan
surface[initial-loading] appear source=runway label=Preparing your feed... value=0/100
surface[initial-loading] appear source=session label=Preparing your feed... value=Waiting for the source catalogue
surface[initial-loading] disappear
surface[initial-loading] statement source=session label=Acquiring 32 sources... value=32 of 71,234 sources watched
runtime-v2 v2Full snapshot edition=edition:5 cards=9 sequence=1 context=main|preset=everything|box=-|MainFeedPlan
surface[initial-loading] disappear
runtime-v2 episode=1 purpose=activeRunway reason=refresh targets=32 pulls=1 admitted=0 observations=0 stop=refused(batchConflict(batchID: "syndication:source:1#1#ca83bdf4975d3b4c73a0a95f8007bd29"))
```

What it shows:

* the session's lane is what a `v2Full` reader gets, and its statement is the runtime's: `Acquiring 32
  sources… / 32 of 71,234 sources watched`, agreeing with the runtime's own `targets=32`;
* **no percentage and no bar are rendered on that lane** — the screenshot taken inside the window shows the
  wave (not green), the title, the statement line, and where the bar and "0/100 · 0%" used to be, one line
  of the runtime's own facts;
* the timing, measured on the tree before the boundary follow-up folded in §6 item 2: the first frame's
  legacy lane is mounted for **7.3 ms** (`appear source=runway` `.815839` → `appear source=session`
  `.823153`; 5.9 ms on the 04:52 launch), the `.readingCatalogue` copy covers **14.1 s** (`.823153` →
  `37.930039`), the `.acquiring` copy **28–50 ms** (`37.930039` → the snapshot `.958568` / the surface's
  `disappear` `.980304`), and then the restored edition is drawn. The `source=runway` line above is that
  tree's; after the follow-up the first frame is the session's own `.readingCatalogue` statement, and a
  `v2Full` launch paints no runway figure at all.

The legacy lane's 7.3 ms first frame was the last place this surface painted the legacy counters, and it is
now closed in the boundary that owns the claim (`MainFeedRuntime.sessionSurface`), not here: §6 item 2.

## 5. Proof

`MainFeedRuntimeV2Tests` (26 tests in the class, 24 of them pre-existing), the two this slice adds:

* `testTheSessionLoadingSurfaceStatesTheRuntimesOwnAcquisitionAndNotTheLegacyRunway` — on a `v2Full` launch
  with a **real legacy runway** (one of three sources fetched, through `FeedStore.configureStartupProgress`
  and `recordStartupFetchProgress`, the pair `FeedStoreTests` uses), the surface state is `.preparing` and
  `sessionLoadingStatement == .readingCatalogue`; the same loader — with its counters non-zero, so the
  assertion is about the choice and not about them being empty by accident — yields
  `.runway(fetched: 1, target: 3, isReady: false, recentlyFetchedSourceNames: ["Legacy Source"], hasPreviouslyLoadedContent: false)`
  on the lane that still owns it, with `detail == "1/3"`, `percentage == "33%"`,
  `accessibilityValue == "1/3"`; and on the session's lane `.session(.readingCatalogue)` /
  `.session(.acquiring(catalogueSources: 118, watched: .init(count: 32, refused: 1)))` with
  `percentage == nil`, `hasProgressBar == false`, `rotatingSourceTitles == []`, a title that carries 32 and
  not 118, and a detail that carries neither `1/3` nor the runway's shape.
* `testEveryModeAndEverySelectionThatOwnsNoSessionKeepsTheLegacyLoadingRunway` — `legacy` and
  `v2Presentation` both state `sessionLoadingStatement == nil`, and
  `FeedLoadingDisplay.forSurface(session: nil, loader:)` is the runway verbatim; in `v2Full` on
  `.lastClicked` (page source `.legacyPage`, `waitForPageSource`) it is nil again with `detail == "1/3"`,
  and back on the session's selection it is `.readingCatalogue` again.

Legacy paths unchanged: `legacyFeedContent`'s `.preparing` branch still constructs `InitialFeedLoadingView()`
with no statement (`FeedScreen.swift:214`), so its title, bar, numbers, percentage, rotation and
accessibility value are the expressions they were, now evaluated in `FeedLoadingDisplay`'s `.runway` branch.
The three DoD2 tests from the boundary slice and the exposure slice's three stay green, and so do the
package's 494 tests (no package source was touched).

## 6. What remains

1. **The header's source chip still reads the runway.** `CompactFeedStatus` (`FeedScreen.swift:1600-1671`)
   reads `startupFetchedSourceCount`/`startupTotalSourceCount`/`startupItemsReady`/`startupItemsTarget`/
   `startupRunwayReady`/`isPreparingInitialRunway` and labels them "…sources verified". Measured on the same
   launches, in `v2Full`: the chip reads `· 71,234/77,443 sources` (visible in the screenshots) while the
   runtime watched 32 and its first episode `admitted=0` — a reader of the header is told 71,234 sources
   were verified on a launch that verified none. It is a different element from the loading surface (it is
   drawn whenever `isPreparingInitialRunway || showReadyPulse`, including over content), so this slice did
   not reformat it; closing it needs facts the runtime does not state yet (the session knows `cards`; the
   acquisition counters know `admittedObservations`; neither is "sources verified").
2. **The first frame of every launch was the legacy lane — closed after this slice, in the boundary.**
   Measured here: 7.3 ms of every `v2Full` launch (§4), because `MainFeedRuntime.sessionSurface` answered
   `nil` while `presentation.pageSource` was `.none` (the boundary's own third nil case) and the content
   branch drew `legacyFeedContent` for it — the only place on this screen where the `0/100` figure was still
   painted, and the reason §1's measurement was taken there. The boundary's follow-up made `sessionSurface`
   answer `.preparing` for `.none` too when the launch owns acquisition (`MainFeedRuntime.swift:222-235`),
   which is the selection its plan is built for and is claimed as the first thing `attach` does; the
   loading statement derives from that surface, so the first frame now renders the session's
   `.readingCatalogue` statement instead of the runway. Proof: `testAV2FullLaunchDrawsTheSessionSurfaceForTheSelectionItsPlanWasBuiltFor`
   asserts `sessionSurface == .preparing` *before* `attach`, and with the `.none` case reverted it failed
   verbatim as `XCTAssertEqual failed: ("nil") is not equal to ("Optional(feedmine.MainFeedSessionSurface.preparing)") -
   the first frame is the session's, not the legacy lane`, passing with the fix (the boundary's own
   measurement). Consequence worth keeping: if `attach` is ever delayed, the reader now sees the
   `.readingCatalogue` statement for longer than the 28–50 ms window measured in §4 — which is the intent,
   since that statement is a fact and the runway's `0/100` was not.
3. **The `.acquiring` copy is a 28–50 ms window on a warm launch**, because the load is dominated by the
   catalogue (14.1 s measured). If the surface should say more during that window, the facts belong to the
   catalogue read (OPML/taxonomy), which is legacy state — the same question as item 1.
4. **The rotation under "Loading articles" is empty on the session's lane**: `V2AcquisitionReport` carries
   counts, not titles, and the descriptors' titles are catalogue configuration (§16's counters rule).
5. **"Refresh in flight" is not stated** (§3), by decision rather than by omission.
6. **`V2FullRuntime.lastSummary` is declared and never assigned** (`V2FullRuntime.swift:199`): the
   per-episode `AcquisitionRunSummary` is produced by the composer and only logged in the episode line, so it
   cannot be a surface fact. Named because the boundary report's gap 3 lists it among the runtime's own
   progress statements.
7. **The empty surface's wording** — the other half of gap 3 — is untouched: `FeedEmptyStateView`'s
   `.generic` variant still reads `loadingState`/`sourceCount`/`fetchErrorCount`/`totalFetched`/`sources`/
   `disabledSourceIDs` (`FeedEmptyStateView.swift:157-226`). It is a different surface from this one.

## 7. Gates

Two things are recorded: the runs that measured this slice, and the state of the tree when the report was
written. Runs were taken one at a time.

**Measured by me, on the tree with every change of this slice** (before the boundary follow-up of §6 item 2):

`swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm`:

```
	 Executed 494 tests, with 0 failures (0 unexpected) in 8.226 (8.256) seconds
```

`xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd`:

```
	 Executed 595 tests, with 0 failures (0 unexpected) in 116.534 (116.716) seconds
** TEST SUCCEEDED **
```

595 = the 593 the exposure slice left plus this slice's two (`MainFeedRuntimeV2Tests`: 26 in the class, 24 of
them pre-existing). The package gate is unchanged at 494 because no package source is touched by this slice
(`V2AcquisitionReport` is app-side, in `feedmine/RuntimeV2/V2Acquisition.swift`).

**After the boundary follow-up folded in §6 item 2** (`sessionSurface` answering for `pageSource == .none`),
that tree was measured by the boundary slice that made the change: package `Executed 494 tests, with 0
failures`; boundary `PASS` (77 source files, 156 imports); app plan `Executed 595 tests, with 0 failures` +
`** TEST SUCCEEDED **` — its change added no test, so the counts are this slice's. It also re-ran this
class (26 tests) green.

**Three of my app-plan attempts after that fold failed without ever running a test, and the cause was a
sibling's mid-edit race, not this slice — corrected below with the measurement that settles it.** A sibling
slice was adding the `operationID` the read port needs to the `.opened` intent, and while it was between the
two halves of that change the build read
`Packages/FeedRuntimeV2/Sources/FeedRuntime/Session/FeedSessionReducer.swift:554` against the other shape:
`case let .opened(cardID, operationID):` →
`error: tuple pattern has the wrong length for tuple type '(cardID: PublicationCardID)'`, so the run ended in
`Testing cancelled because the build failed`. **Measured at 05:12:54, after that window closed, by the
boundary slice:** `swift build --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm` →
`Build complete! (0.64s)`, with `FeedSessionIntent.opened` now carrying `operationID` on both sides
(`FeedDomain/Presentation/FeedPresentationSnapshot.swift:393` and the app's constructor,
`MainFeedRuntime.swift:598-601`). The app half was deliberately not built by that slice, because the sibling
was still active there — so what is owed is the app-plan re-run on a tree where no sibling is mid-edit, which
the coordinating agent owns rather than this slice.

One app-plan attempt on the folded tree did build and run, and crashed the test host during
`DatabasePerformanceTests.testItemCountImpactOnFilterSpeed` (`Restarting after unexpected exit, crash, or test
timeout`, with `Failing tests: DatabasePerformanceTests.testItemCountImpactOnFilterSpeed()`). A later attempt
on the settled tree (the one the coordinating agent unblocked, at 599 tests) crashed the host a **second**
time, in a different suite entirely — `RuntimeV2ShadowTests.testShadowMirrorsWithoutExtraNetwork`, twice
inside that test, each time while the hosted app was bootstrapping, after which the harness relaunched and
finished the remaining 64 tests green. Two different crash sites, both host-level rather than assertions, is
why neither is attributed to a test or to this change: the loading surface touches no database path, that
suite's mode owns no acquisition (so the loading statement is the legacy lane there, and the app's own log
says so: `surface[initial-loading] appear source=runway`), and the volume was at 1.0 GiB free / 100% capacity
for both runs — the condition `baseline.md` §8.25 names as breaking a build on this machine. The counts above
are the measurements this slice stands behind; a green run on the fully settled tree is the project-wide
validation that runs once every sibling has landed.
