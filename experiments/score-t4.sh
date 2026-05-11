#!/usr/bin/env bash
# Mechanical T4 scoring — six deterministic structural checks against the
# commit-message recipe's guards. Each check came from a real past MISS
# observed in this project's sessions, so per-rep pass rate is directly
# comparable to the recipe's empirical calibration history.
#
# Usage: score-t4.sh <raw-output-file>
#
# Scoring rubric (each PASS = 1, each FAIL = 0; per-rep score = passed / 6):
#   1. SUBJECT_LEN     — first non-empty line ≤ 72 chars
#   2. SUBJECT_TYPE    — first non-empty line matches
#                        ^(feat|fix|chore|docs|ci|refactor|test|perf|style|build|revert):
#   3. SUBJECT_NO_PR   — first non-empty line does NOT end with (#<digits>)
#   4. BODY_FLUSH_LEFT — no body line starts with whitespace
#   5. BODY_NO_BULLETS — no body line starts with -, *, or • (bullet markers)
#   6. BODY_NO_PADDING — no body sentence ends in a participial-padding tail
#                        matched by the PADDING_PATTERNS regex below.
#
# Per-rep output: rep N: pass=N/6 fails=[check_name,check_name,...]
# Aggregate: mean, min, max, stdev across reps + machine-parseable T4_SUMMARY.

set -euo pipefail

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
  echo "usage: score-t4.sh <raw-output-file>" >&2
  exit 2
fi

# Padding regexes — each one is a POSIX extended regex matched against the
# lowercased body. Two shapes are covered.
#
# Participial padding: comma + verb-ing at the tail of a clause, e.g.
#   "Added a guard, ensuring that …"
# The leading comma keeps these from firing on legitimate sentence-initial
# use of the same verb ("Ensuring data integrity is the goal."). The
# participle is then followed by either whitespace (continuing words) or
# sentence-terminating punctuation (`.!?,`) so `, ensuring.` is caught
# exactly as `, ensuring that …` would be.
#
# Declarative-rephrase padding: sentence-initial "This <verb>" forms that
# restate the prior paragraph rather than adding new substance, plus a
# small set of high-signal phrases ("closing the gap", "going forward")
# that are nearly always trailing-sentence filler in this project's
# corpus. The "This <verb>" forms are anchored to `(^|\.[[:space:]]+)` so
# mid-sentence uses like "this approach ensures correct rendering" do not
# false-positive. Drawn from the PR #84 and PR #86 T4 dogfood outputs
# where the participial guard held but the declarative restating slipped
# through (see ROADMAP.md T4 calibration finding).
PADDING_REGEXES=(
  ',[[:space:]]+ensuring([[:space:]]|[.!?,])'
  ',[[:space:]]+enabling([[:space:]]|[.!?,])'
  ',[[:space:]]+allowing([[:space:]]|[.!?,])'
  ',[[:space:]]+providing([[:space:]]|[.!?,])'
  'this[[:space:]]+distinction[[:space:]]+is[[:space:]]+crucial'
  'this[[:space:]]+is[[:space:]]+crucial'
  'this[[:space:]]+is[[:space:]]+essential'
  'across[[:space:]]+diverse[[:space:]]+environments'
  '(^|\.[[:space:]]+)this[[:space:]]+ensures[[:space:]]'
  '(^|\.[[:space:]]+)this[[:space:]]+enables[[:space:]]'
  '(^|\.[[:space:]]+)this[[:space:]]+guarantees[[:space:]]'
  '(^|\.[[:space:]]+)this[[:space:]]+delivers[[:space:]]'
  'clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)([[:space:]]|[.!?,])'
  '(going|moving)[[:space:]]+forward([[:space:]]|[.!?,])'
)

# Conventional-commit type allowlist (subject prefix before the first ':').
CONVENTIONAL_TYPES='feat|fix|chore|docs|ci|refactor|test|perf|style|build|revert'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Extract each T4 rep's OUTPUT section into a temp file (mirrors score-t3.sh).
awk '
  /^===== T4-commit-message rep [0-9]+ =====$/ {
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
  echo "no T4 reps found in $infile" >&2
  exit 1
fi

# Score one rep. Prints `<passed>/<total> <fail_list_csv>`.
score_one() {
  local rep_file="$1"
  local subject_len_pass=0
  local subject_type_pass=0
  local subject_no_pr_pass=0
  local body_flush_left_pass=1
  local body_no_bullets_pass=1
  local body_no_padding_pass=1
  local fails=()

  # Subject = first non-empty line. Body = everything after the first blank
  # line separator (the line right after the subject is conventionally blank;
  # we tolerate models that skip the separator).
  local subject="" body_started=0 body=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$subject" ]]; then
      # Skip leading blank lines before the subject.
      [[ -z "${line//[[:space:]]/}" ]] && continue
      subject="$line"
      continue
    fi
    if (( body_started == 0 )); then
      # Skip the single blank separator after the subject.
      [[ -z "${line//[[:space:]]/}" ]] && { body_started=1; continue; }
      # No blank separator — treat this as body (model violated shape, but
      # we still check the body's structural properties).
      body_started=1
    fi
    body+="$line"$'\n'
  done < "$rep_file"

  # Empty output → all six checks fail.
  if [[ -z "$subject" ]]; then
    echo "0/6 SUBJECT_LEN,SUBJECT_TYPE,SUBJECT_NO_PR,BODY_FLUSH_LEFT,BODY_NO_BULLETS,BODY_NO_PADDING"
    return
  fi

  # Check 1: subject length ≤ 72.
  if (( ${#subject} <= 72 )); then
    subject_len_pass=1
  else
    fails+=("SUBJECT_LEN")
  fi

  # Check 2: conventional-commit prefix.
  if [[ "$subject" =~ ^(${CONVENTIONAL_TYPES}):[[:space:]] ]]; then
    subject_type_pass=1
  else
    fails+=("SUBJECT_TYPE")
  fi

  # Check 3: no (#NN) suffix on the subject.
  if [[ "$subject" =~ \(#[0-9]+\)[[:space:]]*$ ]]; then
    fails+=("SUBJECT_NO_PR")
  else
    subject_no_pr_pass=1
  fi

  # Check 4: body has no leading whitespace on any non-empty line.
  if [[ -n "$body" ]]; then
    while IFS= read -r bline; do
      [[ -z "${bline//[[:space:]]/}" ]] && continue
      if [[ "$bline" =~ ^[[:space:]] ]]; then
        body_flush_left_pass=0
        break
      fi
    done <<<"$body"
  fi
  (( body_flush_left_pass == 0 )) && fails+=("BODY_FLUSH_LEFT")

  # Check 5: body has no bullet markers (-, *, •) at the start of any non-empty line.
  if [[ -n "$body" ]]; then
    while IFS= read -r bline; do
      [[ -z "${bline//[[:space:]]/}" ]] && continue
      if [[ "$bline" =~ ^[[:space:]]*[-*•][[:space:]] ]]; then
        body_no_bullets_pass=0
        break
      fi
    done <<<"$body"
  fi
  (( body_no_bullets_pass == 0 )) && fails+=("BODY_NO_BULLETS")

  # Check 6: body has no participial-padding patterns. Lowercase the body
  # once, then test each PADDING_REGEXES entry as a POSIX ERE so the
  # participial trigger is anchored to a comma + whitespace + verb-ing +
  # whitespace-or-punctuation boundary. This catches `, ensuring.` (the
  # trailing-space substring approach used to miss it) and rejects bare
  # `ensuring` mid-sentence (which the substring approach used to flag as
  # a false positive when the trailing space was dropped).
  if [[ -n "$body" ]]; then
    local lower_body
    lower_body=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')
    for pat in "${PADDING_REGEXES[@]}"; do
      if [[ "$lower_body" =~ $pat ]]; then
        body_no_padding_pass=0
        break
      fi
    done
  fi
  (( body_no_padding_pass == 0 )) && fails+=("BODY_NO_PADDING")

  local passed=$((subject_len_pass + subject_type_pass + subject_no_pr_pass + body_flush_left_pass + body_no_bullets_pass + body_no_padding_pass))
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
  # passed is like "5/6"
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
printf "T4 score for %s\n" "$infile"
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
printf "T4_SUMMARY: reps=%d total_passed=%d total_checks=%d mean=%0.4f stdev=%0.4f min=%0.4f max=%0.4f\n" \
  "$n_reps" "$total_passed" "$total_checks" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")"
