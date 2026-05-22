#!/usr/bin/env bash
# Unit tests for experiments/score-t8.sh.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/experiments/score-t8.sh"

pass=0
fail=0

assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle' in:\n$haystack)"; fail=$((fail+1)); fi
}

build_raw() {
  local out="$1"; shift
  : > "$out"
  echo "MODEL: test-model" >> "$out"
  echo "DATE: 2026-05-22T00:00:00Z" >> "$out"
  echo "REPS: $#" >> "$out"
  echo "" >> "$out"
  local rep=1
  for body in "$@"; do
    echo "===== T8-summarise-issue rep $rep =====" >> "$out"
    echo "DURATION_SEC: 5" >> "$out"
    echo "RUN_STATUS: 0" >> "$out"
    echo "OUTPUT:" >> "$out"
    printf '%s\n' "$body" >> "$out"
    echo "" >> "$out"
    rep=$((rep + 1))
  done
}

run_score() {
  bash "$SCRIPT" "$1" 2>&1
}

echo "=== score-t8.sh ==="

# --- Test 1: clean summary scores 6/6 ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## What happened

- 2026-05-13: user-a opened issue describing recipe stall against qwen3.6:35b-a3b-q8_0.
- 2026-05-13 (later): user-b bisected the stall to prompts above ~3KB.
- 2026-05-13 (later): maintainer added a pre-flight canary to delegate.sh.

## What's next

- maintainer will land the pre-flight canary PR today."
out=$(run_score "$raw")
assert_contains "T8_SUMMARY:" "$out" "test 1: emits T8_SUMMARY line"
assert_contains "rep 1: 6/6" "$out" "test 1: clean summary scores 6/6"
rm -rf "$sandbox"

# --- Test 2: missing What happened heading fails HAS_WHAT_HAPPENED ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## Timeline

- 2026-05-13: issue opened by user-a."
out=$(run_score "$raw")
assert_contains "HAS_WHAT_HAPPENED" "$out" "test 2: no What happened header → fail"
rm -rf "$sandbox"

# --- Test 3: preamble before first heading fails STARTS_WITH_SECTION ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "Here is the timeline summary as requested:

## What happened

- 2026-05-13: user-a opened the issue."
out=$(run_score "$raw")
assert_contains "STARTS_WITH_SECTION" "$out" "test 3: preamble → STARTS_WITH_SECTION fail"
rm -rf "$sandbox"

# --- Test 4: 'No blockers' placeholder fails NO_PLACEHOLDER_TEXT ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## What happened

- 2026-05-13: user-a opened the issue.

## What's blocking

- No blockers stated in the thread."
out=$(run_score "$raw")
assert_contains "NO_PLACEHOLDER_TEXT" "$out" "test 4: 'No blockers' placeholder → fail"
rm -rf "$sandbox"

# --- Test 5: 'TBD' as standalone token fails NO_PLACEHOLDER_TEXT ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## What happened

- 2026-05-13: user-a opened the issue.

## What's next

- TBD by the team next week."
out=$(run_score "$raw")
assert_contains "NO_PLACEHOLDER_TEXT" "$out" "test 5: 'TBD' standalone → fail"
rm -rf "$sandbox"

# --- Test 6: group-claim phrase fails NO_GROUP_CLAIM ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## What happened

- 2026-05-13: several people agreed that the recipe was at fault."
out=$(run_score "$raw")
assert_contains "NO_GROUP_CLAIM" "$out" "test 6: group-claim phrase → fail"
rm -rf "$sandbox"

# --- Test 7: padding tail fails NO_PADDING ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## What happened

- 2026-05-13: user-a opened issue describing the recipe stall, ensuring that future callers get fast-fail feedback."
out=$(run_score "$raw")
assert_contains "NO_PADDING" "$out" "test 7: padding tail → fail"
rm -rf "$sandbox"

# --- Test 8: no bullets under What happened fails WHAT_HAPPENED_BULLETS ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## What happened

The issue was opened by user-a and resolved by the maintainer."
out=$(run_score "$raw")
assert_contains "WHAT_HAPPENED_BULLETS" "$out" "test 8: no bullets → WHAT_HAPPENED_BULLETS fail"
rm -rf "$sandbox"

# --- Test 9: empty output fails everything ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" ""
out=$(run_score "$raw")
assert_contains "rep 1: 0/6" "$out" "test 9: empty → 0/6"
rm -rf "$sandbox"

# --- Test 10: multi-rep aggregation ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" \
  "## What happened

- 2026-05-13: user-a opened the issue." \
  "## What happened

- 2026-05-13: No blockers stated."
out=$(run_score "$raw")
assert_contains "reps: 2" "$out" "test 10: two reps detected"
assert_contains "rep 1: 6/6" "$out" "test 10: rep 1 clean"
assert_contains "NO_PLACEHOLDER_TEXT" "$out" "test 10: rep 2 placeholder caught"
rm -rf "$sandbox"

# --- Test 11: usage error on missing arg ---
out=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "usage:" "$out" "test 11: missing arg prints usage"

# --- Test 12: no T8 reps found in unrelated file ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
echo "MODEL: x" > "$raw"
echo "" >> "$raw"
echo "===== T1-doc-drift rep 1 =====" >> "$raw"
echo "OUTPUT:" >> "$raw"
echo "irrelevant" >> "$raw"
out=$(bash "$SCRIPT" "$raw" 2>&1 || true)
assert_contains "no T8 reps found" "$out" "test 12: no T8 reps → error"
rm -rf "$sandbox"

# --- Test 13: T8_SUMMARY machine-parseable shape ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "## What happened

- 2026-05-13: user-a opened the issue."
out=$(run_score "$raw")
assert_contains "T8_SUMMARY: reps=1 total_passed=6 total_checks=6 mean=1.0000" "$out" \
  "test 13: T8_SUMMARY shape"
rm -rf "$sandbox"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
