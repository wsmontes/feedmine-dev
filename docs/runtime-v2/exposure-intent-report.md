# Runtime V2 — the exposure intent: the screen's visibility signal crosses the boundary

Deliverable of the plan's §17 DoD item **"UI de feed recebe exclusivamente snapshots/intents da boundary
de sessão"** ([`2026-09-17-feedmine-runtime-v2-revised.md`](../superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md)
§17), for the half the boundary slice left open: the per-card **exposure** intent.
[`feed-session-boundary-report.md`](feed-session-boundary-report.md) is that slice's report; this one
**corrects its gap 1's authority claim** (§6) and closes the "the app never sends `.cardVisibility`" half
of it.

**State: on the page the session owns, a row becoming visible is an intent the session receives and
records; on every other page, and in every other mode, the legacy read-state write is unchanged.** What
the session records from the signal, and what it cannot (§3), is the honest shape of "exposure travels
through the boundary" in this build. The durable **read state** — `feed_item.consumed_at`, the thing the
screen's old call wrote — is still not written for a runtime card, and this slice does not write it: §6
states why that is the owner's decision and what taking it would cost.

## 1. What was measured before

| Site (before) | What it did | Why it was not the intent |
|---|---|---|
| `FeedScreen.swift:966` | `.onScrollVisibilityChange(threshold: 0.5) { visible in if visible { loader.markAsSeen(row.item.id) } }` | `row.item.id` on a runtime row is the display id the bridge synthesizes (`card:<PublicationCardID>`, `MainFeedPresentationPipeline.displayItem`, `:432-434`), and that id names no legacy row |
| `FeedStore.markAsSeen` (`FeedStore.swift:3938-3948`) | `UPDATE feed_item SET consumed_at = COALESCE(consumed_at, ?) WHERE id = ?`, plus the in-memory `consumedItemIDs` / `reservoir.readItemIDs` | matches **zero** rows for a display id: the durable half was a silent no-op, and the in-memory half recorded a display id as read state |
| `MainFeedRuntime.handle(.cardVisibility)` (`:524-525`) | `cardVisibilityCount += 1` and nothing else | the intent vocabulary and its effect existed and were never reached from the app: `visibility-samples=0` in every launch (baseline §8.32's own device log), so the session's exposure store was fed only by tests |
| `FeedSessionIntent.cardVisibility` (`FeedPresentationSnapshot.swift:384`) → `FeedSessionReducer.swift:537` → `ExposureTracker.submitViewport` → `exposure_fact` | the whole durable path, already built and pinned by `FeedSessionTests` | no sender |

Read state's authority, measured: **`feed_item.consumed_at` in `feedmine.sqlite`**
(`FeedStore.dbPath`, `FeedStore.swift:1353-1356`), read back by `UserStateStore.cachedItems`
(`UserStateStore.swift:889-897`, the Smart Feed's "seen items to the tail" ordering). It is not
`user.sqlite`. The boundary report's gap 1 says otherwise; §6 corrects it.

## 2. What changed

* **One entry point on the runtime.**
  `MainFeedRuntime.cardBecameVisible(itemID:)` (`MainFeedRuntime.swift:465-478`) is the screen's
  visibility signal, and it decides by **page**, not by mode: if `presentation.pageSource ==
  .sessionSnapshot` and the row's id resolves to a card of that page, it builds one observation and
  sends `.cardVisibility`; the branch **returns** there, so the legacy call is unreachable on the page
  that draws display ids. Otherwise `loader?.markAsSeen(itemID)` runs — the same call, with the same id,
  that the screen made before this entry point existed, for every other selection and every other mode
  (`legacy`, `mirroredShadow`, `v2Presentation`).
* **The declared number, in one place.** `MainFeedRuntime.cardVisibilityThreshold`
  (`MainFeedRuntime.swift:447`) is `ExposurePolicy.baseline.minVisibleFraction`, and the screen passes
  *that* as its scroll threshold (`FeedScreen.swift:964-966`). The number the callback fires under and
  the number the observation declares are one expression, not two literals that happen to agree: the
  policy keeps owning the threshold and the view states only the bound it crossed.
* **The screen** (`FeedScreen.swift:964-986`) calls the runtime; the `false` branch still writes nothing,
  exactly as it wrote nothing before (the read state records that a card was shown, never that it
  scrolled away).
* **The forwarding**, so the observation has the effect its vocabulary says it has:
  `MainFeedRuntime.handle(.cardVisibility)` (`:524-534`) hands the value to
  `V2FullRuntime.trackExposure` (`V2FullRuntime.swift:325-328`), which is `session.send(.cardVisibility)`
  and nothing else. It is gated on `ownsAcquisition`: a launch with no acquiring runtime has no session,
  and the observation is dropped by being handed to no one rather than written by a second owner. Neither
  layer does arithmetic or I/O on the callback's path (ADR-007 D6/H-16); the tracker coalesces, dwells and
  flushes.

## 3. What the view can state, and what the session records from it

`onScrollVisibilityChange(threshold:)` gives a Bool. The screen therefore knows exactly one thing — *this
row crossed this threshold* — and the observation says exactly that:

* `edge: .entered`: the callback fires on the crossing, so the entry edge is what happened. `.sample`
  would claim a sample the view never took.
* `visibleFraction = ExposurePolicy.baseline.minVisibleFraction`: the bound the callback fired under. The
  view has no fraction, a fraction it did not measure is not invented, and the declared number is the
  policy's own.
* `direction` stays `0`: the entry is not a measured movement across the viewport.

**What the store gains from this signal.** `viewportEntered` per card per visit, immediately — the
tracker appends it when the observation opens an interval (`ExposureTracker.submitViewport:185-206`) — and
`viewportLeft` when the interval closes: `sessionEnd` at teardown, `editionSwap` when a successor edition
activates, `windowEvicted` when the window drops the card (`ExposureTracker.cardsEvicted:262-269`).
`exposureFactsPersisted` counts them (`FeedSession.swift:663`).

**What it does not gain, and why.** No `seen` fact. `ExposureTracker.credit:366-372` grants `seen` only
from an accepted sample at least `policy.minDwellMs` after the fraction reached the threshold, and
`close` never credits `seen`; an entry edge credits 0 ms. So the fact the ADR-007 D12 history matrix uses
to hide a card in a scope is **not** produced by this signal, however well it is wired — the view's
cadence is one callback per crossing, not a sample while the card dwells. Producing it needs a sampling
cadence, and the screen already has the natural source (`onScrollTargetVisibilityChange` yields the
visible id set per scroll, `FeedScreen.swift:1013-1015`); that is a different trigger, a different rate
and its own slice, and it is also the place to add the `.left` edge (today an interval is closed by the
session's own eviction and edition machinery, so the close reason is `windowEvicted`/`editionSwap` rather
than `leftViewport`).

Also not observable in the field: exposure writes no log line, and the one place the counters appear
(`visibility-samples=N` in `MainFeedRuntime.diagnostics`) is logged once at launch, before any scroll
(`MainFeedRuntime.launch:233`), so it reads 0 there. In-process, `runtime.diagnostics` is the boundary
observable a test reads; in the field, `V2FullRuntime.currentStatistics()` holds the counts and nothing
surfaces them yet.

## 4. Proof

App suite (`feedmineTests/MainFeedRuntimeV2Tests.swift`), three tests, each asserting what a consumer can
observe:

* `testACardEnteringTheViewportOnTheSessionSurfaceReachesTheSessionAndNotTheLegacyStore` (`:461`) — a real
  `v2Full` launch in a temporary directory, a legacy page present, the session's selection claimed, a
  session snapshot applied. It calls the entry point with **the id the drawn row carries**
  (`card:<card id>`, asserted) and observes: `visibility-samples=1` (the intent reached the boundary) and
  `store.consumedItemIDs` **empty** (no display id reached the legacy read state).
* `testEveryModeThatOwnsNoAcquisitionKeepsTheLegacyReadStateWrite` (`:506`) — `legacy` and
  `v2Presentation`: `pageSource == .legacyPage`, the legacy row's id lands in `store.consumedItemIDs`
  exactly as before, and `visibility-samples=0`.
* `testNoExposureObservationIsSentForAPageTheSessionDoesNotOwn` (`:536`) — a `v2Full` launch moved to
  another selection: that page's own row is written to the legacy store and `visibility-samples=0`; coming
  back to the session's selection sends the observation (`visibility-samples=1`) and the display id still
  reaches no legacy write.

Package suite (`Packages/FeedRuntimeV2/Tests/FeedRuntimeTests/FeedSessionTests.swift`):

* `testTheVisibilityCallbacksEntryEdgeIsDurableOnItsOwn` (`:397`) — the exact statement the screen makes
  (`.entered` at `ExposurePolicy.baseline.minVisibleFraction`, the same expression the app's
  `cardVisibilityThreshold` is) on a real session with a published edition: the `viewportEntered` fact for
  that card is in `exposure_fact`, with the declared fraction, and `exposureFactsPersisted >= 1`.

**The limit of that pair, stated rather than hidden.** No single test drives a *launched* session's fact
store end to end. A legitimate runtime card cannot be inserted into a runtime database without Admission
(`OwnerSwapAcquisitionTests`'s own note), and a launched `V2FullRuntime` composes its session's composer
and transport internally, so an in-process test cannot hand it a stubbed source; the loads that would
stub one (`PolicyEnforcingHTTPTransport`, `RuntimeCompositionRoot.swift:85-89`) use `URLSession.shared`,
and registering a protocol stub process-wide would leak into every other test in the app suite. The two
tests above cover the two ends — the intent reaching the boundary, and that exact observation producing a
durable fact — and the hop between them (`handle` → `trackExposure` → `session.send`) is a pass-through of
one value with no branch. This is the same kind of limit baseline §8.28 records for touch injection.

## 5. Gates

Run on this tree, one at a time, after the last edit.

`swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm`:

```
	 Executed 494 tests, with 0 failures (0 unexpected) in 8.212 (8.240) seconds
```

`xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd`:

```
Test Suite 'All tests' passed at 2026-09-18 04:38:06.747.
	 Executed 593 tests, with 0 failures (0 unexpected) in 113.434 (113.621) seconds
** TEST SUCCEEDED **
```

Both counts include this slice's own tests: 494 = 493 before plus one package test, 593 = 590 before plus
three app tests. The boundary gate (`scripts/verify-runtime-v2-boundaries.sh`) was not re-run: no package
source file changed, only a package *test* file.

## 6. The named decision: the durable read state

This is stated for the owner, not taken by this slice.

* **The authority is `feed_item.consumed_at` in `feedmine.sqlite`**, written by `FeedStore.markAsSeen`
  (`FeedStore.swift:3938`) and `FeedStore.markAsRead`, and read by `UserStateStore.cachedItems`
  (`:889-897`) to order a Smart Feed's cached items, plus by the unread badge's
  `loader.items.count - loader.readItemIDs.count` (`FeedScreen.updateBadge`, `:1403-1404`;
  `CompactDebugInfo.unread`, `:1537`).
  `user.sqlite` holds bookmarks and click history; it is not where "seen" lives. The boundary report's
  gap 1 says otherwise and is corrected here.
* **A runtime card has no such row**, so `UPDATE feed_item … WHERE id = 'card:…'` matches zero and the
  intent's durable half is a no-op. The reader's scroll marks nothing read, and the unread badge cannot see
  a runtime card either way.
* **Making it durable would mean projecting a content row per seen card.** The only mechanism that makes a
  runtime card's row exist is the bookmark port's: card → `LegacyUserSubject` (a legacy item id + a content
  snapshot) → `UserStateBridge` / `LegacyContentProjection` → `legacy.write(subject.content, alias:)` (the
  port `MainFeedRuntime.durableUserActions` builds, `MainFeedRuntime.swift:342-365`; `RuntimeCardUserActions`,
  `V2FullRuntime.swift:32-70`). Extending that to *read state* is a
  durable-state policy decision, not a wiring detail: every card a reader scrolls past would leave a
  `feed_item` row with `consumed_at` set, which changes what the legacy page contains and what the unread
  badge counts — and the plan's §1 reserves that kind of decision for the owner. The exposure facts this
  slice now records are the session's own record and change neither.
* The session's exposure store is the right home for the *telemetry*; `seen` (which needs the sampling
  cadence of §3) and `read` (ADR-007 D5's own fact type, `ExposureEventType.read`, with a
  `user_state_op_id`) are the vocabulary a read-state slice would use — not `consumed_at` behind the
  session's back.

## 7. What is left, and who owns it

1. **The sampling cadence and the `.left` edge** (§3). Without it no `seen` fact exists, so the history
   scope's "hide what was seen" rule cannot fire. Owner: the exposure sampler slice. The trigger is the
   visible id set the scroll surface already yields; the intervals the session opens today are closed by
   its own eviction and edition machinery in the meantime.
2. **The durable read state** (§6). Owner: the owner of durable user state, as a policy decision.
3. **Field observability of exposure.** No log line, and the counters appear only in a line logged before
   the first scroll. Owner: whoever needs it; the counters already exist
   (`visibility-samples`, `FeedSessionStatistics.exposureFactsPersisted` / `exposureFlushes`).
4. **The unread badge** and **the loading/empty chrome** — unchanged by this slice, still the legacy
   store's statements. Owner: as the boundary report's §7 names them.
