#!/usr/bin/env bash
# Integrity check for the fan-out fixture suite: every fixture's test must FAIL
# on the buggy source and PASS after reference.patch. No model needed — this is
# the CI guarantee that each fixture has real single-shot headroom and a known
# good fix, which is what the eval harness's "best-of-N" measurement relies on.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$REPO/scripts/apply-and-test.sh"
# Both the canonical (easy, baseline) and the -hard (headroom) fixture dirs.
pass=0; fail=0
assert_eq() { local e="$1" a="$2" n="$3"; if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1)); else echo "  FAIL  $n (want $e got $a)"; fail=$((fail+1)); fi; }

for d in "$REPO"/experiments/fixtures/fanout/*/ "$REPO"/experiments/fixtures/fanout-hard/*/; do
  name=$(basename "$d")
  # Buggy source fails its own test: a no-op patch (identity SEARCH/REPLACE)
  # leaves the bug in place, so apply-and-test must return FAIL (exit 1).
  noop=$(mktemp)
  firstline=$(head -1 "$d/source.py")
  printf '<<<<<<< SEARCH\n%s\n=======\n%s\n>>>>>>> REPLACE\n' "$firstline" "$firstline" > "$noop"
  # exit 1 = "the test did not pass" (an assertion failed OR the test errored on
  # import / at runtime); the reference.patch -> exit 0 leg below rules out a
  # never-passable fixture, so the pair together proves real single-shot headroom.
  EC=0; bash "$APPLY" "$d" "$noop" >/dev/null 2>&1 || EC=$?
  assert_eq 1 "$EC" "$name: buggy source fails its test"
  # reference.patch makes it pass (exit 0).
  EC=0; bash "$APPLY" "$d" "$d/reference.patch" >/dev/null 2>&1 || EC=$?
  assert_eq 0 "$EC" "$name: reference.patch makes the test pass"
  rm -f "$noop"
done
echo ""; echo "fanout-fixtures: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
