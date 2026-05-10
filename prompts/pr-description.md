# pr-description

## When to use

The user has a branch with one or more commits and wants a GitHub PR description ready to paste into `gh pr create --body "..."`. Standard project shape: `## Summary` bullet list at the top, optional narrative subsections in flowing prose, `## Test plan` checkbox list at the end.

## Context to gather first

```bash
gh pr list --repo <owner>/<repo> --state merged --limit 2 \
  --json title,body,number \
  --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body)\n<<<EXAMPLE_END>>>\n"'
git diff <base-branch> --stat                    # what changed
git log <base-branch>..HEAD --pretty=oneline    # commit-by-commit shape
```

The two recent merged-PR bodies are the load-bearing context. The model learns the project's bullet-vs-prose shape, the standard subsection headings, and the test-plan-checkbox convention from these literals, not from descriptors.

The `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelope around each example is intentional — without explicit delimiters the model bleeds content from one example into the next or treats the whole block as one example with confused shape.

## Prompt template

```
Draft a GitHub PR description matching the SHAPE of the recent merged-PR examples below.
Required sections in this order: '## Summary' (3-bullet list of what the PR does), then ANY narrative sections you want (use ### subheaders, flowing prose paragraphs), then '## Test plan' as a checkbox list at the end.
Do NOT invent example output for any tool — only describe what's in the diff.
Do NOT prefix the title with 'PR #NN —' or any PR number reference.
Output ONLY the markdown body, nothing else.

=== Recent merged-PR examples (shape anchors) ===
{{recent_prs}}

=== This PR's stats ===
{{diff_stat}}

=== Context ===
{{context}}
```

## Variables

- `{{recent_prs}}` — output of the `gh pr list ... --jq '...'` command in "Context to gather first", with the `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelopes intact.
- `{{diff_stat}}` — output of `git diff <base-branch> --stat`.
- `{{context}}` — 3–5 sentences naming branch, what was added/changed at the script-or-feature level, motivation, edge cases the reader should know about, any cross-PR relationships ("ships alongside #NN"). Authored by the agent — describe, do not include code.

## Invocation

```bash
bash scripts/delegate.sh --recipe pr-description \
  --var recent_prs="$(gh pr list --repo OWNER/REPO --state merged --limit 2 \
    --json title,body,number \
    --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body)\n<<<EXAMPLE_END>>>\n"')" \
  --var diff_stat="$(git diff main --stat)" \
  --var context="<3-5 sentences>" \
  prose "Match the example PR descriptions exactly in shape and tone. NO invented example output."
```

## Anti-hallucination guards (each line addresses a real past MISS)

- "Required sections in this order" — without explicit ordering the model puts the test plan first or skips the summary.
- "3-bullet list" — caps summary length; without it, summary expands into 8 bullets that duplicate the narrative section.
- "Do NOT invent example output for any tool" — observed: the model fabricated metrics-summary output blocks (`hit: 12 miss: 3` — wrong shape, wrong numbers, wrong format) when asked for "implementation details". Bullets and prose are fine to invent in narrative; concrete tool output is not.
- "Do NOT prefix the title with 'PR #NN —'" — observed: the model copies the `<<<EXAMPLE_BEGIN PR #N>>>` delimiter into the actual title.
- "Output ONLY the markdown body" — without this the model adds "Here's the PR description:" preamble.

## Expected output shape

```
## Summary

- <one-line bullet, what the PR does>
- <one-line bullet, what the PR does>
- <one-line bullet, what the PR does>

### <optional narrative subsection — motivation, design choices, tradeoffs>

<flowing prose paragraphs>

### <optional second subsection>

<more prose>

## Test plan

- [ ] <concrete verifiable check>
- [ ] <concrete verifiable check>
```

Verify before recording verdict: no `PR #NN` prefix in any heading, no fabricated tool output (any code block claiming to show CLI / metrics output should be cross-checked against the actual format), test-plan items are concrete and verifiable rather than aspirational.

## Calibration notes

Distilled from session 2026-05-09 across two attempts:

- **MISS** (ts=2026-05-09T20:18:59Z) — prompt asked for the standard shape and motivation but did not forbid invented output; model fabricated a metrics-summary example block with hallucinated `hit: 12 miss: 3` numbers in the wrong format. Structure was right; one section had to be rewritten by hand.
- **HIT verbatim** (ts=2026-05-09T20:23:58Z) — same recent-examples anchor plus explicit "NO invented example output" guard added in response to the previous MISS. Output used with zero edits.

The "no invented tool output" guard is the recipe's most important addition over the bare anchoring pattern. Recent-examples anchoring alone produces well-shaped HALLUCINATIONS for any concrete-output section; the explicit ban moves narrative into prose where the model has license to summarise but blocks fabricated CLI snippets.

Provenance also lives in the `feedback_delegate_prose_prompt_anchoring.md` memory file.
