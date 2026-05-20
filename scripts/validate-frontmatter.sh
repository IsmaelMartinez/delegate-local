#!/usr/bin/env bash
# Validate a SKILL.md has YAML frontmatter with required fields, that name
# matches the directory it lives in, and that name conforms to the Claude
# Skills name regex.
#
# Usage: validate-frontmatter.sh <path-to-SKILL.md>
# Exit:  0 OK, 1 violation, 2 usage error.

set -uo pipefail

skill="${1:-}"
if [[ -z "$skill" || ! -f "$skill" ]]; then
  echo "usage: validate-frontmatter.sh <path-to-SKILL.md>" >&2
  exit 2
fi

# Determine the directory name to compare `name:` against. The naive choice
# is the SKILL.md's parent directory, which works for the canonical layouts:
#   ./SKILL.md                                 → repo root
#   ~/.claude/skills/delegate-to-ollama/SKILL.md  → installed skill dir
# But it breaks inside a git worktree (.claude/worktrees/<branch>/SKILL.md),
# where the parent is the worktree name, not the skill name. Detect that
# case via git's common-dir (shared across worktrees) and resolve to the
# main checkout's basename. Falls back to the parent-directory check when
# git is unavailable or the file is outside any checkout.
git_common_dir=$(git -C "$(dirname "$skill")" rev-parse --git-common-dir 2>/dev/null || true)
if [[ -n "$git_common_dir" ]]; then
  # --git-common-dir can be relative (".git") or absolute; resolve relative
  # paths against the SKILL.md's parent so the basename below is correct.
  if [[ "$git_common_dir" != /* ]]; then
    git_common_dir="$(cd "$(dirname "$skill")" && cd "$git_common_dir" 2>/dev/null && pwd)"
  fi
  dir_name=$(basename "$(dirname "$git_common_dir")")
else
  dir_name=$(basename "$(cd "$(dirname "$skill")" && pwd)")
fi

fail() {
  echo "::error file=$skill::$1" >&2
  echo "validate-frontmatter: $1" >&2
  exit 1
}

# Extract the first --- ... --- block.
fm=$(awk 'BEGIN{c=0} /^---[[:space:]]*$/{c++; next} c==1{print} c==2{exit}' "$skill")
if [[ -z "$fm" ]]; then fail "no frontmatter"; fi

name=$(awk -F': *' '/^name:/{sub(/^name: */,""); gsub(/["\x27]/,""); print; exit}' <<<"$fm")
# Capture description, including indented continuation lines for YAML block
# scalars (`|` / `>`) or folded multi-line strings.
desc=$(awk '/^description:/{sub(/^description: */,""); print; while(getline && /^[[:space:]]+/) print}' <<<"$fm")

[[ -n "$name" ]] || fail "missing name"
[[ -n "$desc" ]] || fail "missing description"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || fail "name '$name' fails regex ^[a-z0-9][a-z0-9-]{0,63}\$"
[[ "$name" == "$dir_name" ]] || fail "name '$name' does not match directory '$dir_name'"
(( ${#desc} <= 4096 )) || fail "description exceeds 4096 chars (${#desc})"

echo "OK $skill"
