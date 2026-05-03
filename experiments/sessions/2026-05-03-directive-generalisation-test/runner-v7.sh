#!/usr/bin/env bash
# v7: directive-rule generalisation test. Same pattern as v5 (hard-rule
# directive with priority-ordered keyword triggers, non-negotiable framing,
# one-shot example) but on a NEW classification task: PR triage by category
# rather than security-finding severity. Tests whether the directive-rule
# pattern is task-specific or generalises.
#
# 2 models × 3 reps = 6 cells. Models: deepseek-r1:32b (v6 winner) and
# qwen3-coder-next:latest (v5 winner). think:false, temperature 0, ms timing.

set -euo pipefail
cd "$(dirname "$0")"
mkdir -p v7-runs
: > v7-timing.tsv
echo -e "model\trep\tduration_ms\toutput_bytes" > v7-timing.tsv

PROMPT_FILE="pr-triage-prompt.txt"

run_cell() {
  local model="$1" model_label="$2" rep="$3"
  local prompt
  prompt=$(cat "$PROMPT_FILE")
  local out="v7-runs/${model_label}-r${rep}.txt"
  local start end dur_ms
  start=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  jq -n --arg m "$model" --arg p "$prompt" \
    '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}}' \
    | curl -s -X POST http://localhost:11434/api/generate -d @- \
    | jq -r '.response // ""' > "$out"
  end=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  dur_ms=$((end - start))
  local bytes
  bytes=$(wc -c < "$out" | tr -d ' ')
  echo -e "${model_label}\t${rep}\t${dur_ms}\t${bytes}" >> v7-timing.tsv
  echo "  [${model_label} r${rep}] ${dur_ms}ms, ${bytes}B"
}

ollama stop deepseek-r1:32b 2>/dev/null || true
ollama stop qwen3-coder-next:latest 2>/dev/null || true
sleep 2

for spec in "deepseek-r1:32b|deepseek-r1" "qwen3-coder-next:latest|coder-next"; do
  IFS='|' read -r model model_label <<< "$spec"
  echo "=== ${model_label} ==="
  for rep in 1 2 3; do
    run_cell "$model" "$model_label" "$rep"
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[runner-v7 done]"
