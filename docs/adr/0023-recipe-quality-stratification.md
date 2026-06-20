# 23. Recipe-quality stratification — universal/extraction recipes outrun taste-calibrated prose recipes

Date: 2026-06-19

## Status

Accepted. Records a learning that, until this ADR, lived only in the archived
`experiments/results/2026-06-10-quality-trend.md` retrospective (recoverable from
tag `pre-cleanup-2026-06-19`).

## Context

Aggregate production quality (hit-rate across all delegations) sat around 80% at
the 2026-06-10 measurement, which on its own suggests "tune everything a bit
more". The quality-trend analysis showed that the 80% hides a two-tier split:
the universal, extraction-shaped recipes (file-summary, bulk-file-summary,
summarise-issue, ci-log-triage) ran near 90%, while the taste-calibrated prose
recipes (commit-message, doc-section, pr-description) ran near 70%. The two
populations behave differently because extraction is constrained by the input
(the model copies facts) whereas prose generation is constrained by style
calibration (the model must match a voice and avoid padding).

A second, compounding fact from the same trend: verdicts were recorded on only
about 60% of delegations, so the measured distribution rests on barely half the
evidence. Coverage, not raw quality, is the binding constraint on knowing where
to invest.

## Decision

Recipe-calibration effort is prioritised toward the taste-calibrated prose
recipes, because that is where the headroom is — the universal/extraction recipes
are already near their ceiling and further prompt-tuning there yields diminishing
returns. Raising verdict coverage above ~60% is treated as the prerequisite
measurement work, since the stratification can only be trusted as far as the
coverage allows.

## Consequences

This is the durable reason the calibration loop (the kept `delegate-feedback.sh`
→ `metrics-summary.sh` per-recipe hit-rate surface) matters more for the prose
recipes than the extraction ones, and why "the aggregate hit-rate went up/down"
is not actionable without the per-recipe split. It also frames the open
"deeper recipe prune" decision: the low-usage tail is mostly extraction-shaped
and near-ceiling, so pruning it costs little quality. The raw per-recipe trend
data is recoverable from the archived results.
