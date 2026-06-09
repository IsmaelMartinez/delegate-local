---
inputs:
  stdin: string
  ask: string
  recipient: string?
  signoff: string?
---
# maintainer-reply

## When to use

You are a project maintainer drafting a short outbound reply to a contributor or reporter — a PR-review comment, an issue status comment, or a diagnostic one-liner on a bug report — from facts you already have in hand. The desired shape is closed: one sentence of specific praise (for a contribution) or the confirmed cause (for a bug), then exactly one question or ask, then an optional warm sign-off. This is the shape that fit all three live cases in issue #283 (a PR review on teams-for-linux #2632, an issue status comment on #2621, a diagnostic one-liner on #2603).

Distinct from the two adjacent reply recipes: `pr-review-reply.md` is the PR *author* posting a one-line "Applied in `<hash>`" under a reviewer's inline comment, and `polish-reply.md` *tightens an existing multi-paragraph draft*. This recipe *drafts the maintainer's reply from scratch* in the maintainer's outbound voice.

Not for: replies that push back on the reporter's premise or argue a contentious design decision (write those by hand — a model dilutes the maintainer's voice on contention), multi-paragraph technical explanations (the recipe deliberately caps the body at two sentences), or any reply where the "ask" is really several asks (call the recipe once per distinct reply, one ask each).

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

Rules:
- Two body sentences maximum: the praise-or-cause sentence, then the question. No third sentence, no preamble sentence.
- Do NOT repeat any instruction verbatim. If the ask topic is written as an imperative, rephrase it as a question to the reader.
- No filler flattery ("Great work!", "Awesome!", "Thanks for this!", "Nice job!"). Specific praise that names the actual contribution is allowed and is the point; generic praise is not.
- If a recipient handle is given, open with it ("@{{recipient}}, ..."); otherwise address the reader as "you".
- Avoid em dashes; use commas, parentheses, or periods.
- Stop after the question (or the sign-off). Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This ensures", "This enables"). End on the question mark, the sign-off, or a finite verb introducing new content.
- Output only the reply text. No preamble, no "Here's the reply:", no markdown fence.

Example shape (do not copy literally — the input below is different):

Wrong: The regression is in the date parser, and ask the reporter to confirm whether it happens on older inputs.
Correct: The regression is in the date parser. Could you confirm whether it also happens on older inputs?

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
      prose "Two sentences: state the cause, then ask the reader a direct question. Do not echo any instruction."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Do not copy any instruction or imperative from this prompt into the reply; phrase the ask as a question" — this is the live #283 instruction-echo failure: a freeform prompt that embedded the action as an imperative ("…and ask the reporter to check whether X") was echoed verbatim into prose-tier output (`qwen3.6:35b-a3b-q8_0` via MLX) as *"the drop is in Teams' MSAL, and ask the reporter to check whether…"*. Passing the ask as a topic (not an imperative) plus this guard is the fix that closed it on first retry in the original session.
- "Two body sentences maximum … No third sentence" — prose tier loves a closing-paraphrase sentence (see SKILL.md's anti-padding directive). The closed two-sentence shape (cause/praise, then the question) is the whole point of the recipe.
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

Verify before recording verdict: opens with the specific praise or the confirmed cause (not generic filler), the body is at most two sentences, the ask is a question addressed to the reader (no echoed imperative), the sign-off (if any) is preserved verbatim, no em dashes, no closing-paraphrase sentence, no preamble or markdown fence.

## Calibration notes

Drafted 2026-06-09 from issue #283, which filed this as a prompt-pattern coverage gap and a live data point for #277 (trigger rate is the binding constraint). The shape anchor is the three maintainer replies hand-drafted in a teams-for-linux session that day — a PR review on #2632, an issue status comment on #2621, and a diagnostic one-liner on #2603 — all of which fit the "one sentence of cause/praise, then one ask, optional warm sign-off" structure. The recipe exists so this recurring shape becomes a hard trigger (`--recipe maintainer-reply`) rather than a freeform judgement call, which simultaneously raises trigger rate and removes the instruction-echo failure mode #283 documented.

### 2026-06-09 dogfood: HIT, and the anti-echo guard reproduced-and-fixed the #283 failure

First-pass against `mlx-community/Qwen3.6-35B-A3B-8bit` (prose tier, MLX — the same backend/model that produced the original #283 instruction-echo MISS). The dogfood deliberately passed the ask as an *imperative* (`--var ask="ask the reporter to check whether the token survives a cold start of the app"`) to stress the guard, on the literal #283 cause statement. Output:

```
@nneul, the token drop is on Teams' side, in its MSAL cache, not in teams-for-linux itself. Could you check whether the token survives a cold start of the app?
Thanks again!
```

The model rephrased the imperative into a question (`Could you check whether…?`) instead of echoing `…and ask the reporter to check whether…` verbatim — the exact failure #283 reported, fixed on first attempt. Handle preserved, one cause sentence, one question, verbatim sign-off, no flattery, no padding tail, no preamble or fence. HIT, no edits needed (recorded via `delegate-feedback.sh`). This promotes the recipe from structural-starting-point to validated on the prose tier.

### Tier choice

Prose tier (`qwen3.6:35b-a3b-q8_0` by default). The task is drafting short prose from supplied facts; the facts are passive content the model reproduces and reshapes, not active reasoning targets. The discriminator is the same as `polish-reply.md`: this is prose shaping, not reasoning.
