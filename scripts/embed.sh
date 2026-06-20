#!/usr/bin/env bash
# Embed text via a local Ollama model and print the embedding vector to
# stdout as a JSON array of floats. Sibling to delegate.sh: same metrics
# JSONL, same tier resolution via pick-model.sh, but a different call
# shape (POST /api/embed, vector output) because delegate.sh assumes
# text-in / text-out and special-casing it for embeddings would force
# several branches off a shared spine. See ROADMAP "Capability expansion
# — modality tiers" / P1 for rationale.
#
# Usage:
#   echo "<text>" | embed.sh                  # text on stdin
#   embed.sh --text "<text>"                  # text via flag
#
# Env:
#   DELEGATE_BACKEND=auto|ollama          # default ollama. MLX out of scope
#                                         #   for v1 — the wrapper exits 2
#                                         #   with a message saying MLX
#                                         #   embedding isn't wired up yet.
#                                         #   `auto` falls through to ollama
#                                         #   (the MLX probe isn't run; this
#                                         #   keeps the script independent
#                                         #   of MLX_HOST being set).
#   OLLAMA_HOST=<url>                     # default http://localhost:11434
#   DELEGATE_LOCAL_NO_METRICS=1            # opt out of metrics logging
#                                         #   (back-compat: DELEGATE_TO_OLLAMA_NO_METRICS
#                                         #   is accepted if the new name is unset)
#   DELEGATE_METRICS_FILE=<path>          # override metrics destination
#   DELEGATE_EMBED_MAX_CHARS=<int>        # default 6000. Inputs longer than
#                                         #   this are head-truncated with a
#                                         #   one-line stderr warning before
#                                         #   posting. Empirical safe ceiling
#                                         #   on nomic-embed-text (8192 token
#                                         #   context); dense markdown lands
#                                         #   near 2 chars/token so the chars
#                                         #   /4 estimate over-shoots —
#                                         #   measured limit on this repo's
#                                         #   prompts/*.md was ~7000 chars,
#                                         #   6000 leaves slack for tokenizer
#                                         #   drift. Raise for prose-heavy
#                                         #   inputs, lower for code/log
#                                         #   inputs. Set 0 to disable
#                                         #   truncation entirely (long
#                                         #   inputs will hit the upstream
#                                         #   400 error which curl --fail
#                                         #   surfaces only as exit 22).
#
# Output: a single line on stdout — compact JSON array of floats from
#         .embeddings[0]. nomic-embed-text returns a 768-dim vector.
# Errors: pick-model and HTTP failures exit non-zero; a metrics row is
#         still written with exit_status set so audit-metrics can pivot
#         on it. No verdict-nudge — embeddings are objective so the
#         hit/miss surface doesn't apply.

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

# Validate the char-budget env var before reading stdin so a malformed
# DELEGATE_EMBED_MAX_CHARS fails fast rather than after pulling potentially
# large content into memory. The validation also drives the read-side
# byte cap below.
max_chars="${DELEGATE_EMBED_MAX_CHARS:-6000}"
if ! [[ "$max_chars" =~ ^[0-9]+$ ]]; then
  echo "embed: DELEGATE_EMBED_MAX_CHARS='$max_chars' is not a non-negative integer" >&2
  exit 2
fi

# Stdin takes precedence only when --text was not passed. Same -p / -s probe
# delegate.sh uses to avoid the `! -t 0` foot-gun (FIFOs and unix sockets
# that hold no data report as "stdin" to -t 0 and block cat forever). When
# the budget is set, cap the read at 4× max_chars bytes — a multi-byte UTF-8
# safety factor (worst case 4 bytes/char in UTF-8) so the post-read
# defensive truncation below has enough source bytes to land on a valid
# char-budget boundary without reading the entire stream when stdin is huge.
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

# Defensive char-budget truncation against the embedding model's context
# window. nomic-embed-text caps at 8192 tokens (~32k chars at the chars/4
# estimate); the default budget of 6000 chars leaves slack for token-vs-
# char drift on dense code/log input. The upstream HTTP 400 ("input length
# exceeds the context length") is curl --fail's silent path — the body
# never reaches stdout, so callers get a much less actionable failure than
# a head-truncated input would. The truncation point is the head of the
# file because the relevant query-doc relevance signal usually lives near
# the start (titles, headings) — taking the tail would discard the most
# discriminating tokens. Runs after the read-side byte cap so the warning
# is sized against the user-visible char count, not the byte budget.
if (( max_chars > 0 )) && (( ${#input_text} > max_chars )); then
  echo "embed: input is ${#input_text} chars, truncating to first $max_chars (raise DELEGATE_EMBED_MAX_CHARS to keep more)" >&2
  input_text="${input_text:0:$max_chars}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
backend_requested="${DELEGATE_BACKEND:-ollama}"
case "$backend_requested" in
  ollama|auto)
    # auto falls through to ollama because the MLX probe assumes an
    # mlx_lm.server running on port 8080, which is not required for
    # embedding work today. v1 keeps the surface minimal.
    backend="ollama"
    ;;
  mlx)
    echo "embed: DELEGATE_BACKEND=mlx is not wired up yet (Ollama only in v1)" >&2
    exit 2
    ;;
  *)
    echo "embed: unknown DELEGATE_BACKEND='$backend_requested' (valid: auto|ollama)" >&2
    exit 2
    ;;
esac
ollama_host="${OLLAMA_HOST:-http://localhost:11434}"

log_metric() {
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 0
  local ts="$1" tier="$2" model="$3" input_chars="$4" embedding_dim="$5" dur_ms="$6" status="$7"
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  # source:"embed" discriminates this row from delegate.sh (source:"delegate")
  # and experiment-runner traffic (source:"experiment") that write to the
  # same file. embedding_dim is the vector length so audit-metrics can spot
  # an unexpected model swap (768 → 1024 is a wire-shape change).
  jq -nc \
    --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
    --argjson input_chars "$input_chars" --argjson embedding_dim "$embedding_dim" \
    --argjson dur_ms "$dur_ms" --argjson status "$status" \
    '{ts:$ts, source:"embed", backend:$backend, tier:$tier, model:$model, input_chars:$input_chars, embedding_dim:$embedding_dim, duration_ms:$dur_ms, exit_status:$status}' \
    >> "$metrics_file" 2>/dev/null || true
}

ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')

# Force the embedding-tier resolution via pick-model.sh — never hardcode the
# model name (the installed-model set drifts and the override hook can
# reorder the prefs).
if ! model=$(DELEGATE_BACKEND=ollama bash "$pick" embedding 2>/dev/null); then
  end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  fail_dur_ms=$((end_epoch_ms - start_epoch_ms))
  log_metric "$ts_start" "embedding" "(none)" "${#input_text}" 0 "$fail_dur_ms" 1
  echo "embed: pick-model failed for tier 'embedding' (is nomic-embed-text installed?)" >&2
  exit 1
fi

# Build the POST body via jq so quotes, backslashes, and newlines in
# input_text escape correctly. Ollama's /api/embed accepts either `input:
# "<string>"` for a single text or `input: ["a", "b"]` for a batch; v1
# embeds one text per call.
payload=$(jq -nc --arg m "$model" --arg t "$input_text" \
  '{model:$m, input:$t}')

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
curl -sS --fail -X POST "$ollama_host/api/embed" -d @- \
  -o "$body_file" <<< "$payload"
status=$?

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

if (( status != 0 )); then
  log_metric "$ts_start" "embedding" "$model" "${#input_text}" 0 "$duration_ms" "$status"
  echo "embed: curl POST $ollama_host/api/embed failed with exit $status" >&2
  exit "$status"
fi

# Parse the response: .embeddings is an array of vectors (one per input);
# v1 only sends one input so we take .embeddings[0]. One jq call emits
# both the compact JSON vector and its length as a tab-separated row, so
# the parse + dimensionality lookup share a single jq process instead of
# the two-pass shape an earlier iteration used. `select(. != null)`
# filters out the missing-key case so `read` sees an empty stream and
# the variables stay empty for the post-read guard. `@json` re-emits the
# vector as a compact JSON literal — same shape downstream jq arithmetic
# expects.
read -r vector embedding_dim < <(jq -r '.embeddings[0] | select(. != null) | [(@json), length] | @tsv' < "$body_file")
if [[ -z "$vector" || "$vector" == "null" ]]; then
  log_metric "$ts_start" "embedding" "$model" "${#input_text}" 0 "$duration_ms" 1
  echo "embed: response did not contain .embeddings[0] (model '$model' may not be an embedding model)" >&2
  exit 1
fi

log_metric "$ts_start" "embedding" "$model" "${#input_text}" "$embedding_dim" "$duration_ms" 0

printf '%s\n' "$vector"
exit 0
