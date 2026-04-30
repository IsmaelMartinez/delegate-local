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

dir_name=$(basename "$(cd "$(dirname "$skill")" && pwd)")

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
