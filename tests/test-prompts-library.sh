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

# Print every fenced code block under the given '## ' heading. Fence state is
# tracked so a '## ' heading appearing *inside* an example does not end the
# section early — github-issue-body.md passes literal '## Summary' lines as a
# --var value, and without the gating everything past them goes unchecked.
# This mirrors the fence-aware extraction scripts/delegate.sh performs when it
# loads a recipe template, so the tests shadow the production reader.
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
  # Catch the legacy `<paste X here>` style — every such marker should now be
  # a {{name}} placeholder so --recipe can substitute it programmatically.
  if printf '%s' "$template" | grep -qE '<paste .* here>'; then
    echo "  FAIL  $base: legacy '<paste ... here>' marker found in template (use {{name}})"; fail=$((fail+1))
  else
    echo "  PASS  $base: no legacy '<paste ... here>' markers"; pass=$((pass+1))
  fi
  # The '## Invocation' example must be free of shell command substitution
  # (issue #350). Sandboxed agent harnesses — including a Claude Code session
  # working inside a git worktree — refuse `$(...)`, and because the refusal
  # arrives on the agent's first --recipe call it reads as "delegate-local is
  # broken" rather than "this shell won't run that shape". Literal --var values
  # work everywhere and the caller already holds them from its own earlier
  # git/gh step, so the literal form is the documented one; the gathering
  # commands live under '## Context to gather first' instead.
  # Only the fenced example is scanned: it is the copy-paste surface, and
  # restricting to it keeps inline `code` in the surrounding prose out of scope.
  invocation_example=$(extract_fenced "$recipe" "## Invocation")
  if [[ -z "$invocation_example" ]]; then
    echo "  FAIL  $base: '## Invocation' has no fenced example to check"; fail=$((fail+1))
  elif [[ "$invocation_example" == *'$('* || "$invocation_example" == *'`'* ]]; then
    echo "  FAIL  $base: '## Invocation' uses command substitution (pass literal --var values; quote inline code with '\"' not backticks)"; fail=$((fail+1))
  else
    echo "  PASS  $base: '## Invocation' free of command substitution"; pass=$((pass+1))
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

# plan-section-intro.md — heading-line and FACTS-echo Wrong/Correct anchoring.
# Pinned after the two confirming 2026-05-22 dogfood MISS observations
# (ts=2026-05-22T11:12:12Z + verdict ts=2026-05-22T11:12:47Z; and
# ts=2026-05-22T11:43:18Z + verdict ts=2026-05-22T11:43:47Z) prompted the
# sharpening. Without these pins a future refactor could silently drop a
# guard whose absence cost two dogfood iterations to add. Same discipline
# the OMIT-EMPTY-SECTION + COMMENT-N-CITATION pins above apply to
# summarise-issue.md.
plan_section_intro_body=$(cat "$PROMPTS_DIR/plan-section-intro.md")
assert_contains "NO-HEADING-LINE" "$plan_section_intro_body" \
  "plan-section-intro.md names NO-HEADING-LINE rule"
assert_contains "FACTS-BLOCK-REPHRASE" "$plan_section_intro_body" \
  "plan-section-intro.md names FACTS-BLOCK-REPHRASE rule"
# Both rules must appear in the Anti-hallucination guards section so the
# calibration provenance for each guard is anchored in the document.
plan_guards_section=$(awk '
  /^## Anti-hallucination guards/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/plan-section-intro.md")
assert_contains "NO-HEADING-LINE" "$plan_guards_section" \
  "plan-section-intro.md '## Anti-hallucination guards' names NO-HEADING-LINE"
assert_contains "FACTS-BLOCK-REPHRASE" "$plan_guards_section" \
  "plan-section-intro.md '## Anti-hallucination guards' names FACTS-BLOCK-REPHRASE"
# The Wrong/Correct anchor for NO-HEADING-LINE must be grounded in the
# actual observed dogfood failure (the `### Phase 13 — Cross-machine
# calibration aggregation` heading from the 2026-05-22T11:12:12Z dogfood)
# rather than an abstract Wrong shape. Pinning the literal heading string
# guards against a future refactor that paraphrases the anchor away from
# the failure shape it was grounded in.
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
# The FACTS-BLOCK-REPHRASE Wrong/Correct anchor must reference the actual
# observed verbatim-echo from the 2026-05-22T11:43:18Z second dogfood
# (the SCOPE last sentence "The aggregator is opt-in, single-user..."),
# proxy for "the Wrong shape stays grounded in real failure rather than
# drifting to an abstract paraphrase".
assert_contains "The aggregator is opt-in, single-user" "$plan_template_section" \
  "plan-section-intro.md prompt template anchors FACTS-echo Wrong shape to observed dogfood failure"

# maintainer-reply.md — MULTI-ASK-SPLIT and NO-FACT-DROP. Pinned after the
# 2026-08-03 metrics sweep measured 0 keeps out of 13 on multi-ask
# teams-for-linux replies (against 92% on single-ask work, same model, same
# backend, unedited template). The two-sentence cap was merging distinct asks
# into one run-on question and, in one row, discarding a supplied fact
# outright. Both directives must stay inside the prompt template — the old
# scope note asked callers to split multi-ask replies themselves and was
# ignored 13 consecutive times, so an advisory line is demonstrably not enough.
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

# pr-description.md — EVIDENCE precedence, SHAPE deference, test-plan sourcing.
# Pinned after the 2026-08-03 sweep put the recipe at 0 keeps out of 10 in the
# window, and re-pinned 2026-08-21 after a reproducible fabrication: anchored on
# a merged PR whose template quotes a pytest run, and given a Context silent
# about testing, the recipe emitted a ticked box and an invented "24 passed in
# 1.12s" log. The old guard could not stop it — SHAPE was "non-negotiable" and
# came first, while the evidence rule scoped itself out with "applies only when
# the examples use a test plan", and that example had a Verification section,
# not a test plan. EVIDENCE now outranks SHAPE explicitly, and the ban is on
# boxes that ASSERT a verification, not on every `- [x]`: a box that classifies
# the change ("- [x] Bug fix") states intent and is legitimate in templates that
# use one. Assert the precedence, or a future edit silently restores the
# fabrication.
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
pr_description_guards=$(awk '
  /^## Anti-hallucination guards/ { in_section=1; next }
  /^## / && in_section { in_section=0 }
  in_section { print }
' "$PROMPTS_DIR/pr-description.md")
assert_contains "SHAPE — the examples govern" "$pr_description_guards" \
  "pr-description.md '## Anti-hallucination guards' names SHAPE directive"
assert_contains "EVIDENCE — outranks SHAPE" "$pr_description_guards" \
  "pr-description.md '## Anti-hallucination guards' names the EVIDENCE precedence guard"

# Every dispatchable recipe declares a frontmatter `tier:` (#411). 39 of the 44
# recorded bad-tier calls supplied a --recipe, so the tier left the documented
# invocation entirely; a recipe without one puts the guess back and fails at
# call time instead. Scoped to files that delegate.sh can actually dispatch:
# README.md has no frontmatter, and semantic-search.md says in its own body that
# "there is no `delegate.sh --recipe` call because the wrapper assumes text-in /
# text-out" — it is a shell-pipeline recipe, not a model prompt.
# Read the vocabulary from pick-model.sh's own TIERS line rather than restating
# it, so this test cannot drift from the source of truth the wrapper uses.
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

# The tier left the documented invocation, so no recipe may still show one.
# The section-end check is gated on being OUTSIDE the fence: a --var value may
# legitimately contain markdown headings (github-issue-body.md passes a
# `--var sections` listing '## Summary' and friends), and exiting on those
# reintroduced the same silent truncation one level down.
# Scan the whole fenced block under '## Invocation', not backslash-continued
# lines: the earlier `exit`-on-first-line-without-a-trailing-backslash stopped
# at the first multi-line --var value, so pr-description.md — whose recent_prs
# example spans lines — was scanned two lines deep and passed while still
# documenting a positional `prose` tier. A silent skip in an invariant is worse
# than no invariant, because the PASS line asserts coverage that did not happen.
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
  # Pin both truncation bugs. pr-description.md's first --var spans lines, so a
  # scanner that stops at the first line without a trailing backslash never
  # reaches the trailing prompt. github-issue-body.md's --var sections contains
  # '## ' headings, so a scanner that treats any '## ' as the section end stops
  # just as early. Both shipped as green PASS lines. If either assertion fails,
  # the scan narrowed again and every FAIL below became unreachable.
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

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
