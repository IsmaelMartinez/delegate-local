# polish-reply

## When to use

The user has drafted a multi-paragraph reply on a GitHub/GitLab issue or PR and wants a tightened version with project voice intact. Inputs are typically 1–3 paragraphs of maintainer prose with embedded `file:line` citations, a warm conversational opener, the substantive answer, and a closing acknowledgement; the desired output is a slightly more concise version of the same reply that preserves every technical claim, the opener, and the closer verbatim. Distinct from `pr-review-reply.md`, which produces a one-sentence reply after applying or declining an inline review comment — `polish-reply` is the multi-paragraph polish shape.

Not for: drafting the reply from scratch (the recipe assumes a draft exists), replies that need to push back on the reporter's premise (rewrite by hand), or replies whose value is the maintainer's specific voice on a contentious decision (a model polish dilutes the voice even with guards).

## Context to gather first

```bash
# The draft reply body — pipe it on stdin as {{stdin}}.
# Typical sources: a markdown file with the draft, or the body of a
# reply being composed in the issue-review skill's working buffer:
cat /tmp/reply-draft.md
```

The recipe takes the draft via `{{stdin}}` and emits the polished version on stdout. No per-call `--var` slots are needed beyond stdin.

## Prompt template

```
Tighten this maintainer reply for concision while preserving voice and every technical claim.

RULES:
- Preserve every technical claim, file path, and file:line citation verbatim. Do not paraphrase a `path/to/file.ext:42` reference into prose; copy it as-is.
- Do not add new technical claims or change facts. Only tighten what is already there.
- If the input begins with a warm conversational opener (greeting, acknowledgement, "Hi @user", "Hey @user", "Thanks @user", "Fun question"), preserve it verbatim. Do not compress greetings.
- If the input ends with a closer ("I hope helps!", "Thanks again!", "Hope that helps!", "Let me know"), preserve it verbatim. Do not compress closers.
- Avoid em dashes; use commas, parentheses, or periods.
- Stop after the substantive content. Do NOT add a trailing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling", "highlighting", "underscoring"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "To summarise", "This ensures", "This enables", "This guarantees", "This delivers"). Do NOT end with restating phrases ("this distinction is crucial", "this is crucial", "this is essential", "across diverse environments", "closes the gap", "closing the gap", "closes the loop", "closing the loop", "going forward", "moving forward"). End on a finite verb introducing new content, or stop.
- Output the revised reply only. No preamble, no "Here's the revised reply:", no markdown fence around the output.

Example shape (do not copy literally — the input below is different):

Wrong: @nneul, yes, this is on our side
Correct: Hey @nneul, fun one and the short answer is yes, this is on our side, not hooked into something untouchable.

=== Draft reply ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the draft reply body, piped in. No `--var` slot needed.

## Invocation

```bash
cat /tmp/reply-draft.md | bash scripts/delegate.sh --recipe polish-reply \
  prose "Preserve the opener, the closer, and every technical claim verbatim. Tighten only the middle."
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Preserve every technical claim, file path, and file:line citation verbatim" — without it the prose tier paraphrases `app/screenSharing/index.ts:42` into prose ("the screen-sharing module around line 42"), which strips the reader's ability to click through to the cited line. Most expensive miss-mode because it makes the polish a net loss versus the original draft.
- "If the input begins with a warm conversational opener … preserve it verbatim. Do not compress greetings." — the 2026-05-11 MISS in issue #97 was exactly this: a draft opening `"Hey @nneul, fun one and the short answer is yes, this is on our side, not hooked into something untouchable."` was compressed to `"@nneul, yes, this is on our side"`, stripping the human cue that signals warmth. Symmetric to SKILL.md's anti-padding directive — preserve-opener is the opening-end counterpart.
- "If the input ends with a closer … preserve it verbatim. Do not compress closers." — observed on the same maintainer's reply pattern: project voice consistently ends with `I hope helps!` or `Thanks again!`, and the model treats both as removable filler when concision is asked for.
- "Avoid em dashes; use commas, parentheses, or periods" — em dashes are not in the maintainer's voice on this project (the surrounding draft uses commas and parens), and the prose tier defaults to em-dash punctuation when asked for "tightening".
- "Stop after the content sentences. Do not add a closing sentence that restates the point." — the standard anti-padding directive from SKILL.md; the prose tier appends a final paraphrase of the substantive answer ("This distinction is important for understanding …") that adds nothing.
- "Output the revised reply only. No preamble" — without it the model prefaces with "Here's the revised reply:" or wraps in a markdown code fence, both of which the caller has to strip by hand.

## Expected output shape

```
Hey @nneul, fun one and the short answer is yes, this is on our side, not hooked into something untouchable. The screen picker is fully ours: `app/screenSharing/` builds the selection dialog as a `WebContentsView` mounted on the main window, and the source list comes from Electron's `desktopCapturer.getSources({ types: ["window", "screen"] })`.

The three options to address this are: (1) ..., (2) ..., (3) ...

I hope helps!
```

Verify before recording verdict: opener preserved verbatim, every `path:line` citation preserved verbatim, closer preserved verbatim, no em dashes, no closing-paraphrase sentence after the substantive content, no preamble or markdown fence.

## Calibration notes

Initial recipe drafted 2026-05-11 from the MISS reported in issue #97. The original session used the prompt `Tighten this maintainer reply for concision. RULES: (1) Preserve every technical claim and file path verbatim. (2) Do not add new technical claims or change facts. (3) Keep the three numbered options. (4) Keep the closing 'I hope helps!'. (5) Avoid em dashes; use commas, parentheses, or periods. (6) Stop after the content sentences. Do not add a closing sentence that restates the point. Output the revised reply only.` against `qwen3.6:35b-a3b-q8_0` (prose tier) on a 5829-char draft body. The technical claims, file paths, three numbered options, and the `I hope helps!` closer were all preserved correctly; the failure was opening-tone compression: the warm hook `"Hey @nneul, fun one and the short answer is yes, …"` was tightened to `"@nneul, yes, this is on our side"`, stripping the conversational cue carrying the project's voice. The agent had to discard the polished output and keep the original draft, making the delegation a net loss for that call.

### Working prompt not yet verified

The recipe ships the four canonical guards (preserve-technical-claims, preserve-opener, preserve-closer, anti-padding) as the structural starting point per issue #97's suggested fix, but the working-prompt experiment that would confirm the preserve-opener guard actually closes the MISS was not run in the original session (the parent task was the issue review itself, not skill calibration). The next caller who reaches this recipe should run it against the issue #97 draft (or an equivalent multi-paragraph maintainer reply) and record HIT or MISS — a confirmed HIT cycle promotes this recipe from "structural starting point" to "validated", same path the other recipes in this directory took. If the preserve-opener guard alone is not enough, expect the next iteration to add a verbatim one-shot example of the desired opening shape.

### Tier choice

Prose tier (`qwen3.6:35b-a3b-q8_0` by default). The task is rewriting prose for concision; the technical claims to preserve are passive content the model reproduces, not active reasoning targets. Reasoning tier would be over-spending and would not improve the preserve-opener failure mode (which is a prose-tier prior on what "concision" looks like, not a reasoning failure).
