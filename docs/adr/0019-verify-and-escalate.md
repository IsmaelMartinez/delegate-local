# 19. Verify-and-escalate delegation — prototyped, positive, recommended for a production gate

Date: 2026-06-18

## Status

Accepted. Records a positive prototype result and recommends a gated production implementation. Complements ADR 0018 (fan-out, negative).

## Context

The 2026-06-18 quality investigation tested two levers for lifting local-model output quality. Fan-out (ADR 0018) failed: the MLX backend is deterministic and the benchmark failures are systematic, so drawing N samples gives no lift. This ADR covers the complementary lever the same investigation pointed at — verify-and-escalate — which the data suggested would work where fan-out does not, because the baseline matrix showed different models succeed on different tasks (a capability gap, not a sampling gap).

The idea: run a task on a cheap, fast model; run the deterministic checks the skill already computes; and only when a check fails, escalate to a stronger model — rather than re-prompting the same small model, which both the literature and our own data show self-corrects prose poorly. The cost is asymmetric by construction: tasks the cheap model already passes never pay for the strong model, so average latency stays near the cheap model's while only the failure tail pays for the bigger one.

## Investigation

`experiments/escalate-eval.sh` is the prototype: run the cheap model, score it with the existing `experiments/score-t*.sh` structural scorer, escalate to the strong model only when the score is below a threshold (default 1.0, a perfect structural pass), and report whether escalation recovered the failure and what it cost. It does not touch `delegate.sh`.

The results are clean and consistent. On T6 (regex), the 0.6B model scored 0.50 in 0.2s, escalation to Qwen3-Coder-30B produced 1.00 in 3.8s — fixed, 4.0s total. On T5 (JSON), the 0.6B scored 0.67 in 1.0s, escalation produced 1.00 in 3.2s — fixed, 4.2s total. On T4 (commit-message), the 0.6B scored a perfect 1.00 in 0.8s, so escalation never fired — and notably the tiny model beats the 30B and 35B here, which both drop a check by adding a participial padding tail the small model does not produce. The counterexample confirms the boundary: with Qwen3-Coder-30B as the cheap model (0.857, failing the padding check) escalating to the 35B, the 35B also scored 0.857 — no change, 28s spent for nothing, because the failure is a shared systematic style issue, not a capability gap.

Three findings fall out. Verify-and-escalate genuinely recovers capability failures — the cases where a small model is simply too weak (regex anchoring, JSON schema conformance) and a stronger model is not. The cost is asymmetric and low: tasks that pass cheap cost only the cheap model's latency (sub-second to a few seconds), and only real failures pay the escalation. And escalation does not help — and wastes the most time — when the failure is a style or systematic issue every model shares (the T4 padding tail), which is the domain of the ADR 0017 auto-strip, not a bigger model.

A fourth, strategic finding: "smallest model sufficient" is vindicated and sharpened. The 0.6B is not merely cheaper on T4, it is better, because it does not pad. Cheap-first routing is therefore sometimes a quality win on its own, before escalation even enters.

## Decision

Adopt verify-and-escalate as the next production quality lever, implemented as a gate so it can be switched on and benchmarked (off by default, no regression). The shape: route to the cheapest tier-appropriate model first, run the existing oracle-free output checks, and on a failed check escalate to a stronger tier model.

Four design constraints come directly from the data and must hold in the implementation. Escalate only on capability-type checks (structural conformance, schema validity, regex anchoring), never on shared-style checks like `no_padding_tail` — there a bigger model is no better and can be worse, and the ADR 0017 auto-strip is the correct fix. Route the cheapest sufficient model first, because on some tasks (commit messages) the small model is the higher-quality choice. Escalate to a stronger model, never re-prompt the same one. And bound the escalation cost with a budget/timeout, because the larger reasoning-capable models are ~24–30s, an order of magnitude above the cheap path.

## Consequences

This is the positive complement to ADR 0018's negative: ensembling does not help on this setup, but cheap-first-plus-escalate-on-capability-failure does, cheaply. The harness stays as the benchmark instrument for the production gate. The open design question the implementation must answer is the check-type discrimination — which of the declared `checks:` are capability-type (trigger escalation) versus style-type (do not) — since the current checks block does not carry that distinction. The faithfulness bucket (the 23% no structural check can catch) remains outside this lever's reach and stays with the separate grounding/verify work.
