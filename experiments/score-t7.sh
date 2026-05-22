#!/usr/bin/env bash
# Mechanical T7 scoring — six deterministic structural checks against the
# file-summary recipe's guards. Each check came from a real past MISS
# observed in this project's file-summary dogfood batch.
#
# Usage: score-t7.sh <raw-output-file>
#
# Scoring rubric (each PASS = 1, each FAIL = 0; per-rep score = passed / 6):
#   1. SINGLE_LINE     — output is exactly one non-empty line after trimming
#                        (no markdown bullets, no preamble, no closing line)
#   2. LENGTH_BOUND    — line length ≤ 200 chars (the recipe asks for a
#                        short sentence; 200 is the looser deterministic
#                        bound that captures "~25 words" without false-
#                        positiving on legitimately long substantive
#                        sentences)
#   3. NO_LEADING_DASH — line does not start with `- ` or `* ` (the recipe
#                        forbids bullet/markdown leading characters)
#   4. SUBJECT_LED     — first word starts with a capital letter and is NOT
#                        one of the bare past-tense opener fragments the
#                        recipe's anti-hallucination guards explicitly
#                        prohibit (Confirmed, Found, Showed, Identified,
#                        Rejected — these are subject-omitting leading
#                        verbs documented in the 2026-05-11 calibration
#                        note)
#   5. HAS_MECHANISM   — sentence contains the word `because`, `by`, `via`,
#                        `through`, `due to`, or `from` (one of the
#                        standard mechanism-introducer words the recipe
#                        requires to be present)
#   6. NO_PADDING      — no participial- or declarative-padding tail
#                        matching the same PADDING_REGEXES set as score-t4.sh
#                        (single-source-of-truth for padding shapes across
#                        prose-tier recipe scoring)
#
# Per-rep output: rep N: pass=N/6 fails=[check_name,...]
# Aggregate: mean, min, max, stdev across reps + machine-parseable
# T7_SUMMARY line for downstream tooling.

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
  echo "usage: score-t7.sh <raw-output-file>" >&2
  exit 2
fi

# Same PADDING_REGEXES as score-t4.sh — single source of truth for the
# project's anti-padding shapes (participial + declarative + going-forward
# variants). Kept in sync by convention; if score-t4.sh extends its set,
# this scorer's set must extend in lock-step.
PADDING_REGEXES=(
  ',[[:space:]]+ensuring([[:space:]]|[.!?,])'
  ',[[:space:]]+enabling([[:space:]]|[.!?,])'
  ',[[:space:]]+allowing([[:space:]]|[.!?,])'
  ',[[:space:]]+providing([[:space:]]|[.!?,])'
  'this[[:space:]]+distinction[[:space:]]+is[[:space:]]+crucial'
  'this[[:space:]]+is[[:space:]]+crucial'
  'this[[:space:]]+is[[:space:]]+essential'
  'across[[:space:]]+diverse[[:space:]]+environments'
  '(^|[.!?,][[:space:]]+)this[[:space:]]+ensures([[:space:]]|[.!?,])'
  '(^|[.!?,][[:space:]]+)this[[:space:]]+enables([[:space:]]|[.!?,])'
  '(^|[.!?,][[:space:]]+)this[[:space:]]+guarantees([[:space:]]|[.!?,])'
  '(^|[.!?,][[:space:]]+)this[[:space:]]+delivers([[:space:]]|[.!?,])'
  'clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)([[:space:]]|[.!?,])'
  '(going|moving)[[:space:]]+forward([[:space:]]|[.!?,])'
)

# Subject-omitting bare past-tense opener verbs — the recipe's calibration
# note 2026-05-11 names these as the failure mode the subject-required
# guard targets. Each is checked case-insensitive against the first word.
BARE_VERB_OPENERS=(
  'confirmed'
  'found'
  'showed'
  'identified'
  'rejected'
  'accepted'
  'decided'
  'adopted'
  'chose'
  'selected'
)

# Mechanism-introducer words the recipe directive requires. Lowercased and
# matched as standalone words via the lowercase-body regex below.
MECHANISM_WORDS=(
  'because'
  'by'
  'via'
  'through'
  'due to'
  'from'
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Extract each T7 rep's OUTPUT section into a temp file (mirrors the T3/T4
# parsers — same `===== <task> rep N =====` envelope).
awk -v work="$work" '
  /^===== T7-file-summary rep [0-9]+ =====$/ {
    if (in_rep && capture) close(out)
    rep = $4
    out = work "/rep-" rep ".txt"
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
  echo "no T7 reps found in $infile" >&2
  exit 1
fi

# Score one rep. Prints `<passed>/6 <fail_csv>`.
score_one() {
  local rep_file="$1"
  local single_line_pass=0
  local length_bound_pass=0
  local no_leading_dash_pass=0
  local subject_led_pass=0
  local has_mechanism_pass=0
  local no_padding_pass=1
  local fails=()

  # Collect non-blank lines.
  local body
  body=$(cat "$rep_file")
  # Strip leading/trailing whitespace per line, drop blank lines.
  local non_blank_lines
  non_blank_lines=$(printf '%s\n' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk 'NF')
  local n_lines
  n_lines=$(printf '%s\n' "$non_blank_lines" | awk 'NF' | wc -l | tr -d ' ')

  # Empty output → all six checks fail.
  if [[ -z "$non_blank_lines" ]]; then
    echo "0/6 SINGLE_LINE,LENGTH_BOUND,NO_LEADING_DASH,SUBJECT_LED,HAS_MECHANISM,NO_PADDING"
    return
  fi

  local sentence
  sentence=$(printf '%s' "$non_blank_lines" | head -n 1)

  # Check 1: exactly one non-empty line.
  if (( n_lines == 1 )); then
    single_line_pass=1
  else
    fails+=("SINGLE_LINE")
  fi

  # Check 2: length ≤ 200 chars.
  if (( ${#sentence} <= 200 )); then
    length_bound_pass=1
  else
    fails+=("LENGTH_BOUND")
  fi

  # Check 3: does not start with `- ` or `* ` or `• `.
  if [[ "$sentence" =~ ^[[:space:]]*[-*•][[:space:]] ]]; then
    fails+=("NO_LEADING_DASH")
  else
    no_leading_dash_pass=1
  fi

  # Check 4: subject-led — first word starts with a capital and is not in
  # the bare-verb opener blocklist. Case-insensitive match.
  local first_word
  first_word=$(printf '%s' "$sentence" | awk '{print $1}' | sed -E 's/[[:punct:]]+$//')
  local first_word_lower
  first_word_lower=$(printf '%s' "$first_word" | tr '[:upper:]' '[:lower:]')
  local bare_opener=0
  for v in "${BARE_VERB_OPENERS[@]}"; do
    if [[ "$first_word_lower" == "$v" ]]; then
      bare_opener=1
      break
    fi
  done
  # Also require the first character to be uppercase (a noun-led subject
  # almost always capitalises; a bare-verb opener would also capitalise,
  # which is why the blocklist runs above first).
  local first_char="${first_word:0:1}"
  if (( bare_opener == 0 )) && [[ "$first_char" =~ [A-Z] ]]; then
    subject_led_pass=1
  else
    fails+=("SUBJECT_LED")
  fi

  # Check 5: contains a mechanism word. Match as a whole word, case-insensitive.
  local sentence_lower
  sentence_lower=$(printf '%s' "$sentence" | tr '[:upper:]' '[:lower:]')
  local found_mechanism=0
  for w in "${MECHANISM_WORDS[@]}"; do
    # Whole-word match: surround with space/punctuation boundaries.
    # `due to` is a two-token phrase, handle it as a literal substring.
    if [[ "$w" == *" "* ]]; then
      if [[ "$sentence_lower" == *"$w"* ]]; then
        found_mechanism=1
        break
      fi
    else
      if [[ "$sentence_lower" =~ (^|[^a-zA-Z])$w($|[^a-zA-Z]) ]]; then
        found_mechanism=1
        break
      fi
    fi
  done
  if (( found_mechanism == 1 )); then
    has_mechanism_pass=1
  else
    fails+=("HAS_MECHANISM")
  fi

  # Check 6: no padding tail per the shared PADDING_REGEXES set.
  for pat in "${PADDING_REGEXES[@]}"; do
    if [[ "$sentence_lower" =~ $pat ]]; then
      no_padding_pass=0
      break
    fi
  done
  (( no_padding_pass == 0 )) && fails+=("NO_PADDING")

  local passed=$((single_line_pass + length_bound_pass + no_leading_dash_pass + subject_led_pass + has_mechanism_pass + no_padding_pass))
  local fail_csv=""
  if (( ${#fails[@]} > 0 )); then
    fail_csv=$(IFS=,; echo "${fails[*]}")
  fi
  echo "$passed/6 $fail_csv"
}

# Aggregate across reps.
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

# Mean.
sum=0
for s in "${scores[@]}"; do sum=$((sum + s)); done
mean=$((sum / n_reps))

# Stdev (population).
sumsq=0
for s in "${scores[@]}"; do
  d=$((s - mean))
  sumsq=$((sumsq + d * d))
done
var=$((sumsq / n_reps))
stdev=$(perl -e "printf '%.0f', sqrt($var)")

# Min / max.
min=${scores[0]}
max=${scores[0]}
for s in "${scores[@]}"; do
  (( s < min )) && min=$s
  (( s > max )) && max=$s
done

# Output: human-readable + a final machine-parseable line.
printf "T7 score for %s\n" "$infile"
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
printf "T7_SUMMARY: reps=%d total_passed=%d total_checks=%d mean=%0.4f stdev=%0.4f min=%0.4f max=%0.4f\n" \
  "$n_reps" "$total_passed" "$total_checks" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")"
