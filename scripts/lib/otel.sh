#!/usr/bin/env bash
# Shared OTel export helpers — sourced by scripts/delegate.sh,
# scripts/delegate-feedback.sh, and scripts/backfill-otel.sh.
#
# The "two bash scripts" rule (CLAUDE.md) expanded to three scripts plus this
# one shared lib. The lib exists so the backfill script (Track E, #157) can
# emit the exact same OTLP/HTTP wire payload as the live exporter without
# duplicating the jq pipelines, header parsing, and curl invocation logic.
#
# This file is NOT executable on its own — it only defines functions. Sourcing
# it has no side effects (no `set -*`, no top-level code beyond function
# definitions). Callers keep their own `set -uo pipefail` semantics; the
# functions here are tolerant of `set -u` (every variable is locally bound or
# defaulted via `${name:-}`).
#
# Exit-status invariant: the OTel functions in this lib NEVER change the
# caller's exit status. Every curl invocation is guarded with `|| true`
# (default) or a verbose-mode echo-on-failure that still returns 0. This
# matches the existing telemetry-non-fatal contract from delegate.sh and
# delegate-feedback.sh.
#
# Bash 3.2 compatible: no associative arrays, no `${var^^}`, no `mapfile`,
# no `readarray`. Verified against macOS-shipped /bin/bash 3.2.57.

# Guard against double-sourcing — functions are idempotent so a re-source
# is benign, but the guard keeps any future top-level code from running
# twice in the rare case a caller sources delegate.sh which sources this.
if [[ -n "${_DELEGATE_OTEL_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_DELEGATE_OTEL_LIB_LOADED=1

# delegate_project_name
#   Resolve the value for delegate.project: the basename of the MAIN repository,
#   even when delegate.sh runs inside a linked git worktree. `git rev-parse
#   --show-toplevel` returns the worktree directory (e.g.
#   `.claude/worktrees/<branch>`), which would make every worktree session show
#   up as its own "project" and scatter a single repo across many names.
#   `--git-common-dir` (git 2.5+) points at the main repo's `.git` regardless of
#   which worktree is checked out, so its parent directory is the real repo root.
#   The path it prints may be relative, so `cd` + `pwd` makes it absolute — this
#   avoids `--path-format=absolute`, which needs git 2.31+ and would otherwise
#   fail silently on older git and fall back to the (wrong) worktree name.
#   Falls back to the worktree toplevel, then the cwd, when not in (or unable to
#   resolve) a git repo — preserving the previous behaviour outside worktrees.
#   bash 3.2-safe.
delegate_project_name() {
  local common common_dir
  common=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$common" ]]; then
    common_dir=$(cd "$common" 2>/dev/null && pwd)
    basename "$(dirname "$common_dir")"
  else
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
}

# otel_gen_id <nhex>
#   Generate a random hex string of $1 hex chars (so $1*4 bits of entropy).
#   Used for OTel trace IDs (32 hex = 128 bits) and span IDs (16 hex = 64
#   bits). Perl rather than openssl because openssl is not a hard dep on the
#   project baseline (some CI images strip it); perl is already required by
#   every other timing helper here. /dev/urandom + unpack is bash 3.2-safe.
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

# otel_deterministic_ids <ts> <source>
#   Print "<trace_id>\t<span_id>" derived from the JSONL row's ts and source
#   fields via SHA-256 / SHA-1. Used by scripts/backfill-otel.sh so re-runs
#   produce identical IDs and the OTel collector dedups via its own ID space.
#   trace_id = first 32 hex chars of sha256("$ts|$source") (128 bits).
#   span_id  = first 16 hex chars of sha1("$ts|$source")   (64 bits).
#   The `|` separator avoids the (theoretical) collision where two rows with
#   different `ts` and `source` concatenate to the same string.
otel_deterministic_ids() {
  local ts="$1" source="$2"
  perl -MDigest::SHA=sha256_hex,sha1_hex -e '
    my $key = $ARGV[0] . "|" . $ARGV[1];
    printf "%s\t%s\n", substr(sha256_hex($key), 0, 32), substr(sha1_hex($key), 0, 16);
  ' "$ts" "$source"
}

# _otel_post <payload> <error_prefix>
#   Internal helper: POST a JSON payload to $DELEGATE_OTEL_ENDPOINT with the
#   parsed DELEGATE_OTEL_HEADERS. Honours DELEGATE_OTEL_TIMEOUT (default 5)
#   for curl --max-time. Honours DELEGATE_OTEL_VERBOSE=1 to log failures to
#   stderr with the named prefix; default is silent. Always returns 0 — the
#   telemetry-non-fatal contract holds for every caller.
#
#   Header parsing: DELEGATE_OTEL_HEADERS is a comma-separated list of
#   `Header: value` pairs matching the OpenTelemetry SDK convention. The
#   split is on `,`, so a header value that legitimately contains a comma
#   (e.g. `Cookie: a=1, b=2`) would otherwise fragment into two malformed
#   `-H` flags. The OTel SDK convention is that callers url-encode reserved
#   characters in values; we honour that by url-decoding each value (the
#   part after the first `:`) before emitting the -H flag, so the on-wire
#   header is the literal original. Header names are not decoded — RFC 7230
#   forbids reserved characters in field names, so encoding there would be a
#   caller bug we don't paper over. The trim of surrounding whitespace lets
#   `Auth: x, Tenant: y` work without surprises. Decoding uses core perl
#   only (no URI::Escape dep) so the change works on stripped CI images.
_otel_post() {
  local payload="$1" err_prefix="$2"
  local timeout="${DELEGATE_OTEL_TIMEOUT:-5}"
  local -a header_args=()
  if [[ -n "${DELEGATE_OTEL_HEADERS:-}" ]]; then
    local IFS=','
    local hdr
    for hdr in $DELEGATE_OTEL_HEADERS; do
      hdr="${hdr#"${hdr%%[![:space:]]*}"}"
      hdr="${hdr%"${hdr##*[![:space:]]}"}"
      [[ -z "$hdr" ]] && continue
      if [[ "$hdr" == *":"* ]]; then
        local hname="${hdr%%:*}"
        local hvalue="${hdr#*:}"
        hvalue="${hvalue# }"
        hvalue=$(printf '%s' "$hvalue" | perl -pe 's/%([0-9A-Fa-f]{2})/chr(hex($1))/ge')
        header_args+=("-H" "${hname}: ${hvalue}")
      else
        header_args+=("-H" "$hdr")
      fi
    done
  fi

  if [[ "${DELEGATE_OTEL_VERBOSE:-}" == "1" ]]; then
    local curl_err
    curl_err=$(printf '%s' "$payload" | \
      curl -sS --fail --max-time "$timeout" \
        -X POST "${DELEGATE_OTEL_ENDPOINT}" \
        -H 'Content-Type: application/json' \
        "${header_args[@]+"${header_args[@]}"}" \
        -d @- 2>&1 >/dev/null) || \
        echo "${err_prefix}: OTLP export failed: ${curl_err}" >&2
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

# emit_otel_span <start_ms> <duration_ms> <status> <trace_id> <span_id>
#   <model> <backend> <tier> <recipe_name> <pchars> <cchars> <ochars>
#   <qwait_ms> <gen_ms> <tokens_avoided> [<prompt>] [<context>] [<output>]
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
# host unless the caller explicitly opts in. The backfill path (which only
# has char-count metadata from the JSONL, never the original content) can
# omit the three trailing args entirely — empty strings are skipped by the
# `map(select(...))` filter below so nothing leaks even when an operator
# opts in for the live exporter and then runs the backfill against rows
# that pre-date the content capture.
emit_otel_span() {
  [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]] && return 0
  local start_ms="$1" dur_ms="$2" status="$3" trace_id="$4" span_id="$5"
  local model="$6" backend="$7" tier="$8" recipe_name="$9" pchars="${10}"
  local cchars="${11}" ochars="${12}" qwait_ms="${13}" gen_ms="${14}"
  local tokens_avoided="${15}" prompt_text="${16:-}" context_text="${17:-}"
  local output_text="${18:-}" project="${19:-}"
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
    --arg output_text "$output_text" --arg project "$project" \
    '{
      resourceSpans: [{
        resource: {
          attributes: [
            {key: "service.name", value: {stringValue: "delegate-local"}}
          ]
        },
        scopeSpans: [{
          scope: {name: "delegate-local", version: "1.0"},
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
              + (if $project != "" then [{key: "delegate.project", value: {stringValue: $project}}] else [] end)
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

  _otel_post "$payload" "delegate"
  return 0
}

# emit_otel_feedback_span <fb_ts> <verdict> <reason> <parent_trace_id>
#   <parent_span_id> <parent_model> [<parent_recipe>] [<project>]
#
# Emit a feedback-as-linked-span per ADR 0007: NEW trace, NEW span, with
# `links: [{traceId, spanId}]` pointing at the parent delegation when the
# parent IDs are known. Belt-and-braces, the parent IDs are duplicated as
# plain string attributes (delegate.feedback.parent_trace_id /
# delegate.feedback.parent_span_id) for backends that don't render `links`
# well. The span is short by design — 1 ms end-time bump per the schema
# doc — because it is a marker event, not a unit of work.
#
# Failures are intentionally swallowed: OTLP-export errors NEVER change
# delegate-feedback.sh's exit status. The JSONL feedback row has already
# been written by the time this function runs, so the user's verdict is
# always durable on disk.
emit_otel_feedback_span() {
  [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]] && return 0
  local fb_ts="$1" verdict="$2" reason="$3" parent_trace_id="$4"
  local parent_span_id="$5" parent_model="$6" parent_recipe="${7:-}"
  local project="${8:-}"

  # Generate this span's own identifiers. Per ADR 0007, the feedback is in a
  # new trace because the parent trace has already been flushed by the time
  # the feedback arrives (often minutes or hours later).
  local trace_id span_id
  trace_id=$(otel_gen_id 32) || return 0
  span_id=$(otel_gen_id 16) || return 0

  emit_otel_feedback_span_with_ids "$trace_id" "$span_id" \
    "$fb_ts" "$verdict" "$reason" "$parent_trace_id" "$parent_span_id" "$parent_model" "$parent_recipe" "$project"
  return 0
}

# emit_otel_feedback_span_with_ids <trace_id> <span_id> <fb_ts> <verdict>
#   <reason> <parent_trace_id> <parent_span_id> <parent_model>
#   [<parent_recipe>] [<project>]
#
# The same as emit_otel_feedback_span but with this span's trace_id /
# span_id supplied by the caller rather than generated fresh. Used by
# scripts/backfill-otel.sh so re-runs produce identical IDs (the collector
# dedups via OTel ID space). The live exporter path uses the random-ID
# wrapper above because a feedback event has no replay invariant — the
# verdict-recording moment is the only time it ever occurs.
#
# The `delegate.feedback.reason` content attribute is only emitted when
# DELEGATE_OTEL_INCLUDE_CONTENT=1 (Track F #158 default). Verdict + parent
# IDs are metadata and always travel; only the free-text reason is gated.
emit_otel_feedback_span_with_ids() {
  [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]] && return 0
  local trace_id="$1" span_id="$2" fb_ts="$3" verdict="$4" reason="$5"
  local parent_trace_id="$6" parent_span_id="$7" parent_model="$8"
  local parent_recipe="${9:-}"
  local project="${10:-}"
  local include_content="${DELEGATE_OTEL_INCLUDE_CONTENT:-0}"

  # Convert the feedback row's ISO ts to nanoseconds and derive end_ns
  # (start + 1 ms) in the same perl invocation so the OTLP export costs
  # one process instead of two. The 1 ms bump is intentional — zero-
  # duration spans are rejected by some collectors. The arithmetic
  # assumes 64-bit perl integers (every modern macOS and Linux build is
  # 64-bit; on a 32-bit perl build, $Config{ivsize}=4, perl would
  # silently switch to floating-point for values above 2^31 and lose the
  # last few digits of ns precision — accepted edge case, the in-
  # practice impact is negligible).
  local start_ns end_ns
  read -r start_ns end_ns <<< "$(perl -MTime::Local=timegm -e '
    my $ts = shift @ARGV;
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      my $s = timegm($6, $5, $4, $3, $2-1, $1) * 1_000_000_000;
      printf "%d %d\n", $s, $s + 1_000_000;
    } else { exit 1; }
  ' "$fb_ts" 2>/dev/null)"
  [[ -z "$start_ns" || -z "$end_ns" ]] && return 0

  # SPAN_KIND_INTERNAL = 1 per OTLP proto. Span status OK (code 1) always —
  # the feedback span carries the verdict in an attribute, the span's own
  # status reflects whether the marker event happened, which it did.
  local span_kind=1 status_code=1

  # Build the span. The `links` array is populated only when the parent IDs
  # are known; for rows that pre-date the exporter (no otel_trace_id in the
  # JSONL), the span is emitted without a link but with the parent_trace_id
  # attribute left empty — Track E #157 backfills these later.
  #
  # `delegate.feedback.reason` is content (user-authored free text) and so
  # is gated on DELEGATE_OTEL_INCLUDE_CONTENT=1. Default is to omit it
  # entirely — the verdict, parent IDs, and span itself still go through
  # so dashboards keep counting hits and misses; only the reason text is
  # held back unless the operator opts in.
  local payload
  payload=$(jq -nc \
    --arg trace_id "$trace_id" --arg span_id "$span_id" \
    --arg parent_trace_id "$parent_trace_id" --arg parent_span_id "$parent_span_id" \
    --arg model "$parent_model" --arg recipe "$parent_recipe" \
    --arg project "$project" \
    --arg verdict "$verdict" --arg reason "$reason" \
    --arg start_ns "$start_ns" --arg end_ns "$end_ns" \
    --arg include_content "$include_content" \
    --argjson span_kind "$span_kind" --argjson status_code "$status_code" \
    '{
      resourceSpans: [{
        resource: {
          attributes: [
            {key: "service.name", value: {stringValue: "delegate-local"}}
          ]
        },
        scopeSpans: [{
          scope: {name: "delegate-local", version: "1.0"},
          spans: [(
            {
              traceId: $trace_id,
              spanId: $span_id,
              name: ("feedback " + (if $model != "" then $model else "(unknown)" end)),
              kind: $span_kind,
              startTimeUnixNano: $start_ns,
              endTimeUnixNano: $end_ns,
              attributes: ([
                {key: "delegate.feedback.verdict", value: {stringValue: $verdict}},
                {key: "delegate.feedback.parent_trace_id", value: {stringValue: $parent_trace_id}},
                {key: "delegate.feedback.parent_span_id", value: {stringValue: $parent_span_id}}
              ]
              + (if $recipe != "" then [{key: "delegate.recipe", value: {stringValue: $recipe}}] else [] end)
              + (if $project != "" then [{key: "delegate.project", value: {stringValue: $project}}] else [] end)
              + (if $include_content == "1" and $reason != "" then [{key: "delegate.feedback.reason", value: {stringValue: $reason}}] else [] end)),
              status: {code: $status_code}
            }
            + (if $parent_trace_id != "" and $parent_span_id != "" then
                {links: [{traceId: $parent_trace_id, spanId: $parent_span_id}]}
              else {} end)
          )]
        }]
      }]
    }')

  _otel_post "$payload" "delegate-feedback"
  return 0
}
