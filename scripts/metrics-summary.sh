#!/usr/bin/env bash
# Read the delegate.sh metrics JSONL and print a summary: volume per tier,
# p50/p95 latency, total tokens-avoided, top models by frequency.
#
# Usage:  metrics-summary.sh [--file path]
# Env:    DELEGATE_METRICS_FILE   override default metrics path
# Exit:   0 OK, 1 file missing, 2 usage error.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-to-ollama/metrics.jsonl}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) metrics_file="$2"; shift 2 ;;
    -h|--help) echo "usage: metrics-summary.sh [--file path]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$metrics_file" ]]; then
  echo "no metrics file at $metrics_file" >&2
  echo "(run delegate.sh at least once, or set DELEGATE_METRICS_FILE)" >&2
  exit 1
fi

command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

total=$(jq -s 'length' "$metrics_file")
if (( total == 0 )); then
  echo "metrics file is empty: $metrics_file"
  exit 0
fi

ts_first=$(jq -rs 'min_by(.ts) | .ts' "$metrics_file")
ts_last=$(jq -rs 'max_by(.ts) | .ts' "$metrics_file")
total_avoided=$(jq -s 'map(.estimated_tokens_avoided) | add' "$metrics_file")
errors=$(jq -s '[.[] | select(.exit_status != 0)] | length' "$metrics_file")

echo "=== delegate-to-ollama metrics ==="
echo "File:                $metrics_file"
echo "Time range:          $ts_first  →  $ts_last"
echo "Total invocations:   $total"
echo "Errors (non-zero):   $errors"
echo "Tokens avoided (≈):  $total_avoided"
echo

echo "Per-tier:"
# For each tier compute count, p50, p95 of duration_ms.
jq -rs '
  group_by(.tier)
  | map({
      tier: .[0].tier,
      n: length,
      p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms)),
      p95: ((sort_by(.duration_ms) | .[((length * 95 / 100) | floor) | if . >= length then length - 1 else . end] | .duration_ms))
    })
  | sort_by(-.n)
  | .[]
  | "  \(.tier | . + (" " * (14 - length)))  n=\(.n)  p50=\(.p50)ms  p95=\(.p95)ms"
' "$metrics_file"
echo

echo "Top models:"
jq -rs '
  group_by(.model)
  | map({model: .[0].model, n: length})
  | sort_by(-.n)
  | .[0:5]
  | .[]
  | "  \(.n)  \(.model)"
' "$metrics_file"
