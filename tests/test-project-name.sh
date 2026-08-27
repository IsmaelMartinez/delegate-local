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

# T4: outside any git repo → NOTHING. The cwd's basename is not a project, and
# saying it is produced a real-looking name that names nothing: a delegation
# about `delegate-local` issued from a scratch directory was filed under
# `project:"tmp"` on 2026-08-27. That fragments the per-project rollup and can
# never match a boundary lookup, so the hook nudges a session that did in fact
# delegate. delegate-boundary-hook.sh already refuses this exact string for its
# own derivation (#385); this is the wrapper agreeing.
outside="$tmp/not-a-repo"
mkdir -p "$outside"
assert_eq "" "$(cd "$outside" && delegate_project_name)" "T4: outside a repo yields no project"
# T4b: and specifically not the scratch-directory name that started this.
scratch="$tmp/tmp"
mkdir -p "$scratch"
assert_eq "" "$(cd "$scratch" && delegate_project_name)" "T4b: a scratch dir is not filed under its basename"

# T4c: a git too old to answer --git-common-dir (pre-2.5) still resolves a
# project via --show-toplevel. Removing that fallback while adding the
# outside-a-repo case would have returned nothing INSIDE a repository on those
# hosts. Simulated with a git shim that refuses the one subcommand.
shim="$tmp/shim"
mkdir -p "$shim"
cat > "$shim/git" <<'SHIMEOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "--git-common-dir" ]]; then exit 129; fi
done
exec /usr/bin/env -u PATH_SHIM "$REAL_GIT" "$@"
SHIMEOF
chmod +x "$shim/git"
REAL_GIT=$(command -v git) \
  && assert_eq "myrepo" "$(cd "$repo" && PATH="$shim:$PATH" REAL_GIT="$REAL_GIT" delegate_project_name)" \
    "T4c: --show-toplevel still resolves a project when --git-common-dir fails"
assert_eq "" "$(cd "$outside" && PATH="$shim:$PATH" REAL_GIT="$(command -v git)" delegate_project_name)" \
  "T4d: the fallback still yields nothing outside a repo"

# T5: an explicit DELEGATE_PROJECT wins over every derivation. The cwd answer
# is only right when the script runs inside the repo the delegation is FOR, so
# delegating on behalf of repo X from the skill checkout has to be statable
# (#342). Resolving it here rather than in delegate.sh alone is what keeps
# delegate-feedback.sh's verdict row on the same project as the delegate row.
assert_eq "teams-for-linux" "$(cd "$repo" && DELEGATE_PROJECT=teams-for-linux delegate_project_name)" \
  "T5: DELEGATE_PROJECT overrides the repo derivation"
assert_eq "teams-for-linux" "$(cd "$outside" && DELEGATE_PROJECT=teams-for-linux delegate_project_name)" \
  "T5b: DELEGATE_PROJECT still names the project outside a repo"
# T6: an empty DELEGATE_PROJECT is not an override — it falls through.
assert_eq "myrepo" "$(cd "$repo" && DELEGATE_PROJECT= delegate_project_name)" \
  "T6: empty DELEGATE_PROJECT falls through to the derivation"

git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
