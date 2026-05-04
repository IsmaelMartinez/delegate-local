#!/usr/bin/env bash
# v8: code-generation delegation probe under Aider-style SEARCH/REPLACE format.
#
# 2 models × 3 tasks × 3 reps = 18 cells.
# Models: deepseek-r1:32b (v6 reasoning winner) and qwen3-coder-next:latest
# (v5 code winner). think:false, temperature 0, ms timing. Uses run_api_cell.sh.

set -euo pipefail
cd "$(dirname "$0")"
source "../../lib/run_api_cell.sh"

mkdir -p v8-runs
: > v8-timing.tsv
echo -e "model\ttask\trep\tduration_ms\toutput_bytes" > v8-timing.tsv

TASKS=(t1 t2 t3)
MODEL_SPECS=("deepseek-r1:32b|deepseek-r1" "qwen3-coder-next:latest|coder-next")

for spec in "${MODEL_SPECS[@]}"; do
  IFS='|' read -r model _ <<< "$spec"
  ollama stop "$model" 2>/dev/null || true
done
sleep 2

for spec in "${MODEL_SPECS[@]}"; do
  IFS='|' read -r model model_label <<< "$spec"
  echo "=== ${model_label} ==="
  for task in "${TASKS[@]}"; do
    prompt=$(bash build-prompt.sh "fixtures/${task}")
    for rep in 1 2 3; do
      out="v8-runs/${model_label}-${task}-r${rep}.txt"
      run_api_cell "$model" "$prompt" "$out"
      echo -e "${model_label}\t${task}\t${rep}\t${CELL_DUR_MS}\t${CELL_BYTES}" >> v8-timing.tsv
      echo "  [${model_label} ${task} r${rep}] ${CELL_DUR_MS}ms, ${CELL_BYTES}B"
    done
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[runner-v8 done]"
