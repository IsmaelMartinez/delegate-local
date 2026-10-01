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

# 2. README points to delegate.sh and delegate-feedback.sh as the integration surface.
assert_contains "scripts/delegate.sh" "$readme" "README references delegate.sh"
assert_contains "scripts/delegate-feedback.sh" "$readme" "README references delegate-feedback.sh"
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

# 6. Recipe-specific structure. The wording inside a template is judged by
# the offline replay gate (ADR 0031, scripts/replay-recipe.sh) and is not
# pinned here, so a replay-accepted wording edit needs no test edit (#566).
# What stays is what a script or a caller depends on: declared inputs,
# placeholders and where they sit, declared checks, and the gather command.

# maintainer-reply.md (#517): the judgment sentence is the caller's. `lead`
# is a required input (no trailing `?`, so delegate.sh exits 2 without it and
# the boundary hook's nudge names it), and the template places {{lead}}
# exactly once, after the opener and before the facts, so the reply carries
# it verbatim in that position.
maintainer_reply_template=$(extract_fenced "$PROMPTS_DIR/maintainer-reply.md" "## Prompt template")
maintainer_reply_fm=$(awk '/^---[[:space:]]*$/{d++; if (d==2) exit; next} d==1' "$PROMPTS_DIR/maintainer-reply.md")
if printf '%s\n' "$maintainer_reply_fm" | grep -qE '^[[:space:]]+lead:[[:space:]]*string[[:space:]]*$'; then
  echo "  PASS  maintainer-reply.md declares lead as a required input (#517)"; pass=$((pass+1))
else
  echo "  FAIL  maintainer-reply.md does not declare lead: string as a required input (#517)"; fail=$((fail+1))
fi
lead_count=$(printf '%s' "$maintainer_reply_template" | grep -o '{{lead}}' | grep -c '')
if (( lead_count == 1 )); then
  echo "  PASS  maintainer-reply.md prompt template carries {{lead}} exactly once (#517)"; pass=$((pass+1))
else
  echo "  FAIL  maintainer-reply.md prompt template carries {{lead}} $lead_count times, expected exactly once (#517)"; fail=$((fail+1))
fi
opener_line=$(printf '%s\n' "$maintainer_reply_template" | grep -n -F '{{opener}}' | head -1 | cut -d: -f1)
lead_line=$(printf '%s\n' "$maintainer_reply_template" | grep -n -F '{{lead}}' | head -1 | cut -d: -f1)
stdin_line=$(printf '%s\n' "$maintainer_reply_template" | grep -n -F '{{stdin}}' | head -1 | cut -d: -f1)
if [[ -n "$opener_line" && -n "$lead_line" && -n "$stdin_line" ]] \
   && (( opener_line < lead_line && lead_line < stdin_line )); then
  echo "  PASS  maintainer-reply.md prompt template places {{lead}} after {{opener}} and before {{stdin}} (#517)"; pass=$((pass+1))
else
  echo "  FAIL  maintainer-reply.md prompt template must place {{lead}} after {{opener}} and before {{stdin}} (opener=$opener_line lead=$lead_line stdin=$stdin_line) (#517)"; fail=$((fail+1))
fi

# pr-description.md: the gather block fetches more than one example and
# strips the generated-by footer: no_example_echo treats a line as convention
# only when more than one exemplar carries it.
pr_description_gather=$(awk '
  /^## Context to gather first[[:space:]]*$/ { in_section=1; next }
  in_section && /^## / { exit }
  in_section { print }
' "$PROMPTS_DIR/pr-description.md")
# Asserted on the number, not the absence of `--limit 1`, so `--limit 0` or
# no --limit also fails.
pr_description_limit=$(printf '%s' "$pr_description_gather" \
  | sed -nE 's/^.*[[:space:]]--limit[[:space:]]+([0-9]+).*$/\1/p' | head -n 1)
if [[ "$pr_description_limit" =~ ^[0-9]+$ ]] && (( 10#$pr_description_limit >= 2 )); then
  echo "  PASS  pr-description.md gather block fetches at least two examples"; pass=$((pass+1))
else
  echo "  FAIL  pr-description.md gather block fetches at least two examples (got '${pr_description_limit:-no --limit}')"; fail=$((fail+1))
fi
assert_contains "Generated with" "$pr_description_gather" \
  "pr-description.md gather block strips the generated-by footer from each example"

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
  # Sentinels prove the scan reaches the trailing prompt on both shapes; a
  # truncated scan makes every FAIL below unreachable.
  case "$base" in
    pr-description)    sentinel='NO invented example output' ;;
    github-issue-body) sentinel='No title line, no closing summary' ;;
    *)                 sentinel='' ;;
  esac
  if [[ -n "$sentinel" ]]; then
    if printf '%s' "$inv" | grep -qF "$sentinel"; then
      echo "  PASS  $base.md invocation scan reaches the trailing prompt"; pass=$((pass+1))
    else
      echo "  FAIL  $base.md invocation scan truncated before the trailing prompt"; fail=$((fail+1))
    fi
  fi
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

# pr-review-reply's anti-padding half is the declared no_padding_tail check,
# which replaced the old one-clause cap.
prr="$PROMPTS_DIR/pr-review-reply.md"
if awk '/^---[[:space:]]*$/{d++; if (d==2) exit; next} d==1' "$prr" 2>/dev/null | grep -qE '^[[:space:]]+no_padding_tail:[[:space:]]*true'; then
  echo "  PASS  pr-review-reply.md declares no_padding_tail"; pass=$((pass+1))
else
  echo "  FAIL  pr-review-reply.md does not declare no_padding_tail (the check that replaced the clause cap)"; fail=$((fail+1))
fi

# The two maintainer reply recipes keep no_context_echo declared (it is
# opt-in) and the opener as a caller-supplied input (#475).
for base in maintainer-reply maintainer-review-reply; do
  rf="$PROMPTS_DIR/$base.md"
  rf_fm=$(awk '/^---[[:space:]]*$/{d++; if (d==2) exit; next} d==1' "$rf" 2>/dev/null)
  if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+no_context_echo:[[:space:]]*true'; then
    echo "  PASS  $base.md declares no_context_echo"; pass=$((pass+1))
  else
    echo "  FAIL  $base.md does not declare no_context_echo"; fail=$((fail+1))
  fi
  if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+opener:[[:space:]]*string\?'; then
    echo "  PASS  $base.md declares opener as an optional input"; pass=$((pass+1))
  else
    echo "  FAIL  $base.md does not declare opener: string?"; fail=$((fail+1))
  fi
  # The length ceiling is a declared, retry-able check (#487), not a prose
  # rule; the unconditional SHORTER rule contradicted LENGTH.
  if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+max_context_ratio:[[:space:]]*0\.8'; then
    echo "  PASS  $base.md declares max_context_ratio: 0.8"; pass=$((pass+1))
  else
    echo "  FAIL  $base.md does not declare max_context_ratio: 0.8"; fail=$((fail+1))
  fi
  rf_template=$(extract_fenced "$rf" "## Prompt template")
  # The evidence-led recipe's length is a numeric cap the caller can set
  # (2026-09-20): an optional input with its slot in the template.
  if [[ "$base" == maintainer-review-reply ]]; then
    assert_contains "{{max_words}}" "$rf_template" \
      "$base.md prompt template carries the {{max_words}} slot"
    if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+max_words:[[:space:]]*integer\?'; then
      echo "  PASS  $base.md declares max_words as an optional integer input"; pass=$((pass+1))
    else
      echo "  FAIL  $base.md does not declare max_words: integer?"; fail=$((fail+1))
    fi
  fi
  # A clean approval has no ask (#471): `ask` is optional in both reply
  # recipes.
  if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+ask:[[:space:]]*string\?'; then
    echo "  PASS  $base.md declares ask as an optional input (#471)"; pass=$((pass+1))
  else
    echo "  FAIL  $base.md does not declare ask: string? (#471)"; fail=$((fail+1))
  fi
  # #520: {{recipient}} may appear only inside the "=== Recipient handle
  # (optional) ===" block. Elsewhere in the template it must be described as
  # the angle-bracket skeleton "@<handle>, ", or an omitted (empty-string)
  # recipient renders as a bare "@,".
  rf_template_outside_recipient_block=$(printf '%s' "$rf_template" | awk '
    /^=== Recipient handle \(optional\) ===$/ { skip=1; next }
    skip && /^=== / { skip=0 }
    skip { next }
    { print }
  ')
  if printf '%s' "$rf_template_outside_recipient_block" | grep -qF '{{recipient}}'; then
    echo "  FAIL  $base.md prompt template carries {{recipient}} outside the Recipient block (#520)"; fail=$((fail+1))
  else
    echo "  PASS  $base.md prompt template carries {{recipient}} only inside the Recipient block (#520)"; pass=$((pass+1))
  fi
  # STATED-NOT-ASKED has a check behind it (#513): the value names the var
  # holding the asks, so the check can tell the caller's ask from a fact.
  if [[ "$base" == maintainer-reply ]]; then
    if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+no_fact_as_question:[[:space:]]*ask[[:space:]]*$'; then
      echo "  PASS  $base.md declares no_fact_as_question: ask (#513)"; pass=$((pass+1))
    else
      echo "  FAIL  $base.md does not declare no_fact_as_question: ask (#513)"; fail=$((fail+1))
    fi
  fi
done

# #589: pr-description strips a leading title line and commit-message rejects
# a subject copied from an exemplar; both are declared checks.
for pair in pr-description:no_title_line commit-message:no_subject_echo; do
  base="${pair%%:*}"; chk="${pair#*:}"
  rf_fm=$(awk '/^---[[:space:]]*$/{d++; if (d==2) exit; next} d==1' "$PROMPTS_DIR/$base.md" 2>/dev/null)
  if printf '%s\n' "$rf_fm" | grep -qE "^[[:space:]]+$chk:[[:space:]]*true[[:space:]]*$"; then
    echo "  PASS  $base.md declares $chk (#589)"; pass=$((pass+1))
  else
    echo "  FAIL  $base.md does not declare $chk: true (#589)"; fail=$((fail+1))
  fi
done
echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
