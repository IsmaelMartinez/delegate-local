#!/usr/bin/env bash
# Unit tests for experiments/score-t4.sh.
# Builds synthetic raw output files (no fixture lookup needed — T4 scoring
# is structural, not citation-based) and asserts each of the six checks
# fires as documented.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/experiments/score-t4.sh"

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

# Build a raw output file with one or more T4 reps. T1/T2/T3 rep blocks are
# noise interleaved between T4 blocks to verify the awk extraction targets
# T4 specifically.
build_raw() {
  local out="$1"; shift
  : > "$out"
  echo "MODEL: test-model" >> "$out"
  echo "DATE: 2026-05-11T00:00:00Z" >> "$out"
  echo "REPS: $#" >> "$out"
  echo "T3_SNAPSHOT: 2026-04-28" >> "$out"
  echo "T4_SNAPSHOT: 2026-05-11" >> "$out"
  echo "" >> "$out"
  local rep=1
  for body in "$@"; do
    echo "===== T1-doc-drift rep $rep =====" >> "$out"
    echo "DURATION_SEC: 1" >> "$out"
    echo "RUN_STATUS: 0" >> "$out"
    echo "OUTPUT:" >> "$out"
    echo "(unrelated noise)" >> "$out"
    echo "" >> "$out"
    echo "===== T4-commit-message rep $rep =====" >> "$out"
    echo "DURATION_SEC: 8" >> "$out"
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

echo "=== score-t4.sh ==="

# --- Test 1: all six checks pass on a clean commit message ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: add T4 commit-message fixture and scorer

Phase 7 of the roadmap asked for a commit-message fixture and this delivers it. The fixture sends the substituted recipe prompt to any Ollama model and the scorer applies six structural checks per rep.

Each check came from a real past MISS so model pass rate maps directly to the recipe's calibration history."
out=$(run_score "$raw")
assert_contains "T4_SUMMARY:" "$out" "test 1: emits T4_SUMMARY line"
assert_contains "rep 1: 6/6" "$out" "test 1: clean commit scores 6/6"
assert_contains "mean=1.0000" "$out" "test 1: mean is 1.0"
rm -rf "$sandbox"

# --- Test 2: subject too long fails SUBJECT_LEN only ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
long_subject="feat: this subject is intentionally far too long to fit within the conventional 72-char budget and should fail SUBJECT_LEN"
build_raw "$raw" "$long_subject

Short flush-left body paragraph that does not pad.

Another short paragraph."
out=$(run_score "$raw")
assert_contains "rep 1: 5/6" "$out" "test 2: subject too long → 5/6"
assert_contains "fails=SUBJECT_LEN" "$out" "test 2: fails list names SUBJECT_LEN"
rm -rf "$sandbox"

# --- Test 3: missing conventional-type prefix fails SUBJECT_TYPE ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "added a thing without a conventional prefix

Body paragraph that is short and clean.

Another body paragraph."
out=$(run_score "$raw")
assert_contains "rep 1: 5/6" "$out" "test 3: no type prefix → 5/6"
assert_contains "SUBJECT_TYPE" "$out" "test 3: fails list names SUBJECT_TYPE"
rm -rf "$sandbox"

# --- Test 4: (#NN) suffix fails SUBJECT_NO_PR ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: add T4 commit-message fixture and scorer (#42)

Short body paragraph one.

Short body paragraph two."
out=$(run_score "$raw")
assert_contains "rep 1: 5/6" "$out" "test 4: (#NN) suffix → 5/6"
assert_contains "SUBJECT_NO_PR" "$out" "test 4: fails list names SUBJECT_NO_PR"
rm -rf "$sandbox"

# --- Test 5: indented body fails BODY_FLUSH_LEFT ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: add T4 commit-message fixture and scorer

    This body paragraph is indented four spaces, which is what git log --pretty=fuller produces.

    Another indented paragraph."
out=$(run_score "$raw")
assert_contains "rep 1: 5/6" "$out" "test 5: indented body → 5/6"
assert_contains "BODY_FLUSH_LEFT" "$out" "test 5: fails list names BODY_FLUSH_LEFT"
rm -rf "$sandbox"

# --- Test 6: bullet markers fail BODY_NO_BULLETS ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: add T4 commit-message fixture and scorer

- one bullet
- another bullet
- a third bullet"
out=$(run_score "$raw")
assert_contains "rep 1: 5/6" "$out" "test 6: bullet body → 5/6"
assert_contains "BODY_NO_BULLETS" "$out" "test 6: fails list names BODY_NO_BULLETS"
rm -rf "$sandbox"

# --- Test 7: participial-padding tail fails BODY_NO_PADDING ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: add T4 commit-message fixture and scorer

The commit-message recipe lacked a guard against participial-padding tails, ensuring that every recurring miss has a clear path."
out=$(run_score "$raw")
assert_contains "rep 1: 5/6" "$out" "test 7: padding tail → 5/6"
assert_contains "BODY_NO_PADDING" "$out" "test 7: fails list names BODY_NO_PADDING"
rm -rf "$sandbox"

# --- Test 8: multiple failures stack ---
# Subject: no conventional prefix + >72 chars + ends with (#99) → fails 3 subject checks.
# Body: indented + bullet marker + comma-led "ensuring" padding → fails 3 body checks.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "no conventional prefix and a deliberately very long subject that exceeds the seventy-two char budget by a margin (#99)

    - indented bulleted body line, ensuring that nothing here passes"
out=$(run_score "$raw")
assert_contains "rep 1: 0/6" "$out" "test 8: every check fails → 0/6"
assert_contains "SUBJECT_LEN" "$out" "test 8: lists SUBJECT_LEN"
assert_contains "SUBJECT_TYPE" "$out" "test 8: lists SUBJECT_TYPE"
assert_contains "SUBJECT_NO_PR" "$out" "test 8: lists SUBJECT_NO_PR"
assert_contains "BODY_FLUSH_LEFT" "$out" "test 8: lists BODY_FLUSH_LEFT"
assert_contains "BODY_NO_BULLETS" "$out" "test 8: lists BODY_NO_BULLETS"
assert_contains "BODY_NO_PADDING" "$out" "test 8: lists BODY_NO_PADDING"
rm -rf "$sandbox"

# --- Test 9: empty output fails everything (0/6) ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" ""
out=$(run_score "$raw")
assert_contains "rep 1: 0/6" "$out" "test 9: empty output → 0/6"
rm -rf "$sandbox"

# --- Test 10: multi-rep aggregation (mean, min, max) ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" \
  "feat: clean rep one

Short body." \
  "feat: clean rep two

Short body, ensuring that things are clear." \
  "no prefix and a deliberately very long subject that exceeds the seventy-two char budget by a margin (#99)

    - indented bullet body line, ensuring that this is crucial"
out=$(run_score "$raw")
assert_contains "reps: 3" "$out" "test 10: three reps detected"
assert_contains "rep 1: 6/6" "$out" "test 10: rep 1 clean"
assert_contains "rep 2: 5/6" "$out" "test 10: rep 2 misses padding"
assert_contains "rep 3: 0/6" "$out" "test 10: rep 3 misses everything"
assert_contains "min: 0.00" "$out" "test 10: min = 0.00"
assert_contains "max: 1.00" "$out" "test 10: max = 1.00"
rm -rf "$sandbox"

# --- Test 11: usage error on missing file arg ---
out=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "usage:" "$out" "test 11: missing arg prints usage"

# --- Test 12: usage error on nonexistent file ---
out=$(bash "$SCRIPT" /nonexistent/path/raw.txt 2>&1 || true)
assert_contains "usage:" "$out" "test 12: nonexistent path prints usage"

# --- Test 13: no T4 reps in input file ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
echo "MODEL: x" > "$raw"
echo "" >> "$raw"
echo "===== T1-doc-drift rep 1 =====" >> "$raw"
echo "OUTPUT:" >> "$raw"
echo "irrelevant" >> "$raw"
out=$(bash "$SCRIPT" "$raw" 2>&1 || true)
assert_contains "no T4 reps found" "$out" "test 13: no T4 reps → error"
rm -rf "$sandbox"

# --- Test 14: case-insensitive padding detection ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: case-insensitive padding check

Body text, Ensuring That capitalisation does not bypass the padding check."
out=$(run_score "$raw")
assert_contains "BODY_NO_PADDING" "$out" "test 14: padding match is case-insensitive"
rm -rf "$sandbox"

# --- Test 14b: padding immediately followed by punctuation (gemini-code-assist
# finding) — the older substring approach with trailing-space patterns missed
# `, ensuring.` because there was no space after the participle. The regex
# alternative `[[:space:]]|[.!?,]` should catch it.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: punctuation-anchored padding

Body sentence trailing with the classic padding shape, ensuring."
out=$(run_score "$raw")
assert_contains "BODY_NO_PADDING" "$out" "test 14b: padding followed by '.' is caught"
rm -rf "$sandbox"

# --- Test 14c: legitimate mid-sentence participial use does NOT false-positive
# — without the leading comma the regex does not match, so prose that uses
# `ensuring` as a substantive verb (rather than a trailing-clause participle)
# stays clean.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: mid-sentence ensuring is not padding

This change is about ensuring data integrity across writes."
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 14c: mid-sentence 'ensuring' without comma is not flagged"
rm -rf "$sandbox"

# --- Test 14d: declarative "This ensures" sentence-starter is caught.
# Drawn from the PR #86 T4 dogfood that scored 6/6 on the old participial-
# only regex set while still emitting this exact shape.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: declarative restating tail

Added a guard against trailing participial padding. This ensures the anti-padding hardening is measured rather than merely asserted."
out=$(run_score "$raw")
assert_contains "BODY_NO_PADDING" "$out" "test 14d: 'This ensures' sentence-starter flagged as padding"
rm -rf "$sandbox"

# --- Test 14e: declarative "This enables / This guarantees / This delivers"
# variants are caught — same restating-sentence shape as test 14d.
for verb in enables guarantees delivers; do
  sandbox=$(mktemp -d)
  raw="$sandbox/raw.txt"
  build_raw "$raw" "feat: declarative $verb variant

Added a substantive change. This $verb broader adoption of the calibration discipline across future sessions."
  out=$(run_score "$raw")
  assert_contains "BODY_NO_PADDING" "$out" "test 14e: 'This $verb' sentence-starter flagged"
  rm -rf "$sandbox"
done

# --- Test 14f: legitimate mid-sentence "this ensures" is NOT flagged. The
# anchor `(^|\.[[:space:]]+)` keeps these patterns from firing when the
# token chain appears in the middle of a substantive sentence.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: substantive mid-sentence usage stays clean

The contract is that this ensures correct behaviour under concurrent writes by serialising the queue."
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 14f: mid-sentence 'this ensures' is not flagged"
rm -rf "$sandbox"

# --- Test 14g: "closing the gap" / "closes the gap" / "closing the loop"
# are caught as high-signal restating-tail filler.
for phrase in "closing the gap in the framework" \
              "closes the gap between modules" \
              "closing the loop on the calibration"; do
  sandbox=$(mktemp -d)
  raw="$sandbox/raw.txt"
  build_raw "$raw" "feat: gap-or-loop padding variant

Added a substantive change, $phrase."
  out=$(run_score "$raw")
  assert_contains "BODY_NO_PADDING" "$out" "test 14g: '$phrase' flagged as padding"
  rm -rf "$sandbox"
done

# --- Test 14h: "going forward" and "moving forward" as trailing-sentence
# filler are caught.
for phrase in "going forward" "moving forward"; do
  sandbox=$(mktemp -d)
  raw="$sandbox/raw.txt"
  build_raw "$raw" "feat: forward-looking filler

Added a substantive change. The team will iterate on this $phrase."
  out=$(run_score "$raw")
  assert_contains "BODY_NO_PADDING" "$out" "test 14h: '$phrase' flagged as padding"
  rm -rf "$sandbox"
done

# --- Test 15: machine-parseable T4_SUMMARY line shape ---
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: clean

Short body."
out=$(run_score "$raw")
assert_contains "T4_SUMMARY: reps=1 total_passed=6 total_checks=6 mean=1.0000" "$out" \
  "test 15: T4_SUMMARY shape"
rm -rf "$sandbox"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
