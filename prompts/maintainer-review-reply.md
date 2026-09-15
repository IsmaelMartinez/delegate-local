---
tier: prose
inputs:
  stdin: string
  verdict: string
  ask: string?
  opener: string?
  recipient: string?
  signoff: string?
checks:
  no_padding_tail: true
  no_single_item_list: true
  no_context_echo: true
  max_context_ratio: 0.8
---
# maintainer-review-reply

## When to use

You are a maintainer replying to a contributor's PR or issue with a JUDGEMENT and the evidence behind it: the change is right, the change is wrong, this is not a regression, this blocker is real and that one is not. You already did the investigation, so the reply has to carry the anchors it rests on — file paths, line references, commit hashes, issue and PR numbers, measured counts — and then, when there is one, say what you want the contributor to do next; a clean approval has no ask and ends on the evidence.

Distinct from the three adjacent reply recipes. `maintainer-reply.md` is the CLOSED short shape: one sentence of cause-or-praise, then one ask, capped at two sentences, for a diagnostic one-liner or a status comment. `pr-review-reply.md` carries the same evidence-shaped body in the PR *author's* voice, answering a reviewer under their own inline comment behind a fixed opener; the axis between that recipe and this one is role, not length. `summarise-issue.md` digests a thread rather than answering it. This recipe is for the case those three keep being asked to cover and cannot: a substantive reply whose length is set by how much evidence there is.

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
1. The opening, in this order and only this order: the recipient handle if one is given ("@{{recipient}}, "), then the opener verbatim if one is given, then the verdict in one sentence. With no handle, address the reader as "you"; with no opener, the verdict is the first sentence. State the judgement given below plainly and up front. Never open by restating what the contributor said, and never open with a preamble of your own.
2. The evidence for that verdict, in flowing prose sentences you write. This is the body of the reply and its length is set by how much evidence there is.
3. What you are asking the contributor to do next, derived from the ask topic below and phrased as a direct question or request to the reader in the second person. Never as an instruction about the reader ("ask them to ...", "they should ..."). If the ask block below is empty, there is no item 3: stop after the evidence and do not invent a next step for the contributor.
4. If a sign-off is given below, end with it verbatim on its own line.

ANCHOR-PRESERVATION — non-negotiable, and the reason this recipe exists:
An anchor is any of these appearing in the FACTS block: a path or filename, a `backticked` span, a commit hash, an issue or PR number, a version, or a measured count. EVERY anchor in the FACTS block must appear in the reply, spelled exactly as the facts spell it, inside sentences you write. Preserve the anchors, never the sentences: do not copy a line of the FACTS block into the reply. The anchors are the evidence; a reply that states the verdict without them is worthless to the reader, who cannot check it, and a reply made of the FACTS block's own lines is the input handed back, which the reader already had.
You may NOT introduce an anchor that is absent from the FACTS block. No invented file names, line numbers, versions, counts, or issue references. If you need one and it is not there, write around it.

LENGTH — read this before deciding how long the reply is:
The FACTS block is the content of the reply, not a hint about it. Do not compress it to a sentence or two. Match the reply to the evidence: a handful of facts is a short paragraph, a dozen is two or three, and either way the reply runs well under the FACTS block's own length, because a sentence of yours that joins two facts and drops their framing is shorter than the two facts were. Brevity that drops an anchor is one failure; a reply the length of the FACTS block, built from its lines, is the other. Curate: order the facts by what supports the verdict, join the ones that belong together, and drop framing that was written for you rather than for the reader.

Rules:
- CURATION: the reply carries the anchors (paths, line references, numbers, hashes, issue and PR numbers) and states the judgement; it does not carry the facts' sentences. On a fact list of more than a few lines it runs well under the facts' length: a reply as long as its facts has curated nothing, however its sentences are worded.
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

Wrong: <restates what the contributor wrote>. <the FACTS lines copied in order>. <verdict buried at the end>.
Correct: @<handle>, <opener, verbatim, if given> <verdict>. <evidence sentence of your own naming `<anchor>` and <anchor>>. <second evidence sentence>. <the ask, as a question, only when one is given>?

=== VERDICT (the judgement to lead with) ===
{{verdict}}

=== FACTS (verified; every anchor here must survive into the reply, inside your own sentences) ===
{{stdin}}

=== The ask (a topic, not an instruction; empty means there is none) ===
{{ask}}

=== Opener (verbatim, optional) ===
{{opener}}

=== Recipient handle (optional) ===
{{recipient}}

=== Sign-off (verbatim, optional) ===
{{signoff}}
```

## Variables

- `{{stdin}}` — the verified facts, piped in, with their anchors already written the way they should appear in the reply. No `--var` slot needed.
- `{{verdict}}` — the judgement to lead with, as a short statement (e.g. `the rework is right and this is not a regression`). The recipe puts it in the first sentence.
- `{{ask}}` — what you want the contributor to do next, as a *topic* (e.g. `whether they can add a regression test before merge`), never as an imperative. Pass several in one value when there are several; two or more become a short numbered list at the end. Optional: omit it on a clean approval and the reply ends on the evidence. Never pass `none` or `nothing` as the value; the model reads any text here as a topic and renders it as a question (#471).
- `{{opener}}` — optional opening sentence placed verbatim after the recipient handle and before the verdict (e.g. `Thanks for the thorough bisect.`). The caller writes it; the model never invents gratitude, so a caller who wants the reply to thank the contributor MUST supply it here. Omit for none, and the verdict opens the reply with no thanks at all.
- `{{recipient}}` — optional `@handle` to open with. Omit to address the reader as "you".
- `{{signoff}}` — optional closer appended verbatim (e.g. `Thanks again!`). Omit for none.

## Invocation

```bash
bash scripts/delegate.sh --recipe maintainer-review-reply \
  --var verdict="the rework is right, and the blank window is not a regression from it" \
  --var ask="whether they can add a regression test that covers the sandbox flag path" \
  --var opener="Thanks for the thorough bisect." \
  --var recipient="nneul" \
  --var signoff="Thanks again!" \
  < facts.txt
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "ANCHOR-PRESERVATION" — the dominant 2026-08-26 failure, measured across nine rejected `maintainer-reply` drafts on `pr-agent` and `teams-for-linux`: "dropped all verified specifics (file:line anchors, the 4-step pin-removal experiment and its exact outputs)", "dropped every measured fact from the context", "dropped the null-element finding and the thanks entirely". Inputs of 7-9 KB came back as 96 to 470 characters. Naming the anchor classes explicitly is what the generic "do not drop facts" phrasing failed to convey. Reworded 2026-09-11 so that preservation means the anchors inside new sentences and never the supplied sentences themselves: the original "the reply IS the evidence" line was read as licence to return the FACTS block wholesale (see the calibration note of that date), and `no_context_echo` now rejects a draft that copies two or more of its lines.
- "You may NOT introduce an anchor that is absent from the FACTS block" — the symmetric failure: "invented a mechanic: claimed the corridor change stops bashers colliding with each other", and "misread the 531-test suite total as tests added by this PR". Preservation without an invention ceiling just moves the error.
- "LENGTH — the FACTS block is the content, not a hint" — the prose tier treats a long input as something to summarise. Every adjacent recipe caps length; this one has to say the opposite out loud, or the model applies the cap it has seen everywhere else. The "built from its lines" clause and the "Curate" sentence were added 2026-09-11 because, said alone, "do not compress" had produced the mirror failure: a reply the same length as its input, made of the input.
- "CURATION" plus the declared `max_context_ratio: 0.8` — the 2026-09-14 reading of the same failure after that rewording: the 16 rejected drafts in the window were still the size of their input (1172 characters out for 981 in, 557 for 560, 940 for 899), and the #384 retry, carrying "do not copy sentences of the supplied facts", came back the same size, because `no_context_echo` measures echo and its notice says nothing about length. The ceiling is a check rather than a prose rule: an unconditional "shorter than the FACTS block" was tried first and withdrawn in review, since it contradicted LENGTH, cannot be met on a three-line fact list once opener, verdict, anchors, ask and sign-off are all mandatory, and did not discriminate (three of the sixteen were already shorter and still echoing). The check fails when the output is at least 0.8 of the context by characters and the context is at least 400 characters (`min_context_chars`), so a short fact list is exempt, and it carries its own retry constraint in `scripts/delegate.sh`.
- "If an opener is given below, begin with it verbatim, then the verdict" plus "Never write thanks of your own" — the 2026-08-26 reasons were "opened by thanking and restating, gave no verdict" and "dropped the verdict and the thanks entirely", so the recipe forbade an opening thanks outright. By 2026-09-11, 39 of 97 rejections wanted exactly that thanks ("no thanks opener", "opened with the verdict instead of thanks"). The two are reconciled the way `signoff` already works: the caller supplies the opener verbatim, so the model never invents gratitude and never restates, and with no opener the verdict still comes first.
- "Prose sentences and paragraphs. No bullet list, no numbered list" with the two-or-more exception — "emitted a numbered list despite an explicit no-list instruction", "rendered a single request as a numbered list" (twice the same day). The exception is scoped tightly so the fix does not simply invert the defect.
- "Do NOT hedge a verdict the facts state plainly" — a verdict softened into a maybe reads as no verdict at all, and the reader then has to ask again.
- Angle-bracket skeletons rather than written-out example sentences — see the `maintainer-reply.md` 2026-08-26 calibration note: a fluent example sentence is something the model returns verbatim when the real input is long. `no_example_echo` (ADR 0029) backstops it.

## Expected output shape

For the invocation above (handle, opener and sign-off all supplied; the opener keeps its capital because it is the caller's sentence, verbatim):

```
@nneul, Thanks for the thorough bisect. The rework is right and the blank window is not a regression from it. The flip is in the Electron 39 upgrade, specifically the GPU sandbox flag in `src/main.js:412`, which predates your change by two releases. I re-ran the suite on your branch with the flag forced back on and all 531 tests pass, so the failure you saw on CI is the flag and not the refactor.

Could you add a regression test that covers the sandbox flag path before we merge?

Thanks again!
```

Verify before recording verdict: the opener (if any) and the sign-off (if any) are present verbatim and are the only gratitude in the reply; the verdict is the first sentence after them; every anchor from the facts appears, spelled as supplied, inside sentences the model wrote; no line of the facts is reproduced as written (that is what `no_context_echo` rejects); on a fact list of more than a few lines the reply runs well under the facts' length (`max_context_ratio` says so when it does not); no anchor appears that the facts did not supply.

## Calibration notes

Drafted 2026-08-26 from a measured scope mismatch rather than from a coverage gap. `maintainer-reply` had absorbed 29 of 58 delegations in the rolling window at a 3% keep rate, and the rejection reasons were one shape repeated: the recipe's closed two-sentence cap meeting a workload of evidence-led review replies it explicitly excludes ("Not for: ... multi-paragraph technical explanations"). The drafting skills had started routing every maintainer comment through the one recipe that existed, so the cap ate the evidence every time.

The alternative considered and rejected was widening `maintainer-reply`. Its two-sentence cap is its identity — the shape that fits a diagnostic one-liner — and the library's design is one closed shape per recipe. Widening it would have cost the short shape without reliably buying the long one.

Un-validated on first commit: written from nine rejection reasons and the shipped replies that replaced those drafts, not yet from its own HIT. Expect the first ten calls to move it. The pairing to watch is `no_example_echo` against ANCHOR-PRESERVATION: this recipe's skeleton is deliberately anchor-free so that a leak of it is visibly bracketed rather than a plausible fabrication.

### 2026-08-26 (later) — no_single_item_list declared before the first call

This recipe carries the same rule as `maintainer-reply.md` ("A single ask is
never a list") and inherits its history: there the rule survived two rewordings
and had to become a deterministic check. Declaring `no_single_item_list` here
now, at n=0 calls, costs one frontmatter line and stops the identical defect
being re-discovered from scratch on a recipe that already knows about it.

### Tier choice

Prose tier. The task is reshaping supplied facts into a maintainer's voice; the facts are passive content to preserve and order, not reasoning targets. Same discriminator as `maintainer-reply.md`. If a future measurement shows anchor preservation failing on the prose tier specifically, the reasoning tier is the escalation to try before rewriting the guards again.

### 2026-08-26 (later) — the routing became mechanical

Still `n=0` calls at the end of the day it was created, with pointers in
SKILL.md and in both scope paragraphs of `maintainer-reply.md`. The reason turned
out to be structural rather than persuasive: `gh pr review --body`, the most
common way a maintainer posts a judgement, was not a boundary in
`scripts/delegate-boundary-hook.sh` at all. It cleared the pre-filter, matched no
branch, and produced no opportunity row and no reminder, so nothing ever named
this recipe at the moment of drafting. The hook now classifies it (and a `POST`
to `.../pulls/<n>/reviews`) as `pr-review-body` and names this recipe with its
`verdict` and `ask` vars.

`gh pr comment` still routes to `maintainer-reply`, pinned by its own assertion,
so the fix cannot quietly swallow the closed short shape. Re-measure by whether
this recipe starts taking calls at all; anything about its keep rate needs
roughly ten of them first.

### 2026-08-27 — the second routing fix

`#440` made `gh pr review --body` a boundary that names this recipe; it has
taken no traffic since, because that is not the command the sessions on this
machine actually use. `gh pr comment` is, and it was pinned to
`maintainer-reply`. The hook now routes it by the size of the body being
posted, so a long evidence-led comment names this recipe.

Still `n=0` calls. Two mechanical routing fixes are now in place and the honest
status is that neither has been measured. Re-measure by whether this recipe
starts taking calls at all; anything about its keep rate needs roughly ten of
them first.

### 2026-08-27 — what the routing threshold was measured against

The 600-character split that sends a comment here rather than to
`maintainer-reply` was a guess when it shipped. The population it routes was
measured the same day — 27 maintainer-authored issue comments on this repo,
min 8, p25 573, median 950, p75 1417, max 2522 — and the split sends 19 of the
27 to this recipe. That is the traffic
this recipe has been waiting for, so the next reading of its keep rate has a
denominator to work with. Still `n=0` calls at the time of writing.

### 2026-09-11 — the reply was the input handed back, and the opener rule was fighting the verdicts

The traffic arrived and the recipe failed it in one shape. Measured on live
rows from 2026-08-28 to 2026-09-11 (agent verdicts, `--source agent`): 46
rejections here and 51 on `maintainer-reply`, 97 in all, with
`self-improve.sh --peek --days 14` reporting usable rates of 71% here
(kept=0, scaffold=33, rewrote=13) and 66% there (kept=0, scaffold=34,
rewrote=17). Not one draft in the window was kept as-is on either recipe. 63
of the 97 rejection reasons said the draft restated the supplied context back:
"restated the whole stdin context verbatim as three long paragraphs", "copied
the context brief sentence for sentence, including internal framing", "echoed
all eleven stdin fact lines verbatim". The size signature says the same thing
without any reading: rejected output here ran p50 1637 characters against a
context p50 of 1627. The draft was its input (#475).

That is the 2026-08-26 failure inverted. The ANCHOR-PRESERVATION note above
was written from nine drafts that had compressed 7-9 KB of facts to under 500
characters, and "the reply IS the evidence" fixed that by being read
literally: the model now returned the evidence wholesale instead of curating
it. No check caught it because `no_example_echo` compares against the
pre-substitution template only, on purpose, so every one of the 46 rejections
here carried `checks_failed=0` and none took the #384 retry.

Three changes. ANCHOR-PRESERVATION and LENGTH now say what preservation means:
the anchors (paths, line references, numbers, hashes, PR and issue numbers)
carried inside sentences the model writes, never the supplied sentences
themselves, and a reply the length of the FACTS block built from its lines is
named as the second failure beside brevity. `no_context_echo` is declared in
the frontmatter and fails a draft that reproduces two or more sentences of the
piped context verbatim (both sides split into sentences first, then the same
normalisation and 40-character floor as `no_example_echo`), so the retry now
fires with the constraint named; one echoed sentence is left alone because
quoting a single fact back is exactly the anchor-carrying the recipe asks for.
The unit is the sentence and not the line because the rejected drafts are one
paragraph line each (the 2026-09-10T20:00:01Z row: context 1687 characters,
body one 1687-character line), so a whole-line compare matched none of them.
And the opener: 39 of the 97 reasons wanted a thanks first ("no thanks
opener", "opened with the verdict instead of thanks") while the template said
"Do not open by thanking" twice, so the recipe's house shape and the verdicts
disagreed on every call that had one. Resolved the way `signoff` already
works: an optional `opener` input the caller supplies verbatim, placed after
the handle and before the verdict. The model still never invents gratitude,
and with no opener the verdict still comes first.

Re-measure after roughly ten calls each. The number to watch is the ratio of
output to context characters on rejected rows, which should drop well below
1.0, and whether `no_context_echo` appears in `checks_failed_names` at all: if
the retry clears it, the row shows `retried:true` with no failed check; if it
does not, the model cannot curate this input and the reply is hand-written.

### 2026-09-14 — the ceiling had to be stated relative to the input

Measured on agent verdicts over 13-14 September, the first window after #475
(PR #478, merged 2026-09-11) declared `no_context_echo` here: n=16, kept 0,
scaffold 0, rewrote 16, usable 0%. Every rejected draft was still the fact
sheet handed back, and the size pairs say so without any reading: 1172
characters out for 981 in, 557 for 560, 940 for 899. `no_context_echo` fired
on 7 of the 38 reply calls across this recipe and `maintainer-reply.md`, and
the #384 retry ran on 9 of them, so the check catches the failure; the second
generation came back the same size as the first every time, so the retry
notice ("do not copy sentences of the supplied facts into the answer") does
not change the output. The recipe set no length target: LENGTH named a reply the
length of the FACTS block as a failure but never said how long the reply
should be, and the rules said only that it carries the anchors and stops
after the ask.

The ceiling is a declared check, not a prose rule. A first cut said in the
Rules block that the reply is SHORTER than the FACTS block and put the same
sentence into the `no_context_echo` retry constraint; review of PR #488
withdrew both. The rule contradicted LENGTH ("a dozen facts is three or four
paragraphs"), cannot be met on a three-line fact list once the opener,
verdict, anchors, ask and sign-off are all mandatory, and does not
discriminate: 3 of the 16 rejected rows (557/560, 547/578, 318/329) were
already shorter than their input and still echoing. And `no_context_echo`
measures echo, so its notice cannot claim a length rule was broken. So
`max_context_ratio: 0.8` is declared in the frontmatter (ADR 0014 machinery:
counted in `checks_run`, named in `checks_failed_names`, retried once with
its own constraint), failing when the output is at least 0.8 of the context
by characters and the context is at least 400 characters
(`min_context_chars`, so a short fact list is exempt); the Rules block
carries a CURATION rule consistent with LENGTH instead, carry the anchors and
state the judgement, never the facts' sentences, and on a fact list of more
than a few lines run well under its length; and LENGTH itself now says the
reply runs well under the FACTS block whatever the paragraph count, since a
sentence that joins two facts and drops their framing is shorter than the
two facts were. The 16 rows carry one identical reason pasted 16 times at
11:00 on 2026-09-13, which is why `delegate-feedback.sh` now warns on a
reason repeated across delegations inside ten minutes; the figures above are
the size pairs, which do not depend on the reason text.

Re-measure after roughly ten calls. The number to watch is unchanged from
2026-09-11, the ratio of output to context characters on rejected rows, plus
two more: whether `max_context_ratio` appears in `checks_failed_names` after
the retry, and the second generation's size on rows with `retried:true`. If
the retry still returns the input's length, the model cannot curate this
input and the constraint sentence is not the lever.
