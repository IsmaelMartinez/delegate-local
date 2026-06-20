# 24. The commit-message padding ceiling is model-dependent, not recipe-tunable

Date: 2026-06-19

## Status

Accepted. Records a learning that, until this ADR, lived only in the archived
`experiments/results/2026-06-03-baseline.md` and `2026-06-15-gpt-oss-120b-prose-audit.md`
retrospectives (recoverable from tag `pre-cleanup-2026-06-19`).

## Context

The `commit-message` recipe's deterministic `no_padding_tail` (T4 `BODY_NO_PADDING`)
check is the recipe's most stubborn failure. The 2026-06-03 all-tiers baseline
found it failing on all three installed MLX models (Qwen3-Coder-30B, Qwen3.6-35B,
DeepSeek-R1) with essentially zero variance — exactly one check failing per
repetition, every time. That zero-variance, all-models signature means the
failure is not a quirk of one model; the models are each faithfully copying the
participial-tail padding shape from the one-shot example in the prompt, and the
recipe's anti-padding directive has proven unable to move the ceiling.

The 2026-06-15 gpt-oss-120b prose audit then showed the ceiling *is* movable by
model, not by prompt: gpt-oss-120b cleared `no_padding_tail` (1.00 vs the
incumbent ~0.83) where the smaller models could not. So the lever is the model,
not more prompt engineering.

## Decision

The padding ceiling is accepted as model-dependent and is **not** chased with
further anti-padding prompt iteration on the current models — that path is
measured-exhausted. Per-recipe model routing (sending `commit-message`
specifically to a padding-clearing model) is acknowledged as the real lever but
is **not adopted**, because the routing architecture is per-tier (not
per-recipe) by design, and the only model shown to clear the ceiling carries a
~2–3× slower API path and a ~65GB footprint that does not justify the gain for a
commit-message. The mitigation that ships instead is ADR 0017's auto-strip,
which removes the safe padding tail deterministically after generation rather
than trying to prevent it in the prompt.

## Consequences

This is the durable reason `no_padding_tail` failures on `commit-message` are
expected and handled by auto-strip rather than treated as a recipe bug to be
prompt-fixed. If a padding-clearing model ever lands in a tier at acceptable
cost, per-recipe routing becomes worth revisiting — this ADR is the record of
the trade-off so that revisit starts from the evidence rather than rediscovering
it. The raw per-model check results are recoverable from the archived baselines.
