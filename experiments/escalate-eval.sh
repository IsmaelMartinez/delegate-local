#!/usr/bin/env bash
# escalate-eval.sh — PROTOTYPE evaluation of verify-and-escalate delegation.
#
# Premise (see docs/adr/0019-verify-and-escalate.md): instead of fan-out (ADR
# 0018, which gives no lift on a deterministic MLX backend with systematic
# failures), run the task on a cheap/fast model, run the deterministic checks,
# and only when a check fails escalate to a STRONGER model — not re-prompt the
# same small model, which self-corrects prose poorly. The cost is asymmetric:
# tasks the cheap model already passes never pay for the strong model, so
# average latency stays near the cheap model's while the failure tail gets the
# bigger model's accuracy. This harness measures, per task, whether escalation
# actually recovers the failure and what it costs. It does not touch delegate.sh.
#
# The check is the existing experiments/score-t*.sh structural scorer: a score
# below --threshold (default 1.0 = a perfect structural pass) triggers escalation.
#
# Usage: escalate-eval.sh --task T4|T5|T6 --cheap <mlx-model> --strong <mlx-model>
#                         [--threshold 1.0] [--max-tokens M]
# Env:   MLX_HOST (default http://localhost:8080)
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixtures="$repo_root/experiments/fixtures"
mlx="${MLX_HOST:-http://localhost:8080}"

task="" cheap="" strong="" threshold="1.0" max_tokens=2048
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --task) task="${2:-}"; shift 2 ;;
    --cheap) cheap="${2:-}"; shift 2 ;;
    --strong) strong="${2:-}"; shift 2 ;;
    --threshold) threshold="${2:-}"; shift 2 ;;
    --max-tokens) max_tokens="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$task" && -n "$cheap" && -n "$strong" ]] || { echo "usage: escalate-eval.sh --task T4|T5|T6 --cheap <model> --strong <model> [--threshold 1.0]" >&2; exit 2; }

# Per-task config mirrors experiments/runner.sh / fanout-eval.sh. T3 is excluded:
# its citation scorer needs the fixture as oracle and rewards terseness, so it is
# a poor structural-escalation signal.
case "$task" in
  T4) task_id="T4-commit-message"; fixture="$fixtures/task-4-commit-message-2026-06-11.txt"; scorer="score-t4.sh"
      directive="Follow the instructions in the message above. Match the example commit messages exactly in shape and tone." ;;
  T5) task_id="T5-json-shape"; fixture="$fixtures/task-5-json-shape-2026-05-11.txt"; scorer="score-t5.sh"
      directive="Follow the instructions in the message above. Output ONLY the JSON object, no preamble or markdown fence." ;;
  T6) task_id="T6-regex-generation"; fixture="$fixtures/task-6-regex-generation-2026-05-11.txt"; scorer="score-t6.sh"
      directive="Follow the instructions in the message above. Output ONLY the regex pattern on a single line. No fence, no slashes, no commentary." ;;
  *) echo "unknown task: $task (want T4|T5|T6)" >&2; exit 2 ;;
esac
[[ -f "$fixture" ]] || { echo "fixture not found: $fixture" >&2; exit 2; }

prompt="$(cat "$fixture")"$'\n\n'"$directive"
work="$(mktemp -d "${TMPDIR:-/tmp}/escalate.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
[[ -n "$work" && -d "$work" ]] || { echo "could not create temp dir" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT

# Returns non-zero on a backend error (curl --fail) or empty content.
gen() { # model outfile
  local resp
  resp=$(jq -nc --arg m "$1" --arg p "$prompt" --argjson mt "$max_tokens" \
    '{model:$m, messages:[{role:"user",content:$p}], stream:false, temperature:0, max_tokens:$mt, chat_template_kwargs:{enable_thinking:false}}' \
    | curl -sS --fail --max-time 300 -X POST "$mlx/v1/chat/completions" -d @-) || return 1
  printf '%s' "$resp" | jq -r '.choices[0].message.content // ""' > "$2"
  [[ -s "$2" ]] || return 1
}
# Portable high-resolution clock: perl Time::HiRes (perl is already a hard dep)
# so sub-second timing works on BSD/macOS, where `date +%s.%N` emits a literal N.
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }
write_raw() { # outfile model sample
  { echo "MODEL: $2"; echo "BACKEND: mlx"; echo "REPS: 1"; echo "";
    echo "===== $task_id rep 1 ====="; echo "DURATION_SEC: 0"; echo "RUN_STATUS: 0"; echo "OUTPUT:"; cat "$3"; echo ""; } > "$1"
}
score() { # model sample -> echoes mean score (0..1)
  write_raw "$work/raw" "$1" "$2"
  bash "$repo_root/experiments/$scorer" "$work/raw" 2>/dev/null | sed -nE 's/^T[0-9]_SUMMARY:.* mean=([0-9.]+).*/\1/p'
}
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }  # a >= b ?
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >  b+0)}'; }  # a >  b ?

echo "================================================================"
echo "verify-and-escalate   task=$task  threshold=$threshold"
echo "  cheap=$cheap"
echo "  strong=$strong"
echo "================================================================"

# Step 1 — cheap model.
s=$(now); gen "$cheap" "$work/cheap" || { echo "cheap generation failed (backend error/empty)" >&2; exit 1; }; e=$(now)
cheap_lat=$(secs "$s" "$e"); cheap_score=$(score "$cheap" "$work/cheap")
[[ -n "$cheap_score" ]] || { echo "scorer returned no score for the cheap output" >&2; exit 1; }
echo "cheap:   score=$cheap_score   latency=${cheap_lat}s"

# Step 2 — escalate only if the cheap output fails the check.
if ge "$cheap_score" "$threshold"; then
  echo "verdict: PASS on cheap — no escalation. final=$cheap_score  total_latency=${cheap_lat}s"
else
  s=$(now); gen "$strong" "$work/strong" || { echo "strong generation failed (backend error/empty)" >&2; exit 1; }; e=$(now)
  strong_lat=$(secs "$s" "$e"); strong_score=$(score "$strong" "$work/strong")
  [[ -n "$strong_score" ]] || { echo "scorer returned no score for the strong output" >&2; exit 1; }
  total_lat=$(awk -v a="$cheap_lat" -v b="$strong_lat" 'BEGIN{printf "%.1f", a+b}')
  echo "escalated -> strong:   score=$strong_score   latency=${strong_lat}s"
  if ge "$strong_score" "$threshold"; then
    helped="FIXED"; final="$strong_score"
  elif gt "$strong_score" "$cheap_score"; then
    helped="improved but still failing"; final="$strong_score"
  elif ge "$strong_score" "$cheap_score"; then
    helped="NO CHANGE (same failure — not a capability gap, escalation wasted)"; final="$cheap_score"
  else
    helped="COUNTERPRODUCTIVE (strong scored lower)"; final="$cheap_score"
  fi
  echo "verdict: escalation $helped. final=$final  total_latency=${total_lat}s (cheap ${cheap_lat}s + strong ${strong_lat}s)"
fi
echo "----------------------------------------------------------------"