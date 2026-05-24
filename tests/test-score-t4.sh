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
# anchor `(^|[.!?,][[:space:]]+)` keeps these patterns from firing when the
# token chain appears in the middle of a substantive sentence.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: substantive mid-sentence usage stays clean

The contract is that this ensures correct behaviour under concurrent writes by serialising the queue."
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 14f: mid-sentence 'this ensures' is not flagged"
rm -rf "$sandbox"

# --- Test 14f1: declarative pattern fires after non-period sentence
# terminators (! and ?). PR #93 review pointed out that anchoring only on
# `\.` would miss "Done! This ensures correctness." — the new anchor
# `[.!?,]` covers all four sentence-ending characters.
for term in "!" "?"; do
  sandbox=$(mktemp -d)
  raw="$sandbox/raw.txt"
  build_raw "$raw" "feat: declarative tail after $term terminator

The change landed cleanly${term} This ensures the framework holds together."
  out=$(run_score "$raw")
  assert_contains "BODY_NO_PADDING" "$out" "test 14f1: 'This ensures' after '${term}' is flagged"
  rm -rf "$sandbox"
done

# --- Test 14f2: declarative pattern fires when followed immediately by
# sentence-ending punctuation (no trailing space). Same shape as the
# participial regression in test 14b, applied to the declarative form.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: declarative tail abuts punctuation

Added a substantive change. This ensures."
out=$(run_score "$raw")
assert_contains "BODY_NO_PADDING" "$out" "test 14f2: 'This ensures.' (no trailing space) is flagged"
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

# --- Test 14i: Phase 16 Track B — Phase 13 scorer-recipe parity restored
# for the full enumerated participial set (`making`, `highlighting`,
# `underscoring` plus the new batch `replacing`, `supporting`, `reflecting`,
# `keeping`, `exemplified`). The recipe enumerates all eight; the scorer
# now matches. Gemini-code-assist's PR #209 review caught the three older
# omissions that pre-dated Phase 16 — fixed in the same PR for parity.
for verb in "making" "highlighting" "underscoring" "replacing" "supporting" "reflecting" "keeping" "exemplified"; do
  sandbox=$(mktemp -d)
  raw="$sandbox/raw.txt"
  build_raw "$raw" "feat: phase 16 enum extension

The wrapper accepts JSON inputs and returns structured errors, $verb the legacy plaintext path."
  out=$(run_score "$raw")
  assert_contains "BODY_NO_PADDING" "$out" "test 14i: ', $verb X' flagged as padding"
  rm -rf "$sandbox"
done

# --- Test 14j: Phase 16 Track B — "This provides" declarative restating
# tail (the unenumerated declarative cousin of "This ensures") is caught.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: this-provides declarative

Added a substantive change. This provides downstream consumers with extra context."
out=$(run_score "$raw")
assert_contains "BODY_NO_PADDING" "$out" "test 14j: 'This provides' declarative flagged as padding"
rm -rf "$sandbox"

# --- Test 14k: Phase 16 Track B negative case — legitimate mid-sentence
# uses of the same verbs (NOT padding tails) do NOT false-positive. The
# regex's comma-anchor is load-bearing here.
#
# This test ALSO acts as the false-positive guard for the Phase 17 Track B
# generalised `,[[:space:]]+[a-z]{3,}ing([[:space:]]|[.!?,])` matcher. The
# sentence-initial uses below have NO leading comma before the participle,
# so the generalised matcher must NOT flag them either. If a future
# iteration regresses on these, the comma-anchor on the generalised matcher
# has been weakened in a way that costs precision.
for clause in "Replacing the legacy SDK requires the new env var." \
              "Supporting the new locale needs two extra translation keys." \
              "Reflecting state changes through the websocket happens on every event."; do
  sandbox=$(mktemp -d)
  raw="$sandbox/raw.txt"
  build_raw "$raw" "feat: legitimate mid-sentence use

$clause The rest of the body adds substantive context."
  out=$(run_score "$raw")
  assert_not_contains "BODY_NO_PADDING" "$out" "test 14k: '$clause' not flagged as padding (legitimate use)"
  rm -rf "$sandbox"
done

# --- Test 14l: Phase 17 Track B — generalised `,[[:space:]]+[a-z]{3,}ing`
# trailing-clause matcher catches participial-tail padding past the per-verb
# enumeration treadmill. These five verbatim MISSes came from the
# 2026-05-24 dogfood drafts where the model AVOIDED the enumerated verbs
# (`ensuring`, `enabling`, etc.) and substituted structurally-equivalent
# unenumerated verbs (`lifting`, `confirming`, `moving`, `including`).
# `exemplified` is in the per-verb enumeration already; including it here
# documents that the generalised matcher does NOT subsume `-ied` shapes
# (it only handles `-ing`), so the per-verb regex remains load-bearing
# for that shape.
for clause in ", lifting the mean score from 0.67 to 1.00" \
              ", confirming the need for a generalised structural matcher" \
              ", moving the calibration from assertion to empirical data" \
              ", including subject length, type prefix, fake suffixes"; do
  sandbox=$(mktemp -d)
  raw="$sandbox/raw.txt"
  build_raw "$raw" "feat: phase 17 generalised matcher

The change extends the scorer$clause."
  out=$(run_score "$raw")
  assert_contains "BODY_NO_PADDING" "$out" "test 14l: '$clause' flagged by generalised matcher"
  rm -rf "$sandbox"
done

# --- Test 14l (verified existing): the `, exemplified` case from the
# 2026-05-24 dogfood corpus is already caught by the per-verb regex
# (the generalised `-ing` matcher does not subsume `-ied` forms). This
# rep documents that coverage in this PR's test block for completeness.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: phase 17 generalised matcher exemplified

The change extends the scorer, exemplified by the output 'No explicit blockers stated'."
out=$(run_score "$raw")
assert_contains "BODY_NO_PADDING" "$out" "test 14l: ', exemplified' caught (per-verb regex, not generalised)"
rm -rf "$sandbox"

# --- Test 14l negative supplement: the generalised matcher's `[a-z]{3,}`
# minimum prefix excludes coincidental bare-noun matches on five-char-or-
# shorter `-ing` nouns that could appear in legitimate lists after a comma.
# None of these should be flagged: `bring` (5, `br` prefix), `ring` (4,
# `r` prefix), `wing` (4, `w` prefix), `king` (4, `k` prefix), `sing` (4,
# `s` prefix), `cling` (5, `cl` prefix), `fling` (5, `fl` prefix),
# `sting` (5, `st` prefix), `swing` (5, `sw` prefix). The {3,} prefix on
# the participial verb requires the prefix itself to be 3+ chars (so
# total word length 6+, e.g. `lifting`, `moving`, `including`).
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: short-word coordination list

The schema covers ring, wing, and king geometries used by the calibration suite."
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 14l: short-word coordination list not flagged by generalised matcher"
rm -rf "$sandbox"

# --- Test 14l acknowledged-false-positive: `string` (6 chars, `str` prefix
# meets the 3-char floor) IS matched by the generalised regex. This test
# documents the false positive so future regex tightening regressions
# surface immediately. The trade-off was chosen on PR #213 review: bumping
# the floor to {4,} would also exclude `moving` — one of the five
# MUST-catch positives from the 2026-05-24 dogfood corpus — so the
# coordination-list-of-types false positive is accepted.
sandbox=$(mktemp -d)
raw="$sandbox/raw.txt"
build_raw "$raw" "feat: support multiple primitive types

The schema accepts integer, string, and boolean inputs from the upstream parser."
out=$(run_score "$raw")
assert_contains "BODY_NO_PADDING" "$out" "test 14l: ', string' acknowledged false-positive (matches due to 3-char prefix floor)"
rm -rf "$sandbox"

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
