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
#   Optional frontmatter `inputs:` block (Phase 12 Track B, issue #161) lets
#   a recipe declare flat `key: type` pairs that get validated pre-flight.
#   Supported types: integer, string, integer?, string? (the `?` suffix means
#   optional). Recipes without a frontmatter inputs: block skip the check
#   (lazy migration). Undeclared --var keys pass through untouched (strict
#   mode deferred). Type-check failure or a missing required input exits 2
#   with a clear error before the model is contacted.
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
#   DELEGATE_LOCAL_NO_METRICS=1              # opt out of metrics logging
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_NO_METRICS
#                                           #   is accepted if the new name is unset)
#   DELEGATE_LOCAL_NO_VERDICT_NUDGE=1        # silence the one-line stderr
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE
#                                           #   is accepted if the new name is unset)
#                                           #   reminder printed after each
#                                           #   successful call pointing at
#                                           #   delegate-feedback.sh. Off-by-
#                                           #   default; the nudge fires
#                                           #   unconditionally on success
#                                           #   when metrics are on,
#                                           #   regardless of stdin/stdout
#                                           #   shape (Agent SDK tool calls,
#                                           #   CI scripts, and other non-
#                                           #   TTY callers are the highest-
#                                           #   volume users and their
#                                           #   verdicts are what closes the
#                                           #   training-loop gap — see
#                                           #   issue #149). Three escape
#                                           #   hatches: this env var (opt
#                                           #   out per call), NO_METRICS
#                                           #   (no row to verdict against),
#                                           #   non-zero exit (failure has
#                                           #   no output to judge).
#   DELEGATE_LOCAL_VERDICT_NUDGE_FD=<N>      # redirect the verdict-nudge line
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_VERDICT_NUDGE_FD
#                                           #   is accepted if the new name is unset)
#                                           #   to file descriptor N instead
#                                           #   of fd 2 (stderr). Default
#                                           #   unset → fd 2, preserving the
#                                           #   unconditional-fire behaviour
#                                           #   the #149 reversal pinned. The
#                                           #   escape hatch for parallel-
#                                           #   capture callers (issue #139)
#                                           #   that want clean stdout AND
#                                           #   coverage tracking: redirect
#                                           #   stdout+stderr together into a
#                                           #   single output file and route
#                                           #   the nudge to a separate fd,
#                                           #   e.g.
#                                           #     DELEGATE_LOCAL_VERDICT_NUDGE_FD=3 \
#                                           #     bash delegate.sh prose "X" \
#                                           #     > out.txt 2>&1 3>>nudge.log
#                                           #   GOTCHA: the caller must
#                                           #   redirect fd N to somewhere
#                                           #   (file, pipe, or another fd).
#                                           #   If fd N is closed when the
#                                           #   nudge fires, the write fails
#                                           #   silently — the call still
#                                           #   succeeds but no nudge lands
#                                           #   anywhere. Suppression rules
#                                           #   still apply: NO_VERDICT_NUDGE
#                                           #   wins (no nudge written),
#                                           #   NO_METRICS wins (no row to
#                                           #   verdict), non-zero exit wins
#                                           #   (no output to judge). Valid
#                                           #   values: single-digit positive
#                                           #   integer 1-9. Multi-digit FDs
#                                           #   are rejected because bash 3.2
#                                           #   (the project's portability
#                                           #   floor) does not support the
#                                           #   `{var}>file` form for high
#                                           #   FDs and `>&$N` with N>=10
#                                           #   can silently fail; tightening
#                                           #   validation makes the failure
#                                           #   mode loud. 0 (stdin), negative
#                                           #   numbers, and non-numeric
#                                           #   values exit 2 with a clear
#                                           #   error before the model is
#                                           #   contacted. 1 (stdout) and 2
#                                           #   (stderr / the default) are
#                                           #   both accepted.
#   DELEGATE_PREFLIGHT_TIMEOUT=<s>          # default 10. Only consulted when
#                                           #   --recipe is set. A 1-token
#                                           #   canary probe hits the resolved
#                                           #   model with --max-time S; if
#                                           #   the probe does not return,
#                                           #   exit 3 with a stderr message
#                                           #   listing recovery options
#                                           #   (raise timeout, smaller model,
#                                           #   hand-write) before the full
#                                           #   recipe-shaped request is sent.
#                                           #   Set 0 to disable the canary.
#                                           #   Closes the recipe-stall gap
#                                           #   in issue #110.
#   DELEGATE_NO_PREFLIGHT=1                 # alternate disable for the canary
#                                           #   (equivalent to TIMEOUT=0).
#   DELEGATE_FORCE_FLAKY=1                  # override the recipe-level flaky-
#                                           #   on-model gate (Phase 16 Track
#                                           #   A). When a recipe declares
#                                           #   `flaky_on_models:` in its
#                                           #   frontmatter and the resolved
#                                           #   model matches any listed
#                                           #   substring (case-insensitive),
#                                           #   delegate.sh exits 4 with a
#                                           #   stderr message naming the
#                                           #   recipe's documented mitigation
#                                           #   (typically hand-writing). Set
#                                           #   this env var to send the
#                                           #   request anyway — useful for
#                                           #   capturing fresh evidence the
#                                           #   flaky-class behaviour has
#                                           #   changed across model upgrades.
#   DELEGATE_LOCAL_NO_META=1                 # silence the structured
#                                           #   (back-compat: DELEGATE_TO_OLLAMA_NO_META
#                                           #   is accepted if the new name is unset)
#                                           #   `delegate-meta:` summary line
#                                           #   printed to stderr after each
#                                           #   successful call. SKILL.md
#                                           #   teaches the assistant to read
#                                           #   that line and surface the
#                                           #   model + tokens_local count to
#                                           #   the user, so the line is the
#                                           #   contract surface for "this is
#                                           #   how much we kept local." Off-
#                                           #   by-default; opt out for clean
#                                           #   stderr in batch runs.
#   DELEGATE_METRICS_FILE=<path>            # override metrics destination
#   DELEGATE_PROMPTS_DIR=<path>             # override prompts/ directory
#                                           #   (default: <script_dir>/../prompts)
#   DELEGATE_THINK=true|false               # default false; set true if the
#                                           #   model's chain-of-thought
#                                           #   genuinely helps for the task.
#                                           #   Maps to Ollama's `think` field
#                                           #   and to MLX's
#                                           #   `chat_template_kwargs.enable_thinking`.
#   DELEGATE_STRIP_THINK=1|0                # Strip a leading <think>...</think>
#                                           #   reasoning trace from the response
#                                           #   (drop everything up to and
#                                           #   including the first </think>,
#                                           #   trim leading whitespace) so
#                                           #   structured-output recipes still
#                                           #   parse when a trace-emitting model
#                                           #   leaks the trace into the answer
#                                           #   under think:false. ON by default
#                                           #   for the reasoning tier (which
#                                           #   routes trace-emitting models);
#                                           #   =1 forces it on for any tier; =0
#                                           #   force-disables it even on the
#                                           #   reasoning tier, for a reasoning
#                                           #   recipe whose own output may
#                                           #   contain </think>.
#   OLLAMA_HOST=<url>                       # default http://localhost:11434
#   MLX_HOST=<url>                          # default http://localhost:8080
#   DELEGATE_MAX_TOKENS=<int>               # default 4096. MLX-only — the
#                                           #   OpenAI completions shape
#                                           #   requires max_tokens. Raise
#                                           #   for long-context tier or
#                                           #   verbose models.
#   DELEGATE_TEMPERATURE=<float>            # override sampler temperature.
#                                           #   Default for all models is 0
#                                           #   (greedy). Set to opt INTO
#                                           #   non-greedy sampling per-call;
#                                           #   the Alibaba-recommended Qwen
#                                           #   instruct profile is
#                                           #   DELEGATE_TEMPERATURE=0.7
#                                           #   DELEGATE_TOP_P=0.8
#                                           #   DELEGATE_TOP_K=20
#                                           #   DELEGATE_PRESENCE_PENALTY=1.3.
#                                           #   Non-numeric value exits 2.
#   DELEGATE_TOP_P=<float>                  # override top_p. Default unset (no
#                                           #   top_p key sent in payload).
#                                           #   Non-numeric exits 2.
#   DELEGATE_TOP_K=<int>                    # override top_k. Default unset.
#                                           #   Non-numeric exits 2.
#   DELEGATE_PRESENCE_PENALTY=<float>       # override presence_penalty.
#                                           #   Default unset. Non-numeric
#                                           #   exits 2.
#   DELEGATE_OTEL_ENDPOINT=<url>            # Phase 11 Track A (#134). When
#                                           #   set, POST one OTLP/HTTP span
#                                           #   per invocation to this URL
#                                           #   (e.g. https://otlp.example
#                                           #   /v1/traces) after the metrics
#                                           #   row is written. Off when
#                                           #   unset — zero overhead. The
#                                           #   POST is SYNCHRONOUS: a hung
#                                           #   collector adds up to
#                                           #   DELEGATE_OTEL_TIMEOUT seconds
#                                           #   of user-visible latency per
#                                           #   call. If delegations feel
#                                           #   sluggish, set DELEGATE_OTEL
#                                           #   _VERBOSE=1 to see export
#                                           #   failures or unset the
#                                           #   endpoint to disable.
#   DELEGATE_OTEL_TIMEOUT=<s>               # default 5. curl --max-time on
#                                           #   the OTLP POST so a hung
#                                           #   collector cannot block the
#                                           #   caller's pipeline.
#   DELEGATE_OTEL_VERBOSE=1                 # log exporter failures to stderr.
#                                           #   Default silent — a misconfigured
#                                           #   endpoint must not spam the
#                                           #   caller's tool output. Use this
#                                           #   to diagnose suspected exporter
#                                           #   failures (timeouts, auth, DNS).
#   DELEGATE_OTEL_HEADERS=<H: v,H: v>       # optional. Comma-separated
#                                           #   Header: value pairs (matches
#                                           #   OpenTelemetry SDK convention).
#                                           #   Used for collector auth on
#                                           #   Grafana Cloud, Langfuse, etc.
#                                           #   Per OTel SDK convention, header
#                                           #   values containing commas (or
#                                           #   any reserved char) MUST be
#                                           #   url-encoded — the script
#                                           #   url-decodes each value before
#                                           #   emitting -H flags so the on-
#                                           #   wire header is the literal
#                                           #   original (e.g. `a%2Cb` →
#                                           #   `a,b`).
#   DELEGATE_OTEL_INCLUDE_CONTENT=1         # Phase 11 Track F (#158). When =1,
#                                           #   include prompt / context /
#                                           #   output content in the OTel span
#                                           #   as attribute values
#                                           #   (delegate.prompt,
#                                           #   delegate.context,
#                                           #   delegate.output). Default unset
#                                           #   = redact those fields entirely
#                                           #   — only metadata (tier, model,
#                                           #   recipe, char counts, durations)
#                                           #   leaves the host. WARNING:
#                                           #   content fields may carry PII,
#                                           #   API keys, or internal URLs;
#                                           #   only enable this against
#                                           #   trusted collectors (a local
#                                           #   Phoenix instance, a vetted
#                                           #   private OTel backend, etc.).
#                                           #   See ADR 0007 + docs/otel-
#                                           #   schema.md for the field-by-
#                                           #   field split.
#
# Output:  model response on stdout (no ANSI; HTTP body is plain text)
# Errors:  pick-model failures and HTTP errors propagate as non-zero exit.
#          A metrics line is still appended with exit_status set. OTLP-export
#          failures NEVER change exit status — telemetry is non-fatal.

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

# Backwards compat: old env var names (rename delegate-to-ollama → delegate-local).
DELEGATE_LOCAL_NO_METRICS="${DELEGATE_LOCAL_NO_METRICS:-${DELEGATE_TO_OLLAMA_NO_METRICS:-}}"
DELEGATE_LOCAL_NO_VERDICT_NUDGE="${DELEGATE_LOCAL_NO_VERDICT_NUDGE:-${DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE:-}}"
DELEGATE_LOCAL_VERDICT_NUDGE_FD="${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-${DELEGATE_TO_OLLAMA_VERDICT_NUDGE_FD:-}}"
DELEGATE_LOCAL_NO_META="${DELEGATE_LOCAL_NO_META:-${DELEGATE_TO_OLLAMA_NO_META:-}}"

# Validate the verdict-nudge FD env var up-front so a bad value fails fast,
# before model resolution or the canary probe — a caller who fat-fingers
# `DELEGATE_LOCAL_VERDICT_NUDGE_FD=foo` shouldn't pay the cold-load cost
# before discovering the typo. Default 2 (stderr) keeps the back-compat
# behaviour the #149 reversal pinned. The accepted range is 1-9 (single-
# digit shell FDs): bash 3.2 — the project's portability floor, macOS-
# shipped /bin/bash — only supports the `{var}>file` syntax for high FDs
# from bash 4 onward, so multi-digit FDs via the `>&$N` form are unreliable
# on the target platform. Restricting validation to 1-9 makes the failure
# mode loud (clear error here) rather than silent (write-failure at nudge
# time absorbed by the 2>/dev/null guard below). 0 (stdin) is rejected as
# nonsense; 1 (stdout) is allowed for callers who genuinely want the nudge
# inline with the model output.
nudge_fd="${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-2}"
if ! [[ "$nudge_fd" =~ ^[1-9]$ ]]; then
  echo "delegate: DELEGATE_LOCAL_VERDICT_NUDGE_FD='${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-}' is not a single-digit positive file descriptor (valid: 1-9; 0 is stdin and is rejected, multi-digit FDs are unreliable on bash 3.2)" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"
prompts_dir="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
# delegate_project is derived after lib/otel.sh is sourced (it provides
# delegate_project_name); first used in the metric/span emission near the end.
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

# Single source of truth for the local-tokenizer estimate: total chars in +
# out divided by 4. Both the JSONL metrics row (estimated_tokens_avoided)
# and the delegate-meta stderr line (tokens_local) call this helper, so the
# two surfaces cannot drift on the formula — see gemini-code-assist's PR
# #133 review concern that the divisor was previously duplicated in two
# code paths. Bash integer division of a sum of `${#...}` lengths has no
# zero-divide risk.
compute_tokens_local() {
  local pchars=$1 cchars=$2 ochars=$3
  echo $(( (pchars + cchars + ochars) / 4 ))
}

log_metric() {
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 0
  local ts="$1" tier="$2" model="$3" pchars="$4" cchars="$5" ochars="$6" dur_ms="$7" status="$8" recipe_name="${9:-}" qwait_ms="${10:-0}" gen_ms="${11:-0}" trace_id="${12:-}" span_id="${13:-}" \
    s_temp="${14:-}" s_top_p="${15:-}" s_top_k="${16:-}" s_pp="${17:-}" project="${18:-}"
  local tokens_avoided
  tokens_avoided=$(compute_tokens_local "$pchars" "$cchars" "$ochars")
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  # source:"delegate" discriminates this from experiment-runner traffic that
  # writes to the same file via experiments/lib/run_api_cell.sh. backend
  # discriminates ollama vs mlx traffic — pre-2026-05 rows lack the field and
  # metrics-summary.sh treats their absence as backend=ollama for back-compat.
  # duration_ms remains the inclusive total (invoke → response complete) so
  # downstream consumers (metrics-summary.sh rollups, audit-metrics) keep
  # seeing the same field they did before #170. queue_wait_ms (invoke →
  # first byte from the model server) and generation_ms (first byte →
  # response complete) are emitted alongside so Phase 11 OTel can split the
  # span into queue-wait and generation attributes, and so parallel-caller
  # contention shows up in metrics instead of being hidden inside the
  # generation phase. The two new fields always sum to duration_ms within
  # rounding.
  # otel_trace_id / otel_span_id (#134) carry the trace and span identifiers
  # the OTLP exporter generates so delegate-feedback.sh can join its later
  # feedback-as-linked-span back to the parent delegation without a second
  # lookup. They are always written when the exporter generated them (we
  # generate them unconditionally — the cost is two perl invocations — so
  # historical backfill (Track E #157) and the feedback-span linkage both
  # have a stable identifier even when the exporter endpoint is unset).
  # sampling_temperature / sampling_top_p / sampling_top_k /
  # sampling_presence_penalty (Track A of #193) record the dispatch sampler
  # profile so audit-metrics can pivot on greedy-vs-Qwen-profile runs.
  # Non-Qwen models emit only sampling_temperature (always 0); Qwen models
  # emit all four; env-var overrides surface as whatever the caller set.
  # jq builds the line so any quote, backslash, or newline in $model or
  # $recipe_name (recipe names are filename-safe today but model names come
  # from `ollama list` parsing and are not under our control) escapes
  # correctly rather than producing invalid JSON.
  if [[ -n "$recipe_name" ]]; then
    jq -nc \
      --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" \
      --arg model "$model" --arg recipe "$recipe_name" --arg project "$project" \
      --arg trace_id "$trace_id" --arg span_id "$span_id" \
      --arg s_temp "$s_temp" --arg s_top_p "$s_top_p" --arg s_top_k "$s_top_k" --arg s_pp "$s_pp" \
      --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
      --argjson dur_ms "$dur_ms" --argjson qwait_ms "$qwait_ms" --argjson gen_ms "$gen_ms" \
      --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
      '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, recipe:$recipe, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, queue_wait_ms:$qwait_ms, generation_ms:$gen_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}
       + (if $project != "" then {project:$project} else {} end)
       + (if $trace_id != "" then {otel_trace_id:$trace_id} else {} end)
       + (if $span_id != "" then {otel_span_id:$span_id} else {} end)
       + (if $s_temp != "" then {sampling_temperature:($s_temp|tonumber)} else {} end)
       + (if $s_top_p != "" then {sampling_top_p:($s_top_p|tonumber)} else {} end)
       + (if $s_top_k != "" then {sampling_top_k:($s_top_k|tonumber)} else {} end)
       + (if $s_pp != "" then {sampling_presence_penalty:($s_pp|tonumber)} else {} end)' \
      >> "$metrics_file" 2>/dev/null || true
  else
    jq -nc \
      --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
      --arg project "$project" \
      --arg trace_id "$trace_id" --arg span_id "$span_id" \
      --arg s_temp "$s_temp" --arg s_top_p "$s_top_p" --arg s_top_k "$s_top_k" --arg s_pp "$s_pp" \
      --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
      --argjson dur_ms "$dur_ms" --argjson qwait_ms "$qwait_ms" --argjson gen_ms "$gen_ms" \
      --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
      '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, queue_wait_ms:$qwait_ms, generation_ms:$gen_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}
       + (if $project != "" then {project:$project} else {} end)
       + (if $trace_id != "" then {otel_trace_id:$trace_id} else {} end)
       + (if $span_id != "" then {otel_span_id:$span_id} else {} end)
       + (if $s_temp != "" then {sampling_temperature:($s_temp|tonumber)} else {} end)
       + (if $s_top_p != "" then {sampling_top_p:($s_top_p|tonumber)} else {} end)
       + (if $s_top_k != "" then {sampling_top_k:($s_top_k|tonumber)} else {} end)
       + (if $s_pp != "" then {sampling_presence_penalty:($s_pp|tonumber)} else {} end)' \
      >> "$metrics_file" 2>/dev/null || true
  fi
}

# OTel ID generation and OTLP/HTTP span emission live in scripts/lib/otel.sh —
# shared with delegate-feedback.sh and backfill-otel.sh (Track E, #157). The
# lib defines otel_gen_id, otel_deterministic_ids, emit_otel_span, and
# emit_otel_feedback_span. emit_otel_span carries the Track F redaction
# behaviour (DELEGATE_OTEL_INCLUDE_CONTENT=1 to include content; default
# omits prompt/context/output entirely). Sourcing has no side effects.
# shellcheck source=lib/otel.sh
. "$script_dir/lib/otel.sh"

# Resolve the project name (main repo basename, even inside a git worktree).
delegate_project=$(delegate_project_name)

ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')

# Generate trace_id (32 hex / 128 bits) and span_id (16 hex / 64 bits) for
# the OTel exporter and for the delegate-feedback.sh linkage. We generate
# them unconditionally — the cost is two short perl invocations — so the
# JSONL row always carries the identifiers even when the exporter is
# disabled. That means historical backfill (Track E #157) and feedback-
# as-linked-span (delegate-feedback.sh) both work without a second pass.
otel_trace_id=$(otel_gen_id 32)
otel_span_id=$(otel_gen_id 16)

# Read stdin into a variable if anything is piped in (needed early so {{stdin}}
# substitution can run before the model resolution, and so the recipe-driven
# error paths still surface with a clean metric line). The probe is
# `-p /dev/stdin || -s /dev/stdin` rather than the more obvious `! -t 0`
# because the latter returns true for unix sockets and FIFOs that hold no
# data, and `cat` on such an FD then blocks forever waiting for EOF that
# never arrives — the failure mode hit by Agent SDK `run_in_background`
# callers on 2026-05-22 (#169). `-p` covers ordinary pipes (so the
# `echo data | delegate.sh ...` flow works whether or not bytes have landed
# yet), `-s` covers regular files and heredocs that have content, and both
# are bash 3.2 compatible (the issue's suggested `read -t 0 -N 0` is bash
# 4+ only — verified on macOS-shipped /bin/bash 3.2.57).
context=""
if [[ -p /dev/stdin || -s /dev/stdin ]]; then
  context=$(cat)
fi

# Resolve recipe template (if any) and substitute {{key}} placeholders.
recipe_template=""
recipe_had_stdin_marker=0
declared_inputs_present=0
if [[ -n "$recipe" ]]; then
  recipe_file="$prompts_dir/${recipe}.md"
  if [[ ! -f "$recipe_file" ]]; then
    echo "delegate: recipe '$recipe' not found at $recipe_file" >&2
    exit 2
  fi

  # Optional frontmatter `inputs:` block (Phase 12 Track B, issue #161).
  # Extracts flat `key: type` pairs only — no nesting, no anchors, no flow
  # style — so `awk` parses it without `yq` and the "two bash scripts" rule
  # holds. Supported types: integer, string, integer?, string? (the `?`
  # suffix means optional). Anything richer is deferred until needed.
  # Pre-flight type-validation runs BEFORE placeholder substitution so the
  # caller gets a clear type error rather than an opaque "missing placeholder"
  # downstream message. Recipes without a frontmatter block (today's
  # majority) skip the validation entirely — full back-compat.
  inputs_block=$(awk '
    BEGIN { in_fm=0; in_inputs=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^inputs:[[:space:]]*$/ { in_inputs=1; next }
    in_fm && in_inputs && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*[a-zA-Z?]+[[:space:]]*$/ { print; next }
    in_fm && in_inputs && /^[a-zA-Z_]/ { in_inputs=0 }
  ' "$recipe_file")

  if [[ -n "$inputs_block" ]]; then
    # Build parallel arrays: declared_keys[i] / declared_types[i] / declared_optional[i].
    # Bash 3.2 has no associative arrays, so we use indexed arrays and a
    # linear scan — recipes have at most a handful of inputs so O(n*m) is
    # fine. The `?` suffix is parsed off the type into a separate optional
    # flag so the type-check itself stays a clean enum (integer | string).
    declared_keys=()
    declared_types=()
    declared_optional=()
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Trim leading whitespace and split on colon.
      trimmed="${line#"${line%%[![:space:]]*}"}"
      ikey="${trimmed%%:*}"
      itype_raw="${trimmed#*:}"
      # Trim whitespace around the type token.
      itype_raw="${itype_raw#"${itype_raw%%[![:space:]]*}"}"
      itype_raw="${itype_raw%"${itype_raw##*[![:space:]]}"}"
      iopt=0
      if [[ "$itype_raw" == *"?" ]]; then
        iopt=1
        itype="${itype_raw%?}"
      else
        itype="$itype_raw"
      fi
      case "$itype" in
        integer|string) ;;
        *)
          echo "delegate: recipe '$recipe' inputs:$ikey declares unsupported type '$itype_raw'" >&2
          echo "         supported types: integer, string, integer?, string?" >&2
          exit 2
          ;;
      esac
      declared_keys+=("$ikey")
      declared_types+=("$itype")
      declared_optional+=("$iopt")
    done <<< "$inputs_block"
    declared_inputs_present=1

    # Build a map of provided --var keys (and {{stdin}} when stdin is piped)
    # so we can both type-check each value and detect missing required inputs.
    # provided_keys is a newline-delimited list; matching uses grep -Fxq for
    # an exact-line match so a key like `pr` doesn't accidentally match `pr_number`.
    provided_keys=""
    for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
      if [[ "$kv" != *"="* ]]; then
        echo "delegate: --var must be key=value, got '$kv'" >&2
        exit 2
      fi
      pkey="${kv%%=*}"
      pvalue="${kv#*=}"
      if [[ -z "$pkey" ]]; then
        echo "delegate: --var has empty key in '$kv'" >&2
        exit 2
      fi
      # Type-check against the declared inputs (if any). Undeclared --var
      # keys pass through untouched — lazy migration means most recipes
      # don't declare types yet, and a strict-mode rejection would break
      # them. Strict mode is deferred until migration is more complete.
      idx=0
      for dk in "${declared_keys[@]}"; do
        if [[ "$dk" == "$pkey" ]]; then
          dtype="${declared_types[$idx]}"
          case "$dtype" in
            integer)
              if ! [[ "$pvalue" =~ ^-?[0-9]+$ ]]; then
                echo "delegate: --var $pkey expected type 'integer', got '$pvalue'" >&2
                exit 2
              fi
              ;;
            string)
              # Any value is a valid string. Empty string is permitted so
              # callers can pass `--var name=` for an intentional blank.
              :
              ;;
          esac
          break
        fi
        idx=$((idx + 1))
      done
      provided_keys="${provided_keys}${pkey}"$'\n'
    done

    # `{{stdin}}` satisfies a declared `stdin: string` input when piped, so
    # a recipe can require stdin via the typed surface without forcing the
    # caller to pass it twice (once as --var, once piped). If the recipe
    # declares a non-string type for stdin (e.g. `stdin: integer`), the
    # piped value is type-checked against that declaration here so the
    # pre-flight covers stdin the same way it covers --var inputs.
    if [[ -n "$context" ]]; then
      provided_keys="${provided_keys}stdin"$'\n'
      sidx=0
      for dk in "${declared_keys[@]}"; do
        if [[ "$dk" == "stdin" ]]; then
          stype="${declared_types[$sidx]}"
          case "$stype" in
            integer)
              if ! [[ "$context" =~ ^-?[0-9]+$ ]]; then
                echo "delegate: piped stdin expected type 'integer' (declared by recipe '$recipe'), got non-integer value" >&2
                exit 2
              fi
              ;;
            string)
              :
              ;;
          esac
          break
        fi
        sidx=$((sidx + 1))
      done
    fi

    # Required-input check: any declared input without the `?` optional
    # marker MUST be provided. List every missing key in one error so the
    # caller can fix them in one pass rather than discovering them one at
    # a time.
    missing_required=""
    idx=0
    for dk in "${declared_keys[@]}"; do
      if (( declared_optional[idx] == 0 )); then
        if ! printf '%s' "$provided_keys" | grep -Fxq "$dk"; then
          missing_required="${missing_required}${dk} "
        fi
      fi
      idx=$((idx + 1))
    done
    if [[ -n "${missing_required// /}" ]]; then
      echo "delegate: recipe '$recipe' missing required inputs: ${missing_required% }" >&2
      echo "         pass them via --var key=value" >&2
      exit 2
    fi
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

  # Optional frontmatter `checks:` block (ADR 0014, deterministic output
  # constraints). Each indented `name: value` line declares a check that runs
  # on the finalised output (warn-only). Extracted here so it rides the same
  # {{key}} substitution as the template below — a check value may reference a
  # flavor placeholder (e.g. `subject_max: {{flavor_commit_subject_max}}`) and
  # stay consistent with the prompt. Recipes with no checks: block are untouched.
  recipe_checks=$(awk '
    BEGIN { in_fm=0; in_checks=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^checks:[[:space:]]*$/ { in_checks=1; next }
    in_fm && in_checks && /^[[:space:]]+[a-zA-Z_]/ { print; next }
    in_fm && in_checks && /^[a-zA-Z_]/ { in_checks=0 }
  ' "$recipe_file")

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
    recipe_checks="${recipe_checks//\{\{$key\}\}/$value}"
    satisfied_keys="${satisfied_keys}{{${key}}}"$'\n'
  done

  # Per-user flavor profile (ADR 0013): shipped defaults plus an optional user
  # override, resolved by load-flavor.sh and injected as {{flavor_*}} placeholders.
  # Runs AFTER the --var loop and only fills placeholders --var didn't already
  # satisfy, so an explicit --var flavor_x=… still wins. With no profile installed
  # the defaults reproduce the pre-split prompt verbatim (back-compat). Gated on
  # the template actually using a {{flavor_*}} placeholder, so recipes that don't
  # opt in skip the loader subprocess entirely (no cost, zero behaviour change).
  # Process substitution (not a pipe) so the substitutions land in this shell.
  if [[ "$recipe_template$recipe_checks" == *'{{flavor_'* ]]; then
    while IFS='=' read -r fkey fval; do
      # Defence-in-depth: only act on flavor_* keys, so a stray line (e.g. a
      # value with an embedded newline) can't substitute a non-flavor placeholder.
      [[ "$fkey" != flavor_* ]] && continue
      # The checks block always resolves flavor refs (independent of the
      # template's --var satisfaction state) so e.g. subject_max stays in sync
      # with the prompt's flavor cap.
      recipe_checks="${recipe_checks//\{\{$fkey\}\}/$fval}"
      if ! printf '%s' "$satisfied_keys" | grep -Fxq "{{${fkey}}}"; then
        recipe_template="${recipe_template//\{\{$fkey\}\}/$fval}"
        satisfied_keys="${satisfied_keys}{{${fkey}}}"$'\n'
      fi
    done < <(bash "$script_dir/load-flavor.sh" 2>/dev/null)
  fi

  # Declared-optional inputs (the `?` suffix) the caller did NOT supply have
  # their {{key}} placeholder collapsed to empty here, BEFORE the unsubstituted-
  # placeholder guard below. Without this, an optional input whose placeholder
  # appears in the template body would trip that guard (exit 2) the moment a
  # caller omitted it — forcing every optional placeholder to be all-or-nothing.
  # Blanking lets a recipe expose a genuine override (e.g. commit-message
  # `type`) that most callers leave off, with the template's surrounding prose
  # handling the empty case. Guarded on declared_inputs_present so recipes with
  # no inputs: block (today's majority) are untouched, and so "${declared_keys[@]}"
  # is only expanded when the array was actually built (bash 3.2 + set -u safe).
  if (( declared_inputs_present == 1 )); then
    oidx=0
    for dk in "${declared_keys[@]}"; do
      if (( declared_optional[oidx] == 1 )) \
         && ! printf '%s' "$satisfied_keys" | grep -Fxq "{{${dk}}}"; then
        recipe_template="${recipe_template//\{\{$dk\}\}/}"
        recipe_checks="${recipe_checks//\{\{$dk\}\}/}"
        satisfied_keys="${satisfied_keys}{{${dk}}}"$'\n'
      fi
      oidx=$((oidx + 1))
    done
  fi

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
  fail_dur_ms=$((end_epoch_ms - start_epoch_ms))
  fail_pchars=$(( ${#recipe_template} + ${#prompt} ))
  fail_cchars=${#context}
  fail_toks=$(compute_tokens_local "$fail_pchars" "$fail_cchars" 0)
  log_metric "$ts_start" "$tier" "(none)" "$fail_pchars" "$fail_cchars" 0 "$fail_dur_ms" 1 "$recipe" 0 "$fail_dur_ms" "$otel_trace_id" "$otel_span_id" "" "" "" "" "$delegate_project"
  emit_otel_span "$start_epoch_ms" "$fail_dur_ms" 1 "$otel_trace_id" "$otel_span_id" "(none)" "$backend" "$tier" "$recipe" "$fail_pchars" "$fail_cchars" 0 0 "$fail_dur_ms" "$fail_toks" "${recipe_template}${prompt}" "$context" "" "$delegate_project"
  echo "delegate: pick-model failed for tier '$tier'" >&2
  exit 1
fi

# Recipe-level flaky-on-model gate (Phase 16 Track A). Recipes that have a
# documented flaky-on-class can declare a frontmatter `flaky_on_models:`
# list of case-insensitive substrings; when the resolved model matches any
# of them, the wrapper refuses (exit 4) with a stderr message naming the
# recipe's documented mitigation. Opt-out via DELEGATE_FORCE_FLAKY=1 for
# callers who want to capture fresh evidence that the flaky-class behaviour
# has changed across model upgrades. Backwards-compat: recipes without a
# `flaky_on_models:` frontmatter block skip the check entirely. Sits before
# the pre-flight canary because the gate is structural ("this recipe won't
# work reliably on this model class") while the canary is dynamic ("the
# model isn't responding right now") — no point probing a model the recipe
# already classifies as unreliable.
if [[ -n "$recipe" ]] && [[ "${DELEGATE_FORCE_FLAKY:-}" != "1" ]]; then
  flaky_list=$(awk '
    BEGIN { in_fm=0; in_flaky=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^flaky_on_models:[[:space:]]*$/ { in_flaky=1; next }
    in_fm && in_flaky && /^[[:space:]]+-[[:space:]]+[^[:space:]]/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
      next
    }
    in_fm && in_flaky && /^[a-zA-Z_]/ { in_flaky=0 }
  ' "$recipe_file")
  if [[ -n "$flaky_list" ]]; then
    model_lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
    matched_pat=""
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      pat_lower=$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')
      if [[ "$model_lower" == *"$pat_lower"* ]]; then
        matched_pat="$pat"
        break
      fi
    done <<< "$flaky_list"
    if [[ -n "$matched_pat" ]]; then
      end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
      fail_dur_ms=$((end_epoch_ms - start_epoch_ms))
      fail_pchars=$(( ${#recipe_template} + ${#prompt} ))
      fail_cchars=${#context}
      fail_toks=$(compute_tokens_local "$fail_pchars" "$fail_cchars" 0)
      log_metric "$ts_start" "$tier" "$model" "$fail_pchars" "$fail_cchars" 0 "$fail_dur_ms" 4 "$recipe" 0 "$fail_dur_ms" "$otel_trace_id" "$otel_span_id" "" "" "" "" "$delegate_project"
      emit_otel_span "$start_epoch_ms" "$fail_dur_ms" 4 "$otel_trace_id" "$otel_span_id" "$model" "$backend" "$tier" "$recipe" "$fail_pchars" "$fail_cchars" 0 0 "$fail_dur_ms" "$fail_toks" "${recipe_template}${prompt}" "$context" "" "$delegate_project"
      {
        echo "delegate: recipe '$recipe' is flagged as flaky on model '$model'"
        echo "         (matched frontmatter pattern '$matched_pat'; see prompts/$recipe.md calibration notes)"
        echo "         Options:"
        echo "         - hand-write the output (recommended — the recipe documents this as the active mitigation)"
        echo "         - route to a different tier (e.g. --tier code) and retry"
        echo "         - override with DELEGATE_FORCE_FLAKY=1 (sends the request; expect known-flaky behaviour)"
      } >&2
      exit 4
    fi
  fi
fi

# Resolve the sampler profile for the dispatch call. Default for all models
# is greedy (temperature=0, no top_p/top_k/presence_penalty in the payload).
# Per-call overrides via DELEGATE_TEMPERATURE / DELEGATE_TOP_P / DELEGATE_TOP_K
# / DELEGATE_PRESENCE_PENALTY let callers opt INTO non-greedy sampling — the
# Alibaba-recommended Qwen3 instruct profile is `DELEGATE_TEMPERATURE=0.7
# DELEGATE_TOP_P=0.8 DELEGATE_TOP_K=20 DELEGATE_PRESENCE_PENALTY=1.3`. An
# earlier iteration of this code path auto-applied the Qwen profile on
# Qwen3-family models, but the T4 A/B (see experiments/results/2026-05-22-
# track-a-qwen-sampling-ab.md) found that profile regresses commit-message
# output: temperature=0.7 reintroduces lexical variety that lands on the
# participial-padding tails the commit-message recipe's guards explicitly
# reject. Greedy is the empirically-validated default; the env-vars stay so
# callers can experiment with non-greedy sampling on prose-shaped tasks
# where temperature-induced variety helps. Qwen-family detection still runs
# and sets a `model_family` variable as a hook for future audit-metrics
# work — the field is NOT currently emitted into the JSONL row; a follow-up
# will wire it in once the calibration backlog needs the pivot.
#
# All overrides are validated as numeric (bash 3.2 case-pattern, no
# associative arrays). Numeric pattern: optional leading minus, digits,
# optional decimal point and more digits — covers 0, 0.7, 1.3, -42, .5, 1.
# (top_k is sent as int but the same pattern is used for the validation
# surface so the error message shape stays consistent across all four
# overrides).
model_family=""
model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lc" in
  *qwen3.6*|*qwen3-coder*|*qwen3-next*|*qwen3.5*)
    model_family="qwen3"
    ;;
esac

# Dispatch-side defaults: greedy. The variables holding what actually goes
# into the wire payload are populated below; the parallel `metric_*` set
# captures only what the caller explicitly opted into, so a bare greedy
# invocation writes no sampling_* keys to the JSONL row (back-compat with
# pre-Phase-13 rows). When an env var is set, both surfaces carry it.
sampling_temperature="0"
sampling_top_p=""
sampling_top_k=""
sampling_presence_penalty=""
metric_sampling_temperature=""
metric_sampling_top_p=""
metric_sampling_top_k=""
metric_sampling_presence_penalty=""

validate_numeric() {
  # Bash 3.2 =~ POSIX ERE — same idiom as the canary's preflight_timeout
  # check at line 711. Accepts: optional leading minus, then digits, or
  # digits.digits, or digits., or .digits. Rejects strings like `1-2`,
  # `5-`, `.-` that an earlier permissive `case` pattern passed through
  # and pushed to jq as garbage --argjson input (the failure surfaced as
  # an obscure 'invalid JSON text' rather than the script's own clean error).
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]]; then
    echo "delegate: $name='$value' is not numeric" >&2
    exit 2
  fi
}

if [[ -n "${DELEGATE_TEMPERATURE:-}" ]]; then
  validate_numeric "DELEGATE_TEMPERATURE" "$DELEGATE_TEMPERATURE"
  sampling_temperature="$DELEGATE_TEMPERATURE"
  metric_sampling_temperature="$DELEGATE_TEMPERATURE"
fi
if [[ -n "${DELEGATE_TOP_P:-}" ]]; then
  validate_numeric "DELEGATE_TOP_P" "$DELEGATE_TOP_P"
  sampling_top_p="$DELEGATE_TOP_P"
  metric_sampling_top_p="$DELEGATE_TOP_P"
fi
if [[ -n "${DELEGATE_TOP_K:-}" ]]; then
  validate_numeric "DELEGATE_TOP_K" "$DELEGATE_TOP_K"
  sampling_top_k="$DELEGATE_TOP_K"
  metric_sampling_top_k="$DELEGATE_TOP_K"
fi
if [[ -n "${DELEGATE_PRESENCE_PENALTY:-}" ]]; then
  validate_numeric "DELEGATE_PRESENCE_PENALTY" "$DELEGATE_PRESENCE_PENALTY"
  sampling_presence_penalty="$DELEGATE_PRESENCE_PENALTY"
  metric_sampling_presence_penalty="$DELEGATE_PRESENCE_PENALTY"
fi

# Pre-flight canary — only fires when --recipe is set. Issue #110 documented
# recipe stalls of 6–10 minutes when a 35B-class prose-tier model was hit
# with a recipe-shaped prompt; a 1-token probe with a bounded timeout
# catches that case before the caller's input investment is sunk. The probe
# uses the same backend, model, and think setting as the real dispatch will
# — if the model can't return one token to "hi" within the timeout, the
# real recipe-shaped call definitely won't succeed either. Skipped on bare
# (non-recipe) calls, where the caller hasn't gathered inputs and the
# probe overhead doesn't pay off.
preflight_timeout="${DELEGATE_PREFLIGHT_TIMEOUT:-10}"
if [[ -n "$recipe" ]] \
   && [[ "${DELEGATE_NO_PREFLIGHT:-}" != "1" ]] \
   && [[ "$preflight_timeout" =~ ^[0-9]+$ ]] \
   && (( preflight_timeout > 0 )); then
  # The canary is a 1-token probe — "did the model respond at all" is the
  # only signal we want. Keep it at temperature:0 / greedy so a single fast
  # deterministic token comes back regardless of the dispatch profile. The
  # Qwen sampler overrides (top_p, top_k, presence_penalty) are pointless
  # at num_predict:1 / max_tokens:1 and would only add JSON noise to the
  # smallest-possible health check.
  if [[ "$backend" == "ollama" ]]; then
    canary_payload=$(jq -nc --arg m "$model" --argjson th "$think" \
      '{model:$m, prompt:"hi", stream:false, think:$th, options:{num_predict:1, temperature:0}}')
    canary_url="$ollama_host/api/generate"
  else
    canary_payload=$(jq -nc --arg m "$model" --argjson et "$think" \
      '{model:$m, messages:[{role:"user", content:"hi"}], stream:false, temperature:0, max_tokens:1, chat_template_kwargs:{enable_thinking:$et}}')
    canary_url="$mlx_host/v1/chat/completions"
  fi
  curl -sS --fail --max-time "$preflight_timeout" -X POST "$canary_url" -d @- >/dev/null 2>&1 <<< "$canary_payload"
  canary_status=$?
  if (( canary_status != 0 )); then
    end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
    canary_dur_ms=$((end_epoch_ms - start_epoch_ms))
    canary_pchars=$(( ${#recipe_template} + ${#prompt} ))
    canary_cchars=${#context}
    canary_toks=$(compute_tokens_local "$canary_pchars" "$canary_cchars" 0)
    log_metric "$ts_start" "$tier" "$model" "$canary_pchars" "$canary_cchars" 0 "$canary_dur_ms" 3 "$recipe" 0 "$canary_dur_ms" "$otel_trace_id" "$otel_span_id" "$metric_sampling_temperature" "$metric_sampling_top_p" "$metric_sampling_top_k" "$metric_sampling_presence_penalty" "$delegate_project"
    emit_otel_span "$start_epoch_ms" "$canary_dur_ms" 3 "$otel_trace_id" "$otel_span_id" "$model" "$backend" "$tier" "$recipe" "$canary_pchars" "$canary_cchars" 0 0 "$canary_dur_ms" "$canary_toks" "${recipe_template}${prompt}" "$context" "" "$delegate_project"
    # Distinguish curl exit codes so the recovery advice points at the
    # right knob. 28 is the --max-time-fired timeout (the case the canary
    # was designed for); 7 is "can't reach host" (daemon down or wrong
    # OLLAMA_HOST/MLX_HOST); 22 is curl --fail on a non-2xx response
    # (e.g. an unknown model name returning 404). Anything else falls
    # through to a generic curl-exit-N message that names the code so the
    # caller can look it up.
    case "$canary_status" in
      28) canary_cause="did not return within ${preflight_timeout}s (curl --max-time fired)" ;;
      7)  canary_cause="could not reach $canary_url (connection refused; backend daemon may be down)" ;;
      22) canary_cause="received an HTTP error response (curl --fail; likely a bad model name or invalid payload)" ;;
      *)  canary_cause="failed with curl exit $canary_status" ;;
    esac
    {
      echo "delegate: pre-flight canary $canary_cause"
      echo "         recipe='$recipe' tier='$tier' model='$model' backend='$backend'"
      echo "         Options:"
      echo "         - retry with DELEGATE_PREFLIGHT_TIMEOUT=30 if cold-load is suspected"
      echo "         - start the backend daemon (ollama serve, or mlx_lm.server) and confirm OLLAMA_HOST / MLX_HOST"
      echo "         - re-route to a smaller-parameter model on this host"
      echo "         - hand-write the output (recommended for 35B-class prose tiers on recipe-shaped prompts — see prompts/$recipe.md)"
      echo "         - silence the probe with DELEGATE_NO_PREFLIGHT=1 (sends the full request and inherits the failure)"
    } >&2
    exit 3
  fi
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
#
# curl -w "%{time_starttransfer}" reports seconds-from-curl-start until the
# first response byte arrived. This is the closest measurable proxy for
# "time the Ollama/MLX daemon spent queuing this request plus connecting
# plus model cold-load" — issue #170. We capture body and TTFB separately
# (-o body_file plus -w on stdout) so the response stays parser-clean and
# the timing flows into queue_wait_ms / generation_ms without disturbing
# the existing response-handling path.
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
if [[ "$backend" == "ollama" ]]; then
  # think:false suppresses chain-of-thought for thinking-capable models —
  # see DELEGATE_THINK above. The sampler-profile overlay is built via jq
  # additions so the dispatch payload carries only the keys the caller
  # opted into via env vars; with no overrides the payload is the bare
  # {temperature:0} greedy shape regardless of model family.
  payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson th "$think" \
    --argjson temp "$sampling_temperature" \
    --arg top_p "$sampling_top_p" --arg top_k "$sampling_top_k" --arg pp "$sampling_presence_penalty" \
    '{model:$m, prompt:$p, stream:false, think:$th, options:({temperature:$temp}
      + (if $top_p != "" then {top_p:($top_p|tonumber)} else {} end)
      + (if $top_k != "" then {top_k:($top_k|tonumber)} else {} end)
      + (if $pp != "" then {presence_penalty:($pp|tonumber)} else {} end))}')
  ttfb_s=$(curl -sS --fail -X POST "$ollama_host/api/generate" -d @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
  status=$?
  if [[ "$status" -eq 0 ]]; then
    output=$(jq -r '.response // ""' < "$body_file")
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
  # chat-template kwarg). MLX honours top_p / top_k / presence_penalty on
  # the top-level options (OpenAI-compatible chat-completions shape — same
  # field names, different envelope from Ollama's nested options object).
  payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson mt "$max_tokens" --argjson et "$think" \
    --argjson temp "$sampling_temperature" \
    --arg top_p "$sampling_top_p" --arg top_k "$sampling_top_k" --arg pp "$sampling_presence_penalty" \
    '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:$temp, max_tokens:$mt, chat_template_kwargs:{enable_thinking:$et}}
      + (if $top_p != "" then {top_p:($top_p|tonumber)} else {} end)
      + (if $top_k != "" then {top_k:($top_k|tonumber)} else {} end)
      + (if $pp != "" then {presence_penalty:($pp|tonumber)} else {} end)')
  ttfb_s=$(curl -sS --fail -X POST "$mlx_host/v1/chat/completions" -d @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
  status=$?
  if [[ "$status" -eq 0 ]]; then
    output=$(jq -r '.choices[0].message.content // ""' < "$body_file")
  else
    output=""
  fi
fi

# Reasoning-trace strip. Some trace-emitting reasoning models (qwen3-next-
# thinking, qwq, phi4-reasoning) prepend a <think>...</think> chain-of-thought
# to the answer even under think:false — their Ollama chat template can prefill
# the opening <think> server-side, so only the closing </think> appears in
# .response, with the real answer after it. The strip drops everything up to and
# including the FIRST </think> and trims leading whitespace, leaving the clean
# answer so the structured-output recipes (JSON, regex) parse. It applies when
# DELEGATE_STRIP_THINK=1 OR for the reasoning tier by default (that tier exists
# to route trace-emitting models, and on the Ollama fallback path even the R1
# distill leaks its trace). DELEGATE_STRIP_THINK=0 force-disables even on the
# reasoning tier, for a reasoning recipe whose own output may legitimately
# contain </think>. No-op when the response has no </think>, when the call
# failed (empty output), or when stripping is off. Applied before output_chars
# and the metric/span emission below so every surface sees the clean answer.
strip_think=0
if [[ "${DELEGATE_STRIP_THINK:-}" == "1" ]]; then
  strip_think=1
elif [[ "$tier" == "reasoning" && "${DELEGATE_STRIP_THINK:-}" != "0" ]]; then
  strip_think=1
fi
if (( strip_think == 1 )) && [[ "$output" == *"</think>"* ]]; then
  output="${output#*</think>}"
  output="${output#"${output%%[![:space:]]*}"}"
fi

# Deterministic output checks (ADR 0014): a recipe's frontmatter `checks:` block
# declares constraints that run on the finalised output. Warn-only — they never
# change the output or the exit status. The value is converting a failure the
# prompt cannot reliably prevent under greedy decoding (an over-long subject, a
# trailing padding clause) from "the caller might notice" into "the wrapper
# always flags it". Gated on the same clean-stderr conditions as the meta line
# so batch runs (NO_META) and failed calls stay quiet. The surfaced count rides
# the delegate-meta line below as checks_failed=N.
checks_failed=0
if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] && (( status == 0 )) && [[ -n "${recipe_checks:-}" ]]; then
  # Signatures of the recurring BODY_NO_PADDING failure: a trailing participial
  # clause, a "This-X" declarative rephrase, or a known restating phrase. The
  # participial arm is STRUCTURAL — `, <word>ing` matches any gerund tail rather
  # than an enumerated verb list, because the 2026-06-07 MISS-cluster analysis
  # showed ~3/4 of cited padding verbs (confirming, lifting, undermining,
  # preserving, documenting…) were unenumerated: per-verb enumeration is a
  # treadmill the model walks off by reaching for the next unlisted verb. This
  # mirrors the proven matcher in experiments/score-t4.sh (`[a-z]{3,}ing`, whose
  # {3,} floor and accepted `, string,` false positive carry the same trade-off,
  # documented there). The This-X arm stays enumerated to bound false positives
  # but is extended with the gap verbs the same analysis surfaced (prevents,
  # avoids, serves). Warn-only framing keeps any false positive cheap.
  padding_re=',[[:space:]]+[a-z]{3,}ing([[:space:]]|[.!?,]|$)|(^|[.!?][[:space:]])(this[[:space:]]+(means|approach|ensures|enables|guarantees|delivers|provides|prevents|avoids|serves)|in summary|overall|consequently|ultimately|in effect|as a result)\b|(going|moving)[[:space:]]+forward|clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)'
  check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
  check_last_line=$(printf '%s' "$output" | awk 'NF { l=$0 } END { print l }')
  while IFS= read -r cline; do
    # Parse `  key: value` in-process (no sed subshells in this per-line loop);
    # non-matching/blank lines are skipped. The nested-expansion trim drops any
    # trailing whitespace on the value (bash 3.2 safe).
    if [[ "$cline" =~ ^[[:space:]]*([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
      ckey="${BASH_REMATCH[1]}"
      cval="${BASH_REMATCH[2]}"
      cval="${cval%"${cval##*[![:space:]]}"}"
    else
      continue
    fi
    case "$ckey" in
      subject_max)
        if [[ "$cval" =~ ^[0-9]+$ ]] && (( ${#check_first_line} > cval )); then
          echo "delegate: check 'subject_max' FAILED — first line is ${#check_first_line} chars (> $cval)" >&2
          checks_failed=$((checks_failed + 1))
        fi
        ;;
      no_padding_tail)
        if [[ "$cval" == "true" ]] && printf '%s' "$check_last_line" | grep -Eiq "$padding_re"; then
          echo "delegate: check 'no_padding_tail' FAILED — output ends on a padding/restating clause" >&2
          checks_failed=$((checks_failed + 1))
        fi
        ;;
      subject_type)
        # Caller-supplied conventional-commit type the subject MUST carry. The
        # value rides {{key}} substitution, so `subject_type: {{type}}` is the
        # caller's --var type=X echoed here; an omitted (optional) type collapses
        # to empty and the check is skipped — it only fires when the caller
        # asserted a type and the model ignored it (a recurring MISS the recipe
        # itself named as the wrapper-enforcement escalation). Accepts the full
        # conventional-commit subject shape: type, type(scope), type!, all with
        # the trailing colon.
        if [[ -n "$cval" ]]; then
          type_re="^${cval}(\([^)]*\))?!?:"
          if [[ ! "$check_first_line" =~ $type_re ]]; then
            echo "delegate: check 'subject_type' FAILED — subject does not start with '$cval:' (got '${check_first_line%%:*}:')" >&2
            checks_failed=$((checks_failed + 1))
          fi
        fi
        ;;
      *)
        echo "delegate: unknown check '$ckey' in recipe '$recipe' — ignored" >&2
        ;;
    esac
  done <<< "$recipe_checks"
fi

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

# Derive queue_wait_ms and generation_ms from curl's time_starttransfer
# (seconds-float). awk handles the float→int conversion without depending
# on bc (not always installed on stripped CI images). If curl failed or
# emitted an empty TTFB (some failure modes leave ttfb_s blank), fall back
# to attributing the whole duration to generation_ms so the two fields
# still sum to duration_ms and consumers can detect "no queue split
# available" by queue_wait_ms == 0 on a failed call. Clamp queue_wait_ms
# at duration_ms in case clock skew or sub-millisecond rounding pushes
# it above; the generation_ms = duration_ms - queue_wait_ms invariant
# stays intact.
queue_wait_ms=0
if [[ -n "${ttfb_s:-}" ]] && [[ "$status" -eq 0 ]]; then
  queue_wait_ms=$(awk -v s="$ttfb_s" 'BEGIN { printf "%.0f", s * 1000 }')
  if (( queue_wait_ms > duration_ms )); then
    queue_wait_ms=$duration_ms
  fi
fi
generation_ms=$((duration_ms - queue_wait_ms))

# Char counts that feed both the metrics row and the stderr meta line. Both
# surfaces route through compute_tokens_local so the two cannot drift on
# the formula — the assistant surfaces `tokens_local` from the stderr line
# while metrics-summary.sh rolls up `estimated_tokens_avoided` from the
# JSONL; if they ever disagreed, "how much have I saved" would mean two
# different things depending on which surface you ask.
prompt_chars=$(( ${#recipe_template} + ${#prompt} ))
context_chars=${#context}
output_chars=${#output}
tokens_local=$(compute_tokens_local "$prompt_chars" "$context_chars" "$output_chars")

log_metric "$ts_start" "$tier" "$model" "$prompt_chars" "$context_chars" "$output_chars" "$duration_ms" "$status" "$recipe" "$queue_wait_ms" "$generation_ms" "$otel_trace_id" "$otel_span_id" "$metric_sampling_temperature" "$metric_sampling_top_p" "$metric_sampling_top_k" "$metric_sampling_presence_penalty" "$delegate_project"
emit_otel_span "$start_epoch_ms" "$duration_ms" "$status" "$otel_trace_id" "$otel_span_id" "$model" "$backend" "$tier" "$recipe" "$prompt_chars" "$context_chars" "$output_chars" "$queue_wait_ms" "$generation_ms" "$tokens_local" "${recipe_template}${prompt}" "$context" "$output" "$delegate_project"

# Structured stderr contract — the line SKILL.md teaches the assistant to
# read after every delegation, so it can tell the user which model handled
# the work and how many tokens stayed on-device. Format is parser-friendly
# `key=value` pairs separated by spaces (matches the verdict-nudge plain-text
# convention rather than the JSONL machine surface — humans skim this line
# too). Conditions: successful call only (status==0; meaningless on a failed
# call where there's no output to count), silenceable via NO_META for batch
# runs that want clean stderr. The `tokens_local` value is the local-model
# tokenizer's view (chars/4 estimate, same number as the JSONL row's
# `estimated_tokens_avoided`) — not Anthropic's tokenizer, hence "kept local"
# framing in SKILL.md rather than "saved from Claude".
if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] \
   && (( status == 0 )); then
  # String-typed fields are quoted so a model or recipe name containing a
  # space stays a single token rather than ambiguating the format ("recipe=my
  # name" otherwise reads as `recipe=my` + bare `name`). Today's Ollama tags
  # and MLX HF identifiers don't have spaces, but model names come from
  # `ollama list` parsing and the JSONL surface already escapes them via jq;
  # the stderr surface owes the same defensive shape — flagged on PR #133.
  # Integer fields (tokens_local, duration_ms) stay bare to avoid visual
  # noise on the line.
  meta="model=\"$model\" tier=\"$tier\" backend=\"$backend\" tokens_local=$tokens_local duration_ms=$duration_ms"
  if [[ -n "$recipe" ]]; then
    meta="$meta recipe=\"$recipe\""
  fi
  if (( checks_failed > 0 )); then
    meta="$meta checks_failed=$checks_failed"
  fi
  echo "delegate-meta: $meta" >&2
fi

# Verdict nudge — without it the metrics file accumulates "untracked" rows
# (delegate row with no matching feedback row) and the recipe library can't
# self-correct from production data. Fires unconditionally on success when
# metrics are on, regardless of stdin/stdout shape. A TTY-only gate was
# considered (issue #139 / PR #140) to avoid noisy CI stderr, but the cost
# of the silent-skip on Agent SDK callers — the highest-volume users of
# delegate.sh and the only ones whose verdicts feed future recipe iterations
# — proved higher than the cost of an extra stderr line in CI logs. Lifetime
# coverage was 47.8% under the TTY-gate approach; removing the gate is the
# fix for issue #149. The three escape hatches stay: NO_VERDICT_NUDGE (opt
# out per call), NO_METRICS (no metrics row → nothing to verdict against),
# and non-zero exit (failed calls have no model output to judge). Issue #139
# (parallel-capture callers contaminating stdout via 2>&1) is addressed
# without re-introducing the coverage-losing gate by routing the nudge to a
# caller-chosen file descriptor via DELEGATE_LOCAL_VERDICT_NUDGE_FD=N
# (default 2 = back-compat); the caller-side recipe is to redirect fd N
# alongside the 2>&1 capture so coverage tracking stays intact while stdout
# stays clean.
if [[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]] \
   && [[ "${DELEGATE_LOCAL_NO_VERDICT_NUDGE:-}" != "1" ]] \
   && (( status == 0 )); then
  # nudge_fd was validated up-front (see "Validate the verdict-nudge FD"
  # block at the top); the value here is guaranteed to be a positive integer.
  # The fd=2 path is the default, back-compat shape — write directly so the
  # nudge can't be lost. The fd!=2 path wraps the echo + redirect in a
  # compound `{ ...; } 2>/dev/null` so bash's "Bad file descriptor" error
  # (emitted by the shell when the >&N redirect can't be set up against a
  # closed fd, not by the echo command) is absorbed. A bare `echo ... >&"$N"
  # 2>/dev/null` only catches what echo writes; the redirect-failure noise
  # would still leak back to the very fd 2 the caller was trying to keep
  # clean. The two branches keep fd=2 callers simple and only pay the
  # absorption cost on the gotcha-prone redirect path. Pin verified on
  # macOS bash 3.2.57.
  nudge_msg='delegate: record verdict → bash scripts/delegate-feedback.sh hit (or miss "<reason>")'
  if (( nudge_fd == 2 )); then
    echo "$nudge_msg" >&2
  else
    { echo "$nudge_msg" >&"$nudge_fd"; } 2>/dev/null
  fi
fi

printf '%s\n' "$output"
exit $status
