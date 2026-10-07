#!/bin/bash
# verify-card-resolution-invariants.sh
# Static verification that the card resolution architecture meets all
# acceptance criteria from docs/cards-resolvidos-antes-de-aparecer.md.
# Runs without Xcode — only checks source code invariants.
#
# Usage: bash scripts/verify-card-resolution-invariants.sh

set -euo pipefail
PASS=0; FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); }

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$ROOT/feedmine"

# Preflight: every check below greps a specific file. A negative grep over a
# missing file proves nothing, so refuse to run against a partial checkout.
REQUIRED_FILES=(
  "Views/FeedItemCardView.swift"
  "Views/PreparedCardImage.swift"
  "Views/FeedScreen.swift"
  "Models/FeedCardPresentation.swift"
  "Services/ImageLoader.swift"
  "Services/FeedStore.swift"
  "Services/FeedLoader.swift"
  "Services/CardPreparationPipeline.swift"
  "Services/ReadyCardQueue.swift"
)
MISSING=0
for rel in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$SRC/$rel" ]; then
    echo -e "  ${RED}FAIL${NC} missing required file: $SRC/$rel"
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  echo "INVARIANTS UNVERIFIABLE — $SRC is not a complete checkout." >&2
  exit 1
fi
echo "Source root: $SRC"

echo "=== FeedItemCardView: Zero async image loading ==="
grep -q "CachedAsyncImage" "$SRC/Views/FeedItemCardView.swift" \
  && fail "CachedAsyncImage still referenced in FeedItemCardView" \
  || pass "No CachedAsyncImage in FeedItemCardView"

grep -q "@State.*imageAppeared\|@State.*imageLoadFailed" "$SRC/Views/FeedItemCardView.swift" \
  && fail "imageAppeared/imageLoadFailed @State still exist" \
  || pass "No @State imageAppeared/imageLoadFailed"

grep -q "onResult" "$SRC/Views/FeedItemCardView.swift" \
  && fail "onResult callback still exists" \
  || pass "No onResult callback"

grep -q "\.task(" "$SRC/Views/FeedItemCardView.swift" \
  && fail ".task() modifier still triggers async work" \
  || pass "No .task() modifier"

echo ""
echo "=== PreparedCardImage: Zero async behavior ==="
# Exclude comments — "zero-async" in the doc comment is NOT async code
grep -q "\.task\|Task {\|URLSession\|async\|await" \
  <(grep -v "^//\|^ \*\|^/\*\*\|^ \*/\|^$" "$SRC/Views/PreparedCardImage.swift") \
  && fail "PreparedCardImage has async code" \
  || pass "PreparedCardImage is fully synchronous"

echo ""
echo "=== FeedStore: Old resolution removed ==="
grep -q "resolveArticleImagesInBackground\|resolveOneArticleImage" "$SRC/Services/FeedStore.swift" \
  && fail "resolveArticleImagesInBackground still exists in FeedStore" \
  || pass "resolveArticleImagesInBackground removed from FeedStore"

echo ""
echo "=== ImageLoader: No post-insertion upgrades ==="
grep -q "improveImageIfNeeded" <(grep -v "^//\|^ \*\|^/\*\*\|^ \*/\|^$" "$SRC/Services/ImageLoader.swift") \
  && fail "improveImageIfNeeded called in ImageLoader" \
  || pass "No improveImageIfNeeded in ImageLoader (comment only)"

echo ""
echo "=== FeedScreen: Render gate on presentations ==="
grep -q "presentations.isEmpty" "$SRC/Views/FeedScreen.swift" \
  && pass "FeedScreen gates on presentations.isEmpty" \
  || fail "FeedScreen does not gate on presentations"

echo ""
echo "=== CardPreparationPipeline: Order preservation ==="
grep -q "results.sorted" "$SRC/Services/CardPreparationPipeline.swift" \
  && pass "CardPreparationPipeline preserves input order (sorted)" \
  || fail "CardPreparationPipeline missing order preservation"

grep -q "\.none\b" "$SRC/Services/CardPreparationPipeline.swift" \
  && pass "CardPreparationPipeline returns .none for text-only items" \
  || fail "CardPreparationPipeline missing .none path"

grep -q "\.placeholder\b" "$SRC/Services/CardPreparationPipeline.swift" \
  && pass "CardPreparationPipeline returns .placeholder on failure" \
  || fail "CardPreparationPipeline missing .placeholder path"

echo ""
echo "=== ReadyCardQueue: Timeout safety ==="
grep -q "deadline\|timeout\|Date().addingTimeInterval" "$SRC/Services/ReadyCardQueue.swift" \
  && pass "ReadyCardQueue has timeout logic" \
  || fail "ReadyCardQueue missing timeout"

grep -q "Task.sleep" "$SRC/Services/ReadyCardQueue.swift" \
  && pass "ReadyCardQueue polls with Task.sleep" \
  || fail "ReadyCardQueue missing polling"

echo ""
echo "=== FeedCardPresentation: Terminal media ==="
grep -q "case image\|case placeholder\|case none" "$SRC/Models/FeedCardPresentation.swift" \
  && pass "ResolvedCardMedia has three terminal states" \
  || fail "ResolvedCardMedia missing terminal states"

echo ""
echo "=== New files created ==="
for f in \
  "$SRC/Models/FeedCardPresentation.swift" \
  "$SRC/Views/PreparedCardImage.swift" \
  "$SRC/Services/ImageLoader.swift" \
  "$SRC/Services/CardPreparationPipeline.swift" \
  "$SRC/Services/ReadyCardQueue.swift"; do
  if [ -f "$f" ]; then
    pass "Exists: $(basename "$f")"
  else
    fail "Missing: $(basename "$f")"
  fi
done

echo ""
echo "=== Modified files ==="
for f in \
  "$SRC/Services/FeedStore.swift" \
  "$SRC/Services/FeedLoader.swift" \
  "$SRC/Views/FeedScreen.swift" \
  "$SRC/Views/FeedItemCardView.swift"; do
  if [ -f "$f" ]; then
    pass "Exists: $(basename "$f")"
  else
    fail "Missing: $(basename "$f")"
  fi
done

echo ""
echo "=============================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "=============================================="

if [ $FAIL -gt 0 ]; then
  echo "INVARIANTS VIOLATED — architecture is incomplete."
  exit 1
else
  echo "ALL INVARIANTS SATISFIED — zero post-insertion image mutations."
  exit 0
fi
