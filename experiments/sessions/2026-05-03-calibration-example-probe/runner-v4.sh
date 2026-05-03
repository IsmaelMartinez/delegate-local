#!/usr/bin/env bash
# v4 runner: re-runs ONLY sub-task 1 (severity classification) with a
# counterintuitive one-shot example (G0 = "intentional risky behaviour, medium")
# instead of v2's "hardcoded credentials → high". Tests whether one
# calibration-shaped example shifts the model's reading of the qualifier text.
# 1 sub-task × 2 models × 3 reps = 6 cells.

set -euo pipefail
cd "$(dirname "$0")"
mkdir -p v4-runs
: > v4-timing.tsv
echo -e "model\tsubtask\trep\tduration_ms\toutput_bytes" > v4-timing.tsv

run_cell() {
  local model="$1" model_label="$2" rep="$3"
  local prompt
  prompt=$(cat subtask-1-severity-v4.txt)
  local out="v4-runs/${model_label}-st1-r${rep}.txt"
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
  echo -e "${model_label}\t1\t${rep}\t${dur_ms}\t${bytes}" >> v4-timing.tsv
  echo "  [${model_label} st1 r${rep}] ${dur_ms}ms, ${bytes}B"
}

ollama stop qwen3.6:35b-a3b-q8_0 2>/dev/null || true
ollama stop qwen3-coder-next:latest 2>/dev/null || true
sleep 2

for spec in "qwen3.6:35b-a3b-q8_0|qwen3.6" "qwen3-coder-next:latest|coder-next"; do
  IFS='|' read -r model model_label <<< "$spec"
  echo "=== ${model_label} (counterintuitive one-shot) ==="
  for rep in 1 2 3; do
    run_cell "$model" "$model_label" "$rep"
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[runner-v4 done]"
