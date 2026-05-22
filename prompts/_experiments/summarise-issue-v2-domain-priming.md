# summarise-issue-v2-domain-priming

> **EXPERIMENT VARIANT (Phase 12 Track A, issue #160)** — copy of `prompts/summarise-issue.md` with a single domain-priming opening line added to the prompt template. Do not use in production.

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

Pick the smallest input that captures what you want summarised. The 35B prose-tier model's practical ceiling on the reference host is sharper than the original ~5 KB framing suggests. Issue #110's 2026-05-13 follow-up shows the same model class stalls on recipe-shaped prompts of ~3-4 KB on both Ollama and MLX, while a 0.6B-class model handles the same shape in seconds. The discriminator is model parameter count at recipe-sized prompts, not bytes (see `pr-description.md` calibration history for the full evidence). The `reasoning` tier handles larger inputs because the output is shorter and more structured.

## Prompt template

```
The input is a GitHub issue body plus its comments, with timestamps and author names.
Summarise this {{kind}} thread as a timeline. Output the sections below in this exact order, and OMIT any section that has no content in the input — do not fabricate.

## What happened
{{N_FACTS}} bullets, each one event from the thread in chronological order. Format: "- <date or comment-N>: <one-line factual statement>". Quote short fragments (`like this`) when helpful; do not paraphrase commands or error messages.

## What's blocking
At most 3 bullets naming concrete blockers stated in the thread.

## What's next
At most 3 bullets naming concrete next actions stated by participants in the thread.

Rules:
- Every claim must point back to a specific comment, date, or log line. If you cannot, drop the claim.
- OMIT-EMPTY-SECTION (priority 1, non-negotiable): If the thread does NOT explicitly state at least one blocker, the heading `## What's blocking` MUST be absent from your output entirely — no heading, no bullets. Same for `## What's next` if the thread does not explicitly state at least one next action. Placeholder bullets like "No blockers stated" / "Nothing to do" / "TBD" are FORBIDDEN. **Your output MUST NOT contain the substrings "No blockers", "no blockers", "no specific blockers", "Nothing to do", "TBD", "N/A", or any other phrase indicating absence — if you would write one of those, delete the entire section (heading included) instead.** Either there is a real bullet under the heading, or both the heading and its body are gone.
  - Wrong (input has no blockers): `## What's blocking\n- No blockers stated in the thread.`
  - Correct (input has no blockers): the `## What's blocking` heading does NOT appear; the next heading after `## What happened` is `## What's next` (or end of output if next is also empty).
- Do NOT summarise comments as a group ("several people agreed that ...") — name the comment.
- Do NOT include emoji or reaction-style commentary.
- Output ONLY the markdown sections, no preamble, no closing summary sentence.

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
      reasoning "Adhere to the section order exactly. Omit empty sections."
```

For a CI log:

```bash
gh run view <run-id> --log-failed \
  | bash scripts/delegate.sh --recipe summarise-issue \
      --var kind="CI log" \
      --var N_FACTS=5 \
      reasoning "List only the failure events. Omit 'What's blocking' if the log already names the cause."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "OMIT-EMPTY-SECTION RULE ... the entire heading line ... MUST NOT appear in the output. Do NOT write placeholder bullets" — the highest-volume failure mode on this task shape. First-attempt dogfood produced `## What's blocking\n- No specific blockers mentioned in the thread.` instead of dropping the heading. The "soft" omit rule wasn't strong enough; the named rule with explicit "the heading line MUST NOT appear" plus the named anti-pattern ("No blockers" placeholder) flipped it on re-test. SKILL.md's "find anything interesting" failure mode applies here in disguise — the model wants to fill the slot even when the input doesn't support it.
- "Every claim must point back to a specific comment, date, or log line. If you cannot, drop the claim" — the citation-rate discipline from the Phase 7 T3 fixture (`experiments/score-t3.sh`). Forces the model to anchor against the input instead of pattern-matching on the issue title and inventing.
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

Initial recipe drafted 2026-05-10 from the `cat build.log | delegate.sh reasoning "List only the lines indicating test failures."` example in SKILL.md's Pattern section. The recipe generalises that example: SKILL.md's snippet is a closed-form filter over a single log file; this recipe handles the broader "long thread → timeline" shape that requires the same citation-rate discipline.

### 2026-05-10 dogfood: HIT-with-edits — OMIT rule resists three iterations

Three consecutive attempts against `deepseek-r1:32b` (reasoning tier) on issue #75 (~3 KB input). All three placed a "No blockers explicitly stated in the thread" bullet under `## What's blocking` despite progressively stronger rules:

1. Soft "OMIT this section entirely. Do NOT speculate" — produced placeholder.
2. Named "OMIT-EMPTY-SECTION RULE" with explicit "the entire heading line MUST NOT appear ... no placeholder bullets like 'No blockers'" — still produced placeholder.
3. v5/v7-style directive-rule with priority + Wrong/Correct contrastive example showing the heading absent — still produced placeholder.

The other content was correct on all three runs: `## What happened` bullets cited dates, `## What's next` bullets matched the issue's stated fix options, no fabrication. The only resistant failure mode is the empty-section placeholder.

Useful empirical finding: the v5/v7 directive-rule + contrastive-example pattern that closed the severity-capping gap (5/5 Opus parity on the same model) does NOT fully bind on this task shape. Hypothesis: the model interprets "explicit empty marker" as compliant with the rule because it is being honest about absence, not fabricating presence. The Phase 10 retrospective's "directive-rule with hard-coded keyword triggers" pattern was tested against closed-form classification, not output-structure conditional rules; the latter may need a different discipline (perhaps a string-level prohibition like "your output must not contain the substring 'No blockers'").

Recipe ships with HIT-with-edits status: the output is usable after deleting "No X stated" placeholder lines by hand.

### 2026-05-11 — string-level prohibition also fails to bind

Fourth attempt with the explicit substring prohibition gemini-code-assist suggested on PR #81 (and which the calibration note above hypothesised would work): the rule was extended to `Your output MUST NOT contain the substrings "No blockers", "no blockers", "no specific blockers", "Nothing to do", "TBD", "N/A", or any other phrase indicating absence`. Re-tested against the same issue #75 on `deepseek-r1:32b` (reasoning tier).

Result: the model produced `## What's blocking\n- No explicit blockers stated in the thread.` — an unlisted synonym for the prohibited set. The "or any other phrase indicating absence" catch-all did not bind either.

This is a sharper empirical finding than the previous iteration. The model is not just ignoring a directive; it is actively pattern-matching for unlisted synonyms when its preferred behaviour (explicit-absence-marker) is forbidden. The world-model is "honest acknowledgement of absence is informative output", and prompt-only calibration up to and including substring blocklists cannot override that on this task shape on this model.

Concrete next options for a future calibration iteration:
1. Restructure the template so optional sections are described as conditional-include rather than conditional-omit (positive rule, not negative).
2. Route to a different tier (the `code` tier with `qwen3-coder-next:latest` may bind the rule differently; the v6 retro found same-family scale-down loses cross-reference capability, but the cross-reference being lost here is about output structure, not severity calibration).
3. Add a post-processing step in the recipe documentation: `sed -i '/^- No .* stated.*$/d; /^## What.s blocking$/d' <<< output` as a known artefact strip.
4. Accept the placeholder as a HIT-with-edits artefact and let users strip by hand (current state).

Option 1 or 2 are the empirical experiments worth running next.
