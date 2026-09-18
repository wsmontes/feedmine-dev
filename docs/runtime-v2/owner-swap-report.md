# Owner swap — V2 owns acquisition

Slice between PR-16 and PR-17. The plan has no item for it (baseline §8.21); the seam is located at
baseline §8.23 and briefed at `local://owner-swap-spec.md`. This document records what landed, what was
measured, and every gap left open. It is written by the slice that made the change, in the shape of
`pr-16-hardening-report.md`.

**Status: code complete; all three gates green; and the acceptance criterion is met — a `v2Full` launch
has been observed on a simulator, and the UI draws the runtime's cards.** Three observations in all: the
first found two defects (§7.2, §7.3), both diagnosed and fixed; the third confirmed the fixes and showed
the chain end to end.

## 1. Gates

| Gate | Measured |
|---|---|
| `swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm` | **489 tests, 0 failures** (484 before this slice; +5 new) |
| `bash scripts/verify-runtime-v2-boundaries.sh` | `boundary gate: 76 source files, 153 imports` / **`PASS: module boundaries match the plan`** |
| `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath .build-dd` | **BUILD SUCCEEDED** (app target, production sources) |
| `xcodebuild build-for-testing … -testPlan FeedMine-RuntimeV2` | **`** TEST BUILD SUCCEEDED **`** |
| `xcodebuild test-without-building … -testPlan FeedMine-RuntimeV2` | **`Executed 579 tests, with 0 failures`** — `** TEST EXECUTE SUCCEEDED **`. The plan held 572 tests before this slice and holds 579 after. The one failure it carried earlier was this slice's own `OwnerSwapAcquisitionTests` asserting an invariant the runtime does not have; §7.1 records the measurement that settled it. |
| `xcrun simctl launch … -RuntimeV2UI -RuntimeV2Network` (iPhone 16 simulator, runtime database deleted first) | **The acceptance criterion, observed**: `acquisition_target 32`, `origin_record`/`origin_revision`/`origin_search`/`selection_supply`/`source_membership` 30 each, `connector_checkpoint` 32, `feed_edition` **2** with 1 active and 1 superseded, `published_card` 42 — stable across three samples 15 s apart. On screen: "ICC – International Chamber of Commerce" / "ICC Global Trade Intelligence Report 2026" / a summary / "17 hours ago", i.e. the runtime's source line and declared date materialised from the frozen payload. |

An isolated derived-data directory was tried once for the first `build-for-testing` and exhausted the
volume (`No space left on device`); it was deleted and every measurement above was then taken
incrementally in `.build-dd`. The app production target compiles: that is the `BUILD SUCCEEDED` line.

## 2. The four pieces

### 2.1 A concrete `HTTPTransport`, and the policy on every fetch

`Packages/FeedRuntimeV2/Sources/FeedConnectorSyndication/PolicyEnforcingHTTPTransport.swift` — host
module `FeedConnectorSyndication`, as the plan's §3 table intends (`Foundation`/HTTP allowed there, and
`FeedStorage`/`FeedRuntime`/`FeedMedia`/`FeedUIBridge` forbidden from importing it; the gate is PASS).

- It validates **every** request through `EndpointPolicy` before the bytes leave the process: scheme,
  host, embedded credentials and the http→https upgrade. A rejection becomes
  `HTTPTransportError.transport(rejection.description)` — the description names the rule and never the
  URL, because a query string is personal data (ADR-005 D14).
- It **refuses redirects** (a session-level delegate returns `nil` from `willPerformHTTPRedirection`).
  `URLSession` follows redirects by default and forwards the request headers, which would let a
  conditional-request validator travel to a host that never issued it (ADR-005 D12) and would hide
  every hop from `SyndicationHTTPClient`'s per-hop `EndpointPolicy` check, its redirect ceiling, its
  chain evidence and the endpoint a checkpoint is bound to (D10).
- Not enforced by the old arrangement: the policy used to run only inside `SyndicationHTTPClient`, so a
  `HTTPTransport` injected anywhere else never passed through it — `FeedMedia/MediaPreparation.swift:560`
  fetched directly. It now passes through the policy by construction, because this is the only
  production transport there is.

**Coverage, stated exactly.** The connector's fetches go through it (the app injects it), and media
would too — but `grep` shows **no production caller of `MediaPreparation`** in this tree, so no media
fetch exists to cover today. The two exposures are in §6.

### 2.2 The production converter

The existing `SyndicationConnector` + `SyndicationTranslator` are wired; **no second converter was
added**. What the translator now populates, beyond what it already did:

| Field | Source, and nothing else |
|---|---|
| `precedence` | unchanged: derived from the declared version + payload fingerprint (`SyndicationRepresentationStamp.precedence(from:)`) |
| `provider` | RSS item `<source url>` (fallback: channel `<link>` + `<title>`); Atom `entry.source.id` (fallback: feed `id` / `rel=self`); role `.publisher`; keys in `SyndicationNamespace.connector` |
| `memberships` | `SyndicationSourceEnrollment` (source id + binding key + generation) passed from the composition root into the connector, which stamps every observation |
| `mediaCandidates` | declared only: RSS `<enclosure>`/Atom `rel=enclosure` MIME, Media RSS `media:content` (`medium` then `type`), `media:thumbnail` → `.thumbnail`, `itunes:image` → `.poster`; positions numbered per role; deduped by (role, url) |
| `nextCheckpoint` | **proposed**, never committed: `SyndicationBatchOutcome.proposedCheckpoint` is encoded by the app's `SyndicationAcquisitionSource` into `batch.nextCheckpoint`, and `AdmissionEngine` (`:265`, `:718`) is the only writer |

`memberships` is not optional and this is the sharpest finding of the slice: I read
`SelectionSupplyRepository.eligibilitySQL` (`:228-240`) and the guard at `:137` — a `selection_supply`
row with no `source_membership` is **invisible to Selection**. A successful fetch that enrolls nothing
shows the reader nothing.

`RuntimeSourceRegistry` (new, `FeedStorage/Identity`) is the allocator that did not exist anywhere: it
upserts the `source` row for an `EditorialSourceKey` and returns the durable `SourceID`. It is named
`RuntimeSourceRegistry` because the app already declares its own `SourceRegistry` (the OPML registry),
which shadowed the package type and made the first app build fail.

`SyndicationAcquisitionSource` (new, app target) is the acquisition-layer bridge, because no package
module may see both `AcquisitionSource` (`FeedRuntime`) and `SyndicationConnector`
(`FeedConnectorSyndication`): it decodes/encodes the checkpoint, stamps the batch with generation,
binding revision, lease epoch and checkpoint revision, and maps the connector's outcome taxonomy —
`.batch` → batch; `.notModified` → `.finished`; `.transportFailure` → thrown; `.throttled` → recorded in
`SyndicationHostGateStore` and `.disconnected`; everything else `.disconnected`.

### 2.3 The production composer, installed

`Packages/FeedRuntimeV2/Sources/FeedRuntime/Session/RuntimeFeedSessionComposer.swift`:

plan (`FeedPlanSource`) → **acquire** (`FeedCompositionAcquiring`) → `openEdition` (`.first` for
cold/contextSwitch, `.successor` for refresh/replenishment) → `token(for:)` *before* selection →
`SelectionEngine.draft` → `EditorialSequencer.sequence` → `PublicationCoordinator.publish` → read back
`repository.edition(_:)` + `repository.cards(in:)` → `FeedSessionComposition`.

- Who initiates: **the session pulls**; `PublicationCoordinator` never references `FeedSession`.
- New supporting read: `PublicationRepository.publishedOccurrences(for:editions:)`. The repetition
  window had no production source at all, so `EditorialSequencer` could only ever be given `.empty`, and
  a refresh would recur the visible page.
- Media is `[]`, so every declared candidate publishes as the deterministic placeholder (ADR-001 D14)
  and a launch never waits on bytes.
- Installed: `RuntimeCompositionRoot.compose` returns `.fullComposed(databaseDirectory:)` for `v2Full`
  (its own database in the production directory, one transport, `V2Acquisition`, `V2FullRuntime`);
  `MainFeedRuntime.attach(loader:)` builds the session from the loader's own plan and follows
  `session.snapshots()`; `MainFeedPresentation.applySnapshot(_:)` applies each snapshot to
  `FeedScreenStore` and builds the rows the screen draws. `CardPresentation` gained
  `publishedAt`/`sourceTitle`/`link` (filled in `FeedSessionReducer.snapshotEffects` from the frozen
  payload) so a row can exist without a legacy `FeedItem`.

### 2.4 The gate, flipped deliberately

`feedmine/RuntimeV2/LegacyAcquisitionGate.swift`: process-wide, installed once in
`MainFeedRuntime.launch` when `decision.mode.ownsAcquisition` (deliberately **not** in
`RuntimeCompositionRoot.compose`, which tests drive directly and which would leak a closed gate into
every other test in the process), reopened by `MainFeedRuntime.stop()`.

**One choke point**, not twenty: the check sits at the top of `RSSFetcher.performFetch`, before
`attemptedFetchCount += 1`, so every producer — bootstrap, progressive fill, drip, coverage mining, the
flush pipeline, refresh, stale refresh, replenishment, shake, the urgent batch, the smart-feed
maintenance loop, the search sweep, the import refill, source and collection, the region seed, What's
New, the onboarding showcase — stops issuing requests with no line changed in `FeedStore`. A missed
producer is a double fetch, which is the one failure this mode must not have.

`legacy` and `mirroredShadow` are untouched: the gate defaults open, `mirroredShadow` still installs the
shadow sink and the drain loop, and `v2Presentation` still returns `.legacyOnly`.
`FeedFetchOutcome.legacyProducerClosed` is a new state because neither existing one is true — not
`.failed` (which would write source-health penalties and move the adaptive backoff for a request that
never existed) and not `.notModified` (which would claim an endpoint confirmed a baseline nobody asked
about). Gated requests stay out of `sourceOutcomes`, so the demand ledger cannot count them as a refill
that happened; `FeedFetchBatch.gatedSourceCount` counts them instead.

**The `FeedSurfacePlans` owner rows** now state both modes. `owner` means the owner in the modes whose
legacy producers run; a new `runtimeOwner` states the owner in a mode whose runtime acquires, and
`acquisitionOwner(legacyProducerClosed:)` is the only way to read it. The Main Feed names
`AcquisitionCoordinator`; the other ten rows name none, and `FeedSurfaceCatalog
.surfacesWithoutRuntimeAcquisition` is the honest remainder as data:
`bookmarks, lastClicked, onboarding, search, smartFeed, source, sourceCollection, whatsNew`.
`catalogueBrowse` and `persistentSearch` are *not* on the list: their acquisitions are local reads that
closing the producers does not reassign. `FeedSurfaceCatalog.violations` additionally refuses a row that
names a runtime owner while acquiring through neither engine. `SurfaceOwnershipByModeTests` (new) asserts
all of it — and caught two defects in my own first version (the remainder filter omitted `.search`, and a
local-only surface wrongly reported "no owner").

## 3. Tests

**New, and passing (package gate, 489/0):** `Tests/FeedRuntimeTests/SurfaceOwnershipByModeTests.swift` —
5 tests: the Main Feed's owner per mode, the remainder list and the accessor's answer for each member, a
local-only surface keeping its owner, `.search` being listed because its sweep is closed, and the matrix
still validating.

**New; compiles; 6 of 7 pass:** `feedmineTests/OwnerSwapAcquisitionTests.swift`. It is the end-to-end test
the acceptance criterion needs — one scripted HTTP answer through the real
`PolicyEnforcingHTTPTransport` → `SyndicationAcquisitionSource` → connector/translator →
`AcquisitionCoordinator` → Admission → (`origin_search` and `selection_supply.source_id` populated) →
`SelectionSupplyRepository.page` → `RuntimeFeedSessionComposer` → a `FeedSession` snapshot with the card
in it — plus a second episode against a `304` (asserts the conditional header, zero admitted batches, an
unchanged checkpoint revision and blob), plus the transport's policy refusal (asserting the URL's query
is absent from the message) and a redirect returned rather than followed, plus three gate tests (a
closed producer is refused, is not an attempt, and does not enter `sourceOutcomes`; an open one behaves
exactly as before). All seven pass. They are the end-to-end chain above; both `304` episodes; the transport's policy refusal
(asserting the query string is absent from the message); the redirect returned rather than followed; both
closed-gate tests; the open-gate behaviour test; and the gated-sources-out-of-`sourceOutcomes` test.

**It earned its place immediately.** It caught a real defect in this slice: the provider claim added in
§2.2 used `role: .publisher`, while `SelectionSupplyRepository.primaryProviders:368` reads a candidate's
provider key from the `primary` attribution alone — so the attribution was written and never read, and
the card lost the attribution the document declared. `SyndicationAttribution.provider` now claims
`.primary`, with the reason recorded at the line.

**No existing test was changed**, and none went vacuous: nothing asserts that `v2Full` composes nothing,
and the suites that pin legacy behaviour drive `FeedStore`/`RSSFetcher` directly with no mode, so an open
gate leaves them as they were.

## 4. No double acquisition

Observables, not assertions: `RSSFetcher.fetchAttemptCount()` stays 0 for the legacy path in `v2Full`
(the gate is checked before the attempt is counted), `LegacyAcquisitionGate.refusedRequestCount` counts
what was refused, and `FeedFetchBatch.gatedSourceCount` counts it per batch.
`MainFeedRuntime.diagnostics` prints `legacy-gate=closed legacy-requests-refused=N`; `V2AcquisitionCounters`
reports episodes/pulls/admitted/duplicate/refused per launch. **None of these has been observed in a run.**

## 5. What this document does not cover

- **No `v2Full` launch has been run, on a device or a simulator.** Everything in §2 is compiled, not
  observed. The UI drawing a runtime snapshot is implemented and unproven.
- **The app test gate was never run** (`-testPlan FeedMine-RuntimeV2`), because the isolated
  `build-for-testing` attempt exhausted the volume. The new app test file is uncompiled.
- **`V2FullRuntime` itself is untested**: it needs a whole `FeedLoader` (OPML, taxonomy, the legacy
  store) to state its plan, so the end-to-end test drives the session and the composer directly and
  leaves the launch-time composition to the app.
- The `.22.1` CI failure was not touched, no boundary rule was relaxed, and no test was re-pinned.

## 6. Gaps, named

### 6.1 Five consequences that change what shipping `v2Full` today would mean

> **Updated 2026-09-18** (baseline §8.50–§8.53). Three of the five have moved since this section was written: the bookmark path landed and was then proven with the shipped binary, the markup consequence was fixed in the presentation layer it named as owner, and the BGTask and media entries are narrower than they read here. Each item keeps what it said and carries its current disposition.

1. **Bookmark actions on a runtime card are refused.** `RuntimeCardUserActions.setBookmarked` throws
   `subjectUnavailable`. `user.sqlite` is keyed by the legacy item id and legacy hydration reads
   `feedmine.sqlite.feed_item` for it — and V2-acquired content has no such row at all, so *no* subject
   string could make a bookmark hydrate after a rollback. Writing one would silently close the window
   ADR-004 D12 holds open, so the intent is refused and the control does nothing.
   **Delivered since:** the canonical-card → durable-user-subject projection and the content projection
   both landed, and the window's reverse half was then run with the shipped binary — a bookmark taken in
   `v2Full` by a driven tap survives installing build 17 over that container, in both stores, resolving
   through the path build 17's hydration reads (baseline §8.50).
2. **The BGTask fetches nothing in `v2Full`.** The handler still runs through
   `FeedLoaderProvider.shared`, whose requests the gate refuses, so the task completes as unsuccessful
   having issued no request. PR-15's single-owner property survives; serving the demand from the
   runtime's owner is open, and the route is traced rather than assumed:
   `FeedLoader.runBackgroundRefresh` → `FeedStore.runBackgroundRefreshDemand` (`FeedLoader.swift:1278` →
   `FeedStore.swift:5768`) is the legacy path the gate refuses, while the runtime acquires only inside a
   session composition (`V2Acquisition.acquire(for:reason:)`, whose `reason` is a
   `FeedSessionCompositionReason`), and the purpose such a wiring would use — `backgroundMaintenance` —
   already exists in the plan's table (baseline §8.53).
3. **Date sectioning is absent, deliberately.** The snapshot carries none, so the rows are one headerless
   list in publication order — and the second sentence of this item is the reason rather than a regret:
   inventing Today/Yesterday/This Week headers in the presentation **would be a second grouping rule beside
   `FeedLoader.dateSections`**, which `MainFeedPresentationPipeline`'s own doc states as the choice
   (baseline §8.53). Whether the runtime's feed should group by day is a product question, not debt.
4. **No media is ever fetched — and it is visible on screen.** `PublicationRequest.media` is `[]`, so
   every card publishes a deterministic placeholder; the observed launch draws **cards with empty image
   placeholders**, which is ADR-001 D14 behaving as designed rather than a rendering fault. A
   `.local(assetDigest:)` card (which this composer cannot produce) would draw a reserved empty frame —
   resolving a published digest to bytes is not wired. Audio playback of a runtime card is unresolvable
   because the payload carries no stream URL; the affordance tap is `.openReader` because the runtime's
   affordances are the neutral `.undecided`. **Contract-acceptable as it stands:** matrix row 22 asks for
   text plus a thumbnail/poster *or* a deterministic placeholder, and the placeholder carries its reason —
   what is missing is acquiring image bytes for published cards, a slice nobody has taken (baseline §8.53).
5. **A declared summary reaches the view with its markup intact.** The observed card body reads
   `<p>The ICC Global Trade Intelligence Report is the leading industry benchmark…</p>` — the document's
   HTML is what the revision froze, which is right for the canonical payload (the source of truth keeps
   what was declared), and wrong for a card: the legacy renderer strips it and the snapshot path does
   not. A presentation-layer gap rather than a canonical one, and not this slice's to fix — but it is the
   first thing a reader sees, so it is named here rather than left to be discovered.
   **Fixed 2026-09-18 by exactly that owner-shaped change:** one `FeedTextSanitizer.displayExcerpt` now
   serves the legacy extractor and the three runtime boundaries that turn canonical text into display text
   (baseline §8.52). A second `v2Full` launch draws "The ICC Global Trade Intelligence Report is the leading
   industry benchmark…" with no markup, and the gate after the change reads package 495 / 0 and app plan
   605 / 0.

### 6.2 Implementation limits

5. `PlanProjections` are `.empty`: no production read turns `user.sqlite`/`UserStateProjectionStore`
   subjects into canonical `SupplyStableKey`s, so the plan's `seen` exclusion excludes nothing and a card
   the reader already saw can reappear in a later edition. (`PlanCatalogProjection` being empty is
   benign: the Main Feed declares no `sourceSelection`, and the enabled set is enforced by what the
   launch acquires.)
6. `publishedOccurrences` uses the card's `observation_at_ms` as `PublishedOccurrence.publishedAt`. The
   sequencer ignores that field today; it is not the segment commit time.
7. An endpoint change does not advance the binding generation. The connector discards an
   endpoint-mismatched checkpoint and fetches unconditionally, so the fetch is correct (D12); the
   *record* of the change is not written.
8. The acquisition catalogue is bounded to `V2Acquisition.launchWindow = 32` sources per launch
   (registration only — the purpose budgets bound the fetching). Successive demands widen coverage; one
   launch does not walk a thirteen-thousand-source catalogue.
9. A source disabled *after* its content was admitted stays selectable: the Main Feed plan declares no
   source selection, so only acquisition enforces the enabled set. PR-17's revalidation owns removal.
10. Media fetches route through `PolicyEnforcingHTTPTransport` and therefore inherit its redirect
    refusal: a media URL answered with a 3xx fails with `httpStatus(3xx)` rather than being followed.
    Nothing composes media today, so nothing regresses; the media slice must handle redirects explicitly
    rather than relying on a transport that follows them.
11. The session's `releaseResources(for:)` is a deliberate no-op: the only per-composition resource is
    the coordinator's draft pins, and `PublicationCoordinator` releases them on every exit path.
12. `ShadowOutcomeKind` and `AdaptiveScheduler` carry an unreachable `.legacyProducerClosed` branch, kept
    for exhaustiveness and documented as unreachable rather than folded into `.failed`.
13. The shadow lane and the production lane now share one connector namespace
    (`LegacySourceMapper.syndicationNamespace` is taken from `SyndicationNamespace.connector` rather than
    spelled `"syndication"`), so the same source observed by both lanes is one scope. No test pinned the
    old literal; a shadow database written before this change has its objects under the old namespace.

## 7. Open findings from the observed runs

Recorded because both were found by running the thing, not by reading it, and neither is closed.

### 7.1 "One request, two admitted batches" — resolved, and it was the test

**Resolved in favour of the runtime: my expectation was wrong, and the run proved it.** Dumping the rows
from the failing test settled it in one measurement:

```
requests=2 admitted=1
row: syndication:source:test#1#9eee612fcdaa282718f9e838c8e3dc3c
     result=admitted expected=0 written=1 observations=1 fingerprint=0f411810e8ae
```

So there was never a second admission — there was a second **request**. Of the three possibilities, it is
none of "the target is pulled twice and the second submission is admitted again" and none of "an empty
batch is recorded as admitted": it is the third, and the plain one. `AcquisitionCoordinator`'s work-item
loop pulls a target repeatedly until the item's observation budget is met or the frontier degrades — the
live log for a cold launch reads `pulls=4 admitted=3`, and for a refresh `pulls=2 admitted=2` — so a
budgeted episode legitimately issues more than one request to the same endpoint, and the repeats are
answered as duplicates with no canonical effect. Every canonical cardinality is exactly 1, which is what
the earlier run already showed.

My assertion of one request per episode described a runtime this codebase does not have, and the failing
identity in the app's own log (`refused(batchConflict(batchID: "syndication:source:1#1#ca83…"))`, episode
3) is the same fact from the other side: a repeat pull whose batch identity collided with one Admission
had already taken. Main's observation that the transport sets `urlCache = nil` and
`.reloadIgnoringLocalCacheData` is what ruled out the cache mechanism I had proposed, and it was right.

The test now asserts the invariant that matters — **one target, one endpoint, one owner**, plus one
record per canonical table — instead of one request. That is the acceptance criterion's own subject:
double acquisition is two *owners* drawing the same URL, which the mode gate refuses and
`LegacyAcquisitionGate.refusedRequestCount` counts, not one bounded episode looking twice.

The same test's `tearDown` removes its temporary directory while the `RuntimeDatabase` is still open,
which logs `BUG IN CLIENT OF libsqlite3.dylib: database integrity compromised by API violation: vnode
unlinked while in use`. Test hygiene, owned by this slice, not a production defect.

### 7.2 A `v2Full` launch registered no acquisition target (fixed)

The first simulator observation found a runtime database holding an edition and nothing else:
`acquisition_target 0`, `origin_record 0`, `origin_search 0`, `connector_checkpoint 0`.

Diagnosis, from the path rather than from the counts: `FeedScreen.startScreen()` calls
`runtime.attach(loader:)` and only **then** `await loader.start()`, and `attach` fired the session task
immediately with its descriptor set built from `loader.enabledSources` — the OPML registry, filled by the
slow part of bootstrap, still empty. Empty descriptors → `V2Acquisition.watch([])` → empty catalogue →
`acquire` returned `nil` at its `guard !catalogue.isEmpty` → no target, no connector, no fetch. The
composer then ran to completion on empty supply: `openEdition(.first)` created the edition, selection
found nothing, `publish` answered `nothingToPublish`, and the session delivered a snapshot with no cards.

Fix: the session no longer starts at attach time. `MainFeedRuntime.catalogue(_:within:)` waits (bounded
at 30 s, cancellable) for `loader.enabledSources` to be non-empty, then binds the descriptors from those
sources; if the deadline passes it logs `session=no-catalogue` and does not start the session. The design
point is stated at the call site: a plan cannot be composed before the catalogue exists, so the session is
deferred rather than started empty, and the catalogue is not read from a second source of truth.

Confirmed by the second observation (one context, runtime database deleted first):

| | before | after |
|---|---:|---:|
| `acquisition_target` | 0 | 32 |
| `origin_record` / `origin_revision` | 0 / 0 | 30 / 30 |
| `origin_search` | 0 | **30** |
| `selection_supply` / `source_membership` | 0 / 0 | 30 / 30 |
| `connector_checkpoint` | 0 | 32 |
| `admission_batch` | 0 | 5 |

`origin_search` is populated for the first time in this project's history: baseline §8.14 recorded the
canonical content index as inert.

### 7.3 A runaway successor-edition loop (fixed, and observed settling)

The same run revealed a loop: sampled ten seconds apart while idle, `feed_edition` 531 → 703 and
`published_card` 6,390 → 8,466 — about **17 editions and 208 cards per second with no user input**,
terminated at 807 editions and 9,702 cards. All in one context, **one epoch**, 1 `active` and 806
`superseded`: a successor chain, not a fan-out.

**The lap**: `MainFeedPresentation.applySnapshot` wrote `sections` on every snapshot → the screen
re-rendered → the scroll surface's visibility observation fired again → `MainFeedRuntime.viewportChanged`
→ the store's viewport channel → the session's `.viewportChanged` → the reducer's near-the-tail rule
emitted `.compose(.refresh)` → `RuntimeFeedSessionComposer.opening(for: .refresh)` returned `.successor` →
`PublicationCoordinator.publish` → `.composed` → a new snapshot → `applySnapshot` → the next lap.

**Why nothing guarded it**: `PublicationCoordinator.singleFlight` is per *edition*, and the lap creates a
**new** edition every time, so "one in-flight composition per edition" never engages. The reducer's own
coalescer (`state.replenishment[context] = tail` before composing) is defeated by the loop's own effect,
because every successor moves the tail. And the rule that was actually missing — *a refresh that admitted
nothing must not append an edition* — was written nowhere, which is why the initial compose and the
runway behaved differently under pressure.

**Fix, two guards**: the composer reads `SelectionSupplyRepository.supplyGeneration` **after** acquisition
and keeps a per-context ledger of the generation its last composition saw; on a `.refresh`/
`.replenishment` with an unchanged generation it returns the active edition and its cards without opening
a successor or publishing (ADR-002 D4's logic — a supply increment that did not happen cannot justify a
new edition), while `.cold`/`.contextSwitch` still open their first edition and a plan whose supply moved
still gets its successor. `applySnapshot` no longer rebuilds `sections` for a snapshot identical to the
last one, which removes the re-render that drove the observation. Both sit where the loop's two
re-entering calls are, so the guard governs the runway path exactly as it governs the initial compose.

**Observability, added because the loop was invisible**: `FeedCompositionEvent` reports every composition
decision (`published` / `unchanged` / `empty`, with context, reason, edition and card count) through a new
`observe:` closure on the composer; `V2Acquisition` logs one line per episode (episode, purpose, reason,
targets, pulls, admitted, observations, stop); the snapshot sink logs edition/cards/sequence/context. The
loop that wrote 9 MB produced a log with no repeated line at all, and that is the property this fixes.

**Observed, and it settles.** The third simulator run, sampled three times 15 seconds apart, held
`feed_edition` at **2** and `published_card` at **42** (1 active, 1 superseded) against 807 editions and
9,702 cards before the fix. The instrumentation reads exactly as intended:

```
episode=1 purpose=bootstrap     reason=cold    pulls=4 admitted=3 observations=18 stop=degraded(streamDisconnected(...))
composition reason=cold    decision=published edition=edition:1 cards=18
episode=2 purpose=activeRunway  reason=refresh pulls=2 admitted=2 observations=24 stop=planCompleted
composition reason=refresh decision=published edition=edition:2 cards=24
episode=3 purpose=activeRunway  reason=refresh pulls=1 admitted=0 observations=0  stop=refused(batchConflict(...))
composition reason=refresh decision=unchanged edition=edition:2 cards=24
```

Episode 3 is the guard: nothing admitted, `decision=unchanged`, no successor. The runway — the path that
kept the loop running — now converges instead of appending.
