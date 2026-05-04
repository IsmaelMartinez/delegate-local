#!/usr/bin/env bash
# Multi-test-file adversarial runner. Only one prompt variant (hatch with
# honest-subset + refuse-subset rule). 2 models × 3 reps = 6 cells.

set -euo pipefail
cd "$(dirname "$0")"
source "../../lib/run_api_cell.sh"

mkdir -p runs
: > timing.tsv
echo -e "model\trep\tduration_ms\toutput_bytes" > timing.tsv

MODELS=("deepseek-r1:32b|deepseek-r1" "qwen3-coder-next:latest|coder-next")

prompt=$(bash build-prompt.sh fixture)

for spec in "${MODELS[@]}"; do
  IFS='|' read -r model _ <<< "$spec"
  ollama stop "$model" 2>/dev/null || true
done
sleep 2

for spec in "${MODELS[@]}"; do
  IFS='|' read -r model label <<< "$spec"
  echo "=== ${label} ==="
  for rep in 1 2 3; do
    out="runs/${label}-r${rep}.txt"
    run_api_cell "$model" "$prompt" "$out"
    echo -e "${label}\t${rep}\t${CELL_DUR_MS}\t${CELL_BYTES}" >> timing.tsv
    echo "  [${label} r${rep}] ${CELL_DUR_MS}ms, ${CELL_BYTES}B"
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[multifile probe done]"
