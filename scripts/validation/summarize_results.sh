#!/bin/bash
# FeedMine Validation — Summarize .xcresult bundles into Markdown
#
# Usage:
#   ./Scripts/validation/summarize_results.sh Artifacts/Validation/Results/*.xcresult
set -euo pipefail

# A bundle whose summary is missing, unparseable, or free of an executed-test
# count is INCONCLUSIVE: this script must not announce a pass without data.
# Exit status: 0 only when every bundle reports executed tests and no failures.
SUMMARY_PROGRAM=$(cat <<'PY'
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception as error:  # empty stdin, truncated JSON, xcresulttool failure
    print(f"_Unable to parse xcresult: {error}_")
    print("_Run `xcrun xcresulttool get --path <bundle> --format json` manually_")
    print("")
    sys.exit(1)

issues = data.get("issues", {})
test_failures = issues.get("testFailureSummaries") or []
if test_failures:
    print(f"  ❌ {len(test_failures)} failure(s):")
    for failure in test_failures[:10]:
        name = failure.get("testCaseName", "?")
        message = failure.get("message", "")
        print(f"  - {name}: {message[:120]}")
    print("")
    sys.exit(1)

tests = data.get("metrics", {}).get("testsCount", {})
tests_count = tests.get("value") if isinstance(tests, dict) else None
if not isinstance(tests_count, int) or tests_count <= 0:
    print("  ⚠️  No executed-test count in this bundle — INCONCLUSIVE, not a pass")
    print("")
    sys.exit(1)

print(f"  Tests: {tests_count}")
print("  Failures: 0")
print("")
print("✅ All tests passed")
PY
)

echo "# FeedMine Test Results"
echo ""
echo "**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "**Commit:** $(git rev-parse --short HEAD)"
echo "**Branch:** $(git branch --show-current)"
echo ""

STATUS=0
for BUNDLE in "$@"; do
    if [ ! -d "$BUNDLE" ]; then
        echo "⚠️  Skipping missing bundle: $BUNDLE"
        STATUS=1
        continue
    fi

    BUNDLE_NAME="$(basename "$BUNDLE" .xcresult)"
    echo "## $BUNDLE_NAME"
    echo ""

    bundle_status=0
    xcrun xcresulttool get --path "$BUNDLE" --format json 2>/dev/null \
        | python3 -c "$SUMMARY_PROGRAM" || bundle_status=$?
    if [ "$bundle_status" -ne 0 ]; then
        echo "_Bundle $BUNDLE_NAME failed or was inconclusive — see the raw bundle_"
        echo ""
        STATUS=1
    fi
done

echo ""
echo "---"
echo ""
echo "## Environment"
echo ""
echo "- **Xcode:** $(xcodebuild -version | head -1)"
echo "- **macOS:** $(sw_vers -productVersion)"
echo "- **Arch:** $(uname -m)"
echo "- **Host:** $(hostname)"

exit "$STATUS"
