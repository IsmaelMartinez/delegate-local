# Supervised draft delegation for code — design spec

Date: 2026-06-22
Status: approved design, pre-implementation
Topic: let Claude use the local `code` tier as a divergent, executable draft generator under a verify loop, without making the skill the handler for coding tasks.

## Problem

The skill routes "gather context once, send one prompt, return text" work to local
models, and its discriminator deliberately rejects agentic coding: "local models are
strong summarisers and weak agents." That boundary is sound for unbounded,
repo-wide, multi-step work. But two facts sit in tension with it. First, the `code`
tier (default `qwen3-coder-next`) is almost unused — on the order of two delegations
in the whole metrics history — so whatever value it could add is going unrealised.
Second, there is a genuine, narrow case for pointing a local code model at a bounded
task even when we will not ship its output verbatim.

The honest version of that case, after stripping the parts that do not survive
scrutiny: a generic "draft so Claude can think against it" is largely redundant,
because Claude already drafts internally at zero latency. What does survive is
(a) divergence — a differently-trained model proposes an approach or makes a mistake
Claude would not have generated itself, which a self-generated draft cannot provide —
and (b) executable empirical feedback — running the draft answers "does it compile,
pass the test, does this API behave as we assumed" in a way static reasoning cannot.
So the durable value is "a divergent, executable second opinion," not "scaffolding,"
and the design aims there.

## The amended discriminator

The discriminator changes from "weak agent, so don't" to: **weak *unsupervised*
agent — usable as a *supervised* draft generator under a verify loop.** This is an
amendment scoped to delegation as a *sub-step of Claude's own work*, not a change to
what the skill is the handler for. The skill still does not own feature
implementation; Claude does. Claude may, within its own implementation work, delegate
a bounded code draft.

Delegation of a code draft fires only when both a value trigger and the bounded
guard hold:

- Value trigger (at least one): the approach is genuinely forked and Claude is unsure
  which way to go; OR executing the draft would teach more than reasoning about it
  (compilation, a test result, real API behaviour).
- Bounded guard (always): a single file or function, small output, with a concrete
  verification (a test to run or an explicit acceptance check) named up front.

The draft is always disposable. Claude verifies before keeping anything. This is
explicitly **not** "delegate all coding" — generic, low-divergence, easily-self-drafted
code does not qualify, because for those the local round-trip only adds latency.

## Scope

In scope: a body-only doctrine change in `SKILL.md`; a `prompts/code-draft.md`
recipe; a third `scaffold` verdict in `delegate-feedback.sh` and `metrics-summary.sh`;
the matching tests; and an ADR recording the amendment and its kill criterion.

Out of scope (explicit): changing the `SKILL.md` frontmatter `description` (the
trigger surface stays as-is, so the trigger-eval CI gate is unaffected and there is no
frontmatter-vs-body contradiction); multi-agent fan-out / "multiply delegate" (it
multiplies Claude's reading cost and must earn its way in on evidence from this leaner
version first); and anything that ships local-model code without Claude's
verification.

## Goals

Ordered so each goal is independently verifiable and later goals build on earlier
ones. Each carries a concrete "Done when" acceptance check. The measurement
infrastructure (G1) lands first so that once the doctrine and recipe ship, every code
draft is gradeable.

### G1 — Add the `scaffold` verdict to the calibration loop

The current verdict is binary: a kept output is a hit, a rewritten/discarded one is a
miss. That wrongly punishes the exact case this design is about — a draft discarded
but genuinely useful (divergence/execution improved the final result). Introduce a
third outcome, `scaffold`, distinct from both, recorded backward-compatibly so legacy
hit/miss rows are untouched.

Done when:
- `delegate-feedback.sh scaffold "<note>"` (and the `--source agent scaffold` form)
  records a feedback row distinguishable from hit and miss, with existing hit/miss
  behaviour unchanged.
- `metrics-summary.sh` reports `scaffold` as its own count in the calibration
  section, alongside hits and misses, derivable for legacy rows (no `scaffold` rows
  pre-exist, so they read as before).
- `tests/test-delegate-feedback.sh` and `tests/test-metrics-summary.sh` assert the new
  verdict; the full suite stays green.

### G2 — Add the `code-draft` recipe

A recipe that encodes the crisp brief — which is the real value engine, because
writing it forces Claude's own clarity whether or not the model's output is used.

Done when:
- `prompts/code-draft.md` exists with inputs `goal`, `scope`, `constraints`,
  `verification` (plus `{{stdin}}` for the surrounding source/context), routes to the
  `code` tier, and instructs a focused full-snippet output (not a unified diff — weak
  models botch hunk headers, and Claude can diff a snippet itself), with output-only /
  no-explanation guards in the spirit of the existing recipes.
- `prompts/README.md` indexes it (the library cross-reference the prompts-library test
  enforces).
- `tests/test-prompts-library.sh` passes; a live `delegate.sh --recipe code-draft code
  ...` smoke produces a focused snippet (manual confirmation, noted in the PR).

### G3 — Land the doctrine in `SKILL.md` (body only)

Done when:
- The `SKILL.md` body amends the discriminator to the "supervised draft generator
  under a verify loop" framing and adds the divergent-draft pattern with the tight
  triggers and the disposable-draft / verify-before-keep discipline from this spec.
- The frontmatter `description` is byte-identical to `main` (verified by
  `git diff main -- SKILL.md` showing no frontmatter change), so the trigger-eval gate
  is unaffected.
- `validate-frontmatter.sh` and `validate-skill-content.sh` pass and the MUST / MUST
  NOT structure of the description is intact.

### G4 — Record the amendment as an ADR

Done when:
- `docs/adr/0025-supervised-draft-delegation.md` records the discriminator amendment,
  the experiment frame, and the success/kill criteria below; references this spec; and
  follows the existing ADR format.

### G5 — Run the evidence gate (the "verify as we go" goal)

The amendment is an experiment, not a settled belief. This goal is the honest test of
whether the divergent-draft idea pays off, and it is what verifies the change in the
field rather than on paper.

Done when:
- After the doctrine ships, code-tier draft delegations accrue graded verdicts
  (hit / miss / scaffold) visible in `metrics-summary.sh`.
- A go/no-go review at the window end records the outcome against the criteria below.

Success: over the window (at least ~10 code-draft delegations, to avoid judging on
noise), `hit + scaffold` is a clear majority (≈60%+), and the honest review —
"would Claude have reached as good a solution as fast without the draft?" — leans
net-positive.

Kill: if `hit + scaffold` is a minority (delegations are mostly pure misses), or the
median added latency clearly outweighs the value, revert G2 and G3 (the doctrine and
recipe). G1's `scaffold` verdict stays — it is harmless and useful on its own. Record
the outcome in the ADR.

## Risks and mitigations

Latency on every coding step — mitigated by the tight value triggers and the bounded
guard, so drafts fire only where divergence or execution actually helps, on small
tasks, on the fast code tier.

Self-deception about scaffold value ("it helped" is easy to rationalise) — mitigated
by G1 making the value measurable and G5 gating continuation on the numbers plus an
honest review, with a real kill path.

Scope creep and frontmatter/body contradiction — mitigated by leaving the frontmatter
untouched and putting fan-out explicitly out of scope.

Reversibility — the doctrine and recipe are cleanly removable; the verdict is
backward-compatible and safe to keep regardless. Nothing here is a one-way door.

## Testing and gates

Per-goal verification as above. The whole CI suite stays green. Because the frontmatter
`description` is unchanged, the trigger-eval gate is unaffected. New tests:
`test-delegate-feedback.sh` (scaffold verdict), `test-metrics-summary.sh` (scaffold
reporting), and `test-prompts-library.sh` coverage of the new recipe (structure +
README cross-reference).
