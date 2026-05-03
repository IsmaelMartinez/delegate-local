#!/usr/bin/env bash
# Shared helpers for experiment runners. Source this from a runner script:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../../lib/run_api_cell.sh"
#
# Exports:
#   now_ms              — print Unix epoch milliseconds (HiRes precision).
#   run_api_cell        — call Ollama generate API with the disciplined defaults.
#
# After run_api_cell returns, these globals are set:
#   CELL_DUR_MS         — duration in ms (sufficient resolution for sub-second cells).
#   CELL_BYTES          — output file size in bytes.
#
# The disciplined defaults baked in:
#   stream:false        — single response, not chunked.
#   think:false         — suppress reasoning tokens for closed-format work.
#   temperature: 0      — deterministic outputs across reps.
#   curl -sS --fail     — HTTP errors propagate as non-zero exit; under
#                         set -euo pipefail this breaks the cell loudly
#                         instead of silently producing empty output.
#
# Three bugs caught one PR at a time during the v3-through-v7 chain that
# this template prevents:
#   1. date +%s precision is 50–100% error margin for 1–2s cells. Use ms.
#   2. curl -s without --fail swallows HTTP errors as 0-byte output. Use --fail.
#   3. Scorer score functions that compare o.get("severity") == GT.get(o.get("id"))
#      return True on malformed dicts via None==None. Always guard the id lookup.
#      (The third bug is a scorer concern, not a runner concern, but worth flagging
#      here because new runners often pair with new scorers.)

if [[ "${RUN_API_CELL_LIB_LOADED:-}" == "1" ]]; then
  return 0
fi
RUN_API_CELL_LIB_LOADED=1

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'
}

# run_api_cell <model> <prompt> <out_file> [<extras_json>]
#
# extras_json is an optional JSON object that gets merged into the default
# request payload. The default is empty (no override).
#
# Use it to pass schema-constrained decoding:
#   schema='{"type":"array","items":{...}}'
#   run_api_cell "$model" "$prompt" "$out" "{\"format\":$schema}"
#
# Or to override think/temperature for one cell:
#   run_api_cell "$model" "$prompt" "$out" '{"think":true,"options":{"temperature":0.2}}'
#
# Aborts the script on HTTP error (curl --fail). Caller is expected to be
# under set -euo pipefail.
run_api_cell() {
  local model="$1" prompt="$2" out="$3" extras="${4:-}"
  [[ -z "$extras" ]] && extras='{}'
  local start end payload
  payload=$(jq -n --arg m "$model" --arg p "$prompt" --argjson e "$extras" \
    '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}} * $e')
  local host="${OLLAMA_HOST:-http://localhost:11434}"
  start=$(now_ms)
  printf '%s' "$payload" | curl -sS --fail -X POST "$host/api/generate" -d @- \
    | jq -r '.response // ""' > "$out"
  end=$(now_ms)
  CELL_DUR_MS=$((end - start))
  CELL_BYTES=$(wc -c < "$out" | awk '{print $1}')
}
