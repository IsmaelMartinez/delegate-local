#!/usr/bin/env bash
# P1 probe (ROADMAP 2026-05-13 follow-up from MLX track v2 baseline #115):
# does explicit "fewer claims you are confident about" prompting pull MLX
# toward the voluntary 1-claim-per-rep restraint Ollama showed in v2?
#
# Design: four cells — {Ollama, MLX} × {base, restraint} — 3 reps each,
# against the existing 2026-04-28 T3 fixture so the only variable is the
# prompt wording. Wire shape mirrors experiments/runner.sh's run_task_api
# (Ollama: /api/generate think:false; MLX: /v1/chat/completions
# enable_thinking:false) — same regime as PR #115's v2 measurement.
#
# Decision rule:
#   - If MLX restraint drops claim count without losing citation rate
#     → restraint is a prompt property → recipe-authoring guideline.
#   - If MLX restraint stays at the cap (4/rep)
#     → restraint is a runtime property → finding documented, no recipe.
#
# Score with experiments/score-t3.sh on each cell's runs/*.txt — the rep
# header format matches what the scorer expects.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
fixture="$repo_root/experiments/fixtures/task-3-merge-patterns-2026-04-28.txt"
runs_dir="$here/runs"
mkdir -p "$runs_dir"

REPS="${REPS:-3}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
MLX_HOST="${MLX_HOST:-http://localhost:8080}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.6:35b-a3b-q8_0}"
MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen3.6-35B-A3B-8bit}"

PROMPT_BASE="These are the last 10 commits on a Scottish election website. List up to 4 specific concerns or loose ends each tied to a checkable file/path/grep pattern. For each: CONCERN | FILE_OR_PATTERN_TO_VERIFY. If nothing is reliably checkable, output: NONE. Do not speculate beyond what the commit subjects state."

PROMPT_RESTRAINT="$PROMPT_BASE Prefer fewer claims you are confident about over filling the cap. Listing one well-supported concern beats listing four speculative ones. Output only the concerns the commit subjects directly support."

cell() {
  local backend="$1" model="$2" prompt_label="$3" prompt="$4"
  local out="$runs_dir/${backend}-${prompt_label}.txt"
  : > "$out"
  echo "BACKEND: $backend" >> "$out"
  echo "MODEL: $model" >> "$out"
  echo "PROMPT_LABEL: $prompt_label" >> "$out"
  echo "REPS: $REPS" >> "$out"
  echo "FIXTURE: $(basename "$fixture")" >> "$out"

  local full_input
  full_input="$(cat "$fixture")"$'\n\n'"$prompt"

  local rep
  for rep in $(seq 1 "$REPS"); do
    echo "===== T3-merge-patterns rep $rep =====" >> "$out"
    local start end elapsed response body status=0 payload
    start=$(date +%s)
    if [[ "$backend" == "ollama" ]]; then
      payload=$(jq -nc --arg m "$model" --arg p "$full_input" \
        '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}}')
      response=$(curl -sS --fail -X POST "$OLLAMA_HOST/api/generate" -d @- <<<"$payload") || status=$?
      if (( status == 0 )); then
        body=$(jq -r '.response // ""' <<<"$response")
      else
        body="API_CALL_FAILED status=$status"
      fi
    else
      payload=$(jq -nc --arg m "$model" --arg p "$full_input" \
        '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:0, max_tokens:4096, chat_template_kwargs:{enable_thinking:false}}')
      response=$(curl -sS --fail -X POST "$MLX_HOST/v1/chat/completions" -d @- <<<"$payload") || status=$?
      if (( status == 0 )); then
        body=$(jq -r '.choices[0].message.content // ""' <<<"$response")
      else
        body="API_CALL_FAILED status=$status"
      fi
    fi
    end=$(date +%s)
    elapsed=$((end - start))
    echo "DURATION_SEC: $elapsed" >> "$out"
    echo "RUN_STATUS: $status" >> "$out"
    echo "OUTPUT:" >> "$out"
    echo "$body" >> "$out"
    echo "" >> "$out"
    printf "  %-6s %-9s rep %d: %2ds (status=%d)\n" "$backend" "$prompt_label" "$rep" "$elapsed" "$status" >&2
  done
}

echo "Probe: T3 restraint prompting against the v2-baseline backends." >&2
echo "  Ollama: $OLLAMA_MODEL @ $OLLAMA_HOST" >&2
echo "  MLX:    $MLX_MODEL @ $MLX_HOST" >&2
echo "  Reps:   $REPS" >&2
echo >&2

cell ollama "$OLLAMA_MODEL" base      "$PROMPT_BASE"
cell ollama "$OLLAMA_MODEL" restraint "$PROMPT_RESTRAINT"
cell mlx    "$MLX_MODEL"    base      "$PROMPT_BASE"
cell mlx    "$MLX_MODEL"    restraint "$PROMPT_RESTRAINT"

echo >&2
echo "Done. Score each cell with:" >&2
for f in "$runs_dir"/*.txt; do
  echo "  bash experiments/score-t3.sh $f" >&2
done
