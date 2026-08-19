#!/usr/bin/env bash
# Integrity check for the fix-with-test fixture suite: every fixture's test must
# FAIL on the buggy source and PASS after reference.patch. No model needed. This
# is the CI guarantee that each fixture is a real bug with a known good fix, so a
# score on this suite means something was solved rather than a no-op passing.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$REPO/scripts/apply-and-test.sh"
# 01-05 are single-function bugs; 06-09 are the deliberately harder set.
pass=0; fail=0
assert_eq() { local e="$1" a="$2" n="$3"; if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (want $e got $a)"; fail=$((fail+1)); fi; }

for d in "$REPO"/experiments/fixtures/fix-with-test/*/; do
  name=$(basename "$d")
  # Buggy source fails its own test: a no-op patch (identity SEARCH/REPLACE)
  # leaves the bug in place, so apply-and-test must return FAIL (exit 1).
  noop=$(mktemp)
  firstline=$(head -1 "$d/source.py")
  printf '<<<<<<< SEARCH\n%s\n=======\n%s\n>>>>>>> REPLACE\n' "$firstline" "$firstline" > "$noop"
  # exit 1 = "the test did not pass" (an assertion failed OR the test errored on
  # import / at runtime); the reference.patch -> exit 0 leg below rules out a
  # never-passable fixture, so the pair together proves the fixture is real.
  EC=0; bash "$APPLY" "$d" "$noop" >/dev/null 2>&1 || EC=$?
  assert_eq 1 "$EC" "$name: buggy source fails its test"
  # reference.patch makes it pass (exit 0).
  EC=0; bash "$APPLY" "$d" "$d/reference.patch" >/dev/null 2>&1 || EC=$?
  assert_eq 0 "$EC" "$name: reference.patch makes the test pass"
  rm -f "$noop"
done
echo ""; echo "fix-with-test-fixtures: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
