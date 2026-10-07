# FeedMine 1.0 — Product & Runtime Development Contract

**Status:** Normative development document  
**Date:** 7 October 2026  
**Audited baseline:** `wsmontes/feedmine-dev` → `fix/release-1.0-final-hardening` @ `fb410634877fb2dd4f737e045e8003df57cf9305`  
**Scope:** FeedMine 1.0 runtime, Main Feed behavior, acquisition, local supply, selection, media preparation, publication, session, presentation, background work, compatibility boundaries, and release gates.  
**Role:** This document governs current development direction. It does not replace the architectural rationale in the Unified Architecture Blueprint v0.4, the Runtime V2 Technical Architecture, ADRs, or measurement reports. When an older status/closure document conflicts with the current audited implementation state or with the development priorities below, this document governs current work until explicitly superseded.

---

## 1. Why this document exists

FeedMine has accumulated enough code, tests, compatibility paths, release machinery, and partially migrated runtime behavior that a locally correct change can easily make the product worse. The project can no longer be guided primarily by isolated defects, individual test failures, micro-benchmarks, or the internal concerns of whichever subsystem an agent happens to inspect first.

The purpose of this document is to restore one development contract:

> **FeedMine must behave like a continuous local feed whose future is prepared proactively while the user consumes already prepared local history.**

FeedMine does not own a content server. It acquires content from thousands of external sources at runtime, under real network, energy, storage, memory, thermal, and iOS background-execution constraints. Some latency is therefore intrinsic. Product quality does not mean pretending that latency does not exist. It means ensuring that unavoidable latency happens sufficiently far ahead of the user and is represented honestly when it cannot be hidden.

The project should not be rewritten from scratch. Runtime V2 already contains most of the architectural boundaries we want. The immediate objective is to make the shipping runtime behaviorally complete, assign one owner to each responsibility, then remove or disable overlapping legacy work.

---

## 2. Product thesis

FeedMine is a local-first, offline-capable feed reader that continuously transforms heterogeneous external content into a local, presentation-ready editorial supply.

The user does not scroll the Internet.

The user scrolls local published history.

The runtime works ahead:

```text
External systems
        ↓
    Connectors
        ↓
Transactional Admission
        ↓
Canonical Local Supply
        ↓
     Selection
        ↓
 Media Preparation
        ↓
    Publication
        ↓
Immutable FeedEdition / Segments
        ↓
    FeedSession
        ↓
Local Presentation Window
        ↓
      SwiftUI
```

Two loops coexist but must remain decoupled:

```text
SUPPLY LOOP
external demand
→ acquisition
→ admission
→ canonical local supply
→ media preparation / future publication capacity

CONSUMPTION LOOP
FeedSession
→ local published history
→ FeedWindow
→ viewport observations
→ runway pressure / future demand
```

They meet through local supply and publication. They do **not** meet through `scroll → network`.

The most important operational rule remains:

> **finger moves → local history moves**

not:

> **finger moves → selection → network → remote media → UI**

---

## 3. Product invariants

These invariants outrank micro-optimizations and incidental test expectations.

### I-1 — The Main Feed is behaviorally continuous

If usable sources and network access exist, normal scrolling must not reach a hard end because the runtime failed to prepare future supply.

“Continuous” does not mean infinite memory or unbounded storage. It means the production system continuously creates enough future local supply that the user does not catch the producer under ordinary use.

A true exhaustion state is allowed only when the system can state why no additional eligible supply exists. Silence at the tail is not a valid exhaustion UX.

### I-2 — First paint is not completion

Publishing the first usable cards is the moment the user may begin consuming the feed. It is **not** the moment acquisition, admission, preparation, or persistence stops.

After first paint, the runtime should normally continue increasing future usable supply until its adaptive runway policy considers the context healthy or resource conditions require throttling.

### I-3 — Runway is adaptive capacity, not a page-size trick

Fixed card counts may exist as implementation bounds, database query limits, window sizes, or concurrency budgets. They must not become the product model.

The runtime must not reason that “N cards should buy enough time.”

Runway policy should respond to actual supply pressure and operating conditions, including where relevant:

- current presentation-ready supply;
- consumption velocity;
- acquisition latency;
- media-preparation latency;
- source availability and freshness;
- network cost/availability;
- memory/storage pressure;
- foreground/background state;
- reuse probability of recently active contexts.

The important distinction is:

> **bounded work does not mean bounded universe.**

Concurrency, active requests, decoded images, and materialized windows should be bounded. The set of sources the product can eventually explore must not be accidentally reduced to a small fixed prefix merely because work must be bounded.

### I-4 — Warm local state wins

If a valid published edition and its presentation assets exist locally, the user should be able to see them without waiting for OPML reconstruction, catalogue rebuilding, network acquisition, or a fresh selection pass.

Restoration and acquisition are separate concerns.

A warm restore should happen first. Future supply can be refreshed after the visible local state is available.

### I-5 — Published presentation is local

A published card must be renderable without network activity.

Publication must freeze enough presentation state that SwiftUI does not need to resolve protocol data, query canonical storage, fetch remote media, or negotiate acquisition.

A deterministic placeholder is valid when policy chooses to publish without an image. The renderer initiating network work is not valid.

### I-6 — Acquisition grows the future; it does not destabilize the present

Background acquisition, admission, media preparation, and selection must not silently reorder or replace what the user is currently navigating.

Refresh or an explicit context/revision transition may create a successor publication. It must not mutate the visible history as an incidental side effect of background work.

### I-7 — A user action reprioritizes future work without gratuitous destruction

A filter, preset, source, bookmark context, or other editorial change may require a new `EditorialRevision` or session context.

Changing direction should:

1. preserve the currently visible experience until the successor is usable when product semantics allow;
2. prioritize preparation for the new context;
3. preserve recently prepared/published contexts when useful and affordable;
4. make A → B → A cheap when A was just used;
5. allow pressure/retention policy to reclaim old contexts later.

The solution should prefer reusable published/local state over creating another cache or parallel preparation system.

### I-8 — There is one effective owner per responsibility

For any shipping surface, it must be possible to answer unambiguously:

- who owns acquisition;
- who owns selection;
- who owns media preparation;
- who owns publication;
- who owns session state;
- who owns presentation;
- who owns durable user state.

Compatibility code may continue to exist, but compatibility is not permission for two owners to perform equivalent work for the same visible surface.

### I-9 — Background uses the same acquisition architecture

There is no separate “background feed engine.”

Background execution produces bounded demand against the same effective acquisition owner and canonical admission path used by foreground execution. Only the budget/purpose changes.

### I-10 — Offline degradation is graceful

Loss of network reduces the rate at which future supply can grow. It should not destroy already published history or already prepared local supply.

The local runway is a product asset, not disposable staging.

### I-11 — Correctness is judged at the product boundary

A green component test is evidence that a component works under its tested contract. It is not evidence that the shipping product is wired correctly.

A subsystem that is perfectly tested but unused by the shipping path does not prove the product behavior it was intended to provide.

### I-12 — Complexity must earn its existence

Before adding a cache, timer, retry loop, generation counter, state machine, fallback, scheduler, queue, or new abstraction, identify:

1. the product invariant currently violated;
2. the existing owner that should satisfy it;
3. why the existing owner cannot be corrected;
4. why the new mechanism will not create a competing owner.

Prefer completing or simplifying an existing mechanism over creating a parallel one.

---

## 4. Architectural decisions that remain valid

The audit does **not** justify reopening the fundamental Runtime V2 architecture.

The following principles from the existing Blueprint/Runtime V2 remain the intended direction:

- external protocol heterogeneity ends at Admission;
- canonical local supply is the downstream source of truth;
- publication is immutable/append-oriented;
- `FeedSession` owns navigation of published history;
- SwiftUI consumes session/presentation state, not the acquisition engine;
- scroll never directly means fetch/load-more network work;
- media is local before rendering;
- SQLite owns durable facts;
- actors coordinate ephemeral work rather than becoming hidden databases;
- stale async work must not mutate newer state;
- publication history survives upstream raw/canonical retention;
- background work uses the normal acquisition architecture with a different budget;
- working sets are bounded;
- architectural ownership should be explicit and small.

The task is to make the shipping implementation obey these decisions end-to-end.

---

## 5. Audited current reality — `fb410634`

This section is intentionally descriptive. It records what the audited shipping tree does today, not what earlier status documents intended it to do.

### 5.1 `v2Full` is the shipping default

A fresh launch with no explicit rollback/test request resolves to Runtime V2 full acquisition + presentation.

This changed after the 6 October build-18 measurement work. Therefore measurements and fixes explicitly describing the legacy path as the 1.0 shipping path must be treated as historical evidence, not as proof of the current default path.

### 5.2 Legacy remains active inside the process

`FeedLoader` / `FeedStore` still initialize and continue to own important compatibility responsibilities, including catalogue/OPML state, taxonomy, legacy databases/user projections, secondary surfaces, page/cache behavior, and legacy media/preparation infrastructure.

The acquisition gate prevents the legacy Main Feed fetcher from being a second feed-acquisition owner under `v2Full`, but it does not remove the legacy runtime or all of its work.

This is migration state, not the desired end state.

### 5.3 Warm V2 restore is sequenced behind the legacy catalogue

The current Main Feed session startup waits for the loader catalogue before starting `V2FullRuntime`. The session's local edition restore occurs only after that start.

Therefore a valid local V2 publication can be delayed by legacy catalogue/OPML work that should not be required to display it.

This violates I-4 and is a release-critical architectural gap.

### 5.4 V2 acquisition watches a fixed launch prefix

Production `V2Acquisition` currently derives descriptors from a fixed prefix of the enabled-source catalogue (`launchWindow = 32` in the audited tree).

The underlying `AcquisitionFrontier` is designed and tested to keep active work bounded over very large catalogues. However, the production wiring bounds the candidate universe before the frontier sees it.

The issue is not “32 is too small.” The issue is that a concurrency/registration bound has become an accidental universe bound.

This violates I-3.

### 5.5 V2 scroll replenishment is local-page replenishment

`FeedSession` correctly coalesces viewport pressure and requests another page when the viewport approaches the current materialized tail.

However, the audited `performPage()` reads the next cards from the **same already-published edition**. When that edition has no more cards, the page result can be empty; that path does not itself acquire new supply and compose/publish a successor segment.

Therefore local page replenishment is not yet equivalent to continuous future-supply production.

This violates I-1/I-2.

### 5.6 The standalone Runtime V2 runway machinery is not proof of shipping runway behavior

Runtime V2 contains `RunwayController`, `RunwayEstimator`, policy, and extensive tests. The shipping Main Feed path observed in the audit is driven primarily through `FeedSession` viewport/page replenishment rather than a fully connected proactive runway loop.

Tests of the standalone runway subsystem therefore cannot be used as evidence that the shipping Main Feed continuously builds future supply.

### 5.7 Main Feed editorial/filter revision is not propagated end-to-end

The current filter UI mutates `FeedLoader` state. Runtime V2 correctly models content type/language/mood/taxonomy policy as editorial inputs rather than as the stable `ContextKey`.

However, `V2FullRuntime.start()` captures the resolved `FeedCompositionPlan` for the session, and the audited `MainFeedRuntime` observes source-catalogue mutation but does not provide an equivalent live path for a changed editorial revision.

The architecture contains the right concept (`EditorialRevision`); the shipping wiring does not yet carry the revision transition to the live session.

This violates I-7.

### 5.8 Background refresh is still wired to the legacy acquisition path

The app's background scheduler correctly avoids constructing a second `FeedStore`. It asks for the process's shared background owner.

However, that owner currently routes background demand through `FeedLoader`/`FeedStore` and the legacy fetch path. Under `v2Full`, the legacy acquisition gate closes that path.

The background mechanism therefore does not yet express its demand through the current V2 acquisition owner.

This violates I-9.

### 5.9 Main Feed media has overlapping legacy and V2 machinery

The audited tree contains a legacy prepared-media stack and a Runtime V2 media stack.

The legacy acquisition gate closes feed acquisition, not all legacy image/preparation activity. Therefore legacy media/preparation can remain alive while V2 is the visible Main Feed owner.

The long-term target is one Main Feed media-preparation owner. Compatibility surfaces may temporarily keep legacy media behavior where those surfaces still depend on it.

This is an ownership/consolidation problem, not a reason to introduce a third cache or broker.

### 5.10 Recently prepared contexts are only partially reusable

The legacy implementation persists first-page snapshots keyed by filter/composition signature, which can make some context returns cheap.

But the legacy in-memory prepared runway is centered on one active context and clears preparation state on context replacement.

Runtime V2's immutable editions/local assets provide the stronger long-term reuse primitive. The preferred solution is to make published contexts cheap to restore and retain, not to add another context cache.

### 5.11 Editorial policy exists in two implementations

The legacy and V2 `EditorialSequencer` implementations encode different sequencing/admission behavior.

The shipping project therefore does not yet have one unambiguous Main Feed editorial policy across all paths.

This should be consolidated when V2 owns Main Feed selection end-to-end.

### 5.12 `FeedStore` is a migration hotspot, not a target architecture

The audited `FeedStore.swift` is roughly 9,000+ lines and coordinates a large number of long-lived tasks, cancellation paths, scheduling loops, filtering, preparation, persistence, and compatibility behavior.

The development goal is **not** to rewrite or cosmetically refactor `FeedStore`.

The goal is to remove responsibilities from it as Runtime V2 proves ownership of those responsibilities end-to-end.

---

## 6. Ownership target

| Responsibility | Target owner | Audited state | Development decision |
|---|---|---|---|
| Main Feed acquisition | Runtime V2 acquisition | V2 owns shipping feed requests; legacy runtime remains active | **KEEP V2 / retire overlapping Main Feed legacy work** |
| Canonical admission | Runtime V2 storage/admission | V2 | **KEEP** |
| Main Feed future-supply pressure | Runtime V2 runway/demand | Concepts exist; shipping continuity is incomplete | **P0 COMPLETE WIRING** |
| Main Feed source exploration | Acquisition planner/frontier | Production pre-bounds universe to launch prefix | **P0 FIX** |
| Main Feed selection | Runtime V2 selection | V2 + legacy policy coexist | **P1 CONSOLIDATE** |
| Main Feed media preparation | Runtime V2 media | V2 + legacy preparation coexist | **P1 CONSOLIDATE** |
| Publication | Runtime V2 PublicationCoordinator | V2 | **KEEP** |
| Main Feed session/history | Runtime V2 FeedSession | V2 | **KEEP / extend continuity** |
| Warm restore | FeedSession + publication repository | Correct local primitive exists but startup waits for legacy catalogue | **P0 FIX** |
| Filter/editorial revision | Runtime V2 plan/session | UI mutates legacy loader; live V2 revision propagation incomplete | **P0 FIX** |
| Background acquisition | Effective Runtime V2 acquisition owner | Scheduler routes to legacy path | **P1 FIX** |
| Main Feed presentation | V2 presentation/session snapshots | V2 shipping owner | **KEEP** |
| Bookmark/user durable state | User-state authority + bridge | Mixed by migration design | **KEEP until migration closes** |
| Source Detail / Collections / Smart Feed / other compatibility surfaces | Legacy compatibility paths where still required | Legacy | **KEEP TEMPORARILY, explicitly scoped** |
| Legacy Main Feed runway/preparation | None under `v2Full` once V2 is behaviorally complete | Still partially alive | **RETIRE progressively** |

---

## 7. Development program

Development is ordered by behavioral importance, not by ease of implementation.

### P0 — Make the shipping Runtime V2 behaviorally complete

#### P0.1 Continuous feed production

Close the loop:

```text
viewport pressure
→ local published-page availability
→ runway/supply pressure
→ bounded acquisition demand if needed
→ Admission
→ Selection
→ Media Preparation
→ Publication
→ more local published history
→ FeedSession window
```

Reaching the end of the currently published edition must not be the terminal state when more eligible supply can be produced.

Do not solve this by increasing `cardLimit`, page size, or tail threshold.

#### P0.2 Explore the complete eligible source universe with bounded work

Remove the accidental equivalence between “sources registered in this launch window” and “sources the product can ever explore.”

Keep strict bounds on:

- concurrent target work;
- episode budget;
- network requests;
- host concurrency;
- memory;
- background execution.

Do not impose a permanent small-prefix bound on the catalogue.

Prefer a lazy/frontier/cursor mechanism that allows the acquisition owner to continue discovering eligible work as runway demand persists.

#### P0.3 Restore before catalogue bootstrap

Reorder Main Feed startup so a valid local published edition can be restored and presented before catalogue/OPML reconstruction and network acquisition are required.

After restore:

- catalogue initialization continues;
- acquisition refreshes future supply;
- the user keeps consuming the restored publication.

No new page cache should be introduced to solve this. Runtime V2 already has the correct durable publication primitive.

#### P0.4 Propagate editorial revisions

A filter/editorial change must resolve a new plan/revision and reach the active Runtime V2 session.

Desired behavior:

```text
A visible
→ user selects B
→ B becomes priority
→ A remains valid/visible until B is usable where appropriate
→ B publishes
→ session transitions
→ A's published local context remains reusable according to retention policy
```

A quick B → A return should not rebuild A from the Internet when a valid recent A publication already exists.

---

### P1 — Establish one owner for Main Feed work

#### P1.1 Background demand uses the effective acquisition owner

The scheduler should express bounded `backgroundMaintenance` demand to the same acquisition architecture that owns foreground Main Feed acquisition.

No second engine.

No special background fetch path.

#### P1.2 Stop hidden legacy Main Feed preparation under `v2Full`

Once the P0 Main Feed path is behaviorally complete, identify legacy work whose only purpose is preparing the Main Feed page that V2 already owns.

Disable/remove that work in `v2Full` without removing legacy functionality still required by explicit compatibility surfaces.

#### P1.3 Consolidate Main Feed media ownership

Runtime V2 media preparation should become the sole owner of media required by Runtime V2 publications.

Legacy media components remain only where named compatibility surfaces still need them.

Do not add another image cache, retry queue, or broker to bridge the two worlds.

#### P1.4 Consolidate editorial policy

Define one Main Feed editorial policy and make the V2 selection/publication path its authority.

Legacy compatibility surfaces may temporarily preserve legacy policy where required, but the Main Feed must not have two competing definitions of diversity/sequencing.

---

### P2 — Product experience and reuse

#### P2.1 Living cold-start experience

A true cold install cannot always be instantaneous. The product should communicate useful real activity without fabricating percentages or arbitrary completion numbers.

The loading experience may surface real locally known facts such as:

- sources being admitted/considered;
- recent publisher names;
- titles/media that have become presentation-ready;
- cards appearing into a staging preview as they become usable.

This is a presentation of real progress, not a substitute for fixing supply continuity.

#### P2.2 Context reuse

Use immutable local publications and prepared local assets as the reuse primitive.

Retain recent contexts opportunistically within storage/resource policy. Reclaim them under pressure.

Do not create another independent context cache unless the existing publication/retention model is proven insufficient.

#### P2.3 Offline runway quality

Measure and improve how much meaningful feed remains available after network disappears.

Optimization target: useful local continuity, not raw cached-item count.

---

### P3 — Simplify and remove

Only after the relevant V2 owner is complete and behaviorally proven:

1. identify legacy Main Feed responsibilities with no remaining shipping caller;
2. disable them in `v2Full`;
3. delete dead compatibility branches;
4. remove tests whose only contract was deleted machinery;
5. collapse duplicated policies/helpers;
6. reduce `FeedStore` by responsibility removal, not by file-splitting cosmetics.

The desired result is a smaller system because fewer things are responsible for the same outcome.

---

## 8. Rules for every implementation task

Before changing code, the implementer must answer:

### 8.1 Which product invariant is violated?

If no invariant or explicit release requirement is violated, the task is not automatically important.

### 8.2 Who owns the behavior?

Name the intended owner before coding.

If two components appear to own it, investigate ownership before adding behavior to either.

### 8.3 Is the proposed change completing an existing mechanism or creating another one?

Prefer completion.

Parallel mechanisms require explicit justification.

### 8.4 Does this improve the shipping path?

A test helper, shadow path, compatibility branch, or unconnected Runtime V2 component is not the shipping product.

Always identify the production caller.

### 8.5 Does the change preserve the visible publication?

Background work should normally increase future supply without destructively replacing what the user is currently navigating.

### 8.6 Is a number a bound or a product assumption?

Numbers used for:

- concurrency;
- memory;
- query limits;
- page materialization;
- backpressure;
- platform budget

may be necessary.

Numbers used as:

- “this many cards should last long enough”;
- “wait this many seconds then fetch”;
- “only ever consider this many sources”

require much stronger justification.

### 8.7 Are we solving the current architecture or yesterday's architecture?

Check the branch HEAD and effective shipping mode before using measurements or test evidence from an older runtime configuration.

---

## 9. Test strategy

The test suite has three roles and they must not be confused.

### 9.1 Component/contract tests

These prove local properties:

- Admission transaction behavior;
- Publication CAS;
- reducer transitions;
- frontier bounds;
- media identity;
- storage recovery;
- user-state semantics;
- connector translation;
- concurrency contracts.

They are necessary.

They do not prove shipping wiring.

### 9.2 Wiring/integration tests

These prove that the components the architecture relies on are actually connected in production composition.

Required examples:

- the production source universe can advance beyond the first launch window;
- exhausted published pages cause future supply production;
- filter/editorial revision reaches the live session;
- background demand reaches the current acquisition owner;
- warm restore occurs before catalogue/network dependency;
- Runtime V2 media preparation is the media used by the published Main Feed card.

### 9.3 Product behavioral gates

These determine whether the FeedMine experience is release-worthy.

The 1.0 gate should include at minimum:

#### G-1 — Continuous consumption across production boundaries

A long continuous scroll must cross multiple publication/supply episodes without reaching a false terminal end while eligible supply remains.

The test must prove more than “new IDs appeared after a swipe.” It must demonstrate:

```text
published tail exhausted
→ new supply episode
→ new publication
→ user continues
```

#### G-2 — Warm local restore

With a valid prior V2 publication:

- relaunch;
- local cards appear without waiting for OPML/catalogue/network;
- acquisition may continue afterwards.

#### G-3 — Cold start continues working after first paint

On a clean install:

- useful loading state is shown;
- first usable publication appears;
- after first paint, canonical/published future supply continues to grow;
- the user does not immediately catch the producer.

#### G-4 — A → B → A editorial context

Prepare A, move to B, return to A.

The return must reuse valid local A state where product semantics allow, rather than unnecessarily reconstructing it from remote sources.

#### G-5 — Offline continuation

Build runway, remove network, continue consuming local published/prepared content. The current publication remains stable.

#### G-6 — Background acquisition ownership

A background refresh must use the same effective V2 acquisition architecture, with bounded background budget, and must not create or awaken a competing legacy Main Feed acquisition tree.

#### G-7 — Renderer-local guarantee

Rendering/scrolling already published cards initiates zero network requests.

---

## 10. Release decision hierarchy

When signals conflict, use this order:

1. **Product invariant**
2. **Shipping-path behavioral evidence**
3. **Architecture/ownership contract**
4. **Integration tests**
5. **Component tests**
6. **Micro-benchmarks**
7. **Code-style/test-count cleanliness**

Examples:

- A feed that reaches a false end is a release blocker even if 647 tests pass.
- A 700 ms improvement in an isolated operation does not outrank a broken warm restore.
- A flaky test should not be “fixed” by changing valid product behavior merely to restore green.
- A component with excellent tests but no production caller should not influence release confidence as if it were shipping behavior.

---

## 11. What not to do

Until the P0/P1 ownership work is complete:

- do not create a third feed/runtime pipeline;
- do not create another Main Feed cache;
- do not create another runway implementation;
- do not make scroll call acquisition directly;
- do not fix continuity by simply increasing page/card limits;
- do not add arbitrary periodic fetch timers as the primary supply strategy;
- do not duplicate Runtime V2 fixes into legacy Main Feed merely because legacy code is easier to modify;
- do not rewrite `FeedStore` wholesale;
- do not delete compatibility code before naming the surface that still uses it;
- do not treat the 6 October legacy performance numbers as proof of the 7 October `v2Full` shipping path;
- do not optimize a subsystem merely because an agent found a measurable number to improve.

---

## 12. How legacy should disappear

Legacy retirement is incremental.

For each responsibility:

```text
1. Name the shipping behavior.
2. Prove Runtime V2 owns it end-to-end.
3. Add/repair the product behavioral gate.
4. Stop the equivalent legacy work in v2Full.
5. Observe the product.
6. Remove now-unreachable code.
7. Remove or rewrite tests that protected the deleted path.
```

Do not begin with a global dead-code purge.

The most valuable deletions will come from eliminating duplicate responsibility, because entire clusters of timers, queues, caches, retries, state, and tests can then disappear together.

---

## 13. Definition of development success

FeedMine 1.0 development is converging when all of the following become true:

- the shipping Main Feed has one acquisition owner;
- one selection/editorial authority;
- one media-preparation authority;
- immutable local publication as the presentation boundary;
- a FeedSession that can consume indefinitely while supply can still be produced;
- warm restore independent of catalogue/network bootstrap;
- adaptive future-supply preparation rather than tail panic;
- bounded work over the complete eligible source universe;
- filter/context changes that reprioritize instead of unnecessarily destroying useful local state;
- background demand using the same acquisition architecture;
- compatibility paths explicitly named and shrinking;
- product behavioral gates capable of failing even when hundreds of component tests remain green;
- `FeedStore` becoming smaller because responsibilities leave it.

The project is **not** successful merely when every test is green.

It is successful when a developer can explain the active Main Feed on one page, identify exactly one owner for each stage, and the observable app behaves according to that explanation.

---

## 14. Immediate authorized work

Unless new evidence invalidates this audit, development should proceed in this order:

1. **P0.1 — close the continuous-feed production loop in Runtime V2.**
2. **P0.2 — replace the fixed source-universe prefix with bounded exploration of the complete eligible catalogue.**
3. **P0.3 — restore local V2 publication before legacy catalogue/bootstrap.**
4. **P0.4 — propagate filter/editorial revisions to the live V2 session.**
5. Add the corresponding **product behavioral gates**.
6. Route **background acquisition** to the effective V2 owner.
7. Disable **overlapping legacy Main Feed preparation/media work** under `v2Full`.
8. Consolidate Main Feed media and editorial policy.
9. Improve context reuse and cold-start presentation.
10. Remove legacy code only after reachability and behavioral evidence make the deletion safe.

Each step should preferably reduce ambiguity or ownership overlap. A change that adds another mechanism without removing or completing an existing one should be treated with suspicion.

---

## 15. Source hierarchy

For current development decisions, use this hierarchy:

1. **This document — Product & Runtime Development Contract**
2. Current audited shipping code and reproducible behavioral evidence
3. Unified Architecture Blueprint v0.4 + ADRs
4. Runtime V2 Technical Architecture
5. Current measurement reports
6. Release/status/handoff documents
7. Historical implementation notes

Older documents remain valuable evidence. They do not override a newer audited shipping state merely because they were once marked “closed” or “proven.”

When this contract itself becomes stale, update or supersede it explicitly. Do not let development silently diverge from it.

---

# One-sentence contract

> **FeedMine presents stable local history while continuously and adaptively preparing future local supply; every development decision should make that behavior more complete, simpler, and more clearly owned.**