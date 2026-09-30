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
# expected at all. It is also where a credited post's body FILE is stored as
# the shipped final (#587), since only now does the file hold what was
# posted. Fails OPEN: any error exits 0 with no output. Install is
# opt-in, beside the boundary hook — see docs/boundary-hook.md.
#
# Env:
#   DELEGATE_LOCAL_DATA_DIR       where per-user data lives
#                                 (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE         metrics path (shared with delegate.sh)
#   DELEGATE_LOCAL_NO_METRICS=1   nothing was credited, so nothing to confirm

set -uo pipefail

# Resolved before the cd to the payload cwd, as in the boundary hook.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""

[[ -t 0 ]] && exit 0
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]] || exit 0

# Registered under PostToolUseFailure by mistake, this hook would confirm the
# failed post and deny its retry, so the event is checked, not assumed. Unit
# separator, not tab: tab is IFS whitespace, so an empty field would collapse
# and shift the tool id into the session.
IFS=$'\x1f' read -r event session_id tool_use_id interrupted hook_cwd < <(jq -r '
  [(.hook_event_name // ""), (.session_id // ""), (.tool_use_id // ""),
   ((.tool_response.interrupted // false) | tostring), (.cwd // "")] | join("\u001f")' <<<"$input" 2>/dev/null) || exit 0
[[ "${event:-}" == "PostToolUse" && -n "${session_id:-}" ]] || exit 0

# The boundary hook resolves a relative metrics path after chdir to the
# payload cwd; the same chdir here keeps both on one pending directory.
[[ -n "${hook_cwd:-}" && -d "$hook_cwd" ]] && cd "$hook_cwd" 2>/dev/null || true
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

# capture_body_file <marker> — a credited post whose body is a FILE is
# captured here, after the call succeeded, never at PreToolUse (#587): one
# call that writes the file and posts it would have stored what the file held
# before, the previous post's text. Filed under the marker's draft that the
# text overlaps most (the oldest on a tie), with the boundary hook's own
# guarantees: a bare *.draft.txt name, a stem that holds no final yet, an
# exclusive create, 700 on the directory and 600 on the file.
capture_body_file() {
  local marker="$1" body_file drafts_csv drafts_dir d best text captured draft
  local -a cands=()
  IFS=$'\x1f' read -r body_file drafts_csv captured draft < <(jq -r '[(.body_file // ""), ((.drafts // []) | map(strings) | join(",")), (.captured // false | tostring), (.draft // "")] | join("\u001f")' "$marker" 2>/dev/null) || return 0
  [[ -n "${body_file:-}" && "$body_file" == /* && -f "$body_file" && -r "$body_file" ]] || return 0
  drafts_dir="$(dirname "$metrics_file")/drafts"
  text=$(head -c 65536 < "$body_file" 2>/dev/null; printf X); text=${text%X}
  [[ -n "$text" ]] || return 0
  # A retry of a refused inline post whose provisional final the boundary
  # hook wrote (`captured`, #497): what this call sent replaces it.
  case "${draft:-}" in */*|.*) draft="" ;; *.draft.txt) ;; *) draft="" ;; esac
  if [[ "${captured:-}" == "true" && -n "$draft" ]]; then
    ( umask 077; printf '%s' "$text" > "$drafts_dir/${draft%.draft.txt}.final.txt" ) 2>/dev/null
    return 0
  fi
  IFS=',' read -r -a _raw <<<"${drafts_csv:-}"
  for d in ${_raw[@]+"${_raw[@]}"}; do
    case "$d" in */*|.*) continue ;; *.draft.txt) ;; *) continue ;; esac
    [[ -e "$drafts_dir/${d%.draft.txt}.final.txt" ]] || cands+=("$d")
  done
  (( ${#cands[@]} > 0 )) || return 0
  best="${cands[0]}"
  if (( ${#cands[@]} > 1 )) && [[ -f "$script_dir/lib/pair-score.sh" ]]; then
    # shellcheck source=lib/pair-score.sh
    . "$script_dir/lib/pair-score.sh"
    best=$(best_draft <(printf '%s' "$text") "$drafts_dir" "${cands[@]}")
  fi
  mkdir -p "$drafts_dir" 2>/dev/null || return 0
  chmod 700 "$drafts_dir" 2>/dev/null || true
  ( umask 077; set -C; printf '%s' "$text" > "$drafts_dir/${best%.draft.txt}.final.txt" ) 2>/dev/null \
    && chmod 600 "$drafts_dir/${best%.draft.txt}.final.txt" 2>/dev/null
  return 0
}

# An interrupted call may or may not have posted; only a clean success confirms.
[[ -n "${tool_use_id:-}" && "${interrupted:-}" != "true" ]] || exit 0
# One marker per call (#587). It is renamed before it is acted on: the
# boundary hook claims a marker it takes for a retry by the same kind of
# rename, so exactly one of the two wins. A plain marker won here is the
# ordinary confirmation. A `.superseded` one was claimed by a later call
# taken for this one's retry, but this call ran, so that one was a post of
# its own: its row, written beside the claim as `.row`, is appended now.
for marker in "$pending_dir/$session_id".*; do
  [[ -f "$marker" && "$marker" != "$seen" ]] || continue
  case "$marker" in *.row|*.confirming.*) continue ;; esac
  [[ "$(jq -r '.id // empty' "$marker" 2>/dev/null)" == "$tool_use_id" ]] || continue
  mine="$marker.confirming.$$"
  if ! mv "$marker" "$mine" 2>/dev/null; then
    # Claimed between the glob and the rename: act on the claimed copy.
    marker="$marker.superseded"
    mv "$marker" "$mine" 2>/dev/null || continue
  fi
  capture_body_file "$mine"
  if [[ "$marker" == *.superseded ]]; then
    row="${marker%.superseded}.row"
    if [[ -f "$row" ]] && jq -e 'type == "object" and .source == "opportunity"' "$row" >/dev/null 2>&1; then
      jq -c . "$row" >> "$metrics_file" 2>/dev/null
    fi
    rm -f "$row" 2>/dev/null
  fi
  rm -f "$mine" 2>/dev/null
done
exit 0
