# PR-16 — Retention, recovery and hardening: report

Owner: the PR-16 slice. Scope: `Packages/FeedRuntimeV2/**` and `docs/runtime-v2/**`.
Every number below was measured on this tree; every claim that is not measured says so.

## 1. What landed, item by item

### 1.1 The retention coordinator, and the decision on the durable tables

**Decision: the durable tables are needed, and they were created** (migration `v6_retention_schema`).

Grounds, checked rather than asserted:

- ADR-004 D8 requires retention to be "expressed as limits per class that run before any collection, plus
  GC by mark/sweep or transactional refcounts with periodic reconciliation", and D4 keeps GC state
  durable ("asset versions and GC state"), so an in-memory report cannot answer *did GC run, when, in
  which mode, and what did it take* after a relaunch — the exact gap baseline §8.18.1 names.
- ADR-004's `OPEN` item forbids inventing numeric budgets: the knobs must arrive by measurement on the
  minimum device. A table with nullable limits lets a build have *no* declared limit instead of a
  hardcoded one, and an absent row is refused rather than read as unlimited.
- The schema already had the same shape twice: `exposure_policy` (`RuntimeMigrations.swift:578` before
  this slice) and `history_policy` (`:656`) are declared-policy tables whose absent rows are refused.

What was created:

| Table | What it holds |
|---|---|
| `retention_policy` | one row per class: `max_age_seconds`, `max_bytes`, `max_editions`, all nullable, with a `CHECK` that at least one is present, so "declared but unlimited" cannot be stored |
| `gc_run` | one row per run: `mode` (`mark_sweep` \| `refcount_reconcile`), `outcome` (`completed` \| `aborted`), start/finish, `detail` |
| `gc_run_class` | the per-class result of one run: `collected`, `protected`, `freed_bytes`, `orphans_collected`, `skipped` |

`MigrationTests.laterSlices` lost both names (`retention_policy`, `gc_run`) and they moved into the
must-exist list, together with `gc_run_class`; `asset_pin` stays absent with its existing owner note. The
change records the decision in the test rather than hiding it in a diff.

**The coordinator** is `FeedStorage/Retention/RetentionCoordinator.swift`, with the class vocabulary, the
policy store and the root provider in `Retention/RetentionPolicy.swift`.

- **Order** (`RetentionClass.collectionOrder`, cheapest-to-recover first): decoded cache → publication →
  unpublished downloads → published asset bytes → projections → connector evidence → canonical supply →
  WAL → diagnostics → durable user state. `publication` runs *before* `publishedAssetBytes` so bytes whose
  last reference this run released are collectable in the same run; both run before `canonical supply`,
  because bytes can be fetched again while canonical rows must be re-admitted.
- **Classes that are never collected are still classes.** `durable_user_state` has no policy knob and
  `RetentionPolicyStore.declare` refuses one; a run reports it as skipped, so "GC ran" cannot quietly mean
  "GC looked at the user's rows". `diagnostics` (the shadow lane's bytes) and `wal_and_journal` are the
  same shape of statement.
- **Roots are read inside the collection transaction.** `RetentionRootProviding.roots(in: Database)` is
  called with the same `Database` the deletion uses, so SQLite's write lock orders them: a pin committed
  before the transaction is honoured, and one committed after belongs to a run that had already decided.
  `testRootsAreReadFromTheSameTransactionThatTakesTheRows` fails on a provider that refuses to answer
  outside a transaction, which is what a "read the roots first, delete later" implementation does.
- **The bookmark root is a proxy, and it is named as one.** `user.sqlite` is the authority for bookmark
  rows (ADR-004 D7) and this package cannot read it. `BookmarkSubjectProviding` is the port through which
  the composition hands the authoritative saved subjects over, and `SqlRetentionRootProvider` unions them
  with the runtime's own projection — neither alone is the safe set. `GCRunReport.bookmarkRootSource`
  records which of the two worlds the run actually consulted, so a run's account cannot imply the
  stronger one. `testABookmarkTheRuntimeProjectionHasNotSeenStillProtectsItsEdition` proves both halves:
  with the authority attached the edition survives, and without it the same fixture loses it.
- **Reconciliation collects nothing and fixes nothing.** `refcount_reconcile` re-derives every root and
  reports blockers: bytes removed from under a retained card, a card whose revision was collected, a
  purged edition a root points at, a saved item with no durable mapping.
  `testPinsBlockCollectionUnconditionallyAndReconciliationReportsALostPin` produces the failure the ADR
  cares about — the sweep cannot see the publication pin, takes the bytes, and reconciliation reports
  `published bytes removed while a retained card names them: 1` — while the card keeps its identity and its
  frozen media reference.
- **Age-based collection uses a stored watermark plus a suspension.**
  `runtime_metadata['retention_clock_high_water_ms']` only ever moves forward; a wall clock behind it is a
  rollback and the run *suspends* age-based classes instead of deciding from it.
  `testAgeRetentionUsesAStoredWatermarkAndSuspendsOnARewoundClock` asserts the stored watermark, the
  suspension (nothing evicted), that the watermark is never lowered, and that expiry resumes when the
  clock catches up. Suspension is the point: an age computed from a rewound clock either evicts rows that
  were just written or keeps expired ones forever, and neither is recoverable once the rows are gone.
- **The account**: `gc_run` + `gc_run_class` in one transaction, `runtime_metadata['last_gc_revision']`
  always, `['last_purge_revision']` when the run removed canonical supply or connector evidence. Neither
  is a migration counter: `runtime_schema_version` stays absent (`MigrationTests`).
  `testAFailingRunIsRecordedAsAbortedRatherThanAsNeverHavingHappened` covers the abort path.

**Tested under continuous supply (PR-16 item 1's own sub-clause).**
`testSupplyArrivingBetweenRunsIsNeverTakenAndAPinReleasedLaterIsCollectedInThatRun` runs GC twice
against supply that *arrives* rather than supply that merely exists:

1. between the runs the fixture admits a real batch through `AdmissionEngine` (two revisions
   through the runtime's own path) **and** inserts an age-eligible record directly, whose timestamp is old
   while its arrival is new — the row a run that decided from a candidate list alone would take. After the
   second run every record, revision and supply row is still there, and the arriving record's supply row
   is still one;
2. two successors are published between the runs, so the edition that pinned the asset becomes a purge
   candidate under the declared edition limit. The second run purges it **and** collects the bytes it
   released, in that run: the asset goes to `bytes_removed` and the media port is asked for its digest.
   This is the discriminating claim — a coordinator that snapshots its roots once per run keeps the bytes
   protected for a run that never comes, and the test fails on exactly that;
3. the account holds two `gc_run` rows with distinct ids, a full `gc_run_class` set for each, and
   `last_gc_revision` equal to the second run — advancing, not rewritten in place. The publication
   aggregate still passes integrity/FK/uniqueness.

Falsified rather than argued: moving `publishedAssetBytes` ahead of `publication` in
`RetentionClass.collectionOrder` makes the test fail with
`("Optional("committed")") is not equal to ("Optional("bytes_removed")")` and
`("[]") is not equal to ("["dddd…dddd"]")` — 1 test, 2 failing assertions. The order the test defends is
the order the report claims.

**The two collectors were reused, not replaced.** `MediaRetentionCollector` (FeedMedia) is the production
conformance to `RetentionMediaCollecting` (FeedDomain) and calls `DecodedImageCache.trimToLimits()` +
`collectUnpinnedEntries()`, `LocalAssetStore.remove(_:)` and `collectOrphanTemporaryFiles()` — limits
before collection, which is D8's rule. The port exists because `FeedStorage` may not see `FeedMedia`
(plan §3): the coordinator decides, the media module deletes.

### 1.2 `evidencePurgePreservesBookmarksAndHistory` (contract-matrix row 33, DoD item 8)

`FeedStorageTests/RetentionCoordinatorTests.testEvidencePurgePreservesBookmarksAndHistory`.

The fixture makes the purge *want* the edition a bookmark depends on: four editions of one context are
activated in order, three end up superseded, and the declared limit keeps one. The keeper is the newest
superseded edition; the older two would both go on count alone. One of them holds the card of a saved
item, so it must survive — and the assertion is the **reachability** of the card, not the number of
editions left:

- the saved article is still published in a retained edition (`published_card → feed_edition WHERE
  state <> 'purged'` returns exactly one row), with its frozen payload and media identity intact;
- the durable mapping a rebuild re-resolves is untouched, and `savedSubjects(kind: .bookmark)` still
  answers;
- the *unprotected* older edition is the one the limit takes, so the protection is not a shifted count;
- connector evidence past its age went, the recent one stayed; the superseded canonical revision went,
  the current revisions stayed;
- pins blocked collection unconditionally: the retained card's asset stays `committed`, the unreferenced
  cached asset went to `bytes_removed` and its bytes were handed to the media port by digest;
- `history_projection` survived the purge (ADR-007 D10), exposure facts of the purged edition did not
  (they name its cards);
- the publication aggregate still passes `integrity_check`, `foreign_key_check` and both uniqueness
  rules, and the run reports no blockers.

The bookmark is created through **both** worlds — the authoritative port and the runtime projection — and
the reachability is asserted after the purge, so the test cannot pass on the proxy's opinion alone
(`bookmarkRootSource` is asserted too).

### 1.3 The crash class (§15.1), which was absent

`FeedStorageTests/CrashTerminationTests.swift` + the `FeedStorageProbe` executable target
(`Probes/FeedStorageProbe`, a test helper, not a module of §3's table — see §4).

Each test spawns a real process, waits for its boundary line on stdout, **asserts it is still running**,
sends `SIGKILL`, asserts `terminationReason == .uncaughtSignal` and `terminationStatus == SIGKILL`, and
only then reopens the database and validates:

| Boundary | What the child did | What the reopen proves |
|---|---|---|
| after commit | admitted a batch through `AdmissionEngine`; the transaction committed and nothing after it ran | content, checkpoint (0→1), supply generation and the batch row are durable; the receipt is readable from the ledger, which is the lost-response path ADR-006 D2 requires; `integrity_check=ok`, `foreign_key_check=0` |
| holding an open transaction | committed batch 1, then wrote batch 2's identity/record/revision/batch-row **and** the checkpoint advance inside `BEGIN IMMEDIATE`, and held it | batch 1 survives in full; batch 2 leaves nothing — not its revision (`headline = 'Probe held'` count 0), not its batch row, and not its checkpoint advance (still 1). The checkpoint never runs ahead of committed content |
| between the file write and the move | wrote and fsynced a `LocalAssetStore` temporary file and never moved it | no `asset_version` row names those bytes, the destination does not exist, the orphan is present, and `LocalAssetStore.collectOrphanTemporaryFiles()` reclaims it with no bookkeeping |

**The tests assert the death, not that the code ran** — proven by falsification: with the child exiting
instead of holding, all three tests fail with `(NSTaskTerminationReason(rawValue: 1)) is not equal to (2)`
and `(0) is not equal to (9)` — 3 tests, 6 failing assertions. The signal, not the run, is the evidence.

### 1.4 The failure-seed capture and its replay command

`FeedStorage/Diagnostics/FailureSeedCapture.swift` (`CapturedFailure`, `FailureSeedCheck`,
`FailureSeedCapture`, `FailureSeedCapturing`, `FailureSeedReplay`) with its real caller in
`FeedRuntime/Session/FeedSession.swift`.

- **The caller.** A restore refused for `payloadCorrupted` or an incompatible publication schema is a
  deterministic check failing in production. The session writes the failing input through the optional
  `failureCapture` port: the edition's **seed**, the context, the edition, the epoch, the editorial
  revision, the publication schema version, the card identities, the check, the expected and observed
  kinds, and the database path. Recording is best effort and cannot change the refusal.
  `RestoreRefusalCaptureTests` (3 tests) asserts the artifact's fields against the edition and asserts a
  session with no port writes nothing.
- **The artifact carries no URL and no published content** — asserted on the file's own bytes
  (`testTheArtifactCarriesNoURLAndNoPublishedContent`), because the plan forbids signed URLs and publisher
  content in anything a run leaves behind.
- **The replay is a command, not a description**: `FailureSeedCapture.replayCommand(artifact:)` prints
  `FEEDMINE_REPLAY_SEED=<artifact> swift test --package-path Packages/FeedRuntimeV2 --filter
  FeedStorageTests.FailureSeedReplayTests`. The filter's spelling matters: `Target/Class` selects nothing
  and exits 0, which is the false green this repository has been bitten by before.
- **Proven end to end, across processes.** With `FEEDMINE_SEED_CAPTURE_DIR=/tmp/pr16-replay`, one run
  wrote `/tmp/pr16-replay/failure-seed-edition_restore_is_reproducible-1700000000000.json` **and** bundled
  the failing database beside it with its `-wal`/`-shm` companions (ADR-004 D3: a copy of the `.sqlite`
  file alone can lose the committed tail). Then the exact command above selected 6 tests and all passed,
  replaying the artifact from a process whose temporary directory no longer exists.
- **The replay checks the seed**, so `reproduced` means something:
  `testTheReplayNamesTheSeedItUsedAndRefusesAnArtifactThatDoesNotDescribeTheEdition` rewrites the
  artifact's `seedBase64` and gets `diverged: the recorded seed is not the edition's seed`.

### 1.5 Recovery rehearsals (six)

Each *creates* the condition and asserts a recoverable state or an explicit diagnostic.

| # | Rehearsal | Fixture | Asserted outcome |
|---|---|---|---|
| 1 | **Kill switch** | `KillSwitchRehearsalTests` (FeedRuntimeTests): a real edition, checkpoint and bookmark projection, then the mode table flips to `legacy` and back | `legacy` is an exact mode with no acquisition owner and no presentation; `RuntimeMode.allCases.filter(\.ownsAcquisition) == [.v2Full]`; the durable fingerprint of 14 tables is unchanged; flipping back restores the same edition and the same checkpoint offset |
| 2 | **Rollback** | `RollbackRehearsalTests`: a synthetic container (`user.sqlite`-shaped: `bookmark_list`, `bookmark_item`, `source_collection`, `read_history`, `user_operation`) beside the runtime database; a V2 run publishes and saves; then a legacy relaunch | the container fingerprint is byte-identical; the runtime fingerprint is unchanged; every bookmark resolves through `legacy_item_map` to a live revision **and** to a card in a retained edition with its frozen payload; the projection is intact for the next V2 launch; **no double acquisition** — no target added, no batch admitted, `checkpoint_revision` still 0 |
| 3 | **Compatible upgrade** | `RecoveryRehearsalTests`: a database built with `RuntimeMigrations.through("v5_session_and_exposure")` — the shipped set, obtained from the same migration list rather than a copy — with synthetic canonical, projection, edition and bookmark rows | only the missing migration runs; every row is byte-identical afterwards; no table disappears and exactly `gc_run`, `gc_run_class`, `retention_policy` appear; the bookmark written before the upgrade still resolves; `inspect` says healthy |
| 4 | **Disk full** | a real `SQLITE_FULL`: `PRAGMA max_page_count` capped at the current `page_count`, `wal_autocheckpoint = 1`, then a 400 KB insert | the write is refused and **classified** `RuntimeRecovery.reason(for:) == .diskFull` (which is why `RuntimeDatabaseError` gained `.storage(code:message:)`: reporting every refusal as "the transaction failed" made D9 unimplementable); the previous state stands — row counts unchanged, no half-written row, the published edition still restores, the aggregate still healthy; raising the cap lets a write through |
| 5 | **Controlled corruption** | page 2 of the database overwritten with `0xFF` after a `wal_checkpoint(TRUNCATE)` and a pool close, so the header stays valid and the damage is what `integrity_check` is for | `inspect` returns `.readOnly(.corruption(...))` and changes nothing; `rebuild` quarantines the damaged files (the `.sqlite` and its companions) and the quarantined copy is **byte-identical to the damaged file**; the fresh database migrates and verifies, and it is empty of the user's rows — reported, not discovered |
| 6 | **Incompatible edition** | an edition stored with `publication_schema_version = 99` (written after the commit, which is how a database from a newer build arrives) | `restore` refuses with `.unsupportedPublicationSchemaVersion(99)`; `RuntimeRecovery.editionReason` classifies it `.incompatiblePublicationSchema(99)` and marks it **edition-scoped**, while the database itself still inspects as `.healthy` — the distinction that keeps a cold/recovery launch from being read as "the database is broken" |

What the rollback rehearsal does **not** cover, stated rather than implied: the *legacy schema* itself is
the app target's (`feedmine/Services/UserStateStore.swift`), so the container here is synthetic, as
ADR-004 D11 asks. The device half — reinstalling build 17 over a database V2 wrote — was observed at PR-13
close (baseline §8.13.1: identical seeded user rows across a `mode=legacy` relaunch) and is repeated by
PR-17. Build 17 has no runtime database of its own, so the package-level half of "upgrade from the
supported release's container" is the forward migration in #3.

### 1.6 SLO capture, honestly bounded

**What is instrumented.** `FeedStorage/Diagnostics/RuntimeMetricsRecorder.swift`: an operation sample is
`operation` + operation ID + edition + epoch + duration + outcome, and `OperationSummary` reports
count/percentiles by the nearest-rank rule. Counter events: `no_op_batch`, `stale_rejection`,
`admission_refusal`, `publication_retry`, `orphan_asset_collected`, `gc_run`. The recorder's sample and
counter types have **no field for a URL**, which is how §16's "no sensitive URLs" is kept rather than
promised.

Wired where the operation actually happens: `AdmissionEngine.admit` (duration + verdict counters),
`SelectionSupplyRepository.page` (candidate query, with `rows=`, `examined=` and `window=` in its outcome
because §16 asks for the dataset size), `PublicationRepository.commit` (duration + the retry counter,
counted where the attempt number is known), `RetentionCoordinator.run` (duration + GC and orphan
counters). `RuntimeMetricsTests` proves each path records its operation and its counter, including a real
duplicate batch (`no_op_batch = 1`) and a real retry after a storage failure (`publication_retry = 1`).

**World, measured.** `swift test --package-path Packages/FeedRuntimeV2` on the macOS host, **Debug** build,
in-process, synthetic dataset, one run: admission ~0.1 ms per batch, candidate query over the fixture pool
sub-millisecond, publication commit sub-millisecond, GC run sub-millisecond. These are *not* §16's SLOs
and are not offered as any: they measure Debug in-process primitives on an M4 host, and §16's numbers are
wall-clock targets for a Release build on the minimum device.

**What is not produced here, named.**

- **The Performance class (§15.1).** Release build, physical device, declared sampling, `.xcresult`
  traces: not producible in this environment (baseline §8.16 and §8.17.1 both say so). Nothing here
  estimates it.
- **Warm presentation, context switch, MainActor apply, scroll hitch, energy, placeholders.** These need
  the app runtime and a device. `MainActor apply < 4 ms` is a budget on the app's snapshot application;
  the app-side claim today is the absence proof (network in the renderer = 0) that PR-08 and PR-13
  established.
- **Shadow drop and rollback counters.** §16 asks for both; neither belongs to this package. A shadow drop
  is the app parity lane's own accounting (`ShadowComparator`), and a rollback is a launch decision whose
  observation is `RuntimeMode`'s resolution plus the device counts in §8.13.1. They are absent from
  `RuntimeCounterEvent` on purpose: a counter nobody increments reads as a measure that is always zero.
- **No absolute memory or disk budget was fixed.** §16 forbids approving one before a baseline on the
  minimum device, and `retention_policy` ships with no rows: a class with no declared limit is skipped,
  not unlimited.

**The warm-restore rule's second half, implemented.** `FeedRuntime/Session/StartupReport.swift` adds
`StartupClassification` (`warm_restore` | `cold_recovery`) and `FeedSession.currentStartupReport()`.
`StartupClassificationTests` covers every path: a stored edition restores → `warm_restore` with the
edition and its card count; **no compatible edition → `cold_recovery`**; an edition from a newer build →
`cold_recovery`; a payload that no longer recomputes → `cold_recovery`; and no report exists before the
session opens. The rule's first half was already proven on a device (§8.13.1) and is not re-claimed here.

## 2. Gates

Verbatim, in the order the runner uses them.

```
$ swift test --package-path Packages/FeedRuntimeV2 --scratch-path .build-dd/swiftpm
	 Executed 484 tests, with 0 failures (0 unexpected) in 10.102 (10.131) seconds
```
(441 before this slice, +43 new tests; 0 skipped. The app plan was re-run by the orchestrator, not here:
the last run of it in this slice was 572 passed / 0 failed / 0 skipped on iPhone 16.)

```
$ bash scripts/verify-runtime-v2-boundaries.sh
boundary gate: 70 source files, 138 imports, root=/Users/wagnermontes/Documents/GitHub/feedmine/Packages/FeedRuntimeV2
PASS: module boundaries match the plan
```
(63 files / 122 imports before; the gate's own number, reported as it prints it.)

```
$ xcodebuild test -project feedmine.xcodeproj -scheme feedmine \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -testPlan FeedMine-RuntimeV2 -derivedDataPath .build-dd
Test Suite 'All tests' passed at 2026-09-18 01:47:58.984.
	 Executed 572 tests, with 0 failures (0 unexpected) in 113.949 (114.123) seconds
** TEST SUCCEEDED **
```
Produced by **iPhone 16** with **Xcode 26.6** / iOS 26.5 SDK on the macOS host. Baseline §8.22 records
that the repository's GitHub CI runs Xcode 16.4 / iOS 18.5 and is red for reasons that predate this
slice (a `-testPlan` / scheme mismatch and a Swift 6 concurrency error in `ArticleReaderView.swift`), so
"the app gate is green" here means green under 26.6 and does not imply CI green.

One note on the first app-gate attempt: it failed with `Cannot find type 'MediaCollectionOutcome' in
scope` inside `FeedMedia`, while a plain `xcodebuild build` for the same destination and the package
suite both succeeded. That is a stale incremental module (Xcode's dependency scan reusing a pre-change
`FeedDomain`), not a source problem: the same command re-run after the build was green, 572/0.

## 3. Files

Production (`Packages/FeedRuntimeV2/Sources/`):

- `FeedStorage/Migrations/RuntimeMigrations.swift` — `v6_retention_schema`; `knownMigrationIdentifiers`;
  `steps` + `through(_:)`, so the upgrade rehearsal builds the shipped set from the same list that ships.
- `FeedStorage/Retention/RetentionPolicy.swift`, `Retention/RetentionCoordinator.swift` — new.
- `FeedStorage/Recovery/RuntimeRecovery.swift` — new.
- `FeedStorage/Diagnostics/FailureSeedCapture.swift`, `Diagnostics/RuntimeMetricsRecorder.swift` — new.
- `FeedStorage/RuntimeDatabase.swift` — `RuntimeDatabaseError.storage(code:message:)`, `checkpointWAL()`.
- `FeedStorage/Publication/PublicationRepository.swift` — `location`, the commit measurement.
- `FeedStorage/Admission/AdmissionEngine.swift`, `Selection/SelectionSupplyRepository.swift` — measurement.
- `FeedDomain/Ports/Ports.swift` — `MediaAssetKey`, `MediaCollectionOutcome`, `RetentionMediaCollecting`,
  `BookmarkSubjectProviding`'s counterpart usage.
- `FeedMedia/MediaRetentionCollector.swift` — new (the port's production conformance).
- `FeedRuntime/Session/StartupReport.swift` — new; `FeedRuntime/Session/FeedSession.swift` — startup
  classification + the failure-capture port.

Tests: `FeedStorageTests/{RetentionCoordinatorTests (13), CrashTerminationTests, RecoveryRehearsalTests,
RollbackRehearsalTests, FailureSeedReplayTests, RuntimeMetricsTests, MigrationTests}`, `FeedMediaTests/
MediaRetentionCollectorTests`, `FeedRuntimeTests/{KillSwitchRehearsalTests, RestoreRefusalCaptureTests,
StartupClassificationTests}`. Helper executable: `Probes/FeedStorageProbe/main.swift`.

## 4. Decisions and gaps

- **The probe lives under `Probes/`, not `Sources/`, and is an executable target without a product.**
  `Sources/` means "the modules of §3's dependency table"; the boundary gate fails on a directory there
  that no rule governs, and that check is right. It names `FeedStorage` *and* `FeedMedia` — a pair no
  production target may combine — because the file-write boundary must place its temporary file where
  `LocalAssetStore`'s own reclaim path looks for it. It is built by `swift test` (verified) and never by
  the app scheme.
- **`FeedStorageTests` gained a `FeedMedia` dependency** (test-only) so the crash rehearsal can prove the
  orphan is collectable by the store's own path instead of a second implementation in the test. Production
  `FeedStorage` still may not see `FeedMedia`.
- **`RuntimeDatabaseError` gained a case.** D9's disk-full path needs SQLite's result code; without it a
  full disk and a constraint violation are the same string, and only one of them is recoverable by
  reclaiming space.
- **Gap, named: the build-17 legacy container.** The rollback/upgrade rehearsals run against a synthetic
  container and the shipped *runtime* schema set. The real legacy schema is app-owned; the device
  observation is §8.13.1's, and PR-17 owns the reinstall-over-V2 repeat. Recorded rather than implied.
- **Gap, named: one latent write-path inconsistency found while building a fixture.** A card whose frozen
  `editorialRevision` differs from its edition's is accepted by `PublicationRepository.commit`'s validation
  and only rejected later, by `restore`'s payload-digest check (the row has no per-card revision column, so
  the digest is recomputed against the edition's). Production never produces it — the coordinator passes
  one revision for both — but a caller could. It is a publication-invariant question (PR-06's write path),
  not retention, so it is reported here with a reproduction rather than fixed inside this slice.
- **Gap, named: the Performance class and the device half of §16's SLOs** (§1.6). Not produced, not
  estimated.
- **Nothing was re-opened.** `Runway/**`, the shadow's budget work, the PR-14 surface matrix and demand
  ledger, and the PR-15 background path are unchanged; the coordinator's optional `metrics` parameter and
  the session's optional `failureCapture` parameter are additive, so no existing call site had to change.
