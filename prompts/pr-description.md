# pr-description

## When to use

The user has a branch with one or more commits and wants a GitHub PR description ready to paste into `gh pr create --body "..."`. Standard project shape: `## Summary` bullet list at the top, optional narrative subsections in flowing prose, `## Test plan` checkbox list at the end.

## Context to gather first

```bash
gh pr list --repo <owner>/<repo> --state merged --limit 1 \
  --json title,body,number \
  --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body)\n<<<EXAMPLE_END>>>\n"'
git diff <base-branch> --stat                    # what changed
git log <base-branch>..HEAD --pretty=oneline    # commit-by-commit shape
```

The recent merged-PR body is the load-bearing context. The model learns the project's bullet-vs-prose shape, the standard subsection headings, and the test-plan-checkbox convention from the literal, not from descriptors.

**`--limit 1` is the default for a reason** — see the calibration note below on the 2026-05-10 timeout: two full PR bodies (~5 KB combined) is enough to push the prose-tier model past the wall-clock budget on a 35B host. If a single example doesn't give the model enough shape (rare; most repos have a stable PR shape), bump to `--limit 2` and route to the `long-context` tier rather than `prose`.

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
  --var recent_prs="$(gh pr list --repo OWNER/REPO --state merged --limit 1 \
    --json title,body,number \
    --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body)\n<<<EXAMPLE_END>>>\n"')" \
  --var diff_stat="$(git diff main --stat)" \
  --var context="<3-5 sentences>" \
  prose "Match the example PR description exactly in shape and tone. NO invented example output."
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

### 2026-05-10 — single-example default after timeout

Attempted on the reference host (`qwen3.6:35b-a3b-q8_0`, prose tier) with `gh pr list --limit 2` producing two full merged-PR bodies (~5 KB combined plus the diff-stat and context vars). The delegation hung past 16 minutes and was killed per SKILL.md's "kill if hung >30 s" rule. The recipe now defaults to `--limit 1`, and the "Context to gather first" section documents the `long-context` tier as the escape hatch when one example doesn't anchor the shape strongly enough. The earlier 2026-05-09 HIT used `--limit 2` and worked; the difference is that this PR's combined inputs were ~2× larger (the `context` paragraph alone was ~1.5 KB). The recipe's load-bearing claim is "one well-delimited example anchors shape" — the 2× input budget for a second example is rarely worth it on the 35B host.

### 2026-05-10 — second timeout reveals output cost is the dominating factor

The `--limit 1` fix above was itself dogfooded against this recipe's own PR (`feat/recipe-library-expansion`). Inputs: `recent_prs` 2078 B (single example), `diff_stat` 360 B, `context` 748 B — total ~3.2 KB plus the ~2 KB recipe template, so ~5.2 KB input. **It still timed out past 5 minutes.** This was a comparable-size input to the earlier commit-message HIT (~4.5 KB total) that completed in ~30 s, so input size alone is not the discriminating factor. The differentiating variable is *output size*: commit-message produces ~500 B of structured output, while pr-description targets ~2–3 KB (Summary + narrative subsections + Test plan). On the 35B MoE prose-tier model, generating 2–3 KB of structured markdown appears to push the wall-clock past the practical budget regardless of input size.

Concrete recommendation pending future work: route `pr-description` to the `long-context` tier (Qwen3-Next 80B-A3B on this host is faster per-token despite being larger because it's an A3B MoE) rather than `prose`. The recipe's `## Invocation` section still calls `prose` because that's the tier the existing tests cover and the safer default to ship; a `## Calibration notes` update with an actual `long-context` HIT measurement would graduate that change into the recipe body. Until then, callers seeing a hang should kill the delegation and route to `long-context` manually, or write the PR description by hand (which is what this PR did).

Provenance also lives in the `feedback_delegate_prose_prompt_anchoring.md` memory file.
