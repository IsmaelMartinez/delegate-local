#!/usr/bin/env bash
# Append a hit/miss feedback event to the delegate metrics JSONL, referencing
# the most recent `source:"delegate"` line. Lets the caller record whether
# they actually used the delegated output (hit) or had to rewrite/discard
# it (miss), with an optional one-line reason.
#
# The file remains append-only — feedback events join the JSONL as their own
# rows, keyed by `ref_ts` to the delegate event they evaluate. `metrics-
# summary.sh` joins them at read time to compute hit-rate per tier / model.
#
# Usage:  delegate-feedback.sh hit|miss [reason words...]
# Env:    DELEGATE_METRICS_FILE   override default metrics path
# Exit:   0 OK, 1 file/event missing, 2 usage error.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-to-ollama/metrics.jsonl}"

usage() {
  echo "usage: delegate-feedback.sh hit|miss [reason words...]" >&2
  echo "  feedback applies to the most recent delegate event in $metrics_file" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage

case "$1" in
  hit)  kept=true ;;
  miss) kept=false ;;
  -h|--help) usage ;;
  *) echo "first arg must be 'hit' or 'miss' (got '$1')" >&2; usage ;;
esac
shift
reason="$*"

[[ -f "$metrics_file" ]] || { echo "metrics file not found: $metrics_file" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Find the most recent delegate event ts. `jq -s` slurps the JSONL into an
# array; we filter and pick the last (highest ts assumed equal to last-line
# order, which holds for an append-only log). Portable across macOS/Linux —
# avoids `tac` which BSD coreutils doesn't ship.
#
# Parens around `(.source // "delegate")` are load-bearing: jq's `//` binds
# looser than `==`, so `.source // "delegate" == "delegate"` parses as
# `.source // ("delegate" == "delegate")` = `.source // true`, which is
# truthy for every event including experiments and feedback rows.
ref_ts=$(jq -sr '[.[] | select((.source // "delegate") == "delegate") | .ts] | last // empty' "$metrics_file")
if [[ -z "$ref_ts" || "$ref_ts" == "null" ]]; then
  echo "no recent delegate event found in $metrics_file" >&2
  exit 1
fi

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build the feedback row. `reason` is omitted when the caller didn't supply
# one so empty-string entries don't pollute future filters.
if [[ -n "$reason" ]]; then
  jq -nc --arg ts "$ts" --arg ref "$ref_ts" --argjson kept "$kept" --arg reason "$reason" \
    '{ts:$ts, source:"feedback", ref_ts:$ref, kept:$kept, reason:$reason}' \
    >> "$metrics_file"
else
  jq -nc --arg ts "$ts" --arg ref "$ref_ts" --argjson kept "$kept" \
    '{ts:$ts, source:"feedback", ref_ts:$ref, kept:$kept}' \
    >> "$metrics_file"
fi

verdict_word=$([[ "$kept" == "true" ]] && echo "HIT" || echo "MISS")
echo "$verdict_word recorded against delegate ts=$ref_ts${reason:+ ($reason)}"
