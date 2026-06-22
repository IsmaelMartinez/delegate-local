#!/usr/bin/env bash
# Read the delegate metrics JSONL and print a summary: per-source breakdown
# (delegate = interactive calls via scripts/delegate.sh, experiment = runner
# traffic via experiments/lib/run_api_cell.sh), per-tier or per-session
# rollup, and top models. Entries missing a `source` field are treated as
# `delegate` for backward compatibility with lines written before the
# source field landed.
#
# Usage:  metrics-summary.sh [--file path] [--since YYYY-MM-DD|ISO-8601] [--days N]
#         --since / --days restrict every section to rows at or after the cutoff
#         (a windowed view of recent activity; --days N == "the last N days").
# Env:    DELEGATE_METRICS_FILE   override default metrics path
# Exit:   0 OK, 1 file missing, 2 usage error.

set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
since=""
days=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) [[ $# -ge 2 ]] || { echo "--file requires a path" >&2; exit 2; }; metrics_file="$2"; shift 2 ;;
    --since) [[ $# -ge 2 ]] || { echo "--since requires a value (YYYY-MM-DD or ISO-8601)" >&2; exit 2; }; since="$2"; shift 2 ;;
    --days) [[ $# -ge 2 ]] || { echo "--days requires a positive integer" >&2; exit 2; }; days="$2"; shift 2 ;;
    -h|--help) echo "usage: metrics-summary.sh [--file path] [--since YYYY-MM-DD|ISO] [--days N]"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$metrics_file" ]]; then
  echo "no metrics file at $metrics_file" >&2
  echo "(run delegate.sh at least once, or set DELEGATE_METRICS_FILE)" >&2
  exit 1
fi

command -v jq >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

# Optional time window. --since DATE|ISO or --days N restricts every section
# below to rows at or after the cutoff. The cutoff is resolved with jq (now /
# fromdateiso8601) rather than `date` arithmetic so there is no BSD-vs-GNU epoch
# portability split. Matching rows are filtered once into a temp file; every
# downstream jq pass then reads that file unchanged.
display_file="$metrics_file"
window_active=0
cutoff_iso=""
orig_total=0
if [[ -n "$since" || -n "$days" ]]; then
  if [[ -n "$since" && -n "$days" ]]; then
    echo "use either --since or --days, not both" >&2; exit 2
  fi
  if [[ -n "$days" ]]; then
    [[ "$days" =~ ^[0-9]+$ && "$days" -gt 0 ]] \
      || { echo "--days takes a positive integer, got '$days'" >&2; exit 2; }
    # We generate the cutoff, so its epoch and ISO form come from one jq pass —
    # no second jq to re-parse a self-generated timestamp. The error path below
    # is --since-only because a generated cutoff cannot be invalid.
    IFS=$'\t' read -r cutoff_epoch cutoff_iso \
      < <(jq -rn --argjson d "$days" '((now | floor) - ($d * 86400)) | [., todateiso8601] | @tsv')
  else
    case "$since" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) cutoff_iso="${since}T00:00:00Z" ;;
      *) cutoff_iso="$since" ;;
    esac
    cutoff_epoch=$(jq -rn --arg c "$cutoff_iso" '$c | fromdateiso8601' 2>/dev/null) \
      || { echo "invalid --since value '$since' (use YYYY-MM-DD or an ISO-8601 timestamp)" >&2; exit 2; }
  fi
  orig_total=$(jq -s 'length' "$metrics_file")
  filtered=$(mktemp "${TMPDIR:-/tmp}/delegate-metrics.XXXXXX") \
    || { echo "cannot create temp file for the metrics window" >&2; exit 2; }
  trap 'rm -f "$filtered"' EXIT
  jq -c --argjson cutoff "$cutoff_epoch" \
    'select(((.ts // "") | fromdateiso8601?) >= $cutoff)' "$metrics_file" > "$filtered"
  metrics_file="$filtered"
  window_active=1
fi

total=$(jq -s 'length' "$metrics_file")
if (( total == 0 )); then
  if (( window_active )); then
    echo "no rows in window (since $cutoff_iso) — $orig_total total rows in $display_file"
  else
    echo "metrics file is empty: $metrics_file"
  fi
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
echo "File:                $display_file"
(( window_active )) && echo "Window:              since $cutoff_iso  ($total of $orig_total rows)"
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
# Agent-observed verdict tier (Phase E). Feedback rows carry verdict_source:
# "agent" when the agent auto-recorded whether it used its own delegated output;
# a human (or pre-tier legacy) verdict omits the field. The two tiers are kept
# separate: the headline hit-rate counts HUMAN verdicts only (so the quality
# signal stays a maintainer taste judgment), while coverage and "untracked"
# count BOTH tiers (so auto-recorded verdicts close the tracking gap). The agent
# column and the dedicated agent-observed line are shown only when at least one
# agent verdict exists, so single-tier files (the common case today) print
# exactly as before. ADR 0015 covers why the tiers stay separate.
# n_agent is guaranteed 0 when there are no feedback rows, so the scan only runs
# inside the n_feedback>0 guard; the per-project / per-recipe blocks below read
# n_agent too, hence the unconditional 0 initialiser.
# n_scaffold mirrors n_agent: a feedback row carries scaffold:true when the
# verdict is the third "discarded but useful" outcome (G1). The scaffold column
# is shown only when at least one scaffold verdict exists, so files without any
# (every legacy file, and the common case today) print exactly as before. The
# counters AND the show_* gates are initialised unconditionally because the
# per-project / per-recipe blocks below read them outside the n_feedback>0 guard
# (set -u safety). Both counts come from a single jq pass over the feedback rows.
n_agent=0
n_scaffold=0
show_agent=false
show_scaffold=false
if (( n_feedback > 0 )); then
  IFS=$'\t' read -r n_agent n_scaffold < <(jq -rs '
    map(select((.source // "") == "feedback"))
    | [ (map(select((.verdict_source // "human") == "agent")) | length),
        (map(select((.scaffold // false) == true)) | length) ]
    | @tsv' "$metrics_file")
  (( n_agent > 0 )) && show_agent=true
  (( n_scaffold > 0 )) && show_scaffold=true
  echo "Delegation feedback (hit/miss):"
  jq -rs --argjson show_agent "$show_agent" \
         --argjson show_scaffold "$show_scaffold" '
    def src: .source // "delegate";
    # fbv maps a feedback row to its verdict string. scaffold (the discarded-
    # but-useful third outcome, G1) is checked first because it also carries
    # kept:false; a legacy row with no scaffold field falls through to the
    # hit/miss read of kept, so historical rows derive exactly as before.
    def fbv: if (.scaffold // false) then "scaffold" elif .kept then "hit" else "miss" end;
    # Two maps: human (verdict_source absent/human) and agent. Latest verdict in
    # each tier wins independently (verdict revision). A delegation can carry
    # both a human and an agent verdict — they count in separate columns, never
    # merged, so the human hit-rate cannot be inflated by the agent tier.
    (reduce (.[] | select(src == "feedback" and (.verdict_source // "human") == "human")) as $i ({}; .[$i.ref_ts] = ($i | fbv))) as $hmap
    | (reduce (.[] | select(src == "feedback" and (.verdict_source // "human") == "agent")) as $i ({}; .[$i.ref_ts] = ($i | fbv))) as $amap
    | (map(select(src == "delegate" and (.exit_status // 0) == 0) | {recipe, tier, h: $hmap[.ts], a: $amap[.ts]})) as $d
    | ($d | map(select(.recipe != null))) as $rx
    | ($d | map(select(.recipe == null))) as $raw
    | ($rx | length) as $rn
    | ($raw | length) as $wn
    | ($rx | map(select(.a != null)) | length) as $an
    | "  Recipe delegations (calibration signal): n=\($rn)  hits=\($rx|map(select(.h=="hit"))|length)  misses=\($rx|map(select(.h=="miss"))|length)" + (if $show_scaffold then "  scaffold=\($rx|map(select(.h=="scaffold"))|length)" else "" end) + (if $show_agent then "  agent=\($an)" else "" end) + "  untracked=\($rx|map(select(.h==null and .a==null))|length)" + (if $rn > 0 then "  coverage=\((($rx|map(select(.h!=null or .a!=null))|length) * 100 / $rn) | floor)%" else "" end),
      ($rx | group_by(.tier) | map({tier:.[0].tier, n:length, hits:(map(select(.h=="hit"))|length), misses:(map(select(.h=="miss"))|length), scaffold:(map(select(.h=="scaffold"))|length), agent:(map(select(.a!=null))|length), untracked:(map(select(.h==null and .a==null))|length)}) | sort_by(-.n) | .[] | "    \(.tier | . + (" " * (14 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + (if $show_agent then "  agent=\(.agent)" else "" end) + "  untracked=\(.untracked)"),
      (if $show_agent then "  Agent-observed (usage, not quality): n=\($an)  used=\($rx|map(select(.a=="hit"))|length)  rewrote=\($rx|map(select(.a=="miss"))|length)" + (if $show_scaffold then "  scaffold=\($rx|map(select(.a=="scaffold"))|length)" else "" end) + (if $an > 0 then "  usage_rate=\((($rx|map(select(.a=="hit"))|length) * 100 / $an) | floor)%" else "" end) else empty end),
      (if $wn > 0 then "  Raw / no-recipe (verdicts optional — experiments, audits, ad-hoc): n=\($wn)  tracked=\($raw|map(select(.h!=null or .a!=null))|length)  untracked=\($raw|map(select(.h==null and .a==null))|length)" else empty end)
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
  map(select((.source // "delegate") == "delegate" and (.exit_status // 0) == 0))
  | map(.project // "(none)")
  | unique
  | length
' "$metrics_file")
if (( n_projects > 1 )); then
  echo "Per-project (delegate):"
  jq -rs --argjson show_agent "$show_agent" \
         --argjson show_scaffold "$show_scaffold" '
    def src: .source // "delegate";
    def fbv: if (.scaffold // false) then "scaffold" elif .kept then "hit" else "miss" end;
    (reduce (.[] | select(src == "feedback" and (.verdict_source // "human") == "human")) as $i ({}; .[$i.ref_ts] = ($i | fbv))) as $hmap
    | (reduce (.[] | select(src == "feedback" and (.verdict_source // "human") == "agent")) as $i ({}; .[$i.ref_ts] = ($i | fbv))) as $amap
    | map(select(src == "delegate" and (.exit_status // 0) == 0) | {ts, project: (.project // "(none)"), duration_ms, h: $hmap[.ts], a: $amap[.ts]})
    | group_by(.project)
    | map({
        project: .[0].project,
        n: length,
        hits: (map(select(.h == "hit")) | length),
        misses: (map(select(.h == "miss")) | length),
        scaffold: (map(select(.h == "scaffold")) | length),
        agent: (map(select(.a != null)) | length),
        untracked: (map(select(.h == null and .a == null)) | length),
        p50: ((sort_by(.duration_ms) | .[(length / 2 | floor)] | .duration_ms // 0))
      })
    | sort_by(-.n)
    | .[]
    | "  \(.project | . + (" " * (20 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + (if $show_agent then "  agent=\(.agent)" else "" end) + "  untracked=\(.untracked)  p50=\(.p50)ms"
  ' "$metrics_file"
  echo
fi

# Per-recipe rollup: hit-rate grouped by .recipe across the delegate rows that
# carry a recipe field (i.e. --recipe NAME calls). Only printed when at least
# one recipe row exists. Same feedback-join shape as the per-project block so a
# recorded miss is counted, not dropped. This answers "which recipes underperform."
n_recipe=$(jq -rs '
  map(select((.source // "delegate") == "delegate" and .recipe != null and (.exit_status // 0) == 0))
  | length
' "$metrics_file")
if (( n_recipe > 0 )); then
  echo "Per-recipe (delegate):"
  jq -rs --argjson show_agent "$show_agent" \
         --argjson show_scaffold "$show_scaffold" '
    def src: .source // "delegate";
    def fbv: if (.scaffold // false) then "scaffold" elif .kept then "hit" else "miss" end;
    (reduce (.[] | select(src == "feedback" and (.verdict_source // "human") == "human")) as $i ({}; .[$i.ref_ts] = ($i | fbv))) as $hmap
    | (reduce (.[] | select(src == "feedback" and (.verdict_source // "human") == "agent")) as $i ({}; .[$i.ref_ts] = ($i | fbv))) as $amap
    | map(select(src == "delegate" and .recipe != null and (.exit_status // 0) == 0) | {ts, recipe, h: $hmap[.ts], a: $amap[.ts]})
    | group_by(.recipe)
    | map({
        recipe: .[0].recipe,
        n: length,
        hits: (map(select(.h == "hit")) | length),
        misses: (map(select(.h == "miss")) | length),
        scaffold: (map(select(.h == "scaffold")) | length),
        agent: (map(select(.a != null)) | length),
        untracked: (map(select(.h == null and .a == null)) | length)
      })
    | sort_by(-.n)
    | .[]
    | "  \(.recipe | . + (" " * (20 - length)))  n=\(.n)  hits=\(.hits)  misses=\(.misses)" + (if $show_scaffold then "  scaffold=\(.scaffold)" else "" end) + (if $show_agent then "  agent=\(.agent)" else "" end) + "  untracked=\(.untracked)"
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
