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

# A throwaway cwd that IS a git repository, so the hook derives its basename
# as the project — a stable, known name. Until #476 this directory was
# deliberately NOT a repository and the suite leaned on the fallback that
# invented a project out of `pwd`; that fallback is the bug, and outside a
# repository the hook now records no project at all (asserted in the #476
# block below). `mk_repo` makes a real one with a commit, which the #385
# worktree case needs.
mk_repo() { # dir
  mkdir -p "$1" && ( cd "$1" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && : > f && git add f && git commit -qm init )
}
tmpcwd=$(mktemp -d)
mk_repo "$tmpcwd" >/dev/null 2>&1
proj=$(basename "$tmpcwd")
METRICS=$(mktemp)
# The #385 and #476 blocks below create $gitroot and $norepo; initialised
# here so the trap owns their cleanup too, and a failing assertion or an
# early exit cannot leave them behind (`set -u` would otherwise fault on the
# expansion). The suite's own environment must not leak in either:
# DELEGATE_PROJECT would rename every row the hook records.
gitroot="" norepo=""
unset DELEGATE_PROJECT
unset DELEGATE_BOUNDARY_MODE DELEGATE_BOUNDARY_ENFORCE
# Since #483 the four proven boundaries DENY by default, and only while a
# provider is reachable, so the whole suite runs against one pinned provider
# state rather than whatever daemon the developer happens to have up: a mock
# `curl` first on PATH answers `GET /models` on port 8080 with one prose-tier
# model and refuses everything else (exit 7, curl's failed-to-connect), and the
# per-user override config is pointed at a non-file so it cannot reorder the
# prefs. The mock also records every call in $MOCKDIR/probed, so a test can
# assert the probe did NOT run on a path that must stay cheap.
MOCKDIR=$(mktemp -d)
cat > "$MOCKDIR/curl" <<'EOF'
#!/usr/bin/env bash
: >> "$(dirname "$0")/probed"
for a in "$@"; do
  case "$a" in
    *:8080/*) printf '{"object":"list","data":[{"id":"qwen3.6:35b-a3b-q8_0","object":"model"}]}'; exit 0 ;;
  esac
done
exit 7
EOF
chmod +x "$MOCKDIR/curl"
export PATH="$MOCKDIR:$PATH"
export DELEGATE_BASE_URL=http://localhost:8080/v1
export DELEGATE_LOCAL_CONFIG=/dev/null
# The pre-#483 tests post placeholder bodies (`--body x`, `-m "fix: thing"`)
# to exercise classification, routing and the lookup, none of which the
# body-length floor is about; a 120-character floor would silence every one
# of them. The floor is pinned off here and tested at its default in the #483
# block below.
export DELEGATE_BOUNDARY_MIN_CHARS=0
trap 'rm -rf "$tmpcwd" "$METRICS" "$gitroot" "$norepo" "$MOCKDIR"' EXIT
nowts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The harness hands every hook the session id (the transcript UUID); the same
# value reaches delegate.sh as CLAUDE_CODE_SESSION_ID and is written on its
# row as `session` (#479). Tests that need another session pass it as $3; an
# explicit "" is kept (so `${3-…}`, not `${3:-…}`) to model a payload without one.
payload() { # cmd  cwd  [session_id]
  jq -nc --arg cmd "$1" --arg cwd "$2" --arg sid "${3-sess-A}" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, session_id:$sid, tool_input:{command:$cmd}}'
}
last_row() { tail -1 "$METRICS"; }
nrows() { local n; n=$(grep -c . "$METRICS" 2>/dev/null) || true; echo "${n:-0}"; }
# The reminder text, whichever channel carried it: additionalContext on the
# warn path, permissionDecisionReason on the deny path. Tests about the TEXT
# read it through this so they do not also pin the channel.
hook_msg() { jq -r '.hookSpecificOutput | .additionalContext // .permissionDecisionReason // empty' <<<"$1"; }

# 1. Non-boundary command: silent, no row.
: > "$METRICS"
ec=0
out=$(payload "ls -la" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "non-boundary: exit 0"
assert_eq "" "$out" "non-boundary: no stdout"
assert_eq 0 "$(nrows)" "non-boundary: no metrics row"

# 2. git commit, no prior delegation: DENIED (#483 — git-commit is one of the
# four enforced-by-default boundaries) with the reminder as the reason, plus a
# delegated:false opportunity row.
: > "$METRICS"
out=$(payload 'git commit -m "fix: thing"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "commit/no-delegation: denied by default (#483)"
assert_contains '"permissionDecisionReason"' "$out" "commit/no-delegation: the reminder is the deny reason"
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

# 12. DELEGATE_LOCAL_NO_METRICS=1: the reminder still fires, no row written —
# and it cannot deny (PR #484 review, item E): with metrics off no credit can
# ever be written where the hook reads, so a deny would be a permanent block.
: > "$METRICS"
out=$(payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_LOCAL_NO_METRICS=1 bash "$HOOK")
assert_contains 'commit-message' "$(hook_msg "$out")" "no-metrics: still nudges"
assert_contains '"permissionDecision":"allow"' "$out" "no-metrics: never denies (no credit could be recorded)"
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

# --- #465: a body read from an existing file is a counted opportunity -----
# It used to be excluded as state:"pre-drafted" (#349). The hook cannot tell an
# approved body file from one the agent wrote a Bash call earlier, and the very
# same act WAS counted whenever the write and the post shared a call, so the
# rate moved with shell batching rather than with behaviour.
mkdir -p "$tmpcwd/drafts"
printf 'already drafted and approved\n' > "$tmpcwd/drafts/body.md"

# 15a. gh issue create --body-file <existing file>: nudges, no state.
: > "$METRICS"
ec=0
out=$(payload 'gh issue create --title t --body-file drafts/body.md' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "issue-create --body-file existing: exit 0"
assert_contains 'github-issue-body' "$out" "issue-create --body-file existing: nudges"
assert_eq issue-create "$(jq -r .boundary <<<"$(last_row)")" "issue-create --body-file existing: boundary recorded"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "issue-create --body-file existing: no state"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "issue-create --body-file existing: counted as missed"

# 15a-bis. The SAME post written and posted in one Bash call — the shape that
# exposed the inconsistency — now records identically. Batching must not move
# the row into a different bucket.
: > "$METRICS"
payload "cat > $tmpcwd/drafts/inline.md <<'EOF'
already drafted and approved
EOF
gh issue create --title t --body-file $tmpcwd/drafts/inline.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "same-call write+post: no state, same as the two-call form"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "same-call write+post: counted as missed, same as the two-call form"

# 15b. The -F shorthand behaves the same.
: > "$METRICS"
out=$(payload 'gh issue comment 7 -F drafts/body.md' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'maintainer' "$out" "comment-reply -F existing: nudges"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "comment-reply -F existing: no state"

# 15c. gh pr comment --body-file <existing file>: same.
: > "$METRICS"
out=$(payload "gh pr comment 12 --body-file $tmpcwd/drafts/body.md" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'maintainer' "$out" "pr comment --body-file (absolute) existing: nudges"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "pr comment --body-file (absolute) existing: no state"

# 15c-i. `gh api -F body=@file` is the form used to post an inline PR review
# reply, and it is now a counted opportunity like every other body-file post.
: > "$METRICS"
out=$(payload "gh api repos/o/r/pulls/355/comments -X POST -F body=@$tmpcwd/drafts/body.md -F in_reply_to=1" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'pr-review-reply' "$out" "gh api -F body=@existing: nudges"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "gh api -F body=@existing: no state"

# 15c-ii. A delegation inside the window still credits a body-file post:
# delegate → save → post is the workflow the nudge asks for, and recording it
# as delegated:false removed the sensor's best outcome from the ratio.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", recipe:"pr-description", project:$p}' >> "$METRICS"
out=$(payload "gh pr create --title t --body-file $tmpcwd/drafts/body.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "delegated + body-file: no nudge"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "delegated + body-file: delegated=true"

# 15c-iii. Segment scoping still matters for classification: the FIRST segment
# is the one that classifies, so a later body-file post does not change what the
# earlier inline post is recorded as.
: > "$METRICS"
out=$(payload "gh issue comment 1 --body \"inline reply\" && gh issue comment 2 --body-file $tmpcwd/drafts/body.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "delegate-local" "$out" "cross-segment body-file: inline post still nudges"

# 15c-iv. Prose naming a body flag inside a quoted message is data, not a flag.
: > "$METRICS"
out=$(payload "git commit -m \"docs: see --body-file drafts/body.md for the template\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "delegate-local" "$out" "prose naming --body-file: still nudges"

# 15c-v. `git commit -F <file>` nudges like every other boundary.
: > "$METRICS"
out=$(payload "git commit -F $tmpcwd/drafts/body.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "delegate-local" "$out" "git commit -F: still nudges"

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

# 15e. --body-file pointing at a file that does NOT exist behaves the same.
: > "$METRICS"
out=$(payload 'gh issue create --title t --body-file drafts/nope.md' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'github-issue-body' "$out" "--body-file missing file: still nudges"
assert_eq null "$(jq -r '.state // null' <<<"$(last_row)")" "--body-file missing file: no state"

# 15f. gh api's -F is a field assignment, not a body file.
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
# Its own repository (nested repos resolve to the innermost .git), since a bare
# subdirectory of $tmpcwd would now resolve to $tmpcwd's name.
spacedir="$tmpcwd/a project"
mk_repo "$spacedir" >/dev/null 2>&1
: > "$METRICS"
out=$(payload 'git commit -m "fix: thing"' "$spacedir" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
ctx=$(hook_msg "$out")
assert_contains '--project "a project"' "$ctx" "spaced project: quoted in the rendered command"

# --- #385: the boundary's repo is the one the command cd's into -------------
# These need two distinct repositories plus a linked worktree, so that a
# basename-of-path implementation (which would record the worktree directory
# and the cd target's parent alike) cannot pass by accident.
gitroot=$(mktemp -d)
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
mkdir -p "$gitroot/not-a-repo"
: > "$METRICS"
payload "cd $gitroot/not-a-repo && git commit -m x" "$gitroot/repo-a" \
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

# --- #476: a session cwd outside any repository has NO project ---------------
# `/Users/x/projects/gitlab` is the parent folder holding checkouts, not a
# repository. 14 boundaries recorded there on 2026-09-07/08 were filed under
# `project:"gitlab"` at a permanent rate=0%: delegate.sh (delegate_project_name)
# records NO project outside a repository, so a lookup keyed on "gitlab" could
# never match one and every post there was counted as a miss and nudged. The
# #385 refusal above guards the `cd <path> &&` branch; until this fix the
# session-cwd fallback still invented a project out of `pwd`.
norepo=$(mktemp -d)

# 41a. The recorded row carries no project field at all — not the basename,
# not an empty string — the same shape delegate.sh writes from that cwd.
: > "$METRICS"
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq 'has("project")' <<<"$(last_row)")" "no-repo cwd: row carries no project field"
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "no-repo cwd: the boundary is still recorded"

# 41b. The nudge names neither the directory nor any --project at all: the
# command must run as printed (docs/boundary-hook.md), so no `--project ""`
# and no `--project <name>` — bash reads the latter as a redirection — and a
# delegation carrying ANY name could never credit this projectless boundary
# (41d), so omitting the flag is also the only advice that matches.
ctx=$(hook_msg "$out")
case "$ctx" in
  *"$(basename "$norepo")"*) assert_eq "absent" "present" "no-repo cwd: nudge does not name the directory" ;;
  *)                          assert_eq "absent" "absent"  "no-repo cwd: nudge does not name the directory" ;;
esac
case "$ctx" in
  *'--project'*) assert_eq "absent" "present" "no-repo cwd: nudge omits --project when it has no value" ;;
  *)             assert_eq "absent" "absent"  "no-repo cwd: nudge omits --project when it has no value" ;;
esac
assert_contains 'delegate.sh --recipe commit-message' "$ctx" "no-repo cwd: the rendered command is still contiguous"
assert_contains 'commit-message' "$ctx" "no-repo cwd: nudge still names the recipe"

# 41b-ii. When the command names its repo, the nudge has a value to offer and
# renders it quoted: a delegation under that name is a lookup candidate here.
: > "$METRICS"
out=$(payload 'gh issue comment 1 --repo owner/repo-b --body x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
ctx=$(hook_msg "$out")
assert_contains '--project "repo-b"' "$ctx" "no-repo cwd + --repo: nudge renders the --repo candidate as --project"

# 41c. A delegation issued from the same non-repo cwd carries no project
# either, and it is this session's delegation: it must credit the boundary
# rather than leave the session nudged for work it did. "This session" is
# literal: the metrics file is shared by every session on the machine, so a
# projectless row is credited only when its `session` (delegate.sh writes
# CLAUDE_CODE_SESSION_ID, #479) equals the session_id the harness hands the
# hook. Anything else would pool every scratch-cwd session's credits.
seed_projectless() { # session|"" recipe
  jq -nc --arg ts "$nowts" --arg s "$1" --arg r "$2" \
    '{ts:$ts, source:"delegate", tier:"prose", recipe:$r} + (if $s != "" then {session:$s} else {} end)' >> "$METRICS"
}
: > "$METRICS"; seed_projectless sess-A commit-message
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: a projectless delegation from THIS session credits the boundary"
assert_eq "" "$out" "no-repo cwd: credited, so no nudge"
assert_eq sess-A "$(jq -r .session <<<"$(last_row)")" "no-repo cwd: the opportunity row records the session too"

# 41c-ii. Another session's projectless delegation does not credit it, and
# neither does one carrying no session at all (written before #479, or by a
# caller outside Claude): fail safe and nudge.
: > "$METRICS"; seed_projectless sess-B commit-message
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: another session's projectless delegation does not credit"
assert_contains 'commit-message' "$(hook_msg "$out")" "no-repo cwd: ...and the nudge fires"
: > "$METRICS"; seed_projectless "" commit-message
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: a projectless delegation with no session does not credit"

# 41c-iii. Consumption is per session as well: this session's credited post
# spends this session's credit, another session's credited post does not.
: > "$METRICS"; seed_projectless sess-A commit-message; seed_projectless sess-A commit-message
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: two delegations credit two posts"
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: the third post finds both credits spent"
: > "$METRICS"; seed_projectless sess-A commit-message
jq -nc --arg ts "$nowts" '{ts:$ts, source:"opportunity", boundary:"git-commit", suggested_recipe:"commit-message", delegated:true, session:"sess-B"}' >> "$METRICS"
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: another session's credited post does not spend this session's credit"

# 41c-iv. A payload with no session_id can scope nothing, so a projectless
# row credits nothing even when it carries a session.
: > "$METRICS"; seed_projectless sess-A commit-message
payload 'git commit -m x' "$norepo" "" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: no session_id in the payload credits nothing"
assert_eq false "$(jq 'has("session")' <<<"$(last_row)")" "no-repo cwd: no session_id in the payload writes no session field"

# 41d. A delegation filed under a real project does not credit a projectless
# boundary — no project is not a wildcard.
: > "$METRICS"; seed_delegation repo-a commit-message
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: a delegation under a real project does not credit it"

# 41e. A `cd <repo> &&` from the non-repo cwd still files the boundary under
# the cd target, and the empty session-cwd candidate still matches a
# projectless delegation this session issued before the cd.
: > "$METRICS"; seed_projectless sess-A commit-message
payload "cd $gitroot/repo-b && git commit -m x" "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-b "$(jq -r .project <<<"$(last_row)")" "no-repo cwd + cd: project taken from the cd target"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd + cd: projectless same-session delegation still credits"

# 41f. Inside a repository nothing moves: the project is recorded and named.
: > "$METRICS"
out=$(payload 'git commit -m x' "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "repo cwd: project still recorded"
assert_contains "for project 'repo-a'" "$out" "repo cwd: nudge still names the project"
assert_contains '--project \"repo-a\"' "$out" "repo cwd: nudge still renders --project"

# 41g. The converse of 41c, which the lookup comment relies on: a projectless
# delegation does NOT credit a boundary whose session cwd is inside a
# repository. Empty matches empty and nothing else.
: > "$METRICS"
jq -nc --arg ts "$nowts" '{ts:$ts, source:"delegate", tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m x' "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "repo cwd: a projectless delegation does not credit it"

# 41h. A delegation that FAILED produced no draft to post, so it credits
# nothing. delegate.sh writes exit_status:3 for a pre-flight stall and the
# summary already joins on exit_status 0; the hook was the odd one out.
: > "$METRICS"
jq -nc --arg ts "$nowts" '{ts:$ts, source:"delegate", project:"repo-a", tier:"prose", recipe:"commit-message", exit_status:3}' >> "$METRICS"
payload 'git commit -m x' "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "repo cwd: a failed delegation (exit_status 3) does not credit"

# 41i. DELEGATE_PROJECT is the same override delegate.sh and
# delegate-feedback.sh honour, so a session that sets it records every row
# under one name — including from a non-repo cwd, where it is the ONLY way
# to name the project — and a delegation recorded under it credits the post.
: > "$METRICS"; seed_delegation explicit-name commit-message
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK")
assert_eq explicit-name "$(jq -r .project <<<"$(last_row)")" "DELEGATE_PROJECT: recorded as the project from a non-repo cwd"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "DELEGATE_PROJECT: a delegation under it credits the post"
: > "$METRICS"
out=$(payload 'git commit -m x' "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK")
assert_eq explicit-name "$(jq -r .project <<<"$(last_row)")" "DELEGATE_PROJECT: wins over the repo cwd, as it does in delegate.sh"
assert_contains '--project \"explicit-name\"' "$out" "DELEGATE_PROJECT: the nudge names it"
# ...and over a cd target: delegate.sh run after that same cd inherits the
# variable and records it, so the row has to be filed where the lookup looks.
: > "$METRICS"
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK" >/dev/null
assert_eq explicit-name "$(jq -r .project <<<"$(last_row)")" "DELEGATE_PROJECT: wins over the cd target too"
# ...and once it wins, neither the physical repository nor the cd target is a
# LOOKUP candidate any more: delegate.sh under the same override records the
# override, so a delegation filed under either name is not this session's.
: > "$METRICS"; seed_delegation repo-a commit-message
payload 'git commit -m x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "DELEGATE_PROJECT: the physical repo is not a candidate under the override"
: > "$METRICS"; seed_delegation repo-b commit-message
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "DELEGATE_PROJECT: the cd target is not a candidate under the override"

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

# 58d-iv. A quoted path containing SPACES is one path, not its first word.
: > "$METRICS"
cp "$tmpcwd/long.md" "$tmpcwd/notes with spaces.md"
payload "gh pr comment 12 --body-file \"$tmpcwd/notes with spaces.md\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a quoted path with spaces is measured whole"

# 58d-v. A --body-file wins over an inline --body in the same command: it names
# where the text really is.
: > "$METRICS"
payload "gh pr comment 12 --body \"short\" --body-file $tmpcwd/long.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: --body-file outranks an inline body in the same command"

# 58d-vi. A flag MENTIONED inside quoted prose is data, not a flag. The scan
# that classifies the boundary already blanks quoted spans; the measurement
# reads the raw command and has to do its own skipping, or a sentence about
# `--body-file` promotes a two-sentence reply to the evidence-led recipe —
# the direction that costs something.
: > "$METRICS"
payload "echo \"pass --body-file $tmpcwd/long.md when you post it\"; gh pr comment 12 --body \"two sentences. and an ask?\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a flag inside quoted prose is not measured"
: > "$METRICS"
payload "echo \"$long_body\"; gh pr comment 12 --body \"two sentences. and an ask?\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: a long quoted string in another segment is not the body"

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

# ---------------------------------------------------------------------------
# Capturing the posted body as the shipped half of the (generated, shipped)
# pair. `maintainer-reply` was the weakest recipe with any volume — 21% usable
# over n=33 — and the only one whose 32 rejections carried no captured final,
# because its output is posted inline and never reaches a file
# `delegate-feedback.sh --final` could name. This hook is the one place that
# sees the shipped text.
# ---------------------------------------------------------------------------
cap_setup() { # -> sets capdir capm capcwd capproj; seeds one delegate row
  capdir=$(mktemp -d); capm="$capdir/metrics.jsonl"
  capcwd=$(mktemp -d); mk_repo "$capcwd" >/dev/null 2>&1; capproj=$(basename "$capcwd")
  capts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","project":"%s","draft_file":"20260827T100000Z-aaaa1111.draft.txt"}\n' \
    "$capts" "$capproj" > "$capm"
}
cap_post() { payload "$1" "$capcwd" | DELEGATE_METRICS_FILE="$capm" bash "$HOOK" >/dev/null 2>&1; }

cap_setup
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq true "$(jq -r .delegated <<<"$(tail -1 "$capm")")" \
  "capture: the post is credited to the delegation"
assert_eq "the fix landed in abc1234" "$(cat "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt" 2>/dev/null)" \
  "capture: a credited post stores the posted body under the credited draft's stem"
rm -rf "$capdir" "$capcwd"

# Uncredited: nothing was delegated, so there is no draft this post is the
# shipped form OF, and storing it would invent a pair.
cap_setup
: > "$capm"
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq false "$(jq -r .delegated <<<"$(tail -1 "$capm")")" "capture: uncredited post is not credited"
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" "capture: an uncredited post stores nothing"
rm -rf "$capdir" "$capcwd"

# A hand-supplied --final outranks an inferred one, so an existing file is
# never overwritten.
cap_setup
mkdir -p "$capdir/drafts"
printf 'what the human actually shipped' > "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt"
cap_post 'gh pr comment 12 --body "a different body entirely"'
assert_eq "what the human actually shipped" "$(cat "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt")" \
  "capture: an existing final is not overwritten"
rm -rf "$capdir" "$capcwd"

# Opting out of metrics opts out of the capture too: the shipped text is more
# sensitive than the row, so it cannot outlive the thing it annotates.
cap_setup
payload 'gh pr comment 12 --body "the fix landed in abc1234"' "$capcwd" \
  | DELEGATE_METRICS_FILE="$capm" DELEGATE_LOCAL_NO_METRICS=1 bash "$HOOK" >/dev/null 2>&1
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" \
  "capture: DELEGATE_LOCAL_NO_METRICS=1 stores nothing"
rm -rf "$capdir" "$capcwd"

# Same sensitivity rules as the draft it sits beside: verbatim outbound text,
# so neither the directory nor the file may inherit a permissive umask.
cap_setup
( umask 000; cap_post 'gh pr comment 12 --body "the fix landed in abc1234"' )
assert_eq 700 "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$capdir/drafts")" \
  "capture: drafts directory is private (700) under a permissive umask"
assert_eq 600 "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt")" \
  "capture: stored body is private (600) under a permissive umask"
rm -rf "$capdir" "$capcwd"

# Oldest-unspent-first. A sweep delegates a batch and works down it, so with one
# post already credited the next one belongs to the SECOND draft, not the first.
# Pairing the newest delegation with every post would file a whole afternoon of
# replies against one draft.
cap_setup
printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","project":"%s","draft_file":"20260827T110000Z-bbbb2222.draft.txt"}\n' \
  "$capts" "$capproj" >> "$capm"
printf '{"ts":"%s","source":"opportunity","boundary":"comment-reply","suggested_recipe":"maintainer-reply","delegated":true,"project":"%s"}\n' \
  "$capts" "$capproj" >> "$capm"
cap_post 'gh pr comment 12 --body "the second reply"'
assert_eq "the second reply" "$(cat "$capdir/drafts/20260827T110000Z-bbbb2222.final.txt" 2>/dev/null)" \
  "capture: the second post is filed against the second draft"
assert_eq "false" "$([[ -e "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt" ]] && echo true || echo false)" \
  "capture: the already-spent draft is left alone"
rm -rf "$capdir" "$capcwd"

# A --body-file post is credited like any other, and the file is where the
# shipped text is.
cap_setup
printf 'the reply that came from a file\n' > "$capcwd/reply.md"
cap_post "gh pr comment 12 --body-file $capcwd/reply.md"
assert_eq "the reply that came from a file" "$(cat "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt" 2>/dev/null)" \
  "capture: a --body-file post stores the file's contents"
rm -rf "$capdir" "$capcwd"

# ---------------------------------------------------------------------------
# #461. `gh api ... -f body=... -F in_reply_to=...` is the shape
# /address-pr-comments prescribes for replying to one review comment, and it is
# the shape the scanner could not read: `-f` was not a recognised flag at all,
# and a bare `-F` argument was taken as a body-file path, so `in_reply_to=99`
# became a filename that does not exist. Every post in that shape yielded no
# text, which is why the capture had 0 rows carrying final_source in the whole
# corpus while 37 finals on disk had all been supplied by hand.
# ---------------------------------------------------------------------------
cap_setup_recipe() { # $1 = recipe to seed, so a non-comment-reply boundary credits
  capdir=$(mktemp -d); capm="$capdir/metrics.jsonl"
  capcwd=$(mktemp -d); mk_repo "$capcwd" >/dev/null 2>&1; capproj=$(basename "$capcwd")
  capts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","source":"delegate","recipe":"%s","project":"%s","draft_file":"20260827T100000Z-aaaa1111.draft.txt"}\n' \
    "$capts" "$1" "$capproj" > "$capm"
}
capfinal="drafts/20260827T100000Z-aaaa1111.final.txt"

cap_setup_recipe pr-review-reply
cap_post 'gh api repos/o/r/pulls/12/comments -X POST -f body="Applied in abc1234." -F in_reply_to=99'
assert_eq true "$(jq -r .delegated <<<"$(tail -1 "$capm")")" \
  "capture: the gh api reply is credited to the delegation"
assert_eq "Applied in abc1234." "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: -f body= is the posted body (#461)"
rm -rf "$capdir" "$capcwd"

# A field flag whose key is not `body` is not text anyone posted. `-f
# event=COMMENT` is longer than the body beside it, so a fix that read every
# field argument as a candidate body would store the wrong one.
cap_setup_recipe maintainer-review-reply
cap_post 'gh api repos/o/r/pulls/12/reviews -X POST -f body=hello -f event=COMMENT'
assert_eq "hello" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: a non-body field key is not mistaken for the body"
rm -rf "$capdir" "$capcwd"

# `-F body=@file` reads the field FROM a file, so the scanner resolves the path
# rather than storing the literal `body=@...` argument.
cap_setup_recipe pr-review-reply
printf 'the reply that came from a field file' > "$capcwd/reply.md"
cap_post "gh api repos/o/r/pulls/12/comments -X POST -F body=@$capcwd/reply.md -F in_reply_to=1"
assert_eq "the reply that came from a field file" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: -F body=@file stores the file's contents"
rm -rf "$capdir" "$capcwd"

# The long forms of the same two flags.
cap_setup_recipe pr-review-reply
cap_post 'gh api repos/o/r/pulls/12/comments -X POST --raw-field body="the long form" --field in_reply_to=9'
assert_eq "the long form" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: --raw-field body= is the posted body"
rm -rf "$capdir" "$capcwd"

# A POST carrying no body field at all has no text to store, and must not
# invent one out of the other fields.
cap_setup_recipe pr-review-reply
cap_post 'gh api repos/o/r/pulls/12/comments -X POST -F in_reply_to=99 -F commit_id=abc1234'
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" \
  "capture: a POST with no body field stores nothing"
rm -rf "$capdir" "$capcwd"

# `-F` is ALSO `--body-file`'s short form in `gh pr comment`, where the argument
# is a bare path with no `=`. That meaning has to survive the fix.
cap_setup
printf 'the reply posted with the short flag' > "$capcwd/reply.md"
cap_post "gh pr comment 12 -F $capcwd/reply.md"
assert_eq "the reply posted with the short flag" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: a bare -F path is still a body file"
rm -rf "$capdir" "$capcwd"

# No routing assertion accompanies these: `posted_body_chars` has one caller,
# the 600-char comment-reply split, and every `gh api` form is classified by
# endpoint before it reaches that split. There is no real command where a
# field flag meets the split, so the parse is asserted where it is observable.

# A delegation with no captured draft has no stem to file the post under, so the
# capture is skipped rather than inventing a name that matches no draft.
cap_setup
printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","project":"%s"}\n' "$capts" "$capproj" > "$capm"
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq true "$(jq -r .delegated <<<"$(tail -1 "$capm")")" "capture: draftless delegation still credits the post"
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" "capture: a draftless delegation stores nothing"
rm -rf "$capdir" "$capcwd"

# A draft_file read out of the metrics JSONL becomes part of a path this hook
# writes to, so it is untrusted input: a bare filename ending in .draft.txt or
# nothing at all. A hand-edited or corrupted row must not be able to place the
# captured body outside the drafts directory.
cap_setup
printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","project":"%s","draft_file":"../escaped.draft.txt"}\n' \
  "$capts" "$capproj" > "$capm"
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq "false" "$([[ -e "$capdir/escaped.final.txt" ]] && echo true || echo false)" \
  "capture: a traversing draft_file writes nothing outside the drafts dir"
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" \
  "capture: a traversing draft_file writes nothing inside it either"
rm -rf "$capdir" "$capcwd"

# A draft_file that is not a draft at all is refused the same way.
cap_setup
printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","project":"%s","draft_file":"notes.txt"}\n' \
  "$capts" "$capproj" > "$capm"
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" "capture: a draft_file without the .draft.txt suffix stores nothing"
rm -rf "$capdir" "$capcwd"

# ---------------------------------------------------------------------------
# #483. Measured 2026-09-13 over 14 days: 680 boundaries, 108 delegated (15%),
# and the warn-mode nudge does not move it — after a nudge the next boundary
# within 30 minutes is delegated 9% of the time, against 34% after a credit,
# because the nudge lands while the post executes and cannot change the text
# it is about. Only a deny makes the agent redo the text with a draft. The
# four boundaries whose recipe is proven deny by default; pr-create and
# pr-review-body stay on warn until pr-description is above 80% usable.
# ---------------------------------------------------------------------------
# These run at the DEFAULT floor (the pin at the top is lifted per call) with
# bodies long enough to be real drafting, and against the pinned mock
# provider unless a case says otherwise.
body300=$(python3 -c "print('The sandbox flag in src/main.js is the cause, not your distro. ' * 5)")
dflt() { DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }
# Provider down: the real curl against a closed port refuses at once, and the
# mock is out of the way so it cannot answer.
down() { PATH="${PATH#$MOCKDIR:}" DELEGATE_BASE_URL=http://localhost:1/v1 DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }

# 60. Each of the four proven boundaries is denied when nothing was delegated,
# the reason is the runnable reminder, and the row says why the post did not
# happen — `denied:true`, so the retry that follows is not counted twice.
for spec in \
  "git-commit|commit-message|git commit -m \"$body300\"" \
  "issue-create|github-issue-body|gh issue create --title t --body \"$body300\"" \
  "comment-reply|maintainer-reply|gh pr comment 12 --body \"$body300\"" \
  "pr-review-comment|pr-review-reply|gh api repos/o/r/pulls/12/comments -X POST -f body=\"$body300\" -F in_reply_to=9"; do
  b="${spec%%|*}"; rest="${spec#*|}"; r="${rest%%|*}"; c="${rest#*|}"
  : > "$METRICS"
  out=$(payload "$c" "$tmpcwd" | dflt bash "$HOOK")
  assert_contains '"permissionDecision":"deny"' "$out" "enforce: $b is denied without a credit"
  assert_contains "--recipe $r" "$(hook_msg "$out")" "enforce: $b deny reason names the runnable command"
  assert_eq "$b" "$(jq -r .boundary <<<"$(last_row)")" "enforce: $b row still recorded"
  assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "enforce: $b row is delegated=false"
  assert_eq true "$(jq -r '.denied // false' <<<"$(last_row)")" "enforce: $b row carries denied:true"
  assert_eq false "$(jq 'has("enforce_skipped")' <<<"$(last_row)")" "enforce: $b row carries no enforce_skipped while a provider answers"
  # ...and allowed, silently, once the delegation exists.
  : > "$METRICS"; seed_delegation "$proj" "$r"
  out=$(payload "$c" "$tmpcwd" | dflt bash "$HOOK")
  assert_eq "" "$out" "enforce: $b passes once credited"
  assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "enforce: $b credited row is delegated=true"
  assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "enforce: $b credited row carries no denied field"
done

# 61. pr-create and pr-review-body stay on warn: their recipe is not proven.
for spec in \
  "pr-create|gh pr create --title t --body \"$body300\"" \
  "pr-review-body|gh pr review 12 --comment --body \"$body300\""; do
  b="${spec%%|*}"; c="${spec#*|}"
  : > "$METRICS"; rm -f "$MOCKDIR/probed"
  out=$(payload "$c" "$tmpcwd" | dflt bash "$HOOK")
  assert_contains '"permissionDecision":"allow"' "$out" "warn: $b is only warned by default"
  assert_contains '"additionalContext"' "$out" "warn: $b reminder is non-blocking"
  assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "warn: $b row carries no denied field"
  assert_eq "absent" "$([[ -e "$MOCKDIR/probed" ]] && echo present || echo absent)" "warn: $b did not probe the provider"
done

# 62. The overrides. DELEGATE_BOUNDARY_MODE=warn and =off are global and win
# over the enforced set; =enforce means every boundary; the set itself is
# DELEGATE_BOUNDARY_ENFORCE, comma-separated, and empty means none.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=warn dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "override: MODE=warn downgrades an enforced boundary to a reminder"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=off dflt bash "$HOOK")
assert_eq "" "$out" "override: MODE=off silences an enforced boundary"
assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "override: MODE=off row carries no denied field"
: > "$METRICS"
out=$(payload "gh pr create --title t --body \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=enforce dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "override: MODE=enforce denies pr-create too"
: > "$METRICS"
out=$(payload "gh pr create --title t --body \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_ENFORCE=pr-create dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "override: ENFORCE=pr-create denies pr-create"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_ENFORCE=pr-create dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "override: ENFORCE=pr-create leaves git-commit on warn"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_ENFORCE= dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "override: ENFORCE= (empty) enforces nothing"
: > "$METRICS"
out=$(payload "gh pr comment 12 --body \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_ENFORCE="git-commit, comment-reply" dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "override: ENFORCE tolerates a space after the comma"

# 63. Fail open when no provider answers. A session with MLX and Ollama down
# cannot delegate and must still be able to commit, so the deny becomes a
# reminder and the row says so.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | down bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "no provider: an enforced boundary is not denied"
assert_contains 'commit-message' "$(hook_msg "$out")" "no provider: the reminder still fires"
assert_contains 'No local provider answered' "$(hook_msg "$out")" "no provider: the reminder says why the call proceeds"
assert_eq no-provider "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "no provider: row records enforce_skipped=no-provider"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no provider: row is still a real miss (delegated=false)"
assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "no provider: row carries no denied field"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=enforce down bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "no provider: explicit MODE=enforce fails open too"
# A credited post never probes: the provider's state is irrelevant to a post
# that already has its delegation.
: > "$METRICS"; seed_delegation "$proj" commit-message; rm -f "$MOCKDIR/probed"
payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "absent" "$([[ -e "$MOCKDIR/probed" ]] && echo present || echo absent)" "no probe: a credited post does not probe the provider"

# 64. The body-length floor. Inline review comments ran at 3% because most are
# one line — an applied-in hash, a dependabot command, one word — and the hook
# stored no length, so they could not be told from real drafting after the
# fact. `body_chars` is an integer (never the text) on every row whose body is
# measurable; under DELEGATE_BOUNDARY_MIN_CHARS (120) the hook neither nudges
# nor denies and marks the row `below_floor:true` so the data stays for tuning.
body40='LGTM, applied in abc123 and pushed; thanks!'
: > "$METRICS"; rm -f "$MOCKDIR/probed"
out=$(payload "gh pr comment 12 --body \"$body40\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq "" "$out" "floor: a ${#body40}-char reply is neither nudged nor denied"
assert_eq "${#body40}" "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "floor: row records body_chars as an integer"
assert_eq true "$(jq -r '.below_floor // false' <<<"$(last_row)")" "floor: row carries below_floor:true"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "floor: row is still recorded as delegated=false"
assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "floor: row carries no denied field"
assert_eq "absent" "$([[ -e "$MOCKDIR/probed" ]] && echo present || echo absent)" "floor: a below-floor post does not probe the provider"
assert_eq "absent" "$(grep -qF "$body40" "$METRICS" && echo present || echo absent)" "floor: the body text itself is never written to the row"
# A body over the floor is enforced, and carries its length with no marker.
: > "$METRICS"
out=$(payload "gh pr comment 12 --body \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "floor: a ${#body300}-char reply is enforced"
assert_eq "${#body300}" "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "floor: over-floor row records body_chars"
assert_eq false "$(jq 'has("below_floor")' <<<"$(last_row)")" "floor: over-floor row carries no below_floor field"
# A commit whose message arrives on stdin (`-F -` with a heredoc) has no body
# the hook can read at PreToolUse time — a bare `git commit` is not a boundary
# at all, it opens the editor — so the row carries no body_chars and today's
# behaviour stands: enforced.
: > "$METRICS"
out=$(payload "git commit -F - <<'EOF'
$body300
EOF" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "floor: a commit with no measurable body is enforced"
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "floor: no measurable body, no body_chars field"
assert_eq false "$(jq 'has("below_floor")' <<<"$(last_row)")" "floor: no measurable body, no below_floor field"
# A credited post under the floor keeps both facts.
: > "$METRICS"; seed_delegation "$proj" maintainer-reply
out=$(payload "gh pr comment 12 --body \"$body40\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq "" "$out" "floor: a credited below-floor post is silent"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "floor: credited below-floor row is delegated=true"
assert_eq true "$(jq -r '.below_floor // false' <<<"$(last_row)")" "floor: credited below-floor row still carries below_floor"
# The floor is tunable.
: > "$METRICS"
out=$(payload "gh pr comment 12 --body \"$body40\"" "$tmpcwd" | DELEGATE_BOUNDARY_MIN_CHARS=10 DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "floor: DELEGATE_BOUNDARY_MIN_CHARS=10 enforces the ${#body40}-char reply"

# 65. `git commit -m` is measured. The scanner knew `--message` and `-F` but
# not `-m`, so every commit posted the way Claude Code posts them —
# `-m "$(cat <<'EOF' … EOF\n)"` — measured nothing. The heredoc wrapper is
# not part of the message: the length and the captured final are the text
# between the delimiters, and a quote or a paren inside the message does not
# end it early.
commit_body="fix: handle a \"quoted\" flag (see 1) and 2) in the notes)

$body300"
cc="git commit -m \"\$(cat <<'EOF'
$commit_body
EOF
)\""
: > "$METRICS"
out=$(payload "$cc" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "commit -m: the heredoc shape is enforced"
assert_eq "${#commit_body}" "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "commit -m: body_chars is the message between the delimiters"
: > "$METRICS"
payload 'git commit -am "fix: short"' "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq 10 "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "commit -am: the combined short flag is measured"
# ...and the credited commit stores the same text as its final (ADR 0029).
cap_setup_recipe commit-message
payload "$cc" "$capcwd" | DELEGATE_METRICS_FILE="$capm" DELEGATE_BOUNDARY_MIN_CHARS= bash "$HOOK" >/dev/null 2>&1
assert_eq "$commit_body" "$(cat "$capdir/$capfinal" 2>/dev/null)" "commit -m: a credited commit stores the unwrapped message as its final"
rm -rf "$capdir" "$capcwd"

# ---------------------------------------------------------------------------
# PR #484 review. The deny had bypasses and one loop, each reproduced below
# before it was closed.
# ---------------------------------------------------------------------------

# 66 (A). Unexpanded shell text is not a body. `--body "$(cat draft.md)"`
# measured 15 characters and was silently allowed as below the floor;
# `MSG=…; git commit -m "$MSG"` measured 4 — a one-token bypass the agent finds
# on its first denied commit — and a compliant, credited `--body "$(cat
# reply.txt)"` was marked below_floor and dropped from the numerator. Any body
# holding an unresolved `$`, backtick or `$(` — other than the recognised
# `-m "$(cat <<'EOF' … EOF)"` shape — is UNMEASURABLE: no body_chars, no
# below_floor, enforced as before.
: > "$METRICS"
out=$(payload 'gh pr comment 12 --body "$(cat draft.md)"' "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "unmeasurable: \$(cat draft.md) is enforced, not measured"
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "unmeasurable: \$(cat file) carries no body_chars"
assert_eq false "$(jq 'has("below_floor")' <<<"$(last_row)")" "unmeasurable: \$(cat file) carries no below_floor"
: > "$METRICS"
out=$(payload 'MSG="fix: thing"; git commit -m "$MSG"' "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "unmeasurable: a \$VAR body is enforced"
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "unmeasurable: a \$VAR body carries no body_chars"
: > "$METRICS"
out=$(payload 'gh pr comment 12 --body "see `cat notes.md` for the rest of the reasoning behind this"' "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "unmeasurable: a backtick body is enforced"
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "unmeasurable: a backtick body carries no body_chars"
# Credited and unmeasurable: delegated=true, no below_floor, and nothing is
# stored as the final — the literal text is not what shipped.
cap_setup
cap_post 'gh pr comment 12 --body "$(cat reply-draft.txt)"'
assert_eq true "$(jq -r .delegated <<<"$(tail -1 "$capm")")" "unmeasurable: a credited \$(cat) post is still credited"
assert_eq false "$(jq 'has("below_floor")' <<<"$(tail -1 "$capm")")" "unmeasurable: a credited \$(cat) post is not marked below_floor"
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" "unmeasurable: a credited \$(cat) post stores no final"
rm -rf "$capdir" "$capcwd"
# A literal dollar inside SINGLE quotes is text, and stays measurable.
: > "$METRICS"
out=$(payload "gh pr comment 12 --body 'the \$5 plan covers it; $body300'" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "measurable: a single-quoted \$ is literal and the body is enforced on length"
assert_eq true "$(jq 'has("body_chars")' <<<"$(last_row)")" "measurable: a single-quoted \$ body still records body_chars"
# An escaped dollar inside double quotes is literal too.
: > "$METRICS"
payload "gh pr comment 12 --body \"costs \\\$5; $body300\"" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq true "$(jq 'has("body_chars")' <<<"$(last_row)")" "measurable: an escaped \\\$ inside double quotes is literal"

# 67 (B). The loop. comment-reply names its recipe from the ORIGINAL body's
# length (the 600 split). A 700-char post was denied naming
# maintainer-review-reply; the agent delegated exactly that and posted the
# 450-char draft, which routed to maintainer-reply, matched no credit, and was
# denied again under a different recipe name. Either comment-reply recipe
# credits a comment-reply boundary.
body700=$(python3 -c "print('The sandbox flag in src/main.js is the cause, not your distro. ' * 11)")
body450=$(python3 -c "print('The sandbox flag in src/main.js is the cause, not your distro. ' * 7)")
: > "$METRICS"
out=$(payload "gh pr comment 12 --body \"$body700\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "loop: the 700-char post is denied"
assert_contains '--recipe maintainer-review-reply' "$(hook_msg "$out")" "loop: ...naming maintainer-review-reply"
seed_delegation "$proj" maintainer-review-reply
out=$(payload "gh pr comment 12 --body \"$body450\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq "" "$out" "loop: the 450-char draft posted next is credited, not denied again"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "loop: ...and recorded delegated=true"
assert_eq maintainer-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" "loop: ...under the recipe its own length routes to"
# The converse: a maintainer-reply delegation credits a long comment too.
: > "$METRICS"; seed_delegation "$proj" maintainer-reply
out=$(payload "gh pr comment 12 --body \"$body700\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "loop: a maintainer-reply delegation credits a long comment-reply"
# Other boundaries are still recipe-exact.
: > "$METRICS"; seed_delegation "$proj" maintainer-reply
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "loop: a reply delegation does not credit a commit"

# 68 (C). The body is read from the MATCHED SEGMENT, not the whole compound
# command. `git commit -m "fix: x" && gh pr create --body "<300 chars>"`
# measured the PR body against the commit boundary and denied a 6-char commit;
# the reverse paired a commit with a `--body-file` further along and stored
# that file as the commit's final.
: > "$METRICS"
out=$(payload "git commit -m \"fix: x\" && gh pr create --title t --body \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "segment scope: the first segment classifies"
assert_eq 6 "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "segment scope: the commit is measured, not the PR body"
assert_eq "" "$out" "segment scope: a 6-char commit is below its floor, not denied on the PR body's length"
cap_setup_recipe commit-message
printf 'notes that are not the commit message\n' > "$capcwd/notes.md"
payload "git commit -m \"fix: thing\" && gh pr comment 1 --body-file $capcwd/notes.md" "$capcwd" \
  | DELEGATE_METRICS_FILE="$capm" DELEGATE_BOUNDARY_MIN_CHARS= bash "$HOOK" >/dev/null 2>&1
assert_eq "fix: thing" "$(cat "$capdir/$capfinal" 2>/dev/null)" "segment scope: the commit's final is its own message, not a later --body-file"
rm -rf "$capdir" "$capcwd"

# 69 (D). Repeated `-m` are paragraphs — git joins them with a blank line — so
# a two-paragraph commit that clears the floor combined was marked below_floor
# because only the longest one was kept. The inline bodies of one command are
# summed (joined with a blank line).
para1='fix: the subject line, forty characters'
para2='and the body paragraph, also forty chars'
: > "$METRICS"
out=$(payload "git commit -m \"$para1\" -m \"$para2\"" "$tmpcwd" | DELEGATE_BOUNDARY_MIN_CHARS=60 DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "$(( ${#para1} + 2 + ${#para2} ))" "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "summed -m: body_chars is both paragraphs plus the blank line"
assert_contains '"permissionDecision":"deny"' "$out" "summed -m: two 40-char paragraphs clear a 60-char floor together"

# 70 (E). Never a permanent block. A delegation that fails (exit_status 3, an
# HTTP 500, the echo check) never credits, and DELEGATE_LOCAL_NO_METRICS=1 or a
# metrics path that differs between the hook's env and the Bash tool's means
# no credit can ever be written where the hook reads — and the deny text
# itself says a command prefix cannot change the hook's env. Two escapes:
# after two consecutive denials for the same session and boundary the third
# attempt is warned with enforce_skipped:"retry-cap", and a metrics file the
# hook cannot append to fails open with enforce_skipped:"metrics-unwritable".
seed_denied() { # session boundary [ts]
  jq -nc --arg ts "${3:-$nowts}" --arg p "$proj" --arg s "$1" --arg b "$2" \
    '{ts:$ts, source:"opportunity", boundary:$b, suggested_recipe:"x", delegated:false, denied:true, project:$p, session:$s}' >> "$METRICS"
}
: > "$METRICS"; seed_denied sess-A git-commit; seed_denied sess-A git-commit
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "retry cap: the third consecutive attempt is not denied"
assert_eq retry-cap "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "retry cap: the row records enforce_skipped=retry-cap"
assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "retry cap: the row is not a denial"
assert_contains 'twice' "$(hook_msg "$out")" "retry cap: the reminder says why the call proceeds"
# The natural sequence, with nothing seeded: deny, deny, proceed.
: > "$METRICS"
for i in 1 2; do
  out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
  assert_contains '"permissionDecision":"deny"' "$out" "retry cap: attempt $i is denied"
done
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "retry cap: attempt 3 proceeds"
# A credited post in between resets the streak, so the cap cannot be banked.
: > "$METRICS"; seed_denied sess-A git-commit; seed_denied sess-A git-commit
jq -nc --arg ts "$nowts" --arg p "$proj" '{ts:$ts, source:"opportunity", boundary:"git-commit", suggested_recipe:"commit-message", delegated:true, project:$p, session:"sess-A"}' >> "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: a later non-denied row resets the streak"
# Scoped to the session and the boundary.
: > "$METRICS"; seed_denied sess-B git-commit; seed_denied sess-B git-commit
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: another session's denials do not count"
: > "$METRICS"; seed_denied sess-A comment-reply; seed_denied sess-A comment-reply
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: another boundary's denials do not count"
# Outside the window the denials have expired.
: > "$METRICS"; seed_denied sess-A git-commit 2020-01-01T00:00:00Z; seed_denied sess-A git-commit 2020-01-01T00:00:01Z
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: denials outside the window do not count"
# Metrics unwritable: a directory where the file should be.
unwritable=$(mktemp -d)
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$unwritable" bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "metrics unwritable: the boundary is not denied"
assert_contains 'metrics' "$(hook_msg "$out")" "metrics unwritable: the reminder says the row could not be written"
rmdir "$unwritable"

# 71 (F). DELEGATE_BOUNDARY_MODE is case-insensitive and an unknown value is
# warn, as it was on main — for a while any value but the three exact spellings
# fell into the default branch and enforced.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=Off dflt bash "$HOOK")
assert_eq "" "$out" "mode: Off is off"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=WARN dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "mode: WARN is warn"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=0 dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "mode: an unknown value (0) is warn, not enforce"
: > "$METRICS"
out=$(payload "gh pr create --title t --body \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=Enforce dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "mode: Enforce is enforce"

# 72 (G). "No provider" was also said when a provider IS up but serves no
# model for the tier, or the recipe's tier is malformed. pick-model.sh already
# tells the three apart; the row and the reminder now do too.
MOCKDIR2=$(mktemp -d)
sed 's/qwen3.6:35b-a3b-q8_0/nomic-embed-text/' "$MOCKDIR/curl" > "$MOCKDIR2/curl"; chmod +x "$MOCKDIR2/curl"
nomodel() { PATH="$MOCKDIR2:${PATH#$MOCKDIR:}" DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | nomodel bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "no model: fails open"
assert_eq no-model "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "no model: the row says no-model, not no-provider"
assert_contains 'no model for the prose tier' "$(hook_msg "$out")" "no model: the reminder names the tier that has no model"
rm -rf "$MOCKDIR2"
badtier=$(mktemp -d)
sed 's/^tier: prose$/tier: bogus/' "$REPO/prompts/commit-message.md" > "$badtier/commit-message.md"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_PROMPTS_DIR="$badtier" dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "bad tier: fails open"
assert_eq bad-tier "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "bad tier: the row says bad-tier"
assert_contains "'bogus'" "$(hook_msg "$out")" "bad tier: the reminder names the tier the recipe declares"
# (I) The tier is read the way delegate.sh reads it: trailing whitespace is
# not a different tier.
sed 's/^tier: prose$/tier: prose   /' "$REPO/prompts/commit-message.md" > "$badtier/commit-message.md"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_PROMPTS_DIR="$badtier" dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "tier read: 'tier: prose   ' resolves like delegate.sh and is enforced"
rm -rf "$badtier"

# 73 (H). One 120-char floor calibrated on inline review comments exempted the
# one-line conventional commit — the commit-message recipe's own core output —
# from enforcement and from the denominator. Per-boundary defaults: 20 for
# git-commit (a subject line), 120 for the rest; DELEGATE_BOUNDARY_MIN_CHARS
# stays the global override.
subject46='fix: close the body-floor bypasses in the hook'
: > "$METRICS"
out=$(payload "git commit -m \"$subject46\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq 46 "${#subject46}" "per-boundary floor: the fixture subject is 46 chars"
assert_contains '"permissionDecision":"deny"' "$out" "per-boundary floor: a 46-char conventional commit is enforced"
assert_eq false "$(jq 'has("below_floor")' <<<"$(last_row)")" "per-boundary floor: ...and counted"
: > "$METRICS"
out=$(payload 'git commit -m "wip"' "$tmpcwd" | dflt bash "$HOOK")
assert_eq "" "$out" "per-boundary floor: a 3-char commit is under the 20-char commit floor"
assert_eq true "$(jq -r '.below_floor // false' <<<"$(last_row)")" "per-boundary floor: ...and marked below_floor"
: > "$METRICS"
out=$(payload "gh pr comment 12 --body \"$subject46\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq "" "$out" "per-boundary floor: 46 chars is still under the 120-char reply floor"
: > "$METRICS"
out=$(payload 'git commit -m "wip"' "$tmpcwd" | DELEGATE_BOUNDARY_MIN_CHARS=2 DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "per-boundary floor: the global override applies to git-commit too"

# 74 (M). One credit, two hooks at once. The lookup read a snapshot and the
# spending row was appended later, so two enforced boundaries after one
# delegation could both see the credit, both allow, and both spend it. Lookup
# and append are serialised with a mkdir lock in the data dir.
for i in 1 2 3; do
  : > "$METRICS"; seed_delegation "$proj" commit-message
  payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK" >/dev/null &
  payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK" >/dev/null &
  wait
  assert_eq 1 "$(grep -c '"delegated":true' "$METRICS")" "lock: run $i — one credit is spent exactly once"
  assert_eq 2 "$(grep -c '"source":"opportunity"' "$METRICS")" "lock: run $i — both boundaries are recorded"
done
lockdir="$(dirname "$METRICS")/.boundary-hook.lock"
# A stale lock (a killed hook) is broken rather than wedging every later post.
mkdir -p "$lockdir"; printf '%s' "$(( $(date -u +%s) - 60 ))" > "$lockdir/ts"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "lock: a stale lock is broken and the boundary is judged normally"
assert_eq "absent" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock: the lock is released afterwards"
# A live lock that is never released fails open to warn after the timeout,
# and is never removed by a hook that does not own it.
mkdir -p "$lockdir"; printf '%s' "$(date -u +%s)" > "$lockdir/ts"; printf 'someone-else' > "$lockdir/owner"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "lock: an unobtainable lock fails open"
assert_eq lock-timeout "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "lock: ...recording enforce_skipped=lock-timeout"
assert_eq "present" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock: a live lock is not removed by a non-owner"
assert_eq "someone-else" "$(cat "$lockdir/owner" 2>/dev/null)" "lock: ...and its owner file is untouched"
rm -rf "$lockdir"

# 75. Lock ownership (third review round). A hook whose provider probe keeps
# it running past the 5 s stale threshold had its lock broken by the next
# hook, and then its own EXIT cleanup removed the REPLACEMENT lock, so both
# ran their lookup unserialised and consumed the same credit. The lock dir
# carries an owner token written on acquisition; release removes the dir
# only when the token matches. Two mocks whose GET /models sleeps: hook A
# probes for 9 s, hook B — started 7 s in, so A's lock reads stale — probes
# for 3 s. A exits at ~9 s while B still holds the lock it took over; the
# lock must survive A's exit and vanish only when B finishes.
slow_mock() { # dir seconds
  mkdir -p "$1"
  { printf '#!/usr/bin/env bash\nsleep %s\n' "$2"; sed '1d;/^: >> /d' "$MOCKDIR/curl"; } > "$1/curl"
  chmod +x "$1/curl"
}
SLOWA=$(mktemp -d); slow_mock "$SLOWA" 9
SLOWB=$(mktemp -d); slow_mock "$SLOWB" 3
slow() { PATH="$1:${PATH#$MOCKDIR:}" DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "${@:2}"; }
: > "$METRICS"; rm -rf "$lockdir"
payload "git commit -m \"$body300\"" "$tmpcwd" | slow "$SLOWA" bash "$HOOK" >/dev/null &
pid_a=$!
sleep 7
payload "git commit -m \"$body300\"" "$tmpcwd" | slow "$SLOWB" bash "$HOOK" >/dev/null &
pid_b=$!
wait "$pid_a"
assert_eq "present" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock owner: A's exit leaves B's replacement lock in place"
wait "$pid_b"
assert_eq "absent" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock owner: B releases its own lock when it finishes"
assert_eq 2 "$(grep -c '"denied":true' "$METRICS")" "lock owner: both boundaries were judged (denied, no credit)"
rm -rf "$SLOWA" "$SLOWB"

echo
echo "delegate-boundary-hook: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
