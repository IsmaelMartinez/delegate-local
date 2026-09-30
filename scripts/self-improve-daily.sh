#!/usr/bin/env bash
# self-improve-daily.sh — the scheduled runner for the daily calibration pass
# (#558, docs/self-improvement-loop.md "Run it on a schedule"). launchd starts
# it once a day; a session-bound cron dies with its session, which left the
# watermark at 2026-09-22 for over a week.
#
# It runs the gate with --peek. Exit 10 (nothing new) is a quiet, successful
# run and no model is called. Otherwise it starts one headless `claude -p`
# session in a detached worktree of this clone at origin/main, with the
# evidence bundle on stdin and a narrow tool allowlist, and advances the
# watermark to the bundle's "Newest row" only when that session exits 0, so
# a failed session leaves the window for the next day. Rows appended while
# the session runs (its own commit and PR delegations) stay after the
# watermark and reach the next bundle.
#
# Run it from the live clone (~/.local/share/delegate-local-live), never from
# a dev checkout: the gate and the worktree both come from the clone this
# script sits in.
#
# Env:
#   DELEGATE_LOCAL_DATA_DIR      data dir (default ~/.local/share/delegate-local);
#                                the log, lock and worktree live here
#   DELEGATE_SELF_IMPROVE_STATE  watermark file (default <data dir>/self-improve.state),
#                                the same one self-improve.sh reads
# Exit: 0 quiet, done, or another run holds the lock; 1 the session failed;
#       2 setup or gate error. Everything goes to <data dir>/self-improve-daily.log.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_dir="${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}"
state_file="${DELEGATE_SELF_IMPROVE_STATE:-$data_dir/self-improve.state}"
log="$data_dir/self-improve-daily.log"
lock="$data_dir/self-improve-daily.lock"
work="$data_dir/self-improve-work"

# The log carries rejection reasons and corpus evidence: private, as the
# drafts and the replay cache are.
umask 077
mkdir -p "$data_dir" || exit 2
exec >>"$log" 2>&1
chmod 600 "$log" 2>/dev/null || true
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# One run at a time. The lock is a symlink whose target is the owner's pid,
# created in one step, so there is no moment where it exists without an
# owner for a second run to read as stale; a run killed mid-session (sleep,
# reboot) leaves a lock the next day's run can see is dead. Two runs that
# both find the same dead owner can still race the takeover, which launchd,
# never starting a job that is already running, does not produce.
if ! ln -s "$$" "$lock" 2>/dev/null; then
  owner=$(readlink "$lock" 2>/dev/null)
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    say "another run is already running (pid $owner); skipping"
    exit 0
  fi
  say "taking over a stale lock (pid ${owner:-unknown})"
  rm -rf "$lock"
  ln -s "$$" "$lock" 2>/dev/null || { say "another run took the lock first; skipping"; exit 0; }
fi
bundle=$(mktemp)
cleanup() {
  if [[ -d "$work" ]]; then git -C "$root" worktree remove --force "$work" >/dev/null 2>&1 || rm -rf "$work"; fi
  rm -f "$bundle"
  if [[ "$(readlink "$lock" 2>/dev/null)" == "$$" ]]; then rm -f "$lock"; fi
}
trap cleanup EXIT

claude_bin=$(command -v claude) || {
  say "claude not found on PATH ($PATH); launchd does not read your shell profile, so set PATH in the plist"
  exit 2
}

say "gate: $root/scripts/self-improve.sh --peek"
bash "$root/scripts/self-improve.sh" --peek > "$bundle"
rc=$?
if (( rc == 10 )); then say "quiet: nothing new since the watermark"; exit 0; fi
if (( rc != 0 )); then say "gate failed with exit $rc"; exit 2; fi
newest=$(sed -n 's/^Newest row: //p' "$bundle" | head -n 1)
if [[ -z "$newest" ]]; then say "gate printed no 'Newest row:' line; not starting a session"; exit 2; fi
say "open: bundle up to $newest"

# The session edits recipes on a branch, so it needs a checkout of its own:
# a branch in the live clone would ship into every Claude session (#360).
rm -rf "$work"
git -C "$root" worktree prune >/dev/null 2>&1
git -C "$root" fetch -q origin || { say "git fetch failed"; exit 2; }
git -C "$root" worktree add --detach "$work" origin/main >/dev/null || { say "could not create $work"; exit 2; }

today=$(date -u +%Y-%m-%d)
prompt="You are the scheduled daily self-improvement pass for delegate-local, running headless with nobody watching.
Read docs/self-improvement-loop.md and follow it from \"What the bundle gives you\" to the end. The gate has already run with --peek and its evidence bundle is on stdin; do not run scripts/self-improve.sh without --peek, because this runner advances the watermark when you exit successfully.
Choose at most one fix. If you make one, create a branch named loop/$today-<short-slug> from this detached checkout, commit, push that branch with 'git push -u origin loop/$today-<slug>', and open a PR against main with 'gh pr create'. Draft commit and PR text with scripts/delegate.sh recipes and record each verdict with scripts/delegate-feedback.sh --id, as the repo's CLAUDE.md describes.
Never merge, never push to main, never publish or release anything.
End with one line: the PR URL, or why the evidence was too thin to change anything."

# The allowlist is only a boundary while nothing it runs can be rewritten:
# a script the session could edit and then run would carry any denied
# command past it. So edits are confined to prompts/ (a recipe and its
# calibration notes, all the procedure changes; an Edit rule binds the Write
# tool too, and prompts/../ is refused), the scripts and suites it may run
# live outside prompts/, and the suites are named exactly. User settings are
# not loaded, so the profile's own allow rules cannot widen this list.
allowed=(
  Read Grep Glob "Edit(prompts/**)"
  "Bash(bash scripts/self-improve.sh --peek*)"
  "Bash(bash scripts/replay-recipe.sh *)"
  "Bash(bash scripts/metrics-summary.sh*)"
  "Bash(bash scripts/delegate.sh *)"
  "Bash(bash scripts/delegate-feedback.sh *)"
  "Bash(bash tests/test-delegate.sh)"
  "Bash(bash tests/test-prompts-library.sh)"
  "Bash(bash tests/test-self-improve.sh)"
  "Bash(shellcheck *)"
  "Bash(git status*)" "Bash(git diff*)" "Bash(git log*)" "Bash(git show*)"
  "Bash(git switch -c loop/*)" "Bash(git checkout -b loop/*)"
  "Bash(git add *)" "Bash(git commit *)"
  "Bash(git push -u origin loop/*)"
  "Bash(gh pr create *)" "Bash(gh pr list *)" "Bash(gh pr view *)" "Bash(gh issue view *)"
)
denied=(
  "Bash(gh pr merge *)" "Bash(gh release *)" "Bash(npm publish *)"
  "Bash(git push * main*)" "Bash(git push *:main*)"
)

say "session: $claude_bin -p in $work"
(cd "$work" && "$claude_bin" -p "$prompt" \
  --setting-sources project \
  --permission-mode dontAsk \
  --allowedTools "${allowed[@]}" \
  --disallowedTools "${denied[@]}" < "$bundle")
rc=$?
if (( rc != 0 )); then say "session failed with exit $rc; watermark left where it was"; exit 1; fi

mkdir -p "$(dirname "$state_file")"
printf '%s\n' "$newest" > "$state_file" || { say "could not write the watermark $state_file"; exit 2; }
say "done: watermark advanced to $newest"
