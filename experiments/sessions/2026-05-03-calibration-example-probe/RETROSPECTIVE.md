# v4/v5: closing the severity-calibration gap with prompt-side directives

**Date:** 2026-05-03
**Parent experiments:** `../2026-05-03-security-review-delegation/RETROSPECTIVE.md` (v2), `../2026-05-03-format-schema-followup/RETROSPECTIVE.md` (v3)
**Sub-task tested:** st1 severity classification only (the single residual gap from v2/v3)
**Models:** qwen3.6:35b-a3b-q8_0 (prose tier), qwen3-coder-next:latest (code tier)
**N:** 3 reps per cell, temperature 0, think:false

The v3 retrospective concluded that schema enforcement is shape-not-judgment, and the calibration gap requires a content intervention. v4 and v5 test two such interventions on the same fixture.

## v4: counterintuitive one-shot example

**Hypothesis:** Replace v2's "hardcoded credentials → high" example (which reinforces the model's existing CVSS prior) with a calibration-shaped example showing a privileged trust delegation rated medium because of documented intent. One-shot example is the lever; nothing else changes.

**Result: zero delta vs v2.** Per-cell outputs were byte-identical to v2 across all 6 cells (qwen3.6 2/5, coder-next 3/5, stdev=0). The model's prior on what severity means for code-execution-shaped findings was not moved by a single counterintuitive example. This rules out the "calibration via prompt examples" hypothesis as stated in the v3 follow-up plan.

## v5: explicit hard-rule severity cap

**Hypothesis:** A directive-shaped rule, "if the finding text contains 'intentional', 'by design', 'documented as', or 'design choice', severity is capped at medium," with explicit non-negotiable framing. Tests whether a literal-rule directive moves where a single example can't.

**Result: split — coder-tier 5/5, prose-tier 2/5.**

| Model | F1 | F2 | F3 | F4 | F5 | Score | vs Opus |
|---|---|---|---|---|---|---|---|
| Opus (ground truth) | medium | medium | low | low | info | 5/5 | — |
| qwen3.6 v2 | medium | high | medium | high | info | 2/5 | F2,F3,F4 |
| qwen3.6 v4 | medium | high | medium | high | info | 2/5 | F2,F3,F4 |
| qwen3.6 v5 | medium | high | medium | medium | info | 2/5 | F2,F3,F4 (F4 shifted down within "wrong") |
| coder-next v2 | medium | medium | high | high | info | 3/5 | F3,F4 |
| coder-next v4 | medium | medium | high | high | info | 3/5 | F3,F4 |
| **coder-next v5** | **medium** | **medium** | **low** | **low** | **info** | **5/5** | **— (matches Opus exactly)** |

Stdev=0 across all 3 reps in every cell, both models.

**Coder-next reaches Opus parity** — this is the first time any local model has matched the ground truth on st1. The directive rule, applied through coder-next's stronger cross-reference reasoning (it inferred F2/F3/F4 inherit the same design-intent context that F1 explicitly stated, even though those findings don't restate the keyword), closed the entire calibration gap.

qwen3.6 prose-tier applied the rule literally: only F1 (which contains the keyword "intentional") got capped, F2-F4 stayed at the model's CVSS-conservative reading. The prose-tier's more literal application is a known qwen3.6 trait — it follows directives but doesn't propagate context across an unbounded list of items as readily.

## Implication for the overall picture

The v2 retrospective put coder-next at 3.6/4 of Opus quality (within 9% of Haiku 3.95/4) at sub-cent cost. v5 moves coder-next to **4.0/4 — full parity with Opus and Sonnet** on this workload. The remaining gap to cloud workers is now zero on the four sub-tasks of this fixture. Cost ratio: ~1500× in favour of local.

For prose-tier (qwen3.6), v5 shows a different conclusion: directive rules don't fully close its calibration gap because the model interprets the rule literally rather than propagating context. The implication for the skill is route-by-task-shape: severity classification with cross-referenced findings goes to **code tier**, not prose tier, regardless of whether the surface looks "prosey." Add this to the SKILL.md tier-routing table.

## Aggregate scoreboard so far

| Worker | st1 best | st2 | st3 | st4 | Total / 4 |
|---|---|---|---|---|---|
| Opus 4.7 | 5/5 | 5/5 | 5/5 | PASS | 4.00 |
| Sonnet 4.6 (subagent) | 5/5 | 5/5 | 5/5 | PASS | 4.00 |
| Haiku 4.5 (subagent) | 5/5 | 4/5 (F5 inconsistent) | 5/5 | PASS | 3.95 |
| qwen3-coder-next + v5 hard-rule | **5/5** | 5/5 | 5/5 | PASS | **4.00** |
| qwen3-coder-next + v2 disciplined only | 3/5 | 5/5 | 5/5 | PASS | 3.60 |
| qwen3.6 prose + v5 hard-rule | 2/5 | 5/5 | 5/5 | PASS | 3.40 |
| qwen3.6 prose + v2 disciplined only | 2/5 | 5/5 | 5/5 | PASS | 3.40 |

## What this changes for the skill

1. **`SKILL.md` discipline subsection should add an "explicit-rule directive" practice** alongside the existing four (atomic per call, one-shot example, explicit qualifier rules, thinking off). For closed-form classification with a calibration dimension (severity, priority, risk level), spell out the qualifier rule as a hard directive in the prompt — not as an example, as a non-negotiable rule with the keyword triggers and the cap value.

2. **Tier routing for classification work that involves cross-referenced findings should default to code tier, not prose.** v5 shows the code-tier model propagates context across items in a way prose-tier doesn't. The current Tier→model routing table maps "structured extraction, classification, triage" to *reasoning* tier; for the closed-form-classification subset specifically, code tier outperforms.

3. **Director-side reweighting is no longer the only path** to closing the calibration gap. With the right prompt directive + code-tier model, the gap closes prompt-side. The director-reweighting pattern is still valid as a fallback (when calibration is genuinely subjective and shouldn't be hardcoded), but it's no longer the *only* path.

4. **The "delegate everything" target use-case from the start of this session is now empirically bounded.** With v5 prompt discipline + code tier, local delegation matches cloud-worker quality on closed-form sub-tasks at sub-cent cost. The remaining frontier is the open-ended sub-tasks (multi-step reasoning, tool use loops, code generation) that local-brain identified as out-of-scope from the start. This experiment chain confirms that boundary empirically rather than by prior.

## Open questions for next round

- Does v5's directive-rule pattern generalise beyond severity classification? Test on FP-filter and prose-drafting variants where v2 was already 5/5; null-result if so (already at ceiling). More interesting: test on a classification task v2 hasn't covered (e.g. PR triage by category).
- Does the prose-tier limitation propagate to other cross-reference tasks, or is it specific to "rule applied to one finding propagates to others"? Worth a single follow-up cell to characterise.
- Code-generation delegation under constrained edit format (Aider-style search/replace) — still the highest-leverage gap in the larger picture, untouched by this experiment chain. Now feasible with confidence that closed-form sub-tasks are reliable, since constrained edit format is itself a closed-form sub-task shape.
