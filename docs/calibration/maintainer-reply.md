# Calibration history for [`prompts/maintainer-reply.md`](../../prompts/maintainer-reply.md)

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

Rather than re-assert the "one ask per call" scope note that callers had already ignored 13 times, multi-ask became a supported shape via MULTI-ASK-SPLIT, with NO-FACT-DROP added because one MISS showed the cap discarding a supplied fact outright rather than merely compressing. Both were pinned in `tests/test-prompts-library.sh` so a later simplification pass could not quietly drop them, until #566 left wording to the replay gate. Re-measure over the next ~10 `teams-for-linux` replies before trusting the fix.

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

### 2026-08-27 — the 600-character threshold, measured after the fact

The threshold above was set from the two recipes' own documented output and
said so. The population it actually routes is now measured: 27 issue comments
authored by the maintainer on this repo run min 8, p25 573, median 950, p75
1417, max 2522 characters. A 600-character split leaves 8 of them here and
sends 19 to `maintainer-review-reply`, and the tail it keeps — two comments
under 200 characters — is the status-line shape this recipe is capped for. The
guess was close enough to leave alone. What it does not license is reusing the
number elsewhere: the `pr-review-comment` boundary's population has a median of
312 over n=23, so 600 would route none of it.

### 2026-09-11 — the facts came back as written, and the opener was missing

Measured on live rows from 2026-08-28 to 2026-09-11 (agent verdicts): 51
rejections here, `self-improve.sh --peek --days 14` at 66% usable with kept=0,
scaffold=34, rewrote=17. 26 of the 51 reasons said the draft restated the stdin
facts back ("echoed all eleven stdin fact lines verbatim", "restated every
supplied fact back as one dense paragraph instead of curating"), the same
failure `maintainer-review-reply` showed on 37 of its 46 in the same window,
97 rejections and 63 restatements between them (#475). Rejected output here
ran p50 372 characters against a context p50 of 1337, so the cap was holding;
what came back inside it was the input's own lines rather than a sentence
about them. NO-FACT-DROP had been read as "keep the lines", which is why the
rule now says what survive means (the anchors, inside your sentence) and a
rule forbids copying the facts as written. `no_context_echo` is declared so a
draft that reproduces two or more stdin sentences (the unit is the sentence,
because the facts come back joined into one paragraph line) takes the #384
retry with the constraint named; a single quoted fact is left alone because
this recipe's cause sentence legitimately is one fact.

The other half of the same window: reasons asking for a thanks first, on a
recipe whose only opening rule was the flattery ban. An optional `opener`
input now takes the caller's own sentence verbatim ahead of the cause, exactly
as `signoff` takes the closer, and sits outside the two-sentence cap. The
model still writes no gratitude of its own. Re-measure after roughly ten
calls; the reason phrases to watch for disappearing are "restated" and "no
thanks opener".

### 2026-09-14 — the facts came back as questions

Measured on agent verdicts over 13-14 September, the first window after #475
(PR #478, merged 2026-09-11) declared `no_context_echo` here: n=21 (19 on
`pr-agent`), kept 0, scaffold 10, rewrote 11, usable 47%, against 88% on
`commit-message` (n=18) and 100% on `github-issue-body` (n=3) in the same
window. The restating reasons have thinned. What replaced them is a new tic
in 15 of the 38 rejection reasons across this recipe and
`maintainer-review-reply.md`: the model turns an established fact into a
question back at the contributor. The reasons, as skeletons rather than as
written so a later run does not mistake them for output: <turned an
established fact (key count 258) into a question to the contributor>, <asked
whether they had assigned themselves, asked to be told when ready>, <asked
the contributor to apply and verify the inline fix as a question>, <rendered
the asks as a numbered questionnaire>, and once <claimed I fixed the bug
inline (I only suggest)>. The reading: the recipe asks for exactly one
question or ask and, since #475, forbids restating the facts, and the model
resolves the two by rephrasing the facts as questions, which satisfies both
rules and drops the fact. The opener now arrives (today's drafts open with
the supplied thanks), so the 26 "no thanks opener" mentions in the window are
rows recorded before the callers passed `--var opener`; that fix is working
and is left alone.

Two named blocks, both pinned in `tests/test-prompts-library.sh` until #566.
STATED-NOT-ASKED: every fact is a statement, every question is one of the
caller's asks and nothing else is a question, outside the supplied opener,
sign-off and anchors. Its first wording called "the asks written out as a
questionnaire" a defect, which contradicted MULTI-ASK-SPLIT rule 2 (two or
more asks ARE a numbered list of questions) and was corrected in review of
PR #488: a numbered list of the caller's asks is correct, and the recorded
"<rendered the asks as a numbered questionnaire>" reason is read as facts
rendered as questions, not as the list shape itself. NO-CLAIMED-ACTION: the
reply reports what the maintainer did or will do only as the facts state it,
and a fix the facts only suggest is not reported as done. The frontmatter
also declares `max_context_ratio: 0.8` alongside `maintainer-review-reply.md`
(same review): rejected output here ran p50 372 characters against a context
p50 of 1337, so it is expected to fire rarely, and a context under 400
characters is exempt. Re-measure after roughly ten calls; the reason phrases
to watch for disappearing are "as a question" and "claimed".

### 2026-09-16 — the judgment became the caller's (#517)

The agent-framework spike graded 168 candidates blind and found the missing
verdict to be the single most frequent defect: about 30 candidates described
the change or the evidence and never said what the maintainer thought of it,
and no flow change (validator, schema, critic, three-round loop) moved it.
Every one of the 16 shipped `maintainer-reply` finals in the spike set opened
with a judgment sentence the maintainer had written. So the judgment is now a
required input, `lead`, placed verbatim after the recipient handle and the
opener, and the template stopped asking the model to derive one: its job is
the facts' anchors in a sentence or two of its own, and the caller's asks as
direct questions.

Measured on the spike's 18 cases through the wrapper against
`mlx-community/Qwen3.6-35B-A3B-8bit` (thinking off, temperature 0), with the
same lead supplied to both arms: the before arm is the previous template with
the lead prepended to stdin as a fact, so both see identical information and
only the template differs. Question-count mismatches against the shipped
finals fell from 13 of 16 to 2 of 16; the blind grade >= 4 share rose from 0
of 16 to 6 of 16 (38%), mean grade 2.50 to 3.38, with the stored drafts at 0
of 16 (2.12) under the same grader. The two remaining mismatches are the two
cases whose final does ask a question: the draft carried the ask as an
imperative in one and stated the deferral in the other. A rerun of the same
template returned 17 of 18 outputs byte-identical, so the numbers are the
template's, not sampling noise; a second round that added one clause to
ASK-OR-NONE moved three untouched cases from 4 to 3 (19%) while fixing one
mismatch, which is prompt sensitivity, and was reverted.

Two things the measurement forced into the template. ASK-OR-NONE: 13 of the
18 cases passed the ask as a description of the reply (<open with thanks,
verdict first, what held, the one ask (if any), under N words>), and every
wording that left the model to find an ask produced a question built from
whatever the facts stated, including a line marked "not an ask". With an
empty ask block the same case produced no question, so the pull was the
block's text, not the model; the first-match-wins block names the shape-only
case as NO question, the Ask block header says the same, and a closing line
after the blocks repeats it. And the sentence cap yields: a leftover fact was
being parked in the question slot because that sat outside the two-sentence
cap, so the cap is now "two as a rule, more when NO-FACT-DROP needs them", and
a fact never moves into a question to make room. An example ask skeleton
written as a fluent phrase leaked into one output as the reply's question
("Does the token survive a cold start of the app?"), the same failure as
2026-08-26, and was rewritten as nested angle brackets.

What the after arm still gets wrong, for the next pass: it sometimes opens
with a handle lifted from the facts when no recipient was passed, it restates
the PR's own header (number, author, head) in a few cases despite the
NO-FACT-DROP exemption, and "applied, N passed" in the facts comes back as "I
applied the fix", which reads as done in the PR. The issue's second goal, kept
from 1% to 10% and usable from 47% to 65% over the next 30 tracked calls, is
read with `metrics-summary.sh --days 30`.

### 2026-09-22 — no @-mention the caller did not ask for

`no_unbidden_mention: recipient` is declared here for the reason measured on
`maintainer-review-reply` the same day and recorded in that recipe's notes:
across both reply recipes, 42 of 82 rejected drafts carry an `@`-mention that
is not the supplied recipient, every one on a call that supplied none, while
0 of the 81 shipped replies carry one. The live failures were on the sibling
recipe, but the shape is shared — same optional `recipient` input, same prose
rule, same model — so the check is declared on both rather than waiting for
this one to post its own. A mention is the one defect that notifies a real
person before the maintainer sees the draft.

### 2026-10-08 — `verify: true` (#661)

The frontmatter gains `verify: true`, so `delegate.sh` runs the draft verifier on every call of this recipe and reports a flag on stderr and on the row (`docs/checks.md`). Nothing the model sees changes and the key is left out of `template_sha`, so the hash and the per-template history carry on unbroken and no replay applies. The #660 read-out behind the choice of recipes is in `docs/verify.md`.
