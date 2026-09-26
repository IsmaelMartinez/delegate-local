#!/usr/bin/env bash
# Stop hook: the backstop for verdicts the agent did not record inline. The
# agent that used or rewrote a draft is the only judge there is (ADR 0030),
# and it knows only while it is still running; a Stop fires while it is
# alive with the turn's work done. The hook lists this session's untracked
# successful delegations ONCE and returns {"decision":"block",...}, which is
# what re-engages a stopping agent (additionalContext does not). A marker
# keyed by session_id stops the re-inject looping when the agent declines.
# There is no enforce mode: a forced verdict is not a fact. Fails OPEN: any
# error, missing jq or an unwritable marker exits 0 without injecting.
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

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
window_hours="${DELEGATE_SWEEP_WINDOW_HOURS:-24}"
[[ "$window_hours" =~ ^[0-9]+$ ]] || exit 0   # non-numeric → fail open

# A Stop with no metrics file yet has nothing to sweep.
[[ -f "$metrics_file" ]] || exit 0

# --- session-once guard ----------------------------------------------------
# The marker is written only when a batch is surfaced; a Stop with no
# session_id cannot be guarded, so it does not inject.
[[ -z "$session_id" ]] && exit 0
# The injected instruction must name the SAME metrics file this hook scanned.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
marker_dir="$(dirname "$metrics_file")/.verdict-stop-markers"
marker="$marker_dir/$session_id"
[[ -f "$marker" ]] && exit 0

# --- scan for this session's untracked delegations in the window ----------
# Delegate rows with exit_status 0 and no referencing feedback row, filtered
# to the session; the feedback-ref map stays global. Referencing is by
# otel_span_id first and ts second (#481): a ts-only map marked a verdicted
# row's same-second sibling as tracked. Only rows whose session is this one
# are listed (#479): the file is shared by every session on the machine, and
# asking an agent about a draft it never saw is the wrong question. A row
# with no session field is nobody's and stays untracked. The project is not
# a filter (#551): a session that ran `cd other && ... --project other`
# delegated under two projects, and the marker would hide the second for good.
cutoff_iso=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]*3600))' "$window_hours" 2>/dev/null) || exit 0
[[ -z "$cutoff_iso" ]] && exit 0

rows=$(jq -rs --arg cutoff "$cutoff_iso" --arg sid "$session_id" '
  def src: .source // "delegate";
  def in_scope: (.session // "") == $sid;
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
# Injecting without a durable marker would let the next Stop re-surface the
# same batch and loop.
mkdir -p "$marker_dir" 2>/dev/null || exit 0
: > "$marker" 2>/dev/null || exit 0
# Opportunistic prune; -mtime/-delete work on BSD and GNU find.
find "$marker_dir" -type f -mtime +7 -delete 2>/dev/null || true

# --- surface the batch and hand it back to the agent ----------------------
# Each line leads with the pin to copy: --id where the row has a span id
# (--ts is refused on a shared second), --ts otherwise, since a copied
# `--id -` matches nothing and the marker means the row is never surfaced again.
count=$(printf '%s\n' "$rows" | grep -c '')
batch=$(printf '%s\n' "$rows" | awk -F'\t' 'NF>=2 && $2!="" {
  if ($1 == "-") printf "  - --ts %s  recipe=%s  tier=%s\n", $2, $3, $4;
  else           printf "  - --id %s  ts=%s  recipe=%s  tier=%s\n", $1, $2, $3, $4 }')

# Each verdict is a complete command on its own line, because the line is
# copied as printed (`a | b | c` ran as a pipeline); the note after each is a
# shell comment so a whole-line copy still runs.
reason=$(cat <<EOF
delegate-local verdict sweep:${count} delegation(s) from this session produced output but carry no verdict. Before you stop, record for each one whether you USED the delegated output as-is (hit), edited it and shipped it (scaffold), or rewrote/discarded it (miss) — a fact about what you did. scaffold and miss need a reason, and --final <path|-> naming what you shipped instead:

${batch}

Run one of these per row, with <pin> replaced by the --id or --ts shown on its line:
  DELEGATE_METRICS_FILE="${metrics_file}" bash "${script_dir}/delegate-feedback.sh" <pin> --source agent hit                  # shipped as-is
  DELEGATE_METRICS_FILE="${metrics_file}" bash "${script_dir}/delegate-feedback.sh" <pin> --source agent scaffold "<reason>"  # edited and shipped
  DELEGATE_METRICS_FILE="${metrics_file}" bash "${script_dir}/delegate-feedback.sh" <pin> --source agent miss "<reason>"      # thrown away

This prompt is shown once per session; recording what you can and then stopping is fine. Set DELEGATE_VERDICT_STOP_MODE=off to silence.
EOF
)

jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
