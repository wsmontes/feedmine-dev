#!/usr/bin/env python3
"""Resolve an xcodebuild destination from `-showdestinations` output (plan §15).

Reads the output of `xcodebuild -showdestinations` on stdin and prints one `id=…` line, or nothing when
no simulator is available.

Why this exists as a file rather than a pipeline in place:

* **The brace form is not an argument.** `-showdestinations` prints
  `{ platform:iOS Simulator, arch:…, id:…, OS:…, name:… }`, and `-destination` wants `key=value`. Passing
  the brace form through verbatim makes xcodebuild answer `option 'Destination' requires at least one
  parameter of the form 'key=value'` and exit 64 — which reads like a bad argument rather than a bad
  extraction. Both the iOS CI workflow and `scripts/validation/run_runtime_v2_tests.sh` had that bug until
  this file replaced their pipelines (baseline §8.22.2 records the CI half).
* **`sed` with bracket expressions trips on this output** (`[[:space:]}]+` is read as an unterminated POSIX
  class), and the two callers need the identical answer.
* **A YAML `run: |` block cannot hold an unindented Python heredoc**, so the workflow cannot inline it.

An iPhone simulator wins over anything else, because every suite this project ships targets one; the first
non-placeholder entry is the fallback.
"""

import re
import sys

PATTERN = re.compile(
    r"\{[^}]*platform:iOS Simulator[^}]*id:([^,\s}]+)[^}]*name:([^,}]+)[^}]*\}"
)


def resolve(lines):
    """Return the first preferred simulator id, or None."""
    fallback = None
    for line in lines:
        match = PATTERN.search(line)
        if not match:
            continue
        identifier, name = match.group(1), match.group(2).strip()
        if "placeholder" in identifier or "placeholder" in name:
            continue
        if fallback is None:
            fallback = identifier
        if name.startswith("iPhone"):
            return identifier
    return fallback


def main():
    identifier = resolve(sys.stdin)
    if identifier:
        print(f"id={identifier}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
