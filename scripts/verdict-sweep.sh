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
# Usage:  verdict-sweep.sh [--file PATH]
# Env:
#   DELEGATE_METRICS_FILE       metrics JSONL (default
#                               ~/.claude/skills/delegate-local/metrics.jsonl).
#   DELEGATE_SWEEP_WINDOW_HOURS look-back in hours (default 24): a full working
#                               day, without dredging up rows too old to judge.
#   DELEGATE_LOCAL_NO_SWEEP=1   opt out entirely (matches the DELEGATE_LOCAL_NO_*
#                               family).
# Exit: 0 always on the happy/idle/no-op paths; 2 only on a usage error or a
#       missing jq/perl dependency.
set -uo pipefail

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
window_hours="${DELEGATE_SWEEP_WINDOW_HOURS:-24}"

while (($# > 0)); do
  case "$1" in
    --file)
      [[ $# -lt 2 || -z "${2:-}" ]] && { echo 'verdict-sweep: --file requires a path' >&2; exit 2; }
      metrics_file="$2"; shift 2;;
    --file=*) metrics_file="${1#--file=}"; shift;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "verdict-sweep: unknown arg '$1'" >&2; exit 2;;
  esac
done

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
rows=$(jq -rs --arg cutoff "$cutoff_iso" '
  def src: .source // "delegate";
  (reduce (.[] | select(src == "feedback")) as $f ({}; .[$f.ref_ts] = true)) as $fb
  | map(select(src == "delegate"
        and (.ts != null)
        and ((.exit_status // 0) == 0)
        and (.ts >= $cutoff)
        and ($fb[.ts] | not)))
  | .[]
  | [.ts, (.recipe // "(bare/no-recipe)"), (.tier // "-"), (.model // "-")] | @tsv
' "$metrics_file")

if [[ -z "$rows" ]]; then
  echo "verdict-sweep: no untracked delegations in the last ${window_hours}h." >&2
  exit 0
fi

count=$(printf '%s\n' "$rows" | grep -c '')

# Read answers from /dev/tty in real use, or from stdin when a test sets
# DELEGATE_SWEEP_ASSUME_TTY=1 (a real pty can't be driven in CI). With neither a
# tty nor that flag there is no way to ask, so report and no-op rather than block.
if [[ "${DELEGATE_SWEEP_ASSUME_TTY:-}" != "1" && ! -t 0 ]]; then
  echo "verdict-sweep: $count untracked delegation(s) in the last ${window_hours}h — run this in an interactive shell (bash scripts/verdict-sweep.sh) to record verdicts." >&2
  exit 0
fi

# Read the TSV into parallel indexed arrays (bash 3.2: no associative arrays, no
# guaranteed mapfile on the macOS baseline). The here-string keeps the loop in
# the current shell so the arrays persist.
tss=(); recipes=(); tiers=(); models=()
while IFS=$'\t' read -r ts recipe tier model; do
  [[ -z "$ts" ]] && continue
  tss+=("$ts"); recipes+=("$recipe"); tiers+=("$tier"); models+=("$model")
done <<< "$rows"

n=${#tss[@]}
echo "verdict-sweep: $n untracked delegation(s) in the last ${window_hours}h." >&2
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
  printf '  [%d/%d] %s  recipe=%s  tier=%s  model=%s — h/m/s/q? ' \
    "$((i+1))" "$n" "$ts" "${recipes[$i]}" "${tiers[$i]}" "${models[$i]}" >&2
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
