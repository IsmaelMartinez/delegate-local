---
inputs:
  stdin: string
  sections: string
checks:
  no_padding_tail: true
---
# github-issue-body

## When to use

You are drafting the body of a *new* GitHub issue from facts you already have in hand — a bug report write-up, a `prompt-pattern` filing, a feature proposal, a coverage-gap note — where the caller can supply both the ordered set of markdown section headings the body should use and the source facts to fill them. The output is the issue body markdown only (no title), ready to pass to `gh issue create --body-file`.

Distinct from the two adjacent recipes: `pr-description.md` drafts a PR body from a *diff* (it has code changes as input; on a cold 35B MLX host its first call needs `DELEGATE_PREFLIGHT_TIMEOUT=90` to absorb cold-load — see ADR 0027), and `maintainer-reply.md` drafts a short *comment* under an existing issue or PR. This recipe drafts a structured multi-section issue body from facts, with no diff and no length cap beyond the per-section content.

Not for: issues whose body is one or two sentences (open them by hand or with `maintainer-reply`'s shape), or issues that require multi-file reasoning to write (a model handed only the facts cannot reconstruct repo context it was not given — gather the facts yourself first, then delegate the prose).

## Context to gather first

```bash
# 1. The facts — pipe them on stdin as {{stdin}}. Author a scratch file with the
#    raw material: the observation, the verbatim error/output excerpts, the
#    proposed fix, the issue/PR numbers involved. State them as plain facts.
cat > "$CLAUDE_JOB_DIR/tmp/issue-facts.md" <<'EOF'
<the observation, with verbatim excerpts and identifiers — invent nothing here>
EOF

# 2. The section plan — the exact ordered markdown headings the body should use,
#    each with a one-line note on what it should contain. This is the caller's
#    structure decision, passed via --var sections=...
cat > "$CLAUDE_JOB_DIR/tmp/issue-sections.md" <<'EOF'
## Summary
(content: one paragraph framing the problem)
## Why this matters
(content: one paragraph on the impact)
## Suggested fix
(content: the proposed change, one paragraph per option)
EOF
```

The section plan is load-bearing: without an explicit heading list the prose tier invents its own structure (often a generic Background/Steps/Expected/Actual bug template) regardless of what the issue actually is. Each `##` line is the literal heading to reproduce; the `(content: ...)` line below it is a note describing what goes under that heading and must never appear in the output (keep the heading and its note on separate lines, never on one line — a combined `## Summary — one paragraph ...` line gets echoed whole into the heading).

## Prompt template

```
Draft a GitHub issue body in markdown from the facts below. Use exactly the section headings listed under SECTIONS, in that order, and put under each heading only the content its note describes. Do not invent facts, file paths, numbers, or sections not given below.

Rules:
- Each line under SECTIONS that begins with `#` is a markdown heading to reproduce VERBATIM, in the given order. Each line in parentheses is a note describing the content for the heading above it; it is guidance, NOT output. Never reproduce a parenthetical note, and never append it to the heading line.
Wrong heading: ## Summary (content: one paragraph framing the problem)
Correct heading: ## Summary
- Do not add a heading that is not listed, do not drop one, do not rename or reorder them.
- Fill each section only from the FACTS. If a section's content is not supported by the facts, write one short honest sentence saying so rather than inventing detail.
- Flowing prose under each heading. No bullet lists unless a section's note explicitly asks for a list. Keep every issue/PR number, identifier, and quoted excerpt verbatim from the FACTS; do not paraphrase a quoted excerpt.
- Use British spelling (organisation, behaviour, prioritise, summarise).
- Output ONLY the markdown body: the headings and their content. No title line above the first heading, no preamble ("Here is the issue body:"), no markdown fence, no closing summary section that restates the issue.
- Stop after the substantive content. Do NOT add a closing sentence that restates the point. Do NOT append a participial clause (beginning with -ing or "supported by", "leading to", "ensuring", "reflecting", "providing", "allowing", "making", "enabling"). Do NOT end with a declarative rephrase ("This means", "This approach", "The result is", "In effect", "Overall", "In summary", "This ensures", "This enables"). Do NOT end with restating phrases ("going forward", "moving forward", "closes the gap", "closes the loop"). End on a finite verb introducing new content, or stop.
Wrong: ## Summary
The migration removes the legacy adapter, ensuring smoother rollouts going forward.
Correct: ## Summary
The migration removes the legacy adapter; the rollout steps are listed under ## Plan.

=== SECTIONS (the exact headings in order, each with a note on its content) ===
{{sections}}

=== FACTS (the only source material — invent nothing beyond this) ===
{{stdin}}
```

## Variables

- `{{stdin}}` — the facts, piped in: the observation, verbatim excerpts, identifiers, and proposed fix. State as plain facts, not as instructions. No `--var` slot needed.
- `{{sections}}` — the ordered section plan, as alternating lines: a `##` heading line to reproduce verbatim, then a `(content: ...)` note line describing what goes under it. Keep heading and note on separate lines (a combined `## Heading — note` line gets echoed whole into the output). The caller's structure decision; the model fills the sections, it does not invent its own headings.

## Invocation

```bash
bash scripts/delegate.sh --recipe github-issue-body \
  --var sections="$(cat "$CLAUDE_JOB_DIR/tmp/issue-sections.md")" \
  prose "Use exactly the listed headings in order. British spelling. Invent nothing beyond the facts. No title line, no closing summary." \
  < "$CLAUDE_JOB_DIR/tmp/issue-facts.md"
```

Then create the issue from the drafted body and record the verdict:

```bash
gh issue create --title "<title you write by hand>" --body-file drafted-body.md
bash scripts/delegate-feedback.sh hit   # or: miss "<reason>"
```

## Anti-hallucination guards (each line addresses a recurring miss-mode)

- "Use exactly the markdown headings under SECTIONS ... do not add a heading that is not listed" — without an explicit heading list the prose tier falls back to a generic bug template (Background / Steps to reproduce / Expected / Actual) even when the issue is a proposal or a coverage-gap note. Pinning the caller's headings is the recipe's load-bearing structure directive.
- "If a section's content is not supported by the facts, write one short honest sentence saying so rather than inventing detail" — the closed-source-material discipline. A section the facts do not cover is exactly where the model invents a plausible-but-false detail; the honest-absence escape hatch is the same pattern `summarise-issue.md` uses for empty sections.
- "Keep every issue/PR number, identifier, and quoted excerpt verbatim" — issue bodies routinely cite `#NNN` and verbatim error output; the prose tier paraphrases excerpts and drifts numbers unless told to preserve them.
- "Output ONLY the markdown body ... no title line above the first heading, no closing summary" — without it the model prepends a `# Title` line (which `gh issue create` would double up) or appends a `## Summary` that restates the whole issue. The anti-padding block is the SKILL.md prose-tier directive; the Wrong/Correct anchor uses domain-neutral content (a migration/adapter, not issue-tracking) per the library's domain-neutral-anchor convention so the model does not copy it into a real body.
- British spelling is the maintainer's taste default (this is a taste-calibrated recipe); a different adopter should swap it for their own convention.

## Expected output shape

```
## Summary

One paragraph that frames the problem, citing the relevant #NNN verbatim.

## Why this matters

One paragraph on the impact.

## Suggested fix

The proposed change in prose, one paragraph per option, each grounded in the facts.
```

Verify before recording verdict: the headings match SECTIONS exactly (same set, same order, none added or dropped), every section's content traces to the FACTS, issue/PR numbers and quoted excerpts appear verbatim, British spelling, no title line above the first heading, no preamble or markdown fence, no closing summary that restates the issue.

## Calibration notes

Graduated 2026-06-16 from observed recurring bare-delegation usage rather than from a recorded HIT. A 2026-06-15 analysis of the session-transcript corpus (the bare, no-`--recipe` `delegate.sh` invocations across all projects) found drafting a new GitHub issue body from facts to be one of the highest-recurrence task shapes with no recipe — distinct from `pr-description` (no diff) and `maintainer-reply` (a comment, not a body) — so it fell back to the bare `prose` tier each time, the weaker trigger surface, with the structure and anti-drift directives re-specified by hand.

The prompt skeleton is lifted from the actual bare prompts used in those sessions, which had already converged on the load-bearing guards independently: an explicit ordered heading list ("Output sections in this order: ## Summary ... ## Suggested fixes"), "invent nothing", "British spelling", "Output ONLY the markdown sections, no preamble or closing summary", and "Stop after the content sentences. Do not add a closing sentence that restates the point." Those hand-specified guards are what this recipe makes permanent.

This recipe also closes the matching interception gap: `gh issue create` is the one delegatable boundary `scripts/delegate-boundary-hook.sh` did not previously match (commit, PR-create, release-create, and comment-reply were covered; new-issue bodies were not). The boundary hook's `issue-create` branch (added in the same change) suggests this recipe when a `gh issue create` with an inline `--body`/`--body-file` is about to run with no recent local delegation.

### 2026-06-16 — first dogfood: MISS → fix → HIT

First dogfood against `qwen3.6:35b-a3b-q8_0` (prose tier, Ollama) surfaced a recipe-design MISS the structural tests cannot catch. The original `{{sections}}` convention put each heading and its content-note on one line (`## Summary — one paragraph framing the problem`); the model echoed the whole line into the heading, emitting `## Summary — one paragraph naming the gap` instead of `## Summary`. Recorded MISS via `delegate-feedback.sh --source agent`.

The fix changed the sections convention to two lines per section — a `##` heading line to reproduce verbatim, then a `(content: ...)` note line that is guidance, not output — and added a Wrong/Correct heading anchor (`Wrong heading: ## Summary (content: ...)` / `Correct heading: ## Summary`) grounded in the observed failure. Re-run on the same facts produced clean `## Summary` / `## Why this matters` / `## Suggested fix` headings with no note-echo, content tracing to the facts, British spelling, no title line, and no closing summary. Recorded HIT. The load-bearing learning: a heading and its content-note on one input line are indistinguishable to the prose tier; separating them onto adjacent lines is what binds the heading-verbatim rule. If a later MISS surfaces a drift not enumerated above, extend the directives with a contrastive Wrong/Correct one-shot grounded in the failing output (domain-neutral Correct content) per the library convention.
