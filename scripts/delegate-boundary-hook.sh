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
#      (no jq slurp, no metrics read). Classification runs over the *leading
#      tokens of each shell segment*, never the raw string, so a command that
#      merely writes ABOUT a boundary command (a heredoc body, a quoted message)
#      does not fire (#342 defect 2).
#   2. Otherwise derive the project (same rule as delegate.sh's metrics rows) and
#      check metrics.jsonl for a delegate.sh row for THIS project within the last
#      N minutes. Its presence means the artifact was drafted locally; its
#      absence means it is about to be authored inline.
#   3. Log one source:"opportunity" row per boundary with delegated:true|false so
#      metrics-summary.sh can report trigger rate = delegated / opportunities per
#      project — the number #277 is about, previously unmeasured.
#   4. When delegated:false, surface a reminder naming the exact recipe. The
#      four boundaries whose recipe is proven — git-commit, issue-create,
#      comment-reply, pr-review-comment — are DENIED until a delegation exists
#      (#483); the rest get the same text as non-blocking additionalContext.
#      DELEGATE_BOUNDARY_MODE=warn|off overrides that globally, =enforce
#      denies every boundary, and DELEGATE_BOUNDARY_ENFORCE names the set.
#
# Why deny rather than remind (#483). Measured 2026-09-13 over 14 days: 680
# boundaries, 108 delegated, 15%. The warn-mode nudge is delivered while the
# `git commit` / `gh pr comment` it is about executes, so the text is already
# authored and posted by the time the agent reads it; the only boundary it can
# influence is the next one, and after a nudge the next boundary within 30
# minutes on the same project was delegated 9% of the time, against 34% after
# a credit. There is no human in the loop to notice a reminder, so only a
# mechanism that makes the agent redo the text with a draft moves the rate.
#
# Every boundary counts the same way. A body read from an existing file used to
# be excluded as state:"pre-drafted" (#349), on the theory that the drafting
# moment had passed; that exclusion was removed in #465 because the hook cannot
# distinguish it from a body the agent authored one call earlier, and because
# the identical act was counted when the write and the post shared a Bash call.
# One exception since #483: a body under the boundary's floor (20 characters
# for git-commit, 120 for the rest) is neither nudged nor denied, and its row
# is marked below_floor:true so the summary can leave it out of the rate.
# Inline review comments sat at 3% because most are one line — an applied-in
# hash, a dependabot command, one word — and no recipe should draft those. A
# body the hook cannot read (unresolved shell in the value, a heredoc on
# stdin, a file not yet written) is not under any floor: it is enforced.
#
# Fails OPEN: any error, missing jq, or unparseable input exits 0 so a commit is
# never blocked by a hook bug, and a deny is issued only after pick-model.sh
# confirms a provider is serving the recipe's tier — a session with MLX and
# Ollama down cannot delegate and must still be able to commit — and only
# while the credit path can work at all: two consecutive denials for one
# session and boundary, metrics the hook cannot write, or a lookup lock it
# cannot take all fall open to warn, with the reason on the row as
# enforce_skipped (PR #484 review). Install is opt-in — see
# docs/boundary-hook.md.
#
# Env:
#   DELEGATE_BOUNDARY_MODE        unset (default: enforce the set below, warn
#                                 elsewhere) | warn | enforce | off
#                                 (case-insensitive; any other value is warn)
#   DELEGATE_BOUNDARY_ENFORCE     comma-separated boundaries denied by default
#                                 (default git-commit,issue-create,comment-reply,
#                                 pr-review-comment; empty means none)
#   DELEGATE_BOUNDARY_MIN_CHARS   body length under which a boundary is recorded
#                                 but neither nudged nor denied; overrides the
#                                 per-boundary defaults (20 git-commit, 120 rest)
#   DELEGATE_BOUNDARY_WINDOW_MIN  look-back window for a prior delegation (default 480)
#   DELEGATE_LOCAL_DATA_DIR     where per-user data lives
#                               (default ~/.local/share/delegate-local)
#   DELEGATE_METRICS_FILE         metrics path (shared with delegate.sh)
#   DELEGATE_LOCAL_NO_METRICS=1   skip writing the opportunity row

set -uo pipefail

# Resolve our own directory BEFORE the cd to the payload's cwd below. Doing it
# later resolved a relative $0 against the wrong tree — invoked as
# `bash scripts/delegate-boundary-hook.sh` from a project checkout it produced
# <that-project>/scripts/../prompts, so the recipe lookup silently found nothing.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""

# --- read the harness payload ---------------------------------------------
# Exit cleanly if stdin is a TTY (the hook run by hand in a terminal) so `cat`
# can't block waiting for input that will never arrive.
[[ -t 0 ]] && exit 0
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
[[ -z "$cmd" ]] && exit 0
hook_cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || hook_cwd=""
# Work from the payload's cwd from here on. Relative paths in the command — a
# `--body-file reply.md` — mean relative to where the Bash tool will run,
# not to wherever the hook process happened to start; reading the body
# before this chdir looked `reply.md` up in the wrong directory, found
# nothing, and enforced a post the hook could have measured (fifth review
# round on #484). A builtin, so the common path pays nothing.
[[ -n "$hook_cwd" && -d "$hook_cwd" ]] && cd "$hook_cwd" 2>/dev/null || true
# A leading `cd <path> &&` retargets those relative paths (and, below, the
# project) to that directory. Parsed off the RAW command: the scan surface
# blanks quoted spans, so a quoted path with a space survives there only as
# `cd   `. The match is ^-anchored, so a heredoc body mentioning `cd /x &&
# git commit` cannot reach it, and the captured path is only ever a quoted
# argument to `cd` inside a subshell — never expanded, never eval'd. `cd -`
# resolves to $OLDPWD, which is not knowable from the payload, and a path
# carrying $, backtick or ~ would need an expansion the hook must not
# perform; both are rejected outright rather than sanitised. Kept only when
# it names a directory.
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
# The session id (the transcript UUID) is the same value delegate.sh sees as
# CLAUDE_CODE_SESSION_ID and writes on its row as `session` (#479). It scopes
# the projectless lookup below and is recorded on the opportunity row.
session_id=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null) || session_id=""

# --- cheap pre-filter (the common path exits here) ------------------------
# One linear-time grep over the raw string. Everything below is gated on it, so
# the overwhelming majority of Bash calls cost a single grep and nothing else.
# It over-matches on purpose (a heredoc body mentioning `gh pr create` passes);
# the segment-aware classifier below is what decides.
grep -Eq 'git[[:space:]]+commit|gh[[:space:]]+(pr|issue|release|api)([[:space:]]|$)|glab[[:space:]]+(mr|issue)([[:space:]]|$)' <<<"$cmd" || exit 0

# --- build the classification surface -------------------------------------
# Only the leading tokens of a shell segment can BE a command. Matching the raw
# string made merely writing ABOUT a boundary command enough to fire: a
# `cat > notes.md <<'EOF' ... gh pr create ... EOF` write classified as
# pr-create, because the heredoc body was part of the string the classifier saw
# (#342 defect 2). Quoting the delimiter cannot help — the match happens before
# the shell ever runs.
#
# One awk pass turns the command into one segment per line:
#   * everything from the first `<<` (heredoc / here-string) is dropped — that
#     is data being written, not a command being run. Real boundary uses of a
#     heredoc (`gh pr create --body-file - <<'EOF'`) keep their flags, which all
#     precede the redirect, so they still classify.
#   * quoted spans are blanked, so prose inside -m/--body cannot classify.
#   * `; & | ( ) { }` and newlines become line breaks, so `cd x && git commit`
#     and `url=$(gh pr create ...)` both expose their command at a line start.
# Each grep below therefore sees one segment. The patterns deliberately do NOT
# anchor at segment start: once data is stripped, a leading wrapper or prefix
# (`sudo gh pr create`, `timeout 30 gh pr create`, `GIT_AUTHOR_NAME=x git
# commit`, `for f in ...; do git commit`) is still a real boundary, and
# anchoring dropped all of them without buying any false-positive protection.
#
# The same pass also records where each segment starts and ends in the RAW
# command, and emits the raw segments after the blanked surface: a 0x1e
# (record separator) between the two parts, 0x02 between raw segments, and a
# terminal marker because bash 3.2 `read -a` drops a trailing empty field.
# Not 0x01 for the split: that is CTLESC, the byte bash uses internally to
# mark quoting, and `${var#*$'\1'}` silently matched nothing inside the
# process substitution below. The body measurement and the ADR 0029
# capture read the raw text of the MATCHED segment only: reading the whole
# command let `git commit -m "fix: x" && gh pr create --body "<300 chars>"`
# measure the PR body against the commit boundary and deny a 6-character
# commit, and the reverse stored a later `--body-file` as the commit's final
# (PR #484 review, item C).
scan_all=$(awk 'BEGIN{RS="\1"} {
  n = length($0); q = ""; out = ""; nseg = 0; segstart = 1;
  # The loop is O(n) per character, and this runs on every Bash call that
  # clears the pre-filter. A 200KB command (a big heredoc that happens to
  # mention a boundary command) measured ~800ms, so cap the surface: no real
  # command line is decided by anything past 32KB.
  if (n > 32768) n = 32768;
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1);
    # A backslash escapes the next character everywhere except inside single
    # quotes, where the shell treats it literally. Without this an odd number
    # of \" inside a quoted string flips quote parity, and the tail of the
    # prose gets scanned as live shell — the #342 false positive again.
    if (q != "\047" && c == "\\") { i++; continue }
    if (q != "") { if (c == q) { q = ""; } continue }
    if (c == "\047" || c == "\"") { q = c; out = out " "; continue }
    if (c == "<" && substr($0, i + 1, 1) == "<") {
      # Heredoc body is data, not commands — but skip only the body and resume
      # after the terminator. Dropping the rest of the command instead loses
      # the write-then-post pattern (`cat > b.md <<EOF ... EOF` followed by
      # `gh issue create --body-file b.md`), which is a genuine opportunity.
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
# Each segment is classified independently and the first match wins, so a flag
# never binds to a command in a different segment.
boundary="" recipe=""
# Any command word added below must also appear in the pre-filter grep above —
# everything here is gated on it, so a new branch whose command word is missing
# there is dead code that silently never fires, with tests still green because
# they only exercise branches that exist.
# What text a boundary command is about to publish, read ONCE per boundary
# and shared by everything downstream: the 600-character comment-reply split,
# the length floor, and the ADR 0029 capture. It used to run twice with
# different units — bytes from `wc -c` for the split, characters capped at
# 64 KB for the floor — so the two could disagree about one body (PR #484
# review, item J). Now one scan, one text, one length.
#
# Read from the raw text of the MATCHED segment, never from $scan (which
# blanks every quoted run, so the segment handed to classify_segment carries
# no body at all) and never from the whole command (item C above). Nothing
# here is executed; the only things taken from the raw text are a length and
# the text itself.
#
# What counts as a body. A `--body-file` (and `-F <path>`, `body=@path`)
# wins over an inline body because it names where the text really is, and
# the file is read when it is a readable regular file. Inline bodies of ONE
# command are summed, joined with a blank line, because that is what git
# does with repeated `-m` and a two-paragraph commit that clears the floor
# combined was being marked below_floor on its longest paragraph alone
# (item D). A body is MEASURABLE only when the hook can know its text: a
# double-quoted or bare value holding an unresolved `$`, backtick or `$( … )`
# is shell the tool has not run yet — `--body "$(cat draft.md)"` measured 15
# characters and was silently allowed as below the floor, `-m "$MSG"`
# measured 4, and a credited `--body "$(cat reply.txt)"` was marked
# below_floor and dropped from the numerator (item A). The one shape that is
# resolved here is the one every Claude Code commit uses, `-m "$(cat <<'EOF'
# … EOF\n)"` as the whole value: its heredoc body is the message, and it is
# literal when the delimiter is quoted (or when the body carries no `$` or
# backtick). Single quotes are always literal. An unmeasurable body reports
# no text and no length, and the caller treats that exactly like no body:
# no body_chars, no below_floor, enforced as the mode says.
_posted_body_scan() {
  local raw="$1"
  # ONE left-to-right pass, no backtracking: find each flag that starts at a
  # word boundary and read the argument after it. A quoted argument is taken
  # whole, spaces included, so `--body-file "notes with spaces.md"` resolves to
  # a path rather than to its first word; a bare one stops at whitespace or at
  # shell punctuation, so `--body-file notes.md;` does not become `notes.md;`.
  # Output is `FILE\t<path>` or `INLINE\t<literal 0|1>\n<joined text>`.
  # (No apostrophes in the comments below: the program sits inside a
  # single-quoted bash string.)
  awk 'BEGIN { RS="\1" } {
    n = length($0); if (n > 32768) n = 32768;
    body = ""; nbody = 0; lit = 1; file = ""; i = 1; prev = " ";
    while (i <= n) {
      c = substr($0, i, 1);
      # A quoted span that is not a flag argument is DATA, and is skipped
      # whole. Without this, prose that merely mentions a flag counts —
      # `echo "x --body-file draft.md"; gh pr comment --body "short"` measured
      # the mention and promoted a two-sentence reply to the long recipe,
      # which is the direction that costs something.
      if (c == "\"" || c == "\047") {
        j = i + 1;
        while (j <= n && substr($0, j, 1) != c) {
          if (c == "\"" && substr($0, j, 1) == "\\") j++;
          j++;
        }
        prev = "x"; i = j + 1; continue;
      }
      if (prev ~ /[[:space:]]/) {
        # `-f`/`-F` and their long forms are gh api FIELD flags: the argument
        # is `key=value`, and only the `body` key is a body. Reading `-F` as a
        # bare path is how `-F in_reply_to=99` became a filename, which made
        # the whole `gh api ... -f body=... -F in_reply_to=...` reply — the
        # shape /address-pr-comments prescribes — measure 0 characters and
        # carry no text (#461). `-F` keeps its file meaning when the argument
        # has no `=`, because it is also the short form of `--body-file` in
        # `gh pr comment` / `gh issue create`. `-m` is `git commit` and
        # `glab … note` alike (no gh command takes it), and `-am` is the one
        # combined form seen in real commits; neither was read until #483, so
        # a commit measured nothing and stored no final.
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
          # The key is read before the value so the value reader below still
          # sees a quote where one opens: `-f body="two words"` is one body,
          # not the bare token `body="two`.
          key = "";
          if (isfield) {
            k = j;
            while (k <= n && substr($0, k, 1) ~ /[A-Za-z0-9_-]/) { key = key substr($0, k, 1); k++ }
            if (key != "" && substr($0, k, 1) == "=") j = k + 1; else key = "";
          }
          d = substr($0, j, 1); v = ""; vlit = 1;
          if (d == "\"" || d == "\047") {
            j++;
            while (j <= n && substr($0, j, 1) != d) {
              # Inside double quotes a $( … ) is opaque to the shell: quotes
              # nest and the closing quote cannot be in there. The one shape
              # resolved is `-m "$(cat <<EOF … EOF\n)"` as the WHOLE value:
              # the heredoc body is copied out as the message (it may hold
              # any quote or paren), and it is literal when the delimiter was
              # quoted or nothing in it expands. Any other substitution, or
              # that shape with text around it, is consumed to its closing
              # paren so the quote parity stays right, and makes the body
              # unmeasurable. Checked before the backslash rule below so an
              # escaped \$( stays literal.
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
              # A backslash escapes the next character inside double quotes
              # only; inside single quotes the shell takes it literally.
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
          # What this argument IS, decided once: a body file, an inline body,
          # or neither. A field flag carrying any key but `body` is neither —
          # `-f event=COMMENT` and `-F in_reply_to=99` are not text anyone
          # posted, and reading them as one is the whole of #461.
          asfile = 0; asbody = 0;
          if (isfield && key != "") {
            if (key == "body") {
              if (substr(v, 1, 1) == "@") { asfile = 1; v = substr(v, 2) } else asbody = 1;
            }
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
    # NONE when no body flag was present at all; an INLINE with empty text
    # is a body flag whose value was empty — a known 0-character post, which
    # the caller must not confuse with no body (fourth review round on #484).
    if (file != "") { printf "FILE\t%s\n", file }
    else if (nbody == 0) { printf "NONE\n" }
    else { printf "INLINE\t%d\n", lit; printf "%s", body }
  }' <<<"$raw"
}

# Reads the body once into three globals: `body_text` (what would be posted,
# capped at 64 KB — this runs inside a PreToolUse hook on every Bash call, and
# a body larger than that is not a reply anyone hand-edited from a draft),
# `body_chars` (its length, or "" when there is no measurable body) and
# `body_measurable` (true|false). Only a regular file is read: `head -c` on
# /dev/zero would hang the hook, and a directory or a FIFO is not a body file.
# A path with an unresolved `$` never names a readable file, so it falls out
# as unmeasurable by the same test.
#
# Measurable means the scan SUCCEEDED, not that the text is non-empty:
# `--body ""` and a readable empty `--body-file` are known 0-character posts
# and record body_chars:0 (under any floor), where a command with no body
# flag, an unreadable file or unresolved shell records nothing and is
# enforced. Conflating the two enforced a post the hook had fully read.
body_text="" body_chars="" body_measurable=false body_read=false
read_posted_body() { # raw-segment
  local out first kind flag path
  body_text="" body_chars="" body_measurable=false body_read=true
  # The trailing X survives command substitution newline stripping, so a body
  # that legitimately ends in a blank line is not silently reshaped.
  out=$(_posted_body_scan "$1"; printf X); out=${out%X}
  first=${out%%$'\n'*}
  IFS=$'\t' read -r kind flag <<<"$first"
  if [[ "$kind" == "FILE" ]]; then
    path="$flag"
    # The hook already sits in the payload cwd; a leading `cd <path> &&`
    # moves relative paths again (fifth review round on #484).
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

# 600 was picked on 2026-08-27 from the two recipes' own documented output, and
# said so. Measured the same day against the population it actually routes: 27
# issue comments authored by the maintainer on this repo run min 8, p25 573,
# median 950, p75 1417, max 2522 characters. The split sends 19 to
# `maintainer-review-reply` and keeps 8 for `maintainer-reply`, and the tail it
# keeps (two comments under 200 characters) is the status-line shape that recipe
# is capped for. Re-measure before moving it, and do not reuse the number
# elsewhere: the `pr-review-comment` population is a different distribution
# entirely (median 312 over n=23), where 600 would route nothing.
long_body_chars="${DELEGATE_BOUNDARY_LONG_BODY_CHARS:-600}"

classify_segment() { # blanked-segment raw-segment
  local seg="$1" rawseg="$2"
  # git commit that authors a message inline (-m/-F), but not --amend (which
  # reuses an existing message — no fresh drafting moment).
  if grep -Eq '(^|[^[:alnum:]_-])git[[:space:]]+commit([[:space:]]|$)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[mF]|--message|--file)' <<<"$seg" \
     && ! grep -Eq -- '--amend' <<<"$seg"; then
    boundary="git-commit"; recipe="commit-message"; return 0
  fi
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+mr[[:space:]]+create([[:space:]]|$)' <<<"$seg"; then
    boundary="pr-create"; recipe="pr-description"; return 0
  fi
  # New issue authored with an inline body (--body / -b / --body-file / -F), but
  # not the interactive editor or the --web form — those have no inline drafting
  # moment, same reasoning as commit --amend.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[bF]|--body)' <<<"$seg" \
     && ! grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*w|--web)([[:space:]]|$)' <<<"$seg"; then
    boundary="issue-create"; recipe="github-issue-body"; return 0
  fi
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+release[[:space:]]+create([[:space:]]|$)' <<<"$seg"; then
    boundary="release-create"; recipe="release-note"; return 0
  fi
  # A maintainer's PR REVIEW BODY, either `gh pr review <n> --body ...` or the
  # equivalent reviews-endpoint POST. This is the evidence-led shape — a verdict
  # plus the anchors it rests on — which is `maintainer-review-reply`, not the
  # closed two-sentence `maintainer-reply` below.
  #
  # Until 2026-08-26 this was not a boundary at all. `gh pr review` clears the
  # pre-filter (it is `gh pr ...`) and then matched no branch, so the single most
  # common way a maintainer posts a judgement produced no row and no nudge. Over
  # the same period `maintainer-reply` absorbed the workload at 21% usable over
  # n=33 while `maintainer-review-reply` sat at n=0 calls, with prose pointers in
  # SKILL.md and in both scope paragraphs of `maintainer-reply.md`. Prose routing
  # had been tried twice; this is the mechanical version.
  #
  # An inline body is required for the same reason issue-create requires one:
  # `--web` and the interactive editor have no drafting moment to intercept.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+review([[:space:]]|$)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*[bF]|--body)' <<<"$seg" \
     && ! grep -Eq -- '(^|[[:space:]])(-[[:alnum:]]*w|--web)([[:space:]]|$)' <<<"$seg"; then
    boundary="pr-review-body"; recipe="maintainer-review-reply"; return 0
  fi
  # The API form carries the same inline-body requirement as the CLI form above.
  # A reviews POST is not necessarily a drafting moment: `-f event=APPROVE` with
  # no body is an approval with no text to intercept, and firing on it would
  # nudge for a message that is never written.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+api([[:space:]]|$)' <<<"$seg" \
     && grep -Eq '/pulls/[0-9]+/reviews' <<<"$seg" \
     && grep -Eq -- '(-X[[:space:]]*=?POST|--method([[:space:]]+|=)POST)' <<<"$seg" \
     && grep -Eq -- '(^|[[:space:]])(-[fF]|--field|--raw-field)([[:space:]]+|=)body=' <<<"$seg"; then
    boundary="pr-review-body"; recipe="maintainer-review-reply"; return 0
  fi
  # Inline PR review-comment reply: `gh api .../pulls/<n>/comments -X POST -f body=...`
  # (the /address-pr-comments inline path). Scope to the pulls endpoint so an
  # issue-comment POST (`.../issues/<n>/comments`) is not misread as a PR review
  # reply, and require an explicit POST so the read-only fetch step
  # (`gh api .../comments --jq ...`, no -X POST) is NOT a boundary.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+api([[:space:]]|$)' <<<"$seg" \
     && grep -Eq '/pulls/[0-9]+/comments' <<<"$seg" \
     && grep -Eq -- '(-X[[:space:]]*=?POST|--method([[:space:]]+|=)POST)' <<<"$seg"; then
    boundary="pr-review-comment"; recipe="pr-review-reply"; return 0
  fi
  # General PR / issue / MR comment reply authored inline. Which recipe this
  # names depends on how much is being posted, because the two candidates are
  # different SHAPES rather than different qualities: `maintainer-reply` caps
  # its prose body at two sentences, and `maintainer-review-reply` sets its
  # length by how much evidence the reply has to carry.
  #
  # Pinning `maintainer-reply` unconditionally is how that recipe came to hold
  # 33 of the corpus's delegations at 21% usable, with rejection reasons that
  # are one shape repeated — "collapsed all 14 facts into a single run-on
  # sentence", "returned two sentences instead of a four-paragraph body",
  # "dropped every measured fact from the context". The closed shape was doing
  # exactly its job to a workload it explicitly excludes, and the nudge naming
  # it was teaching that routing rather than correcting it.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+comment([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+issue[[:space:]]+comment([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+(mr|issue)[[:space:]]+(discussion[[:space:]]+)?note([[:space:]]|$)' <<<"$seg"; then
    boundary="comment-reply"
    # The one scan this boundary gets; the floor and the capture below reuse
    # its result. An unmeasurable or unreadable body keeps the short shape —
    # a measurement that failed must not promote a reply on no evidence.
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
  # Builtin pre-filter, no subprocess: classify_segment costs up to 9 greps and
  # runs per SEGMENT, so a routine `gh pr list ... | while read n; do ...; done`
  # (5 segments, classifies as nothing) paid 46 grep spawns / ~204ms. Every
  # branch above needs a literal git/gh/glab, so skipping segments without one
  # is free — measured 204ms -> 93ms on that shape.
  case "$seg" in *git*|*gh*|*glab*) ;; *) continue ;; esac
  # Blanked line k of $scan is raw segment k (0-based in the array).
  if classify_segment "$seg" "${rawsegs[$((seg_idx - 1))]-}"; then
    matched_seg="$seg"; matched_raw="${rawsegs[$((seg_idx - 1))]-}"; break
  fi
done <<<"$scan"
[[ -z "$boundary" ]] && exit 0
# Every other boundary reads its body here, once, from its own segment.
[[ "$body_read" == "true" ]] || read_posted_body "$matched_raw"

# --- derive the project name (shared with delegate.sh via lib/otel.sh) -----
# The SAME function delegate.sh and delegate-feedback.sh call, not a copy of
# it: the row this hook writes and the rows its lookup reads then agree by
# construction. The inline mirror that lived here drifted twice — it ignored
# DELEGATE_PROJECT, which both of those scripts honour, and it fell back to
# the cwd's basename outside a git repository (#476), filing 14 boundaries
# from `~/projects/gitlab` (the parent folder holding the checkouts) under
# `project:"gitlab"`. delegate_project_name records no project from that same
# cwd, so a lookup keyed on "gitlab" could never match a delegation there, and
# the row sat at rate=0% for a name that names nothing while every post nudged
# a session that may well have delegated. The #385 refusal below had guarded
# only the `cd <path> &&` branch against this. Sourcing the lib is documented
# side-effect free; it is done here, after the boundary is known, so the
# common path pays nothing for it. $script_dir was resolved before the cd to
# the payload cwd (done right after the payload was read), and through the
# ~/.claude/skills symlink it names the symlinked tree, which is where lib/
# is. A missing lib leaves cwd_project empty: fail open.
cwd_project=""
if [[ -n "$script_dir" && -f "$script_dir/lib/otel.sh" ]]; then
  # shellcheck source=lib/otel.sh
  . "$script_dir/lib/otel.sh"
  cwd_project=$(delegate_project_name 2>/dev/null) || cwd_project=""
fi

# --- which repository is this boundary actually about? (#385) -------------
# The harness reports the SESSION cwd, but agents routinely run
# `cd <other-repo> && git commit …`. delegate.sh runs AFTER that cd, so it
# records the other repo, and a lookup keyed on the session cwd could never
# match across it: a boundary whose drafting genuinely was delegated got
# recorded as a miss and nudged anyway. Measured 2026-08-18, 66 opportunities
# filed under `pr-agent` against 3 delegations there, while 35 delegations sat
# under `delegate-local` with none.
#
# Parsed off the RAW $cmd rather than the $scan surface. That is a deliberate
# departure from the doctrine above, because scan blanks quoted spans and a
# quoted path with a space survives there as `cd   `. The parse itself (and
# its refusals) now sits with the payload read near the top, because the
# body scanner needs the target too; $cd_path is empty unless it named a
# directory.
cd_project=""
if [[ -n "$cd_path" ]]; then
  # Derived inside a SUBSHELL that has chdir'd to the target. Do not reach for
  # `git -C "$cd_path" rev-parse --git-common-dir`: at a repo root that returns
  # the RELATIVE string `.git`, which then resolves against the hook's own cwd
  # and silently reproduces the very bug this block exists to fix.
  # Accepted only when the target is inside a git repository — a `cd /tmp`
  # must not file the boundary under `tmp` and fragment the denominator.
  cd_project=$(cd -- "$cd_path" 2>/dev/null || exit
    c=$(git rev-parse --git-common-dir 2>/dev/null) || exit
    d=$(cd "$c" 2>/dev/null && pwd) || exit
    basename "$(dirname "$d")")
fi
# An explicit DELEGATE_PROJECT outranks the cd target as well: delegate.sh run
# after that same `cd` inherits the variable and records it, so the row has to
# be filed where the lookup will find it.
project="${DELEGATE_PROJECT:-${cd_project:-$cwd_project}}"

# --- a boundary that names its repo explicitly (#393 follow-up) ------------
# `gh issue comment --repo owner/name` carries no `cd`, so it is filed under the
# session cwd. This candidate widens the delegation LOOKUP only and never sets
# the recorded project: replaying the whole metrics file showed recording it buys
# no extra recall, because the either-match set is identical, while adding four
# `rate=0%` project keys and moving 22 rows off two real projects. The driver is
# hub-repo sweeps (`gh pr comment N --repo IsmaelMartinez/<other> --body
# "@dependabot rebase"`), 13 of the 34 affected rows.
#
# Parsed off $matched_seg, NOT the raw $cmd, which is the opposite trade-off
# from the `cd` block above: the scan surface blanks quoted spans, so a `--repo`
# inside a quoted body cannot reach here (good), but a legitimately quoted
# `--repo "owner/name"` is blanked too and falls back silently (6 of 534 real
# invocations, and it fails safe).
#
# The charset test is security work, not tidiness. It is the only thing
# rejecting `--repo IsmaelMartinez/$1`, `--repo $R` and `` --repo `whoami`/name ``
# — shell-variable values are 11 of 534 real invocations — and it validates the
# WHOLE value, because a last-segment-only check accepts all three.
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
# Until 2026-08-28 a `--body-file` / `-F` post whose file already existed was
# recorded `state:"pre-drafted"` and excluded from the trigger-rate ratio (#349,
# #355), on the theory that the text had been authored at an earlier Write and
# often approved by a human. The hook cannot tell those apart from a body the
# agent wrote inline one Bash call earlier, which is the case the sensor exists
# to catch — and it never could, so the exclusion was quiet rather than
# accurate (#358). It was also inconsistent: writing the body and posting it in
# ONE call left the file non-existent at PreToolUse time, so the identical act
# was counted as a miss and nudged, making the rate depend on how the agent
# batched its shell calls (#465). Every boundary is now counted the same way,
# and a body file nudges like an inline one.

# --- was there a local delegation for THIS boundary's recipe, recently? ----
# Recipe-aware: only a delegation whose recipe matches this boundary's recipe
# counts as capturing it. Matching on project alone over-counted — a commit-message
# delegation marked a later `gh pr create` / review-comment reply as captured even
# though the PR body / reply was authored inline, which both inflated the trigger
# rate AND suppressed the nudge (delegated:true skips it below), so the artifact the
# boundary is about was never delegated. A bare (no-recipe) delegation no longer
# counts for any boundary — the calibrated recipe the nudge names is the path.
# Runs for file-backed bodies too. Delegate-then-save-then-post is the whole
# workflow the nudge asks for, and skipping the lookup recorded that compliant
# case as delegated:false — removing the sensor's best outcome from the ratio.
metrics_file="${DELEGATE_METRICS_FILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/metrics.jsonl}"
# Default 480 rather than 10: the batch flow delegates a sweep of drafts,
# waits for human approval, and posts hours later. Measured 2026-08-25, a
# 12-reply sweep delegated at 11:13 had still not posted four hours on, so a
# 10-minute window would have recorded every one of those posts as a missed
# delegation and fired 12 spurious nudges at the compliant session. The wide
# window is safe because credits are CONSUMED below: each delegated:true
# opportunity row spends one delegate row, so one morning delegation credits
# one post rather than silencing the nudge for the whole afternoon.
window_min="${DELEGATE_BOUNDARY_WINDOW_MIN:-480}"
now_epoch=$(date -u +%s)

# --- is this enough text to be drafting? (#483) ----------------------------
# `body_chars` (set by read_posted_body above, from the matched segment) is a
# count, never the text, and is recorded only when there is a measurable body
# at PreToolUse time: a `-F -` fed by a heredoc, a file written by the same
# call, a `--body-file` that does not exist yet, or any unresolved shell in
# the value leave it absent, and an absent count keeps the pre-#483
# behaviour (nudge or deny as the mode says). Measured 2026-09-13,
# `pr-review-comment` ran at 3% delegated over n=63 because most inline
# replies are one line — an applied-in hash, a dependabot rebase command, a
# one-word acknowledgement — and no recipe should draft those; without a
# stored length they could not be told from real drafting after the fact, so
# the floor records them and steps aside.
#
# The floor is per boundary (PR #484 review, item H). 120 was calibrated on
# inline review comments, where a paragraph clears it and a status line does
# not, but a one-line conventional commit is 40-60 characters — the
# commit-message recipe's own core output — and one global 120 exempted every
# such commit from enforcement and from the denominator, inflating the
# git-commit rate. git-commit gets 20 (a subject line); the rest keep 120.
# DELEGATE_BOUNDARY_MIN_CHARS overrides both. The rows carry the number, not
# the floor, so it can be re-tuned from the corpus.
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
# Unset (the default) enforces the set in DELEGATE_BOUNDARY_ENFORCE and warns
# elsewhere. The default set is the four boundaries whose recipe is proven on
# the corpus: git-commit (commit-message, 92% usable over n=41), issue-create
# (github-issue-body, 100% over n=12), and the two reply boundaries
# (pr-review-reply, maintainer-reply). pr-create and pr-review-body stay on
# warn until pr-description is above 80% usable on more than a handful of
# rows — denying a post to hand the agent a recipe that fails half the time
# would teach it to route around the hook. `${VAR-default}` rather than
# `:-`, so an explicitly empty set means "enforce nothing", which is the
# documented override.
#
# The deny is issued only while a provider is serving the recipe's tier: the
# same resolution delegate.sh will perform, so a deny never points at a
# command that cannot run. It costs one pick-model.sh run — the first
# reachable provider answers in tens of milliseconds, a dead localhost port
# refuses at once, and a dead remote host costs DELEGATE_PROBE_TIMEOUT (1s)
# per entry — and it is paid only on the deny path: never on a warn-only
# boundary, a credited post, or a body under the floor.
enforce_set="${DELEGATE_BOUNDARY_ENFORCE-git-commit,issue-create,comment-reply,pr-review-comment}"
enforce_set="${enforce_set// /}"
# Case-insensitive, and an unknown value is warn — as it was on main before
# #483, when any spelling but `enforce`/`off` fell through to the warn
# default. For a while an unknown value fell into the DEFAULT branch here and
# enforced, so `DELEGATE_BOUNDARY_MODE=Off` denied (PR #484 review, item F).
# nocasematch is bash 3.2 and costs no fork (`${var,,}` is bash 4).
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

# --- serialise lookup + append across concurrent hooks (PR #484, item M) ----
# The lookup reads a snapshot and the row that spends the credit is appended
# further down, so two enforced boundaries running at once after one
# delegation could both see `recent=1`, both allow, and both append
# delegated:true — one credit spent twice, rate inflated. A mkdir lock in the
# data dir is the portable primitive (flock is not on macOS, bash 3.2 has no
# better one): mkdir is atomic, so exactly one hook holds it, and the others
# wait in 50 ms steps. A lock older than a few seconds is a killed hook — the
# whole hook runs in ~150 ms — and is broken rather than wedging every later
# post; a lock that cannot be taken in 2 s fails OPEN: the hook proceeds
# unlocked and records enforce_skipped:"lock-timeout" instead of denying.
# Taken only when metrics are on, since with them off there is nothing to
# spend. Released on every exit path by the trap.
#
# The lock is OWNED. A hook whose provider probe runs past the stale
# threshold (a dead remote host costs DELEGATE_PROBE_TIMEOUT per entry) has
# its lock broken and replaced by the next hook; without an ownership check
# its own EXIT cleanup then removed the REPLACEMENT lock, and both ran their
# lookup unserialised against the same credit (third review round on #484).
# An owner token — pid plus a random suffix — is written into the dir on
# acquisition, and release removes the dir only while the token still
# matches. Breaking a stale lock removes it and re-runs mkdir, so the breaker
# owns what it takes.
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
    # The dir is visible at mkdir before `ts` is written, so a hook killed in
    # between leaves a lock with no `ts`; treating that as fresh made every
    # later hook wait 2 s and fail open for good (fifth review round). With
    # no `ts` the DIRECTORY mtime stands in — BSD `stat -f %m` first, GNU
    # `stat -c %Y` as the fallback, the pattern pick-model.sh already uses.
    lock_ts=$(cat "$lock_dir/ts" 2>/dev/null)
    if [[ ! "$lock_ts" =~ ^[0-9]+$ ]]; then
      lock_ts=$(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null)
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
denied_streak=0
if [[ -f "$metrics_file" ]]; then
  # Only the recent tail can fall inside the look-back window, so cap the read
  # instead of slurping the whole (ever-growing) metrics file on each boundary.
  # 2000 lines, not 500: truncation is asymmetric — it drops the OLDEST rows,
  # which are the earning delegate rows, while keeping the newer opportunity
  # rows that spent them, so a too-small tail denies credit (and can push the
  # count negative, which `-gt 0` already reads as uncredited). 2000 rows
  # covers the 480-minute window unless boundaries exceed ~4/minute all day.
  # `recent` is delegate rows MINUS already-credited posts (delegated:true
  # opportunity rows for the same project+recipe in the same window), so a
  # boundary is credited only while an unspent delegation remains.
  #
  # `credit_recipes` is the set of recipes that credit THIS boundary. Every
  # boundary but one maps to a single recipe; comment-reply names its recipe
  # from the body's length (the 600 split above), and matching on that exact
  # name looped (PR #484 review, item B): a 700-char post was denied naming
  # maintainer-review-reply, the agent delegated exactly that and posted the
  # 450-char draft, which routed to maintainer-reply, matched no credit, and
  # was denied again under a different name. Either comment-reply recipe
  # credits a comment-reply boundary, on both the earning and the spending
  # side; the row still records the recipe its own length routes to.
  # Built by hand rather than with jq: $recipe is one of the fixed identifiers
  # classify_segment assigns, never user text, and this runs on every
  # boundary.
  case "$boundary" in
    comment-reply) credit_recipes='["maintainer-reply","maintainer-review-reply"]' ;;
    *)             credit_recipes="[\"${recipe}\"]" ;;
  esac
  recent_out=$(tail -n 2000 "$metrics_file" 2>/dev/null | jq -rs --argjson win "$((window_min * 60))" --arg proj "$project" --arg proj2 "$cwd_project" --arg proj3 "$repo_project" --arg sid "$session_id" --argjson recipes "$credit_recipes" --arg boundary "$boundary" --argjson now "$now_epoch" '
    # Any of the three NAMED candidates counts, each guarded against being
    # empty. With no `cd`, $proj and $proj2 are equal, so $proj3 is
    # load-bearing rather than decorative.
    #
    # A PROJECTLESS row (no .project) is a different case. It is what
    # delegate.sh writes when its cwd is outside a git repository (#476), so
    # it can only belong to a boundary whose session cwd is likewise outside
    # one ($proj2 == "") — a boundary inside a repository has a non-empty
    # $proj2 and the projectless rows never reach it. But the metrics file is
    # shared by every session on the machine, and "no project" would name one
    # pool across all of them: an unrelated scratch-cwd session could credit
    # this post, silence its nudge, and have its draft filed as the shipped
    # form of a reply it never wrote (PR #477 review). So a projectless row
    # is credited only when its `session` — CLAUDE_CODE_SESSION_ID as
    # delegate.sh records it (#479), the same UUID the harness hands this
    # hook as .session_id — equals this session. A projectless row with no
    # session (written before #479, or by a caller outside Claude) credits
    # nothing: fail safe, nudge. The same predicate scopes the delegated:true
    # opportunity rows that SPEND credits, which is why the opportunity row
    # below records the session too, and the ADR 0029 draft capture inherits
    # the scoping for free. (No apostrophes here: this comment sits inside
    # the single-quoted jq program.)
    def named($c): $c != "" and (.project // "") == $c;
    def same_session: $sid != "" and (.session // "") == $sid;
    def matches_proj: named($proj) or named($proj2) or named($proj3)
                      or ((.project // "") == "" and $proj2 == "" and same_session);
    def in_window: ((.ts | fromdateiso8601?) // 0) > ($now - $win);
    # A delegation that failed (exit_status:3 is the pre-flight stall, #110)
    # produced no draft this post could be the shipped form of, so it earns
    # no credit. metrics-summary.sh and the Stop hook already join on
    # exit_status 0; until PR #477 this lookup was the odd one out.
    ([ .[]
       | select((.source // "delegate") == "delegate")
       | select((.exit_status // 0) == 0)
       | select(matches_proj)
       | select((.recipe // "") as $r | $recipes | index($r) != null)
       | select(in_window) ] | sort_by(.ts)) as $d
    | ([ .[]
       | select((.source // "") == "opportunity")
       | select(.delegated == true)
       | select(matches_proj)
       | select((.suggested_recipe // "") as $r | $recipes | index($r) != null)
       | select(in_window) ] | length) as $c
    # The denial streak (PR #484 review, item E): how many of this
    # session+boundary rows in the window, newest first, are denied:true
    # before the first that is not. Two in a row and the next attempt is
    # warned rather than denied — a delegation that fails never credits, and
    # a metrics path that differs between the hook env and the tool env
    # means no credit can be written where this lookup reads, so without a
    # cap a deny was a permanent block. A credited (or any non-denied) row
    # resets it, so the cap cannot be banked across a session.
    | ([ .[]
       | select((.source // "") == "opportunity")
       | select((.boundary // "") == $boundary)
       | select((.session // "") == $sid)
       | select(in_window) ] | sort_by(.ts) | reverse
       | reduce .[] as $r ({n: 0, stop: false};
           if .stop then . elif $r.denied == true then .n += 1 else .stop = true end)
       | .n) as $streak
    # Three fields from one pass: the credit count the nudge decision reads,
    # the draft belonging to the delegation THIS post is about to spend, and
    # the streak. Oldest-unspent-first, because that is the order a sweep
    # posts in — the 12-reply flow that set the 480-minute window delegates a
    # batch and works down it, so the n-th post is the n-th draft.
    | "\($d | length - $c)\u001f\($d[$c].draft_file // "")\u001f\($streak)"' 2>/dev/null) || recent_out=""
  # Unit separator, not tab: tab is IFS whitespace, so an empty middle field
  # (a delegation with no draft) would collapse and shift the streak into
  # credit_draft.
  IFS=$'\x1f' read -r recent credit_draft denied_streak <<<"$recent_out"
  [[ "${recent:-0}" =~ ^-?[0-9]+$ ]] || recent=0
  [[ "${denied_streak:-0}" =~ ^[0-9]+$ ]] || denied_streak=0
  # `credit_draft` is read out of a JSONL file and is about to become part of a
  # path this hook WRITES to, so it is treated as untrusted: a bare filename
  # ending in .draft.txt, nothing else. A hand-edited or corrupted row carrying
  # `../../x.draft.txt` would otherwise place the captured body outside the
  # drafts directory. Anything that fails simply loses the capture.
  case "$credit_draft" in
    *.draft.txt) [[ "$credit_draft" == */* || "$credit_draft" == .* ]] && credit_draft="" ;;
    *) credit_draft="" ;;
  esac
  [[ "${recent:-0}" -gt 0 ]] && delegated=true
fi

# --- record the opportunity (the trigger-rate sensor) ---------------------
# One row per boundary so trigger rate has a denominator. Stores no command or
# message text — only boundary type, suggested recipe, project and the flag.
# The project field is omitted, not emptied, when there is none (#476), the
# same shape delegate.sh writes; metrics-summary.sh reports those rows on one
# `(no project)` line rather than under a name. The session is recorded on
# the same terms as delegate.sh records it (present when known, omitted
# otherwise): a delegated:true row spends a credit, and the projectless
# lookup above only counts spends from the same session, so a row without it
# could never spend one.
#
# Three #483 fields, each omitted when it does not apply. `body_chars` is the
# measured length (an integer, never the text). `below_floor:true` marks a
# row the floor kept out of the nudge, so the summary can keep it out of the
# rate. `denied:true` marks an attempt this hook blocked: the post did not
# happen, the agent will delegate and retry, and that retry writes the row
# that counts — counting the blocked attempt too would record every enforced
# boundary as a miss followed by a hit and cap the rate near 50%.
# `enforce_skipped:"<reason>"` marks a deny that fell open (the reasons are
# listed above); the post went through undrafted, so that row stays a real
# miss. Returns the append's status, so the caller can tell a row that was
# not written (item E: a deny is withdrawn when no credit could ever be
# recorded here either).
append_row() {
  [[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]] || return 0
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  jq -nc --arg ts "$ts" --arg project "$project" --arg boundary "$boundary" \
     --arg recipe "$recipe" --arg sid "$session_id" --argjson delegated "$delegated" \
     --arg body_chars "$body_chars" --argjson below_floor "$below_floor" \
     --argjson denied "$denied" --arg skipped "$enforce_skipped" '
     {ts:$ts, source:"opportunity", boundary:$boundary, suggested_recipe:$recipe, delegated:$delegated}
     + (if $project != "" then {project:$project} else {} end)
     + (if $sid != "" then {session:$sid} else {} end)
     + (if $body_chars != "" then {body_chars:($body_chars | tonumber)} else {} end)
     + (if $below_floor then {below_floor:true} else {} end)
     + (if $denied then {denied:true} else {} end)
     + (if $skipped != "" then {enforce_skipped:$skipped} else {} end)' \
     >> "$metrics_file" 2>/dev/null
}

# --- the critical section ends here (fifth review round on #484) ----------
# Only a delegated:true row spends a credit, so only a credited post has to
# append under the lock; the lookup and that append are the whole critical
# section, milliseconds. An uncredited post releases the lock FIRST and only
# then decides whether it can be denied — the provider probe, the retry cap,
# the writability test — because a slow probe (DELEGATE_PROBE_TIMEOUT raised
# against a dead remote host) held inside the lock could be stale-broken at
# 5 s and let a second hook spend the same credit; the owner token protects
# only the cleanup. Its delegated:false row is appended unlocked: it spends
# nothing, and the worst a race can do is count one extra denial toward the
# retry cap. A credited post never probes at all.
denied=false enforce_skipped="" tier_decl=""
if [[ "$delegated" == "true" ]]; then
  # --- store the posted body as the shipped half of the pair (ADR 0029) -------
  # `maintainer-reply` was the weakest recipe with any volume (21% usable over
  # n=33) and the only one whose 32 rejections carried no captured final at all,
  # because its output is posted inline inside `gh pr comment --body "..."` and
  # there is no path on disk for `delegate-feedback.sh --final` to name. A commit
  # message reaches a file before `git commit -F` reads it; a reply never does.
  #
  # This hook is the one place that sees the shipped text, and when the post is
  # credited to a delegation it IS that delegation's shipped form by definition.
  # Store it beside the draft under the draft's own stem, so the two halves are
  # guaranteed to belong together, and let `delegate-feedback.sh` adopt it when
  # the caller passed no `--final`. An existing file is never overwritten: a
  # hand-supplied final outranks an inferred one. The `-e` check is only the
  # cheap way to skip parsing the body; the guarantee is the `set -C` on the
  # write, which makes the redirect itself fail if a feedback call claimed the
  # bare name between the check and the write (PR #479 review).
  #
  # The capture is PRE-post, so a post that then fails leaves a final for text
  # that never shipped. The verdict is recorded by whoever ran the command and
  # knows, and `--final` still wins, so the cost of that is bounded.
  if [[ "$delegated" == "true" && -n "${credit_draft:-}" \
        && "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]]; then
    drafts_dir="$(dirname "$metrics_file")/drafts"
    final_path="$drafts_dir/${credit_draft%.draft.txt}.final.txt"
    if [[ ! -e "$final_path" && -n "$body_text" ]]; then
      if mkdir -p "$drafts_dir" 2>/dev/null; then
        chmod 700 "$drafts_dir" 2>/dev/null || true
        ( umask 077; set -C; printf '%s' "$body_text" > "$final_path" ) 2>/dev/null || true
        [[ -f "$final_path" ]] && chmod 600 "$final_path" 2>/dev/null
      fi
    fi
  fi
  append_row || true
  release_lock
else
  release_lock
  # Why a deny was not issued, when it was not. Every reason here fails OPEN to
  # warn, because "a commit is never blocked by a hook bug" has to survive
  # every way the credit path can be broken (PR #484 review, items E, G, M):
  #   metrics-unwritable  DELEGATE_LOCAL_NO_METRICS=1 in the hook env, or the
  #                       metrics file cannot be appended to — no credit can
  #                       ever be written where this hook reads, so a deny
  #                       would have no escape.
  #   retry-cap           two consecutive denials for this session+boundary
  #                       already; a delegation that fails (canary stall, HTTP
  #                       500, echo check) never credits, so the third attempt
  #                       goes through.
  #   lock-timeout        the lookup lock above could not be taken in 2 s.
  #   no-provider         pick-model.sh: nothing reachable.
  #   no-model            pick-model.sh: a provider is up but serves no model
  #                       for the recipe tier.
  #   bad-tier            pick-model.sh: the recipe declares a tier it does not
  #                       know (or the frontmatter is malformed).
  # The probe is pick-model.sh on the recipe tier — the same resolution
  # delegate.sh will perform, so a deny never points at a command that cannot
  # run. It exits 1 for both "unreachable" and "no model", telling them apart
  # only on stderr, and 2 for a bad tier. It costs ~50 ms when the first
  # provider answers or every localhost port is closed (a dead remote host costs
  # DELEGATE_PROBE_TIMEOUT, 1 s, per entry), and it is paid only when a deny is
  # otherwise about to happen: never on a warn-only boundary, a credited post,
  # a body under the floor, or a capped or unlockable session.
  enforce_skipped="" tier_decl=""
  retry_cap=2
  if [[ "$mode" == "enforce" && "$delegated" != "true" && "$below_floor" != "true" ]]; then
    if [[ "${DELEGATE_LOCAL_NO_METRICS:-}" == "1" ]]; then
      enforce_skipped="metrics-unwritable"
    elif [[ "$lock_failed" == "true" ]]; then
      enforce_skipped="lock-timeout"
    elif (( denied_streak >= retry_cap )); then
      enforce_skipped="retry-cap"
    else
      # The tier the recipe declares, read with the same expression delegate.sh
      # uses (lib/recipe.sh, item I), so `tier: prose ` resolves in both.
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
  # The append is the writability test. When it fails and a deny was about
  # to be issued, the deny is withdrawn: no row means no credit could ever be
  # recorded here either, and the row that would have said `denied:true` was
  # not written, so nothing is left inconsistent. The reminder carries the
  # reason instead (item E).
  if ! append_row && [[ "$denied" == "true" ]]; then
    denied=false; mode=warn; enforce_skipped="metrics-unwritable"
  fi
fi

# --- nudge unless the artifact was already delegated ----------------------
# The only exemption is a credited delegation. Since #465 a file-backed body
# nudges like an inline one, because a body file is not evidence that the text
# came from anywhere but this agent a call earlier. A body under the floor is
# recorded above and left alone here: it is not drafting.
[[ "$delegated" == "true" ]] && exit 0
[[ "$below_floor" == "true" ]] && exit 0
[[ "$mode" == "off" ]] && exit 0

# Every boundary recipe declares required inputs, and a --recipe call that
# omits one exits 2 ("missing required inputs: ..."). Naming the recipe without
# its --var keys therefore handed the agent a command that could not run: the
# nudge fired, the agent tried it, delegate.sh refused, and the delegation never
# happened. Read the keys from the recipe's own frontmatter rather than
# hardcoding them here, so the nudge stays correct as recipes change their
# inputs. `stdin` is not a --var — it means "pipe the context in" — and a
# trailing `?` marks an optional input, which the nudge leaves out.
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

# The nudge names --project explicitly: the metrics project is derived from
# delegate.sh's own cwd, so an agent that cd's into the skill checkout to run
# the command records project=delegate-local and never matches this lookup,
# which is the nag loop #342 describes. The hook already knows the right value.
#
# Outside a git repository it knows no value (#476). The command must still
# run as printed (docs/boundary-hook.md), so neither `--project ""` nor a
# `--project <name>` placeholder — bash reads that as a redirection — can
# appear. When the command names its repo (`--repo owner/name`) that value is
# rendered, because it is a lookup candidate here. Otherwise the flag is left
# out entirely: a delegation issued from this same cwd is projectless, which
# is exactly what the empty session-cwd candidate matches, whereas one
# carrying ANY name could never credit this boundary. Not every non-repo
# boundary carries a `cd` or `--repo` — `gh api ... -F in_reply_to=`,
# `git -C <path>` and a `~` path all reach here without one — so the no-flag
# form is the only advice that matches the lookup in every case.
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

# The same text on both channels; only the closing sentence differs. The
# hook reads its environment from the harness, not from the command it is
# judging, so a `DELEGATE_BOUNDARY_MODE=off git commit …` prefix changes
# nothing — the deny says what does help: delegate, then rerun this call,
# which the recorded delegation then credits.
if [[ "$denied" == "true" ]]; then
  jq -nc --arg r "${reminder} This call was blocked; rerun it once the delegation is recorded, and it is credited. DELEGATE_BOUNDARY_MODE=warn in the hook's environment downgrades this to a reminder." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  # A deny that fell open says why, in terms the agent can act on: each
  # reason names a different remedy, and "start MLX or Ollama" was being said
  # when a provider was up all along (item G).
  case "$enforce_skipped" in
    no-provider)        tail="No local provider answered, so this call proceeds undrafted; start MLX or Ollama to draft the next one." ;;
    no-model)           tail="A local provider is up but serves no model for the ${tier_decl:-prose} tier, so this call proceeds undrafted; pull one or edit the prefs in pick-model.sh." ;;
    bad-tier)           tail="The recipe declares tier '${tier_decl}', which pick-model.sh does not know, so this call proceeds undrafted; fix the recipe's frontmatter." ;;
    retry-cap)          tail="This session was already denied twice for this boundary, so this call proceeds undrafted rather than blocking for good; if the delegation keeps failing, check its stderr." ;;
    metrics-unwritable) tail="The metrics file cannot be written from the hook's environment, so no delegation could ever be credited here and this call proceeds undrafted; check DELEGATE_METRICS_FILE / DELEGATE_LOCAL_DATA_DIR match between settings.json and the shell, or unset DELEGATE_LOCAL_NO_METRICS." ;;
    lock-timeout)       tail="Another boundary hook held the metrics lock for over two seconds, so this call proceeds undrafted." ;;
    *)                  tail="Set DELEGATE_BOUNDARY_MODE=off to silence." ;;
  esac
  jq -nc --arg c "${reminder} ${tail}" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$c}}'
fi
exit 0
