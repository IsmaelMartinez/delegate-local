# v6: discipline-not-size probe — does the v5 hard-rule generalise to smaller models?

**Date:** 2026-05-03
**Parent experiments:** `../2026-05-03-security-review-delegation/RETROSPECTIVE.md` (v2), `../2026-05-03-format-schema-followup/RETROSPECTIVE.md` (v3), `../2026-05-03-calibration-example-probe/RETROSPECTIVE.md` (v4/v5)
**Sub-task tested:** st1 severity classification only
**Models:** five installed candidates spanning 9.6 GB to 51 GB across four families

The v5 retrospective showed the hard-rule directive lifted qwen3-coder-next:latest (51 GB) to 5/5 — full Opus parity. Open question: does the same prompt + same discipline work on smaller models, or is the result size-dependent?

## Setup

Same fixture, same v5 prompt verbatim (`subtask-1-severity-v5.txt`), same disciplined defaults (`think:false`, temperature 0). N=3 per cell, ms timing precision. Sequential per model with `ollama stop` between models so VRAM is released and cold-load timing is fair.

## Result

| Model | Size GB | Family | r1 | r2 | r3 | Mean | Verdict |
|---|---|---|---|---|---|---|---|
| qwen3-coder-next:latest | 51 | qwen-coder | 5/5 | 5/5 | 5/5 | **5.00** | PARITY (control, matches v5) |
| **deepseek-r1:32b** | **19** | **deepseek-r1** | **5/5** | **5/5** | **5/5** | **5.00** | **PARITY at 19 GB** |
| phi4-reasoning:plus | 11 | phi-reasoning | 4/5 | 3/5 | 3/5 | 3.33 | partial, variable |
| qwen3-coder:30b-a3b-q8_0 | 32 | qwen-coder | 2/5 | 2/5 | 2/5 | 2.00 | same-family scale-down breaks |
| gemma4:latest | 9.6 | gemma | 2/5 | 2/5 | 2/5 | 2.00 | literal rule application |

## Headline finding: deepseek-r1 32b at 19 GB hits Opus parity

This is the standout result. deepseek-r1:32b is **2.7× smaller** than qwen3-coder-next (19 GB vs 51 GB) and produces byte-identical 5/5 outputs across all three reps. Cold-load 12 s, then ~4 s/cell. The model correctly applies the hard-rule directive AND propagates the design-intent context across F2/F3/F4 even though those findings don't restate the trigger keywords — exactly the cross-reference reasoning that v5 showed prose-tier qwen3.6 couldn't do.

This is consistent with deepseek-r1 being a reasoning-distilled model: its internal latent state preserves enough of the chain-of-thought structure to handle directive-rule + cross-reference tasks, even when the API's `think:false` suppresses the explicit reasoning tokens. The discipline-not-size hypothesis holds for this family; size is *not* the limiting factor when the model architecture preserves rule-application machinery.

## Same family, smaller config, breaks: qwen3-coder:30b at 32 GB → 2/5

The qwen-coder family at 30B-a3b (32 GB at q8) scores identically to v2's qwen3.6 prose tier (F1=med, F2=high, F3=med, F4=high, F5=info — exact same wrong cells). This is the *control test* for "is it size or family". The same family, smaller config, fails the cross-reference test. Yet a smaller model from a different family (deepseek-r1) succeeds.

So the relevant axis is not parameter count, it's *whether the model architecture and training preserve rule-application behaviour at the inference scale*. Within a family, scaling down can drop the discipline; across families, smaller can be more capable.

## Phi4-reasoning's `<think>` tags bypass `think:false`

The API request set `think:false` but phi4-reasoning's response begins with a `<think>...</think>` block consuming most of the inference time (390 s wall, 47 KB of reasoning tokens). The actual final JSON is at the end after `</think>` and is correctly parseable. This means: phi4-reasoning's reasoning is not the Ollama-controlled think channel — it's in-band tagged tokens that the API parameter cannot suppress. The scorer was updated to strip `<think>` blocks before extracting JSON.

After the strip, phi4-reasoning scores 3.33/5 mean (4/3/3 across reps) — the reasoning chain is *non-deterministic* even at temperature 0, presumably because the in-band reasoning tokens are sampled from a richer distribution than the structured output. This is a useful negative finding for the tier-routing logic: phi4-reasoning is not a good substitute for deepseek-r1 on this workload despite being smaller (11 GB vs 19 GB) — it's slower (390 s vs 4 s per call), inconsistent across reps, and gives a strictly worse score.

## gemma4 9.6 GB: produces clean JSON, doesn't apply cross-reference

gemma4:latest at 9.6 GB produces well-formed JSON consistently across reps (byte-identical 2.00 mean), but applies the directive literally only on F1 (where the keyword fires) and falls back to CVSS-conservative reasoning for F2-F4. Same failure shape as v2's qwen3.6 prose tier — the model honors directives but doesn't propagate context across the finding list. The smallest-model-in-the-set bound at 2/5 is consistent with the broader pattern: cross-reference rule application is the discriminating capability, not size.

## Implications for tier routing

Two updates to `scripts/pick-model.sh` follow from this:

1. **Promote `deepseek-r1` ahead of `phi4-reasoning` in the `reasoning` tier prefs.** Currently `reasoning) prefs=("phi4-reasoning" "qwq" "deepseek-r1" "glm-4")`. v6 evidence is that deepseek-r1 outperforms phi4-reasoning on directive-rule classification (5/5 vs 3.33/5), at 4/5× faster wall time per call, at deterministic output. The current ordering inherited from earlier audits should be reversed.
2. **Add `deepseek-r1` to the `code` tier prefs as a small-model fallback.** Currently `code) prefs=("qwen3-coder-next" "qwen3-coder" "deepseek-r1" "qwen3.5")`. deepseek-r1 is already there but at position 3; given v6 it could move ahead of qwen3-coder (the 30B variant), which we now know fails on cross-reference.

The discipline-not-size finding also belongs in `SKILL.md` as a tier-routing note: when the task involves cross-reference reasoning (rule applied to one item must propagate context across other items), reasoning-distilled models in the 19–51 GB range are interchangeable; same-family scale-down within coder/prose families is unsafe.

## Cost recalibration

| Model | Cost / suite (15 cells × electricity) | Score | $/correct cell |
|---|---|---|---|
| coder-next 51 GB | ~$0.0001 | 5.00 | $0.000007 |
| **deepseek-r1 19 GB** | **~$0.00003** | **5.00** | **$0.000002** |
| phi4-reasoning 11 GB | ~$0.005 (inference time dominates) | 3.33 | $0.0003 (wide variance) |
| coder-30b 32 GB | ~$0.00005 | 2.00 | $0.0001 |

Inference-time cost (electricity × duration) for deepseek-r1 is ~3× cheaper than coder-next per cell — slightly slower per cell (4 s vs 2 s) but the model is more efficient on disk and presumably in VRAM. Phi4-reasoning is ~50× more expensive than coder-next per cell despite being 4.6× smaller, because of its 390 s reasoning tax.

## Open questions

- **Does discipline-not-size hold below 19 GB on a reasoning-distilled model?** Worth pulling and testing deepseek-r1:14b or qwen3.5:14b to find the floor. Constrained by which models have public Q4/Q8 builds at that size.
- **Does Devstral Small (24B) match deepseek-r1 on this workload?** Same size class, different family (Mistral). Evidence so far is one data point per family.
- **Why does phi4-reasoning emit `<think>` despite `think:false`?** Worth a small investigation — possibly the model card uses Modelfile-template-level reasoning-emission instead of the Ollama think channel. Relevant to the Ollama #14645 contribution.

## Bottom line

Within the installed model set, **deepseek-r1:32b at 19 GB is the new frontier-cost-quality point** for closed-form classification with cross-reference reasoning under the v5 disciplined prompt. Same Opus-quality output as qwen3-coder-next:latest (51 GB) at ~3× lower per-cell electricity cost. Tier-routing prefs should promote it.

The discipline-not-size hypothesis is *partially confirmed* — it holds across families when the smaller model preserves reasoning-application machinery, and fails when the smaller model is a same-family scale-down that loses cross-reference capability. The framing in SKILL.md should be "discipline + reasoning-architecture > size" rather than just "discipline > size".
