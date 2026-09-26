#!/usr/bin/env bash
# Embed text via whichever provider in the list serves an embedding model and
# print the vector to stdout as a JSON array of floats. Sibling to delegate.sh
# (same metrics JSONL, tier resolution and provider list) with a different
# call shape, POST {base}/embeddings, since delegate.sh assumes text-in /
# text-out.
#
# Usage:
#   echo "<text>" | embed.sh                  # text on stdin
#   embed.sh --text "<text>"                  # text via flag
#
# Env:
#   DELEGATE_BASE_URL=<urls>        the provider list (pick-model.sh owns the default)
#   DELEGATE_LOCAL_NO_METRICS=1     opt out of metrics logging (the old
#                                   DELEGATE_TO_OLLAMA_ name is accepted when unset)
#   DELEGATE_LOCAL_DATA_DIR         per-user data (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE=<path>    override the metrics destination
#   DELEGATE_EMBED_MAX_CHARS=<int>  default 6000; longer inputs are head-truncated
#                                   with a stderr warning. Dense markdown lands
#                                   near 2 chars/token, so the chars/4 estimate
#                                   over-shoots the 8192-token context. 0 disables
#                                   (the upstream 400 then surfaces only as curl exit 22)
#   DELEGATE_EMBED_TIMEOUT=<s>      default 60; embedding is fast and
#                                   semantic-search calls this once per chunk
#
# Output: one line, the compact JSON vector from .data[0].embedding.
# Errors: pick-model and HTTP failures exit non-zero with a metrics row still
#         written. No verdict nudge: embeddings are objective.

set -uo pipefail

# Backwards compat: old env var name (rename delegate-to-ollama → delegate-local).
DELEGATE_LOCAL_NO_METRICS="${DELEGATE_LOCAL_NO_METRICS:-${DELEGATE_TO_OLLAMA_NO_METRICS:-}}"

usage() {
  echo 'usage: embed.sh [--text "<text>"]' >&2
  echo '       (text comes from stdin if --text is omitted)' >&2
}

input_text=""
have_text_flag=0
while (($# > 0)); do
  case "$1" in
    --text)
      if [[ $# -lt 2 ]]; then
        echo 'embed: --text requires a value' >&2; exit 2
      fi
      input_text="$2"; have_text_flag=1; shift 2;;
    --text=*)
      input_text="${1#--text=}"; have_text_flag=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "embed: unknown argument: $1" >&2; usage; exit 2;;
  esac
done

# Validated before stdin is read, so a bad value fails before a large read.
max_chars="${DELEGATE_EMBED_MAX_CHARS:-6000}"
if ! [[ "$max_chars" =~ ^[0-9]+$ ]]; then
  echo "embed: DELEGATE_EMBED_MAX_CHARS='$max_chars' is not a non-negative integer" >&2
  exit 2
fi

# The same -p / -s probe delegate.sh uses: `! -t 0` is true for a FIFO or
# socket holding no data, and `cat` then blocks forever. The read is capped
# at 4x max_chars bytes (the UTF-8 worst case) so the char truncation below
# has enough source without reading a huge stream whole.
if (( have_text_flag == 0 )); then
  if [[ -p /dev/stdin || -s /dev/stdin ]]; then
    if (( max_chars > 0 )); then
      input_text=$(head -c "$((max_chars * 4))")
    else
      input_text=$(cat)
    fi
  fi
fi

if [[ -z "$input_text" ]]; then
  echo 'embed: no input (pipe text on stdin or pass --text "...")' >&2
  exit 2
fi

# Head truncation, because the relevance signal (titles, headings) lives near
# the start; the upstream 400 would otherwise surface only as curl exit 22.
# Runs after the byte cap so the warning is sized in chars, not bytes.
if (( max_chars > 0 )) && (( ${#input_text} > max_chars )); then
  echo "embed: input is ${#input_text} chars, truncating to first $max_chars (raise DELEGATE_EMBED_MAX_CHARS to keep more)" >&2
  input_text="${input_text:0:$max_chars}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
# The placeholder label only reaches a metrics row for a failure before resolution.
backend="provider"
resolved_base=""

log_metric() {
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 0
  local ts="$1" tier="$2" model="$3" input_chars="$4" embedding_dim="$5" dur_ms="$6" status="$7"
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  # embedding_dim is the vector length, so an unexpected model swap shows.
  jq -nc \
    --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
    --argjson input_chars "$input_chars" --argjson embedding_dim "$embedding_dim" \
    --argjson dur_ms "$dur_ms" --argjson status "$status" \
    '{ts:$ts, source:"embed", backend:$backend, tier:$tier, model:$model, input_chars:$input_chars, embedding_dim:$embedding_dim, duration_ms:$dur_ms, exit_status:$status}' \
    >> "$metrics_file" 2>/dev/null || true
}

ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')

# Never hardcode the model name: the installed set drifts and the override
# hook can reorder the prefs. --print-resolution probes a dead provider once.
if ! _resolved=$(bash "$pick" --print-resolution embedding 2>/dev/null); then
  end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  fail_dur_ms=$((end_epoch_ms - start_epoch_ms))
  log_metric "$ts_start" "embedding" "(none)" "${#input_text}" 0 "$fail_dur_ms" 1
  echo "embed: pick-model failed for tier 'embedding' (is nomic-embed-text installed?)" >&2
  exit 1
fi
resolved_base="${_resolved%%	*}"
model="${_resolved#*	}"
# Same URL-derived label as delegate.sh, so both land in one per-provider series.
case "$resolved_base" in
  *:8080*)  backend="mlx" ;;
  *:12434*) backend="docker" ;;
  *:11434*) backend="ollama" ;;
  *) backend=$(printf '%s' "$resolved_base" | sed -E 's|^[a-z]+://||; s|/.*$||') ;;
esac

# jq builds the body so quotes, backslashes and newlines escape correctly;
# one text per call.
payload=$(jq -nc --arg m "$model" --arg t "$input_text" \
  '{model:$m, input:$t}')

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
curl -sS --fail --max-time "${DELEGATE_EMBED_TIMEOUT:-60}" --connect-timeout 5 \
  -X POST "$resolved_base/embeddings" -H 'Content-Type: application/json' --data-binary @- \
  -o "$body_file" <<< "$payload"
status=$?

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

if (( status != 0 )); then
  log_metric "$ts_start" "embedding" "$model" "${#input_text}" 0 "$duration_ms" "$status"
  echo "embed: curl POST $resolved_base/embeddings failed with exit $status" >&2
  exit "$status"
fi

# Vectors stored by the old Ollama /api/embed path stay valid: both endpoints
# return the same floats and unit norm. `select(. != null)` leaves the
# variables empty on a missing key so the guard below fires.
read -r vector embedding_dim < <(jq -r '.data[0].embedding | select(. != null) | [(@json), length] | @tsv' < "$body_file")
if [[ -z "$vector" || "$vector" == "null" ]]; then
  log_metric "$ts_start" "embedding" "$model" "${#input_text}" 0 "$duration_ms" 1
  echo "embed: response did not contain .data[0].embedding (model '$model' may not be an embedding model)" >&2
  exit 1
fi

log_metric "$ts_start" "embedding" "$model" "${#input_text}" "$embedding_dim" "$duration_ms" 0

printf '%s\n' "$vector"
exit 0
