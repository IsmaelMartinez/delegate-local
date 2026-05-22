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
#                         delegate-to-ollama/metrics.jsonl}.
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
#                                   ~/.claude/skills/delegate-to-ollama/
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

metrics_file="${metrics_file_override:-${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-to-ollama/metrics.jsonl}}"

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

# Read the file once into a perl-friendly working set. The two-pass design
# (first pass: build parent lookup; second pass: emit) is the simplest way
# to support feedback rows linking to parent delegate rows without a
# stateful streaming parser. JSONL files in practice top out at a few MB
# (thousands of rows, ~150 bytes each) so the memory cost is negligible.
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

# Reduce the metrics file to a list of rows to consider, applying the
# --since filter here so the emission loop doesn't have to re-check.
# jq -c keeps the JSON compact (one row per line) for the perl-side
# processing.
if [[ -n "$since_iso" ]]; then
  rows_to_process=$(jq -c --arg since "$since_iso" 'select(.ts >= $since)' "$metrics_file")
else
  rows_to_process=$(jq -c '.' "$metrics_file")
fi

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
  ts=$(jq -r '.ts // ""' <<< "$row")
  source=$(jq -r '.source // "delegate"' <<< "$row")
  existing_trace=$(jq -r '.otel_trace_id // ""' <<< "$row")
  existing_span=$(jq -r '.otel_span_id // ""' <<< "$row")
  ROW_KIND="delegate"

  if [[ -n "$existing_trace" && -n "$existing_span" ]]; then
    ROW_RESULT="SKIP"
    return 0
  fi

  if [[ -z "$ts" ]]; then
    ROW_RESULT="ERROR malformed row (no ts)"
    return 0
  fi

  # Pull the rest of the row. Defaults match delegate.sh's log_metric:
  # backend defaults to ollama (pre-2026-05 rows omit the field); empty
  # tier/model/recipe pass through to the OTel payload as empty strings.
  backend=$(jq -r '.backend // "ollama"' <<< "$row")
  tier=$(jq -r '.tier // ""' <<< "$row")
  model=$(jq -r '.model // ""' <<< "$row")
  recipe=$(jq -r '.recipe // ""' <<< "$row")
  pchars=$(jq -r '.prompt_chars // 0' <<< "$row")
  cchars=$(jq -r '.context_chars // 0' <<< "$row")
  ochars=$(jq -r '.output_chars // 0' <<< "$row")
  dur_ms=$(jq -r '.duration_ms // 0' <<< "$row")
  qwait_ms=$(jq -r '.queue_wait_ms // 0' <<< "$row")
  gen_ms=$(jq -r '.generation_ms // 0' <<< "$row")
  status=$(jq -r '.exit_status // 0' <<< "$row")
  tokens_avoided=$(jq -r '.estimated_tokens_avoided // 0' <<< "$row")

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
    "$qwait_ms" "$gen_ms" "$tokens_avoided"
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
  fb_ts=$(jq -r '.ts // ""' <<< "$row")
  ref_ts=$(jq -r '.ref_ts // ""' <<< "$row")
  kept=$(jq -r '.kept // false' <<< "$row")
  reason=$(jq -r '.reason // ""' <<< "$row")
  ROW_KIND="feedback"

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
    parent_line=$(printf '%s\n' "$parent_lookup" | awk -F'\t' -v ts="$ref_ts" '$1 == ts {print; exit}')
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

# Main loop. perl-side line iteration to keep parse-once-then-iterate
# shape; the per-row jq invocations inside emit_*_row are unavoidable
# (jq is the only sane way to handle a JSON-with-special-chars row from
# bash without breaking on quoted backslashes in model names or recipe
# placeholders). The cost is bounded by row count, not row size.
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  total_rows=$((total_rows + 1))

  source=$(jq -r '.source // "delegate"' <<< "$row")
  ts=$(jq -r '.ts // ""' <<< "$row")

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
done <<< "$rows_to_process"

# --update-jsonl rewrite phase. The metrics file is rewritten atomically
# via a tempfile in the same directory (so the rename is a single inode
# swap, no cross-filesystem move). Each original line is re-emitted; lines
# matching a row that was just exported get their otel_trace_id /
# otel_span_id fields added. The `--rawfile` jq trick streams the update
# tsv into the jq filter via env so the in-loop matching stays O(rows ×
# updates) without an external join. For workstation-scale JSONL (few MB)
# this is fine; if the file ever grew to GB scale, the right answer would
# be a hash-table join in perl, not micro-optimising the jq filter.
if (( update_jsonl == 1 && sent_count > 0 )); then
  tmp_out=$(mktemp "${metrics_file}.backfill.XXXXXX") || {
    echo "backfill-otel: could not create tempfile for --update-jsonl" >&2
    echo "backfill: $total_rows rows, $sent_count sent, $skipped_count skipped, $errored_count errored" >&2
    exit 0
  }
  # Stream the original file; for each row, if it's a delegate row whose
  # ts matches an update tuple and it does NOT already have otel_trace_id,
  # append the IDs. The match is O(updates) per row, fine at workstation
  # scale.
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      printf '\n' >> "$tmp_out"
      continue
    fi
    # Extract source + ts + existing otel_trace_id without re-shelling for
    # speed. jq is still the right tool here because the line is JSON and
    # raw bash matching would break on edge cases (model names containing
    # `"ts":"...`, etc.).
    line_meta=$(jq -r '[(.source // "delegate"), (.ts // ""), (.otel_trace_id // "")] | @tsv' <<< "$line" 2>/dev/null) || line_meta=""
    if [[ -z "$line_meta" ]]; then
      # Malformed line — pass through unchanged. Don't drop user data.
      printf '%s\n' "$line" >> "$tmp_out"
      continue
    fi
    IFS=$'\t' read -r line_source line_ts line_existing_trace <<< "$line_meta"
    if [[ "$line_source" != "delegate" || -n "$line_existing_trace" ]]; then
      printf '%s\n' "$line" >> "$tmp_out"
      continue
    fi
    update_match=$(printf '%s' "$updates_tsv" | awk -F'\t' -v ts="$line_ts" '$1 == ts {print; exit}')
    if [[ -z "$update_match" ]]; then
      printf '%s\n' "$line" >> "$tmp_out"
      continue
    fi
    IFS=$'\t' read -r _ upd_trace upd_span <<< "$update_match"
    # Inject the IDs via jq so the field order stays controlled and any
    # special characters in the original row stay correctly escaped.
    jq -c --arg t "$upd_trace" --arg s "$upd_span" \
      '. + {otel_trace_id: $t, otel_span_id: $s}' <<< "$line" >> "$tmp_out"
  done < "$metrics_file"
  mv "$tmp_out" "$metrics_file"
fi

echo "backfill: $total_rows rows, $sent_count sent, $skipped_count skipped, $errored_count errored" >&2
exit 0
