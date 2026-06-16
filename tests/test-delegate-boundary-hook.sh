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

# 8h-ter. gh issue create --web (browser form) is NOT a boundary: no inline body.
: > "$METRICS"
ec=0
out=$(payload 'gh issue create --web' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "gh issue create --web: exit 0"
assert_eq "" "$out" "gh issue create --web: no nudge"
assert_eq 0 "$(nrows)" "gh issue create --web: no row (no inline body)"

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
: > "$METRICS"
oldish=$(jq -rn --argjson now "$(date -u +%s)" '($now - 300) | todateiso8601')
jq -nc --arg ts "$oldish" --arg p "$proj" \
  '{ts:$ts, source:"delegate", project:$p, tier:"prose"}' >> "$METRICS"
payload 'git commit -m x' "$tmpcwd" | DELEGATE_METRICS_FILE="$METRICS" DELEGATE_BOUNDARY_WINDOW_MIN=1 bash "$HOOK" >/dev/null
assert_eq false "$(jq -r .delegated <<<"$(last_row)")" "custom window: 5m-old delegation outside 1m window"

# 14. Fail-open on malformed stdin.
ec=0
out=$(echo 'not json' | DELEGATE_METRICS_FILE="$METRICS" bash "$HOOK") || ec=$?
assert_eq 0 "$ec" "malformed stdin: exit 0 (fail-open)"

rm -rf "$tmpcwd" "$METRICS"
echo
echo "delegate-boundary-hook: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
