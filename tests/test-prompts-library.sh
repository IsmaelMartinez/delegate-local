#!/usr/bin/env bash
# Structural checks on every prompts/<task>.md recipe: required sections,
# documented placeholders, README listing, and per-recipe directive pins.

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

# 6. Recipe-specific pins: directives that calibration showed must stay
# inside the prompt template, not in an advisory note.

# commit-message.md: SUBJECT_LEN and TYPE selection are first-match-wins
# directives in the template body.
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
# Both rules appear in the Anti-hallucination guards section.
guards_section=$(awk '
  /^## Anti-hallucination guards/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/summarise-issue.md")
assert_contains "OMIT-EMPTY-SECTION" "$guards_section" \
  "summarise-issue.md '## Anti-hallucination guards' names OMIT-EMPTY-SECTION"
assert_contains "COMMENT-N-CITATION" "$guards_section" \
  "summarise-issue.md '## Anti-hallucination guards' names COMMENT-N-CITATION"
# The OMIT-EMPTY-SECTION anchors cover both `## What's blocking` and `## What's next`.
prompt_template_section=$(awk '
  /^## Prompt template[[:space:]]*$/ { in_section=1; next }
  in_section && /^```/ { in_block = !in_block; print; next }
  in_section && !in_block && /^## / { exit }
  in_section { print }
' "$PROMPTS_DIR/summarise-issue.md")
assert_contains "## What's next" "$prompt_template_section" \
  "summarise-issue.md prompt template references What's next section"
assert_contains "no next-action stated" "$prompt_template_section" \
  "summarise-issue.md prompt template anchors no-next-action Wrong shape"

# plan-section-intro.md: NO-HEADING-LINE and FACTS-BLOCK-REPHRASE.
plan_section_intro_body=$(cat "$PROMPTS_DIR/plan-section-intro.md")
assert_contains "NO-HEADING-LINE" "$plan_section_intro_body" \
  "plan-section-intro.md names NO-HEADING-LINE rule"
assert_contains "FACTS-BLOCK-REPHRASE" "$plan_section_intro_body" \
  "plan-section-intro.md names FACTS-BLOCK-REPHRASE rule"
plan_guards_section=$(awk '
  /^## Anti-hallucination guards/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/plan-section-intro.md")
assert_contains "NO-HEADING-LINE" "$plan_guards_section" \
  "plan-section-intro.md '## Anti-hallucination guards' names NO-HEADING-LINE"
assert_contains "FACTS-BLOCK-REPHRASE" "$plan_guards_section" \
  "plan-section-intro.md '## Anti-hallucination guards' names FACTS-BLOCK-REPHRASE"
# The Wrong anchors stay grounded in the observed failures, not paraphrased.
plan_template_section=$(awk '
  /^## Prompt template[[:space:]]*$/ { in_section=1; next }
  in_section && /^```/ { in_block = !in_block; print; next }
  in_section && !in_block && /^## / { exit }
  in_section { print }
' "$PROMPTS_DIR/plan-section-intro.md")
assert_contains "NO-HEADING-LINE" "$plan_template_section" \
  "plan-section-intro.md prompt template carries NO-HEADING-LINE directive"
assert_contains "FACTS-BLOCK-REPHRASE" "$plan_template_section" \
  "plan-section-intro.md prompt template carries FACTS-BLOCK-REPHRASE directive"
assert_contains "Phase 13 — Cross-machine calibration aggregation" "$plan_template_section" \
  "plan-section-intro.md prompt template anchors heading-line Wrong shape to observed dogfood failure"
assert_contains "The aggregator is opt-in, single-user" "$plan_template_section" \
  "plan-section-intro.md prompt template anchors FACTS-echo Wrong shape to observed dogfood failure"

# maintainer-reply.md: MULTI-ASK-SPLIT and NO-FACT-DROP must be inside the
# template; an advisory scope note was ignored.
maintainer_reply_template=$(awk '
  /^## Prompt template[[:space:]]*$/ { in_section=1; next }
  in_section && /^```/ { in_block = !in_block; print; next }
  in_section && !in_block && /^## / { exit }
  in_section { print }
' "$PROMPTS_DIR/maintainer-reply.md")
assert_contains "MULTI-ASK-SPLIT — first match wins, non-negotiable" "$maintainer_reply_template" \
  "maintainer-reply.md prompt template names MULTI-ASK-SPLIT first-match-wins directive"
assert_contains "NO-FACT-DROP" "$maintainer_reply_template" \
  "maintainer-reply.md prompt template carries NO-FACT-DROP directive"
maintainer_reply_guards=$(awk '
  /^## Anti-hallucination guards/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/maintainer-reply.md")
assert_contains "MULTI-ASK-SPLIT" "$maintainer_reply_guards" \
  "maintainer-reply.md '## Anti-hallucination guards' names MULTI-ASK-SPLIT"
assert_contains "NO-FACT-DROP" "$maintainer_reply_guards" \
  "maintainer-reply.md '## Anti-hallucination guards' names NO-FACT-DROP"
# STATED-NOT-ASKED and NO-CLAIMED-ACTION (#487) resolve the tension between
# "exactly one ask" and "do not restate the facts".
assert_contains "STATED-NOT-ASKED — non-negotiable" "$maintainer_reply_template" \
  "maintainer-reply.md prompt template carries STATED-NOT-ASKED directive"
assert_contains "NO-CLAIMED-ACTION — non-negotiable" "$maintainer_reply_template" \
  "maintainer-reply.md prompt template carries NO-CLAIMED-ACTION directive"
# STATED-NOT-ASKED must not contradict MULTI-ASK-SPLIT rule 2: a numbered
# list of the caller's asks is correct, and verbatim slots are exempt.
assert_contains "a numbered list of the caller's asks, one question each, is correct" "$maintainer_reply_template" \
  "maintainer-reply.md STATED-NOT-ASKED keeps a numbered list of the caller's asks correct"
assert_contains "Outside the supplied opener, lead, sign-off and anchors" "$maintainer_reply_template" \
  "maintainer-reply.md STATED-NOT-ASKED exempts the verbatim slots, the lead among them, from the question-mark rule"
if printf '%s' "$maintainer_reply_template" | grep -qi 'questionnaire'; then
  echo "  FAIL  maintainer-reply.md prompt template still calls a list of asks a questionnaire defect"; fail=$((fail+1))
else
  echo "  PASS  maintainer-reply.md prompt template no longer calls a list of asks a defect"; pass=$((pass+1))
fi
assert_contains "STATED-NOT-ASKED" "$maintainer_reply_guards" \
  "maintainer-reply.md '## Anti-hallucination guards' names STATED-NOT-ASKED"
assert_contains "NO-CLAIMED-ACTION" "$maintainer_reply_guards" \
  "maintainer-reply.md '## Anti-hallucination guards' names NO-CLAIMED-ACTION"
# #517: the judgment sentence is the caller's. `lead` is a required input
# (no trailing `?`, so delegate.sh exits 2 without it and the boundary hook's
# nudge names it), and the template places {{lead}} exactly once, after the
# opener and before the facts, so the reply carries it verbatim in that
# position. The template no longer asks the model to derive the judgment.
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
assert_contains "ASK-OR-NONE — first match wins, non-negotiable" "$maintainer_reply_template" \
  "maintainer-reply.md prompt template decides the question with ASK-OR-NONE (#517)"
if printf '%s' "$maintainer_reply_template" | grep -qE 'either specific praise for what the contributor did, or a plain statement of the confirmed cause'; then
  echo "  FAIL  maintainer-reply.md prompt template still asks the model to derive the praise-or-cause sentence (#517)"; fail=$((fail+1))
else
  echo "  PASS  maintainer-reply.md prompt template no longer asks the model to derive the judgment (#517)"; pass=$((pass+1))
fi
# The template reads an ask block that says there is nothing to ask as no
# question (ASK-OR-NONE rule 1), so the variable contract must not go on
# telling callers the model renders such a value as a question (#471 wording).
maintainer_reply_variables=$(awk '
  /^## Variables/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/maintainer-reply.md")
assert_contains "says there is nothing to ask: NO question" "$maintainer_reply_template" \
  "maintainer-reply.md ASK-OR-NONE reads a nothing-to-ask block as no question (#517)"
if printf '%s' "$maintainer_reply_variables" | grep -qF 'the model reads any text here as a topic and renders it as a question'; then
  echo "  FAIL  maintainer-reply.md Variables still says a nothing-to-ask value is rendered as a question, contradicting ASK-OR-NONE (#517)"; fail=$((fail+1))
else
  echo "  PASS  maintainer-reply.md Variables agrees with ASK-OR-NONE on a nothing-to-ask value (#517)"; pass=$((pass+1))
fi
# The other half of that contract stays explicit: a real topic is a question.
assert_contains "a real topic is still rendered as a question" "$maintainer_reply_variables" \
  "maintainer-reply.md Variables keeps a real ask topic rendered as a question (#517)"

# pr-description.md: EVIDENCE outranks SHAPE explicitly, and the ban is on
# boxes that assert a verification, not on every `- [x]`.
pr_description_template=$(awk '
  /^## Prompt template[[:space:]]*$/ { in_section=1; next }
  in_section && /^```/ { in_block = !in_block; print; next }
  in_section && !in_block && /^## / { exit }
  in_section { print }
' "$PROMPTS_DIR/pr-description.md")
assert_contains "SHAPE — the examples govern structure, non-negotiable" "$pr_description_template" \
  "pr-description.md prompt template names SHAPE-defers-to-examples directive"
assert_contains "EVIDENCE — outranks SHAPE, non-negotiable" "$pr_description_template" \
  "pr-description.md prompt template names the EVIDENCE-outranks-SHAPE precedence"
assert_contains "TEST-PLAN SOURCING — applies only when the examples use a test plan" "$pr_description_template" \
  "pr-description.md prompt template names the test-plan sourcing directive"
assert_contains "NEVER tick a box that asserts a verification" "$pr_description_template" \
  "pr-description.md prompt template bans the verification-asserting checked box"
assert_contains "NEVER write a command's output, a pass/fail count, or a timing" "$pr_description_template" \
  "pr-description.md prompt template bans fabricated command output"
assert_contains "PARAGRAPHS — the examples set the paragraph count, the Context does not" "$pr_description_template" \
  "pr-description.md prompt template names the PARAGRAPHS directive"
assert_contains "one for each distinct change the stats and the Context describe" "$pr_description_template" \
  "pr-description.md prompt template splits paragraphs per change, not by the Context's shape"
# The gather block fetches more than one example and strips the generated-by
# footer: no_example_echo treats a line as convention only when more than one
# exemplar carries it.
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

pr_description_guards=$(awk '
  /^## Anti-hallucination guards/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/pr-description.md")
assert_contains "SHAPE — the examples govern" "$pr_description_guards" \
  "pr-description.md '## Anti-hallucination guards' names SHAPE directive"
assert_contains "EVIDENCE — outranks SHAPE" "$pr_description_guards" \
  "pr-description.md '## Anti-hallucination guards' names the EVIDENCE precedence guard"

# Every dispatchable recipe declares a frontmatter `tier:` (#411); README.md
# and the shell-pipeline semantic-search.md are not dispatchable. The
# vocabulary is read from pick-model.sh's TIERS line so this cannot drift.
VALID_TIERS=$(sed -n 's/^TIERS="\(.*\)"$/\1/p' "$REPO/scripts/pick-model.sh" | tr '|' ' ')
if [[ -z "$VALID_TIERS" ]]; then
  echo "  FAIL  could not read TIERS from scripts/pick-model.sh"; fail=$((fail+1))
fi
for recipe_file in "$PROMPTS_DIR"/*.md; do
  base=$(basename "$recipe_file" .md)
  [[ "$base" == "README" ]] && continue
  [[ "$base" == "semantic-search" ]] && continue
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

# pr-review-reply must not cap its body at one clause again; no_padding_tail
# took over the anti-padding half.
prr="$PROMPTS_DIR/pr-review-reply.md"
prr_template=$(awk '/^## Prompt template/{f=1} f' "$prr" 2>/dev/null | awk '/^```/{n++; next} n==1')
if [[ -z "$prr_template" ]]; then
  # An empty template would pass the grep below, so it is a failure of its own.
  echo "  FAIL  pr-review-reply.md prompt template could not be extracted"; fail=$((fail+1))
elif printf '%s' "$prr_template" | grep -qiE 'at most one short clause|no additional sentences|one-sentence reply'; then
  echo "  FAIL  pr-review-reply.md prompt template still caps the body at one clause"; fail=$((fail+1))
else
  echo "  PASS  pr-review-reply.md prompt template does not cap the body at one clause"; pass=$((pass+1))
fi
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
  if printf '%s' "$rf_template" | grep -qiE 'do not open by thanking|do not thank the contributor'; then
    echo "  FAIL  $base.md prompt template still forbids the opener the caller supplies"; fail=$((fail+1))
  else
    echo "  PASS  $base.md prompt template no longer forbids an opener"; pass=$((pass+1))
  fi
  if printf '%s' "$rf_template" | grep -q 'SHORTER than the FACTS block'; then
    echo "  FAIL  $base.md prompt template still carries the unconditional SHORTER rule"; fail=$((fail+1))
  else
    echo "  PASS  $base.md prompt template carries no unconditional SHORTER rule"; pass=$((pass+1))
  fi
  # The evidence-led recipe narrowed on 2026-09-20: the facts are the
  # maintainer's notes and the reply never describes the change back to its
  # author; the every-anchor rule that produced that description is gone and
  # the length is a numeric cap the caller can set.
  if [[ "$base" == maintainer-review-reply ]]; then
    assert_contains "VERIFIED-NOT-DESCRIBED" "$rf_template" \
      "$base.md prompt template carries the VERIFIED-NOT-DESCRIBED guard"
    if printf '%s' "$rf_template" | grep -q 'EVERY anchor in the FACTS block must appear'; then
      echo "  FAIL  $base.md prompt template still demands every anchor in the facts"; fail=$((fail+1))
    else
      echo "  PASS  $base.md prompt template no longer demands every anchor in the facts"; pass=$((pass+1))
    fi
    assert_contains "or 80 words when that block is empty" "$rf_template" \
      "$base.md LENGTH states the numeric cap and its default"
    assert_contains "{{max_words}}" "$rf_template" \
      "$base.md prompt template carries the {{max_words}} slot"
    if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+max_words:[[:space:]]*integer\?'; then
      echo "  PASS  $base.md declares max_words as an optional integer input"; pass=$((pass+1))
    else
      echo "  FAIL  $base.md does not declare max_words: integer?"; fail=$((fail+1))
    fi
  fi
  # A clean approval has no ask (#471): `ask` is optional in both reply
  # recipes, the template stops after the evidence (or the cause sentence)
  # when it is empty, and neither asks the contributor to confirm a merge.
  if printf '%s\n' "$rf_fm" | grep -qE '^[[:space:]]+ask:[[:space:]]*string\?'; then
    echo "  PASS  $base.md declares ask as an optional input (#471)"; pass=$((pass+1))
  else
    echo "  FAIL  $base.md does not declare ask: string? (#471)"; fail=$((fail+1))
  fi
  # The item number differs: the lead (#517) makes the ask item 4 in
  # maintainer-reply, and ASK-OR-NONE is what names the empty block there.
  if [[ "$base" == maintainer-reply ]]; then
    assert_contains "When ASK-OR-NONE says there is none, there is no item 4" "$rf_template" \
      "$base.md prompt template has a no-ask branch (#471)"
  else
    assert_contains "If the ask block below is empty, there is no item 3" "$rf_template" \
      "$base.md prompt template has a no-ask branch (#471)"
  fi
  assert_contains "Never ask the contributor to confirm, approve or authorise a merge" "$rf_template" \
    "$base.md prompt template forbids asking the contributor to confirm a merge (#471)"
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
echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
