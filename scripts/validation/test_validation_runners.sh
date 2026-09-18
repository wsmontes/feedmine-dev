#!/bin/bash
# Proves the validation runners report the real xcodebuild exit status.
#
# The regression this guards: both runners used to pipe xcodebuild into grep and then read
# ${PIPESTATUS[0]} after a `|| true`. When xcodebuild failed with output the filter did not
# match, `true` became the last command of the AND-OR list, PIPESTATUS reset to (0), and the
# runner printed PASS and exited 0 on a broken suite — the whole smoke/performance gate.
#
# No simulator, no Xcode build: xcodebuild is stubbed.
#
# Usage: bash scripts/validation/test_validation_runners.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SMOKE="$SCRIPT_DIR/run_smoke.sh"
RUN_PERFORMANCE="$SCRIPT_DIR/run_performance.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# stub_xcodebuild <exit code> <stdout line>
stub_xcodebuild() {
  cat > "$TMP_DIR/xcodebuild" <<STUB
#!/bin/bash
echo "stub xcodebuild \$*"
echo "$2"
exit $1
STUB
  chmod +x "$TMP_DIR/xcodebuild"
}

# stub_xcodebuild_split <build-for-testing exit> <test-without-building exit>
stub_xcodebuild_split() {
  cat > "$TMP_DIR/xcodebuild" <<STUB
#!/bin/bash
if [ "\$1" = "build-for-testing" ]; then exit $1; fi
echo "stub xcodebuild \$*"
echo "no test summary in this output"
exit $2
STUB
  chmod +x "$TMP_DIR/xcodebuild"
}

# run_case <runner> <name> <stub exit> <stub output> <expected exit> <expected summary word>
run_case() {
  local runner="$1" name="$2" stub_exit="$3" stub_out="$4" want_exit="$5" want_word="$6"
  stub_xcodebuild "$stub_exit" "$stub_out"
  local out got_exit
  out="$(FEEDMINE_XCODEBUILD="$TMP_DIR/xcodebuild" FEEDMINE_RESULTS_DIR="$TMP_DIR/artifacts" bash "$runner" 2>&1)"
  got_exit=$?
  if [ "$got_exit" -eq "$want_exit" ]; then
    pass "$name: exited $got_exit"
  else
    fail "$name: exited $got_exit, expected $want_exit"
  fi
  if grep -q "Result: $want_word" <<<"$out"; then
    pass "$name: summary says $want_word"
  else
    fail "$name: summary does not say $want_word (got: $(grep 'Result:' <<<"$out"))"
  fi
}

echo "=== run_smoke.sh exit code propagation ==="
# xcodebuild failed and printed nothing the display filter matches: the exact case the old
# `|| true` + PIPESTATUS bug turned into a PASS.
run_case "$RUN_SMOKE" "smoke: failure with unmatched output" 1 "no test summary in this output" 1 FAIL
run_case "$RUN_SMOKE" "smoke: failure with matched output" 1 "Executed 3 tests, with 1 failure" 1 FAIL
run_case "$RUN_SMOKE" "smoke: success" 0 "Executed 3 tests" 0 PASS
run_case "$RUN_SMOKE" "smoke: failure with no output" 2 "" 2 FAIL

echo ""
echo "=== run_smoke.sh cannot report PASS when it cannot start ==="
: > "$TMP_DIR/blocked"
stub_xcodebuild 0 "Executed 3 tests"
out="$(FEEDMINE_XCODEBUILD="$TMP_DIR/xcodebuild" FEEDMINE_RESULTS_DIR="$TMP_DIR/blocked/artifacts" bash "$RUN_SMOKE" 2>&1)"
got_exit=$?
if [ "$got_exit" -ne 0 ]; then
  pass "smoke: unwritable results dir exited $got_exit"
else
  fail "smoke: unwritable results dir exited 0"
fi

echo ""
echo "=== run_performance.sh exit code propagation ==="
# The build succeeds and the test run fails: the failure that must not be masked.
stub_xcodebuild_split 0 1
out="$(FEEDMINE_XCODEBUILD="$TMP_DIR/xcodebuild" FEEDMINE_RESULTS_DIR="$TMP_DIR/artifacts" bash "$RUN_PERFORMANCE" simulator 2>&1)"
got_exit=$?
if [ "$got_exit" -eq 1 ]; then
  pass "performance: failing test run exited 1"
else
  fail "performance: failing test run exited $got_exit, expected 1"
fi
if grep -q "Result: FAIL" <<<"$out"; then
  pass "performance: summary says FAIL"
else
  fail "performance: summary does not say FAIL"
fi

# Same runner, healthy test run: must stay PASS/0.
stub_xcodebuild_split 0 0
out="$(FEEDMINE_XCODEBUILD="$TMP_DIR/xcodebuild" FEEDMINE_RESULTS_DIR="$TMP_DIR/artifacts" bash "$RUN_PERFORMANCE" simulator 2>&1)"
got_exit=$?
if [ "$got_exit" -eq 0 ]; then
  pass "performance: successful run exited 0"
else
  fail "performance: successful run exited $got_exit, expected 0"
fi

echo ""
echo "=== run_runtime_v2_tests.sh exit codes and floors ==="
# This gate has four ways to be wrong: the package half failing, the app half failing, either half
# executing zero tests (plan §15: a green run that selected nothing is a failure), and the destination
# discovery finding nothing. All four are proven with stubs, because the real halves need a simulator
# and a build.
RUN_RUNTIME_V2="$SCRIPT_DIR/run_runtime_v2_tests.sh"

# stub_rv2 <emit destination> <xcodebuild test exit> <swift exit> <package executed> <app passed> <app failed>
stub_rv2() {
  cat > "$TMP_DIR/xcodebuild" <<STUB
#!/bin/bash
for arg in "\$@"; do
  if [ "\$arg" = "-showdestinations" ]; then
    [ "$1" = "0" ] || echo "    { platform:iOS Simulator, arch:arm64, id:STUB-DEVICE, OS:26.5, name:iPhone Stub }"
    exit 0
  fi
done
echo "stub xcodebuild \$*"
exit $2
STUB
  cat > "$TMP_DIR/swift" <<STUB
#!/bin/bash
echo "Executed $4 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
exit $3
STUB
  cat > "$TMP_DIR/xcresulttool" <<STUB
#!/bin/bash
echo '{"passedTests": $5, "failedTests": $6}'
exit 0
STUB
  chmod +x "$TMP_DIR/xcodebuild" "$TMP_DIR/swift" "$TMP_DIR/xcresulttool"
}

rv2_case() {
  local name="$1" want_exit="$2"
  local out got_exit
  out="$(FEEDMINE_XCODEBUILD="$TMP_DIR/xcodebuild" FEEDMINE_SWIFT="$TMP_DIR/swift" \
        FEEDMINE_XCRESULTTOOL="$TMP_DIR/xcresulttool" FEEDMINE_RESULTS_DIR="$TMP_DIR/artifacts" \
        bash "$RUN_RUNTIME_V2" 2>&1)"
  got_exit=$?
  if [ "$got_exit" -eq "$want_exit" ]; then
    pass "$name: exited $got_exit"
  else
    fail "$name: exited $got_exit, expected $want_exit"
  fi
}

stub_rv2 1 0 1 500 590 0
rv2_case "runtime-v2: package half failed" 1

stub_rv2 1 1 0 500 0 3
rv2_case "runtime-v2: app half failed" 1

stub_rv2 1 0 0 0 590 0
rv2_case "runtime-v2: zero package tests executed (floor)" 1

stub_rv2 0 0 0 500 590 0
rv2_case "runtime-v2: no discoverable destination" 2

stub_rv2 1 0 0 500 590 0
rv2_case "runtime-v2: both halves healthy" 0

echo ""
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================================="

[ "$FAIL" -eq 0 ] || exit 1
