# v3 follow-up: does `format: schema` close the severity-calibration gap?

**Date:** 2026-05-03
**Parent experiment:** `../2026-05-03-security-review-delegation/RETROSPECTIVE.md`
**Hypothesis:** Ollama's `format` parameter (XGrammar-backed JSON-schema constrained decoding) — flagged by 2026 practitioner reports as the highest-leverage discipline for local-model structured output, hitting 100% schema compliance vs 89-98% with native JSON mode — would close v2's residual gap on severity classification (qwen3.6 2/5, qwen3-coder-next 3/5; the only sub-task where local trailed Haiku).

**Setup:** Same fixture, same prompts (verbatim from `subtask-*-v2.txt`), same models (qwen3.6:35b-a3b-q8_0, qwen3-coder-next:latest), same N=3, same disciplined defaults (`think:false`, temperature 0). Only difference: API request includes a `format` JSON schema for sub-tasks 1–3 (sub-task 4 stays plaintext). Schemas use `enum` for severity values (`high`/`medium`/`low`/`info`), classification (`REAL`/`ALLOWLISTED_FP`), and ID values (`F1`–`F5`), plus `minItems:5, maxItems:5` to lock array length.

## Result: zero delta vs v2

| Sub-task | qwen3.6 v2 | qwen3.6 v3 | Δ | coder-next v2 | coder-next v3 | Δ |
|---|---|---|---|---|---|---|
| 1 — severity | 2.00 | 2.00 | 0.00 | 3.00 | 3.00 | 0.00 |
| 2 — FP filter | 5.00 | 5.00 | 0.00 | 5.00 | 5.00 | 0.00 |
| 3 — prose | 5.00 | 5.00 | 0.00 | 5.00 | 5.00 | 0.00 |
| 4 — PR comment | PASS | PASS | — | PASS | PASS | — |

Stdev=0 across all reps in both v2 and v3. Per-cell timings were also nearly identical (qwen3.6 cold-load 8s then 2s/cell for st1; coder-next cold-load 9s then 2s/cell — same as v2). Output bytes for st1 are exactly 156 in both v2 and v3, suggesting the model produced byte-identical output regardless of the schema constraint.

## Interpretation

The hypothesis was wrong, and the disconfirming evidence is clean. v2 already had the model emitting valid JSON that matched the implicit schema (every sub-task 1 cell produced 5 objects with `id` and `severity` fields, every severity value was one of the four valid enum members, no extraneous keys). Schema enforcement is a no-op when the model is already conforming voluntarily.

What v3 does *not* fix: the calibration disagreement on findings F2, F3, F4 between Opus's design-intent reasoning (medium/low/low) and the local model's CVSS-conservative reasoning (high/medium/high for qwen3.6; medium/high/high for coder-next). The model picks consistently within the enum but picks the *more conservative* enum value because its prior on "what severity means" treats arbitrary code execution and supply-chain exposure as inherently elevated, regardless of qualifier text in the input. An enum constraint cannot move that prior.

This narrows the path to closing the residual gap considerably. Three of the four levers practitioners commonly cite (thinking-off, one-shot example, atomic per call) are already applied in v2. The fourth (format: schema) is now empirically disconfirmed for this workload. What's left is calibration — and calibration is content-shaped, not format-shaped:

- **Calibration via prompt examples.** A one-shot example whose finding text says "this is intentional in single-user dev" and whose expected output is `severity: medium` would teach the model to weight intent qualifiers over CVSS conventions. v2's example used a hardcoded-credentials finding with severity `high` — exactly the prior the model already has, so it didn't help. A counterintuitive example (a "scary-looking" behaviour rated low because the input says it's intentional) is the test.
- **Director-side reweighting.** Opus accepts the model's raw severity, then applies its own design-intent rule and overrides specific cells. This moves the calibration into the director, which is correct under the local-brain insight: local models classify, the director judges.
- **Bigger models are not the answer.** v2 showed coder-next (51GB) only marginally better than qwen3.6 (38GB) on st1 (3/5 vs 2/5), and the parent retrospective surveyed evidence that bigger models often make calibration worse (qwen3.5:122b worst on T3; qwen3-next:80b breaking format on T2). Scaling won't close this gap.

## What this means for the skill

`delegate.sh` does *not* need a `format:` parameter for closed-form classification on these workloads, because v2's prompt discipline already gets the model to produce conformant JSON. The Phase 10 ROADMAP item to add `format: schema` should be downgraded — it would not have moved any of the measured numbers in this experiment. The HTTP-API switch is still worth doing for other reasons (cleaner output capture, removes the spinner-stripping plumbing) but not for schema enforcement.

The experiment also produces an unexpectedly clean disconfirming signal on Ollama issue [#14645](https://github.com/ollama/ollama/issues/14645) — the bug report says `format` is silently ignored when thinking is disabled for Qwen3.5-family models. Our probe with `think:false` and `format:schema` returned valid schema-conformant JSON, so the bug either doesn't affect qwen3.6 / qwen3-coder-next (different family/version) or has been fixed in a recent Ollama. Worth noting in the upstream issue if the maintainer ends up filing the contribution.

## Bottom line

Negative results are useful when they remove a candidate. Format-schema is removed. The remaining calibration gap requires a *content* intervention (calibration examples) or a *director* intervention (Opus reweighting), not a *format* intervention. v3 also confirms the v2 picture: with the disciplined defaults already shipped in `delegate.sh` and `SKILL.md`, qwen3-coder-next 51GB is at 3.6/4 of Haiku-quality on this workload at sub-cent cost — and that's the empirical floor for local closed-form delegation in 2026.

## Future work (priority-reordered after v3)

1. **Counterintuitive one-shot example test.** Re-run sub-task 1 with the example finding being "scary-looking but intentional → severity medium" and measure whether it shifts the model's calibration on F2/F3/F4. Cheapest experiment to run; tests calibration-by-prompting hypothesis.
2. **Director-side severity reweighting pattern.** Document in SKILL.md as the recommended pattern when calibration matters: delegate raw severity, then have the director apply qualifier-aware adjustments. No code change, just guidance.
3. **HTTP-API switch in `delegate.sh`.** Still worth doing for output-capture cleanliness, but its priority drops since `format` doesn't add value here.
4. **`format:schema` for non-classification work.** May still help on other shapes (long structured extractions where the model might forget a field). Test before generalising.
5. **Smaller-model test (14B).** Untouched by v3. Still worth running to see if discipline-not-size holds.
