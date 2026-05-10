#!/usr/bin/env bash
# Append a hit/miss feedback event to the delegate metrics JSONL, referencing
# either the most recent `source:"delegate"` line or a caller-pinned ts.
# Lets the caller record whether they actually used the delegated output
# (hit) or had to rewrite/discard it (miss), with an optional one-line
# reason.
#
# The file remains append-only — feedback events join the JSONL as their own
# rows, keyed by `ref_ts` to the delegate event they evaluate. `metrics-
# summary.sh` joins them at read time to compute hit-rate per tier / model.
#
# Usage:  delegate-feedback.sh [--ts <iso8601>] hit|miss [reason words...]
# Env:
#   DELEGATE_METRICS_FILE             override default metrics path
#   DELEGATE_FEEDBACK_STALE_SECONDS   max age of the implicit "most recent
#                                     delegate row" before this script
#                                     refuses to attach without --ts
#                                     (default 300; set 0 to disable).
# Exit:   0 OK, 1 file/event missing or stale, 2 usage error.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-to-ollama/metrics.jsonl}"
stale_seconds="${DELEGATE_FEEDBACK_STALE_SECONDS:-300}"

usage() {
  cat >&2 <<'EOF'
usage: delegate-feedback.sh [--ts <iso8601>] hit|miss [reason words...]
  Without --ts, the verdict attaches to the most recent delegate row in
  the metrics JSONL — but only if that row is fresh (default 300 s).
  Pass --ts to pin the verdict to a specific delegate row when metrics
  were off, or the delegation was killed before its row was written, or
  enough time has passed that the most recent row is no longer "yours".
EOF
  exit 2
}

# Argument parsing — flags come first, then verdict, then reason.
override_ts=""
while (($# > 0)); do
  case "$1" in
    --ts)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo 'delegate-feedback: --ts requires a value' >&2; exit 2
      fi
      override_ts="$2"; shift 2;;
    --ts=*)
      override_ts="${1#--ts=}"; shift;;
    -h|--help) usage;;
    --) shift; break;;
    *) break;;
  esac
done

[[ $# -ge 1 ]] || usage

case "$1" in
  hit)  kept=true ;;
  miss) kept=false ;;
  *) echo "first arg must be 'hit' or 'miss' (got '$1')" >&2; usage ;;
esac
shift
reason="$*"

[[ -f "$metrics_file" ]] || { echo "metrics file not found: $metrics_file" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Convert ISO 8601 (Y-m-dTH:M:SZ) to epoch seconds. Cross-platform: BSD
# date (macOS) and GNU date have incompatible flag sets; perl Time::Local
# is already a project runtime dep and gives one code path that works on
# both. Returns nothing and exits 1 on a malformed ts so the caller can
# fall back gracefully.
iso_to_epoch() {
  perl -MTime::Local=timegm -e '
    my $ts = shift @ARGV;
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      print timegm($6, $5, $4, $3, $2-1, $1);
    } else {
      exit 1;
    }
  ' "$1"
}

if [[ -n "$override_ts" ]]; then
  # Validate that the override matches an actual delegate row. Without
  # this check, a typoed --ts would silently attach to a non-existent
  # delegation, which the metrics-summary join would then drop.
  match=$(jq -r --arg ts "$override_ts" \
    'select((.source // "delegate") == "delegate" and .ts == $ts) | .ts' \
    "$metrics_file" | head -n 1)
  if [[ -z "$match" || "$match" == "null" ]]; then
    echo "delegate-feedback: --ts $override_ts does not match any delegate row in $metrics_file" >&2
    exit 1
  fi
  ref_ts="$override_ts"
else
  # Find the most recent delegate event ts. Stream the JSONL through jq
  # (no `-s` slurp) and pipe the matching ts column through `tail -n 1`.
  # Parens around `(.source // "delegate")` are load-bearing — see git
  # history for the precedence trap.
  ref_ts=$(jq -r 'select((.source // "delegate") == "delegate") | .ts' "$metrics_file" | tail -n 1)
  if [[ -z "$ref_ts" || "$ref_ts" == "null" ]]; then
    echo "no recent delegate event found in $metrics_file" >&2
    exit 1
  fi
  # Stale-window check: refuse to silently attach to a row that almost
  # certainly isn't the delegation the caller meant. The 5-minute default
  # bounds "I just delegated" without forcing tight clock discipline; set
  # DELEGATE_FEEDBACK_STALE_SECONDS=0 to disable for back-compat scripts.
  if [[ "$stale_seconds" -gt 0 ]]; then
    ref_epoch=$(iso_to_epoch "$ref_ts" 2>/dev/null || true)
    now_epoch=$(date -u +%s)
    if [[ -n "$ref_epoch" ]] && (( now_epoch - ref_epoch > stale_seconds )); then
      age=$(( now_epoch - ref_epoch ))
      cat >&2 <<MSG
delegate-feedback: most recent delegate row is ${age}s old (> ${stale_seconds}s).
  ts=$ref_ts is likely not the delegation you mean. Pass --ts <iso8601>
  to pin the verdict explicitly, or set DELEGATE_FEEDBACK_STALE_SECONDS=0
  to disable this check.
MSG
      exit 1
    fi
  fi
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
