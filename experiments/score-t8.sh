#!/usr/bin/env bash
# Mechanical T8 scoring — six deterministic structural / content checks
# against the summarise-issue recipe's guards. Each check came from a
# real past MISS observed in this project's summarise-issue dogfooding
# (see prompts/summarise-issue.md calibration notes 2026-05-10 and
# 2026-05-11 for provenance).
#
# Usage: score-t8.sh <raw-output-file>
#
# Scoring rubric (each PASS = 1, each FAIL = 0; per-rep score = passed / 6):
#   1. HAS_WHAT_HAPPENED   — output contains the literal `## What happened`
#                            heading (the recipe's primary section)
#   2. STARTS_WITH_SECTION — first non-empty line is `## What happened`
#                            (the recipe forbids preamble)
#   3. WHAT_HAPPENED_BULLETS — at least one `- ` bullet under the
#                            `## What happened` heading (recipe requires
#                            "N_FACTS bullets, each one event")
#   4. NO_PLACEHOLDER_TEXT — output does NOT contain any of the documented
#                            empty-section placeholder phrases ("No blockers",
#                            "Nothing to do", "TBD", "N/A", "No specific
#                            blockers", "No explicit blockers") — the recipe's
#                            OMIT-EMPTY-SECTION rule is the highest-volume
#                            failure mode and these are the exact phrases
#                            the substring blocklist names
#   5. NO_GROUP_CLAIM      — output does NOT contain the documented group-
#                            claim opener phrases ("several people agreed",
#                            "the team agreed", "many commenters", "various
#                            participants") — recipe forbids summarising
#                            comments as a group
#   6. NO_PADDING          — no participial- or declarative-padding tail
#                            matching the shared PADDING_REGEXES set
#                            (single-source-of-truth across prose-tier
#                            recipe scoring)
#
# Per-rep output: rep N: pass=N/6 fails=[check_name,...]
# Aggregate: mean, min, max, stdev across reps + machine-parseable
# T8_SUMMARY line for downstream tooling.

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
  echo "usage: score-t8.sh <raw-output-file>" >&2
  exit 2
fi

# Shared PADDING_REGEXES — kept in sync with score-t4.sh / score-t7.sh.
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

# Placeholder phrases the recipe's OMIT-EMPTY-SECTION rule explicitly
# prohibits. Case-insensitive substring match against the full body.
PLACEHOLDER_PHRASES=(
  'no blockers'
  'no specific blockers'
  'no explicit blockers'
  'nothing to do'
  'n/a'
  'not applicable'
)
# `tbd` is matched separately as a whole word to avoid false-positive on
# 'subtbd' or substrings inside URLs.

# Group-claim opener phrases the recipe's "name the comment, not the
# group" rule prohibits. Case-insensitive substring match.
GROUP_CLAIM_PHRASES=(
  'several people agreed'
  'the team agreed'
  'many commenters'
  'various participants'
  'everyone agreed'
  'most people'
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Extract each T8 rep's OUTPUT section into a temp file.
awk -v work="$work" '
  /^===== T8-summarise-issue rep [0-9]+ =====$/ {
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
  echo "no T8 reps found in $infile" >&2
  exit 1
fi

# Score one rep. Prints `<passed>/6 <fail_csv>`.
score_one() {
  local rep_file="$1"
  local has_what_happened_pass=0
  local starts_with_section_pass=0
  local what_happened_bullets_pass=0
  local no_placeholder_text_pass=1
  local no_group_claim_pass=1
  local no_padding_pass=1
  local fails=()

  local body
  body=$(cat "$rep_file")

  # Empty output → all six checks fail.
  if [[ -z "${body//[[:space:]]/}" ]]; then
    echo "0/6 HAS_WHAT_HAPPENED,STARTS_WITH_SECTION,WHAT_HAPPENED_BULLETS,NO_PLACEHOLDER_TEXT,NO_GROUP_CLAIM,NO_PADDING"
    return
  fi

  local body_lower
  body_lower=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')

  # Check 1: contains `## What happened` heading.
  if [[ "$body" == *"## What happened"* ]]; then
    has_what_happened_pass=1
  else
    fails+=("HAS_WHAT_HAPPENED")
  fi

  # Check 2: first non-empty line is `## What happened` exactly (after
  # stripping leading/trailing whitespace).
  local first_line
  first_line=$(printf '%s\n' "$body" | awk 'NF{print; exit}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [[ "$first_line" == "## What happened" ]]; then
    starts_with_section_pass=1
  else
    fails+=("STARTS_WITH_SECTION")
  fi

  # Check 3: at least one `- ` bullet appears after the `## What happened`
  # heading but before the next `## ` heading (if any).
  local what_happened_section
  what_happened_section=$(awk '
    /^## What happened[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section { in_section=0 }
    in_section { print }
  ' "$rep_file")
  if printf '%s\n' "$what_happened_section" | awk 'NF' | grep -qE '^[[:space:]]*-[[:space:]]'; then
    what_happened_bullets_pass=1
  else
    fails+=("WHAT_HAPPENED_BULLETS")
  fi

  # Check 4: no placeholder text.
  local placeholder_found=0
  for p in "${PLACEHOLDER_PHRASES[@]}"; do
    if [[ "$body_lower" == *"$p"* ]]; then
      placeholder_found=1
      break
    fi
  done
  # TBD as a whole word (with word boundaries).
  if (( placeholder_found == 0 )); then
    if [[ "$body_lower" =~ (^|[^a-zA-Z])tbd($|[^a-zA-Z]) ]]; then
      placeholder_found=1
    fi
  fi
  if (( placeholder_found == 1 )); then
    no_placeholder_text_pass=0
    fails+=("NO_PLACEHOLDER_TEXT")
  fi

  # Check 5: no group-claim opener phrase.
  for g in "${GROUP_CLAIM_PHRASES[@]}"; do
    if [[ "$body_lower" == *"$g"* ]]; then
      no_group_claim_pass=0
      break
    fi
  done
  (( no_group_claim_pass == 0 )) && fails+=("NO_GROUP_CLAIM")

  # Check 6: no padding tail per the shared PADDING_REGEXES set.
  for pat in "${PADDING_REGEXES[@]}"; do
    if [[ "$body_lower" =~ $pat ]]; then
      no_padding_pass=0
      break
    fi
  done
  (( no_padding_pass == 0 )) && fails+=("NO_PADDING")

  local passed=$((has_what_happened_pass + starts_with_section_pass + what_happened_bullets_pass + no_placeholder_text_pass + no_group_claim_pass + no_padding_pass))
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

printf "T8 score for %s\n" "$infile"
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
printf "T8_SUMMARY: reps=%d total_passed=%d total_checks=%d mean=%0.4f stdev=%0.4f min=%0.4f max=%0.4f\n" \
  "$n_reps" "$total_passed" "$total_checks" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")"
