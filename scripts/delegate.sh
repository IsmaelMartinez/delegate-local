#!/usr/bin/env bash
# Wrap `ollama run` with tier-based model selection, ANSI stripping, and
# per-invocation metrics. Use this instead of bare `ollama run` so every
# delegation is observable.
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
#
# Output:  cleaned model response on stdout (ANSI control codes stripped)
# Errors:  pick-model failures and ollama errors propagate the original exit
#          status. A metrics line is still appended with exit_status set.

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

# Resolve the tier to a model. If pick-model fails (no ollama, no match),
# log the failure and exit with the same status.
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

# Run ollama and strip spinner / cursor-control ANSI bytes from the output.
# The same sed pattern is documented in README "Capturing output non-interactively".
# stderr is *not* redirected — real errors (server down, missing model, OOM)
# need to reach the user. The spinner that needs cleaning lives on stdout.
output=$(printf '%s' "$full_input" | ollama run "$model" \
  | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' \
  | sed -E $'s/\x1b\\][^\a]*\a//g')
status=$?

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

log_metric "$ts_start" "$tier" "$model" "${#prompt}" "${#context}" "${#output}" "$duration_ms" "$status"

# Emit the cleaned output on stdout. Exit with whatever ollama reported.
printf '%s\n' "$output"
exit $status
