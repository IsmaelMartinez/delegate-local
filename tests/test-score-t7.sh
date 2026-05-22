#!/usr/bin/env bash
# Unit tests for experiments/score-t7.sh.
# Builds synthetic raw output files (T7 scoring is structural, not
# citation-based) and asserts each of the six checks fires as documented.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/experiments/score-t7.sh"

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
    echo "===== T7-file-summary rep $rep =====" >> "$out"
    echo "DURATION_SEC: 3" >> "$out"
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

echo "=== score-t7.sh ==="

# --- Test 1: clean one-sentence summary scores 6/6 ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "CloudWAN was accepted over Transit Gateway because the global routing model handles cross-region intent at the policy layer."
out=$(run_score "$raw")
assert_contains "T7_SUMMARY:" "$out" "test 1: emits T7_SUMMARY line"
assert_contains "rep 1: 6/6" "$out" "test 1: clean summary scores 6/6"
assert_contains "mean=1.0000" "$out" "test 1: mean is 1.0"
rm -rf "$sandbox"

# --- Test 2: multi-line output fails SINGLE_LINE ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "The 3-axis grid surfaces one new regime cell missed by the 2-axis grid because slope conditioning reveals heterogeneity.

This is an extra paragraph the model emitted in violation of the recipe."
out=$(run_score "$raw")
assert_contains "SINGLE_LINE" "$out" "test 2: multi-line → SINGLE_LINE fail"
rm -rf "$sandbox"

# --- Test 3: bare past-tense opener fails SUBJECT_LED ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "Confirmed CloudWAN adoption because the global routing model handles cross-region intent at the policy layer."
out=$(run_score "$raw")
assert_contains "SUBJECT_LED" "$out" "test 3: bare verb opener → SUBJECT_LED fail"
rm -rf "$sandbox"

# --- Test 4: leading dash fails NO_LEADING_DASH ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "- CloudWAN was accepted over Transit Gateway because the global routing model handles cross-region intent at the policy layer."
out=$(run_score "$raw")
assert_contains "NO_LEADING_DASH" "$out" "test 4: leading dash → NO_LEADING_DASH fail"
rm -rf "$sandbox"

# --- Test 5: no mechanism word fails HAS_MECHANISM ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "CloudWAN was accepted over Transit Gateway as the global routing solution."
out=$(run_score "$raw")
assert_contains "HAS_MECHANISM" "$out" "test 5: no mechanism word → HAS_MECHANISM fail"
rm -rf "$sandbox"

# --- Test 6: padding tail fails NO_PADDING ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "CloudWAN was accepted over Transit Gateway because of the global routing model, ensuring that drift incidents drop to zero."
out=$(run_score "$raw")
assert_contains "NO_PADDING" "$out" "test 6: padding tail → NO_PADDING fail"
rm -rf "$sandbox"

# --- Test 7: empty output fails everything (0/6) ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" ""
out=$(run_score "$raw")
assert_contains "rep 1: 0/6" "$out" "test 7: empty output → 0/6"
rm -rf "$sandbox"

# --- Test 8: extremely long sentence (>200 chars) fails LENGTH_BOUND ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
long_sentence="CloudWAN was accepted over Transit Gateway because the global routing model handles cross-region intent at the policy layer instead of in per-attachment route tables which had become a recurring source of operational incidents over the past six months across our growing AWS footprint."
build_raw "$raw" "$long_sentence"
out=$(run_score "$raw")
assert_contains "LENGTH_BOUND" "$out" "test 8: >200 char sentence → LENGTH_BOUND fail"
rm -rf "$sandbox"

# --- Test 9: multi-rep aggregation ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" \
  "CloudWAN was accepted because of the global routing model." \
  "Found CloudWAN better via the policy layer." \
  "TGW was rejected by the platform team due to manual route-table drift."
out=$(run_score "$raw")
assert_contains "reps: 3" "$out" "test 9: three reps detected"
assert_contains "rep 1: 6/6" "$out" "test 9: rep 1 clean"
assert_contains "rep 2:" "$out" "test 9: rep 2 scored"
assert_contains "rep 3: 6/6" "$out" "test 9: rep 3 clean (subject-led, has mechanism 'by'/'due to')"
rm -rf "$sandbox"

# --- Test 10: usage error on missing file arg ---
out=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "usage:" "$out" "test 10: missing arg prints usage"

# --- Test 11: no T7 reps found in unrelated file ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
echo "MODEL: x" > "$raw"
echo "" >> "$raw"
echo "===== T1-doc-drift rep 1 =====" >> "$raw"
echo "OUTPUT:" >> "$raw"
echo "irrelevant" >> "$raw"
out=$(bash "$SCRIPT" "$raw" 2>&1 || true)
assert_contains "no T7 reps found" "$out" "test 11: no T7 reps → error"
rm -rf "$sandbox"

# --- Test 12: T7_SUMMARY machine-parseable shape ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "Adoption of CloudWAN approved because the policy layer eliminates manual route-table drift."
out=$(run_score "$raw")
assert_contains "T7_SUMMARY: reps=1 total_passed=6 total_checks=6 mean=1.0000" "$out" \
  "test 12: T7_SUMMARY shape"
rm -rf "$sandbox"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
