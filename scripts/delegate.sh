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
#   DELEGATE_TO_OLLAMA_NO_METRICS=1         # opt out of metrics logging
#   DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1   # silence the one-line stderr
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
#   DELEGATE_TO_OLLAMA_NO_META=1            # silence the structured
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
#   OLLAMA_HOST=<url>                       # default http://localhost:11434
#   MLX_HOST=<url>                          # default http://localhost:8080
#   DELEGATE_MAX_TOKENS=<int>               # default 4096. MLX-only — the
#                                           #   OpenAI completions shape
#                                           #   requires max_tokens. Raise
#                                           #   for long-context tier or
#                                           #   verbose models.
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
  [[ "${DELEGATE_TO_OLLAMA_NO_METRICS:-}" == "1" ]] && return 0
  local ts="$1" tier="$2" model="$3" pchars="$4" cchars="$5" ochars="$6" dur_ms="$7" status="$8" recipe_name="${9:-}" qwait_ms="${10:-0}" gen_ms="${11:-0}" trace_id="${12:-}" span_id="${13:-}"
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
  # jq builds the line so any quote, backslash, or newline in $model or
  # $recipe_name (recipe names are filename-safe today but model names come
  # from `ollama list` parsing and are not under our control) escapes
  # correctly rather than producing invalid JSON.
  if [[ -n "$recipe_name" ]]; then
    jq -nc \
      --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" \
      --arg model "$model" --arg recipe "$recipe_name" \
      --arg trace_id "$trace_id" --arg span_id "$span_id" \
      --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
      --argjson dur_ms "$dur_ms" --argjson qwait_ms "$qwait_ms" --argjson gen_ms "$gen_ms" \
      --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
      '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, recipe:$recipe, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, queue_wait_ms:$qwait_ms, generation_ms:$gen_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}
       + (if $trace_id != "" then {otel_trace_id:$trace_id} else {} end)
       + (if $span_id != "" then {otel_span_id:$span_id} else {} end)' \
      >> "$metrics_file" 2>/dev/null || true
  else
    jq -nc \
      --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
      --arg trace_id "$trace_id" --arg span_id "$span_id" \
      --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
      --argjson dur_ms "$dur_ms" --argjson qwait_ms "$qwait_ms" --argjson gen_ms "$gen_ms" \
      --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
      '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, queue_wait_ms:$qwait_ms, generation_ms:$gen_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}
       + (if $trace_id != "" then {otel_trace_id:$trace_id} else {} end)
       + (if $span_id != "" then {otel_span_id:$span_id} else {} end)' \
      >> "$metrics_file" 2>/dev/null || true
  fi
}

# Generate a random hex string of $1 hex chars (so $1*4 bits of entropy).
# Used for OTel trace IDs (32 hex = 128 bits) and span IDs (16 hex = 64 bits).
# Perl rather than openssl because openssl is not a hard dep on the project
# baseline (some CI images strip it); perl is already required by every other
# timing helper here. /dev/urandom + unpack is bash 3.2-safe.
otel_gen_id() {
  local nhex="$1"
  perl -e '
    my $n = int(shift @ARGV);
    my $bytes = int(($n + 1) / 2);
    open(my $fh, "<", "/dev/urandom") or die "urandom: $!";
    binmode $fh;
    my $buf;
    read($fh, $buf, $bytes) == $bytes or die "short read";
    close $fh;
    print substr(unpack("H*", $buf), 0, $n);
  ' "$nhex"
}

# emit_otel_span <start_ms> <duration_ms> <status> <trace_id> <span_id>
#   <model> <backend> <tier> <recipe_name> <pchars> <cchars> <ochars>
#   <qwait_ms> <gen_ms> <tokens_avoided> <prompt> <context> <output>
#
# Translate a delegate row into an OTLP/HTTP JSON payload matching ADR 0007
# (schema in docs/otel-schema.md) and POST it to $DELEGATE_OTEL_ENDPOINT.
# Failures are intentionally swallowed — telemetry must never change the
# caller's exit status or pollute its stdout. When DELEGATE_OTEL_VERBOSE=1
# the failure reason goes to stderr; default is silent so a misconfigured
# endpoint doesn't spam every delegation.
#
# Content fields (prompt / context / output) are only emitted when
# DELEGATE_OTEL_INCLUDE_CONTENT=1. Track F (#158) made the default redact:
# only metadata (tier, model, recipe, char counts, durations) leaves the
# host unless the caller explicitly opts in.
emit_otel_span() {
  [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]] && return 0
  local start_ms="$1" dur_ms="$2" status="$3" trace_id="$4" span_id="$5"
  local model="$6" backend="$7" tier="$8" recipe_name="$9" pchars="${10}"
  local cchars="${11}" ochars="${12}" qwait_ms="${13}" gen_ms="${14}"
  local tokens_avoided="${15}" prompt_text="${16:-}" context_text="${17:-}"
  local output_text="${18:-}"
  local include_content="${DELEGATE_OTEL_INCLUDE_CONTENT:-0}"

  # Compute nanosecond timestamps. start_ms is the high-resolution
  # millisecond epoch captured at script start (Time::HiRes), so ns = ms *
  # 1e6 and end_ns = start_ns + dur_ms * 1e6. Bash arithmetic is signed
  # long on every platform this script runs on (macOS bash 3.2 + Linux), so
  # the values fit comfortably below 2^63 for any timestamp in this
  # millennium. Strings (not numbers) are emitted to jq below because the
  # OTLP/JSON spec encodes int64 fields as JSON strings (proto3 JSON
  # mapping); doing the math here keeps it out of the perl process and
  # avoids the second-precision truncation the ts_iso path used.
  local start_ns end_ns
  start_ns="${start_ms}000000"
  end_ns="$(( start_ms + dur_ms ))000000"

  # Span kind 3 = SPAN_KIND_CLIENT (OTel proto enum). Status code 1 = OK,
  # 2 = ERROR per OTLP proto. Mapping per docs/otel-schema.md.
  local span_kind=3 status_code=1
  (( status != 0 )) && status_code=2

  # Build attributes per the schema in docs/otel-schema.md. The OTLP/HTTP
  # JSON encoding wraps each value in a typed envelope ({stringValue},
  # {intValue}, {doubleValue}); jq handles the structure directly. Per the
  # OTLP/JSON spec, AnyValue.int_value is an int64 field that MUST be
  # encoded as a JSON string (proto3 JSON mapping) — so each int attribute
  # is passed via --arg (string), not --argjson (raw number). The span
  # kind and status code are int32 enums and stay JSON numbers (--argjson).
  # delegate.recipe is only emitted when --recipe was used (the schema
  # explicitly forbids the attribute with an empty string).
  #
  # Content fields (delegate.prompt / delegate.context / delegate.output)
  # are only appended when DELEGATE_OTEL_INCLUDE_CONTENT=1. Default is to
  # omit them entirely — Track F (#158) inverted the default so content
  # never leaves the host unless the operator explicitly opts in. Char
  # counts above are the unconditional metadata equivalents.
  local payload
  payload=$(jq -nc \
    --arg trace_id "$trace_id" --arg span_id "$span_id" \
    --arg model "$model" --arg backend "$backend" --arg tier "$tier" \
    --arg recipe "$recipe_name" \
    --arg start_ns "$start_ns" --arg end_ns "$end_ns" \
    --argjson span_kind "$span_kind" --argjson status_code "$status_code" \
    --arg pchars "$pchars" --arg cchars "$cchars" --arg ochars "$ochars" \
    --arg dur_ms "$dur_ms" --arg qwait_ms "$qwait_ms" --arg gen_ms "$gen_ms" \
    --arg exit_status "$status" --arg tokens_avoided "$tokens_avoided" \
    --arg include_content "$include_content" \
    --arg prompt_text "$prompt_text" --arg context_text "$context_text" \
    --arg output_text "$output_text" \
    '{
      resourceSpans: [{
        resource: {
          attributes: [
            {key: "service.name", value: {stringValue: "delegate-to-ollama"}}
          ]
        },
        scopeSpans: [{
          scope: {name: "delegate-to-ollama", version: "1.0"},
          spans: [(
            {
              traceId: $trace_id,
              spanId: $span_id,
              name: ("chat " + $model),
              kind: $span_kind,
              startTimeUnixNano: $start_ns,
              endTimeUnixNano: $end_ns,
              attributes: ([
                {key: "gen_ai.operation.name", value: {stringValue: "chat"}},
                {key: "gen_ai.provider.name", value: {stringValue: $backend}},
                {key: "gen_ai.request.model", value: {stringValue: $model}},
                {key: "gen_ai.request.temperature", value: {doubleValue: 0}},
                {key: "delegate.tier", value: {stringValue: $tier}},
                {key: "delegate.prompt_chars", value: {intValue: $pchars}},
                {key: "delegate.context_chars", value: {intValue: $cchars}},
                {key: "delegate.output_chars", value: {intValue: $ochars}},
                {key: "delegate.queue_wait_ms", value: {intValue: $qwait_ms}},
                {key: "delegate.generation_ms", value: {intValue: $gen_ms}},
                {key: "delegate.estimated_tokens_avoided", value: {intValue: $tokens_avoided}},
                {key: "delegate.exit_status", value: {intValue: $exit_status}}
              ]
              + (if $recipe != "" then [{key: "delegate.recipe", value: {stringValue: $recipe}}] else [] end)
              + (if $include_content == "1" then [
                  {key: "delegate.prompt", value: {stringValue: $prompt_text}},
                  {key: "delegate.context", value: {stringValue: $context_text}},
                  {key: "delegate.output", value: {stringValue: $output_text}}
                ] | map(select(.value.stringValue != "")) else [] end)),
              status: {code: $status_code}
            }
          )]
        }]
      }]
    }')

  # Build the curl command. DELEGATE_OTEL_HEADERS is a comma-separated list
  # of `Header: value` pairs matching the OpenTelemetry SDK convention. The
  # split is on `,`, which means a header value that legitimately contains
  # a comma (e.g. `Cookie: a=1, b=2`) would otherwise fragment into two
  # malformed `-H` flags. The OTel SDK convention is that callers url-
  # encode reserved characters in values; we honour that by url-decoding
  # each value (the part after the first `:`) before emitting the -H flag,
  # so the on-wire header is the literal original. The header name itself
  # is not decoded — RFC 7230 forbids reserved characters in field names,
  # so encoding there would be a caller bug we don't paper over. The trim
  # of surrounding whitespace lets `Auth: x, Tenant: y` work without
  # surprises. Decoding uses core perl only (no URI::Escape dep) so the
  # change works on stripped CI images.
  local timeout="${DELEGATE_OTEL_TIMEOUT:-5}"
  local -a header_args=()
  if [[ -n "${DELEGATE_OTEL_HEADERS:-}" ]]; then
    local IFS=','
    local hdr
    for hdr in $DELEGATE_OTEL_HEADERS; do
      # Trim surrounding whitespace.
      hdr="${hdr#"${hdr%%[![:space:]]*}"}"
      hdr="${hdr%"${hdr##*[![:space:]]}"}"
      [[ -z "$hdr" ]] && continue
      # url-decode the value portion (everything after the first colon).
      # Header lines without a colon are emitted as-is so curl can surface
      # the malformed-input error rather than the script silently
      # swallowing it. Empty values decode to empty; that's a valid header
      # per RFC 7230 and curl handles it.
      if [[ "$hdr" == *":"* ]]; then
        local hname="${hdr%%:*}"
        local hvalue="${hdr#*:}"
        # Strip one leading space if present (OTel SDK convention is
        # `Name: value`; the space is cosmetic and not part of the value).
        hvalue="${hvalue# }"
        hvalue=$(printf '%s' "$hvalue" | perl -pe 's/%([0-9A-Fa-f]{2})/chr(hex($1))/ge')
        header_args+=("-H" "${hname}: ${hvalue}")
      else
        header_args+=("-H" "$hdr")
      fi
    done
  fi

  # POST. -sS keeps stderr clean unless we explicitly want errors. The
  # entire pipeline is guarded by `|| true` and any stderr is conditionally
  # redirected so a non-2xx response, timeout, or DNS failure cannot
  # propagate. The verbose path lets users debugging a misconfigured
  # endpoint see what's happening.
  local curl_err
  if [[ "${DELEGATE_OTEL_VERBOSE:-}" == "1" ]]; then
    curl_err=$(printf '%s' "$payload" | \
      curl -sS --fail --max-time "$timeout" \
        -X POST "${DELEGATE_OTEL_ENDPOINT}" \
        -H 'Content-Type: application/json' \
        "${header_args[@]+"${header_args[@]}"}" \
        -d @- 2>&1 >/dev/null) || \
        echo "delegate: OTLP export failed: ${curl_err}" >&2
  else
    printf '%s' "$payload" | \
      curl -sS --fail --max-time "$timeout" \
        -X POST "${DELEGATE_OTEL_ENDPOINT}" \
        -H 'Content-Type: application/json' \
        "${header_args[@]+"${header_args[@]}"}" \
        -d @- >/dev/null 2>&1 || true
  fi
  return 0
}

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
  fail_dur_ms=$((end_epoch_ms - start_epoch_ms))
  fail_pchars=$(( ${#recipe_template} + ${#prompt} ))
  fail_cchars=${#context}
  fail_toks=$(compute_tokens_local "$fail_pchars" "$fail_cchars" 0)
  log_metric "$ts_start" "$tier" "(none)" "$fail_pchars" "$fail_cchars" 0 "$fail_dur_ms" 1 "$recipe" 0 "$fail_dur_ms" "$otel_trace_id" "$otel_span_id"
  emit_otel_span "$start_epoch_ms" "$fail_dur_ms" 1 "$otel_trace_id" "$otel_span_id" "(none)" "$backend" "$tier" "$recipe" "$fail_pchars" "$fail_cchars" 0 0 "$fail_dur_ms" "$fail_toks" "${recipe_template}${prompt}" "$context" ""
  echo "delegate: pick-model failed for tier '$tier'" >&2
  exit 1
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
    log_metric "$ts_start" "$tier" "$model" "$canary_pchars" "$canary_cchars" 0 "$canary_dur_ms" 3 "$recipe" 0 "$canary_dur_ms" "$otel_trace_id" "$otel_span_id"
    emit_otel_span "$start_epoch_ms" "$canary_dur_ms" 3 "$otel_trace_id" "$otel_span_id" "$model" "$backend" "$tier" "$recipe" "$canary_pchars" "$canary_cchars" 0 0 "$canary_dur_ms" "$canary_toks" "${recipe_template}${prompt}" "$context" ""
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
  # see DELEGATE_THINK above.
  payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson th "$think" \
    '{model:$m, prompt:$p, stream:false, think:$th, options:{temperature:0}}')
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
  # chat-template kwarg).
  payload=$(jq -nc --arg m "$model" --arg p "$full_input" --argjson mt "$max_tokens" --argjson et "$think" \
    '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:0, max_tokens:$mt, chat_template_kwargs:{enable_thinking:$et}}')
  ttfb_s=$(curl -sS --fail -X POST "$mlx_host/v1/chat/completions" -d @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
  status=$?
  if [[ "$status" -eq 0 ]]; then
    output=$(jq -r '.choices[0].message.content // ""' < "$body_file")
  else
    output=""
  fi
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

log_metric "$ts_start" "$tier" "$model" "$prompt_chars" "$context_chars" "$output_chars" "$duration_ms" "$status" "$recipe" "$queue_wait_ms" "$generation_ms" "$otel_trace_id" "$otel_span_id"
emit_otel_span "$start_epoch_ms" "$duration_ms" "$status" "$otel_trace_id" "$otel_span_id" "$model" "$backend" "$tier" "$recipe" "$prompt_chars" "$context_chars" "$output_chars" "$queue_wait_ms" "$generation_ms" "$tokens_local" "${recipe_template}${prompt}" "$context" "$output"

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
if [[ "${DELEGATE_TO_OLLAMA_NO_META:-}" != "1" ]] \
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
# and non-zero exit (failed calls have no model output to judge).
if [[ "${DELEGATE_TO_OLLAMA_NO_METRICS:-}" != "1" ]] \
   && [[ "${DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE:-}" != "1" ]] \
   && (( status == 0 )); then
  echo "delegate: record verdict → bash scripts/delegate-feedback.sh hit (or miss \"<reason>\")" >&2
fi

printf '%s\n' "$output"
exit $status
