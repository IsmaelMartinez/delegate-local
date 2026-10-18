#!/usr/bin/env bash
# Structural checks on every prompts/<task>.md recipe: required sections,
# documented placeholders, README listing, and per-recipe inputs, placeholder
# placement and declared checks. Template wording is the replay gate's job.

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

# Print every fenced block under the given '## ' heading. Fence state is
# tracked so a '## ' line inside an example does not end the section, as
# delegate.sh's own extraction does.
extract_fenced() {
  local file="$1" heading="$2"
  awk -v heading="$heading" '
    { line=$0; sub(/[[:space:]]+$/, "", line) }
    line == heading { in_section=1; next }
    in_section && /^```/ { in_block = !in_block; next }
    in_section && !in_block && line ~ /^## / { in_section=0 }
    in_section && in_block { print }
  ' "$file"
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

# 2. README points to delegate.sh as the integration surface.
assert_contains "scripts/delegate.sh" "$readme" "README references delegate.sh"
assert_contains "SKILL.md" "$readme" "README references SKILL.md"

# 3. Every prompts/<task>.md (excluding README itself) is structurally valid.
required_sections=(
  "## When to use"
  "## Context to gather first"
  "## Prompt template"
  "## Invocation"
  "## Calibration notes"
)

recipe_count=0
for recipe in "$PROMPTS_DIR"/*.md; do
  base=$(basename "$recipe")
  [[ "$base" == "README.md" ]] && continue
  recipe_count=$((recipe_count + 1))
  body=$(cat "$recipe")
  # The title must match the filename, after any YAML frontmatter is stripped.
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
  # An `inputs:` block must be flat `key: type[?]` pairs (integer | string)
  # so the awk in delegate.sh stays small.
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
  # The dated history lives in docs/calibration/<task>.md (#569); the recipe
  # keeps only a one-line pointer, so the section must stay that short.
  calib="docs/calibration/${base%.md}.md"
  if [[ -f "$REPO/$calib" ]]; then
    echo "  PASS  $base: $calib exists"; pass=$((pass+1))
  else
    echo "  FAIL  $base: $calib missing"; fail=$((fail+1))
  fi
  calib_section=$(awk '
    /^## Calibration notes[[:space:]]*$/ { s=1; next }
    s && /^## / { exit }
    s && NF { print }
  ' "$recipe")
  if [[ "$calib_section" == *"$calib"* && "$(printf '%s\n' "$calib_section" | grep -c '')" -eq 1 ]]; then
    echo "  PASS  $base: '## Calibration notes' is a one-line pointer to $calib"; pass=$((pass+1))
  else
    echo "  FAIL  $base: '## Calibration notes' must be one line pointing at $calib"; fail=$((fail+1))
  fi
  # Every {{placeholder}} except {{stdin}} must be documented under '## Variables'.
  template=$(extract_fenced "$recipe" "## Prompt template")
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
  # The legacy `<paste X here>` marker cannot be substituted by --recipe.
  if printf '%s' "$template" | grep -qE '<paste .* here>'; then
    echo "  FAIL  $base: legacy '<paste ... here>' marker found in template (use {{name}})"; fail=$((fail+1))
  else
    echo "  PASS  $base: no legacy '<paste ... here>' markers"; pass=$((pass+1))
  fi
  # The fenced '## Invocation' example must be free of command substitution
  # (#350): sandboxed harnesses refuse `$(...)`, so literal --var values are
  # the documented form.
  invocation_example=$(extract_fenced "$recipe" "## Invocation")
  if [[ -z "$invocation_example" ]]; then
    echo "  FAIL  $base: '## Invocation' has no fenced example to check"; fail=$((fail+1))
  elif [[ "$invocation_example" == *'$('* || "$invocation_example" == *'`'* ]]; then
    echo "  FAIL  $base: '## Invocation' uses command substitution (pass literal --var values; quote inline code with '\"' not backticks)"; fail=$((fail+1))
  else
    echo "  PASS  $base: '## Invocation' free of command substitution"; pass=$((pass+1))
  fi
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

# 6. Structure every recipe shares. Template wording is not pinned here
# (#566); the recipe-specific pins left with their recipes in ADR 0035.

# Every dispatchable recipe declares a frontmatter `tier:` (#411); README.md
# is not dispatchable. The vocabulary is read from pick-model.sh's TIERS line so this cannot drift.
VALID_TIERS=$(sed -n 's/^TIERS="\(.*\)"$/\1/p' "$REPO/scripts/pick-model.sh" | tr '|' ' ')
if [[ -z "$VALID_TIERS" ]]; then
  echo "  FAIL  could not read TIERS from scripts/pick-model.sh"; fail=$((fail+1))
fi
for recipe_file in "$PROMPTS_DIR"/*.md; do
  base=$(basename "$recipe_file" .md)
  [[ "$base" == "README" ]] && continue
  if [[ "$(head -1 "$recipe_file")" != "---" ]]; then
    if grep -q '^## Prompt template' "$recipe_file"; then
      echo "  FAIL  $base.md is dispatchable but has no frontmatter to declare tier: in"; fail=$((fail+1))
    fi
    continue
  fi
  declared=$(awk '
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^tier:[[:space:]]*[a-z-]+[[:space:]]*$/ {
      sub(/^tier:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }
  ' "$recipe_file")
  if [[ -z "$declared" ]]; then
    echo "  FAIL  $base.md declares no frontmatter tier:"; fail=$((fail+1)); continue
  fi
  ok=0
  for t in $VALID_TIERS; do [[ "$t" == "$declared" ]] && ok=1; done
  if [[ "$ok" == "1" ]]; then
    echo "  PASS  $base.md declares tier: $declared"; pass=$((pass+1))
  else
    echo "  FAIL  $base.md declares an unknown tier: $declared"; fail=$((fail+1))
  fi
done

# No invocation may still show a tier. The whole fenced block is scanned
# (multi-line --var values exist), and the section-end check is gated on
# being outside the fence (a --var value may contain '## ' headings).
for recipe_file in "$PROMPTS_DIR"/*.md; do
  base=$(basename "$recipe_file" .md)
  inv=$(awk '
    /^## Invocation[[:space:]]*$/ { in_sec=1; next }
    in_sec && !in_block && /^## / { exit }
    in_sec && /^```/ { if (in_block) exit; in_block=1; next }
    in_sec && in_block { print }
  ' "$recipe_file" | tr '\n' ' ')
  [[ -z "$inv" ]] && continue
  tier_alt=$(printf '%s' "$VALID_TIERS" | tr ' ' '|' | sed 's/^|//; s/|$//')
  if printf '%s' "$inv" | grep -qE "(^|[[:space:]])($tier_alt)([[:space:]]|\$)"; then
    echo "  FAIL  $base.md invocation still passes a tier"; fail=$((fail+1))
  else
    echo "  PASS  $base.md invocation passes no tier"; pass=$((pass+1))
  fi
done

# Every backticked `<name>.md` in a recipe or SKILL.md resolves to a file in
# prompts/; a pruned recipe is named without the extension.
dangling=""
while read -r ref; do
  [[ -z "$ref" ]] && continue
  [[ -f "$PROMPTS_DIR/$ref" ]] && continue
  dangling="${dangling:+$dangling }$ref"
done < <(grep -oh '`[a-z0-9-]\{1,\}\.md`' "$PROMPTS_DIR"/*.md "$REPO/SKILL.md" 2>/dev/null \
           | tr -d '`' | sort -u)
if [[ -n "$dangling" ]]; then
  echo "  FAIL  recipe cross-references resolve (missing in prompts/: $dangling)"; fail=$((fail+1))
else
  echo "  PASS  every backticked <name>.md cross-reference resolves to a recipe"; pass=$((pass+1))
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
