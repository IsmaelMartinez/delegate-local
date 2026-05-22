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
  # Optional YAML frontmatter (Phase 12 Track B, #161) is stripped first so a
  # recipe declaring an inputs: block still passes the title-prefix check.
  expected_title="# ${base%.md}"
  body_after_fm="$body"
  if [[ "$body" == "---"$'\n'* ]]; then
    body_after_fm=$(awk 'BEGIN{c=0} /^---[[:space:]]*$/{c++; if (c==2) {f=1; next}} f' "$recipe")
  fi
  if [[ "$body_after_fm" == "$expected_title"* ]]; then
    echo "  PASS  $base: title matches filename"; pass=$((pass+1))
  else
    echo "  FAIL  $base: expected first line '$expected_title' after optional frontmatter"; fail=$((fail+1))
  fi
  # If the recipe has frontmatter with an `inputs:` block, validate it
  # against the flat `key: type` constraint Convention 2 (Phase 12 Track B,
  # #161) imposes. Nested keys, anchors, or flow style are rejected by the
  # convention so `awk` in delegate.sh stays small. Supported types:
  # integer | string | integer? | string?.
  if [[ "$body" == "---"$'\n'* ]]; then
    inputs_lines=$(awk '
      BEGIN { in_fm=0; in_inputs=0 }
      NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
      in_fm && /^---[[:space:]]*$/ { exit }
      in_fm && /^inputs:[[:space:]]*$/ { in_inputs=1; next }
      in_fm && in_inputs && /^[[:space:]]/ { print }
      in_fm && in_inputs && /^[a-zA-Z_]/ { in_inputs=0 }
    ' "$recipe")
    if [[ -n "$inputs_lines" ]]; then
      bad_inputs=0
      while IFS= read -r iline; do
        [[ -z "$iline" ]] && continue
        # Each non-empty inputs line must match the flat `  key: type[?]` shape.
        if ! [[ "$iline" =~ ^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*(integer|string)\??[[:space:]]*$ ]]; then
          bad_inputs=1
          echo "  FAIL  $base: inputs: line violates flat key:type convention: '$iline'"; fail=$((fail+1))
        fi
      done <<< "$inputs_lines"
      if (( bad_inputs == 0 )); then
        echo "  PASS  $base: inputs: block uses only supported flat key:type pairs"; pass=$((pass+1))
      fi
    fi
  fi
  for section in "${required_sections[@]}"; do
    assert_contains "$section" "$body" "$base: contains '$section'"
  done
  # Every {{placeholder}} in the prompt template must be documented in the
  # '## Variables' section so future agents know what each --var expects.
  # `{{stdin}}` is the implicit pipe slot and does not need explicit doc.
  template=$(awk '
    /^## Prompt template[[:space:]]*$/ { in_section=1; next }
    /^## / && in_section { in_section=0 }
    in_section && /^```/ {
      if (in_block) { exit }
      in_block=1; next
    }
    in_section && in_block { print }
  ' "$recipe")
  if [[ -z "$template" ]]; then
    echo "  FAIL  $base: '## Prompt template' has no fenced code block"; fail=$((fail+1))
  fi
  placeholders=$(printf '%s' "$template" | grep -oE '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' | sort -u || true)
  for ph in $placeholders; do
    name="${ph#\{\{}"; name="${name%\}\}}"
    [[ "$name" == "stdin" ]] && continue
    if [[ "$body" == *"\`{{$name}}\`"* ]]; then
      echo "  PASS  $base: {{$name}} documented under Variables"; pass=$((pass+1))
    else
      echo "  FAIL  $base: {{$name}} used in template but not listed in '## Variables'"; fail=$((fail+1))
    fi
  done
  # Catch the legacy `<paste X here>` style — every such marker should now be
  # a {{name}} placeholder so --recipe can substitute it programmatically.
  if printf '%s' "$template" | grep -qE '<paste .* here>'; then
    echo "  FAIL  $base: legacy '<paste ... here>' marker found in template (use {{name}})"; fail=$((fail+1))
  else
    echo "  PASS  $base: no legacy '<paste ... here>' markers"; pass=$((pass+1))
  fi
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

# 6. Recipe-specific structural pins. Each entry names the recipe and the
# named directives that calibration history shows must survive future
# "simplification" passes — without these pins a refactor can silently drop
# a guard whose absence cost real session iterations to add.

# commit-message.md: the 2026-05-22 calibration entry promoted SUBJECT_LEN
# and TYPE-selection into template-body first-match-wins directives after
# three MISS rows (ts=2026-05-22T09:42:54Z, 11:14:13Z, 09:40:45Z) confirmed
# the trailing-prompt reinforcement was insufficient. Pin both directive
# headings inside the prompt template so a future simplification cannot
# silently revert to advisory enumeration.
commit_message_template=$(awk '
  /^## Prompt template[[:space:]]*$/ { in_section=1; next }
  in_section && /^```/ { in_block = !in_block; print; next }
  in_section && !in_block && /^## / { exit }
  in_section { print }
' "$PROMPTS_DIR/commit-message.md")
assert_contains "Subject length — first match wins, non-negotiable" "$commit_message_template" \
  "commit-message.md prompt template names SUBJECT_LEN first-match-wins directive"
assert_contains "TYPE selection — first match wins, non-negotiable" "$commit_message_template" \
  "commit-message.md prompt template names TYPE-selection first-match-wins directive"

summarise_issue_body=$(cat "$PROMPTS_DIR/summarise-issue.md")
assert_contains "OMIT-EMPTY-SECTION" "$summarise_issue_body" \
  "summarise-issue.md names OMIT-EMPTY-SECTION rule"
assert_contains "COMMENT-N-CITATION" "$summarise_issue_body" \
  "summarise-issue.md names COMMENT-N-CITATION rule"
# The Anti-hallucination guards section must explicitly enumerate both rules
# so the calibration provenance for each guard is anchored in the document.
guards_section=$(awk '
  /^## Anti-hallucination guards/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/summarise-issue.md")
assert_contains "OMIT-EMPTY-SECTION" "$guards_section" \
  "summarise-issue.md '## Anti-hallucination guards' names OMIT-EMPTY-SECTION"
assert_contains "COMMENT-N-CITATION" "$guards_section" \
  "summarise-issue.md '## Anti-hallucination guards' names COMMENT-N-CITATION"
# The OMIT-EMPTY-SECTION rule's Wrong/Correct anchors must cover BOTH
# `## What's blocking` and `## What's next` per the PR #173 dual-anchoring
# principle. PR #180 added the What's-next symmetric pair after gemini and
# self-review flagged the asymmetry. Pin the symmetric anchor so a future
# refactor cannot silently revert to a blockers-only anchor set.
prompt_template_section=$(awk '
  /^## Prompt template[[:space:]]*$/ { in_section=1; next }
  in_section && /^```/ { in_block = !in_block; print; next }
  in_section && !in_block && /^## / { exit }
  in_section { print }
' "$PROMPTS_DIR/summarise-issue.md")
assert_contains "## What's next" "$prompt_template_section" \
  "summarise-issue.md prompt template references What's next section"
# The Wrong-shape anchor for the What's-next zero-comments case must be
# present — proxy for "the symmetric anchor pair survives refactors".
assert_contains "no next-action stated" "$prompt_template_section" \
  "summarise-issue.md prompt template anchors no-next-action Wrong shape"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
