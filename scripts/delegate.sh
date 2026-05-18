#!/usr/bin/env bash
# Wrap a local-LLM HTTP endpoint (Ollama by default, MLX optional) with
# tier-based model selection and per-invocation metrics. Use this instead of
# bare `ollama run` so every delegation is observable and the response is
# parser-clean (no CLI cursor rewrites or spinner ANSI mixed into stdout).
#
# Usage:
#   delegate.sh <tier> "<prompt>"                            # context comes from stdin
#   echo "..." | delegate.sh prose "..."                     # explicit pipe
#   delegate.sh --recipe NAME [--var k=v ...] <tier> ["<prompt>"]
#                                                            # prepend prompts/NAME.md
#                                                            # template with {{k}} subs
#
# Tiers: code | prose | reasoning | long-context (see scripts/pick-model.sh)
#
# Recipe flag (layer 2 of the training-loop initiative):
#   --recipe NAME            load prompts/<NAME>.md, extract its '## Prompt
#                            template' fenced block, prepend it to the input.
#   --var key=value          substitute {{key}} placeholders inside the
#                            recipe template. Repeat for multiple variables.
#                            Values may contain newlines and special chars.
#                            A {{stdin}} placeholder is auto-substituted with
#                            stdin content when stdin is piped in.
#   The trailing positional <tier> stays required; <prompt> becomes optional
#   when --recipe is set (the recipe carries the instruction).
#
# Env:
#   DELEGATE_BACKEND=auto|ollama|mlx        # default auto. auto probes
#                                           #   ${MLX_HOST:-http://localhost:8080}/v1/models
#                                           #   with a 1 s timeout and picks
#                                           #   mlx if reachable, otherwise
#                                           #   ollama. Explicit ollama or
#                                           #   mlx skips the probe. The
#                                           #   metrics line always logs the
#                                           #   resolved backend, never "auto".
#   DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT=<s> # override the auto probe timeout
#                                           #   (default 1, integer seconds).
#   DELEGATE_TO_OLLAMA_NO_METRICS=1         # opt out of metrics logging
#   DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1   # silence the one-line stderr
#                                           #   reminder printed after each
#                                           #   successful call pointing at
#                                           #   delegate-feedback.sh. Off-by-
#                                           #   default; the nudge is the
#                                           #   intervention that closes the
#                                           #   untracked-verdict gap (see the
#                                           #   2026-05-18 calibration finding
#                                           #   in ROADMAP).
#   DELEGATE_METRICS_FILE=<path>            # override metrics destination
#   DELEGATE_PROMPTS_DIR=<path>             # override prompts/ directory
#                                           #   (default: <script_dir>/../prompts)
#   DELEGATE_THINK=true|false               # default false; set true if the
#                                           #   model's chain-of-thought
#                                           #   genuinely helps for the task.
#                                           #   Maps to Ollama's `think` field
#                                           #   and to MLX's
#                                           #   `chat_template_kwargs.enable_thinking`.
#   OLLAMA_HOST=<url>                       # default http://localhost:11434
#   MLX_HOST=<url>                          # default http://localhost:8080
#   DELEGATE_MAX_TOKENS=<int>               # default 4096. MLX-only — the
#                                           #   OpenAI completions shape
#                                           #   requires max_tokens. Raise
#                                           #   for long-context tier or
#                                           #   verbose models.
#
# Output:  model response on stdout (no ANSI; HTTP body is plain text)
# Errors:  pick-model failures and HTTP errors propagate as non-zero exit.
#          A metrics line is still appended with exit_status set.

set -uo pipefail

usage() {
  echo 'usage: delegate.sh [--recipe NAME [--var key=value ...]] <tier> ["<prompt>"]' >&2
  echo '       (context piped via stdin; prompt optional when --recipe is set)' >&2
}

recipe=""
recipe_vars=()
positional=()
while (($# > 0)); do
  case "$1" in
    --recipe)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate: --recipe requires a value' >&2; exit 2
      fi
      recipe="$2"; shift 2;;
    --recipe=*)
      recipe="${1#--recipe=}"; shift;;
    --var)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate: --var requires key=value' >&2; exit 2
      fi
      recipe_vars+=("$2"); shift 2;;
    --var=*)
      recipe_vars+=("${1#--var=}"); shift;;
    --)
      shift
      while (($# > 0)); do positional+=("$1"); shift; done
      ;;
    -h|--help)
      usage; exit 0;;
    *)
      positional+=("$1"); shift;;
  esac
done

tier="${positional[0]:-}"
prompt="${positional[1]:-}"
if [[ -z "$tier" ]] || { [[ -z "$prompt" ]] && [[ -z "$recipe" ]]; }; then
  usage; exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"
prompts_dir="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-to-ollama/metrics.jsonl}"
# Resolve auto backend by probing the MLX server. Cheap (sub-second
# timeout, single GET) and runs once per invocation. Explicit ollama|mlx
# skip the probe. The metrics line records the resolved backend, never
# "auto" — so downstream consumers (metrics-summary, audit-metrics) keep
# seeing the same shape they did before the auto default.
backend_requested="${DELEGATE_BACKEND:-auto}"
case "$backend_requested" in
  auto)
    mlx_host_probe="${MLX_HOST:-http://localhost:8080}"
    probe_timeout="${DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT:-1}"
    if curl -sS --max-time "$probe_timeout" --fail "$mlx_host_probe/v1/models" >/dev/null 2>&1; then
      backend="mlx"
    else
      backend="ollama"
    fi
    ;;
  ollama|mlx) backend="$backend_requested" ;;
  *) echo "delegate: unknown DELEGATE_BACKEND='$backend_requested' (valid: auto|ollama|mlx)" >&2; exit 2 ;;
esac
ollama_host="${OLLAMA_HOST:-http://localhost:11434}"
mlx_host="${MLX_HOST:-http://localhost:8080}"

# Normalise DELEGATE_THINK to a strict JSON boolean ("true"/"false") before
# it reaches jq --argjson, so a stray value like "yes" / "True" / " true "
# doesn't cause a jq parse error that kills the whole delegation.
if [[ "${DELEGATE_THINK:-false}" == "true" ]]; then
  think="true"
else
  think="false"
fi

log_metric() {
  [[ "${DELEGATE_TO_OLLAMA_NO_METRICS:-}" == "1" ]] && return 0
  local ts="$1" tier="$2" model="$3" pchars="$4" cchars="$5" ochars="$6" dur_ms="$7" status="$8" recipe_name="${9:-}"
  local total=$((pchars + cchars + ochars))
  local tokens_avoided=$((total / 4))
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  # source:"delegate" discriminates this from experiment-runner traffic that
  # writes to the same file via experiments/lib/run_api_cell.sh. backend
  # discriminates ollama vs mlx traffic — pre-2026-05 rows lack the field and
  # metrics-summary.sh treats their absence as backend=ollama for back-compat.
  # jq builds the line so any quote, backslash, or newline in $model or
  # $recipe_name (recipe names are filename-safe today but model names come
  # from `ollama list` parsing and are not under our control) escapes
  # correctly rather than producing invalid JSON.
  if [[ -n "$recipe_name" ]]; then
    jq -nc \
      --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" \
      --arg model "$model" --arg recipe "$recipe_name" \
      --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
      --argjson dur_ms "$dur_ms" --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
      '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, recipe:$recipe, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}' \
      >> "$metrics_file" 2>/dev/null || true
  else
    jq -nc \
      --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
      --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
      --argjson dur_ms "$dur_ms" --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
      '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}' \
      >> "$metrics_file" 2>/dev/null || true
  fi
}

ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')

# Read stdin into a variable if anything is piped in (needed early so {{stdin}}
# substitution can run before the model resolution, and so the recipe-driven
# error paths still surface with a clean metric line).
context=""
if [[ ! -t 0 ]]; then
  context=$(cat)
fi

# Resolve recipe template (if any) and substitute {{key}} placeholders.
recipe_template=""
recipe_had_stdin_marker=0
if [[ -n "$recipe" ]]; then
  recipe_file="$prompts_dir/${recipe}.md"
  if [[ ! -f "$recipe_file" ]]; then
    echo "delegate: recipe '$recipe' not found at $recipe_file" >&2
    exit 2
  fi
  # Extract the first ``` fenced code block under the '## Prompt template'
  # heading. awk-based — bash 3 / BSD awk safe. The section-end check
  # `/^## /` is gated on `!in_block` so a markdown heading inside the
  # fenced block (legitimate prompt content) doesn't prematurely close the
  # section before the closing ``` is reached.
  recipe_template=$(awk '
    /^## Prompt template[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section && !in_block { in_section=0 }
    in_section && /^```/ {
      if (in_block) { exit }
      in_block=1; next
    }
    in_section && in_block { print }
  ' "$recipe_file")
  if [[ -z "$recipe_template" ]]; then
    echo "delegate: recipe '$recipe' has empty or missing '## Prompt template' fenced block" >&2
    exit 2
  fi

  # Identify the placeholders the *original* template requires. Validating
  # against this list — not the post-substitution string — means substituted
  # values that legitimately contain `{{...}}` (Vue/Angular bindings, Go
  # templates, logs with curly braces) don't trigger a false positive.
  required_placeholders=$(printf '%s' "$recipe_template" | grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' | sort -u)

  # Substitute --var key=value pairs into {{key}} placeholders. Bash
  # parameter substitution handles the literal {{ }} braces fine since they
  # are not glob metacharacters; values may contain newlines and arbitrary
  # punctuation because they came in via argv (no shell re-evaluation).
  satisfied_keys=""
  for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
    if [[ "$kv" != *"="* ]]; then
      echo "delegate: --var must be key=value, got '$kv'" >&2
      exit 2
    fi
    key="${kv%%=*}"
    value="${kv#*=}"
    if [[ -z "$key" ]]; then
      echo "delegate: --var has empty key in '$kv'" >&2
      exit 2
    fi
    recipe_template="${recipe_template//\{\{$key\}\}/$value}"
    satisfied_keys="${satisfied_keys}{{${key}}}"$'\n'
  done

  # {{stdin}} is the implicit placeholder for the piped context.
  if printf '%s' "$required_placeholders" | grep -qx '{{stdin}}'; then
    recipe_had_stdin_marker=1
    recipe_template="${recipe_template//\{\{stdin\}\}/$context}"
    satisfied_keys="${satisfied_keys}{{stdin}}"$'\n'
  fi

  # Refuse to invoke the model with required placeholders the caller didn't
  # supply — the partly-substituted template almost certainly isn't what
  # they meant. Compare against the original-template placeholder set, not
  # the post-substitution string, so legit `{{...}}` content survives.
  missing=""
  while IFS= read -r ph; do
    [[ -z "$ph" ]] && continue
    if ! printf '%s' "$satisfied_keys" | grep -Fxq "$ph"; then
      missing="${missing}${ph} "
    fi
  done <<< "$required_placeholders"
  if [[ -n "${missing// /}" ]]; then
    echo "delegate: recipe '$recipe' has unsubstituted placeholders: $missing" >&2
    echo "         pass them via --var key=value (or {{stdin}} via piped context)" >&2
    exit 2
  fi
fi

if ! model=$(bash "$pick" "$tier" 2>/dev/null); then
  end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  log_metric "$ts_start" "$tier" "(none)" "$(( ${#recipe_template} + ${#prompt} ))" "${#context}" 0 $((end_epoch_ms - start_epoch_ms)) 1 "$recipe"
  echo "delegate: pick-model failed for tier '$tier'" >&2
  exit 1
fi

# Compose the input. The recipe template (if any) carries its own
# instruction structure, so it goes first; piped context follows unless it
# was already absorbed via the {{stdin}} marker; the user's prompt arg is
# the trailing instruction (often a one-line "match the example shape and
# tone." reinforcement). The leading-instruction-vs-prompt-last debate is
# settled empirically by the recipe authors — placeholder content lands
# inside the template, the prompt arg lands after.
parts=()
if [[ -n "$recipe_template" ]]; then
  parts+=("$recipe_template")
  if [[ -n "$context" ]] && (( recipe_had_stdin_marker == 0 )); then
    parts+=("$context")
  fi
  if [[ -n "$prompt" ]]; then
    parts+=("$prompt")
  fi
else
  if [[ -n "$context" ]]; then
    parts+=("$context")
  fi
  parts+=("$prompt")
fi

# Join with a blank line between parts.
full_input=""
for p in "${parts[@]}"; do
  if [[ -z "$full_input" ]]; then
    full_input="$p"
  else
    full_input="${full_input}

${p}"
  fi
done

# Build the JSON payload via jq so prompts containing quotes / backslashes /
# newlines are escaped correctly. Each backend has its own request and
# response envelope — Ollama's /api/generate returns .response, MLX's
# OpenAI-compatible /v1/chat/completions returns .choices[0].message.content.
if [[ "$backend" == "ollama" ]]; then
  # think:false suppresses chain-of-thought for thinking-capable models —
  # see DELEGATE_THINK above.
  payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson th "$think" \
    '{model:$m, prompt:$p, stream:false, think:$th, options:{temperature:0}}')
  response=$(curl -sS --fail -X POST "$ollama_host/api/generate" -d @- <<< "$payload")
  status=$?
  if [[ "$status" -eq 0 ]]; then
    output=$(jq -r '.response // ""' <<< "$response")
  else
    output=""
  fi
else
  # MLX server (mlx_lm.server) speaks the OpenAI chat-completions shape.
  # /v1/completions is the raw-prompt endpoint — it bypasses the model's
  # chat template, so instruction-tuned models emit whitespace until
  # max_tokens. /v1/chat/completions wraps the input via apply_chat_template
  # and produces real instruction-following output. The response carries
  # .choices[0].message.content (and .choices[0].message.reasoning when
  # thinking is on — we mirror Ollama's think:false default by passing
  # chat_template_kwargs.enable_thinking=false so the content field carries
  # the answer rather than the reasoning trace.
  max_tokens="${DELEGATE_MAX_TOKENS:-4096}"
  # $think is already the normalised "true"/"false" string from lines
  # 111-115; enable_thinking maps to it directly (think:true -> reasoning
  # on, same semantic as Ollama's think field, just expressed through the
  # chat-template kwarg).
  payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson mt "$max_tokens" --argjson et "$think" \
    '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:0, max_tokens:$mt, chat_template_kwargs:{enable_thinking:$et}}')
  response=$(curl -sS --fail -X POST "$mlx_host/v1/chat/completions" -d @- <<< "$payload")
  status=$?
  if [[ "$status" -eq 0 ]]; then
    output=$(jq -r '.choices[0].message.content // ""' <<< "$response")
  else
    output=""
  fi
fi

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

log_metric "$ts_start" "$tier" "$model" "$(( ${#recipe_template} + ${#prompt} ))" "${#context}" "${#output}" "$duration_ms" "$status" "$recipe"

# Verdict nudge — without it the metrics file accumulates "untracked" rows
# (delegate row with no matching feedback row) and the recipe library can't
# self-correct from production data. Conditions: only after a successful call
# (status==0), only when a metrics row was actually written (NO_METRICS off),
# and silenceable via NO_VERDICT_NUDGE for callers who want clean stderr.
if [[ "${DELEGATE_TO_OLLAMA_NO_METRICS:-}" != "1" ]] \
   && [[ "${DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE:-}" != "1" ]] \
   && (( status == 0 )); then
  echo "delegate: record verdict → bash scripts/delegate-feedback.sh hit  (or 'miss \"<reason>\"')" >&2
fi

printf '%s\n' "$output"
exit $status
