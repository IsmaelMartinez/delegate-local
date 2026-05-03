#!/usr/bin/env bash
# v3 runner: re-runs the v2 sub-task suite with Ollama's `format` parameter
# providing a JSON schema for sub-tasks 1–3. Tests whether schema-constrained
# decoding (XGrammar-backed) closes the severity-calibration gap that was
# the only remaining failure in v2.
#
# Same fixture, same prompts, same models, same N=3. Sub-task 4 stays plaintext
# (no schema applies). Probes Ollama bug #14645 in passing — if the bug bites,
# format will be silently ignored when think:false and outputs will look like
# v2 (no enum enforcement).

set -euo pipefail

cd "$(dirname "$0")"
PROMPT_DIR="../2026-05-03-security-review-delegation"
mkdir -p v3-runs
: > v3-timing.tsv
echo -e "model\tsubtask\trep\tduration_ms\toutput_bytes" > v3-timing.tsv

# JSON schemas per sub-task. Sub-task 4 is plaintext (no schema).
SCHEMA_ST1='{"type":"array","minItems":5,"maxItems":5,"items":{"type":"object","properties":{"id":{"type":"string","enum":["F1","F2","F3","F4","F5"]},"severity":{"type":"string","enum":["high","medium","low","info"]}},"required":["id","severity"]}}'
SCHEMA_ST2='{"type":"array","minItems":5,"maxItems":5,"items":{"type":"object","properties":{"id":{"type":"string","enum":["F1","F2","F3","F4","F5"]},"classification":{"type":"string","enum":["REAL","ALLOWLISTED_FP"]},"matched_allowlist":{"type":["string","null"]}},"required":["id","classification","matched_allowlist"]}}'
SCHEMA_ST3='{"type":"array","minItems":5,"maxItems":5,"items":{"type":"object","properties":{"id":{"type":"string","enum":["F1","F2","F3","F4","F5"]},"prose":{"type":"string"}},"required":["id","prose"]}}'

run_cell() {
  local model="$1" model_label="$2" st="$3" rep="$4"
  local prompt
  prompt=$(cat "${PROMPT_DIR}/subtask-${st}-"*"-v2.txt")
  local out="v3-runs/${model_label}-st${st}-r${rep}.txt"
  local schema_var="SCHEMA_ST${st}"
  local schema="${!schema_var:-}"
  local payload
  if [[ -n "$schema" ]]; then
    payload=$(jq -n --arg m "$model" --arg p "$prompt" --argjson f "$schema" \
      '{model:$m, prompt:$p, stream:false, think:false, format:$f, options:{temperature:0}}')
  else
    payload=$(jq -n --arg m "$model" --arg p "$prompt" \
      '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}}')
  fi
  local start end dur_ms
  start=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  printf '%s' "$payload" | curl -s -X POST http://localhost:11434/api/generate -d @- \
    | jq -r '.response // ""' > "$out"
  end=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  dur_ms=$((end - start))
  local bytes
  bytes=$(wc -c < "$out" | tr -d ' ')
  echo -e "${model_label}\t${st}\t${rep}\t${dur_ms}\t${bytes}" >> v3-timing.tsv
  echo "  [${model_label} st${st} r${rep}] ${dur_ms}ms, ${bytes}B"
}

ollama stop qwen3.6:35b-a3b-q8_0 2>/dev/null || true
ollama stop qwen3-coder-next:latest 2>/dev/null || true
sleep 2

for spec in "qwen3.6:35b-a3b-q8_0|qwen3.6" "qwen3-coder-next:latest|coder-next"; do
  IFS='|' read -r model model_label <<< "$spec"
  echo "=== ${model_label} (with format:schema for st1-3) ==="
  for st in 1 2 3 4; do
    for rep in 1 2 3; do
      run_cell "$model" "$model_label" "$st" "$rep"
    done
  done
  ollama stop "$model" 2>/dev/null || true
  sleep 2
done

echo "[runner-v3 done]"
