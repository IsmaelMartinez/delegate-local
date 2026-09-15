#!/usr/bin/env bash
# Stream the delegate metrics JSONL into Loki, one log line per row stamped at
# the row's own `ts`, so the Grafana dashboards can chart the FULL history.
# Tempo cannot: it indexes by ingestion time, so backfilled spans are
# unreachable at their real time. Idempotent via a line-offset watermark (the
# JSONL is append-only), so it is safe to schedule; `--full` re-pushes every
# row, and Loki de-duplicates identical (timestamp, line) entries per stream.
#
# Usage:
#   sync-metrics-to-loki.sh [--full] [--dry-run] [--metrics-file PATH]
#                           [--loki-url URL] [--state-file PATH]
#
# Env (overridden by the matching flags):
#   DELEGATE_LOKI_URL        Loki base URL (default http://localhost:3100)
#   DELEGATE_LOCAL_DATA_DIR  per-user data (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE    metrics JSONL (default <data dir>/metrics.jsonl)
#   DELEGATE_LOKI_STATE      watermark file (default <metrics-file>.loki-sync)
#   DELEGATE_LOKI_TIMEOUT    curl --max-time on the push (default 30)
#
# Exit: 0 on success (including "nothing new to push"), 2 on usage error,
#       1 on missing metrics file / jq / curl, or a failed push.
set -uo pipefail

loki_url="${DELEGATE_LOKI_URL:-http://localhost:3100}"
metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
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
# A watermark past the end means the file was replaced: re-sync from the start.
(( watermark > total_lines )) && watermark=0

if (( watermark >= total_lines )); then
  echo "sync-metrics-to-loki: nothing new to push ($total_lines rows, watermark $watermark)" >&2
  exit 0
fi

start_line=$((watermark + 1))
new_count=$((total_lines - watermark))

# One stream per `source` label; each value is [<ns timestamp string>, <row>].
# The ns timestamp is built as a STRING: 1.7e18 exceeds float64 exact-integer
# range. The JSONL ts is second-granular and Loki drops entries that collide
# on (stream, timestamp), so the 9 sub-second digits are a CONTENT hash of the
# row: content-derived, not line-derived, so a row re-pushed at a different
# file position dedups instead of duplicating (a line-number scheme doubled
# the feedback rows once). Feedback rows are enriched with the parent's
# recipe/tier from a map over the WHOLE file, since the parent may pre-date
# the watermark. The map is keyed by ts, not ref_id, so two parents in one
# second enrich from the same row; the source JSONL is left untouched.
parent_map=$(jq -sc '
  reduce (.[] | select((.source // "delegate") == "delegate" and .ts != null)) as $r
    ({}; .[$r.ts] = {recipe: ($r.recipe // ""), tier: ($r.tier // "")} )
' "$metrics_file")

# pipefail is on, so a torn final line (the sync racing an in-progress append)
# fails the slurp and the batch is retried WITHOUT advancing the watermark,
# rather than pushing an empty payload and skipping every row.
payload=$(tail -n "+$start_line" "$metrics_file" \
  | jq -sc --argjson parents "$parent_map" '
      # Base 31 mod 1e9 keeps every intermediate under 2^53 so jq float64 math
      # is exact; enrichment runs BEFORE hashing so a feedback row hashes the
      # bytes that get pushed.
      def nshash: tojson | explode | reduce .[] as $c (0; ((. * 31) + $c) % 1000000000);
      [ .[]
        | select(.ts != null and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
        # never overwrites a field the row already has
        | ( if (.source // "delegate") == "feedback" and .ref_ts != null and ($parents[.ref_ts] != null)
            then ($parents[.ref_ts] | with_entries(select(.value != ""))) + . else . end ) ]
      | group_by(.source // "delegate")
      | map({
          stream: {service: "delegate-local", source: (.[0].source // "delegate")},
          values: map([
            ((.ts | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | tostring)
              + (("000000000" + (nshash | tostring))[-9:])),
            tojson
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

# Every new row lacked a valid ts: advance the watermark (else they are
# re-scanned forever) but say so.
if [[ "$pushed_rows" == "0" ]]; then
  echo "$total_lines" > "$state_file"
  echo "sync-metrics-to-loki: $new_count new row(s) (lines $start_line..$total_lines) had no pushable entries (missing/invalid ts); skipped, watermark -> $total_lines" >&2
  exit 0
fi

# mktemp, not a $$-suffixed /tmp path: PIDs are guessable on a shared /tmp.
resp_file=$(mktemp)
trap 'rm -f "$resp_file"' EXIT
# The payload goes in on stdin, not argv: a full-history push exceeds the
# ~1 MB ARG_MAX on macOS. -sS, not -s: on a connection failure curl emits
# http_code 000, and -S lets its own error line through to say why.
http_code=$(printf '%s' "$payload" | curl -sS -o "$resp_file" -w '%{http_code}' \
  --max-time "${DELEGATE_LOKI_TIMEOUT:-30}" --connect-timeout 5 \
  -X POST "${loki_url%/}/loki/api/v1/push" \
  -H 'Content-Type: application/json' --data-binary @-)
resp=$(cat "$resp_file" 2>/dev/null)

if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
  echo "$total_lines" > "$state_file"
  # Historical rows are served from the store, so they become queryable only
  # once flushed to a chunk; best-effort, and the result is discarded.
  curl -s -o /dev/null --max-time 5 --connect-timeout 5 \
    -X POST "${loki_url%/}/flush" 2>/dev/null || true
  echo "sync-metrics-to-loki: pushed $pushed_rows rows (lines $start_line..$total_lines) to $loki_url; watermark -> $total_lines" >&2
  exit 0
else
  echo "sync-metrics-to-loki: push failed (HTTP $http_code): $resp" >&2
  echo "sync-metrics-to-loki: watermark unchanged at $watermark — re-run to retry" >&2
  exit 1
fi
