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
    *:8080/*) printf '{"object":"list","data":[{"id":"qwen3.6:35b-a3b-q8_0","object":"model"}]}'; exit 0 ;;
  esac
done
exit 7
EOF
chmod +x "$MOCKDIR/curl"
export PATH="$MOCKDIR:$PATH"
export DELEGATE_BASE_URL=http://localhost:8080/v1
export DELEGATE_LOCAL_CONFIG=/dev/null
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
assert_contains '"permissionDecision":"allow"' "$out" "no-metrics: never denies (no credit could be recorded)"
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
cap_post() { payload "$1" "$capcwd" | DELEGATE_METRICS_FILE="$capm" bash "$HOOK" >/dev/null 2>&1; }

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

# A --body-file post stores the file's contents.
cap_setup
printf 'the reply that came from a file\n' > "$capcwd/reply.md"
cap_post "gh pr comment 12 --body-file $capcwd/reply.md"
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

# A POST with no body field stores nothing.
cap_setup_recipe pr-review-reply
cap_post 'gh api repos/o/r/pulls/12/comments -X POST -F in_reply_to=99 -F commit_id=abc1234'
assert_eq "" "$(ls "$capdir/drafts" 2>/dev/null)" \
  "capture: a POST with no body field stores nothing"
rm -rf "$capdir" "$capcwd"

# A bare `-F path` (no `=`) is still `--body-file`.
cap_setup
printf 'the reply posted with the short flag' > "$capcwd/reply.md"
cap_post "gh pr comment 12 -F $capcwd/reply.md"
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

# --- #483: the four proven boundaries deny by default; pr-create and
# pr-review-body stay on warn. These run at the default body floor with
# bodies long enough to be real drafting ---
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

# 62. DELEGATE_BOUNDARY_MODE=warn/off win over the set, =enforce means every
# boundary; DELEGATE_BOUNDARY_ENFORCE is the comma-separated set, empty is none.
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

# 63. Fail open when no provider answers: the deny becomes a reminder and the
# row says so.
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
# A commit whose message arrives on stdin (`-F -`) has no measurable body:
# no body_chars, and enforced.
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
payload "$cc" "$capcwd" | DELEGATE_METRICS_FILE="$capm" DELEGATE_BOUNDARY_MIN_CHARS= bash "$HOOK" >/dev/null 2>&1
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
payload "git commit -m \"fix: thing\" && gh pr comment 1 --body-file $capcwd/notes.md" "$capcwd" \
  | DELEGATE_METRICS_FILE="$capm" DELEGATE_BOUNDARY_MIN_CHARS= bash "$HOOK" >/dev/null 2>&1
assert_eq "fix: thing" "$(cat "$capdir/$capfinal" 2>/dev/null)" "segment scope: the commit's final is its own message, not a later --body-file"
rm -rf "$capdir" "$capcwd"

# 69. Repeated `-m` are paragraphs git joins with a blank line, so they are summed.
para1='fix: the subject line, forty characters'
para2='and the body paragraph, also forty chars'
: > "$METRICS"
out=$(payload "git commit -m \"$para1\" -m \"$para2\"" "$tmpcwd" | DELEGATE_BOUNDARY_MIN_CHARS=60 DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK")
assert_eq "$(( ${#para1} + 2 + ${#para2} ))" "$(jq -r '.body_chars // empty' <<<"$(last_row)")" "summed -m: body_chars is both paragraphs plus the blank line"
assert_contains '"permissionDecision":"deny"' "$out" "summed -m: two 40-char paragraphs clear a 60-char floor together"

# 70. Never a permanent block: after two consecutive denials for the same
# session and boundary the third attempt is warned (enforce_skipped:"retry-cap"),
# and a metrics file the hook cannot append to fails open.
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

# 71. DELEGATE_BOUNDARY_MODE is case-insensitive and an unknown value is warn.
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

# 72. No provider, no model for the tier, and a malformed tier are told
# apart on the row and in the reminder, as pick-model.sh tells them apart.
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
: > "$METRICS"
out=$(payload "git commit -m \"$body300\"" "$tmpcwd" | dflt bash "$HOOK")
assert_contains '"permissionDecision":"allow"' "$out" "lock: an unobtainable lock fails open"
assert_eq lock-timeout "$(jq -r '.enforce_skipped // empty' <<<"$(last_row)")" "lock: ...recording enforce_skipped=lock-timeout"
assert_eq "present" "$([[ -d "$lockdir" ]] && echo present || echo absent)" "lock: a live lock is not removed by a non-owner"
assert_eq "someone-else" "$(cat "$lockdir/owner" 2>/dev/null)" "lock: ...and its owner file is untouched"
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
# ...while a command with no body flag at all is still unmeasurable.
: > "$METRICS"
out=$(payload "git commit -F - <<'EOF'
$body300
EOF" "$tmpcwd" | dflt bash "$HOOK")
assert_eq false "$(jq 'has("body_chars")' <<<"$(last_row)")" "empty body: no body flag is still no body_chars"

# 75. Lock ownership: a lock broken as stale must not be removed by its
# original holder's exit cleanup. The slow holder is a jq wrapper sleeping
# on the lookup's `-rs` slurp: A holds 9 s, B starts at 7 s (A reads stale)
# and holds 3 s; the lock must survive A's exit and vanish when B finishes.
REAL_JQ=$(command -v jq)
slow_jq() { # dir seconds
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\ncase " $* " in *" -rs "*) sleep %s ;; esac\nexec %q "$@"\n' "$2" "$REAL_JQ" > "$1/jq"
  chmod +x "$1/jq"
}
SLOWA=$(mktemp -d); slow_jq "$SLOWA" 9
SLOWB=$(mktemp -d); slow_jq "$SLOWB" 3
slow() { PATH="$1:$PATH" DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "${@:2}"; }
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

# 75b. The provider probe runs outside the lock: two 3 s probes started 1 s
# apart finish in about one probe's time.
SLOWC=$(mktemp -d)
{ printf '#!/usr/bin/env bash\nsleep 3\n'; sed '1d;/^: >> /d' "$MOCKDIR/curl"; } > "$SLOWC/curl"; chmod +x "$SLOWC/curl"
slowc() { PATH="$SLOWC:${PATH#$MOCKDIR:}" DELEGATE_BOUNDARY_MIN_CHARS= DELEGATE_METRICS_FILE="$METRICS" "$@"; }
: > "$METRICS"; rm -rf "$lockdir"
t0=$(date +%s)
payload "git commit -m \"$body300\"" "$tmpcwd" | slowc bash "$HOOK" >/dev/null &
pid_a=$!
sleep 1
payload "git commit -m \"$body300\"" "$tmpcwd" | slowc bash "$HOOK" >/dev/null &
pid_b=$!
wait "$pid_a" "$pid_b"
elapsed=$(( $(date +%s) - t0 ))
assert_eq "yes" "$([[ $elapsed -le 5 ]] && echo yes || echo "no (${elapsed}s)")" "probe outside lock: two slow probes overlap instead of queueing on the lock"
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
payload 'gh api repos/o/r/pulls/12/comments -X POST --field body=@"$T489_DIR/rr.txt" -F in_reply_to=1' "$capcwd" | T489_DIR="$envdir" DELEGATE_METRICS_FILE="$capm" bash "$HOOK" >/dev/null 2>&1
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
payload "bash $wrdir/do-commit.sh" "$capcwd" | DELEGATE_METRICS_FILE="$capm" DELEGATE_BOUNDARY_MIN_CHARS= bash "$HOOK" >/dev/null 2>&1
assert_eq true "$(jq -r '.delegated' <<<"$(tail -1 "$capm")")" "wrapper: a delegated commit inside a wrapper is credited"
assert_eq "$body300" "$(cat "$capdir/$capfinal" 2>/dev/null)" "wrapper: ...and stores the message as its final"
rm -rf "$capdir" "$capcwd" "$wrdir"

echo
echo "delegate-boundary-hook: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
