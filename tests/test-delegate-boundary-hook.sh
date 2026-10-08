#!/usr/bin/env bash
# Unit tests for scripts/delegate-boundary-hook.sh. Feeds PreToolUse payloads
# on stdin and asserts on the emitted JSON and the source:"opportunity" rows
# written to a throwaway metrics file.

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

# The throwaway cwd must be a git repository, since outside one the hook
# records no project (#476); it needs a commit for the #385 worktree case.
mk_repo() { # dir
  mkdir -p "$1" && ( cd "$1" && git init -q . \
    && git config user.email t@t.t && git config user.name t \
    && : > f && git add f && git commit -qm init )
}
tmpcwd=$(mktemp -d)
mk_repo "$tmpcwd" >/dev/null 2>&1
proj=$(basename "$tmpcwd")
# In its own directory: the hook's lock lives beside the metrics file, so a
# bare mktemp in $TMPDIR made every suite run on the machine share one lock.
METRICS_DIR=$(mktemp -d); METRICS="$METRICS_DIR/metrics.jsonl"; : > "$METRICS"
# $gitroot and $norepo are created later; initialised here so the trap owns
# them under `set -u`. DELEGATE_PROJECT would rename every row the hook records.
gitroot="" norepo=""
unset DELEGATE_PROJECT
unset DELEGATE_BOUNDARY_MODE DELEGATE_BOUNDARY_ENFORCE
# The proven boundaries deny only while a provider is reachable (#483), so the
# suite pins one: a mock curl answers GET /models on port 8080 with one prose
# model, refuses everything else, and logs each call in $MOCKDIR/probed.
MOCKDIR=$(mktemp -d)
cat > "$MOCKDIR/curl" <<'EOF'
#!/usr/bin/env bash
: >> "$(dirname "$0")/probed"
for a in "$@"; do
  case "$a" in
    *:8080/*) printf '{"object":"list","data":[{"id":"test-prose-model","object":"model"}]}'; exit 0 ;;
  esac
done
exit 7
EOF
chmod +x "$MOCKDIR/curl"
export PATH="$MOCKDIR:$PATH"
export DELEGATE_BASE_URL=http://localhost:8080/v1
export DELEGATE_LOCAL_CONFIG=/dev/null
# Routes every tier to the fixture id exactly, so no test names the shipped model (#654).
export DELEGATE_MODEL=test-prose-model
# Most tests post placeholder bodies that a 120-char floor would silence; the
# floor is pinned off here and tested at its default in the #483 block.
export DELEGATE_BOUNDARY_MIN_CHARS=0
trap 'rm -rf "$tmpcwd" "$METRICS_DIR" "$gitroot" "$norepo" "$MOCKDIR"' EXIT
nowts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# $3 is the session id (#479); an explicit "" is kept (`${3-…}`, not
# `${3:-…}`) to model a payload without one.
payload() { # cmd  cwd  [session_id]
  jq -nc --arg cmd "$1" --arg cwd "$2" --arg sid "${3-sess-A}" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, session_id:$sid, tool_input:{command:$cmd}}'
}
last_row() { tail -1 "$METRICS"; }
nrows() { local n; n=$(grep -c . "$METRICS" 2>/dev/null) || true; echo "${n:-0}"; }
# The reminder text whichever channel carried it (warn: additionalContext,
# deny: permissionDecisionReason), so text tests do not pin the channel.
hook_msg() { jq -r '.hookSpecificOutput | .additionalContext // .permissionDecisionReason // empty' <<<"$1"; }
# A reminder that decides nothing (#546): "allow" would skip the permission
# prompt for the whole call, including anything chained after the boundary.
assert_nudge() { # out name
  assert_eq "true false" "$(jq -r '.hookSpecificOutput | "\(has("additionalContext")) \(has("permissionDecision"))"' <<<"$1" 2>/dev/null)" "$2"
}

# 1. Non-boundary command: silent, no row.
: > "$METRICS"
ec=0
out=$(payload "ls -la" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "non-boundary: exit 0"
assert_eq "" "$out" "non-boundary: no stdout"
assert_eq 0 "$(nrows)" "non-boundary: no metrics row"

# 2. git commit with no prior delegation: denied (#483) with the reminder as
# the reason, plus a delegated:false opportunity row.
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

# 5a. A recent pr-description delegation captures a pr-create boundary.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"pr-description"}' >> "$METRICS"
out=$(payload 'gh pr create --title t --body b' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "pr-create/matching pr-description delegation: delegated=true"
assert_eq "" "$out" "pr-create/matching delegation: no nudge"

# 5b. A recent commit-message delegation does not capture a pr-create
# boundary (#312): the match is by recipe, not project alone.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
out=$(payload 'gh pr create --title t --body b' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "pr-create/commit-message delegation: delegated=false (recipe mismatch)"
assert_contains 'pr-description' "$out" "pr-create/commit-message delegation: nudge still fires for pr-description"

# 5c. The same mismatch for a pr-review-comment boundary.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
out=$(payload 'gh api repos/o/r/pulls/12/comments -X POST -f body="x" -F in_reply_to=9' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "pr-review-comment/commit-message delegation: delegated=false (recipe mismatch)"
assert_contains 'pr-review-reply' "$out" "pr-review-comment/commit-message delegation: nudge names pr-review-reply"

# 5d. A bare (no-recipe) delegation counts for no boundary.
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
# 6a. #546: the default-mode nudge carries context only. A permissionDecision
# of "allow" would approve the whole call, including what is chained after it.
: > "$METRICS"
out=$(payload 'gh pr create --title t --body b && rm -rf x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_nudge "$out" "pr-create && rm -rf: additionalContext and no permissionDecision (#546)"

# 7. glab mr create -> also pr-create.
: > "$METRICS"
payload 'glab mr create --fill' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-create "$(jq -r .boundary <<<"$(last_row)")" "glab mr create: boundary"

# 8. gh release create is not a boundary since release-note was retired (#568).
: > "$METRICS"
out=$(payload 'gh release create v1.0.0 --notes x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "0 " "$(wc -l < "$METRICS" | tr -d ' ') $out" "gh release create: no row and no nudge (#568)"

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

# 8h-ter-bis. The --web exclusion is a standalone flag, so --webhooks in a title does not match.
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

# 8b-bis. #546: git's global options between `git` and `commit` still make a
# commit boundary; a quoted -C path is blanked, so `commit` follows -C directly.
for c in \
  'git -C /tmp/x commit -m "fix: thing"' \
  'git -c user.name=x commit -m "fix: thing"' \
  'git -C "/tmp/my dir" commit -m "fix: thing"' \
  'git --git-dir=/tmp/x/.git --work-tree=/tmp/x commit -m "fix: thing"' \
  'git --no-pager -C /tmp/x -c a.b=c commit -m "fix: thing"'; do
  : > "$METRICS"
  payload "$c" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "global options: $c writes a git-commit row"
done
# ...but not a different subcommand behind them, nor a config value naming commit.
for c in \
  'git -C /tmp/x log --grep commit -m' \
  'git -c commit.gpgsign=false log -m' \
  'git -C /tmp/x commit --amend --no-edit'; do
  : > "$METRICS"
  payload "$c" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq 0 "$(nrows)" "global options: $c is not a boundary"
done

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

# 12. DELEGATE_LOCAL_NO_METRICS=1: the reminder still fires, no row is written,
# and it cannot deny, since no credit could ever be recorded to lift the block.
: > "$METRICS"
out=$(payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_LOCAL_NO_METRICS=1 bash "$HOOK")
assert_contains 'commit-message' "$(hook_msg "$out")" "no-metrics: still nudges"
assert_nudge "$out" "no-metrics: never denies (no credit could be recorded)"
assert_eq 0 "$(nrows)" "no-metrics: no row written"

# 13. Custom window: a 5-minute-old delegation misses a 1-minute window. The
# row matches on project and recipe so the timestamp is the only reason.
: > "$METRICS"
oldish=$(jq -rn --argjson now "$(date -u +%s)" '($now - 300) | todateiso8601')
jq -nc --arg ts "$oldish" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_BOUNDARY_WINDOW_MIN=1 bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "custom window: 5m-old delegation outside 1m window"

# --- #342 defect 2: the classifier must only see leading tokens -----------

# 14a. A heredoc body that mentions a boundary command is data, not a boundary.
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

# 14c-i. An odd number of backslash-escaped quotes must not flip quote
# parity, or the ';' starts a fresh segment scanned as live shell.
: > "$METRICS"
out=$(payload 'echo "the flag is \" ; gh pr create --title x --body y"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "escaped quote in prose: no nudge"
assert_eq 0 "$(nrows)" "escaped quote in prose: no row"

# 14c-ii. Even parity stays safe.
: > "$METRICS"
out=$(payload 'echo "the flag is \" and \" ; gh pr create --title x --body y"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "paired escaped quotes in prose: no nudge"
assert_eq 0 "$(nrows)" "paired escaped quotes in prose: no row"

# 14c-iii. A commit message with an escaped quote is still a boundary.
: > "$METRICS"
payload 'git commit -m "fix: handle a \" in input"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "escaped quote in commit message: still git-commit"

# 14d. Quoted content never contributes to classification.
: > "$METRICS"
payload 'git commit -m "docs: explain gh pr create usage"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "commit message mentioning gh pr create: still git-commit"
assert_eq 1 "$(nrows)" "commit message mentioning gh pr create: exactly one row"

# 14e. Boundaries after a `&&` or inside a command substitution still classify.
: > "$METRICS"
payload 'cd /tmp/repo && git commit -m "fix: thing"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "git commit after &&: still a boundary"
: > "$METRICS"
payload 'url=$(gh pr create --title t --body b)' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-create "$(jq -r .boundary <<<"$(last_row)")" "gh pr create in a command substitution: still a boundary"

# 14f. A boundary that uses a heredoc still classifies: its flags precede the redirect.
: > "$METRICS"
payload "$(printf 'gh pr create --title t --body-file - <<%s\nbody text\nEOF' "'EOF'")" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-create "$(jq -r .boundary <<<"$(last_row)")" "gh pr create with a heredoc body: still a boundary"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "gh pr create with a heredoc body: delegated=false (- is not a file)"

# --- #465: a body read from an existing file is a counted opportunity, since
# the hook cannot tell an approved file from one the agent wrote a call earlier ---
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

# 15a-bis. The same post written and posted in one call records identically.
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

# 15c-i. `gh api -F body=@file` counts like every other body-file post.
: > "$METRICS"
out=$(payload "gh api repos/o/r/pulls/355/comments -X POST -F body=@$tmpcwd/drafts/body.md -F in_reply_to=1" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains 'pr-review-reply' "$out" "gh api -F body=@existing: nudges"
assert_eq null "$(jq -r '.state // "null"' <<<"$(last_row)")" "gh api -F body=@existing: no state"

# 15c-ii. A delegation inside the window credits a body-file post: delegate,
# save, post is the workflow the nudge asks for.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", recipe:"pr-description", project:$p}' >> "$METRICS"
out=$(payload "gh pr create --title t --body-file $tmpcwd/drafts/body.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "" "$out" "delegated + body-file: no nudge"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "delegated + body-file: delegated=true"

# 15c-iii. The first segment classifies; a later body-file post does not change it.
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

# 15c-vi. A heredoc write followed by a boundary in the same call: the body is
# data, but the command after the terminator still classifies.
: > "$METRICS"
payload "cat > $tmpcwd/b.md <<'EOF'
some body text
EOF
gh issue create --title t --body-file $tmpcwd/b.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq issue-create "$(jq -r .boundary <<<"$(last_row)")" "heredoc then post: the post still classifies"

# 15c-vii. Wrapper and prefix tokens (sudo, timeout, env assignment, loops)
# are still boundaries: the patterns are not anchored at segment start.
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

# 15. The nudge names a command that runs: every required input from the
# recipe's frontmatter, since delegate.sh exits 2 when one is missing.
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
# The nudge names no tier (#411): the recipe declares its own.
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
# its optional inputs stay out. maintainer-reply's one required var is the
# lead (#517; ask has been optional since #471), so the nudge names the
# recipe, the lead and the redirection; the review recipe still names its
# required verdict.
: > "$METRICS"
out=$(payload 'gh pr comment 42 --body "thanks"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
# The hook's output is JSON, so the hint's quotes arrive escaped.
assert_contains '--recipe maintainer-reply --var lead=\"...\" < context.txt' "$out" "stdin recipe: the required lead is the only var named, ahead of the redirection (#517)"
if [[ "$out" != *'--var ask='* ]]; then
  echo "  PASS  stdin recipe: the optional ask is not named (#471)"; pass=$((pass+1))
else
  echo "  FAIL  stdin recipe: the optional ask is not named (#471)"; fail=$((fail+1))
fi
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

# 17. script_dir is resolved before the cd to the payload cwd, so a relative
# invocation still finds prompts/.
: > "$METRICS"
out=$(cd "$REPO" && payload 'git commit -m "fix: thing"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash scripts/delegate-boundary-hook.sh)
assert_contains '--var why=' "$out" "relative invocation: still resolves prompts/"

# 18. The project is quoted in the rendered command so a name with a space
# still runs. It needs its own repository: a bare subdirectory of $tmpcwd
# would resolve to $tmpcwd's name.
spacedir="$tmpcwd/a project"
mk_repo "$spacedir" >/dev/null 2>&1
: > "$METRICS"
out=$(payload 'git commit -m "fix: thing"' "$spacedir" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
ctx=$(hook_msg "$out")
assert_contains '--project "a project"' "$ctx" "spaced project: quoted in the rendered command"

# --- #385: the boundary's repo is the one the command cd's into -------------
# Two repositories plus a linked worktree, so a basename-of-path
# implementation cannot pass by accident.
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

# 32. A worktree resolves to the repository (via --git-common-dir), not 'wt-x'.
: > "$METRICS"; seed_delegation repo-b commit-message
payload "cd $gitroot/wt-x && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-b "$(jq -r .project <<<"$(last_row)")" "cd: worktree resolves to the repo"

# 33. A cd to a non-repository is not accepted: a scratch basename is not a project.
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

# 36. The cwd stays a lookup candidate beside the cd target: a --project
# delegation (#342) filed under the cwd must still match.
: > "$METRICS"; seed_delegation repo-a commit-message
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "cd: a delegation under the cwd project still matches"

# 37. A delegation under neither candidate still counts as missed.
: > "$METRICS"; seed_delegation some-other-repo commit-message
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "cd: unrelated project still records a miss"

# 38. `cd -` resolves to $OLDPWD, which is not knowable from the payload.
: > "$METRICS"
payload "cd - && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "cd -: rejected, falls back to the cwd"

# 39. A path carrying a shell expansion is rejected, never evaluated.
: > "$METRICS"
payload 'cd $(echo /tmp) && git commit -m x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "cd \$(...): rejected, not expanded"

# 40. A quoted path with a space is parsed: the cd parse runs on the raw
# command because the scan surface blanks quoted spans.
mk_repo "$gitroot/a repo" >/dev/null 2>&1
: > "$METRICS"
payload "cd \"$gitroot/a repo\" && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "a repo" "$(jq -r .project <<<"$(last_row)")" "cd: quoted path with a space is parsed"

# 41. A heredoc body mentioning a cd cannot retarget: the parse is anchored
# at the start of the command.
: > "$METRICS"
payload "git commit -F - <<'EOF'
cd $gitroot/repo-b && git commit -m x
EOF" "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-a "$(jq -r .project <<<"$(last_row)")" "heredoc mentioning cd: not retargeted"

# --- #476: a session cwd outside any repository has NO project, the same
# shape delegate.sh writes from that cwd ---
norepo=$(mktemp -d)

# 41a. No project field at all: not the basename, not an empty string.
: > "$METRICS"
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq 'has("project")' <<<"$(last_row)")" "no-repo cwd: row carries no project field"
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "no-repo cwd: the boundary is still recorded"

# 41b. The nudge omits --project entirely: the command must run as printed
# (bash reads `--project <name>` as a redirection), and only a projectless
# delegation could credit this boundary (41d).
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

# 41b-ii. When the command names its repo the nudge renders it as --project.
: > "$METRICS"
out=$(payload 'gh issue comment 1 --repo owner/repo-b --body x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
ctx=$(hook_msg "$out")
assert_contains '--project "repo-b"' "$ctx" "no-repo cwd + --repo: nudge renders the --repo candidate as --project"

# 41c. A projectless delegation credits a projectless boundary only when its
# `session` equals the payload's session_id (#479): the metrics file is
# shared by every session on the machine.
seed_projectless() { # session|"" recipe
  jq -nc --arg ts "$nowts" --arg s "$1" --arg r "$2" \
    '{ts:$ts, source:"delegate", tier:"prose", recipe:$r} + (if $s != "" then {session:$s} else {} end)' >> "$METRICS"
}
: > "$METRICS"; seed_projectless sess-A commit-message
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: a projectless delegation from THIS session credits the boundary"
assert_eq "" "$out" "no-repo cwd: credited, so no nudge"
assert_eq sess-A "$(jq -r .session <<<"$(last_row)")" "no-repo cwd: the opportunity row records the session too"

# 41c-ii. Another session's delegation, or one with no session, does not credit.
: > "$METRICS"; seed_projectless sess-B commit-message
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: another session's projectless delegation does not credit"
assert_contains 'commit-message' "$(hook_msg "$out")" "no-repo cwd: ...and the nudge fires"
: > "$METRICS"; seed_projectless "" commit-message
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: a projectless delegation with no session does not credit"

# 41c-iii. Consumption is per session too.
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

# 41c-iv. A payload with no session_id can scope nothing, so nothing credits.
: > "$METRICS"; seed_projectless sess-A commit-message
payload 'git commit -m x' "$norepo" "" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: no session_id in the payload credits nothing"
assert_eq false "$(jq 'has("session")' <<<"$(last_row)")" "no-repo cwd: no session_id in the payload writes no session field"

# 41d. No project is not a wildcard: a delegation under a real project does not credit.
: > "$METRICS"; seed_delegation repo-a commit-message
payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no-repo cwd: a delegation under a real project does not credit it"

# 41e. A `cd <repo> &&` from the non-repo cwd files under the cd target, and
# the empty cwd candidate still matches a same-session projectless delegation.
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

# 41g. The converse of 41c: empty matches empty and nothing else.
: > "$METRICS"
jq -nc --arg ts "$nowts" '{ts:$ts, source:"delegate", tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m x' "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "repo cwd: a projectless delegation does not credit it"

# 41h. A failed delegation (non-zero exit_status) produced no draft, so it credits nothing.
: > "$METRICS"
jq -nc --arg ts "$nowts" '{ts:$ts, source:"delegate", project:"repo-a", tier:"prose", recipe:"commit-message", exit_status:3}' >> "$METRICS"
payload 'git commit -m x' "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "repo cwd: a failed delegation (exit_status 3) does not credit"

# 41i. DELEGATE_PROJECT is the override delegate.sh honours, so every row
# lands under one name and a delegation recorded under it credits the post.
: > "$METRICS"; seed_delegation explicit-name commit-message
out=$(payload 'git commit -m x' "$norepo" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK")
assert_eq explicit-name "$(jq -r .project <<<"$(last_row)")" "DELEGATE_PROJECT: recorded as the project from a non-repo cwd"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "DELEGATE_PROJECT: a delegation under it credits the post"
: > "$METRICS"
out=$(payload 'git commit -m x' "$gitroot/repo-a" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK")
assert_eq explicit-name "$(jq -r .project <<<"$(last_row)")" "DELEGATE_PROJECT: wins over the repo cwd, as it does in delegate.sh"
assert_contains '--project \"explicit-name\"' "$out" "DELEGATE_PROJECT: the nudge names it"
# ...and over a cd target, since delegate.sh after that cd records the override.
: > "$METRICS"
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK" >/dev/null
assert_eq explicit-name "$(jq -r .project <<<"$(last_row)")" "DELEGATE_PROJECT: wins over the cd target too"
# ...and neither the physical repo nor the cd target is a lookup candidate
# under the override.
: > "$METRICS"; seed_delegation repo-a commit-message
payload 'git commit -m x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "DELEGATE_PROJECT: the physical repo is not a candidate under the override"
: > "$METRICS"; seed_delegation repo-b commit-message
payload "cd $gitroot/repo-b && git commit -m x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_PROJECT=explicit-name bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "DELEGATE_PROJECT: the cd target is not a candidate under the override"

# --- an explicit --repo widens the lookup only; recording it as the project
# would fragment hub-repo sweeps across rate=0% keys ---

# 42. A delegation under the named repo matches; the recorded project stays the cwd.
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

# 44. A shell variable or expansion in the value is rejected, not used.
for bad in 'IsmaelMartinez/$1' '$R' 'owner/`whoami`' 'owner/../../etc' 'noslash'; do
  : > "$METRICS"; seed_delegation repo-b maintainer-reply
  payload "gh issue comment 1 --repo $bad --body x" "$gitroot/repo-a" \
    | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: rejects '$bad'"
done

# 45. A bare --repo, or one followed by another flag, falls back.
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

# 47. A quoted value is blanked by the scan surface and falls back (the
# opposite trade-off from the cd parse, which reads the raw command).
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload 'gh issue comment 1 --repo "owner/repo-b" --body x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: quoted value falls back (known trade-off)"

# 48. A --repo inside the quoted body cannot reach the parse.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload 'gh issue comment 1 --repo owner/repo-c --body "see --repo owner/repo-b"' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "--repo: value inside a quoted body is not parsed"

# 49. With both a leading cd and a --repo, the cd target owns the recorded
# project and both are lookup candidates.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload "cd $gitroot/repo-b && gh issue comment 1 --repo owner/repo-c --body x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq repo-b "$(jq -r .project <<<"$(last_row)")" "cd + --repo: cd target owns the recorded project"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "cd + --repo: cd target still matches the lookup"

# 49b. `glab --repo` accepts GROUP/NAMESPACE/REPO, so the value regex allows
# more than one slash and the project is the final segment.
: > "$METRICS"; seed_delegation repo-b maintainer-reply
payload "glab mr note 1 --repo group/namespace/repo-b --message x" "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "--repo: glab GROUP/NAMESPACE/REPO resolves to the final segment"

# 50. A projectless delegate row must not match an empty --repo candidate:
# an unguarded `(.project // "") == $proj3` would credit every boundary.
: > "$METRICS"
jq -nc --arg ts "$nowts" '{ts:$ts, source:"delegate", tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m x' "$gitroot/repo-a" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "projectless delegate row does not match an empty --repo candidate"

# 51. One delegation credits exactly one post; the delegated:true opportunity
# row spends it.
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

# 52b (#503). A spend outlives the delegation it consumed: delegation at
# T-500m, credited post at T-470m, then a fresh delegation now. Netting
# in-window rows (1 delegation, 1 spend) read the fresh one as spent and
# denied a session that had just delegated; replaying the spend against
# its own window pairs it with the old row and leaves the new one to credit.
: > "$METRICS"
old_d=$(jq -rn --argjson now "$(date -u +%s)" '($now - 30000) | todateiso8601')
old_s=$(jq -rn --argjson now "$(date -u +%s)" '($now - 28200) | todateiso8601')
jq -nc --arg ts "$old_d" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message", draft_file:"old.draft.txt"}' >> "$METRICS"
jq -nc --arg ts "$old_s" --arg p "$proj" \
  '{ts:$ts, source:"opportunity", boundary:"git-commit", suggested_recipe:"commit-message", delegated:true, project:$p}' >> "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message", draft_file:"new.draft.txt"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "window replay: a spend that consumed an aged-out delegation does not cancel a fresh one"
payload 'git commit -m "y"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "window replay: ...and the fresh one is still spent exactly once"
# The mirror: a spend inside the window with NO earning row in its own
# window (the delegation was outside the window when it was credited, or
# has left the tail) is not charged against a later delegation either.
: > "$METRICS"
jq -nc --arg ts "$old_s" --arg p "$proj" \
  '{ts:$ts, source:"opportunity", boundary:"git-commit", suggested_recipe:"commit-message", delegated:true, project:$p}' >> "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "window replay: an orphan spend is not charged to a later delegation"
# Same second, file order decides: a delegation appended AFTER an orphan spend
# in the same second was not there to be spent, so it still credits.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"opportunity", boundary:"git-commit", suggested_recipe:"commit-message", delegated:true, project:$p}' >> "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "window replay: a same-second delegation appended after a spend is not consumed by it"
# ...and one appended BEFORE it in the same second is.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"opportunity", boundary:"git-commit", suggested_recipe:"commit-message", delegated:true, project:$p}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "window replay: a same-second delegation appended before the spend is consumed by it"

# 53. The default window covers a 3-hour-old delegation (delegate, await
# approval, post).
: > "$METRICS"
threehrs=$(jq -rn --argjson now "$(date -u +%s)" '($now - 10800) | todateiso8601')
jq -nc --arg ts "$threehrs" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "default window: 3h-old delegation credits"

# 54. Consumption is per project+recipe.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"opportunity", boundary:"pr-create", suggested_recipe:"pr-description", delegated:true, project:$p}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "consumption: other-recipe credit spend does not count"

# 55. A delegate row under 600 newer rows still credits: a too-small tail
# drops the earning rows first and reads as spent > earned.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"commit-message"}' >> "$METRICS"
jq -nc --arg ts "$nowts" 'range(600) | {ts:$ts, source:"opportunity", boundary:"comment-reply", suggested_recipe:"maintainer-reply", delegated:false, project:"unrelated-filler"}' >> "$METRICS"
payload 'git commit -m "x"' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "tail depth: delegate row under 600 filler rows still credits"

( cd "$gitroot/repo-b" && git worktree remove --force "$gitroot/wt-x" ) >/dev/null 2>&1

# 56. pr-review-body: `gh pr review --body` routes to maintainer-review-reply.
: > "$METRICS"
payload 'gh pr review 2822 --comment --body "the rework is right and this is not a regression"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "pr-review-body" "$(jq -r .boundary <<<"$(last_row)")" \
  "pr-review-body: gh pr review --body is a boundary"
assert_eq "maintainer-review-reply" "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "pr-review-body: it routes to maintainer-review-reply"
out=$(payload 'gh pr review 2822 --comment --body "x"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_contains "--recipe maintainer-review-reply" "$out" \
  "pr-review-body: the nudge names maintainer-review-reply"

# 57. `/pulls/<n>/reviews` is the same boundary; `/pulls/<n>/comments` is an
# inline reply and stays pr-review-reply.
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

# 57-i. A reviews POST with no body= has no text to intercept.
: > "$METRICS"
payload 'gh api repos/o/r/pulls/12/reviews -X POST -f event=APPROVE' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq 0 "$(nrows)" "pr-review-body: a reviews POST with no body= writes no row"

# 58. A short status comment still routes to the closed shape.
: > "$METRICS"
payload 'gh pr comment 2822 --body "thanks, merged"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "comment-reply" "$(jq -r .boundary <<<"$(last_row)")" \
  "pr-review-body: gh pr comment is still comment-reply"
assert_eq "maintainer-reply" "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "pr-review-body: gh pr comment still routes to maintainer-reply"

# 59. No inline body, no drafting moment.
: > "$METRICS"
payload 'gh pr review 2822 --approve' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq 0 "$(nrows)" "pr-review-body: a bare --approve writes no row"
payload 'gh pr review 2822 --web' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq 0 "$(nrows)" "pr-review-body: --web writes no row"

# --- 58. comment-reply routes by body length: maintainer-reply is the short
# shape, maintainer-review-reply the evidence-led one ---
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

# 58d-ii. Only a regular file is read: `wc -c < /dev/zero` never returns.
: > "$METRICS"
payload "gh pr comment 12 --body-file /dev/zero" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" perl -e 'alarm 15; exec @ARGV' bash "$HOOK" >/dev/null 2>&1
ec=$?
# perl's alarm, not GNU `timeout`, which macOS lacks; a regression exits 142.
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

# 58d-v. A --body-file outranks an inline --body in the same command.
: > "$METRICS"
payload "gh pr comment 12 --body \"short\" --body-file $tmpcwd/long.md" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null 2>&1
assert_eq maintainer-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: --body-file outranks an inline body in the same command"

# 58d-vi. A flag inside quoted prose is data: the measurement reads the raw
# command and has to skip quoted spans itself.
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

# 58e. The threshold is overridable.
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

# 58g. A long PR-review-comment body is still pr-review-reply: that branch
# matches first.
: > "$METRICS"
payload "gh api repos/o/r/pulls/12/comments -X POST -f body=\"$long_body\"" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-review-reply "$(jq -r .suggested_recipe <<<"$(last_row)")" \
  "comment-reply: the inline review-comment branch still wins on a long body"

# --- Capturing the posted body as the shipped half of the (draft, final)
# pair: inline posts never reach a file `--final` could name ---
cap_setup() { # -> sets capdir capm capcwd capproj; seeds one delegate row
  capdir=$(mktemp -d); capm="$capdir/metrics.jsonl"
  capcwd=$(mktemp -d); mk_repo "$capcwd" >/dev/null 2>&1; capproj=$(basename "$capcwd")
  capts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","project":"%s","draft_file":"20260827T100000Z-aaaa1111.draft.txt"}\n' \
    "$capts" "$capproj" > "$capm"
}
cap_pre() { payload "$1" "$capcwd" | DELEGATE_METRICS_FILE="$capm" bash "$HOOK" >/dev/null 2>&1; }
# A body is stored only once the call has run (#587): the PreToolUse hook
# leaves a marker holding the inline text or naming the file, and the
# PostToolUse confirm hook stores it after the call succeeded.
cap_post() { cap_post_run "$@"; }
cap_post_run() { # cmd [extra env assignment]
  jq -nc --arg cmd "$1" --arg cwd "$capcwd" --arg ev PreToolUse \
    '{hook_event_name:$ev, tool_name:"Bash", cwd:$cwd, session_id:"sess-C", tool_use_id:"toolu-C", tool_input:{command:$cmd}}' \
    | env ${2:+"$2"} DELEGATE_METRICS_FILE="$capm" bash "$HOOK" >/dev/null 2>&1
  jq -nc --arg cmd "$1" --arg cwd "$capcwd" --arg ev PostToolUse \
    '{hook_event_name:$ev, tool_name:"Bash", cwd:$cwd, session_id:"sess-C", tool_use_id:"toolu-C", tool_input:{command:$cmd}, tool_response:{interrupted:false}}' \
    | DELEGATE_METRICS_FILE="$capm" bash "$REPO/scripts/delegate-boundary-confirm-hook.sh" >/dev/null 2>&1
}

cap_setup
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq true "$(jq -r .delegated <<<"$(tail -1 "$capm")")" \
  "capture: the post is credited to the delegation"
assert_eq "the fix landed in abc1234" "$(cat "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt" 2>/dev/null)" \
  "capture: a credited post stores the posted body under the credited draft's stem"
rm -rf "$capdir" "$capcwd"

# Uncredited: there is no draft this post is the shipped form of.
cap_setup
: > "$capm"
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq false "$(jq -r .delegated <<<"$(tail -1 "$capm")")" "capture: uncredited post is not credited"
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" "capture: an uncredited post stores nothing"
rm -rf "$capdir" "$capcwd"

# An existing final (hand-supplied via --final) is never overwritten.
cap_setup
mkdir -p "$capdir/drafts"
printf 'what the human actually shipped' > "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt"
cap_post 'gh pr comment 12 --body "a different body entirely"'
assert_eq "what the human actually shipped" "$(cat "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt")" \
  "capture: an existing final is not overwritten"
rm -rf "$capdir" "$capcwd"

# Opting out of metrics opts out of the capture too.
cap_setup
payload 'gh pr comment 12 --body "the fix landed in abc1234"' "$capcwd" \
  | DELEGATE_METRICS_FILE="$capm" DELEGATE_LOCAL_NO_METRICS=1 bash "$HOOK" >/dev/null 2>&1
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" \
  "capture: DELEGATE_LOCAL_NO_METRICS=1 stores nothing"
rm -rf "$capdir" "$capcwd"

# Verbatim outbound text: neither directory nor file may inherit a permissive umask.
cap_setup
( umask 000; cap_post 'gh pr comment 12 --body "the fix landed in abc1234"' )
assert_eq 700 "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$capdir/drafts")" \
  "capture: drafts directory is private (700) under a permissive umask"
assert_eq 600 "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt")" \
  "capture: stored body is private (600) under a permissive umask"
rm -rf "$capdir" "$capcwd"

# Oldest-unspent-first: a sweep delegates a batch and posts in that order, so
# the next post belongs to the second draft.
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

# A --body-file post stores the file's contents, once the call has run.
cap_setup
printf 'the reply that came from a file\n' > "$capcwd/reply.md"
cap_pre "gh pr comment 12 --body-file $capcwd/reply.md"
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" \
  "capture: a --body-file post stores nothing before the call has run"
rm -rf "$capdir" "$capcwd"; cap_setup; printf 'the reply that came from a file\n' > "$capcwd/reply.md"
cap_post_run "gh pr comment 12 --body-file $capcwd/reply.md"
assert_eq "the reply that came from a file" "$(cat "$capdir/drafts/20260827T100000Z-aaaa1111.final.txt" 2>/dev/null)" \
  "capture: a --body-file post stores the file's contents"
rm -rf "$capdir" "$capcwd"

# --- #461: the `gh api` field flags (-f / -F / --raw-field / --field) carry
# the body when the key is `body`; `-F` without `=` is still a body-file path ---
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

# A field whose key is not `body` is not the body, even when it is longer.
cap_setup_recipe maintainer-review-reply
cap_post 'gh api repos/o/r/pulls/12/reviews -X POST -f body=hello -f event=COMMENT'
assert_eq "hello" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: a non-body field key is not mistaken for the body"
rm -rf "$capdir" "$capcwd"

# `-F body=@file` names a file, so its contents are stored.
cap_setup_recipe pr-review-reply
printf 'the reply that came from a field file' > "$capcwd/reply.md"
cap_post_run "gh api repos/o/r/pulls/12/comments -X POST -F body=@$capcwd/reply.md -F in_reply_to=1"
assert_eq "the reply that came from a field file" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: -F body=@file stores the file's contents"
rm -rf "$capdir" "$capcwd"

# The long forms of the same two flags.
cap_setup_recipe pr-review-reply
cap_post 'gh api repos/o/r/pulls/12/comments -X POST --raw-field body="the long form" --field in_reply_to=9'
assert_eq "the long form" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: --raw-field body= is the posted body"
rm -rf "$capdir" "$capcwd"

# A POST with no body field stores nothing.
cap_setup_recipe pr-review-reply
cap_post 'gh api repos/o/r/pulls/12/comments -X POST -F in_reply_to=99 -F commit_id=abc1234'
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" \
  "capture: a POST with no body field stores nothing"
rm -rf "$capdir" "$capcwd"

# A bare `-F path` (no `=`) is still `--body-file`.
cap_setup
printf 'the reply posted with the short flag' > "$capcwd/reply.md"
cap_post_run "gh pr comment 12 -F $capcwd/reply.md"
assert_eq "the reply posted with the short flag" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "capture: a bare -F path is still a body file"
rm -rf "$capdir" "$capcwd"


# A delegation with no captured draft has no stem to file the post under.
cap_setup
printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","project":"%s"}\n' "$capts" "$capproj" > "$capm"
cap_post 'gh pr comment 12 --body "the fix landed in abc1234"'
assert_eq true "$(jq -r .delegated <<<"$(tail -1 "$capm")")" "capture: draftless delegation still credits the post"
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" "capture: a draftless delegation stores nothing"
rm -rf "$capdir" "$capcwd"

# draft_file is untrusted input that becomes part of a written path: a bare
# filename ending in .draft.txt, or nothing at all.
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

# --- #483, #521: the five proven boundaries deny by default; pr-create
# stays on warn. These run at the default body floor with bodies long enough
# to be real drafting ---
body300=$(python3 -c "print('The sandbox flag in src/main.js is the cause, not your distro. ' * 5)")
dflt() { DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }
# Provider down: the mock is off PATH and the real curl hits a closed port.
down() { PATH="${PATH#$MOCKDIR:}" DELEGATE_BASE_URL=http://localhost:1/v1 DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }

# 60. Each proven boundary is denied without a credit, with the runnable
# reminder as the reason and `denied:true` on the row so the retry is not
# counted twice.
for spec in \
  "git-commit|commit-message|git commit -m \"$body300\"" \
  "issue-create|github-issue-body|gh issue create --title t --body \"$body300\"" \
  "comment-reply|maintainer-reply|gh pr comment 12 --body \"$body300\"" \
  "pr-review-comment|pr-review-reply|gh api repos/o/r/pulls/12/comments -X POST -f body=\"$body300\" -F in_reply_to=9" \
  "pr-review-body|maintainer-review-reply|gh pr review 12 --comment --body \"$body300\""; do
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

# 60a. #521: a pr-review-body post read from a --body-file is denied the same
# as an inline body, with no delegation behind it.
: > "$METRICS"
mkdir -p "$tmpcwd/drafts"
printf '%s' "$body300" > "$tmpcwd/drafts/review-body.md"
out=$(payload "gh pr review 12 --comment --body-file $tmpcwd/drafts/review-body.md" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "enforce: pr-review-body --body-file is denied without a credit"
assert_eq pr-review-body "$(jq -r .boundary <<<"$(last_row)")" "enforce: pr-review-body --body-file row recorded"
assert_eq true "$(jq -r '.denied // false' <<<"$(last_row)")" "enforce: pr-review-body --body-file row carries denied:true"

# 61. pr-create stays on warn: its recipe is not proven.
spec="pr-create|gh pr create --title t --body \"$body300\""
b="${spec%%|*}"; c="${spec#*|}"
: > "$METRICS"; rm -f "$MOCKDIR/probed"
out=$(payload "$c" "$tmpcwd" | dflt bash "$HOOK")
assert_nudge "$out" "warn: $b is only warned by default"
assert_contains '"additionalContext"' "$out" "warn: $b reminder is non-blocking"
assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "warn: $b row carries no denied field"
assert_eq "absent" "$([[ -e "$MOCKDIR/probed" ]] && echo present || echo absent)" "warn: $b did not probe the provider"

# 62. DELEGATE_BOUNDARY_MODE=warn/off win over the set, =enforce means every
# boundary; DELEGATE_BOUNDARY_ENFORCE is the comma-separated set, empty is none.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=warn dflt bash "$HOOK")
assert_nudge "$out" "override: MODE=warn downgrades an enforced boundary to a reminder"
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
assert_nudge "$out" "override: ENFORCE=pr-create leaves git-commit on warn"
: > "$METRICS"
out=$(payload "gh pr review 12 --comment --body \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_ENFORCE=git-commit dflt bash "$HOOK")
assert_nudge "$out" "override: ENFORCE=git-commit restores warn for pr-review-body"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_ENFORCE= dflt bash "$HOOK")
assert_nudge "$out" "override: ENFORCE= (empty) enforces nothing"
: > "$METRICS"
out=$(payload "gh pr comment 12 --body \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_ENFORCE="git-commit, comment-reply" dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "override: ENFORCE tolerates a space after the comma"

# 63. Fail open when no provider answers: the deny becomes a reminder and the
# row says so.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | down bash "$HOOK")
assert_nudge "$out" "no provider: an enforced boundary is not denied"
assert_contains 'commit-message' "$(hook_msg "$out")" "no provider: the reminder still fires"
assert_contains 'No local provider answered' "$(hook_msg "$out")" "no provider: the reminder says why the call proceeds"
assert_eq no-provider "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "no provider: row records enforce_skipped=no-provider"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "no provider: row is still a real miss (delegated=false)"
assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "no provider: row carries no denied field"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=enforce down bash "$HOOK")
assert_nudge "$out" "no provider: explicit MODE=enforce fails open too"
# A credited post never probes.
: > "$METRICS"; seed_delegation "$proj" commit-message; rm -f "$MOCKDIR/probed"
payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "absent" "$([[ -e "$MOCKDIR/probed" ]] && echo present || echo absent)" "no probe: a credited post does not probe the provider"

# 64. The body-length floor: `body_chars` (an integer, never the text) on
# every measurable row; under DELEGATE_BOUNDARY_MIN_CHARS the hook neither
# nudges nor denies and marks the row `below_floor:true`.
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
# A commit whose message the shell would expand has no measurable body: no
# body_chars, and enforced.
: > "$METRICS"
out=$(payload 'git commit -m "$MSG"' "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "floor: a commit with no measurable body is enforced"
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "floor: no measurable body, no body_chars field"
# A message on stdin (`-F -`) from a heredoc is that heredoc, measured (#562).
: > "$METRICS"
out=$(payload "git commit -F - <<'EOF'
$body300
EOF" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "floor: a -F - heredoc commit over the floor is enforced"
assert_eq "$(( ${#body300} + 1 ))" "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "floor: a -F - heredoc commit records its length"
assert_eq false "$(jq 'has("below_floor")' <<<"$(last_row)")" "floor: a -F - heredoc commit over the floor carries no below_floor field"
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

# 65. `git commit -m "$(cat <<'EOF' … EOF)"` is measured as the text between
# the delimiters; a quote or paren inside the message does not end it early.
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
# ...and a credited commit stores the same text as its final.
cap_setup_recipe commit-message
cap_post_run "$cc" "DELEGATE_BOUNDARY_MIN_CHARS="
assert_eq "$commit_body" "$(cat "$capdir/$capfinal" 2>/dev/null)" "commit -m: a credited commit stores the unwrapped message as its final"
rm -rf "$capdir" "$capcwd"

# --- Deny bypasses (#484) ---

# 66. A body holding an unresolved `$`, backtick or `$(` (other than the
# `-m "$(cat <<'EOF' … EOF)"` shape) is unmeasurable: no body_chars, no
# below_floor, enforced.
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
# Credited and unmeasurable: no below_floor, and no final stored, since the
# literal text is not what shipped.
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

# 67. Either comment-reply recipe credits a comment-reply boundary, or a
# long post denied under one name is denied again when its shorter draft
# routes to the other.
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

# 68. The body is read from the matched segment, not the whole compound command.
: > "$METRICS"
out=$(payload "git commit -m \"fix: x\" && gh pr create --title t --body \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_eq git-commit "$(jq -r .boundary <<<"$(last_row)")" "segment scope: the first segment classifies"
assert_eq 6 "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "segment scope: the commit is measured, not the PR body"
assert_eq "" "$out" "segment scope: a 6-char commit is below its floor, not denied on the PR body's length"
cap_setup_recipe commit-message
printf 'notes that are not the commit message\n' > "$capcwd/notes.md"
cap_post_run "git commit -m \"fix: thing\" && gh pr comment 1 --body-file $capcwd/notes.md" "DELEGATE_BOUNDARY_MIN_CHARS="
assert_eq "fix: thing" "$(cat "$capdir/$capfinal" 2>/dev/null)" "segment scope: the commit's final is its own message, not a later --body-file"
rm -rf "$capdir" "$capcwd"

# 69. Repeated `-m` are paragraphs git joins with a blank line, so they are summed.
para1='fix: the subject line, forty characters'
para2='and the body paragraph, also forty chars'
: > "$METRICS"
out=$(payload "git commit -m \"$para1\" -m \"$para2\"" "$tmpcwd" | DELEGATE_BOUNDARY_MIN_CHARS=60 DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "$(( ${#para1} + 2 + ${#para2} ))" "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "summed -m: body_chars is both paragraphs plus the blank line"
assert_contains '"permissionDecision":"deny"' "$out" "summed -m: two 40-char paragraphs clear a 60-char floor together"

# 70. Never a permanent block, never a free pass: after two consecutive
# denials for the same session and boundary the third attempt is warned
# (enforce_skipped:"retry-cap") ONLY when the session recorded a delegation
# for the recipe since the streak began (#511). A plain retry records nothing
# and stays denied; a metrics file the hook cannot append to fails open.
seed_denied() { # session boundary [ts]
  jq -nc --arg ts "${3:-$nowts}" --arg p "$proj" --arg s "$1" --arg b "$2" \
    '{ts:$ts, source:"opportunity", boundary:$b, suggested_recipe:"x", delegated:false, denied:true, project:$p, session:$s}' >> "$METRICS"
}
seed_attempt() { # session recipe [ts] [exit_status] -- a delegate row that did not credit
  jq -nc --arg ts "${3:-$nowts}" --arg s "$1" --arg r "$2" --argjson ec "${4:-0}" \
    '{ts:$ts, source:"delegate", project:"elsewhere", recipe:$r, tier:"prose", session:$s, exit_status:$ec}' >> "$METRICS"
}
# Two denials and a delegation after them (credited nowhere: wrong project) open the cap.
: > "$METRICS"; seed_denied sess-A git-commit; seed_denied sess-A git-commit; seed_attempt sess-A commit-message
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_nudge "$out" "retry cap: two denials plus a delegation since -> the third attempt is not denied"
assert_eq retry-cap "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "retry cap: the row records enforce_skipped=retry-cap"
assert_eq false "$(jq 'has("denied")' <<<"$(last_row)")" "retry cap: the row is not a denial"
assert_contains 'twice' "$(hook_msg "$out")" "retry cap: the reminder says why the call proceeds"
# A failed delegation (canary stall, exit 3) is still an attempt.
: > "$METRICS"; seed_denied sess-A git-commit; seed_denied sess-A git-commit; seed_attempt sess-A commit-message "$nowts" 3
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_nudge "$out" "retry cap: a delegation that failed (exit 3) still counts as the attempt"
# Two denials and NOTHING delegated: the third, fourth and fifth stay denied.
: > "$METRICS"
for i in 1 2 3 4 5; do
  out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
  assert_contains '"permissionDecision":"deny"' "$out" "retry cap: plain retry $i with no delegation is denied (#511)"
done
assert_eq 0 "$(jq -r 'select(.enforce_skipped == "retry-cap") | 1' "$METRICS" | wc -l | tr -d ' ')" "retry cap: no fall-open row was written for the plain retries"
# A delegation BEFORE the streak began is not the attempt the streak asks for.
: > "$METRICS"
seed_attempt sess-A commit-message "$(jq -rn --arg now "$nowts" '($now | fromdateiso8601) - 120 | todateiso8601')"
seed_denied sess-A git-commit; seed_denied sess-A git-commit
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: a delegation from before the streak does not open it"
# Same second as the first denial: file order decides, as in the spend replay.
: > "$METRICS"; seed_attempt sess-A commit-message; seed_denied sess-A git-commit; seed_denied sess-A git-commit
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: a same-second delegation appended BEFORE the first denial does not open the cap"
: > "$METRICS"; seed_denied sess-A git-commit; seed_attempt sess-A commit-message; seed_denied sess-A git-commit
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_nudge "$out" "retry cap: a same-second delegation appended AFTER the first denial opens it"
# Another session's delegation does not count for this one.
: > "$METRICS"; seed_denied sess-A git-commit; seed_denied sess-A git-commit; seed_attempt sess-B commit-message
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: another session's delegation does not open this session's cap"
# A delegation for another recipe does not count either.
: > "$METRICS"; seed_denied sess-A git-commit; seed_denied sess-A git-commit; seed_attempt sess-A pr-description
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: a delegation for another recipe does not open the cap"
# A credited post in between resets the streak, so the cap cannot be banked.
: > "$METRICS"; seed_denied sess-A git-commit; seed_denied sess-A git-commit
jq -nc --arg ts "$nowts" --arg p "$proj" '{ts:$ts, source:"opportunity", boundary:"git-commit", suggested_recipe:"commit-message", delegated:true, project:$p, session:"sess-A"}' >> "$METRICS"
seed_attempt sess-A commit-message
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: a later non-denied row resets the streak"
# Scoped to the session and the boundary.
: > "$METRICS"; seed_denied sess-B git-commit; seed_denied sess-B git-commit; seed_attempt sess-A commit-message
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: another session's denials do not count"
: > "$METRICS"; seed_denied sess-A comment-reply; seed_denied sess-A comment-reply; seed_attempt sess-A commit-message
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: another boundary's denials do not count"
# Outside the window the denials have expired.
: > "$METRICS"; seed_denied sess-A git-commit 2020-01-01T00:00:00Z; seed_denied sess-A git-commit 2020-01-01T00:00:01Z; seed_attempt sess-A commit-message
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "retry cap: denials outside the window do not count"
# Metrics unwritable: a directory where the file should be.
unwritable=$(mktemp -d)
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$unwritable" bash "$HOOK")
assert_nudge "$out" "metrics unwritable: the boundary is not denied"
assert_contains 'metrics' "$(hook_msg "$out")" "metrics unwritable: the reminder says the row could not be written"
rmdir "$unwritable"

# 71. DELEGATE_BOUNDARY_MODE is case-insensitive and an unknown value is warn.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=Off dflt bash "$HOOK")
assert_eq "" "$out" "mode: Off is off"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=WARN dflt bash "$HOOK")
assert_nudge "$out" "mode: WARN is warn"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=0 dflt bash "$HOOK")
assert_nudge "$out" "mode: an unknown value (0) is warn, not enforce"
: > "$METRICS"
out=$(payload "gh pr create --title t --body \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_MODE=Enforce dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "mode: Enforce is enforce"

# 72. No provider, no model for the tier, and a malformed tier are told
# apart on the row and in the reminder, as pick-model.sh tells them apart.
MOCKDIR2=$(mktemp -d)
sed 's/test-prose-model/nomic-embed-text/' "$MOCKDIR/curl" > "$MOCKDIR2/curl"; chmod +x "$MOCKDIR2/curl"
nomodel() { PATH="$MOCKDIR2:${PATH#$MOCKDIR:}" DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | nomodel bash "$HOOK")
assert_nudge "$out" "no model: fails open"
assert_eq no-model "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "no model: the row says no-model, not no-provider"
assert_contains 'no model for the prose tier' "$(hook_msg "$out")" "no model: the reminder names the tier that has no model"
rm -rf "$MOCKDIR2"
badtier=$(mktemp -d)
sed 's/^tier: prose$/tier: bogus/' "$REPO/prompts/commit-message.md" > "$badtier/commit-message.md"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_PROMPTS_DIR="$badtier" dflt bash "$HOOK")
assert_nudge "$out" "bad tier: fails open"
assert_eq bad-tier "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "bad tier: the row says bad-tier"
assert_contains "'bogus'" "$(hook_msg "$out")" "bad tier: the reminder names the tier the recipe declares"
# The tier is read the way delegate.sh reads it: trailing whitespace is not a different tier.
sed 's/^tier: prose$/tier: prose   /' "$REPO/prompts/commit-message.md" > "$badtier/commit-message.md"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_PROMPTS_DIR="$badtier" dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "tier read: 'tier: prose   ' resolves like delegate.sh and is enforced"
rm -rf "$badtier"

# 73. Per-boundary floors: 20 for git-commit (a subject line), 120 for the
# rest; DELEGATE_BOUNDARY_MIN_CHARS is the global override.
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

# 74. One credit, two hooks at once: lookup and append are serialised with a
# mkdir lock so both cannot spend the same credit.
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
# A live lock never released fails open after the timeout and is never
# removed by a non-owner.
mkdir -p "$lockdir"; printf '%s' "$(date -u +%s)" > "$lockdir/ts"; printf 'someone-else' > "$lockdir/owner"
# DELEGATE_BOUNDARY_LOCK_WAIT_MS shortens the default 2 s wait.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_LOCK_WAIT_MS=200 dflt bash "$HOOK")
assert_nudge "$out" "lock: an unobtainable lock fails open"
assert_eq lock-timeout "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "lock: ...recording enforce_skipped=lock-timeout"
assert_eq "present" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock: a live lock is not removed by a non-owner"
assert_eq "someone-else" "$(cat "$lockdir/owner" 2>/dev/null)" "lock: ...and its owner file is untouched"
# A leading zero is decimal, not octal: 08 is an 8 ms wait (one try), not an
# arithmetic abort that skips the boundary.
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | DELEGATE_BOUNDARY_LOCK_WAIT_MS=08 DELEGATE_BOUNDARY_LOCK_STALE_SEC=09 dflt bash "$HOOK" 2>&1)
assert_eq lock-timeout "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "lock: a zero-padded wait (08) is decimal and still times out"
rm -rf "$lockdir"

# 76. An empty measurable body is a known 0-character post, not an unknown
# one: body_chars:0, below_floor:true, no nudge, no deny.
: > "$METRICS"
out=$(payload 'gh pr comment 12 --body ""' "$tmpcwd" | dflt bash "$HOOK")
assert_eq "" "$out" "empty body: --body \"\" is neither nudged nor denied"
assert_eq 0 "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "empty body: --body \"\" records body_chars:0"
assert_eq true "$(jq -r '.below_floor // false' <<<"$(last_row)")" "empty body: --body \"\" is below_floor"
: > "$tmpcwd/empty.md"
: > "$METRICS"
out=$(payload "gh issue create --title t --body-file $tmpcwd/empty.md" "$tmpcwd" | dflt bash "$HOOK")
assert_eq "" "$out" "empty body: an empty --body-file is neither nudged nor denied"
assert_eq 0 "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "empty body: an empty --body-file records body_chars:0"
assert_eq true "$(jq -r '.below_floor // false' <<<"$(last_row)")" "empty body: an empty --body-file is below_floor"
# ...while a body the shell would expand is still unmeasurable.
: > "$METRICS"
out=$(payload 'git commit -F "$MSG_FILE"' "$tmpcwd" | dflt bash "$HOOK")
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "empty body: an unmeasurable body is still no body_chars"

# 75. Lock ownership: a lock broken as stale must not be removed by its
# original holder's exit cleanup. The slow holder is a jq wrapper sleeping
# on the lookup's `-rs` slurp. DELEGATE_BOUNDARY_LOCK_STALE_SEC=0 makes any
# lock from an earlier second stale, so A holds 3 s, B starts at 1.5 s (A's
# lock reads stale; B's now_epoch is at least one second past A's ts) and
# holds 3 s; the lock must survive A's exit and vanish when B finishes. Under
# the default 5 s threshold B would wait out the 2 s timeout and never take it.
REAL_JQ=$(command -v jq)
slow_jq() { # dir seconds
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\ncase " $* " in *" -rs "*) sleep %s ;; esac\nexec %q "$@"\n' "$2" "$REAL_JQ" > "$1/jq"
  chmod +x "$1/jq"
}
SLOWA=$(mktemp -d); slow_jq "$SLOWA" 3
SLOWB=$(mktemp -d); slow_jq "$SLOWB" 3
slow() { PATH="$1:$PATH" DELEGATE_BOUNDARY_LOCK_STALE_SEC=0 DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "${@:2}"; }
: > "$METRICS"; rm -rf "$lockdir"
payload "git commit -m \"$body300\"" "$tmpcwd" | slow "$SLOWA" bash "$HOOK" >/dev/null &
pid_a=$!
sleep 1.5
payload "git commit -m \"$body300\"" "$tmpcwd" | slow "$SLOWB" bash "$HOOK" >/dev/null &
pid_b=$!
wait "$pid_a"
assert_eq "present" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock owner: A's exit leaves B's replacement lock in place"
wait "$pid_b"
assert_eq "absent" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock owner: B releases its own lock when it finishes"
assert_eq 2 "$(grep -c '"denied":true' "$METRICS")" "lock owner: both boundaries were judged (denied, no credit)"
rm -rf "$SLOWA" "$SLOWB"

# 75b. The provider probe runs outside the lock: two 2 s probes started 0.5 s
# apart finish in about one probe's time.
SLOWC=$(mktemp -d)
{ printf '#!/usr/bin/env bash\nsleep 2\n'; sed '1d;/^: >> /d' "$MOCKDIR/curl"; } > "$SLOWC/curl"; chmod +x "$SLOWC/curl"
slowc() { PATH="$SLOWC:${PATH#$MOCKDIR:}" DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }
: > "$METRICS"; rm -rf "$lockdir"
t0=$(date +%s)
payload "git commit -m \"$body300\"" "$tmpcwd" | slowc bash "$HOOK" >/dev/null &
pid_a=$!
sleep 0.5
payload "git commit -m \"$body300\"" "$tmpcwd" | slowc bash "$HOOK" >/dev/null &
pid_b=$!
wait "$pid_a" "$pid_b"
elapsed=$(( $(date +%s) - t0 ))
assert_eq "yes" "$([[ $elapsed -le 4 ]] && echo yes || echo "no (${elapsed}s)")" "probe outside lock: two slow probes overlap instead of queueing on the lock"
assert_eq 2 "$(grep -c '"denied":true' "$METRICS")" "probe outside lock: both boundaries were judged"
rm -rf "$SLOWC"

# 77. A lock dir with no `ts` (a hook killed between mkdir and the write) is
# stale once the directory itself is older than the threshold.
rm -rf "$lockdir"; mkdir -p "$lockdir"; touch -t 202001010000 "$lockdir"
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "incomplete lock: an old ts-less lock dir is broken and the boundary judged"
assert_eq "absent" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "incomplete lock: ...and released afterwards"

# 78. A relative `--body-file` resolves against the payload cwd, or the
# leading `cd <path> &&` target when there is one.
printf '%s' "$body300" > "$tmpcwd/reply.md"
: > "$METRICS"
payload 'gh pr comment 1 --body-file reply.md' "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "${#body300}" "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "relative body-file: resolved against the payload cwd"
mk_repo "$gitroot/repo-c" >/dev/null 2>&1
printf 'short' > "$gitroot/repo-c/reply.md"
: > "$METRICS"
out=$(payload "cd $gitroot/repo-c && gh pr comment 1 --body-file reply.md" "$tmpcwd" | dflt bash "$HOOK")
assert_eq 5 "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "relative body-file: resolved against the cd target"
assert_eq "" "$out" "relative body-file: ...so the 5-char reply is under the floor, not enforced as unmeasurable"
rm -f "$tmpcwd/reply.md"

# 79 (#489). A body-file path opening with `$NAME` / `${NAME}` is resolved by
# lookup in the hook's environment, never by expansion: set → measured and
# captured; unset, `$(...)`, or a further `$` → unmeasurable as before.
envdir=$(mktemp -d)
printf '%s' "$body300" > "$envdir/rr.txt"
: > "$METRICS"
payload 'gh api repos/o/r/pulls/1/comments -X POST --field body=@"$T489_DIR/rr.txt" -F in_reply_to=9' "$tmpcwd" | T489_DIR="$envdir" dflt bash "$HOOK" >/dev/null
assert_eq "${#body300}" "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "env path: body=@\"\$VAR/file\" measures the file when VAR is set in the hook env"
: > "$METRICS"
payload 'gh pr comment 1 --body-file "${T489_DIR}/rr.txt"' "$tmpcwd" | T489_DIR="$envdir" dflt bash "$HOOK" >/dev/null
assert_eq "${#body300}" "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "env path: --body-file \"\${VAR}/file\" resolves the braced form too"
: > "$METRICS"
out=$(payload 'gh pr comment 1 --body-file "$T489_UNSET/rr.txt"' "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "env path: an unset VAR stays unmeasurable and enforced"
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "env path: an unset VAR carries no body_chars"
: > "$METRICS"
out=$(payload 'gh pr comment 1 --body-file "$(cat where.txt)"' "$tmpcwd" | T489_DIR="$envdir" dflt bash "$HOOK")
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "env path: \$(cat x) is not a lookup and stays unmeasurable"
: > "$METRICS"
out=$(payload 'gh pr comment 1 --body-file "$T489_DIR/$SUB/rr.txt"' "$tmpcwd" | T489_DIR="$envdir" SUB=. dflt bash "$HOOK")
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "env path: a second \$ in the rest of the path stays unmeasurable"
: > "$METRICS"
out=$(payload 'gh pr comment 1 --body-file "$T489_DIR/rr.txt"' "$tmpcwd" | T489_DIR='$HOME/x' dflt bash "$HOOK")
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "env path: a value that itself holds \$ stays unmeasurable"
: > "$METRICS"
out=$(payload 'gh pr comment 1 --body-file "$T489_DIR/rr.txt"' "$tmpcwd" | T489_DIR='relative/dir' dflt bash "$HOOK")
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "env path: a non-absolute value stays unmeasurable"
# The `@` inside the quotes, and the whole pair quoted, name the same file.
: > "$METRICS"
payload "gh api repos/o/r/pulls/1/comments -X POST --field body=\"@$envdir/rr.txt\" -F in_reply_to=9" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "${#body300}" "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "field file: body=\"@file\" (at inside the quotes) is still read as a file"
: > "$METRICS"
payload "gh api repos/o/r/pulls/1/comments -X POST -F 'body=@$envdir/rr.txt' -F in_reply_to=9" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "${#body300}" "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "field file: 'body=@file' (the whole pair quoted) is read as a file"
# The capture fires once the path resolves: a credited post under $VAR stores
# its final beside the draft.
cap_setup_recipe pr-review-reply
printf 'the reply posted from the job dir' > "$envdir/rr.txt"
cap_post_run 'gh api repos/o/r/pulls/12/comments -X POST --field body=@"$T489_DIR/rr.txt" -F in_reply_to=1' "T489_DIR=$envdir"
assert_eq "the reply posted from the job dir" "$(cat "$capdir/$capfinal" 2>/dev/null)" \
  "env path: a credited body=@\"\$VAR/file\" post stores the file as the final"
rm -rf "$capdir" "$capcwd" "$envdir"

# 80 (#469). A boundary inside a wrapper script under a scratch directory is
# classified from the script's text (read, never run) and the row names the
# wrapper; a script elsewhere, `bash -c`, and a script with no boundary leave
# no row, as before.
wrdir=$(mktemp -d)
printf 'set -e\ngit commit -m "%s"\n' "$body300" > "$wrdir/do-commit.sh"
: > "$METRICS"
out=$(payload "bash $wrdir/do-commit.sh" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "wrapper: git commit inside bash <scratch script> is classified and enforced"
assert_eq "git-commit" "$(jq -r '.boundary // "absent"' <<<"$(last_row)")" "wrapper: the row carries the script's boundary"
assert_eq "$wrdir/do-commit.sh" "$(jq -r '.wrapper // "absent"' <<<"$(last_row)")" "wrapper: the row names the wrapper script"
assert_eq "${#body300}" "$(jq -r '.body_chars // "absent"' <<<"$(last_row)")" "wrapper: the commit body is measured from the script text"
: > "$METRICS"
payload "cd $tmpcwd && zsh -e \"$wrdir/do-commit.sh\" && echo done" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "git-commit" "$(jq -r '.boundary // "absent"' <<<"$(last_row)")" "wrapper: cd &&, an interpreter option, a quoted path and a trailing && still classify"
: > "$METRICS"
payload 'bash "$T469_DIR/do-commit.sh"' "$tmpcwd" | T469_DIR="$wrdir" dflt bash "$HOOK" >/dev/null
assert_eq "git-commit" "$(jq -r '.boundary // "absent"' <<<"$(last_row)")" "wrapper: an env-prefixed script path resolves by lookup"
: > "$METRICS"
payload "bash $wrdir/do-commit.sh" "$tmpcwd" | DELEGATE_BOUNDARY_WRAPPER_DIRS=/nonexistent dflt bash "$HOOK" >/dev/null
assert_eq "" "$(cat "$METRICS")" "wrapper: a script outside the scratch directories is not read (no row)"
: > "$METRICS"
payload 'bash -c "git commit -m x"' "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "" "$(cat "$METRICS")" "wrapper: bash -c is a string, not a script, and is left alone"
printf 'set -e\nls -la\n' > "$wrdir/no-boundary.sh"
: > "$METRICS"
payload "bash $wrdir/no-boundary.sh" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "" "$(cat "$METRICS")" "wrapper: a script with no boundary command writes no row"
# A credited wrapper commit stores its message as the final, like an inline one.
cap_setup_recipe commit-message
cap_post_run "bash $wrdir/do-commit.sh" "DELEGATE_BOUNDARY_MIN_CHARS="
assert_eq true "$(jq -r '.delegated' <<<"$(tail -1 "$capm")")" "wrapper: a delegated commit inside a wrapper is credited"
assert_eq "$body300" "$(cat "$capdir/$capfinal" 2>/dev/null)" "wrapper: ...and stores the message as its final"
rm -rf "$capdir" "$capcwd" "$wrdir"

# 81 (#497). A credit is provisional until the PostToolUse confirm hook sees
# the call succeed. The harness refuses a call AFTER PreToolUse (no hook
# fires) and a command that fails inside git fires PostToolUseFailure, so an
# unconfirmed marker for this session+boundary inside the window means the
# post did not happen and the retry is that post: allowed on the same
# credit, no second row, no denial. Confirmed by tool_use_id, so a different
# call in between cannot confirm it.
CONFIRM="$REPO/scripts/delegate-boundary-confirm-hook.sh"
pending="$METRICS_DIR/.boundary-pending"
payload_id() { # cmd cwd session tool_use_id
  jq -nc --arg cmd "$1" --arg cwd "$2" --arg sid "$3" --arg id "$4" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, session_id:$sid, tool_use_id:$id, tool_input:{command:$cmd}}'
}
post_payload() { # cmd cwd session tool_use_id [event] [interrupted]
  jq -nc --arg cmd "$1" --arg cwd "$2" --arg sid "$3" --arg id "$4" --arg ev "${5:-PostToolUse}" --argjson intr "${6:-false}" \
    '{hook_event_name:$ev, tool_name:"Bash", cwd:$cwd, session_id:$sid, tool_use_id:$id, tool_input:{command:$cmd},
      tool_response:{stdout:"", stderr:"", interrupted:$intr, isImage:false}}'
}
confirm() { post_payload "$@" | dflt bash "$CONFIRM" 2>/dev/null; }
# One marker per call (#587): `<session>.<boundary>.<project>.<id>`; a claimed
# one is `.superseded` and no longer pending.
pmarkers() { local m; for m in "$pending/$1".*; do [[ -f "$m" ]] || continue; case "$m" in *.superseded|*.row|*.confirming.*) continue ;; esac; printf '%s\n' "$m"; done; }
marker_id() { local m; m=$(pmarkers "$1" | head -n 1); [[ -n "$m" ]] && jq -r '.id // empty' "$m" 2>/dev/null; }
pstate() { [[ -n "$(pmarkers "$1")" ]] && echo present || echo absent; }
seed_draft() { # recipe draft_stem
  jq -nc --arg ts "$nowts" --arg p "$proj" --arg r "$1" --arg d "$2" \
    '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:$r, draft_file:$d}' >> "$METRICS"
}
reset497() { : > "$METRICS"; rm -rf "$pending" "$METRICS_DIR/drafts"; }
# Shape 1 (the issue): the review reply names its body file through a
# variable the hook cannot resolve, is credited, and the worktree guard then
# refuses it; no PostToolUse fires. The retry 5 s later names the file
# literally.
printf '%s' "$body300" > "$tmpcwd/rr.txt"
refused='gh api repos/o/r/pulls/12/comments -X POST --field body=@"$T497_DIR/rr.txt" -F in_reply_to=9'
retried="gh api repos/o/r/pulls/12/comments -X POST --field body=@$tmpcwd/rr.txt -F in_reply_to=9"
reset497; seed_draft pr-review-reply d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0   # any earlier call: the confirm hook has been seen in this session
out=$(payload_id "$refused" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK")
assert_eq "" "$out" "refused: the first attempt is credited"
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "refused: ...with a delegated:true row"
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "refused: ...whose body the hook could not measure"
assert_eq toolu-1 "$(marker_id sess-A.pr-review-comment.$proj)" "refused: a pending marker names the call"
out=$(payload_id "$retried" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_eq "" "$out" "refused: the retry is allowed on the same credit"
assert_eq 1 "$(grep -c '"delegated":true' "$METRICS")" "refused: exactly one delegated:true row"
assert_eq 0 "$(grep -c '"denied":true' "$METRICS")" "refused: no denied row"
assert_eq 1 "$(grep -c '"source":"opportunity"' "$METRICS")" "refused: the retry writes no second row"
assert_eq toolu-2 "$(marker_id sess-A.pr-review-comment.$proj)" "refused: the marker is re-armed for the retry"
confirm "$retried" "$tmpcwd" sess-A toolu-2
assert_eq "$body300" "$(cat "$METRICS_DIR/drafts/d497.final.txt" 2>/dev/null)" "refused: the confirmed retry stores the final the refused attempt could not"
assert_eq "absent" "$(pstate sess-A.pr-review-comment.$proj)" "refused: the confirmed retry spends the credit"
out=$(payload_id "$retried" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "refused: a further post finds the credit spent"
# Shape 2 (the comment): a credited `git commit` exits 1 on an empty index.
# That fires PostToolUseFailure, on which the confirm hook is not registered
# and which it ignores anyway; the `git add` that follows is confirmed as
# its own call and cannot confirm the commit.
commit="git commit -m \"$body300\""
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "failed: the commit is credited"
confirm "$commit" "$tmpcwd" sess-A toolu-1 PostToolUseFailure
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "failed: a PostToolUseFailure payload does not confirm"
confirm 'git add f' "$tmpcwd" sess-A toolu-2
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "failed: another call's success does not confirm it"
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_eq "" "$out" "failed: the retried commit is allowed on the same credit"
assert_eq 1 "$(grep -c '"delegated":true' "$METRICS")" "failed: exactly one delegated:true row"
assert_eq 0 "$(grep -c '"denied":true' "$METRICS")" "failed: no denied row"
assert_eq 1 "$(grep -c '"source":"opportunity"' "$METRICS")" "failed: one opportunity row in all"
confirm "$commit" "$tmpcwd" sess-A toolu-3
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "failed: the retry's success confirms the spend"
# The normal shape: one delegation, a post that ran, then a second distinct
# post. The confirmation is what keeps the second one denied.
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "normal: the credited post is pending"
confirm "$commit" "$tmpcwd" sess-A toolu-1
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "normal: the spend is confirmed when the call succeeds"
out=$(payload_id 'git commit -m "fix: a second, different commit message that is long enough to clear the floor"' "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "normal: a second post after a confirmed spend is denied"
assert_eq 1 "$(grep -c '"delegated":true' "$METRICS")" "normal: one credited row"
assert_eq 1 "$(grep -c '"denied":true' "$METRICS")" "normal: one denied row"
# ...and an identical re-post after a confirmed spend is a new post, not a retry.
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-4 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "normal: the same text again after a confirmed spend is denied"
# A pending marker outranks a fresh credit: delegate A, post A refused,
# delegate B, retry A, post B. Spending B on the retry would deny post B.
reset497; seed_draft pr-review-reply dA.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$refused" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
seed_draft pr-review-reply dB.draft.txt
out=$(payload_id "$retried" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_eq "" "$out" "sweep: the refused post's retry reuses its own credit"
confirm "$retried" "$tmpcwd" sess-A toolu-2
out=$(payload_id "$retried" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_eq "" "$out" "sweep: the next post spends the second delegation"
assert_eq 2 "$(grep -c '"delegated":true' "$METRICS")" "sweep: two delegations, two credited rows"
assert_eq 0 "$(grep -c '"denied":true' "$METRICS")" "sweep: no denial"
# Scoped: a marker is honoured only inside the window, only for its own
# session and boundary, and only once the confirm hook has been seen in the
# session (a PreToolUse-only install cannot tell a refusal from a sweep, so
# for it nothing changes).
reset497; seed_draft commit-message d497.draft.txt
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "unseen: with no confirm hook in the session the retry is denied as before"
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
m=$(pmarkers sess-A.git-commit.$proj | head -n 1); jq -c --argjson e "$(( $(date -u +%s) - 301 ))" '.epoch = $e' "$m" > "$pending/old" && mv "$pending/old" "$m"
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "window: a marker older than 300 s is not honoured"
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0; confirm 'ls' "$tmpcwd" sess-B toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
out=$(payload_id "$commit" "$tmpcwd" sess-B toolu-2 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "scope: another session does not reuse this session's marker"
out=$(payload_id "gh pr comment 12 --body \"$body300\"" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "scope: another boundary does not reuse it either"
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "scope: ...and neither touched the marker"
# An interrupted call may or may not have posted: not confirmed.
confirm "$commit" "$tmpcwd" sess-A toolu-1 PostToolUse true
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "confirm: an interrupted call does not confirm"
# The marker is bound to the project the refused post recorded: a same-
# boundary post from another repository in the same session is not its
# retry, and must not file its final under the first repository's draft.
out=$(payload_id "$commit" "$gitroot/repo-a" sess-A toolu-5 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "scope: a post from another repository does not reuse the marker"
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "scope: ...and leaves it in place"
# ...and a credited post from another repository has a marker of its own, so
# the refused post's retry still finds its credit.
seed_delegation repo-a commit-message
payload_id "$commit" "$gitroot/repo-a" sess-A toolu-6 | dflt bash "$HOOK" >/dev/null
assert_eq toolu-6 "$(marker_id sess-A.git-commit.repo-a)" "scope: the other repository's credited post leaves its own marker"
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "scope: ...without touching the first repository's"
confirm "$commit" "$gitroot/repo-a" sess-A toolu-6
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-7 | dflt bash "$HOOK")
assert_eq "" "$out" "scope: the first repository's retry still reuses its credit"
# PostToolUse reports the whole call, whose status is the boundary's only
# when the boundary is the last segment or `&&`-joined to the rest (#587): no
# marker after `;` or `||`, so the credit
# is spent for good as before, and a reused marker is consumed rather than
# left for a further post.
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit; echo done" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "compound: a commit followed by another command is still credited"
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "compound: ...but leaves no marker, since a later failure would not be the commit's"
reset497; seed_draft commit-message d497.draft.txt
payload_id "$commit || true" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "compound: || true leaves no marker, since success would not be the commit's"
reset497; seed_draft commit-message d497.draft.txt
payload_id "git add f && $commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq toolu-1 "$(marker_id sess-A.git-commit.$proj)" "compound: a commit that is the last segment leaves a marker"
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
out=$(payload_id "$commit; echo done" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_eq "" "$out" "compound: a compound retry still reuses the refused post's credit"
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "compound: ...and consumes the marker"
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "compound: ...so a third post is denied"
# No marker without an id to confirm by, none with metrics off.
reset497; seed_draft commit-message d497.draft.txt
payload "$commit" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "marker: a payload with no tool_use_id leaves none"
reset497; seed_draft commit-message d497.draft.txt
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | DELEGATE_LOCAL_NO_METRICS=1 dflt bash "$HOOK" >/dev/null
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "marker: DELEGATE_LOCAL_NO_METRICS=1 leaves none"
# Nothing is stored before a call has run (#587), so a refused attempt
# leaves no final and the confirmed retry stores what it sent. A final the
# hook did not write (a verdict's explicit --final, recorded while the
# marker was pending) is never overwritten.
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq "absent" "$([[ -e "$METRICS_DIR/drafts/d497.final.txt" ]] && echo present || echo absent)" "recapture: the refused attempt stores nothing"
rewritten="git commit -m \"fix: rewritten after the refusal. $body300\""
payload_id "$rewritten" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK" >/dev/null
confirm "$rewritten" "$tmpcwd" sess-A toolu-2
assert_eq "fix: rewritten after the refusal. $body300" "$(cat "$METRICS_DIR/drafts/d497.final.txt" 2>/dev/null)" "recapture: the confirmed retry stores what it sent"
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "git commit -F -" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
mkdir -p "$METRICS_DIR/drafts"; printf 'from --final' > "$METRICS_DIR/drafts/d497.final.txt"
payload_id "$rewritten" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK" >/dev/null
confirm "$rewritten" "$tmpcwd" sess-A toolu-2
assert_eq "from --final" "$(cat "$METRICS_DIR/drafts/d497.final.txt" 2>/dev/null)" "recapture: a final the hook did not write is never overwritten"
# The daily prune of stale markers keeps the session's .seen file, which is
# on a week's retention: a session older than a day would otherwise lose
# its confirmation on the next refused post.
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)" "$pending/sess-A.seen"
printf '{"id":"old","epoch":1,"project":"x","draft":""}' > "$pending/sess-old.git-commit.x"
touch -t 202001010000 "$pending/sess-old.git-commit.x"
: > "$pending/sess-dead.seen"; touch -t 202001010000 "$pending/sess-dead.seen"
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq "present" "$([[ -e "$pending/sess-A.seen" ]] && echo present || echo absent)" "prune: a day-old .seen survives the marker prune"
assert_eq "absent" "$([[ -e "$pending/sess-old.git-commit.x" ]] && echo present || echo absent)" "prune: a stale marker is removed"
assert_eq "absent" "$([[ -e "$pending/sess-dead.seen" ]] && echo present || echo absent)" "prune: a .seen older than a week is removed"
# The confirm hook resolves a relative DELEGATE_METRICS_FILE against the
# payload cwd, as the boundary hook does, so both use one pending directory.
rel=$(mktemp -d); mk_repo "$rel" >/dev/null 2>&1; mkdir -p "$rel/elsewhere"
( cd "$rel/elsewhere" && post_payload 'ls' "$rel" sess-R toolu-0 | DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE=data/metrics.jsonl bash "$CONFIRM" 2>/dev/null )
assert_eq "present" "$([[ -e "$rel/data/.boundary-pending/sess-R.seen" ]] && echo present || echo absent)" "relative metrics: the confirm hook writes .seen under the payload cwd, not its own"
rm -rf "$rel"
# A reused marker is consumed before the re-arm is written: the retry is
# already allowed, its PostToolUse carries the new id, and a re-arm that
# fails would otherwise leave the old id for a further post to reuse.
reset497; seed_draft commit-message d497.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
# A jq that fails on the marker write only (its --arg body_text is unique).
BADJQ=$(mktemp -d)
printf '#!/usr/bin/env bash\ncase " $* " in *" --arg body_text "*) exit 1 ;; esac\nexec %q "$@"\n' "$REAL_JQ" > "$BADJQ/jq"
chmod +x "$BADJQ/jq"
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-2 | PATH="$BADJQ:$PATH" dflt bash "$HOOK")
assert_eq "" "$out" "re-arm failure: the retry is still allowed on the reused credit"
assert_eq "absent" "$(pstate sess-A.git-commit.$proj)" "re-arm failure: ...and the old marker is consumed, not left with its old id"
out=$(payload_id "$commit" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "re-arm failure: a further post cannot reuse the consumed marker"
rm -rf "$BADJQ"
# The confirm hook fails open and is silent.
ec=0; out=$(printf 'not json' | dflt bash "$CONFIRM" 2>/dev/null) || ec=$?
assert_eq 0 "$ec" "confirm: malformed stdin exits 0"
assert_eq "" "$out" "confirm: ...with no output"
ec=0; out=$(confirm 'ls' "$tmpcwd" sess-A toolu-9) || ec=$?
assert_eq 0 "$ec" "confirm: an ordinary call exits 0"
assert_eq "" "$out" "confirm: ...silently"
rm -rf "$pending" "$METRICS_DIR/drafts" "$tmpcwd/rr.txt"

# 82 (#587). A body FILE is read after the command has run, never before:
# one call that writes the file and posts it would otherwise store the text
# the file held from the previous post. The PostToolUse confirm hook reads it
# once the call has succeeded.
dfinal() { cat "$METRICS_DIR/drafts/$1.final.txt" 2>/dev/null; }
dfinal_state() { [[ -e "$METRICS_DIR/drafts/$1.final.txt" ]] && echo present || echo absent; }
stale_text="fix: the previous commit message, which already shipped"
new_text="fix: the message this very call writes before it commits"
reset497; seed_draft commit-message d587.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
printf '%s' "$stale_text" > "$tmpcwd/msg.txt"
stale_cmd="printf '%s' '$new_text' > msg.txt; git commit -F msg.txt"
payload_id "$stale_cmd" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "stale file: the write-then-commit call is credited"
assert_eq absent "$(dfinal_state d587)" "stale file: nothing is stored before the command has run"
printf '%s' "$new_text" > "$tmpcwd/msg.txt"   # what the command does when it runs
confirm "$stale_cmd" "$tmpcwd" sess-A toolu-1
assert_eq "$new_text" "$(dfinal d587)" "stale file: the confirmed commit stores what the command wrote"
[[ "$(dfinal d587)" != *"$stale_text"* ]] && r=clean || r=stale
assert_eq clean "$r" "stale file: no final holds the previous post's text"
# A file-backed post that failed (no PostToolUse) stores nothing at all.
reset497; seed_draft commit-message d587.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "git commit -F msg.txt" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
confirm "git commit -F msg.txt" "$tmpcwd" sess-A toolu-1 PostToolUseFailure
assert_eq absent "$(dfinal_state d587)" "stale file: a failed file-backed post stores no final"
# A refused inline commit stores nothing; its confirmed retry from a file is
# filed once, under one draft.
reset497; seed_draft commit-message d497.draft.txt; seed_draft commit-message d498.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "$commit" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq absent "$(dfinal_state d497)" "file retry: the refused inline attempt stores no final"
printf '%s' "$new_text" > "$tmpcwd/msg.txt"
payload_id "git commit -F msg.txt" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK" >/dev/null
confirm "git commit -F msg.txt" "$tmpcwd" sess-A toolu-2
assert_eq "$new_text" "$(dfinal d497)" "file retry: the confirmed file-backed retry stores what it sent"
assert_eq absent "$(dfinal_state d498)" "file retry: ...and no other draft is paired with it"
rm -f "$tmpcwd/msg.txt"

# Two unspent drafts, the first abandoned after a rejection and never
# posted: the post is filed under the draft its text overlaps, not under the
# oldest unspent one, so every later post in the session is not shifted one
# delegation early. Credits are still counted oldest first.
seed_two() {
  reset497; seed_draft maintainer-reply dA.draft.txt; seed_draft maintainer-reply dB.draft.txt
  mkdir -p "$METRICS_DIR/drafts"
  printf 'The sandbox flag in the launcher script is the cause of the blank window, not your distribution.\n' > "$METRICS_DIR/drafts/dA.draft.txt"
  printf 'Pruning the lock directory now also removes stale pending markers left behind by crashed sessions.\n' > "$METRICS_DIR/drafts/dB.draft.txt"
}
reply_b="Pruning the lock directory now removes the stale pending markers that crashed sessions leave behind."
seed_two
payload_id "gh pr comment 12 --body \"$reply_b\"" "$tmpcwd" sess-A toolu-1 | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
confirm "gh pr comment 12 --body \"$reply_b\"" "$tmpcwd" sess-A toolu-1
assert_eq "$reply_b" "$(dfinal dB)" "two unspent: an inline post lands under the draft it overlaps (the second)"
assert_eq absent "$(dfinal_state dA)" "two unspent: ...and not under the abandoned oldest draft"
seed_two
confirm 'ls' "$tmpcwd" sess-A toolu-0
printf '%s' "$reply_b" > "$tmpcwd/reply.md"
payload_id "gh pr comment 12 --body-file reply.md" "$tmpcwd" sess-A toolu-1 | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
confirm "gh pr comment 12 --body-file reply.md" "$tmpcwd" sess-A toolu-1
assert_eq "$reply_b" "$(dfinal dB)" "two unspent: a confirmed file-backed post lands under the draft it overlaps"
assert_eq absent "$(dfinal_state dA)" "two unspent: ...and the abandoned draft is left alone"
# With no text to tell them apart, the oldest unspent draft still wins.
seed_two
payload_id 'gh pr comment 12 --body "Thanks, merged."' "$tmpcwd" sess-A toolu-1 | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
confirm 'gh pr comment 12 --body "Thanks, merged."' "$tmpcwd" sess-A toolu-1
assert_eq "Thanks, merged." "$(dfinal dA)" "two unspent: no overlap falls back to the oldest unspent draft"
rm -rf "$pending" "$METRICS_DIR/drafts" "$tmpcwd/reply.md"

# Two file-backed posts in flight at once in one session (parallel subagents
# share the session id): each keeps its own marker, each confirmed call
# stores its own final, and both are counted, whichever confirms first.
text_c1="fix: prune the lock directory and the stale pending markers of crashed sessions"
text_c2="fix: read the sandbox flag from the launcher so the blank window goes away"
seed_two_commits() {
  reset497; seed_draft commit-message dC1.draft.txt; seed_draft commit-message dC2.draft.txt
  mkdir -p "$METRICS_DIR/drafts"
  printf 'fix: prune stale pending markers and the lock directory left by crashed sessions\n' > "$METRICS_DIR/drafts/dC1.draft.txt"
  printf 'fix: the launcher sandbox flag causes the blank window\n' > "$METRICS_DIR/drafts/dC2.draft.txt"
  printf '%s' "$text_c1" > "$tmpcwd/m1.txt"; printf '%s' "$text_c2" > "$tmpcwd/m2.txt"
  confirm 'ls' "$tmpcwd" sess-A toolu-0
  payload_id "git commit -F m1.txt" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
  payload_id "git commit -F m2.txt" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK" >/dev/null
}
seed_two_commits
confirm "git commit -F m1.txt" "$tmpcwd" sess-A toolu-1
confirm "git commit -F m2.txt" "$tmpcwd" sess-A toolu-2
assert_eq "$text_c1" "$(dfinal dC1)" "concurrent: the first call's final is kept"
assert_eq "$text_c2" "$(dfinal dC2)" "concurrent: the second call's final is kept"
assert_eq 2 "$(grep -c '"delegated":true' "$METRICS")" "concurrent: both posts are counted as credited"
seed_two_commits
confirm "git commit -F m2.txt" "$tmpcwd" sess-A toolu-2
confirm "git commit -F m1.txt" "$tmpcwd" sess-A toolu-1
assert_eq "$text_c1" "$(dfinal dC1)" "concurrent, reversed: the first call's final is kept"
assert_eq "$text_c2" "$(dfinal dC2)" "concurrent, reversed: the second call's final is kept"
assert_eq 2 "$(grep -c '"delegated":true' "$METRICS")" "concurrent, reversed: both posts are counted as credited"
rm -f "$tmpcwd/m1.txt" "$tmpcwd/m2.txt"
# The same with INLINE bodies: each call's text waits in its own marker
# until its own confirmation, so neither overwrites the other's final.
reply_a="The sandbox flag in the launcher script causes the blank window, not your distribution."
seed_two_inline() {
  seed_two
  confirm 'ls' "$tmpcwd" sess-A toolu-0
  payload_id "gh pr comment 12 --body \"$reply_a\"" "$tmpcwd" sess-A toolu-1 | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  payload_id "gh pr comment 12 --body \"$reply_b\"" "$tmpcwd" sess-A toolu-2 | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
}
seed_two_inline
confirm "gh pr comment 12 --body \"$reply_a\"" "$tmpcwd" sess-A toolu-1
confirm "gh pr comment 12 --body \"$reply_b\"" "$tmpcwd" sess-A toolu-2
assert_eq "$reply_a" "$(dfinal dA)" "concurrent inline: the first call's final holds its own text"
assert_eq "$reply_b" "$(dfinal dB)" "concurrent inline: the second call's final holds its own text"
seed_two_inline
confirm "gh pr comment 12 --body \"$reply_b\"" "$tmpcwd" sess-A toolu-2
confirm "gh pr comment 12 --body \"$reply_a\"" "$tmpcwd" sess-A toolu-1
assert_eq "$reply_a" "$(dfinal dA)" "concurrent inline, reversed: the first call's final holds its own text"
assert_eq "$reply_b" "$(dfinal dB)" "concurrent inline, reversed: the second call's final holds its own text"
# Overlapping claims reserve credits: three delegations and four calls in
# flight at once, each later call claiming the previous one's marker. The
# `.row` a claim defers is not in the metrics file yet, so unless it is
# counted every claimer sees the same fresh credit and one delegation credits
# several posts.
reset497; for _i in 1 2 3; do seed_draft commit-message "dR$_i.draft.txt"; done
confirm 'ls' "$tmpcwd" sess-A toolu-0
for _i in 1 2 3 4; do
  payload_id "git commit -m \"$body300\"" "$tmpcwd" sess-A "toolu-r$_i" | dflt bash "$HOOK" >/dev/null
done
for _i in 1 2 3 4; do confirm "git commit -m \"$body300\"" "$tmpcwd" sess-A "toolu-r$_i"; done
assert_eq 3 "$(grep -c '"delegated":true' "$METRICS")" "concurrent claims: three delegations credit three posts, not four"
# ...but a claim holds its credit only while its claimer is unconfirmed: in a
# sweep whose first post was refused, the confirmed retry releases it, so the
# sweep's other two posts are still credited (#497).
reset497; for _i in 1 2 3; do seed_draft commit-message "dS$_i.draft.txt"; done
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "git commit -m \"$body300\"" "$tmpcwd" sess-A toolu-s1 | dflt bash "$HOOK" >/dev/null
payload_id "git commit -m \"$body300\"" "$tmpcwd" sess-A toolu-s2 | dflt bash "$HOOK" >/dev/null
confirm "git commit -m \"$body300\"" "$tmpcwd" sess-A toolu-s2
for _i in 3 4; do
  payload_id "git commit -m \"$body300\"" "$tmpcwd" sess-A "toolu-s$_i" | dflt bash "$HOOK" >/dev/null
  assert_eq true "$(jq -r .delegated <<<"$(last_row)")" "sweep after a refused post: post $_i is credited"
  confirm "git commit -m \"$body300\"" "$tmpcwd" sess-A "toolu-s$_i"
done
# Two confirm hooks racing onto the same best draft: the one that loses the
# exclusive create files its text under the next unspent draft instead of
# dropping it. The race is made deterministic with a pair-score stub whose
# best_draft lets the rival win first.
seed_two
racedir=$(mktemp -d); mkdir -p "$racedir/lib"
cp "$CONFIRM" "$racedir/confirm.sh"
cp "$REPO/scripts/lib/hook.sh" "$racedir/lib/hook.sh"
cat > "$racedir/lib/pair-score.sh" <<EOF
best_draft() { printf 'rival' > "$METRICS_DIR/drafts/dA.final.txt"; printf 'dA.draft.txt'; }
EOF
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "gh pr comment 12 --body \"$reply_b\"" "$tmpcwd" sess-A toolu-1 | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
post_payload "gh pr comment 12 --body \"$reply_b\"" "$tmpcwd" sess-A toolu-1 | dflt bash "$racedir/confirm.sh" 2>/dev/null
assert_eq rival "$(dfinal dA)" "raced capture: the rival's final is not overwritten"
assert_eq "$reply_b" "$(dfinal dB)" "raced capture: the losing hook files its text under the next unspent draft"
rm -rf "$racedir"
# An inline body is not stored before its call has run.
seed_two
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "gh pr comment 12 --body \"$reply_a\"" "$tmpcwd" sess-A toolu-1 | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "absent absent" "$(dfinal_state dA) $(dfinal_state dB)" "inline: nothing is stored before the call has run"
assert_eq 600 "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$(pmarkers sess-A.comment-reply.$proj | head -n 1)")" \
  "inline: the marker holding the body is private (600)"
rm -rf "$pending" "$METRICS_DIR/drafts"
# The inline text kept in a marker is cut at the drafts' byte cap.
cap_setup
cap_post_run 'gh pr comment 12 --body "the fix landed in abc1234"' "DELEGATE_DRAFT_MAX_BYTES=10"
assert_eq "the fix la" "$(cat "$capdir/$capfinal" 2>/dev/null)" "inline: the stored body respects DELEGATE_DRAFT_MAX_BYTES"
rm -rf "$capdir" "$capcwd"

# A successful `&&` chain ran every segment, so a file-backed boundary that
# is not the last segment is still captured once the call succeeds; after
# `;` or `||` the call's success says nothing about the boundary, so nothing.
chain_run() { # cmd id
  reset497; seed_draft commit-message d587.draft.txt
  printf '%s' "$stale_text" > "$tmpcwd/msg.txt"
  confirm 'ls' "$tmpcwd" sess-A toolu-0
  payload_id "$1" "$tmpcwd" sess-A "$2" | dflt bash "$HOOK" >/dev/null
  printf '%s' "$new_text" > "$tmpcwd/msg.txt"
  confirm "$1" "$tmpcwd" sess-A "$2"
}
chain_run "printf '%s' '$new_text' > msg.txt && git commit -F msg.txt && git push" toolu-1
assert_eq "$new_text" "$(dfinal d587)" "&& chain: a confirmed chain stores what the command wrote"
chain_run "git commit -F msg.txt; git push" toolu-1
assert_eq absent "$(dfinal_state d587)" "; chain: the call's success is not the commit's, so no final"
chain_run "git commit -F msg.txt || true" toolu-1
assert_eq absent "$(dfinal_state d587)" "|| chain: the call's success is not the commit's, so no final"
rm -rf "$pending" "$METRICS_DIR/drafts" "$tmpcwd/msg.txt"

# 90 (#562). One shell-word tokenizer reads the body the shell would pass:
# concatenated quoting, an attached `--body=`/`--message=`/`-m"x"` value and
# `$'...'` are measured whole, a `<<-` heredoc does not swallow the segments
# after its tab-indented terminator, and a stdin heredoc is the body.
chars562() { # cmd -> body_chars on the row, or "absent"
  : > "$METRICS"
  payload "$1" "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
  jq -r '.body_chars // "absent"' <<<"$(last_row)"
}
assert_eq 12 "$(chars562 "gh pr comment 12 --body 'it'\\''s a reply'")" \
  "#562: concatenated quoting is one body ('it'\\''s a reply)"
assert_eq 11 "$(chars562 'gh pr comment 12 --body="hello world"')" \
  "#562: an attached --body= value is measured"
assert_eq 12 "$(chars562 'git commit --message="fix: a thing"')" \
  "#562: an attached --message= value is measured"
assert_eq 12 "$(chars562 'git commit -m"fix: a thing"')" \
  "#562: an attached -m\"x\" value is measured"
assert_eq 17 "$(chars562 "gh pr comment 12 --body \$'line one\\nline two'")" \
  "#562: a \$'...' body is measured with its escapes resolved"
assert_eq absent "$(chars562 'gh pr comment 12 --body "$REPLY"')" \
  "#562: a body the shell would expand stays unmeasurable"
assert_eq 12 "$(chars562 "$(printf 'gh issue comment 1 --body-file - <<%s\nhello there\nEOF' "'EOF'")")" \
  "#562: a --body-file - heredoc is the posted body"
: > "$METRICS"
payload "$(printf 'cat <<-EOF > notes.md\n\tsome notes\n\tEOF\ngh pr comment 12 --body "after the heredoc"')" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq comment-reply "$(jq -r '.boundary // "none"' <<<"$(last_row)")" \
  "#562: a <<-EOF heredoc does not hide the segment after its terminator"
# gh api sends a POST whenever a field is given and no method is named, which
# is how /address-pr-comments posts a reply.
: > "$METRICS"
payload 'gh api repos/o/r/pulls/12/comments/99/replies -f body="thanks, fixed"' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-review-comment "$(jq -r '.boundary // "none"' <<<"$(last_row)")" \
  "#562: gh api .../replies -f body= without -X POST is a pr-review-comment"
: > "$METRICS"
payload "gh api repos/o/r/pulls/12/comments/99/replies -f 'body=thanks, fixed'" "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq pr-review-comment "$(jq -r '.boundary // "none"' <<<"$(last_row)")" \
  "#562: a quoted -f 'body=...' field without -X POST is a pr-review-comment"
# `<<\EOF` quotes the delimiter as `<<'EOF'` does, so `$` in the body is literal.
assert_eq 16 "$(chars562 "$(printf 'gh issue comment 1 --body-file - <<\\EOF\nit costs $5 now\nEOF')")" \
  "#562: a <<\\EOF stdin heredoc with a \$ is literal and measured"
assert_eq 13 "$(chars562 "$(printf 'git commit -m "$(cat <<\\EOF\nfix: $x thing\nEOF\n)"')")" \
  "#562: a \$(cat <<\\EOF ...) message with a \$ is literal and measured"
: > "$METRICS"
payload 'gh api -X GET repos/o/r/pulls/12/comments -f body=x' "$tmpcwd" \
  | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq 0 "$(nrows)" "#562: an explicit -X GET with a body field is still not a post"

# 91 (#563). A pending marker is the retry of the post it was left by, so it
# is reused only by a post to the same target: the selector, `gh api`
# endpoint and thread fields and `--repo` the command names. A refused reply
# to PR 12 that was never retried must not credit a reply to PR 13.
reset497; seed_draft maintainer-reply d563.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "gh pr comment 12 --body \"$body300\"" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
assert_eq toolu-1 "$(marker_id sess-A.comment-reply.$proj)" "#563 target: the credited reply to PR 12 is pending"
out=$(payload_id "gh pr comment 13 --body \"$body300\"" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "#563 target: a reply to PR 13 is not the retry of the one to PR 12"
assert_eq toolu-1 "$(marker_id sess-A.comment-reply.$proj)" "#563 target: ...and leaves the PR 12 marker in place"
out=$(payload_id "gh pr comment 12 --repo o/r --body \"$body300\"" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "#563 target: the same number in a named --repo is another target"
out=$(payload_id "gh pr comment 12 --body-file $tmpcwd/rr.txt" "$tmpcwd" sess-A toolu-4 | dflt bash "$HOOK")
assert_eq "" "$out" "#563 target: the retry to PR 12 reuses its credit whatever its body flag"
assert_eq toolu-4 "$(marker_id sess-A.comment-reply.$proj)" "#563 target: ...and re-arms the marker"
rm -rf "$pending" "$METRICS_DIR/drafts"
# The target is the parsed destination, not every number-looking word: an
# env assignment in front of a commit is not one (a commit's target is its
# project alone), a numeric body is not one, and a branch selector is one.
reset497; seed_draft commit-message d563.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "GIT_OPTIONAL_LOCKS=0 git commit -m \"$body300\"" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
out=$(payload_id "git commit -m \"$body300\"" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_eq "" "$out" "#563 target: an env assignment is not part of a commit's target, so the retry reuses the credit"
reset497; seed_draft maintainer-reply d563.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id 'gh pr comment 12 --body 123' "$tmpcwd" sess-A toolu-1 | DELEGATE_BOUNDARY_MIN_CHARS=0 DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
payload_id 'gh pr comment 12 --body 456' "$tmpcwd" sess-A toolu-2 | DELEGATE_BOUNDARY_MIN_CHARS=0 DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" >/dev/null
assert_eq "1 toolu-2" "$(grep -c '"source":"opportunity"' "$METRICS") $(marker_id sess-A.comment-reply.$proj)" \
  "#563 target: a numeric body value is not part of the target, so the retry reuses the marker"
reset497; seed_draft maintainer-reply d563.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "gh pr comment my-branch --body \"$body300\"" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
out=$(payload_id "gh pr comment other-branch --body \"$body300\"" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "#563 target: a reply to another branch's PR is another target"
out=$(payload_id "gh pr comment my-branch --body \"$body300\"" "$tmpcwd" sess-A toolu-3 | dflt bash "$HOOK")
assert_eq "" "$out" "#563 target: ...while the retry to the same branch's PR reuses its credit"
# Value-taking flags are per command: on `gh pr review` -r and -a are the
# booleans --request-changes and --approve, so the word after them is not
# swallowed as their value and a retry with another body still reaches its
# marker.
retry563() { # boundary first-cmd retry-cmd recipe name
  reset497; seed_draft "$4" d563.draft.txt
  confirm 'ls' "$tmpcwd" sess-A toolu-0
  payload_id "$2" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
  out=$(payload_id "$3" "$tmpcwd" sess-A toolu-2 | dflt bash "$HOOK")
  assert_eq " toolu-2" "$out $(marker_id "sess-A.$1.$proj")" "#563 target: $5"
}
retry563 pr-review-body "gh pr review 12 -r --body \"first $body300\"" "gh pr review 12 -r --body \"second $body300\"" \
  maintainer-review-reply "gh pr review -r is boolean, so the retry with another body reuses the marker"
retry563 pr-review-body "gh pr review 12 -a --body \"first $body300\"" "gh pr review 12 -a --body \"second $body300\"" \
  maintainer-review-reply "gh pr review -a is boolean, so the retry with another body reuses the marker"
retry563 comment-reply "glab mr discussion note 4 --message \"first $body300\"" "glab mr discussion note 4 --message \"second $body300\"" \
  maintainer-reply "glab mr discussion note reads glab mr note's flags, so a rewritten --message retry reuses the marker"
# A command with no flag table of its own still never keys on a body-ish
# value (the tokenizer's TARGET line, read directly).
assert_eq $'TARGET\t4 repo=o/r' "$(perl "$REPO/scripts/lib/shell-words.pl" 0 <<<'gh pr edit 4 --body first --title t2 --notes n --field f -R o/r' | head -n 1)" \
  "#563 target: an unlisted command skips --body/--title/--notes/--field values"
rm -rf "$pending" "$METRICS_DIR/drafts"

# 92 (#563). The common path spawns no jq: the boundary hook pre-filters the
# raw payload before any jq, and the confirm hook globs the session's markers
# before reading the payload with jq. A PATH-shadowed jq logs every call.
JQLOG=$(mktemp -d)
printf '#!/usr/bin/env bash\nprintf x >> %q/calls\nexec %q "$@"\n' "$JQLOG" "$REAL_JQ" > "$JQLOG/jq"
chmod +x "$JQLOG/jq"
jqcalls() { local n; n=$(wc -c < "$JQLOG/calls" 2>/dev/null) || n=0; echo $((n + 0)); }
: > "$METRICS"; : > "$JQLOG/calls"
p563=$(payload 'ls -la ~/projects/github && echo "done; high time"' "$tmpcwd")
out=$(PATH="$JQLOG:$PATH" DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK" <<<"$p563")
assert_eq "0 " "$(jqcalls) $out" "#563 prefilter: a call naming no git/gh/glab spawns no jq and prints nothing"
: > "$JQLOG/calls"
out=$(payload 'git commit -m "fix: the prefilter still lets a boundary through"' "$tmpcwd" | PATH="$JQLOG:$PATH" dflt bash "$HOOK")
assert_contains '"permissionDecision":"deny"' "$out" "#563 prefilter: a boundary still reaches the classifier"
assert_eq true "$( (( $(jqcalls) > 0 )) && echo true || echo false)" "#563 prefilter: ...and the shadowed jq logs the calls it makes"
# A newline-separated command reaches the raw payload as `\ngit`, and a
# wrapper script as `bash <path>`: both pass the raw pre-filter.
: > "$METRICS"
payload "$(printf 'cd %s\ngit commit -m "fix: after a newline"' "$tmpcwd")" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r '.boundary // "none"' <<<"$(last_row)")" "#563 prefilter: a boundary after an escaped newline is classified"
wr563=$(mktemp -d); printf 'git commit -m "fix: from inside a wrapper script"\n' > "$wr563/w.sh"
: > "$METRICS"
payload "bash $wr563/w.sh" "$tmpcwd" | DELEGATE_BOUNDARY_WRAPPER_DIRS="$wr563" dflt bash "$HOOK" >/dev/null
assert_eq git-commit "$(jq -r '.boundary // "none"' <<<"$(last_row)")" "#563 prefilter: a wrapper script with no git in its command line is still read"
rm -rf "$wr563"
# The confirm hook with no marker for the session: .seen is written, no jq.
rm -rf "$pending"; : > "$JQLOG/calls"
post_payload 'ls -la' "$tmpcwd" sess-F toolu-1 | PATH="$JQLOG:$PATH" dflt bash "$CONFIRM" 2>/dev/null
assert_eq "0 present" "$(jqcalls) $([[ -e "$pending/sess-F.seen" ]] && echo present || echo absent)" \
  "#563 confirm: no pending marker, no jq, and the session is still marked seen"
post_payload 'ls -la' "$tmpcwd" sess-F toolu-1 PostToolUseFailure | PATH="$JQLOG:$PATH" dflt bash "$CONFIRM" 2>/dev/null
assert_eq 0 "$(jqcalls)" "#563 confirm: a wrong event exits before any jq too"
# ...and with one, the jq path confirms it as before.
reset497; seed_draft maintainer-reply d563.draft.txt
confirm 'ls' "$tmpcwd" sess-A toolu-0
payload_id "gh pr comment 12 --body \"$body300\"" "$tmpcwd" sess-A toolu-1 | dflt bash "$HOOK" >/dev/null
: > "$JQLOG/calls"
post_payload "gh pr comment 12 --body \"$body300\"" "$tmpcwd" sess-A toolu-1 | PATH="$JQLOG:$PATH" dflt bash "$CONFIRM" 2>/dev/null
assert_eq "absent" "$(pstate sess-A.comment-reply.$proj)" "#563 confirm: a pending marker is still confirmed"
assert_eq "$body300" "$(cat "$METRICS_DIR/drafts/d563.final.txt" 2>/dev/null)" "#563 confirm: ...and its final stored"
rm -rf "$pending" "$METRICS_DIR/drafts" "$JQLOG"

# 93. A boundary command asked for its help posts nothing, so it is no
# boundary: no row, no nudge, no deny. `-h` is help on every classified gh,
# glab and git commit command (none binds it to anything else), and the flag
# is read from the tokenizer's words: as the value of a flag that takes one
# (`--body --help`, `-m -h`), after `--`, or inside a quoted body it is text.
help_none() { # cmd name
  : > "$METRICS"
  local out; out=$(payload "$1" "$tmpcwd" | dflt bash "$HOOK")
  assert_eq "0 " "$(nrows) $out" "help: $2 writes no row and emits nothing"
}
help_none 'gh pr create --help' "gh pr create --help"
help_none 'gh pr create "--help"' "a quoted --help word is still the flag"
help_none 'gh pr comment -h' "gh pr comment -h"
help_none "gh pr comment 12 --body \"$body300\" --help" "gh pr comment with a body and --help"
help_none "gh pr review 12 --body \"$body300\" -h" "gh pr review with a body and -h"
help_none "gh issue create --title t --body \"$body300\" --help" "gh issue create with a body and --help"
help_none 'glab mr note --help' "glab mr note --help"
help_none "glab mr note 4 -h --message \"$body300\"" "glab mr note -h before a message"
help_none "glab mr create --help" "glab mr create --help"
help_none 'gh api --help' "gh api --help"
help_none "gh api repos/o/r/pulls/1/comments -X POST -f body=\"$body300\" --help" "gh api comment POST with --help"
help_none "gh api repos/o/r/pulls/1/reviews -f body=\"$body300\" -h" "gh api review POST with -h"
help_none 'git commit --help' "git commit --help"
help_none 'git commit -m "fix: a message long enough to be drafted" --help' "git commit -m with --help"
help_none 'git commit -h -m "fix: a message long enough to be drafted"' "git commit -h before -m"
help_none 'git commit -am "fix: a message long enough to be drafted" -h' "git commit -am with -h"
help_none 'git -C . commit -m "fix: a message long enough to be drafted" --help' "git -C . commit with --help"
help_boundary() { # cmd boundary name
  : > "$METRICS"
  payload "$1" "$tmpcwd" | dflt bash "$HOOK" >/dev/null
  assert_eq "$2" "$(jq -r '.boundary // "none"' <<<"$(last_row)" 2>/dev/null)" "help: $3 is still a boundary"
}
help_boundary "gh pr comment 12 --body \"see --help and -h for the flags. $body300\"" comment-reply "--help inside a quoted body"
help_boundary 'git commit -m "docs: say that --help and -h print usage only"' git-commit "--help inside a quoted message"
help_boundary 'gh pr comment 12 --body --help' comment-reply "--help as the value of --body"
help_boundary 'git commit -m -h' git-commit "-h as the value of -m"
help_boundary 'git commit -am --help' git-commit "--help as the value of the -am cluster"
help_boundary 'git commit -m "fix: a message long enough to be drafted" -- --help' git-commit "--help after -- (a pathspec)"
help_boundary "gh pr comment --help; gh pr comment 12 --body \"$body300\"" comment-reply "a later segment after a help segment"
# A short-option cluster ending in a flag that takes a value takes the next
# word as that value, as pflag and git parse it (`-d` is boolean --draft and
# `-t` --title on gh pr create, so `-dt --help` titles the PR "--help").
help_boundary "gh pr create -dt --help -b \"$body300\"" pr-create "--help as the value of the -dt cluster"
help_boundary "gh pr comment 12 -eb --help" comment-reply "--help as the value of the -eb cluster"
help_boundary "gh pr review 12 -cb -h" pr-review-body "-h as the value of the -cb cluster"
help_boundary "gh issue create -wt -h -b \"$body300\"" issue-create "-h as the value of the -wt cluster"
help_boundary "glab mr create -ft --help" pr-create "--help as the value of glab's -ft cluster"
help_boundary "glab mr note 4 -m --help" comment-reply "--help as the value of glab mr note -m"
help_boundary 'git commit -am -h' git-commit "-h as the value of the -am cluster"
# A value letter before the end of a cluster takes the rest as its value, so
# the word after it is an option again.
help_none "gh pr create -dtTitle --help" "gh pr create --help after an attached -dtTitle"
# Fail closed: a short flag or cluster with a letter the command's table does
# not know as on/off may take the next word as its value, so a help flag
# straight after it keeps the call a boundary. Only known on/off letters
# (`-d`/`-w` on gh pr create, `-a` on gh pr review) let it read as help.
help_boundary "gh pr create -zt --help -b \"$body300\"" pr-create "--help after the unknown-letter cluster -zt"
help_boundary "gh pr create -zd --help" pr-create "--help after the unknown-letter cluster -zd"
help_boundary "gh pr comment 12 -z --help" comment-reply "--help after an unknown short flag"
help_boundary "glab mr note 4 -x -h" comment-reply "-h after a short flag glab mr note does not know"
help_none "gh pr create -dw --help" "gh pr create --help after the known on/off cluster -dw"
help_none "gh pr review 12 -a --help -b \"$body300\"" "gh pr review --help after the known on/off -a"

# --- #607 (D8): text the human was already shown and answered is not denied ---
# On the deny path the hook reads the session transcript at the payload's
# transcript_path: a post whose body has >= 90% of its word bigrams in one
# assistant message that a genuine human turn followed is exempt, silently,
# with approved:true on its row. Every other shape is denied as before.
tdir=$(mktemp -d)
appr_body="Thanks for the report. The crash comes from the sandbox flag in src/main.js, which the Electron 38 upgrade turned on by default; the fix in #612 passes the flag only on the affected distros, and Friday's release ships it. Please retry once it lands and reopen if the window still closes."
appr_half1="${appr_body:0:140}"
appr_half2="${appr_body:140}"
appr_edit="Thanks for the report. We traced the crash to a GPU driver regression rather than anything in src/main.js; the workaround in #612 disables hardware acceleration for that driver, and a later release will ship it. Please try it and reopen if the window still closes."
t_asst() { # id text [sidechain]
  jq -nc --arg id "$1" --arg t "$2" --argjson sc "${3:-false}" \
    '{type:"assistant", isSidechain:$sc, message:{id:$id, role:"assistant", content:[{type:"text", text:$t}]}}'
}
t_tool_use() { # id
  jq -nc --arg id "$1" '{type:"assistant", isSidechain:false, message:{id:$id, role:"assistant", content:[{type:"tool_use", id:"toolu_x", name:"Bash", input:{command:"ls"}}]}}'
}
t_user() { jq -nc --arg t "$1" '{type:"user", isSidechain:false, message:{role:"user", content:$t}}'; }
t_user_blocks() { jq -nc --arg t "$1" '{type:"user", isSidechain:false, message:{role:"user", content:[{type:"text", text:$t}]}}'; }
t_meta() { jq -nc --arg t "$1" '{type:"user", isSidechain:false, isMeta:true, message:{role:"user", content:$t}}'; }
t_compact() { jq -nc --arg t "$1" '{type:"user", isSidechain:false, isCompactSummary:true, message:{role:"user", content:$t}}'; }
t_result() { jq -nc '{type:"user", isSidechain:false, message:{role:"user", content:[{type:"tool_result", tool_use_id:"toolu_x", content:"ok, looks good"}]}}'; }
t_queued() { # mode prompt
  jq -nc --arg m "$1" --arg p "$2" '{type:"attachment", isSidechain:false, attachment:{type:"queued_command", commandMode:$m, prompt:$p}}'
}
payload_tp() { # cmd cwd transcript_path
  jq -nc --arg cmd "$1" --arg cwd "$2" --arg tp "$3" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", cwd:$cwd, session_id:"sess-D8", transcript_path:$tp, tool_input:{command:$cmd}}'
}
appr_post="gh pr comment 12 --body \"$appr_body\""
appr_run() { # transcript cmd -> out; row in $METRICS
  : > "$METRICS"
  payload_tp "${2:-$appr_post}" "$tmpcwd" "$1" | dflt bash "$HOOK"
}
assert_denied_d8() { # out name
  assert_contains '"permissionDecision":"deny"' "$1" "approved: $2 is denied"
  assert_eq false "$(jq -r '.approved // false' <<<"$(last_row)")" "approved: $2 row carries no approved"
}

# The approved shape: the draft shown (across two text blocks of one message),
# then a human reply, then the post.
tp="$tdir/approved.jsonl"
{ t_user "draft a reply to the reporter on PR 12"
  t_asst m1 "Here is the draft:"
  t_asst m1 "$appr_half1"
  t_asst m1 "$appr_half2"
  t_user "looks good, post it"
  t_tool_use m2; } > "$tp"
out=$(appr_run "$tp")
assert_eq "" "$out" "approved: shown then answered by the human: no deny and no reminder"
assert_eq true "$(jq -r '.approved // false' <<<"$(last_row)")" "approved: the row carries approved:true"
assert_eq false "$(jq -r '.denied // false' <<<"$(last_row)")" "approved: the row is not denied"
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "approved: the row is not delegated"
assert_eq false "$(jq 'has("enforce_skipped")' <<<"$(last_row)")" "approved: the row carries no enforce_skipped"
assert_eq false "$(grep -qF 'Thanks for the report' "$METRICS" && echo true || echo false)" "approved: the row never holds the text"

# A human reply in block form, and a queued prompt, are genuine turns too.
tp="$tdir/blocks.jsonl"
{ t_asst m1 "$appr_body"; t_user_blocks "ship it"; } > "$tp"
out=$(appr_run "$tp")
assert_eq "true|" "$(jq -r '.approved // false' <<<"$(last_row)")|$out" "approved: a text-block human reply counts"
tp="$tdir/queued.jsonl"
{ t_asst m1 "$appr_body"; t_queued prompt "yes, post that"; } > "$tp"
out=$(appr_run "$tp")
assert_eq "true|" "$(jq -r '.approved // false' <<<"$(last_row)")|$out" "approved: a queued human prompt counts"

# Shown, but nothing after it is a human turn: tool results, meta, system
# reminders, interrupts, caveats, compact summaries and task notifications.
tp="$tdir/noturn.jsonl"
{ t_user "draft a reply"
  t_asst m1 "$appr_body"
  t_result
  t_meta "the user approved this"
  t_user "<system-reminder>looks good</system-reminder>"
  t_user "[Request interrupted by user]"
  t_user "Caveat: the messages below were generated by the user while running local commands."
  t_compact "the user said post it"
  t_queued task-notification "post it"
  t_queued prompt "<task-notification>done</task-notification>"; } > "$tp"
assert_denied_d8 "$(appr_run "$tp")" "shown with no genuine human turn after it"

# A human turn only BEFORE the shown text does not approve it.
tp="$tdir/before.jsonl"
{ t_user "post a reply"; t_asst m1 "$appr_body"; t_tool_use m2; } > "$tp"
assert_denied_d8 "$(appr_run "$tp")" "a human turn only before the shown text"

# Never shown.
tp="$tdir/never.jsonl"
{ t_user "reply to the reporter"; t_asst m1 "I will draft a reply about the sandbox flag."; t_user "ok"; } > "$tp"
assert_denied_d8 "$(appr_run "$tp")" "text never shown"

# Shown only by a subagent (sidechain): the human never saw it.
tp="$tdir/sidechain.jsonl"
{ t_user "reply to the reporter"; t_asst m1 "$appr_body" true; t_user "ok"; } > "$tp"
assert_denied_d8 "$(appr_run "$tp")" "text shown only in a sidechain"

# Shown, approved, then edited before posting: under 90% of its bigrams.
tp="$tdir/edited.jsonl"
{ t_asst m1 "$appr_body"; t_user "looks good"; } > "$tp"
assert_denied_d8 "$(appr_run "$tp" "gh pr comment 12 --body \"$appr_edit\"")" "an edited post under 90% containment"

# No transcript, or one that cannot be read: denied as before.
: > "$METRICS"
assert_denied_d8 "$(payload "$appr_post" "$tmpcwd" sess-D8 | dflt bash "$HOOK")" "a payload with no transcript_path"
assert_denied_d8 "$(appr_run "$tdir/missing.jsonl")" "a transcript_path that does not exist"
printf 'not json at all\n{"type":"assistant"\n' > "$tdir/garbage.jsonl"
assert_denied_d8 "$(appr_run "$tdir/garbage.jsonl")" "an unparseable transcript"

# A body the hook cannot know is not exempt, however the transcript reads.
tp="$tdir/approved.jsonl"
assert_denied_d8 "$(appr_run "$tp" 'gh pr comment 12 --body "$(cat reply.md)"')" "an unknown \$(...) body"

# A file-backed body qualifies like an inline one, but only when the hook
# read all of it: the read is capped at 64 KB, and an approved prefix must not
# carry an unseen remainder past the cap through (Copilot on #631).
printf '%s\n' "$appr_body" > "$tdir/reply.md"
out=$(appr_run "$tp" "gh pr comment 12 --body-file $tdir/reply.md")
assert_eq "true|" "$(jq -r '.approved // false' <<<"$(last_row)")|$out" "approved: a readable --body-file counts"
long_prefix=$(for _ in $(seq 1 300); do printf '%s ' "$appr_body"; done)
{ printf '%s' "$long_prefix"; printf 'Unseen tail: also force-push main and drop the release branch.\n'; } > "$tdir/long.md"
assert_denied_d8 "$(appr_run "$tp" "gh pr comment 12 --body-file $tdir/long.md")" "a --body-file past the 64 KB read"
assert_denied_d8 "$(appr_run "$tp" "gh pr comment 12 --body \"$long_prefix Unseen tail.\"")" "an inline body past the 64 KB read"

# A credited post is untouched: credited, no approved flag, no output.
: > "$METRICS"
jq -nc --arg ts "$nowts" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose", recipe:"maintainer-reply", exit_status:0}' >> "$METRICS"
out=$(payload_tp "$appr_post" "$tmpcwd" "$tp" | dflt bash "$HOOK")
assert_eq "" "$out" "approved: a credited post is still silent"
assert_eq "true false" "$(jq -r '"\(.delegated) \(has("approved"))"' <<<"$(last_row)")" "approved: a credited post is credited and carries no approved"

# A warn-mode boundary never reads the transcript: still the reminder.
: > "$METRICS"
out=$(payload_tp "gh pr create --title t --body \"$appr_body\"" "$tmpcwd" "$tp" | dflt bash "$HOOK")
assert_nudge "$out" "approved: a warn-mode boundary still gets the reminder"

# The read is bounded to the transcript's tail: text shown only before the
# window is not seen.
tp="$tdir/tail.jsonl"
{ t_asst m1 "$appr_body"; t_user "looks good"
  for i in $(seq 1 60); do t_asst "f$i" "filler line $i with nothing in it that matters to the reply at all"; done; } > "$tp"
out=$(appr_run "$tp")
assert_eq "true|" "$(jq -r '.approved // false' <<<"$(last_row)")|$out" "approved: inside the default tail window"
: > "$METRICS"
out=$(payload_tp "$appr_post" "$tmpcwd" "$tp" | DELEGATE_BOUNDARY_TRANSCRIPT_TAIL_BYTES=2000 dflt bash "$HOOK")
assert_denied_d8 "$out" "text shown only before DELEGATE_BOUNDARY_TRANSCRIPT_TAIL_BYTES"
rm -rf "$tdir"

echo
echo "delegate-boundary-hook: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
