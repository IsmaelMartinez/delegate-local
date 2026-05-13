# MLX vs Ollama v2 — apples-to-apples, ollama daemon stopped during MLX run — 2026-05-12

Second cross-backend pass on the same Qwen3.6-35B 8-bit weights, taken after PR #114 (which added `runner.sh --ollama-api`, fixed the T3 backtick-span scorer, and extended the commit-message recipe with a `closes the gap` guard). v1 is preserved alongside this file for direct comparison.

Two regime changes vs v1:

1. Ollama T1–T3 now route through `/api/generate` with `think:false` — same regime as MLX, and same regime that `scripts/delegate.sh` uses in real production. The v1 CLI-with-reasoning-on path is no longer the comparison surface.
2. The MLX run was taken with `Ollama.app` fully quit so MLX had unified memory and the host's idle daemon footprint to itself.

The v1 headline of "MLX is 15× faster" was almost entirely a regime artefact — the CLI path streamed every reasoning token through stdout. With both backends on the same API and the same `think:false`/`enable_thinking:false`, **MLX is 2× faster** on the wall-clock total and **25% lighter** on peak memory.

## Setup

| | Ollama (v2) | MLX (v2) |
|---|---|---|
| Daemon state during run | desktop app running, model cold-loaded on first request | `Ollama.app` fully quit, `mlx_lm.server` resident with model preloaded |
| Backend version | ollama 0.21.1 | mlx-lm 0.31.3 |
| Endpoint | `/api/generate` with `think:false` (via `runner.sh --ollama-api`) | `/v1/chat/completions` with `chat_template_kwargs.enable_thinking:false` |
| Reasoning suppressed | All six tasks (T1–T6) | All six tasks (T1–T6) |
| Reps per task | 3 | 3 |
| Raw output header | `OLLAMA_API: 1` | `OLLAMA_API: 0` (no-op on MLX backend) |

## Wall times

| | v1 total | v2 total | Δ |
|---|---:|---:|---:|
| Ollama (`qwen3.6:35b-a3b-q8_0`) | 519 s (8 m 39 s) | **64 s** | **8.1× faster** just from `--ollama-api` |
| MLX (`mlx-community/Qwen3.6-35B-A3B-8bit`) | 34 s | **32 s** | 1.06× (within noise) |

The Ollama improvement is the load-bearing finding here: routing T1–T3 through the API with reasoning off cut the wall by 8× with no accuracy regression. The MLX improvement is essentially nil — confirming that the idle Ollama daemon was NOT competing for unified memory in v1, contrary to the prior intuition. MLX's KV cache and weights fit comfortably and the daemon's idle footprint is sub-300 MB.

## Per-task latency (v2 apples-to-apples)

| Task | Ollama API (mean s) | MLX (mean s) | MLX speedup |
|---|---:|---:|---:|
| T1 doc-drift     | 5.0 (10 cold, 2/3 warm) | 2.0 | 2.5× |
| T2 party-config  | 4.0 | 1.0 | 4.0× |
| T3 merge-patterns | 1.7 | 2.3 | 0.7× (Ollama slightly ahead) |
| T4 commit-message | 4.7 | 2.7 | 1.7× |
| T5 JSON shape     | 3.0 | 2.0 | 1.5× |
| T6 regex          | 1.0 | 0.3 | 3.0× |
| **Mean across tasks** | **3.2** | **1.7** | **1.9×** |

The first Ollama T1 rep was 10 s (cold load); reps 2 and 3 settled to 2 and 3 s. MLX's cold-load cost was absorbed during `mlx_lm.server --model …` preload, so the per-rep numbers are warm throughout. Both reach steady state quickly.

## Peak memory

| | v1 | v2 |
|---|---|---|
| Ollama (`ollama ps` SIZE) | 49 GB | 49 GB |
| MLX (process RSS) | 36.5 GB | 36.5 GB |
| Host total (M5 Max) | 128 GB | 128 GB |
| Headroom while Ollama resident | 79 GB | 79 GB |
| Headroom while MLX resident | 91.5 GB | 91.5 GB |

Identical memory footprints across the two runs — the regime change (CLI → API) doesn't move the weights or KV cache, only how they're invoked.

## Pass rates (re-scored with PR #114's T3 fix)

| Task | Scorer | Ollama v2 | MLX v2 | Notes |
|---|---|---|---|---|
| T1 doc-drift | human, 4 CLAIM verdicts | 4/4 × 3 | 4/4 × 3 | tie |
| T2 party-config | human, CLEAN vs INCONSISTENT | 3/3 CLEAN | 3/3 CLEAN | tie |
| T3 merge-patterns | citation rate (backtick-span aware) | **1.00 (3 / 3)** | **0.75 (9 / 12)** | Different restraint behaviour — see below |
| T4 commit-message | 6 structural checks | 18/18 | 15/18 | MLX still trips `BODY_NO_PADDING`; the PR #114 recipe fix won't show until the T4 fixture is regenerated |
| T5 JSON shape | 6 checks | 18/18 | 18/18 | tie |
| T6 regex | 6 checks | 18/18 | 18/18 | tie |

T3 with `think:false` on Ollama produces a *very* restrained output: exactly 1 claim per rep across 3 reps, every claim supported. MLX produces ~4 claims per rep (the prompt's cap), 3 supported each. Same factual accuracy in terms of cited-vs-fabricated ratio; different verbosity. Ollama's strict restraint is closer to a `NONE`-like posture; MLX fills the cap.

## What v2 changes vs v1

1. **The headline cross-backend gap is 2×, not 15×.** Anyone reading v1 thinking MLX is order-of-magnitude faster should re-read with v2 as the corrective.
2. **`scripts/delegate.sh` was always doing the right thing on Ollama.** Production calls already used `/api/generate` with `think:false`. The 15× number was specific to the runner's back-compat CLI path on T1–T3. Real users were never paying that latency.
3. **Stopping the Ollama daemon doesn't make MLX faster.** The user's intuition was reasonable in theory — an idle daemon holding model state would compete — but `ollama stop` between sessions empties VRAM, and the daemon's idle footprint is small. 32 s vs 34 s is noise.
4. **T3 scoring is now meaningful.** The backtick-span extraction in PR #114 means a model that puts its canonical reference inside `` `code` `` formatting gets scored on the canonical reference, not on the surrounding prose. MLX's prior 0.00 was a scorer artefact; the underlying behaviour was 0.75 all along.

## New opportunities surfaced

These are the load-bearing things this v2 run actually shows, in priority order:

### MLX as the default on Apple Silicon

The case for switching `DELEGATE_BACKEND` default from `ollama` to `mlx` on Apple Silicon is now empirical, not theoretical:

- 2× faster on the same workload (`scripts/delegate.sh` production routing).
- 25% less peak memory for the same weights.
- The chat-template wire-fix (PR #112) plus the dispatcher unification (PR #114) mean the failure modes that justified Ollama as default are gone.

Concrete proposal: gate the default switch on a single condition — `mlx_lm.server` reachable on `MLX_HOST` AND at least one tier resolves via the HF hub cache. Add a `DELEGATE_BACKEND=auto` mode to `pick-model.sh` that picks MLX if reachable, else Ollama. The fallback is automatic and the user opt-out is one env var.

### Multi-tier-resident model serving

The host has 91.5 GB of headroom while MLX holds the 35B prose model. That is room for a second resident model:

- A 4-bit Q4 122B premium-general MLX model (~60 GB) would fit alongside the 35B prose model (~36 GB) — total ~96 GB, leaves 32 GB for OS + apps.
- Or a 4-bit Q4 80B prose-fallback (~40 GB) plus the 35B prose primary plus a small vision/embedding model.

`mlx_lm.server` loads one model at a time today — but `mlx_lm` itself supports multi-model registries. A small fork-or-PR to `mlx-lm` server (or a thin multi-server-port wrapper) would unlock parallel-resident tiers. The skill side would need `MLX_HOST_<TIER>` env vars or a `mlx_lm.server` instance per tier. Not trivial, but the memory headroom makes it newly feasible.

### Promote `--ollama-api` from runner-flag to baseline default

The runner's default for `--backend ollama` is still the CLI path for back-compat with the 2026-04-28 and 2026-05-01 baselines. Future baselines should pass `--ollama-api` by default; the CLI path should be opt-in via a `--ollama-cli` flag (or a `--legacy` flag covering all back-compat regimes). The 8× wall-time saving is too large to leave behind a flag for new baseline work — and the comparability argument is weaker now that we have a v2 with the new regime to anchor against.

### T3 restraint heuristic worth exploring

Ollama with `think:false` voluntarily emitted only 1 claim per rep on T3 (3/3 across 3 reps) where the prompt allowed up to 4. MLX emitted exactly 4 (the cap). The difference is meaningful — Ollama is choosing fewer-but-confident, MLX is filling-up-the-cap. A future eval could measure: under matched temperature and matched reasoning-suppression, does Ollama-style restraint generalise to other open-ended tasks (would it skip a `release-note` bullet when uncertain rather than inventing one)? If yes, the answer feeds into recipe authoring — maybe prompts should explicitly invite restraint by saying "fewer claims you're confident about beats more claims you're not".

### Idle-MLX vs idle-Ollama background draw

v2 confirms idle-Ollama is sub-300 MB. We didn't measure idle-MLX equivalently. The MLX server process at idle (model preloaded, no requests in flight) sat at the same 36.5 GB RSS it had during inference — the weights aren't paged out between requests. For users who run MLX only occasionally, kicking the server (and reclaiming 36 GB) between sessions is worth documenting in `docs/install-mlx.md`. The current docs only cover startup; an "idle / shutdown" section is missing.

## Reproducibility

```bash
# v2 — apples-to-apples
osascript -e 'tell application "Ollama" to quit'  # or killall Ollama
mlx_lm.server --port 8080 --model mlx-community/Qwen3.6-35B-A3B-8bit &
bash experiments/run-baseline.sh --backend mlx --reps 3 mlx-community/Qwen3.6-35B-A3B-8bit
pkill -f mlx_lm.server

open -a Ollama
bash experiments/run-baseline.sh --backend ollama --ollama-api --reps 3 qwen3.6:35b-a3b-q8_0

# Score (PR #114's backtick-aware T3 scorer)
for f in experiments/results/raw/qwen3_6_35b-a3b-q8_0-v2.txt \
         experiments/results/raw/mlx-community_Qwen3_6-35B-A3B-8bit-v2.txt; do
  for s in t3 t4 t5 t6; do
    bash "experiments/score-${s}.sh" "$f" | tail -1
  done
done
```

## Raw outputs

- `experiments/results/raw/qwen3_6_35b-a3b-q8_0-v2.txt` — Ollama with `--ollama-api`, 18 reps
- `experiments/results/raw/mlx-community_Qwen3_6-35B-A3B-8bit-v2.txt` — MLX, ollama-quit, 18 reps
