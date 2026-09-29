# FeedMine Runtime V2 — Phase 2: Surface Convergence & Release Closure

**Date:** 2026-09-28  
**Branch baseline:** `fix/release-1.0-final-hardening` @ `6953f4955b0f6c3b5c71c920528ca20b3dde4593`  
**Status:** execution plan  
**Goal:** close the remaining product/runtime integration gaps without redesigning Runtime V2, then produce the evidence required to ship.

## 1. Why this is a new phase

The architectural build-out is no longer the critical path. Runtime V2 already has canonical supply, immutable publication, session/windowing, media preparation, runway/acquisition ownership, recovery, retention, metrics, background handling and the Main Feed production path. The Sacred Feed path is also closed: a published visual reaches presentation as prewarmed local pixels or a deterministic placeholder; the renderer does not fetch.

The remaining work is **convergence and proof**:

1. move the remaining *shipping card surfaces* onto the runtime where the required identity/content path already exists;
2. make the remaining identity/overlay decisions explicit where it does not;
3. preserve legacy fallback until each surface has evidence;
4. run the final upgrade/rollback/device/performance gates;
5. remove only the legacy code whose replacement has actually been proven.

This phase deliberately does **not** reopen Runway, Admission, Publication, media architecture, connector architecture, background ownership or the canonical supply model unless a failing acceptance test demonstrates a defect.

## 2. Baseline facts

At this baseline:

- Main Feed is runtime-owned in `v2Full`, including acquisition and session presentation.
- Bookmark list membership is already projected into runtime storage (`v7_user_list_membership`), the app writes/reconciles that membership, and `SubjectSelection.savedSubjects(kind:listKey:)` can select one box.
- Bookmark selection adoption already occurs; device evidence showed the session composing the box correctly, while the screen continued drawing the legacy page. The remaining Bookmark defect is therefore the **surface handoff**.
- Smart Feed, Last Clicked and Source Collection still draw retained legacy content and need the shared content/card-identity lane before they can safely become session surfaces.
- Source Detail cannot yet resolve a runtime plan because a durable runtime `SourceID` must be allocated/mapped; deriving identity from URL/catalogue id is forbidden.
- Canonical local Search exists in `v2Full`, but canonical hits do not yet carry the complete read/bookmark overlay and Saved search still reads legacy storage.
- Persistent Search and What's New have no shipping card view to migrate. They are not release blockers unless product scope changes.
- Onboarding is a deliberate product/lifecycle decision, not automatically a runtime migration.
- PR-16 instrumentation exists, but Release-build physical-device SLO evidence is still missing.
- The latent publication invariant reported by PR-16 has now been fixed and regression-covered in commits `ae1f0ce` and `6953f49`.

## 3. Phase rules

1. **No new architecture.** Prefer wiring, identity projection and deletion over new abstraction.
2. **One runtime, one acquisition owner.** A migrated surface may not create another feed engine or transport.
3. **Surface switch only after content equivalence.** Never point a view at a session that cannot select the content its label promises.
4. **Fallback is per surface.** A failing secondary migration falls back to that surface's existing legacy page; it must not contaminate Main.
5. **No renderer network.** A surface migration cannot reintroduce image/network loading in SwiftUI.
6. **History semantics remain explicit.** Main `seen` exclusion must not make Bookmark/Source/Search/Last Clicked history disappear.
7. **No removal by aspiration.** Legacy code is deleted only when its replacement has automated tests plus device evidence where required.
8. **No GitHub Actions work in this phase.** Existing CI configuration is not a dependency for the implementation sequence; validation is performed through the package/app gates and recorded evidence.
9. **Release scope beats completeness.** Surfaces with no consumer do not block 1.0.

## 4. Workstreams and order

### P0 — Re-baseline and protect the branch

**Objective:** make `6953f49` the explicit Phase 2 baseline and prevent stale documentation from driving implementation.

Tasks:

- Record the new baseline in rollout/baseline documentation.
- Mark the PR-16 editorial-revision write-path gap as closed by `ae1f0ce` + `6953f49`.
- Re-run/static-check the runtime boundary gate and package tests when an Apple/macOS checkout is available.
- Add a small release-closure checklist that points to the evidence artifacts rather than duplicating them.

**Exit:** no known architectural gap is being mistaken for an unimplemented feature; open work is represented by this plan.

---

### P1 — Bookmark Box surface handoff

**Objective:** make Bookmark Box the second real runtime-driven card surface.

This is first because the difficult storage/selection work is already done. Device evidence already showed that opening a box changes the runtime selection and produces the correct box snapshot; the view simply kept drawing its legacy page.

Tasks:

- Change the feed surface routing so an adopted Bookmark Box selection renders `MainFeedPresentationPipeline` / session rows when the session context matches.
- Preserve the existing legacy Bookmark page as fallback when no valid session surface exists.
- Ensure loading/empty/error statements come from the session for the adopted box, not from the Main Feed or stale legacy counters.
- Ensure closing/switching the box changes the session stamp/context and cannot accept an older snapshot.
- Preserve bookmark-list actions and list identity.
- Verify that opening a box does not restart process-wide acquisition.
- Add app tests for: box opens → session rows; box A → box B; box → Main; stale snapshot rejection; empty box; legacy fallback.
- Device proof: open a populated box and an empty box, scroll, leave/re-enter, background/foreground.

**Exit:** Bookmark Box visibly renders the exact runtime session selection with no duplicate fetch and no Main Feed contamination.

---

### P2 — Durable card identity + user-state overlay lane

**Objective:** give secondary surfaces and canonical Search one durable way to refer to the same card/user state.

Tasks:

- Audit the existing `legacy_item_map`, publication IDs and `UserStateBridge` and define the minimum mapping needed from retained legacy subject → canonical origin → published occurrence.
- Do **not** make the deterministic legacy bridge ID authoritative. Runtime `PublicationCardID` remains allocated by publication.
- Add/read the projection needed for canonical hits and runtime-presented retained subjects to expose bookmark/read/opened state.
- Make overlay application independent of the surface: Search, Bookmark, Last Clicked and later surfaces consume the same projection.
- Prove that toggling bookmark/read updates authority first and converges to runtime/legacy projections without rewriting immutable publication.
- Cover alias-missing, canonical-record-missing and old-upgrade-container cases explicitly.

**Exit:** one subject can cross Main/Search/Bookmark/history without changing identity semantics or losing user-state overlay.

---

### P3 — Retained-content secondary surfaces

**Objective:** migrate the secondary surfaces whose content is already representable after P2.

Order:

1. **Last Clicked** — local retained history, no acquisition needed.
2. **Source Collection** — durable collection key already exists.
3. **Smart Feed** — migrate only after proving its membership/selection semantics match what the runtime can state.

For each surface:

- add/confirm explicit `FeedPlan.subjectSelection`;
- start/adopt a session for that selection;
- render session rows only when context matches;
- preserve per-surface history policy;
- keep legacy fallback until device proof;
- ensure acquisition demand remains owned by the existing runtime owner;
- test transitions between Main and every migrated surface, not only cold entry.

**Smart Feed stop condition:** if its legacy retained-membership semantics cannot be expressed without adding a new editorial subsystem, keep Smart Feed on the compatibility path for 1.0 and document it. Do not redesign the runtime to force parity.

**Exit:** each accepted surface has content-equivalence tests, transition tests and no duplicate acquisition.

---

### P4 — Source identity decision and Source Detail

**Objective:** remove `runtimeIdentityUnavailable(.source)` correctly.

Decision to implement:

- Runtime allocates an opaque durable `SourceID` for a catalogue source through an explicit persisted mapping.
- Catalogue id / URL / endpoint is evidence or mapping input, never the `SourceID` itself.
- Endpoint changes must preserve the allocated Source identity when the editorial source is the same.
- Ambiguous mappings refuse composition rather than merging sources heuristically.

Tasks:

- add migration/repository operation for catalogue-source ↔ runtime-source mapping if the existing source mapping cannot already express it;
- reconcile existing enabled sources at startup/import;
- make `SurfaceContextAdapters` resolve Source Detail using the allocated runtime identity;
- migrate Source Detail presentation/session lifecycle;
- prove endpoint change preserves source history and Source Detail content;
- prove two endpoints may belong to one Source without duplicate editorial identity.

**Exit:** Source Detail resolves a runtime plan without URL-derived identity and renders through the shared runtime.

---

### P5 — Search convergence

**Objective:** make Search coherent without forcing unrelated search modes into one database.

Tasks:

- Apply P2's overlay to canonical local-content hits.
- Preserve explicit distinction between canonical Content search and Saved/bookmark search while their authorities differ.
- Ensure opening a canonical result resolves the same durable card/action semantics used by feed presentation.
- Verify no network is started by local Search.
- Keep online content sweep as explicit user-initiated acquisition demand, not an implicit search-render side effect.
- Add mixed-state tests: canonical hit bookmarked/read/opened; alias unavailable; empty canonical database; upgrade container.

**Exit:** Search results do not lose user state or invent a second card identity, and local Search remains network-free.

---

### P6 — Explicit non-blockers / product cuts

These do not block 1.0 unless a shipping view starts consuming them:

- **Persistent Search:** matching may remain runtime/legacy plumbing; no card view exists.
- **What's New:** fetch path may remain compatibility plumbing; no card view exists.
- **Catalogue Browse:** intentionally outside feed runtime; it composes no cards.
- **Reader / Audio:** remain explicit-action network categories.
- **Onboarding:** default Phase 2 decision is **keep the existing showcase compatibility path for 1.0** unless a concrete defect requires migration. Revisit after release.

Document these as intentional scope, not forgotten migrations.

---

### P7 — Compatibility-window and legacy-removal pass

**Objective:** remove only code made unreachable by P1–P5.

Tasks:

- inventory legacy feed producers/readers again after surface migrations;
- delete per-surface acquisition paths that are provably unreachable under `v2Full`;
- keep rollback mode and data needed by the defined compatibility window;
- remove bridge code only when no shipping surface or upgrade/rollback rehearsal uses it;
- run boundary/network inventory after each deletion batch;
- update rollout matrix from “route today” to final ownership.

**Do not delete yet:** legacy schema/data required to open the supported previous release or execute rollback rehearsal.

**Exit:** no dead duplicate acquisition path remains in `v2Full`; compatibility code that remains has a named reason and removal trigger.

---

### P8 — Release evidence and SLO gate

**Objective:** turn “works in architecture/tests” into “safe to publish”.

Required environment: Release build, supported minimum physical device, declared dataset and sampling.

Capture:

- warm restore time;
- cold recovery/bootstrap to first valid publication;
- context/surface switch latency;
- MainActor snapshot apply;
- scroll hitch/jank while runway refills;
- placeholder rate and missing-published-bytes fallback;
- memory high-water;
- runtime DB + media disk footprint;
- acquisition counts/bytes/hosts for bootstrap and active runway;
- background expiration/cancellation;
- shadow/parity drop count if shadow remains in the build;
- integrity/FK/uniqueness report after stress/relaunch.

Also repeat:

- clean install;
- upgrade from the supported previous release using a real legacy container;
- kill/relaunch during Admission;
- kill/relaunch during Publication/media commit boundary;
- disk-full recovery;
- database-corruption/quarantine path;
- background/foreground;
- offline warm restore;
- rollback to the supported legacy mode without data loss.

**Important:** do not invent thresholds that have not been approved. Record measured values first. Any new release threshold must be explicitly accepted and documented.

**Exit:** evidence bundle is complete; no integrity violation; no release-blocking regression.

## 5. Release blockers vs post-release

### Must close before 1.0

- P1 Bookmark Box surface handoff.
- P2 durable identity/user-state overlay sufficient for shipping migrated surfaces and Search.
- P3 only for secondary surfaces that are part of the 1.0 navigation promise; otherwise explicitly compatibility-scoped.
- P4 Source identity if Source Detail is a 1.0 runtime-owned surface; otherwise it remains an explicit compatibility exception.
- P5 canonical Search overlay.
- P7 duplicate-owner/dead-path cleanup sufficient to guarantee one acquisition owner.
- P8 upgrade/rollback/device/integrity evidence.

### May ship as compatibility exceptions

- Smart Feed presentation, if exact retained-membership parity would require new architecture.
- Source Detail, until opaque SourceID mapping is implemented, provided its legacy path cannot acquire in conflict with V2 ownership.
- Onboarding showcase.
- Persistent Search UI (none exists).
- What's New UI (none exists).

Compatibility exceptions must be visible in the release matrix and must not violate single-owner acquisition, data integrity or renderer-network invariants.

## 6. Test matrix

Every migrated surface must pass the same minimum matrix:

| Case | Required proof |
|---|---|
| cold open | correct context, cards and loading state |
| warm restore | same edition/card identity; no network needed to draw retained history |
| Main → surface | new session/context; no Main cards leak |
| surface → Main | Main session resumes/recomposes correctly |
| surface A → surface B | stale A snapshot refused |
| empty | explicit empty state, no endless spinner |
| offline | retained publication remains navigable |
| bookmark/read/open | overlay is correct and durable |
| fast scroll | viewport signal only; no direct load-more/network from view |
| background/foreground | checkpoint/session remains coherent |
| acquisition | no duplicate target request |
| media | local bytes or deterministic placeholder; renderer network = 0 |

## 7. Commit slicing

Keep commits small enough to revert independently:

1. `docs(runtime-v2): baseline phase 2 release closure`
2. `fix(runtime-v2): hand bookmark box surface to session`
3. `test(runtime-v2): cover bookmark surface transitions`
4. `feat(runtime-v2): project canonical card user-state overlay`
5. `test(runtime-v2): cover cross-surface identity and overlay`
6. one production + one test commit per additional surface
7. `feat(runtime-v2): allocate durable source identities`
8. `fix(runtime-v2): apply user-state overlay to canonical search`
9. legacy cleanup in narrowly scoped deletion commits
10. release-evidence/documentation commits only after the measured runs

Do not squash evidence-bearing milestones until release sign-off; individual rollback points are useful during this phase.

## 8. Definition of done

Phase 2 is done when all of the following are true:

- Main and every **declared 1.0 runtime-owned card surface** render through a context-correct session.
- Any compatibility surface is explicitly listed and cannot create duplicate acquisition.
- Published cards remain immutable and restore without canonical joins.
- User-state overlays converge without rewriting publication.
- Source identity, where migrated, is opaque and durable.
- Renderer network remains zero.
- Runtime acquisition has one owner per target, including background.
- Clean install, real upgrade, crash, offline and rollback rehearsals pass.
- Package/app/boundary gates are green in the declared validation environment.
- Release-device SLO measurements are recorded rather than estimated.
- Integrity checks report no violations.
- Legacy removal is limited to paths whose replacement has evidence.
- The release matrix tells a maintainer exactly what is V2, compatibility, intentionally outside, or post-1.0.

## 9. Immediate execution order

Start with **P1 Bookmark Box**. It is the highest-value/lowest-risk closure because its canonical selection,
list membership projection, app write/reconciliation and session adoption already exist. The known failure is
at the final rendering handoff, and fixing it gives the project a second real runtime surface before touching
the harder identity lane.

After P1, execute **P2**, then reassess P3 surface-by-surface using the stop conditions above. P4 and P5 can
proceed after P2. P7 follows the last accepted surface migration. P8 is the release gate, not a substitute for
the earlier tests.
