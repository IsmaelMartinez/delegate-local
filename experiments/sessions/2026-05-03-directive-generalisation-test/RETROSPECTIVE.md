# v7: directive-rule generalisation test on PR triage

**Date:** 2026-05-03
**Parent experiments:** v5 (directive-rule introduction), v6 (smaller-model probe)
**Hypothesis:** The hard-rule directive pattern that closed the severity-classification gap in v5 is *task-shape* discipline, not *task-content* discipline. If so, applying the same pattern to a fresh classification task should reproduce the parity result.

## Setup

New fixture: 5 PR descriptions to be triaged into one of REFACTOR / BUGFIX / FEATURE / DOCS / PERF. Same v5-shape prompt: numbered priority-ordered category rules with "first match wins, non-negotiable" framing, one-shot example with a different finding, JSON-array output requirement. Two models tested: deepseek-r1:32b (v6 winner at 19 GB) and qwen3-coder-next:latest (v5 winner at 51 GB). Same disciplined defaults — `think:false`, temperature 0, ms timing, sequential per model with `ollama stop` between. N=3 per cell, 6 cells total.

Ground truth: P1=REFACTOR, P2=BUGFIX, P3=FEATURE, P4=DOCS, P5=PERF.

## Result: both models 5/5 across all 3 reps

| Model | r1 | r2 | r3 | Mean | Verdict |
|---|---|---|---|---|---|
| deepseek-r1:32b | 5/5 | 5/5 | 5/5 | 5.00 | PARITY |
| qwen3-coder-next:latest | 5/5 | 5/5 | 5/5 | 5.00 | PARITY |

Stdev=0 across all reps. Per-cell timing: deepseek-r1 cold-load 7.9 s then 3.0 s/cell; coder-next cold-load 9.3 s then 1.9 s/cell — both well within the practical range. Output bytes constant per model (199 / 161). deepseek-r1 wraps its response in markdown JSON fences (```json...```); coder-next emits raw JSON without fences. Both parse cleanly with the v6 parser's existing fence-stripping.

## Interpretation

The hypothesis is confirmed. The hard-rule directive pattern is **task-shape discipline, not task-content discipline**. v5's mechanism — explicit priority-ordered keyword-triggered rules with non-negotiable framing — applies across:

- Calibration-shaped classification (severity with intent qualifier — v5)
- Mapping-shaped classification (PR description → category enum — v7)

This is a useful generalisation. SKILL.md's discipline section can now confidently describe the pattern as the recommended approach for closed-form classification with directive rules in general, rather than tying it to severity calibration specifically. The pattern stays the same; the rule content varies.

The cross-reference reasoning that v6 showed only deepseek-r1 (and not coder-30b) handled is *not* needed for v7 — each PR is independently classifiable. So both models score perfectly here. v6's narrower finding remains: cross-reference within a list of items is the discriminating capability that breaks at same-family scale-down. Per-item independent classification works on a much wider model range.

## What this means for the skill

`SKILL.md`'s discipline subsection can be lightly tightened to describe the directive-rule pattern as task-agnostic: when the task is closed-form classification with a finite enum of valid outputs, spell out the rules as priority-ordered keyword-triggered hard directives with non-negotiable framing and a one-shot example. Independent of whether the rules are calibration caps (v5), category mappings (v7), or some other shape.

`pick-model.sh` tier prefs are unchanged by v7. The reasoning-tier promotion of deepseek-r1 from v6 holds; the v7 evidence is consistent with it (deepseek-r1 keeps parity on a new task).

## Open questions

- Does the pattern hold on classification tasks with **>5 categories**? PR triage has 5; some real-world tasks (issue labeling, bug component routing) have 20+. Untested.
- Does the pattern hold on classification tasks where **the rules conflict deliberately** (ambiguous inputs that fit multiple categories)? v7's fixture had clean unambiguous PRs; real-world categorization often has overlap. Untested.
- Does **gemma4 9.6 GB** — which failed v5/v6 cross-reference — pass v7's per-item independent classification? Quick follow-up worth running to map the floor for the simpler task shape.

## Bottom line

Five wins now in the v5-derived directive-rule pattern: v5 (severity, coder-next 5/5), v6 (severity, deepseek-r1 5/5), v7 (PR triage, both 5/5). Three task-distinct cells × 5 = 15 cells of consistent 5/5 evidence. The pattern is the right SKILL.md guidance for closed-form classification with finite output enums.
