#!/usr/bin/env bash
# Stop hook (Phase E) — the backstop for verdicts the agent did not record
# inline.
#
# Auto-delegation (the boundary hook's commit-message nudge, /address-pr-comments
# maintainer replies, /roadmap status notes) moved the decision-maker from the
# human to the agent, and the verdict moved with it: the agent that used or
# rewrote a draft is the one party that knows what happened to it, and the
# only judge there is (ADR 0030). It knows only while it is still running. A
# Stop hook fires when the main agent finishes a turn — the agent is alive,
# the turn's work is done, and it can judge its own delegations from live
# memory. This hook surfaces this session's untracked delegations once and
# hands the batch back to the agent with an instruction to record each with
# `delegate-feedback.sh --id <id> --source agent`.
#
# The verdict is a fact about the agent's own behaviour — did it use the
# draft, edit and ship it, or throw it away — and the reason on a scaffold or
# miss, with the stored draft/final pair, is the calibration signal.
#
# On every Stop event:
#   1. If mode is `off`, exit 0 immediately.
#   2. If this session already had a batch surfaced (a marker file keyed by
#      session_id exists), exit 0 — the session-once guard that stops the
#      decision:"block" re-inject from looping when the agent declines.
#   3. Derive the project (same rule as delegate.sh / the boundary hook) and
#      scan metrics.jsonl for this session's untracked successful delegations
#      inside the look-back window: delegate rows with exit_status 0 and no
#      referencing feedback row, filtered to the project and the session.
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
#   DELEGATE_SWEEP_WINDOW_HOURS  look-back in hours (default 24)
#   DELEGATE_METRICS_FILE        metrics path (shared with delegate.sh)

set -uo pipefail

mode="${DELEGATE_VERDICT_STOP_MODE:-warn}"
[[ "$mode" == "off" ]] && exit 0

# --- read the harness payload ---------------------------------------------
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

session_id=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null) || exit 0
hook_cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || hook_cwd=""

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
window_hours="${DELEGATE_SWEEP_WINDOW_HOURS:-24}"
[[ "$window_hours" =~ ^[0-9]+$ ]] || exit 0   # non-numeric → fail open

# A Stop with no metrics file yet has nothing to sweep.
[[ -f "$metrics_file" ]] || exit 0

# --- session-once guard ----------------------------------------------------
# The marker is written only when a batch is actually surfaced (step 5). Its
# presence on a later Stop in the SAME session makes the hook exit 0 without
# re-injecting, so a declined or ignored prompt cannot loop the agent to the
# turn limit. The marker IS the loop guard, keyed by session_id — so a Stop
# with no session_id (shouldn't happen) cannot be guarded, and we fail open by
# NOT injecting rather than risk a guardless re-inject on every Stop.
[[ -z "$session_id" ]] && exit 0
# The injected instruction must name the SAME metrics file this hook scanned.
# Without it the hook resolves one path and the agent's shell resolves another,
# so a verdict can be recorded against a file the untracked-set never read.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
marker_dir="$(dirname "$metrics_file")/.verdict-stop-markers"
marker="$marker_dir/$session_id"
[[ -f "$marker" ]] && exit 0

# --- derive the project name (shared with delegate.sh via lib/otel.sh) -----
# The same delegate_project_name the rows being scanned were written with, so
# the filter below matches by construction: DELEGATE_PROJECT is honoured, and
# outside a git repository the project is EMPTY rather than the cwd's basename
# (#476) — the inline mirror that lived here carried the same `|| pwd`
# fallback the boundary hook had, so a Stop in a parent folder of checkouts
# scanned for rows under that folder's name, which delegate.sh never writes.
# An empty project scans the projectless rows, which is what delegate.sh
# records from that same cwd — but only those THIS session wrote (see the
# selector below). A missing lib leaves it empty too: fail open.
[[ -n "$hook_cwd" && -d "$hook_cwd" ]] && cd "$hook_cwd" 2>/dev/null || true
project=""
if [[ -f "$script_dir/lib/otel.sh" ]]; then
  # shellcheck source=lib/otel.sh
  . "$script_dir/lib/otel.sh"
  project=$(delegate_project_name 2>/dev/null) || project=""
fi

# --- scan for this session's untracked delegations in the window ----------
# Delegate rows with exit_status 0 and no referencing feedback row, inside the
# window, filtered to the project (a Stop in repo A must not surface repo B's
# work) and to the session. The feedback-ref map stays global (a feedback row
# references a delegation regardless of which project recorded it). No tty
# step: the agent is the consumer here.
#
# "Referencing" is by otel_span_id first and ts second (#481). ts is
# second-precision and parallel delegations share it, so a map keyed on ts
# alone marked a verdicted row's same-second sibling as tracked and the
# sibling was never surfaced. A feedback row written since #479 carries
# ref_id, the delegate row's otel_span_id, and is keyed on that; one written
# before carries ref_ts only and is keyed on the ts, which still reaches every
# delegate row of that second — the best a legacy row can do.
#
# The metrics file is shared by every session on the machine, and delegate.sh
# records CLAUDE_CODE_SESSION_ID as `session` (#479), the same UUID this
# payload carries. Only a row whose session is this one is listed, named
# project or not: #477 scoped only the projectless rows this way, so a row
# under this repo's name from a parallel session was still listed here, and
# with no human sweep to pick it up (ADR 0030) that asked an agent about a
# draft it never saw. A row with no session field is nobody's — surfacing it
# to every session in the repo is the same wrong question — so it stays
# untracked; #479 merged 2026-09-12, so the rows that predate the field sit
# outside the 24 h window in any case.
cutoff_iso=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]*3600))' "$window_hours" 2>/dev/null) || exit 0
[[ -z "$cutoff_iso" ]] && exit 0

rows=$(jq -rs --arg cutoff "$cutoff_iso" --arg proj "$project" --arg sid "$session_id" '
  def src: .source // "delegate";
  def in_scope: (.project // "") == $proj and (.session // "") == $sid;
  def fbkey: if (.ref_id // "") != "" then "id:" + .ref_id else "ts:" + .ref_ts end;
  (reduce (.[] | select(src == "feedback" and (.ref_id != null or .ref_ts != null))) as $f ({}; .[$f | fbkey] = true)) as $fb
  | def tracked: $fb["id:" + (.otel_span_id // "")] // $fb["ts:" + .ts] // false;
  map(select(src == "delegate"
        and (.ts != null)
        and ((.exit_status // 0) == 0)
        and in_scope
        and (.ts >= $cutoff)
        and (tracked | not)))
  | .[]
  | [(.otel_span_id // "-"), .ts, (.recipe // "(bare/no-recipe)"), (.tier // "-")] | @tsv
' "$metrics_file" 2>/dev/null) || exit 0   # corrupt file → fail open, never wedge

# Cheap common path: nothing to verdict. No marker written, so a later Stop
# after a fresh delegation in this session can still surface it.
[[ -z "$rows" ]] && exit 0

# --- write the session marker (must succeed before we inject) -------------
# session_id is guaranteed non-empty here (we exit 0 above when it is absent),
# so the marker path is always set. If the marker can't be written, do NOT
# inject: injecting without a durable marker would let the next Stop re-surface
# the same batch and loop.
mkdir -p "$marker_dir" 2>/dev/null || exit 0
: > "$marker" 2>/dev/null || exit 0
# Opportunistic prune so per-session markers don't accumulate forever. Bounded
# by the rare inject path and tolerant of find flag differences (BSD + GNU both
# support -mtime/-delete); failure is non-fatal.
find "$marker_dir" -type f -mtime +7 -delete 2>/dev/null || true

# --- surface the batch and hand it back to the agent ----------------------
# Each batch line leads with the pin to copy. It is the row's otel_span_id
# where the row has one: ts is second-precision and parallel delegations share
# it, so delegate-feedback.sh refuses a --ts pin on a shared second while --id
# cannot name two rows. A row with no span id is pinned by --ts instead — one
# recommended `--id <id>` for every row would have the agent copy `--id -` off
# such a line, which matches nothing, and with the session marker written the
# row would never be surfaced again.
count=$(printf '%s\n' "$rows" | grep -c '')
batch=$(printf '%s\n' "$rows" | awk -F'\t' 'NF>=2 && $2!="" {
  if ($1 == "-") printf "  - --ts %s  recipe=%s  tier=%s\n", $2, $3, $4;
  else           printf "  - --id %s  ts=%s  recipe=%s  tier=%s\n", $1, $2, $3, $4 }')

# Outside a repository there is no name to print; say so rather than `''`.
if [[ -n "$project" ]]; then scope="project '${project}'"
else scope="no project: cwd outside any git repository"; fi
reason=$(cat <<EOF
delegate-local verdict sweep (${scope}): ${count} delegation(s) from this session produced output but carry no verdict. Before you stop, record for each one whether you USED the delegated output as-is (hit), edited it and shipped it (scaffold), or rewrote/discarded it (miss) — a fact about what you did. scaffold and miss need a reason, and --final <path|-> naming what you shipped instead:

${batch}
  DELEGATE_METRICS_FILE="${metrics_file}" bash "${script_dir}/delegate-feedback.sh" <pin from the line above> --source agent hit, scaffold "<reason>" or miss "<reason>"

This prompt is shown once per session; recording what you can and then stopping is fine. Set DELEGATE_VERDICT_STOP_MODE=off to silence.
EOF
)

jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
