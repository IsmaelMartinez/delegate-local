# 22. MLX as the primary local backend, Ollama as fallback — a performance choice, not a capability one

Date: 2026-06-19

## Status

Accepted. Records a learning that, until this ADR, lived only in the archived
`experiments/results/2026-05-12-mlx-vs-ollama*.md` and `2026-05-27-mlx-baseline.md`
retrospectives (recoverable from tag `pre-cleanup-2026-06-19`).

## Context

`DELEGATE_BACKEND=auto` (the default since 2026-05-13) probes `mlx_lm.server`
and routes to MLX when it is reachable, falling back to Ollama otherwise. The
*reason* MLX is preferred when available was measured but never written down
outside the experiment logs, so a future operator could not tell whether the
default is a performance decision, a quality decision, or an architectural one.

The 2026-05-12 MLX-vs-Ollama comparison and the 2026-05-27 MLX baseline measured
the same models at the same 8-bit quantisation on both backends. The finding:
MLX delivered roughly an order-of-magnitude lower latency than Ollama on
identical weights, with appreciably lighter memory, deterministic output at
greedy sampling, and equivalent quality on the structured-output checks
(T4/T5/T6) — open-ended citation quality (T3) was, if anything, marginally better
on MLX with the anchoring directive. There was no quality or capability loss
from preferring MLX.

## Decision

The `auto` default prefers MLX purely on performance and resource grounds. It is
explicitly **not** a capability or quality decision: the two backends are
treated as interchangeable for output correctness, and any host without
`mlx_lm.server` (non-Apple-Silicon, or Apple Silicon with the server stopped)
transparently uses Ollama with no expected quality difference. The single
`prefs` list in `pick-model.sh` serves both backends because the matcher is
case-insensitive, reinforcing that the choice is about *where* a model runs, not
*which* capability you get.

## Consequences

Operators can stop the MLX server to reclaim memory without worrying about a
quality regression — they trade latency, not correctness. The equivalence
boundary (measured at 8-bit quant on this hardware class) is the caveat: it was
established for the installed model set, not proven for every quantisation or
architecture, so a new model added to a tier should not be assumed
backend-equivalent without a spot check. The raw measurements are recoverable
from the archived experiment results if a re-baseline is ever needed.
