#!/bin/bash
# FeedMine Validation — Smoke tests
#
# Fast functional gate intended to run on every PR.
# Uses Debug config + simulator + small fixtures.
#
# Usage:
#   ./scripts/validation/run_smoke.sh
#
# Overrides (all optional):
#   FEEDMINE_DESTINATION   full xcodebuild -destination string; wins over FEEDMINE_SIM_NAME
#   FEEDMINE_SIM_NAME      simulator name, default "iPhone 16" (discover with
#                          `xcodebuild -showdestinations -project feedmine.xcodeproj -scheme feedmine`)
#   FEEDMINE_RESULTS_DIR   where the .xcresult bundle and its log are written
#   FEEDMINE_XCODEBUILD    alternate xcodebuild executable; used by
#                          scripts/validation/test_run_smoke.sh to prove failure propagation
#
# Exit status is xcodebuild's exit status. The grep below only formats output for humans;
# it never decides the result.
#
# Only a small JSON summary is kept per run; the .xcresult is removed afterwards unless
# FEEDMINE_KEEP_RESULT_BUNDLE=1. Purge caches with
# `bash scripts/validation/clean_validation_artifacts.sh --build`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

XCODEBUILD="${FEEDMINE_XCODEBUILD:-xcodebuild}"
PROJECT="feedmine.xcodeproj"
SCHEME="feedmine"
DESTINATION="${FEEDMINE_DESTINATION:-platform=iOS Simulator,name=${FEEDMINE_SIM_NAME:-iPhone 16}}"
DERIVED_DATA="$REPO_ROOT/.build-dd"
RESULTS_DIR="${FEEDMINE_RESULTS_DIR:-$REPO_ROOT/Artifacts/Validation}"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_BUNDLE="$RESULTS_DIR/Results/Smoke-$TIMESTAMP.xcresult"
SUMMARY="$RESULTS_DIR/Results/Summaries/Smoke-$TIMESTAMP.json"
LOG="$RESULTS_DIR/Logs/Smoke-$TIMESTAMP.log"

mkdir -p "$(dirname "$RESULT_BUNDLE")" "$(dirname "$SUMMARY")" "$(dirname "$LOG")"

echo "🧪 Smoke tests"
echo "   Simulator: $DESTINATION"

set +e
"$XCODEBUILD" test \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -configuration Debug \
    -testPlan "FeedMine-Smoke" \
    -resultBundlePath "$RESULT_BUNDLE" \
    > "$LOG" 2>&1
EXIT_CODE=$?
set -e

grep -E "(Test Suite|Test Case.*failed|Executed|Failing|passed|failed)" "$LOG" || true

echo ""
echo "📊 Result: $( [ "$EXIT_CODE" -eq 0 ] && echo "PASS" || echo "FAIL" )"
echo "   Log:    $LOG"

# Keep the numbers, not the bundle: the summary is a few KB, the .xcresult is tens of MB.
if [ -d "$RESULT_BUNDLE" ]; then
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json > "$SUMMARY" 2>/dev/null || true
fi
if [ -s "$SUMMARY" ]; then
  echo "   Summary: $SUMMARY"
else
  rm -f "$SUMMARY"
fi
if [ "${FEEDMINE_KEEP_RESULT_BUNDLE:-0}" = "1" ]; then
  echo "   Bundle: $RESULT_BUNDLE"
else
  rm -rf "$RESULT_BUNDLE"
  echo "   Bundle: removed (FEEDMINE_KEEP_RESULT_BUNDLE=1 keeps it; clean_validation_artifacts.sh purges caches)"
fi

exit "$EXIT_CODE"
