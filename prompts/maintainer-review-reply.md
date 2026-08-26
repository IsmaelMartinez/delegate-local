---
tier: prose
inputs:
  stdin: string
  verdict: string
  ask: string
  recipient: string?
  signoff: string?
checks:
  no_padding_tail: true
  no_single_item_list: true
---
# maintainer-review-reply

## When to use

You are a maintainer replying to a contributor's PR or issue with a JUDGEMENT and the evidence behind it: the change is right, the change is wrong, this is not a regression, this blocker is real and that one is not. You already did the investigation, so the reply has to carry the anchors it rests on — file paths, line references, commit hashes, issue and PR numbers, measured counts — and then say what you want the contributor to do next.

Distinct from the three adjacent reply recipes. `maintainer-reply.md` is the CLOSED short shape: one sentence of cause-or-praise, then one ask, capped at two sentences, for a diagnostic one-liner or a status comment. `pr-review-reply.md` is the PR *author* posting "Applied in `<hash>`" under a reviewer's inline comment. `summarise-issue.md` digests a thread rather than answering it. This recipe is for the case those three keep being asked to cover and cannot: a substantive reply whose length is set by how much evidence there is.

Not for: replies that argue a contentious design decision or push back on the reporter's premise (write those by hand, a model dilutes the maintainer's voice on contention), and not for a reply you have not investigated yet — the recipe reshapes evidence you already hold, it does not find any.

## Context to gather first

```bash
# The verified facts, piped on stdin as {{stdin}}. Everything the reply will
# rest on, stated as plain facts with the anchors already in them. Anchors are
# what the recipe preserves, so write them the way they should appear:
#   src/main.js:412, `--no-sandbox`, PR #2632, 531 tests, commit b3f2a91.
# One fact per line is easiest to check afterwards.
gh pr diff <N> --name-only
gh pr view <N> --json author --jq '.author.login'
gh issue view <N> --json title,body
```

Do the investigation first and pipe its conclusions, not its raw output. Every anchor you want in the reply must be in the facts, because the recipe forbids the model from producing one that is not.

## Prompt template

```
Draft a maintainer's reply to a contributor, using only the verified facts below. You are the maintainer. Do not copy any instruction or imperative from this prompt into the reply.

Write it in this order:
1. The verdict, in one sentence, first. State the judgement given below plainly and up front. Do not open by thanking, do not open by restating what the contributor said, do not open with a preamble.
2. The evidence for that verdict, in flowing prose sentences. This is the body of the reply and its length is set by how much evidence there is.
3. What you are asking the contributor to do next, derived from the ask topic below and phrased as a direct question or request to the reader in the second person. Never as an instruction about the reader ("ask them to ...", "they should ...").
4. If a sign-off is given below, end with it verbatim on its own line.

ANCHOR-PRESERVATION — non-negotiable, and the reason this recipe exists:
An anchor is any of these appearing in the FACTS block: a path or filename, a `backticked` span, a commit hash, an issue or PR number, a version, or a measured count. EVERY anchor in the FACTS block must appear in the reply, spelled exactly as the facts spell it. The reply is the evidence; a reply that states the verdict without the anchors is worthless to the reader, who cannot check it.
You may NOT introduce an anchor that is absent from the FACTS block. No invented file names, line numbers, versions, counts, or issue references. If you need one and it is not there, write around it.

LENGTH — read this before deciding how long the reply is:
The FACTS block is the content of the reply, not a hint about it. Do not compress it to a sentence or two. Match the reply to the evidence: a handful of facts is a short paragraph, a dozen is three or four. Brevity that drops a fact is the failure this recipe exists to prevent, not the goal.

Rules:
- Prose sentences and paragraphs. No bullet list, no numbered list, no headings, no markdown sections. The one exception: if the ask topic carries TWO OR MORE distinct asks (answering one does not answer the other), write those asks as a short numbered list at the end, one question per item, and keep everything above them as prose. A single ask is never a list.
- If the trailing instruction asks for a different format, obey it; an explicit format instruction from the caller outranks the previous rule.
- If a recipient handle is given, open with it ("@{{recipient}}, ..."), still followed immediately by the verdict.
- Do not thank the contributor in the opening sentence. If thanks belong anywhere, they go after the verdict or in the sign-off.
- Avoid em dashes; use commas, parentheses, or periods.
- Do NOT hedge a verdict the facts state plainly. Do NOT soften "this is not a regression" into "this may not be a regression".
- Stop after the ask (or the sign-off). Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This ensures", "This enables").
- Output only the reply text. No preamble, no "Here's the reply:", no markdown fence.

Shape skeleton. These are slots, not sentences: fill every angle bracket from the blocks below and never carry the bracket text through.

Wrong: <opens by thanking and restating>. <verdict buried at the end, no anchors>.
Correct: @<handle>, <verdict>. <evidence sentence naming `<anchor>` and <anchor>>. <second evidence sentence>. <the ask, as a question>?

=== VERDICT (the judgement to lead with) ===
{{verdict}}

=== FACTS (verified; every anchor here must survive into the reply) ===
{{stdin}}

=== The ask (a topic, not an instruction) ===
{{ask}}

=== Recipient handle (optional) ===
{{recipient}}

=== Sign-off (verbatim, optional) ===
{{signoff}}
```

## Variables

- `{{stdin}}` — the verified facts, piped in, with their anchors already written the way they should appear in the reply. No `--var` slot needed.
- `{{verdict}}` — the judgement to lead with, as a short statement (e.g. `the rework is right and this is not a regression`). The recipe puts it in the first sentence.
- `{{ask}}` — what you want the contributor to do next, as a *topic* (e.g. `whether they can add a regression test before merge`), never as an imperative. Pass several in one value when there are several; two or more become a short numbered list at the end.
- `{{recipient}}` — optional `@handle` to open with. Omit to address the reader as "you".
- `{{signoff}}` — optional closer appended verbatim (e.g. `Thanks again!`). Omit for none.

## Invocation

```bash
bash scripts/delegate.sh --recipe maintainer-review-reply \
  --var verdict="the rework is right, and the blank window is not a regression from it" \
  --var ask="whether they can add a regression test that covers the sandbox flag path" \
  --var recipient="nneul" \
  --var signoff="Thanks again!" \
  < facts.txt
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "ANCHOR-PRESERVATION" — the dominant 2026-08-26 failure, measured across nine rejected `maintainer-reply` drafts on `pr-agent` and `teams-for-linux`: "dropped all verified specifics (file:line anchors, the 4-step pin-removal experiment and its exact outputs)", "dropped every measured fact from the context", "dropped the null-element finding and the thanks entirely". Inputs of 7-9 KB came back as 96 to 470 characters. Naming the anchor classes explicitly, and stating that the reply IS the evidence, is what the generic "do not drop facts" phrasing failed to convey.
- "You may NOT introduce an anchor that is absent from the FACTS block" — the symmetric failure: "invented a mechanic: claimed the corridor change stops bashers colliding with each other", and "misread the 531-test suite total as tests added by this PR". Preservation without an invention ceiling just moves the error.
- "LENGTH — the FACTS block is the content, not a hint" — the prose tier treats a long input as something to summarise. Every adjacent recipe caps length; this one has to say the opposite out loud, or the model applies the cap it has seen everywhere else.
- "The verdict, in one sentence, first" plus "Do not thank the contributor in the opening sentence" — "opened by thanking and restating, gave no verdict", "dropped the verdict and the thanks entirely, and collapsed the whole reply into three bare imperative questions". Verdict-first is the house shape and the model reverts to a support-desk opener without it.
- "Prose sentences and paragraphs. No bullet list, no numbered list" with the two-or-more exception — "emitted a numbered list despite an explicit no-list instruction", "rendered a single request as a numbered list" (twice the same day). The exception is scoped tightly so the fix does not simply invert the defect.
- "Do NOT hedge a verdict the facts state plainly" — a verdict softened into a maybe reads as no verdict at all, and the reader then has to ask again.
- Angle-bracket skeletons rather than written-out example sentences — see the `maintainer-reply.md` 2026-08-26 calibration note: a fluent example sentence is something the model returns verbatim when the real input is long. `no_example_echo` (ADR 0029) backstops it.

## Expected output shape

```
@nneul, the rework is right and the blank window is not a regression from it. The flip is in the Electron 39 upgrade, specifically the GPU sandbox flag in `src/main.js:412`, which predates your change by two releases. I re-ran the suite on your branch with the flag forced back on and all 531 tests pass, so the failure you saw on CI is the flag and not the refactor.

Could you add a regression test that covers the sandbox flag path before we merge?

Thanks again!
```

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
