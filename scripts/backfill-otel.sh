#!/usr/bin/env bash
# Walk the delegate metrics JSONL and emit one OTLP/HTTP span per row to
# ${DELEGATE_OTEL_ENDPOINT} (ADR 0007). Row-level idempotent: rows already
# exported live (otel_trace_id present) are skipped, and pre-exporter rows
# get IDs derived from sha256/sha1(ts|source) so re-runs collide in the
# collector's ID space. A feedback row links to its parent by the same
# derivation, or by the parent's live IDs when it has them.
#
# Usage:
#   backfill-otel.sh [--since <iso8601>] [--dry-run] [--metrics-file PATH]
#                    [--update-jsonl]
#
# Flags:
#   --since <iso8601>     only rows with ts >= iso (UTC, Z suffix)
#   --dry-run             print one line per row, no HTTP calls
#   --metrics-file PATH   override the metrics JSONL location
#   --update-jsonl        after a successful POST, write the computed IDs back
#                         to the row (atomic tempfile-and-rename) so later
#                         runs take the SKIP path; off by default
#
# Env:
#   DELEGATE_OTEL_ENDPOINT      required unless --dry-run
#   DELEGATE_OTEL_HEADERS       comma-separated header pairs, values url-encoded
#   DELEGATE_OTEL_TIMEOUT       curl --max-time per POST (default 5)
#   DELEGATE_OTEL_VERBOSE=1     log per-POST failures to stderr
#   DELEGATE_LOCAL_DATA_DIR     per-user data (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE       overridden by --metrics-file
#
# Output:  per-row progress on stderr (`OK`, `SKIP`, `ERROR ts=... (<reason>)`)
#          and a final `backfill: N rows, M sent, K skipped, L errored`.
# Exit:    0 on success (best-effort: errored rows do not fail the run), 2 on
#          usage error, 1 on a missing metrics file or endpoint.

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

metrics_file="${metrics_file_override:-${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}}"

[[ -f "$metrics_file" ]] || { echo "backfill-otel: metrics file not found: $metrics_file" >&2; exit 1; }
command -v jq >/dev/null || { echo "backfill-otel: jq not on PATH" >&2; exit 2; }
command -v perl >/dev/null || { echo "backfill-otel: perl not on PATH" >&2; exit 2; }

if (( dry_run == 0 )) && [[ -z "${DELEGATE_OTEL_ENDPOINT:-}" ]]; then
  echo 'backfill-otel: DELEGATE_OTEL_ENDPOINT is not set' >&2
  echo '         Either set it to the OTLP/HTTP traces URL, or pass --dry-run' >&2
  echo '         to preview what would be sent.' >&2
  exit 1
fi

# Cheap shape check; "2026-05-22" without the T...Z suffix would otherwise
# match no rows.
if [[ -n "$since_iso" ]]; then
  if ! [[ "$since_iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "backfill-otel: --since must be ISO 8601 like 2026-05-22T12:34:56Z (got '$since_iso')" >&2
    exit 2
  fi
fi

# Two passes (parent lookup, then emit) so feedback rows can link to their
# parent without a stateful streaming parser. Keyed by ts alone: two
# delegate rows in one second would alias, an accepted edge case.
parent_lookup=$(jq -rc '
  select((.source // "delegate") == "delegate") |
  [.ts, (.model // ""), (.otel_trace_id // ""), (.otel_span_id // "")] |
  @tsv
' "$metrics_file")

total_rows=0
sent_count=0
skipped_count=0
errored_count=0

# --update-jsonl tuples, applied in one rewrite after the loop: a script
# killed mid-emit leaves the JSONL untouched, and the next run re-derives
# the same IDs.
updates_tsv=""

# Per-row results travel via globals: bash 3.2 has no clean multi-value return.
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
  local pchars cchars ochars dur_ms qwait_ms gen_ms status tokens_avoided retry_chars
  local existing_trace existing_span
  ROW_KIND="delegate"

  # One jq call per row, not one per field. Unit Separator (0x1F), not tab:
  # `read` with a whitespace IFS collapses adjacent separators, so empty
  # fields would disappear; 0x1F cannot appear in any source value. The
  # field order here MUST match the `read -r` below.
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
    .project // "",
    .retry_chars // ""
  ] | map(tostring) | join("\u001f")' <<< "$row")
  IFS=$'\x1f' read -r ts source backend tier model recipe \
    pchars cchars ochars dur_ms qwait_ms gen_ms status tokens_avoided \
    existing_trace existing_span project retry_chars <<< "$fields"

  if [[ -n "$existing_trace" && -n "$existing_span" ]]; then
    ROW_RESULT="SKIP"
    return 0
  fi

  if [[ -z "$ts" ]]; then
    ROW_RESULT="ERROR malformed row (no ts)"
    return 0
  fi

  # Rows older than the queue split have only duration_ms; attribute it all
  # to generation_ms so the two still sum to duration_ms.
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

  # Second precision is all the JSONL retains; good enough for history.
  local start_ms
  start_ms=$(iso_to_epoch_ms "$ts") || {
    ROW_RESULT="ERROR ts parse failed"
    return 0
  }

  if (( dry_run == 1 )); then
    ROW_RESULT="OK"
    return 0
  fi

  # The lib swallows curl's exit code by design, so a misconfigured endpoint
  # surfaces only in its verbose mode; ERROR here means an upstream condition.
  emit_otel_span "$start_ms" "$dur_ms" "$status" "$trace_id" "$span_id" \
    "$model" "$backend" "$tier" "$recipe" "$pchars" "$cchars" "$ochars" \
    "$qwait_ms" "$gen_ms" "$tokens_avoided" "" "" "" "$project" "$retry_chars"
  ROW_RESULT="OK"
  return 0
}

# emit_feedback_row <row_json>
#   Process one source:"feedback" row, linked to its parent by ref_ts. No
#   skip path of its own: the span ID is derived from (ts, source), so the
#   collector dedups a re-emit.
emit_feedback_row() {
  local row="$1"
  local fb_ts ref_ts kept reason verdict project verdict_source
  ROW_KIND="feedback"

  # Same one-call, 0x1F-separated extraction as emit_delegate_row; an empty
  # reason must round-trip as a real empty field.
  local fields
  fields=$(jq -r '[
    .ts // "",
    .ref_ts // "",
    (.kept // false | tostring),
    .reason // "",
    .project // "",
    (.verdict_source // "agent")
  ] | join("\u001f")' <<< "$row")
  IFS=$'\x1f' read -r fb_ts ref_ts kept reason project verdict_source <<< "$fields"

  if [[ -z "$fb_ts" ]]; then
    ROW_RESULT="ERROR malformed feedback row (no ts)"
    return 0
  fi

  if [[ "$kept" == "true" ]]; then
    verdict="hit"
  else
    verdict="miss"
  fi

  # Deterministic from (ts, "feedback") so re-runs collide in the collector.
  local fb_ids fb_trace fb_span
  fb_ids=$(otel_deterministic_ids "$fb_ts" "feedback") || {
    ROW_RESULT="ERROR feedback id derivation failed"
    return 0
  }
  IFS=$'\t' read -r fb_trace fb_span <<< "$fb_ids"
  ROW_TRACE="$fb_trace"
  ROW_SPAN="$fb_span"

  # Parent IDs: live ones when the parent has them, else the same derivation
  # the delegate-row path uses.
  local parent_line parent_model parent_existing_trace parent_existing_span
  local parent_trace parent_span
  parent_trace=""
  parent_span=""
  parent_model=""
  if [[ -n "$ref_ts" ]]; then
    # Fixed-string match on the ts plus a literal tab, so a prefix cannot
    # false-match; -m1 stops at the first hit.
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
  # An unknown parent leaves the IDs empty and the `links` array is omitted.

  if (( dry_run == 1 )); then
    ROW_RESULT="OK"
    return 0
  fi

  # parent_recipe is left empty (the lookup carries no recipe); a row that
  # pre-dates verdict_source is the agent's like every other (ADR 0030).
  emit_otel_feedback_span_with_ids "$fb_trace" "$fb_span" \
    "$fb_ts" "$verdict" "$reason" "$parent_trace" "$parent_span" "$parent_model" "" "$project" "$verdict_source"
  ROW_RESULT="OK"
  return 0
}

# iso_to_epoch_ms <iso8601>
#   JSONL ts to epoch milliseconds; the JSONL retains second precision only.
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

# Rows stream from one jq pass through process substitution, bounding memory
# at the row size and avoiding ARG_MAX; each line is "<source>\t<ts>\t<row>"
# so the loop never re-invokes jq to discriminate source. The --since filter
# runs inside the same pass.
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
      # experiment rows and future sources: skip without an error count.
      ROW_RESULT="SKIP"
      ROW_KIND="$source"
      ;;
  esac

  case "$ROW_RESULT" in
    OK)
      sent_count=$((sent_count + 1))
      echo "OK ts=$ts ($ROW_KIND)" >&2
      # Only just-exported delegate rows are written back; feedback IDs are
      # recomputed from (ts, source) on every run.
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

# --update-jsonl rewrite: a tempfile in the same directory so the rename is
# one inode swap, in a single perl pass. Keys are spliced before the closing
# brace, which relies on the row being flat `jq -nc` output; any other line
# passes through verbatim. Concurrent appends are not coordinated: the
# second writer wins per `mv` semantics, accepted at workstation scale.
if (( update_jsonl == 1 && sent_count > 0 )); then
  tmp_out=$(mktemp "${metrics_file}.backfill.XXXXXX") || {
    echo "backfill-otel: could not create tempfile for --update-jsonl" >&2
    echo "backfill: $total_rows rows, $sent_count sent, $skipped_count skipped, $errored_count errored" >&2
    exit 0
  }

  # updates_tsv arrives as a file (process substitution); the metrics file
  # and the output path are positional.
  perl -e '
    use strict; use warnings;
    my $updates_path = shift @ARGV;
    my $metrics_path = shift @ARGV;
    my $out_path = shift @ARGV;
    # ts -> "trace\tspan" hash from the updates file.
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
    # One regex per line, never a JSON parse, which relies on the flat
    # jq -nc shape delegate.sh writes.
    open(my $ih, "<", $metrics_path) or die "open metrics: $!";
    open(my $oh, ">", $out_path) or die "open out: $!";
    while (my $line = <$ih>) {
      # Preserve blank lines exactly.
      if ($line =~ /^\s*$/) { print $oh $line; next; }
      # Not a delegate row, or already carrying otel_trace_id: pass through.
      if ($line =~ /"source":"feedback"/ || $line =~ /"source":"experiment"/) {
        print $oh $line; next;
      }
      if ($line =~ /"otel_trace_id":/) { print $oh $line; next; }
      if ($line =~ /"ts":"([^"]+)"/) {
        my $ts = $1;
        if (exists $updates{$ts}) {
          # Splice before the final brace, keeping the trailing newline.
          my $injected = $updates{$ts};
          if ($line =~ s/\}(\s*)$/,${injected}\}$1/) {
            print $oh $line;
            next;
          }
        }
      }
      # Fall-through: pass through unchanged.
      print $oh $line;
    }
    close $ih;
    close $oh;
  ' <(printf '%s' "$updates_tsv") "$metrics_file" "$tmp_out"
  mv "$tmp_out" "$metrics_file"
fi

echo "backfill: $total_rows rows, $sent_count sent, $skipped_count skipped, $errored_count errored" >&2
exit 0
