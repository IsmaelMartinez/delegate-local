# 2026-06-05 — Reasoning-tier audit: Qwen3-Next-80B-A3B-Thinking → REJECT

Topic A's corrected first action (ROADMAP, hardware-gated via `llmfit`): audit `Qwen3-Next-80B-A3B-Thinking` — `llmfit`'s top hardware-fitting reasoning candidate (composite 97.9, ~84 GB at q8) — against the `deepseek-r1:32b` MLX-distill incumbent. Verdict: **REJECT**. Keep the incumbent; `pick-model.sh` prefs unchanged.

## Setup

Pulled `qwen3-next:80b-a3b-thinking-q8_0` (84 GB, the 8-bit quant matching the incumbent's 8-bit level) and ran `scripts/model-change-audit.sh qwen3-next:80b-a3b-thinking-q8_0 reasoning`. The MLX prose server was stopped during the run so the 84 GB model had headroom on the 128 GB host (it auto-restarts via its launchd KeepAlive agent afterwards). Candidate ran via Ollama with `think:false` dispatch, 3 reps per task.

## Results

| Gate | Result | Verdict |
|---|---|---|
| Trigger eval (`--ollama`) | recall 0.905, negative-precision 1.000 | PASS |
| T4 commit-message | 0.50 (incumbent 0.83) | FAIL |
| T5 JSON-shape | 0.00 (incumbent 1.00) | FAIL |
| T6 regex-generation | 0.00 (incumbent 0.00 — artifact) | non-discriminating |
| Chat-template diff | `<think>` blocks + default system prompt + tool-call surface | DIVERGES |

## Root cause — unstrippable reasoning trace

The failure is not a capability gap: the model's reasoning and final answers are correct. On the T5 JSON task it produced a long plain-text reasoning trace, closed it with `</think>` (the opening `<think>` is prefilled server-side by the chat template, so no opening tag appears in the output), then emitted perfectly valid, correct JSON — `{"owner":"ismael","items":[...3 correct items...]}`. The problem is the output shape: `think:false` did NOT suppress the trace, it only affected tag emission, so every structured-output response carries a reasoning dump before the answer. The deterministic scorers can't parse JSON behind a reasoning preamble (T5 → 0.00), and the same pollution disrupts the commit-message structural checks (T4 → 0.50). This is the same class of failure SKILL.md documents for `phi4-reasoning` (`<think>` breaks parsers); routing the reasoning tier here would break the structured recipes (JSON extraction, `ci-log-triage`, etc.).

The incumbent `deepseek-r1:32b` distill, served via MLX with `enable_thinking:false`, suppresses its trace cleanly (T5 1.00) — which is exactly why it remains the right reasoning model. T6 0.00 on both is a scorer-side artifact (chain-of-thought wrapping trips the single-line regex), not a discriminator.

## Methodological note

The audit's auto-comparison fell back to the 0.80 absolute floor rather than the incumbent's measured numbers: with the MLX server stopped for memory, `pick-model.sh reasoning` resolved the Ollama `deepseek-r1:32b` (which has no baseline raw at `experiments/results/raw/deepseek-r1_32b.txt`) instead of the MLX distill. The candidate fails both the 0.80 floor and the MLX incumbent's actual scores (T4 0.83 / T5 1.00), so the REJECT is robust either way — re-running with MLX up would only sharpen a comparison that already fails decisively.

## Decision and future lever

REJECT — `deepseek-r1:32b` (MLX distill) stays as the reasoning incumbent. `gpt-oss-120b` (llmfit 97.2, fits at 4-bit) remains the only untested fitting candidate from the 2026-06-05 `audit-models.sh` run.

Worth recording: this model is *recoverable* by a wrapper-side strip of everything up to and including the last `</think>` — its final JSON was clean and correct. A deterministic think-trace strip in `delegate.sh` would make trace-emitting reasoning models adoptable and is adjacent to Topic F's wrapper-side-strip idea. Deferred — the incumbent already works, and the strip is its own change with its own test surface. Raw output: `experiments/results/raw/qwen3-next_80b-a3b-thinking-q8_0.txt`; trigger eval: `evals/results/20260605T202450Z-ollama.jsonl`.
