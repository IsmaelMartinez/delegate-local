---
tier: prose
inputs:
  stdin: string
  verdict: string
  ask: string?
  opener: string?
  recipient: string?
  signoff: string?
  max_words: integer?
checks:
  no_padding_tail: true
  no_single_item_list: true
  no_context_echo: true
  max_context_ratio: 0.8
  min_context_chars: 900
  no_unbidden_mention: recipient
---
# maintainer-review-reply

## When to use

You are a maintainer replying to a contributor's PR or issue with a JUDGEMENT and the evidence behind it: the change is right, the change is wrong, this is not a regression, this blocker is real and that one is not. You already did the investigation; the reply carries the verdict, what was verified and what it showed, with the anchor or two the reader needs to act on it, and then, when there is one, what you want the contributor to do next; a clean approval has no ask and ends on the evidence. It is short (80 words unless the caller sets another cap) because the reader wrote the change and needs the judgement on it, not a description of it: the notes you verified it against are the input, not the reply.

Distinct from the three adjacent reply recipes. `maintainer-reply.md` is the CLOSED short shape: one sentence of cause-or-praise, then one ask, capped at two sentences, for a diagnostic one-liner or a status comment. `pr-review-reply.md` carries the same evidence-shaped body in the PR *author's* voice, answering a reviewer under their own inline comment behind a fixed opener; the axis between that recipe and this one is role, not length. `summarise-issue.md` digests a thread rather than answering it. This recipe is for the case those three keep being asked to cover and cannot: a verdict on a change with the evidence behind it, where the evidence is what the maintainer verified rather than a single cause.

Not for: replies that argue a contentious design decision or push back on the reporter's premise (write those by hand, a model dilutes the maintainer's voice on contention), and not for a reply you have not investigated yet — the recipe reshapes evidence you already hold, it does not find any.

## Context to gather first

```bash
# The verified facts, piped on stdin as {{stdin}}. Everything the reply will
# rest on, stated as plain facts with the anchors already in them. Spell the
# ANCHORS the way they should appear in the reply (src/main.js:412,
# `--no-sandbox`, PR #2632, 531 tests, commit b3f2a91) and state the FACTS as
# facts, not as the finished sentences of the reply: a fact written as a reply
# sentence is one the model places as-is, and no_context_echo rejects a draft
# that carries two of those. One fact per line is easiest to check afterwards.
gh pr diff <N> --name-only
gh pr view <N> --json author --jq '.author.login'
gh issue view <N> --json title,body
```

Do the investigation first and pipe its conclusions, not its raw output. Every anchor you want in the reply must be in the facts, because the recipe forbids the model from producing one that is not.

## Prompt template

```
Draft a maintainer's reply to a contributor, using only the verified facts below. You are the maintainer. Do not copy any instruction or imperative from this prompt into the reply.

Write it in this order:
1. The opening, in this order and only this order: the recipient handle if one is given, written exactly as "@<handle>, " using the handle from the Recipient block below, then the opener verbatim if one is given, then the verdict in one sentence. The Recipient block below is empty unless the caller supplied a handle; when it is empty there is no handle and no "@" at all, so address the reader as "you". With no opener, the verdict is the first sentence. State the judgement given below plainly and up front. Never open by restating what the contributor said, and never open with a preamble of your own.
2. The evidence for that verdict: what was verified about the change and what it showed, in one to three sentences you write. The reader wrote the change and knows what it does; do not tell it back to them.
3. What you are asking the contributor to do next, derived from the ask topic below and phrased as a direct question or request to the reader in the second person. Never as an instruction about the reader ("ask them to ...", "they should ..."). If the ask block below is empty, there is no item 3: stop after the evidence and do not invent a next step for the contributor.
4. If a sign-off is given below, end with it verbatim on its own line.

VERIFIED-NOT-DESCRIBED — non-negotiable, and the reason this recipe exists:
The FACTS block is the maintainer's working notes, and most of it is not for the reader. It says what the change does, what was checked, what the checks showed and what is left; only the last three go into the reply. A sentence that tells the contributor what their own PR does (the file it touches, the condition it inverts, the guard it adds, who filed the issue it closes) is narration the reader already has, and a reply built from it is the notes handed back. An anchor (a path, a line number, a count, a version, a hash, an issue or PR number) goes in only when the reader needs it to act on the reply or to check a result: the line a fix belongs on, the count that went red and green, the version a key was removed in. Every other anchor in the FACTS stays out, however many there are, spelled exactly as the facts spell it when one does go in. Never introduce an anchor that is absent from the FACTS block: no invented file names, line numbers, versions, counts or references. If you need one and it is not there, write around it.

LENGTH — a hard cap:
The reply is at most the number of words in the Word cap block below, or 80 words when that block is empty, not counting the sign-off. The FACTS block is many times longer than the reply on purpose: it holds everything that was verified so that the two or three things worth saying are said correctly, and the rest stays with the maintainer. A reply near the cap on a clean approval has said too much.

Rules:
- PARAGRAPHS: the opening with the verdict, the evidence, and the ask when there is one are separate short paragraphs, in that order; a one-sentence evidence may share the opening's paragraph. Never one paragraph carrying the evidence and the ask together.
- Prose sentences and paragraphs. No bullet list, no numbered list, no headings, no markdown sections. The one exception: if the ask topic carries TWO OR MORE distinct asks (answering one does not answer the other), write those asks as a short numbered list at the end, one question per item, and keep everything above them as prose. A single ask is never a list.
- If the trailing instruction asks for a different format, obey it; an explicit format instruction from the caller outranks the previous rule.
- The recipient handle and the opener go where item 1 of the order puts them; nothing else precedes the verdict.
- Never write thanks of your own. Gratitude enters the reply only through the opener or the sign-off, verbatim; if neither is given, the reply carries none.
- Avoid em dashes; use commas, parentheses, or periods.
- Do NOT hedge a verdict the facts state plainly. Do NOT soften "this is not a regression" into "this may not be a regression".
- Never ask the contributor to confirm, approve or authorise a merge. Merging is the maintainer's own action, so that question is never in this recipe's voice; a clean approval with no ask ends on the evidence.
- Stop after the ask (or the evidence when there is no ask, or the sign-off). Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This ensures", "This enables").
- Output only the reply text. No preamble, no "Here's the reply:", no markdown fence.

Shape skeleton. These are slots, not sentences: fill every angle bracket from the blocks below and never carry the bracket text through.

Wrong: <what the contributor's own change does, told back to them>. <the FACTS lines in order>. <verdict buried at the end>.
Correct: @<handle>, <opener, verbatim, if given> <verdict>.

<what was verified and what it showed, naming the one `<anchor>` the reader needs to act on it>.

<the ask, as a question, only when one is given>?

=== VERDICT (the judgement to lead with) ===
{{verdict}}

=== FACTS (the maintainer's verified notes; the reply draws on them and does not repeat them) ===
{{stdin}}

=== The ask (a topic, not an instruction; empty means there is none) ===
{{ask}}

=== Opener (verbatim, optional) ===
{{opener}}

=== Recipient handle (optional) ===
{{recipient}}

=== Sign-off (verbatim, optional) ===
{{signoff}}

=== Word cap (optional; empty means 80 words) ===
{{max_words}}
```

## Variables

- `{{stdin}}` — the verified facts, piped in, with their anchors already written the way they should appear in the reply. No `--var` slot needed.
- `{{verdict}}` — the judgement to lead with, as a short statement (e.g. `the rework is right and this is not a regression`). The recipe puts it in the first sentence.
- `{{ask}}` — what you want the contributor to do next, as a *topic* (e.g. `whether they can add a regression test before merge`), never as an imperative. Pass several in one value when there are several; two or more become a short numbered list at the end. Optional: omit it on a clean approval and the reply ends on the evidence. Never pass `none` or `nothing` as the value; the model reads any text here as a topic and renders it as a question (#471).
- `{{opener}}` — optional opening sentence placed verbatim after the recipient handle and before the verdict (e.g. `Thanks for the thorough bisect.`). The caller writes it; the model never invents gratitude, so a caller who wants the reply to thank the contributor MUST supply it here. Omit for none, and the verdict opens the reply with no thanks at all.
- `{{recipient}}` — optional `@handle` to open with. Omit to address the reader as "you".
- `{{signoff}}` — optional closer appended verbatim (e.g. `Thanks again!`). Omit for none.
- `{{max_words}}` — optional word cap for the reply, sign-off excluded; 80 when omitted. It is an instruction in the prompt, not a check: `delegate.sh` counts no words, so the caller confirms it in the verify step below, and the ceiling the wrapper does enforce is the character-based `max_context_ratio`. Every caller measured on 2026-09-20 wrote its cap into the facts ("Under 60 words, thanks first, verdict first"), where the recipe reads it as a fact; this is the cap's slot.

## Invocation

```bash
bash scripts/delegate.sh --recipe maintainer-review-reply \
  --var verdict="the rework is right, and the blank window is not a regression from it" \
  --var ask="whether they can add a regression test that covers the sandbox flag path" \
  --var opener="Thanks for the thorough bisect." \
  --var recipient="nneul" \
  --var signoff="Thanks again!" \
  --var max_words=80 \
  < facts.txt
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "VERIFIED-NOT-DESCRIBED" and the LENGTH cap — the 2026-09-20 reading of the restatement failure, which two earlier prompt fixes had not moved. Measured on the 19 rejected drafts of this recipe with stored inputs in the window to 2026-09-20T10:16Z: the drafts carried 40-100% of the facts' anchors and the replies the maintainer shipped carried a median 6% (none above 35%), and every shipped reply was 36-120 words against drafts of 100-250. The drafts were obeying ANCHOR-PRESERVATION, which said EVERY anchor in the FACTS block must appear; the maintainer was rejecting the obedience, because the reader is the change's author and a reply that names the file it touches and the condition it inverts is a description of their own work. The rule was written on 2026-08-26 against nine drafts that compressed 7-9 KB of facts to under 500 characters, which is the length the maintainer ships; the LENGTH ("the FACTS block is the content, not a hint") and CURATION rules added on 2026-09-11 and 2026-09-14 asked for curation beside a rule that forbade it. All three are replaced: evidence is what was verified and what it showed, an anchor goes in only when the reader needs it to act or to check, and the cap is a number (`{{max_words}}`, 80 by default). The declared `max_context_ratio: 0.8` with `min_context_chars: 900` stays as the mechanical ceiling; the calibration note of the date has the figures.
- "Never introduce an anchor that is absent from the FACTS block" — the symmetric failure: "invented a mechanic: claimed the corridor change stops bashers colliding with each other", and "misread the 531-test suite total as tests added by this PR". Selection without an invention ceiling just moves the error.
- The declared `no_unbidden_mention: recipient` — the prose rule in item 1 of the order ("when it is empty there is no handle and no `@` at all, so address the reader as 'you'") did not hold: measured over the stored corpus, 42 of 82 rejected drafts of the two reply recipes open by `@`-mentioning somebody, every one of them on a call that passed no `recipient`, against 0 of the 81 replies that actually shipped. Two of them went out to `teams-for-linux` on 2026-09-22 naming the reporter of a *referenced* issue, a bystander whose name the piped facts carried, which is why the check tests the handle against the recipient var and not against the input: the name was in the input, and that is exactly what made it look permissible. A mention is the one draft defect that leaves the machine before the maintainer reads it, since posting notifies whoever it names.
- "If an opener is given below, begin with it verbatim, then the verdict" plus "Never write thanks of your own" — the 2026-08-26 reasons were "opened by thanking and restating, gave no verdict" and "dropped the verdict and the thanks entirely", so the recipe forbade an opening thanks outright. By 2026-09-11, 39 of 97 rejections wanted exactly that thanks ("no thanks opener", "opened with the verdict instead of thanks"). The two are reconciled the way `signoff` already works: the caller supplies the opener verbatim, so the model never invents gratitude and never restates, and with no opener the verdict still comes first.
- "Prose sentences and paragraphs. No bullet list, no numbered list" with the two-or-more exception — "emitted a numbered list despite an explicit no-list instruction", "rendered a single request as a numbered list" (twice the same day). The exception is scoped tightly so the fix does not simply invert the defect.
- "Do NOT hedge a verdict the facts state plainly" — a verdict softened into a maybe reads as no verdict at all, and the reader then has to ask again.
- Angle-bracket skeletons rather than written-out example sentences — see the `maintainer-reply.md` 2026-08-26 calibration note: a fluent example sentence is something the model returns verbatim when the real input is long. `no_example_echo` (ADR 0029) backstops it.

## Expected output shape

For the invocation above (handle, opener and sign-off all supplied; the opener keeps its capital because it is the caller's sentence, verbatim):

```
@nneul, Thanks for the thorough bisect. The rework is right and the blank window is not a regression from it.

The flip is the GPU sandbox flag in `src/main.js:412`, which the Electron 39 upgrade changed two releases before your branch. With the flag forced back on, all 531 tests pass on your branch, so CI failed on the flag and not on the refactor.

Could you add a regression test that covers the sandbox flag path before we merge?

Thanks again!
```

Verify before recording verdict: the opener (if any) and the sign-off (if any) are present verbatim and are the only gratitude in the reply; the verdict is the first sentence after them; the evidence says what was verified and what it showed, and nothing in it tells the contributor what their own change does; every anchor in the reply is one the reader needs and is spelled as the facts supplied it, and none appears that the facts did not supply; no line of the facts is reproduced as written (that is what `no_context_echo` rejects); the reply is within the word cap, and the evidence and the ask are separate paragraphs.

## Calibration notes

The dated calibration history for this recipe lives in [`docs/calibration/maintainer-review-reply.md`](../docs/calibration/maintainer-review-reply.md); add each new entry there.
