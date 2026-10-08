---
tier: prose
verify: true
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
  no_unbidden_mention: recipient
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

The dated calibration history for this recipe lives in [`docs/calibration/maintainer-reply.md`](../docs/calibration/maintainer-reply.md); add each new entry there.
