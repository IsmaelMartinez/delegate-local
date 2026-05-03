#!/usr/bin/env bash
# Re-run the v2 cells via Ollama HTTP API to avoid the CLI's stream-rewrite
# artefacts that contaminate the captured-to-file output. Same cells as
# runner-v2.sh: 4 sub-tasks × 2 models × 3 reps = 24.

set -euo pipefail
cd "$(dirname "$0")"
mkdir -p v2-runs
: > v2-timing.tsv
echo -e "model\tsubtask\trep\tseconds\toutput_bytes" > v2-timing.tsv

run_cell() {
  local model="$1" model_label="$2" st="$3" rep="$4"
  local prompt
  prompt=$(cat subtask-${st}-*-v2.txt)
  local out="v2-runs/${model_label}-st${st}-r${rep}.txt"
  local start end
  start=$(date +%s)
  jq -n --arg m "$model" --arg p "$prompt" \
    '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}}' \
    | curl -s -X POST http://localhost:11434/api/generate -d @- \
    | jq -r '.response // ""' > "$out"
  end=$(date +%s)
  local secs=$((end - start))
  local bytes
  bytes=$(wc -c < "$out" | tr -d ' ')
  echo -e "${model_label}\t${st}\t${rep}\t${secs}\t${bytes}" >> v2-timing.tsv
  echo "  [${model_label} st${st} r${rep}] ${secs}s, ${bytes}B"
}

ollama stop qwen3.6:35b-a3b-q8_0 2>/dev/null || true
ollama stop qwen3-coder-next:latest 2>/dev/null || true
sleep 2

for spec in "qwen3.6:35b-a3b-q8_0|qwen3.6" "qwen3-coder-next:latest|coder-next"; do
  IFS='|' read -r model model_label <<< "$spec"
  echo "=== ${model_label} ==="
  for st in 1 2 3 4; do
    for rep in 1 2 3; do
      run_cell "$model" "$model_label" "$st" "$rep"
    done
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[done]"
