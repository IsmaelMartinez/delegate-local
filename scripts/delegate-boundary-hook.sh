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
#   4. When delegated:false, surface a reminder naming the exact recipe. Mode is
#      env-controlled: warn (default, non-blocking additionalContext the model
#      sees), enforce (deny the call so the model re-routes), or off (measure
#      only, no reminder).
#
# One boundary shape is neither delegated nor missed: a body read from a file
# that already exists (`--body-file` / `-F` / `--notes-file` / `--file`). The
# drafting moment was the earlier Write, several tool calls back, so re-drafting
# now would throw away text that was often already human-approved. Those rows
# carry state:"pre-drafted" and no nudge fires; metrics-summary.sh keeps them out
# of the trigger-rate numerator AND denominator so human-approved posts stop
# reading as missed delegations (#349).
#
# Fails OPEN: any error, missing jq, or unparseable input exits 0 so a commit is
# never blocked by a hook bug. The only blocking path is the explicit
# DELEGATE_BOUNDARY_MODE=enforce deny. Install is opt-in — see
# docs/boundary-hook.md.
#
# Env:
#   DELEGATE_BOUNDARY_MODE        warn (default) | enforce | off
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
scan=$(awk 'BEGIN{RS="\1"} {
  n = length($0); q = ""; out = "";
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
        || c == "(" || c == ")" || c == "{" || c == "}") { out = out "\n"; continue }
    out = out c;
  }
  print out;
}' <<<"$cmd" 2>/dev/null) || exit 0
[[ -z "$scan" ]] && exit 0

# --- is this a delegatable boundary? --------------------------------------
# Each segment is classified independently and the first match wins, so a flag
# never binds to a command in a different segment.
boundary="" recipe=""
# Any command word added below must also appear in the pre-filter grep above —
# everything here is gated on it, so a new branch whose command word is missing
# there is dead code that silently never fires, with tests still green because
# they only exercise branches that exist.
classify_segment() {
  local seg="$1"
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
  # General PR / issue / MR comment reply authored inline.
  if grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+comment([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+issue[[:space:]]+comment([[:space:]]|$)' <<<"$seg" \
     || grep -Eq '(^|[^[:alnum:]_-])glab[[:space:]]+(mr|issue)[[:space:]]+(discussion[[:space:]]+)?note([[:space:]]|$)' <<<"$seg"; then
    boundary="comment-reply"; recipe="maintainer-reply"; return 0
  fi
  return 1
}

matched_seg=""
while IFS= read -r seg; do
  [[ -z "$seg" ]] && continue
  # Builtin pre-filter, no subprocess: classify_segment costs up to 9 greps and
  # runs per SEGMENT, so a routine `gh pr list ... | while read n; do ...; done`
  # (5 segments, classifies as nothing) paid 46 grep spawns / ~204ms. Every
  # branch above needs a literal git/gh/glab, so skipping segments without one
  # is free — measured 204ms -> 93ms on that shape.
  case "$seg" in *git*|*gh*|*glab*) ;; *) continue ;; esac
  if classify_segment "$seg"; then matched_seg="$seg"; break; fi
done <<<"$scan"
[[ -z "$boundary" ]] && exit 0

# --- derive the project name (mirror delegate.sh / lib/otel.sh) -----------
[[ -n "$hook_cwd" && -d "$hook_cwd" ]] && cd "$hook_cwd" 2>/dev/null || true
cwd_project=""
common=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [[ -n "$common" ]]; then
  common_dir=$(cd "$common" 2>/dev/null && pwd || true)
  [[ -n "$common_dir" ]] && cwd_project=$(basename "$(dirname "$common_dir")")
else
  cwd_project=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
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
# quoted path with a space survives there as `cd   `. The match is ^-anchored,
# so a heredoc body mentioning `cd /x && git commit` cannot reach it, and the
# captured path is only ever a quoted argument to `cd` inside a subshell. It is
# never expanded and never eval'd.
cd_project=""
_cd_sq="^[[:space:]]*cd[[:space:]]+'([^']+)'[[:space:]]*&&"
_cd_dq="^[[:space:]]*cd[[:space:]]+\"([^\"]+)\"[[:space:]]*&&"
_cd_bare="^[[:space:]]*cd[[:space:]]+([^[:space:]&'\"]+)[[:space:]]*&&"
if [[ "$cmd" =~ $_cd_sq ]] || [[ "$cmd" =~ $_cd_dq ]] || [[ "$cmd" =~ $_cd_bare ]]; then
  cd_path="${BASH_REMATCH[1]}"
  # `cd -` resolves to $OLDPWD, which is not knowable from the payload, and a
  # path carrying $, backtick or ~ would need an expansion the hook must not
  # perform. Both are rejected outright rather than sanitised.
  case "$cd_path" in
    -*|*'$'*|*'`'*|*'~'*) cd_path="" ;;
  esac
  if [[ -n "$cd_path" && -d "$cd_path" ]]; then
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
fi
project="${cd_project:-$cwd_project}"

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

# --- was the body drafted earlier, into a file? (#349) --------------------
# `--body-file` / `-F` / `--notes-file` / `--file` pointing at a file that
# already exists means the drafting moment has passed: the text was authored at
# an earlier Write, and in practice was often shown to and approved by the human
# before this call. Re-drafting on-device now would discard what they signed off
# on, so the nudge is not actionable — and counting it as a missed delegation
# deflates the per-project trigger rate. Recorded as its own state instead.
# An inline `--body`/`-m` string keeps nudging: that IS the drafting moment.
# A path that does not exist (`--body-file -`, a file about to be written) is
# not pre-drafted either, so the boundary behaves exactly as before.
#
# Scoped to the segment that classified, and to the already-sanitised scan
# surface, so the detector inherits the classifier's parsing rather than
# re-deriving it: a `-F` in an unrelated segment, or the words `--body-file
# drafts/body.md` inside quoted prose, must not mark an inline call as
# pre-drafted (that would suppress a real nudge and delete the row from the
# metric — worse than the deflation #349 reports). A literally-quoted path is
# blanked with the rest of the quoted span and simply falls back to nudging,
# which is the fail-safe direction.
#
# git-commit is excluded on purpose. #349 is about gh/glab posts of text a
# human already approved; `git commit -F /tmp/msg.txt` is the standard way an
# agent commits a message it composed itself moments earlier, which is exactly
# the drafting moment this hook exists to catch.
state=""
if [[ "$boundary" != "git-commit" ]]; then
  body_file_args=$(awk 'BEGIN{RS="\1"} {
    n = split($0, t, /[[:space:]]+/);
    for (i = 1; i <= n; i++) {
      v = "";
      if (t[i] == "--body-file" || t[i] == "--notes-file" || t[i] == "--file" || t[i] == "-F") {
        if (i < n) v = t[i + 1];
      } else if (t[i] ~ /^(--body-file|--notes-file|--file|-F)=/) {
        v = t[i]; sub(/^[^=]*=/, "", v);
      }
      # `gh api -F body=@draft.md` reads the field from a file — the same
      # already-drafted situation, in the form used to post inline PR review
      # replies. A plain `-F key=value` has no @ and yields no candidate.
      if (v ~ /^[A-Za-z_][A-Za-z0-9_-]*=@/) sub(/^[^=]*=@/, "", v);
      if (v != "" && v !~ /=/) print v;
    }
  }' <<<"$matched_seg" 2>/dev/null) || body_file_args=""
  while IFS= read -r cand; do
    [[ -z "$cand" ]] && continue
    if [[ -f "$cand" ]]; then state="pre-drafted"; break; fi
  done <<<"$body_file_args"
fi

# --- was there a local delegation for THIS boundary's recipe, recently? ----
# Recipe-aware: only a delegation whose recipe matches this boundary's recipe
# counts as capturing it. Matching on project alone over-counted — a commit-message
# delegation marked a later `gh pr create` / review-comment reply as captured even
# though the PR body / reply was authored inline, which both inflated the trigger
# rate AND suppressed the nudge (delegated:true skips it below), so the artifact the
# boundary is about was never delegated. A bare (no-recipe) delegation no longer
# counts for any boundary — the calibrated recipe the nudge names is the path.
# Runs for pre-drafted bodies too. Delegate-then-save-then-post is the whole
# workflow the nudge asks for, and skipping the lookup recorded that compliant
# case as delegated:false — removing the sensor's best outcome from both sides
# of the ratio. delegated:true wins over pre-drafted when both apply.
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
delegated=false
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
  recent=$(tail -n 2000 "$metrics_file" 2>/dev/null | jq -s --argjson win "$((window_min * 60))" --arg proj "$project" --arg proj2 "$cwd_project" --arg proj3 "$repo_project" --arg recipe "$recipe" --argjson now "$now_epoch" '
    # Any of the three candidates counts. With no `cd`, $proj and $proj2 are
    # equal, so $proj3 is load-bearing rather than decorative. $proj3 is the
    # only candidate that can be empty, and it is guarded: 3 delegate rows in
    # the current file carry no project at all, and an unguarded `== ""` would
    # let them match every boundary. They are saved today only by the recipe
    # predicate also failing, which is an accident, not a design.
    def matches_proj: (.project // "") == $proj
                      or (.project // "") == $proj2
                      or ($proj3 != "" and (.project // "") == $proj3);
    def in_window: ((.ts | fromdateiso8601?) // 0) > ($now - $win);
    ([ .[]
       | select((.source // "delegate") == "delegate")
       | select(matches_proj)
       | select((.recipe // "") == $recipe)
       | select(in_window) ] | length)
    -
    ([ .[]
       | select((.source // "") == "opportunity")
       | select(.delegated == true)
       | select(matches_proj)
       | select((.suggested_recipe // "") == $recipe)
       | select(in_window) ] | length)' 2>/dev/null) || recent=0
  [[ "${recent:-0}" -gt 0 ]] && delegated=true
fi
# A delegated boundary is a counted success, not an excluded row, so the
# delegated flag supersedes pre-drafted when both describe the same post.
[[ "$delegated" == "true" ]] && state=""

# --- record the opportunity (the trigger-rate sensor) ---------------------
# One row per boundary so trigger rate has a denominator. Stores no command or
# message text — only boundary type, suggested recipe, project, the flag, and
# (when the body came from a file that already existed) state:"pre-drafted".
if [[ "${DELEGATE_LOCAL_NO_METRICS:-}" != "1" ]]; then
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true
  jq -nc --arg ts "$ts" --arg project "$project" --arg boundary "$boundary" \
     --arg recipe "$recipe" --argjson delegated "$delegated" --arg state "$state" '
     {ts:$ts, source:"opportunity", boundary:$boundary, suggested_recipe:$recipe, delegated:$delegated}
     + (if $state != "" then {state:$state} else {} end)
     + (if $project != "" then {project:$project} else {} end)' \
     >> "$metrics_file" 2>/dev/null || true
fi

# --- nudge only when the artifact is about to be authored inline ----------
[[ -n "$state" ]] && exit 0
[[ "$delegated" == "true" ]] && exit 0

mode="${DELEGATE_BOUNDARY_MODE:-warn}"
[[ "$mode" == "off" ]] && exit 0

# Every boundary recipe declares required inputs, and a --recipe call that
# omits one exits 2 ("missing required inputs: ..."). Naming the recipe without
# its --var keys therefore handed the agent a command that could not run: the
# nudge fired, the agent tried it, delegate.sh refused, and the delegation never
# happened. Read the keys from the recipe's own frontmatter rather than
# hardcoding them here, so the nudge stays correct as recipes change their
# inputs. `stdin` is not a --var — it means "pipe the context in" — and a
# trailing `?` marks an optional input, which the nudge leaves out.
prompts_dir="${DELEGATE_PROMPTS_DIR:-$script_dir/../prompts}"
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
reminder="delegate-local: about to author a ${boundary} message inline with no local delegation recorded in the last ${window_min}m for project '${project}'. Draft it on-device first — bash ~/.claude/skills/delegate-local/scripts/delegate.sh --project \"${project}\" --recipe ${recipe}${var_hint}${stdin_hint} — then record the verdict with ~/.claude/skills/delegate-local/scripts/delegate-feedback.sh --source agent. Set DELEGATE_BOUNDARY_MODE=off to silence."

if [[ "$mode" == "enforce" ]]; then
  jq -nc --arg r "$reminder" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
else
  jq -nc --arg c "$reminder" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",additionalContext:$c}}'
fi
exit 0
