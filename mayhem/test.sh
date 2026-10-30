#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Mbed TLS's own test programs (built with normal flags by mayhem/build.sh):
# `selftest` (known-answer self-tests for every primitive) and a set of generated test_suite_*
# data-driven suites (X.509/PKCS#7/TLS parsing, PK, hashes, RSA, ECP, ...).
# Each suite prints a `PASSED (n / n tests (s skipped))` / `FAILED (f / n tests (s skipped))` summary and
# each selftest check prints `<name>: passed|failed`; a neutered binary prints none of that, so the
# oracle fails when the program under test does nothing.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Keep in sync with the test_suite_* targets in mayhem/build.sh.
TEST_SUITES="x509parse x509write pkcs7 ssl asn1parse base64 pem pk pkparse sha256 sha512 md rsa ecp"

passed=0 failed=0 skipped=0
log="$(mktemp)"

# selftest: one `<check>: passed|failed` line per known-answer test, then "[ All tests PASS ]".
st="$(find build-tests -name selftest -type f -perm -u+x | head -1)"
if [ -z "$st" ]; then echo "selftest binary missing (mayhem/build.sh builds it)" >&2; failed=$((failed+1))
else
  "$st" > "$log" 2>&1; rc=$?
  p=$(grep -c ': passed$' "$log"); f=$(grep -c ': failed$' "$log")
  if [ "$rc" -ne 0 ] || ! grep -q '\[ All tests PASS \]' "$log"; then
    echo "selftest did not report success (rc=$rc)" >&2; tail -5 "$log" >&2; f=$((f+1))
  fi
  # a real run has dozens of checks; a no-op reports none
  [ "$p" -ge 40 ] || { echo "selftest reported only $p passed checks" >&2; f=$((f+1)); }
  passed=$((passed+p)); failed=$((failed+f))
fi

# generated suites: run from the directory that holds the binary (ctest does the same).
for s in $TEST_SUITES; do
  bin="$(find build-tests -name "test_suite_$s" -type f -perm -u+x | head -1)"
  if [ -z "$bin" ]; then echo "test_suite_$s binary missing (mayhem/build.sh builds it)" >&2; failed=$((failed+1)); continue; fi
  ( cd "$(dirname "$bin")" && "./$(basename "$bin")" ) > "$log" 2>&1; rc=$?
  line="$(grep -E '^(PASSED|FAILED) \(' "$log" | tail -1)"
  if [[ "$line" =~ ^(PASSED|FAILED)\ \(([0-9]+)\ /\ ([0-9]+)\ tests\ \(([0-9]+)\ skipped\)\) ]]; then
    verdict="${BASH_REMATCH[1]}" a="${BASH_REMATCH[2]}" t="${BASH_REMATCH[3]}" sk="${BASH_REMATCH[4]}"
    if [ "$verdict" = PASSED ] && [ "$rc" -eq 0 ] && [ "$t" -gt "$sk" ]; then
      passed=$((passed + a - sk)); skipped=$((skipped + sk))
    else
      echo "test_suite_$s: $line (rc=$rc)" >&2; grep -E 'FAIL' "$log" | head -5 >&2
      if [ "$verdict" = FAILED ] && [ "$a" -gt 0 ]; then failed=$((failed + a)); else failed=$((failed+1)); fi
    fi
  else
    echo "test_suite_$s: no PASSED/FAILED summary (rc=$rc)" >&2; failed=$((failed+1))
  fi
done
rm -f "$log"

emit_ctrf "mbedtls-selftest-and-test-suites" "$passed" "$failed" "$skipped"
