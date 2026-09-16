#!/usr/bin/env bash
# PreToolUse hook (Bash matcher): the trigger-rate boundary sensor (#277).
# The highest-volume delegation triggers (commit message, PR body, reply) are
# turn-medial, where SKILL.md text cannot reach them; a hook fires at the
# missed site. On every Bash call it classifies the leading tokens of each
# shell segment (never the raw string, so text ABOUT a boundary cannot fire),
# looks for a matching delegate.sh row in the window, logs one
# source:"opportunity" row, and when none is found nudges with the exact
# recipe, denying the proven boundaries until a delegation exists (#483). A
# credited post leaves a marker that delegate-boundary-confirm-hook.sh
# (PostToolUse) clears once the call has run, so a refused or failed post can
# be retried on the same credit (#497).
# Fails OPEN: any error, missing jq, no reachable provider, two consecutive
# denials, unwritable metrics or an untakeable lock all fall back to warn,
# with the reason recorded as enforce_skipped. Install is opt-in — see
# docs/boundary-hook.md.
#
# Env:
#   DELEGATE_BOUNDARY_MODE        unset (enforce the set below, warn elsewhere)
#                                 | warn | enforce | off (case-insensitive;
#                                 any other value is warn)
#   DELEGATE_BOUNDARY_ENFORCE     comma-separated boundaries denied by default
#                                 (default git-commit,issue-create,comment-reply,
#                                 pr-review-comment; empty means none)
#   DELEGATE_BOUNDARY_MIN_CHARS   body length under which a boundary is recorded
#                                 but neither nudged nor denied (default 20 for
#                                 git-commit, 120 for the rest)
#   DELEGATE_BOUNDARY_WINDOW_MIN  look-back window for a prior delegation (default 480)
#   DELEGATE_BOUNDARY_WRAPPER_DIRS colon-separated directories whose scripts are
#                                 read when run via bash/sh/zsh (default
#                                 $CLAUDE_JOB_DIR, $TMPDIR, /tmp, /private/tmp,
#                                 /var/folders)
#   DELEGATE_LOCAL_DATA_DIR       where per-user data lives
#                                 (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE         metrics path (shared with delegate.sh)
#   DELEGATE_LOCAL_NO_METRICS=1   skip writing the opportunity row

set -uo pipefail

# Resolved BEFORE the cd to the payload cwd below: a relative $0 resolved
# afterwards names the wrong tree and the recipe lookup silently finds nothing.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""

# --- read the harness payload ---------------------------------------------
# A TTY on stdin means the hook was run by hand; exit before `cat` blocks.
[[ -t 0 ]] && exit 0
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
[[ -z "$cmd" ]] && exit 0
hook_cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || hook_cwd=""
# Relative paths in the command (`--body-file reply.md`) are relative to where
# the Bash tool will run, so chdir there before reading any body.
[[ -n "$hook_cwd" && -d "$hook_cwd" ]] && cd "$hook_cwd" 2>/dev/null || true
# A path opening with `$NAME` or `${NAME}` is resolved by LOOKUP in
# the hook's own environment (the Bash tool's, where drafts live under
# `$CLAUDE_JOB_DIR/tmp`), never by expansion; an unset name, a non-absolute
# value, or any further `$`/backtick leaves the path as it came (#489).
_env_prefix_braced='^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(/.*)?$'
_env_prefix_bare='^\$([A-Za-z_][A-Za-z0-9_]*)(/.*)?$'
resolve_env_prefix() { # path -> path with a leading env var resolved, else unchanged
  local p="$1" name rest val
  if [[ "$p" =~ $_env_prefix_braced ]] || [[ "$p" =~ $_env_prefix_bare ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]-}"
    val="${!name-}"
    if [[ -n "$val" && "$val" == /* && "$val" != *'$'* && "$val" != *'`'* \
          && "$rest" != *'$'* && "$rest" != *'`'* ]]; then
      printf '%s' "$val$rest"; return 0
    fi
  fi
  printf '%s' "$p"
}
# A leading `cd <path> &&` retargets relative paths and the project. Parsed off
# the RAW command (the scan surface blanks quoted spans) with a ^-anchored match
# so a heredoc body cannot reach it; the path is never expanded or eval'd. `cd -`
# and a path carrying $, backtick or ~ would need an expansion the hook must not
# perform, so both are rejected outright rather than sanitised.
cd_path=""
_cd_sq="^[[:space:]]*cd[[:space:]]+'([^']+)'[[:space:]]*&&"
_cd_dq="^[[:space:]]*cd[[:space:]]+\"([^\"]+)\"[[:space:]]*&&"
_cd_bare="^[[:space:]]*cd[[:space:]]+([^[:space:]&'\"]+)[[:space:]]*&&"
if [[ "$cmd" =~ $_cd_sq ]] || [[ "$cmd" =~ $_cd_dq ]] || [[ "$cmd" =~ $_cd_bare ]]; then
  cd_path="${BASH_REMATCH[1]}"
  case "$cd_path" in
    -*|*'$'*|*'`'*|*'~'*) cd_path="" ;;
  esac
  [[ -n "$cd_path" && -d "$cd_path" ]] || cd_path=""
fi
# The transcript UUID delegate.sh writes on its row as `session` (#479); it
# scopes the projectless lookup below. The tool_use_id is what the PostToolUse
# confirm hook matches a credited call by (#497).
session_id=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null) || session_id=""
tool_use_id=$(jq -r '.tool_use_id // empty' <<<"$input" 2>/dev/null) || tool_use_id=""

# --- cheap pre-filter (the common path exits here) ------------------------
# One linear-time grep over the raw string; it over-matches on purpose and the
# segment-aware classifier below decides.
# A boundary command inside a wrapper script is invisible to the token
# classifier, and a wrapper is what the worktree-isolation guard forces on a
# substitution-bearing call (#469): a script run via bash/sh/zsh from a scratch
# directory is read (never run) and its text classified; `wrapper` on the row
# names it.
wrapper=""
_wrapper_re='^[[:space:]]*(cd[[:space:]]+[^&]+&&[[:space:]]*)?((/usr/bin/env[[:space:]]+)?(bash|sh|zsh)|/bin/(bash|sh|zsh))[[:space:]]+((-[a-bd-zA-Z]+[[:space:]]+)*)("([^"]+)"|'"'"'([^'"'"']+)'"'"'|([^[:space:];&|"'"'"']+))'
if [[ "$cmd" =~ $_wrapper_re ]]; then
  _wr_whole="${BASH_REMATCH[0]}"
  _wr_path="${BASH_REMATCH[9]:-${BASH_REMATCH[10]:-${BASH_REMATCH[11]-}}}"
  _wr_resolved=$(resolve_env_prefix "$_wr_path")
  [[ -n "$_wr_resolved" && "$_wr_resolved" != /* && -n "$cd_path" ]] && _wr_resolved="$cd_path/$_wr_resolved"
  [[ -n "$_wr_resolved" && "$_wr_resolved" != /* ]] && _wr_resolved="$PWD/$_wr_resolved"
  _wr_dirs="${DELEGATE_BOUNDARY_WRAPPER_DIRS:-${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR:}${TMPDIR:+$TMPDIR:}/tmp:/private/tmp:/var/folders}"
  _wr_ok=false
  IFS=':' read -r -a _wr_list <<<"$_wr_dirs"
  for _wr_d in ${_wr_list[@]+"${_wr_list[@]}"}; do
    [[ -n "$_wr_d" ]] || continue
    _wr_d="${_wr_d%/}"
    if [[ "$_wr_resolved" == "$_wr_d"/* ]]; then _wr_ok=true; break; fi
  done
  if [[ "$_wr_ok" == "true" && -f "$_wr_resolved" && -r "$_wr_resolved" ]]; then
    _wr_text=$(head -c 32768 < "$_wr_resolved" 2>/dev/null; printf X); _wr_text=${_wr_text%X}
    if [[ -n "$_wr_text" ]]; then
      wrapper="$_wr_path"
      cmd="$_wr_text"$'\n'"${cmd#"$_wr_whole"}"
    fi
  fi
fi
grep -Eq 'git[[:space:]]+commit|gh[[:space:]]+(pr|issue|release|api)([[:space:]]|$)|glab[[:space:]]+(mr|issue)([[:space:]]|$)' <<<"$cmd" || exit 0

# --- build the classification surface -------------------------------------
# Only the leading tokens of a shell segment can BE a command: matching the raw
# string let a heredoc mentioning `gh pr create` classify (#342). One awk pass
# skips heredoc bodies, blanks quoted spans and breaks segments on `; & | ( ) { }`
# and newlines. The greps below do NOT anchor at segment start, so a wrapper or
# prefix (`sudo`, `VAR=x`) still classifies. The raw segments follow a 0x1e,
# split on 0x02 (0x01 is CTLESC, which bash eats in process substitution) with
# a terminal marker because bash 3.2 `read -a` drops a trailing empty field.
scan_all=$(awk 'BEGIN{RS="\1"} {
  n = length($0); q = ""; out = ""; nseg = 0; segstart = 1;
  # O(n) per character on every Bash call that clears the pre-filter; no real
  # command line is decided by anything past 32KB.
  if (n > 32768) n = 32768;
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1);
    # A backslash escapes the next character except inside single quotes,
    # where the shell takes it literally; otherwise \" flips quote parity.
    if (q != "\047" && c == "\\") { i++; continue }
    if (q != "") { if (c == q) { q = ""; } continue }
    if (c == "\047" || c == "\"") { q = c; out = out " "; continue }
    if (c == "<" && substr($0, i + 1, 1) == "<") {
      # Skip only the heredoc body and resume after the terminator: a
      # write-then-post (`cat > b.md <<EOF ... EOF` then `gh issue create
      # --body-file b.md`) is a genuine opportunity.
      j = i + 2;
      if (substr($0, j, 1) == "-") j++;
      if (substr($0, j, 1) == "<") { i = j; continue }   # <<< here-string: no body
      while (j <= n && substr($0, j, 1) == " ") j++;
      delim = ""; dq = substr($0, j, 1);
      if (dq == "\"" || dq == "\047") {
        j++;
        while (j <= n && substr($0, j, 1) != dq) { delim = delim substr($0, j, 1); j++ }
        j++;
      } else {
        while (j <= n && substr($0, j, 1) ~ /[A-Za-z0-9_]/) { delim = delim substr($0, j, 1); j++ }
      }
      if (delim == "") break;
      term = "\n" delim;
      p = index(substr($0, j), term);
      if (p == 0) break;                                # unterminated: rest is data
      i = j + p + length(term) - 2;
      continue;
    }
    if (c == ";" || c == "\n" || c == "&" || c == "|" \
        || c == "(" || c == ")" || c == "{" || c == "}") {
      out = out "\n";
      rawseg[++nseg] = substr($0, segstart, i - segstart); segstart = i + 1;
      continue
    }
    out = out c;
  }
  rawseg[++nseg] = substr($0, segstart, n - segstart + 1);
  printf "%s\036", out;
  for (s = 1; s <= nseg; s++) printf "%s\002", rawseg[s];
  printf ".";
}' <<<"$cmd" 2>/dev/null) || exit 0
scan="${scan_all%%$'\x1e'*}"
[[ -z "$scan" ]] && exit 0
rawsegs=()
IFS=$'\x02' read -r -d '' -a rawsegs < <(printf '%s' "${scan_all#*$'\x1e'}") || true

# --- is this a delegatable boundary? --------------------------------------
# Segments are classified independently and the first match wins, so a flag
# never binds to a command in another segment.
boundary="" recipe=""
# Any command word added to classify_segment must also appear in the pre-filter
# grep above, or the branch is dead code that never fires.
# The text a boundary is about to publish, read ONCE from the raw text of the
# MATCHED segment (never $scan, which blanks quoted runs, never the whole
# command) and shared by the length split, the floor and the ADR 0029 capture.
# Nothing here is executed. A body file wins over an inline body; repeated
# inline bodies are joined with a blank line as git does with `-m`. Unresolved
# shell (`$`, backtick, `$( … )`) makes a body unmeasurable, except the
# `-m "$(cat <<'EOF' … EOF\n)"` shape, whose heredoc body is the message.
_posted_body_scan() {
  local raw="$1"
  # One left-to-right pass: each flag at a word boundary, then its argument (a
  # quoted one taken whole, a bare one stopping at whitespace or shell
  # punctuation). Output is FILE\t<path>, NONE, or INLINE\t<literal 0|1>\n<text>.
  # (No apostrophes in the comments below: the program sits inside a
  # single-quoted bash string.)
  awk 'BEGIN { RS="\1" } {
    n = length($0); if (n > 32768) n = 32768;
    body = ""; nbody = 0; lit = 1; file = ""; i = 1; prev = " ";
    while (i <= n) {
      c = substr($0, i, 1);
      # A quoted span that is not a flag argument is data: prose that merely
      # mentions a flag must not count.
      if (c == "\"" || c == "\047") {
        j = i + 1;
        while (j <= n && substr($0, j, 1) != c) {
          if (c == "\"" && substr($0, j, 1) == "\\") j++;
          j++;
        }
        prev = "x"; i = j + 1; continue;
      }
      if (prev ~ /[[:space:]]/) {
        # -f/-F and their long forms are gh api FIELD flags whose argument is
        # key=value, and only the body key is a body (#461). -F keeps its file
        # meaning without an =, being also the short --body-file. -m/-am are
        # git commit and glab note; no gh command takes them.
        f = 0; isfile = 0; isfield = 0;
        if (substr($0, i, 12) == "--body-file ")      { f = 12; isfile = 1 }
        else if (substr($0, i, 12) == "--raw-field ") { f = 12; isfield = 1 }
        else if (substr($0, i, 8) == "--field ")      { f = 8;  isfield = 1 }
        else if (substr($0, i, 3) == "-F ")           { f = 3;  isfile = 1; isfield = 1 }
        else if (substr($0, i, 3) == "-f ")           { f = 3;  isfield = 1 }
        else if (substr($0, i, 7) == "--body ")         f = 7;
        else if (substr($0, i, 10) == "--message ")     f = 10;
        else if (substr($0, i, 3) == "-b ")             f = 3;
        else if (substr($0, i, 3) == "-m ")             f = 3;
        else if (substr($0, i, 4) == "-am ")            f = 4;
        if (f > 0) {
          j = i + f;
          while (j <= n && substr($0, j, 1) == " ") j++;
          # The key is read before the value so a quote opening the value is
          # still seen: -f body="two words" is one body.
          key = "";
          if (isfield) {
            k = j;
            while (k <= n && substr($0, k, 1) ~ /[A-Za-z0-9_-]/) { key = key substr($0, k, 1); k++ }
            if (key != "" && substr($0, k, 1) == "=") j = k + 1; else key = "";
          }
          # `body=@path` names a file, and the `@` sits before any quote:
          # `body=@"$DIR/reply.md"` read bare kept the quotes in the path and
          # never named a readable file (#489).
          atfile = 0;
          if (isfield && key == "body" && substr($0, j, 1) == "@") { atfile = 1; j++ }
          d = substr($0, j, 1); v = ""; vlit = 1;
          if (d == "\"" || d == "\047") {
            j++;
            while (j <= n && substr($0, j, 1) != d) {
              # Inside double quotes a $( … ) is opaque to the shell. The one
              # shape resolved is -m "$(cat <<EOF … EOF\n)" as the WHOLE value;
              # any other substitution is consumed to its closing paren to keep
              # quote parity and makes the body unmeasurable. Checked before the
              # backslash rule so an escaped \$( stays literal.
              if (d == "\"" && substr($0, j, 2) == "$(") {
                shape = 0;
                if (v == "") {
                  k = j + 2; while (k <= n && substr($0, k, 1) == " ") k++;
                  if (substr($0, k, 6) == "cat <<") {
                    k += 6; if (substr($0, k, 1) == "-") k++;
                    while (k <= n && substr($0, k, 1) == " ") k++;
                    hq = substr($0, k, 1); hd = "";
                    if (hq == "\"" || hq == "\047") {
                      k++;
                      while (k <= n && substr($0, k, 1) != hq) { hd = hd substr($0, k, 1); k++ }
                      k++;
                    } else {
                      hq = "";
                      while (k <= n && substr($0, k, 1) ~ /[A-Za-z0-9_]/) { hd = hd substr($0, k, 1); k++ }
                    }
                    while (k <= n && substr($0, k, 1) == " ") k++;
                    if (hd != "" && substr($0, k, 1) == "\n") {
                      k++;
                      ht = "\n" hd; hp = index(substr($0, k), ht);
                      if (hp > 0) {
                        hbody = substr($0, k, hp - 1);
                        m = k + hp + length(ht) - 1;
                        while (m <= n && (substr($0, m, 1) == " " || substr($0, m, 1) == "\n")) m++;
                        if (substr($0, m, 1) == ")" && substr($0, m + 1, 1) == d) {
                          shape = 1; v = hbody; j = m + 1;
                          if (hq == "" && hbody ~ /[$`]/) vlit = 0;
                        }
                      }
                    }
                  }
                }
                if (!shape) {
                  vlit = 0; depth = 1; v = v "$("; j += 2;
                  while (j <= n && depth > 0) {
                    ch = substr($0, j, 1);
                    if (ch == "(") depth++; else if (ch == ")") depth--;
                    v = v ch; j++;
                  }
                }
                continue;
              }
              # A backslash escapes only inside double quotes.
              if (d == "\"" && substr($0, j, 1) == "\\") { j++; v = v substr($0, j, 1); j++; continue }
              ch = substr($0, j, 1);
              if (d == "\"" && (ch == "$" || ch == "`")) vlit = 0;
              v = v ch; j++;
            }
            j++;
          } else {
            while (j <= n && substr($0, j, 1) !~ /[[:space:];,&|)]/) {
              ch = substr($0, j, 1);
              if (ch == "$" || ch == "`") vlit = 0;
              v = v ch; j++;
            }
          }
          # A field flag with any key but body is neither a file nor a body:
          # -f event=COMMENT and -F in_reply_to=99 are not posted text (#461).
          asfile = 0; asbody = 0;
          # The `@` may also sit inside the quotes (`body="@file"`), or the
          # whole pair may (`'body=@file'`); the shell hands gh the same bytes.
          if (isfield && key == "" && substr(v, 1, 5) == "body=") { key = "body"; v = substr(v, 6) }
          if (isfield && key == "body" && !atfile && substr(v, 1, 1) == "@") { atfile = 1; v = substr(v, 2) }
          if (isfield && key != "") {
            if (key == "body") { if (atfile) asfile = 1; else asbody = 1 }
          }
          else if (isfile) asfile = 1;
          else if (!isfield) asbody = 1;
          if (asfile) { if (file == "") file = v }
          else if (asbody) {
            if (nbody++ > 0) body = body "\n\n";
            body = body v;
            if (!vlit) lit = 0;
          }
          prev = " "; i = j; continue;
        }
      }
      prev = c; i++;
    }
    # NONE means no body flag at all; INLINE with empty text is a known
    # 0-character post, which the caller must not confuse with no body.
    if (file != "") { printf "FILE\t%s\n", file }
    else if (nbody == 0) { printf "NONE\n" }
    else { printf "INLINE\t%d\n", lit; printf "%s", body }
  }' <<<"$raw"
}

# Sets body_text (capped at 64 KB: this runs on every Bash call), body_chars
# ("" when unmeasurable) and body_measurable. Only a regular file is read:
# `head -c` on /dev/zero would hang the hook. Measurable means the scan
# SUCCEEDED, not that the text is non-empty: `--body ""` records body_chars:0
# (under any floor), where no body flag, an unreadable file or unresolved
# shell records nothing and is enforced.
body_text="" body_chars="" body_measurable=false body_read=false
read_posted_body() { # raw-segment
  local out first kind flag path
  body_text="" body_chars="" body_measurable=false body_read=true
  # The trailing X survives command-substitution newline stripping.
  out=$(_posted_body_scan "$1"; printf X); out=${out%X}
  first=${out%%$'\n'*}
  IFS=$'\t' read -r kind flag <<<"$first"
  if [[ "$kind" == "FILE" ]]; then
    path=$(resolve_env_prefix "$flag")
    # A leading `cd <path> &&` moves relative paths again.
    [[ -n "$path" && "$path" != /* && -n "$cd_path" ]] && path="$cd_path/$path"
    [[ -n "$path" && -f "$path" && -r "$path" ]] || return 0
    body_text=$(head -c 65536 < "$path" 2>/dev/null; printf X); body_text=${body_text%X}
    body_measurable=true
  elif [[ "$kind" == "INLINE" ]]; then
    [[ "$flag" == "1" ]] || return 0
    body_text=${out#*$'\n'}
    body_text=${body_text:0:65536}
    body_measurable=true
  fi
  [[ "$body_measurable" == "true" ]] && body_chars=${#body_text}
  return 0
}

# Calibrated on this repo's issue comments; re-measure before moving it, and do
# not reuse the number for pr-review-comment, a different distribution.
long_body_chars="${DELEGATE_BOUNDARY_LONG_BODY_CHARS:-600}"

classify_segment() { # blanked-segment raw-segment
  local seg="$1" rawseg="$2"
  # Inline message (-m/-F) only; --amend reuses a message, no drafting moment.
  if grep -Eq '(^|[^[:alnum:]_-])git[[:space:]]+commit([[:space:]]|$)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[mF]|--message|--file)' <<<"$seg" \
     && ! grep -Eq -- '--amend' <<<"$seg"; then
    boundary="git-commit"; recipe="commit-message"; return 0
  fi
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+mr[[:space:]]+create([[:space:]]|$)' <<<"$seg"; then
    boundary="pr-create"; recipe="pr-description"; return 0
  fi
  # Inline body only; the editor and --web have no drafting moment.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[bF]|--body)' <<<"$seg" \
     && ! grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*w|--web)([[:space:]]|$)' <<<"$seg"; then
    boundary="issue-create"; recipe="github-issue-body"; return 0
  fi
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+release[[:space:]]+create([[:space:]]|$)' <<<"$seg"; then
    boundary="release-create"; recipe="release-note"; return 0
  fi
  # A PR REVIEW BODY is the evidence-led shape, which is maintainer-review-reply
  # rather than the two-sentence maintainer-reply below. Inline body required,
  # for the same reason as issue-create.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+review([[:space:]]|$)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[bF]|--body)' <<<"$seg" \
     && ! grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*w|--web)([[:space:]]|$)' <<<"$seg"; then
    boundary="pr-review-body"; recipe="maintainer-review-reply"; return 0
  fi
  # Same inline-body requirement: `-f event=APPROVE` with no body has no text
  # to intercept.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+api([[:space:]]|$)' <<<"$seg" \
     && grep -Eq '/pulls/[0-9]+/reviews' <<<"$seg" \
     && grep -Eq -- '(-X[[:space:]]*=?POST|--method([[:space:]]+|=)POST)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[fF]|--field|--raw-field)([[:space:]]+|=)body=' <<<"$seg"; then
    boundary="pr-review-body"; recipe="maintainer-review-reply"; return 0
  fi
  # Scoped to the pulls endpoint so an issues-comment POST is not misread, and
  # to an explicit POST so the read-only fetch step is not a boundary.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+api([[:space:]]|$)' <<<"$seg" \
     && grep -Eq '/pulls/[0-9]+/comments' <<<"$seg" \
     && grep -Eq -- '(-X[[:space:]]*=?POST|--method([[:space:]]+|=)POST)' <<<"$seg"; then
    boundary="pr-review-comment"; recipe="pr-review-reply"; return 0
  fi
  # Which recipe this names depends on how much is posted: maintainer-reply
  # caps its body at two sentences, maintainer-review-reply sizes by evidence.
  # Pinning maintainer-reply unconditionally taught the wrong routing.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+comment([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+issue[[:space:]]+comment([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+(mr|issue)[[:space:]]+(discussion[[:space:]]+)?note([[:space:]]|$)' <<<"$seg"; then
    boundary="comment-reply"
    # An unmeasurable body keeps the short shape: a failed measurement must
    # not promote a reply on no evidence.
    read_posted_body "$rawseg"
    if [[ "$body_measurable" == "true" ]] && (( body_chars >= long_body_chars )); then
      recipe="maintainer-review-reply"
    else
      recipe="maintainer-reply"
    fi
    return 0
  fi
  return 1
}

matched_seg="" matched_raw="" seg_idx=0
while IFS= read -r seg; do
  seg_idx=$((seg_idx + 1))
  [[ -z "$seg" ]] && continue
  # Builtin pre-filter: classify_segment costs up to 9 greps per segment, and
  # every branch needs a literal git/gh/glab.
  case "$seg" in *git*|*gh*|*glab*) ;; *) continue ;; esac
  # Blanked line k of $scan is raw segment k (0-based in the array).
  if classify_segment "$seg" "${rawsegs[$((seg_idx - 1))]-}"; then
    matched_seg="$seg"; matched_raw="${rawsegs[$((seg_idx - 1))]-}"; break
  fi
done <<<"$scan"
[[ -z "$boundary" ]] && exit 0
# Every other boundary reads its body here, once, from its own segment.
[[ "$body_read" == "true" ]] || read_posted_body "$matched_raw"
# PostToolUse reports the whole call, and its status is the boundary's own
# only when the boundary is the last segment: `cd x && git commit` and a
# wrapper script ending in the commit both are, `git commit … && gh pr
# create` and `git commit … || true` are not, and a marker for those would
# be left unconfirmed by a later failure the commit had nothing to do with,
# or confirmed by a success it did not have (#497). The last non-blank line
# of the scan is compared by the index the loop stopped at.
boundary_last=false
[[ "$seg_idx" == "$(awk 'NF { n = NR } END { print n + 0 }' <<<"$scan")" ]] && boundary_last=true

# --- derive the project name (shared with delegate.sh via lib/otel.sh) -----
# The SAME function delegate.sh and delegate-feedback.sh call, so the row this
# hook writes and the rows its lookup reads agree by construction; an inline
# mirror drifted twice (#476). Sourced only after the boundary is known so the
# common path pays nothing. A missing lib leaves cwd_project empty: fail open.
cwd_project=""
if [[ -n "$script_dir" && -f "$script_dir/lib/otel.sh" ]]; then
  # shellcheck source=lib/otel.sh
  . "$script_dir/lib/otel.sh"
  cwd_project=$(delegate_project_name 2>/dev/null) || cwd_project=""
fi

# --- which repository is this boundary actually about? (#385) -------------
# Agents routinely run `cd <other-repo> && git commit …`; delegate.sh runs
# AFTER that cd and records the other repo, so a lookup keyed on the session
# cwd could never match. $cd_path was parsed off the RAW command near the top.
cd_project=""
if [[ -n "$cd_path" ]]; then
  # Derived inside a subshell that has chdir'd to the target: `git -C <path>
  # rev-parse --git-common-dir` at a repo root returns the RELATIVE `.git`,
  # which resolves against the hook's own cwd. Accepted only inside a git
  # repository, so a `cd /tmp` does not file the boundary under `tmp`.
  cd_project=$(cd -- "$cd_path" 2>/dev/null || exit
    c=$(git rev-parse --git-common-dir 2>/dev/null) || exit
    d=$(cd "$c" 2>/dev/null && pwd) || exit
    basename "$(dirname "$d")")
fi
# DELEGATE_PROJECT outranks the cd target: delegate.sh run after that same
# `cd` inherits it and records it.
project="${DELEGATE_PROJECT:-${cd_project:-$cwd_project}}"

# --- a boundary that names its repo explicitly (#393 follow-up) ------------
# `--repo owner/name` widens the delegation LOOKUP only and never sets the
# recorded project (recording it bought no recall and fragmented the rollup).
# Parsed off $matched_seg, not the raw command, so a `--repo` inside a quoted
# body cannot reach here; a quoted `--repo "owner/name"` is blanked too and
# fails safe. The charset test validates the WHOLE value: it is what rejects
# `--repo $R` and `` --repo `whoami`/name ``.
repo_project=""
_repo_flag_re="(^|[[:space:]])(--repo[[:space:]]+|--repo=|-R[[:space:]]+)([^[:space:]]+)"
_repo_val_re="^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$"
if [[ "$matched_seg" =~ $_repo_flag_re ]]; then
  repo_val="${BASH_REMATCH[3]}"
  repo_val="${repo_val%/}"
  repo_val="${repo_val%.git}"
  if [[ "$repo_val" =~ $_repo_val_re ]]; then
    repo_project="${repo_val##*/}"
  fi
fi

# --- #465: a body file is NOT evidence the drafting moment passed ---------
# The hook cannot tell a pre-existing body file from one the agent wrote a
# call earlier, so every boundary is counted the same way.

# --- was there a local delegation for THIS boundary's recipe, recently? ----
# Recipe-aware: only a delegation whose recipe matches counts, else a
# commit-message delegation credits a later `gh pr create`. A bare (no-recipe)
# delegation credits nothing. Runs for file-backed bodies too:
# delegate-then-save-then-post is the workflow the nudge asks for.
metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
# 480 rather than 10: a batch sweep delegates its drafts, waits for approval
# and posts hours later. Safe because credits are CONSUMED below, one per
# delegated:true row.
window_min="${DELEGATE_BOUNDARY_WINDOW_MIN:-480}"
now_epoch=$(date -u +%s)
# The confirm hook's markers live beside the metrics file, like the lock
# (#497). One is honoured for 300 s: the "just now" delegate-feedback.sh uses
# for an unpinned verdict, against retries 5-13 s after the refusal in the
# corpus, and the confirmation is what spends a credit for good.
pending_dir="$(dirname "$metrics_file")/.boundary-pending"
reuse_window=300
reused=false pending="" pending_epoch="" pending_project="" pending_draft="" pending_captured=false

# --- is this enough text to be drafting? (#483) ----------------------------
# `body_chars` is a count, never the text, recorded only when the body is
# measurable at PreToolUse time; an absent count nudges or denies as the mode
# says. Most inline review replies are one line and no recipe should draft
# those. The floor is per boundary: a one-line conventional commit is 40-60
# characters, so a global 120 exempted every such commit. The rows carry the
# number, not the floor, so it can be re-tuned from the corpus.
case "$boundary" in
  git-commit) min_chars=20 ;;
  *)          min_chars=120 ;;
esac
if [[ "${DELEGATE_BOUNDARY_MIN_CHARS:-}" =~ ^[0-9]+$ ]]; then
  min_chars="$DELEGATE_BOUNDARY_MIN_CHARS"
fi
below_floor=false
if [[ "$body_measurable" == "true" ]] && (( body_chars < min_chars )); then
  below_floor=true
fi

# --- which mode applies to THIS boundary? (#483) ---------------------------
# Unset enforces the set in DELEGATE_BOUNDARY_ENFORCE and warns elsewhere;
# pr-create and pr-review-body stay on warn until pr-description is reliable,
# since denying a post to hand the agent a recipe that fails would teach it to
# route around the hook. `${VAR-default}` rather than `:-`, so an explicitly
# empty set means "enforce nothing". The deny is issued only while a provider
# serves the recipe's tier, probed only on the deny path.
enforce_set="${DELEGATE_BOUNDARY_ENFORCE-git-commit,issue-create,comment-reply,pr-review-comment}"
enforce_set="${enforce_set// /}"
# Case-insensitive, and an unknown value is warn, never enforce. nocasematch
# is bash 3.2 (`${var,,}` is bash 4).
shopt -s nocasematch
case "${DELEGATE_BOUNDARY_MODE:-}" in
  "") case ",${enforce_set}," in
        *",${boundary},"*) mode=enforce ;;
        *)                 mode=warn ;;
      esac ;;
  off)     mode=off ;;
  enforce) mode=enforce ;;
  *)       mode=warn ;;
esac
shopt -u nocasematch
prompts_dir="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"

# --- serialise lookup + append across concurrent hooks ---------------------
# Two enforced boundaries after one delegation could both see `recent=1` and
# spend one credit twice. mkdir is the portable atomic primitive (flock is not
# on macOS). A lock older than 5 s is a killed hook and is broken; one that
# cannot be taken in 2 s fails OPEN as enforce_skipped:"lock-timeout". The lock
# is OWNED by a pid+random token so a hook whose lock was broken does not
# remove its replacement on EXIT. Taken only when metrics are on.
lock_dir="$(dirname "$metrics_file")/.boundary-hook.lock"
lock_held=false lock_failed=false
lock_token="$$-${RANDOM}${RANDOM}"
release_lock() {
  [[ "$lock_held" == "true" ]] || return 0
  lock_held=false
  [[ "$(cat "$lock_dir/owner" 2>/dev/null)" == "$lock_token" ]] || return 0
  rm -rf "$lock_dir" 2>/dev/null; return 0
}
if [[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]]; then
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  lock_tries=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    # A hook killed between mkdir and writing `ts` leaves no `ts`, so the
    # directory mtime stands in. GNU `stat -c %Y` FIRST: BSD stat rejects `-c`,
    # but GNU stat accepts `-f %m` and prints the mount point, so BSD-first
    # never reached its fallback on Linux.
    lock_ts=$(cat "$lock_dir/ts" 2>/dev/null)
    if [[ ! "$lock_ts" =~ ^[0-9]+$ ]]; then
      lock_ts=$(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null)
    fi
    if [[ "$lock_ts" =~ ^[0-9]+$ && $(( now_epoch - lock_ts )) -gt 5 ]]; then
      rm -rf "$lock_dir" 2>/dev/null; continue
    fi
    lock_tries=$((lock_tries + 1))
    if (( lock_tries >= 40 )); then lock_failed=true; break; fi
    sleep 0.05
  done
  if [[ "$lock_failed" != "true" ]]; then
    lock_held=true
    printf '%s' "$now_epoch" > "$lock_dir/ts" 2>/dev/null || true
    printf '%s' "$lock_token" > "$lock_dir/owner" 2>/dev/null || true
    trap release_lock EXIT
  fi
fi

delegated=false
credit_draft=""
denied_streak=0 streak_attempted=no
if [[ -f "$metrics_file" ]]; then
  # Only the recent tail can fall inside the window. 2000 lines, not 500:
  # truncation drops the OLDEST rows, the earning delegate rows, so a too-small
  # tail denies credit. `recent` is delegate rows MINUS already-credited posts.
  # comment-reply names its recipe from the body length, so either of its two
  # recipes credits it on both the earning and the spending side, else a deny
  # answered by a shorter draft is denied again under the other name. Built by
  # hand: $recipe is a fixed identifier classify_segment assigns, never user text.
  case "$boundary" in
    comment-reply) credit_recipes='["maintainer-reply","maintainer-review-reply"]' ;;
    *)             credit_recipes="[\"${recipe}\"]" ;;
  esac
  recent_out=$(tail -n 2000 "$metrics_file" 2>/dev/null | jq -rs --argjson win "$((window_min * 60))" --arg proj "$project" --arg proj2 "$cwd_project" --arg proj3 "$repo_project" --arg sid "$session_id" --argjson recipes "$credit_recipes" --arg boundary "$boundary" --argjson now "$now_epoch" '
    # Any of the three named candidates counts, each guarded against empty.
    # A PROJECTLESS row (delegate.sh outside a git repository, #476) is
    # credited only when its session equals this one: the metrics file is
    # shared by every session on the machine, and one pool across them would
    # let an unrelated scratch-cwd session credit this post. A projectless row
    # with no session credits nothing. The same predicate scopes the spending
    # rows. (No apostrophes here: this sits inside the single-quoted jq program.)
    def named($c): $c != "" and (.project // "") == $c;
    def same_session: $sid != "" and (.session // "") == $sid;
    def matches_proj: named($proj) or named($proj2) or named($proj3)
                      or ((.project // "") == "" and $proj2 == "" and same_session);
    def in_window: ((.ts | fromdateiso8601?) // 0) > ($now - $win);
    # A failed delegation (exit_status 3, the pre-flight stall) produced no
    # draft this post could be the shipped form of, so it earns no credit.
    # Credited posts are replayed against the delegations each could have
    # spent AT ITS OWN TIME (inside its own window, oldest first), not netted
    # inside the current window: a delegation ages out of the window before
    # the post that spent it does, so "in-window delegations minus in-window
    # spends" read three fresh delegations as already spent and denied a
    # session that had done exactly what the deny asked (#503). ts is second
    # precision, so file order breaks ties: a delegation appended after a
    # spend in the same second was not there to be spent.
    ([ to_entries[] | {i: .key, r: .value}
       | select(.r | (.source // "delegate") == "delegate")
       | select(.r | (.exit_status // 0) == 0)
       | select(.r | matches_proj)
       | select(.r | (.recipe // "") as $x | $recipes | index($x) != null)
       | .r + {epoch: ((.r.ts | fromdateiso8601?) // 0), idx: .i} ] | sort_by(.epoch, .idx)) as $earned
    | ([ to_entries[] | {i: .key, r: .value}
       | select(.r | (.source // "") == "opportunity")
       | select(.r | .delegated == true)
       | select(.r | matches_proj)
       | select(.r | (.suggested_recipe // "") as $x | $recipes | index($x) != null)
       | {st: ((.r.ts | fromdateiso8601?) // 0), idx: .i} ] | sort_by(.st, .idx)) as $spends
    | (reduce $spends[] as $s ($earned;
         (to_entries | map(select(
            (.value.epoch < $s.st or (.value.epoch == $s.st and .value.idx < $s.idx))
            and .value.epoch > $s.st - $win)) | .[0].key) as $i
         | if $i == null then . else del(.[$i]) end)) as $unspent
    | ([ $unspent[] | select(.epoch > ($now - $win)) ]) as $d
    # The denial streak: denied:true rows for this session+boundary, newest
    # first, before the first that is not. Two in a row open the cap only when
    # the session recorded a delegation for the recipe of this boundary AFTER the
    # streak began, whatever its exit status: that is a delegation that failed
    # to credit, which must not block for good. A plain retry of the same
    # command records nothing and stays denied, because two retries were all
    # it took to walk an undrafted post through the cap (#511). ts is second
    # precision, so the file index breaks ties, as the spend replay does.
    | ([ to_entries[] | {i: .key, r: .value}
       | select(.r | (.source // "") == "opportunity")
       | select(.r | (.boundary // "") == $boundary)
       | select(.r | (.session // "") == $sid)
       | select(.r | in_window)
       | {epoch: ((.r.ts | fromdateiso8601?) // 0), idx: .i, denied: .r.denied} ] | sort_by(.epoch, .idx) | reverse
       | reduce .[] as $r ({n: 0, stop: false, since: 0, since_idx: -1};
           if .stop then . elif $r.denied == true then .n += 1 | .since = $r.epoch | .since_idx = $r.idx else .stop = true end)) as $sk
    | ([ to_entries[] | {i: .key, r: .value}
       | select(.r | (.source // "delegate") == "delegate")
       | select(.r | (.session // "") == $sid)
       | select(.r | (.recipe // "") as $x | $recipes | index($x) != null)
       | ((.r.ts | fromdateiso8601?) // 0) as $e
       | select($e > $sk.since or ($e == $sk.since and .i > $sk.since_idx)) ] | length > 0) as $attempted
    # Credit count, the draft this post spends, the streak, and whether the
    # session delegated since it began. The draft is oldest-unspent-first,
    # because that is the order a sweep posts in.
    | "\($d | length)\u001f\($d[0].draft_file // "")\u001f\($sk.n)\u001f\(if $sk.n > 0 and $attempted then "yes" else "no" end)"' 2>/dev/null) || recent_out=""
  # Unit separator, not tab: tab is IFS whitespace, so an empty middle field
  # would collapse and shift the streak into credit_draft.
  IFS=$'\x1f' read -r recent credit_draft denied_streak streak_attempted <<<"$recent_out"
  [[ "${recent:-0}" =~ ^-?[0-9]+$ ]] || recent=0
  [[ "${denied_streak:-0}" =~ ^[0-9]+$ ]] || denied_streak=0
  [[ "${streak_attempted:-no}" == "yes" ]] || streak_attempted=no
  # --- an unconfirmed spend is not a spend (#497) ---------------------------
  # The credit is spent here, before the harness has decided whether the call
  # runs: the worktree guard refuses it after this hook, or git fails on an
  # empty index, and the retry found the credit gone. A credited post leaves a
  # marker that the PostToolUse confirm hook removes when the call ran and
  # succeeded (a failure fires PostToolUseFailure, a denial fires nothing). A
  # marker still there when this session reaches the same boundary again
  # inside the window is a post that did not happen, and this call is it:
  # credited on the same delegation, no second row, the final captured if the
  # first attempt could not. It outranks a fresh credit, else a sweep whose
  # refused post was retried after its next delegation would spend that one
  # and be denied on the post it was for. Honoured only once the confirm hook
  # has been seen in this session: a PreToolUse-only install never confirms,
  # and an unconfirmed marker would credit every post after the first. And
  # only for the project the refused post recorded, since the credit it
  # holds and the draft its final would be filed under are that project's:
  # the file is keyed by it too, so a credited post in another repository
  # does not overwrite it. The name is a basename or DELEGATE_PROJECT, so it
  # is reduced to a safe charset for the filename; a collision only makes the
  # stored project mismatch, which denies as before.
  pending_key="${project//[^A-Za-z0-9._-]/_}"
  [[ -n "$session_id" ]] && pending="$pending_dir/$session_id.$boundary.${pending_key:--}"
  if [[ -n "$pending" && "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" \
        && -f "$pending_dir/$session_id.seen" && -f "$pending" ]]; then
    IFS=$'\x1f' read -r pending_epoch pending_project pending_draft pending_captured < <(jq -r '[(.epoch // 0 | tostring), (.project // ""), (.draft // ""), (.captured // false | tostring)] | join("\u001f")' "$pending" 2>/dev/null) || pending_epoch=""
    if [[ "${pending_epoch:-}" =~ ^[0-9]+$ && "${pending_project:-}" == "$project" ]] \
       && (( now_epoch - pending_epoch <= reuse_window )); then
      reused=true; credit_draft="${pending_draft:-}"
    fi
  fi
  # `credit_draft` comes from the JSONL file (or the marker written from it)
  # and becomes part of a path this hook WRITES to, so it is untrusted: a bare
  # *.draft.txt filename only.
  case "$credit_draft" in
    *.draft.txt) [[ "$credit_draft" == */* || "$credit_draft" == .* ]] && credit_draft="" ;;
    *) credit_draft="" ;;
  esac
  [[ "$reused" == "true" || "${recent:-0}" -gt 0 ]] && delegated=true
fi

# --- record the opportunity (the trigger-rate sensor) ---------------------
# One row per boundary; no command or message text. `project` and `session`
# are omitted, not emptied, when unknown, the shape delegate.sh writes.
# `body_chars` is a length, `below_floor:true` keeps a row out of the rate,
# `denied:true` marks a blocked attempt (the retry writes the row that counts;
# counting both would cap the rate near 50%), `enforce_skipped` marks a deny
# that fell open and stays a real miss. Returns the append status so a deny
# can be withdrawn when no credit could be recorded.
append_row() {
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]] || return 0
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  jq -nc --arg ts "$ts" --arg project "$project" --arg boundary "$boundary" \
     --arg recipe "$recipe" --arg sid "$session_id" --argjson delegated "$delegated" \
     --arg body_chars "$body_chars" --argjson below_floor "$below_floor" \
     --argjson denied "$denied" --arg skipped "$enforce_skipped" --arg wrapper "$wrapper" '
     {ts:$ts, source:"opportunity", boundary:$boundary, suggested_recipe:$recipe, delegated:$delegated}
     + (if $project != "" then {project:$project} else {} end)
     + (if $sid != "" then {session:$sid} else {} end)
     + (if $body_chars != "" then {body_chars:($body_chars | tonumber)} else {} end)
     + (if $below_floor then {below_floor:true} else {} end)
     + (if $denied then {denied:true} else {} end)
     + (if $skipped != "" then {enforce_skipped:$skipped} else {} end)
     + (if $wrapper != "" then {wrapper:$wrapper} else {} end)' \
     >> "$metrics_file" 2>/dev/null
}

# The marker the confirm hook removes when this call succeeds (#497): the
# call's id, the project and draft stem the credit pairs with, and the FIRST
# attempt's epoch, so a chain of refusals cannot extend the window. Without
# an id there is nothing a confirmation could match, and when the boundary
# is not the call's last segment its outcome is not the call's, so none is
# written and the credit is spent for good as before.
write_pending() {
  [[ -n "$pending" && "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]] || return 0
  # A reused marker is consumed FIRST: this call is already allowed and its
  # confirmation carries the new id, so a re-arm that fails below must not
  # leave the old id for a further post to reuse. The same holds for a
  # credited call that can leave no marker at all.
  [[ "$reused" == "true" ]] && rm -f "$pending" 2>/dev/null
  [[ -n "$tool_use_id" && "$boundary_last" == "true" ]] || return 0
  local epoch="$now_epoch"
  [[ "$reused" == "true" ]] && epoch="$pending_epoch"
  mkdir -p "$pending_dir" 2>/dev/null || return 0
  chmod 700 "$pending_dir" 2>/dev/null || true
  jq -nc --arg id "$tool_use_id" --argjson epoch "$epoch" --arg project "$project" \
     --arg draft "$credit_draft" --argjson captured "$final_captured" \
    '{id:$id, epoch:$epoch, project:$project, draft:$draft, captured:$captured}' > "$pending" 2>/dev/null \
    || rm -f "$pending" 2>/dev/null
  # Opportunistic prune; -mtime/-delete work on BSD and GNU find. The .seen
  # files are on a week's retention, not a day's: a session older than a
  # day would otherwise lose its confirmation on its next refused post.
  find "$pending_dir" -type f ! -name '*.seen' -mtime +1 -delete 2>/dev/null || true
  find "$pending_dir" -type f -name '*.seen' -mtime +7 -delete 2>/dev/null || true
}

# --- the critical section ends here ---------------------------------------
# Only a credited post spends a credit, so only it appends under the lock. An
# uncredited post releases the lock FIRST and then decides on the deny: a slow
# provider probe held inside the lock could be stale-broken at 5 s and let a
# second hook spend the same credit. Its delegated:false row spends nothing.
denied=false enforce_skipped="" tier_decl=""
if [[ "$delegated" == "true" ]]; then
  # --- store the posted body as the shipped half of the pair (ADR 0029) -----
  # A reply posted inline has no file for `delegate-feedback.sh --final` to
  # name; a credited post IS its delegation's shipped form, stored under the
  # draft's own stem. Never overwritten: the `set -C` on the write is the
  # guarantee, the `-e` check only skips the work. The capture is PRE-post,
  # so a post that then fails leaves a final for text that never shipped.
  # One exception (#497): on a reused credit the marker proves the earlier
  # attempt never ran, so a final THIS HOOK wrote for it (`captured` on the
  # marker; a verdict's explicit --final is never marked) is replaced by what
  # the retry sends, when that is measurable. The last measurable attempt is
  # the text a confirmation then stands behind.
  final_captured=false
  [[ "$reused" == "true" && "$pending_captured" == "true" ]] && final_captured=true
  if [[ "$delegated" == "true" && -n "${credit_draft:-}" \
        && "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]]; then
    drafts_dir="$(dirname "$metrics_file")/drafts"
    final_path="$drafts_dir/${credit_draft%.draft.txt}.final.txt"
    if [[ -n "$body_text" ]] && [[ ! -e "$final_path" || "$final_captured" == "true" ]]; then
      if mkdir -p "$drafts_dir" 2>/dev/null; then
        chmod 700 "$drafts_dir" 2>/dev/null || true
        if [[ "$final_captured" == "true" ]]; then
          ( umask 077; printf '%s' "$body_text" > "$final_path" ) 2>/dev/null || true
        else
          ( umask 077; set -C; printf '%s' "$body_text" > "$final_path" ) 2>/dev/null && final_captured=true
        fi
        [[ -f "$final_path" ]] && chmod 600 "$final_path" 2>/dev/null
      fi
    fi
  fi
  # A reused credit was recorded by the attempt that did not run: this call
  # inherits that row and re-arms the marker so its own outcome is confirmed.
  if [[ "$reused" != "true" ]]; then append_row || true; fi
  write_pending
  release_lock
else
  release_lock
  # Every reason here fails OPEN to warn, so a hook bug never blocks a commit:
  #   metrics-unwritable  no credit could ever be written where this hook reads
  #   retry-cap           two consecutive denials for this session+boundary AND a
  #                       delegation recorded since the first (a plain retry stays denied)
  #   lock-timeout        the lookup lock could not be taken in 2 s
  #   no-provider         pick-model.sh: nothing reachable
  #   no-model            a provider is up but serves no model for the tier
  #   bad-tier            the recipe declares a tier pick-model.sh does not know
  # pick-model.sh exits 1 for both no-provider and no-model (told apart on
  # stderr) and 2 for a bad tier; it is run only when a deny is otherwise
  # about to happen.
  enforce_skipped="" tier_decl=""
  retry_cap=2
  if [[ "$mode" == "enforce" && "$delegated" != "true" && "$below_floor" != "true" ]]; then
    if [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]]; then
      enforce_skipped="metrics-unwritable"
    elif [[ "$lock_failed" == "true" ]]; then
      enforce_skipped="lock-timeout"
    elif (( denied_streak >= retry_cap )) && [[ "$streak_attempted" == "yes" ]]; then
      enforce_skipped="retry-cap"
    else
      # The same expression delegate.sh uses, so `tier: prose ` resolves in both.
      if [[ -n "$script_dir" && -f "$script_dir/lib/recipe.sh" && -f "$prompts_dir/$recipe.md" ]]; then
        # shellcheck source=lib/recipe.sh
        . "$script_dir/lib/recipe.sh"
        tier_decl=$(recipe_tier "$prompts_dir/$recipe.md")
      fi
      if [[ -z "$tier_decl" ]]; then
        # delegate.sh exits 2 on this too; the command as printed would fail.
        tier_decl=$(awk 'NR > 1 && /^tier:/ { sub(/^tier:[[:space:]]*/, ""); print; exit }' "$prompts_dir/$recipe.md" 2>/dev/null)
        enforce_skipped="bad-tier"
      elif [[ -z "$script_dir" || ! -f "$script_dir/pick-model.sh" ]]; then
        enforce_skipped="no-provider"
      else
        probe_err=$(bash "$script_dir/pick-model.sh" "$tier_decl" 2>&1 >/dev/null); probe_rc=$?
        if (( probe_rc == 2 )); then
          enforce_skipped="bad-tier"
        elif (( probe_rc != 0 )); then
          case "$probe_err" in
            *"holds a model"*) enforce_skipped="no-model" ;;
            *)                 enforce_skipped="no-provider" ;;
          esac
        fi
      fi
    fi
    [[ -n "$enforce_skipped" ]] && mode=warn
  fi
  denied=false
  [[ "$mode" == "enforce" && "$delegated" != "true" && "$below_floor" != "true" ]] && denied=true
  # The append is the writability test: when it fails the deny is withdrawn,
  # since no credit could ever be recorded here either.
  if ! append_row && [[ "$denied" == "true" ]]; then
    denied=false; mode=warn; enforce_skipped="metrics-unwritable"
  fi
fi

# --- nudge unless the artifact was already delegated ----------------------
# A file-backed body nudges like an inline one (#465); a body under the floor
# is not drafting.
[[ "$delegated" == "true" ]] && exit 0
[[ "$below_floor" == "true" ]] && exit 0
[[ "$mode" == "off" ]] && exit 0

# A --recipe call that omits a required input exits 2, so the keys are read
# from the recipe's own frontmatter rather than hardcoded. `stdin` is not a
# --var, and a trailing `?` marks an optional input the nudge leaves out.
var_hint="" stdin_hint=""
if [[ -f "$prompts_dir/$recipe.md" ]]; then
  while IFS= read -r key; do
    if [[ "$key" == "stdin" ]]; then stdin_hint=" < context.txt"
    else var_hint="${var_hint} --var ${key}=\"...\""; fi
  done < <(awk '
    /^---[[:space:]]*$/ { d++; if (d == 2) exit; next }
    d == 1 && /^inputs:[[:space:]]*$/ { in_inputs = 1; next }
    d == 1 && /^[^[:space:]]/ { in_inputs = 0 }
    in_inputs && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:/ {
      line = $1; sub(/:$/, "", line);
      if ($2 !~ /\?$/) print line;
    }
  ' "$prompts_dir/$recipe.md" 2>/dev/null)
fi

# The nudge names --project explicitly: an agent that cd's into the skill
# checkout to run the command would record project=delegate-local and never
# match this lookup (#342). Outside a git repository (#476) the command must
# still run as printed, so neither `--project ""` nor a placeholder appears:
# a `--repo owner/name` value is rendered because it is a lookup candidate,
# otherwise the flag is left out, and the projectless delegation that
# produces is exactly what the empty session-cwd candidate matches.
if [[ -n "$project" ]]; then
  where="for project '${project}'"
  project_flag=" --project \"${project}\""
elif [[ -n "$repo_project" ]]; then
  where="from a cwd outside any git repository"
  project_flag=" --project \"${repo_project}\""
else
  where="from a cwd outside any git repository"
  project_flag=""
fi
reminder="delegate-local: about to author a ${boundary} message inline with no local delegation recorded in the last ${window_min}m ${where}. Draft it on-device first — bash ~/.claude/skills/delegate-local/scripts/delegate.sh${project_flag} --recipe ${recipe}${var_hint}${stdin_hint} — then record the verdict with ~/.claude/skills/delegate-local/scripts/delegate-feedback.sh --source agent."

# The hook reads its environment from the harness, not from the command it
# judges, so a `DELEGATE_BOUNDARY_MODE=off git commit …` prefix changes nothing.
if [[ "$denied" == "true" ]]; then
  jq -nc --arg r "${reminder} This call was blocked; rerun it once the delegation is recorded, and it is credited. DELEGATE_BOUNDARY_MODE=warn in the hook's environment downgrades this to a reminder." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  # Each reason names a different remedy.
  case "$enforce_skipped" in
    no-provider)        tail="No local provider answered, so this call proceeds undrafted; start MLX or Ollama to draft the next one." ;;
    no-model)           tail="A local provider is up but serves no model for the ${tier_decl:-prose} tier, so this call proceeds undrafted; pull one or edit the prefs in pick-model.sh." ;;
    bad-tier)           tail="The recipe declares tier '${tier_decl}', which pick-model.sh does not know, so this call proceeds undrafted; fix the recipe's frontmatter." ;;
    retry-cap)          tail="This session was denied twice for this boundary and has delegated since without the credit landing, so this call proceeds undrafted rather than blocking for good; check the delegation's stderr and its --project." ;;
    metrics-unwritable) tail="The metrics file cannot be written from the hook's environment, so no delegation could ever be credited here and this call proceeds undrafted; check DELEGATE_METRICS_FILE / DELEGATE_LOCAL_DATA_DIR match between settings.json and the shell, or unset DELEGATE_LOCAL_NO_METRICS." ;;
    lock-timeout)       tail="Another boundary hook held the metrics lock for over two seconds, so this call proceeds undrafted." ;;
    *)                  tail="Set DELEGATE_BOUNDARY_MODE=off to silence." ;;
  esac
  jq -nc --arg c "${reminder} ${tail}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$c}}'
fi
exit 0
