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

# Backwards compat: old env var name (rename delegate-to-ollama → delegate-local).
DELEGATE_LOCAL_NO_METRICS="${DELEGATE_LOCAL_NO_METRICS:-${DELEGATE_TO_OLLAMA_NO_METRICS:-}}"

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
#
# Metrics: each call appends one JSON line to
# ${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}
# with source:"experiment" so the rollup in scripts/metrics-summary.sh can
# separate interactive delegations from experiment traffic. Opt out with
# DELEGATE_LOCAL_NO_METRICS=1. Token counts come from Ollama's own
# prompt_eval_count / eval_count fields (not char-based estimates) so the
# "tokens avoided" headline reflects real model usage.
run_api_cell() {
  local model="$1" prompt="$2" out="$3" extras="${4:-}"
  [[ -z "$extras" ]] && extras='{}'
  local start end payload response_file
  payload=$(jq -n --arg m "$model" --arg p "$prompt" --argjson e "$extras" \
    '{model:$m, prompt:$p, stream:false, think:false, options:{temperature:0}} * $e')
  local host="${OLLAMA_HOST:-http://localhost:11434}"
  response_file=$(mktemp)
  start=$(now_ms)
  local status=0
  printf '%s' "$payload" | curl -sS --fail -X POST "$host/api/generate" -d @- \
    > "$response_file" || status=$?
  end=$(now_ms)
  CELL_DUR_MS=$((end - start))
  if [[ "$status" -eq 0 ]]; then
    jq -r '.response // ""' "$response_file" > "$out"
  else
    : > "$out"
  fi
  CELL_BYTES=$(wc -c < "$out" | awk '{print $1}')

  _run_api_cell_log_metric "$model" "$response_file" "$status"

  rm -f "$response_file"
  if [[ "$status" -ne 0 ]]; then
    return "$status"
  fi
}

# Append one JSONL metrics line. Kept separate so the happy path is easy to
# read and so the metrics code can be disabled without touching the call site.
_run_api_cell_log_metric() {
  local model="$1" response_file="$2" status="$3"
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 0
  local metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true

  # Session label = leaf directory of the runner's cwd, which is the
  # per-experiment session folder convention (2026-05-04-code-delegation-probe/).
  local session
  session=$(basename "$PWD")
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Pull Ollama's own token counters from the response body when the call
  # succeeded. On failure the fields are absent, so default to 0.
  local prompt_tokens=0 eval_tokens=0
  if [[ "$status" -eq 0 && -s "$response_file" ]]; then
    IFS=$'\t' read -r prompt_tokens eval_tokens < <(jq -r \
      '[(.prompt_eval_count // 0), (.eval_count // 0)] | @tsv' "$response_file" 2>/dev/null)
    prompt_tokens=${prompt_tokens:-0}
    eval_tokens=${eval_tokens:-0}
  fi
  local tokens_avoided=$((prompt_tokens + eval_tokens))

  jq -nc \
    --arg ts "$ts" \
    --arg source "experiment" \
    --arg session "$session" \
    --arg model "$model" \
    --argjson prompt_tokens "$prompt_tokens" \
    --argjson eval_tokens "$eval_tokens" \
    --argjson duration_ms "$CELL_DUR_MS" \
    --argjson output_bytes "$CELL_BYTES" \
    --argjson status "$status" \
    --argjson tokens_avoided "$tokens_avoided" \
    '{ts:$ts, source:$source, session:$session, model:$model, prompt_tokens:$prompt_tokens, eval_tokens:$eval_tokens, duration_ms:$duration_ms, output_bytes:$output_bytes, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}' \
    >> "$metrics_file" 2>/dev/null || true
}
