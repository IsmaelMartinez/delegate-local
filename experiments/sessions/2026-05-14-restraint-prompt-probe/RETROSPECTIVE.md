# P1 — Restraint prompting probe (T3) — 2026-05-14

ROADMAP follow-up from PR #115's MLX-vs-Ollama v2 baseline. The v2 measurement showed Ollama (with `think:false`) voluntarily emitting only 1 T3 claim per rep at 100% citation, while MLX on the same weights filled the cap (4 claims/rep) at 75% citation. This probe asked whether the difference is driven by the prompt or by the runtime.

## Hypothesis

> Explicit "prefer fewer claims you are confident about" wording pulls MLX toward Ollama's voluntary restraint posture without losing citation accuracy. If yes → recipe-authoring guideline. If no → restraint is a runtime property and we have learned that.

## Design

Four cells against `experiments/fixtures/task-3-merge-patterns-2026-04-28.txt`, three reps each, identical wire shape to PR #115's v2 baseline (Ollama `/api/generate` `think:false`, MLX `/v1/chat/completions` `enable_thinking:false`, temperature 0 on both):

```
            base prompt              restraint prompt
Ollama      qwen3.6:35b-a3b-q8_0     qwen3.6:35b-a3b-q8_0
MLX         Qwen3.6-35B-A3B-8bit     Qwen3.6-35B-A3B-8bit
```

Base prompt is verbatim from `experiments/runner.sh:289` — "List up to 4 specific concerns ... If nothing is reliably checkable, output: NONE. Do not speculate beyond what the commit subjects state." Restraint prompt appends "Prefer fewer claims you are confident about over filling the cap. Listing one well-supported concern beats listing four speculative ones. Output only the concerns the commit subjects directly support."

Scored with `experiments/score-t3.sh` (PR #114's backtick-aware citation matcher) — same scorer used in the v2 baseline so the numbers are directly comparable.

## Results

| Cell | Claims / rep | Cited / claimed (3 reps) | Mean citation rate |
|---|---:|---:|---:|
| Ollama base | 0 (NONE all 3) | 3 / 3 | 1.00 |
| Ollama restraint | 4 | 9 / 12 | 0.75 |
| MLX base | 4 | 9 / 12 | 0.75 |
| MLX restraint | 4 | 12 / 12 | 1.00 |

Wall times were 1–11s per rep across all cells (cold-load on Ollama base rep 1, warm thereafter). Variance was zero on all four cells across three reps — at temperature 0 with the same wire shape the decoders are deterministic.

## What the data says

The hypothesis predicted a binary outcome (restraint is a prompt property or a runtime property). The data shows neither, and instead splits restraint along two independent axes.

The verbosity axis (how many claims the model emits) is not controllable through this restraint wording. MLX stayed at the cap (4/rep) regardless of prompt. Ollama moved in the opposite direction predicted, jumping from 0 claims (NONE) under the base prompt to 4 claims under restraint. The "Listing one well-supported concern beats listing four speculative ones" clause reads as an implicit invitation to enumerate, and Ollama took the invitation. If the goal is fewer claims, the prompt needs a hard cap ("List exactly one concern, the most important") rather than a permissive comparison.

The citation-anchoring axis (cited / claimed ratio per rep) is partially controllable. MLX's citation rate moved from 0.75 to 1.00 with the restraint wording — every claim now anchored to a concrete file or pattern, no fabricated references. That is a pure quality win at no cost. Ollama's apparent drop from 1.00 to 0.75 is a measurement artefact of the cap-fill shift, not a reasoning regression: the model went from emitting one safe answer (NONE) to emitting four substantive claims of which three are cited.

The Ollama base reproduction is slightly more conservative than the v2 baseline characterisation. v2 measured "exactly 1 claim per rep, all supported"; this probe measured 0 claims (NONE) for all three reps on the same model and wire shape. That's the model sitting on the boundary between the two safest postures (NONE vs one-cited-claim) and falling slightly to the NONE side on this run. It does not change the cross-cell comparison since the citation rate ceiling is the same in both shapes.

## Implication for recipe authoring

The "fewer claims" framing alone is not a useful prompt lever — it does not reduce verbosity on either backend, and on Ollama it can paradoxically push toward cap-filling. The "anchor every claim to evidence" framing IS a useful lever, and the existing restraint clause already delivers it on MLX (0.75 → 1.00 citation rate). Future recipes where citation accuracy is the load-bearing quality dimension (release-note bullets that name specific PRs, pr-description retrospectives that cite commits, summarise-issue findings that quote the original report) should include an explicit "anchor every claim to a concrete reference in the input" reinforcement. The wording does not need the "fewer beats more" framing to deliver the anchoring effect — that framing carries a verbosity-permissive side-effect on Ollama-style models without delivering the verbosity-reducing primary effect.

## Decision

Restraint is a runtime property on the verbosity axis (claim count) and a prompt property on the citation-anchoring axis. The original recipe-authoring guideline ("prompts should explicitly invite restraint by saying 'fewer claims you're confident about beats more claims you're not'") is rejected — the data shows the inverse on Ollama. The replacement guideline is recorded in this retrospective: for citation-quality dimensions, an explicit anchoring clause helps; for verbosity dimensions, only a hard cap helps.

No skill or recipe edit ships from this probe. The finding lands as documentation only. The trigger for promoting the anchoring clause into a specific recipe (`prompts/release-note.md`, `prompts/pr-description.md`, `prompts/summarise-issue.md`) is the next real-session MISS attributable to fabricated references in those tasks — same trigger-driven discipline the rest of the prompts library uses.

## Reproducibility

```bash
# Both backends running on the reference host:
#   - Ollama 0.21.1 daemon with qwen3.6:35b-a3b-q8_0 available
#   - mlx_lm.server with mlx-community/Qwen3.6-35B-A3B-8bit preloaded
bash experiments/sessions/2026-05-14-restraint-prompt-probe/runner.sh
for f in experiments/sessions/2026-05-14-restraint-prompt-probe/runs/*.txt; do
  echo "===== $(basename "$f") ====="
  bash experiments/score-t3.sh "$f"
done
```

Raw outputs live in `runs/` (one file per cell, four total).
