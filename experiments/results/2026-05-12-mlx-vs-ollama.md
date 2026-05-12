# MLX vs Ollama — same model, same fixtures — 2026-05-12

First apples-to-apples comparison between the two local backends on the same model class. The Ollama tag `qwen3.6:35b-a3b-q8_0` and the HuggingFace MLX repo `mlx-community/Qwen3.6-35B-A3B-8bit` are different quantisations of the same upstream weights at the same precision (8-bit). Run on the reference host (Apple M5 Max, 128 GB unified memory), one backend resident at a time, both starting cold.

Wire shape: PR #112 landed the `/v1/chat/completions` fix earlier today; this run is the first end-to-end verification on the production-tier 35B model.

## Setup

| | Ollama | MLX |
|---|---|---|
| Backend version | ollama 0.21.1 daemon | mlx-lm 0.31.3, `mlx_lm.server --port 8080 --model ...` |
| Model id | `qwen3.6:35b-a3b-q8_0` | `mlx-community/Qwen3.6-35B-A3B-8bit` |
| On-disk size | 38 GB (Q8_0 GGUF) | 35 GB (MLX 8-bit safetensors) |
| Endpoint(s) used | `/api/generate` for T4–T6; `ollama run` CLI for T1–T3 (back-compat with 2026-05-01 baseline) | `/v1/chat/completions` for all six tasks (no CLI exists) |
| Reasoning suppressed | `think:false` on T4–T6 only | `chat_template_kwargs.enable_thinking:false` on all six |
| Reps per task | 3 | 3 |
| Start state | cold (model unloaded before run) | cold (server launched, weights loaded on first request) |

The asymmetric reasoning-suppression is the most important caveat. T4–T6 on both backends use the same API + `think:false` regime — the times and scores are directly comparable. T1–T3 on Ollama use the legacy CLI path with reasoning enabled (matching prior baselines), so the latency numbers there are not apples-to-apples to MLX's API + `enable_thinking:false`. The accuracy comparison on T3 is still meaningful (both produced real claims either way) but the timing comparison on T1–T3 is not.

## Pass rates

| Task | Scorer | Ollama (mean) | MLX (mean) | Notes |
|---|---|---|---|---|
| T1 doc-drift | human (claim count out of 4) | 4 / 4 across all reps | 4 / 4 across all reps | Both perfect, as in every baseline since 2026-04-28. |
| T2 party-config | human (CLEAN vs INCONSISTENT) | 3 / 3 CLEAN | 3 / 3 CLEAN | Both correct. |
| T3 merge-patterns | `score-t3.sh` literal-substring citation rate | 0.47 mean (52 cited / 101 claimed) | 0.00 mean (0 cited / 12 claimed) | See "T3 anomaly" below. |
| T4 commit-message | `score-t4.sh` six structural checks | 1.00 (18 / 18) | 0.83 (15 / 18) | MLX tripped `BODY_NO_PADDING` on all three reps via "This closes the gap …" tail. |
| T5 JSON shape | `score-t5.sh` six checks | 1.00 (18 / 18) | 1.00 (18 / 18) | Both perfect. |
| T6 regex | `score-t6.sh` six checks | 1.00 (18 / 18) | 1.00 (18 / 18) | Both perfect. |

## Latency

Per-rep wall-clock from `DURATION_SEC` in each raw file (3 reps each, T1–T6).

| Task | Ollama (s, mean of 3) | MLX (s, mean of 3) | MLX speedup |
|---|---:|---:|---:|
| T1 doc-drift     | 47.0 | 1.0 | 47× |
| T2 party-config  | 49.7 | 2.0 | 25× |
| T3 merge-patterns | 65.3 | 2.0 | 33× |
| T4 commit-message | 5.7  | 3.0 | 1.9× |
| T5 JSON shape     | 3.7  | 2.0 | 1.8× |
| T6 regex          | 1.0  | 0.7 | 1.5× |
| **Total wall (18 reps)** | **519 s (8 m 39 s)** | **34 s** | **15×** |

T4–T6 use the same API + reasoning-off regime on both backends and show MLX ahead by a modest 1.5–1.9×. That is the load-bearing measurement: at equal-precision weights and equal request shape on this hardware, MLX is meaningfully faster but not order-of-magnitude faster. The 25–47× headline gap on T1–T3 is mostly because Ollama is paying for streaming the full reasoning trace through the CLI — not a property of the model or the runtime.

## Memory

| Backend | Peak resident during inference |
|---|---|
| Ollama | 49 GB (`ollama ps` SIZE column, 100% GPU) |
| MLX    | 36.5 GB (`ps -o rss` on `mlx_lm.server` PID just before shutdown) |

MLX is ~25 % lighter for the same 8-bit model on this host. Consistent with the `docs/install-mlx.md` "10–30 % lighter" claim and with the design note that MLX's KV cache is unified-memory-aware.

## T3 anomaly — scorer rigidity exposed

The headline T3 result (Ollama 0.47 vs MLX 0.00) does not mean MLX hallucinates more. The scorer (`score-t3.sh`) checks whether each `CONCERN | PATTERN` line's `PATTERN` is a literal substring of the dated T3 fixture. The two backends formatted their patterns differently:

- Ollama (CLI, reasoning on) emitted ~30+ pattern lines per rep, many of them embedded in the model's thinking-aloud prose. Some of those literal strings happened to match the fixture (52 of 101 across 3 reps). The 0.47 is partly real, partly artifact of reasoning leak.
- MLX (API, reasoning off) emitted exactly the 4 pattern lines the prompt asked for, but wrapped each path in backticks (`` `src/pages/index.astro` ``). The literal-substring check failed on the wrapping characters even though the underlying paths are real and present in the fixture.

So this is **a scorer–format mismatch, not a hallucination gap**. The deterministic T3 scorer assumes bare paths and the recipe should either tell the model to omit backticks, or the scorer should strip a leading/trailing backtick before checking. Either is a one-line fix; logging as a Phase 7 follow-up.

## T4 finding — recipe needs a "closes the gap" guard

MLX's T4 fails are all the same pattern: every rep ended its body paragraph with the trailing-cliché tail `This closes the gap between asserted hardening and measured accuracy.` That is exactly the kind of padding the recipe's `BODY_NO_PADDING` rule is meant to catch — the regex `clos(es|ing) the (gap|loop)` matched cleanly.

Ollama produced clean bodies on all three reps. The difference is not capability — MLX is clearly capable of writing the body without the padding (it does it in the rest of the commit), it just defaults to that tail more readily on this prompt. The fix is in `prompts/commit-message.md`: promote the "no `closes the gap` / `closes the loop` tail" guard from a regex-only check into a directive in the template body with a contrastive Wrong/Correct one-shot. Same pattern that closed the `(#NN)` suffix gap.

## What this run validates (and doesn't)

It validates that PR #112's `/v1/chat/completions` switch produces real, schema-correct, instruction-following output on the production prose-tier model. T5 and T6 — the two fixtures with the most rigid structural rubrics — score perfectly on both backends. The skill's anti-hallucination guards, the JSON schema directive, and the regex acceptance-test pattern all hold on the MLX path.

It does not yet validate that MLX is the right default for any tier in `pick-model.sh`. The decisive measurement would be a `/api/generate` + `think:false` Ollama T1–T3 run side-by-side with the MLX numbers above. The current `runner.sh` keeps T1–T3 on the CLI path for Ollama for back-compat reasons. Adding `--ollama-api` (or making the API path the default and the CLI path opt-in via a flag) is the next iteration if we want a clean speed comparison on the open-ended tasks.

## Raw outputs

- `experiments/results/raw/qwen3_6_35b-a3b-q8_0.txt` — Ollama, 18 reps
- `experiments/results/raw/mlx-community_Qwen3_6-35B-A3B-8bit.txt` — MLX, 18 reps

## Reproducibility

```bash
# Ollama
bash experiments/run-baseline.sh --backend ollama --reps 3 qwen3.6:35b-a3b-q8_0

# MLX (server preload helps cold-load latency)
mlx_lm.server --port 8080 --model mlx-community/Qwen3.6-35B-A3B-8bit &
bash experiments/run-baseline.sh --backend mlx --reps 3 mlx-community/Qwen3.6-35B-A3B-8bit

# Score
for f in experiments/results/raw/qwen3_6_35b-a3b-q8_0.txt \
         experiments/results/raw/mlx-community_Qwen3_6-35B-A3B-8bit.txt; do
  for s in t3 t4 t5 t6; do
    bash "experiments/score-${s}.sh" "$f" | tail -1
  done
done
```
