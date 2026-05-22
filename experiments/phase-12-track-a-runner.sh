#!/usr/bin/env bash
# One-off runner for the Phase 12 Track A domain-priming experiment
# (issue #160). Runs 3 recipes × 3 variants × N models × R reps via
# `scripts/delegate.sh --recipe NAME` and writes per-cell raw output
# files shaped for the T4 / T7 / T8 scorers.
#
# Variants:
#   v1 = current production recipe (control)              -> prompts/
#   v2 = current + domain-priming opening line            -> prompts/_experiments/<recipe>-v2-domain-priming
#   v3 = current + persona-prefix opening (neg control)   -> prompts/_experiments/<recipe>-v3-persona
#
# Recipes:
#   commit-message  -> scored with T4 (existing)
#   file-summary    -> scored with T7 (new)
#   summarise-issue -> scored with T8 (new)
#
# Usage: phase-12-track-a-runner.sh [--reps N] [--time-budget-sec S] <model> [<model>...]
#
# Output: experiments/results/raw/phase-12-track-a/<model-slug>/<recipe>-<variant>.txt
#         (each file contains R reps in the T?-<recipe-id> envelope so the
#         existing scorers can consume them).

set -uo pipefail

reps=5
time_budget_sec=3600  # 60-minute total wall-clock cap

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --reps)
      reps="${2:-}"
      [[ "$reps" =~ ^[1-9][0-9]*$ ]] || { echo "--reps requires positive integer" >&2; exit 2; }
      shift 2
      ;;
    --time-budget-sec)
      time_budget_sec="${2:-}"
      [[ "$time_budget_sec" =~ ^[1-9][0-9]*$ ]] || { echo "--time-budget-sec requires positive integer" >&2; exit 2; }
      shift 2
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if (( $# < 1 )); then
  echo "usage: phase-12-track-a-runner.sh [--reps N] [--time-budget-sec S] <model> [<model>...]" >&2
  exit 2
fi

models=("$@")

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
delegate="$repo_root/scripts/delegate.sh"
feedback="$repo_root/scripts/delegate-feedback.sh"
prompts_dir="$repo_root/prompts"
experiments_prompts_dir="$repo_root/prompts/_experiments"
out_root="$repo_root/experiments/results/raw/phase-12-track-a"

mkdir -p "$out_root"

# T7 fixture body — same input used for every file-summary variant rep.
t7_input_file="$repo_root/experiments/fixtures/task-7-file-summary-2026-05-22.txt"
# T8 fixture body — same input used for every summarise-issue variant rep.
t8_input_file="$repo_root/experiments/fixtures/task-8-summarise-issue-2026-05-22.txt"
# T4 fixture body — for commit-message variants, the fixture's substituted
# template already mirrors the production recipe shape. To test recipe
# variants cleanly we instead reconstruct the inputs (recent_commits,
# diff_stat, why) from the existing dated fixture so the only intentional
# variable is the prompt template the variant carries.
t4_fixture_file="$repo_root/experiments/fixtures/task-4-commit-message-2026-05-21.txt"

# Extract the three commit-message recipe inputs (recent_commits, diff_stat,
# why) from the T4 fixture. The fixture is the substituted recipe template
# already, so we parse it back into its component vars.
extract_t4_var() {
  local marker="$1" body
  body=$(awk -v m="$marker" '
    $0 == "=== " m " ===" { capture=1; next }
    /^=== / && capture { capture=0 }
    capture { print }
  ' "$t4_fixture_file")
  printf '%s' "$body"
}

# Read inputs once. recent_commits = "Recent commit examples to match",
# diff_stat = "This commit (changes)", why = "Context for the WHY paragraph".
t4_recent_commits=$(extract_t4_var "Recent commit examples to match")
t4_diff_stat=$(extract_t4_var "This commit (changes)")
t4_why=$(extract_t4_var "Context for the WHY paragraph")

t7_input=$(cat "$t7_input_file")
t8_input=$(cat "$t8_input_file")

# Each (recipe, variant) cell:
#   recipe_id: T4-commit-message | T7-file-summary | T8-summarise-issue
#   recipe_name: which file under prompts/ (or _experiments/) to load
#   prompts_dir_override: where the recipe lives
#   invocation_tier: prose | reasoning
#   stdin_input: piped to delegate.sh
#   var_args: --var foo=bar ... (whitespace-safe via array)
#   trailing_prompt: final positional prompt arg

start_epoch=$(date +%s)

# Track HIT/MISS counters for the final report.
total_runs=0
total_hits=0
total_misses=0
total_partials=0

# Wrapper to dispatch one rep. Writes one block in the
# `===== <recipe_id> rep <i> =====` envelope to the cell file, captures
# stdout to the OUTPUT section, records HIT/MISS via delegate-feedback.sh.
run_one_rep() {
  local cell_file="$1" recipe_id="$2" rep="$3"
  local recipe_name="$4" prompts_dir_override="$5"
  local tier="$6" trailing_prompt="$7" stdin_input="$8"
  shift 8
  local var_args=("$@")

  echo "===== $recipe_id rep $rep =====" >> "$cell_file"
  local rep_start
  rep_start=$(date +%s)

  local body
  body=$(DELEGATE_PROMPTS_DIR="$prompts_dir_override" \
    DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1 \
    DELEGATE_TO_OLLAMA_NO_META=1 \
    DELEGATE_PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-60}" \
    OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}" \
    OLLAMA_MODEL_OVERRIDE="$CURRENT_MODEL" \
    bash "$delegate" \
    --recipe "$recipe_name" \
    ${var_args[@]+"${var_args[@]}"} \
    "$tier" "$trailing_prompt" \
    <<< "$stdin_input")
  local status=$?
  local rep_end
  rep_end=$(date +%s)
  local elapsed=$((rep_end - rep_start))

  echo "DURATION_SEC: $elapsed" >> "$cell_file"
  echo "RUN_STATUS: $status" >> "$cell_file"
  echo "OUTPUT:" >> "$cell_file"
  printf '%s\n' "$body" >> "$cell_file"
  echo "" >> "$cell_file"

  total_runs=$((total_runs + 1))

  # Record verdict via delegate-feedback.sh — HIT when status=0 and body
  # non-empty; MISS otherwise with a brief reason.
  if (( status == 0 )) && [[ -n "${body//[[:space:]]/}" ]]; then
    bash "$feedback" hit >/dev/null 2>&1 || true
    total_hits=$((total_hits + 1))
  else
    local reason="experiment phase-12 rep failed status=$status recipe=$recipe_name"
    bash "$feedback" miss "$reason" >/dev/null 2>&1 || true
    total_misses=$((total_misses + 1))
  fi

  # Per-rep 90 s guard — stop early if a single rep takes too long.
  if (( elapsed > 90 )); then
    echo "[time-guard] rep took ${elapsed}s (>90s budget) — flagging cell as slow" >&2
  fi
}

# pick-model.sh resolves the tier dynamically; here we want the experiment
# to run against a SPECIFIC model rather than whatever the installed-models
# scan picks. Override via a wrapper that ignores the tier and emits the
# model name we set in CURRENT_MODEL — same trick as the runner.sh does
# implicitly via the API call's `model:` field.
#
# But delegate.sh doesn't accept a --model arg. Easiest path: a per-cell
# wrapper that overrides pick-model.sh via PATH so it returns CURRENT_MODEL.
# The wrapper directory goes ahead of the repo's scripts/ on PATH.

picker_override_dir=$(mktemp -d)
trap 'rm -rf "$picker_override_dir"' EXIT
cat > "$picker_override_dir/pick-model.sh" <<'PICK_EOF'
#!/usr/bin/env bash
# Override: ignore the tier, print whatever was passed in via CURRENT_MODEL.
echo "${CURRENT_MODEL:-}"
PICK_EOF
chmod +x "$picker_override_dir/pick-model.sh"

# delegate.sh calls pick-model.sh via `"$script_dir/pick-model.sh"`, an
# absolute path — so PATH override doesn't help. Need to bind-mount or
# symlink. The clean approach: copy the entire scripts/ dir to a temp
# location and replace pick-model.sh in the copy. That way the original
# scripts/ stays untouched. delegate.sh is referenced by absolute path
# in our invocation, so we point at the copy.

scripts_tmp=$(mktemp -d)
trap 'rm -rf "$picker_override_dir" "$scripts_tmp"' EXIT
cp -R "$repo_root/scripts/." "$scripts_tmp/"
cp "$picker_override_dir/pick-model.sh" "$scripts_tmp/pick-model.sh"
delegate="$scripts_tmp/delegate.sh"

echo "Phase 12 Track A runner starting"
echo "  models:  ${models[*]}"
echo "  reps:    $reps"
echo "  budget:  ${time_budget_sec}s wall-clock"
echo "  out:     $out_root"
echo

for model in "${models[@]}"; do
  export CURRENT_MODEL="$model"
  model_slug=$(echo "$model" | tr '/:.' '___')
  cell_dir="$out_root/$model_slug"
  mkdir -p "$cell_dir"

  echo "=== model: $model ==="

  # Variant table: (variant_label, recipe-name suffix, prompts_dir_override)
  variants=(
    "v1:commit-message:$prompts_dir"
    "v2:commit-message-v2-domain-priming:$experiments_prompts_dir"
    "v3:commit-message-v3-persona:$experiments_prompts_dir"
  )
  for v in "${variants[@]}"; do
    label="${v%%:*}"
    rest="${v#*:}"
    recipe_name="${rest%%:*}"
    pdir="${rest#*:}"
    cell_file="$cell_dir/commit-message-${label}.txt"
    : > "$cell_file"
    echo "MODEL: $model" >> "$cell_file"
    echo "VARIANT: $label" >> "$cell_file"
    echo "RECIPE: $recipe_name" >> "$cell_file"
    echo "DATE: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$cell_file"
    echo "REPS: $reps" >> "$cell_file"
    echo "" >> "$cell_file"

    for (( r=1; r<=reps; r++ )); do
      now_epoch=$(date +%s)
      if (( now_epoch - start_epoch > time_budget_sec )); then
        echo "[budget] global wall-clock budget exceeded ($((now_epoch - start_epoch))s > ${time_budget_sec}s) — stopping" >&2
        echo "PARTIAL: time budget hit at rep $r" >> "$cell_file"
        total_partials=$((total_partials + 1))
        break 3
      fi
      echo "  commit-message $label rep $r/$reps"
      run_one_rep "$cell_file" "T4-commit-message" "$r" \
        "$recipe_name" "$pdir" \
        "prose" "Match the example commit messages exactly in shape and tone. Keep subject ≤ 72 chars." \
        "" \
        --var "recent_commits=$t4_recent_commits" \
        --var "diff_stat=$t4_diff_stat" \
        --var "why=$t4_why"
    done
  done

  variants=(
    "v1:file-summary:$prompts_dir"
    "v2:file-summary-v2-domain-priming:$experiments_prompts_dir"
    "v3:file-summary-v3-persona:$experiments_prompts_dir"
  )
  for v in "${variants[@]}"; do
    label="${v%%:*}"
    rest="${v#*:}"
    recipe_name="${rest%%:*}"
    pdir="${rest#*:}"
    cell_file="$cell_dir/file-summary-${label}.txt"
    : > "$cell_file"
    echo "MODEL: $model" >> "$cell_file"
    echo "VARIANT: $label" >> "$cell_file"
    echo "RECIPE: $recipe_name" >> "$cell_file"
    echo "DATE: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$cell_file"
    echo "REPS: $reps" >> "$cell_file"
    echo "" >> "$cell_file"

    for (( r=1; r<=reps; r++ )); do
      now_epoch=$(date +%s)
      if (( now_epoch - start_epoch > time_budget_sec )); then
        echo "[budget] global wall-clock budget exceeded — stopping" >&2
        echo "PARTIAL: time budget hit at rep $r" >> "$cell_file"
        total_partials=$((total_partials + 1))
        break 3
      fi
      echo "  file-summary $label rep $r/$reps"
      run_one_rep "$cell_file" "T7-file-summary" "$r" \
        "$recipe_name" "$pdir" \
        "prose" "One sentence only. Include the subject and the mechanism." \
        "$t7_input"
    done
  done

  variants=(
    "v1:summarise-issue:$prompts_dir"
    "v2:summarise-issue-v2-domain-priming:$experiments_prompts_dir"
    "v3:summarise-issue-v3-persona:$experiments_prompts_dir"
  )
  for v in "${variants[@]}"; do
    label="${v%%:*}"
    rest="${v#*:}"
    recipe_name="${rest%%:*}"
    pdir="${rest#*:}"
    cell_file="$cell_dir/summarise-issue-${label}.txt"
    : > "$cell_file"
    echo "MODEL: $model" >> "$cell_file"
    echo "VARIANT: $label" >> "$cell_file"
    echo "RECIPE: $recipe_name" >> "$cell_file"
    echo "DATE: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$cell_file"
    echo "REPS: $reps" >> "$cell_file"
    echo "" >> "$cell_file"

    for (( r=1; r<=reps; r++ )); do
      now_epoch=$(date +%s)
      if (( now_epoch - start_epoch > time_budget_sec )); then
        echo "[budget] global wall-clock budget exceeded — stopping" >&2
        echo "PARTIAL: time budget hit at rep $r" >> "$cell_file"
        total_partials=$((total_partials + 1))
        break 3
      fi
      echo "  summarise-issue $label rep $r/$reps"
      run_one_rep "$cell_file" "T8-summarise-issue" "$r" \
        "$recipe_name" "$pdir" \
        "reasoning" "Adhere to the section order exactly. Omit empty sections." \
        "$t8_input" \
        --var "kind=issue" \
        --var "N_FACTS=5"
    done
  done

  # Stop the model between models for cold-load fairness (mirrors run-baseline.sh).
  if command -v ollama >/dev/null 2>&1; then
    ollama stop "$model" 2>/dev/null || true
    sleep 2
  fi
done

end_epoch=$(date +%s)
elapsed_total=$((end_epoch - start_epoch))

echo
echo "=== Phase 12 Track A runner finished ==="
echo "  total reps:    $total_runs"
echo "  HITs:          $total_hits"
echo "  MISSes:        $total_misses"
echo "  partial cells: $total_partials"
echo "  wall-clock:    ${elapsed_total}s"
echo "  output:        $out_root"
echo
echo "RUNNER_SUMMARY: total_runs=$total_runs hits=$total_hits misses=$total_misses partials=$total_partials wall_clock_sec=$elapsed_total"
