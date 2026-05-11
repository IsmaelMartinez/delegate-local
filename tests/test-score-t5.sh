#!/usr/bin/env bash
# Unit tests for experiments/score-t5.sh.
# Builds synthetic raw output files containing each of the six check
# failure modes plus the all-pass case and the markdown-fence-wrap case,
# then asserts each PASS/FAIL fires as documented.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/experiments/score-t5.sh"

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

# Build a raw output file with one or more T5 reps. T1/T4 blocks are
# interleaved as noise so the awk extractor's `T5-json-shape` targeting is
# actually exercised.
build_raw() {
  local out="$1"; shift
  : > "$out"
  echo "MODEL: test-model" >> "$out"
  echo "DATE: 2026-05-11T00:00:00Z" >> "$out"
  echo "REPS: $#" >> "$out"
  echo "T3_SNAPSHOT: 2026-04-28" >> "$out"
  echo "T4_SNAPSHOT: 2026-05-11" >> "$out"
  echo "T5_SNAPSHOT: 2026-05-11" >> "$out"
  echo "" >> "$out"
  local rep=1
  for body in "$@"; do
    echo "===== T1-doc-drift rep $rep =====" >> "$out"
    echo "DURATION_SEC: 1" >> "$out"
    echo "RUN_STATUS: 0" >> "$out"
    echo "OUTPUT:" >> "$out"
    echo "(unrelated noise)" >> "$out"
    echo "" >> "$out"
    echo "===== T5-json-shape rep $rep =====" >> "$out"
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

CLEAN_JSON='{"owner":"ismael","items":[
  {"task":"update the data-retention policy doc","due":"2026-04-22"},
  {"task":"draft the SOC2 type-II evidence pack","due":"2026-05-08"},
  {"task":"review the privacy impact assessment","due":"2026-04-30"}
]}'

echo "=== score-t5.sh ==="

# Test 1: clean JSON matching the schema scores 6/6.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "$CLEAN_JSON"
out=$(run_score "$raw")
assert_contains "T5_SUMMARY:" "$out" "test 1: emits T5_SUMMARY line"
assert_contains "rep 1: 6/6" "$out" "test 1: clean JSON scores 6/6"
assert_contains "mean=1.0000" "$out" "test 1: mean is 1.0"
rm -rf "$sandbox"

# Test 2: ```json fence is stripped before scoring (common model behaviour).
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "\`\`\`json
$CLEAN_JSON
\`\`\`"
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 2: fenced JSON still scores 6/6"
rm -rf "$sandbox"

# Test 3: unparseable JSON fails everything cascadingly (one PARSE fail
# triggers automatic FAIL on the other 5 since they cannot be evaluated).
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" 'this is not JSON, just prose'
out=$(run_score "$raw")
assert_contains "rep 1: 0/6" "$out" "test 3: unparseable → 0/6"
assert_contains "JSON_PARSEABLE" "$out" "test 3: fails list names JSON_PARSEABLE"
rm -rf "$sandbox"

# Test 4: top-level array instead of object fails TOP_LEVEL_OBJECT (and
# subsequent object-shape checks, since .owner on an array is null).
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '[{"task":"x","due":"2026-04-22"}]'
out=$(run_score "$raw")
assert_contains "TOP_LEVEL_OBJECT" "$out" "test 4: top-level array → TOP_LEVEL_OBJECT fail"
rm -rf "$sandbox"

# Test 5: wrong owner ("Maria") fails OWNER_FIELD; rest may still pass.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '{"owner":"Maria","items":[
  {"task":"a","due":"2026-04-22"},
  {"task":"b","due":"2026-05-08"},
  {"task":"c","due":"2026-04-30"}
]}'
out=$(run_score "$raw")
assert_contains "OWNER_FIELD" "$out" "test 5: wrong owner → OWNER_FIELD fail"
rm -rf "$sandbox"

# Test 6: capitalised "Ismael" still passes OWNER_FIELD — case-insensitive
# comparison is documented in the rubric.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '{"owner":"ISMAEL","items":[
  {"task":"a","due":"2026-04-22"},
  {"task":"b","due":"2026-05-08"},
  {"task":"c","due":"2026-04-30"}
]}'
out=$(run_score "$raw")
assert_contains "rep 1: 6/6" "$out" "test 6: ISMAEL (uppercase) still 6/6 (case-insensitive owner)"
rm -rf "$sandbox"

# Test 7: items as an object (not array) fails ITEMS_ARRAY and ITEM_COUNT
# and ITEM_SHAPE.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '{"owner":"ismael","items":{"a":1}}'
out=$(run_score "$raw")
assert_contains "ITEMS_ARRAY" "$out" "test 7: items as object → ITEMS_ARRAY fail"
rm -rf "$sandbox"

# Test 8: wrong item count (4 instead of 3 — model leaked Maria's item).
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '{"owner":"ismael","items":[
  {"task":"a","due":"2026-04-22"},
  {"task":"b","due":"2026-05-08"},
  {"task":"c","due":"2026-04-30"},
  {"task":"maria leaked","due":"2026-05-01"}
]}'
out=$(run_score "$raw")
assert_contains "ITEM_COUNT" "$out" "test 8: 4 items → ITEM_COUNT fail"
rm -rf "$sandbox"

# Test 9: malformed date (April 22 instead of 2026-04-22) fails ITEM_SHAPE.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '{"owner":"ismael","items":[
  {"task":"a","due":"April 22"},
  {"task":"b","due":"2026-05-08"},
  {"task":"c","due":"2026-04-30"}
]}'
out=$(run_score "$raw")
assert_contains "ITEM_SHAPE" "$out" "test 9: non-ISO date → ITEM_SHAPE fail"
rm -rf "$sandbox"

# Test 10: missing task field fails ITEM_SHAPE.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '{"owner":"ismael","items":[
  {"due":"2026-04-22"},
  {"task":"b","due":"2026-05-08"},
  {"task":"c","due":"2026-04-30"}
]}'
out=$(run_score "$raw")
assert_contains "ITEM_SHAPE" "$out" "test 10: missing task → ITEM_SHAPE fail"
rm -rf "$sandbox"

# Test 11: empty items array fails ITEM_COUNT and ITEM_SHAPE.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" '{"owner":"ismael","items":[]}'
out=$(run_score "$raw")
assert_contains "ITEM_COUNT" "$out" "test 11: empty items → ITEM_COUNT fail"
assert_contains "ITEM_SHAPE" "$out" "test 11: empty items → ITEM_SHAPE fail (all-of-empty would pass but we require non-empty)"
rm -rf "$sandbox"

# Test 12: multi-rep aggregation — one clean rep, one wrong-owner rep.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "$CLEAN_JSON" '{"owner":"someoneelse","items":[
  {"task":"a","due":"2026-04-22"},
  {"task":"b","due":"2026-05-08"},
  {"task":"c","due":"2026-04-30"}
]}'
out=$(run_score "$raw")
assert_contains "reps: 2" "$out" "test 12: two reps detected"
assert_contains "rep 1: 6/6" "$out" "test 12: rep 1 clean"
assert_contains "rep 2: 5/6" "$out" "test 12: rep 2 misses owner"
rm -rf "$sandbox"

# Test 13: usage error on missing arg.
out=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "usage:" "$out" "test 13: missing arg prints usage"

# Test 14: no T5 reps in file.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
echo "MODEL: x" > "$raw"
echo "" >> "$raw"
echo "===== T4-commit-message rep 1 =====" >> "$raw"
echo "OUTPUT:" >> "$raw"
echo "irrelevant" >> "$raw"
out=$(bash "$SCRIPT" "$raw" 2>&1 || true)
assert_contains "no T5 reps found" "$out" "test 14: no T5 reps → error"
rm -rf "$sandbox"

# Test 15: T5_SUMMARY machine-parseable shape on clean input.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "$CLEAN_JSON"
out=$(run_score "$raw")
assert_contains "T5_SUMMARY: reps=1 total_passed=6 total_checks=6 mean=1.0000" "$out" "test 15: T5_SUMMARY shape"
rm -rf "$sandbox"

# Test 16: leading whitespace + trailing prose around clean JSON is NOT
# tolerated — the scorer strips the markdown fence but not arbitrary
# preamble/postamble. This matches the fixture's directive ("Output ONLY
# the JSON object"). A model that ignores the directive and adds preamble
# fails JSON_PARSEABLE.
sandbox=$(mktemp -d); raw="$sandbox/raw.txt"
build_raw "$raw" "Here is the JSON:

$CLEAN_JSON

Let me know if you need anything else."
out=$(run_score "$raw")
assert_contains "JSON_PARSEABLE" "$out" "test 16: preamble+postamble around JSON → JSON_PARSEABLE fail"
rm -rf "$sandbox"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
