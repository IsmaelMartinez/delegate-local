---
tier: prose
inputs:
  stdin: string
  ask: string
  recipient: string?
  signoff: string?
checks:
  no_padding_tail: true
  no_single_item_list: true
---
# maintainer-reply

## When to use

You are a project maintainer drafting a short outbound reply to a contributor or reporter — a PR-review comment, an issue status comment, or a diagnostic one-liner on a bug report — from facts you already have in hand. The desired shape is closed: one sentence of specific praise (for a contribution) or the confirmed cause (for a bug), then exactly one question or ask, then an optional warm sign-off. This is the shape that fit all three live cases in issue #283 (a PR review on teams-for-linux #2632, an issue status comment on #2621, a diagnostic one-liner on #2603).

Distinct from the two adjacent reply recipes: `pr-review-reply.md` is the PR *author* posting a one-line "Applied in `<hash>`" under a reviewer's inline comment, and `maintainer-review-reply.md` leads with a verdict and then carries the evidence behind it, at whatever length that evidence needs. This recipe *drafts the maintainer's reply from scratch* in the maintainer's outbound voice, in the closed short shape.

Multi-ask replies are in scope as of 2026-08-03: pass the several asks in one `--var ask=...` and the MULTI-ASK-SPLIT rule keeps each as its own numbered question instead of merging them. This replaced the earlier "call the recipe once per distinct reply" guidance, which callers did not follow — 13 consecutive multi-ask teams-for-linux replies were rewritten because the two-sentence cap compressed several asks into one run-on sentence.

Not for: replies that push back on the reporter's premise or argue a contentious design decision (write those by hand — a model dilutes the maintainer's voice on contention), or multi-paragraph technical explanations (the recipe caps the prose body at two sentences even when the ask list is long). A reply whose length is set by how much evidence it has to carry — file paths, hashes, issue refs, measured counts — belongs to `maintainer-review-reply.md`. Reaching for this recipe and then having to expand the answer back into paragraphs is the most common way it gets rejected, so check that first.

## Context to gather first

```bash
# The facts — pipe them on stdin as {{stdin}}. For a bug, the confirmed cause
# (e.g. from your own investigation); for a PR, the specific thing worth
# praising. State them as plain facts, NOT as an instruction to the model.
#   echo "The token drop is on Teams' side, in its MSAL cache." | ...
# The reviewer's / reporter's handle, if you want to open with it:
gh pr view <N> --json author --jq '.author.login'
gh issue view <N> --json author --jq '.author.login'
```

The one thing to ask is passed via `--var ask=...` as a *topic*, never as an imperative the model can copy verbatim (issue #283 documented exactly this instruction-echo failure mode). The sign-off and recipient handle are optional.

## Prompt template

```
Draft a short reply from a project maintainer to a contributor or reporter, using only the facts below. Do not copy any instruction or imperative from this prompt into the reply; phrase the ask as a question addressed to the reader.

Write exactly this structure, in order:
1. One sentence: either specific praise for what the contributor did, or a plain statement of the confirmed cause. Name the actual thing (the specific change, or the specific cause), never generic "great work" or "the issue".
2. Exactly one question or ask, addressed to the reader in the second person. Derive it from the ask topic below and phrase it as a direct question. Never write it as an instruction about the reader ("ask them to ...", "they should ...", "the reporter needs to ...").
3. If a sign-off is given below, end with it verbatim on its own line. If none is given, stop after the question.

MULTI-ASK-SPLIT — first match wins, non-negotiable:
Count the distinct asks in the ask topic below. Two asks are distinct when answering one does not answer the other.
1. If there is exactly ONE ask, write the closed two-sentence shape described above.
2. If there are TWO OR MORE, do NOT merge them into one sentence and do NOT drop any of them. Keep the cause-or-praise sentence, then write each ask as its own numbered item, each a direct question to the reader. The two-sentence cap in the rules below is lifted for the ask list only; everything else still applies.
3. Never join distinct asks with "and" into a single run-on question. Mutually exclusive asks in particular must stay separate, because merging them produces a question the reader cannot answer.
4. A SINGLE ask is never a numbered list, however many clauses, conditions or qualifiers it carries. One ask means one question, written as a sentence. Splitting one ask across numbered items is the same defect as merging several into one.
5. If the ask topic or the trailing instruction asks for prose, or says not to use a list, obey it: keep the asks as separate sentences rather than numbering them. An explicit format instruction from the caller outranks this rule.
Wrong: <the cause>. Could you confirm <ask one> and also send <ask two> and say whether <ask three>?
Correct: <the cause>.
1. <ask one, as a question>?
2. <ask two, as a question>?
3. <ask three, as a question>?

NO-FACT-DROP — non-negotiable:
Every fact supplied on stdin that bears on the diagnosis must survive into the reply. The sentence cap is a ceiling on padding, never a licence to discard a supplied fact. If the facts do not fit the shape, add an item — do not delete a fact. If a fact is supplied that you cannot place, keep it in the cause sentence rather than dropping it.

Rules:
- Two body sentences maximum: the praise-or-cause sentence, then the question. No third sentence, no preamble sentence. (Superseded by MULTI-ASK-SPLIT rule 2 when the ask topic carries more than one distinct ask.)
- Do NOT repeat any instruction verbatim. If the ask topic is written as an imperative, rephrase it as a question to the reader.
- No filler flattery ("Great work!", "Awesome!", "Thanks for this!", "Nice job!"). Specific praise that names the actual contribution is allowed and is the point; generic praise is not.
- If a recipient handle is given, open with it ("@{{recipient}}, ..."); otherwise address the reader as "you".
- Avoid em dashes; use commas, parentheses, or periods.
- Stop after the question (or the sign-off). Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This ensures", "This enables"). End on the question mark, the sign-off, or a finite verb introducing new content.
- Output only the reply text. No preamble, no "Here's the reply:", no markdown fence.

Example shape. These are skeletons, not sentences: the angle-bracket slots are
filled from the facts below, never carried through as written.

Wrong: <the cause>, and ask the reporter to confirm whether <condition>.
Correct: <the cause>. Could you confirm whether <condition>?

=== Facts (confirmed cause, or the specific thing to praise) ===
{{stdin}}

=== The one thing to ask (a topic, not an instruction) ===
{{ask}}

=== Recipient handle (optional) ===
{{recipient}}

=== Sign-off (verbatim, optional) ===
{{signoff}}
```

## Variables

- `{{stdin}}` — the facts, piped in: the confirmed cause (for a bug reply) or the specific contribution worth praising (for a PR reply). State as plain facts, never as an instruction. No `--var` slot needed.
- `{{ask}}` — the single thing to ask, as a *topic* (e.g. `whether the token survives a cold start`), not an imperative (`ask them to check ...`). The recipe phrases it as a question to the reader.
- `{{recipient}}` — optional `@handle` of the contributor/reporter to open with. Omit to address the reader as "you".
- `{{signoff}}` — optional warm closer to append verbatim (e.g. `Thanks again!`, `I hope this helps!`). Omit for no sign-off.

## Invocation

```bash
echo "The token drop is on Teams' side, in its MSAL cache, not in teams-for-linux." \
  | bash scripts/delegate.sh --recipe maintainer-reply \
      --var ask="whether the token survives a cold start of the app" \
      --var recipient="nneul" \
      --var signoff="Thanks again!" \
      "Two sentences: state the cause, then ask the reader a direct question. Do not echo any instruction."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Do not copy any instruction or imperative from this prompt into the reply; phrase the ask as a question" — this is the live #283 instruction-echo failure: a freeform prompt that embedded the action as an imperative ("…and ask the reporter to check whether X") was echoed verbatim into prose-tier output (`qwen3.6:35b-a3b-q8_0` via MLX) as *"the drop is in Teams' MSAL, and ask the reporter to check whether…"*. Passing the ask as a topic (not an imperative) plus this guard is the fix that closed it on first retry in the original session.
- "Two body sentences maximum … No third sentence" — prose tier loves a closing-paraphrase sentence (see SKILL.md's anti-padding directive). The closed two-sentence shape (cause/praise, then the question) is the whole point of the recipe for the single-ask case.
- "MULTI-ASK-SPLIT" — measured 2026-08-03: keep-rate on `teams-for-linux` was 0 of 13 over the preceding 30 days against 92% on single-ask work, with the same model, backend and an unedited template. The rewrite reasons were one pattern: "merged two mutually exclusive asks into one sentence", "compressed four items into one run-on ask", "dropped all substance from the three asks", "fixed wrong conditional chaining of asks". The old scope note told callers to invoke once per ask; they did not, so the cap silently ate the asks. The rule makes multi-ask a first-class shape instead of an unenforced instruction.
- "NO-FACT-DROP" — same measurement window: "two-sentence cap squeezed out the PR #2424 cross-run dedup fact from stdin; kept only the commitable_code_suggestions fact, losing the strategic link". The cap was being read as licence to discard supplied facts rather than to suppress padding; this states which of the two it is.
- "No filler flattery … Specific praise that names the actual contribution is allowed" — generic praise ("Great work!") doubles the reply length for no information and reads as boilerplate; the praise that earns its place names the specific thing the contributor did.
- "If the ask topic is written as an imperative, rephrase it as a question" — the topic var is the most likely place a caller accidentally hands the model a copyable imperative; the guard makes the model transform it rather than echo it.
- "Output only the reply text. No preamble" — without it the model prefaces with "Here's the reply:" or wraps in a markdown fence.

## Expected output shape

```
@nneul, the token drop is on Teams' side, in its MSAL cache, not in teams-for-linux itself. Could you check whether it survives a cold start of the app on your setup?

Thanks again!
```

```
Nice catch on the off-by-one in the pagination cursor, the fix in `b3f2a91` is exactly right. Would you be up for adding a regression test that pages past the last item before we merge?
```

Multi-ask shape (MULTI-ASK-SPLIT), when the ask topic carries more than one distinct ask:

```
@nneul, the blank-window regression is in the Electron 39 upgrade, specifically the GPU sandbox flag flip, which also silently disabled cross-run dedup in PR #2424.
1. Does it reproduce on 2.9?
2. Could you paste the launch flags you use?
3. Does a downgrade to 2.9 clear it?

Thanks again!
```

Verify before recording verdict: opens with the specific praise or the confirmed cause (not generic filler), the ask is a question addressed to the reader (no echoed imperative), the sign-off (if any) is preserved verbatim, no em dashes, no closing-paraphrase sentence, no preamble or markdown fence. On length: a single-ask reply is at most two sentences; a multi-ask reply is one cause sentence plus one numbered question per ask, and every ask supplied must appear — do NOT record a MISS on a multi-ask reply merely for exceeding two sentences, that is the MULTI-ASK-SPLIT shape working. Do record a MISS if distinct asks were merged into one question, or if a fact supplied on stdin is missing.

## Calibration notes

Drafted 2026-06-09 from issue #283, which filed this as a prompt-pattern coverage gap and a live data point for #277 (trigger rate is the binding constraint). The shape anchor is the three maintainer replies hand-drafted in a teams-for-linux session that day — a PR review on #2632, an issue status comment on #2621, and a diagnostic one-liner on #2603 — all of which fit the "one sentence of cause/praise, then one ask, optional warm sign-off" structure. The recipe exists so this recurring shape becomes a hard trigger (`--recipe maintainer-reply`) rather than a freeform judgement call, which simultaneously raises trigger rate and removes the instruction-echo failure mode #283 documented.

### 2026-06-09 dogfood: HIT, and the anti-echo guard reproduced-and-fixed the #283 failure

First-pass against `mlx-community/Qwen3.6-35B-A3B-8bit` (prose tier, MLX — the same backend/model that produced the original #283 instruction-echo MISS). The dogfood deliberately passed the ask as an *imperative* (`--var ask="ask the reporter to check whether the token survives a cold start of the app"`) to stress the guard, on the literal #283 cause statement. Output:

```
@nneul, the token drop is on Teams' side, in its MSAL cache, not in teams-for-linux itself. Could you check whether the token survives a cold start of the app?
Thanks again!
```

The model rephrased the imperative into a question (`Could you check whether…?`) instead of echoing `…and ask the reporter to check whether…` verbatim — the exact failure #283 reported, fixed on first attempt. Handle preserved, one cause sentence, one question, verbatim sign-off, no flattery, no padding tail, no preamble or fence. HIT, no edits needed (recorded via `delegate-feedback.sh`). This promotes the recipe from structural-starting-point to validated on the prose tier.

### 2026-08-03 — multi-ask compression measured, MULTI-ASK-SPLIT and NO-FACT-DROP added

A metrics sweep over the rolling 30-day window put the recipe at 23% keep across 21 calls, against 93% across 16 calls before 2026-07-04. Splitting by project isolated it: `delegate-local` moved 92% → 71% (a dip), while `teams-for-linux` moved 3/3 → 0/13. The model (`mlx-community/Qwen3.6-35B-A3B-8bit`), the backend (MLX) and the template were all unchanged across the two eras, so the regression is task shape, not drift — the recipe met a wave of multi-ask reporter replies it was never scoped for, and the two-sentence cap merged or dropped the asks every time.

Rather than re-assert the "one ask per call" scope note that callers had already ignored 13 times, multi-ask became a supported shape via MULTI-ASK-SPLIT, with NO-FACT-DROP added because one MISS showed the cap discarding a supplied fact outright rather than merely compressing. Both are pinned in `tests/test-prompts-library.sh` so a later simplification pass cannot quietly drop them. Re-measure over the next ~10 `teams-for-linux` replies before trusting the fix.

### 2026-08-26 — the examples were being returned as the answer

Two `pr-agent` calls minutes apart, carrying 7,689 and 7,317 characters of
piped context, both returned exactly 96 characters. Ninety-six characters is
the length of this recipe's own `Correct:` line, and the outputs were that
line, byte for byte. A third call the same hour opened with the same example's
"the regression is" framing for a change that was not a regression at all. The
agent that received them recorded "recipe appears broken, not a prose-quality
problem", which is the right instinct and the wrong diagnosis: the recipe was
working exactly as written, and what it had written was a fluent, on-topic,
grammatically complete sentence for the model to reach for when the real input
got long. Same shape as the AI-815 leak in `pr-description`.

The contrast is what makes ADR 0011 anchors work, not the sentences carrying
it, so both pairs became skeletons with angle-bracket slots. A leak now
surfaces as literal `<the cause>` text rather than a plausible fabrication —
the same principle that killed the reference-trailer guard in `pr-description`,
where a guard that turned visibly-wrong output into a believable fake was worse
than no guard. Backing it up, `no_example_echo` (ADR 0029) now runs on every
recipe call and rejects any output that reproduces a line of its own prompt.

The same day's rejections also showed MULTI-ASK-SPLIT rule 2 firing on single
asks — "rendered a single request as a numbered list", twice, and once against
an explicit no-list instruction from the caller — so rules 4 and 5 pin one ask
to one sentence and give a caller's format instruction precedence.

### 2026-08-26 (later) — the single-ask list survived two rewordings, so it became a check

Four `pr-agent` rejections in twelve minutes, all on this recipe. One of them
(19:29:41Z) came back as a numbered list holding exactly one item: `1. Would you
like to apply the two inline suggestions ... or leave the pipe-label case for a
follow-up?`. That is MULTI-ASK-SPLIT rule 4 failing hours after rule 4 was
written to prevent it, and rule 4 was itself the second attempt, because the
rule 2 numbered shape (2026-08-03) is what introduced the defect in the first
place.

`no_single_item_list`, declared in the frontmatter above, is the third attempt
and the first that does not ask the model to comply. A one-item list is wrong
here whichever branch the caller is on: rule 2 gives two-or-more asks an item
each and rule 4 gives a single ask a sentence, so the check never needs to know
how many asks were passed. Counted against the four drafts from that window it
fires on exactly the one carrying the defect (1 item) and leaves the others
alone (0, 2 and 2 items). Warn-only, like every declared check except
`no_padding_tail`.

The larger signal in the same window is deliberately NOT addressed here, and is
recorded so a later run does not read it as new. Three of the four rejections
wanted a verdict-first, multi-paragraph, anchor-carrying reply, which is
`maintainer-review-reply.md` — live since 15:09 that day, pointed at from
SKILL.md, and still at n=0 calls. That is a routing problem, and a third
paragraph of routing prose is the thrash path `docs/self-improvement-loop.md`
warns about. Re-measure once that recipe has calls of its own.

### 2026-08-26 (later still) — the scope note pointed at a recipe that had been deleted

The "distinct from the two adjacent reply recipes" paragraph named
`polish-reply`, pruned in `7a64d46` as a zero-use recipe, and the prune never
updated the referrer. So a caller reading this file to decide whether it was the
right recipe was offered one alternative that does not exist and was not told
about `maintainer-review-reply.md`, which is the one built for the workload this
recipe keeps absorbing.

That matters more than a dangling link because of what the same day measured.
`maintainer-reply` took 14 verdicted calls on 2026-08-26 and kept none of them,
and three of the four rejections in the 19:17-19:29 window wanted the
verdict-first, multi-paragraph, anchor-carrying shape that this recipe
explicitly excludes. `maintainer-review-reply` had been live since 15:09 with a
pointer in SKILL.md and had zero calls. The pointer in SKILL.md is one clause in
a long paragraph; this file is what a caller actually opens when deciding, so
the hand-off belongs here too.

Prose only, no template change: the two-sentence shape is unchanged and the
model's behaviour is not what this addresses. Re-measure by whether
`maintainer-review-reply` starts taking calls at all, not by this recipe's keep
rate.

### Tier choice

Prose tier (`qwen3.6:35b-a3b-q8_0` by default). The task is drafting short prose from supplied facts; the facts are passive content the model reproduces and reshapes, not active reasoning targets. The discriminator is the same as `maintainer-review-reply.md`: this is prose shaping, not reasoning.

### 2026-08-27 — the comment boundary now routes by size

`comment-reply` pinned this recipe unconditionally, so every `gh pr comment`
posted anywhere named the closed two-sentence shape. That is most of how it
came to hold 33 of the corpus's delegations at 21% usable (agent tier, h=0),
with the rejection reasons repeating one sentence in different words:
"collapsed all 14 facts into a single run-on sentence", "returned two sentences
instead of a four-paragraph body", "dropped every measured fact from the
context".

None of that is a quality problem with this recipe. The closed shape was doing
exactly its job to a workload its own scope section excludes. The hook now
measures the body being posted and names `maintainer-review-reply` at or above
600 characters, a threshold taken from the two recipes' own documented output
(182 here, 467 there) and set high on purpose: routing a genuinely short reply
to the evidence-led recipe would be a new failure, while leaving a long one
here is only today's behaviour.

Re-measure this recipe's usable rate after roughly ten more calls, and expect
the n to fall as well as the rate to move — some of its traffic should now be
going elsewhere.
