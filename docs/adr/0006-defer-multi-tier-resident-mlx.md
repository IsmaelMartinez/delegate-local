# 6. Defer multi-tier-resident MLX model serving

Date: 2026-05-14

## Status

Accepted.

## Context

The 2026-05-12 v2 baseline (PR #115) demonstrated that MLX on the reference host serves the prose tier at 2× the wall speed and 25% lower peak memory of Ollama on the same Qwen3.6-35B-A3B-8bit weights. The host (M5 Max, 128 GB unified memory) holds the 35B model in roughly 36 GB, leaving ~91 GB of headroom. The ROADMAP "MLX track follow-ups" listed this as P1 with the framing that `mlx_lm.server` serves one model at a time, the re-load on first request to a new model id is a latency cliff, and two paths might be worth pursuing: (a) one `mlx_lm.server` process per tier on different ports, or (b) an upstream fork-or-PR adding a multi-model registry to `mlx-lm`. The open question gating either path was whether the prose model's KV cache survives a round-trip swap to a different model — if not, the round-trip pays the load cost both ways.

A short empirical probe on 2026-05-14 answered the open question and reshaped the design calculus. The probe sent tiny prompts in a fixed sequence against the running `mlx_lm.server` (cold A → warm A → cold B → warm B → cold A → warm A → cold B → warm B → cold A → warm A), measuring wall time per request and system-wide available memory deltas. `mlx-community/Qwen3.6-35B-A3B-8bit` served as model A and `mlx-community/Qwen3-0.6B-4bit` as model B. The size asymmetry between the models is acknowledged: the absolute load times are not symmetric across A↔B switches, but the qualitative answers (eviction yes/no, cache survival yes/no, second-cold-vs-first-cold cost ratio) hold across the asymmetry.

The headline findings. First, `mlx_lm.server` does serve one model at a time and evicts the prior model from working memory when a request arrives for a different model id, confirmed by the system-wide available-memory delta on the first A→B and B→A transitions. Second, eviction is partial: disk-mmap'd weight pages survive in the OS file cache, so a second cold-load of the same model is materially cheaper than the first. The 35B's first re-load after eviction cost 4.07 s wall; its second re-load (after another swap-out and swap-back) cost 1.63 s, a 2.5× speedup attributable to warm OS file cache. Third, the KV cache does NOT survive a model swap. The same tiny prompt that took 4.07 s on the first re-load took 1.63 s on the second, but neither figure matched the 0.18 s warm-hit cost — if the KV cache had survived, the second re-load would have served the cached prompt in the 0.18 s window instead of paying any load cost at all. This is the empirical evidence that the ROADMAP's open question is settled in the negative: a swap is a full model context reset, not just a parameter reload.

The implication is that the "latency cliff" framing in the ROADMAP overestimated the cost. After the first cross-tier swap of a session, the OS file cache warms and subsequent cross-tier swaps cost roughly 1.6 s on the reference hardware. Compared to the 0.5–4 s typical wall times for actual completion work measured in PR #115's v2 baseline, 1.6 s on a swap boundary is rarely the user-visible bottleneck. The trigger condition the ROADMAP attached to shipping path (a) or (b) was "a real session where the user wants to mix tiers in quick succession and notices the re-load cost". The measurement suggests that even on workloads that thrash tiers, the noticed cost is small after the first switch.

## Decision

Neither path (a) nor path (b) ships at this time. The skill continues to run a single `mlx_lm.server` instance per host. `pick-model.sh` continues to resolve every MLX tier to a model id and addresses the same server on `${MLX_HOST:-http://localhost:8080}`. The OS file cache absorbs the practical cost of cross-tier swaps after the first one.

`docs/install-mlx.md` will gain a short "What happens on a cross-tier request" subsection naming the empirical numbers (4 s first-time, ~1.6 s thereafter on the reference host) so a user who notices the wait understands what it is and where it goes. The fix is the documentation, not the routing.

This decision does not retire path (a) or path (b) permanently. It defers them until a concrete workload demonstrates that the warm re-load cost is materially user-visible. The kinds of evidence that would re-open the question: a tier-mixing workload (interactive multi-tier work, say a session that alternates prose drafting and reasoning calibration sub-second per turn) reporting cumulative-wait pain; benchmarking that shows the OS file cache evicts the dormant model weights when other workloads compete for memory, breaking the ~1.6 s second-cold amortisation; or a use case for the `vision` or `embedding` scaffolded tiers where the model in question doesn't fit alongside the 35B prose model and the user wants to keep both resident anyway.

## Consequences

The skill avoids two implementation paths that the empirical measurement showed to be over-engineered for the actual cost they would remove. Path (a)'s two-process design would have introduced a new env-var surface (`MLX_HOST_PROSE`, `MLX_HOST_PREMIUM`, etc.), a documented lifecycle for managing multiple server processes, and an untested assumption that macOS unified memory pressure between two `mlx_lm.server` processes does not silently page one of them out — which would buy back the cliff in disguise. Path (b)'s upstream contribution would have been a multi-week project against a moving target and lived outside this repo regardless. Neither is justified by a 1.6 s amortised cross-tier wait.

The ROADMAP "Follow-ups from the MLX track" section can drop P1 from the priority list once this ADR lands and the install-mlx.md note follows. The two remaining items move up to P1 and P2 respectively; the ROADMAP itself is the live source for the current numbering.

What would justify revisiting the decision: the evidence shapes listed under "Decision" above. The probe itself is reproducible — the `vm_stat`-plus-`curl`-plus-`time` shape used on 2026-05-14 lives in this PR's session transcript and can be re-run by anyone with the two referenced MLX models in their HF hub cache. The numbers are reference-hardware-specific (M5 Max, 128 GB) and would need re-measurement on different hardware before generalising.

The cost of this ADR is one more file in `docs/adr/`. The benefit is that the empirical rationale for not building a feature now lives in a durable single artifact, so a future contributor who reads the ROADMAP and wonders why P1 was dropped without code finds the measurement and the reasoning here.
