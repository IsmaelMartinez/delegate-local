---
tier: reasoning
inputs:
  kind: string
  N_FACTS: integer
  stdin: string
---
# summarise-issue

## When to use

The user wants a timeline-style summary of a long-running GitHub issue, MR/PR thread, or CI log — typically pasted as a comment on the same issue ("status as of <date>") or as a status update elsewhere. Input is text-heavy: issue body + comments, or a build log, or an MR discussion thread. Output is a short structured rundown of "what happened, what's blocking, what's next."

This is the recipe SKILL.md calls out by example (`cat build.log | bash scripts/delegate.sh reasoning "List only the lines indicating test failures..."`). The `reasoning` tier is the default here, not `prose` — the task is filtering and classification, not generation of new prose.

For short issues (≤ 5 comments, single failure mode), do not delegate — the setup overhead dominates. The recipe's threshold is roughly: if the input does not benefit from being structured, the output won't either.

## Context to gather first

```bash
# For a GitHub issue: body + every comment, oldest first.
gh issue view <issue-number> --json title,body,comments \
  --jq '{title, body, comments: [.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]}'

# For a CI / build log: pipe the raw log on stdin via {{stdin}}.
gh run view <run-id> --log-failed                       # job-step failures only
gh run view <run-id> --log | head -500                   # full log, capped

# For an MR thread: the discussions list, oldest first.
glab mr view <mr-iid> --comments --output json
```

Pick the smallest input that captures what you want summarised. The 35B prose-tier model has a real first-call ceiling on the reference host: a recipe-shaped prompt against a cold 35B pays a one-time cold-LOAD (~77 s on MLX, ~18 s on Ollama) before any tokens stream, while a 0.6B-class model loads in about a second. (Earlier notes framed this as a parameter-count *generation* stall; the 2026-06-28 re-measurement traced it to cold-load — see `pr-description.md`'s 2026-06-28 note and ADR 0027.) Keep inputs small so the first call clears quickly, or set `DELEGATE_PREFLIGHT_TIMEOUT=90` and keep the model warm. The `reasoning` tier handles larger inputs because the output is shorter and more structured.

## Prompt template

```
Summarise this {{kind}} thread as a timeline. Output the sections below in this exact order, and OMIT any section that has no content in the input — do not fabricate.

## What happened
{{N_FACTS}} bullets, each one event from the thread in chronological order. Format: "- <date or comment-N>: <one-line factual statement>". Quote short fragments (`like this`) when helpful; do not paraphrase commands or error messages.

BULLET CAP — non-negotiable:
Count the bullets under `## What happened`. If the count exceeds {{N_FACTS}}, DELETE bullets from the end until the count equals {{N_FACTS}}. The cap is a hard ceiling, not a guideline. Stop after the {{N_FACTS}}th bullet. Do not add a bullet that summarises or restates what the preceding bullets already said.
Wrong (N_FACTS=5, output has 7 bullets under What happened): the model splits multi-clause events into separate bullets or appends summary bullets beyond the cap.
Correct (N_FACTS=5, output has exactly 5 bullets under What happened): the model compresses multi-clause events into single bullets and stops at the cap.

## What's blocking
At most 3 bullets naming concrete blockers stated in the thread. Stop after the 3rd bullet. Do not add a bullet that restates an earlier blocker in different words.

## What's next
At most 3 bullets naming concrete next actions stated by participants in the thread. Stop after the 3rd bullet. Do not add a bullet that restates an earlier action in different words.

Rules:
- Every claim must point back to a specific comment, date, or log line. If you cannot, drop the claim.
- OMIT-EMPTY-SECTION (priority 1, non-negotiable): the `## What's blocking` section is conditional-include, not conditional-omit. **Include the `## What's blocking` heading ONLY if the input contains at least one statement that something is blocking, is blocked, is waiting on, is stalled by, depends on, or is otherwise stopped from progressing.** If the input contains NO such statement, omit the `## What's blocking` heading entirely and do not produce that section — no heading, no bullets, no acknowledgement of absence. Same for `## What's next`: include the heading only if the input contains at least one explicit next-action statement; otherwise omit the heading entirely. Acknowledging absence is itself a violation: any sentence whose subject is the absence of blockers/next-steps (paraphrases including but not limited to "No blockers", "no blockers", "no specific blockers", "No explicit blockers stated", "Nothing to do", "TBD", "N/A", "None mentioned", "Not specified") counts as the prohibited shape regardless of exact wording. The test is semantic, not literal-substring: if the sentence's meaning is "the input does not contain a blocker" or "the input does not contain a next action", delete the entire section (heading included).
  - Wrong shape (zero comments, no blockers stated in body): output contains `## What's blocking` followed by a single bullet whose meaning is "no blockers were stated in the thread" — the model previously emitted phrasings of this shape including `- No explicit blockers stated in the thread.`, `- No specific blockers mentioned in the thread.`, `- No blockers stated.`, and `- None mentioned by participants.`. Treat any sentence carrying that meaning as the prohibited shape regardless of exact wording.
  - Correct (zero comments, no blockers stated in body): the `## What's blocking` heading does NOT appear; the next heading after `## What happened` is `## What's next` (or end of output if next is also empty).
  - Wrong shape (with-comments thread, no blockers stated anywhere): output contains `## What's blocking` followed by a single bullet whose meaning is "no participant raised a blocker" (any wording).
  - Correct (with-comments thread, no blockers stated anywhere): the `## What's blocking` heading does NOT appear at all.
  - Wrong shape (zero comments, no next-action stated): output contains `## What's next` followed by a single bullet whose meaning is "no next actions were stated" — symmetric to the blockers shape, prohibited by the same rule.
  - Correct (zero comments, no next-action stated): the `## What's next` heading does NOT appear; if `## What happened` is the only section with content, output ends after its bullets.
- COMMENT-N-CITATION (priority 2, non-negotiable): the `comment-N` citation label refers strictly to entries in the input's `comments:` array, indexed in the order they appear there. If the input shows ZERO comments (the `comments:` array is empty or the comments section under the body is absent), do NOT fabricate `Comment-1`, `Comment-2`, etc. Markdown section headings inside the issue body (e.g., `## Context`, `## Scope`, `## Implementation plan`) are NOT comments — they are body structure. Cite body facts as "the issue body" or by quoting the body's heading verbatim (e.g., "the body's `'## Scope'` section"). When there are N real comments, `Comment-1` through `Comment-N` are valid; `Comment-(N+1)` and beyond are fabrications.
  - Wrong (input shows 0 comments, body has internal headings): bullets reference `Comment-1: Implementation plan outlined…`, `Comment-2: Discussed emitting one span…`
  - Correct (input shows 0 comments, body has internal headings): bullets reference `the issue body: Implementation plan outlined…` or `the body's '## Implementation plan' section…`
  - Wrong (input shows 2 comments, body also has internal headings): bullets reference `Comment-3` for a body heading.
  - Correct (input shows 2 comments, body also has internal headings): `Comment-1` and `Comment-2` cite the two actual comments; body content is cited as "the issue body" or by quoted heading.
- Do NOT summarise comments as a group ("several people agreed that ...") — name the comment.
- Do NOT include emoji or reaction-style commentary.
- Output ONLY the markdown sections, no preamble.
- Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

=== Input ({{kind}}) ===
{{stdin}}
```

## Variables

- `{{kind}}` — what the input is: `issue`, `MR thread`, `PR thread`, `CI log`. Surfaces in the section headers and the `=== Input ===` envelope to anchor the model on the expected vocabulary.
- `{{N_FACTS}}` — number of "What happened" bullets to aim for (default 5; use fewer for short threads, more for very long ones). Cap at 10 — beyond that the summary becomes its own readability problem.
- `{{stdin}}` — the gathered input (issue JSON, log text, MR discussion list) piped to the wrapper.

## Invocation

```bash
gh issue view 75 --json title,body,comments \
  --jq '{title, body, comments: [.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]}' \
  | bash scripts/delegate.sh --recipe summarise-issue \
      --var kind="issue" \
      --var N_FACTS=5 \
      "Adhere to the section order exactly. Omit empty sections."
```

For a CI log:

```bash
gh run view <run-id> --log-failed \
  | bash scripts/delegate.sh --recipe summarise-issue \
      --var kind="CI log" \
      --var N_FACTS=5 \
      "List only the failure events. Omit 'What's blocking' if the log already names the cause."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- OMIT-EMPTY-SECTION (priority 1, non-negotiable) recast 2026-05-22 from substring-blocklist to positive-form conditional-include directive — the substring blocklist was bypassed on 2026-05-21 by the paraphrase `No explicit blockers stated in the thread` (issue #148). The new directive states the include condition rather than enumerating forbidden phrases: include the `## What's blocking` heading ONLY if the input names at least one blocker. The Wrong/Correct example set is paired across both zero-comments and with-comments thread shapes for both `## What's blocking` and `## What's next` per the PR #173 review principle that few-shot anchors must cover both outcomes or the model over-generalises. The PR #180 review-pass refinement reframed each Wrong example from a single verbatim literal into a family-of-paraphrases description that lists four real prior MISS phrasings — the single-literal anchor was hypothesised to function as a copyable crib (the 2026-05-22T11:11:53Z dogfood reproduced it verbatim); the family-of-paraphrases framing keeps the shape signal without the verbatim-copy attack surface. The semantic test sentence covers both blockers and next-action meanings so the directive itself enforces symmetry across the two sections. The substring blocklist (including the restored lowercase `no blockers` variant) is retained as a belt-and-braces secondary guard but is no longer the primary mechanism.
- COMMENT-N-CITATION (priority 2, non-negotiable) added 2026-05-22 from issue #148: the model fabricated `Comment-1` through `Comment-4` against issue #134 (zero comments) by treating the body's markdown section headings as separate comment entries. The directive states explicitly that `comment-N` indexes the `comments:` array of the input, that markdown headings inside the body are NOT comments, and gives the correct citation form ("the issue body" or quoted body heading). Wrong/Correct pairs cover both zero-comment and with-comments cases so the model doesn't over-generalise to one shape.
- "OMIT-EMPTY-SECTION RULE ... the entire heading line ... MUST NOT appear in the output. Do NOT write placeholder bullets" — the highest-volume failure mode on this task shape. First-attempt dogfood produced `## What's blocking\n- No specific blockers mentioned in the thread.` instead of dropping the heading. The "soft" omit rule wasn't strong enough; the named rule with explicit "the heading line MUST NOT appear" plus the named anti-pattern ("No blockers" placeholder) flipped it on re-test. SKILL.md's "find anything interesting" failure mode applies here in disguise — the model wants to fill the slot even when the input doesn't support it.
- "Every claim must point back to a specific comment, date, or log line. If you cannot, drop the claim" — the citation-rate discipline from the Phase 7 T3 fixture (its scorer was archived out of `main` in 22395b2). Forces the model to anchor against the input instead of pattern-matching on the issue title and inventing.
- "Do NOT summarise comments as a group" — observed in similar timeline-summary tasks: the prose tier produces "the team agreed to defer the fix" when one specific commenter said it and others didn't. Group-level claims hide the source.
- "Do NOT include emoji or reaction-style commentary" — GitHub comments often contain emoji reactions that the model copies into the summary; the recipe forbids it explicitly.
- "Output ONLY the markdown sections" — the prose tier's anti-padding directive from SKILL.md.

The `reasoning` tier (not `prose`) is intentional. SKILL.md is explicit: "For analytical work over a diff or log, use `reasoning` even if the input is text-heavy" — and this recipe is exactly that. The output is short and structured; the cost is on the filtering, not the generation.

## Expected output shape

```
## What happened

- 2026-05-09: @user-a opened the issue describing `foo()` returning the wrong type for empty input.
- 2026-05-09 (+2h): @user-b posted a 3-line reproduction.
- 2026-05-10: @user-c bisected to commit `abc1234` (the recent refactor of `foo`).

## What's blocking

- Waiting for @user-c to confirm whether `abc1234` is safe to revert or needs a forward fix.

## What's next

- @user-a will draft a forward-fix PR once @user-c confirms.
- @user-b will add a regression test for the empty-input case.
```

Verify before recording verdict: every bullet cites a date / comment / log line; no group-level claims; no fabricated blockers or next steps; output starts with `## What happened` (no preamble).

## Calibration notes

The dated calibration history for this recipe lives in [`docs/calibration/summarise-issue.md`](../docs/calibration/summarise-issue.md); add each new entry there.
