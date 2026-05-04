#!/usr/bin/env bash
# Wrap Ollama's /api/generate HTTP endpoint with tier-based model selection
# and per-invocation metrics. Use this instead of bare `ollama run` so every
# delegation is observable and the response is parser-clean (no CLI cursor
# rewrites or spinner ANSI mixed into stdout).
#
# Usage:
#   delegate.sh <tier> "<prompt>"           # context comes from stdin
#   echo "..." | delegate.sh prose "..."    # explicit pipe
#
# Tiers: code | prose | reasoning | long-context (see scripts/pick-model.sh)
#
# Env:
#   DELEGATE_TO_OLLAMA_NO_METRICS=1         # opt out of metrics logging
#   DELEGATE_METRICS_FILE=<path>            # override metrics destination
#   DELEGATE_THINK=true|false               # default false; set true if the
#                                           #   model's chain-of-thought
#                                           #   genuinely helps for the task.
#   OLLAMA_HOST=<url>                       # default http://localhost:11434
#
# Output:  model response on stdout (no ANSI; HTTP body is plain text)
# Errors:  pick-model failures and HTTP errors propagate as non-zero exit.
#          A metrics line is still appended with exit_status set.

set -uo pipefail

tier="${1:-}"
prompt="${2:-}"
if [[ -z "$tier" || -z "$prompt" ]]; then
  echo 'usage: delegate.sh <tier> "<prompt>"  (context piped via stdin)' >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-to-ollama/metrics.jsonl}"
host="${OLLAMA_HOST:-http://localhost:11434}"
think="${DELEGATE_THINK:-false}"

log_metric() {
  [[ "${DELEGATE_TO_OLLAMA_NO_METRICS:-}" == "1" ]] && return 0
  local ts="$1" tier="$2" model="$3" pchars="$4" cchars="$5" ochars="$6" dur_ms="$7" status="$8"
  local total=$((pchars + cchars + ochars))
  local tokens_avoided=$((total / 4))
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  printf '{"ts":"%s","tier":"%s","model":"%s","prompt_chars":%d,"context_chars":%d,"output_chars":%d,"duration_ms":%d,"exit_status":%d,"estimated_tokens_avoided":%d}\n' \
    "$ts" "$tier" "$model" "$pchars" "$cchars" "$ochars" "$dur_ms" "$status" "$tokens_avoided" \
    >> "$metrics_file" 2>/dev/null || true
}

ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')

if ! model=$(bash "$pick" "$tier" 2>/dev/null); then
  end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  log_metric "$ts_start" "$tier" "(none)" "${#prompt}" 0 0 $((end_epoch_ms - start_epoch_ms)) 1
  echo "delegate: pick-model failed for tier '$tier'" >&2
  exit 1
fi

# Read stdin into a variable if anything is piped in.
context=""
if [[ ! -t 0 ]]; then
  context=$(cat)
fi

# Compose the input. Local models prefer the prompt last so the instruction is
# fresh in the attention window; we keep it simple and concatenate as
# "<context>\n\n<prompt>".
if [[ -n "$context" ]]; then
  full_input="${context}

${prompt}"
else
  full_input="$prompt"
fi

# Build the JSON payload via jq so prompts containing quotes / backslashes /
# newlines are escaped correctly. think:false suppresses chain-of-thought
# tokens for thinking-capable models — see DELEGATE_THINK above.
payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson th "$think" \
  '{model:$m, prompt:$p, stream:false, think:$th, options:{temperature:0}}')

response=$(printf '%s' "$payload" | curl -sS --fail -X POST "$host/api/generate" -d @-)
status=$?

if [[ "$status" -eq 0 ]]; then
  output=$(printf '%s' "$response" | jq -r '.response // ""')
else
  output=""
fi

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

log_metric "$ts_start" "$tier" "$model" "${#prompt}" "${#context}" "${#output}" "$duration_ms" "$status"

printf '%s\n' "$output"
exit $status
