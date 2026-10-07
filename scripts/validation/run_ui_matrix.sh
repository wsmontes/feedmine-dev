#!/bin/bash
# Feedmine validation — UI matrix: the journeys plus every filter axis, with the app's own log beside them.
#
# What it runs, and why in this order:
#
#   * Leg A — `FeedmineFilterUITests/testTimeToFirstCardColdThenWarm` **alone**, immediately after
#     `simctl uninstall`. A cold time-to-first-card is only cold if the container holds no persisted page, and the
#     only way to get that state is to wipe the app right before the launch. The test proves the precondition by
#     reading the container and prints it next to the number, so a leg that accidentally inherited a warm
#     container says so instead of mislabelling the measurement.
#   * Leg B — the three UI classes: `PersonaExplorationUITests` (the journey), `FeedmineFilterUITests` (the axis
#     sweep, the end-of-feed probe, the existing filter matrix) and `FeedmineUITests`. Leg A has already warmed
#     the container, which is the warm start the end-of-feed test needs to reproduce the reader's report.
#
# `xcrun simctl spawn <udid> log stream` runs for the whole run, in parallel, filtered to the app's own
# subsystem (`com.feedmine.app`): the UI test process cannot read the app's log, so the `READY`, `LoadMore`,
# `Viewport`, `page[` and `Latency` lines that explain *why* a measured wait was long only exist there. They are
# written into the report in order, so a slow `content_wait_ms` can be read against the acquisition decision that
# was being made at that instant.
#
# Serialization: the lane lock covers `simctl` as well as `xcodebuild`. `simctl uninstall` wipes the app container
# — the exact state leg A measures — and another front is measuring on the same one-simulator device, so the lock
# is taken before the wipe and released by removing its `holder` file first (`rmdir` alone cannot remove a
# non-empty directory, which is how earlier versions leaked the lock).
#
# Exit status: non-zero when any leg reported a failure, when xcodebuild exited non-zero, or when the build
# failed. The report is written in every case — a red run is the one that most needs the evidence.
#
# Usage: bash scripts/validation/run_ui_matrix.sh
#   env: FEEDMINE_SIM_UDID  simulator UDID (required when more than one device matches FEEDMINE_SIM_NAME)
#        FEEDMINE_SIM_NAME  model to use; default `iPhone 16`
#        FEEDMINE_RESULTS_DIR  artifact root; default `<repo>/Artifacts/Validation`
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

SIM_NAME="${FEEDMINE_SIM_NAME:-iPhone 16}"
# Device selection is exact, not "some iPhone": the journey asserts coordinates and frames, and leg A's cold
# number is model-specific, so more than one match is an error rather than a coin flip.
discover_udid() {
  local booted matches count
  booted=$(xcrun simctl list devices booted 2>/dev/null | awk -F'[()]' -v n="$SIM_NAME" '$0 ~ n {gsub(/ /,"",$2); print $2; exit}')
  if [ -n "$booted" ]; then echo "$booted"; return 0; fi
  matches=$(xcrun simctl list devices available 2>/dev/null | awk -F'[()]' -v n="$SIM_NAME" '$0 ~ n {gsub(/ /,"",$2); print $2}')
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if [ "$count" -gt 1 ]; then
    echo "ABORTADO: $count simulators match '$SIM_NAME' — set FEEDMINE_SIM_UDID to choose:" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    return 1
  fi
  printf '%s\n' "$matches" | head -1
}

S="${FEEDMINE_SIM_UDID:-$(discover_udid)}"
if [ -z "$S" ]; then echo "ABORTADO: no simulator matching '$SIM_NAME' — set FEEDMINE_SIM_UDID"; exit 9; fi
DEST="platform=iOS Simulator,id=$S"

LANE=/tmp/feedmine-lane.lock
release_lane() { rm -f "$LANE/holder" 2>/dev/null || true; rmdir "$LANE" 2>/dev/null || true; }
acquire() {
  for _ in $(seq 1 180); do
    if mkdir "$LANE" 2>/dev/null; then
      echo "$$ $(date +%s)" > "$LANE/holder"
      return 0
    fi
    H=$(awk '{print $1}' "$LANE/holder" 2>/dev/null || true)
    AGE=$(( $(date +%s) - $(awk '{print $2}' "$LANE/holder" 2>/dev/null || echo "$(date +%s)") ))
    reclaim() { echo "RECLAIM: $1"; rm -f "$LANE/holder" 2>/dev/null || true; rmdir "$LANE" 2>/dev/null || rm -rf "$LANE"; }
    if [ -n "$H" ] && ! kill -0 "$H" 2>/dev/null; then reclaim "holder pid $H is gone"; continue; fi
    if [ "$AGE" -gt 900 ] 2>/dev/null && ! pgrep -f "xcodebuild|simctl" >/dev/null; then reclaim "lock age ${AGE}s idle"; continue; fi
    sleep 10
  done
  echo "ABORTADO: lane lock held by pid ${H:-?}"; exit 9
}

RESULTS_DIR="${FEEDMINE_RESULTS_DIR:-$REPO/Artifacts/Validation}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGDIR="$RESULTS_DIR/Logs"
REPORT="$RESULTS_DIR/Results/ui-matrix-$TIMESTAMP.md"
mkdir -p "$LOGDIR" "$(dirname "$REPORT")"
BUILDLOG="$LOGDIR/ui-matrix-$TIMESTAMP-build.log"
LEGA="$LOGDIR/ui-matrix-$TIMESTAMP-leg-cold.log"
LEGB="$LOGDIR/ui-matrix-$TIMESTAMP-leg-matrix.log"
APPLOG="$LOGDIR/ui-matrix-$TIMESTAMP-app.log"
# The post-run ring-buffer read. The live stream above is kept as well, but it cannot be the only source: a
# `log stream` child that is killed (measured 2026-10-06: "Child process terminated with signal 15" 30 s into the
# run — another front's stray-process cleanup took it) leaves a file with a banner and no events, and the run
# would then report "no app log" for a run the app logged normally. `log show --info` reads the same messages out
# of the simulator's ring buffer after the fact, so the report survives the stream dying.
APPLOG_SHOW="$LOGDIR/ui-matrix-$TIMESTAMP-app-show.log"
RUN_START="$(date '+%Y-%m-%d %H:%M:%S')"

LOG_STREAM_PID=""
cleanup() {
  if [ -n "$LOG_STREAM_PID" ]; then
    kill "$LOG_STREAM_PID" 2>/dev/null || true
    wait "$LOG_STREAM_PID" 2>/dev/null || true
  fi
  release_lane
}
trap cleanup EXIT

acquire
echo "== UI matrix start $(date '+%H:%M:%S') at $(git rev-parse --short HEAD 2>/dev/null || echo no-git) =="
echo "simulator: $S | destination: $DEST"
echo "artifacts: $REPORT"

xcrun simctl shutdown "$S" 2>/dev/null || true; sleep 3
xcrun simctl boot "$S" 2>/dev/null || true
xcrun simctl bootstatus "$S" -b >/dev/null 2>&1 || true
# The cold precondition for leg A, asserted rather than assumed: fail loudly if the container survived.
xcrun simctl uninstall "$S" com.feedmine.app 2>/dev/null || true
if xcrun simctl get_app_container "$S" com.feedmine.app >/dev/null 2>&1; then
  echo "ABORTADO: com.feedmine.app still has a container on $S — leg A's cold start would be mislabelled"
  exit 9
fi

echo "-- app log stream (subsystem com.feedmine.app) -> $APPLOG"
xcrun simctl spawn "$S" log stream --style syslog --level info \
  --predicate 'subsystem == "com.feedmine.app"' > "$APPLOG" 2>&1 &
LOG_STREAM_PID=$!
sleep 3

echo "-- build-for-testing"
if xcodebuild build-for-testing -project feedmine.xcodeproj -scheme feedmine \
  -destination "$DEST" > "$BUILDLOG" 2>&1; then BUILD_EXIT=0; else BUILD_EXIT=$?; fi
BUILD_ERRORS=$(grep -acE 'error:' "$BUILDLOG" || true)
echo "   build errors=$BUILD_ERRORS exit=$BUILD_EXIT"
if [ "$BUILD_ERRORS" != "0" ] || [ "$BUILD_EXIT" != "0" ]; then
  echo "ABORTADO: o build falhou; não se mede contra produto velho"
  grep -aE 'error:' "$BUILDLOG" | sed 's|.*/feedmine/||' | sort -u | head -20 || true
  exit 8
fi

run_leg() { # run_leg <log> <label> <only-testing args...>
  local log="$1"; local label="$2"; shift 2
  echo "-- $label $(date '+%H:%M:%S')"
  local args=()
  local t
  for t in "$@"; do args+=("-only-testing:$t"); done
  xcodebuild test-without-building -project feedmine.xcodeproj -scheme feedmine \
    -destination "$DEST" -parallel-testing-enabled NO "${args[@]}" > "$log" 2>&1
  return $?
}

# Leg A — cold TTFF on the just-wiped container. Nothing else shares this leg: another test's launch would
# populate the container and the "cold" number would be a warm one.
run_leg "$LEGA" "leg A (cold TTFF)" "feedmineUITests/FeedmineFilterUITests/testTimeToFirstCardColdThenWarm"
LEG_A_EXIT=$?

# Leg B — the journeys and the whole filter matrix.
run_leg "$LEGB" "leg B (journeys + filter matrix)" \
  "feedmineUITests/PersonaExplorationUITests" \
  "feedmineUITests/FeedmineFilterUITests" \
  "feedmineUITests/FeedmineUITests"
LEG_B_EXIT=$?

sleep 2
if [ -n "$LOG_STREAM_PID" ]; then kill "$LOG_STREAM_PID" 2>/dev/null || true; wait "$LOG_STREAM_PID" 2>/dev/null || true; LOG_STREAM_PID=""; fi

echo "-- app log (ring buffer, \`log show\`) -> $APPLOG_SHOW"
xcrun simctl spawn "$S" log show --style compact --info --debug \
  --start "$RUN_START" --end "$(date '+%Y-%m-%d %H:%M:%S')" \
  --predicate 'subsystem == "com.feedmine.app"' > "$APPLOG_SHOW" 2>&1 || true

# ---- Report ------------------------------------------------------------------------------------------------
rows_file=$(mktemp)
for leg in "$LEGA" "$LEGB"; do
  [ -f "$leg" ] || continue
  # `sed -nE`, not the BRE form: this `sed` does not implement `\|` alternation in BRE, and the BRE spelling
  # silently produced an empty table for a run that had 30+ test cases in the log.
  sed -nE "s/^Test Case '-\[([^]]*)\]' (passed|failed|skipped) \(([0-9.]+) seconds\).*/\1|\2|\3/p" "$leg" >> "$rows_file"
done

{
  echo "# UI matrix — $TIMESTAMP"
  echo
  echo "- simulator: \`$S\` ($SIM_NAME)"
  echo "- run window: \`$RUN_START\` → \`$(date '+%Y-%m-%d %H:%M:%S')\`"
  # Provenance matters more than usual here: the tree carries uncommitted instrumentation (`[LoadMore]` /
  # `[Viewport]`) and in-flight fixes, so a number attributed to a bare sha would be a number nobody can rebuild.
  DIRTY_FILES="$(git status --porcelain 2>/dev/null | awk '{print $2}')"
  DIRTY_COUNT="$(printf '%s\n' "$DIRTY_FILES" | grep -c . || true)"
  echo "- revision: \`$(git rev-parse HEAD 2>/dev/null || echo no-git)\` | dirty: $([ "$DIRTY_COUNT" = "0" ] && echo "nao" || echo "sim ($DIRTY_COUNT arquivos)")"
  if [ "$DIRTY_COUNT" != "0" ]; then
    echo "- uncommitted files measured (a dirty tree means these numbers belong to this tree, not to the sha):"
    printf '%s\n' "$DIRTY_FILES" | sed 's/^/  - `/; s/$/`/'
  fi
  echo "- legs: A cold-TTFF exit=$LEG_A_EXIT | B journeys+matrix exit=$LEG_B_EXIT"
  echo "- build log: \`${BUILDLOG#$REPO/}\`"
  echo "- leg A log: \`${LEGA#$REPO/}\`"
  echo "- leg B log: \`${LEGB#$REPO/}\`"
  echo "- app log, live stream (\`com.feedmine.app\`): \`${APPLOG#$REPO/}\`"
  echo "- app log, ring buffer (\`log show --info\`): \`${APPLOG_SHOW#$REPO/}\`"
  echo
  echo "## (a) Tests"
  echo
  echo "| class | test | result | seconds |"
  echo "|---|---|---|---|"
  awk -F'|' '{split($1, p, " "); gsub(/^feedmineUITests\./, "", p[1]); printf "| %s | %s | %s | %s |\n", p[1], p[2], $2, $3}' "$rows_file"
  echo
  total=$(grep -c . "$rows_file" || true)
  passed=$(awk -F'|' '$2 == "passed"' "$rows_file" | grep -c . || true)
  failed=$(awk -F'|' '$2 == "failed"' "$rows_file" | grep -c . || true)
  skipped=$(awk -F'|' '$2 == "skipped"' "$rows_file" | grep -c . || true)
  seconds=$(awk -F'|' '{s += $3} END {printf "%.1f", s}' "$rows_file")
  echo "## (c) Summary"
  echo
  echo "- tests: $total — passed: $passed, failed: $failed, skipped: $skipped"
  echo "- summed test duration: ${seconds}s"
  echo "- app log lines: READY=$(grep -ahc 'READY' "$APPLOG" "$APPLOG_SHOW" 2>/dev/null | awk '{s+=$1} END {print s+0}') LoadMore=$(grep -ahc 'LoadMore' "$APPLOG" "$APPLOG_SHOW" 2>/dev/null | awk '{s+=$1} END {print s+0}') Viewport=$(grep -ahc 'Viewport' "$APPLOG" "$APPLOG_SHOW" 2>/dev/null | awk '{s+=$1} END {print s+0}') page=$(grep -ahc 'page\[' "$APPLOG" "$APPLOG_SHOW" 2>/dev/null | awk '{s+=$1} END {print s+0}') Latency=$(grep -ahc 'Latency' "$APPLOG" "$APPLOG_SHOW" 2>/dev/null | awk '{s+=$1} END {print s+0}')"
  echo
  echo "## Findings and probes (test-side)"
  echo
  echo '```'
  for leg in "$LEGA" "$LEGB"; do
    [ -f "$leg" ] || continue
    grep -aE '^(FINDING|AXISSWEEP|ENDOFFEED|READY|REOPEN|READER|JORNADA)' "$leg" || true
  done
  echo '```'
  echo
  echo "## (b) App log — READY | LoadMore | Viewport | page[ | Latency, in order"
  echo
  echo "### (b1) ring buffer (\`log show --info --debug\`, survives the live stream dying)"
  echo
  echo '```'
  grep -aE 'READY|LoadMore|Viewport|page\[|Latency' "$APPLOG_SHOW" 2>/dev/null || echo "(no matching lines — the subsystem produced none in the run window)"
  echo '```'
  echo
  echo "### (b2) live stream"
  echo
  echo '```'
  grep -aE 'READY|LoadMore|Viewport|page\[|Latency' "$APPLOG" 2>/dev/null || echo "(no matching lines — see (b1); a killed stream leaves only its banner here)"
  echo '```'
  echo
  if [ "$LEG_A_EXIT" = "0" ] && [ "$LEG_B_EXIT" = "0" ] && [ "$failed" = "0" ]; then
    echo "VERDICT: PASS (exit 0)"
  else
    echo "VERDICT: FAIL (leg A exit=$LEG_A_EXIT, leg B exit=$LEG_B_EXIT, failed tests=$failed)"
  fi
} > "$REPORT"
rm -f "$rows_file"

echo "== report: $REPORT =="
grep -aE '^- tests:|^- summed|- app log lines' "$REPORT" || true
grep -aE '^\| .*\| (failed|skipped) \|' "$REPORT" || true

if [ "$LEG_A_EXIT" != "0" ] || [ "$LEG_B_EXIT" != "0" ]; then
  echo "== UI matrix FAILED $(date '+%H:%M:%S') =="
  exit 1
fi
if grep -aqE '^\| .*\| failed \|' "$REPORT"; then
  echo "== UI matrix FAILED (failing tests) $(date '+%H:%M:%S') =="
  exit 1
fi
echo "== UI matrix OK $(date '+%H:%M:%S') =="
