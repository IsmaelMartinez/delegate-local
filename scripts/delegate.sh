#!/usr/bin/env bash
# Wrap a local OpenAI-compatible endpoint (MLX, Docker Model Runner or Ollama)
# with tier-based model selection, calibrated recipes, deterministic output
# checks and per-invocation metrics. The HTTP body is plain text, so stdout is
# parser-clean, unlike the `ollama run` CLI this replaced.
#
# Usage:
#   delegate.sh <tier> "<prompt>"                    # context comes from stdin
#   echo "..." | delegate.sh prose "..."             # explicit pipe
#   delegate.sh --recipe NAME [--var k=v ...] ["<prompt>"]
#       prepend prompts/NAME.md with {{k}} substituted ({{stdin}} from the
#       pipe); the tier comes from the recipe's frontmatter `tier:`, --tier
#       overrides it. A lone positional is the tier only when it exactly
#       matches a tier name, otherwise it is the prompt (#411).
#   --recipe auto   infer the recipe from stdin: a unified diff -> commit-message
#                   with diff_stat computed from the diff and recent_commits
#                   backfilled from git log; anything else exits 2, never a guess.
#
# Tiers: read from pick-model.sh, the single source of truth.
#
# Env (each DELEGATE_LOCAL_* accepts the old DELEGATE_TO_OLLAMA_* name when unset):
#   DELEGATE_LOCAL_NO_METRICS=1         skip the metrics row (and the draft capture)
#   DELEGATE_LOCAL_NO_VERDICT_NUDGE=1   silence the verdict reminder on stderr
#   DELEGATE_LOCAL_VERDICT_NUDGE_FD=N   fd for the reminder, 1-9 (default 2); the
#                                       caller must redirect fd N or the write is
#                                       silently lost
#   DELEGATE_LOCAL_NO_META=1            silence the `delegate-meta:` stderr line
#   DELEGATE_PREFLIGHT_TIMEOUT=<s>      recipe-call canary timeout (default 10;
#                                       0 disables); a stalled probe exits 3
#   DELEGATE_NO_PREFLIGHT=1             disable the canary
#   DELEGATE_REQUEST_TIMEOUT=<s>        curl --max-time on the dispatch (default
#                                       600, which covers a cold model load)
#   DELEGATE_BASE_URL=<urls>            ordered OpenAI-compatible base URLs; the
#                                       default list lives in pick-model.sh
#   MLX_HOST / DOCKER_MODEL_HOST / OLLAMA_HOST   feed that default list
#   DELEGATE_FORCE_FLAKY=1              send a recipe its frontmatter marks flaky
#                                       on the resolved model (else exit 4)
#   DELEGATE_LOCAL_DATA_DIR             per-user data (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE=<path>        override the metrics destination
#   DELEGATE_PROJECT=<name>             the project the delegation is FOR, when
#                                       the cwd is not it (#342); --project wins
#   CLAUDE_CODE_SESSION_ID=<uuid>       stamped on the row as `session` so the
#                                       hooks can credit this session (#476)
#   DELEGATE_PROMPTS_DIR=<path>         override prompts/ (default <script_dir>/../prompts)
#   DELEGATE_THINK=true|false           default false; enable_thinking via the
#                                       chat template
#   DELEGATE_STRIP_THINK=1|0            strip a leading <think>...</think> trace;
#                                       on by default for the reasoning tier
#   DELEGATE_MAX_TOKENS=<int>           default 4096
#   DELEGATE_TEMPERATURE / DELEGATE_TOP_P / DELEGATE_TOP_K / DELEGATE_PRESENCE_PENALTY
#                                       sampler overrides (default greedy,
#                                       temperature 0); non-numeric exits 2
#   DELEGATE_OTEL_ENDPOINT=<url>        POST one OTLP/HTTP span per call
#                                       (synchronous: a hung collector adds up
#                                       to DELEGATE_OTEL_TIMEOUT s of latency)
#   DELEGATE_OTEL_TIMEOUT=<s>           default 5
#   DELEGATE_OTEL_VERBOSE=1             log exporter failures (silent by default)
#   DELEGATE_OTEL_HEADERS=<H: v,H: v>   comma-separated; values url-encoded per
#                                       the OTel SDK convention
#   DELEGATE_OTEL_INCLUDE_CONTENT=1     send prompt/context/output in the span;
#                                       off by default because they may carry
#                                       secrets (ADR 0007, docs/otel-schema.md)
#
# Output: model response on stdout. Errors: pick-model and HTTP failures exit
# non-zero with a metrics row still written; OTLP export never changes the exit.

set -uo pipefail

usage() {
  echo 'usage: delegate.sh [--recipe NAME [--var key=value ...]] [--project NAME] [--tier NAME] <tier> ["<prompt>"]' >&2
  echo '       (context piped via stdin; prompt optional when --recipe is set)' >&2
  echo '       --tier NAME is equivalent to the positional <tier> and wins over it;' >&2
  echo '       with --tier the first positional is the prompt.' >&2
}

recipe=""
project_override=""
tier_flag=""
recipe_vars=()
positional=()
while (($# > 0)); do
  case "$1" in
    --recipe)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --recipe requires a value' >&2; exit 2
      fi
      recipe="$2"; shift 2;;
    --recipe=*)
      recipe="${1#--recipe=}"; shift;;
    --var)
      # A following flag is the next option, not this one's value.
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --var requires key=value' >&2; exit 2
      fi
      recipe_vars+=("$2"); shift 2;;
    --var=*)
      recipe_vars+=("${1#--var=}"); shift;;
    --project)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --project requires a value' >&2; exit 2
      fi
      project_override="$2"; shift 2;;
    --project=*)
      project_override="${1#--project=}"; shift;;
    # Without this branch the catch-all read `--tier` as the positional tier.
    --tier)
      if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == -* ]]; then
        echo 'delegate: --tier requires a value' >&2; exit 2
      fi
      tier_flag="$2"; shift 2;;
    --tier=*)
      tier_flag="${1#--tier=}"; shift;;
    --)
      shift
      while (($# > 0)); do positional+=("$1"); shift; done
      ;;
    -h|--help)
      usage; exit 0;;
    *)
      positional+=("$1"); shift;;
  esac
done

# Backwards compat: old env var names (rename delegate-to-ollama → delegate-local).
DELEGATE_LOCAL_NO_METRICS="${DELEGATE_LOCAL_NO_METRICS:-${DELEGATE_TO_OLLAMA_NO_METRICS:-}}"
DELEGATE_LOCAL_NO_VERDICT_NUDGE="${DELEGATE_LOCAL_NO_VERDICT_NUDGE:-${DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE:-}}"
DELEGATE_LOCAL_VERDICT_NUDGE_FD="${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-${DELEGATE_TO_OLLAMA_VERDICT_NUDGE_FD:-}}"
DELEGATE_LOCAL_NO_META="${DELEGATE_LOCAL_NO_META:-${DELEGATE_TO_OLLAMA_NO_META:-}}"

# Validated up-front so a bad value fails before the cold-load cost. 1-9 only:
# bash 3.2 has no `{var}>file` form, so multi-digit FDs via `>&$N` are
# unreliable on the target platform, and 0 (stdin) is nonsense.
nudge_fd="${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-2}"
if ! [[ "$nudge_fd" =~ ^[1-9]$ ]]; then
  echo "delegate: DELEGATE_LOCAL_VERDICT_NUDGE_FD='${DELEGATE_LOCAL_VERDICT_NUDGE_FD:-}' is not a single-digit positive file descriptor (valid: 1-9; 0 is stdin and is rejected, multi-digit FDs are unreliable on bash 3.2)" >&2
  exit 2
fi

# Reject a --var value that is nothing but an unreplaced `<placeholder>` copied
# from a recipe's Invocation block: the model summarises the placeholder and
# the row records an ordinary success (#356). Only a whole-value single bracket
# token is rejected; values that merely contain brackets (diff hunks, HTML,
# `a < b`) must pass. Glob matching, so there is nothing to backtrack.
for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
  [[ "$kv" == *"="* ]] || continue
  placeholder_value="${kv#*=}"
  placeholder_value="${placeholder_value#"${placeholder_value%%[![:space:]]*}"}"
  placeholder_value="${placeholder_value%"${placeholder_value##*[![:space:]]}"}"
  if [[ "$placeholder_value" == "<"*">" ]]; then
    placeholder_inner="${placeholder_value:1:${#placeholder_value}-2}"
    if [[ "$placeholder_inner" != *"<"* && "$placeholder_inner" != *">"* ]]; then
      echo "delegate: --var ${kv%%=*} is an unreplaced placeholder: '$placeholder_value'" >&2
      echo "         substitute the real content before delegating" >&2
      exit 2
    fi
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"
prompts_dir="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"

# Runs here because it needs $pick: the tier vocabulary is read from
# pick-model.sh's own TIERS line. A lone positional is the tier only when it
# EXACTLY matches a known tier name; otherwise it is the prompt and the tier
# comes from the recipe frontmatter, since most recipes pass a trailing
# reinforcement prompt (#411).
known_tiers=$(sed -n 's/^TIERS="\(.*\)"$/\1/p' "$pick" 2>/dev/null | tr '|' ' ')
is_known_tier() {
  local candidate="$1" t
  [[ -z "$known_tiers" ]] && return 1
  for t in $known_tiers; do [[ "$t" == "$candidate" ]] && return 0; done
  return 1
}

if [[ -n "$tier_flag" ]]; then
  tier="$tier_flag"
  prompt="${positional[0]:-}"
elif [[ -n "$recipe" && ${#positional[@]} -eq 1 ]] && ! is_known_tier "${positional[0]}"; then
  tier=""
  prompt="${positional[0]}"
else
  tier="${positional[0]:-}"
  prompt="${positional[1]:-}"
fi

# Without a recipe both are still required. With one, an absent tier is resolved
# from the recipe frontmatter further down, once the recipe file is known.
if [[ -z "$recipe" ]] && { [[ -z "$tier" ]] || [[ -z "$prompt" ]]; }; then
  usage; exit 2
fi

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
# Which base URL wins is not known until the tier is resolved (a provider can
# be reachable yet hold no model for it); this placeholder label only reaches
# a metrics row for a failure before resolution.
resolved_base=""
backend="provider"

# Normalised to a strict JSON boolean before it reaches jq --argjson.
if [[ "${DELEGATE_THINK:-false}" == "true" ]]; then
  think="true"
else
  think="false"
fi

# The one tokens estimate (chars in + out over 4) both the metrics row and
# the meta line use, so the two surfaces cannot drift on the formula.
compute_tokens_local() {
  local pchars=$1 cchars=$2 ochars=$3
  echo $(( (pchars + cchars + ochars) / 4 ))
}

# capture_file <text> <path> <max> — one captured file, written under
# `umask 077` then 600 so there is no window between create and chmod.
# head -c bounds a runaway generation without failing the call; the marker
# keeps a truncated file from being read later as complete. Returns 1 when
# nothing was written, which the callers treat as "no file to name".
capture_file() {
  local text="$1" path="$2" max="$3" bytes
  # Bytes, not ${#text}: that counts characters under a UTF-8 locale.
  bytes=$(printf '%s' "$text" | wc -c | tr -d '[:space:]')
  if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 10#$max )); then
    ( umask 077
      { printf '%s' "$text" | head -c "$max"; printf '\n[truncated at %s bytes by DELEGATE_DRAFT_MAX_BYTES]\n' "$max"; } \
        > "$path" ) 2>/dev/null || return 1
  else
    ( umask 077; printf '%s' "$text" > "$path" ) 2>/dev/null || return 1
  fi
  chmod 600 "$path" 2>/dev/null || true
}

# capture_draft <draft> <ts> [<input>] [<inputs-json>] — persist the
# generated draft beside the metrics row that scores it and, when given, the
# rendered input the model saw (#516) and the structured inputs it was
# rendered from, under one stem; echo the basenames for the row's
# `draft_file`, `input_file` and `inputs_file`, tab-separated, each absent
# when none was written. With the shipped text from `delegate-feedback.sh
# --final` a MISS becomes a (generated, shipped) pair the calibration loop
# can diff, and the input is what that pair is scored against: which
# supplied anchors each half carried, which supplied sentences the draft
# handed back. The structured inputs (the piped stdin, every --var, the
# positional prompt) are what lets replay-recipe.sh render the same case
# under an edited template: the rendered input cannot be un-rendered, and the
# 2026-09-16 spike recovered only 42 of 135 cases from transcripts for want
# of them. Local-only: the files sit under DELEGATE_LOCAL_DATA_DIR and
# inherit the sensitivity of the piped context; both inputs hold all of it.
# One cap, one retention, one opt-out for all three files:
# DELEGATE_NO_DRAFT_CAPTURE=1 writes none, and all are skipped when metrics
# are off.
capture_draft() {
  local text="$1" ts="$2" input="${3:-}" inputs="${4:-}" stem dir max names
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 0
  [[ "${DELEGATE_NO_DRAFT_CAPTURE:-}" == "1" ]] && return 0
  [[ -n "$text" ]] || return 0
  dir="$(dirname "$metrics_file")/drafts"
  mkdir -p "$dir" 2>/dev/null || return 0
  # 700 on the directory, 600 on the files.
  chmod 700 "$dir" 2>/dev/null || true
  # The ts alone is not a safe name: second precision, and parallel callers
  # collide. The span id makes the stem unique; the ts stays in front so the
  # directory sorts chronologically, colons dropped for shell globs.
  stem=$(printf '%s' "$ts" | tr -d ':-')
  if [[ -n "${otel_span_id:-}" ]]; then
    stem="$stem-${otel_span_id:0:8}"
  else
    stem="$stem-$$"
  fi
  max="${DELEGATE_DRAFT_MAX_BYTES:-65536}"
  if ! [[ "$max" =~ ^[1-9][0-9]*$ ]]; then
    echo "delegate: DELEGATE_DRAFT_MAX_BYTES='$max' is not a positive integer — using 65536" >&2
    max=65536
  fi
  capture_file "$text" "$dir/$stem.draft.txt" "$max" || return 0
  names="$stem.draft.txt"
  # The input shares the draft's stem, so the pair maps back to it the way a
  # final does (ADR 0029), and the row names it only when it was written.
  if [[ -n "$input" ]] && capture_file "$input" "$dir/$stem.input.txt" "$max"; then
    names="$names"$'\t'"$stem.input.txt"
  fi
  if [[ -n "$inputs" ]] && capture_file "$inputs" "$dir/$stem.inputs.json" "$max"; then
    names="$names"$'\t'"$stem.inputs.json"
  fi
  # Retention prune, inline so there is no cron dependency. 0 disables.
  # -mtime +N behaves the same on BSD and GNU find; '*.txt' takes drafts,
  # inputs and finals together, '*.json' the structured inputs.
  local keep="${DELEGATE_DRAFT_RETENTION_DAYS:-14}"
  if [[ "$keep" =~ ^[0-9]+$ ]] && (( 10#$keep > 0 )); then
    find "$dir" -type f \( -name '*.txt' -o -name '*.json' \) -mtime "+$keep" -exec rm -f {} + 2>/dev/null || true
  fi
  printf '%s' "$names"
}

# Returns 0 only when a row was appended: the meta line and the verdict nudge
# name that row's ts and id, so both are gated on this status (#474). Failure
# is non-fatal for the delegation itself.
log_metric() {
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]] && return 1
  local ts="$1" tier="$2" model="$3" pchars="$4" cchars="$5" ochars="$6" dur_ms="$7" status="$8" recipe_name="${9:-}" qwait_ms="${10:-0}" gen_ms="${11:-0}" trace_id="${12:-}" span_id="${13:-}" \
    s_temp="${14:-}" s_top_p="${15:-}" s_top_k="${16:-}" s_pp="${17:-}" project="${18:-}" \
    checks_run="${19:-}" checks_failed="${20:-}" checks_autofixed="${21:-}" checks_failed_names="${22:-}" \
    draft_file="${23:-}" retried="${24:-}" retry_chars="${25:-}" input_file="${26:-}" \
    template_sha="${27:-}" inputs_file="${28:-}"
  local tokens_avoided
  tokens_avoided=$(compute_tokens_local "$pchars" "$cchars" "$(( ochars + ${retry_chars:-0} ))")
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  # source:"delegate" discriminates from experiment-runner rows in the same
  # file; a missing backend reads as ollama downstream. duration_ms stays the
  # inclusive total; queue_wait_ms + generation_ms sum to it within rounding.
  # The otel ids are written unconditionally so feedback rows and backfills
  # join without a second lookup. jq builds the line because model ids come
  # from whatever a provider reports. Optional fields (recipe, project,
  # session, sampling_*) are present iff set, so the row shape is stable.
  jq -nc \
    --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
    --arg recipe "$recipe_name" --arg project "$project" --arg session "${CLAUDE_CODE_SESSION_ID:-}" \
    --arg trace_id "$trace_id" --arg span_id "$span_id" \
    --arg s_temp "$s_temp" --arg s_top_p "$s_top_p" --arg s_top_k "$s_top_k" --arg s_pp "$s_pp" \
    --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
    --argjson dur_ms "$dur_ms" --argjson qwait_ms "$qwait_ms" --argjson gen_ms "$gen_ms" \
    --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
    --arg crun "$checks_run" --arg cfail "$checks_failed" --arg cfix "$checks_autofixed" \
    --arg cnames "$checks_failed_names" --arg draft "$draft_file" --arg input "$input_file" \
    --arg retried "$retried" --arg retry_chars "$retry_chars" \
    --arg tsha "$template_sha" --arg inputs "$inputs_file" \
    '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, queue_wait_ms:$qwait_ms, generation_ms:$gen_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}
     + (if $recipe != "" then {recipe:$recipe} else {} end)
     + (if $tsha != "" then {template_sha:$tsha} else {} end)
     + (if $project != "" then {project:$project} else {} end)
     + (if $session != "" then {session:$session} else {} end)
     + (if $trace_id != "" then {otel_trace_id:$trace_id} else {} end)
     + (if $span_id != "" then {otel_span_id:$span_id} else {} end)
     + (if $s_temp != "" then {sampling_temperature:($s_temp|tonumber)} else {} end)
     + (if $s_top_p != "" then {sampling_top_p:($s_top_p|tonumber)} else {} end)
     + (if $s_top_k != "" then {sampling_top_k:($s_top_k|tonumber)} else {} end)
     + (if $s_pp != "" then {sampling_presence_penalty:($s_pp|tonumber)} else {} end)
     + (if ($crun != "" and ($crun|tonumber) > 0) then {checks_run:($crun|tonumber), checks_failed:($cfail|tonumber), checks_autofixed:($cfix|tonumber)} else {} end)
     + (if $cnames != "" then {checks_failed_names:($cnames|split(","))} else {} end)
     + (if $draft != "" then {draft_file:$draft} else {} end)
     + (if $input != "" then {input_file:$input} else {} end)
     + (if $inputs != "" then {inputs_file:$inputs} else {} end)
     + (if $retried != "" then {retried:true, retry_chars:($retry_chars|tonumber)} else {} end)' \
    >> "$metrics_file" 2>/dev/null
}

# Shared with delegate-feedback.sh and backfill-otel.sh; sourcing has no side effects.
# shellcheck source=lib/otel.sh
. "$script_dir/lib/otel.sh"
# recipe_tier lives in lib/recipe.sh so the boundary hook reads the tier with
# the exact expression used here.
# shellcheck source=lib/recipe.sh
. "$script_dir/lib/recipe.sh"

# The cwd derivation is only right when delegate.sh runs inside the repo the
# delegation is FOR; delegating for repo X from the skill checkout recorded
# project=delegate-local and the boundary hook never matched (#342). Flag
# beats env beats cwd; exported so delegate_project_name resolves it.
[[ -n "$project_override" ]] && export DELEGATE_PROJECT="$project_override"
delegate_project=$(delegate_project_name)

ts_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')

# Generated unconditionally so the row carries the ids even when the exporter
# is off; feedback rows and backfills join on them.
otel_trace_id=$(otel_gen_id 32)
otel_span_id=$(otel_gen_id 16)

# One metrics row + span for an early-exit failure (pick-model, flaky gate,
# canary): zero output chars, the elapsed time attributed to generation_ms.
emit_failure() {
  local fstatus="$1" fmodel="$2" fs_temp="${3:-}" fs_top_p="${4:-}" fs_top_k="${5:-}" fs_pp="${6:-}"
  local fend fdur fp fc ftoks
  fend=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  fdur=$((fend - start_epoch_ms))
  fp=$(( ${#recipe_template} + ${#prompt} ))
  fc=${#context}
  ftoks=$(compute_tokens_local "$fp" "$fc" 0)
  log_metric "$ts_start" "$tier" "$fmodel" "$fp" "$fc" 0 "$fdur" "$fstatus" "$recipe" 0 "$fdur" "$otel_trace_id" "$otel_span_id" "$fs_temp" "$fs_top_p" "$fs_top_k" "$fs_pp" "$delegate_project"
  emit_otel_span "$start_epoch_ms" "$fdur" "$fstatus" "$otel_trace_id" "$otel_span_id" "$fmodel" "$backend" "$tier" "$recipe" "$fp" "$fc" 0 0 "$fdur" "$ftoks" "${recipe_template}${prompt}" "$context" "" "$delegate_project"
}

# stdin is read early so {{stdin}} can be substituted before model resolution.
# `-p || -s` rather than `! -t 0`: the latter is true for a socket or FIFO
# holding no data, and `cat` then blocks forever (Agent SDK run_in_background,
# #169). `read -t 0 -N 0` is bash 4+ only.
context=""
if [[ -p /dev/stdin || -s /dev/stdin ]]; then
  context=$(cat)
fi

# --recipe auto (#277): one high-confidence mapping, a unified diff on stdin
# -> commit-message. diff_stat is computed FROM the piped diff so it matches
# what was piped even when the index is clean; recent_commits is real repo
# state, so it is backfilled from git log; `why` is never inferable and stays
# a required --var. Anything else is an explicit error, never a guess.
if [[ "$recipe" == "auto" ]]; then
  if [[ -z "$context" ]]; then
    echo "delegate: --recipe auto needs context on stdin to infer a recipe (none piped). Pass --recipe NAME explicitly; see prompts/README.md." >&2
    exit 2
  fi
  # A here-string, not `printf | grep -q`: grep exits on the first match and
  # printf then takes SIGPIPE on any diff over the pipe buffer, so under
  # pipefail every diff past ~64 KiB fell through to "could not infer" (#480).
  if grep -Eq '^diff --git |^@@ ' <<<"$context"; then
    recipe="commit-message"
    _auto_have_var() { local k="$1" v; for v in ${recipe_vars[@]+"${recipe_vars[@]}"}; do [[ "$v" == "$k="* ]] && return 0; done; return 1; }
    if ! _auto_have_var diff_stat; then
      # awk over the piped diff, not `git diff --stat`, so the summary reflects
      # exactly what was piped.
      _auto_ds=$(printf '%s\n' "$context" | awk '
        /^diff --git / { if (f != "") printf " %s | +%d -%d\n", f, a, d; f=$3; sub(/^a\//,"",f); a=0; d=0; next }
        /^\+\+\+ / || /^--- / { next }
        /^\+/ { a++ }
        /^-/  { d++ }
        END { if (f != "") printf " %s | +%d -%d\n", f, a, d }')
      [[ -n "$_auto_ds" ]] && recipe_vars+=("diff_stat=$_auto_ds")
    fi
    if ! _auto_have_var recent_commits; then
      # Bodies stay (bodyless anchors produced subject-only messages); the
      # trailer lines go, because a `Refs:` or Co-Authored-By line copied
      # from a previous commit names the wrong issue every time (#501).
      # Case-insensitive: GitHub's squash trailer is Co-authored-by.
      _auto_rc=$(git log -3 --pretty=fuller 2>/dev/null \
        | grep -viE '^[[:space:]]*(Refs|Co-Authored-By|Claude-Session|Signed-off-by):' || true)
      [[ -n "$_auto_rc" ]] && recipe_vars+=("recent_commits=$_auto_rc")
    fi
    echo "delegate: --recipe auto inferred commit-message from the piped diff" >&2
  else
    echo "delegate: --recipe auto could not infer a recipe from the piped context (expected a unified diff for commit-message). Pass --recipe NAME explicitly; see prompts/README.md." >&2
    exit 2
  fi
fi

# Resolve recipe template (if any) and substitute {{key}} placeholders.
recipe_template=""
recipe_had_stdin_marker=0
declared_inputs_present=0
template_sha=""
if [[ -n "$recipe" ]]; then
  recipe_file="$prompts_dir/${recipe}.md"
  if [[ ! -f "$recipe_file" ]]; then
    echo "delegate: recipe '$recipe' not found at $recipe_file" >&2
    exit 2
  fi
  # The template that produced this row, as a short content hash, so the
  # outcomes before and after a recipe edit can be told apart without git
  # archaeology (replay-recipe.sh reads it, self-improve.sh splits on it).
  # Empty, and the field omitted, where shasum is missing.
  if command -v shasum >/dev/null 2>&1; then
    template_sha=$(shasum -a 256 "$recipe_file" 2>/dev/null | cut -c1-12)
  fi

  # Frontmatter `tier:` (#411); an explicit tier (positional or --tier) still
  # wins. Read by `recipe_tier` in lib/recipe.sh, shared with the boundary hook.
  if [[ -z "$tier" ]]; then
    tier=$(recipe_tier "$recipe_file")
    if [[ -z "$tier" ]]; then
      {
        echo "delegate: recipe '$recipe' declares no tier and none was given"
        echo "         add a frontmatter 'tier: <name>' to $recipe_file,"
        echo "         or pass one: delegate.sh --recipe $recipe --tier <name> ..."
      } >&2
      exit 2
    fi
  fi

  # Frontmatter `inputs:` block: flat `key: type` pairs only (integer, string,
  # `?` suffix for optional), parsed with awk so there is no yq dependency.
  # Validated BEFORE placeholder substitution so the caller gets a type error
  # rather than "missing placeholder"; recipes without the block skip it.
  inputs_block=$(awk '
    BEGIN { in_fm=0; in_inputs=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^inputs:[[:space:]]*$/ { in_inputs=1; next }
    in_fm && in_inputs && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*[a-zA-Z?]+[[:space:]]*$/ { print; next }
    in_fm && in_inputs && /^[a-zA-Z_]/ { in_inputs=0 }
  ' "$recipe_file")

  if [[ -n "$inputs_block" ]]; then
    # Parallel indexed arrays: bash 3.2 has no associative arrays. The `?` is
    # parsed off into declared_optional so the type stays a clean enum.
    declared_keys=()
    declared_types=()
    declared_optional=()
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      trimmed="${line#"${line%%[![:space:]]*}"}"
      ikey="${trimmed%%:*}"
      itype_raw="${trimmed#*:}"
      itype_raw="${itype_raw#"${itype_raw%%[![:space:]]*}"}"
      itype_raw="${itype_raw%"${itype_raw##*[![:space:]]}"}"
      iopt=0
      if [[ "$itype_raw" == *"?" ]]; then
        iopt=1
        itype="${itype_raw%?}"
      else
        itype="$itype_raw"
      fi
      case "$itype" in
        integer|string) ;;
        *)
          echo "delegate: recipe '$recipe' inputs:$ikey declares unsupported type '$itype_raw'" >&2
          echo "         supported types: integer, string, integer?, string?" >&2
          exit 2
          ;;
      esac
      declared_keys+=("$ikey")
      declared_types+=("$itype")
      declared_optional+=("$iopt")
    done <<< "$inputs_block"
    declared_inputs_present=1

    # provided_keys is newline-delimited and matched with grep -Fxq so `pr`
    # does not match `pr_number`.
    provided_keys=""
    for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
      if [[ "$kv" != *"="* ]]; then
        echo "delegate: --var must be key=value, got '$kv'" >&2
        exit 2
      fi
      pkey="${kv%%=*}"
      pvalue="${kv#*=}"
      if [[ -z "$pkey" ]]; then
        echo "delegate: --var has empty key in '$kv'" >&2
        exit 2
      fi
      # Undeclared --var keys pass through untouched (strict mode deferred).
      idx=0
      for dk in "${declared_keys[@]}"; do
        if [[ "$dk" == "$pkey" ]]; then
          dtype="${declared_types[$idx]}"
          case "$dtype" in
            integer)
              if ! [[ "$pvalue" =~ ^-?[0-9]+$ ]]; then
                echo "delegate: --var $pkey expected type 'integer', got '$pvalue'" >&2
                exit 2
              fi
              ;;
            string)
              # Empty is permitted, for an intentional blank.
              :
              ;;
          esac
          break
        fi
        idx=$((idx + 1))
      done
      provided_keys="${provided_keys}${pkey}"$'\n'
    done

    # Piped stdin satisfies a declared `stdin:` input, type-checked the same way.
    if [[ -n "$context" ]]; then
      provided_keys="${provided_keys}stdin"$'\n'
      sidx=0
      for dk in "${declared_keys[@]}"; do
        if [[ "$dk" == "stdin" ]]; then
          stype="${declared_types[$sidx]}"
          case "$stype" in
            integer)
              if ! [[ "$context" =~ ^-?[0-9]+$ ]]; then
                echo "delegate: piped stdin expected type 'integer' (declared by recipe '$recipe'), got non-integer value" >&2
                exit 2
              fi
              ;;
            string)
              :
              ;;
          esac
          break
        fi
        sidx=$((sidx + 1))
      done
    fi

    # Every missing required key is listed in one error.
    missing_required=""
    idx=0
    for dk in "${declared_keys[@]}"; do
      if (( declared_optional[idx] == 0 )); then
        if ! printf '%s' "$provided_keys" | grep -Fxq "$dk"; then
          missing_required="${missing_required}${dk} "
        fi
      fi
      idx=$((idx + 1))
    done
    if [[ -n "${missing_required// /}" ]]; then
      echo "delegate: recipe '$recipe' missing required inputs: ${missing_required% }" >&2
      echo "         pass them via --var key=value" >&2
      exit 2
    fi
  fi

  # First fenced block under '## Prompt template'. The `/^## /` section end is
  # gated on `!in_block` so a heading inside the fenced block does not close it.
  recipe_template=$(awk '
    /^## Prompt template[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section && !in_block { in_section=0 }
    in_section && /^```/ {
      if (in_block) { exit }
      in_block=1; next
    }
    in_section && in_block { print }
  ' "$recipe_file")
  if [[ -z "$recipe_template" ]]; then
    echo "delegate: recipe '$recipe' has empty or missing '## Prompt template' fenced block" >&2
    exit 2
  fi
  # The PRE-substitution template: every later assignment folds caller values
  # in, and no_example_echo must compare against recipe-authored text only.
  recipe_template_raw="$recipe_template"

  # Frontmatter `checks:` block (ADR 0014), extracted here so it rides the
  # same {{key}} substitution as the template: a check value may reference a
  # flavor placeholder and must stay consistent with the prompt.
  recipe_checks=$(awk '
    BEGIN { in_fm=0; in_checks=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^checks:[[:space:]]*$/ { in_checks=1; next }
    in_fm && in_checks && /^[[:space:]]+[a-zA-Z_]/ { print; next }
    in_fm && in_checks && /^[a-zA-Z_]/ { in_checks=0 }
  ' "$recipe_file")

  # Frontmatter `echo_guard_vars:`: comma-separated --var names whose values
  # are shape exemplars and must never come back in the output (#428).
  recipe_echo_guard_vars=$(awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^echo_guard_vars:[[:space:]]*/ {
      sub(/^echo_guard_vars:[[:space:]]*/, ""); print; exit
    }
  ' "$recipe_file")

  # Placeholders of the ORIGINAL template, so substituted values that contain
  # `{{...}}` (Vue bindings, Go templates) do not trip the guard below.
  required_placeholders=$(printf '%s' "$recipe_template" | grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' | sort -u)

  # Values came in via argv, so they may hold newlines and any punctuation.
  satisfied_keys=""
  for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
    if [[ "$kv" != *"="* ]]; then
      echo "delegate: --var must be key=value, got '$kv'" >&2
      exit 2
    fi
    key="${kv%%=*}"
    value="${kv#*=}"
    if [[ -z "$key" ]]; then
      echo "delegate: --var has empty key in '$kv'" >&2
      exit 2
    fi
    # The key is interpolated into a pattern replacement, so a glob
    # metacharacter in it would make the substitution overbroad.
    if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      echo "delegate: --var has invalid key '$key' in '$kv'" >&2
      echo "         keys must match ^[a-zA-Z_][a-zA-Z0-9_]*$ (letters, digits, underscore)" >&2
      exit 2
    fi
    recipe_template="${recipe_template//\{\{$key\}\}/$value}"
    recipe_checks="${recipe_checks//\{\{$key\}\}/$value}"
    satisfied_keys="${satisfied_keys}{{${key}}}"$'\n'
  done

  # Per-user flavor profile (ADR 0013), injected as {{flavor_*}} placeholders
  # AFTER the --var loop so an explicit --var flavor_x= still wins. Gated on
  # the template using one, so other recipes skip the loader subprocess.
  # Process substitution, not a pipe, so the substitutions land in this shell.
  if [[ "$recipe_template$recipe_checks" == *'{{flavor_'* ]]; then
    while IFS='=' read -r fkey fval; do
      # Only flavor_* keys, so a value with an embedded newline cannot
      # substitute a non-flavor placeholder.
      [[ "$fkey" != flavor_* ]] && continue
      # The checks block always resolves flavor refs so subject_max stays in
      # sync with the prompt's cap.
      recipe_checks="${recipe_checks//\{\{$fkey\}\}/$fval}"
      if ! printf '%s' "$satisfied_keys" | grep -Fxq "{{${fkey}}}"; then
        recipe_template="${recipe_template//\{\{$fkey\}\}/$fval}"
        satisfied_keys="${satisfied_keys}{{${fkey}}}"$'\n'
      fi
    done < <(bash "$script_dir/load-flavor.sh" 2>/dev/null)
  fi

  # Optional inputs the caller did not supply collapse to empty BEFORE the
  # unsubstituted-placeholder guard, so an optional placeholder in the body
  # does not exit 2. Guarded on declared_inputs_present so "${declared_keys[@]}"
  # is only expanded when the array was built (bash 3.2 + set -u).
  if (( declared_inputs_present == 1 )); then
    oidx=0
    for dk in "${declared_keys[@]}"; do
      if (( declared_optional[oidx] == 1 )) \
         && ! printf '%s' "$satisfied_keys" | grep -Fxq "{{${dk}}}"; then
        recipe_template="${recipe_template//\{\{$dk\}\}/}"
        recipe_checks="${recipe_checks//\{\{$dk\}\}/}"
        satisfied_keys="${satisfied_keys}{{${dk}}}"$'\n'
      fi
      oidx=$((oidx + 1))
    done
  fi

  # {{stdin}} is the implicit placeholder for the piped context.
  if grep -qx '{{stdin}}' <<<"$required_placeholders"; then
    recipe_had_stdin_marker=1
    recipe_template="${recipe_template//\{\{stdin\}\}/$context}"
    satisfied_keys="${satisfied_keys}{{stdin}}"$'\n'
  fi

  # Compared against the original-template placeholder set, not the
  # post-substitution string, so legit `{{...}}` content survives.
  missing=""
  while IFS= read -r ph; do
    [[ -z "$ph" ]] && continue
    if ! printf '%s' "$satisfied_keys" | grep -Fxq "$ph"; then
      missing="${missing}${ph} "
    fi
  done <<< "$required_placeholders"
  if [[ -n "${missing// /}" ]]; then
    echo "delegate: recipe '$recipe' has unsubstituted placeholders: $missing" >&2
    echo "         pass them via --var key=value (or {{stdin}} via piped context)" >&2
    exit 2
  fi
fi

# pick-model.sh exit 2 is "that tier does not exist", exit 1 is "no installed
# model matches it"; the remedies are opposite, and the valid-tier list is
# echoed from its own message so there is one source of truth.
pick_err=$(mktemp)
# One call, not two: --print-resolution returns "<base>\t<model>" so a dead
# provider in the list is probed once rather than once per question.
_resolved=$(bash "$pick" --print-resolution "$tier" 2>"$pick_err")
pick_rc=$?
if [[ $pick_rc -eq 0 ]]; then
  resolved_base="${_resolved%%	*}"
  model="${_resolved#*	}"
  # lib/otel.sh maps this to gen_ai.provider.name and the dashboards sum by
  # backend, so neither the URL nor a flat "provider" will do. Never "openai":
  # that is a registered SemConv value meaning OpenAI.
  case "$resolved_base" in
    *:8080*)  backend="mlx" ;;
    *:12434*) backend="docker" ;;
    *:11434*) backend="ollama" ;;
    *) backend=$(printf '%s' "$resolved_base" | sed -E 's|^[a-z]+://||; s|/.*$||') ;;
  esac
else
  model=""
fi
pick_msg=$(cat "$pick_err" 2>/dev/null)
rm -f "$pick_err"
if [[ $pick_rc -ne 0 ]]; then
  if [[ $pick_rc -eq 2 ]]; then
    emit_failure 2 "(none)"
    {
      echo "delegate: ${pick_msg:-unknown tier: $tier}"
      if [[ "$tier" == -* ]]; then
        echo "         '$tier' is not a flag delegate.sh knows, so it was read as the positional tier."
        echo "         the tier is positional: delegate.sh [options] <tier> [\"<prompt>\"] — or pass --tier $tier."
      else
        echo "         '$tier' is not a tier — pick one from the valid list above."
      fi
      echo "         tiers name the TASK, not the model size: there is no small/fast/medium/light/standard tier."
      echo "         prose = commit messages, PR descriptions, replies, summaries; code = code drafts;"
      echo "         long-context = big logs and many-file diffs; reasoning = genuine multi-step reasoning."
      echo "         nothing needs installing — re-run with a valid tier."
    } >&2
    exit 2
  fi
  emit_failure 1 "(none)"
  {
    echo "delegate: pick-model failed for tier '$tier'"
    [[ -n "$pick_msg" ]] && echo "         $pick_msg"
    echo "         no installed model matches this tier — run scripts/audit-models.sh to see routing, or pull a model from the tier's preference list in scripts/pick-model.sh"
    echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
  } >&2
  exit 1
fi

# Recipe-level flaky-on-model gate: a frontmatter `flaky_on_models:` list of
# case-insensitive substrings refuses (exit 4) on a matching model unless
# DELEGATE_FORCE_FLAKY=1. Before the canary: no point probing a model the
# recipe already classifies as unreliable.
if [[ -n "$recipe" ]] && [[ "${DELEGATE_FORCE_FLAKY:-}" != "1" ]]; then
  flaky_list=$(awk '
    BEGIN { in_fm=0; in_flaky=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^flaky_on_models:[[:space:]]*$/ { in_flaky=1; next }
    in_fm && in_flaky && /^[[:space:]]+-[[:space:]]+[^[:space:]]/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
      next
    }
    in_fm && in_flaky && /^[a-zA-Z_]/ { in_flaky=0 }
  ' "$recipe_file")
  if [[ -n "$flaky_list" ]]; then
    model_lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
    matched_pat=""
    while IFS= read -r pat; do
      [[ -z "$pat" ]] && continue
      pat_lower=$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')
      if [[ "$model_lower" == *"$pat_lower"* ]]; then
        matched_pat="$pat"
        break
      fi
    done <<< "$flaky_list"
    if [[ -n "$matched_pat" ]]; then
      emit_failure 4 "$model"
      {
        echo "delegate: recipe '$recipe' is flagged as flaky on model '$model'"
        echo "         (matched frontmatter pattern '$matched_pat'; see prompts/$recipe.md calibration notes)"
        echo "         Options:"
        echo "         - hand-write the output (recommended — the recipe documents this as the active mitigation)"
        echo "         - route to a different tier (e.g. --tier code) and retry"
        echo "         - override with DELEGATE_FORCE_FLAKY=1 (sends the request; expect known-flaky behaviour)"
      } >&2
      exit 4
    fi
  fi
fi

# Sampler profile: greedy (temperature 0, no top_p/top_k/presence_penalty)
# for every model. The Qwen-recommended profile was auto-applied once and
# measured to regress commit-message output (temperature reintroduces the
# padding tails the recipe guards reject), so non-greedy is opt-in via the
# env vars. model_family is not emitted yet; it is a hook for future audit work.
model_family=""
model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lc" in
  *qwen3.6*|*qwen3-coder*|*qwen3-next*|*qwen3.5*)
    model_family="qwen3"
    ;;
esac

# The parallel `metric_*` set carries only what the caller explicitly opted
# into, so a bare greedy call writes no sampling_* keys to the row.
sampling_temperature="0"
sampling_top_p=""
sampling_top_k=""
sampling_presence_penalty=""
metric_sampling_temperature=""
metric_sampling_top_p=""
metric_sampling_top_k=""
metric_sampling_presence_penalty=""

validate_numeric() {
  # bash 3.2 =~ POSIX ERE: optional minus, then digits, digits.digits,
  # digits. or .digits. A permissive `case` pattern let `1-2` reach jq --argjson.
  local name="$1" value="$2"
  if ! [[ "$value" =~ ^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]]; then
    echo "delegate: $name='$value' is not numeric" >&2
    exit 2
  fi
}

if [[ -n "${DELEGATE_TEMPERATURE:-}" ]]; then
  validate_numeric "DELEGATE_TEMPERATURE" "$DELEGATE_TEMPERATURE"
  sampling_temperature="$DELEGATE_TEMPERATURE"
  metric_sampling_temperature="$DELEGATE_TEMPERATURE"
fi
if [[ -n "${DELEGATE_TOP_P:-}" ]]; then
  validate_numeric "DELEGATE_TOP_P" "$DELEGATE_TOP_P"
  sampling_top_p="$DELEGATE_TOP_P"
  metric_sampling_top_p="$DELEGATE_TOP_P"
fi
if [[ -n "${DELEGATE_TOP_K:-}" ]]; then
  validate_numeric "DELEGATE_TOP_K" "$DELEGATE_TOP_K"
  sampling_top_k="$DELEGATE_TOP_K"
  metric_sampling_top_k="$DELEGATE_TOP_K"
fi
if [[ -n "${DELEGATE_PRESENCE_PENALTY:-}" ]]; then
  validate_numeric "DELEGATE_PRESENCE_PENALTY" "$DELEGATE_PRESENCE_PENALTY"
  sampling_presence_penalty="$DELEGATE_PRESENCE_PENALTY"
  metric_sampling_presence_penalty="$DELEGATE_PRESENCE_PENALTY"
fi

# Pre-flight canary, recipe calls only (#110): a 1-token probe with a bounded
# timeout on the same backend, model and think setting catches a stalled
# model before the caller's input investment is sunk.
preflight_timeout="${DELEGATE_PREFLIGHT_TIMEOUT:-10}"
if [[ -n "$recipe" ]] \
   && [[ "${DELEGATE_NO_PREFLIGHT:-}" != "1" ]] \
   && [[ "$preflight_timeout" =~ ^[0-9]+$ ]] \
   && (( 10#$preflight_timeout > 0 )); then
  # Greedy, max_tokens 1: the only signal wanted is "did the model respond".
  canary_payload=$(jq -nc --arg m "$model" --argjson et "$think" \
    '{model:$m, messages:[{role:"user", content:"hi"}], stream:false, temperature:0, max_tokens:1, chat_template_kwargs:{enable_thinking:$et}}')
  canary_url="$resolved_base/chat/completions"
  curl -sS --fail --max-time "$preflight_timeout" -X POST "$canary_url" -d @- >/dev/null 2>&1 <<< "$canary_payload"
  canary_status=$?
  if (( canary_status != 0 )); then
    emit_failure 3 "$model" "$metric_sampling_temperature" "$metric_sampling_top_p" "$metric_sampling_top_k" "$metric_sampling_presence_penalty"
    # 28 is --max-time, 7 is connection refused, 22 is --fail on a non-2xx.
    case "$canary_status" in
      28) canary_cause="did not return within ${preflight_timeout}s (curl --max-time fired)" ;;
      7)  canary_cause="could not reach $canary_url (connection refused; backend daemon may be down)" ;;
      22) canary_cause="received an HTTP error response (curl --fail; likely a bad model name or invalid payload)" ;;
      *)  canary_cause="failed with curl exit $canary_status" ;;
    esac
    {
      echo "delegate: pre-flight canary $canary_cause"
      echo "         recipe='$recipe' tier='$tier' model='$model' backend='$backend'"
      echo "         Options:"
      echo "         - retry with DELEGATE_PREFLIGHT_TIMEOUT=30 if cold-load is suspected"
      echo "         - start the provider daemon (mlx_lm.server, Docker Model Runner or ollama serve) and confirm MLX_HOST / DOCKER_MODEL_HOST / OLLAMA_HOST"
      echo "         - re-route to a smaller-parameter model on this host"
      echo "         - hand-write the output (recommended for 35B-class prose tiers on recipe-shaped prompts — see prompts/$recipe.md)"
      echo "         - silence the probe with DELEGATE_NO_PREFLIGHT=1 (sends the full request and inherits the failure)"
      echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
    } >&2
    exit 3
  fi
fi

# The recipe template goes first, piped context follows unless {{stdin}}
# absorbed it, and the prompt arg is the trailing instruction.
parts=()
if [[ -n "$recipe_template" ]]; then
  parts+=("$recipe_template")
  if [[ -n "$context" ]] && (( recipe_had_stdin_marker == 0 )); then
    parts+=("$context")
  fi
  if [[ -n "$prompt" ]]; then
    parts+=("$prompt")
  fi
else
  if [[ -n "$context" ]]; then
    parts+=("$context")
  fi
  parts+=("$prompt")
fi

# Join with a blank line between parts.
full_input=""
for p in "${parts[@]}"; do
  if [[ -z "$full_input" ]]; then
    full_input="$p"
  else
    full_input="${full_input}

${p}"
  fi
done

# jq builds the payload so quotes, backslashes and newlines escape correctly.
# curl -w "%{time_starttransfer}" is the closest proxy for queue wait plus
# cold load (#170); body and TTFB are captured separately (-o plus -w) so the
# response stays parser-clean.
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT

# Sentinel for "the call succeeded but the model returned nothing", above
# curl's exit-code range (max 99) so it is never read as a transport failure;
# it shows in the metrics row as exit_status:100.
EMPTY_RESPONSE_STATUS=100
# Initialised here because the script runs under `set -u`.
empty_finish_reason=""

# dispatch_to_model <model> — POST the request, parse the response into the
# globals $output, $status, $ttfb_s, $payload, and strip any reasoning trace.
dispatch_to_model() {
local _model="$1"
# Not validated: a non-numeric value makes curl print its own clear error.
# Not local: the dispatch-failure guidance below reads it.
request_timeout="${DELEGATE_REQUEST_TIMEOUT:-600}"
# /chat/completions, never /v1/completions: the raw-prompt endpoint bypasses
# the chat template and instruction-tuned models emit whitespace until
# max_tokens. enable_thinking is passed so `content` carries the answer, not
# the reasoning trace.
max_tokens="${DELEGATE_MAX_TOKENS:-4096}"
# The payload carries only the sampler keys the caller opted into; with none
# it is the bare {temperature:0} greedy shape.
payload=$(jq -nc --arg m "$_model" --arg p "$full_input" --argjson mt "$max_tokens" --argjson et "$think" \
  --argjson temp "$sampling_temperature" \
  --arg top_p "$sampling_top_p" --arg top_k "$sampling_top_k" --arg pp "$sampling_presence_penalty" \
  '{model:$m, messages:[{role:"user", content:$p}], stream:false, temperature:$temp, max_tokens:$mt, chat_template_kwargs:{enable_thinking:$et}}
    + (if $top_p != "" then {top_p:($top_p|tonumber)} else {} end)
    + (if $top_k != "" then {top_k:($top_k|tonumber)} else {} end)
    + (if $pp != "" then {presence_penalty:($pp|tonumber)} else {} end)')
# resolved_base already had one trailing slash stripped by pick-model.sh, so
# the join cannot double up.
chat_url="$resolved_base/chat/completions"
ttfb_s=$(curl -sS --fail --max-time "$request_timeout" --connect-timeout 5 \
  -X POST "$chat_url" -d @- \
  -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
status=$?
if [[ "$status" -eq 0 ]]; then
  output=$(jq -r '.choices[0].message.content // ""' < "$body_file")
  # Empty content on a well-formed response is a failure, not a short answer:
  # a provider that ignores enable_thinking spends the budget on reasoning
  # and returns finish_reason "length" with `content` empty.
  if [[ -z "$output" ]]; then
    empty_finish_reason=$(jq -r '.choices[0].finish_reason // "unknown"' < "$body_file")
    status=$EMPTY_RESPONSE_STATUS
  fi
else
  output=""
fi

# Reasoning-trace strip: everything up to the first </think>. On for
# DELEGATE_STRIP_THINK=1 or the reasoning tier (=0 force-disables).
local _strip=0
if [[ "${DELEGATE_STRIP_THINK:-}" == "1" ]]; then
  _strip=1
elif [[ "$tier" == "reasoning" && "${DELEGATE_STRIP_THINK:-}" != "0" ]]; then
  _strip=1
fi
if (( _strip == 1 )) && [[ "$output" == *"</think>"* ]]; then
  output="${output#*</think>}"
  output="${output#"${output%%[![:space:]]*}"}"
fi
}

dispatch_to_model "$model"

# curl -sS already printed its own error line; this adds the delegate context.
if (( status == EMPTY_RESPONSE_STATUS )); then
  {
    echo "delegate: model returned an empty response — model=\"$model\" tier=\"$tier\" backend=\"$backend\""
    echo "         finish_reason=$empty_finish_reason"
    if [[ "$empty_finish_reason" == "length" ]]; then
      echo "         the budget was spent before any answer was emitted, which happens"
      echo "         when a thinking-capable model ignores the think:false hint"
      echo "         - raise DELEGATE_MAX_TOKENS (currently $max_tokens)"
      echo "         - or route this tier to a provider that honours enable_thinking"
    fi
    echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
  } >&2
elif (( status != 0 )); then
  {
    echo "delegate: dispatch failed (curl exit $status) — model=\"$model\" tier=\"$tier\" backend=\"$backend\""
    if (( status == 28 )); then
      echo "         the request did not return within ${request_timeout}s (curl --max-time fired)"
      echo "         - raise DELEGATE_REQUEST_TIMEOUT if a cold model load is suspected"
      echo "         - or pick a smaller model for this tier"
    fi
    echo "         check the provider daemon (mlx_lm.server / Docker Model Runner / ollama serve) and MLX_HOST / DOCKER_MODEL_HOST / OLLAMA_HOST — see the README Troubleshooting section"
    echo "         still broken? file a bug: https://github.com/${DELEGATE_GITHUB_REPO:-IsmaelMartinez/delegate-local}/issues/new?template=bug_report.md"
  } >&2
fi


# Every arithmetic comparison against a value from outside this script (a
# recipe's frontmatter, a flavor profile, an env var) writes the operand as
# `10#$var`: bash reads a leading zero as octal, so `subject_max: 08` aborted
# the arithmetic AND took the wrong branch, failing open. The `^[0-9]+$`
# guards keep the value numeric; `10#` keeps it decimal.
#
# Deterministic output checks (ADR 0014, ADR 0017): a recipe's `checks:` block
# declares constraints run on the finalised output. All are warn-only except
# no_padding_tail, whose safe participial-comma tail is auto-stripped
# (checks_autofixed). Gated like the meta line, so NO_META and failed calls
# stay quiet. $capability_failed counts the non-style checks; nothing reads it yet.
#
# retry_constraint_for — one sentence per check name for the repair attempt
# (#384). The limit is read back out of $recipe_checks, the same
# post-substitution frontmatter the checks parse, so the two cannot drift.
retry_constraint_for() {
  local name="$1" val
  val=$(printf '%s\n' "${recipe_checks:-}" | awk -v k="$name" '
    { sub(/^[[:space:]]+/, "") }
    index($0, k ":") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  case "$name" in
    subject_max)
      echo "subject_max: the first line must be at most ${val:-the stated number of} characters." ;;
    body_max_words)
      echo "body_max_words: everything after the first blank line must be at most ${val:-the stated number of} words." ;;
    subject_type)
      echo "subject_type: the first line must begin with one of these types: ${val:-the stated list}." ;;
    body_required)
      echo "body_required: the answer needs a body after the first blank line, not a subject on its own." ;;
    no_padding_tail)
      echo "no_padding_tail: do not end with a clause that restates what the answer already said." ;;
    no_single_item_list)
      echo "no_single_item_list: a single item is a sentence, never a one-item numbered list." ;;
    no_invented_task_list)
      echo "no_invented_task_list: do not write a markdown task list; the examples you were given carry none." ;;
    no_invented_headings)
      echo "no_invented_headings: do not write a markdown heading; the examples you were given carry none, so write flowing prose." ;;
    no_invented_refs)
      echo "no_invented_refs: every issue or ticket identifier in a trailer must appear in the input you were given." ;;
    no_example_echo)
      echo "no_example_echo: do not reproduce any line of this prompt or of an example; write from the input." ;;
    no_context_echo)
      # Measures echo, not length; max_context_ratio owns the length rule (#487).
      echo "no_context_echo: reproduce none of the supplied sentences as written; carry their paths, numbers and references inside sentences of your own." ;;
    max_context_ratio)
      # A copy ban says nothing about length, so this one says it out loud (#487).
      echo "max_context_ratio: the answer runs about as long as the supplied facts; curate it to well under the facts' length, carrying every path, number and reference inside new sentences." ;;
    *)
      echo "$name: the constraint of that name, stated above, was not met." ;;
  esac
}

# echo_normalise — the ONE normalisation both echo checks apply to every
# pattern source and to the output; asymmetry is how no_example_echo failed
# twice. Any new rule goes here and nowhere else. sed -E because the optional
# `(scope)` needs an ERE group; BSD and GNU both take -E. Order matters: the
# label comes off before the type prefix.
echo_normalise() {
  sed -E -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
         -e 's/^[Ww]rong:[[:space:]]*//' -e 's/^[Cc]orrect:[[:space:]]*//' \
         -e 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//' \
         -e 's/[[:space:]]*\(#[0-9]+\)$//'
}

# echo_matches — the ONE comparison both echo checks run. Units arrive RAW on
# stdin and in $1 and are normalised here exactly once (echo_normalise is not
# idempotent); pattern units under the 40-char floor are dropped, and the
# distinct answer units that reproduce a pattern unit are printed. Whole-unit,
# fixed-string (grep -F, linear). The caller chooses the unit: lines or sentences.
echo_matches() {
  echo_normalise \
    | awk 'length($0) >= 40' \
    | grep -Fxf - <(printf '%s\n' "$1" | echo_normalise) \
    | sort -u
}

# split_sentences — one unit per line, on newlines and on `.`/`?`/`!` followed
# by whitespace. The terminator is DROPPED on both sides: facts arrive as bare
# lines and the model closes them with a full stop, so keeping it made
# `<fact>` and `<fact>.` different units. Abbreviations split the same way on
# both sides, and a fragment that shape falls under the floor.
split_sentences() {
  awk '{ gsub(/[.?!]+[[:space:]]+/, "\n"); sub(/[.?!]+[[:space:]]*$/, "") } 1'
}

# question_units — the questions of the text on stdin, one per line, each
# ending in its `?`. Split where split_sentences splits, but the terminator is
# KEPT: it is what makes a unit a question. A numbered item's `1. ` prefix
# splits off as a unit of its own, so a MULTI-ASK-SPLIT question arrives bare.
question_units() {
  awk '{ gsub(/[.?!]+[[:space:]]+/, "&\n") } 1' | sed -E 's/[[:space:]]+$//' | grep -E '\?$'
}

# fact_anchors — the anchors of the text on stdin, one per line, sorted
# unique: issue refs, file:line, file names, numbers of two-plus digits,
# snake_case and camelCase identifiers. The spike's scorer regex (#513), in
# ERE; `\b` is honoured by BSD and GNU grep alike. Leftmost-longest keeps
# `#3359` one ref and `test_x.py` one file rather than an identifier.
fact_anchors() {
  grep -oE '#[0-9]+|\b[[:alnum:]_./-]+\.[[:alnum:]_]+:[0-9]+\b|\b[[:alnum:]_-]+\.(py|js|ts|sh|md|toml|json|ya?ml|go|c|h|txt)\b|\b[0-9]{2,}\b|\b[A-Za-z]+_[A-Za-z_]+\b|\b[a-z]+[A-Z][A-Za-z]+\b' \
    | sort -u
}

# content_words — the topic words of the text on stdin, one per line, sorted
# unique: lowercased words of four-plus letters, minus the function words a
# question is built from (modals, pronouns, prepositions). Without that
# subtraction "could", "that" and "your" match the ask on every question and
# exempt it; measured, the fallback below then flags nothing at all.
content_words() {
  tr 'A-Z' 'a-z' | grep -oE '\b[a-z][a-z-]{3,}\b' \
    | grep -vxE 'could|would|should|shall|will|have|does|been|were|being|that|this|these|those|what|which|when|where|whether|your|yours|them|they|their|there|here|each|both|same|other|another|such|some|many|much|most|more|very|else|itself|yourself|with|from|into|onto|upon|about|over|once|only|also|then|than|while|until|before|after|because|since|though|although|make|made|know|want|need|like|able|sure|must|might|please|just|still' \
    | sort -u
}

# fact_as_question_matches — the questions of the output ($1) that hand a
# supplied fact back to the reader (#513), one per line in order. The unit is
# the anchor when the question carries one: every anchor in the piped context
# ($2) and none in the ask ($3) is a fact, not an ask (an anchor outside the
# context is the model's own, one in the ask is the caller's). With no anchor
# the unit is the content word, two or more from the context and none from
# the ask: one shared word is any question at all ("could you make that
# change?"). A question the caller wrote ($4, every --var value) is skipped
# first: an opener or sign-off is emitted as written and STATED-NOT-ASKED
# exempts it whatever it asks. The caller's questions are looked for INSIDE
# the emitted unit, not the other way round, because the recipe prefixes the
# opener with "@handle, " and the unit then carries more than the caller
# wrote. Measured on the 18 spike cases: anchors alone flag 6 of the 11
# confirm/question rejections, the fallback lifts it to 8, both at 0 of the
# 16 shipped finals. comm wants both sides sorted, which the extractors are.
fact_as_question_matches() {
  local q cq callers units ctx_anchors ask_anchors ctx_words ask_words caller_questions n_ctx n_out n_ask
  ctx_anchors=$(printf '%s\n' "$2" | fact_anchors)
  ask_anchors=$(printf '%s\n' "$3" | fact_anchors)
  ctx_words=$(printf '%s\n' "$2" | content_words)
  ask_words=$(printf '%s\n' "$3" | content_words)
  caller_questions=$(printf '%s\n' "${4:-}" | question_units)
  while IFS= read -r q; do
    callers=0
    while IFS= read -r cq; do
      [[ -n "$cq" && "$q" == *"$cq"* ]] && callers=1
    done <<<"$caller_questions"
    (( callers )) && continue
    units=$(printf '%s\n' "$q" | fact_anchors)
    if [[ -n "$units" ]]; then
      n_out=$(comm -23 <(printf '%s\n' "$units") <(printf '%s\n' "$ctx_anchors") | grep -c '')
      n_ask=$(comm -12 <(printf '%s\n' "$units") <(printf '%s\n' "$ask_anchors") | grep -c '')
      (( n_out == 0 && n_ask == 0 )) && printf '%s\n' "$q"
      continue
    fi
    units=$(printf '%s\n' "$q" | content_words)
    [[ -z "$units" ]] && continue
    n_ctx=$(comm -12 <(printf '%s\n' "$units") <(printf '%s\n' "$ctx_words") | grep -c '')
    n_ask=$(comm -12 <(printf '%s\n' "$units") <(printf '%s\n' "$ask_words") | grep -c '')
    (( n_ctx >= 2 && n_ask == 0 )) && printf '%s\n' "$q"
  done < <(printf '%s\n' "$1" | question_units)
  return 0
}

run_output_checks() {
# The result and the counters (output, checks_*, capability_failed) are
# deliberately NOT local: they are the function's outputs.
local padding_re padding_re_adopt check_first_line check_last_line cline ckey cval stripped new_output new_last subj_type body_lines body_words echoed_line echo_exemplars _egv _kv list_items task_prog out_tasks auth_tasks head_prog out_heads auth_heads authority ref_ground ref_tok invented_refs context_echoed context_echoed_n ctx_floor ctx_ratio fact_questions caller_text
checks_failed=0
checks_failed_names=""
checks_run=0
checks_autofixed=0
capability_failed=0

# no_example_echo — ON by default for every recipe call: a line copied out of
# the prompt is never a correct outcome, and the contrastive anchors (ADR 0011)
# hand the model a fluent sentence to fall back on when the input is long.
# Prompt text cannot close this, since the guards are themselves copyable
# lines. Compared against $recipe_template_raw so only recipe-AUTHORED text is
# a pattern. Opt out with `no_example_echo: false` or DELEGATE_NO_ECHO_CHECK=1.
if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] && (( status == 0 )) \
   && [[ -n "${recipe_template_raw:-}" ]] \
   && [[ "${DELEGATE_NO_ECHO_CHECK:-}" != "1" ]] \
   && [[ "${recipe_checks:-}" != *"no_example_echo: false"* ]]; then
  checks_run=$((checks_run + 1))
  # Exemplar --var values join the pattern set when the recipe declares them
  # (#428): commit-message returned one of its shape-anchor commits as its
  # subject. A line repeated across exemplars is convention (a trailer, a
  # footer) the output is supposed to reproduce, so only a line unique to one
  # exemplar is that exemplar's own content.
  echo_exemplars=""
  if [[ -n "${recipe_echo_guard_vars:-}" ]]; then
    for _egv in $(printf '%s' "$recipe_echo_guard_vars" | tr ',' ' '); do
      for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
        if [[ "${_kv%%=*}" == "$_egv" ]]; then
          echo_exemplars="${echo_exemplars}${_kv#*=}
"
        fi
      done
    done
  fi
  # The convention filter judges on the normalised form (so `ci: X` and
  # `chore(deps): X (#253)` count as one line repeated) but hands echo_matches
  # the RAW line: echo_normalise is not idempotent, and a twice-normalised
  # pattern never matches a once-normalised echo. paste keeps the pairs
  # aligned because echo_normalise never drops a line.
  echoed_line=$( { printf '%s\n' "$recipe_template_raw"
    if [[ -n "$echo_exemplars" ]]; then
      paste -d "$(printf '\037')" \
        <(printf '%s' "$echo_exemplars" | echo_normalise) \
        <(printf '%s' "$echo_exemplars") \
        | awk -F "$(printf '\037')" '
            { seen[$1]++; form[NR] = $1; raw[NR] = $2 }
            END { for (i = 1; i <= NR; i++) if (seen[form[i]] == 1) print raw[i] }'
    fi; } | echo_matches "$output" | head -n 1)
  if [[ -n "$echoed_line" ]]; then
    echo "delegate: check 'no_example_echo' FAILED — REJECT this draft. The model" >&2
    echo "  reproduced a line from its own prompt (the recipe's example, or one of the" >&2
    echo "  exemplars you passed as a shape anchor) instead of writing one from your" >&2
    echo "  content: \"${echoed_line:0:120}\"" >&2
    echo "  The draft is not grounded in the input. Re-run or hand-write; do not ship it." >&2
    # Boilerplate every artifact carries reaches the convention filter only
    # when more than one exemplar carries it; the fix belongs in the exemplar.
    echo "  If that line is boilerplate every artifact in the repo carries, strip it from" >&2
    echo "  the exemplar you passed (and pass two, so shared lines can be recognised as" >&2
    echo "  convention) rather than removing it from the answer." >&2
    checks_failed=$((checks_failed + 1))
    checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_example_echo"
    capability_failed=$((capability_failed + 1))
  fi
fi

if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] && (( status == 0 )) && [[ -n "${recipe_checks:-}" ]]; then
  # The participial arm is structural (`, <word>ing`) because per-verb
  # enumeration is a treadmill, and anchored to the line end because an
  # unanchored arm flagged mid-sentence clauses. Measured, do not simplify:
  # `([[:space:]]…)?` keeps `ing` a word ending (else every -ings plural
  # matches); the class permits commas but not a sentence boundary; `{0,200}`
  # keeps the match linear (unbounded is quadratic on a long line). ACCEPTED
  # GAP: a tail with a non-terminal full stop is not detected; #390 measured
  # recovering it and declined. The This-X arm stays enumerated.
  padding_re=',[[:space:]]+[a-z]{3,}ing([[:space:]][^.!?]{0,200})?[.!?]?[[:space:]]*$|(^|[.!?][[:space:]]+)(this[[:space:]]+(means|approach|ensures|enables|guarantees|delivers|provides|prevents|avoids|serves)|in summary|overall|consequently|ultimately|in effect|as a result)\b|(going|moving)[[:space:]]+forward|clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)'
  # ADR 0017's adoption rule, byte-identical to the pre-anchor expression on
  # purpose: anchoring this second gate would widen the strip, adopting output
  # that still carries a mid-line participial. Detection narrows; adoption does not.
  padding_re_adopt=',[[:space:]]+[a-z]{3,}ing([[:space:]]|[.!?,]|$)|(^|[.!?][[:space:]]+)(this[[:space:]]+(means|approach|ensures|enables|guarantees|delivers|provides|prevents|avoids|serves)|in summary|overall|consequently|ultimately|in effect|as a result)\b|(going|moving)[[:space:]]+forward|clos(es|ing)[[:space:]]+the[[:space:]]+(gap|loop)'
  check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
  check_last_line=$(printf '%s' "$output" | awk 'NF { l=$0 } END { print l }')
  while IFS= read -r cline; do
    # In-process parse, no sed subshell per line.
    if [[ "$cline" =~ ^[[:space:]]*([a-zA-Z_]+):[[:space:]]*(.*)$ ]]; then
      ckey="${BASH_REMATCH[1]}"
      cval="${BASH_REMATCH[2]}"
      cval="${cval%"${cval##*[![:space:]]}"}"
    else
      continue
    fi
    case "$ckey" in
      subject_max)
        if [[ "$cval" =~ ^[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          if (( ${#check_first_line} > 10#$cval )); then
            echo "delegate: check 'subject_max' FAILED — first line is ${#check_first_line} chars (> $cval)" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}subject_max"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      no_padding_tail)
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          if printf '%s' "$check_last_line" | grep -Eiq "$padding_re"; then
            # Detection is broad for recall; the auto-strip is NARROWER for
            # precision: only a trailing ", <filler-gerund> ...<end>" clause
            # with the gerund in an allowlist and no comma inside, so a
            # meaningful participial stays a FAILED warning. Adopted only when
            # non-empty AND it clears the padding, so a FAILED verdict always
            # matches the emitted text. DELEGATE_NO_AUTOFIX=1 opts out.
            stripped=0
            if [[ "${DELEGATE_NO_AUTOFIX:-}" != "1" ]]; then
              new_output=$(printf '%s' "$output" | perl -0777 -pe '
                my @l = split /\n/, $_, -1;
                for (my $i = $#l; $i >= 0; $i--) {
                  next if $l[$i] =~ /^\s*$/;            # skip trailing blank lines
                  $l[$i] =~ s/(\S.*\S)\s*,\s+(?:ensuring|confirming|allowing|enabling|providing|leading|reflecting|making|supporting|helping|keeping|maintaining|delivering|guaranteeing|underscoring|highlighting|streamlining|facilitating|promoting|fostering|paving|cementing|reinforcing)\b[^,.!?]*([.!?])?\s*$/$1 . (defined $2 ? $2 : ".")/ie;
                  last;                                  # only the last non-empty line
                }
                $_ = join("\n", @l);
              ')
              if [[ -n "$new_output" && "$new_output" != "$output" ]]; then
                new_last=$(printf '%s' "$new_output" | awk 'NF { l=$0 } END { print l }')
                if ! printf '%s' "$new_last" | grep -Eiq "$padding_re_adopt"; then
                  output="$new_output"
                  check_first_line=$(printf '%s' "$output" | awk 'NF { print; exit }')
                  check_last_line="$new_last"
                  stripped=1
                fi
              fi
            fi
            if (( stripped )); then
              echo "delegate: check 'no_padding_tail' AUTO-FIXED — stripped a trailing participial padding clause" >&2
              checks_autofixed=$((checks_autofixed + 1))
            else
              echo "delegate: check 'no_padding_tail' FAILED — output ends on a padding/restating clause" >&2
              checks_failed=$((checks_failed + 1))
              checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_padding_tail"
            fi
          fi
        fi
        ;;
      subject_type)
        # `subject_type: {{type}}` is the caller's --var echoed; an omitted
        # optional type collapses to empty and the check is skipped. Pure
        # string ops, not a regex built from cval, so a metacharacter in the
        # --var cannot break the match; `!` and `(scope)` are stripped so the
        # full conventional shape is honoured.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          subj_type="${check_first_line%%:*}"   # segment before the first colon
          subj_type="${subj_type%!}"            # drop a trailing ! (type!: form)
          subj_type="${subj_type%%(*}"          # drop a (scope) suffix
          if [[ "$check_first_line" != *:* || "$subj_type" != "$cval" ]]; then
            echo "delegate: check 'subject_type' FAILED — subject does not start with '$cval:' (got '${check_first_line%%:*}:')" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}subject_type"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      body_required)
        # `printf '%s\n'` guarantees a trailing newline so awks that drop a
        # final unterminated line still count it; `tr -d '\r'` so a CRLF blank
        # separator (a lone \r is non-whitespace to awk) is not miscounted;
        # `+ 0` keeps the count numeric on empty output.
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          body_lines=$(printf '%s\n' "$output" | tr -d '\r' | awk 'NF { n++ } END { print n + 0 }')
          if (( body_lines < 2 )); then
            echo "delegate: check 'body_required' FAILED — output is subject-only ($body_lines non-empty line(s), need >= 2)" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}body_required"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      body_max_words)
        # Body length in words (everything after the first blank line). The
        # limit is a flavor placeholder: how long a body should be is house
        # style, tuned in profile.sh.
        if [[ "$cval" =~ ^[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          # tr -d '\r' first: a CRLF blank separator is a lone \r, which mawk
          # (CI) does not count as [[:space:]], so the body would measure 0
          # words and always pass; BWK awk (macOS) hides the bug.
          body_words=$(printf '%s\n' "$output" | tr -d '\r' | awk '
            BEGIN { s = 0 }
            s { n += NF; next }
            /^[[:space:]]*$/ { s = 1 }
            END { print n + 0 }')
          if [[ "$body_words" =~ ^[0-9]+$ ]] && (( body_words > 10#$cval )); then
            echo "delegate: check 'body_max_words' FAILED — body is $body_words words (> $cval)" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}body_max_words"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      no_single_item_list)
        # A one-item numbered list breaks both reply recipes whichever branch
        # applies (two-plus asks get items, one ask is a sentence), so the
        # check needs no knowledge of the ask count. A check, not a third
        # rewording: the defect survived two prompt edits. Counting matches
        # body_required's idiom (`printf '%s\n'`, `tr -d '\r'`).
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          list_items=$(printf '%s\n' "$output" | tr -d '\r' \
            | awk '/^[[:space:]]*[0-9]+[.)][[:space:]]/ { n++ } END { print n + 0 }')
          if [[ "$list_items" =~ ^[0-9]+$ ]] && (( list_items == 1 )); then
            echo "delegate: check 'no_single_item_list' FAILED — output is a numbered list of one item; a single ask is one sentence" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_single_item_list"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      no_invented_task_list)
        # Either box state is a claim the model cannot support. A blanket ban
        # would be wrong: a repo whose PR template carries task boxes SHOULD
        # get them back, so the value names the --var holding the shape
        # authority and the check fires only when the output has a task list
        # and the examples have none. awk, not `grep -c`, because grep exits 1
        # on no match and the `|| echo 0` workaround double-emits.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          # The pattern is the awk PROGRAM, not a -v value: awk escape-processes
          # -v values, so `\[` collapses to `[` and the bracket expression breaks.
          task_prog='/^[[:space:]]*[-*+][[:space:]]+\[[ xX]\][[:space:]]/ { n++ } END { print n + 0 }'
          out_tasks=$(printf '%s\n' "$output" | tr -d '\r' | awk "$task_prog")
          if [[ "$out_tasks" =~ ^[0-9]+$ ]] && (( out_tasks > 0 )); then
            authority=""
            for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
              if [[ "${_kv%%=*}" == "$cval" ]]; then
                authority="${_kv#*=}"
              fi
            done
            auth_tasks=$(printf '%s\n' "$authority" | tr -d '\r' | awk "$task_prog")
            if [[ "$auth_tasks" == "0" ]]; then
              echo "delegate: check 'no_invented_task_list' FAILED — output carries $out_tasks markdown task-list item(s) but the '$cval' examples carry none; the shape was invented, and a task-list box asserts a verification state the model cannot know" >&2
              checks_failed=$((checks_failed + 1))
              checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_invented_task_list"
              capability_failed=$((capability_failed + 1))
            fi
          fi
        fi
        ;;
      no_invented_headings)
        # Same contract as no_invented_task_list: the value names the --var
        # holding the shape authority, and the check fires only when the
        # output has a heading and the examples have none. Verify an exemplar
        # is heading-free before concluding a heading was invented. Fenced
        # blocks are skipped on both sides (a pasted shell snippet carries
        # `# comment` lines), and `#+[[:space:]]` leaves a shebang alone.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          # The awk PROGRAM, for the same reason as the task-list one.
          head_prog='/^[[:space:]]*```/ { fence = !fence; next } !fence && /^[[:space:]]*#+[[:space:]]/ { n++ } END { print n + 0 }'
          out_heads=$(printf '%s\n' "$output" | tr -d '\r' | awk "$head_prog")
          if [[ "$out_heads" =~ ^[0-9]+$ ]] && (( out_heads > 0 )); then
            authority=""
            for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
              if [[ "${_kv%%=*}" == "$cval" ]]; then
                authority="${_kv#*=}"
              fi
            done
            auth_heads=$(printf '%s\n' "$authority" | tr -d '\r' | awk "$head_prog")
            if [[ "$auth_heads" == "0" ]]; then
              echo "delegate: check 'no_invented_headings' FAILED — output carries $out_heads markdown heading(s) but the '$cval' examples carry none; the shape was invented rather than matched" >&2
              checks_failed=$((checks_failed + 1))
              checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_invented_headings"
              capability_failed=$((capability_failed + 1))
            fi
          fi
        fi
        ;;
      no_invented_refs)
        # A trailer identifier the model made up by continuing the examples'
        # numbering. Prompt-side attempts failed, and a `Wrong:` example
        # carrying a literal identifier was copied verbatim, so the grounding
        # set is the CALLER's inputs only (every --var plus stdin), never the
        # recipe template. Only trailer-shaped lines are scanned; the ticket
        # shape needs two-plus trailing digits so `UTF-8` stays out. KNOWN
        # GAP: `SHA-256` in a trailer would flag.
        if [[ "$cval" == "true" ]]; then
          checks_run=$((checks_run + 1))
          ref_ground=""
          for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
            ref_ground="${ref_ground}${_kv#*=}
"
          done
          ref_ground="${ref_ground}${context}"
          # Token-for-token, not substring: a `grep -F` for `#427` matches
          # inside `#4271`, so an invented reference one digit short would pass.
          ref_ground=$(printf '%s\n' "$ref_ground" \
            | grep -oE '#[0-9]+|[A-Z][A-Z0-9]+-[0-9]{2,}' | sort -u)
          invented_refs=""
          while IFS= read -r ref_tok; do
            [[ -z "$ref_tok" ]] && continue
            grep -qxF -- "$ref_tok" <<<"$ref_ground" && continue
            invented_refs="${invented_refs:+$invented_refs }$ref_tok"
          done < <(printf '%s\n' "$output" | tr -d '\r' \
            | awk '/^[A-Za-z][A-Za-z0-9-]*:[[:space:]]/' \
            | grep -oE '#[0-9]+|[A-Z][A-Z0-9]+-[0-9]{2,}' \
            | sort -u)
          if [[ -n "$invented_refs" ]]; then
            echo "delegate: check 'no_invented_refs' FAILED — trailer names $invented_refs, which appears in none of the inputs you supplied" >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_invented_refs"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      no_context_echo)
        # The piped context handed straight back, the mirror of no_example_echo
        # (#475). Same machinery (echo_matches) with the unit changed to
        # SENTENCES: facts arrive one per line and come back joined into a
        # paragraph, so a whole-line compare matched nothing. The pattern set
        # is stdin ONLY, never --var values (a --var is a verdict or ask the
        # recipe tells the model to place). Threshold TWO sentences: one
        # quoted back is the anchor-carrying the reply recipes ask for.
        if [[ "$cval" == "true" ]] && [[ "${DELEGATE_NO_ECHO_CHECK:-}" != "1" ]]; then
          checks_run=$((checks_run + 1))
          context_echoed=$(printf '%s\n' "$context" | split_sentences \
            | echo_matches "$(printf '%s\n' "$output" | split_sentences)")
          context_echoed_n=$(printf '%s' "$context_echoed" | grep -c '')
          if (( context_echoed_n >= 2 )); then
            echo "delegate: check 'no_context_echo' FAILED — $context_echoed_n distinct sentence(s) of the answer reproduce sentences of the piped context verbatim, e.g. \"$(printf '%s\n' "$context_echoed" | head -n 1 | cut -c1-120)\"" >&2
            echo "  The draft restates the facts instead of curating them; carry the anchors inside new sentences." >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_context_echo"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      max_context_ratio)
        # A length ceiling relative to the piped context (#487): the reply
        # recipes handed the fact sheet back at input size, and no_context_echo
        # measures echo, not length. A prose rule was tried and withdrawn (it
        # cannot be met on a three-line fact list). Applies only when the
        # context is at least min_context_chars (sibling key, default 400).
        # The ratio is a decimal, compared in awk since bash arithmetic is
        # integer-only. Capability, so it counts toward capability_failed.
        if [[ "$cval" =~ ^[0-9]*\.?[0-9]+$ ]]; then
          checks_run=$((checks_run + 1))
          ctx_floor=$(printf '%s\n' "$recipe_checks" | awk '
            { sub(/^[[:space:]]+/, "") }
            index($0, "min_context_chars:") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
          [[ "$ctx_floor" =~ ^[0-9]+$ ]] || ctx_floor=400
          if (( ${#context} > 0 && ${#context} >= 10#$ctx_floor )); then
            ctx_ratio=$(awk -v o="${#output}" -v c="${#context}" 'BEGIN { printf "%.2f", o / c }')
            if awk -v o="${#output}" -v c="${#context}" -v r="$cval" 'BEGIN { exit !(o / c >= r) }'; then
              echo "delegate: check 'max_context_ratio' FAILED — the answer is ${#output} chars against ${#context} chars of context (ratio $ctx_ratio >= $cval)" >&2
              echo "  The draft runs about as long as its facts; curate them, well under the facts' length, carrying every anchor inside new sentences." >&2
              checks_failed=$((checks_failed + 1))
              checks_failed_names="${checks_failed_names:+$checks_failed_names,}max_context_ratio"
              capability_failed=$((capability_failed + 1))
            fi
          fi
        fi
        ;;
      no_fact_as_question)
        # A supplied fact handed back as a question to the reader (#513), the
        # defect STATED-NOT-ASKED forbids and 65 of 132 maintainer-reply
        # rejections described while one carried a failed check. The value
        # names the --var holding the caller's asks, as no_invented_task_list
        # names its authority: a question whose anchors are all in the piped
        # context and none in that var is a fact, not an ask. Context only,
        # never the other --var values, as no_context_echo; a question found
        # verbatim in any --var (an opener, a sign-off) is the caller's and
        # is skipped. Never retried on its own: the spike's validator arm
        # cleared 3 of 13 on a second pass.
        if [[ -n "$cval" ]]; then
          checks_run=$((checks_run + 1))
          authority=""
          caller_text=""
          for _kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
            if [[ "${_kv%%=*}" == "$cval" ]]; then
              authority="${_kv#*=}"
            fi
            caller_text="${caller_text}${_kv#*=}
"
          done
          fact_questions=$(fact_as_question_matches "$output" "$context" "$authority" "$caller_text")
          if [[ -n "$fact_questions" ]]; then
            echo "delegate: check 'no_fact_as_question' FAILED — a supplied fact comes back as a question to the reader: \"$(printf '%s\n' "$fact_questions" | head -n 1 | cut -c1-120)\"" >&2
            echo "  What it asks about is in the piped facts and absent from the '$cval' var: the reader is asked to confirm what the facts already state. State it instead." >&2
            checks_failed=$((checks_failed + 1))
            checks_failed_names="${checks_failed_names:+$checks_failed_names,}no_fact_as_question"
            capability_failed=$((capability_failed + 1))
          fi
        fi
        ;;
      min_context_chars)
        # The floor max_context_ratio reads out of the same block (above); a
        # setting, not a check of its own, so it is accepted and does nothing.
        ;;
      no_example_echo)
        # Handled before this loop (on by default); the key is only an opt-out.
        ;;
      *)
        echo "delegate: unknown check '$ckey' in recipe '$recipe' — ignored" >&2
        ;;
    esac
  done <<< "$recipe_checks"
fi
}

# One bounded repair attempt (#384): the wrapper holds the exact prompt and
# the name of the constraint it broke, so one more generation is cheaper than
# the rewrite. Exactly one retry, never a loop: a second failure means the
# model cannot satisfy the constraint on this input. no_padding_tail reaches
# here only when the auto-strip declined. The first pass's stderr is captured
# and released unchanged only when no retry follows.
# no_context_echo on its own is not retried (#514): the notice does not
# repair it — on maintainer-review-reply the second generation came back the
# same size and the same echo on 8 of 12 retries over 2026-09-13/14 — so the
# check fails, prints and is named on the row, and the second generation is
# not spent. Beside any other failed check the retry still runs.
checks_stderr=$(mktemp)
trap 'rm -f "$body_file" "$checks_stderr"' EXIT
# Banked before the checks run, because run_output_checks can MUTATE $output
# (the auto-strip); reading afterwards would under-count the rejected generation.
rejected_output_chars=${#output}
run_output_checks 2>"$checks_stderr"

retried=""
# no_fact_as_question never earns the retry (#513): the spike's validator arm
# cleared 3 of 13 on a second generation, so the row records it and the
# caller decides. It is dropped from the trigger and from the notice; the
# other names still retry as before, and no_context_echo left alone by that
# subtraction is the #514 case above, so it does not retry either.
retry_names=$(printf '%s' "$checks_failed_names" | tr ',' '\n' | grep -vx 'no_fact_as_question' | paste -s -d ',' -)
if (( status == 0 )) && [[ -n "$retry_names" ]] \
   && [[ "$retry_names" != "no_context_echo" ]] \
   && [[ -n "$recipe" ]] \
   && [[ "${DELEGATE_NO_RETRY:-}" != "1" ]]; then
  retried="true"
  # The rejected generation and the appended notice are real local work,
  # carried in their own field so prompt_chars / output_chars keep meaning
  # "the request that produced the answer you got".
  retry_chars=$rejected_output_chars
  retry_notice=""
  for _rc in $(printf '%s' "$retry_names" | tr ',' ' '); do
    retry_notice="${retry_notice}- $(retry_constraint_for "$_rc")
"
  done
  echo "delegate: check(s) ${retry_names} failed — regenerating once." >&2
  # Appended to the SAME templated prompt: a fresh, differently worded prompt
  # would have failures that could not be attributed to the recipe.
  retry_input_before=${#full_input}
  full_input="${full_input}

Your previous answer was REJECTED. It broke these constraints:
${retry_notice}Write the answer again, in full, obeying every rule above. Output only the answer."
  retry_chars=$(( retry_chars + ${#full_input} - retry_input_before ))
  # duration_ms covers both dispatches, so both waits are summed or the whole
  # rejected call lands in generation_ms; dispatch_to_model overwrites ttfb_s.
  ttfb_prev="${ttfb_s:-0}"
  dispatch_to_model "$model"
  ttfb_s=$(awk -v a="${ttfb_prev:-0}" -v b="${ttfb_s:-0}" 'BEGIN { printf "%.6f", a + b }')
  run_output_checks
else
  cat "$checks_stderr" >&2
fi

end_epoch_ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
duration_ms=$((end_epoch_ms - start_epoch_ms))

# awk for the float-to-int conversion (bc is not always installed). A failed
# call or an empty TTFB attributes the whole duration to generation_ms, so
# the two still sum to duration_ms; queue_wait_ms is clamped at duration_ms.
queue_wait_ms=0
if [[ -n "${ttfb_s:-}" ]] && [[ "$status" -eq 0 ]]; then
  queue_wait_ms=$(awk -v s="$ttfb_s" 'BEGIN { printf "%.0f", s * 1000 }')
  if (( queue_wait_ms > duration_ms )); then
    queue_wait_ms=$duration_ms
  fi
fi
generation_ms=$((duration_ms - queue_wait_ms))

# Both surfaces route through compute_tokens_local so they cannot drift.
prompt_chars=$(( ${#recipe_template} + ${#prompt} ))
context_chars=${#context}
output_chars=${#output}
tokens_local=$(compute_tokens_local "$prompt_chars" "$context_chars" "$(( output_chars + ${retry_chars:-0} ))")

draft_file=""
input_file=""
inputs_file=""
if (( status == 0 )); then
  # The rendered input is stored for recipe calls only (#516): a recipe is
  # what the pair calibrates, and a bare call's context has no recipe to be
  # scored against. After a retry $full_input carries the appended notice,
  # which is exactly the prompt that produced the draft stored beside it.
  # The structured inputs go beside it as JSON — the piped stdin, every
  # --var as passed, the positional prompt when there was one — so
  # replay-recipe.sh can render the same case under another template. jq
  # builds it from the flat key/value list because values carry newlines.
  inputs_json=""
  if [[ -n "$recipe" ]]; then
    kv_flat=()
    for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
      kv_flat+=("${kv%%=*}" "${kv#*=}")
    done
    inputs_json=$(jq -nc --arg recipe "$recipe" --arg stdin "$context" --arg prompt "$prompt" \
      '{recipe:$recipe, stdin:$stdin,
        vars:($ARGS.positional | [range(0; length; 2) as $i | {key: .[$i], value: .[$i+1]}] | from_entries)}
       + (if $prompt != "" then {prompt:$prompt} else {} end)' \
      --args ${kv_flat[@]+"${kv_flat[@]}"} 2>/dev/null)
  fi
  IFS=$'\t' read -r draft_file input_file inputs_file <<<"$(capture_draft "$output" "$ts_start" "${recipe:+$full_input}" "$inputs_json")"
fi
# row_written is what the meta line's ts/id and the verdict nudge are gated
# on: they name the row this call wrote, so they are only true when one was.
row_written=false
log_metric "$ts_start" "$tier" "$model" "$prompt_chars" "$context_chars" "$output_chars" "$duration_ms" "$status" "$recipe" "$queue_wait_ms" "$generation_ms" "$otel_trace_id" "$otel_span_id" "$metric_sampling_temperature" "$metric_sampling_top_p" "$metric_sampling_top_k" "$metric_sampling_presence_penalty" "$delegate_project" "$checks_run" "$checks_failed" "$checks_autofixed" "$checks_failed_names" "$draft_file" "$retried" "${retry_chars:-}" "$input_file" "$template_sha" "$inputs_file" && row_written=true
emit_otel_span "$start_epoch_ms" "$duration_ms" "$status" "$otel_trace_id" "$otel_span_id" "$model" "$backend" "$tier" "$recipe" "$prompt_chars" "$context_chars" "$output_chars" "$queue_wait_ms" "$generation_ms" "$tokens_local" "${recipe_template}${prompt}" "$context" "$output" "$delegate_project" "${retry_chars:-}"

# The stderr line SKILL.md teaches the assistant to read after every
# delegation: `key=value` pairs, successful calls only, silenced by NO_META.
# tokens_local is the chars/4 estimate, the same number as the row's
# estimated_tokens_avoided: "kept local", not "saved from Claude".
if [[ "${DELEGATE_LOCAL_NO_META:-}" != "1" ]] \
   && (( status == 0 )); then
  # String fields are quoted because model ids come from whatever a provider
  # reports; integers stay bare.
  meta="model=\"$model\" tier=\"$tier\" backend=\"$backend\" tokens_local=$tokens_local duration_ms=$duration_ms"
  # ts and id name the row this call wrote (#474). id is the otel_span_id and
  # the pin `delegate-feedback.sh --id` takes: ts has second precision and
  # parallel delegations share it. Omitted when no row was written.
  if [[ "$row_written" == "true" ]]; then
    meta="$meta ts=\"$ts_start\" id=\"$otel_span_id\""
  fi
  if [[ -n "$recipe" ]]; then
    meta="$meta recipe=\"$recipe\""
  fi
  if (( checks_failed > 0 )); then
    meta="$meta checks_failed=$checks_failed"
  fi
  if (( checks_autofixed > 0 )); then
    meta="$meta checks_autofixed=$checks_autofixed"
  fi
  echo "delegate-meta: $meta" >&2
fi

# Verdict nudge: without it the metrics file accumulates untracked rows and
# the recipe library cannot self-correct. Fires unconditionally on success
# when a row was written: a TTY-only gate silently skipped the Agent SDK
# callers whose verdicts matter most (#149). DELEGATE_LOCAL_VERDICT_NUDGE_FD
# routes it off stderr for callers capturing 2>&1 (#139).
if [[ "$row_written" == "true" ]] \
   && [[ "${DELEGATE_LOCAL_NO_VERDICT_NUDGE:-}" != "1" ]] \
   && (( status == 0 )); then
  # The fd!=2 path wraps echo + redirect in `{ ...; } 2>/dev/null` so bash's
  # own "Bad file descriptor" (raised by the shell, not by echo) is absorbed
  # rather than leaking to the fd 2 the caller wanted clean (macOS bash 3.2.57).
  # The nudge names the WHOLE contract with `--id` pre-filled (#474): ts is
  # second-precision and siblings share it. Each verdict is a complete command
  # on its own line, because the line is copied as printed (`a | b | c` ran as
  # a pipeline); the note after each is a shell comment so a copy still runs.
  nudge_msg="delegate: record verdict → bash scripts/delegate-feedback.sh --source agent --id $otel_span_id hit                  # shipped as-is
delegate:                  bash scripts/delegate-feedback.sh --source agent --id $otel_span_id scaffold \"<reason>\"  # edited and shipped
delegate:                  bash scripts/delegate-feedback.sh --source agent --id $otel_span_id miss \"<reason>\"      # thrown away
delegate:   on scaffold/miss also pass --final <path|-> naming what you shipped instead. The draft is already saved; the pair is what calibrates the recipe."
  if (( nudge_fd == 2 )); then
    echo "$nudge_msg" >&2
  else
    { echo "$nudge_msg" >&"$nudge_fd"; } 2>/dev/null
  fi
fi

printf '%s\n' "$output"
exit $status
