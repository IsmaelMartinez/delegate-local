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
# Env:
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
#   DELEGATE_MODEL=<id>                 this exact model id instead of the
#                                       tier's preference list (pick-model.sh)
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
#   DELEGATE_MAX_TOKENS=<int>           default 4096; not a positive integer exits 2
#   DELEGATE_TEMPERATURE=<n>            sampler temperature (default 0, greedy);
#                                       non-numeric exits 2
#   DELEGATE_VERIFY=1|0                 force the draft verifier on (1) or off
#                                       (0) for a recipe call; unset, the
#                                       recipe's `verify: true` decides (#661)
#   DELEGATE_DECIDE_TIMEOUT=<s>         per-request bound on the verifier
#                                       (default 60 here); a timeout is a
#                                       verify_error, never a failed call
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
# bash 5.2 turns patsub_replacement on, where `&` in a ${t//pat/rep} replacement
# means the matched text: a --var value of `R&D` rendered as `R{{lead}}D`
# (#547). bash 3.2 has no such option, hence the guard.
shopt -u patsub_replacement 2>/dev/null || true

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

# A flag the parser does not know lands in the tier slot; refused here, before
# any metrics row, since the corpus once recorded tier:"--file" (#550).
if [[ "$tier" == -* ]]; then
  echo "delegate: '$tier' is not a flag delegate.sh knows, so it cannot be the positional tier." >&2
  echo "         the tier is positional: delegate.sh [options] <tier> [\"<prompt>\"] — or pass --tier NAME." >&2
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
  # The JSON is never truncated: a cut draft is still evidence, a cut JSON
  # is unreadable, so over the cap it is simply not written and the row
  # carries no inputs_file.
  if [[ -n "$inputs" ]] && (( $(printf '%s' "$inputs" | wc -c | tr -d ' ') <= max )) \
     && capture_file "$inputs" "$dir/$stem.inputs.json" "$max"; then
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
    s_temp="${14:-}" project="${15:-}" \
    checks_run="${16:-}" checks_failed="${17:-}" checks_autofixed="${18:-}" checks_failed_names="${19:-}" \
    draft_file="${20:-}" retried="${21:-}" retry_chars="${22:-}" input_file="${23:-}" \
    template_sha="${24:-}" inputs_file="${25:-}" retry_failed="${26:-}"
  local tokens_avoided
  tokens_avoided=$(compute_tokens_local "$pchars" "$cchars" "$(( ochars + ${retry_chars:-0} ))")
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  # source:"delegate" discriminates from experiment-runner rows in the same
  # file; a missing backend reads as ollama downstream. duration_ms stays the
  # inclusive total; queue_wait_ms + generation_ms sum to it within rounding.
  # The otel ids are written unconditionally so feedback rows and backfills
  # join without a second lookup. jq builds the line because model ids come
  # from whatever a provider reports. Optional fields (recipe, project,
  # session, sampling_temperature, input_quality, verify, verify_error) are
  # present iff set, so the row shape is stable. input_quality, verify and
  # verify_error are read from the globals the recipe and verifier blocks set.
  jq -nc \
    --arg ts "$ts" --arg backend "$backend" --arg tier "$tier" --arg model "$model" \
    --arg recipe "$recipe_name" --arg project "$project" --arg session "${CLAUDE_CODE_SESSION_ID:-}" \
    --arg trace_id "$trace_id" --arg span_id "$span_id" \
    --arg s_temp "$s_temp" \
    --argjson pchars "$pchars" --argjson cchars "$cchars" --argjson ochars "$ochars" \
    --argjson dur_ms "$dur_ms" --argjson qwait_ms "$qwait_ms" --argjson gen_ms "$gen_ms" \
    --argjson status "$status" --argjson tokens_avoided "$tokens_avoided" \
    --arg crun "$checks_run" --arg cfail "$checks_failed" --arg cfix "$checks_autofixed" \
    --arg cnames "$checks_failed_names" --arg draft "$draft_file" --arg input "$input_file" \
    --arg retried "$retried" --arg retry_chars "$retry_chars" \
    --arg tsha "$template_sha" --arg inputs "$inputs_file" --arg retry_failed "$retry_failed" --arg iq "${input_quality:-}" \
    --arg verify "${verify_json:-}" --arg verify_error "${verify_error:-}" \
    '{ts:$ts, source:"delegate", backend:$backend, tier:$tier, model:$model, prompt_chars:$pchars, context_chars:$cchars, output_chars:$ochars, duration_ms:$dur_ms, queue_wait_ms:$qwait_ms, generation_ms:$gen_ms, exit_status:$status, estimated_tokens_avoided:$tokens_avoided}
     + (if $recipe != "" then {recipe:$recipe} else {} end)
     + (if $tsha != "" then {template_sha:$tsha} else {} end)
     + (if $project != "" then {project:$project} else {} end)
     + (if $session != "" then {session:$session} else {} end)
     + (if $trace_id != "" then {otel_trace_id:$trace_id} else {} end)
     + (if $span_id != "" then {otel_span_id:$span_id} else {} end)
     + (if $s_temp != "" then {sampling_temperature:($s_temp|tonumber)} else {} end)
     + (if ($crun != "" and ($crun|tonumber) > 0) then {checks_run:($crun|tonumber), checks_failed:($cfail|tonumber), checks_autofixed:($cfix|tonumber)} else {} end)
     + (if $cnames != "" then {checks_failed_names:($cnames|split(","))} else {} end)
     + (if $draft != "" then {draft_file:$draft} else {} end)
     + (if $input != "" then {input_file:$input} else {} end)
     + (if $inputs != "" then {inputs_file:$inputs} else {} end)
     + (if $retried != "" then {retried:true, retry_chars:($retry_chars|tonumber)} else {} end)
     + (if $retry_failed != "" then {retry_failed:true} else {} end)
     + (if $iq != "" then {input_quality:($iq|split(","))} else {} end)
     + (if $verify != "" then {verify:($verify|fromjson)} else {} end)
     + (if $verify_error != "" then {verify_error:$verify_error} else {} end)' \
    >> "$metrics_file" 2>/dev/null
}

# Shared with delegate-feedback.sh and backfill-otel.sh; sourcing has no side effects.
# shellcheck source=lib/otel.sh
. "$script_dir/lib/otel.sh"
# recipe_tier lives in lib/recipe.sh so the boundary hook reads the tier with
# the exact expression used here.
# shellcheck source=lib/recipe.sh
. "$script_dir/lib/recipe.sh"
# The deterministic output checks (#560); it sources lib/text.sh, the
# sentence, normalise and anchor helpers shared with lib/pair-score.sh.
# shellcheck source=lib/checks.sh
. "$script_dir/lib/checks.sh"

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

# One metrics row + span for an early-exit failure (pick-model or the
# canary): zero output chars, the elapsed time attributed to generation_ms.
emit_failure() {
  local fstatus="$1" fmodel="$2" fs_temp="${3:-}"
  local fend fdur fp fc ftoks
  fend=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  fdur=$((fend - start_epoch_ms))
  fp=$(( recipe_template_chars + ${#prompt} ))
  fc=${#context}
  ftoks=$(compute_tokens_local "$fp" "$fc" 0)
  # A failed recipe row still names its template (arg 24), so a stall is
  # attributed to the template that was live; the eight check and capture
  # fields between are empty, as nothing was generated.
  log_metric "$ts_start" "$tier" "$fmodel" "$fp" "$fc" 0 "$fdur" "$fstatus" "$recipe" 0 "$fdur" "$otel_trace_id" "$otel_span_id" "$fs_temp" "$delegate_project" \
    "" "" "" "" "" "" "" "" "${template_sha:-}"
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
# The template's own length, without the context {{stdin}} folds into it.
recipe_template_chars=0
recipe_had_stdin_marker=0
declared_inputs_present=0
template_sha=""
if [[ -n "$recipe" ]]; then
  recipe_file="$prompts_dir/${recipe}.md"
  if [[ ! -f "$recipe_file" ]]; then
    echo "delegate: recipe '$recipe' not found at $recipe_file" >&2
    exit 2
  fi
  # The template that produced this row, as a short content hash of the
  # frontmatter and the prompt block (lib/recipe.sh), so the outcomes before
  # and after a recipe edit can be told apart without git archaeology
  # (replay-recipe.sh reads it, self-improve.sh splits on it) while a
  # calibration note does not start a new bucket. Empty, and the field
  # omitted, where shasum is missing.
  template_sha=$(recipe_template_sha "$recipe_file")

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

  # Frontmatter `inputs:` block (integer, string, `?` suffix for optional),
  # read by `recipe_required_inputs` in lib/recipe.sh, shared with the
  # boundary hook's nudge. Validated BEFORE placeholder substitution so the
  # caller gets a type error rather than "missing placeholder"; recipes
  # without the block skip it.
  inputs_block=$(recipe_required_inputs "$recipe_file")

  if [[ -n "$inputs_block" ]]; then
    # Parallel indexed arrays: bash 3.2 has no associative arrays. The `?` is
    # parsed off into declared_optional so the type stays a clean enum.
    declared_keys=()
    declared_types=()
    declared_optional=()
    while read -r ikey itype_raw; do
      [[ -z "$ikey" ]] && continue
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

  # First fenced block under '## Prompt template' (lib/recipe.sh), the same
  # block template_sha hashes.
  recipe_template=$(recipe_template "$recipe_file")
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
  recipe_checks=$(recipe_fm_block "$recipe_file" | awk '
    /^checks:[[:space:]]*$/ { in_checks=1; next }
    in_checks && /^[[:space:]]+[a-zA-Z_]/ { print; next }
    in_checks && /^[a-zA-Z_]/ { in_checks=0 }
  ')

  # Frontmatter `echo_guard_vars:`: comma-separated --var names whose values
  # are shape exemplars and must never come back in the output (#428).
  recipe_echo_guard_vars=$(recipe_fm_block "$recipe_file" | awk '
    /^echo_guard_vars:[[:space:]]*/ {
      sub(/^echo_guard_vars:[[:space:]]*/, ""); print; exit
    }
  ')

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

  # prompt_chars is measured here, before {{stdin}} folds the context in:
  # context_chars already counts it, and measuring after the substitution
  # counted it twice in estimated_tokens_avoided (#550).
  recipe_template_no_ctx="${recipe_template//\{\{stdin\}\}/}"
  recipe_template_chars=${#recipe_template_no_ctx}
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

# Weak inputs (#590): the recipe's frontmatter `input_quality:` block maps an
# input (a --var name, or `stdin`) to the shape that makes it weak. A match is
# named on one stderr line and recorded on the row as `input_quality`, and the
# call goes ahead: an exit-2 refusal writes no row, so callers padded inputs
# past it or stopped delegating. The labels:
#   one_line_exemplar  no exemplar carries a body (one detector, read by
#   titles_only        the value's shape; the two names follow each recipe):
#                        `git log --pretty=fuller` — no commit whose indented
#                        message holds a second non-blank line, so the gap
#                        between headers and subject is not a body;
#                        the gather step's BODY:/<<<EXAMPLE_END>>> envelope —
#                        no BODY: section with a non-blank line in it;
#                        anything else — no non-blank line after a blank one
#                        that is not itself subject-shaped (any `#N ` line,
#                        or a conventional `type(scope): ` line, optionally
#                        behind a sha or a bare number)
#   no_diff            no `diff --git` or `@@` line
# A label this list does not know is ignored.
input_quality=""
if [[ -n "$recipe" ]]; then
  iq_decl=$(recipe_fm_block "$recipe_file" | awk '
    /^input_quality:[[:space:]]*$/ { in_iq=1; next }
    in_iq && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*[a-z_]+[[:space:]]*$/ {
      gsub(/[:[:space:]]+/, " "); sub(/^ /, ""); print; next }
    in_iq && /^[a-zA-Z_]/ { in_iq=0 }
  ')
  iq_named=""
  while read -r iq_key iq_label; do
    [[ -z "$iq_key" ]] && continue
    iq_value=""
    if [[ "$iq_key" == "stdin" ]]; then
      iq_value="$context"
    else
      # The first value, the one the substitution used.
      for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
        if [[ "${kv%%=*}" == "$iq_key" ]]; then iq_value="${kv#*=}"; break; fi
      done
    fi
    case "$iq_label" in
      no_diff)
        grep -Eq '^diff --git |^@@ ' <<<"$iq_value" && continue ;;
      one_line_exemplar|titles_only)
        # Exit 0 when some exemplar carries a body, per the shapes above.
        printf '%s\n' "$iq_value" | awk '
          function subj(l) { return l ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+ / ||
                                    l ~ /^#[0-9]+ / ||
                                    l ~ /^([0-9]+ )?[a-z]+(\([^)]*\))?!?: / }
          /^commit [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/ { mode = "fuller"; msg = 0; next }
          mode == "fuller" { if (/^[[:space:]]+[^[:space:]]/ && ++msg >= 2) body = 1; next }
          /^<<<EXAMPLE_(BEGIN|END)/ { mode = "env"; inbody = 0; next }
          /^BODY:/ { mode = "env"; inbody = 1; if (/^BODY:[[:space:]]*[^[:space:]]/) body = 1; next }
          mode == "env" { if (inbody && NF) body = 1; next }
          NF { if (gap && !subj($0)) body = 1; seen = 1; next }
          seen { gap = 1 }
          END { exit !body }' && continue ;;
      *) continue ;;
    esac
    input_quality="${input_quality:+$input_quality,}$iq_label"
    iq_named="${iq_named:+$iq_named, }$iq_key=$iq_label"
  done <<<"$iq_decl"
  if [[ -n "$iq_named" ]]; then
    echo "delegate: weak input for recipe '$recipe': $iq_named (sending anyway; see \"Context to gather first\" in prompts/$recipe.md)" >&2
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
      echo "         '$tier' is not a tier — pick one from the valid list above."
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

# Sampler profile: greedy (temperature 0) for every model. The
# Qwen-recommended profile was auto-applied once and measured to regress
# commit-message output (temperature reintroduces the padding tails the recipe
# guards reject), so DELEGATE_TEMPERATURE is the one opt-in. Only an explicit
# value reaches the row, so a bare greedy call writes no sampling_temperature.
sampling_temperature="0"
metric_sampling_temperature=""
if [[ -n "${DELEGATE_TEMPERATURE:-}" ]]; then
  # bash 3.2 =~ POSIX ERE: optional minus, then digits, digits.digits,
  # digits. or .digits. A permissive `case` pattern let `1-2` reach jq --argjson.
  if ! [[ "$DELEGATE_TEMPERATURE" =~ ^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)$ ]]; then
    echo "delegate: DELEGATE_TEMPERATURE='$DELEGATE_TEMPERATURE' is not numeric" >&2
    exit 2
  fi
  sampling_temperature="$DELEGATE_TEMPERATURE"
  metric_sampling_temperature="$DELEGATE_TEMPERATURE"
fi
# Validated here, not at dispatch: `4k` made jq --argjson fail, and curl then
# posted an empty body (#547). A positive integer with no leading zero, not
# the temperature's numeric test: strict providers reject 4.0 and -1, and 04
# is not JSON.
# Not local: the dispatch-failure guidance reads it.
max_tokens="${DELEGATE_MAX_TOKENS:-4096}"
if ! [[ "$max_tokens" =~ ^[1-9][0-9]*$ ]]; then
  echo "delegate: DELEGATE_MAX_TOKENS='$max_tokens' is not a positive integer" >&2
  exit 2
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
  curl -sS --fail --max-time "$preflight_timeout" -X POST "$canary_url" \
    -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 <<< "$canary_payload"
  canary_status=$?
  if (( canary_status != 0 )); then
    emit_failure 3 "$model" "$metric_sampling_temperature"
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
# The request body could not be built (jq failed), so nothing was sent.
EMPTY_PAYLOAD_STATUS=101
# Initialised here because the script runs under `set -u`.
empty_finish_reason=""

# dispatch_to_model — POST the request to $model, parse the response into the
# globals $output, $status, $ttfb_s, $payload, and strip any reasoning trace.
dispatch_to_model() {
# Not validated: a non-numeric value makes curl print its own clear error.
# Not local: the dispatch-failure guidance below reads it.
request_timeout="${DELEGATE_REQUEST_TIMEOUT:-600}"
# /chat/completions, never /v1/completions: the raw-prompt endpoint bypasses
# the chat template and instruction-tuned models emit whitespace until
# max_tokens. enable_thinking is passed so `content` carries the answer, not
# the reasoning trace.
# The only sampler key is temperature, 0 unless DELEGATE_TEMPERATURE set
# it. The input goes in on stdin
# (-Rs), never as an --arg: above ARG_MAX (1 MiB on macOS, 128 KiB per
# argument on Linux) jq cannot start and the body came out empty (#547).
payload=$(printf '%s' "$full_input" | jq -Rsc --arg m "$model" --argjson mt "$max_tokens" --argjson et "$think" \
  --argjson temp "$sampling_temperature" \
  '{model:$m, messages:[{role:"user", content:.}], stream:false, temperature:$temp, max_tokens:$mt, chat_template_kwargs:{enable_thinking:$et}}')
# resolved_base already had one trailing slash stripped by pick-model.sh, so
# the join cannot double up.
chat_url="$resolved_base/chat/completions"
ttfb_s=""
if [[ -z "$payload" ]]; then
  # Never POST a 0-byte body: the provider's refusal read as a daemon fault.
  status=$EMPTY_PAYLOAD_STATUS
else
  # --data-binary sends the bytes as-is with the JSON type; -d would label
  # them application/x-www-form-urlencoded.
  ttfb_s=$(curl -sS --fail --max-time "$request_timeout" --connect-timeout 5 \
    -X POST "$chat_url" -H 'Content-Type: application/json' --data-binary @- \
    -o "$body_file" -w "%{time_starttransfer}" <<< "$payload")
  status=$?
fi
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

dispatch_to_model

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
elif (( status == EMPTY_PAYLOAD_STATUS )); then
  {
    echo "delegate: request payload is empty, nothing was sent — model=\"$model\" tier=\"$tier\" backend=\"$backend\""
    echo "         jq could not build the chat request (its error, if any, is above); check that jq is installed and working"
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
# recipe's frontmatter, a flavor profile, an env var), here and in
# lib/checks.sh, writes the operand as `10#$var`: bash reads a leading zero as
# octal, so `subject_max: 08` aborted the arithmetic AND took the wrong
# branch, failing open. The `^[0-9]+$` guards keep the value numeric; `10#`
# keeps it decimal. The output checks themselves (run_output_checks,
# retry_constraint_for) live in lib/checks.sh, sourced above.

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
retry_failed=""
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
  # Kept so a retry that fails to dispatch returns this draft (#550).
  first_output="$output" first_full_input="$full_input" first_checks_stderr=$(cat "$checks_stderr")
  first_checks_run=$checks_run first_checks_failed=$checks_failed
  first_checks_autofixed=$checks_autofixed first_checks_failed_names=$checks_failed_names
  full_input="${full_input}

Your previous answer was REJECTED. It broke these constraints:
${retry_notice}Write the answer again, in full, obeying every rule above. Output only the answer."
  retry_chars=$(( retry_chars + ${#full_input} - retry_input_before ))
  # duration_ms covers both dispatches, so both waits are summed or the whole
  # rejected call lands in generation_ms; dispatch_to_model overwrites ttfb_s.
  ttfb_prev="${ttfb_s:-0}"
  dispatch_to_model
  ttfb_s=$(awk -v a="${ttfb_prev:-0}" -v b="${ttfb_s:-0}" 'BEGIN { printf "%.6f", a + b }')
  if (( status == 0 )); then
    run_output_checks
  else
    # A failed dispatch (transport error, empty answer) is no reason to throw
    # away a usable draft: return the first generation with its own status,
    # check results and input, and mark the row. The rejected generation is
    # now the output, so retry_chars keeps only the notice.
    echo "delegate: the retry failed (status $status); the first draft is returned, with the check failures below." >&2
    [[ -n "$first_checks_stderr" ]] && printf '%s\n' "$first_checks_stderr" >&2
    retry_failed="true"
    status=0
    output="$first_output"
    full_input="$first_full_input"
    retry_chars=$(( retry_chars - rejected_output_chars ))
    checks_run=$first_checks_run checks_failed=$first_checks_failed
    checks_autofixed=$first_checks_autofixed checks_failed_names=$first_checks_failed_names
  fi
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
prompt_chars=$(( recipe_template_chars + ${#prompt} ))
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
  # --var as passed, the resolved tier, the positional prompt when there was
  # one — so replay-recipe.sh can render the same case under another
  # template on the same tier. jq builds it from the flat key/value list
  # because values carry newlines; a key passed twice keeps its first value,
  # which is the one the substitution used (the second found no placeholder).
  inputs_json=""
  if [[ -n "$recipe" ]]; then
    kv_flat=()
    for kv in ${recipe_vars[@]+"${recipe_vars[@]}"}; do
      kv_flat+=("${kv%%=*}" "${kv#*=}")
    done
    # The piped context goes in on stdin, as for the chat payload (#547).
    inputs_json=$(printf '%s' "$context" | jq -Rsc --arg recipe "$recipe" --arg prompt "$prompt" --arg tier "$tier" \
      '{recipe:$recipe, tier:$tier, stdin:.,
        vars:(reduce ($ARGS.positional | [range(0; length; 2) as $i | {key: .[$i], value: .[$i+1]}] | .[]) as $kv
                ({}; if has($kv.key) then . else . + {($kv.key): $kv.value} end))}
       + (if $prompt != "" then {prompt:$prompt} else {} end)' \
      --args ${kv_flat[@]+"${kv_flat[@]}"} 2>/dev/null)
  fi
  IFS=$'\t' read -r draft_file input_file inputs_file <<<"$(capture_draft "$output" "$ts_start" "${recipe:+$full_input}" "$inputs_json")"
fi

# The draft verifier (#661), recipe calls only, after the checks and any
# retry: verify-draft.sh scores whether every claim in the draft is stated in
# the call's facts (the piped stdin then each --var value, the rule its --id
# mode uses). It informs the caller and never acts: the draft, the retry and
# the exit code are untouched, since retries did not repair the reply
# recipes (#513, #514). DELEGATE_VERIFY=1 forces it on, =0 off, otherwise
# the recipe's frontmatter `verify: true` decides. The row gets `verify`
# (verify-draft.sh's JSON line) or `verify_error` (why there is no score).
# Run after duration_ms is taken, so that keeps meaning the generation; the
# verifier's own time is verify.latency_ms. DELEGATE_DECIDE_TIMEOUT bounds
# each request at 60 s by default here (decide.sh's own default is 120),
# which covers a 27B cold load of about 20 s.
verify_json=""
verify_error=""
verify_on=0
if [[ -n "$recipe" ]] && (( status == 0 )) && [[ -n "$output" ]]; then
  case "${DELEGATE_VERIFY:-}" in
    1) verify_on=1 ;;
    0) ;;
    *) [[ "$(recipe_verify "$recipe_file")" == "true" ]] && verify_on=1 ;;
  esac
fi
if (( verify_on == 1 )); then
  verify_timeout="${DELEGATE_DECIDE_TIMEOUT:-60}"
  verify_err=$(mktemp)
  if [[ -z "$inputs_json" ]]; then
    verify_rc=2
    echo "verify-draft: the call's structured inputs could not be built" > "$verify_err"
  else
    verify_json=$({ printf '%s' "$inputs_json"; printf '%s' "$output" | jq -Rs .; } | recipe_verify_input \
      | DELEGATE_DECIDE_TIMEOUT="$verify_timeout" bash "$script_dir/verify-draft.sh" 2>"$verify_err")
    verify_rc=$?
  fi
  if (( verify_rc <= 1 )) && jq -e '.verdict' <<<"$verify_json" >/dev/null 2>&1; then
    # verify-draft.sh's only stderr on a score is the uncalibrated-threshold
    # note, which the caller should see.
    cat "$verify_err" >&2
    if [[ "$(jq -r '.verdict' <<<"$verify_json")" == "flag" ]]; then
      echo "delegate: verifier flagged a possibly unsupported claim ($(jq -r '"p_supported=\(.p_supported) < \(.threshold), \(.model)"' <<<"$verify_json")) — check the draft against the facts before posting." >&2
    fi
  else
    verify_json=""
    # A curl --max-time on decide.sh's request is named as the timeout it
    # is; otherwise verify-draft.sh's own last word on why.
    if grep -q 'curl: (28)' "$verify_err"; then
      verify_error="timed out after ${verify_timeout}s"
    else
      verify_error=$(grep '^verify-draft: ' "$verify_err" | tail -n 1)
      verify_error="${verify_error#verify-draft: }"
      [[ -n "$verify_error" ]] || verify_error="verify-draft.sh exited $verify_rc"
    fi
    echo "delegate: verifier unavailable ($verify_error); the draft is returned unverified." >&2
  fi
  rm -f "$verify_err"
fi
# row_written is what the meta line's ts/id and the verdict nudge are gated
# on: they name the row this call wrote, so they are only true when one was.
row_written=false
log_metric "$ts_start" "$tier" "$model" "$prompt_chars" "$context_chars" "$output_chars" "$duration_ms" "$status" "$recipe" "$queue_wait_ms" "$generation_ms" "$otel_trace_id" "$otel_span_id" "$metric_sampling_temperature" "$delegate_project" "$checks_run" "$checks_failed" "$checks_autofixed" "$checks_failed_names" "$draft_file" "$retried" "${retry_chars:-}" "$input_file" "$template_sha" "$inputs_file" "$retry_failed" && row_written=true
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
  if [[ -n "$verify_json" ]]; then
    meta="$meta verify=\"$(jq -r '.verdict' <<<"$verify_json")\""
  elif [[ -n "$verify_error" ]]; then
    meta="$meta verify=\"error\""
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
