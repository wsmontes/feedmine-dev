# Runtime V2 Phase 2 — Release Status

**Baseline:** `fix/release-1.0-final-hardening`  
**Updated:** 2026-09-28  
**Execution rule:** unexecuted Apple/device tests are prepared and marked pending; they are never reported green.

## Surface matrix for 1.0

| Surface | 1.0 route | Acquisition in v2Full | Reason / closure |
|---|---|---|---|
| Main Feed | Runtime V2 session | Runtime V2 | complete |
| Bookmark Box | Runtime V2 adopted session; legacy page only while awaiting first snapshot | none of its own | handoff regression prepared in `MainFeedRuntimeV2Tests` |
| Search — canonical content | canonical runtime index + runtime user-state overlay | none for local search | overlay implemented; regression prepared |
| Search — Saved | compatibility read | none | user.sqlite/feedmine.sqlite remain authority during compatibility window |
| Last Clicked | compatibility page | legacy network refused | retained legacy membership has no canonical selector; do not invent one for 1.0 |
| Source Collection | compatibility page | legacy network refused | collection membership has no canonical projection |
| Smart Feed | compatibility page | legacy network refused | exact retained-membership parity would require new editorial selection semantics |
| Source Detail | compatibility page | legacy network refused | runtime SourceID allocation exists, but the separate sheet has no runtime session lifecycle |
| Onboarding | compatibility showcase | bounded existing path | intentional 1.0 product exception |
| Persistent Search | no card view | n/a | non-blocker |
| What's New | no card view | n/a | non-blocker |
| Catalogue Browse | local catalogue | n/a | intentionally outside feed runtime |
| Reader / Audio | explicit action | explicit-action network | intentionally outside feed acquisition |

## Work completed in this phase

- PR-16 publication invariant closed: a card from another editorial revision is rejected before commit.
- Bookmark Box surface handoff behavior pinned: compatibility rows remain only until the adopted context publishes; the snapshot then owns the surface.
- Runtime user-state projection gained one bounded asynchronous batch read for overlays.
- Canonical Search now applies bookmark/read overlay from runtime state.
- V2-only Search hits derive the same durable subject as `RuntimeCardUserActions`; the display-only `origin:*` id never becomes user-state identity.
- Canonical Search overlay regression prepared without introducing network.

## Compatibility invariants

A compatibility surface is acceptable for 1.0 only while all of these hold:

1. `LegacyAcquisitionGate` refuses its feed fetches in `v2Full`; local retained reads remain allowed.
2. It cannot replace or publish into the Main/Bookmark runtime session.
3. Its view may perform explicit reader/audio actions, but rendering itself does not become a feed acquisition owner.
4. User state continues to be authoritative in the stores defined by ADR-004.
5. The release matrix names the exception and its post-1.0 migration trigger.

## Tests prepared but not executed in this environment

- `MainFeedRuntimeV2Tests.testAdoptedBookmarkContextHandsTheSurfaceToItsSessionSnapshot`
- `SurfacePlanMigrationTests.testCanonicalSearchAppliesRuntimeUserStateOverlay`
- existing Runtime V2 package/app plans, including the publication-revision regression added immediately before Phase 2.

Required commands on the Apple checkout:

```sh
swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm
bash scripts/verify-runtime-v2-boundaries.sh
xcodebuild test -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd
```

## Physical-device release gate — pending execution

Use a Release build and record the environment/device/dataset. Capture warm restore, cold bootstrap,
surface switch, MainActor snapshot apply, scroll hitch, placeholder rate, memory high-water, DB/media
disk footprint, acquisition requests/bytes/hosts, background expiration, offline restore and integrity.

Repeat clean install, upgrade from the supported previous release with a real container, crash/relaunch
at Admission and Publication/media boundaries, disk-full recovery and rollback.

No numeric result is recorded until measured.

## Phase 2 disposition

Implementation-critical 1.0 work that can be completed statically is closed or prepared. The remaining
unexecuted release gate is environmental (Apple simulator/device), and the remaining secondary surfaces
are explicit compatibility exceptions rather than unfinished Runtime V2 semantics.

The next engineering phase is **application release closure**: audit the whole shipping app for compile-risk,
dead/inconsistent feature paths, launch/configuration/privacy/localization/App Store readiness and product
scope. It must not reopen Runtime V2 architecture unless that audit finds a release blocker.
