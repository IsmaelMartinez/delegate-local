#!/usr/bin/env bash
# PostToolUse hook for Edit / Write — runs the same validators CI runs,
# scoped to the file just edited. Exit 2 surfaces a failure to Claude so
# it can react before the next action; the file is already written by the
# time this runs.
#
# Wired up in .claude/settings.json. The validators themselves are the
# canonical gate; this hook just shortens the local feedback loop.

set -uo pipefail

input=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null)
[[ -z "$file" ]] && exit 0

case "$file" in
  *SKILL.md)
    bash scripts/validate-frontmatter.sh "$file" >&2 || exit 2
    bash scripts/validate-skill-content.sh "$file" >&2 || exit 2
    ;;
  */scripts/*.sh|*/tests/*.sh)
    bash -n "$file" >&2 || exit 2
    ;;
  *evals/eval-set.json)
    bash scripts/eval-skill-triggers.sh >&2 || exit 2
    ;;
esac
exit 0
