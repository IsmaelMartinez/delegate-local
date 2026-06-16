---
inputs:
  stdin: string
checks:
  no_padding_tail: true
---
# miss-theme-cluster

## When to use

You have a flat list of short failure reasons — the MISS reasons from the delegate-local metrics log, a column of QA defect notes, recurring error strings — and want them grouped into the few recurring themes they fall into, each named with one verbatim example. The output is flat prose naming 3-5 themes (most frequent first), one example quote per theme. This is the recipe that dogfoods the skill's own calibration loop: turning a rolling window of MISS reasons into the themes that should drive the next recipe iteration.

This sits at the edge of the skill's scope and stays on the right side of it by being closed: it groups the reasons you give it and quotes verbatim from them, rather than speculating about causes. It is NOT the open-ended "what patterns or loose ends do you see" prompt SKILL.md warns against — every theme must be supported by at least two of the supplied reasons and named with a verbatim quote, so the model summarises the input rather than reasoning beyond it.

Distinct from `bulk-classify.md`, which assigns each item to one category from a *fixed* set the caller supplies. Here the themes are not known in advance — the model induces them from the data — which is why the anti-invention and verbatim-quote guards are load-bearing. Not for: root-cause analysis (why each failure happened — that needs context the reasons alone do not carry), or proposing fixes (write those yourself from the themes).

## Context to gather first

```bash
# The reasons — pipe them on stdin as {{stdin}}, one short reason per line.
# For the delegate-local calibration use case, pull recent MISS reasons from
# the metrics log over a rolling window:
jq -r 'select(.source=="feedback" and .kept==false) | .reason // empty' \
  ~/.claude/skills/delegate-local/metrics.jsonl \
  | tail -40 > "$CLAUDE_JOB_DIR/tmp/miss-reasons.txt"
```

One reason per line. The recipe induces themes from the list, so the list should be the actual reason strings (verbatim), not a pre-summarised digest — pre-summarising defeats the verbatim-quote guard.

## Prompt template

```
Group the failure reasons below into 3-5 recurring themes. Each reason names a concrete failure shape. Induce the themes from the data; do not impose a taxonomy and do not invent a theme the reasons do not support. Fewer real themes is better than padding to reach five.

Rules:
- Output flat plain prose: 3-5 short sentences or very short paragraphs, no bullet lists, no headings, no markdown.
- Name the most frequent theme first, then the next, in descending frequency. For each theme give a one-sentence name of the shape, then quote ONE example reason for it. The quote MUST be copied character-for-character from a single line in the FAILURE REASONS block below — never from these instructions, this prompt, or any text outside the FAILURE REASONS block (you may truncate the tail of a long line to about 60 characters, but every quoted word must appear verbatim on one FAILURE REASONS line, and do not add punctuation such as a trailing comma inside the quote). If you cannot find a single FAILURE REASONS line that states the theme, name the theme without a quote rather than inventing or paraphrasing one. Never assemble a quote from words across multiple lines.
- Every theme MUST be supported by at least two of the input reasons. A failure shape seen only once is a one-off, not a theme — do not promote it to a theme. You may note one or two notable one-offs in a single closing sentence if they matter.
- Group by the failure shape, not by which recipe or source each reason came from.
- Do not invent a failure shape, a cause, or a fix that is not present in the input. Describe what the reasons say, not why they happened.
- Output ONLY the themes prose. No preamble, no header, no markdown fence.
- Stop after the substantive content. Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This suggests", "This indicates"). Do NOT end with restating phrases ("going forward", "moving forward", "across the board"). End on a finite verb introducing new content, or stop.
Wrong: The dominant theme is output-shape drift, showing the model still struggles with formatting overall.
Correct: The dominant theme is output-shape drift, for example "bulleted output when prose was wanted"; it is the most frequent and the most mechanical to guard against.

=== FAILURE REASONS (one per line — the only source material) ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the flat list of failure reasons, one per line, piped in verbatim (not pre-summarised). The model induces the themes from this list and quotes from it. No `--var` slot needed.

## Invocation

```bash
jq -r 'select(.source=="feedback" and .kept==false) | .reason // empty' \
  ~/.claude/skills/delegate-local/metrics.jsonl | tail -40 \
  | bash scripts/delegate.sh --recipe miss-theme-cluster \
      reasoning "3-5 themes, most frequent first, one verbatim quote each. Every theme needs at least two supporting reasons. Flat prose, no bullets, invent nothing."
```

After the call, verify (see Expected output shape) and record the verdict:

```bash
bash scripts/delegate-feedback.sh hit   # or: miss "<reason>"
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Induce the themes from the data; do not impose a taxonomy and do not invent a theme the reasons do not support" — this is the guard that keeps the recipe inside the skill's scope. An unconstrained "find the themes" prompt is the open-ended shape SKILL.md says produces hallucination; tying every theme to the supplied reasons turns it into a closed summarisation task.
- "Every theme MUST be supported by at least two of the input reasons ... a failure shape seen only once is a one-off, not a theme" — without a minimum-support rule the model promotes a single colourful reason to a headline theme, over-fitting to one data point. The two-reason floor is the load-bearing anti-over-fit guard.
- "quote ONE verbatim example reason ... do not paraphrase the example" — the verbatim quote is the auditable anchor that lets you check each theme against the input; a paraphrased example can drift into a claim the data does not make.
- "copied character-for-character from a single line in the FAILURE REASONS block — never from these instructions, this prompt, or any text outside the FAILURE REASONS block" — a 2026-06-16 cross-model probe on `qwq:32b` quoted the call's trailing prompt ("match the recipe's expected shape exactly") as if it were a theme example. Scoping the quote source to the FAILURE REASONS block closes that instruction-echo (the same failure family `maintainer-reply.md` fights with its anti-instruction-echo guard from issue #283). The same probe surfaced a quote with a trailing comma placed inside the quote marks on synthetic input, so the rule also forbids adding punctuation inside the quote.
- "Do not invent a failure shape, a cause, or a fix ... Describe what the reasons say, not why they happened" — the reasons name *what* failed, not *why*; the prose tier will helpfully invent causes ("because the context window was too small") that the input does not state. The describe-not-explain rule keeps the output grounded.
- "Output ONLY the themes prose ... Stop after the substantive content" — the anti-padding block; a theme summary is especially prone to an "overall this suggests..." closing flourish. The Wrong/Correct anchor uses content drawn from this skill's own domain (output-shape drift) because the recipe's real caller is this skill's calibration loop, but it is phrased so it cannot be copied as a real theme.

The `reasoning` tier (not `prose`) is intentional: the load-bearing work is inducing the grouping and counting support per theme, which is classification over the set, not prose generation. The output prose is short; the cost is in the grouping, which is reasoning-tier territory (the same argument `ci-log-triage.md` makes).

## Expected output shape

```
The most frequent theme is output-shape drift, where the model returns bullets
or headings when flat prose was wanted (for example "bulleted output when prose
was wanted"); it shows up across several recipes. The second theme is padding
tails, closing sentences that restate the point ("trailing 'ensuring...' clause
on a commit body"). A third, smaller theme is verbatim-identifier drift, where
PR numbers or quoted excerpts get paraphrased. One notable one-off was a JSON
fence that broke parsing.
```

Verify before recording verdict: 3-5 themes, most frequent first; each theme has a verbatim quote that appears in the input (grep-check if unsure); no theme rests on a single reason; the prose describes what the reasons say without inventing causes or fixes; flat prose, no bullets or headings; no preamble, no markdown fence, no closing flourish.

## Calibration notes

Graduated 2026-06-16 from observed recurring bare-delegation usage rather than from a recorded HIT. A 2026-06-15 analysis of the session-transcript corpus found "group these MISS reasons into recurring themes" recurring as a bare `prose`/`reasoning` delegation with no recipe — a self-referential shape, since the recurring caller is this skill's own calibration loop turning a rolling window of MISS reasons into the themes that drive the next recipe iteration. It fell back to the bare tier each time, with the anti-invention and verbatim-quote directives re-specified by hand.

This is the most borderline of the four recipes graduated in this change, because theme-induction sits near the open-ended-prompt boundary SKILL.md warns against. It is kept on the closed side deliberately: the at-least-two-reasons floor, the verbatim-quote-per-theme requirement, and the describe-not-explain rule together constrain the model to summarising the supplied reasons rather than reasoning beyond them. The prompt skeleton is lifted from the actual bare prompts used, which had already converged on these guards: "Group them into 3-5 recurring themes ... Do not invent themes the data does not support", "quote ONE verbatim example reason per theme (truncate to 60 chars)", "Group by theme not by recipe", and the full anti-padding tail.

### 2026-06-16 — first dogfood: MISS → fix → HIT

First dogfood against `deepseek-r1:32b` (reasoning tier, Ollama) on the last 30 real MISS reasons from the metrics log. The themes induced were all genuine and grounded (output-shape drift, anti-padding violations, hallucination / fact conflation), but a grep-check of the example quotes against the input — the recipe's own verify step — caught the predicted weakness: one of three quotes (`"bulleted output when prose was wanted"`) was paraphrased rather than copied verbatim from any supplied line. Because verbatim-quote auditability is the recipe's load-bearing property, this was recorded as a MISS via `delegate-feedback.sh --source agent` even though the themes themselves were correct.

The fix sharpened the verbatim-quote rule with an explicit omit-rather-than-invent escape hatch: the quote must be copied character-for-character from a single input line, assembling a quote from words across multiple lines is forbidden, and a theme with no verbatim-quotable line is named without a quote rather than approximated. Re-run on the same window produced five quoted spans, all five grep-verified verbatim-present in the input, with the themes and one-offs intact. Recorded HIT.

This confirmed the borderline-but-in-scope reading: the model did not invent themes or causes (which would have meant the shape is over the scope line and should route to Claude), it paraphrased an example, which the verbatim-only escape-hatch directive fixed. The verify step (grep-check every quote against the input before recording a verdict) is mandatory for this recipe, not optional — it is the only auditable check that the verbatim guard held. If a future dogfood shows the model inventing a *theme* or a *cause* despite the guards, that is the signal this shape is over the scope line; note that finding here rather than loosening the guards to force a HIT.

### 2026-06-16 — cross-model effectiveness probe + anti-instruction-quote hardening

A two-model effectiveness probe ran the recipe on the primary reasoning model (`deepseek-r1:32b`) and a second model (`qwq:32b`) over both real MISS-reason data and a synthetic defect list. On real data the primary model was clean (themes grounded, all quotes verbatim). Two off-path failures reproduced deterministically: on synthetic data the primary model placed a trailing comma inside a quote (breaking strict verbatim), and on the weaker `qwq` model it quoted the call's trailing prompt ("match the recipe's expected shape exactly") as if it were a theme example. The quote-source-scoping rule (quote only from the FAILURE REASONS block, never from these instructions, and no added punctuation inside the quote) was added in response. The probe confirmed the recipe is reliable for its designed case (primary reasoning model, real MISS-reason data) and that its verbatim-quote guard is the fragile axis off that path — consistent with this recipe's borderline status.
