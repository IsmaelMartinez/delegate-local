#!/usr/bin/env bash
# Unit tests for experiments/score-t6.sh. Builds synthetic raw output
# files containing each of the six check failure modes plus the all-pass
# case, the markdown-fence-wrap case, and the multi-rep aggregation case.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/experiments/score-t6.sh"

pass=0
fail=0

assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle' in:\n$haystack)"; fail=$((fail+1)); fi
}

assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (unexpected '$needle' in:\n$haystack)"; fail=$((fail+1)); fi
}

# Build a raw output file with one or more T6 reps. T1/T4/T5 rep blocks
# are interleaved as noise so the awk extractor's `T6-regex-generation`
# targeting is exercised.
build_raw() {
  local out="$1"; shift
  : > "$out"
  echo "MODEL: test-model" >> "$out"
  echo "DATE: 2026-05-11T00:00:00Z" >> "$out"
  echo "REPS: $#" >> "$out"
  echo "T3_SNAPSHOT: 2026-04-28" >> "$out"
  echo "T4_SNAPSHOT: 2026-05-11" >> "$out"
  echo "T5_SNAPSHOT: 2026-05-11" >> "$out"
  echo "T6_SNAPSHOT: 2026-05-11" >> "$out"
  echo "" >> "$out"
  local rep=1
  for body in "$@"; do
    echo "===== T1-doc-drift rep $rep =====" >> "$out"
    echo "DURATION_SEC: 1" >> "$out"
    echo "RUN_STATUS: 0" >> "$out"
    echo "OUTPUT:" >> "$out"
    echo "(unrelated noise)" >> "$out"
    echo "" >> "$out"
    echo "===== T6-regex-generation rep $rep =====" >> "$out"
    echo "DURATION_SEC: 3" >> "$out"
    echo "RUN_STATUS: 0" >> "$out"
    echo "OUTPUT:" >> "$out"
    printf '%s\n' "$body" >> "$out"
    echo "" >> "$out"
    rep=$((rep + 1))
  done
}

run_score() { bash "$SCRIPT" "$1" 2>&1; }

# The canonical correct regex for the fixture's ZIP+4 task.
CLEAN_REGEX='^\d{5}(-\d{4})?$'

echo "=== score-t6.sh ==="

# Test 1: canonical correct regex scores 6/6.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "$CLEAN_REGEX"
out=$(run_score "$raw")
assert_contains "T6_SUMMARY:" "$out" "test 1: emits T6_SUMMARY line"
assert_contains "rep 1: 6/6" "$out" "test 1: canonical regex scores 6/6"
assert_contains "mean=1.0000" "$out" "test 1: mean is 1.0"
rm -rf "$sandbox"

# Test 2: equivalent POSIX-class form also scores 6/6.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '^[0-9]{5}(-[0-9]{4})?$'
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 2: [0-9]-class equivalent scores 6/6"
rm -rf "$sandbox"

# Test 3: markdown ```regex fence is stripped before scoring.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "\`\`\`regex
$CLEAN_REGEX
\`\`\`"
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 3: fenced regex still scores 6/6"
rm -rf "$sandbox"

# Test 4: empty output fails everything cascadingly.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" ""
out=$(run_score "$raw")
assert_contains "rep 1: 0/6" "$out" "test 4: empty output → 0/6"
assert_contains "OUTPUT_CLEAN" "$out" "test 4: fails list names OUTPUT_CLEAN"
rm -rf "$sandbox"

# Test 5: multi-line output (preamble + regex) fails OUTPUT_CLEAN.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "Here is the regex:
$CLEAN_REGEX"
out=$(run_score "$raw")
assert_contains "OUTPUT_CLEAN" "$out" "test 5: multi-line output → OUTPUT_CLEAN fail"
rm -rf "$sandbox"

# Test 6: uncompilable regex (unmatched open paren) fails REGEX_VALID
# and cascades into the downstream checks.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '^\d{5}(-\d{4}?$'
out=$(run_score "$raw")
assert_contains "REGEX_VALID" "$out" "test 6: uncompilable regex → REGEX_VALID fail"
rm -rf "$sandbox"

# Test 7: unanchored regex fails ANCHORED (would otherwise score 5/6).
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '\d{5}(-\d{4})?'
out=$(run_score "$raw")
assert_contains "ANCHORED" "$out" "test 7: unanchored regex → ANCHORED fail"
rm -rf "$sandbox"

# Test 8: missing end anchor only fails ANCHORED.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '^\d{5}(-\d{4})?'
out=$(run_score "$raw")
assert_contains "ANCHORED" "$out" "test 8: missing \$ → ANCHORED fail"
rm -rf "$sandbox"

# Test 9: too-permissive regex (4-digit minimum) matches all positives but
# also matches "1234" → NEGATIVES_REJECT fails.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '^\d{4,}(-\d{4})?$'
out=$(run_score "$raw")
assert_contains "NEGATIVES_REJECT" "$out" "test 9: too-permissive → NEGATIVES_REJECT fail"
rm -rf "$sandbox"

# Test 10: too-strict regex (requires the extension) rejects "12345" alone
# → POSITIVES_MATCH fails.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '^\d{5}-\d{4}$'
out=$(run_score "$raw")
assert_contains "POSITIVES_MATCH" "$out" "test 10: requires extension → POSITIVES_MATCH fail"
rm -rf "$sandbox"

# Test 11: catch-all `.*` regex passes positives but fails NEGATIVES_REJECT
# and USES_DIGIT_CLASS (no digit class) — the rubric resists cheats.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '^.*$'
out=$(run_score "$raw")
assert_contains "NEGATIVES_REJECT" "$out" "test 11: .* catch-all → NEGATIVES_REJECT fail"
assert_contains "USES_DIGIT_CLASS" "$out" "test 11: .* catch-all → USES_DIGIT_CLASS fail"
rm -rf "$sandbox"

# Test 12: regex matching positives via wildcard but no digit class.
# `^[^ ]{5}(-[^ ]{4})?$` matches all positives, also (probably) all
# negatives except the space one, but most importantly lacks a digit
# class. USES_DIGIT_CLASS must fail.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '^[^ ]{5}(-[^ ]{4})?$'
out=$(run_score "$raw")
assert_contains "USES_DIGIT_CLASS" "$out" "test 12: non-digit char class → USES_DIGIT_CLASS fail"
rm -rf "$sandbox"

# Test 13: multi-rep aggregation — one clean, one too-permissive.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "$CLEAN_REGEX" '^\d{4,}(-\d{4})?$'
out=$(run_score "$raw")
assert_contains "reps: 2" "$out" "test 13: two reps detected"
assert_contains "rep 1: 6/6" "$out" "test 13: rep 1 clean"
assert_contains "rep 2: 5/6" "$out" "test 13: rep 2 misses NEGATIVES_REJECT"
rm -rf "$sandbox"

# Test 14: usage errors.
out=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "usage:" "$out" "test 14: missing arg prints usage"
out=$(bash "$SCRIPT" /nonexistent/path 2>&1 || true)
assert_contains "usage:" "$out" "test 14: nonexistent path prints usage"

# Test 15: no T6 reps in file.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
echo "MODEL: x" > "$raw"
echo "" >> "$raw"
echo "===== T4-commit-message rep 1 =====" >> "$raw"
echo "OUTPUT:" >> "$raw"
echo "irrelevant" >> "$raw"
out=$(bash "$SCRIPT" "$raw" 2>&1 || true)
assert_contains "no T6 reps found" "$out" "test 15: no T6 reps → error"
rm -rf "$sandbox"

# Test 16: T6_SUMMARY machine-parseable shape on clean input.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "$CLEAN_REGEX"
out=$(run_score "$raw")
assert_contains "T6_SUMMARY: reps=1 total_passed=6 total_checks=6 mean=1.0000" "$out" "test 16: T6_SUMMARY shape"
rm -rf "$sandbox"

# Test 17: leading-only inline mode flag `(?i)^...$` is still treated as
# anchored — the project's other regex consumers accept this shape.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '(?i)^\d{5}(-\d{4})?$'
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 17: (?i)-prefixed anchored regex scores 6/6"
rm -rf "$sandbox"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
