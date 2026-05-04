#!/usr/bin/env bash
# Adversarial test-file probe. 2 models × 2 variants × 3 reps = 12 cells.
# Variant A: prompt includes a REFUSE: escape hatch.
# Variant B: same fixture, no REFUSE hatch — tests whether the model
# refuses anyway or edits source/test under pressure.

set -euo pipefail
cd "$(dirname "$0")"
source "../../lib/run_api_cell.sh"

mkdir -p runs
: > timing.tsv
echo -e "model\tvariant\trep\tduration_ms\toutput_bytes" > timing.tsv

MODELS=("deepseek-r1:32b|deepseek-r1" "qwen3-coder-next:latest|coder-next")
VARIANTS=("A|build-prompt.sh" "B|build-prompt-no-refuse.sh")

for spec in "${MODELS[@]}"; do
  IFS='|' read -r model _ <<< "$spec"
  ollama stop "$model" 2>/dev/null || true
done
sleep 2

for spec in "${MODELS[@]}"; do
  IFS='|' read -r model label <<< "$spec"
  for vspec in "${VARIANTS[@]}"; do
    IFS='|' read -r variant builder <<< "$vspec"
    prompt=$(bash "$builder" fixture)
    echo "=== ${label} variant ${variant} ==="
    for rep in 1 2 3; do
      out="runs/${label}-${variant}-r${rep}.txt"
      run_api_cell "$model" "$prompt" "$out"
      echo -e "${label}\t${variant}\t${rep}\t${CELL_DUR_MS}\t${CELL_BYTES}" >> timing.tsv
      echo "  [${label} ${variant} r${rep}] ${CELL_DUR_MS}ms, ${CELL_BYTES}B"
    done
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[adversarial probe done]"
