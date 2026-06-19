#!/usr/bin/env bash
# fanout-eval.sh — PROTOTYPE evaluation of fan-out (sampled-ensemble) delegation.
#
# Premise (see docs/adr/0018-fan-out-ensemble-prototype.md): a single greedy (temperature 0)
# generation occasionally lands on a bad mode — a hallucinated claim, a padding
# tail, a malformed field. The MLX server parallelises concurrent requests at
# ~1.5x the cost of one (measured 2026-06-18), so drawing N *sampled* generations
# (temperature > 0 for diversity) and merging them is a cheap quality lift rather
# than an N-fold cost. This harness measures whether that lift is real on the
# existing T3–T6 fixtures, WITHOUT touching production delegate.sh.
#
# Two merges, both production-viable (no oracle):
#   best-by-checks  — for tasks with deterministic checks (T4/T5/T6): score each
#                     sample with the existing experiments/score-t*.sh and keep
#                     the highest. Implemented for free by writing the N samples
#                     as N "reps" and reading the scorer's max.
#   consensus       — for list-style faithfulness tasks (T3): keep only the
#                     CONCERN | PATTERN lines whose PATTERN appears in >= ceil(N/2)
#                     samples. A hallucinated pattern (cited once) is voted out;
#                     a grounded one (cited by the majority) survives.
#
# A single greedy (temperature 0) generation is run as the baseline for contrast.
#
# Usage: fanout-eval.sh --task T3|T4|T5|T6 --model <mlx-model> [--n N] [--temperature T] [--max-tokens M]
# Env:   MLX_HOST (default http://localhost:8080)
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixtures="$repo_root/experiments/fixtures"
mlx="${MLX_HOST:-http://localhost:8080}"

task="" model="" n=3 temp="0.7" max_tokens=2048
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --task) task="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --n) n="${2:-}"; shift 2 ;;
    --temperature) temp="${2:-}"; shift 2 ;;
    --max-tokens) max_tokens="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$task" && -n "$model" ]] || { echo "usage: fanout-eval.sh --task T3|T4|T5|T6 --model <mlx-model> [--n N] [--temperature T]" >&2; exit 2; }
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "--n must be a positive integer" >&2; exit 2; }

# Per-task config: marker id, fixture, trailing directive, scorer. Directives
# mirror experiments/runner.sh so the measurement is comparable to the baseline.
case "$task" in
  T3) task_id="T3-merge-patterns"; fixture="$fixtures/task-3-merge-patterns-2026-04-28.txt"; scorer="score-t3.sh"
      directive="These are the last 10 commits on a Scottish election website. List up to 4 specific concerns each tied to a checkable file/path/grep pattern. For each: CONCERN | FILE_OR_PATTERN_TO_VERIFY. If nothing reliably checkable, output: NONE. Do not speculate beyond what the commit subjects state." ;;
  T4) task_id="T4-commit-message"; fixture="$fixtures/task-4-commit-message-2026-06-11.txt"; scorer="score-t4.sh"
      directive="Follow the instructions in the message above. Match the example commit messages exactly in shape and tone." ;;
  T5) task_id="T5-json-shape"; fixture="$fixtures/task-5-json-shape-2026-05-11.txt"; scorer="score-t5.sh"
      directive="Follow the instructions in the message above. Output ONLY the JSON object, no preamble or markdown fence." ;;
  T6) task_id="T6-regex-generation"; fixture="$fixtures/task-6-regex-generation-2026-05-11.txt"; scorer="score-t6.sh"
      directive="Follow the instructions in the message above. Output ONLY the regex pattern on a single line. No fence, no slashes, no commentary." ;;
  *) echo "unknown task: $task (want T3|T4|T5|T6)" >&2; exit 2 ;;
esac
[[ -f "$fixture" ]] || { echo "fixture not found: $fixture" >&2; exit 2; }

prompt="$(cat "$fixture")"$'\n\n'"$directive"
work="$(mktemp -d "${TMPDIR:-/tmp}/fanout.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# One MLX chat-completions call -> content into $3. think is always off here.
# NOTE (2026-06-18): the installed mlx_lm.server is deterministic per (prompt,
# temperature) and ignores per-request `seed`, so temperature alone yields N
# identical samples. Diversity therefore has to be injected through the prompt:
# $4 is an optional per-sample suffix that perturbs the request enough to move
# the deterministic decode onto a different path.
# Returns non-zero on a backend error (curl --fail) or empty content, so callers
# can fail fast rather than silently scoring a missing sample.
gen() { # temperature max_tokens outfile [perturb-suffix]
  local p="$prompt"; [[ -n "${4:-}" ]] && p="$prompt"$'\n\n'"$4"
  local resp
  resp=$(jq -nc --arg m "$model" --arg p "$p" --argjson t "$1" --argjson mt "$2" \
    '{model:$m, messages:[{role:"user",content:$p}], stream:false, temperature:$t, max_tokens:$mt, chat_template_kwargs:{enable_thinking:false}}' \
    | curl -sS --fail --max-time 300 -X POST "$mlx/v1/chat/completions" -d @-) || return 1
  printf '%s' "$resp" | jq -r '.choices[0].message.content // ""' > "$3"
  [[ -s "$3" ]] || return 1
}
# date +%s.%N is GNU-only; on stock BSD/macOS date it degrades to whole-second
# resolution (awk parses the literal "N" as 0), which is harmless here.
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }

# Write sample file(s) as runner-format reps so the existing scorer can read them.
write_raw() { # outfile sample1 [sample2 ...]
  local out="$1"; shift
  { echo "MODEL: $model"; echo "BACKEND: mlx"; echo "DATE: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "REPS: $#"; echo ""; } > "$out"
  local i=1 f
  for f in "$@"; do
    { echo "===== $task_id rep $i ====="; echo "DURATION_SEC: 0"; echo "RUN_STATUS: 0"; echo "OUTPUT:"; cat "$f"; echo ""; } >> "$out"
    i=$((i+1))
  done
}
summ() { bash "$repo_root/experiments/$scorer" "$1" 2>/dev/null | grep -E "^T[0-9]_SUMMARY:"; }
field() { sed -nE "s/.*$1=([0-9.]+).*/\1/p" <<<"$2"; }

echo "================================================================"
echo "fan-out eval   task=$task  model=$model  N=$n  temp=$temp"
echo "================================================================"

# Baseline: one greedy (temperature 0) generation.
s=$(date +%s.%N)
gen 0 "$max_tokens" "$work/base" || { echo "baseline generation failed (MLX backend error or empty output)" >&2; exit 1; }
e=$(date +%s.%N); base_lat=$(secs "$s" "$e")
write_raw "$work/base.raw" "$work/base"
base_sum=$(summ "$work/base.raw")
echo "baseline greedy(temp0):  score=$(field mean "$base_sum")   latency=${base_lat}s"

# Fan-out: N generations in parallel, each prompt-perturbed for diversity (the
# MLX server won't sample stochastically; see gen() note).
perturbs=(
  "Independent attempt: reason from the source yourself; do not reuse a template."
  "Independent attempt: be conservative — only state what the source clearly supports."
  "Independent attempt: double-check each item against the source before including it."
  "Independent attempt: prefer the simplest correct answer."
  "Independent attempt: re-derive the answer step by step, then output only the final result."
)
s=$(date +%s.%N)
pids=()
for ((i=1;i<=n;i++)); do
  gen "$temp" "$max_tokens" "$work/s$i" "${perturbs[$(((i-1) % ${#perturbs[@]}))]}" & pids+=($!)
done
# wait per-pid and fail fast: a silently-empty sample would otherwise score 0 and
# corrupt the reported mean/max (this is what made an earlier T3 run report 0.0).
fan_ok=1
for pid in "${pids[@]}"; do wait "$pid" || fan_ok=0; done
e=$(date +%s.%N); fan_lat=$(secs "$s" "$e")
(( fan_ok )) || { echo "a fan-out sample failed (MLX backend error or empty output) — aborting to avoid corrupt scores" >&2; exit 1; }
samples=(); for ((i=1;i<=n;i++)); do samples+=("$work/s$i"); done
write_raw "$work/fan.raw" "${samples[@]}"
fan_sum=$(summ "$work/fan.raw")
fan_mean=$(field mean "$fan_sum"); fan_max=$(field max "$fan_sum")
echo "fan-out N=$n parallel:    mean=${fan_mean}  best-by-checks(max)=${fan_max}   latency=${fan_lat}s"

# Consensus merge for T3 (list-style faithfulness task): keep PATTERN lines cited
# by >= ceil(N/2) samples. Pattern is the text after the last '|' on a line.
if [[ "$task" == "T3" ]]; then
  need=$(( (n + 1) / 2 ))
  for ((i=1;i<=n;i++)); do
    awk -F'|' 'NF>=2 { p=$NF; gsub(/^[ \t]+|[ \t]+$/,"",p); if (p!="") print p }' "$work/s$i" | sort -u
  done | sort | uniq -c | awk -v need="$need" '{ c=$1+0; if (c>=need) { sub(/^[ \t]*[0-9]+[ \t]+/,""); print "consensus | " $0 } }' > "$work/consensus_lines"
  if [[ -s "$work/consensus_lines" ]]; then
    write_raw "$work/cons.raw" "$work/consensus_lines"
    cons_sum=$(summ "$work/cons.raw")
    echo "consensus(>=$need/$n):     citation=$(field mean "$cons_sum")   (patterns surviving the vote: $(wc -l < "$work/consensus_lines" | tr -d ' '))"
  else
    echo "consensus(>=$need/$n):     no pattern cited by the majority (samples too divergent — a prototype finding)"
  fi
fi
echo "----------------------------------------------------------------"