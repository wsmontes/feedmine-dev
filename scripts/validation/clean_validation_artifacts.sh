#!/bin/bash
# FeedMine Validation — artifact retention
#
# Everything the validation runners produce is regenerable, and two of the directories are large
# (simulator derived data ~1 GB, SwiftPM build products ~1 GB). This script is the single purge
# point for them, so a machine that runs the gates does not silently accumulate tens of gigabytes.
#
# What each run keeps by default: a small JSON summary per gate plus the newest logs. The
# .xcresult bundles are removed after their summary is extracted, because the numbers are what the
# reports cite and the bundles are the bulk.
#
# Usage:
#   bash scripts/validation/clean_validation_artifacts.sh            # summaries + newest logs, drop bundles
#   bash scripts/validation/clean_validation_artifacts.sh --build    # also drop derived data and SwiftPM products
#   bash scripts/validation/clean_validation_artifacts.sh --tmp      # also drop this repo's leftovers in $TMPDIR
#   KEEP_LOGS=10 bash scripts/validation/clean_validation_artifacts.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS="$REPO_ROOT/Artifacts/Validation"
KEEP_LOGS="${KEEP_LOGS:-5}"

DROP_BUILD=0
DROP_TMP=0
for arg in "$@"; do
  case "$arg" in
    --build) DROP_BUILD=1 ;;
    --tmp) DROP_TMP=1 ;;
    --all) DROP_BUILD=1; DROP_TMP=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

before=$(du -sk "$REPO_ROOT" 2>/dev/null | awk '{print $1}')

echo "Validation artifacts under $ARTIFACTS"
if [ -d "$ARTIFACTS/Results" ]; then
  bundles=$(find "$ARTIFACTS/Results" -maxdepth 1 -name "*.xcresult" 2>/dev/null | wc -l | tr -d ' ')
  echo "  removing $bundles result bundle(s) (summaries in Results/Summaries are kept)"
  find "$ARTIFACTS/Results" -maxdepth 1 -name "*.xcresult" -exec rm -rf {} + 2>/dev/null
else
  echo "  no results directory"
fi

if [ -d "$ARTIFACTS/Logs" ]; then
  logs=$(find "$ARTIFACTS/Logs" -maxdepth 1 -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
  find "$ARTIFACTS/Logs" -maxdepth 1 -name "*.log" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | tail -n "+$((KEEP_LOGS + 1))" \
    | while IFS= read -r old; do rm -f "$old"; done
  after_logs=$(find "$ARTIFACTS/Logs" -maxdepth 1 -name "*.log" 2>/dev/null | wc -l | tr -d ' ')
  echo "  logs: $logs -> $after_logs (keeping newest $KEEP_LOGS)"
fi

if [ "$DROP_BUILD" -eq 1 ]; then
  for dir in "$REPO_ROOT/.build-dd" "$REPO_ROOT/Packages/FeedRuntimeV2/.build" "$REPO_ROOT/Packages/FeedRuntimeV2/.swiftpm"; do
    if [ -d "$dir" ]; then
      size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
      echo "  removing build products $dir ($size) — the next gate rebuilds them"
      rm -rf "$dir"
    fi
  done
fi

if [ "$DROP_TMP" -eq 1 ]; then
  # Only files this repository's runs create; other tools keep their own state in $TMPDIR.
  found=0
  while IFS= read -r stale; do
    [ -z "$stale" ] && continue
    rm -rf "$stale"; found=$((found + 1))
  done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 \( -name "feedruntime-tests-*" -o -name "*RuntimeV2*.xcresult" -o -name "pkg*.xcresult" -o -name "only.xcresult" \) 2>/dev/null)
  echo "  removed $found item(s) from ${TMPDIR:-/tmp}"
fi

after=$(du -sk "$REPO_ROOT" 2>/dev/null | awk '{print $1}')
echo "Repository footprint: $((before / 1024)) MB -> $((after / 1024)) MB"
echo "Sizes that also hold project caches (not touched here):"
du -sh "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Library/Caches/org.swift.swiftpm" 2>/dev/null | sed 's/^/  /'
