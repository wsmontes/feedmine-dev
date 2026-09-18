#!/bin/bash
# verify-runtime-v2-boundaries.sh
#
# Architecture gate for the Runtime V2 package: the module graph in
# Packages/FeedRuntimeV2 must match the dependency table in the migration plan
# (docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md §3).
#
# Two independent checks, because either one alone can be fooled:
#   1. imports — every `import X` in a target's sources must be in that target's allowed set;
#      this is what actually couples code, and it catches an implementation that reaches for
#      GRDB/FeedKit/SwiftUI without declaring the edge;
#   2. manifest — every external product named in a target's `dependencies:` in Package.swift
#      must be allowed for that target, and no target may depend on a sibling it is forbidden
#      to see.
#
# The gate is proven to fail when it should by scripts/validation/test_runtime_v2_boundaries.sh,
# which runs this script against fixture trees (one clean, several violating).
#
# Usage:
#   bash scripts/verify-runtime-v2-boundaries.sh
#   FEEDMINE_V2_ROOT=/path/to/package bash scripts/verify-runtime-v2-boundaries.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="${FEEDMINE_V2_ROOT:-$REPO_ROOT/Packages/FeedRuntimeV2}"

if [ ! -f "$ROOT/Package.swift" ]; then
  echo "FAIL: no Package.swift under $ROOT"
  exit 2
fi

python3 - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]

# Plan §3 table. "allowed" is exhaustive: an import that is not listed is a violation.
RULES = {
    "FeedDomain": {
        "allowed": {"Foundation"},
        "forbidden_siblings": {"FeedStorage", "FeedRuntime", "FeedConnectorSyndication", "FeedMedia", "FeedUIBridge"},
        "forbidden_products": {"GRDB", "FeedKit", "SwiftUI", "UIKit", "ImageIO"},
    },
    "FeedStorage": {
        "allowed": {"Foundation", "FeedDomain", "GRDB"},
        "forbidden_siblings": {"FeedRuntime", "FeedConnectorSyndication", "FeedMedia", "FeedUIBridge"},
        "forbidden_products": {"FeedKit", "SwiftUI", "UIKit"},
    },
    "FeedRuntime": {
        "allowed": {"Foundation", "FeedDomain", "FeedStorage"},
        "forbidden_siblings": {"FeedConnectorSyndication", "FeedMedia", "FeedUIBridge"},
        "forbidden_products": {"GRDB", "FeedKit", "SwiftUI", "UIKit"},
    },
    "FeedConnectorSyndication": {
        "allowed": {"Foundation", "FeedDomain", "FeedKit"},
        "forbidden_siblings": {"FeedStorage", "FeedRuntime", "FeedMedia", "FeedUIBridge"},
        "forbidden_products": {"GRDB", "SwiftUI", "UIKit"},
    },
    "FeedMedia": {
        "allowed": {"Foundation", "FeedDomain", "ImageIO", "UIKit", "CoreGraphics", "UniformTypeIdentifiers"},
        "forbidden_siblings": {"FeedStorage", "FeedRuntime", "FeedConnectorSyndication", "FeedUIBridge"},
        "forbidden_products": {"GRDB", "FeedKit"},
    },
    "FeedUIBridge": {
        "allowed": {"Foundation", "FeedDomain", "FeedRuntime", "FeedStorage", "SwiftUI", "UIKit", "Observation"},
        "forbidden_siblings": {"FeedConnectorSyndication", "FeedMedia"},
        "forbidden_products": {"GRDB", "FeedKit"},
    },
}

SIBLINGS = set(RULES)

# Modules provided by the package's external dependencies: importing one without declaring the
# edge in Package.swift only works by accident of a transitive dependency, and it hides the
# coupling the boundary table is meant to make explicit.
PRODUCT_EDGES = {"GRDB": "GRDB", "FeedKit": "FeedKit"}
violations = []
checked_files = 0
checked_imports = 0

def swift_files(directory):
    for dirpath, _dirnames, filenames in os.walk(directory):
        for name in sorted(filenames):
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)

manifest_path = os.path.join(root, "Package.swift")
manifest = open(manifest_path, encoding="utf-8").read()
declared_targets = set(re.findall(r"\.(?:target|testTarget)\(\s*name:\s*\"([^\"]+)\"", manifest))

# A target directory without a manifest entry is a module nobody declared.
sources_root = os.path.join(root, "Sources")
if os.path.isdir(sources_root):
    for name in sorted(os.listdir(sources_root)):
        if os.path.isdir(os.path.join(sources_root, name)) and name not in declared_targets:
            violations.append(f"{name}: sources exist but no target declares them in Package.swift")

inactive = sorted(set(RULES) - declared_targets)

# 1. imports
for target, rule in sorted(RULES.items()):
    if target not in declared_targets:
        continue
    for sources_dir in (os.path.join(root, "Sources", target),):
        if not os.path.isdir(sources_dir):
            violations.append(f"{target}: declared in Package.swift but has no sources directory")
            continue
        for path in swift_files(sources_dir):
            checked_files += 1
            with open(path, encoding="utf-8") as handle:
                for lineno, line in enumerate(handle, start=1):
                    match = re.match(r"\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", line)
                    if not match:
                        continue
                    module = match.group(1)
                    checked_imports += 1
                    if module in rule["forbidden_siblings"]:
                        violations.append(
                            f"{target}: forbidden sibling import '{module}' at {path}:{lineno}"
                        )
                    elif module in rule["forbidden_products"]:
                        violations.append(
                            f"{target}: forbidden module '{module}' at {path}:{lineno}"
                        )
                    elif module not in rule["allowed"]:
                        violations.append(
                            f"{target}: undeclared import '{module}' at {path}:{lineno} "
                            f"(allowed: {', '.join(sorted(rule['allowed']))})"
                        )

# 2. manifest edges
for target, rule in sorted(RULES.items()):
    if target not in declared_targets:
        continue
    block = re.search(
        r"\.(?:target|testTarget)\(\s*name:\s*\"" + re.escape(target) + r"\",\s*dependencies:\s*\[(.*?)\]\s*,",
        manifest,
        re.DOTALL,
    )
    declared = set()
    declared_products = set()
    if block:
        body = block.group(1)
        declared_products = set(re.findall(r"\.product\(name:\s*\"([^\"]+)\"", body))
        plain = re.sub(r"\.product\([^)]*\)", "", body)
        declared = declared_products | set(re.findall(r"\"([^\"]+)\"", plain))
    for name in sorted(declared):
        if name in rule["forbidden_siblings"] or name in rule["forbidden_products"]:
            violations.append(f"{target}: manifest declares forbidden dependency '{name}'")
        elif name not in rule["allowed"]:
            violations.append(f"{target}: manifest declares undeclared dependency '{name}'")
    # A dependency on the package's own products must be expressible: catch a target that
    # declares nothing while its sources import a sibling.
    imported_modules = set()
    sources_dir = os.path.join(root, "Sources", target)
    if os.path.isdir(sources_dir):
        for path in swift_files(sources_dir):
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    match = re.match(r"\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", line)
                    if match:
                        imported_modules.add(match.group(1))
    imported_siblings = imported_modules & SIBLINGS
    for name in sorted(imported_siblings - declared):
        violations.append(f"{target}: sources import '{name}' but the manifest does not declare it")
    for module, product in sorted(PRODUCT_EDGES.items()):
        if module in imported_modules and product not in declared_products:
            violations.append(
                f"{target}: sources import '{module}' but the manifest does not declare "
                f"the product '{product}'"
            )

print(f"boundary gate: {checked_files} source files, {checked_imports} imports, root={root}")
if inactive:
    print(f"note: targets not declared in Package.swift, not enforced: {', '.join(inactive)}")
if violations:
    print(f"FAIL: {len(violations)} boundary violation(s)")
    for violation in violations:
        print(f"  {violation}")
    sys.exit(1)
print("PASS: module boundaries match the plan")
PY
status=$?
exit $status
