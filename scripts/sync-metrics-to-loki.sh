#!/usr/bin/env bash
# Stream the delegate metrics JSONL into Loki so the Grafana dashboards can
# chart the FULL history. Tempo cannot do this: it indexes blocks by ingestion
# time, so spans backfilled with old timestamps are unreachable at their real
# time (and its metrics generator is forward-only). Loki accepts historical
# timestamps, so one log line per JSONL row — stamped at the row's own `ts` and
# carrying the raw JSON for LogQL `| json` parsing — gives true per-project,
# per-recipe, per-tier trends over the whole 30-day window.
#
# Usage:
#   sync-metrics-to-loki.sh [--full] [--dry-run] [--metrics-file PATH]
#                           [--loki-url URL] [--state-file PATH]
#
# Idempotent via a line-offset watermark (the JSONL is append-only): each run
# pushes only the rows appended since the last successful run, so it is safe to
# schedule (launchd/cron) for ongoing freshness. `--full` ignores the watermark
# and re-pushes every row (Loki de-duplicates identical (timestamp, line)
# entries within a stream, so a full re-sync does not create duplicates).
#
# Env (overridden by the matching flags):
#   DELEGATE_LOKI_URL        Loki base URL. Default http://localhost:3100.
#   DELEGATE_METRICS_FILE    metrics JSONL. Default
#                            ~/.claude/skills/delegate-local/metrics.jsonl.
#   DELEGATE_LOKI_STATE      watermark file. Default <metrics-file>.loki-sync.
#
# Exit: 0 on success (including "nothing new to push"), 2 on usage error,
#       1 on missing metrics file / jq / curl, or a failed push.
set -uo pipefail

loki_url="${DELEGATE_LOKI_URL:-http://localhost:3100}"
metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
state_file=""
full=0
dry_run=0

while (($# > 0)); do
  case "$1" in
    --full) full=1; shift;;
    --dry-run) dry_run=1; shift;;
    --metrics-file)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'sync-metrics-to-loki: --metrics-file requires a path' >&2; exit 2; }
      metrics_file="$2"; shift 2;;
    --metrics-file=*) metrics_file="${1#--metrics-file=}"; shift;;
    --loki-url)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'sync-metrics-to-loki: --loki-url requires a value' >&2; exit 2; }
      loki_url="$2"; shift 2;;
    --loki-url=*) loki_url="${1#--loki-url=}"; shift;;
    --state-file)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'sync-metrics-to-loki: --state-file requires a path' >&2; exit 2; }
      state_file="$2"; shift 2;;
    --state-file=*) state_file="${1#--state-file=}"; shift;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "sync-metrics-to-loki: unknown arg '$1'" >&2; exit 2;;
  esac
done

[[ -f "$metrics_file" ]] || { echo "sync-metrics-to-loki: metrics file not found: $metrics_file" >&2; exit 1; }
command -v jq   >/dev/null || { echo "sync-metrics-to-loki: jq not on PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "sync-metrics-to-loki: curl not on PATH" >&2; exit 1; }
[[ -z "$state_file" ]] && state_file="${metrics_file%.jsonl}.loki-sync"

total_lines=$(grep -c '' "$metrics_file" 2>/dev/null || echo 0)

watermark=0
if (( full == 0 )) && [[ -f "$state_file" ]]; then
  watermark=$(cat "$state_file" 2>/dev/null || echo 0)
  [[ "$watermark" =~ ^[0-9]+$ ]] || watermark=0
fi
# Guard against a truncated/rotated file: if the watermark is past the end,
# the file was replaced — re-sync from the start.
(( watermark > total_lines )) && watermark=0

if (( watermark >= total_lines )); then
  echo "sync-metrics-to-loki: nothing new to push ($total_lines rows, watermark $watermark)" >&2
  exit 0
fi

start_line=$((watermark + 1))
new_count=$((total_lines - watermark))

# Build the Loki push payload from the new rows. One stream per `source` label;
# each value is [<ns timestamp string>, <raw row JSON>].
#
# Two subtleties in the ns timestamp:
#   * It is built as a STRING ("<epoch-seconds>" + 9 sub-second digits) rather
#     than multiplying in jq — 1.7e18 exceeds the float64 exact-integer range
#     and would lose precision / print in scientific notation.
#   * The JSONL `ts` is only second-granularity, and delegate calls cluster
#     (canary preflight, parallel runs, tests) so many rows share a second.
#     Loki drops entries that collide on (stream, timestamp), so a naive
#     "...000000000" sub-second part silently loses all-but-one row per second
#     (observed: 49 of 713 delegate rows survived). We disambiguate by using
#     the row's global line number as the 9-digit sub-second part: unique per
#     row and monotonic with file order (≈ chronological). The 9-digit slice
#     assumes fewer than 1e9 rows in the file (any real metrics JSONL); beyond
#     that the slice would truncate and could re-collide, but a billion-line
#     workstation metrics file is not reachable.
# Feedback rows record only the verdict + parent ref_ts, not the parent's
# recipe/tier — but per-recipe and per-tier HIT-rate are the load-bearing
# calibration signals. Build a (delegate ts -> {recipe, tier}) map from the
# WHOLE file (the parent of a new feedback row may pre-date the watermark) and
# enrich each feedback row by its ref_ts before pushing, so the calibration
# dashboard can group historical verdicts by recipe/tier. This mirrors how the
# OTel feedback span duplicates recipe (#187) — here it is done at sync time so
# the source JSONL is left untouched.
parent_map=$(jq -sc '
  reduce (.[] | select((.source // "delegate") == "delegate" and .ts != null)) as $r
    ({}; .[$r.ts] = {recipe: ($r.recipe // ""), tier: ($r.tier // "")} )
' "$metrics_file")

# pipefail is on, so a malformed/partial row that makes the jq slurp fail
# propagates a non-zero status here. Abort WITHOUT advancing the watermark so
# the batch is retried next run — critical, since a torn final line (the sync
# racing an in-progress delegate.sh append) would otherwise blank the payload,
# get pushed as empty, and silently skip every row in the batch.
payload=$(tail -n "+$start_line" "$metrics_file" \
  | jq -sc --argjson base "$start_line" --argjson parents "$parent_map" '
      [ to_entries[]
        | (.key + $base) as $gln
        | .value
        | select(.ts != null and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
        # enrich feedback rows with the parent recipe/tier (no-op for other
        # sources, and never overwrites a field the row already has)
        | ( if (.source // "delegate") == "feedback" and .ref_ts != null and ($parents[.ref_ts] != null)
            then ($parents[.ref_ts] | with_entries(select(.value != ""))) + . else . end )
        | {row: ., gln: $gln} ]
      | group_by(.row.source // "delegate")
      | map({
          stream: {service: "delegate-local", source: (.[0].row.source // "delegate")},
          values: map([
            ((.row.ts | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | tostring)
              + (("000000000" + (.gln | tostring))[-9:])),
            (.row | tojson)
          ])
        })
      | {streams: .}
    ')
jq_status=$?
if (( jq_status != 0 )); then
  echo "sync-metrics-to-loki: failed to build push payload (a malformed or partial row in lines $start_line..$total_lines?) — watermark left at $watermark, re-run to retry" >&2
  exit 1
fi

pushed_rows=$(printf '%s' "$payload" | jq '[.streams[].values[]?] | length')

if (( dry_run == 1 )); then
  echo "sync-metrics-to-loki: DRY RUN — would push $pushed_rows of $new_count new rows (lines $start_line..$total_lines) to $loki_url" >&2
  printf '%s' "$payload" | jq -c '{streams: [.streams[] | {source: .stream.source, count: (.values | length)}]}' >&2
  exit 0
fi

# Parsed cleanly but no pushable entries — every new row lacked a valid ts and
# cannot be timestamped in Loki. Advance the watermark (else the script re-scans
# them forever) but say so loudly rather than silently.
if [[ "$pushed_rows" == "0" ]]; then
  echo "$total_lines" > "$state_file"
  echo "sync-metrics-to-loki: $new_count new row(s) (lines $start_line..$total_lines) had no pushable entries (missing/invalid ts); skipped, watermark -> $total_lines" >&2
  exit 0
fi

# Unpredictable response-body tempfile (mktemp, not a $$-suffixed /tmp path —
# PIDs are guessable, so a fixed name invites symlink/pre-creation games on a
# shared /tmp). The EXIT trap covers both the success and the failed-push path.
resp_file=$(mktemp)
trap 'rm -f "$resp_file"' EXIT
http_code=$(curl -s -o "$resp_file" -w '%{http_code}' \
  -X POST "${loki_url%/}/loki/api/v1/push" \
  -H 'Content-Type: application/json' --data-binary "$payload")
resp=$(cat "$resp_file" 2>/dev/null)

if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
  echo "$total_lines" > "$state_file"
  # Historical rows (>3h old) are served from the store, not the ingester, so
  # they only become queryable once flushed to a chunk. Trigger a flush so the
  # data is visible immediately rather than after chunk_idle_period. Best-effort:
  # a missing/!supported endpoint never fails the sync.
  curl -s -o /dev/null -X POST "${loki_url%/}/flush" 2>/dev/null || true
  echo "sync-metrics-to-loki: pushed $pushed_rows rows (lines $start_line..$total_lines) to $loki_url; watermark -> $total_lines" >&2
  exit 0
else
  echo "sync-metrics-to-loki: push failed (HTTP $http_code): $resp" >&2
  echo "sync-metrics-to-loki: watermark unchanged at $watermark — re-run to retry" >&2
  exit 1
fi
