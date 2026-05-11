#!/usr/bin/env bash
# Mechanical T6 scoring — six deterministic structural / behavioural
# checks for the regex-generation fixture. Verifies the model emitted a
# single clean pattern line, that the pattern compiles in Perl's regex
# engine, that it is fully anchored, that it matches every positive
# acceptance test, that it rejects every negative acceptance test, and
# that it uses a digit class somewhere (catches "trivially matches
# everything" patterns).
#
# Usage: score-t6.sh <raw-output-file>
#
# Scoring rubric (each PASS = 1, each FAIL = 0; per-rep score = passed / 6):
#   1. OUTPUT_CLEAN     — output (after stripping ```regex/```re/```
#                          markdown fences and leading/trailing whitespace)
#                          is a single non-empty line of pattern text. No
#                          internal newlines, no preamble.
#   2. REGEX_VALID      — pattern compiles in Perl (`qr/.../` succeeds).
#                          Same engine the project's other PCRE-style
#                          regexes already rely on (see score-t4.sh,
#                          delegate-feedback.sh, delegate.sh).
#   3. ANCHORED         — pattern starts with `^` and ends with `$` after
#                          stripping any leading `(?...)` mode flags. The
#                          fixture's directive requires whole-string match.
#   4. POSITIVES_MATCH  — all 5 positive acceptance strings (in the
#                          fixture) match the pattern. Hard-coded here
#                          the same way the T5 ground-truth date set is —
#                          a future dated T6 snapshot with different
#                          test cases needs a scorer update in lock-step.
#   5. NEGATIVES_REJECT — all 7 negative acceptance strings reject.
#   6. USES_DIGIT_CLASS — pattern contains at least one digit class
#                          (`\d`, `[0-9]`, or `[[:digit:]]`). Catches
#                          patterns that trivially match everything via
#                          `.*` without engaging the digit constraint.
#
# Per-rep output: rep N: pass=N/6 fails=[check_name,...]
# Aggregate: mean, min, max, stdev across reps + machine-parseable
# T6_SUMMARY line for downstream tooling.

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
  echo "usage: score-t6.sh <raw-output-file>" >&2
  exit 2
fi

# Hard-coded fixture ground truth — must stay in lock-step with
# experiments/fixtures/task-6-regex-generation-2026-05-11.txt. Newer dated
# snapshots will need a refreshed scorer at the same time. Same pattern
# as the T5 date-set hard-coding.
POSITIVES=(
  "12345"
  "90210"
  "00000"
  "12345-6789"
  "99999-0001"
)
NEGATIVES=(
  "1234"
  "123456"
  "12345-678"
  "12345 6789"
  "1234-5678"
  "12345-"
  " 12345"
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Extract each T6 rep's OUTPUT section into a temp file.
awk '
  /^===== T6-regex-generation rep [0-9]+ =====$/ {
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
  echo "no T6 reps found in $infile" >&2
  exit 1
fi

# Strip markdown fence (```regex / ```re / ```) and surrounding whitespace.
# Models commonly wrap regex output in a fence even when told not to.
strip_fence() {
  local body="$1"
  body=$(printf '%s' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  body=$(printf '%s' "$body" | perl -0777 -pe 's/^```(?:regex|re|RE|REGEX)?\s*\n?//; s/\n?```\s*$//')
  printf '%s' "$body"
}

# Perl-test a regex compiles. Returns 0 if compile succeeds, non-zero
# otherwise. Pattern passed via env var so shell quoting can't corrupt it.
regex_compiles() {
  local pat="$1"
  PATTERN="$pat" perl -e '
    my $p = $ENV{PATTERN};
    eval { my $r = qr/$p/ };
    exit ($@ ? 1 : 0);
  '
}

# Perl-test a string matches a pattern. Returns 0 if match, non-zero
# otherwise. Both via env var for the same shell-quoting reason.
regex_matches() {
  local pat="$1" str="$2"
  PATTERN="$pat" STR="$str" perl -e '
    my $p = $ENV{PATTERN};
    my $s = $ENV{STR};
    my $r = eval { qr/$p/ };
    exit 2 if $@;             # uncompilable pattern: treat as no-match
    exit ($s =~ $r ? 0 : 1);
  '
}

# Score one rep. Prints `<passed>/6 <fail_csv>`.
score_one() {
  local rep_file="$1"
  local body
  body=$(cat "$rep_file")
  body=$(strip_fence "$body")

  local fails=()
  local p_clean=0 p_valid=0 p_anchor=0 p_pos=0 p_neg=0 p_digit=0

  # Check 1: single non-empty line, no internal newlines.
  if [[ -n "$body" && "$body" != *$'\n'* ]]; then
    p_clean=1
  else
    fails+=("OUTPUT_CLEAN")
    # If we don't have a clean line we can't reliably score the rest.
    # Treat the remaining 5 as fails for diagnostic legibility.
    fails+=("REGEX_VALID" "ANCHORED" "POSITIVES_MATCH" "NEGATIVES_REJECT" "USES_DIGIT_CLASS")
    local csv
    csv=$(IFS=,; echo "${fails[*]}")
    echo "0/6 $csv"
    return
  fi

  # Check 2: pattern compiles.
  if regex_compiles "$body"; then
    p_valid=1
  else
    fails+=("REGEX_VALID")
    fails+=("ANCHORED" "POSITIVES_MATCH" "NEGATIVES_REJECT" "USES_DIGIT_CLASS")
    local csv
    csv=$(IFS=,; echo "${fails[*]}")
    echo "1/6 $csv"
    return
  fi

  # Check 3: anchored at start and end. Allow optional leading `(?...)`
  # mode flags before the `^`. The `$` must be at the very end.
  if [[ "$body" =~ ^(\(\?[a-zA-Z\-]*\))?\^ && "$body" =~ \$$ ]]; then
    p_anchor=1
  else
    fails+=("ANCHORED")
  fi

  # Check 4: every positive matches.
  local pos_pass=1
  for s in "${POSITIVES[@]}"; do
    if ! regex_matches "$body" "$s"; then
      pos_pass=0
      break
    fi
  done
  if (( pos_pass == 1 )); then
    p_pos=1
  else
    fails+=("POSITIVES_MATCH")
  fi

  # Check 5: every negative rejects.
  local neg_pass=1
  for s in "${NEGATIVES[@]}"; do
    if regex_matches "$body" "$s"; then
      neg_pass=0
      break
    fi
  done
  if (( neg_pass == 1 )); then
    p_neg=1
  else
    fails+=("NEGATIVES_REJECT")
  fi

  # Check 6: pattern uses a digit class somewhere.
  if [[ "$body" == *'\d'* || "$body" == *'[0-9]'* || "$body" == *'[[:digit:]]'* ]]; then
    p_digit=1
  else
    fails+=("USES_DIGIT_CLASS")
  fi

  local passed=$((p_clean + p_valid + p_anchor + p_pos + p_neg + p_digit))
  local csv=""
  if (( ${#fails[@]} > 0 )); then
    csv=$(IFS=,; echo "${fails[*]}")
  fi
  echo "$passed/6 $csv"
}

# Aggregate across reps (same scale + stdev as the T3 / T4 / T5 scorers).
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

printf "T6 score for %s\n" "$infile"
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
printf "T6_SUMMARY: reps=%d total_passed=%d total_checks=%d mean=%0.4f stdev=%0.4f min=%0.4f max=%0.4f\n" \
  "$n_reps" "$total_passed" "$total_checks" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")"
