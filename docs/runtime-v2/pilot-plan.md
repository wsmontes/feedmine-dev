# Runtime V2 — the pilot's preconditions: window, devices, sample, and how each SLO is read

Plan §22: *"Cada promoção de modo exige suite funcional verde, ensaio de rollback e relatório em
dispositivo real. Definir antes do piloto uma janela de observação, aparelhos e amostra; não tomar uma
única execução sem crash como estabilidade demonstrada."*

This file is that definition. It is written **before** the pilot on purpose: §16's numbers are initial
targets, and §16 forbids fixing absolute budgets before a baseline on the minimum device. So what can be
fixed now is the procedure — who runs what, on which device, how many times, read with which instrument,
and what ends the window or triggers a rollback. The numbers themselves stay unclaimed until the runs
exist; nothing here estimates them.

## 1. What promotion means, in executable terms

A mode (`legacy` → `mirroredShadow` → `v2Presentation` → `v2Full`, per `rollout.md` §1) is promoted only
when all three hold, in this order:

1. **Green suite under the CI's compiler, not ours.** `baseline.md` §8.22 measured the difference: the
   runner builds with Xcode 16.4 and the local machine has 26.6, and one construct the newer SDK accepts
   is rejected by the older one. A local green is therefore a *precondition* for a pipeline run, never a
   substitute for it.
2. **A rollback rehearsal on the real container.** Build 17's container, then the current build over it,
   then back to legacy — with the durable fingerprints compared before and after
   (`baseline.md` §8.28 is the precedent for the upgrade half; §8.13.1 for the mode switch).
3. **A real-device report**, whose shape is §2 below. One crash-free run is not stability: the window and
   the sample are what make a run count.

## 2. Devices and environment

| Slot | Device | Why this one | Build |
|---|---|---|---|
| Minimum | The oldest iPhone that runs iOS 18 (A12 class, iPhone XR/XS) | The deployment target is **iOS 18.0** (`project.yml:34,115,126` for the three targets; in the compiled form `pbxproj:1362,1420,1439,1458` — read on 2026-09-18, and a line number here is true for the tree it was read from). Note which file is authoritative: **the `pbxproj`**, not `project.yml`. `project.yml` is reference-only in this repo (the quality audit's own note, and the drift this session measured: the UI test target's members exist in the `pbxproj` alone, `docs/runtime-v2/baseline.md` §8.50), so a deployment-target change made only in `project.yml` would not build. §16 fixes budgets *after* a baseline on the minimum device, so the minimum is the device the budgets belong to | **Release** |
| Target | The device the owner actually uses daily (one current iPhone, iOS 26.x) | Where the reader's experience is real; catches what the minimum device hides by being slow in a different way | Release |
| Observability | A computer with a console attached | `RuntimeMetricsRecorder` writes in-process; the counters and operation samples are read from the app's own log/signposts, so a run nobody can read is a run that does not count | — |

**Not a slot: the simulator.** It is where this work was verified (it is the only surface available here),
and simulators are legitimate for behaviour. They are not legitimate for any §16 number: wall-clock on a
Mac host measures the host.

The owner fixes the actual two devices; this table fixes the *classes* and the reason, so the choice is not
made after seeing the numbers.

## 3. The sample

Each row is a scenario, a repetition count, and what it is allowed to claim. The recipes are
`PhysicalDeviceTesting.md` §3 — *instalação limpa*, *cold start preservando dados*, *warm start* — which
already exist and are not restated here.

| Scenario | Repetitions | What it can claim | What it can never claim |
|---|---|---|---|
| Clean install, `v2Full`, with network | ≥3 per device | Cold-path correctness: the runtime composes, acquires, admits, publishes, and draws (the simulator precedent produces editions and 32 targets, `baseline.md` §8.25) | Any latency target: the first run after install also builds caches |
| Cold start **preserving data**, no network | ≥3 per device | Warm restore does not depend on network/Selection/catalogue (§16's rule; the device half is already proven once at §8.13.1) | That a compatible edition always exists — the incompatible cases must appear as `cold_recovery` (`StartupReport`, `pr-16-hardening-report.md` §1.6), and folding them into the warm distribution is the failure this scenario exists to catch |
| Warm start, repeated | ≥10 per device | The p50/p95 of §16's *Warm presentation* row, once the runs exist | p95 from fewer than ten samples: the nearest-rank percentile of five samples is a maximum in disguise |
| Upgrade from the supported release | 1 per device, deliberately | That build 17's rows survive (`baseline.md` §8.28) | Anything about a second upgrade path: there is only one supported release |
| Rollback to legacy | 1 per device | That the kill switch works and user state is intact (§1 gate 2) | That V2 is safe — a rollback proves the escape hatch, not the destination |
| Background refresh delivered by the system | as the system delivers | That the handler completes or cancels exactly once (`rollout.md` §7, PR-15's diagnostic) | A rate: this environment cannot schedule the system's delivery, which is why PR-15's diagnostic exists and stays silent until it happens |

**The window.** It closes when every row above has its repetitions **and** the §16 blocker counters read
zero (below). It does not close on elapsed time alone, and it does not close because a run was uneventful:
"no crash" is the *absence* of one class of evidence, not the presence of stability. A crash, a violated
invariant counter, or a rollback during the window ends the pilot and reopens the mode decision.

## 4. Reading each §16 measure

The instrument landed at PR-16 and is described in `pr-16-hardening-report.md` §1.6: operation samples
carrying operation ID, edition, epoch, duration and outcome — with **no field for a URL** — plus counter
events. Only what exists is listed; a measure with no instrument is named as such rather than approximated.

| §16 measure | Instrument | Recipe |
|---|---|---|
| Warm presentation p50/p95 (<250/<500 ms) | App-side: the session's snapshot application, plus the log's `runtime-v2 v2Full snapshot edition=… cards=… sequence=…` timestamps | Warm-start scenario ×≥10; record the interval from the session opening to the first applied snapshot; classify every run with `StartupClassification` so `cold_recovery` never lands in the warm set |
| Context switch local p50 (<100 ms) | The intent's own timestamp to the applied snapshot of the new context | Only meaningful once a mode switches contexts; today `MainFeedRuntime.handle(.switchContext:)` logs and the plan keeps filters legacy in `v2Full` — so this row is **not collectable yet**, and saying so is the point |
| Candidate query p95 (<20 ms) | `SelectionSupplyRepository.page` samples (duration + `rows=`/`examined=`/`window=`) | Read from the device's recorder dump for a real dataset; §16 wants the dataset size recorded, which those fields are |
| MainActor apply (<4 ms budget) | App-side apply samples; excludes decode and SQL by construction | Same warm runs; record p95 and max, not the mean |
| Network in the renderer = 0 | PR-08's and PR-13's absence proof, plus the app's own request log during a run | A run with the feed scrolled end to end, no article opened; count requests started by the visual path. **This is a blocker, not an average** |
| Protocol decoding downstream = 0 | `AdmissionEngine.admit` / publication samples: decoding happens at the connector, and a second decode would show as an admitted payload without a batch | Same runs |
| Published payload mutation = 0 | The append-protected revision guards (PR-06) | Covered by the suite; a device run adds nothing, and pretending otherwise would be theatre |
| Post-publication editorial mutation = 0 (§16, Blueprint §105) | The same append-only guards, plus `EditorialRevision`'s immutability (ADR-002) | Covered by the suite, like the row above: a retained edition's editorial decision cannot change, so a device run adds nothing here either |
| Blocking disk I/O in View body = 0 (§16, Blueprint §105) | **No instrument — read by reviewing the renderer's `body`s** | Named as a review rather than a measurement, which is why it is the one row a device cannot settle. The rule it enforces is that the feed's reads are materialized before the body runs (`rollout.md` §2.1) |
| Stale publication/checkpoint ahead = 0 | The session's stale-rejection counter and the sequence guard | **Blocker**; any non-zero value fails the window |
| Memory peak/steady, asset/DB/WAL bytes | Not instrumented at PR-16 | Named as absent. §16's rule is to block unbounded growth and *not* invent an approved number; a budget needs this row first, so it is the first thing to instrument when the pilot starts |
| Energy, scroll hitch, time-to-first-card, cancellation latency, placeholder share | Not instrumented at PR-16 | Same disposition: named, not estimated |
| Shadow drop, rollback counters | Deliberately **not** in `RuntimeCounterEvent` | A shadow drop is the parity lane's accounting (`ShadowComparator`) and a rollback is a launch decision; PR-16 left them out on the stated ground that a counter nobody increments reads as a measure that is always zero. If the pilot needs them, they get their own reader rather than a placeholder in the package |

## 5. What this file does not claim

- **No absolute memory or disk budget.** §16 forbids one before the minimum-device baseline, and
  `retention_policy` ships with no rows on purpose (a class with no declared limit is skipped, not
  unlimited). This file does not change that.
- **No numbers.** The only figures in the tree are the Debug/in-process ones
  `pr-16-hardening-report.md` §1.6 reports and explicitly refuses to offer as SLOs.
- **Not a pilot.** It is the precondition the plan asks to fix before one starts.
