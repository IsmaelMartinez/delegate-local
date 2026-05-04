#!/usr/bin/env bash
# Smaller-model adversarial runner. Same fixture + two prompt variants as the
# parent adversarial probe, but targets deepseek-r1:14b (9.0 GB) and
# phi4-reasoning:plus (11 GB) instead of the 19 / 51 GB winners. Tests whether
# the deepseek-family correctness preference and the coder-family off-by-one
# trade-off hold at smaller sizes.

set -euo pipefail
cd "$(dirname "$0")"
source "../../lib/run_api_cell.sh"

mkdir -p runs
: > timing.tsv
echo -e "model\tvariant\trep\tduration_ms\toutput_bytes" > timing.tsv

MODELS=("deepseek-r1:14b|deepseek-r1-14b" "phi4-reasoning:plus|phi4-reasoning")
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

echo "[smaller adversarial probe done]"
