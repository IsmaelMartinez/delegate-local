#!/usr/bin/env bash
# PreToolUse hook (Bash matcher) — the trigger-rate boundary for #277.
#
# Skill auto-invocation is turn-INITIAL, but the highest-volume delegation
# triggers (commit message, PR body, release note) are turn-MEDIAL: the last
# sub-step of "implement X, commit, open a PR". By then the agent is deep in
# execution and never re-runs skill selection, so it writes the message inline
# and the calibrated recipes go unused. Instruction text in SKILL.md cannot fix
# a control-flow gating gap (#226 tried; the reminders kept coming). A hook can:
# it fires at the missed site, in the harness, regardless of whether the agent
# re-considered the skill.
#
# On every Bash call:
#   1. If the command is NOT a delegatable boundary (commit, PR/MR-create,
#      issue-create with an inline body, release-create, PR review-comment reply,
#      or PR/issue/MR comment reply), exit 0 immediately — the cheap common path
#      (no jq slurp, no metrics read).
#   2. Otherwise derive the project (same rule as delegate.sh's metrics rows) and
#      check metrics.jsonl for a delegate.sh row for THIS project within the last
#      N minutes. Its presence means the artifact was drafted locally; its
#      absence means it is about to be authored inline.
#   3. Log one source:"opportunity" row per boundary with delegated:true|false so
#      metrics-summary.sh can report trigger rate = delegated / opportunities per
#      project — the number #277 is about, previously unmeasured.
#   4. When delegated:false, surface a reminder naming the exact recipe. Mode is
#      env-controlled: warn (default, non-blocking additionalContext the model
#      sees), enforce (deny the call so the model re-routes), or off (measure
#      only, no reminder).
#
# Fails OPEN: any error, missing jq, or unparseable input exits 0 so a commit is
# never blocked by a hook bug. The only blocking path is the explicit
# DELEGATE_BOUNDARY_MODE=enforce deny. Install is opt-in — see
# docs/boundary-hook.md.
#
# Env:
#   DELEGATE_BOUNDARY_MODE        warn (default) | enforce | off
#   DELEGATE_BOUNDARY_WINDOW_MIN  look-back window for a prior delegation (default 10)
#   DELEGATE_METRICS_FILE         metrics path (shared with delegate.sh)
#   DELEGATE_LOCAL_NO_METRICS=1   skip writing the opportunity row

set -uo pipefail

# --- read the harness payload ---------------------------------------------
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
[[ -z "$cmd" ]] && exit 0
hook_cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || hook_cwd=""

# --- is this a delegatable boundary? (cheap path exits here) --------------
# git commit that authors a message inline (-m/-F), but not --amend (which
# reuses an existing message — no fresh drafting moment).
boundary="" recipe=""
if grep -Eq '(^|[^[:alnum:]_])git[[:space:]]+commit([[:space:]]|$)' <<<"$cmd" \
   && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[mF]|--message|--file)' <<<"$cmd" \
   && ! grep -Eq -- '--amend' <<<"$cmd"; then
  boundary="git-commit"; recipe="commit-message"
elif grep -Eq '(^|[^[:alnum:]_])gh[[:space:]]+pr[[:space:]]+create' <<<"$cmd" \
   || grep -Eq '(^|[^[:alnum:]_])glab[[:space:]]+mr[[:space:]]+create' <<<"$cmd"; then
  boundary="pr-create"; recipe="pr-description"
# New issue authored with an inline body (--body / -b / --body-file / -F), but
# not the interactive editor or the --web form — those have no inline drafting
# moment, same reasoning as commit --amend.
elif grep -Eq '(^|[^[:alnum:]_])gh[[:space:]]+issue[[:space:]]+create' <<<"$cmd" \
   && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[bF]|--body)' <<<"$cmd" \
   && ! grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*w|--web)([[:space:]]|$)' <<<"$cmd"; then
  boundary="issue-create"; recipe="github-issue-body"
elif grep -Eq '(^|[^[:alnum:]_])gh[[:space:]]+release[[:space:]]+create' <<<"$cmd"; then
  boundary="release-create"; recipe="release-note"
# Inline PR review-comment reply: `gh api .../comments -X POST -f body=...` (the
# /address-pr-comments inline path). Require an explicit POST so the read-only
# fetch step (`gh api .../comments --jq ...`, no -X POST) is NOT a boundary.
elif grep -Eq '(^|[^[:alnum:]_])gh[[:space:]]+api([[:space:]]|$)' <<<"$cmd" \
   && grep -Eq '/comments' <<<"$cmd" \
   && grep -Eq -- '(-X[[:space:]]*=?POST|--method([[:space:]]+|=)POST)' <<<"$cmd"; then
  boundary="pr-review-comment"; recipe="pr-review-reply"
# General PR / issue / MR comment reply authored inline.
elif grep -Eq '(^|[^[:alnum:]_])gh[[:space:]]+pr[[:space:]]+comment([[:space:]]|$)' <<<"$cmd" \
   || grep -Eq '(^|[^[:alnum:]_])gh[[:space:]]+issue[[:space:]]+comment([[:space:]]|$)' <<<"$cmd" \
   || grep -Eq '(^|[^[:alnum:]_])glab[[:space:]]+(mr|issue)[[:space:]]+(discussion[[:space:]]+)?note([[:space:]]|$)' <<<"$cmd"; then
  boundary="comment-reply"; recipe="maintainer-reply"
else
  exit 0
fi

# --- derive the project name (mirror delegate.sh / lib/otel.sh) -----------
[[ -n "$hook_cwd" && -d "$hook_cwd" ]] && cd "$hook_cwd" 2>/dev/null || true
project=""
common=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [[ -n "$common" ]]; then
  common_dir=$(cd "$common" 2>/dev/null && pwd || true)
  [[ -n "$common_dir" ]] && project=$(basename "$(dirname "$common_dir")")
else
  project=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
fi

# --- was there a local delegation for THIS boundary's recipe, recently? ----
# Recipe-aware: only a delegation whose recipe matches this boundary's recipe
# counts as capturing it. Matching on project alone over-counted — a commit-message
# delegation marked a later `gh pr create` / review-comment reply as captured even
# though the PR body / reply was authored inline, which both inflated the trigger
# rate AND suppressed the nudge (delegated:true skips it below), so the artifact the
# boundary is about was never delegated. A bare (no-recipe) delegation no longer
# counts for any boundary — the calibrated recipe the nudge names is the path.
metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
window_min="${DELEGATE_BOUNDARY_WINDOW_MIN:-10}"
now_epoch=$(date -u +%s)
delegated=false
if [[ -f "$metrics_file" ]]; then
  recent=$(jq -rs --argjson win "$((window_min * 60))" --arg proj "$project" --arg recipe "$recipe" --argjson now "$now_epoch" '
    [ .[]
      | select((.source // "delegate") == "delegate")
      | select((.project // "") == $proj)
      | select((.recipe // "") == $recipe)
      | ((.ts | fromdateiso8601?) // 0)
      | select(. > ($now - $win)) ] | length' "$metrics_file" 2>/dev/null) || recent=0
  [[ "${recent:-0}" -gt 0 ]] && delegated=true
fi

# --- record the opportunity (the trigger-rate sensor) ---------------------
# One row per boundary so trigger rate has a denominator. Stores no command or
# message text — only boundary type, suggested recipe, project, and the flag.
if [[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]]; then
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  jq -nc --arg ts "$ts" --arg project "$project" --arg boundary "$boundary" \
     --arg recipe "$recipe" --argjson delegated "$delegated" '
     {ts:$ts, source:"opportunity", boundary:$boundary, suggested_recipe:$recipe, delegated:$delegated}
     + (if $project != "" then {project:$project} else {} end)' \
     >> "$metrics_file" 2>/dev/null || true
fi

# --- nudge only when the artifact is about to be authored inline ----------
[[ "$delegated" == "true" ]] && exit 0

mode="${DELEGATE_BOUNDARY_MODE:-warn}"
[[ "$mode" == "off" ]] && exit 0

reminder="delegate-local: about to author a ${boundary} message inline with no local delegation recorded in the last ${window_min}m for project '${project}'. Draft it on-device first — bash ~/.claude/skills/delegate-local/scripts/delegate.sh --recipe ${recipe} <tier> \"...\" — then record the verdict with scripts/delegate-feedback.sh. Set DELEGATE_BOUNDARY_MODE=off to silence."

if [[ "$mode" == "enforce" ]]; then
  jq -nc --arg r "$reminder" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  jq -nc --arg c "$reminder" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$c}}'
fi
exit 0
