# 2026-06-06 — Reasoning-tier audit: qwq:32b with the `<think>`-strip wired in

Topic A follow-up. `qwq:32b` (Alibaba's QwQ, a Qwen-family reasoning model, q8_0, 34 GB) is the Qwen reasoning candidate. Its first audit (2026-06-05) returned REJECT on the structural scorers — but only because Ollama's `think:false` does not suppress its `<think>...</think>` trace and the baseline runner scored the raw output. This run re-audits it after wiring `DELEGATE_STRIP_THINK` into the reasoning-tier dispatch and the audit harness.

## What changed

`delegate.sh` now strips a leading `<think>...</think>` trace for the reasoning tier by default (`DELEGATE_STRIP_THINK=0` opts out), `experiments/runner.sh` honours the same env via a shared `strip_think_trace` helper, and `scripts/model-change-audit.sh` exports `DELEGATE_STRIP_THINK=1` for reasoning-tier audits so gate 2 measures the same clean output production produces.

## Results — before vs after the strip

| Gate | Before strip | After strip |
|---|---|---|
| Trigger eval | recall 0.952 PASS | recall 0.952 PASS |
| T4 commit-message | 0.6666 FAIL | **0.8333 PASS** (= incumbent 0.83) |
| T5 JSON-shape | 0.0000 FAIL | **1.0000 PASS** (= incumbent 1.00) |
| T6 regex | 0.0000 FAIL | **1.0000 PASS** (incumbent 0.00) |
| Chat template | DIVERGES | DIVERGES |

The strip transformed qwq from failing every structural scorer to passing all three. It now matches the incumbent `deepseek-r1:32b` on T4/T5 and beats it on T6 — the incumbent's T6 0.00 is a think-wrapping scorer artifact that the strip clears for qwq.

## Verdict: automated REJECT, manual INVESTIGATE → viable

The automated verdict stays REJECT, now driven solely by gate 3's chat-template flag ("defaults a system prompt; tool-call surface in template"). Both are benign for this skill: the wrapper sends user-role only (no system prompt) and binds no tools, so neither surface is exercised. The incumbent's own template also has a system slot, so "defaults a system prompt" is not a discriminator. On the manual-review (INVESTIGATE) path the gate-3 flag does not block adoption — qwq is at or above the incumbent on every axis the skill actually uses.

## Recommendation

The durable win is the strip-wiring itself: it hardens the reasoning tier on the Ollama fallback path (where even the R1 distill leaks its trace) and makes any future trace-emitting reasoning-model audit fair — proven here by qwq's 0.66/0/0 → 0.83/1.0/1.0 jump.

Promoting qwq into `pick-model.sh` reasoning prefs is optional and not done here. qwq is now a proven-viable Qwen reasoning model, but the incumbent `deepseek-r1:32b` (itself Qwen-arch) already serves the tier via the fast MLX path; qwq is Ollama-only here (no MLX variant pulled) and its measurable edge is the T6 scorer artifact rather than a real capability gap. Keep the incumbent unless the Ollama-path robustness or Qwen-family preference is worth the slower path; the routing is unchanged. Raw: `experiments/results/raw/qwq_32b-q8_0.txt`.
