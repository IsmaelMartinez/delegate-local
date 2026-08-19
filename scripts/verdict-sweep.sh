#!/usr/bin/env bash
# Session-end verdict sweep (Phase E). Only ~60% of delegations carry a
# HIT/MISS verdict, which starves the recipe library's calibration signal. This
# scans the metrics JSONL for recent `source:"delegate"` rows that produced
# output (exit_status 0) and have no matching feedback row, lists them as one
# numbered batch, and records each answer by shelling out to the existing
# `delegate-feedback.sh --ts` path — reusing its row write, --ts validation, and
# OTel span rather than reimplementing them. Run it at session close.
#
# It never blocks: it no-ops when there is nothing to verdict, when there is no
# interactive terminal, or when DELEGATE_LOCAL_NO_SWEEP=1. Skipped rows stay
# untracked and may reappear on a later run; recorded ones won't (the next scan
# sees their feedback row), so re-running is idempotent over the tracked set.
#
# Usage:  verdict-sweep.sh [--file PATH] [--calibrate [--sample N]]
#
#   --calibrate  Instead of unjudged rows, offer ones the AGENT graded itself a
#                HIT on and no human has judged, so a human second opinion can
#                measure the self-flattery ADR 0015 warns about. The default
#                mode can never reach these: an agent verdict marks a row
#                tracked. Restricted to agent HITS because that is the only
#                place the bias is observable, and to rows without an agent
#                scaffold verdict because this prompt has no key for that
#                outcome. Widens the default window to 168h (24h holds 2 such
#                rows against 28 at 7d); DELEGATE_SWEEP_WINDOW_HOURS still wins.
#   --sample N   Cap the offer at N rows, most recent first (default 5, 0 = no
#                cap). Recency is the honest bound: outputs are never stored, so
#                you can only judge a delegation you still recall.
# Env:
#   DELEGATE_METRICS_FILE       metrics JSONL (default
#                               ~/.local/share/delegate-local/metrics.jsonl).
#   DELEGATE_LOCAL_DATA_DIR     where per-user data lives
#                               (default ~/.local/share/delegate-local).
#   DELEGATE_SWEEP_WINDOW_HOURS look-back in hours (default 24): a full working
#                               day, without dredging up rows too old to judge.
#   DELEGATE_LOCAL_NO_SWEEP=1   opt out entirely (matches the DELEGATE_LOCAL_NO_*
#                               family).
# Exit: 0 always on the happy/idle/no-op paths; 2 only on a usage error or a
#       missing jq/perl dependency.
set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
calibrate=0
sample=5
# --calibrate widens the default window: 24h holds 2 eligible rows against 28 at
# 7d, and calibration is a periodic retrospective rather than daily hygiene. An
# explicit DELEGATE_SWEEP_WINDOW_HOURS still wins in either mode.
window_env="${DELEGATE_SWEEP_WINDOW_HOURS:-}"
window_hours="${window_env:-24}"

# Validate the window at the env-var boundary: a non-numeric value would make
# perl evaluate it as 0 and silently sweep an empty window.
if ! [[ "$window_hours" =~ ^[0-9]+$ ]]; then
  echo "verdict-sweep: DELEGATE_SWEEP_WINDOW_HOURS must be a non-negative integer, got '$window_hours'" >&2
  exit 2
fi

while (($# > 0)); do
  case "$1" in
    --file)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'verdict-sweep: --file requires a path' >&2; exit 2; }
      metrics_file="$2"; shift 2;;
    --file=*) metrics_file="${1#--file=}"; shift;;
    # Offer rows the AGENT already graded itself a hit on, so a human second
    # opinion can measure the self-flattery ADR 0015 predicts. The default mode
    # can never reach these: an agent verdict marks a row as tracked.
    --calibrate) calibrate=1; shift;;
    --sample)
      if [[ $# -lt 2 || -z "${2:-}" || ! "${2:-}" =~ ^[0-9]+$ ]]; then
        echo 'verdict-sweep: --sample requires a non-negative integer' >&2; exit 2
      fi
      sample="$2"; shift 2;;
    --sample=*)
      sample="${1#--sample=}"
      [[ "$sample" =~ ^[0-9]+$ ]] || { echo 'verdict-sweep: --sample requires a non-negative integer' >&2; exit 2; }
      shift;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "verdict-sweep: unknown arg '$1'" >&2; exit 2;;
  esac
done

(( calibrate )) && [[ -z "$window_env" ]] && window_hours=168

# Opt-out short-circuit (before any file/dep work).
[[ "${DELEGATE_LOCAL_NO_SWEEP:-}" == "1" ]] && exit 0

# A session-close sweep with no metrics file yet is a no-op, not an error.
[[ -f "$metrics_file" ]] || { echo "verdict-sweep: no metrics file at $metrics_file — nothing to sweep." >&2; exit 0; }
command -v jq   >/dev/null || { echo "verdict-sweep: jq not on PATH" >&2; exit 2; }
command -v perl >/dev/null || { echo "verdict-sweep: perl not on PATH" >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Window cutoff as an ISO string — lexicographic compare works on the fixed-width
# YYYY-MM-DDTHH:MM:SSZ format, same property the other scripts rely on. perl for
# the date math (no GNU `date -d` on the BSD baseline).
cutoff_iso=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]*3600))' "$window_hours")

# Untracked = a delegate row that produced output (exit_status 0, or absent on
# pre-exit_status rows) within the window, with no feedback row referencing its
# ts. jq does the set-membership join in one pass.
# The `.ref_ts != null` guard keeps a malformed feedback row (no ref_ts) from
# crashing jq with "Cannot use null as object key". A jq failure on a corrupt
# file surfaces as exit 2 rather than a silent "nothing to sweep".
if (( calibrate )); then
  # Eligible = the agent's LAST verdict is a hit, and no human has judged it.
  # Restricted to hits deliberately: the bias under test is "I used it, so it
  # was good", which is only observable where the agent claimed a hit. An
  # unrestricted recent sample measured 20% agent-hit against 73% lifetime, so
  # it drew four rows in five from cases with no self-flattery left to catch.
  # agent=scaffold is excluded because the prompt has no key for that outcome,
  # so a human verdict on one could only produce a false comparison.
  # sort_by(.ts) is load-bearing: the file has 8 adjacent out-of-order pairs, so
  # a tail would not be "most recent".
  rows=$(jq -rs --arg cutoff "$cutoff_iso" --argjson sample "$sample" '
    def src: .source // "delegate";
    def fbv: if (.scaffold // false) then "scaffold" elif .kept then "hit" else "miss" end;
    (reduce (.[] | select(src == "feedback" and .ref_ts != null and (.verdict_source // "") == "agent")) as $f
       ({}; .[$f.ref_ts] = {v: ($f | fbv), r: ($f.reason // "")})) as $agent
    | (reduce (.[] | select(src == "feedback" and .ref_ts != null and (.verdict_source // "") != "agent")) as $f
       ({}; .[$f.ref_ts] = true)) as $human
    | map(select(src == "delegate"
          and (.ts != null)
          and ((.exit_status // 0) == 0)
          and (.ts >= $cutoff)
          and (($agent[.ts] // null) != null)
          and ($agent[.ts].v == "hit")
          and (($human[.ts] // false) | not)))
    | sort_by(.ts) | reverse
    | (if $sample > 0 then .[0:$sample] else . end)
    | .[]
    | [ .ts, (.recipe // "(bare/no-recipe)"), (.tier // "-"), (.model // "-"),
        ( ($agent[.ts].r // "") | gsub("[\r\n\t]"; " ")
          | if length > 100 then .[0:100] + "…" else . end ) ]
    | @tsv
  ' "$metrics_file") || { echo "verdict-sweep: failed to parse metrics file $metrics_file" >&2; exit 2; }
else
rows=$(jq -rs --arg cutoff "$cutoff_iso" '
  def src: .source // "delegate";
  (reduce (.[] | select(src == "feedback" and .ref_ts != null)) as $f ({}; .[$f.ref_ts] = true)) as $fb
  | map(select(src == "delegate"
        and (.ts != null)
        and ((.exit_status // 0) == 0)
        and (.ts >= $cutoff)
        and ($fb[.ts] | not)))
  | .[]
  | [.ts, (.recipe // "(bare/no-recipe)"), (.tier // "-"), (.model // "-")] | @tsv
' "$metrics_file") || { echo "verdict-sweep: failed to parse metrics file $metrics_file" >&2; exit 2; }
fi

if [[ -z "$rows" ]]; then
  if (( calibrate )); then
    echo "verdict-sweep: no agent-hit delegations awaiting a human verdict in the last ${window_hours}h." >&2
  else
    echo "verdict-sweep: no untracked delegations in the last ${window_hours}h." >&2
  fi
  exit 0
fi

count=$(printf '%s\n' "$rows" | grep -c '')

# Read answers from /dev/tty in real use, or from stdin when a test sets
# DELEGATE_SWEEP_ASSUME_TTY=1 (a real pty can't be driven in CI). With neither a
# tty nor that flag there is no way to ask, so report and no-op rather than block.
if [[ "${DELEGATE_SWEEP_ASSUME_TTY:-}" != "1" && ! -t 0 ]]; then
  if (( calibrate )); then
    echo "verdict-sweep: $count agent-hit delegation(s) awaiting a human verdict in the last ${window_hours}h — run this in an interactive shell (bash scripts/verdict-sweep.sh --calibrate) to record them." >&2
  else
    echo "verdict-sweep: $count untracked delegation(s) in the last ${window_hours}h — run this in an interactive shell (bash scripts/verdict-sweep.sh) to record verdicts." >&2
  fi
  exit 0
fi

# Read the TSV into parallel indexed arrays (bash 3.2: no associative arrays, no
# guaranteed mapfile on the macOS baseline). The here-string keeps the loop in
# the current shell so the arrays persist.
tss=(); recipes=(); tiers=(); models=(); agent_reasons=()
while IFS=$'\t' read -r ts recipe tier model agent_reason; do
  [[ -z "$ts" ]] && continue
  tss+=("$ts"); recipes+=("$recipe"); tiers+=("$tier"); models+=("$model")
  agent_reasons+=("${agent_reason:-}")
done <<< "$rows"

n=${#tss[@]}
if (( calibrate )); then
  echo "verdict-sweep: $n delegation(s) the agent graded itself a HIT on, in the last ${window_hours}h, with no human verdict." >&2
  echo "  You are answering the HUMAN question — was the output good — not whether you agree with the agent." >&2
  echo "  The agent's claim is shown so you know what is being checked." >&2
else
  echo "verdict-sweep: $n untracked delegation(s) in the last ${window_hours}h." >&2
fi
echo "  h = hit (kept the output), m = miss (rewrote/discarded), s = skip, q = quit." >&2

read_answer() {
  if [[ "${DELEGATE_SWEEP_ASSUME_TTY:-}" == "1" ]]; then
    IFS= read -r _ans
  else
    IFS= read -r _ans </dev/tty
  fi
}

recorded=0
skipped=0
i=0
while (( i < n )); do
  ts="${tss[$i]}"
  if (( calibrate )); then
    printf '  [%d/%d] %s  recipe=%s  tier=%s\n' \
      "$((i+1))" "$n" "$ts" "${recipes[$i]}" "${tiers[$i]}" >&2
    if [[ -n "${agent_reasons[$i]}" ]]; then
      printf '          agent said HIT — %s\n' "${agent_reasons[$i]}" >&2
    else
      printf '          agent said HIT — (no reason recorded)\n' >&2
    fi
    printf '          your verdict — h/m/s/q? ' >&2
  else
    printf '  [%d/%d] %s  recipe=%s  tier=%s  model=%s — h/m/s/q? ' \
      "$((i+1))" "$n" "$ts" "${recipes[$i]}" "${tiers[$i]}" "${models[$i]}" >&2
  fi
  _ans=""
  read_answer || _ans="q"
  case "$_ans" in
    h|H|hit)
      DELEGATE_METRICS_FILE="$metrics_file" bash "$script_dir/delegate-feedback.sh" --ts "$ts" hit </dev/null >&2 \
        && recorded=$((recorded+1))
      i=$((i+1));;
    m|M|miss)
      DELEGATE_METRICS_FILE="$metrics_file" bash "$script_dir/delegate-feedback.sh" --ts "$ts" miss </dev/null >&2 \
        && recorded=$((recorded+1))
      i=$((i+1));;
    s|S|skip|"")
      skipped=$((skipped+1)); i=$((i+1));;
    q|Q|quit)
      break;;
    *)
      echo "    unrecognised '$_ans' — answer h, m, s, or q." >&2;;
  esac
done

left=$(( n - recorded - skipped ))
echo "verdict-sweep: recorded $recorded verdict(s), skipped $skipped, $left left untracked." >&2
exit 0
