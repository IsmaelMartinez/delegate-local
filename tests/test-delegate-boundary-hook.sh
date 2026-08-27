#!/usr/bin/env bash
# Unit tests for scripts/delegate-boundary-hook.sh (the #277 trigger-rate hook).
# Feeds PreToolUse payloads on stdin, asserts on the emitted JSON and the
# source:"opportunity" rows written to a throwaway metrics file. No real models
# or metrics files are touched.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/scripts/delegate-boundary-hook.sh"

pass=0
fail=0
assert_eq() {
  local e="$1" a="$2" n="$3"
  if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1))
  else echo "  FAIL  $n (expected '$e', got '$a')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle' in '$haystack')"; fail=$((fail+1)); fi
}

# A throwaway cwd that is NOT inside any git repo, so the hook's project
# derivation falls back to its basename — a stable, known project name.
tmpcwd=$(mktemp -d)
proj=$(basename "$tmpcwd")
METRICS=$(mktemp)
trap 'rm -rf "$tmpcwd" "$METRICS"' EXIT
nowts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

payload() { # cmd  cwd
  jq -nc --arg cmd "$1" --arg cwd "$2" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, tool_input:{command:$cmd}}'
}
last_row() { tail -1 "$METRICS"; }
nrows() { local n; n=$(grep -c . "$METRICS" 2>/dev/null) || true; echo "${n:-0}"; }

# 1. Non-boundary command: silent, no row.
: > "$METRICS"
ec=0
out=$(payload "ls -la" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "non-boundary: exit 0"
assert_eq "" "$out" "non-boundary: no stdout"
assert_eq 0 "$(nrows)" "non-boundary: no metrics row"

# 2. git commit, no prior delegation: warn nudge + delegated:false opportunity row.
: > "$METRICS"
out=$(payload 'git commit -m "fix: thing"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains '"additionalContext"' "$out" "commit/no-delegation: non-blocking additionalContext"
assert_contains '"permissionDecision":"allow"' "$out" "commit/no-delegation: allow (non-blocking)"
assert_contains 'commit-message' "$out" "commit/no-delegation: names the recipe"
row=$(last_row)
assert_eq opportunity "$(jq -r .source <<<"$row")" "commit row: source=opportunity"
assert_eq git-commit "$(jq -r .boundary <<<"$row")" "commit row: boundary=git-commit"
assert_eq commit-message "$(jq -r .suggested_recipe <<<"$row")" "commit row: suggested_recipe"
assert_eq false "$(jq -r .delegated <<<"$row")" "commit row: delegated=false"
assert_eq "$proj" "$(jq -r .project <<<"$row")" "commit row: project derived from cwd"

# 3. git commit WITH a recent delegation for this project: silent, delegated:true.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
out=$(payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "commit/recent-delegation: no nudge"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "commit/recent-delegation: delegated=true"

# 4. Delegation older than the window: counts as missed.
: > "$METRICS"
jq -nc --arg p "$proj" \
  '{ts:"2020-01-01T00:00:00Z", source:"delegate", project:$p, tier:"prose"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "commit/stale-delegation: delegated=false"

# 5. A delegation for a DIFFERENT project does not count.
: > "$METRICS"
jq -nc --arg ts "$nowts" \
  '{ts:$ts, source:"delegate", project:"some-other-repo", tier:"prose"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "commit/other-project delegation: delegated=false"

# 5a. Recipe-aware MATCH: a recent pr-description delegation captures a pr-create
# boundary -> delegated=true, no nudge.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"pr-description"}' >> "$METRICS"
out=$(payload 'gh pr create --title t --body b' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "pr-create/matching pr-description delegation: delegated=true"
assert_eq "" "$out" "pr-create/matching delegation: no nudge"

# 5b. Recipe-aware MISMATCH (the #312 fix): a recent commit-message delegation does
# NOT capture a pr-create boundary -> delegated=false, nudge still names pr-description.
# Before the fix the project-only match marked this true and suppressed the nudge,
# so the PR body went un-delegated yet counted as captured.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
out=$(payload 'gh pr create --title t --body b' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "pr-create/commit-message delegation: delegated=false (recipe mismatch)"
assert_contains 'pr-description' "$out" "pr-create/commit-message delegation: nudge still fires for pr-description"

# 5c. Recipe-aware MISMATCH for review replies: a recent commit-message delegation
# does not capture a pr-review-comment boundary -> delegated=false, nudge names
# pr-review-reply.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
out=$(payload 'gh api repos/o/r/pulls/12/comments -X POST -f body="x" -F in_reply_to=9' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "pr-review-comment/commit-message delegation: delegated=false (recipe mismatch)"
assert_contains 'pr-review-reply' "$out" "pr-review-comment/commit-message delegation: nudge names pr-review-reply"

# 5d. A bare (no-recipe) delegation no longer counts for any boundary: the nudge
# steers toward the calibrated recipe.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "commit/bare delegation: delegated=false (no recipe to match)"

# 6. gh pr create -> pr-description recipe.
: > "$METRICS"
out=$(payload 'gh pr create --title t --body b' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq pr-create "$(jq -r .boundary <<<"$(last_row)")" "pr-create: boundary"
assert_eq pr-description "$(jq -r .suggested_recipe <<<"$(last_row)")" "pr-create: recipe"
assert_contains 'pr-description' "$out" "pr-create: nudge names recipe"

# 7. glab mr create -> also pr-create.
: > "$METRICS"
payload 'glab mr create --fill' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-create "$(jq -r .boundary <<<"$(last_row)")" "glab mr create: boundary"

# 8. gh release create -> release-note recipe.
: > "$METRICS"
payload 'gh release create v1.0.0 --notes x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq release-create "$(jq -r .boundary <<<"$(last_row)")" "release-create: boundary"
assert_eq release-note "$(jq -r .suggested_recipe <<<"$(last_row)")" "release-create: recipe"

# 8h. gh issue create WITH an inline body -> issue-create / github-issue-body.
: > "$METRICS"
out=$(payload 'gh issue create --title t --body "long body here"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq issue-create "$(jq -r .boundary <<<"$(last_row)")" "gh issue create --body: boundary"
assert_eq github-issue-body "$(jq -r .suggested_recipe <<<"$(last_row)")" "gh issue create --body: recipe"
assert_contains 'github-issue-body' "$out" "gh issue create --body: nudge names recipe"

# 8h-bis. The --body-file / -F form also authors a body inline -> boundary.
: > "$METRICS"
payload 'gh issue create -t t -F body.md' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq issue-create "$(jq -r .boundary <<<"$(last_row)")" "gh issue create -F: boundary"
assert_eq github-issue-body "$(jq -r .suggested_recipe <<<"$(last_row)")" "gh issue create -F: recipe"

# 8h-ter. gh issue create --web / -w (browser form) is NOT a boundary: no inline body.
: > "$METRICS"
ec=0
out=$(payload 'gh issue create --web' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "gh issue create --web: exit 0"
assert_eq "" "$out" "gh issue create --web: no nudge"
assert_eq 0 "$(nrows)" "gh issue create --web: no row (no inline body)"

: > "$METRICS"
ec=0
out=$(payload 'gh issue create -w' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "gh issue create -w: exit 0"
assert_eq "" "$out" "gh issue create -w: no nudge"
assert_eq 0 "$(nrows)" "gh issue create -w: no row (no inline body)"

# 8h-ter-bis. A --web SUBSTRING (--webhooks) in a title/body must NOT suppress the
# boundary — the --web exclusion is anchored to a standalone flag.
: > "$METRICS"
payload 'gh issue create --title "Fix --webhooks handling" --body "long body here"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq issue-create "$(jq -r .boundary <<<"$(last_row)")" "gh issue create with --webhooks substring: still a boundary"

# 8h-quater. gh issue create with no body flag (interactive editor) is NOT a boundary.
: > "$METRICS"
out=$(payload 'gh issue create --title t' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "gh issue create no-body: no nudge"
assert_eq 0 "$(nrows)" "gh issue create no-body: no row (interactive editor, no inline body)"

# 8c. gh pr comment -> comment-reply / maintainer-reply recipe.
: > "$METRICS"
out=$(payload 'gh pr comment 12 --body "Applied in abc123"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq comment-reply "$(jq -r .boundary <<<"$(last_row)")" "gh pr comment: boundary"
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" "gh pr comment: recipe"
assert_contains 'maintainer-reply' "$out" "gh pr comment: nudge names recipe"

# 8d. gh issue comment -> comment-reply / maintainer-reply.
: > "$METRICS"
payload 'gh issue comment 7 --body "thanks"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq comment-reply "$(jq -r .boundary <<<"$(last_row)")" "gh issue comment: boundary"
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" "gh issue comment: recipe"

# 8e. glab mr/issue note and glab mr discussion note -> comment-reply.
: > "$METRICS"
payload 'glab mr note 4 --message "ok"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq comment-reply "$(jq -r .boundary <<<"$(last_row)")" "glab mr note: boundary"
: > "$METRICS"
payload 'glab issue note 4 --message "ok"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq comment-reply "$(jq -r .boundary <<<"$(last_row)")" "glab issue note: boundary"
: > "$METRICS"
payload 'glab mr discussion note 4 abc --message "ok"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq comment-reply "$(jq -r .boundary <<<"$(last_row)")" "glab mr discussion note: boundary"

# 8f. Inline review-comment reply via gh api POST -> pr-review-comment / pr-review-reply.
: > "$METRICS"
out=$(payload 'gh api repos/o/r/pulls/12/comments -X POST -f body="Applied in abc123" -F in_reply_to=99' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq pr-review-comment "$(jq -r .boundary <<<"$(last_row)")" "gh api POST comment: boundary"
assert_eq pr-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" "gh api POST comment: recipe"
assert_contains 'pr-review-reply' "$out" "gh api POST comment: nudge names recipe"

# 8f-bis. The equals-assignment method forms (gh CLI / pflag accept both) also count.
: > "$METRICS"
payload 'gh api repos/o/r/pulls/12/comments --method=POST -f body="x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-review-comment "$(jq -r .boundary <<<"$(last_row)")" "gh api --method=POST: boundary"
: > "$METRICS"
payload 'gh api repos/o/r/pulls/12/comments -X=POST -f body="x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-review-comment "$(jq -r .boundary <<<"$(last_row)")" "gh api -X=POST: boundary"

# 8f-ter. An issue-comment POST via the API (.../issues/<n>/comments) is scoped
# out of the pr-review-comment boundary, so it is not misread as pr-review-reply.
: > "$METRICS"
ec=0
out=$(payload 'gh api repos/o/r/issues/12/comments -X POST -f body="x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "gh api issues-comment POST: exit 0 (not a boundary)"
assert_eq 0 "$(nrows)" "gh api issues-comment POST: no row (not misread as pr-review-comment)"

# 8g. The read-only fetch step (gh api .../comments --jq, no -X POST) is NOT a boundary.
: > "$METRICS"
ec=0
out=$(payload 'gh api repos/o/r/pulls/12/comments --jq ".[].body"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "gh api fetch: exit 0"
assert_eq "" "$out" "gh api fetch: no nudge"
assert_eq 0 "$(nrows)" "gh api fetch: no row (read-only, not a boundary)"

# 8b. Combined short flags (-am, -aF) author a message inline -> still a boundary.
: > "$METRICS"
payload 'git commit -am "fix: thing"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "combined -am flag: detected as git-commit boundary"

# 9. git commit --amend --no-edit: reuses a message, not a boundary.
: > "$METRICS"
ec=0
out=$(payload 'git commit --amend --no-edit' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "amend: exit 0"
assert_eq "" "$out" "amend: no nudge"
assert_eq 0 "$(nrows)" "amend: no row"

# 10. enforce mode: blocks with a deny decision.
: > "$METRICS"
out=$(payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_BOUNDARY_MODE=enforce bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "enforce: deny decision"
assert_contains 'commit-message' "$out" "enforce: names recipe in reason"

# 11. off mode: no nudge, but the opportunity row is still recorded (measure-only).
: > "$METRICS"
out=$(payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_BOUNDARY_MODE=off bash "$HOOK")
assert_eq "" "$out" "off: no nudge"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "off: row still written"

# 12. DELEGATE_LOCAL_NO_METRICS=1: nudge still fires, no row written.
: > "$METRICS"
out=$(payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_LOCAL_NO_METRICS=1 bash "$HOOK")
assert_contains 'additionalContext' "$out" "no-metrics: still nudges"
assert_eq 0 "$(nrows)" "no-metrics: no row written"

# 13. Custom window honoured (1-minute window, 5-minute-old delegation -> missed).
# The row matches on project AND recipe so the out-of-window timestamp is the
# sole reason it is not counted — otherwise the recipe filter would exclude it
# regardless of the window and the test would pass for the wrong reason.
: > "$METRICS"
oldish=$(jq -rn --argjson now "$(date -u +%s)" '($now - 300) | todateiso8601')
jq -nc --arg ts "$oldish" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_BOUNDARY_WINDOW_MIN=1 bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "custom window: 5m-old delegation outside 1m window"

# --- #342 defect 2: the classifier must only see leading tokens -----------

# 14a. A heredoc write whose BODY mentions a boundary command is not a boundary.
# This is the reported false positive: writing an issue about `gh pr create`
# fired a pr-create nudge, because the classifier matched the whole string.
: > "$METRICS"
ec=0
out=$(payload "$(printf 'cat > issue-facts.md <<%s\nThe fix is to run gh pr create --title t --body b\nEOF' "'EOF'")" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "heredoc mentioning gh pr create: exit 0"
assert_eq "" "$out" "heredoc mentioning gh pr create: no nudge"
assert_eq 0 "$(nrows)" "heredoc mentioning gh pr create: no row (body is data, not a command)"

# 14b. A heredoc body mentioning `git commit -m` likewise.
: > "$METRICS"
out=$(payload "$(printf 'cat >> notes.md <<%s\ngit commit -m "example"\nEOF' "'EOF'")" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "heredoc mentioning git commit: no nudge"
assert_eq 0 "$(nrows)" "heredoc mentioning git commit: no row"

# 14c. Quoted prose mentioning a boundary command is not a boundary either.
: > "$METRICS"
out=$(payload 'echo "next step: gh issue create --body something"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "quoted prose: no nudge"
assert_eq 0 "$(nrows)" "quoted prose: no row"

# 14c-i. An ODD number of backslash-escaped quotes inside the prose must not
# flip quote parity. Before the escape handling this closed quote-mode early,
# so the ';' started a fresh segment and 'gh pr create' was scanned as live
# shell — the #342 false positive, reintroduced through a different door.
: > "$METRICS"
out=$(payload 'echo "the flag is \" ; gh pr create --title x --body y"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "escaped quote in prose: no nudge"
assert_eq 0 "$(nrows)" "escaped quote in prose: no row"

# 14c-ii. Even parity was already safe; keep it covered so a future rewrite of
# the scanner cannot fix one case by breaking the other.
: > "$METRICS"
out=$(payload 'echo "the flag is \" and \" ; gh pr create --title x --body y"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "paired escaped quotes in prose: no nudge"
assert_eq 0 "$(nrows)" "paired escaped quotes in prose: no row"

# 14c-iii. Escaping must not swallow a real boundary: a commit message with an
# escaped quote is still a git-commit opportunity.
: > "$METRICS"
payload 'git commit -m "fix: handle a \" in input"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "escaped quote in commit message: still git-commit"

# 14d. A commit message that TALKS about another boundary still classifies as the
# commit it is — quoted content never contributes to classification.
: > "$METRICS"
payload 'git commit -m "docs: explain gh pr create usage"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "commit message mentioning gh pr create: still git-commit"
assert_eq 1 "$(nrows)" "commit message mentioning gh pr create: exactly one row"

# 14e. Real boundaries still classify when they are not the first token of the
# command: after a `&&`, and inside a command substitution.
: > "$METRICS"
payload 'cd /tmp/repo && git commit -m "fix: thing"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "git commit after &&: still a boundary"
: > "$METRICS"
payload 'url=$(gh pr create --title t --body b)' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-create "$(jq -r .boundary <<<"$(last_row)")" "gh pr create in a command substitution: still a boundary"

# 14f. A real boundary that USES a heredoc keeps classifying — its flags all
# precede the redirect, so cutting the body loses nothing.
: > "$METRICS"
payload "$(printf 'gh pr create --title t --body-file - <<%s\nbody text\nEOF' "'EOF'")" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-create "$(jq -r .boundary <<<"$(last_row)")" "gh pr create with a heredoc body: still a boundary"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "gh pr create with a heredoc body: delegated=false (- is not a file)"

# --- #349: a body read from an existing file is pre-drafted, not missed ----
mkdir -p "$tmpcwd/drafts"
printf 'already drafted and approved\n' > "$tmpcwd/drafts/body.md"

# 15a. gh issue create --body-file <existing file>: no nudge, state=pre-drafted.
: > "$METRICS"
ec=0
out=$(payload 'gh issue create --title t --body-file drafts/body.md' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "issue-create --body-file existing: exit 0"
assert_eq "" "$out" "issue-create --body-file existing: no nudge (drafting moment already passed)"
assert_eq issue-create "$(jq -r .boundary <<<"$(last_row)")" "issue-create --body-file existing: boundary still recorded"
assert_eq pre-drafted "$(jq -r .state <<<"$(last_row)")" "issue-create --body-file existing: state=pre-drafted"

# 15b. The -F shorthand behaves the same.
: > "$METRICS"
out=$(payload 'gh issue comment 7 -F drafts/body.md' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "comment-reply -F existing: no nudge"
assert_eq pre-drafted "$(jq -r .state <<<"$(last_row)")" "comment-reply -F existing: state=pre-drafted"

# 15c. gh pr comment --body-file <existing file>: same.
: > "$METRICS"
out=$(payload "gh pr comment 12 --body-file $tmpcwd/drafts/body.md" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "pr comment --body-file (absolute) existing: no nudge"
assert_eq pre-drafted "$(jq -r .state <<<"$(last_row)")" "pr comment --body-file (absolute) existing: state=pre-drafted"

# 15c-i. `gh api -F body=@file` is the form used to post an inline PR review
# reply, and it is the same already-drafted situation as --body-file. Observed
# live: a maintainer session posting an approved reply this way still recorded
# delegated:false, which is the metric noise #349 is about.
: > "$METRICS"
out=$(payload "gh api repos/o/r/pulls/355/comments -X POST -F body=@$tmpcwd/drafts/body.md -F in_reply_to=1" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "gh api -F body=@existing: no nudge"
assert_eq pre-drafted "$(jq -r .state <<<"$(last_row)")" "gh api -F body=@existing: state=pre-drafted"

# 15c-ii. A delegation inside the window beats pre-drafted: delegate → save →
# post is the workflow the nudge asks for, and recording it as delegated:false
# removed the sensor's best outcome from both sides of the ratio.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", recipe:"pr-description", project:$p}' >> "$METRICS"
out=$(payload "gh pr create --title t --body-file $tmpcwd/drafts/body.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "delegated + body-file: no nudge"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "delegated + body-file: delegated=true"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "delegated + body-file: delegated supersedes pre-drafted"

# 15c-iii. A body-file post in a LATER segment must not mark an inline post in
# an earlier one as pre-drafted — that suppressed a real nudge and deleted the
# row from the metric, which is worse than the deflation #349 reports.
: > "$METRICS"
out=$(payload "gh issue comment 1 --body \"inline reply\" && gh issue comment 2 --body-file $tmpcwd/drafts/body.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "delegate-local" "$out" "cross-segment body-file: inline post still nudges"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "cross-segment body-file: no pre-drafted state"

# 15c-iv. Prose naming a body flag inside a quoted message is data, not a flag.
: > "$METRICS"
out=$(payload "git commit -m \"docs: see --body-file drafts/body.md for the template\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "delegate-local" "$out" "prose naming --body-file: still nudges"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "prose naming --body-file: no pre-drafted state"

# 15c-v. `git commit -F <file>` is NOT the #349 case: that is the standard way
# an agent commits a message it composed itself moments earlier, which is
# exactly the drafting moment the hook exists to catch.
: > "$METRICS"
out=$(payload "git commit -F $tmpcwd/drafts/body.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "delegate-local" "$out" "git commit -F: still nudges"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "git commit -F: not pre-drafted"

# 15c-vi. A heredoc write followed by a real boundary in the same call: the
# body is data and must not classify, but the command AFTER the terminator is
# a genuine opportunity. Breaking at the first `<<` dropped it entirely.
: > "$METRICS"
payload "cat > $tmpcwd/b.md <<'EOF'
some body text
EOF
gh issue create --title t --body-file $tmpcwd/b.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq issue-create "$(jq -r .boundary <<<"$(last_row)")" "heredoc then post: the post still classifies"

# 15c-vii. Wrapper and prefix tokens are still real boundaries. Anchoring each
# pattern at segment start dropped all of these, and bought nothing once the
# quoted spans and heredoc bodies were already stripped.
for prefixed in \
  "sudo gh pr create --title t --body b" \
  "timeout 30 gh pr create --title t --body b" \
  "GIT_AUTHOR_NAME=x git commit -m \"msg\"" \
  "for f in a b; do git commit -m \"msg\"; done"; do
  : > "$METRICS"
  payload "$prefixed" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq 1 "$(nrows)" "wrapped boundary classifies: ${prefixed:0:28}"
done

# 15d. An INLINE --body is still the drafting moment: nudge, no state.
: > "$METRICS"
out=$(payload 'gh issue comment 7 --body "thanks for the report"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'maintainer-reply' "$out" "inline --body: still nudges"
assert_eq null "$(jq -r '.state // null' <<<"$(last_row)")" "inline --body: no state (ordinary missed opportunity)"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "inline --body: delegated=false"

# 15e. --body-file pointing at a file that does NOT exist is not pre-drafted.
: > "$METRICS"
out=$(payload 'gh issue create --title t --body-file drafts/nope.md' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'github-issue-body' "$out" "--body-file missing file: still nudges"
assert_eq null "$(jq -r '.state // null' <<<"$(last_row)")" "--body-file missing file: no state"

# 15f. gh api's -F is a field assignment, not a body file — must not pre-draft.
: > "$METRICS"
out=$(payload 'gh api repos/o/r/pulls/12/comments -X POST -f body="x" -F in_reply_to=99' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'pr-review-reply' "$out" "gh api -F field: still nudges"
assert_eq null "$(jq -r '.state // null' <<<"$(last_row)")" "gh api -F field: no state"

# 14. Fail-open on malformed stdin.
ec=0
out=$(echo 'not json' | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "malformed stdin: exit 0 (fail-open)"

# 15. The nudge must name a command that actually RUNS. Every boundary recipe
# declares required inputs and delegate.sh exits 2 when one is missing, so a
# nudge that names only the recipe sent the agent into a hard error and the
# delegation never happened. The keys come from the recipe's own frontmatter.
: > "$METRICS"
out=$(payload 'git commit -m "fix: thing"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains '--var recent_commits=' "$out" "nudge: names required var recent_commits"
assert_contains '--var diff_stat=' "$out" "nudge: names required var diff_stat"
assert_contains '--var why=' "$out" "nudge: names required var why"
assert_contains 'commit-message --var' "$out" "nudge: vars follow the recipe name"
# `type: string?` is optional — naming it would imply it is required.
if [[ "$out" != *'--var type='* ]]; then
  echo "  PASS  nudge: omits optional input 'type'"; pass=$((pass+1))
else
  echo "  FAIL  nudge: omits optional input 'type'"; fail=$((fail+1))
fi
# The nudge names NO tier (#411). It used to emit a concrete one so the agent
# did not have to guess at the `<tier>` stand-in, but the recipe now declares its
# own in frontmatter, so a tier here would re-teach a slot that no longer exists
# in the documented invocation — and 39 of the 44 recorded bad-tier calls came
# from exactly that slot.
if [[ "$out" != *' prose'* && "$out" != *' code'* && "$out" != *' reasoning'* ]]; then
  echo "  PASS  nudge: names no tier (the recipe declares it)"; pass=$((pass+1))
else
  echo "  FAIL  nudge: still names a tier — the recipe declares it now"; fail=$((fail+1))
fi
if [[ "$out" != *'<tier>'* ]]; then
  echo "  PASS  nudge: no unreplaced <tier> stand-in"; pass=$((pass+1))
else
  echo "  FAIL  nudge: no unreplaced <tier> stand-in"; fail=$((fail+1))
fi

# 16. A recipe declaring `stdin` gets an input redirection, not a --var, and
# its optional inputs stay out.
: > "$METRICS"
out=$(payload 'gh pr comment 42 --body "thanks"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains '--var ask=' "$out" "stdin recipe: names required var ask"
assert_contains '< context.txt' "$out" "stdin recipe: stdin becomes a redirection"
if [[ "$out" != *'--var stdin='* ]]; then
  echo "  PASS  stdin recipe: stdin is not passed as a --var"; pass=$((pass+1))
else
  echo "  FAIL  stdin recipe: stdin is not passed as a --var"; fail=$((fail+1))
fi
if [[ "$out" != *'--var recipient='* && "$out" != *'--var signoff='* ]]; then
  echo "  PASS  stdin recipe: omits optional recipient/signoff"; pass=$((pass+1))
else
  echo "  FAIL  stdin recipe: omits optional recipient/signoff"; fail=$((fail+1))
fi

# 17. script_dir is resolved before the cd to the payload cwd. Invoked by a
# RELATIVE path from an unrelated directory, the recipe lookup must still find
# prompts/ — resolving it late produced <payload-cwd>/scripts/../prompts and
# silently degraded the nudge back to the unrunnable form.
: > "$METRICS"
out=$(cd "$REPO" && payload 'git commit -m "fix: thing"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash scripts/delegate-boundary-hook.sh)
assert_contains '--var why=' "$out" "relative invocation: still resolves prompts/"

# 18. The project value is quoted in the rendered command. A checkout directory
# with a space in its name would otherwise split into two arguments and the
# printed command would not run — the exact failure this change exists to end.
spacedir="$tmpcwd/a project"
mkdir -p "$spacedir"
: > "$METRICS"
out=$(payload 'git commit -m "fix: thing"' "$spacedir" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out")
assert_contains '--project "a project"' "$ctx" "spaced project: quoted in the rendered command"

# --- #385: the boundary's repo is the one the command cd's into -------------
# Every test above runs in a cwd that is NOT a git repo, so the git-aware branch
# of the derivation never executes there and a basename-of-path implementation
# would pass all of them while being wrong in production. These build real
# repositories on purpose.
gitroot=$(mktemp -d)
mk_repo() { # dir
  mkdir -p "$1" && ( cd "$1" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && : > f && git add f && git commit -qm init )
}
mk_repo "$gitroot/repo-a" >/dev/null 2>&1
mk_repo "$gitroot/repo-b" >/dev/null 2>&1
mkdir -p "$gitroot/repo-b/sub"
( cd "$gitroot/repo-b" && git worktree add -q "$gitroot/wt-x" -b wtb ) >/dev/null 2>&1
seed_delegation() { # project recipe
  jq -nc --arg ts "$nowts" --arg p "$1" --arg r "$2" \
    '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:$r}' >> "$METRICS"
}

# 30. A commit in another repo, reached by a leading cd, is attributed there and
# matches a delegation recorded under that repo.
: > "$METRICS"; seed_delegation repo-b commit-message
out=$(payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq repo-b "$(jq -r .project <<<"$(last_row)")" "cd: project taken from the cd target"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "cd: delegation under the cd target matches"
assert_eq "" "$out" "cd: no nudge when the drafting was delegated"

# 31. A subdirectory of the target still resolves to the repository.
: > "$METRICS"; seed_delegation repo-b commit-message
payload "cd $gitroot/repo-b/sub && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-b "$(jq -r .project <<<"$(last_row)")" "cd: subdirectory resolves to the repo"

# 32. A worktree resolves to the repository, not the worktree directory name.
# `git rev-parse --git-common-dir` is what makes this work; basename-of-path
# would record 'wt-x'.
: > "$METRICS"; seed_delegation repo-b commit-message
payload "cd $gitroot/wt-x && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-b "$(jq -r .project <<<"$(last_row)")" "cd: worktree resolves to the repo"

# 33. A cd to a path that is not a git repository is NOT accepted: recording
# `project:"tmp"` would fragment the trigger-rate denominator across scratch
# keys rather than merely misattributing it to one real repo.
: > "$METRICS"
payload "cd $tmpcwd && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "cd: non-repo target falls back to the cwd"

# 34. A cd to a path that does not exist falls back to the cwd.
: > "$METRICS"
payload "cd $gitroot/no-such-dir && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "cd: missing target falls back to the cwd"

# 35. No cd prefix: behaviour is unchanged.
: > "$METRICS"
payload 'git commit -m x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "no cd: project still from the cwd"

# 36. Either-match guard. --project (#342) exists so a caller can attribute a
# delegation to a repo other than the one it is cd'd into, and those pairings
# match today. Replacing the cwd candidate instead of adding to it would move
# this from working to broken.
: > "$METRICS"; seed_delegation repo-a commit-message
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "cd: a delegation under the cwd project still matches"

# 37. A delegation under neither candidate still counts as missed.
: > "$METRICS"; seed_delegation some-other-repo commit-message
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "cd: unrelated project still records a miss"

# 38. `cd -` must never reach the shell: it resolves to $OLDPWD, which is not
# the boundary's repo and is not knowable from the payload.
: > "$METRICS"
payload "cd - && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "cd -: rejected, falls back to the cwd"

# 39. A path carrying a shell expansion is rejected rather than expanded. The
# hook must never evaluate agent-supplied text.
: > "$METRICS"
payload 'cd $(echo /tmp) && git commit -m x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "cd \$(...): rejected, not expanded"

# 40. A quoted path containing a space is parsed. The scan surface blanks quoted
# spans, which is why this parse runs on the raw command.
mk_repo "$gitroot/a repo" >/dev/null 2>&1
: > "$METRICS"
payload "cd \"$gitroot/a repo\" && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "a repo" "$(jq -r .project <<<"$(last_row)")" "cd: quoted path with a space is parsed"

# 41. A heredoc body that merely mentions a cd cannot retarget the boundary: the
# parse is anchored at the start of the command.
: > "$METRICS"
payload "git commit -F - <<'EOF'
cd $gitroot/repo-b && git commit -m x
EOF" "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "heredoc mentioning cd: not retargeted"

# --- an explicit --repo widens the LOOKUP only ------------------------------
# `gh issue comment --repo owner/other` carries no cd, so the boundary is filed
# under the session cwd. Replaying the whole metrics file showed that also
# RECORDING the --repo name buys no extra recall (the either-match set is the
# same) while adding four `rate=0%` project keys and moving 22 rows off two real
# projects, mostly from hub-repo sweeps of the form
# `gh pr comment N --repo IsmaelMartinez/<other> --body "@dependabot rebase"`.
# So the candidate joins the lookup and never touches `project`.

# 42. A delegation recorded under the repo the command names is matched, while
# the recorded project stays the session cwd.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload "gh issue comment 1 --repo owner/repo-b --body x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "--repo: delegation under the named repo matches"
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "--repo: recorded project stays the cwd"

# 43. `--repo=owner/name` and `-R owner/name` are the same flag.
for form in "--repo=owner/repo-b" "-R owner/repo-b"; do
  : > "$METRICS"; seed_delegation repo-b maintainer-reply
  payload "gh issue comment 1 $form --body x" "$gitroot/repo-a" \
    | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "--repo: $form form matches"
done

# 44. A shell variable in the value must be REJECTED, not used. This is the
# validation's security job: 11 of 534 real invocations carry one, and a
# last-segment-only check would happily accept `IsmaelMartinez/$1`.
for bad in 'IsmaelMartinez/$1' '$R' 'owner/`whoami`' 'owner/../../etc' 'noslash'; do
  : > "$METRICS"; seed_delegation repo-b maintainer-reply
  payload "gh issue comment 1 --repo $bad --body x" "$gitroot/repo-a" \
    | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: rejects '$bad'"
done

# 45. A bare --repo with no value, and --repo followed by another flag, fall
# back cleanly rather than consuming the flag as a repo name.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload "gh issue comment 1 --body x --repo" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: bare flag falls back"
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload "gh issue comment 1 --repo --body x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: does not consume a following flag"

# 46. A trailing slash and a .git suffix are trimmed.
for form in "owner/repo-b/" "owner/repo-b.git"; do
  : > "$METRICS"; seed_delegation repo-b maintainer-reply
  payload "gh issue comment 1 --repo $form --body x" "$gitroot/repo-a" \
    | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "--repo: trims '$form'"
done

# 47. A quoted value is blanked by the scan surface and falls back. This is the
# opposite trade-off from the cd block, which reads the raw command precisely so
# it can parse quoted paths. 6 of 534 real invocations; it fails safe.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload 'gh issue comment 1 --repo "owner/repo-b" --body x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: quoted value falls back (known trade-off)"

# 48. A --repo inside the quoted body cannot reach the parse.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload 'gh issue comment 1 --repo owner/repo-c --body "see --repo owner/repo-b"' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: value inside a quoted body is not parsed"

# 49. Precedence when both a leading cd and a --repo are present: the cd target
# owns the RECORDED project, and both are candidates for the lookup.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload "cd $gitroot/repo-b && gh issue comment 1 --repo owner/repo-c --body x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-b "$(jq -r .project <<<"$(last_row)")" "cd + --repo: cd target owns the recorded project"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "cd + --repo: cd target still matches the lookup"

# 49b. GitLab's three-part path must keep working. `glab --repo` accepts
# "OWNER/REPO or GROUP/NAMESPACE/REPO" per its own --help, and the hook
# classifies glab boundaries, so the value regex deliberately allows more than
# one slash and the project is the FINAL segment. Do not tighten this to a
# single slash: it would silently drop GitLab support.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload "glab mr note 1 --repo group/namespace/repo-b --message x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "--repo: glab GROUP/NAMESPACE/REPO resolves to the final segment"

# 50. A delegate row carrying no project at all must not match a boundary whose
# --repo candidate is empty. Three such rows exist in the real metrics file; an
# unguarded `(.project // "") == $proj3` would let each of them mark every
# boundary in its window as delegated.
: > "$METRICS"
jq -nc --arg ts "$nowts" '{ts:$ts, source:"delegate", tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "projectless delegate row does not match an empty --repo candidate"

# 51. Credit consumption: one delegation credits exactly one post. The second
# post of the same project+recipe finds the credit spent by the first post's
# delegated:true opportunity row and records a miss, so the wide default
# window cannot silence an afternoon of nudges off one morning delegation.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "consumption: first post spends the credit"
payload 'git commit -m "y"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "consumption: second post finds no credit left"

# 52. Batch flow: three delegations credit three posts, the fourth misses.
: > "$METRICS"
for i in 1 2 3; do
  jq -nc --arg ts "$nowts" --arg p "$proj" \
    '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
done
for i in 1 2 3; do
  payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "batch: post $i of 3 credited"
done
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "batch: post 4 exceeds the 3 credits"

# 53. Wide default window: a 3-hour-old delegation still credits, covering the
# delegate-then-await-approval batch flow that the old 10-minute default
# recorded as missed (measured 2026-08-25: a sweep took >4h to post).
: > "$METRICS"
threehrs=$(jq -rn --argjson now "$(date -u +%s)" '($now - 10800) | todateiso8601')
jq -nc --arg ts "$threehrs" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "default window: 3h-old delegation credits"

# 54. Consumption is per project+recipe: a delegated:true row for a different
# recipe does not spend this recipe's credit.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"opportunity", boundary:"pr-create", suggested_recipe:"pr-description", delegated:true, project:$p}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "consumption: other-recipe credit spend does not count"

# 55. Tail depth: a delegate row buried under 600 newer rows must still credit.
# Truncation drops the oldest rows first, which are the earning delegate rows,
# while the opportunity rows that spend them survive — so a too-small tail
# reads as spent > earned and denies credit. Pins the 2000-line read depth.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
jq -nc --arg ts "$nowts" 'range(600) | {ts:$ts, source:"opportunity", boundary:"comment-reply", suggested_recipe:"maintainer-reply", delegated:false, project:"unrelated-filler"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "tail depth: delegate row under 600 filler rows still credits"

( cd "$gitroot/repo-b" && git worktree remove --force "$gitroot/wt-x" ) >/dev/null 2>&1
rm -rf "$gitroot"

# 56. pr-review-body — a maintainer's PR review body routes to
# maintainer-review-reply, not maintainer-reply. Before 2026-08-26 `gh pr review`
# cleared the pre-filter and matched no branch at all, so the most common way a
# maintainer posts a judgement produced no row and no nudge, while
# maintainer-review-reply sat at n=0 calls behind two rounds of prose routing.
: > "$METRICS"
payload 'gh pr review 2822 --comment --body "the rework is right and this is not a regression"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "pr-review-body" "$(jq -r .boundary <<<"$(last_row)")" \
  "pr-review-body: gh pr review --body is a boundary"
assert_eq "maintainer-review-reply" "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "pr-review-body: it routes to maintainer-review-reply"
# The nudge has to name the recipe, since naming it is the whole point.
out=$(payload 'gh pr review 2822 --comment --body "x"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "--recipe maintainer-review-reply" "$out" \
  "pr-review-body: the nudge names maintainer-review-reply"

# 57. The reviews ENDPOINT is the same boundary; the comments endpoint is not.
# `/pulls/<n>/reviews` is a review body, `/pulls/<n>/comments` is an inline
# reply under someone else's comment, which stays pr-review-reply.
: > "$METRICS"
payload 'gh api repos/o/r/pulls/12/reviews -X POST -f body=hello -f event=COMMENT' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "maintainer-review-reply" "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "pr-review-body: the reviews endpoint routes to maintainer-review-reply"
: > "$METRICS"
payload 'gh api repos/o/r/pulls/12/comments -X POST -f body=hello -F in_reply_to=1' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "pr-review-reply" "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "pr-review-body: the comments endpoint is untouched"

# 57-i. The API form carries the same inline-body requirement as the CLI form.
# An approval POST with no body= field has no text to intercept, so nudging for
# one would ask the agent to draft a message it is never going to write.
: > "$METRICS"
payload 'gh api repos/o/r/pulls/12/reviews -X POST -f event=APPROVE' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq 0 "$(nrows)" "pr-review-body: a reviews POST with no body= writes no row"

# 58. A short status comment still routes to the closed shape. This is the
# assertion that stops the fix from simply swallowing the other recipe.
: > "$METRICS"
payload 'gh pr comment 2822 --body "thanks, merged"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "comment-reply" "$(jq -r .boundary <<<"$(last_row)")" \
  "pr-review-body: gh pr comment is still comment-reply"
assert_eq "maintainer-reply" "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "pr-review-body: gh pr comment still routes to maintainer-reply"

# 59. No inline body, no drafting moment. A bare approve or an editor/--web
# review has nothing to intercept, same reasoning as commit --amend.
: > "$METRICS"
payload 'gh pr review 2822 --approve' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq 0 "$(nrows)" "pr-review-body: a bare --approve writes no row"
payload 'gh pr review 2822 --web' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq 0 "$(nrows)" "pr-review-body: --web writes no row"

# ---------------------------------------------------------------------------
# 58. comment-reply routes by how much is being posted. The two candidates are
# different SHAPES, not different qualities: `maintainer-reply` caps its prose
# body at two sentences, `maintainer-review-reply` sets its length by the
# evidence it carries. Pinning the first unconditionally is how it came to hold
# 33 delegations at 21% usable.
# ---------------------------------------------------------------------------
long_body=$(python3 -c "print('The sandbox flag in src/main.js is the cause and not your distro. ' * 12)")

# 58a. A short inline body keeps the closed short shape.
: > "$METRICS"
payload 'gh pr comment 12 --body "The token drop is on Teams side. Could you check a cold start?"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a short body keeps maintainer-reply"

# 58b. A long inline body names the evidence-led recipe instead.
: > "$METRICS"
out=$(payload "gh pr comment 12 --body \"$long_body\"" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a long body names maintainer-review-reply"
assert_contains 'maintainer-review-reply' "$out" \
  "comment-reply: the nudge names the recipe it routed to"
assert_contains '--var verdict=' "$out" \
  "comment-reply: the nudge carries the routed recipe's own vars"

# 58c. --body-file is measured from the file, not from the path.
: > "$METRICS"
printf '%s' "$long_body" > "$tmpcwd/long.md"
payload "gh pr comment 12 --body-file $tmpcwd/long.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: --body-file is measured from the file"
: > "$METRICS"
printf 'two short sentences. and an ask?' > "$tmpcwd/short.md"
payload "gh pr comment 12 --body-file $tmpcwd/short.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a short --body-file keeps the short shape"

# 58d. A file that cannot be read must not promote the reply on no evidence.
: > "$METRICS"
payload "gh pr comment 12 --body-file $tmpcwd/does-not-exist.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: an unreadable body-file falls back to the short shape"

# 58d-ii. Only a REGULAR file is read. This runs inside a PreToolUse hook on
# every Bash call, and `wc -c < /dev/zero` never returns; a directory or a FIFO
# would be just as wrong, if less dramatic.
: > "$METRICS"
payload "gh pr comment 12 --body-file /dev/zero" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" perl -e 'alarm 15; exec @ARGV' bash "$HOOK" >/dev/null 2>&1
ec=$?
# perl's alarm rather than `timeout`, which is GNU coreutils and absent on the
# macOS baseline; perl is already a hard dependency here. A regression makes
# this exit 142 (SIGALRM) instead of hanging the suite.
assert_eq 0 "$ec" "comment-reply: a character device is not read as a body file"
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a character device falls back to the short shape"
: > "$METRICS"
payload "gh pr comment 12 --body-file $tmpcwd" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a directory is not read as a body file"

# 58d-iii. A quoted path is still a path, and trailing shell punctuation is not
# part of it.
: > "$METRICS"
payload "gh pr comment 12 --body-file \"$tmpcwd/long.md\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a quoted --body-file path is measured"
: > "$METRICS"
payload "gh pr comment 12 --body-file $tmpcwd/long.md; echo done" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: trailing shell punctuation is not part of the path"

# 58e. The threshold is overridable, so the routing can be re-tuned from the
# corpus without editing the hook.
: > "$METRICS"
payload 'gh pr comment 12 --body "short enough by default"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_BOUNDARY_LONG_BODY_CHARS=10 bash "$HOOK" >/dev/null
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: DELEGATE_BOUNDARY_LONG_BODY_CHARS moves the split"

# 58f. glab's --message carries the same routing.
: > "$METRICS"
payload "glab mr note 4 --message \"$long_body\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: glab --message routes the same way"

# 58g. The OTHER boundaries are untouched — a long PR-review-comment body is
# still pr-review-reply, because that branch matches before this one.
: > "$METRICS"
payload "gh api repos/o/r/pulls/12/comments -X POST -f body=\"$long_body\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: the inline review-comment branch still wins on a long body"

echo
echo "delegate-boundary-hook: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
