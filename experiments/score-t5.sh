#!/usr/bin/env bash
# Mechanical T5 scoring — six deterministic structural / content checks
# against the fixture's documented JSON schema. Each check came from a
# real failure mode observed in structured-extraction delegation:
# unparseable output, wrong top-level shape, missing required keys,
# wrong filter (other people's items leaked in), wrong types, malformed
# ISO dates.
#
# Usage: score-t5.sh <raw-output-file>
#
# Scoring rubric (each PASS = 1, each FAIL = 0; per-rep score = passed / 6):
#   1. JSON_PARSEABLE   — output (after stripping ```json fences) is valid
#                          JSON per `jq -e .`
#   2. TOP_LEVEL_OBJECT — top-level value is a JSON object (not array,
#                          string, number, null, or bool)
#   3. OWNER_FIELD      — `.owner == "ismael"` exactly (strict lowercase,
#                          per the fixture's rule 18 "the literal
#                          lowercase string")
#   4. ITEMS_ARRAY      — `.items` is an array
#   5. ITEM_COUNT       — `.items | length == 3` (the three Ismael items
#                          in the fixture's email)
#   6. ITEM_SHAPE       — every element has `.task` (non-empty string)
#                          and `.due` (ISO YYYY-MM-DD string), AND the
#                          sorted set of `.due` dates equals the ground
#                          truth ["2026-04-22", "2026-04-30", "2026-05-08"]
#                          (a model that emits well-formatted but invented
#                          dates fails this check)
#
# Per-rep output: rep N: pass=N/6 fails=[check_name,...]
# Aggregate: mean, min, max, stdev across reps + machine-parseable
# T5_SUMMARY line for downstream tooling.

set -uo pipefail

infile=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$infile" ]] || { echo "unexpected extra arg: $1" >&2; exit 2; }
      infile="$1"
      shift
      ;;
  esac
done

if [[ -z "$infile" || ! -f "$infile" ]]; then
  echo "usage: score-t5.sh <raw-output-file>" >&2
  exit 2
fi

command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Extract each T5 rep's OUTPUT section into a temp file (mirrors the T3/T4
# parsers — same `===== <task> rep N =====` envelope).
awk '
  /^===== T5-json-shape rep [0-9]+ =====$/ {
    if (in_rep && capture) close(out)
    rep = $4
    out = "'"$work"'/rep-" rep ".txt"
    in_rep = 1
    capture = 0
    next
  }
  /^===== / { in_rep = 0; capture = 0; next }
  in_rep && /^OUTPUT:$/ { capture = 1; next }
  in_rep && capture { print > out }
' "$infile"

shopt -s nullglob
rep_files=("$work"/rep-*.txt)
shopt -u nullglob
n_reps=${#rep_files[@]}
if (( n_reps == 0 )); then
  echo "no T5 reps found in $infile" >&2
  exit 1
fi

# Strip a leading/trailing ```json fence + a leading ``` if present so the
# scorer is robust to models that wrap JSON in a markdown code block. Also
# trim leading/trailing whitespace.
strip_fence() {
  local body="$1"
  body=$(printf '%s' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  # `\n?` on both ends — some models emit `...}\`\`\`` without a preceding
  # newline, others emit `\`\`\`json\n{...` with the newline present. Making
  # the newline optional keeps the scorer robust across both shapes.
  body=$(printf '%s' "$body" | perl -0777 -pe 's/^```(?:json|JSON)?\s*\n?//; s/\n?```\s*$//')
  printf '%s' "$body"
}

# Score one rep. Prints `<passed>/6 <fail_csv>`.
score_one() {
  local rep_file="$1"
  local body
  body=$(cat "$rep_file")
  body=$(strip_fence "$body")

  local fails=()
  local p_parse=0 p_obj=0 p_owner=0 p_items=0 p_count=0 p_shape=0

  if [[ -z "$body" ]]; then
    echo "0/6 JSON_PARSEABLE,TOP_LEVEL_OBJECT,OWNER_FIELD,ITEMS_ARRAY,ITEM_COUNT,ITEM_SHAPE"
    return
  fi

  # Check 1: parseable JSON.
  if printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    p_parse=1
  else
    fails+=("JSON_PARSEABLE")
    # Bail with everything-after-parse failing, but still emit the
    # structured fail-list for diagnostic legibility.
    fails+=("TOP_LEVEL_OBJECT" "OWNER_FIELD" "ITEMS_ARRAY" "ITEM_COUNT" "ITEM_SHAPE")
    local csv
    csv=$(IFS=,; echo "${fails[*]}")
    echo "0/6 $csv"
    return
  fi

  # Check 2: top-level object.
  if printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    p_obj=1
  else
    fails+=("TOP_LEVEL_OBJECT")
  fi

  # Check 3: owner field is the literal lowercase "ismael". The fixture's
  # rule 18 says "The 'owner' field is the literal lowercase string
  # 'ismael'" — strict comparison measures compliance with the directive
  # as written rather than tolerating uppercase variants the directive
  # rejects.
  if printf '%s' "$body" | jq -e '.owner == "ismael"' >/dev/null 2>&1; then
    p_owner=1
  else
    fails+=("OWNER_FIELD")
  fi

  # Check 4: items is an array.
  if printf '%s' "$body" | jq -e '.items | type == "array"' >/dev/null 2>&1; then
    p_items=1
  else
    fails+=("ITEMS_ARRAY")
  fi

  # Check 5: exactly 3 items (the three Ismael action items in the fixture).
  if printf '%s' "$body" | jq -e '.items | length == 3' >/dev/null 2>&1; then
    p_count=1
  else
    fails+=("ITEM_COUNT")
  fi

  # Check 6: ITEM_SHAPE — both format and content. Every item must have
  # `task` (non-empty string) and `due` (ISO YYYY-MM-DD string), AND the
  # three `due` dates must sort to the ground-truth set from the fixture
  # (April 22 / 30, May 8 — the three Ismael items in the email). The
  # ground-truth date set is hard-coded here the same way `length == 3` is
  # in check 5: it's part of the fixture-specific rubric, and a future
  # `task-5-json-shape-<DATE>.txt` snapshot with different dates would
  # need a scorer update in lock-step.
  if printf '%s' "$body" | jq -e '
      .items
      | type == "array"
      and length > 0
      and (map(.due) | sort == ["2026-04-22", "2026-04-30", "2026-05-08"])
      and all(
          (.task | type == "string" and (length > 0))
          and (.due | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
      )
  ' >/dev/null 2>&1; then
    p_shape=1
  else
    fails+=("ITEM_SHAPE")
  fi

  local passed=$((p_parse + p_obj + p_owner + p_items + p_count + p_shape))
  local csv=""
  if (( ${#fails[@]} > 0 )); then
    csv=$(IFS=,; echo "${fails[*]}")
  fi
  echo "$passed/6 $csv"
}

# Aggregate across reps (same scale + stdev as the T3 / T4 scorers).
SCORE_SCALE=10000
declare -a scores
declare -a per_rep_passed
declare -a per_rep_fails
total_passed=0
total_checks=0

for (( i=1; i<=n_reps; i++ )); do
  rep_file="$work/rep-$i.txt"
  result=$(score_one "$rep_file")
  passed="${result%% *}"
  fail_csv="${result#* }"
  p="${passed%%/*}"
  total_passed=$((total_passed + p))
  total_checks=$((total_checks + 6))
  per_rep_passed[i]=$p
  per_rep_fails[i]="$fail_csv"
  scores+=( "$((p * SCORE_SCALE / 6))" )
done

sum=0
for s in "${scores[@]}"; do sum=$((sum + s)); done
mean=$((sum / n_reps))

sumsq=0
for s in "${scores[@]}"; do
  d=$((s - mean))
  sumsq=$((sumsq + d * d))
done
var=$((sumsq / n_reps))
stdev=$(perl -e "printf '%.0f', sqrt($var)")

min=${scores[0]}
max=${scores[0]}
for s in "${scores[@]}"; do
  (( s < min )) && min=$s
  (( s > max )) && max=$s
done

printf "T5 score for %s\n" "$infile"
printf "  reps: %d\n" "$n_reps"
printf "  per-rep pass rates:\n"
for (( i=1; i<=n_reps; i++ )); do
  p=${per_rep_passed[i]}
  f=${per_rep_fails[i]}
  if [[ -z "$f" ]]; then
    printf "    rep %d: %d/6 → %0.2f\n" "$i" "$p" "$(perl -e "printf '%f', $p / 6")"
  else
    printf "    rep %d: %d/6 → %0.2f  fails=%s\n" "$i" "$p" "$(perl -e "printf '%f', $p / 6")" "$f"
  fi
done
printf "  totals: %d passed / %d total across all reps\n" "$total_passed" "$total_checks"
printf "  mean: %0.2f   stdev: %0.2f   min: %0.2f   max: %0.2f\n" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")"
printf "T5_SUMMARY: reps=%d total_passed=%d total_checks=%d mean=%0.4f stdev=%0.4f min=%0.4f max=%0.4f\n" \
  "$n_reps" "$total_passed" "$total_checks" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")"
