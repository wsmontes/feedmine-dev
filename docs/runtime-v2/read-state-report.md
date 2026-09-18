# The durable read state, driven

Slice between the owner swap / durable-user-actions work and PR-17. `baseline.md` §8.36 measured the
gap in one sentence: the runtime's durable read state **is implemented and undriven** — `ExposureFact.type`
carries `.read` with the contract's `durableFactRequiresOperationID` rule, `ExposureTracker.read(cardID:operationID:)`
exists, `ExposureStore` folds facts into `history_projection.read_at_ms`/`read_cleared_at_ms`, the reducer
tracks `state.read` and card materialization sets `isRead:` — and nothing called any of it. This document
records what now drives it, the exact writes, the evidence at both levels, the gate counts verbatim, and
the half that is deliberately **not** implemented with the reason and the evidence for that decision.

**Status: the runtime half is code complete; the legacy half is a named owner decision, left unimplemented.**

## 0. The two halves §8.36 named, and which one this is

§8.36 split the work in two, and the split is what this slice is shaped by:

1. **Driving the runtime's own read state** — "an intent, a `recordRead` effect, a port method, a
   `Kind.read` row — not a new authority and not a content projection. It is what would make a read
   durable *inside* the runtime." **This is what is implemented here.**
2. **What the legacy surfaces see** — the unread badge and a legacy relaunch read `feed_item.is_read`,
   which needs a `feed_item` row for a runtime card, which is the content projection the bookmark port
   performs for saved cards. **This is not implemented**, and §5 below is the named decision, with the
   evidence, rather than a silent omission.

## 1. Gates

| Gate | Measured |
|---|---|
| `swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm` | **`Executed 495 tests, with 0 failures (0 unexpected)`** — 494 before this slice plus one package test (`FeedSessionTests.testAnOpenMarksTheCardReadDurablyForThatCardAndScope`). |
| `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd` | **`Executed 599 tests, with 0 failures (0 unexpected)`**; `** TEST SUCCEEDED **`. 595 before this slice plus four app tests: one end-to-end read test in `OwnerSwapAcquisitionTests` and three routing tests in `MainFeedRuntimeV2Tests`. |

One gate at a time, package first, so a package defect cannot hide behind the app suite (the migration
lesson `memory://root` records). The app plan was free when this slice ran (the peer's run settled at
595/0 at 05:05:15); the tree this slice landed on was 494/0 package, 595/0 app plan, boundary PASS.

`bash scripts/verify-runtime-v2-boundaries.sh` re-run after the last edit:
**`boundary gate: 77 source files, 156 imports`** / **`PASS: module boundaries match the plan`**. This
slice adds no package source file and no import — it is one file above the peer's pre-slice reading
(76/153) because a sibling slice's file is in the tree.

**Two environment artefacts worth knowing before re-running these gates** (both cost a full run here and
neither was a code failure): `.build-dd/Build/Products/Debug-iphonesimulator/<Module>.swiftmodule` holds
*frozen* module copies — the inner `arm64-apple-ios-simulator.swiftmodule` stays at whatever build first
wrote it — while the fresh module goes to `PackageFrameworks/<Module>.framework`; because the package
targets compile with `-I .build-dd/Build/Products/Debug-iphonesimulator`, a changed package source keeps
compiling against the stale signature until that module directory is deleted and the build regenerates it
(`FeedDomain` and `FeedStorage` both needed it in this slice). And a package tree that is mid-edit while
another agent's gate starts reports `tuple pattern has the wrong length` on the edit's own line, which is
the build's snapshot of that moment, not a defect that survived.

## 2. What now drives it

Four pieces, exactly the four §8.36 named, each in the file the plan's own vocabulary put it in:

| # | Piece | Site |
|---|---|---|
| 1 | **The read intent** — the open carries the durable operation id | `FeedSessionIntent.opened(cardID:operationID:)` (`FeedPresentationSnapshot.swift:393`) |
| 2 | **The effect** — `.recordRead(operationID:cardID:)` and what the reducer does with the intent | `FeedSessionReducer.swift:297` (kind), `:554` (the `.opened` case) |
| 3 | **The port method** — `setRead(cardID:operationID:)`, mirroring `setBookmarked` | `FeedSession.swift:62` (protocol), `:322` (application), `:584` (`performRead`) |
| 4 | **The `.read` kind row** | `UserStateProjectionStore.Kind.read` (`UserStateProjectionStore.swift:21`) |

### 2.1 The read intent is the open

`FeedSessionIntent.opened` gained the operation id rather than a second intent case being added beside it.
The reason is D5's own list: the reader's open is *both* facts that D5 keeps separate — the explicit
primary-action invocation that records `opened`, and the explicit reader session that grants `read` — and
D5's "none is inferred from another" is a rule about **facts**, not about intents. Two intents for one tap
would make the screen state one user action twice and would put the two facts on two arrival orders; one
intent carrying the app's operation id keeps them one action with two facts, and gives the durable one the
key D7 requires:

```
case let .opened(cardID, operationID):
    effects.append(makeEffect(.trackOpened(cardID: cardID), …))          // the action fact (coalesced)
    effects.append(makeEffect(.recordRead(operationID: operationID, …), …)) // the durable fact (D5/D7)
```

The operation id is minted where the bookmark's is minted — in the app entry point
(`MainFeedRuntime.opened(itemID:)`, `MainFeedRuntime.swift:591`) — and not inside the effect, because D7
keys the fact by "the durable user-state operation id", which is the app's to mint and the port's to
confirm under.

### 2.2 The effect calls the port, then records the fact — in that order

`FeedSession.performRead` (`FeedSession.swift:584`) is `performBookmark`'s shape step for step:

1. `userActions.setRead(cardID:operationID:)` — the app's durable port;
2. adopt the confirmation: `dispatch(.userStateChanged(cardID:bookmarked:read:operationID:))`, which sets
   `state.read`, and, for a card in the window, repaints the snapshot with `isRead:` (the materialization
   is `FeedSessionReducer.swift:744,761`, unchanged);
3. only then `tracker.read(cardID:operationID:)`, which appends the `read` fact, whose store fold sets
   `history_projection.read_at_ms` and clears `read_cleared_at_ms` (`ExposureStore.swift:264-266`).

A port that throws writes **no** fact and the session keeps the state it was showing (the bookmark's rule,
plan §5.2 step 5): a `read` fact without a durable operation behind it would be an invented history, which
is exactly what the contract's `durableFactRequiresOperationID` guard exists to refuse.

## 3. The port, mirrored from `setBookmarked`

`RuntimeCardUserActions.setRead` (`V2FullRuntime.swift:109`) takes the same three-step identity path as
`setBookmarked`, with one step fewer:

| # | `setBookmarked` | `setRead` |
|---|---|---|
| 1 | card → `LegacyUserSubject` (a legacy item id, never the card id) | the same call, the same subject |
| 2 | `UserStateBridge.setBookmarked` → `user.sqlite` intention + `bookmark_item` + snapshot, then `projections.apply(kind: .bookmark, …)` | `UserStateBridge.setRead` (`UserStateBridge.swift:313`) → `projections.apply(kind: .read, wanted: true, operationID: …)` |
| 3 | `LegacyContentProjection.write` (the `feed_item` row, the retention pin, the alias) | **not performed** — §5 |
| 4 | `FeedSessionUserState` confirmed from the row the reader would see | the same, read from both databases that can hold it |

Two details worth stating because they are not obvious:

* **A read confirmation carries the card's bookmark state, and vice versa.** `FeedSessionUserState` is the
  whole confirmed state, and the reducer adopts both fields (`FeedSessionReducer.swift:437-446`). A read
  confirmation answering `bookmarked: false` for a card the reader saved would take the bookmark overlay
  off it; a bookmark confirmation answering `read: false` for a card this launch read would take the read
  overlay off it. So `bookmarkState(subjectID:)` answers from the authority the reader's own bookmark
  surface reads (`BookmarkStore.isBookmarked`, `user.sqlite.bookmark_item`), and `readState(subjectID:)`
  answers from **both** honest sources: the runtime's own projection of the read intent, or the legacy
  content row the legacy lane writes. `setBookmarked`'s previous comment ("this build has no `setRead`
  port … so saying `false` would claim the article is unread") is superseded by that union.
* **Read is absolute, like the bookmark's `wanted`.** There is one direction: the plan's
  `setRead(_:_:operationID:)` shape (`ADR-004.md:248`) takes a `Bool`, and `ExposureStore.clearRead` exists
  (`:576`), but nothing in this build offers "mark unread" and `ExposureEventType` declares no
  `readCleared` fact, so a `wanted: false` path would be an unimplemented branch with no fact vocabulary
  behind it. The port therefore has no `wanted`, and retry safety rests where the bookmark's does: on the
  operation id (`UserStateProjectionStore.apply` is a no-op replay that still answers, `:51-62`).

## 4. The screen's open, and the display-id hazard

`MainFeedRuntime.handle(.opened)` (`:649`) **was** the hazard: on the session's surface the row's item id
is the display id the bridge synthesizes (`card:<card id>`, `MainFeedPresentationPipeline.swift:432-447`),
which names no `feed_item` row, and the effect called `loader.markAsClicked(itemID)` with it — the same
shape §8.35 fixed for visibility. It now decides by page, exactly as `cardBecameVisible` does:

* `presentation.pageSource == .sessionSnapshot` (the page the session owns) **and** `ownsAcquisition`:
  `V2FullRuntime.markRead(cardID:operationID:)` (`V2FullRuntime.swift:403`) sends the intent to the
  session. The legacy call is unreachable on that page, so the display id never reaches the legacy read
  state.
* every other page and every other mode: `loader?.markAsClicked(itemID)` verbatim, with the id that page's
  own row carries. That includes a **legacy page in the acquiring mode** — another selection's page, whose
  rows are the legacy store's — where the open must keep writing `feed_item.is_read`; that page is that
  store's, and losing that write would have been a regression this slice could have introduced.

`read-intents=N` was added to the runtime's diagnostics line (`MainFeedRuntime.swift:250,347`), the same
instrument `visibility-samples` is: the count of opens this launch routed to the session's read path, and
`0` on every page the session does not own.

## 5. The named decision: the legacy half, left unimplemented

**What is not implemented.** For a card the runtime acquired, an open writes **no** `feed_item` row and
**no** legacy read state (`is_read` / `opened_at` / `clicked_at` / `consumed_at`). The read is durable
inside the runtime — the projection row, the `read` fact, `history_projection.read_at_ms` — and the legacy
databases are untouched.

**Why that is a decision and not an omission.** The read-state half of the legacy projection was already
named as the owner's, with its evidence, before this slice: `exposure-intent-report.md` §6 ("The named
decision: the durable read state") records that the authority is `feed_item.consumed_at` in
`feedmine.sqlite`, that a runtime card has no such row, and that "making it durable would mean projecting a
content row per seen card … which changes what the legacy page contains and what the unread badge counts —
and the plan's §1 reserves that kind of decision for the owner". `baseline.md` §8.36 item 2 records the
same split, and adds the rollback half (DoD14). The bookmark's own projection rule (`UserStateBridge.swift`
`LegacyContentProjection` doc: "One row per action, never one per card. … An eager mirror of the feed would
bloat the legacy database and make the rollback window meaningless") does not settle it either, because an
*open* is a much broader action than a save: following that precedent for read writes a content row for
every article the reader ever taps.

**The measurement behind "changes what the unread badge counts".** `FeedStore.loadReadState`
(`FeedStore.swift:6451`) builds `readItemIDs` from `SELECT id FROM feed_item WHERE is_read = 1` — a
**global** set — and the badge is `loader.items.count - loader.readItemIDs.count`
(`FeedScreen.swift:1407-1408`, `CompactDebugInfo.unread`). A row V2 inserted for an opened runtime card is
in `readItemIDs` whether or not it is in `items`, so writing `is_read = 1` for content the legacy lane never
loaded *subtracts* from the visible page's count: the badge can reach zero with unread legacy items still
on screen. The same row also changes what a Smart Feed's cached list shows, since
`UserStateStore.cachedItems` (`:880-890`) orders by `feed_item.consumed_at`. Neither effect is stated
anywhere in the plan, so neither is taken here.

**What the runtime half does instead, for the rollback window (DoD14).** A read taken in `v2Full` does not
survive a relaunch into build 17 today: build 17 reads `feed_item.is_read`, and nothing was written there.
That is the same open gap the durable-user-actions report already records as its §5 item 1, now narrowed
from "the session's port has no `setRead`" to "the port exists and the legacy projection is the owner's
call" — one decision, not two.

## 6. The evidence

### 6.1 Package: the fact, the projection and the published card

`Packages/FeedRuntimeV2/Tests/FeedRuntimeTests/FeedSessionTests.swift`,
`testAnOpenMarksTheCardReadDurablyForThatCardAndScope`. A real on-disk runtime database, a published
edition of two cards, the real `ExposureFactStore` and `HistoryProjectionStore`, and the port spy:

* the port was called once, with the card and the operation id the intent carried
  (`userActions.readCalls == [ReadCall(cardID:operationID:"op-read-1")]`);
* the card the session publishes carries the confirmed state (`isRead == true`);
* the `read` fact is in `exposure_fact` under its D7 key
  (`ExposureFact.key(type:.read, editionID:…, cardID:…, scope:.main, visitOrdinal:0, userStateOperationID:"op-read-1")`)
  with `userStateOperationID == "op-read-1"`;
* `history_projection.read_at_ms` is non-nil for that card and scope, `read_cleared_at_ms` nil, and the
  **other** card of the same edition has no read — so the fact is per card, not per visit or per session.

### 6.2 App: durable inside the runtime, and nothing under the display id

`feedmineTests/OwnerSwapAcquisitionTests.swift`,
`testAnOpenOnARuntimeCardIsDurablyReadInsideTheRuntimeAndNeverUnderItsDisplayID`. The harness publishes a
real card through the production chain and hands the session the app's real port
(`RuntimeCardUserActions` over a `BookmarkStore` on an on-disk container and the runtime database). After
one open:

* the published card reports `isRead`;
* `user_state_projection(kind = 'read')` holds exactly one subject, `wanted = 1`,
  `lastOperationID = "op-read"`, and **the subject is not `card:<cardID>`**;
* the `read` fact exists for that card, edition and scope, with `user_state_operation_id = "op-read"`;
* `history_projection.read_at_ms` is set for that card and scope and `read_cleared_at_ms` is nil;
* `feed_item` holds **zero** rows and zero `is_read = 1` rows — the §5 decision, pinned so a later silent
  implementation of the legacy half fails a test instead of passing unnoticed.

### 6.3 App: the routing, and every legacy path verbatim

`feedmineTests/MainFeedRuntimeV2Tests.swift`, three tests:

* `testACardOpenedOnTheSessionSurfaceReachesTheSessionReadPathAndNotTheLegacyStore` — a `v2Full` launch
  with a session snapshot applied; opening the drawn runtime row (`card:<cardID>`) reports
  `read-intents=1` and leaves `readItemIDs`, `consumedItemIDs` and `clickedItemIDs` **empty**.
* `testEveryPageTheSessionDoesNotOwnKeepsTheLegacyOpenWrite` — the same launch, with the foreign page
  published the way `followLegacyPage` publishes one for another selection (the direct call, which is the
  idiom this file's legacy-page tests already use): opening its row writes
  `["other-surface-item"]` into the legacy read and clicked sets, and `read-intents=0`.
* `testEveryModeThatOwnsNoAcquisitionKeepsTheLegacyOpenWrite` — `legacy` and `v2Presentation`: the entry
  point's own legacy call, with the id the screen passed, `read-intents=0`.

### 6.4 Sensitivity: each write removed fails a test — measured, one at a time, then reverted

| Breakage | Result |
|---|---|
| the tracker's `read` fact removed (`performRead` without `tracker.read(…)`) | the package test fails: `("nil") is not equal to ("Optional("op-read-1")")` on the fact key, and `history_projection.read_at_ms is the read state a reader comes back to`. The app test fails at the same place (`XCTUnwrap failed: expected non-nil value of type "ExposureFactRecord"`) — no other write in this build sets `read_at_ms`. |
| the port's projection write removed (`UserStateBridge.setRead` answering `.applied` without `projections.apply`) | the app test fails on `the read reaches the runtime's own projection` (the `kind = 'read'` subject list is empty), while the card it publishes still reports `isRead` — so the assertion that fails is the *stored row*, not the session's optimism. The package test is blind to this one by construction (its port is a spy), which is why the app-level test exists. |
| the page guard removed from `handle(.opened)` (the legacy call always running) | the session-surface test fails on all four of its assertions — `read-intents=0` and `readItemIDs`/`consumedItemIDs`/`clickedItemIDs` non-empty, i.e. the display id `card:<cardID>` written into the legacy read state again — while the foreign-page test still passes, because writing the legacy read state *is* the correct behaviour there. |

Each breakage was applied alone, run, and reverted; the two gates in §1 were then re-run on the reverted
tree.

## 7. Gaps, named

1. **The legacy half (§5).** Owner: the owner of durable user state, as a policy decision. Until it is
   taken, a read does not survive a rollback to build 17 and does not change the unread badge or the
   legacy page.
2. **`reconcile` does not replay reads.** `UserStateBridge.reconcile` iterates
   `newestOperationsBySubject(kind: "bookmark.set")` only. Read deliberately writes no `user_operation`
   row: there is no authority row in `user.sqlite` for read to be replayed *from* (ADR-004 I-16 keeps one
   authoritative database per fact), and a `pending` row nothing could replay would be a false durability
   claim. What is replayable is what exists: the projection's `apply` is idempotent on the operation id,
   and the fact's key is `card:<id>|event:read|source:<op>`, so re-running the same operation heals
   both.
3. **`Kind.read` rows accumulate.** One row per distinct subject read, upserted, in
   `user_state_projection`; retention reads only `kind = 'bookmark'` rows
   (`RetentionPolicy.swift:278`, `RetentionCoordinator.swift:768`), so read rows are neither retention
   roots nor blockers and nothing expires them. Bounded by distinct articles opened; no GC path exists.
4. **The `.trackOpened` fact and the `read` fact are two effects of one intent, and the tracker can drop
   the second.** `mutateTracker` returns early when `state.visibleEdition` is nil (`FeedSession.swift:597`)
   — reachable only for an open that arrives before any edition is visible, where there is no card to
   open. The durable half is unaffected: the port already ran.
5. **No `isRead` overlay for a card the legacy lane read.** `readState(subjectID:)` answers from the
   legacy row too, so a bookmark taken after a legacy read reports `read: true`; but the session only
   learns the state when an action happens, so a card already read in the legacy lane is materialized
   unread until the reader opens or bookmarks it. That is the projection-inputs gap
   `V2FullRuntime.start`'s `projections: .empty` already names (owner-swap report §5), not a new one.
6. **The `read-intents` counter is per launch**, like `visibility-samples`: it states that the open left
   the boundary, not how many facts were stored. The stored facts are the tests' assertions (§6.1, §6.2).
7. **`MainFeedRuntimeV2Tests` has a latent order dependence on the process-global active preset, found by
   this slice and left as it is.** `FeedStore.setPreset` persists (`Settings.activePreset` →
   `UserDefaults.standard`, `AppSettings.swift:62,134`), and
   `testNoExposureObservationIsSentForAPageTheSessionDoesNotOwn` reaches `.legacyPage` by *changing* the
   preset and waiting for the page to follow (`MainFeedRuntimeV2Tests.swift:710-760`). Any earlier test in
   the same process that leaves a different preset persisted makes that change a no-op
   (`FeedStore.swift:4181`) and the test fails with "the page did not follow the selection". Measured, not
   argued: with a first draft of this slice's test setting `.lastClicked` before it, the pair
   `(testEveryPage…, testNoExposure…)` failed; with the pair `(testEveryModeAndEverySelection…,
   testNoExposure…)` it passed; the full plan was 595/0 before this slice and 599/0 after this test was
   rewritten to publish the foreign page directly instead of through a preset change. The pre-existing
   test is unchanged — this is its owner's call, not this slice's — and the fragility is recorded here
   because the next slice that touches the preset will meet it.

## 8. What is unchanged

* The exposure/visibility path (§8.35): `cardBecameVisible`, `ViewportObservation`, the sampler gap, and
  `MainFeedRuntime.sessionSurface`/`sessionLoadingStatement` (§8.37's first-frame fix and its pre-attach
  assertion are untouched by this slice — the loading lane still selects on the first frame).
* The bookmark path: `setBookmarked`, `BookmarkStore.setBookmarked`, `LegacyContentProjection.write`,
  `UserStateBridge.reconcile` and every existing bookmark test. The only change inside the bookmark path is
  the `read` field of the confirmed state, which is now answered from two sources instead of one.
* `ExposureStore.clearRead` still has no caller (mark-unread is not offered) and `FeedSessionState.read`
  is still only written by the reducer's `.userStateChanged`.
* No display id is written anywhere: the subject the port keys on is derived the same way the bookmark's
  is (`LegacyUserSubject`), and the tests assert it is not `card:<cardID>`.
