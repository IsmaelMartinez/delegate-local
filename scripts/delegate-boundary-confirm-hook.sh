#!/usr/bin/env bash
# PostToolUse hook (Bash matcher): confirms that a boundary credit was spent
# (#497). delegate-boundary-hook.sh spends a delegation credit at PreToolUse
# time, before the harness has decided whether the call runs: the worktree
# guard refuses it after that hook, or git fails on an empty index, and the
# retry found the credit gone. PostToolUse fires only when the tool ran and
# succeeded (a non-zero exit fires PostToolUseFailure; a permission denial
# fires nothing after PreToolUse), so this is the one place the outcome is
# known. It removes the pending marker the boundary hook left for this call,
# matched by tool_use_id so no other call can confirm it, and creates a
# per-session file that tells the boundary hook a confirmation can be
# expected at all. Fails OPEN: any error exits 0 with no output. Install is
# opt-in, beside the boundary hook — see docs/boundary-hook.md.
#
# Env:
#   DELEGATE_LOCAL_DATA_DIR       where per-user data lives
#                                 (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE         metrics path (shared with delegate.sh)
#   DELEGATE_LOCAL_NO_METRICS=1   nothing was credited, so nothing to confirm

set -uo pipefail

[[ -t 0 ]] && exit 0
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]] || exit 0

# Registered under PostToolUseFailure by mistake, this hook would confirm the
# failed post and deny its retry, so the event is checked, not assumed. Unit
# separator, not tab: tab is IFS whitespace, so an empty field would collapse
# and shift the tool id into the session.
IFS=$'\x1f' read -r event session_id tool_use_id interrupted < <(jq -r '
  [(.hook_event_name // ""), (.session_id // ""), (.tool_use_id // ""),
   ((.tool_response.interrupted // false) | tostring)] | join("\u001f")' <<<"$input" 2>/dev/null) || exit 0
[[ "${event:-}" == "PostToolUse" && -n "${session_id:-}" ]] || exit 0

metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
pending_dir="$(dirname "$metrics_file")/.boundary-pending"

# The seen file is the boundary hook's evidence that this session has a
# confirm hook: without it an unconfirmed marker means nothing, since a
# PreToolUse-only install never confirms. One stat per call once it exists.
seen="$pending_dir/$session_id.seen"
if [[ ! -f "$seen" ]]; then
  mkdir -p "$pending_dir" 2>/dev/null || exit 0
  chmod 700 "$pending_dir" 2>/dev/null || true
  : > "$seen" 2>/dev/null || exit 0
fi

# An interrupted call may or may not have posted; only a clean success confirms.
[[ -n "${tool_use_id:-}" && "${interrupted:-}" != "true" ]] || exit 0
for marker in "$pending_dir/$session_id".*; do
  [[ -f "$marker" && "$marker" != "$seen" ]] || continue
  if [[ "$(jq -r '.id // empty' "$marker" 2>/dev/null)" == "$tool_use_id" ]]; then
    rm -f "$marker" 2>/dev/null
  fi
done
exit 0
