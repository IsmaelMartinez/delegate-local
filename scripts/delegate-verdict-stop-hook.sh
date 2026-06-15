#!/usr/bin/env bash
# Stop hook (Phase E) — the agent-observed verdict source for #306-era coverage.
#
# Auto-delegation (the boundary hook's commit-message nudge, /address-pr-comments
# maintainer replies, /roadmap status notes) moved the decision-maker from the
# human to the agent, but verdict recording stayed manual — so recipe coverage
# slips as auto-delegation rises. The session-end sweep meant to catch the
# backlog (verdict-sweep.sh) is interactive and never runs on background jobs.
#
# The agent is the only party that knows whether it used a delegated output, and
# only while it is still running. A Stop hook fires when the main agent finishes
# a turn — the agent is alive, the turn's work is done, and it can judge its own
# delegations from live memory. This hook surfaces the current project's
# untracked delegations once per session and hands the batch back to the agent
# with an instruction to record each with `delegate-feedback.sh --source agent`.
#
# Honesty boundary: the agent can only report a FACT about its own behaviour
# ("did I use it"), never the maintainer's taste judgment ("was it good"). The
# verdicts it records are tagged verdict_source:"agent" and kept in a separate
# tier — coverage counts them, the headline hit-rate does not (see ADR 0015).
#
# On every Stop event:
#   1. If mode is `off`, exit 0 immediately.
#   2. If this session already had a batch surfaced (a marker file keyed by
#      session_id exists), exit 0 — the session-once guard that stops the
#      decision:"block" re-inject from looping when the agent declines.
#   3. Derive the project (same rule as delegate.sh / the boundary hook) and
#      scan metrics.jsonl for this project's untracked successful delegations
#      inside the look-back window — verdict-sweep.sh's base join plus a
#      .project filter, minus the tty prompt.
#   4. Empty set → exit 0 (cheap path, no marker written, so a later Stop after
#      a fresh delegation can still surface it).
#   5. Non-empty set → write the session marker, then emit
#      {"decision":"block","reason":...} listing the batch. `decision:"block"`
#      is what re-engages a stopping agent (plain additionalContext does not).
#
# There is no `enforce` mode: coercing a verdict is both hostile and dishonest —
# a forced verdict is not a fact. Mode is warn (surface once) or off.
#
# Fails OPEN: any error, missing jq, unparseable input, or an unwritable marker
# exits 0 so a session is never wedged by a verdict sweep. If the marker cannot
# be written the hook does NOT inject — injecting without a marker would risk the
# very loop the marker guards against.
#
# Env:
#   DELEGATE_VERDICT_STOP_MODE   warn (default) | off
#   DELEGATE_SWEEP_WINDOW_HOURS  look-back in hours (default 24; shared with
#                                verdict-sweep.sh)
#   DELEGATE_METRICS_FILE        metrics path (shared with delegate.sh)

set -uo pipefail

mode="${DELEGATE_VERDICT_STOP_MODE:-warn}"
[[ "$mode" == "off" ]] && exit 0

# --- read the harness payload ---------------------------------------------
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

session_id=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null) || exit 0
hook_cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || hook_cwd=""

metrics_file="${DELEGATE_METRICS_FILE:-$HOME/.claude/skills/delegate-local/metrics.jsonl}"
window_hours="${DELEGATE_SWEEP_WINDOW_HOURS:-24}"
[[ "$window_hours" =~ ^[0-9]+$ ]] || exit 0   # non-numeric → fail open

# A Stop with no metrics file yet has nothing to sweep.
[[ -f "$metrics_file" ]] || exit 0

# --- session-once guard ----------------------------------------------------
# The marker is written only when a batch is actually surfaced (step 5). Its
# presence on a later Stop in the SAME session makes the hook exit 0 without
# re-injecting, so a declined or ignored prompt cannot loop the agent to the
# turn limit. A session with no session_id (shouldn't happen, but fail open
# safely) skips the guard and relies on idempotency over the tracked set.
marker_dir="$(dirname "$metrics_file")/.verdict-stop-markers"
marker=""
if [[ -n "$session_id" ]]; then
  marker="$marker_dir/$session_id"
  [[ -f "$marker" ]] && exit 0
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

# --- scan for this project's untracked delegations in the window ----------
# verdict-sweep.sh's base join (delegate rows with exit_status 0 and no
# referencing feedback row, inside the window) PLUS a .project filter — the
# sweep is process-wide, but a Stop in repo A must not surface repo B's work.
# The feedback-ref map stays global (a feedback row references a ts regardless
# of which project recorded it). No tty step: the agent is the consumer here.
cutoff_iso=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]*3600))' "$window_hours" 2>/dev/null) || exit 0
[[ -z "$cutoff_iso" ]] && exit 0

rows=$(jq -rs --arg cutoff "$cutoff_iso" --arg proj "$project" '
  def src: .source // "delegate";
  (reduce (.[] | select(src == "feedback" and .ref_ts != null)) as $f ({}; .[$f.ref_ts] = true)) as $fb
  | map(select(src == "delegate"
        and (.ts != null)
        and ((.exit_status // 0) == 0)
        and ((.project // "") == $proj)
        and (.ts >= $cutoff)
        and ($fb[.ts] | not)))
  | .[]
  | [.ts, (.recipe // "(bare/no-recipe)"), (.tier // "-")] | @tsv
' "$metrics_file" 2>/dev/null) || exit 0   # corrupt file → fail open, never wedge

# Cheap common path: nothing to verdict. No marker written, so a later Stop
# after a fresh delegation in this session can still surface it.
[[ -z "$rows" ]] && exit 0

# --- write the session marker (must succeed before we inject) -------------
# If the marker can't be written, do NOT inject: injecting without a durable
# marker would let the next Stop re-surface the same batch and loop.
if [[ -n "$marker" ]]; then
  mkdir -p "$marker_dir" 2>/dev/null || exit 0
  : > "$marker" 2>/dev/null || exit 0
  # Opportunistic prune so per-session markers don't accumulate forever. Bounded
  # by the rare inject path and tolerant of find flag differences (BSD + GNU
  # both support -mtime/-delete); failure is non-fatal.
  find "$marker_dir" -type f -mtime +7 -delete 2>/dev/null || true
fi

# --- surface the batch and hand it back to the agent ----------------------
count=$(printf '%s\n' "$rows" | grep -c '')
batch=$(printf '%s\n' "$rows" | awk -F'\t' 'NF>=1 && $1!="" {printf "  - ts=%s  recipe=%s  tier=%s\n", $1, $2, $3}')

reason=$(cat <<EOF
delegate-local verdict sweep (project '${project}'): ${count} delegation(s) from this session produced output but carry no verdict. Before you stop, for each one you recognise from THIS session, record whether you USED the delegated output as-is (hit) or rewrote/discarded it (miss) — this is a fact about what you did, not a judgment of quality:

${batch}
  bash ~/.claude/skills/delegate-local/scripts/delegate-feedback.sh --ts <ts> --source agent hit|miss

Leave any ts you do not recognise (a leftover from a prior session) untouched — the interactive verdict-sweep.sh handles those. This prompt is shown once per session; recording what you can and then stopping is fine. Set DELEGATE_VERDICT_STOP_MODE=off to silence.
EOF
)

jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
