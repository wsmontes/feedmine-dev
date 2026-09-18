#!/bin/bash
# FeedMine Validation — Performance tests
#
# Performance gate using Release config, serial execution, and local fixtures.
# For official baselines, target a physical device (FEEDMINE_DEVICE_ID).
# Without a device, runs on simulator with INCONCLUSIVE status for physical gates.
#
# Usage:
#   # Simulator (informative only):
#   ./Scripts/validation/run_performance.sh
#
#   # Physical device (official baseline):
#   FEEDMINE_DEVICE_ID=00008110-00067D861486201E ./Scripts/validation/run_performance.sh device
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
PLATFORM="${1:-simulator}"

if [ "$PLATFORM" = "device" ]; then
    DEVICE_ID="${FEEDMINE_DEVICE_ID:-}"
    if [ -z "$DEVICE_ID" ]; then
        echo "❌ FEEDMINE_DEVICE_ID is required for physical device testing"
        echo "   Example: FEEDMINE_DEVICE_ID=00008110-00067D861486201E $0 device"
        exit 1
    fi
    DESTINATION="platform=iOS,id=$DEVICE_ID"
    DERIVED_DATA="$REPO_ROOT/.build-device"
    CONFIG="Release"
else
    SIM_NAME="${FEEDMINE_SIM_NAME:-iPhone 16}"
    DESTINATION="${FEEDMINE_DESTINATION:-platform=iOS Simulator,name=$SIM_NAME}"
    DERIVED_DATA="$REPO_ROOT/.build-dd"
    CONFIG="Release"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="${FEEDMINE_RESULTS_DIR:-$REPO_ROOT/Artifacts/Validation}"
RESULT_BUNDLE="$RESULTS_DIR/Results/Performance-$TIMESTAMP.xcresult"
SUMMARY="$RESULTS_DIR/Results/Summaries/Performance-$TIMESTAMP.json"
LOG="$RESULTS_DIR/Logs/Performance-$TIMESTAMP.log"

mkdir -p "$(dirname "$RESULT_BUNDLE")" "$(dirname "$SUMMARY")" "$(dirname "$LOG")"

echo "⚡ Performance tests"
echo "   Config:      $CONFIG"
echo "   Platform:    $PLATFORM"
echo "   Destination: $DESTINATION"

# Step 1: Build for testing
echo ""
echo "🔨 Building for testing..."
"$XCODEBUILD" build-for-testing \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    2>&1 | tail -3

# Step 2: Test without building (serial execution). The exit status of xcodebuild is the
# runner's status; the grep below only formats output for humans.
echo ""
echo "⚡ Running performance tests..."
set +e
"$XCODEBUILD" test-without-building \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -testPlan "FeedMine-Performance" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$RESULT_BUNDLE" \
    > "$LOG" 2>&1
EXIT_CODE=$?
set -e

grep -E "(Test Suite|Test Case.*failed|Executed|Failing|passed|failed)" "$LOG" || true

echo ""
echo "📊 Result: $( [ "$EXIT_CODE" -eq 0 ] && echo "PASS" || echo "FAIL" )"
if [ "$PLATFORM" != "device" ]; then
    echo "⚠️  Simulator results are INFORMATIVE only — physical device gate is INCONCLUSIVE"
fi
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
