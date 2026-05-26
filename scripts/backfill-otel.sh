#!/usr/bin/env bash
# Walk the delegate metrics JSONL and emit one OTLP/HTTP span per row to
# ${DELEGATE_OTEL_ENDPOINT}. Row-level idempotent: rows already exported
# live (otel_trace_id present) are skipped; pre-exporter rows get
# deterministic IDs derived from (ts, source) so re-runs collide in the
# OTel collector's ID space and don't duplicate. Track E of Phase 11
# (#157) — see ROADMAP "Track E — Historical JSONL backfill" and
# docs/adr/0007-otel-schema.md for the schema this exports against.
#
# Usage:
#   backfill-otel.sh [--since <iso8601>] [--dry-run] [--metrics-file PATH]
#                    [--update-jsonl]
#
# Flags:
#   --since <iso8601>     only backfill rows with ts >= iso (UTC, Z suffix).
#                         default: all rows in the file.
#   --dry-run             print one line per row but make no HTTP calls.
#   --metrics-file PATH   override the metrics JSONL location. Default is
#                         ${DELEGATE_METRICS_FILE:-~/.claude/skills/
#                         delegate-local/metrics.jsonl}.
#   --update-jsonl        after a successful POST, append the computed
#                         otel_trace_id / otel_span_id to the row in the
#                         JSONL so subsequent backfills skip via the live-
#                         exported path. Mutates the metrics file atomically
#                         via tempfile-and-rename. Off by default because
#                         mutating the metrics file is a more invasive
#                         operation than the read-only backfill.
#
# Env:
#   DELEGATE_OTEL_ENDPOINT          required (unless --dry-run). Same URL
#                                   delegate.sh / delegate-feedback.sh use.
#   DELEGATE_OTEL_HEADERS           optional. Comma-separated header pairs,
#                                   url-encoded values per OTel SDK
#                                   convention. Same shape as delegate.sh.
#   DELEGATE_OTEL_TIMEOUT           curl --max-time per POST (default 5).
#   DELEGATE_OTEL_VERBOSE=1         log per-POST failures to stderr (the
#                                   per-row progress line shows ERROR
#                                   regardless; this just adds the curl
#                                   reason).
#   DELEGATE_METRICS_FILE           overridden by --metrics-file. Default
#                                   ~/.claude/skills/delegate-local/
#                                   metrics.jsonl.
#
# Output:  per-row progress on stderr — `OK ts=... (delegate|feedback)`,
#          `SKIP ts=... (already exported by JSONL)`, or
#          `ERROR ts=... (<reason>)`. Final stderr summary line:
#          `backfill: N rows, M sent, K skipped, L errored`.
# Exit:    0 on success (even if individual rows errored — backfill is
#          best-effort), 2 on usage error, 1 on missing metrics file or
#          missing DELEGATE_OTEL_ENDPOINT (without --dry-run).
#
# Idempotency model: each row's emit identity is deterministic from (ts,
# source). A row that was exported live (`otel_trace_id` already set in the
# JSONL) is SKIPPED — sending again would create a duplicate at the
# collector since the live IDs were random. Pre-exporter rows get
# sha256(ts|source) → trace_id (32 hex) and sha1(ts|source) → span_id (16
# hex). Future re-runs see no `otel_trace_id` in the JSONL row but compute
# the same deterministic IDs, so the collector dedups via OTel ID space.
# --update-jsonl flips this into the SKIP path for re-runs by writing the
# IDs back to the row.
#
# Feedback rows: trace_id and span_id of the parent delegation are derived
# the same way from the parent row's (ts, source="delegate"), so the
# linked-span pointer works correctly across backfill runs. If the parent
# row was exported live (has its own otel_trace_id / otel_span_id from
# delegate.sh), those random IDs win — that's the same identity the live
# delegate-feedback.sh would have linked against, so the chain stays
# consistent.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/otel.sh
. "$script_dir/lib/otel.sh"

usage() {
  cat >&2 <<'EOF'
usage: backfill-otel.sh [--since <iso8601>] [--dry-run] [--metrics-file PATH] [--update-jsonl]
  Walks the delegate metrics JSONL and POSTs one OTLP span per row to
  DELEGATE_OTEL_ENDPOINT. Idempotent at row level — re-runs produce no
  duplicate spans at the collector. See script header for full env reference.
EOF
  exit 2
}

since_iso=""
dry_run=0
metrics_file_override=""
update_jsonl=0
while (($# > 0)); do
  case "$1" in
    --since)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'backfill-otel: --since requires a value' >&2; exit 2
      fi
      since_iso="$2"; shift 2;;
    --since=*) since_iso="${1#--since=}"; shift;;
    --dry-run) dry_run=1; shift;;
    --metrics-file)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'backfill-otel: --metrics-file requires a path' >&2; exit 2
      fi
      metrics_file_override="$2"; shift 2;;
    --metrics-file=*) metrics_file_override="${1#--metrics-file=}"; shift;;
    --update-jsonl) update_jsonl=1; shift;;
    -h|--help) usage;;
    *) echo "backfill-otel: unknown arg '$1'" >&2; usage;;
  esac
done

metrics_file="${metrics_file_override:-${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}}"

[[ -f "$metrics_file" ]] || { echo "backfill-otel: metrics file not found: $metrics_file" >&2; exit 1; }
command -v jq >/dev/null || { echo "backfill-otel: jq not on PATH" >&2; exit 2; }
command -v perl >/dev/null || { echo "backfill-otel: perl not on PATH" >&2; exit 2; }

if (( dry_run == 0 )) && [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]]; then
  echo 'backfill-otel: DELEGATE_OTEL_ENDPOINT is not set' >&2
  echo '         Either set it to the OTLP/HTTP traces URL, or pass --dry-run' >&2
  echo '         to preview what would be sent.' >&2
  exit 1
fi

# Validate --since shape (matches the JSONL ts format used by delegate.sh
# and delegate-feedback.sh). Cheap check; saves a confusing "no rows
# matched" footgun later when the user passes "2026-05-22" without the
# T...Z suffix.
if [[ -n "$since_iso" ]]; then
  if ! [[ "$since_iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "backfill-otel: --since must be ISO 8601 like 2026-05-22T12:34:56Z (got '$since_iso')" >&2
    exit 2
  fi
fi

# Two-pass design (first pass: build parent lookup; second pass: emit) is
# the simplest way to support feedback rows linking to parent delegate rows
# without a stateful streaming parser. JSONL files in practice top out at
# a few MB (thousands of rows, ~150 bytes each) so the memory cost of the
# lookup table is negligible.
#
# The parent-lookup pass extracts every delegate row's ts, model,
# otel_trace_id (if already exported live), and otel_span_id. Keyed by ts
# alone — delegate.sh writes one row per call with a unique-to-the-second
# ts, and feedback rows' ref_ts matches that exact ts. Two delegate rows
# with the same ts would alias here, but that requires two delegations
# within one second on the same workstation, which the canary preflight
# already rules out for recipe-shaped calls and which would already break
# the existing delegate-feedback.sh ref_ts lookup. Accepted edge case.
parent_lookup=$(jq -rc '
  select((.source // "delegate") == "delegate") |
  [.ts, (.model // ""), (.otel_trace_id // ""), (.otel_span_id // "")] |
  @tsv
' "$metrics_file")

total_rows=0
sent_count=0
skipped_count=0
errored_count=0

# For --update-jsonl: accumulate (ts, source, trace_id, span_id) tuples
# that need to be appended to the row in the JSONL file. After the emit
# loop, rewrite the file atomically by streaming each original line through
# jq, adding the IDs when the line matches. Keeps the file edit out of
# the per-row hot path (one rewrite at the end vs N partial writes), and
# keeps the failure mode boring — if the script is killed mid-emit, the
# JSONL is untouched and the next run re-derives the same deterministic
# IDs anyway.
updates_tsv=""

# Emit a single row. Sets ROW_RESULT to "OK"|"SKIP"|"ERROR <reason>" via
# global because bash 3.2 has no clean "return multiple values"; ROW_KIND
# similarly carries "delegate"|"feedback" for the progress line.
ROW_RESULT=""
ROW_KIND=""
ROW_TRACE=""
ROW_SPAN=""

# emit_delegate_row <row_json>
#   Process one source:"delegate" row. Skip if otel_trace_id present
#   (already exported live); otherwise derive deterministic IDs and POST.
emit_delegate_row() {
  local row="$1"
  local ts source backend tier model recipe
  local pchars cchars ochars dur_ms qwait_ms gen_ms status tokens_avoided
  local existing_trace existing_span
  ROW_KIND="delegate"

  # One jq call per row extracts every field into a record separated by
  # ASCII Unit Separator (0x1F), then read parses it into named locals.
  # Replaces the 14 per-row jq invocations from the initial draft —
  # gemini-code-assist on PR #191 flagged the per-field calls as the
  # dominant cost on multi-thousand-row metrics files (one fork+exec per
  # call). Defaults match delegate.sh's log_metric: backend defaults to
  # ollama (pre-2026-05 rows omit the field); empty tier/model/recipe
  # pass through to the OTel payload as empty strings.
  #
  # Unit Separator rather than tab because bash `read` with a whitespace
  # IFS collapses adjacent separators (empty fields disappear); 0x1F is
  # a non-whitespace control char so consecutive separators each
  # delimit a real (possibly empty) field. The 0x1F character cannot
  # appear in any of the source values — model names, tier names, recipe
  # names, ISO timestamps, integer fields all reject it by construction.
  #
  # The field order in the jq expression below MUST match the order of
  # vars passed to `read -r` — adding a field requires updating both.
  local fields
  fields=$(jq -r '[
    .ts // "",
    .source // "delegate",
    .backend // "ollama",
    .tier // "",
    .model // "",
    .recipe // "",
    .prompt_chars // 0,
    .context_chars // 0,
    .output_chars // 0,
    .duration_ms // 0,
    .queue_wait_ms // 0,
    .generation_ms // 0,
    .exit_status // 0,
    .estimated_tokens_avoided // 0,
    .otel_trace_id // "",
    .otel_span_id // "",
    .project // ""
  ] | map(tostring) | join("\u001f")' <<< "$row")
  IFS=$'\x1f' read -r ts source backend tier model recipe \
    pchars cchars ochars dur_ms qwait_ms gen_ms status tokens_avoided \
    existing_trace existing_span project <<< "$fields"

  if [[ -n "$existing_trace" && -n "$existing_span" ]]; then
    ROW_RESULT="SKIP"
    return 0
  fi

  if [[ -z "$ts" ]]; then
    ROW_RESULT="ERROR malformed row (no ts)"
    return 0
  fi

  # queue_wait_ms / generation_ms were added in PR #170. Older rows have
  # only duration_ms — attribute the whole duration to generation_ms so
  # the two split fields still sum to duration_ms (the invariant the
  # consumers assume). Same behaviour as the live exporter's fallback
  # path when curl fails to report TTFB.
  if [[ "$qwait_ms" == "0" && "$gen_ms" == "0" && "$dur_ms" != "0" ]]; then
    gen_ms="$dur_ms"
  fi

  local ids trace_id span_id
  ids=$(otel_deterministic_ids "$ts" "$source") || {
    ROW_RESULT="ERROR id derivation failed"
    return 0
  }
  IFS=$'\t' read -r trace_id span_id <<< "$ids"
  ROW_TRACE="$trace_id"
  ROW_SPAN="$span_id"

  # Compute start_ms from the row's ISO ts (the live exporter has the
  # exact start_epoch_ms from Time::HiRes, but post-hoc all we have is the
  # second-precision ts; this is good enough for the historical view).
  local start_ms
  start_ms=$(iso_to_epoch_ms "$ts") || {
    ROW_RESULT="ERROR ts parse failed"
    return 0
  }

  if (( dry_run == 1 )); then
    ROW_RESULT="OK"
    return 0
  fi

  # The lib's emit_otel_span is exit-status-neutral; we have to detect
  # failure ourselves via the verbose path or by counting `otel: ` lines
  # in stderr (the library itself only echoes to stderr when verbose is
  # set). Simpler: probe the endpoint reachability via the same curl
  # invocation inside the lib by reading its exit code through a wrapper.
  # The lib swallows curl's exit code by design, so the only way to know
  # is to invoke the post directly with a known exit-checking shape.
  # Compromise: we invoke the lib function, which always returns 0; the
  # "ERROR" path is reachable only for upstream conditions (malformed row,
  # ts parse failure). A misconfigured endpoint surfaces in the lib's
  # verbose mode and in the absence of spans at the collector; the
  # backfill marks it OK from its own perspective. This matches the
  # exporter's existing exit-status-neutral contract.
  emit_otel_span "$start_ms" "$dur_ms" "$status" "$trace_id" "$span_id" \
    "$model" "$backend" "$tier" "$recipe" "$pchars" "$cchars" "$ochars" \
    "$qwait_ms" "$gen_ms" "$tokens_avoided" "" "" "" "$project"
  ROW_RESULT="OK"
  return 0
}

# emit_feedback_row <row_json>
#   Process one source:"feedback" row. Look up the parent delegate row by
#   ref_ts, derive its deterministic IDs (or use the live IDs if present),
#   and POST the feedback span linked to that parent. Feedback rows do
#   NOT get an "already exported" skip path of their own — the feedback
#   span ID is itself derived from the feedback row's (ts, source), so the
#   collector deduplicates on re-emit via OTel ID space.
emit_feedback_row() {
  local row="$1"
  local fb_ts ref_ts kept reason verdict
  ROW_KIND="feedback"

  # One jq call extracts every field into a 0x1F-separated record — same
  # consolidation that emit_delegate_row does, for the same reason
  # (gemini-code-assist on PR #191). `kept` becomes the boolean string
  # "true"/"false" via the `tostring` filter; downstream code already
  # compares with `[[ ... == "true" ]]`. Unit Separator (0x1F) rather than
  # tab because reason text could in theory contain a tab and the empty-
  # reason case must round-trip as a real empty field rather than being
  # collapsed by whitespace-IFS `read`.
  local fields
  fields=$(jq -r '[
    .ts // "",
    .ref_ts // "",
    (.kept // false | tostring),
    .reason // ""
  ] | join("\u001f")' <<< "$row")
  IFS=$'\x1f' read -r fb_ts ref_ts kept reason <<< "$fields"

  if [[ -z "$fb_ts" ]]; then
    ROW_RESULT="ERROR malformed feedback row (no ts)"
    return 0
  fi

  if [[ "$kept" == "true" ]]; then
    verdict="hit"
  else
    verdict="miss"
  fi

  # Derive the feedback span's own IDs deterministically from its (ts,
  # source="feedback") so re-runs collide in the collector. The live path
  # (delegate-feedback.sh) uses random IDs because there's no replay
  # invariant at the moment-of-record; for backfill we need determinism.
  local fb_ids fb_trace fb_span
  fb_ids=$(otel_deterministic_ids "$fb_ts" "feedback") || {
    ROW_RESULT="ERROR feedback id derivation failed"
    return 0
  }
  IFS=$'\t' read -r fb_trace fb_span <<< "$fb_ids"
  ROW_TRACE="$fb_trace"
  ROW_SPAN="$fb_span"

  # Look up the parent delegate row's IDs and model. The parent_lookup tsv
  # has one line per delegate row: ts<TAB>model<TAB>existing_trace<TAB>existing_span.
  # If the parent was exported live (has IDs), use those. Otherwise derive
  # them the same way the delegate-row path does — sha256(ts|source).
  local parent_line parent_model parent_existing_trace parent_existing_span
  local parent_trace parent_span
  parent_trace=""
  parent_span=""
  parent_model=""
  if [[ -n "$ref_ts" ]]; then
    # grep -F -m1 with a leading anchor — fixed-string match for the ts
    # followed by a literal tab so a prefix match (e.g. ts="2026-05-22T"
    # against a row starting "2026-05-22T10:00:00Z") doesn't false-match.
    # Faster than awk-per-feedback-row (gemini-code-assist's PR #191
    # observation): grep stops at the first match (-m1) and avoids
    # awk's full field-splitting per line. The output goes to read with
    # the same TSV split as before.
    parent_line=$(printf '%s\n' "$parent_lookup" | grep -F -m1 "${ref_ts}	" || true)
    if [[ -n "$parent_line" ]]; then
      IFS=$'\t' read -r _ parent_model parent_existing_trace parent_existing_span <<< "$parent_line"
      if [[ -n "$parent_existing_trace" && -n "$parent_existing_span" ]]; then
        parent_trace="$parent_existing_trace"
        parent_span="$parent_existing_span"
      else
        local parent_ids
        parent_ids=$(otel_deterministic_ids "$ref_ts" "delegate") || true
        IFS=$'\t' read -r parent_trace parent_span <<< "$parent_ids"
      fi
    fi
  fi
  # If the parent row was not found, parent_trace / parent_span stay empty
  # and emit_otel_feedback_span_with_ids omits the `links` array — same
  # behaviour the live delegate-feedback.sh has for pre-exporter rows.

  if (( dry_run == 1 )); then
    ROW_RESULT="OK"
    return 0
  fi

  emit_otel_feedback_span_with_ids "$fb_trace" "$fb_span" \
    "$fb_ts" "$verdict" "$reason" "$parent_trace" "$parent_span" "$parent_model"
  ROW_RESULT="OK"
  return 0
}

# iso_to_epoch_ms <iso8601>
#   Convert a JSONL ts (YYYY-MM-DDTHH:MM:SSZ) to epoch milliseconds. The
#   live exporter has start_epoch_ms from Time::HiRes; post-hoc the JSONL
#   only retains second precision, so the start_ns the lib computes from
#   our return value will end on .000000000. Acceptable — historical
#   spans don't need sub-second timing for the dashboards.
iso_to_epoch_ms() {
  perl -MTime::Local=timegm -e '
    my $ts = shift @ARGV;
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      print timegm($6, $5, $4, $3, $2-1, $1) * 1000;
    } else {
      exit 1;
    }
  ' "$1"
}

# Main loop. Stream rows directly from a single jq pass through process
# substitution rather than buffering the whole file into a shell variable
# — that bounds memory at the row size, not file size, and removes the
# ARG_MAX risk gemini-code-assist flagged on PR #191. Each line emitted by
# jq is "<source>\t<ts>\t<row_json>" so the loop never re-invokes jq just
# to discriminate source — the per-row 2 jq calls drop to zero. Row-level
# field extraction inside emit_*_row still uses a single consolidated jq
# call per row (also a PR #191 review fix), so the dominant per-row cost
# is now one jq invocation rather than fifteen.
#
# The `--since` filter applies inside the same jq pass (when set), so a
# row that doesn't match never costs more than the jq filter evaluation —
# it never reaches the loop body.
while IFS=$'\t' read -r source ts row; do
  [[ -z "$row" ]] && continue
  total_rows=$((total_rows + 1))

  ROW_RESULT=""
  ROW_KIND=""
  ROW_TRACE=""
  ROW_SPAN=""

  case "$source" in
    delegate) emit_delegate_row "$row" ;;
    feedback) emit_feedback_row "$row" ;;
    *)
      # experiment rows, future sources — skip without an error count.
      # The experiment runner writes its own rows under source:"experiment"
      # and they're not part of the live OTel exporter's surface area.
      ROW_RESULT="SKIP"
      ROW_KIND="$source"
      ;;
  esac

  case "$ROW_RESULT" in
    OK)
      sent_count=$((sent_count + 1))
      echo "OK ts=$ts ($ROW_KIND)" >&2
      # Track --update-jsonl writes ONLY for delegate rows that were just
      # exported (not skipped, not errored). Feedback rows don't need
      # back-write because their IDs are recomputed from (ts, source) on
      # every re-run.
      if (( update_jsonl == 1 )) && [[ "$ROW_KIND" == "delegate" && -n "$ROW_TRACE" && -n "$ROW_SPAN" ]]; then
        updates_tsv="${updates_tsv}${ts}"$'\t'"${ROW_TRACE}"$'\t'"${ROW_SPAN}"$'\n'
      fi
      ;;
    SKIP)
      skipped_count=$((skipped_count + 1))
      if [[ "$ROW_KIND" == "delegate" || "$ROW_KIND" == "feedback" ]]; then
        echo "SKIP ts=$ts ($ROW_KIND: already exported by JSONL)" >&2
      else
        echo "SKIP ts=$ts (source=$ROW_KIND not handled)" >&2
      fi
      ;;
    ERROR*)
      errored_count=$((errored_count + 1))
      echo "ERROR ts=$ts (${ROW_RESULT#ERROR })" >&2
      ;;
  esac
done < <(jq -rc --arg since "$since_iso" '
  if $since != "" and .ts < $since then empty
  else [(.source // "delegate"), (.ts // ""), tojson] | @tsv
  end
' "$metrics_file")

# --update-jsonl rewrite phase. The metrics file is rewritten atomically
# via a tempfile in the same directory (so the rename is a single inode
# swap, no cross-filesystem move). The rewrite happens in a single perl
# pass — the original draft of this script ran two jq invocations per
# line of the WHOLE file, which gemini-code-assist flagged on PR #191 as
# the dominant pessimisation for multi-thousand-row metrics files.
#
# Perl reads the updates_tsv into a hash keyed by ts → "trace\tspan",
# then streams the input file line-by-line. For each line that parses as
# JSON and is a delegate row without an existing otel_trace_id, the hash
# is consulted; on a hit, the trace_id / span_id keys are appended with
# minimal JSON manipulation (the closing `}` is replaced with `,"otel_
# trace_id":"...","otel_span_id":"..."}`). For correctness this matters
# only that (a) the line was valid JSON when delegate.sh wrote it (true
# by construction — jq -nc produced it), and (b) the closing brace is
# the last non-whitespace character (true for jq -nc output). Lines that
# don't match either criterion pass through verbatim — same fail-open
# behaviour as the previous bash+jq version.
#
# Concurrent writers (a delegate.sh call appending while the backfill
# rewrites) are not coordinated — the second writer wins per `mv`
# semantics. Acceptable at workstation scale; document explicitly rather
# than building a lock-file dance for a constraint nobody hits.
if (( update_jsonl == 1 && sent_count > 0 )); then
  tmp_out=$(mktemp "${metrics_file}.backfill.XXXXXX") || {
    echo "backfill-otel: could not create tempfile for --update-jsonl" >&2
    echo "backfill: $total_rows rows, $sent_count sent, $skipped_count skipped, $errored_count errored" >&2
    exit 0
  }

  # Pass updates_tsv on stdin as a here-string so perl reads it from a
  # known FH. The metrics file is the script's positional arg.
  perl -e '
    use strict; use warnings;
    my $updates_path = shift @ARGV;
    my $metrics_path = shift @ARGV;
    my $out_path = shift @ARGV;
    # Build the ts -> "trace\tspan" hash. updates_tsv has one line per
    # exported delegate row: ts<TAB>trace_id<TAB>span_id.
    my %updates;
    open(my $uh, "<", $updates_path) or die "open updates: $!";
    while (my $line = <$uh>) {
      chomp $line;
      next unless length $line;
      my ($ts, $trace, $span) = split /\t/, $line, 3;
      next unless defined $trace && defined $span;
      $updates{$ts} = qq{"otel_trace_id":"$trace","otel_span_id":"$span"};
    }
    close $uh;
    # Stream the metrics file. For each line, fast-path: if it does not
    # look like a delegate row needing an update, pass through. Otherwise
    # do a regex check for both an existing otel_trace_id (skip) and a
    # ts match against the hash; on a hit, splice the new keys before the
    # closing brace. The regex extraction works because delegate.sh
    # writes its JSONL via `jq -nc` which produces a flat object with
    # double-quoted ASCII keys and no embedded literal newlines.
    open(my $ih, "<", $metrics_path) or die "open metrics: $!";
    open(my $oh, ">", $out_path) or die "open out: $!";
    while (my $line = <$ih>) {
      # Preserve blank lines exactly.
      if ($line =~ /^\s*$/) { print $oh $line; next; }
      # Cheap discriminator: skip lines that are not delegate rows or
      # that already carry otel_trace_id. Anchored on `"source":` and
      # `"otel_trace_id":` strings rather than parsed JSON so the cost
      # is one regex per line, not a full JSON parse.
      if ($line =~ /"source":"feedback"/ || $line =~ /"source":"experiment"/) {
        print $oh $line; next;
      }
      if ($line =~ /"otel_trace_id":/) { print $oh $line; next; }
      # Extract ts — anchored on the `"ts":"...Z"` shape delegate.sh
      # writes. Skip lines without a matching ts (malformed; pass
      # through unchanged).
      if ($line =~ /"ts":"([^"]+)"/) {
        my $ts = $1;
        if (exists $updates{$ts}) {
          # Splice the new keys before the final `}`. Match the last
          # `}` followed by optional whitespace (\r?\n at line end is
          # captured separately) so a row with trailing newline keeps
          # its newline placement.
          my $injected = $updates{$ts};
          if ($line =~ s/\}(\s*)$/,${injected}\}$1/) {
            print $oh $line;
            next;
          }
        }
      }
      # Fall-through: not a delegate row with a matched ts, or a row
      # whose closing brace could not be located. Pass through unchanged.
      print $oh $line;
    }
    close $ih;
    close $oh;
  ' <(printf '%s' "$updates_tsv") "$metrics_file" "$tmp_out"
  mv "$tmp_out" "$metrics_file"
fi

echo "backfill: $total_rows rows, $sent_count sent, $skipped_count skipped, $errored_count errored" >&2
exit 0
