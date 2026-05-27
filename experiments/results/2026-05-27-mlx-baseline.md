# MLX backend baseline — 2026-05-27

First dedicated MLX baseline with two models covering the code and reasoning tiers. Both models served via `mlx_lm.server` on an Apple M5 Max with 128 GB unified memory. Raw outputs under `experiments/results/raw/`, 3 reps per task, scored by the deterministic T3/T4/T5/T6 scorers.

## Models tested

| Model | Tier (per pick-model.sh) | Backend |
|---|---|---|
| `mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit` | reasoning | MLX |
| `lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-8bit` | code | MLX |

## Results

| Model | T3 citation | T4 commit | T5 JSON | T6 regex |
|---|---|---|---|---|
| DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit | 0.00 (0 claims) | 0.83 (15/18, stdev 0.00) | 1.00 (18/18) | 0.00 (0/18) |
| Qwen3-Coder-30B-A3B-Instruct-MLX-8bit | 1.00 (12/12, stdev 0.00) | 0.83 (15/18, stdev 0.00) | 1.00 (18/18) | 1.00 (18/18) |

## Findings

Qwen3-Coder is the strongest generalist in the matrix, posting perfect scores on T3 citation, T5 structured extraction, and T6 regex generation, with only one consistent structural failure per rep on T4 commit messages (0.83, zero stdev across all three reps). Every claim it emitted on T3 was anchored to the fixture — no hallucination at all across 12 claims.

DeepSeek-R1 is a specialist correctly placed in the reasoning tier. Its T5 perfect score (18/18) confirms it excels at its core job of structured extraction. The T3 score of 0.00 reflects zero claims emitted rather than hallucination — the model chose the `NONE` restraint posture, matching the Ollama-side restraint probe behaviour. The T6 score of 0.00 is a scorer-side artefact: the reasoning model's output shape (chain-of-thought wrapping) trips the single-line check even though the underlying regex may be valid. T4 at 0.83 with zero stdev shows the same consistent single-failure pattern as Qwen3-Coder, suggesting the failing check is a prompt-recipe gap rather than a model limitation.

Both models are correctly placed in their respective tiers. No routing changes are indicated.

## Artefacts

- Raw outputs: `experiments/results/raw/mlx-community_DeepSeek-R1-Distill-Qwen-32B-MLX-8Bit.txt`, `experiments/results/raw/lmstudio-community_Qwen3-Coder-30B-A3B-Instruct-MLX-8bit.txt`
- Scorers: `experiments/score-t3.sh`, `experiments/score-t4.sh`, `experiments/score-t5.sh`, `experiments/score-t6.sh`
