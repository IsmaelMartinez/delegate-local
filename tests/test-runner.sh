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

# 5. Default OLLAMA_API value is 1 in the header (the API path became the
# default 2026-05-13; the legacy `ollama run` CLI path is now opt-in via
# --ollama-cli). We can't run the model end-to-end here (no live ollama/mlx
# in CI), but we can verify by pointing at an unreachable host and
# inspecting the header lines that are written before any inference.
tmp=$(mktemp -d)
slug="some-model"
raw="$REPO/experiments/results/raw/${slug}.txt"

EC=0
OLLAMA_HOST="http://127.0.0.1:1" \
  out=$(bash "$SCRIPT" --backend ollama --reps 1 some-model 2>&1) || EC=$?
if [[ -f "$raw" ]]; then
  header=$(head -10 "$raw")
  assert_contains "OLLAMA_API: 1" "$header" "default OLLAMA_API header is 1"
  rm -f "$raw"
fi

# 6. --ollama-cli flips the header back to OLLAMA_API: 0 for legacy CLI runs.
EC=0
OLLAMA_HOST="http://127.0.0.1:1" \
  out=$(bash "$SCRIPT" --backend ollama --ollama-cli --reps 1 some-model 2>&1) || EC=$?
if [[ -f "$raw" ]]; then
  header=$(head -10 "$raw")
  assert_contains "OLLAMA_API: 0" "$header" "--ollama-cli flips OLLAMA_API header to 0"
  rm -f "$raw"
fi

# 7. --ollama-api is accepted as a deprecated no-op (back-compat with PRs
# #114 / #115 scripted invocations).
EC=0
OLLAMA_HOST="http://127.0.0.1:1" \
  out=$(bash "$SCRIPT" --backend ollama --ollama-api --reps 1 some-model 2>&1) || EC=$?
if [[ -f "$raw" ]]; then
  header=$(head -10 "$raw")
  assert_contains "OLLAMA_API: 1" "$header" "--ollama-api no-op keeps header at 1"
  rm -f "$raw"
fi

rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
