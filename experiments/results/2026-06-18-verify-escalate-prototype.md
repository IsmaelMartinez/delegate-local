# 2026-06-18 — Verify-and-escalate prototype

Backend: MLX (`mlx_lm.server`, localhost:8080). Decoding: greedy (temperature 0), `enable_thinking:false`. Reproduce with `experiments/escalate-eval.sh`. Decision record: `docs/adr/0019-verify-and-escalate.md`. Complements the fan-out negative result (ADR 0018, landing via PR #317).

Mechanism: run the cheap model, score with `experiments/score-t*.sh`, and escalate to the strong model only when the score is below the threshold (1.0 = perfect structural pass).

## Results

| Task | cheap model | cheap score / latency | escalated? | strong score / latency | verdict | total latency |
|---|---|---|---|---|---|---|
| T6 (regex) | Qwen3-0.6B | 0.50 / 0.2s | yes → Coder-30B | 1.00 / 3.8s | FIXED | 4.0s |
| T5 (JSON) | Qwen3-0.6B | 0.67 / 1.0s | yes → Coder-30B | 1.00 / 3.2s | FIXED | 4.2s |
| T4 (commit) | Qwen3-0.6B | 1.00 / 0.8s | no | — | PASS on cheap | 0.8s |
| T4 (commit) | Qwen3-Coder-30B | 0.857 / 4.0s | yes → 35B | 0.857 / 23.9s | NO CHANGE | 27.9s |

## Readings

Verify-and-escalate recovers capability failures cheaply: T6 and T5 go from failing on the 0.6B to a perfect structural pass by escalating to the 30B, at ~4s total. The cost is asymmetric — a task the cheap model passes (T4 on the 0.6B) pays only 0.8s and never loads the strong model, so average latency stays near the cheap model's.

It does not help, and wastes the most time, when the failure is a shared systematic style issue rather than a capability gap: the T4 padding tail is produced by both the 30B and the 35B, so escalating between them changed nothing and cost 28s. That class of failure belongs to the ADR 0017 auto-strip, not to a bigger model.

A strategic corollary: the 0.6B scores a perfect 1.00 on T4 while the 30B/35B drop a check, because the small model does not add the participial padding tail the big models do. Cheap-first routing is therefore sometimes a quality win on its own — "smallest model sufficient" is not only cheaper but occasionally better. The implication for the production gate (ADR 0019): route the cheapest sufficient model first, escalate only on capability-type checks, escalate to a different model, and bound the escalation cost.
