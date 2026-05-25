---
inputs:
  kind: string
  stdin: string
flaky_on_models:
  - qwen3.6:35b
  - qwen3.6-35b
  - qwen3_6-35b
  - qwen3.6_35b
  - qwen3-next:80b
  - qwen3-next-80b
  - qwen3_next-80b
---
# long-thread-distillation

## When to use

The agent is picking up a stale PR or issue thread (10-50 comments, often 20-100 KB) and needs to know where it stands right now — outstanding action items, who is waiting on whom, what has been agreed so far. The use case is triage of current state, not narrative reconstruction. Output is three short structured sections the agent can act on directly: action items, blockers, consensus.

This recipe is the action-oriented sibling of `summarise-issue.md`. Pick this one when the task is "I'm picking up a stale PR and want to know where it stands" — the agent will follow up by replying, applying, or escalating. Pick `summarise-issue.md` when the task is "I'm pasting a status update" — the agent wants a chronological timeline for a comment or report. Both ingest the same shape of input (a thread JSON dump); the output shape is what decides. The most likely trigger surface is `/address-pr-comments` on a thread with many prior rounds of review, where the agent needs to inventory unresolved comments before drafting replies.

## Context to gather first

```bash
# For a GitHub PR thread: body + every review + every comment, oldest first.
gh pr view <pr-number> --json title,body,comments,reviews \
  --jq '{title, body, reviews: [.reviews[] | {author: .author.login, state, body: .body, submittedAt: .submittedAt, comments: [.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]}], comments: [.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]}'
# Inline review comments (the diff-line annotations gemini and human
# reviewers leave) often carry the load-bearing action items — fetch
# them too and merge into the digest:
gh api repos/<owner>/<repo>/pulls/<pr-number>/comments \
  --jq '[.[] | {author: .user.login, path: .path, line: (.line // .original_line), body: .body, in_reply_to: .in_reply_to_id, created_at: .created_at}]'

# For a GitHub issue thread: body + every comment, oldest first.
gh issue view <issue-number> --json title,body,comments \
  --jq '{title, body, comments: [.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]}'

# For a GitLab MR thread: discussions + threads, oldest first.
glab mr view <mr-iid> --comments --output json
```

If the thread is > 50 KB, consider embedding-and-clustering first via `scripts/embed.sh` and `scripts/semantic-search.sh` to pre-group comments by topic before summarising per cluster. Optional pre-step — not a hard dependency. The recipe handles up to a 35B-class prose-tier model's practical ceiling on its own; past that, the cluster-then-summarise pattern keeps each delegation within bounds without losing thread-wide coverage. See `prompts/semantic-search.md` for the wrapper invocation.

## Prompt template

```
Distil this {{kind}} thread into outstanding action items, blockers, and current consensus. Do not invent action items, reviewers, or agreements that are not present in the input.

Output the three sections below in this exact order. OMIT any section that has no content in the input — do not fabricate.

## Action items
Bulleted list of concrete actions raised in the thread that have NOT been completed. Format: `- @reviewer asked X — unaddressed` or `- @author needs to Y per @reviewer's comment of <date>`. Each item must trace to a specific comment, review, or thread entry. Skip an action item if the same comment or a later one shows it has been resolved.

## Blocked
Bulleted list naming who is waiting on whom and the specific blocker. At most 3 bullets. Stop after the 3rd bullet. Do not add a bullet that restates an earlier blocker in different words. Format: `- @author is waiting on @maintainer's review of the test changes from <date>` or `- @reviewer is waiting on a response to their question about X (asked <date>)`. Skip the section entirely if no participant has stated they are waiting, blocked, stalled, or stopped.

## Consensus
Bulleted list of what participants have explicitly agreed on so far. At most 3 bullets. Stop after the 3rd bullet. Do not add a bullet that restates an earlier agreement in different words. Format: `- The TYPE-selection priority list stays load-bearing; the prefix-hint is additive, not a replacement (per @author's reply to @reviewer on <date>)`. Distinguish "asked" from "agreed" — a reviewer asking for X is NOT consensus that X will happen, only that X has been raised. Skip the section entirely if no explicit agreement has been stated.

Rules:
- Every claim must point back to a specific comment, review, or thread entry. If you cannot, drop the claim. Anchor every claim to evidence in the input.
- OMIT-EMPTY-SECTION (priority 1, non-negotiable): each section heading (`## Action items`, `## Blocked`, `## Consensus`) is conditional-include, not conditional-omit. **Include a heading ONLY if the input contains at least one entry that fits the section's definition.** If the input contains NO such entry, omit the heading entirely and do not produce that section — no heading, no bullets, no acknowledgement of absence. Acknowledging absence is itself a violation: any sentence whose subject is the absence of action items / blockers / consensus (paraphrases including but not limited to "No outstanding actions", "No blockers stated", "No explicit consensus reached", "Nothing to do", "TBD", "N/A", "None mentioned", "Not specified") counts as the prohibited shape regardless of exact wording. The test is semantic, not literal-substring: if the sentence's meaning is "the input does not contain an action item / blocker / agreement", delete the entire section (heading included).
  - Wrong shape (thread with reviews but no unaddressed actions): output contains `## Action items` followed by a single bullet whose meaning is "no outstanding actions remain" — the model has previously emitted phrasings of this shape including `- No outstanding action items.`, `- All review comments have been addressed.`, `- No actions pending.`, and `- None mentioned by participants.`. Treat any sentence carrying that meaning as the prohibited shape regardless of exact wording.
  - Correct (thread with reviews but no unaddressed actions): the `## Action items` heading does NOT appear; the next heading is `## Blocked` (or `## Consensus`, or end of output if all sections are empty).
  - Wrong shape (thread with no waiting-on statements): output contains `## Blocked` followed by a single bullet whose meaning is "no one is blocked" (any wording).
  - Correct (thread with no waiting-on statements): the `## Blocked` heading does NOT appear at all.
  - Wrong shape (thread with discussion but no explicit agreements): output contains `## Consensus` followed by a single bullet whose meaning is "no consensus has been reached".
  - Correct (thread with discussion but no explicit agreements): the `## Consensus` heading does NOT appear; output ends after the last non-empty section.
- SECTION-HEADER-LITERALISM (priority 2, non-negotiable): the three section headings MUST be exactly `## Action items`, `## Blocked`, `## Consensus`. Do not invent alternative headings (`## Open Questions`, `## To Do`, `## Pending`, `## Status`, `## Summary`). Do not add a fourth section. If a thread entry does not fit one of the three categories, drop it rather than inventing a category for it.
- ASKED-VS-AGREED (priority 3, non-negotiable): a reviewer asking for a change is NOT the same as consensus that the change will land. A reviewer's request goes under `## Action items` (unaddressed) until the author has explicitly agreed or applied the change. Consensus requires an explicit statement of agreement from the relevant participants — "I'll do that", "Agreed", "Sounds right", "Applied in <hash>", or equivalent. An unanswered question stays in Action items, not in Consensus.
- Attribute every claim to actual usernames present in the input. Do not invent reviewer names, do not paraphrase a username into a role ("the maintainer", "the contributor") when the input gives a literal `@handle`.
- Do NOT summarise multiple comments as a group ("several reviewers agreed that …") — name each contributor explicitly.
- Do NOT include emoji or reaction-style commentary.
- Output ONLY the markdown sections, no preamble.
- Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.

=== Input ({{kind}}) ===
{{stdin}}
```

## Variables

- `{{kind}}` — what the input is: `PR thread`, `issue thread`, `MR thread`. Surfaces in the section headers and the `=== Input ===` envelope to anchor the model on the expected vocabulary.
- `{{stdin}}` — the gathered thread JSON (PR view + reviews + comments, issue view + comments, or MR discussion list) piped to the wrapper.

## Invocation

```bash
gh pr view 196 --json title,body,comments,reviews \
  --jq '{title, body, reviews: [.reviews[] | {author: .author.login, state, body: .body, submittedAt: .submittedAt}], comments: [.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]}' \
  | bash scripts/delegate.sh --recipe long-thread-distillation \
      --var kind="PR thread" \
      reasoning "Distil into the three sections in order. Omit any empty section entirely."
```

For an issue thread:

```bash
gh issue view 159 --json title,body,comments \
  --jq '{title, body, comments: [.comments[] | {author: .author.login, body: .body, createdAt: .createdAt}]}' \
  | bash scripts/delegate.sh --recipe long-thread-distillation \
      --var kind="issue thread" \
      reasoning "Distil into the three sections in order. Omit any empty section entirely."
```

After the call, verify (see Expected output shape) and record the verdict:

```bash
bash scripts/delegate-feedback.sh hit
# or
bash scripts/delegate-feedback.sh miss "<reason>"
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- OMIT-EMPTY-SECTION (priority 1, non-negotiable) adapted from `summarise-issue.md`'s 2026-05-22 positive-form conditional-include directive (PR #180). The directive states each heading's include condition rather than enumerating forbidden phrases: include a heading ONLY if the input contains at least one entry that fits the section's definition. The Wrong/Correct anchor set is paired across all three sections per the PR #173 dual-anchoring principle that few-shot examples must cover both outcomes. The Wrong-shape examples use the family-of-paraphrases framing the PR #180 review settled on, listing four real phrasing variants per section rather than a single literal anchor that the model can pattern-match back into output. The semantic test sentence covers all three sections' meanings so the directive itself enforces symmetry across `## Action items`, `## Blocked`, and `## Consensus`. Note: `summarise-issue.md`'s 2026-05-22 dogfood MISSed on the same directive shape against `deepseek-r1:32b` (the model's honest-acknowledgement-of-absence prior was not overridden by directive phrasing alone) — option 2 from that calibration entry (tier reroute or a different model family) remains the empirical experiment worth running if this recipe shows the same resistance.

- SECTION-HEADER-LITERALISM (priority 2, non-negotiable) is the direct analogue of `commit-message.md`'s TYPE-selection priority list — a closed set of three section headings with explicit prohibition of synonyms (`## Open Questions`, `## To Do`, `## Pending`, `## Status`, `## Summary`) and an explicit "no fourth section" rule. Without this guard the prose tier reliably invents a `## Open Questions` or `## To Do` heading from review questions that the recipe wants categorised under `## Action items`. The closed-list discipline is the same pattern that closed the `(#NN)` gap on `commit-message.md` and the FAILURE_TYPE category-boundary gap on `ci-log-triage.md`.

- ASKED-VS-AGREED (priority 3, non-negotiable) addresses the most likely fabrication site for this recipe: a review request reads like consensus to the model because reviewers tend to phrase requests assertively ("change X to Y", "rename this to Z"). Without an explicit rule, the model files an unanswered review request under `## Consensus` instead of `## Action items`, which inverts the meaning of the output and misleads the agent picking up the thread. The directive names the explicit-agreement signals (`I'll do that`, `Agreed`, `Sounds right`, `Applied in <hash>`) so the model has a positive test for "this belongs in Consensus" rather than only a negative one.

- "Attribute to actual usernames" — without it, the prose tier compresses `@author` and `@reviewer` mentions into role labels (`the maintainer`, `the contributor`) which lose the cross-thread identity the agent needs to follow up correctly. Observed across multiple long-thread tasks in the project's session history.

- "Do NOT summarise multiple comments as a group" — same guard as `summarise-issue.md`. Long PR threads with three or four reviewers in agreement tend to collapse into "several reviewers agreed" when one specific commenter made the substantive point. Group-level claims hide the source.

- "Every claim must point back to a specific comment, review, or thread entry" — citation-rate discipline borrowed from the Phase 7 T3 fixture and from `summarise-issue.md` / `ci-log-triage.md`. Forces the model to anchor against the input instead of pattern-matching on PR title or thread shape.

- Canonical anti-padding directive copied verbatim from `commit-message.md` and `summarise-issue.md`. Names both participial-clause and declarative-rephrase shapes plus the closing-flourish phrases enumerated in `experiments/score-t4.sh`'s PADDING_REGEXES.

The `reasoning` tier (not `prose`) is intentional. Same argument `summarise-issue.md` and `ci-log-triage.md` make: long-thread distillation is filtering and classification (which comment is unresolved, which is consensus, who is waiting on whom), not generation of new prose. The output is short and structured; the cost is on identifying which entry in the thread is the load-bearing one.

## Expected output shape

```
## Action items

- @reviewer-a asked about test coverage for the MLX backend path — unaddressed (review of 2026-05-22).
- @reviewer-b requested the docstring example use the typed surface — @author has not replied yet (comment of 2026-05-22).

## Blocked

- @author is waiting on @maintainer's final approval after the round-3 push (comment of 2026-05-22 +4h).

## Consensus

- The MLX backend stays opt-in via `DELEGATE_BACKEND=mlx` rather than auto-detected (per @author's reply to @reviewer-a's question of 2026-05-21).
- The OMIT-EMPTY directive uses positive-form conditional-include phrasing (agreed by @author and @reviewer-b in the review of 2026-05-22).
```

Verify before recording verdict: every bullet cites a comment / review / date; no group-level claims; no fabricated reviewers or agreements; output starts with the first non-empty section's heading (no preamble); section headings are literally `## Action items`, `## Blocked`, `## Consensus` and only those; no `## Open Questions` / `## To Do` / `## Status` / `## Summary` headings; empty sections omitted entirely (no "No actions pending" placeholders).

## Calibration notes

Initial recipe drafted 2026-05-24 against ROADMAP P2 "Recipe library expansion — `prompts/long-thread-distillation.md`" once the embedding tier wire-up (PR #204) shipped, unblocking the cluster-then-summarise pre-step for very large threads. The recipe is the action-oriented complement to `summarise-issue.md` (timeline) and shares the same input-digestion shape and citation-rate discipline as `ci-log-triage.md`.

### Integration with `summarise-issue.md`

The two recipes are deliberately separate rather than parameterised on one base because the section-order, omit-rules, and section-vocabulary differ substantively. `summarise-issue.md` produces `## What happened` / `## What's blocking` / `## What's next` with `## What happened` mandatory and the other two conditional; `long-thread-distillation.md` produces `## Action items` / `## Blocked` / `## Consensus` with all three conditional. The use case decides — drafting a status comment reaches for the timeline shape, picking up a stale PR reaches for the action-items shape. The recipes can run in sequence on the same thread when both views are wanted (the timeline frames "how did we get here" and the distillation frames "what do we do now"); per-call token cost is acceptable because the two outputs cover different reader needs.

### OMIT-EMPTY adaptation from `summarise-issue.md`

The OMIT-EMPTY directive is structurally identical to `summarise-issue.md`'s positive-form conditional-include phrasing (PR #180 settled state). The adaptation widens the rule to cover all three sections — `summarise-issue.md` only conditionalises two of its three (`## What's blocking` and `## What's next`; `## What happened` is mandatory because every input has a timeline). All three sections of this recipe are conditional because a thread can plausibly have any combination of (zero or more action items, zero or more blockers, zero or more agreements). The semantic test in the directive covers all three meanings explicitly so the rule itself enforces symmetry rather than relying on the model to generalise from a one-section example. The Wrong/Correct anchors use the family-of-paraphrases framing the `summarise-issue.md` PR #180 review settled on after the verbatim-literal crib risk was reproduced.

The known calibration limit carried over from `summarise-issue.md`: the 2026-05-22 dogfood (ts=2026-05-22T11:11:53Z) showed `deepseek-r1:32b` reproducing the prohibited shape verbatim even under the positive-form directive — the model's honest-acknowledgement-of-absence prior was not overridden by directive phrasing alone. If this recipe's first dogfood reproduces the same failure shape, the calibration notes will graduate option 2 from `summarise-issue.md`'s next-options list — tier reroute or a different model family (the `prose` tier with `qwen3.6:35b-a3b-q8_0`, or the `code` tier with `qwen3-coder-next:latest`) — into the empirical experiment list rather than treating it as deferred future work.

### 2026-05-24 dogfood: PR #196 round-3 review thread — MISS on OMIT-EMPTY, HIT on other guards

First dogfood pass against `deepseek-r1:32b` (reasoning tier, resolved by `scripts/pick-model.sh reasoning` at delegation time ts=2026-05-23T23:43:23Z) on PR #196's review thread (4 reviews + 3 inline comments + body, ~10 KB after `--jq` projection). PR #196 closed track A of #193 with gemini-code-assist's initial review surfacing two reasonable critiques (sampling-default empirical evidence, env-var docstring completeness) plus three round-3 inline comments addressed before merge. The thread is the prototypical input shape this recipe is calibrated against — multi-reviewer, multi-round, mostly resolved with a small set of unaddressed items by merge time.

Verbatim model output:

```
## Action items
- @IsmaelMartinez asked to tighten two stale comments regarding auto-Qwen-profile behavior and model_family emission — unaddressed until cc26ee5.

## Blocked
- No participants have stated they are waiting, blocked, or stalled.

## Consensus
- The PR flips the default sampler back to greedy for all models after T4 A/B feedback showed a regression in commit-message output (per @IsmaelMartinez's comment on 2026-05-23T07:55:31Z).
- The four env-var overrides remain as the shipped feature, allowing callers to opt into non-greedy sampling per call where beneficial (per @IsmaelMartinez's comment on 2026-05-23T07:55:31Z).
```

**Verdict: MISS** (recorded via `delegate-feedback.sh miss`, ref ts=2026-05-23T23:43:23Z) for the OMIT-EMPTY-SECTION bypass on `## Blocked`. The model produced `## Blocked\n- No participants have stated they are waiting, blocked, or stalled.` — the exact honest-acknowledgement-of-absence shape the directive prohibits. This is the same failure mode `summarise-issue.md`'s 2026-05-22T11:11:53Z dogfood reproduced on the same model (`deepseek-r1:32b`), and the empirical evidence is now consistent across two recipes that on this model the positive-form conditional-include directive does not override the model's prior. The calibration-notes prediction in the OMIT-EMPTY-SECTION guard description was confirmed by this dogfood.

The other guards bound cleanly on first dogfood:

- **SECTION-HEADER-LITERALISM:** All three section headings are exactly `## Action items`, `## Blocked`, `## Consensus`. No invented `## Open Questions` / `## To Do` / `## Status` / `## Summary` heading. No fourth section.
- **ASKED-VS-AGREED:** The action item correctly cites `asked to tighten two stale comments` (a request) and the consensus items correctly cite `per @IsmaelMartinez's comment` (an explicit agreement statement). The model did not file the action-item request under Consensus.
- **Attribute to actual usernames:** `@IsmaelMartinez` is the literal handle from the input; no compression to `the maintainer` or `the author`.
- **Citation discipline:** Every consensus bullet carries an actual ISO-8601 timestamp from the thread; the action item names a real commit hash (`cc26ee5`) and the resolution status.
- **No group-level claims, no emoji, no preamble, no padding tail.**

The recipe ships in this first-pass state. Five of six guards bound on first dogfood; the resistant guard (OMIT-EMPTY) is the same shape resistant on `summarise-issue.md` against the same model, so the calibration limit is a model-prior property rather than a recipe-phrasing property. Concrete next options for future iterations (mirroring `summarise-issue.md`'s 2026-05-22 next-options list):

1. **Tier reroute experiment.** The `code` tier with `qwen3-coder-next:latest` or the `prose` tier with `qwen3.6:35b-a3b-q8_0` may bind the OMIT-EMPTY rule differently — neither has been measured for this task shape. Worth testing as a one-off probe before treating the limit as fundamental.
2. **Post-processing strip in recipe documentation.** Document `sed` filter for the known artefact shapes: `sed -E '/^- No .* (stated|reached|pending|mentioned|specified).*$/d; /^## (Action items|Blocked|Consensus)$/{N;/\n$/d;}' <<< "$output"` as a documented post-process when the upstream recipe's MISS shape recurs on the user's host. (Three corrections from the first draft: `-E` for the alternation regex, `$output` for the variable expansion, no `-i` since a herestring isn't a file.)
3. **Accept HIT-with-edits status** and let users strip placeholder bullets by hand (current de-facto state, consistent with the 2026-05-22 ship of `summarise-issue.md` in the same condition).

The dogfood is logged as MISS rather than HIT-with-edits because the OMIT-EMPTY bypass is the recipe's load-bearing structural property — without it, the agent picking up the thread cannot trust "no Blocked section" to mean "no blockers", and the action-oriented use case the recipe is built for degrades. Future calibration work tracks against this verdict, not a paraphrase of it.

### 2026-05-25 — flaky_on_models tier-gate (issue #216)

The prose tier fabricates facts on digest inputs per 8 observed MISSes (number-fabrication, entity-substitution, polarity-inversion). Same gate pattern as pr-description.md (Phase 16 Track A).

### 2026-05-25 — Wrong/Correct anchor for numeric cap (issue #215)

Added constructive stop-after-3rd-bullet phrasing to the `## Blocked` and `## Consensus` sections, which had bare "At most 3 bullets" caps. Same lever that closed SUBJECT_LEN on `commit-message.md` (lines 34-40). The `## Action items` section is uncapped by design — the natural length of that section depends on the thread's review history and capping it risks dropping unaddressed items.
