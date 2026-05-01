#!/usr/bin/env bash
# Mechanical T3 scoring — replaces the human "real / plausible / hallucinated"
# rubric with a deterministic citation-rate check, removing author bias from
# the headline number.
#
# Usage: score-t3.sh <raw-output-file> [--t3-snapshot YYYY-MM-DD]
#
# Scoring rubric:
#   - NONE answer (the safe one)            → 1.0
#   - empty / no T3 block                   → 0.0
#   - per-rep score = supported / claimed
#       supported: claim line is `CONCERN | PATTERN` with non-empty PATTERN
#                  AND PATTERN appears as a literal substring in the T3
#                  fixture (the commit log + diffstats the model was given).
#       claimed:   any line containing a `|` separator with non-whitespace on
#                  both sides. Lines without a `|` are chain-of-thought leak
#                  and are excluded from the denominator.
#   - per-file score = mean across reps; also reports min, max, stdev.
#
# Scoring against the fixture (rather than a live repo) keeps the score
# reproducible across machines and time. A model citing a path that exists
# in the fixture has correctly anchored its claim to the input; a model
# citing a path that does not is fabricating. That is the highest-volume
# T3 failure mode the original baseline identified.

set -euo pipefail

t3_snapshot="2026-04-28"
infile=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --t3-snapshot)
      t3_snapshot="${2:-}"
      [[ -n "$t3_snapshot" ]] || { echo "--t3-snapshot requires a date" >&2; exit 2; }
      shift 2
      ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$infile" ]] || { echo "unexpected extra arg: $1" >&2; exit 2; }
      infile="$1"
      shift
      ;;
  esac
done

if [[ -z "$infile" || ! -f "$infile" ]]; then
  echo "usage: score-t3.sh <raw-output-file> [--t3-snapshot DATE]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$repo_root/experiments/fixtures/task-3-merge-patterns-${t3_snapshot}.txt"
if [[ ! -f "$fixture" ]]; then
  echo "T3 fixture not found: $fixture" >&2
  exit 1
fi

# Extract each T3 rep's OUTPUT section into a temp file.
# A rep block looks like:
#   ===== T3-merge-patterns rep N =====
#   DURATION_SEC: ...
#   RUN_STATUS: ...
#   OUTPUT:
#   <body lines until blank line and next ===== or EOF>
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

awk '
  /^===== T3-merge-patterns rep [0-9]+ =====$/ {
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

reps=("$work"/rep-*.txt)
if [[ ! -e "${reps[0]}" ]]; then
  echo "no T3 reps found in $infile" >&2
  exit 1
fi

# Score one rep file. Prints `<supported> <claimed> <score_x100>` to stdout
# (scaled int so we can do integer arithmetic for stdev later).
score_one() {
  local rep_file="$1"
  local body
  body=$(cat "$rep_file")
  # Strip leading/trailing whitespace, blank lines.
  body=$(printf '%s\n' "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' || true)

  if [[ -z "$body" ]]; then
    echo "0 0 0"
    return
  fi
  if [[ "$body" == "NONE" || "$body" == *$'\n'"NONE" || "$body" == "NONE"$'\n'* ]]; then
    # The safe answer.
    echo "1 1 100"
    return
  fi

  local claimed=0 supported=0
  while IFS= read -r line; do
    [[ "$line" != *"|"* ]] && continue
    local left right
    left="${line%%|*}"
    right="${line#*|}"
    left=$(printf '%s' "$left" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    right=$(printf '%s' "$right" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [[ -z "$left" || -z "$right" ]] && continue
    claimed=$((claimed + 1))
    # Strip surrounding quotes/backticks if the model wrapped the pattern.
    right=$(printf '%s' "$right" | sed -E "s/^[\`'\"]+//; s/[\`'\"]+\$//")
    # Look up the pattern as a literal substring in the fixture.
    if grep -F -q -- "$right" "$fixture" 2>/dev/null; then
      supported=$((supported + 1))
    fi
  done <<<"$body"

  if (( claimed == 0 )); then
    echo "0 0 0"
  else
    echo "$supported $claimed $((supported * 100 / claimed))"
  fi
}

# Aggregate across reps.
total_supported=0
total_claimed=0
n_reps=0
scores=()
for rep_file in "${reps[@]}"; do
  read -r s c sc < <(score_one "$rep_file")
  total_supported=$((total_supported + s))
  total_claimed=$((total_claimed + c))
  scores+=("$sc")
  n_reps=$((n_reps + 1))
done

# Mean score (x100).
sum=0
for s in "${scores[@]}"; do sum=$((sum + s)); done
mean=$((sum / n_reps))

# Stdev (population, scaled x100). We compute integer (x100) and convert.
# Variance = mean( (x - mean)^2 ); using integer math, scale up to 4 digits
# to keep fractional precision before sqrt.
sumsq=0
for s in "${scores[@]}"; do
  d=$((s - mean))
  sumsq=$((sumsq + d * d))
done
var=$((sumsq / n_reps))
# Integer sqrt via perl (portable, avoids bc dependency)
stdev=$(perl -e "printf '%.0f', sqrt($var)")

# Min and max.
min=${scores[0]}
max=${scores[0]}
for s in "${scores[@]}"; do
  (( s < min )) && min=$s
  (( s > max )) && max=$s
done

# Output: human-readable + a final machine-parseable line.
printf "T3 score for %s\n" "$infile"
printf "  reps: %d\n" "$n_reps"
printf "  per-rep scores (cited / claimed → fraction):\n"
i=1
for rep_file in "${reps[@]}"; do
  read -r s c sc < <(score_one "$rep_file")
  if (( c == 0 )); then
    printf "    rep %d: 0/0 → 0.00\n" "$i"
  else
    printf "    rep %d: %d/%d → %0.2f\n" "$i" "$s" "$c" "$(perl -e "printf '%f', $s/$c")"
  fi
  i=$((i + 1))
done
printf "  totals: %d cited / %d claimed across all reps\n" "$total_supported" "$total_claimed"
printf "  mean: %0.2f   stdev: %0.2f   min: %0.2f   max: %0.2f\n" \
  "$(perl -e "printf '%f', $mean / 100")" \
  "$(perl -e "printf '%f', $stdev / 100")" \
  "$(perl -e "printf '%f', $min / 100")" \
  "$(perl -e "printf '%f', $max / 100")"
# Machine-parseable (one line, prefixed `T3_SUMMARY:`).
printf "T3_SUMMARY: reps=%d total_cited=%d total_claimed=%d mean=%0.4f stdev=%0.4f min=%0.4f max=%0.4f\n" \
  "$n_reps" "$total_supported" "$total_claimed" \
  "$(perl -e "printf '%f', $mean / 100")" \
  "$(perl -e "printf '%f', $stdev / 100")" \
  "$(perl -e "printf '%f', $min / 100")" \
  "$(perl -e "printf '%f', $max / 100")"
