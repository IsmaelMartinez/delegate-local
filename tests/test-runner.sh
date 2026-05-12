#!/usr/bin/env bash
# Argument-parsing tests for experiments/runner.sh.
# The actual ollama interaction is not tested here (it's exercised by the
# real baseline run); this file just locks in the CLI surface.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/experiments/runner.sh"

pass=0
fail=0

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected '$expected', got '$actual')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}

echo "=== runner.sh argument parsing ==="

# 1. No args -> usage error.
EC=0
out=$(bash "$SCRIPT" 2>&1) || EC=$?
assert_eq "2" "$EC" "no args -> exit 2"
assert_contains "usage:" "$out" "no args -> usage on stderr"

# 2. --reps requires a positive integer.
EC=0
out=$(bash "$SCRIPT" --reps 0 model 2>&1) || EC=$?
assert_eq "2" "$EC" "--reps 0 -> exit 2"

EC=0
out=$(bash "$SCRIPT" --reps abc model 2>&1) || EC=$?
assert_eq "2" "$EC" "--reps non-numeric -> exit 2"

# 3. Unknown flag -> exit 2.
EC=0
out=$(bash "$SCRIPT" --bogus 2>&1) || EC=$?
assert_eq "2" "$EC" "unknown flag -> exit 2"

# 4. Missing T3 snapshot file -> exit 1 with available snapshots listed.
EC=0
out=$(bash "$SCRIPT" --t3-snapshot 1999-01-01 some-model 2>&1) || EC=$?
assert_eq "1" "$EC" "missing T3 snapshot -> exit 1"
assert_contains "available snapshots:" "$out" "missing snapshot -> lists available"
assert_contains "task-3-merge-patterns-2026-04-28.txt" "$out" "missing snapshot -> shows real one"

# 5. --ollama-api is accepted and recorded in the raw output header.
# We can't run the model end-to-end here (no live ollama/mlx in CI),
# but we can verify the flag is parsed by feeding it an unreachable host
# and inspecting the header that gets written before the first curl call.
tmp=$(mktemp -d)
TMP_RESULTS="$tmp/results"
# Point the runner at our temp results dir via a sed-replaced copy.
# Simpler: run with an unreachable host so curl fails fast on first task,
# then inspect the header lines (which are written before any inference).
EC=0
OLLAMA_HOST="http://127.0.0.1:1" \
  out=$(bash "$SCRIPT" --backend ollama --ollama-api --reps 1 some-model 2>&1) || EC=$?
slug="some-model"
raw="$REPO/experiments/results/raw/${slug}.txt"
if [[ -f "$raw" ]]; then
  header=$(head -10 "$raw")
  assert_contains "OLLAMA_API: 1" "$header" "--ollama-api flips OLLAMA_API header to 1"
  rm -f "$raw"
fi

# 6. Default OLLAMA_API value is 0 in the header.
EC=0
OLLAMA_HOST="http://127.0.0.1:1" \
  out=$(bash "$SCRIPT" --backend ollama --reps 1 some-model 2>&1) || EC=$?
if [[ -f "$raw" ]]; then
  header=$(head -10 "$raw")
  assert_contains "OLLAMA_API: 0" "$header" "default OLLAMA_API header is 0"
  rm -f "$raw"
fi

rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
