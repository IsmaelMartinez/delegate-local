#!/usr/bin/env bash
# Unit tests for delegate_project_name (scripts/lib/otel.sh): the value used
# for delegate.project. The behaviour under test is that a delegation run from
# a linked git worktree attributes to the MAIN repository, not the worktree
# directory name — so all of a repo's worktree sessions share one project value.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/otel.sh
. "$REPO/scripts/lib/otel.sh"

pass=0
fail=0
assert_eq() {
  if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1))
  else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi
}

if ! command -v git >/dev/null; then
  echo "  SKIP  git not on PATH"; echo; echo "$pass passed, $fail failed"; exit 0
fi

tmp=$(mktemp -d)
# Isolate from the user's global/system git config so the test is hermetic.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo="$tmp/myrepo"
git init -q "$repo"
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
mkdir -p "$repo/sub/dir"
wt="$tmp/wt-feature-x"
git -C "$repo" worktree add -q "$wt" -b feature-x >/dev/null 2>&1

# T1: from the main repo root → repo basename.
assert_eq "myrepo" "$(cd "$repo" && delegate_project_name)" "T1: main repo root resolves to repo name"

# T2: from a linked worktree → main repo basename (the fix; pre-fix this was
# the worktree dir name "wt-feature-x").
assert_eq "myrepo" "$(cd "$wt" && delegate_project_name)" "T2: linked worktree resolves to main repo name"

# T3: from a nested subdirectory of the main repo → repo basename.
assert_eq "myrepo" "$(cd "$repo/sub/dir" && delegate_project_name)" "T3: subdirectory resolves to repo name"

# T4: outside any git repo → cwd basename (fallback preserves old behaviour).
outside="$tmp/not-a-repo"
mkdir -p "$outside"
assert_eq "not-a-repo" "$(cd "$outside" && delegate_project_name)" "T4: outside a repo falls back to cwd basename"

git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
