#!/usr/bin/env bash
# v6: discipline-not-size probe. Same v5 hard-rule prompt that brought
# qwen3-coder-next to 5/5 (Opus parity). Tested across smaller installed
# models to see how far down the size curve the directive-rule pattern
# survives. Sub-task 1 (severity classification) only — the only sub-task
# with residual gap from earlier baselines.
#
# 5 models × 3 reps = 15 cells. Sequential per model so VRAM is released
# between models. ms timing, temperature 0, think:false.

set -euo pipefail
cd "$(dirname "$0")"
mkdir -p v6-runs
: > v6-timing.tsv
echo -e "model\tsize_gb\trep\tduration_ms\toutput_bytes" > v6-timing.tsv

PROMPT_FILE="../2026-05-03-calibration-example-probe/subtask-1-severity-v5.txt"

run_cell() {
  local model="$1" model_label="$2" size_gb="$3" rep="$4"
  local prompt
  prompt=$(cat "$PROMPT_FILE")
  local out="v6-runs/${model_label}-r${rep}.txt"
  local start end dur_ms
  start=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  jq -n --arg m "$model" --arg p "$prompt" \
    '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}}' \
    | curl -sS --fail -X POST http://localhost:11434/api/generate -d @- \
    | jq -r '.response // ""' > "$out"
  end=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  dur_ms=$((end - start))
  local bytes
  bytes=$(wc -c < "$out" | tr -d ' ')
  echo -e "${model_label}\t${size_gb}\t${rep}\t${dur_ms}\t${bytes}" >> v6-timing.tsv
  echo "  [${model_label} ${size_gb}GB r${rep}] ${dur_ms}ms, ${bytes}B"
}

# Pre-stop everything for clean cold loads
for m in qwen3-coder-next:latest qwen3.6:35b-a3b-q8_0 qwen3-coder:30b-a3b-q8_0 \
         deepseek-r1:32b phi4-reasoning:plus gemma4:latest; do
  ollama stop "$m" 2>/dev/null || true
done
sleep 2

# (model, label, size_gb)
for spec in \
  "qwen3-coder-next:latest|coder-next|51" \
  "qwen3-coder:30b-a3b-q8_0|coder-30b|32" \
  "deepseek-r1:32b|deepseek-r1-32b|19" \
  "phi4-reasoning:plus|phi4-reasoning|11" \
  "gemma4:latest|gemma4|9.6" \
  ; do
  IFS='|' read -r model model_label size_gb <<< "$spec"
  echo "=== ${model_label} (${size_gb} GB) ==="
  for rep in 1 2 3; do
    run_cell "$model" "$model_label" "$size_gb" "$rep"
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[runner-v6 done]"
