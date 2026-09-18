#!/bin/bash
# FeedMine Runtime V2 — test gate (PR-01)
#
# Runs both halves of the Runtime V2 test surface and fails unless each half actually executed
# tests. A green run that selected zero tests is a failure here, because that is exactly how the
# repository's previous gates reported success while doing nothing.
#
# Two halves, because Xcode cannot run them together in this project:
#   1. the package core, on the macOS host (`swift test`). Xcode 26.6 does not let the app's
#      scheme address a local package's test targets: `-only-testing:FeedDomainTests` fails with
#      "Tests in the target "FeedDomainTests" can't be run because "FeedDomainTests" isn't a
#      member of the specified test plan or scheme", and a test-plan entry for a package test
#      target is silently dropped (see docs/runtime-v2/baseline.md §8.1).
#   2. the app-side suite, on the iOS simulator through TestPlans/FeedMine-RuntimeV2.xctestplan,
#      with the number of executed tests read back from the .xcresult.
#
# All build products live under one directory (.build-dd), so
# `bash scripts/validation/clean_validation_artifacts.sh --build` is a complete purge. Each run
# keeps only a small JSON summary; set FEEDMINE_KEEP_RESULT_BUNDLE=1 to keep the .xcresult.
#
# Usage:
#   bash scripts/validation/run_runtime_v2_tests.sh
#   FEEDMINE_DESTINATION=... FEEDMINE_RESULTS_DIR=... bash scripts/validation/run_runtime_v2_tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE="$REPO_ROOT/Packages/FeedRuntimeV2"
DESTINATION="${FEEDMINE_DESTINATION:-}"
# The three binaries are injectable so `test_validation_runners.sh` can prove this gate's exit codes
# with stubs, the way it already does for `run_smoke.sh` and `run_performance.sh` — no simulator, no
# Xcode build. Production uses the real ones.
XCODEBUILD="${FEEDMINE_XCODEBUILD:-xcodebuild}"
SWIFT_BIN="${FEEDMINE_SWIFT:-swift}"
XCRESULTTOOL="${FEEDMINE_XCRESULTTOOL:-xcrun xcresulttool}"
if [ -z "$DESTINATION" ]; then
  # §15: discover a destination instead of presuming one. `-showdestinations` is the only source that
  # knows what this machine has, and a hardcoded name is exactly how the previous CI gate broke when the
  # runner image changed (baseline §8.22: `-testPlan` against a scheme that had none, on a device name
  # nobody had checked). An iPhone simulator is preferred because every suite this project ships targets
  # one; `FEEDMINE_DESTINATION` still wins when set, so a caller can pin a device on purpose.
  #
  # `-showdestinations` prints `platform:iOS Simulator, arch:…, id:…, name:…` inside braces, and
  # `-destination` wants `key=value` instead — passing the brace form through verbatim makes xcodebuild
  # answer `option 'Destination' requires at least one parameter of the form 'key=value'` and exit 64,
  # which reads like a bad argument rather than a bad extraction. So the id is extracted and re-stated as
  # `id=…`, which needs no name and no OS to stay unambiguous.
  # The extraction lives in one file because the CI needs the identical answer and a YAML `run: |` block
  # cannot hold an unindented Python heredoc; `scripts/validation/resolve_destination.py` explains the
  # brace-form trap it exists for.
  DESTINATION=$("$XCODEBUILD" -showdestinations -project "$REPO_ROOT/feedmine.xcodeproj" -scheme feedmine 2>/dev/null \
    | python3 "$SCRIPT_DIR/resolve_destination.py")
  if [ -z "$DESTINATION" ]; then
    echo "no iOS Simulator destination is available on this machine; set FEEDMINE_DESTINATION" >&2
    exit 2
  fi
  echo "destination (discovered): $DESTINATION"
else
  echo "destination (from FEEDMINE_DESTINATION): $DESTINATION"
fi
RESULTS_DIR="${FEEDMINE_RESULTS_DIR:-$REPO_ROOT/Artifacts/Validation}"
DERIVED_DATA="$REPO_ROOT/.build-dd"
# Single SwiftPM product root: keeps package build output inside the one purgeable directory.
SCRATCH="${FEEDMINE_SWIFTPM_SCRATCH:-$DERIVED_DATA/swiftpm}"

# Floors, not targets: they exist to catch a suite that silently ran nothing. Update them in the
# same PR that legitimately changes the test surface.
MIN_PACKAGE_TESTS="${FEEDMINE_MIN_PACKAGE_TESTS:-45}"
MIN_APP_TESTS="${FEEDMINE_MIN_APP_TESTS:-400}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$RESULTS_DIR/Results/Summaries" "$RESULTS_DIR/Logs"
PACKAGE_LOG="$RESULTS_DIR/Logs/RuntimeV2-package-$TIMESTAMP.log"
PACKAGE_SUMMARY="$RESULTS_DIR/Results/Summaries/RuntimeV2-package-$TIMESTAMP.json"
APP_LOG="$RESULTS_DIR/Logs/RuntimeV2-plan-$TIMESTAMP.log"
APP_SUMMARY="$RESULTS_DIR/Results/Summaries/RuntimeV2-plan-$TIMESTAMP.json"
APP_BUNDLE="$RESULTS_DIR/Results/RuntimeV2-plan.xcresult"

status=0

# A run on a full volume is not a run. Measured 2026-09-18: an app-plan run at **1.0 GiB free / 100 %
# capacity** died twice at host level — "Restarting after unexpected exit, crash, or test timeout", no
# assertion anywhere, in two different tests, once while the hosted app was bootstrapping — and the harness
# reports that as a *failing test*, which is a false report about this project's code. The same tree ran
# 599/0 at 1.3 GiB, and baseline §8.25 already names this condition as breaking builds here. So the gate
# refuses to start instead, with a message that says what to do, rather than pretending a full disk is a
# test failure. `FEEDMINE_MIN_FREE_MB=0` disables the check for a caller who knows better.
MIN_FREE_MB="${FEEDMINE_MIN_FREE_MB:-1200}"
FREE_MB=$(df -m "$REPO_ROOT" | awk 'NR==2 {print $4}')
if [ -n "${FREE_MB:-}" ] && [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
  echo "only ${FREE_MB} MB free; this gate needs about ${MIN_FREE_MB} MB or the simulator fails to launch" >&2
  echo "and the harness reports it as a test crash. Free space first —" >&2
  echo "  bash scripts/validation/clean_validation_artifacts.sh --build" >&2
  echo "— or set FEEDMINE_MIN_FREE_MB=0 to run anyway." >&2
  exit 3
fi

echo "=== 1/2 package core on the macOS host (swift test) ==="
"$SWIFT_BIN" test --package-path "$PACKAGE" --scratch-path "$SCRATCH" > "$PACKAGE_LOG" 2>&1
package_exit=$?
package_total=$(grep -Eo "Executed [0-9]+ tests" "$PACKAGE_LOG" | tail -1 | grep -Eo "[0-9]+" || echo 0)
package_failures=$(grep -Eo "with [0-9]+ failures" "$PACKAGE_LOG" | tail -1 | grep -Eo "[0-9]+" || echo -1)

printf '{"gate":"runtime-v2-package","executed":%s,"failures":%s,"exit":%s,"scratch":"%s"}\n' \
  "${package_total:-0}" "${package_failures:--1}" "$package_exit" "$SCRATCH" > "$PACKAGE_SUMMARY"

echo "   exit=$package_exit executed=$package_total failures=$package_failures"
echo "   summary: $PACKAGE_SUMMARY"
if [ "$package_exit" -ne 0 ]; then
  echo "   FAIL: swift test exited $package_exit (log: $PACKAGE_LOG)"
  status=1
elif [ "${package_total:-0}" -lt "$MIN_PACKAGE_TESTS" ]; then
  echo "   FAIL: only $package_total package tests executed, floor is $MIN_PACKAGE_TESTS"
  status=1
elif [ "${package_failures:-1}" -ne 0 ]; then
  echo "   FAIL: $package_failures package test failures"
  status=1
else
  echo "   PASS: $package_total package tests, 0 failures"
fi

echo ""
echo "=== 2/2 app suite through TestPlans/FeedMine-RuntimeV2.xctestplan ==="
# A changed package source can leave the app compiling against a frozen copy of that package's module:
# `Debug-iphonesimulator/<Module>.swiftmodule` keeps the signature from the first build while the fresh
# module goes to `PackageFrameworks/…`, and the app target compiles with `-I` the former — so a correct
# new line reads as `tuple pattern has the wrong length` or `Kind has no member read`. Two sibling slices
# in one session lost their diagnosis to exactly that (baseline §8.39), and the tell is a clean
# `swift build` beside a failing `xcodebuild`. Purging only the local package's own target modules is
# cheap (they rebuild in seconds, unlike FeedKit/GRDB) and removes the trap from the gate.
MODULE_DIR="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"
PURGED=$(python3 - "$REPO_ROOT/Packages/FeedRuntimeV2/Package.swift" "$MODULE_DIR" <<'PY'
import os, re, shutil, sys
manifest, module_dir = sys.argv[1], sys.argv[2]
try:
    source = open(manifest, encoding="utf-8").read()
except OSError:
    print(0); raise SystemExit
names = set(re.findall(r'\.target\(\s*name:\s*"([^"]+)"', source))
purged = 0
for name in sorted(names):
    path = os.path.join(module_dir, f"{name}.swiftmodule")
    if os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)
        purged += 1
print(purged)
PY
)
echo "   purged ${PURGED:-0} local package module(s) that a changed source would have kept stale"
rm -rf "$APP_BUNDLE"
"$XCODEBUILD" test \
  -project "$REPO_ROOT/feedmine.xcodeproj" \
  -scheme feedmine \
  -destination "$DESTINATION" \
  -testPlan FeedMine-RuntimeV2 \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$APP_BUNDLE" > "$APP_LOG" 2>&1
app_exit=$?

app_counts=$($XCRESULTTOOL get test-results summary --path "$APP_BUNDLE" --format json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('0 0'); raise SystemExit
print(d.get('passedTests', 0), d.get('failedTests', 0))
" 2>/dev/null || echo "0 0")
app_passed=$(echo "$app_counts" | awk '{print $1}')
app_failed=$(echo "$app_counts" | awk '{print $2}')

if [ -d "$APP_BUNDLE" ]; then
  $XCRESULTTOOL get test-results summary --path "$APP_BUNDLE" --format json > "$APP_SUMMARY" 2>/dev/null || rm -f "$APP_SUMMARY"
fi
# Keep the numbers, not the bundle: the summary is a few KB, the .xcresult is tens of MB.
if [ "${FEEDMINE_KEEP_RESULT_BUNDLE:-0}" = "1" ]; then
  echo "   bundle kept: $APP_BUNDLE"
else
  rm -rf "$APP_BUNDLE"
fi
[ -s "$APP_SUMMARY" ] && echo "   summary: $APP_SUMMARY"

echo "   exit=$app_exit passed=$app_passed failed=$app_failed"
if [ "$app_exit" -ne 0 ]; then
  echo "   FAIL: xcodebuild exited $app_exit (log: $APP_LOG)"
  status=1
elif [ "${app_passed:-0}" -lt "$MIN_APP_TESTS" ]; then
  echo "   FAIL: the plan executed $app_passed tests, floor is $MIN_APP_TESTS (green with no tests is a failure)"
  status=1
elif [ "${app_failed:-1}" -ne 0 ]; then
  echo "   FAIL: $app_failed app test failures"
  status=1
else
  echo "   PASS: $app_passed app tests, 0 failures"
fi

echo ""
if [ "$status" -eq 0 ]; then
  echo "Runtime V2 test gate: PASS"
else
  echo "Runtime V2 test gate: FAIL"
fi
exit "$status"
