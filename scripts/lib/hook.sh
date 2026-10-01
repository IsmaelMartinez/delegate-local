#!/usr/bin/env bash
# Shared preamble of the two Bash hooks, delegate-boundary-hook.sh
# (PreToolUse) and delegate-boundary-confirm-hook.sh (PostToolUse), sourced by
# both (#563). Every Bash call in every session pays both hooks, so nothing
# here spawns a process: the payload is read with bash's own `$(<file)`, and
# the fields the common path needs are matched with `[[ =~ ]]`, never jq.
# Every function fails open: a caller that gets a non-zero status exits 0.

# hook_read_input — sets hook_input to the payload on stdin. Fails on a TTY
# (the hook was run by hand, and reading would block) or an unreadable stdin.
# `$(</dev/stdin)` copies the pipe in a forked subshell with no exec, where
# `$(cat)` paid a fork and an exec on every call.
hook_read_input() {
  hook_input=""
  [[ -t 0 ]] && return 1
  { hook_input=$(</dev/stdin); } 2>/dev/null || return 1
  [[ -n "$hook_input" ]]
}

# The cheap pre-filter, matched against the RAW payload before any jq. A
# boundary needs the word git, gh or glab followed by whitespace (the
# classifier never takes `xgit` or `high` for one), and a wrapper script
# (#469) needs bash, sh or zsh as a word followed by whitespace. In raw JSON
# that whitespace is a space or an escape (`\n`, `\t`, `\u000b`), and a word
# starts after any non-word character or after the letter ending an escape
# (`\ngit`). It over-matches on purpose (the description and the cwd are in
# the payload too) and the token classifier decides; it must never
# under-match, since a payload it rejects is never looked at again. Linear:
# alternations of fixed strings and single classes, no nested quantifier.
_hook_ws='([[:space:]]|\\[ntrfu])'
# An interpreter's word start also excludes `.` and `-`, so the `.sh ` of a
# script name or `-sh ` does not pass for one.
hook_prefilter_re="(^|[^[:alnum:]_]|\\\\[ntrf]|\\\\u000[bBcC])(git|gh|glab)${_hook_ws}|(^|[^[:alnum:]_.-]|\\\\[ntrf]|\\\\u000[bBcC])(bash|sh|zsh)${_hook_ws}"

# hook_json_str KEY — sets REPLY to the value of the string field KEY of the
# raw payload, matched without jq. Inside a JSON string every `"` is escaped,
# so an unescaped `"KEY":"` can only be a real key. Fails when the key is
# absent or its value holds an escape, so the caller falls back to jq rather
# than act on a value it did not decode.
hook_json_str() {
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]*)\""
  REPLY=""
  [[ "$hook_input" =~ $re ]] || return 1
  REPLY="${BASH_REMATCH[1]}"
}

# hook_metrics_paths — sets metrics_file, metrics_dir (its directory, as
# dirname prints it) and pending_dir, the confirm hook's markers beside the
# metrics file (#497). A relative path resolves against the cwd, which both
# hooks set to the payload's cwd before using it.
hook_metrics_paths() {
  metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
  case "$metrics_file" in
    */*) metrics_dir="${metrics_file%/*}"; metrics_dir="${metrics_dir:-/}" ;;
    *)   metrics_dir=. ;;
  esac
  pending_dir="$metrics_dir/.boundary-pending"
}

# hook_chdir DIR — the Bash tool runs in the payload's cwd, so relative
# paths in the command (`--body-file reply.md`) and a relative metrics path
# resolve there. A missing or unusable DIR leaves the cwd as it is.
hook_chdir() {
  [[ -n "$1" && -d "$1" ]] && cd "$1" 2>/dev/null
  return 0
}
