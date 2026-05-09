#!/usr/bin/env bash
# Read the delegate metrics JSONL and print a summary: per-source breakdown
# (delegate = interactive calls via scripts/delegate.sh, experiment = runner
# traffic via experiments/lib/run_api_cell.sh), per-tier or per-session
# rollup, and top models. Entries missing a `source` field are treated as
# `delegate` for backward compatibility with lines written before the
# source field landed.
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

# Headline + existence checks in a single jq pass so big metrics files are
# read once, not three times. Feedback events (`source:"feedback"`) are
# excluded from token / latency / model rollups — they're zero-cost
# annotations on prior delegate events, surfaced separately below.
IFS=$'\t' read -r ts_first ts_last total_avoided errors n_delegate n_experiment n_tier n_session n_feedback < <(jq -rs '
  def src: .source // "delegate";
  def call: select(src != "feedback");
  [
    (map(call) | min_by(.ts) | .ts),
    (map(call) | max_by(.ts) | .ts),
    (map(call | .estimated_tokens_avoided) | add),
    (map(call | select(.exit_status != 0)) | length),
    (map(call | select(src == "delegate")) | length),
    (map(call | select(src == "experiment")) | length),
    (map(call | select(.tier != null)) | length),
    (map(call | select(.session != null)) | length),
    (map(select(src == "feedback")) | length)
  ] | @tsv' "$metrics_file")

echo "=== delegate-to-ollama metrics ==="
echo "File:                $metrics_file"
echo "Time range:          $ts_first  →  $ts_last"
echo "Total invocations:   $total  (delegate=$n_delegate, experiment=$n_experiment)"
echo "Errors (non-zero):   $errors"
echo "Tokens avoided (≈):  $total_avoided"
echo

# Per-source breakdown: count, tokens avoided, p50/p95 latency. Feedback
# events are excluded — they have no duration / token cost and are reported
# in their own section below.
echo "Per-source:"
jq -rs '
  def src: .source // "delegate";
  map(select(src != "feedback"))
  | group_by(src)
  | map({
      source: (.[0] | src),
      n: length,
      tokens: (map(.estimated_tokens_avoided) | add),
      p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms)),
      p95: ((sort_by(.duration_ms) | .[((length * 95 / 100) | floor) | if . >= length then length - 1 else . end] | .duration_ms))
    })
  | sort_by(-.n)
  | .[]
  | "  \(.source | . + (" " * (12 - length)))  n=\(.n)  tokens≈\(.tokens)  p50=\(.p50)ms  p95=\(.p95)ms"
' "$metrics_file"
echo

# Feedback rollup: hit-rate per delegate-tier across delegate events that
# have a feedback row referring to them. Untracked = delegate events with
# no feedback recorded yet.
if (( n_feedback > 0 )); then
  echo "Delegation feedback (hit/miss):"
  jq -rs '
    def src: .source // "delegate";
    . as $all
    | (map(select(src == "feedback") | {ref_ts, kept})) as $fb
    | (map(select(src == "delegate")) | map({ts, tier, model})) as $dels
    | $dels
    | map(
        . as $d
        | ($fb | map(select(.ref_ts == $d.ts)) | first) as $f
        # Cannot use the // operator here: false // null evaluates to null
        # because // treats false as "not present", which would silently drop
        # every miss. Branch on whether $f is null instead.
        | $d + {kept: (if $f == null then null else $f.kept end)}
      )
    | group_by(.tier)
    | map({
        tier: .[0].tier,
        n: length,
        hits: (map(select(.kept == true)) | length),
        misses: (map(select(.kept == false)) | length),
        untracked: (map(select(.kept == null)) | length)
      })
    | sort_by(-.n)
    | .[]
    | "  \(.tier | . + (" " * (14 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)  untracked=\(.untracked)"
  ' "$metrics_file"
  echo
fi

# Per-tier (delegate entries only have tier; experiment entries have session).
if (( n_tier > 0 )); then
  echo "Per-tier (delegate):"
  jq -rs '
    map(select((.source // "delegate") != "feedback" and .tier != null))
    | group_by(.tier)
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
fi

if (( n_session > 0 )); then
  echo "Per-session (experiment):"
  jq -rs '
    map(select(.session != null))
    | group_by(.session)
    | map({session: .[0].session, n: length, ms: (map(.duration_ms) | add)})
    | sort_by(-.n)
    | .[]
    | "  n=\(.n)  total=\(.ms)ms  \(.session)"
  ' "$metrics_file"
  echo
fi

echo "Top models:"
jq -rs '
  map(select((.source // "delegate") != "feedback"))
  | group_by(.model)
  | map({model: .[0].model, n: length})
  | sort_by(-.n)
  | .[0:5]
  | .[]
  | "  \(.n)  \(.model)"
' "$metrics_file"
