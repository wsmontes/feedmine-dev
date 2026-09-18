#!/bin/bash
# Proves scripts/verify-runtime-v2-boundaries.sh fails on the violations it claims to catch.
# A gate that cannot fail is not a gate: this builds fixture package trees and asserts the
# script's verdict for each.
#
# Usage: bash scripts/validation/test_runtime_v2_boundaries.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/scripts/verify-runtime-v2-boundaries.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

MANIFEST='// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fixture",
    targets: [
        .target(name: "FeedDomain", dependencies: [], path: "Sources/FeedDomain"),
        .target(name: "FeedStorage", dependencies: ["FeedDomain", .product(name: "GRDB", package: "GRDB.swift")], path: "Sources/FeedStorage"),
        .target(name: "FeedRuntime", dependencies: ["FeedDomain", "FeedStorage"], path: "Sources/FeedRuntime"),
    ]
)
'

# make_fixture <dir> <feeddomain body> <feedstorage body> [manifest]
make_fixture() {
  local dir="$1" domain_body="$2" storage_body="$3" manifest="${4:-$MANIFEST}"
  mkdir -p "$dir/Sources/FeedDomain" "$dir/Sources/FeedStorage" "$dir/Sources/FeedRuntime"
  printf '%s\n' "$manifest" > "$dir/Package.swift"
  printf '%s\n' "$domain_body" > "$dir/Sources/FeedDomain/Domain.swift"
  printf '%s\n' "$storage_body" > "$dir/Sources/FeedStorage/Storage.swift"
  printf 'import Foundation\n' > "$dir/Sources/FeedRuntime/Runtime.swift"
}

# expect <label> <expected exit> <fixture dir>
expect() {
  local label="$1" want="$2" dir="$3" out got
  out="$(FEEDMINE_V2_ROOT="$dir" bash "$GATE" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass "$label (exit $got)"
  else
    fail "$label (exit $got, expected $want)"
    echo "$out" | sed 's/^/       /'
  fi
}

echo "=== boundary gate ==="

clean="$TMP_DIR/clean"
make_fixture "$clean" 'import Foundation' 'import Foundation
import GRDB'
expect "clean tree passes" 0 "$clean"

domain_grdb="$TMP_DIR/domain-grdb"
make_fixture "$domain_grdb" 'import Foundation
import GRDB' 'import Foundation'
expect "FeedDomain importing GRDB fails" 1 "$domain_grdb"

scoped_domain_grdb="$TMP_DIR/scoped-domain-grdb"
make_fixture "$scoped_domain_grdb" 'import Foundation
public import GRDB' 'import Foundation'
expect "scoped import cannot bypass FeedDomain GRDB rule" 1 "$scoped_domain_grdb"

runtime_grdb="$TMP_DIR/runtime-grdb"
make_fixture "$runtime_grdb" 'import Foundation' 'import Foundation
import GRDB'
printf 'import Foundation\nimport GRDB\n' > "$runtime_grdb/Sources/FeedRuntime/Runtime.swift"
expect "FeedRuntime importing GRDB directly fails" 1 "$runtime_grdb"

storage_feedkit="$TMP_DIR/storage-feedkit"
make_fixture "$storage_feedkit" 'import Foundation' 'import Foundation
import FeedKit'
expect "FeedStorage importing FeedKit fails" 1 "$storage_feedkit"

undeclared="$TMP_DIR/undeclared"
make_fixture "$undeclared" 'import Foundation' 'import Foundation
import GRDB' '// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fixture",
    targets: [
        .target(name: "FeedDomain", dependencies: [], path: "Sources/FeedDomain"),
        .target(name: "FeedStorage", dependencies: ["FeedDomain"], path: "Sources/FeedStorage"),
        .target(name: "FeedRuntime", dependencies: ["FeedDomain", "FeedStorage"], path: "Sources/FeedRuntime"),
    ]
)
'
expect "import without a manifest edge fails" 1 "$undeclared"

sibling_import="$TMP_DIR/sibling-import"
make_fixture "$sibling_import" 'import Foundation
import FeedStorage' 'import Foundation
import GRDB'
expect "FeedDomain importing FeedStorage fails" 1 "$sibling_import"

manifest_sibling="$TMP_DIR/manifest-sibling"
make_fixture "$manifest_sibling" 'import Foundation' 'import Foundation
import GRDB' '// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fixture",
    targets: [
        .target(name: "FeedDomain", dependencies: ["FeedStorage"], path: "Sources/FeedDomain"),
        .target(name: "FeedStorage", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Sources/FeedStorage"),
        .target(name: "FeedRuntime", dependencies: ["FeedDomain", "FeedStorage"], path: "Sources/FeedRuntime"),
    ]
)
'
expect "manifest edge from FeedDomain to FeedStorage fails" 1 "$manifest_sibling"

ui_storage="$TMP_DIR/ui-storage"
mkdir -p "$ui_storage/Sources/FeedDomain" "$ui_storage/Sources/FeedStorage" \
  "$ui_storage/Sources/FeedRuntime" "$ui_storage/Sources/FeedUIBridge"
cat > "$ui_storage/Package.swift" <<'MANIFEST'
 // swift-tools-version: 6.0
 import PackageDescription

 let package = Package(
     name: "Fixture",
     targets: [
         .target(name: "FeedDomain", dependencies: [], path: "Sources/FeedDomain"),
         .target(name: "FeedStorage", dependencies: ["FeedDomain"], path: "Sources/FeedStorage"),
         .target(name: "FeedRuntime", dependencies: ["FeedDomain", "FeedStorage"], path: "Sources/FeedRuntime"),
         .target(
             name: "FeedUIBridge",
             dependencies: ["FeedDomain", "FeedRuntime", "FeedStorage"],
             path: "Sources/FeedUIBridge"
         ),
     ]
 )
MANIFEST
printf 'import Foundation\n' > "$ui_storage/Sources/FeedDomain/Domain.swift"
printf 'import Foundation\nimport FeedDomain\n' > "$ui_storage/Sources/FeedStorage/Storage.swift"
printf 'import Foundation\nimport FeedDomain\nimport FeedStorage\n' > "$ui_storage/Sources/FeedRuntime/Runtime.swift"
printf 'import Foundation\nimport FeedDomain\nimport FeedRuntime\nimport FeedStorage\n' > "$ui_storage/Sources/FeedUIBridge/UI.swift"
expect "FeedUIBridge cannot depend on FeedStorage" 1 "$ui_storage"

echo ""
echo "=== the real package ==="
expect "Packages/FeedRuntimeV2 passes" 0 "$REPO_ROOT/Packages/FeedRuntimeV2"

echo ""
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================================="

[ "$FAIL" -eq 0 ] || exit 1
