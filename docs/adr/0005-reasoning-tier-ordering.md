# 5. Reasoning-tier ordering: deepseek-r1 ahead of phi4-reasoning and qwen3-coder-next

Date: 2026-05-08

## Status

Accepted.

## Context

`pick-model.sh`'s `reasoning` tier serves closed-form classification work where the prompt encodes a non-negotiable directive (e.g. "if the finding text contains 'intentional', severity is capped at medium"). The tier is the workhorse for severity calibration, category mapping, and any other fixed-enum classification with a hard rule layered on top. Getting the tier order wrong has a directly measurable cost: each calibration cell takes seconds-to-minutes and consumes electricity that scales with model size, so picking a larger-than-necessary model means paying multiples per delegation for no quality gain.

Three candidate families were available on the reference host: `qwen3-coder-next` (51 GB), `deepseek-r1` (14 GB and 32 GB variants), and `phi4-reasoning` (~11 GB). All three claim "reasoning" capability via different architectures: `qwen3-coder-next` via scale, `deepseek-r1` via reasoning-specific RL post-training, `phi4-reasoning` via in-band `<think>` traces. Two empirical questions had to be answered: which model produces correct outputs on the calibration task, and at what cost per cell.

A chain of probes (v5 through v8, plus a size-floor follow-up, all logged under `experiments/sessions/2026-05-03-*` and `2026-05-04-*` with per-session `RETROSPECTIVE.md` files) tested these models on a fixed severity-calibration prompt with a directive rule, then on a fresh PR-triage classification task to confirm the result generalised, then on a code-delegation task to bound applicability. The size-floor probe tested `deepseek-r1:14b` to find where the directive-rule pattern breaks within the same family.

The headline findings:

`deepseek-r1:32b` at 19 GB hits Opus-parity (5/5 on the v5 prompt) at roughly one-third the per-cell electricity cost of `qwen3-coder-next:51b` (also 5/5). `qwen3-coder:30b` — same family as the 51 GB winner, scaled down — drops to 2/5: same-family scale-down breaks the cross-reference capability the directive rule depends on. `phi4-reasoning` at 11 GB scores 3.33/5 with high variance (4/3/3 across reps) and 50× wall-time cost from in-band `<think>` tokens that bypass `think:false`. `gemma4` at 9.6 GB scores 2/5: clean format, no context propagation. `deepseek-r1:14b` at 9.0 GB scores 3/5 deterministic — clean format but no cross-reference propagation, mirroring the 30 GB `qwen3-coder` failure shape.

The discriminator is reasoning architecture, not parameter count. Within the same family (`qwen3-coder`, `deepseek-r1`) capability degrades with scale-down. Across families, a 19 GB reasoning-architecture model beats a 51 GB scale-architecture model on this task at one-third the cost. The directive-rule pattern itself generalises across task content: v7 confirmed both `deepseek-r1:32b` and `qwen3-coder-next` hit 5/5 on a fresh PR-triage classification task using the same prompt shape, so the routing decision is about model architecture for the directive-rule shape, not about the specific severity-calibration content of the v5 fixture.

## Decision

`scripts/pick-model.sh`'s `reasoning` tier preference list is ordered `deepseek-r1` first, `phi4-reasoning` second, and `qwen3-coder-next` only as a fallback. The intent is "smallest architecture-correct model first", which on the reference host means `deepseek-r1:32b` is selected when present.

`tests/run-tests.sh` carries a regression assertion that the resolution order keeps `deepseek-r1` ahead of `phi4-reasoning`. A future preference edit that re-promotes `phi4-reasoning` will fail the test and force a re-run of the v6 baseline before merging.

The directive-rule discipline (encoded in SKILL.md's discipline subsection as the fifth bullet) is the prompt shape this routing assumes. If a consumer uses the reasoning tier for free-form prose synthesis instead of closed-form classification with a hard rule, the routing is wrong for that workload and they should use the prose tier. SKILL.md's tier-routing narrative makes this distinction explicit.

The directive-rule pattern has a size floor. Within the `deepseek-r1` family it sits between 9 and 19 GB: `deepseek-r1:14b` can format the response correctly but cannot propagate the rule across cross-referenced findings. The reasoning tier therefore prefers `deepseek-r1:32b` specifically, not "any `deepseek-r1`".

## Consequences

Routing is empirically grounded rather than llmfit-predicted. llmfit's hardware-fit score does not measure capability on closed-form classification with directive rules; the `experiments/` framework does. As long as the reasoning tier serves the directive-rule shape, this ordering holds.

The ordering is reversible by re-running the v5 / v6 / v7 / v8 probes against new candidates. The fixtures and prompts under `experiments/sessions/2026-05-03-*` and `2026-05-04-*` are intentionally preserved as evidence trails so a future contributor can either reproduce the result or contest it with a new probe. ROADMAP "Phase 7" calls out that re-running the baseline whenever `pick-model.sh` preferences change is the discipline; this ADR is the durable artifact for the current ordering, so ROADMAP "Phase 10" can safely slim its per-experiment narrative without losing the rationale that justifies tier ordering.

What would justify revisiting the decision: a new model in a different reasoning architecture (Mamba, hybrid SSM, etc.) hitting Opus-parity at lower cost than `deepseek-r1:32b`; a same-family scale-down that surprises by maintaining cross-reference propagation; or evidence that the directive-rule pattern stops being the right discipline for closed-form classification at all (which would invalidate the whole reasoning tier, not just its ordering).

The cost of this ADR is one more file in `docs/adr/`. The benefit is that the empirical rationale that justifies the routing — and the regression guard in the test suite that protects it — now lives in a durable single artifact rather than spread across the ROADMAP Phase 10 narrative.
