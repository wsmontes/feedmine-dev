# Runtime V2 — the header chip on the page the runtime owns

Deliverable of the residual named in [`loading-progress-report.md`](loading-progress-report.md) §6 item 1 and
in [`baseline.md`](baseline.md) §8.37 ("the header chip `CompactFeedStatus` still reads the runway and
displayed `71,234/77,443 sources` while the runtime had watched 32"), and of the plan's §17 DoD item "UI de
feed recebe exclusivamente snapshots/intents da boundary de sessão". It is the third application of the
pattern §8.37 established for the loading chrome and §8.41 for the empty surface; those two lanes were not
refactored, because a third application of the pattern is what closes this residual, not a unification.

**State: on the page the session owns, the chip states the runtime's own statement and reads no legacy
runway property. Every other mode and every other selection renders the chip verbatim, from the same
properties, now read in one place.**

## 1. What the chip read, and what reads it now

`CompactFeedStatus` is the header chip: it sits in `compactHeader` (`FeedScreen.swift:497`) beside the
search, bookmark and filter buttons, above both content branches. Before this slice it read the legacy
loader directly, in seven properties, and one of two branches selected them:

| Legacy property | Before, inside `CompactFeedStatus` | After, on the page the session owns | After, everywhere else |
|---|---|---|---|
| `loader.isPreparingInitialRunway` | selected the startup-figures branch (with the view's own `showReadyPulse`) | not read | verbatim |
| `loader.startupFetchedSourceCount` | that branch's numerator (`· N/M`) and its accessibility label | not read | verbatim |
| `loader.startupTotalSourceCount` | that branch's denominator, floored by the catalogue — `max(startupTotalSourceCount, sourceCount)` | not read | verbatim (the fold is kept in `CompactFeedLegacyFacts.totalSourceCount`) |
| `loader.startupItemsReady` | the second clause of that branch: `· N of M articles for your first screen`, with its `.numericText()` transition | not read | verbatim |
| `loader.startupItemsTarget` | the same clause's target | not read | verbatim |
| `loader.startupRunwayReady` | the `.task(id:)` that raises `showReadyPulse`, and through it the green tint and the `checkmark.circle.fill` cue | not read | verbatim |
| `loader.activeSourceCount` / `loader.sourceCount` | the second branch: `·A/S sources`, drawn when the runway flag is clear and the registry has counted a catalogue | not read | verbatim |

The seven properties are now read in exactly one place: `CompactFeedDisplay.forSurface(session:loader:)`
(`FeedScreen.swift:1683-1704`), and only in its `.legacy` branch. `FeedScreen.swift:497` passes
`runtime.sessionChipStatement`; `CompactFeedStatus()` — the default, no statement — is the legacy chip. No
other file constructs this view, so there is no second call site to migrate.

**What the figure meant, precisely, because §6 item 1's one number is two shapes.** The chip's denominator
is the catalogue the registry has counted: `startupTotalSourceCount`, stamped by `FeedStore.start()` from
the bundle's manifest (`77,443` on the launch I logged below), floored by the registry's own count. Its
numerator was either the legacy engine's completed fetches (the startup-figures branch — `· 0/77443` in my
launch log) or the sources the current filters leave in scope (the second branch — the `71,234/77,443` of
§6 item 1, i.e. enabled over all). Both shapes are a statement about an acquisition this launch never
performs: `LegacyAcquisitionGate` refuses that engine's requests (`baseline.md` §8.26), so neither number
could move.

## 2. The runtime's own statement

`MainFeedLoadingStatement` (`MainFeedRuntime.swift:99-146`) is the statement: `.readingCatalogue`,
`.acquiring(catalogueSources:watched:)`, `.noCatalogue` — the value the loading chrome states (`§8.37`) and
the one the empty surface re-states where the legacy wording owed a source count (`§8.41`). The chip uses the
same value, so **one launch has one sentence on its chip, its loading chrome and its empty surface**; there
is no chip-specific wording to keep in sync.

`MainFeedRuntime.sessionChipStatement` (`MainFeedRuntime.swift:264-278`, declaration at `:275`) is non-nil
exactly when `sessionSurface != nil`:

```swift
var sessionChipStatement: MainFeedLoadingStatement? {
    guard sessionSurface != nil else { return nil }
    return MainFeedLoadingStatement.forSession(state: sessionState, report: acquisitionReport)
}
```

**Why its guard is wider than `sessionLoadingStatement`'s, and that is the fact this slice adds.** The
loading chrome is one content branch of the page the session owns, so its statement is non-nil exactly when
`sessionSurface == .preparing`. The chip is drawn for the whole screen, in `compactHeader`, for every content
branch — preparing, content and empty. `sessionLoadingStatement` therefore goes nil the moment the session
publishes, while the chip must not silently fall back to the runway at that same moment. The chip's guard is
the surface itself; the test below asserts both values on the same published surface (`sessionLoadingStatement`
nil, `sessionChipStatement` non-nil), which is what makes the two guards different rather than accidentally
equal.

## 3. The lane as a value

`CompactFeedDisplay` (`FeedScreen.swift:1670-1756`) is the lane, with the legacy inputs as values and a single
reader of the loader:

```swift
enum CompactFeedDisplay: Equatable {
    case session(MainFeedLoadingStatement)     // no legacy counter is in it
    case legacy(CompactFeedLegacyFacts)        // the seven properties, as values

    @MainActor
    static func forSurface(session: MainFeedLoadingStatement?, loader: FeedLoader) -> CompactFeedDisplay {
        guard let session else { return .legacy(CompactFeedLegacyFacts(...)) }
        return .session(session)
    }

    func content(readyPulse: Bool) -> CompactFeedContent? { ... }   // what is drawn, from the value
}
```

`CompactFeedContent` (`:1638`) keeps the chip's two shapes: `.figures(counter:articles:isComplete:label:)`,
the element the startup figures and the session's sentence are both drawn in, and
`.catalogueLine(String)`, the legacy chip's bare `·A/S sources`. `content(readyPulse:)` is the only place that
decides which is drawn; the layout below (`CompactFeedStatus`'s body, `:1758-1843`) holds no loader property
and could not interpolate one — it would have to switch to `.legacy` to see the counter at all. The view's
`showReadyPulse` stays view state and is passed **into** the value, so the branch the legacy chip selected
with `isPreparingInitialRunway || showReadyPulse` is decided in the same place as everything else.

## 4. What the chip says, and why each line is honest

| Session state | What the chip states | What the legacy chip stated there |
|---|---|---|
| `.readingCatalogue` | `· Waiting for the source catalogue` | `· 0/100` or `· 0/77443` — a fraction of a wave this launch never starts |
| `.acquiring(…)` | `· 32 of 71,234 sources watched` (plus `· N refused` when any target was refused) | `· 71,234/77,443 sources`, or the frozen fraction above |
| `.noCatalogue` | nothing (a bare "Feedmine") | nothing, in the same condition (`sourceCount == 0`) |

**The word changes: "verified" becomes "watched", and that is a correction, not a rewording.** The legacy
chip's accessibility label said `N of M sources verified`, which is what the visible `· N/M` was read as. The
runtime's fact is a watch, not a verification: `V2AcquisitionReport.watched` is how many of the catalogue's
sources this launch's acquisition owner took on and `refused` is how many of them no target could be composed
for. So the chip's label is the statement's own sentence — `32 of 71,234 sources watched` — and the test
asserts the sentence contains `watched` and does **not** contain `verified`. Nothing in this mode verifies a
source.

**The first-screen clause is dropped, and nothing is put in its place.** `· R of T articles for your first
screen` had no runtime counterpart: `T` is `FeedStore.coldStartImmediateItemCount`, the legacy ingest's own
constant, and neither `MainFeedSessionState`, `V2AcquisitionReport` nor `MainFeedLoadingStatement` states how
many articles make a first screen. `FeedPresentationSnapshot.cards` states what an edition did publish, which
is a different fact and not a target; a number for `T` would have been invented (plan §16). Measured, not
assumed: the device launch in §5 states `· 32 of 71,234 sources watched` with no articles clause, while the
legacy lane's clause in the tests is `· 0 of 12 articles for your first screen`.

**The completion cue is dropped.** `showReadyPulse` was raised by the legacy runway's `startupRunwayReady` and
drew a green tint plus a `checkmark.circle.fill` for 1.4 s. The runtime's statement carries counts, not a
completion, so the session's lane raises no cue rather than borrowing the runway's readiness — structurally,
`CompactFeedDisplay.runwayReady` is `nil` there, so the `.task(id:)` that would raise it watches nothing, and
`content(readyPulse:)` does not read the flag on the session's branch at all. The legacy lane keeps the cue
verbatim, including the case that matters most for "verbatim": a legacy page whose runway flag has cleared
but whose pulse is still up draws the startup figures (`· 0/4` in the test), because
`isPreparingInitialRunway || showReadyPulse` is still how that lane selects.

**`·A/S sources` is not a shape the session's lane takes.** The legacy chip's second figure is the catalogue's
own arithmetic (enabled over all). The runtime's own account of sources is the acquisition statement, which is
the fact a reader of the chip needs, and it says what happened rather than what is in scope. Where the legacy
chip fell silent (no catalogue counted) the session's lane is silent too, for its own reason: `noCatalogue`,
whose statement the page's empty surface already makes (`No sources enabled`, `§8.41`).

**The figure is one sentence, not a fraction.** The chip's counter is
`FeedLoadingDisplay.session(statement).detail` — the loading chrome's own line — with no arithmetic of its
own, so the chip cannot state one launch's acquisition differently from the chrome beside the page and the
empty surface below it. Two consequences worth naming: the chip's long sentence is drawn with
`lineLimit(1)`/`minimumScaleFactor(0.8)`, the legacy chip's own treatment of a long figure, unchanged; and the
element's accessibility label is the whole sentence, so assistive technology receives it entire even if the
pixel line truncates.

## 5. The lane is a production observable, and it was measured

The chip gained the same diagnostic its two sibling surfaces have — `surface[header-chip] appear
source=… value=…`, plus a `statement` line when its figure changes (`FeedScreen.swift:1812-1821`) — because
"which lane, and what does it say" is otherwise only readable in a test. That log line is the one thing a
legacy path sees that it did not before; it changes no rendering.

Device-observed, on this tree, `xcrun simctl launch … -RuntimeV2UI -RuntimeV2Network -UITestSkipOnboarding`,
read with `log show --info`:

```
# the v2Full launch (pid 62056), first frame and then the session's own watch report
surface[header-chip]    appear    source=session value=· Waiting for the source catalogue
surface[initial-loading] appear   source=session label=Preparing your feed... value=Waiting for the source catalogue
surface[header-chip]    statement source=session value=· 32 of 71,234 sources watched
surface[initial-loading] statement source=session label=Acquiring 32 sources... value=32 of 71,234 sources watched

# a launch whose runtime is not this page's owner (test-host launches, pids 60145 and 60349, same binary)
surface[header-chip] appear source=legacy value=· 0/77443
surface[initial-loading] appear source=runway label=Preparing your feed... value=0/100
```

Three things are settled by that: the chip on the session's page states the session's sentence and not the
runway's (`· 0/77443` is the figure §6 item 1 recorded, and it no longer appears on this page); the chip and
the loading chrome of the same launch agree (`32 of 71,234 sources watched`, from the same
`MainFeedLoadingStatement`, the chrome's title being the `Acquiring 32 sources...` that §8.37 reported); and a
launch that owns no session still states the legacy figures verbatim.

## 6. Proof

`MainFeedRuntimeV2Tests`, the two this slice adds (33 tests in the class, 31 pre-existing):

* `testTheSessionHeaderChipStatesTheRuntimesOwnStatementAndNotTheLegacyRunway` — on a `v2Full` launch with a
  **non-trivial legacy chip** (four enabled sources and a runway one fetch into four, still preparing, through
  `FeedStore`'s own `configureStartupProgress`/`recordStartupFetchProgress`), the screen's selection is handed
  `runtime.sessionChipStatement == .readingCatalogue`, and `CompactFeedDisplay.forSurface` is
  `.session(statement)` with `source == "session"`, `runwayReady == nil`, and the content
  `· Waiting for the source catalogue` with no articles clause — the same answer for `readyPulse` true and
  false, because the cue is not the session's. The same loader on the lane that still owns the chip is
  `.legacy(…)` — the **whole value pinned**, every legacy property accounted for, including the folded
  denominator — and states `· 1/4`, `· 0 of 12 articles for your first screen` and the label
  `1 of 4 sources verified`, with the cue raising `isComplete` and keeping the same figures. On the published
  surface (`sessionSurface == .content`) `sessionLoadingStatement` is nil while `sessionChipStatement` is not:
  the chip's guard is the surface, not the chrome's phase. A started session's statement
  (`.acquiring(catalogueSources: 71,234, watched: 32/1 refused)`) states the loading chrome's own sentence,
  containing `32` and `watched` and neither `verified` nor `1/4`; `.noCatalogue` states nothing.
* `testEveryModeAndEverySelectionThatOwnsNoSessionKeepsTheLegacyHeaderChip` — `legacy`, `mirroredShadow` and
  `v2Presentation` all state `sessionChipStatement == nil` and render the legacy chip verbatim: the catalogue
  line `·4/4 sources` (four enabled, nothing toggled off), and, once a runway is built on the same loader,
  `· 1/4` with the first-screen clause and `1 of 4 sources verified`; in `v2Full` on `.lastClicked`
  (`.legacyPage`, `waitForPageSource`) the statement is nil again and the chip is the runway's, and back on
  the session's selection it is the session's again.

Legacy paths unchanged: `compactHeader` still constructs the chip with no statement on every other mode and
every other selection, so its branch selection, its `· N/M` and `·A/S` counters, its `.numericText()`
transition, its first-screen clause, its `N of M sources verified` accessibility label, its green cue and its
`.task(id:)` that raises it are the expressions they were — the task now watches the value that carries
`startupRunwayReady` and fires only on this lane — now evaluated in `CompactFeedDisplay.content(readyPulse:)`'s
`.legacy` branch, from the same seven properties, read at the same moment (the view's own `display` computed
property). Two producers moved from `LocalizedStringKey` interpolation to plain `String` interpolation
(`Text(counter)`, `Text(text)`), which renders the same source text with the same substitutions — the same
class of note `§8.41` item 6 recorded — and the legacy-lane assertions above pin the strings.

## 7. What remains legacy on that element, named

1. **The chip's legacy lane is still the legacy store's**, which is correct: on a page the session does not
   own, the runway's counters and the catalogue's arithmetic are that page's own truth.
2. **The completion cue is a legacy concept.** `showReadyPulse` and its `.task(id:)` now exist only for the
   legacy lane; the session's lane has no completion to raise. If the runtime ever states "the first edition
   landed" as a value, the cue belongs to that value, not to `startupRunwayReady`.
3. **The chip states no edition figure on the session's lane.** `FeedPresentationSnapshot.cards` /
   `MainFeedPresentation.ordinalCount` (how many cards the session published) are not drawn. Nothing was lost
   — the chip has only ever stated source figures — but this is the runtime fact a later chip might state.
4. **No refresh state and no source names on the session's lane**: `V2AcquisitionReport` carries counts and
   not titles, and "refresh in flight" is not readable in the app layer (§8.37 §3, §8.41 item 3).
5. **On the published page the chip still states the session's acquisition**, not a statement about the
   edition on screen: the runtime states no "this page is complete" fact, and inventing one is the same
   question as item 3.
6. **`CompactDebugInfo` is untouched and is a different element.** When the hidden debug bar is enabled (a
   triple-tap on the chip, `showDebugBar`), that slot draws `CompactDebugInfo`, which reads `loader.items`,
   `loader.readItemIDs`, `loader.filteredItems`, `loader.podcastItemCount`, `loader.fetchErrorCount` and
   `loader.loadingState` (`FeedScreen.swift:1548-1570`). It is a development instrument behind a hidden
   gesture, it reads no *runway* property, and this slice did not reformat it — named so the claim is not
   overstated.

## 8. Gates

Runs were taken one at a time, through the gate rather than a raw `xcodebuild` call, so its destination
discovery, stale-module purge and free-space preflight all applied. The counts below are from the run
immediately before this report was written.

`swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm`:

```
	 Executed 495 tests, with 0 failures (0 unexpected) in 8.540 (8.567) seconds
```

The same half inside `bash scripts/validation/run_runtime_v2_tests.sh` (the gate runs it itself, so its
discovery, stale-module purge and free-space preflight applied to the app half that follows):

```
=== 1/2 package core on the macOS host (swift test) ===
   exit=0 executed=495 failures=0
   PASS: 495 package tests, 0 failures

=== 2/2 app suite through TestPlans/FeedMine-RuntimeV2.xctestplan ===
   purged 4 local package module(s) that a changed source would have kept stale
   exit=0 passed=603 failed=0
   PASS: 603 app tests, 0 failures

Runtime V2 test gate: PASS
```

603 = the 601 the empty-surface slice left plus this slice's two. The package count is unchanged at 495 because
no package source is touched (`CompactFeedDisplay` is in `feedmine/Views/FeedScreen.swift` and
`sessionChipStatement` in `feedmine/RuntimeV2/MainFeedRuntime.swift`). An intermediate run of the same gate on
the first draft of the two tests was red with 2 failures, both in this slice's own assertions — the chip's
denominator is `max(startupTotalSourceCount, sourceCount)`, and `startupTotalSourceCount` is stamped by
`FeedStore.start()`, which these test stores never call, so the fold answers the registry's own count; the
tests now pin that, and one assertion asked `nil` of a legacy lane whose readiness is `false`. Both were test
errors, corrected before the run above.
