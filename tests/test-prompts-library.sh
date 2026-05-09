#!/usr/bin/env bash
# Validate that each prompts/<task>.md recipe has the four required sections
# (When to use, Context to gather first, Prompt template, Calibration notes)
# and that prompts/README.md references the file. Catches drift early — a
# recipe missing its calibration provenance loses its empirical anchor; one
# missing the prompt template is unusable; one missing from the README is
# invisible to future agents loading the skill.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPTS_DIR="$REPO/prompts"

pass=0
fail=0

assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}

# 1. README.md exists.
if [[ -f "$PROMPTS_DIR/README.md" ]]; then
  echo "  PASS  prompts/README.md exists"; pass=$((pass+1))
else
  echo "  FAIL  prompts/README.md missing"; fail=$((fail+1))
  echo
  echo "$pass passed, $fail failed"
  exit 1
fi

readme=$(cat "$PROMPTS_DIR/README.md")

# 2. README points to delegate.sh and delegate-feedback.sh as the integration surface.
assert_contains "scripts/delegate.sh" "$readme" "README references delegate.sh"
assert_contains "scripts/delegate-feedback.sh" "$readme" "README references delegate-feedback.sh"
assert_contains "SKILL.md" "$readme" "README references SKILL.md"

# 3. Every prompts/<task>.md (excluding README itself) is structurally valid.
required_sections=(
  "## When to use"
  "## Context to gather first"
  "## Prompt template"
  "## Calibration notes"
)

recipe_count=0
for recipe in "$PROMPTS_DIR"/*.md; do
  base=$(basename "$recipe")
  [[ "$base" == "README.md" ]] && continue
  recipe_count=$((recipe_count + 1))
  body=$(cat "$recipe")
  # Title must match filename: prompts/foo.md → "# foo" as the first heading.
  expected_title="# ${base%.md}"
  if [[ "$body" == "$expected_title"* ]]; then
    echo "  PASS  $base: title matches filename"; pass=$((pass+1))
  else
    echo "  FAIL  $base: expected first line '$expected_title'"; fail=$((fail+1))
  fi
  for section in "${required_sections[@]}"; do
    assert_contains "$section" "$body" "$base: contains '$section'"
  done
  # README must list this recipe in the "Current recipes" section so future
  # agents can discover it. Match by filename anywhere in the README.
  if [[ "$readme" == *"$base"* ]]; then
    echo "  PASS  $base: listed in README"; pass=$((pass+1))
  else
    echo "  FAIL  $base: not listed in README"; fail=$((fail+1))
  fi
done

# 4. At least one recipe exists (otherwise the library is empty by accident).
if (( recipe_count > 0 )); then
  echo "  PASS  prompts/ contains $recipe_count recipe(s)"; pass=$((pass+1))
else
  echo "  FAIL  prompts/ has no recipes"; fail=$((fail+1))
fi

# 5. SKILL.md "Recipes" section references prompts/ so the agent knows it exists.
skill_body=$(cat "$REPO/SKILL.md")
assert_contains "## Recipes" "$skill_body" "SKILL.md has '## Recipes' section"
assert_contains "prompts/" "$skill_body" "SKILL.md '## Recipes' references prompts/"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
