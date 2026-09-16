---
tier: prose
inputs:
  stdin: string
  lead: string
  ask: string?
  opener: string?
  recipient: string?
  signoff: string?
checks:
  no_padding_tail: true
  no_single_item_list: true
  no_context_echo: true
  max_context_ratio: 0.8
  no_fact_as_question: ask
---
# maintainer-reply

## When to use

You are a project maintainer drafting a short outbound reply to a contributor or reporter — a PR-review comment, an issue status comment, or a diagnostic one-liner on a bug report — from facts you already have in hand and a judgment you have already made. The desired shape is closed: the lead (your own sentence of specific praise, or your verdict, passed verbatim as `--var lead=...`), then one or two sentences carrying the facts, then the ask(s) as direct questions, then an optional warm sign-off. The model writes the middle only: it carries the anchors of the piped facts and phrases the asks; it never decides what the reply thinks of the contribution. This is the shape that fit all three live cases in issue #283 (a PR review on teams-for-linux #2632, an issue status comment on #2621, a diagnostic one-liner on #2603), and since 2026-09-16 (#517) the judgment sentence is the caller's, because every shipped reply in the spike set opened with one the maintainer wrote and the model's own never survived.

Distinct from the two adjacent reply recipes: `pr-review-reply.md` is the PR *author* answering a reviewer under their own inline comment, with a fixed opener and then the evidence, and `maintainer-review-reply.md` leads with a verdict and then carries the evidence behind it, at whatever length that evidence needs. This recipe *drafts the maintainer's reply from scratch* in the maintainer's outbound voice, in the closed short shape.

Multi-ask replies are in scope as of 2026-08-03: pass the several asks in one `--var ask=...` and the MULTI-ASK-SPLIT rule keeps each as its own numbered question instead of merging them. This replaced the earlier "call the recipe once per distinct reply" guidance, which callers did not follow — 13 consecutive multi-ask teams-for-linux replies were rewritten because the two-sentence cap compressed several asks into one run-on sentence.

Not for: replies that push back on the reporter's premise or argue a contentious design decision (write those by hand — a model dilutes the maintainer's voice on contention), or multi-paragraph technical explanations (the recipe keeps the model's own prose to a sentence or two even when the ask list is long). A reply whose length is set by how much evidence it has to carry — file paths, hashes, issue refs, measured counts — belongs to `maintainer-review-reply.md`. Reaching for this recipe and then having to expand the answer back into paragraphs is the most common way it gets rejected, so check that first.

## Context to gather first

```bash
# The lead — write it yourself, as the sentence the reply opens with: the
# specific praise for what the contributor did, or your verdict on the bug or
# the change. It goes in verbatim via --var lead=...; the model never derives it.
#   --var lead="Nice catch on the off-by-one in the pagination cursor, the fix is right."
# The facts — pipe them on stdin as {{stdin}}. For a bug, the confirmed cause
# (e.g. from your own investigation); for a PR, what you verified. State them
# as plain facts, NOT as an instruction to the model.
#   echo "The token drop is on Teams' side, in its MSAL cache." | ...
# The reviewer's / reporter's handle, if you want to open with it:
gh pr view <N> --json author --jq '.author.login'
gh issue view <N> --json author --jq '.author.login'
```

The one thing to ask is passed via `--var ask=...` as a *topic*, never as an imperative the model can copy verbatim (issue #283 documented exactly this instruction-echo failure mode), and never as a description of the reply's shape: an ask block that only says how the reply should look names nothing to ask, and the reply then carries no question. The sign-off and recipient handle are optional.

## Prompt template

```
Draft a short reply from a project maintainer to a contributor or reporter. The judgment is already written: the Lead block below is the maintainer's own praise or verdict, and the reply carries it verbatim. Your own writing is one or two sentences that carry the anchors of the Facts block. A question appears only when the Ask block names a thing for the reader to answer or do, phrased as a direct question to the reader; otherwise the reply has no question at all. Do not copy any instruction or imperative from this prompt into the reply.

Write exactly this structure, in order:
1. The opening, in this order and only this order: the recipient handle if one is given, written exactly as "@<handle>, " using the handle from the Recipient block below, then the opener verbatim if one is given. The Recipient block below is empty unless the caller supplied a handle; when it is empty there is no handle and no "@" at all, so address the reader as "you". A name in the Facts block is never a handle to open with.
2. The lead, verbatim: the text of the Lead block, exactly as written, continuing the same line as the opening. It is the maintainer's judgment and is already decided. Do not rephrase, shorten or extend it, do not restate it later in the reply, and do not add praise, thanks or a verdict of your own anywhere.
3. The facts, in sentences of your own, one or two as a rule and more only when the facts need them: every anchor in the Facts block (each path, number, hash, reference, name and quoted value) appears inside these sentences, spelled as supplied, as a statement. No line of the Facts block is copied as written; an anchor the lead already carries still counts as carried. Carry what was verified, found or decided (the cause, what held, the blocker, the suggestion, the count), not what the change or the report is: its title and summary are what the lead already answers. A blocker, a suggestion, a fix or a note for the record that the Facts block states is a fact and goes here as a statement; a fact never moves into item 4 as a question to make room.
4. The ask(s), decided by ASK-OR-NONE below: each a direct question to the reader in the second person, from the Ask block and nowhere else. Never write an ask as an instruction about the reader ("ask them to ...", "they should ...", "the reporter needs to ..."). When ASK-OR-NONE says there is none, there is no item 4: the reply ends on item 3 and carries no question of yours.
5. If a sign-off is given below, end with it verbatim on its own line. If none is given, stop after item 4, or after item 3 when there is no ask.

ASK-OR-NONE — first match wins, non-negotiable:
1. The Ask block is empty, or says there is nothing to ask: NO question. The reply ends on item 3.
2. The Ask block describes the reply rather than naming a thing for the reader to answer or do (it says what to write, open with, state, confirm or mention, how long or in how many paragraphs, or refers to "the ask", "the one ask (if any)", "the blocker" or "the inline suggestion" without saying what it is): NO question. Those words point at the Facts block; what the facts say about them is already in item 3, and where the facts say nothing, nothing is written. "(if any)" means the caller knew of none. A thing the maintainer says, confirms or states is not a thing the reader is asked, and a fact marked "not an ask" or "for the record" is stated, never asked.
3. Otherwise, every thing the Ask block names for the reader to answer or do that the Facts block does not already state is one question, under MULTI-ASK-SPLIT.
Ask block that names nothing to ask, so NO question: <write the reply for PR N: thanks for what the author did, verdict first, what held, the one ask (if any), mention the inline suggestion, under N words>
Ask block that names a thing to ask, so one question: <whether <a thing only the reader can tell you>>

MULTI-ASK-SPLIT — first match wins, non-negotiable:
Count the distinct asks the Ask block names. Two asks are distinct when answering one does not answer the other.
1. If there is exactly ONE ask, item 4 is one question, written as a sentence.
2. If there are TWO OR MORE, do NOT merge them into one sentence and do NOT drop any of them. Keep items 1 to 3 as they are, then write each ask as its own numbered item, each a direct question to the reader. The sentence cap in the rules below is lifted for the ask list only; everything else still applies.
3. Never join distinct asks with "and" into a single run-on question. Mutually exclusive asks in particular must stay separate, because merging them produces a question the reader cannot answer.
4. A SINGLE ask is never a numbered list, however many clauses, conditions or qualifiers it carries. One ask means one question, written as a sentence. Splitting one ask across numbered items is the same defect as merging several into one.
5. If the Ask block or the trailing instruction asks for prose, or says not to use a list, obey it: keep the asks as separate sentences rather than numbering them. An explicit format instruction from the caller outranks this rule.
Wrong: <the lead>. <the facts>. Could you confirm <ask one> and also send <ask two> and say whether <ask three>?
Correct: <the lead>. <the facts>.
1. <ask one, as a question>?
2. <ask two, as a question>?
3. <ask three, as a question>?

NO-FACT-DROP — non-negotiable:
Every fact supplied on stdin that bears on the diagnosis must survive into the reply. Survive means its anchors (the path, the number, the reference, the name) appear inside the sentences you write, spelled as supplied; it never means a line of the facts copied into the reply as written. The sentence cap is a ceiling on padding, never a licence to discard a supplied fact. If the facts do not fit the shape, add a sentence — do not delete a fact. If a fact is supplied that you cannot place, keep it in the facts sentences rather than dropping it. Exempt, because the reply is posted on the PR or issue itself: that PR's or issue's own number, its author, its head hash and whose review this is are where the reply goes, not facts to carry; every other PR, issue, commit, file, count and person the facts name is an anchor.

STATED-NOT-ASKED — non-negotiable:
Every fact in the Facts block goes into the reply as a statement, never as a question. Every question in the reply is one of the caller's asks from the Ask block, and nothing else is a question: one question for one ask, and under MULTI-ASK-SPLIT a numbered list of the caller's asks, one question each, is correct. Outside the supplied opener, lead, sign-off and anchors, no other question mark appears. A supplied fact rephrased as a question to the reader is that fact dropped and an ask invented.
Wrong: <a supplied fact, as a question to the reader>? <the ask>?
Correct: <the same fact, as a statement>. <the ask>?

NO-CLAIMED-ACTION — non-negotiable:
The reply says what the maintainer did or will do only as the Facts block states it. Never claim a fix, a merge, a change, a test run or an assignment the facts do not state; a fix the facts only suggest is offered as a suggestion, never reported as done.
Wrong: <an action the facts only suggest, reported as done>.
Correct: <the same action, offered as the suggestion the facts make>.

NO-MERGE-ASK — non-negotiable:
Never ask the contributor to confirm, approve or authorise a merge, and never ask them to confirm a result the Facts block already states. Merging is the maintainer's own action and a stated fact needs no confirmation; a clean approval with no ask ends on the facts sentences.

Rules:
- Two sentences of your own for the facts as a rule, then the question when ASK-OR-NONE gives one. No preamble sentence, no closing sentence. A third or fourth facts sentence is right when NO-FACT-DROP needs it; a question is never the place for a fact that did not fit. (The ask list under MULTI-ASK-SPLIT rule 2, the opening, the lead and the sign-off are not your sentences and never count.)
- Do NOT repeat any instruction verbatim. If the Ask block is written as an imperative, rephrase it as a question to the reader.
- Do NOT copy the facts back as they were written. The reply carries their anchors in your own sentences, not their lines.
- No praise, thanks or verdict of your own, and no filler ("Great work!", "Awesome!", "Thanks for this!", "Nice job!"). The lead is the praise or the verdict and it is already written; gratitude enters the reply only through the opener, the lead or the sign-off, verbatim.
- The recipient handle, the opener and the lead go where items 1 and 2 of the structure put them; nothing precedes them and nothing sits between them.
- Avoid em dashes; use commas, parentheses, or periods.
- Stop after the question, or after the facts when there is none (or after the sign-off). Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This ensures", "This enables"). End on the question mark, the sign-off, or a finite verb introducing new content.
- Output only the reply text. No preamble, no "Here's the reply:", no markdown fence.

Example shape. These are skeletons, not sentences: the angle-bracket slots are
filled from the blocks below, never carried through as written.

Wrong: <the lead, reworded>. <a line of the Facts block, as written>. <a fact, as a question to the reader>?
Correct, when the Ask block names a thing to ask: <the lead, verbatim>. <the facts' anchors, in a sentence of your own>. <the ask, as a question to the reader>?
Correct, when it does not: <the lead, verbatim>. <the facts' anchors, in a sentence of your own>.

=== Recipient handle (optional) ===
{{recipient}}

=== Opener (verbatim, optional) ===
{{opener}}

=== Lead (verbatim: the praise or the verdict, already written by the maintainer) ===
{{lead}}

=== Facts (carried as anchors inside your own sentences, never as lines) ===
{{stdin}}

=== Ask (what the reader is asked; empty, "none", or a description of the reply means the reply has NO question, see ASK-OR-NONE) ===
{{ask}}

=== Sign-off (verbatim, optional) ===
{{signoff}}

Before writing, decide from ASK-OR-NONE whether the reply has a question. When it has none, your last sentence states a fact and no question mark appears in any sentence of yours.
```

## Variables

- `{{lead}}` — required (#517). The judgment sentence, written by the calling agent and placed verbatim after the recipient handle and the opener, before everything else: the specific praise for what the contributor did (`Nice catch on the off-by-one in the pagination cursor, the fix is right.`) or the verdict on the bug or the change (`Not a regression, the flip is the sandbox flag.`). The model copies it and never derives one of its own; a call without it exits 2 naming `lead`.
- `{{stdin}}` — the facts, piped in: the confirmed cause (for a bug reply) or what you verified about the contribution (for a PR reply). State as plain facts, never as an instruction. The model carries their anchors in one or two sentences of its own. No `--var` slot needed.
- `{{ask}}` — the thing(s) to ask the reader, as a *topic* (e.g. `whether the token survives a cold start`), not an imperative (`ask them to check ...`) and not a description of the reply's shape. The recipe phrases each as a question to the reader. Optional: omit it on a clean approval or a pure status note and the reply ends on the facts; that is the documented path. Before #517 any text here, `none` included, came back as a question (#471); ASK-OR-NONE now reads a block that says there is nothing to ask, or only describes the reply, as no question, measured on the spike case that passed `none` and on the 13 that passed a shape description, so a caller who does pass such a value is not handed a question either; a real topic is still rendered as a question.
- `{{opener}}` — optional opening sentence placed verbatim after the recipient handle and before the lead (e.g. `Thanks for the clear report.`). The caller writes it; the model never invents gratitude, so a caller who wants the reply to thank the contributor MUST supply it here or in the lead. Omit for none, and the lead opens the reply.
- `{{recipient}}` — optional `@handle` of the contributor/reporter to open with. Omit to address the reader as "you".
- `{{signoff}}` — optional warm closer to append verbatim (e.g. `Thanks again!`, `I hope this helps!`). Omit for no sign-off.

## Invocation

```bash
echo "The token drop is on Teams' side, in its MSAL cache, not in teams-for-linux." \
  | bash scripts/delegate.sh --recipe maintainer-reply \
      --var lead="Your trace was right, and this one is not ours to fix." \
      --var ask="whether the token survives a cold start of the app" \
      --var opener="Thanks for the clear report." \
      --var recipient="nneul" \
      --var signoff="Thanks again!" \
      "After the opener and the lead, one sentence carrying the cause, then ask the reader a direct question. Do not echo any instruction."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "The lead, verbatim … do not add praise, thanks or a verdict of your own anywhere" (#517) — blind grading of 168 candidates on the 2026-09-16 agent-framework spike found the missing verdict to be the single most frequent defect: about 30 candidates described the change or the evidence and never said what the maintainer thought of it, and no flow change (validator, schema, critic, three-round loop) moved it. Every one of the 16 shipped `maintainer-reply` finals in that set opened with a judgment sentence the maintainer wrote. The model is a weak judge and a fair carrier, so the judgment became a required input and the template stopped asking for it.
- "If the Ask block … only describes the reply's shape … there is no item 4" (#517) — 13 of the 18 spike cases passed the ask as a description of the reply ("open with thanks, verdict first, what held, the one ask, under 110 words"), and the model answered that block with a question about whatever the facts stated, which is the fact-as-question defect by another route. Naming the shape-only case tells the model there is nothing to ask rather than leaving it to find something.
- "Do not copy any instruction or imperative from this prompt into the reply; phrase the ask as a question" — this is the live #283 instruction-echo failure: a freeform prompt that embedded the action as an imperative ("…and ask the reporter to check whether X") was echoed verbatim into prose-tier output (`qwen3.6:35b-a3b-q8_0` via MLX) as *"the drop is in Teams' MSAL, and ask the reporter to check whether…"*. Passing the ask as a topic (not an imperative) plus this guard is the fix that closed it on first retry in the original session.
- "Two sentences of your own maximum … No third sentence" — prose tier loves a closing-paraphrase sentence (see SKILL.md's anti-padding directive). The closed shape (lead, one or two facts sentences, then the question) is the whole point of the recipe for the single-ask case.
- "MULTI-ASK-SPLIT" — measured 2026-08-03: keep-rate on `teams-for-linux` was 0 of 13 over the preceding 30 days against 92% on single-ask work, with the same model, backend and an unedited template. The rewrite reasons were one pattern: "merged two mutually exclusive asks into one sentence", "compressed four items into one run-on ask", "dropped all substance from the three asks", "fixed wrong conditional chaining of asks". The old scope note told callers to invoke once per ask; they did not, so the cap silently ate the asks. The rule makes multi-ask a first-class shape instead of an unenforced instruction.
- "NO-FACT-DROP" — same measurement window: "two-sentence cap squeezed out the PR #2424 cross-run dedup fact from stdin; kept only the commitable_code_suggestions fact, losing the strategic link". The cap was being read as licence to discard supplied facts rather than to suppress padding; this states which of the two it is. The "Survive means its anchors" sentence and the "Do NOT copy the facts back" rule were added 2026-09-11 after 26 of 51 rejections in the window said the draft restated the stdin facts as written ("echoed all eleven stdin fact lines verbatim"); `no_context_echo` backstops both.
- "STATED-NOT-ASKED" — measured 2026-09-14, the first window after `no_context_echo` went live: 15 of 38 rejection reasons across this recipe and `maintainer-review-reply.md` said the model turned an established fact into a question back at the contributor (<turned the key count 258 into a question>, <asked whether they had assigned themselves>, <asked the contributor to apply and verify the inline fix as a question>). "Exactly one question or ask" plus "do not copy the facts back" was being resolved by rephrasing the facts as questions, which satisfies both rules and drops the fact. The block says which sentences carry a question mark: the caller's asks, so a numbered list of them under MULTI-ASK-SPLIT stays correct, and the verbatim slots (opener, sign-off, an anchor such as a URL) are exempt because they are not the model's sentences.
- "NO-CLAIMED-ACTION" — same window, once: <claimed I fixed the bug inline (I only suggest)>. A reply that reports an action the maintainer did not take is worse than a dropped fact, because the contributor acts on it; the block confines the maintainer's own actions to what the facts state.
- "then the opener verbatim if one is given" plus "gratitude enters the reply only through the opener, the lead or the sign-off, verbatim" — the same window had rejections asking for a thanks first, and the flattery rule was being read as a ban on any opener. Mirrors `signoff`: the caller supplies the gratitude verbatim, the model never invents it, and with no opener the lead still comes first.
- "No praise, thanks or verdict of your own, and no filler" — generic praise ("Great work!") doubles the reply length for no information and reads as boilerplate; since #517 the praise that earns its place is the caller's lead, and the model adds none.
- "If the Ask block is written as an imperative, rephrase it as a question" — the topic var is the most likely place a caller accidentally hands the model a copyable imperative; the guard makes the model transform it rather than echo it.
- "Output only the reply text. No preamble" — without it the model prefaces with "Here's the reply:" or wraps in a markdown fence.

## Expected output shape

For the invocation above (handle, opener, lead and sign-off all supplied). The facts sentence is a skeleton on purpose: it carries the anchors of the piped fact in a sentence of the model's own, and a written-out version here would be the piped fact restated, which is the shape `no_context_echo` rejects.

```
@nneul, Thanks for the clear report. Your trace was right, and this one is not ours to fix. <the cause, in a sentence of your own, carrying its anchors>. Could you <the ask, as a question>?

Thanks again!
```

With no opener, the lead opens the reply, then the facts sentence, then the ask:

```
<the lead, verbatim>. <the facts' anchors, in a sentence of your own>. <the ask, as a question>?
```

Multi-ask shape (MULTI-ASK-SPLIT), when the Ask block carries more than one distinct ask:

```
@nneul, <the lead, verbatim>. <the facts' anchors, in a sentence of your own>.
1. <ask one, as a question>?
2. <ask two, as a question>?
3. <ask three, as a question>?

Thanks again!
```

Verify before recording verdict: the opener (if any) and the lead are preserved verbatim, in that order, and are followed by the facts in one or two sentences of the model's own (not a stdin line copied as written, and no praise or verdict the model added), the ask is a question addressed to the reader (no echoed imperative) and the only question in the reply (no supplied fact turned into one, and no question at all when the Ask block named nothing to ask), the reply claims no fix, merge or change the facts did not state, the sign-off (if any) is preserved verbatim, no em dashes, no closing-paraphrase sentence, no preamble or markdown fence. On length: a single-ask reply is the lead plus at most two facts sentences plus the question; a multi-ask reply adds one numbered question per ask, and every ask supplied must appear — do NOT record a MISS on a multi-ask reply merely for its length, that is the MULTI-ASK-SPLIT shape working. Do record a MISS if distinct asks were merged into one question, or if a fact supplied on stdin is missing.

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

Two named blocks, both pinned in `tests/test-prompts-library.sh`.
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
