# 25. Local code drafts as a supervised, divergent second opinion — an experiment with a kill criterion

Date: 2026-06-22

## Status

Accepted as an experiment. The amendment ships behind an explicit evidence gate
(below); if the gate fails, the kill path reverts most of it. Records the
decision designed in
`docs/superpowers/specs/2026-06-22-supervised-draft-delegation-design.md`.

## Context

The skill's discriminator deliberately rejects agentic coding: "local models are
strong summarisers and weak agents," so feature implementation, multi-step
reasoning, repo-wide context, and tool-calling are out of scope. That boundary
is sound for unbounded, repo-wide work and is not in question.

Two facts sat in tension with the absolute form of that boundary. First, the
`code` tier was almost unused — on the order of two delegations in the whole
metrics history — so whatever value it could add was going unrealised. Second,
there is a genuine, narrow case for pointing a local code model at a bounded task
even when its output will not be shipped verbatim.

The honest version of that case, after stripping the parts that do not survive
scrutiny: a generic "draft so Claude can think against it" is largely redundant,
because Claude already drafts internally at zero latency. What survives is
(a) divergence — a differently-trained model proposes an approach, or makes a
mistake, Claude would not have generated itself, which a self-generated draft
cannot provide — and (b) executable empirical feedback — running the draft
answers "does it compile, pass the test, behave as we assumed" in a way static
reasoning cannot. So the durable value is "a divergent, executable second
opinion," not "scaffolding."

## Decision

Amend the discriminator from "weak agent, so don't" to: local models are weak
*unsupervised* agents but usable as a *supervised* draft generator under a verify
loop. The amendment is scoped to delegation as a sub-step of Claude's *own*
implementation work. The skill still does not own feature implementation; Claude
does. Within its own implementation work, Claude may delegate one bounded code
draft.

A code draft fires only when both a value trigger and the bounded guard hold.
The value trigger (at least one): the approach is genuinely forked and Claude is
unsure which way to go; or executing the draft would teach more than reasoning
about it. The bounded guard (always): a single file or function, small output,
with a concrete verification — a test to run or an explicit acceptance check —
named up front. The draft is always disposable; Claude verifies before keeping
anything, and a draft that applies but fails its verification is treated as a
refusal, never kept on the strength of its prose.

What ships: the `scaffold` verdict in `delegate-feedback.sh` and
`metrics-summary.sh` (a third outcome for a discarded-but-useful draft, recorded
backward-compatibly); the `prompts/code-draft.md` recipe (routes to the `code`
tier, emits a focused full snippet rather than a unified diff); and the body-only
doctrine in `SKILL.md`. The `SKILL.md` frontmatter `description` is deliberately
left byte-identical to `main`, so the trigger surface — and the trigger-eval CI
gate — is unaffected and there is no frontmatter-vs-body contradiction.

Explicitly out of scope: multi-agent fan-out ("multiply delegate"), which
multiplies Claude's reading cost and must earn its way in on evidence from this
leaner version first; and anything that ships local-model code without Claude's
verification.

## The evidence gate

The amendment is an experiment, not a settled belief, and it is gated on field
evidence rather than on this reasoning.

Success: over a window of at least roughly ten `code-draft` delegations (enough
to avoid judging on noise), `hit + scaffold` verdicts are a clear majority
(around 60% or more), and the honest review — "would Claude have reached as good
a solution as fast without the draft?" — leans net-positive. In that case the
doctrine stays.

Kill: if `hit + scaffold` is a minority (delegations are mostly pure misses), or
the median added latency clearly outweighs the value, revert the recipe
(`prompts/code-draft.md`) and the `SKILL.md` doctrine. The `scaffold` verdict
stays regardless — it is backward-compatible, harmless, and useful on its own as
a more honest third outcome for any delegation. Record the outcome here when the
window closes.

## Consequences

Nothing here is a one-way door. The recipe and the doctrine are cleanly
removable, and the `scaffold` verdict is additive and safe to keep whichever way
the gate resolves. The `scaffold` verdict closes a real measurement gap that
predates this experiment — a draft discarded but genuinely useful was previously
forced into the binary hit/miss frame and wrongly counted as a miss — so even
under the kill path the calibration loop comes out ahead.

The reversibility plus the frontmatter-untouched constraint mean the headline
risk is bounded to latency on the bounded code-draft path, which the tight value
triggers and the bounded guard already minimise. If the gate fails, the cost was
a few code-tier round-trips and this record; if it succeeds, the `code` tier
stops being dead weight and becomes a measured, divergent second opinion under
Claude's verification.
