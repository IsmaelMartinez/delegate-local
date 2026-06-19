#!/usr/bin/env bash
# fanout-patch-eval.sh — measure whether best-of-N code-patch fan-out beats
# single-shot on a fixture suite WITH genuine single-shot headroom.
#
# For each fixture dir (source.py + test_source.py): run R reps of single-shot
# (one delegate.sh+oracle call) and R reps of best-of-N (fanout-patch.sh), and
# report single-shot pass-rate vs best-of-N pass-rate, lift, latency per fix,
# the best-of-N pass-rate distribution across reps, escalation rate, and
# handback %. The load-bearing requirement (the lesson this initiative is built
# on): fixtures MUST have single-shot headroom — if the model nails every
# fixture single-shot, best-of-N cannot lift anything and the result is a false
# "no value", exactly the trap T5/T6 fell into. tests/test-fanout-fixtures.sh
# guarantees the headroom exists; this harness measures the lift.
#
# Runs with DELEGATE_LOCAL_NO_METRICS=1 so measurement does not pollute the
# production metrics/calibration log.
#
# Usage: fanout-patch-eval.sh [--n N] [--reps R] [--tier T] [--temperature F] <fixtures-dir>
set -uo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fanout="$repo_root/scripts/fanout-patch.sh"
delegate="$repo_root/scripts/delegate.sh"
apply="$repo_root/scripts/apply-and-test.sh"
export DELEGATE_LOCAL_NO_METRICS=1 DELEGATE_BACKEND="${DELEGATE_BACKEND:-ollama}"

n=5 reps=3 tier="code" temperature="0.7" fixtures=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --n) n="$2"; shift 2 ;;
    --reps) reps="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --temperature) temperature="$2"; shift 2 ;;
    -h|--help) echo "usage: fanout-patch-eval.sh [--n N] [--reps R] [--tier T] [--temperature F] <fixtures-dir>"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
fixtures="${1:-}"
[[ -n "$fixtures" && -d "$fixtures" ]] || { echo "usage: fanout-patch-eval.sh [opts] <fixtures-dir>" >&2; exit 2; }

# Gather fixtures once (each must carry source.py + test_source.py).
fxs=()
for d in "$fixtures"/*/; do [[ -f "$d/source.py" && -f "$d/test_source.py" ]] && fxs+=("$d"); done
nfx=${#fxs[@]}
(( nfx > 0 )) || { echo "no fixtures with source.py+test_source.py in $fixtures" >&2; exit 2; }

single_shot() { # fixture-dir seed -> 0 if PASS
  local d="$1" seed="$2" p; p=$(mktemp)
  env DELEGATE_SEED="$seed" DELEGATE_TEMPERATURE="$temperature" "$delegate" --recipe fix-with-test \
    --var source="$(cat "$d/source.py")" --var test="$(cat "$d/test_source.py")" \
    "$tier" "Output ONLY SEARCH/REPLACE blocks. Minimal diff." > "$p" 2>/dev/null
  local v; v=$(bash "$apply" "$d" "$p" 2>/dev/null | sed -n 's/^VERDICT: //p' | head -1)
  rm -f "$p"; [[ "$v" == "PASS" ]]
}

ss_pass=0 ss_total=0 bo_pass=0 bo_total=0 esc=0 handback=0 bo_lat_total=0
rep_min="" rep_max=""
# Per-fixture tallies (parallel indexed arrays — no associative arrays on bash 3.2).
i=0; fss=(); fbo=(); while (( i < nfx )); do fss[$i]=0; fbo[$i]=0; i=$((i+1)); done

# reps in the OUTER loop so each rep yields a best-of-N pass-count we can take the
# min/max of — "report the distribution rather than a single point". SECONDS
# (bash builtin, integer) times each best-of-N call without GNU `date +%s.%N`.
for ((r=1; r<=reps; r++)); do
  rep_bo=0; i=0
  for d in "${fxs[@]}"; do
    ss_total=$((ss_total+1))
    if single_shot "$d" "$r"; then ss_pass=$((ss_pass+1)); fss[$i]=$(( ${fss[$i]} + 1 )); fi
    bo_total=$((bo_total+1))
    t0=$SECONDS
    res=$(bash "$fanout" --n "$n" --tier "$tier" --temperature "$temperature" "$d" 2>/dev/null)
    bo_lat_total=$(( bo_lat_total + (SECONDS - t0) ))
    outcome=$(printf '%s' "$res" | sed -n 's/^FANOUT_RESULT: \([A-Z_]*\).*/\1/p' | head -1)
    case "$outcome" in
      PASS_LOCAL)     bo_pass=$((bo_pass+1)); rep_bo=$((rep_bo+1)); fbo[$i]=$(( ${fbo[$i]} + 1 ));;
      PASS_ESCALATED) bo_pass=$((bo_pass+1)); rep_bo=$((rep_bo+1)); esc=$((esc+1)); fbo[$i]=$(( ${fbo[$i]} + 1 ));;
      *) handback=$((handback+1));;
    esac
    i=$((i+1))
  done
  [[ -z "$rep_min" || "$rep_bo" -lt "$rep_min" ]] && rep_min="$rep_bo"
  [[ -z "$rep_max" || "$rep_bo" -gt "$rep_max" ]] && rep_max="$rep_bo"
  echo "rep $r: best-of-$n $rep_bo/$nfx fixtures passed" >&2
done

i=0
for d in "${fxs[@]}"; do
  echo "$(basename "$d"): single-shot ${fss[$i]}/$reps   best-of-$n ${fbo[$i]}/$reps"
  i=$((i+1))
done

rate() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", (b>0)? a/b : 0}'; }
ss_rate=$(rate "$ss_pass" "$ss_total"); bo_rate=$(rate "$bo_pass" "$bo_total")
echo "----------------------------------------------------------------"
printf 'FANOUT_EVAL_SUMMARY: single_shot=%s best_of_n=%s lift=%s latency_per_fix_s=%s escalation_rate=%s handback_pct=%s rep_bo_min=%s rep_bo_max=%s reps=%d n=%d fixtures=%d\n' \
  "$ss_rate" "$bo_rate" \
  "$(awk -v s="$ss_rate" -v b="$bo_rate" 'BEGIN{printf "%.3f", b-s}')" \
  "$(awk -v t="$bo_lat_total" -v c="$bo_total" 'BEGIN{printf "%.1f", (c>0)? t/c : 0}')" \
  "$(rate "$esc" "$bo_total")" "$(rate "$handback" "$bo_total")" \
  "${rep_min:-0}" "${rep_max:-0}" "$reps" "$n" "$nfx"
