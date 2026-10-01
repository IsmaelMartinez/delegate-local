---
tier: prose
inputs:
  recent_prs: string
  diff_stat: string
  context: string
echo_guard_vars: recent_prs
input_quality:
  recent_prs: titles_only
checks:
  no_title_line: true
  no_invented_task_list: recent_prs
  no_invented_headings: recent_prs
  no_invented_refs: true
---
# pr-description

> **Status (2026-06-28): live — the `flaky_on_models` gate was RETIRED after its premise was falsified.** The 2026-05-24 gate refused this recipe on 35B/80B prose hosts believing those models *generation*-stall on recipe-shaped prompts. A 2026-06-28 probe (see the calibration note at the end) showed the opposite: the MLX 35B emits a grade-A PR description in ~6 s once warm — the only slow part is a one-time ~77 s cold-LOAD, which is the pre-flight canary's job (exit 3), not the structural gate's (exit 4). The same 35B serves `commit-message` 294× with no gate. On a 35B MLX host set `DELEGATE_PREFLIGHT_TIMEOUT=90` for the first (cold) call; warm calls need nothing. The recipe also passes where the prose tier resolves to a smaller model (gemma4:31b-it, qwen3.5:27b, qwen3-coder:30b all graded A). See ADR 0027, which supersedes the ADR 0012/0013 premise for this recipe. The historical 45%-HIT signal predates the fix and is on probation — re-measure via `delegate-feedback.sh` before trusting at volume.

## When to use

The user has a branch with one or more commits and wants a GitHub PR description ready to paste into `gh pr create --body "..."`. There is no standard shape: the merged-PR examples you pass in are the shape authority, and they range from a two-sentence body to a full `## Description` / `## Type of change` / `## Verification` template. Pass real examples from the target repo; the recipe has no sensible default without them.

## Context to gather first

```bash
# TWO examples, with the generated-by footer AND any Refs/trailer line stripped
# out of each. Both halves matter: see the 2026-08-27 calibration note.
gh pr list --repo <owner>/<repo> --state merged --limit 2 \
  --json title,body,number \
  --jq '.[] | "<<<EXAMPLE_BEGIN PR #\(.number)>>>\nTITLE: \(.title)\nBODY:\n\(.body | split("\n") | map(select(test("^[[:space:]]*🤖 Generated with|^https://claude\\.ai/code/|^[[:space:]]*(Refs|Co-Authored-By|Claude-Session):"; "i") | not)) | join("\n"))\n<<<EXAMPLE_END>>>\n"'
git diff <base-branch> --stat                    # what changed
git log <base-branch>..HEAD --pretty=oneline    # commit-by-commit shape
```

Two of them, not one, and with the generated-by footer removed. `no_example_echo` classifies a line as shared convention when it appears in more than one exemplar, so a single exemplar leaves the check with nothing to compare and its boilerplate reads as that exemplar's own content; and a footer that only some merged PRs carry defeats the rule even at two, which is why it is stripped rather than left to repetition. A `Refs:` line is stripped for a different reason: on 2026-09-15 two drafts carried the example's `Refs: #487` verbatim while describing other issues, and a reference copied from the exemplar is wrong every time (#501). The filter is anchored to the start of the line, so it removes the footer itself and never a paragraph that merely mentions it. The recent merged-PR body is the load-bearing context. The model learns the project's bullet-vs-prose shape, the standard subsection headings, and the test-plan-checkbox convention from the literal, not from descriptors.

**Superseded 2026-06-28: the blocker is cold-LOAD latency, not generation (see the 2026-06-28 calibration note).** The earlier 2026-05-10/11/13 measurements timed wall-clock from a cold (or memory-evicted) state on the 35B/80B prose and long-context tiers and attributed the disk-load latency to generation — concluding, wrongly, that the failure axis was model parameter count at recipe-sized prompts. The 2026-06-28 probe showed the MLX 35B generates a grade-A PR body in ~6 s once warm; the only slow part is the ~77 s cold-load. The active mitigation is therefore NOT hand-writing: on a host where the prose tier resolves to a 35B-class MLX model, set `DELEGATE_PREFLIGHT_TIMEOUT=90` on the first (cold) call so the pre-flight canary tolerates the load window — warm calls return in seconds and need nothing. Keep the model resident (Ollama `keep_alive`, or `mlx_lm.server` holding the last model) to avoid paying cold-load repeatedly. The recipe also passes where the prose tier resolves to a smaller model.

The `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelope around each example is intentional — without explicit delimiters the model bleeds content from one example into the next or treats the whole block as one example with confused shape.

**Pick an example from unrelated work.** The delimiters stop one example bleeding into the next; they do not stop an example bleeding into the answer. Both 2026-08-26 echo events came from passing the immediately preceding PR on the *same* repo and the *same* topic — a self-improvement PR used as the anchor for the next self-improvement PR — and what came back was that PR's paragraphs, describing that PR's work. This is the same rule SKILL.md already states for one-shot examples generally: "the example must use a different finding/item from the actual input so it doesn't leak the answer." A merged PR from a different area of the repo teaches the shape just as well and has nothing plausible to copy.

## Prompt template

```
Draft a GitHub PR description matching the SHAPE of the recent merged-PR examples below.

EVIDENCE — outranks SHAPE, non-negotiable:
Copy the examples' STRUCTURE, never their FACTS. Headings, section order, bullet style and checkbox lists are structure: reproduce them exactly as the examples use them. The VALUES inside them are evidence and are yours to source, never to copy. An example that pastes a command and its output, quotes a pass count or a timing, or ticks a verification box is showing you its LAYOUT, not facts about this PR. You ran nothing. Every factual claim you write MUST come from the Context below.
1. NEVER write a command's output, a pass/fail count, or a timing. If the Context does not state it, it did not happen.
2. NEVER tick a box that asserts a verification ('- [x] Tests pass', '- [x] Verified'). Leave those as '- [ ]'.
3. A box that CLASSIFIES the change ('- [x] Bug fix', '- [x] Documentation') states intent, not a result — tick it when the diff supports it.
4. If the Context names no verification: where the examples carry a verification section, keep that heading and say plainly the checks have not been run; where they carry none (or there are no examples), add nothing. Never introduce a heading to hold a verification the examples did not ask for, and never fill one.
Wrong (the example pasted a pytest log; the Context said nothing about running tests): ## Verification\n```\n$ pytest -q\n24 passed in 1.12s\n```
Correct (same example, same silent Context): ## Verification\n- [ ] Run `pytest tests/unittest/test_token_handler.py` (not run yet)

SHAPE — the examples govern structure, non-negotiable (EVIDENCE above outranks this):
The recent merged-PR examples are the shape authority. Match their length, their section structure, and their register. If those examples are short — a sentence or two of plain prose with no headings — then produce a sentence or two of plain prose with no headings. Do NOT add '## Summary', '## Test plan', or any heading that the examples themselves do not use. Only when the examples DO carry sections should you use them, and then in this order: '## Summary' (3-bullet list of what the PR does), then ANY narrative sections you want (use ### subheaders, flowing prose paragraphs), then '## Test plan' as a checkbox list at the end.
Wrong (examples were two sentences of prose): ## Summary\n- Adds X\n- Refactors Y\n\n### Rationale\n...\n\n## Test plan\n- [ ] Run the suite
Correct (examples were two sentences of prose): Adds X so that Y no longer needs Z. The behaviour is unchanged for existing callers.

PARAGRAPHS — the examples set the paragraph count, the Context does not:
When the examples are prose without headings, match how many paragraphs they use, never how many the Context has. An example of several paragraphs, one for each thing it did (the cause, the change, the evidence), means several paragraphs here too: one for each distinct change the stats and the Context describe, a blank line between them, and never one block that runs every change together. The Context is usually one paragraph because it is a note to you; its paragraphing is not the shape to copy.
Wrong (examples were four paragraphs, one per change; Context was one paragraph): <every change, the reason and the evidence run together in one paragraph of the Context's length>
Correct (same examples): <one paragraph: the first change>\n\n<one paragraph: the second change>\n\n<one paragraph: the evidence, as the Context states it>

TEST-PLAN SOURCING — applies only when the examples use a test plan:
Every test-plan item MUST correspond to something stated in the Context. If the Context names no verifiable checks, omit the section rather than inventing items to fill it.
Wrong: - [x] Verified incremental sync still works (nothing in the Context says this was run)
Correct: - [ ] Run `bash tests/run-tests.sh` (the Context states the suite covers this)

Do NOT invent example output for any tool — only describe what's in the diff.
Do NOT prefix the title with 'PR #NN —' or any PR number reference.
Output ONLY the markdown body, nothing else.
Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

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

Run the `gh pr list` and `git diff` commands above as their own step, then pass what they printed as literal `--var` values. Keep the `<<<EXAMPLE_BEGIN ... EXAMPLE_END>>>` envelope the `--jq` filter produced — the delimiters are load-bearing:

```bash
bash scripts/delegate.sh --recipe pr-description \
  --var recent_prs="<<<EXAMPLE_BEGIN PR #340>>>
TITLE: <the merged PR's title>
BODY:
<the merged PR's body>
<<<EXAMPLE_END>>>" \
  --var diff_stat="<the git diff <base-branch> --stat output>" \
  --var context="<3-5 sentences>" \
  "Match the example PR description exactly in shape and tone. NO invented example output."
```

## Anti-hallucination guards (each line addresses a real past MISS)

- "EVIDENCE — outranks SHAPE" — added 2026-08-21 after a reproducible fabrication. Anchored on a real pr-agent merged PR (whose template carries `## Type of change` with a ticked box and a `## Verification` section quoting a pytest run), and given a Context that said nothing about testing, the recipe emitted `- [x] Bug fix` *and* a fabricated log: "$ python3 -m pytest ... 24 passed in 1.12s". Deterministic, 3/3 reps. The old wording could not stop it: SHAPE was declared "non-negotiable" and came first, while the evidence rule scoped itself out with "applies only when the examples use a test plan at all" — this example had a *Verification* section, not a test plan. The fix separates structure from values (headings and checkbox lists are copied, the values inside them are sourced), distinguishes a CLASSIFYING box ("- [x] Bug fix" states intent, legitimate) from an ASSERTING one ("- [x] Tests pass" claims a result, forbidden), and states the precedence in the heading. Verified: the fabricated log is gone in every configuration tested, while the sectioned shape and the classification box survive.
- "SHAPE — the examples govern" — observed 2026-07/08 across three MISS rows: the recipe emitted a multi-section `Summary` / `Rationale` / `Test plan` body into projects whose house style (and whose own recent merged PRs) is a one-or-two-sentence summary. The old wording mandated those sections unconditionally, which silently overrode the "match the SHAPE of the examples" instruction directly above it — the model was obeying the recipe, so the recipe was the bug. Ordering is now conditional on the examples actually using sections.
- "3-bullet list" — caps summary length; without it, summary expands into 8 bullets that duplicate the narrative section. Applies only when the examples use a Summary section.
- "TEST-PLAN-EVIDENCE" — observed 2026-07: prose sections graded A and accurate, but the test plan fabricated *pre-checked* `- [x]` items for runs that never happened (a bare "incremental sync still works" check, and a ">2 MB payload" claim phrased as separately executed). The model anchors on the example PR's test-plan shape and fills it with plausible checks rather than restricting itself to the Context var. This is the recipe's most serious failure mode because a checked box asserts a verification to a human reviewer; the numbered rules bind items to supplied facts and permit omitting the section rather than padding it. **Superseded in part 2026-08-21:** this entry's "ban the checked box outright" is no longer what ships. A blanket ban is wrong for repos whose PR template asks the author to tick a change *category*, where `- [x] Bug fix` states intent rather than a result. The directive is now split across the EVIDENCE block above: asserting boxes are banned, classifying boxes are expected. The rest of this entry still holds.
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

The block above is the shape to expect **only when the anchor examples themselves carry those sections**. Where the recent merged PRs are short prose, the correct output is short prose with no headings at all:

```
Adds X so that Y no longer needs Z. The behaviour is unchanged for existing callers, and the suite covers the new path.
```

Verify before recording verdict: the output's shape matches the anchor examples' shape (headings only if the examples used headings — a multi-section body against terse examples is a MISS, not a bonus), no `PR #NN` prefix in any heading, no fabricated tool output (any code block claiming to show CLI / metrics output should be cross-checked against the actual format), and — where a test plan is present at all — every item traces to something stated in the Context and no box is pre-checked. A single `- [x]` is an automatic MISS: it asserts a verification that did not happen.

## Calibration notes

The dated calibration history for this recipe lives in [`docs/calibration/pr-description.md`](../docs/calibration/pr-description.md); add each new entry there.
