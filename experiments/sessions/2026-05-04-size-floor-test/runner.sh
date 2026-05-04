#!/usr/bin/env bash
# size-floor test: does the directive-rule pattern survive below the
# v6-winning 19 GB threshold (deepseek-r1:32b)?
#
# Reuses the v5 severity-classification prompt verbatim. Targets deepseek-r1:14b
# (9.0 GB) as the natural direct-family scale-down from the v6 winner. Also
# pulls metrics via experiments/lib/run_api_cell.sh so the Phase 8 rollup
# picks up the cells.
#
# 1 model × 3 reps = 3 cells. Sequential; ms timing, temperature 0, think:false.

set -euo pipefail
cd "$(dirname "$0")"
source "../../lib/run_api_cell.sh"

mkdir -p size-floor-runs
: > timing.tsv
echo -e "model\tsize_gb\trep\tduration_ms\toutput_bytes" > timing.tsv

PROMPT_FILE="../2026-05-03-calibration-example-probe/subtask-1-severity-v5.txt"
MODEL="deepseek-r1:14b"
LABEL="deepseek-r1-14b"
SIZE_GB="9.0"

prompt=$(cat "$PROMPT_FILE")

ollama stop "$MODEL" 2>/dev/null || true
sleep 2

echo "=== ${LABEL} (${SIZE_GB} GB) ==="
for rep in 1 2 3; do
  out="size-floor-runs/${LABEL}-r${rep}.txt"
  run_api_cell "$MODEL" "$prompt" "$out"
  echo -e "${LABEL}\t${SIZE_GB}\t${rep}\t${CELL_DUR_MS}\t${CELL_BYTES}" >> timing.tsv
  echo "  [${LABEL} r${rep}] ${CELL_DUR_MS}ms, ${CELL_BYTES}B"
done
ollama stop "$MODEL" 2>/dev/null || true

echo "[size-floor runner done]"
