# size-floor test: does directive-rule survive below the 19 GB v6 winner?

**Date:** 2026-05-04
**Parent:** `../2026-05-03-smaller-model-test/RETROSPECTIVE.md` (v6 baseline)
**Hypothesis:** v6 pegged `deepseek-r1:32b` (19 GB) as the smallest model to hit Opus parity (5/5) on the v5 hard-rule severity-classification prompt. Direct-family scale-down (`qwen3-coder:30b` at 32 GB) broke it, but that was a different family from the 51 GB winner. Can the directive-rule pattern hold *within* the reasoning family at half the weights?

## Setup

Same v5 prompt as v6 (`../2026-05-03-calibration-example-probe/subtask-1-severity-v5.txt`), same scoring (5 findings × severity enum `high/medium/low/info`, ground truth derived from design-intent qualifiers in the input text). 1 model × 3 reps = 3 cells.

Target: `deepseek-r1:14b` (9.0 GB). Natural within-family scale-down from the v6 reasoning-tier winner. `qwen3.5:14b` does not exist on the Ollama library — the qwen3.5 ladder is 0.8b / 2b / 27b / 35b / 122b, no 14b tag, so the probe is single-model.

All discipline from v5-v7 applied verbatim: `think:false`, `temperature:0`, `stream:false`, no schema, same prompt bytes. Runner uses `experiments/lib/run_api_cell.sh` so the Phase 8 metrics rollup captures the cells (new since v6; first post-#34 experiment to exercise it).

## Result

| model            | size   | r1  | r2  | r3  | mean | stdev | verdict |
|------------------|--------|-----|-----|-----|------|-------|---------|
| deepseek-r1:14b  | 9.0 GB | 3/5 | 3/5 | 3/5 | 3.00 | 0.00  | partial |

Deterministic (byte-identical output across reps, stdev 0 on both scores and output bytes). The model emits valid JSON in the enum on every rep, so the failure isn't format — it's calibration propagation.

Per-finding breakdown:

| finding | ground truth | deepseek-r1:14b | got it? |
|---|---|---|---|
| F1 | medium | medium | ✓ |
| F2 | medium | high | ✗ |
| F3 | low    | low    | ✓ |
| F4 | low    | medium | ✗ |
| F5 | info   | info   | ✓ |

F2 and F4 are both findings whose "design-intent qualifiers in the input" trigger the directive cap (medium). The 14b model applied the cap to F1 (correctly medium-capped from a scarier base) but failed to propagate the rule to F2/F4, defaulting to CVSS-conservative severities instead. Same failure shape as `qwen3-coder:30b` (2/5) and `gemma4:latest` (2/5) on the v6 baseline: clean format compliance, no cross-reference reasoning.

## Timing

Cold-load 5.5 s (r1), warm ~1.5 s (r2/r3). The 14b beats the 19 GB deepseek-r1:32b on raw latency by ~2-3× (v6 recorded 4-5 s warm for the 32b), which is expected and reflected in the Phase 8 metrics (`tail -3` of `~/.claude/skills/delegate-local/metrics.jsonl` after this run shows three experiment-tagged cells, `prompt_tokens:459`, `eval_tokens:73`). Cheap cells, but the partial-score is the problem — a fast wrong answer isn't a useful trade.

## Interpretation

The v6 retrospective framed the discriminating axis as "reasoning architecture, not parameter count". v6 tested the claim *across families* (deepseek-r1 vs phi4-reasoning vs gemma4 vs the qwen3-coder pair). The size-floor probe tests it *within* the winning family and finds the claim bounded: reasoning architecture gets you into parity territory but doesn't survive a 2× weights cut. deepseek-r1 at 19 GB hits parity; at 9 GB it drops to the same level as the no-reasoning families at comparable size.

Concretely: this places the size floor for the directive-rule severity pattern between 9 and 19 GB within the deepseek-r1 family. Without a 14-18 GB intermediate tag on the Ollama library there's no easy way to bracket it more tightly right now.

Two things v6 still owns that v8 and this test don't change:

1. `pick-model.sh` should keep `deepseek-r1:32b` as the top reasoning-tier preference. Demoting to the 14b would save ~10 GB VRAM and ~3× per-cell latency but cost 40% of the correctness.
2. `phi4-reasoning:plus` (11 GB, 3.33/5 on v6) is no longer meaningfully beaten by deepseek-r1:14b (9 GB, 3.00/5). Both score "partial" at roughly the same rate. If a machine is VRAM-constrained and can only hold a single ~10 GB reasoning model, the choice between the two becomes wall-time (phi4 much slower due to in-band `<think>` tokens that bypass `think:false`) rather than accuracy.

## What this means for the skill

No `pick-model.sh` change. The shipped reasoning-tier order is still correct. The reasoning preference stays as: deepseek-r1 > phi4-reasoning > ... (landed in PR #27 from v6).

ROADMAP Phase 10 line "Smaller still: pull and test deepseek-r1:14b or qwen3.5:14b to find the size floor for the directive-rule pattern" can be marked done with this retrospective as the answer: floor is above 9 GB within the deepseek-r1 family, and since no 14b / 18b intermediate exists today, the question is answered as precisely as the market allows.

## Future work

1. **Bracket tighter if a 14b or 18b reasoning model ships.** An intermediate tag would localise the floor to a narrower weights range; right now we know it's in (9, 19) GB within the deepseek-r1 family.
2. **Cross-family size-floor.** Would a 14b qwen3-coder-next variant (same family as the v5 winner) score higher than the 14b deepseek-r1? Currently untestable — qwen3-coder-next is only distributed at 51 GB.
3. **Probe the phi4-reasoning vs deepseek-r1:14b tie at 9-11 GB.** v6 showed phi4-reasoning variance (4/3/3 across reps) while v8-probe and this size-floor both showed deepseek-r1:14b as deterministic. If constrained to a single ~10 GB reasoning model, deterministic-partial might be more useful than variance-partial — worth a side-by-side at stdev level before recommending one over the other.
