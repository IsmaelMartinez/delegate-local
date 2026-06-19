# 18. Fan-out (sampled-ensemble) delegation — prototyped, and why it is deferred

Date: 2026-06-18

## Status

Accepted. Records a negative prototype result and the reasons it does not (yet) justify production work. Supersedes nothing; informs any future ensemble or sampling work.

> Superseded — the implementation was archived in the 2026-06-19 lean-core reset (recoverable from tag pre-cleanup-2026-06-19). See ROADMAP.md.



## Context

The 2026-06-18 quality investigation (see ADR 0016 for the re-review method) put a clear number on production quality — about 19% true miss rate, with faithfulness ~23% of problem cases — and asked what an established local-delegation approach does that our naive single-shot path does not. One candidate kept surfacing: fan-out, i.e. draw N generations and merge them (self-consistency / best-of-N), on the theory that a single greedy decode occasionally lands on a bad mode (a hallucinated claim, a padding tail) that a vote or a best-by-checks selection would filter out. The idea was attractive because a latency probe showed the MLX server runs three concurrent requests at ~1.5× the cost of one, so an ensemble looked cheap rather than N-fold. The maintainer had also seen ensembling work before, in earlier local-brain experiments that were dropped only for cost.

This ADR records what the prototype actually found.

## Investigation

`experiments/fanout-eval.sh` is the prototype harness. For a task fixture it runs a single greedy (temperature 0) baseline and N fan-out generations in parallel against the MLX backend, writes the N samples as N "reps" so the existing `experiments/score-t*.sh` scorers grade them, and reports the baseline score, the sample mean, the best-of-N (max — what a best-by-checks merge would select), and for the list-style T3 task a majority-consensus merge. It deliberately does not touch `delegate.sh`; the point was to measure before building.

Three findings, each empirical and reproducible:

First, the installed `mlx_lm.server` build is deterministic per (prompt, temperature) and ignores a per-request `seed`. Three draws at temperature 0.7 — and four draws each with a distinct `seed` — returned byte-identical text. Temperature changes the output relative to greedy, but at a fixed temperature there is no per-request randomness. So temperature-sampling fan-out on this backend produces N identical copies, not an ensemble. Every fan-out run showed `mean == max` for exactly this reason. Self-consistency via sampling is simply unavailable here; the only diversity sources on MLX are prompt-perturbation (vary the prompt per sample) and multi-model (same task across different models).

Second, even with prompt-perturbation diversity injected (each sample gets a distinct "independent attempt: be conservative / double-check / simplest answer" suffix, which does move the deterministic decode onto different text), best-of-N gave zero lift on the fixtures that fail single-shot. Qwen3.6-35B fails T4 (commit-message) on one check, `BODY_NO_PADDING`, and every perturbed sample failed the same check — the model reproduces the participial padding tail it sees in the fixture's own example anchors regardless of framing. Qwen3-0.6B fails T6 (regex) at 50% and stayed at 50% across five perturbed samples — it never produces an anchored pattern with a digit class because it cannot, not because it sometimes forgets. These failures are systematic (capability- or prompt-bound), and best-of-N can only rescue stochastic errors — ones some samples get right. There were none to rescue.

Third, multi-model selection does not beat routing to the strongest fast model on this benchmark. Across the three usable MLX models (the DeepSeek-R1 distill is unusable on the MLX think-off path — it emits reasoning into a separate field and returns empty content), Qwen3-Coder-30B-Instruct was the best all-rounder: T3 100%, T5 100%, T6 100%, T4 86%. A best-by-model ensemble equals that column-max, which equals Coder-30B alone. The one residual failure — T4 padding at 86%, shared by every model — is systematic and is exactly what the auto-strip shipped in ADR 0017 already targets.

A latency caveat also surfaced: three concurrent prompt-perturbed requests to the 35B with a 2048-token budget overran a 300-second curl limit once. Concurrency helps, but heavy prompts on a large model can still be slow, so fan-out is not unconditionally cheap.

## Decision

Do not wire sampling-fan-out into production now. On the current backend and benchmark it produces no measurable quality lift, for a concrete reason: the available generation path is deterministic, the diversity we can inject is prompt-level, and the failures we actually have are systematic rather than stochastic — the regime where ensembling helps least.

The levers the same data does support are recorded for the follow-on work: route quality-sensitive tasks to the strongest fast model (Qwen3-Coder-30B here) rather than the largest; keep the ADR 0017 auto-strip for the systematic padding tail; pursue verify-and-escalate (regenerate on a failed deterministic check, escalating to a stronger model rather than asking a small model to fix its own prose, which the literature and this data both show it does poorly); and match output-format difficulty to model capability (do not ask the 0.6B for a regex).

The prototype harness stays in the tree as a measurement tool, not dead code: it is the instrument to re-test ensembling honestly once the two preconditions exist — a benchmark with harder, genuinely stochastic tasks where a single model is sometimes-right-sometimes-wrong, and either a sampling-capable generation path (a newer `mlx_lm` that honours per-request seed, or accepting the latency of multi-model diversity).

## Consequences

The negative result is durable and cited so the idea is not silently re-litigated: fan-out is not free quality, and the binding reasons are MLX determinism plus the systematic nature of our current failures. The faithfulness bucket (the 23% no structural check can touch) remains open and is not addressed by ensembling on this evidence; it moves to the verify-and-escalate and harder-fixtures work named in the roadmap. The harness also produced a reusable side finding worth keeping in mind for any future sampling work — `mlx_lm.server` here does not randomise per request — and a reminder that the T3 citation-rate scorer rewards terseness (a model that lists fewer concerns scores higher), which makes T3 a poor stochastic-error demonstrator and is itself a fixture-quality item for the harder-benchmark work.
