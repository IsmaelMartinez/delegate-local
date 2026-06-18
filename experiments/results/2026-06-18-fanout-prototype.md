# 2026-06-18 — MLX baseline matrix + fan-out (sampled-ensemble) prototype

Backend: MLX (`mlx_lm.server`, localhost:8080). Decoding: greedy (temperature 0), `enable_thinking:false` — the production `delegate.sh` default. Scorers: `experiments/score-t{3,4,5,6}.sh`. Reproduce the fan-out cells with `experiments/fanout-eval.sh`. Companion decision record: `docs/adr/0018-fan-out-ensemble-prototype.md`.

## Baseline matrix — all installed MLX models, T3–T6, single greedy shot

| Model | T3 (citation) | T4 (commit, /7) | T5 (JSON, /6) | T6 (regex, /6) | 6-task wall |
|---|---|---|---|---|---|
| mlx-community/Qwen3-0.6B-4bit | 1/1 cited (terse) | 7/7 (100%) | 5/6 (83%) | 3/6 (50%) | 5s |
| lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit | 4/4 (100%) | 6/7 (86%) | 6/6 (100%) | 6/6 (100%) | 16s |
| mlx-community/Qwen3.6-35B-A3B-8bit | 3/4 (75%) | 6/7 (86%) | 6/6 (100%) | 6/6 (100%) | 27s |
| mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit | empty output — unusable on the MLX think-off path | | | | |

Readings: the capable 30–35B MoE models are strong and fast — T5/T6 perfect, T4 dropping one check (`BODY_NO_PADDING`, a trailing participial the model copies from the fixture's example anchors), and faithfulness the one axis where the 35B slips (it hallucinated one of four T3 claims). Qwen3-Coder-30B is the best all-rounder. The 0.6B is below the capability floor for regex. DeepSeek-R1-Distill ignores `enable_thinking:false`, emits reasoning into a separate `.reasoning` field, and returns empty `.content`, so it is unusable on the path the runner and `delegate.sh` use for MLX.

## Latency (warm, capable MoE)

| Operation | Cost |
|---|---|
| single generation, think-off | 1.5–3.5s |
| cold-load (per resident model, once) | ~14–16s |
| thinking ON, reasoning model (Qwen3.6-35B) | ~33s (≈2,700 reasoning tokens) |
| thinking ON, instruct model (Coder-30B) | no-op, ~3.5s |
| 3 requests concurrent vs 1 | ~1.5–1.8× |

So fan-out and retry sit in the few-seconds range; only the reasoning-model thinking path approaches the minute scale, and it is a no-op on instruct models — thinking should be selective, never blanket.

## Fan-out prototype — negative result

Determinism check: at temperature 0.7, three draws of the same prompt returned byte-identical text; with four distinct `seed` values, still byte-identical. `mlx_lm.server` here is deterministic per (prompt, temperature) and ignores per-request seed, so temperature-sampling fan-out produces N copies, not an ensemble. Diversity therefore has to come from prompt-perturbation or from using different models.

Best-of-N with prompt-perturbation diversity, on the tasks that fail single-shot:

| Task / model | baseline (greedy) | best-of-N (perturbed) | verdict |
|---|---|---|---|
| T4 / Qwen3.6-35B, N=3 | 0.857 | 0.857 | no lift — every sample pads (systematic) |
| T6 / Qwen3-0.6B, N=5 | 0.500 | 0.500 | no lift — never anchors (capability floor) |
| T3 / Qwen3.6-35B, N=3 | 1.000 (terse) | n/a | greedy already perfect; consensus found no majority; one run hit the 300s curl limit |

Best-of-N rescues stochastic errors — ones some samples get right. The fixtures' failures are systematic (fixture-induced padding, capability floor), so there was nothing to rescue. Multi-model best-by-checks equals routing to Qwen3-Coder-30B alone. Conclusion and the levers that the data does support (strongest-fast-model routing, the ADR 0017 auto-strip, verify-and-escalate, capability-matched routing) are in ADR 0018.
