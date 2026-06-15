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

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"

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
  def call: select(src != "feedback" and src != "opportunity");
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

echo "=== delegate-local metrics ==="
echo "File:                $metrics_file"
echo "Time range:          $ts_first  →  $ts_last"
echo "Total invocations:   $total  (delegate=$n_delegate, experiment=$n_experiment)"
echo "Errors (non-zero):   $errors"
echo "Tokens avoided (≈):  $total_avoided"
echo

# Per-source breakdown: count, tokens avoided, p50/p95 latency. Feedback and
# opportunity events are excluded — they have no duration / token cost and are
# reported in their own sections below.
echo "Per-source:"
jq -rs '
  def src: .source // "delegate";
  map(select(src != "feedback" and src != "opportunity"))
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

# Per-backend rollup (delegate entries only). Only printed when 2+ distinct
# backends appear in the file so single-backend users (the common case
# today) don't see a redundant section. Rows missing the backend field —
# pre-2026-05 delegate rows written before DELEGATE_BACKEND landed — are
# bucketed as `ollama` because that was the only path then.
n_backends=$(jq -rs '
  map(select((.source // "delegate") == "delegate"))
  | map(.backend // "ollama")
  | unique
  | length
' "$metrics_file")
if (( n_backends > 1 )); then
  echo "Per-backend (delegate):"
  jq -rs '
    map(select((.source // "delegate") == "delegate"))
    | group_by(.backend // "ollama")
    | map({
        backend: (.[0].backend // "ollama"),
        n: length,
        tokens: (map(.estimated_tokens_avoided // 0) | add),
        p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms // 0)),
        p95: ((sort_by(.duration_ms) | .[((length * 95 / 100) | floor) | if . >= length then length - 1 else . end] | .duration_ms // 0))
      })
    | sort_by(-.n)
    | .[]
    | "  \(.backend | . + (" " * (10 - length)))  n=\(.n)  tokens≈\(.tokens)  p50=\(.p50)ms  p95=\(.p95)ms"
  ' "$metrics_file"
  echo
fi

# Feedback rollup. Verdict coverage is the recipe-calibration signal, so it is
# scoped to RECIPE delegations (--recipe NAME calls — the unit the recipe library
# self-corrects on). Raw / no-recipe delegations (ad-hoc prose calls plus
# experiment / audit / benchmark sessions run from scratch dirs like `audit`) are
# reported on their own line: their hit/miss verdict is optional and would
# otherwise inflate "untracked" even though they belong to no recipe's calibration
# history. (Benchmark/audit sessions should set DELEGATE_LOCAL_NO_METRICS=1 to stay
# out of the metrics stream entirely; this split is the backstop for ones that
# didn't.) The ref_ts -> kept map is built in one reduce pass; direct $fb_map[.ts]
# access (NOT // false) so a recorded miss (false) isn't coerced back to null and
# dropped, and latest feedback for a delegate wins (verdict revision).
#
# Failed delegations (exit_status != 0 — canary timeout exit 3, flaky-gate exit 4,
# pick-model/dispatch failure exit 1/2) produced no output, so there is nothing to
# judge hit/miss against. Counting them would inflate "untracked" and depress
# coverage with operational failures that belong to the exit_status error metric,
# not the calibration signal. The rollup therefore scopes to exit_status==0 (or
# absent, for pre-exit_status rows) delegations only.
if (( n_feedback > 0 )); then
  echo "Delegation feedback (hit/miss):"
  jq -rs '
    def src: .source // "delegate";
    (reduce (.[] | select(src == "feedback")) as $i ({}; .[$i.ref_ts] = $i.kept)) as $fb_map
    | (map(select(src == "delegate" and (.exit_status // 0) == 0) | {recipe, tier, kept: $fb_map[.ts]})) as $d
    | ($d | map(select(.recipe != null))) as $rx
    | ($d | map(select(.recipe == null))) as $raw
    | ($rx | length) as $rn
    | ($raw | length) as $wn
    | "  Recipe delegations (calibration signal): n=\($rn)  hits=\($rx|map(select(.kept==true))|length)  misses=\($rx|map(select(.kept==false))|length)  untracked=\($rx|map(select(.kept==null))|length)" + (if $rn > 0 then "  coverage=\((($rx|map(select(.kept!=null))|length) * 100 / $rn) | floor)%" else "" end),
      ($rx | group_by(.tier) | map({tier:.[0].tier, n:length, hits:(map(select(.kept==true))|length), misses:(map(select(.kept==false))|length), untracked:(map(select(.kept==null))|length)}) | sort_by(-.n) | .[] | "    \(.tier | . + (" " * (14 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)  untracked=\(.untracked)"),
      (if $wn > 0 then "  Raw / no-recipe (verdicts optional — experiments, audits, ad-hoc): n=\($wn)  tracked=\($raw|map(select(.kept!=null))|length)  untracked=\($raw|map(select(.kept==null))|length)" else empty end)
  ' "$metrics_file"
  echo
fi

# Per-project rollup (delegate entries only): volume, hit/miss/untracked, and
# p50 latency grouped by .project. Rows missing the project field — pre-2026-05
# delegate rows written before delegate.project landed — bucket as "(none)".
# Only printed when 2+ distinct project values appear so single-project users
# (the common case) don't see a noise section. The hit/miss derivation mirrors
# the feedback block: a ref_ts -> kept map built in one reduce pass, then
# direct $fb_map[.ts] access (NOT // false) so a recorded miss (false) isn't
# coerced back to null and dropped.
n_projects=$(jq -rs '
  map(select((.source // "delegate") == "delegate"))
  | map(.project // "(none)")
  | unique
  | length
' "$metrics_file")
if (( n_projects > 1 )); then
  echo "Per-project (delegate):"
  jq -rs '
    def src: .source // "delegate";
    (reduce (.[] | select(src == "feedback")) as $i ({}; .[$i.ref_ts] = $i.kept)) as $fb_map
    | map(select(src == "delegate" and (.exit_status // 0) == 0) | {ts, project: (.project // "(none)"), duration_ms, kept: $fb_map[.ts]})
    | group_by(.project)
    | map({
        project: .[0].project,
        n: length,
        hits: (map(select(.kept == true)) | length),
        misses: (map(select(.kept == false)) | length),
        untracked: (map(select(.kept == null)) | length),
        p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms // 0))
      })
    | sort_by(-.n)
    | .[]
    | "  \(.project | . + (" " * (20 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)  untracked=\(.untracked)  p50=\(.p50)ms"
  ' "$metrics_file"
  echo
fi

# Per-recipe rollup: hit-rate grouped by .recipe across the delegate rows that
# carry a recipe field (i.e. --recipe NAME calls). Only printed when at least
# one recipe row exists. Same feedback-join shape as the per-project block so a
# recorded miss is counted, not dropped. This answers "which recipes underperform."
n_recipe=$(jq -rs '
  map(select((.source // "delegate") == "delegate" and .recipe != null))
  | length
' "$metrics_file")
if (( n_recipe > 0 )); then
  echo "Per-recipe (delegate):"
  jq -rs '
    def src: .source // "delegate";
    (reduce (.[] | select(src == "feedback")) as $i ({}; .[$i.ref_ts] = $i.kept)) as $fb_map
    | map(select(src == "delegate" and .recipe != null and (.exit_status // 0) == 0) | {ts, recipe, kept: $fb_map[.ts]})
    | group_by(.recipe)
    | map({
        recipe: .[0].recipe,
        n: length,
        hits: (map(select(.kept == true)) | length),
        misses: (map(select(.kept == false)) | length),
        untracked: (map(select(.kept == null)) | length)
      })
    | sort_by(-.n)
    | .[]
    | "  \(.recipe | . + (" " * (20 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)  untracked=\(.untracked)"
  ' "$metrics_file"
  echo
fi

# Trigger rate (#277): boundary events (commit / PR / release / comment reply)
# recorded by the delegate-boundary hook. Each source:"opportunity" row is one delegatable
# opportunity; .delegated marks whether a local delegation preceded it inside the
# look-back window. Rate = delegated / opportunities, per project — the
# under-triggering number this signal exists to make visible. Only printed when
# opportunity rows exist (i.e. the boundary hook is installed).
n_opp=$(jq -rs 'map(select((.source // "") == "opportunity")) | length' "$metrics_file")
if (( n_opp > 0 )); then
  echo "Trigger rate (commit/PR/release/comment boundaries):"
  jq -rs '
    map(select((.source // "") == "opportunity"))
    | group_by(.project // "(none)")
    | map({
        project: (.[0].project // "(none)"),
        n: length,
        delegated: (map(select(.delegated == true)) | length),
        missed: (map(select(.delegated == false)) | length)
      })
    | sort_by(-.n)
    | .[]
    | "  \(.project | . + (if length < 20 then " " * (20 - length) else "" end))  opportunities=\(.n)  delegated=\(.delegated)  missed=\(.missed)  rate=\(if .n > 0 then (.delegated * 100 / .n | floor) else 0 end)%"
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
