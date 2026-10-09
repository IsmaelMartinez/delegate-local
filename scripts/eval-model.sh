#!/usr/bin/env bash
# eval-model.sh — one report card for a candidate model against the prose
# tier's current one (#678, ADR 0034). It runs, on this skill's own work, the
# measurements docs/model-swap.md steps 2 and 4 to 6 describe, and ends with
# one verdict:
#
#   cost       the rendered inputs of the newest delegations, sent to both
#              models in alternation with delegate.sh's request: seconds per
#              call, output tokens per call and per second, GPU busy-seconds
#              per call (ioreg's Device Utilization over each call, less the
#              level read before the first), the calls that ran to max_tokens,
#              answered empty or carried a reasoning trace although thinking
#              was off, and the candidate's first call. On Apple silicon active
#              parameters, not size, set this.
#   replay     replay-recipe.sh --candidate-model --edited-only per recipe:
#              the sign test on the cases the agent edited, and the anchors
#              each arm dropped, restated (over) and invented. The long step,
#              so it runs last and not at all once the cost step stops the
#              candidate as a writer; a judging failure still lets it run.
#   grounding  verify-draft.sh --calibrate --dry-run on the labelled grounding
#              set: AUROC and threshold in the verifier role, which moves with
#              the prose tier on a server that swaps models.
#   trigger    eval-skill-triggers.sh --decide: the skill's description, read
#              by the model.
#
# The candidate runs on its own server: an mlx_lm.server swaps models rather
# than stacking them, so asking the shared one for the candidate evicts the
# model every other session uses. The champion is whatever the prose tier
# resolves to, asked for by its exact id. Grounding and trigger results are
# cached per model and input hash under <data dir>/evals/cache, so a champion
# measured once costs nothing again; the replay keeps its own per-arm cache;
# cost is measured fresh on both, back to back.
#
# Usage:  eval-model.sh --model ID [--base URL] [--recipes A,B,...] [--limit N]
#                       [--prompts N] [--grounding FILE] [--skip STEP,...]
#                       [--same-server]
#
#   --model ID        the candidate, by the exact id its server lists
#   --base URL        where it is served (default http://127.0.0.1:8081/v1)
#   --recipes LIST    recipes to replay (default the six with the most
#                     delegations in the metrics file)
#   --limit N         newest N edited cases per recipe (default 20)
#   --prompts N       prompts in the cost step (default 8)
#   --grounding FILE  the labelled set (default <data dir>/spikes/clef/
#                     grounding/ground.jsonl); when absent the step is noted
#                     as not measured
#   --skip LIST       steps to leave out: cost, replay, grounding, trigger
#   --same-server     allow --base to be the champion's base, for a provider
#                     that holds both models at once
#
# Verdict (ADR 0034): STOP when a recipe's replay is REJECT, the trigger gate
# fails, grounding AUROC is more than 0.05 under the champion's, the candidate
# does not answer decide.sh's lettered questions at all (the verifier and the
# trigger gate run on them), it answers empty on more calls than the champion,
# or the cost per call is over 1.5 times the
# champion's; else INCONCLUSIVE when a step that could have stopped it did not
# run; else TRIAL when the candidate is cheaper (at most 0.9 times) or better
# (a replay ACCEPT, or AUROC 0.05 or more over); else HOLD. The blind judge
# (docs/model-swap.md step 3) stays a manual read.
#
# Writes <data dir>/evals/<UTC time>-<model slug>/ (report.txt, card.json and
# each step's output) under umask 077 and nothing to the metrics file.
# Env:  DELEGATE_LOCAL_DATA_DIR, DELEGATE_METRICS_FILE as every other script;
#       DELEGATE_GPU_* the heat gate (lib/gpu-gate.sh), waited on before each
#       step and each cost call; DELEGATE_EVAL_SCRIPTS the directory the step
#       scripts run from and DELEGATE_EVAL_CLOCK a file read as the time
#       (both test seams).
# Exit: 0 report printed (the last line is the verdict); 2 usage or
#       dependency error; 3 the candidate is not served at --base; 75 the
#       machine stayed hot or busy past DELEGATE_GPU_WAIT_MAX (rerun: the
#       caches keep what ran).
set -uo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
steps_dir="${DELEGATE_EVAL_SCRIPTS:-$script_dir}"
data_dir="${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}"
metrics_file="${DELEGATE_METRICS_FILE:-$data_dir/metrics.jsonl}"
drafts_dir="$(dirname "$metrics_file")/drafts"

model=""
base="http://127.0.0.1:8081/v1"
recipes=""
limit=20
n_prompts=8
grounding="$data_dir/spikes/clef/grounding/ground.jsonl"
skip=""
same_server=0

need_value() { [[ -n "${2:-}" ]] || { echo "eval-model: $1 needs a value" >&2; exit 2; }; }
while (( $# > 0 )); do
  case "$1" in
    --model) need_value "$@"; model="$2"; shift 2 ;;
    --base) need_value "$@"; base="$2"; shift 2 ;;
    --recipes) need_value "$@"; recipes="$2"; shift 2 ;;
    --limit) need_value "$@"; limit="$2"; shift 2 ;;
    --prompts) need_value "$@"; n_prompts="$2"; shift 2 ;;
    --grounding) need_value "$@"; grounding="$2"; shift 2 ;;
    --skip) need_value "$@"; skip="$2"; shift 2 ;;
    --same-server) same_server=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) echo "eval-model: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$model" ]] || { echo "eval-model: --model is required (the candidate's exact served id)" >&2; exit 2; }
for n in "$limit" "$n_prompts"; do
  case "$n" in ''|*[!0-9]*|0) echo "eval-model: --limit and --prompts take a positive number" >&2; exit 2 ;; esac
done
for s in ${skip//,/ }; do
  case "$s" in cost|replay|grounding|trigger) ;; *) echo "eval-model: --skip takes cost, replay, grounding or trigger, not '$s'" >&2; exit 2 ;; esac
done
skipped() { [[ ",$skip," == *",$1,"* ]]; }
# The base is printed in the report, so credentials in it are refused before
# anything is printed, as pick-model.sh and replay-recipe.sh refuse them.
case "$base" in *"://"*"@"*) echo "eval-model: --base contains userinfo (credentials before an @); refusing" >&2; exit 2 ;; esac
base="${base%/}"
for dep in jq curl perl shasum; do
  command -v "$dep" >/dev/null || { echo "eval-model: $dep not on PATH" >&2; exit 2; }
done

resolution=$(bash "$script_dir/pick-model.sh" --print-resolution prose 2>/dev/null | head -n 1)
if [[ "$resolution" != *$'\t'* ]]; then
  echo "eval-model: the prose tier resolves to no served model; the card compares the candidate with it" >&2; exit 2
fi
champ_base="${resolution%%$'\t'*}"
champ_model="${resolution#*$'\t'}"
if [[ "$model" == "$champ_model" ]]; then
  echo "eval-model: $model is the prose tier's current model; there is nothing to compare it with" >&2; exit 2
fi
same_base() { # two bases name one server: localhost and 127.0.0.1 are one host
  local a b
  a=$(printf '%s' "${1%/}" | tr '[:upper:]' '[:lower:]'); b=$(printf '%s' "${2%/}" | tr '[:upper:]' '[:lower:]')
  [[ "${a/:\/\/localhost/://127.0.0.1}" == "${b/:\/\/localhost/://127.0.0.1}" ]]
}
if same_base "$base" "$champ_base" && (( ! same_server )); then
  cat >&2 <<EOF
eval-model: --base $base is the server the prose tier uses. An mlx_lm.server
swaps models rather than stacking them, so asking it for the candidate evicts
the model every other session is using, on every case. Serve the candidate on
its own port and pass that base:
  mlx_lm.server --model $model --port 8081
Pass --same-server for a provider that holds both models at once.
EOF
  exit 2
fi
if ! curl -s -m 5 "$base/models" 2>/dev/null | jq -er --arg m "$model" '.data[]? | select(.id == $m) | .id' >/dev/null 2>&1; then
  echo "eval-model: $base does not list $model; start it with: mlx_lm.server --model $model --port 8081" >&2
  exit 3
fi

recipe_list=()
if [[ -n "$recipes" ]]; then
  for r in ${recipes//,/ }; do recipe_list+=("$r"); done
elif [[ -f "$metrics_file" ]]; then
  while IFS= read -r r; do recipe_list+=("$r"); done < <(
    jq -r 'select((.source // "delegate") == "delegate" and (.recipe // "") != "") | .recipe' "$metrics_file" 2>/dev/null \
      | sort | uniq -c | sort -k1,1nr -k2 | head -n 6 | awk '{ print $2 }')
fi
for r in ${recipe_list[@]+"${recipe_list[@]}"}; do
  case "$r" in *[!A-Za-z0-9_-]*) echo "eval-model: recipe names are [A-Za-z0-9_-]+, not '$r'" >&2; exit 2 ;; esac
done

# shellcheck source=lib/gpu-gate.sh
. "$script_dir/lib/gpu-gate.sh"
gpu_gate_keep_awake

stamp=$(date -u +%Y%m%dT%H%M%SZ)
slug=$(printf '%s' "$model" | tr '/' '_' | tr -c 'A-Za-z0-9._-' '-' | cut -c1-60)
run_dir="$data_dir/evals/$stamp-$slug"
cache_dir="$data_dir/evals/cache"
mkdir -p "$run_dir" "$cache_dir" || { echo "eval-model: cannot create $run_dir" >&2; exit 2; }
work_tmp=$(mktemp -d)
sampler_pid=""
stop_sampler() { [[ -n "$sampler_pid" ]] && kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null; sampler_pid=""; }
trap 'stop_sampler; rm -rf "$work_tmp"' EXIT

# DELEGATE_EVAL_CLOCK (a test seam) names a file holding the time, which the
# tests' mock provider advances by each model's simulated duration, so a cost
# ratio is exact however loaded the machine running the tests is.
now() {
  if [[ -n "${DELEGATE_EVAL_CLOCK:-}" ]]; then cat "$DELEGATE_EVAL_CLOCK"; return 0; fi
  perl -MTime::HiRes=time -e 'printf "%.3f", time'
}
key_of() { printf '%s' "$1" | shasum -a 256 | cut -c1-10; }
hash_files() { cat "$@" 2>/dev/null | shasum -a 256 | cut -c1-12; }
# gate [first]: wait out a hot machine at the top level, so a give-up ends the
# run with 75 rather than a subshell.
gate() {
  gpu_gate_wait "${1:-}" && return 0
  echo "eval-model: the machine stayed hot or busy; stopping. Rerun to resume: the caches keep what ran." >&2
  exit "$GPU_GATE_BUSY"
}
# weights_gb ID: the size of the model's Hugging Face cache entry, where an
# MLX server loads it from; "?" for a provider that keeps weights elsewhere.
weights_gb() {
  local hub="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}" dir kb
  dir="$hub/models--${1//\//--}/blobs"
  [[ -d "$dir" ]] || { echo "?"; return 0; }
  kb=$(du -sk "$dir" 2>/dev/null | awk '{ print $1 }')
  awk -v k="${kb:-0}" 'BEGIN { printf "%.1f", k * 1024 / 1e9 }'
}
reasons_stop=()
reasons_open=()
reasons_go=()
writer_stop=0

thermal_start=$(gpu_gate_thermal)
chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
cand_gb=$(weights_gb "$model")
champ_gb=$(weights_gb "$champ_model")
gate first

# ---------------------------------------------------------------------------
# Cost: the same prompts to both servers, alternating which goes first, so
# heat and other sessions' load fall on both arms alike.
# ---------------------------------------------------------------------------
cost_measure=""; cost_ratio=""
: > "$run_dir/cost.tsv"
# cost_call <arm> <base> <model> <prompt file> <i>: one line to cost.tsv —
# arm, i, start, end, prompt and output tokens, finish reason, 1 when the
# answer carried a reasoning trace (a server's reasoning field, or <think> in
# the content) although the request turned thinking off, and 1 when it
# answered at all: a reasoning model can spend the whole budget thinking and
# return empty content, which costs the GPU like any call and fails the
# delegation it stands for (delegate.sh exits on empty content).
cost_call() {
  local t0 t1 body
  t0=$(now)
  body=$(jq -Rsc --arg m "$3" '{model:$m, messages:[{role:"user", content:.}], stream:false, temperature:0,
           max_tokens:4096, chat_template_kwargs:{enable_thinking:false}}' < "$4" \
         | curl -sS --fail --max-time 600 -X POST "$2/chat/completions" -H 'Content-Type: application/json' --data-binary @- 2>/dev/null)
  local rc=$?
  t1=$(now)
  if (( rc == 0 )) && jq -e '.choices[0].message' <<<"$body" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$5" "$t0" "$t1" "$(jq -r '.choices[0] as $c
        | [(.usage.prompt_tokens // 0), (.usage.completion_tokens // 0), ($c.finish_reason // "-"),
           (if (($c.message.reasoning // $c.message.reasoning_content // "") != "")
               or (($c.message.content // "") | test("<think>")) then 1 else 0 end),
           (if ($c.message.content // "" | gsub("\\s"; "")) != "" then 1 else 0 end)] | @tsv' <<<"$body")" >> "$run_dir/cost.tsv"
  else
    printf '%s\t%s\t%s\t%s\terror\terror\t-\t0\t0\n' "$1" "$5" "$t0" "$t1" >> "$run_dir/cost.tsv"
  fi
}
first_call() { # <base> <model>: seconds for a one-token answer, the cold load included
  local t0 t1
  t0=$(now)
  curl -sS --fail --max-time 600 -X POST "$1/chat/completions" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$2" '{model:$m, messages:[{role:"user", content:"hi"}], stream:false, temperature:0, max_tokens:1, chat_template_kwargs:{enable_thinking:false}}')" \
    >/dev/null 2>&1 || { echo "error"; return 0; }
  t1=$(now)
  awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }'
}

prompts=()
if ! skipped cost && [[ -f "$metrics_file" ]] && (( ${#recipe_list[@]} > 0 )); then
  while IFS= read -r f; do
    # Names come out of a JSONL file and become paths: bare filenames only.
    [[ -n "$f" && "$f" != */* && "$f" != .* && -s "$drafts_dir/$f" ]] || continue
    prompts+=("$drafts_dir/$f")
    (( ${#prompts[@]} >= n_prompts )) && break
  done < <(jq -rs --arg r " ${recipe_list[*]} " '
      map(select((.source // "delegate") == "delegate" and (.exit_status // 0) == 0 and (.input_file // "") != ""
                 and ((.recipe // "-") as $x | $r | contains(" " + $x + " "))))
      | sort_by(.ts) | reverse | .[].input_file' "$metrics_file" 2>/dev/null)
fi
cand_first=""
if skipped cost; then
  reasons_open+=("cost skipped")
elif (( ${#prompts[@]} == 0 )); then
  reasons_open+=("cost not measured: no stored prompt for the recipes")
else
  echo "eval-model: cost, ${#prompts[@]} prompts on both models ..." >&2
  cand_first=$(first_call "$base" "$model")
  first_call "$champ_base" "$champ_model" >/dev/null
  # Twice a second while the calls run; the two seconds before the first
  # read the idle level, which the busy-seconds are counted above.
  if [[ -n "$(gpu_gate_util)" ]]; then
    ( while :; do printf '%s %s\n' "$(now)" "$(gpu_gate_util)"; sleep 0.5; done ) > "$run_dir/gpu.txt" 2>/dev/null &
    sampler_pid=$!
    sleep 2
  fi
  i=0
  for p in "${prompts[@]}"; do
    i=$((i + 1))
    gate
    if (( i % 2 )); then
      cost_call candidate "$base" "$model" "$p" "$i"; cost_call champion "$champ_base" "$champ_model" "$p" "$i"
    else
      cost_call champion "$champ_base" "$champ_model" "$p" "$i"; cost_call candidate "$base" "$model" "$p" "$i"
    fi
  done
  stop_sampler
  [[ -f "$run_dir/gpu.txt" ]] || : > "$run_dir/gpu.txt"
  # Per arm: calls, errors, seconds, prompt and output tokens, and GPU
  # busy-seconds: the utilisation over the idle level (read in the two
  # seconds before the first call), each sample counted once, for the latest
  # call started before it and up to half a second past that call's end, as
  # ioreg lags. The calls run one at a time, in cost.tsv's order.
  awk -F'\t' -v gpu="$run_dir/gpu.txt" '
    BEGIN { n = 0; while ((getline line < gpu) > 0) { split(line, a, " "); if (a[2] != "") { n++; t[n] = a[1]; u[n] = a[2] } } }
    { arm = $1; calls[arm]++
      if ($5 == "error") { err[arm]++; next }
      s[arm] += $4 - $3; pt[arm] += $5; ct[arm] += $6; capped[arm] += ($7 == "length"); think[arm] += $8; empty[arm] += ($9 == 0)
      m++; c0[m] = $3; c1[m] = $4; who[m] = arm }
    END {
      idle = 0; k = 0
      for (j = 1; j <= n; j++) if (m && t[j] < c0[1]) { idle += u[j]; k++ }
      if (k) idle /= k
      r = 0
      for (j = 2; j <= n; j++) {
        while (r < m && c0[r + 1] <= t[j]) r++
        if (r && t[j] <= c1[r] + 0.5) { d = u[j] - idle; if (d > 0) busy[who[r]] += d / 100 * (t[j] - t[j - 1]) }
      }
      for (arm in calls)
        printf "%s\t%d\t%d\t%.3f\t%d\t%d\t%.3f\t%d\t%d\t%d\t%d\n", arm, calls[arm], err[arm] + 0, s[arm], pt[arm], ct[arm],
          busy[arm] + 0, (n > 0), capped[arm] + 0, think[arm] + 0, empty[arm] + 0
    }' "$run_dir/cost.tsv" > "$work_tmp/cost.sum"
  arm_cost() { awk -F'\t' -v a="$1" '$1 == a' "$work_tmp/cost.sum"; }
  IFS=$'\t' read -r _ c_calls c_err c_s c_pt c_ct c_busy util_ok c_cap c_think c_empty <<<"$(arm_cost candidate)"
  IFS=$'\t' read -r _ h_calls h_err h_s h_pt h_ct h_busy _ h_cap h_think h_empty <<<"$(arm_cost champion)"
  c_ok=$(( ${c_calls:-0} - ${c_err:-0} )); h_ok=$(( ${h_calls:-0} - ${h_err:-0} ))
  if (( c_ok == 0 || h_ok == 0 || c_err > ${c_calls:-0} / 2 || h_err > ${h_calls:-0} / 2 )); then
    reasons_open+=("cost: more than half the calls failed (candidate ${c_err:-?}, champion ${h_err:-?} of ${#prompts[@]})")
  else
    # GPU busy-seconds when ioreg could be read, else wall seconds: one
    # stream keeps the GPU near saturation, so the two track each other.
    if [[ "${util_ok:-0}" == 1 ]] && awk -v c="$c_busy" -v h="$h_busy" 'BEGIN { exit !(c > 0 && h > 0) }'; then
      cost_measure="GPU busy-seconds per call"
      cost_ratio=$(awk -v c="$c_busy" -v co="$c_ok" -v h="$h_busy" -v ho="$h_ok" 'BEGIN { printf "%.2f", (c / co) / (h / ho) }')
    else
      cost_measure="seconds per call"
      cost_ratio=$(awk -v c="$c_s" -v co="$c_ok" -v h="$h_s" -v ho="$h_ok" 'BEGIN { if (c > 0 && h > 0) printf "%.2f", (c / co) / (h / ho) }')
    fi
    # A reasoning trace the request turned off is the usual cause of a cost
    # far above the champion's, so the reason names it.
    think_note=""
    (( ${c_think:-0} > 0 )) && think_note=", and it reasoned before answering on $c_think of $c_ok calls although thinking was off"
    if [[ -z "$cost_ratio" ]]; then
      reasons_open+=("cost: no time measured on one arm")
    elif awk -v r="$cost_ratio" 'BEGIN { exit !(r > 1.5) }'; then
      reasons_stop+=("cost: $cost_ratio times the champion's $cost_measure$think_note"); writer_stop=1
    elif awk -v r="$cost_ratio" 'BEGIN { exit !(r <= 0.9) }'; then
      reasons_go+=("cheaper: $cost_ratio times the champion's $cost_measure$think_note")
    fi
    if (( ${c_empty:-0} > ${h_empty:-0} )); then
      reasons_stop+=("no answer: the candidate returned empty content on $c_empty of $c_ok calls, each a failed delegation"); writer_stop=1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Grounding and trigger: per model, cached by the hash of what they read.
# ---------------------------------------------------------------------------
ground_sha=""
[[ -f "$grounding" ]] && ground_sha=$(hash_files "$grounding" "$steps_dir/verify-draft.sh" "$script_dir/decide.sh")
trigger_sha=$(hash_files "$repo_root/evals/eval-set.json" "$repo_root/SKILL.md" "$steps_dir/eval-skill-triggers.sh" "$script_dir/decide.sh")

# grounding_run <base> <model> <out>: the verify-calibrate line, or nothing.
grounding_run() {
  local f
  f="$cache_dir/$(key_of "$2").grounding.$ground_sha.txt"
  if [[ -s "$f" ]]; then cp "$f" "$3"; return 0; fi
  : > "$3"
  gate
  echo "eval-model: grounding on $2 ..." >&2
  DELEGATE_BASE_URL="$1" DELEGATE_MODEL="$2" bash "$steps_dir/verify-draft.sh" --calibrate "$grounding" --dry-run \
    > "$work_tmp/g.out" 2> "$work_tmp/g.err"
  local rc=$?
  grep -m1 '^verify-calibrate: model=' "$work_tmp/g.out" > "$work_tmp/g.line"
  if (( rc == 0 )) && [[ -s "$work_tmp/g.line" ]] && grep -qF "model=$2 " "$work_tmp/g.line"; then
    cp "$work_tmp/g.line" "$f"; cp "$f" "$3"
  else
    cp "$work_tmp/g.err" "$3.err"
  fi
}
# trigger_run <base> <model> <out>: "<exit>\t<results line>", or nothing.
trigger_run() {
  local f
  f="$cache_dir/$(key_of "$2").trigger.$trigger_sha.txt"
  if [[ -s "$f" ]]; then cp "$f" "$3"; return 0; fi
  : > "$3"
  gate
  echo "eval-model: trigger gate on $2 ..." >&2
  (cd "$repo_root" && DELEGATE_BASE_URL="$1" DELEGATE_MODEL="$2" bash "$steps_dir/eval-skill-triggers.sh" --decide) \
    > "$work_tmp/t.out" 2> "$work_tmp/t.err"
  local rc=$? line
  line=$(grep -m1 '^results: ' "$work_tmp/t.out")
  # Every query has to have been answered by the model named, not another.
  if [[ -n "$line" ]] && (( rc <= 1 )) && grep -qxF "scored on: $2" "$work_tmp/t.out"; then
    printf '%s\t%s\n' "$rc" "$line" > "$f"; cp "$f" "$3"
  else
    cp "$work_tmp/t.err" "$3.err"
  fi
}
# off_format <err file>: the model answered a lettered decide.sh question with
# neither letter (a reasoning model's <think>, or prose) — the verifier and the
# trigger gate cannot run on it at all, which is not a passing fault.
off_format() { grep -qE 'neither option letter|answer letters held only' "$1" 2>/dev/null; }
letter_stop="the candidate does not answer decide.sh's lettered questions (it opens with something other than an option letter), so the verifier and the trigger gate would break on it"
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" "$2" | head -n 1; }

g_cand=""; g_champ=""
if skipped grounding; then
  reasons_open+=("grounding skipped")
elif [[ -z "$ground_sha" ]]; then
  : # no labelled set on this machine: reported, not gating
else
  grounding_run "$base" "$model" "$run_dir/grounding-candidate.txt"
  grounding_run "$champ_base" "$champ_model" "$run_dir/grounding-champion.txt"
  g_cand=$(field auroc "$run_dir/grounding-candidate.txt"); g_champ=$(field auroc "$run_dir/grounding-champion.txt")
  if [[ -z "$g_cand" ]] && off_format "$run_dir/grounding-candidate.txt.err"; then
    reasons_stop+=("grounding: $letter_stop")
  elif [[ -z "$g_cand" || -z "$g_champ" ]]; then
    reasons_open+=("grounding: the verifier question could not be scored on $([[ -z "$g_cand" ]] && echo the candidate || echo the champion)")
  elif awk -v c="$g_cand" -v h="$g_champ" 'BEGIN { exit !(c < h - 0.05) }'; then
    reasons_stop+=("grounding: AUROC $g_cand against the champion's $g_champ")
  elif awk -v c="$g_cand" -v h="$g_champ" 'BEGIN { exit !(c >= h + 0.05) }'; then
    reasons_go+=("better grounding: AUROC $g_cand against $g_champ")
  fi
fi

t_cand_rc=""
if skipped trigger; then
  reasons_open+=("trigger skipped")
else
  trigger_run "$base" "$model" "$run_dir/trigger-candidate.txt"
  trigger_run "$champ_base" "$champ_model" "$run_dir/trigger-champion.txt"
  t_cand_rc=$(cut -f1 "$run_dir/trigger-candidate.txt")
  case "$t_cand_rc" in
    0) ;;
    1) reasons_stop+=("trigger gate: recall $(field recall "$run_dir/trigger-candidate.txt"), negative precision $(field negative-precision "$run_dir/trigger-candidate.txt") under the bar") ;;
    *) if off_format "$run_dir/trigger-candidate.txt.err"; then
         # Named once: grounding has usually said it already.
         [[ " ${reasons_stop[*]-} " == *"$letter_stop"* ]] || reasons_stop+=("trigger gate: $letter_stop")
       else
         reasons_open+=("trigger gate: no score on the candidate")
       fi ;;
  esac
fi

# ---------------------------------------------------------------------------
# Replay: the sign test per recipe on the edited cases.
# ---------------------------------------------------------------------------
: > "$work_tmp/replay.tsv"
# The replay is the long step (a model call per edited case on each arm),
# and it runs last: once the cost step has stopped the candidate as a writer
# (too hot, or empty answers) its heat is not spent. A judging failure
# (grounding, the trigger gate) still lets it run, since a model that writes
# well and judges badly could take the prose tier with the verifier left on
# another model on a server of its own, and the card should show which it is.
replay_note=""
if skipped replay; then
  reasons_open+=("replay skipped")
elif (( writer_stop )); then
  replay_note="not run: the cost step already stops the candidate as a writer"
elif (( ${#recipe_list[@]} == 0 )); then
  reasons_open+=("replay: no recipe to replay (no metrics and no --recipes)")
else
  for r in "${recipe_list[@]}"; do
    gate
    echo "eval-model: replay $r ..." >&2
    out="$run_dir/replay-$r.txt"
    bash "$steps_dir/replay-recipe.sh" --recipe "$r" --candidate-model "$model" --candidate-base "$base" \
      --edited-only --limit "$limit" > "$out" 2> "$run_dir/replay-$r.err"
    rc=$?
    if (( rc == GPU_GATE_BUSY )); then
      echo "eval-model: the replay of $r stopped on the heat gate; rerun to resume from its cache" >&2
      exit "$GPU_GATE_BUSY"
    fi
    # Every field is non-empty ("-" for none): the report reads the rows back
    # with a tab IFS, which would merge an empty field into its neighbour.
    if (( rc == 3 )); then
      printf '%s\tnone\t0\t0\t0\t0\t0\t-\t0 0 0\t0 0 0\n' "$r" >> "$work_tmp/replay.tsv"; continue
    fi
    verdict=$(sed -n 's/^Verdict: \([A-Z]*\).*/\1/p' "$out" | tail -n 1)
    if (( rc != 0 )) || [[ -z "$verdict" ]]; then
      printf '%s\terror\t0\t0\t0\t0\t0\t-\t0 0 0\t0 0 0\n' "$r" >> "$work_tmp/replay.tsv"
      reasons_open+=("replay: $r did not run (exit $rc)"); continue
    fi
    summary=$(sed -n 's/^Summary: n=\([0-9]*\)  wins=\([0-9]*\)  losses=\([0-9]*\)  ties=\([0-9]*\)  errors=\([0-9]*\).*/\1 \2 \3 \4 \5/p' "$out" | tail -n 1)
    read -r n w l t e <<<"${summary:-0 0 0 0 0}"
    p=$(sed -n 's/^Sign test: p=\([0-9.]*\).*/\1/p' "$out" | tail -n 1)
    p="${p:--}"
    # dropped, over and invented per arm, summed over the listed cases:
    # fields 2-4 of each score (checks/dropped/over/invented/echoed/shape/length=total).
    anchors=$(awk '$3 ~ /^(kept|scaffold|rewrote)$/ && $4 ~ /^[0-9]+(\/[0-9]+)+=[0-9]+$/ && $5 ~ /^[0-9]+(\/[0-9]+)+=[0-9]+$/ {
        split($4, a, /[\/=]/); split($5, b, /[\/=]/); hd += a[2]; ho += a[3]; hi += a[4]; cd += b[2]; co += b[3]; ci += b[4] }
      END { printf "%d %d %d\t%d %d %d", hd, ho, hi, cd, co, ci }' "$out")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$verdict" "$n" "$w" "$l" "$t" "$e" "$p" "$anchors" >> "$work_tmp/replay.tsv"
    case "$verdict" in
      REJECT) reasons_stop+=("replay: $r REJECT, $l losses to $w wins (p=$p)") ;;
      ACCEPT) reasons_go+=("better on $r: replay ACCEPT, $w wins to $l (p=$p)") ;;
    esac
    (( ${e:-0} > 0 )) && reasons_open+=("replay: $e case(s) of $r failed to run")
  done
  if ! awk -F'\t' '$2 != "none" && $2 != "error" { found = 1 } END { exit !found }' "$work_tmp/replay.tsv"; then
    reasons_open+=("replay: no recipe had an edited case to compare")
  fi
fi

# ---------------------------------------------------------------------------
# Verdict and report.
# ---------------------------------------------------------------------------
join_reasons() { local IFS=';'; printf '%s' "$*" | sed 's/;/; /g'; }
if (( ${#reasons_stop[@]} > 0 )); then
  verdict="STOP"; why=$(join_reasons "${reasons_stop[@]}")
elif (( ${#reasons_open[@]} > 0 )); then
  verdict="INCONCLUSIVE"; why=$(join_reasons "${reasons_open[@]}")
elif (( ${#reasons_go[@]} > 0 )); then
  verdict="TRIAL"; why="$(join_reasons "${reasons_go[@]}"); worth a live trial (docs/model-swap.md step 7) after the blind judge (step 3)"
else
  verdict="HOLD"; why="it matches the champion without being cheaper or better, so a switch would buy nothing"
fi
thermal_end=$(gpu_gate_thermal)

per_call() { awk -v a="$1" -v n="$2" -v f="${3:-%.2f}" 'BEGIN { if (n > 0) printf f, a / n; else printf "-" }'; }
tok_s() { awk -v c="$1" -v s="$2" 'BEGIN { if (s > 0) printf "%.0f", c / s; else printf "-" }'; }
{
  echo "=== eval-model: $model against the prose tier's $champ_model ==="
  echo "Candidate: $model at $base (weights ${cand_gb} GB)"
  echo "Champion:  $champ_model at $champ_base (weights ${champ_gb} GB)"
  echo "Machine:   $chip, ${mem_gb} GB; thermal state ${thermal_start:-?} at start, ${thermal_end:-?} at end"
  echo
  if [[ -n "$cost_ratio" ]]; then
    echo "Cost, ${#prompts[@]} stored prompts sent to both (candidate / champion):"
    echo "  seconds per call         $(per_call "$c_s" "$c_ok") / $(per_call "$h_s" "$h_ok")"
    echo "  prompt tokens per call   $(per_call "$c_pt" "$c_ok" %.0f) / $(per_call "$h_pt" "$h_ok" %.0f) (each model's own tokenizer)"
    echo "  output tokens per call   $(per_call "$c_ct" "$c_ok" %.0f) / $(per_call "$h_ct" "$h_ok" %.0f)"
    echo "  output tokens per second $(tok_s "$c_ct" "$c_s") / $(tok_s "$h_ct" "$h_s")"
    echo "  ran to max_tokens        $c_cap of $c_ok / $h_cap of $h_ok"
    echo "  empty answer             $c_empty of $c_ok / $h_empty of $h_ok"
    echo "  reasoning trace          $c_think of $c_ok / $h_think of $h_ok (thinking requested off)"
    if [[ "${util_ok:-0}" == 1 ]]; then
      echo "  GPU busy-seconds/call    $(per_call "$c_busy" "$c_ok") / $(per_call "$h_busy" "$h_ok")"
    fi
    echo "  candidate first call     ${cand_first:-?} s (includes any lazy load)"
    echo "  ratio                    $cost_ratio ($cost_measure)"
  else
    echo "Cost: not measured"
  fi
  echo
  echo "Replay, newest $limit edited cases per recipe (candidate against champion; anchors dropped/over/invented, champion | candidate):"
  if [[ -s "$work_tmp/replay.tsv" ]]; then
    while IFS=$'\t' read -r r v n w l t e p ha ca; do
      case "$v" in
        none) printf '  %-24s no edited case\n' "$r" ;;
        error) printf '  %-24s did not run (see %s)\n' "$r" "$run_dir/replay-$r.err" ;;
        *) printf '  %-24s n=%-3s W%-3s L%-3s T%-3s p=%-6s %-13s %s | %s\n' "$r" "$n" "$w" "$l" "$t" "$p" "$v" "${ha// //}" "${ca// //}" ;;
      esac
    done < "$work_tmp/replay.tsv"
  else
    echo "  ${replay_note:-not run}"
  fi
  echo
  echo "Grounding, the verifier role (AUROC, threshold):"
  if [[ -n "$ground_sha" ]] && ! skipped grounding; then
    for arm in candidate champion; do
      f="$run_dir/grounding-$arm.txt"
      if [[ -s "$f" ]]; then
        printf '  %-9s auroc=%s threshold=%s balanced_accuracy=%s n=%s\n' "$arm" "$(field auroc "$f")" "$(field threshold "$f")" "$(field balanced_accuracy "$f")" "$(field n "$f")"
      else
        printf '  %-9s no score: %s\n' "$arm" "$(tail -n 1 "$f.err" 2>/dev/null)"
      fi
    done
    if [[ -n "$g_cand" ]] && awk -v t="$(field threshold "$run_dir/grounding-candidate.txt")" 'BEGIN { exit !(t >= 0.999) }'; then
      echo "  the candidate's scores pile up near 1: set its live threshold a little below the pile (docs/model-swap.md step 7)"
    fi
  elif skipped grounding; then
    echo "  skipped"
  else
    echo "  not measured: no labelled set at $grounding"
  fi
  echo
  echo "Trigger gate (--decide):"
  if skipped trigger; then
    echo "  skipped"
  else
    for arm in candidate champion; do
      f="$run_dir/trigger-$arm.txt"
      if [[ -s "$f" ]]; then
        printf '  %-9s recall=%s negative-precision=%s %s\n' "$arm" "$(field recall "$f")" "$(field negative-precision "$f")" "$([[ "$(cut -f1 "$f")" == 0 ]] && echo pass || echo FAIL)"
      else
        printf '  %-9s no score: %s\n' "$arm" "$(tail -n 1 "$f.err" 2>/dev/null)"
      fi
    done
  fi
  echo
  echo "Not automated: the blind judge over the edited cases (docs/model-swap.md step 3)."
  echo "Run dir: $run_dir"
  echo "Verdict: $verdict — $why."
} | tee "$run_dir/report.txt"

jq -n --arg ts "$stamp" --arg model "$model" --arg base "$base" --arg cand_gb "$cand_gb" \
  --arg champ "$champ_model" --arg champ_base "$champ_base" --arg champ_gb "$champ_gb" \
  --arg chip "$chip" --arg mem "$mem_gb" --arg th0 "${thermal_start:-}" --arg th1 "${thermal_end:-}" \
  --arg measure "$cost_measure" --arg ratio "$cost_ratio" --arg first "${cand_first:-}" \
  --arg g_cand "$g_cand" --arg g_champ "$g_champ" --arg t_cand_rc "$t_cand_rc" \
  --arg verdict "$verdict" --arg why "$why" --arg replay "$(cat "$work_tmp/replay.tsv")" '
  def num: if . == "" or . == "?" or . == "-" or . == "error" then null else tonumber end;
  {schema: 1, ts: $ts,
   candidate: {model: $model, base: $base, weights_gb: ($cand_gb | num)},
   champion: {model: $champ, base: $champ_base, weights_gb: ($champ_gb | num)},
   machine: {chip: $chip, memory_gb: ($mem | num), thermal_start: ($th0 | num), thermal_end: ($th1 | num)},
   cost: {measure: (if $measure == "" then null else $measure end), ratio: ($ratio | num), candidate_first_call_s: ($first | num)},
   replay: [$replay | split("\n")[] | select(. != "") | split("\t")
            | {recipe: .[0], verdict: .[1], n: (.[2] | num), wins: (.[3] | num), losses: (.[4] | num), ties: (.[5] | num),
               errors: (.[6] | num), p: (.[7] | num),
               champion: (.[8] | split(" ") | map(num) | {dropped: .[0], over: .[1], invented: .[2]}),
               candidate: (.[9] | split(" ") | map(num) | {dropped: .[0], over: .[1], invented: .[2]})}],
   grounding: {candidate_auroc: ($g_cand | num), champion_auroc: ($g_champ | num)},
   trigger: {candidate_exit: ($t_cand_rc | num)},
   verdict: $verdict, why: $why}' > "$run_dir/card.json"
exit 0
