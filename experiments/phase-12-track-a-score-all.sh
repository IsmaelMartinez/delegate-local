#!/usr/bin/env bash
# Score every (model, recipe, variant) cell from phase-12-track-a-runner.sh
# and emit a compact summary table consumable by the results-document
# narrative. Reads each cell file via its T-fixture scorer (T4/T7/T8) and
# parses the machine-parseable T?_SUMMARY line for mean/stdev/min/max.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
raw_dir="$repo_root/experiments/results/raw/phase-12-track-a"

if [[ ! -d "$raw_dir" ]]; then
  echo "raw results dir missing: $raw_dir" >&2
  exit 1
fi

# Recipe-to-scorer map.
declare_recipe_scorer() {
  case "$1" in
    commit-message) echo "score-t4.sh T4" ;;
    file-summary)    echo "score-t7.sh T7" ;;
    summarise-issue) echo "score-t8.sh T8" ;;
    *) echo "unknown recipe: $1" >&2; return 1 ;;
  esac
}

echo "MODEL,RECIPE,VARIANT,REPS,MEAN,STDEV,MIN,MAX"
for model_dir in "$raw_dir"/*/; do
  [[ -d "$model_dir" ]] || continue
  model_slug=$(basename "$model_dir")
  for cell_file in "$model_dir"*.txt; do
    [[ -f "$cell_file" ]] || continue
    base=$(basename "$cell_file" .txt)
    # base shape: <recipe>-v<n>  (e.g. commit-message-v1, file-summary-v2)
    variant="${base##*-}"   # v1 / v2 / v3
    recipe="${base%-v*}"    # commit-message / file-summary / summarise-issue
    info=$(declare_recipe_scorer "$recipe") || continue
    scorer_script="${info%% *}"
    fixture_tag="${info##* }"
    summary_line=$(bash "$repo_root/experiments/$scorer_script" "$cell_file" 2>/dev/null | grep -E "^${fixture_tag}_SUMMARY:" | head -n 1)
    if [[ -z "$summary_line" ]]; then
      echo "$model_slug,$recipe,$variant,0,NA,NA,NA,NA"
      continue
    fi
    # Parse: T?_SUMMARY: reps=N total_passed=X total_checks=Y mean=... stdev=... min=... max=...
    reps_val=$(printf '%s' "$summary_line" | grep -oE 'reps=[0-9]+' | head -1 | cut -d= -f2)
    mean_val=$(printf '%s' "$summary_line" | grep -oE 'mean=[0-9.]+' | head -1 | cut -d= -f2)
    stdev_val=$(printf '%s' "$summary_line" | grep -oE 'stdev=[0-9.]+' | head -1 | cut -d= -f2)
    min_val=$(printf '%s' "$summary_line" | grep -oE 'min=[0-9.]+' | head -1 | cut -d= -f2)
    max_val=$(printf '%s' "$summary_line" | grep -oE 'max=[0-9.]+' | head -1 | cut -d= -f2)
    echo "$model_slug,$recipe,$variant,$reps_val,$mean_val,$stdev_val,$min_val,$max_val"
  done
done
