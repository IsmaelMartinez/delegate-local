# Calibration history for [`prompts/code-draft.md`](../../prompts/code-draft.md)

## Calibration notes

Seeded 2026-06-22 from the supervised-draft-delegation design spec
(`docs/superpowers/specs/2026-06-22-supervised-draft-delegation-design.md`, G2)
and ADR 0025. Unlike the prose recipes, this one ships with no verbatim-HIT
calibration history yet — it is the recipe arm of an explicit experiment. Its
guards are anchored in the documented code-delegation failure modes already in
SKILL.md (invented APIs, the prose/code REFUSE contradiction from the
2026-05-04 adversarial probe, code-tier sequence-extension artefacts), not in
this recipe's own MISS log. The evidence gate (spec G5) measures whether
`hit + scaffold` verdicts on `code-draft` delegations clear a clear-majority
bar over a window of at least ~10 calls; if they do not, ADR 0025's kill path
reverts this recipe and the SKILL.md doctrine while keeping the scaffold verdict.
Record every `code-draft` verdict (`hit` / `miss` / `scaffold`) so that gate has
data — the calibration history below grows from those rows as they accrue.
