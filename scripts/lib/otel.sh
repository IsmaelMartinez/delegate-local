#!/usr/bin/env bash
# Shared OTel export helpers, sourced by delegate.sh, delegate-feedback.sh and
# backfill-otel.sh so the backfill emits the same OTLP/HTTP wire payload as
# the live exporter. Sourcing has no side effects (no `set -*`, functions
# only); every function tolerates `set -u` and NEVER changes the caller's
# exit status, since telemetry is non-fatal. bash 3.2 compatible.

# Guard against double-sourcing.
if [[ -n "${_DELEGATE_OTEL_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_DELEGATE_OTEL_LIB_LOADED=1

# delegate_project_name
#   The basename of the MAIN repository, even inside a linked git worktree:
#   `--show-toplevel` names the worktree directory and would scatter one repo
#   across many "projects", so `--git-common-dir` (git 2.5+) is used, made
#   absolute with `cd` + `pwd` because `--path-format=absolute` needs git
#   2.31+. Outside a git repository it emits NOTHING and returns 0: the cwd
#   basename is not a project name. `--project` / DELEGATE_PROJECT win.
delegate_project_name() {
  local common common_dir toplevel
  # DELEGATE_PROJECT wins over any derivation: the cwd is only the right
  # answer when the script runs inside the repo the delegation is FOR (#342).
  if [[ -n "${DELEGATE_PROJECT:-}" ]]; then
    printf '%s\n' "${DELEGATE_PROJECT}"
    return 0
  fi
  common=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ -n "$common" ]]; then
    common_dir=$(cd "$common" 2>/dev/null && pwd)
    basename "$(dirname "$common_dir")"
    return 0
  fi
  # Fallback for a git that cannot answer --git-common-dir (pre-2.5); names
  # the working tree, still a project. Fails outside a repository.
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "$toplevel" ]]; then
    basename "$toplevel"
    return 0
  fi
  # Outside a git repository there is no project: the cwd basename filed a
  # delegation under `project:"tmp"`, a name that matches no boundary lookup
  # (#476). Explicit `return 0`: no project is a normal outcome, and falling
  # off the end would carry out the failed test as status 1.
  return 0
}

# otel_gen_id <nhex>
#   Random hex string of $1 chars. Perl rather than openssl, which is not a
#   hard dep on the project baseline; /dev/urandom + unpack is bash 3.2-safe.
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
#   Print "<trace_id>\t<span_id>" derived from the row's ts and source via
#   SHA-256 / SHA-1, so backfill re-runs produce identical IDs. The `|`
#   separator keeps two different (ts, source) pairs from concatenating alike.
otel_deterministic_ids() {
  local ts="$1" source="$2"
  perl -MDigest::SHA=sha256_hex,sha1_hex -e '
    my $key = $ARGV[0] . "|" . $ARGV[1];
    printf "%s\t%s\n", substr(sha256_hex($key), 0, 32), substr(sha1_hex($key), 0, 16);
  ' "$ts" "$source"
}

# _otel_post <payload> <error_prefix>
#   POST to $DELEGATE_OTEL_ENDPOINT with the parsed DELEGATE_OTEL_HEADERS,
#   honouring DELEGATE_OTEL_TIMEOUT and DELEGATE_OTEL_VERBOSE. Always returns 0.
#   Headers split on `,` per the OTel SDK convention, so a value carrying a
#   comma must be url-encoded; each value is decoded before the -H flag (core
#   perl, no URI::Escape). Names are not decoded: RFC 7230 forbids reserved
#   characters there.
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
#   [<project>] [<retry_chars>]
#
# One OTLP/HTTP span per delegate row (ADR 0007, docs/otel-schema.md).
# Content fields travel only under DELEGATE_OTEL_INCLUDE_CONTENT=1; empty
# strings are dropped by the `map(select(...))` filter, so the backfill,
# which has no content, leaks nothing even when an operator opts in.
emit_otel_span() {
  [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]] && return 0
  local start_ms="$1" dur_ms="$2" status="$3" trace_id="$4" span_id="$5"
  local model="$6" backend="$7" tier="$8" recipe_name="$9" pchars="${10}"
  local cchars="${11}" ochars="${12}" qwait_ms="${13}" gen_ms="${14}"
  local tokens_avoided="${15}" prompt_text="${16:-}" context_text="${17:-}"
  local output_text="${18:-}" project="${19:-}" retry_chars="${20:-}"
  local include_content="${DELEGATE_OTEL_INCLUDE_CONTENT:-0}"

  # OTLP/JSON encodes int64 as JSON strings (proto3 mapping), so the ns
  # values are built as strings; bash arithmetic is signed 64-bit on every
  # platform this runs on.
  local start_ns end_ns
  start_ns="${start_ms}000000"
  end_ns="$(( start_ms + dur_ms ))000000"

  # Span kind 3 = SPAN_KIND_CLIENT (OTel proto enum). Status code 1 = OK,
  # 2 = ERROR per OTLP proto. Mapping per docs/otel-schema.md.
  local span_kind=3 status_code=1
  (( status != 0 )) && status_code=2

  # Int attributes go via --arg (string) because AnyValue.int_value is int64
  # and MUST be a JSON string; span kind and status are int32 enums and stay
  # numbers. delegate.recipe is omitted rather than empty (the schema forbids
  # an empty string).
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
    --arg retry_chars "$retry_chars" \
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
              + (if $retry_chars != "" then [{key: "delegate.retry_chars", value: {intValue: $retry_chars}}] else [] end)
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
#   [<verdict_source>]
#
# A feedback-as-linked-span (ADR 0007): NEW trace, NEW span, `links` pointing
# at the parent delegation when its IDs are known, and the parent IDs
# duplicated as plain attributes for backends that do not render links.
# verdict_source is metadata and always travels; the dashboards filter on it.
emit_otel_feedback_span() {
  [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]] && return 0
  local fb_ts="$1" verdict="$2" reason="$3" parent_trace_id="$4"
  local parent_span_id="$5" parent_model="$6" parent_recipe="${7:-}"
  local project="${8:-}" verdict_source="${9:-agent}"

  # A new trace: the parent trace has been flushed by the time feedback arrives.
  local trace_id span_id
  trace_id=$(otel_gen_id 32) || return 0
  span_id=$(otel_gen_id 16) || return 0

  emit_otel_feedback_span_with_ids "$trace_id" "$span_id" \
    "$fb_ts" "$verdict" "$reason" "$parent_trace_id" "$parent_span_id" "$parent_model" "$parent_recipe" "$project" "$verdict_source"
  return 0
}

# emit_otel_feedback_span_with_ids <trace_id> <span_id> <fb_ts> <verdict>
#   <reason> <parent_trace_id> <parent_span_id> <parent_model>
#   [<parent_recipe>] [<project>] [<verdict_source>]
#
# As emit_otel_feedback_span with the IDs supplied by the caller, so
# backfill-otel.sh re-runs produce identical IDs. Only the free-text reason
# is gated on DELEGATE_OTEL_INCLUDE_CONTENT=1.
emit_otel_feedback_span_with_ids() {
  [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]] && return 0
  local trace_id="$1" span_id="$2" fb_ts="$3" verdict="$4" reason="$5"
  local parent_trace_id="$6" parent_span_id="$7" parent_model="$8"
  local parent_recipe="${9:-}"
  local project="${10:-}"
  local verdict_source="${11:-agent}"
  local include_content="${DELEGATE_OTEL_INCLUDE_CONTENT:-0}"

  # start and end (start + 1 ms) in one perl invocation; zero-duration spans
  # are rejected by some collectors. Assumes 64-bit perl integers.
  local start_ns end_ns
  read -r start_ns end_ns <<< "$(perl -MTime::Local=timegm -e '
    my $ts = shift @ARGV;
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      my $s = timegm($6, $5, $4, $3, $2-1, $1) * 1_000_000_000;
      printf "%d %d\n", $s, $s + 1_000_000;
    } else { exit 1; }
  ' "$fb_ts" 2>/dev/null)"
  [[ -z "$start_ns" || -z "$end_ns" ]] && return 0

  # SPAN_KIND_INTERNAL = 1. Status is always OK: the verdict is an attribute,
  # and the marker event itself happened.
  local span_kind=1 status_code=1

  # `links` only when the parent IDs are known; the reason is content and is
  # gated on DELEGATE_OTEL_INCLUDE_CONTENT=1, the rest always goes through.
  local payload
  payload=$(jq -nc \
    --arg trace_id "$trace_id" --arg span_id "$span_id" \
    --arg parent_trace_id "$parent_trace_id" --arg parent_span_id "$parent_span_id" \
    --arg model "$parent_model" --arg recipe "$parent_recipe" \
    --arg project "$project" \
    --arg verdict "$verdict" --arg reason "$reason" \
    --arg verdict_source "$verdict_source" \
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
                {key: "delegate.feedback.source", value: {stringValue: $verdict_source}},
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
