# 26. Commit-message body-drop on thin diffs — a recipe-side fix and a standing bench

Date: 2026-06-23

## Status

Accepted.

## Context

The delegate-local hit-rate fell over mid-June 2026 (an ~87% peak on 28 May down to ~59% in the week of 18 June). Forensics traced the bulk of the drop to one recipe: `commit-message` was returning subject-only messages — no body — and failing the `body_required` check.

The cause is two-part. First, a genuine model defect: on the thinnest diffs (a rename, a one-line config or test edit) the Qwen3.6-35B model collapses to a subject-only message, because the recipe's only change-signal is a `diff_stat` summary plus `recent_commits` plus the `why` — on a tiny change with squash-merged (bodyless) anchors that is not enough material and the model copies the bodyless shape. Second, a measurement change made the previously-silent defect visible: PR #310 (16 June) added the mandatory-body directive and the `body_required` check, and PR #316 (18 June) began persisting check results, so misses that had always been happening started being counted.

Two plausible-sounding explanations did not survive the data. The MLX backend default was not the cause — quality rose after MLX adoption and the 87% peak was itself on MLX. Reverting to Ollama as the default was not supported either: both the MLX and Ollama prose tiers resolve to the same Qwen3.6-35B model (8bit versus q8_0), and a per-fixture benchmark showed both backends dropping a body on a thin diff. It is a model-bound, recipe-side starvation, not a backend-specific or temperature/seed bug.

Compounding all of this, the regression harness that would have caught and measured the defect had been archived out of `main` in the 19 June lean-core reset, so there was no in-repo tool to reproduce or validate a fix.

## Decision

Fix the recipe, not the backend. The mandatory-body rule was the only major guard in `prompts/commit-message.md` without a contrastive Wrong/Correct one-shot, and the recipe's own calibration history shows that converting bare directives into contrastive one-shots is exactly what flipped the subject-length, `(#NN)`, scope, and padding guards from miss to hit. The fix adds a prominent "BODY — mandatory, non-negotiable" block with a one-shot (using a cache-TTL example unrelated to any benchmark fixture so it cannot leak an answer) and instructs the model to draw the body from the `why` context when the change looks too small to explain. No `pick-model.sh` routing change and no default-backend flip — both were ruled out above. The heavier opt-in diff-excerpt lever, which would have surfaced raw diff content to the model, was scoped but not needed once the directive fix cleared the benchmark, so the privacy floor stays at the `diff_stat` summary.

Keep a standing benchmark in core. `tests/bench-commit-message-body.sh` drives `delegate.sh --recipe auto` with a real unified diff piped on stdin — the exact production path — across a set of diverse thin-diff fixtures plus a rich control, and scores each output with the same `tr -d '\r' | awk 'NF { n++ } END { print n + 0 }'` non-empty-line count and `< 2` threshold as the production `body_required` check (logic-equivalent, not a brittle textual copy). It separates genuine body-drops from infrastructure errors (a cold-load timeout or empty output is an `ERROR`, surfaced loudly and failing the gate as inconclusive, never silently counted as a drop). Because MLX is deterministic per (prompt, temperature) per ADR 0018, statistical power comes from fixture diversity, not repeated runs.

The benchmark is the binding done-criterion for this fix: a green run (`drops=0 errors=0` on every fixture, both backends) is what merges it, whereas production hit-rate recovery is a post-merge observation tracked over weeks of feedback rows, not a merge gate. The live run is opt-in because it contacts a model:

```bash
BENCH_GATE=1 BENCH_BACKENDS="mlx ollama" bash tests/bench-commit-message-body.sh
```

Run it before merging any change to `prompts/commit-message.md` or the commit-message path in `delegate.sh`. The hermetic unit suite (`tests/run-tests.sh`) stays offline: it adds only a model-free wiring smoke that syntax-checks the bench, asserts the fixtures exist, and unit-tests `score_body` — it never runs the bench.

## Consequences

The commit-message recipe no longer drops the body on thin diffs on either backend, and the regression is now reproducible on demand rather than only visible weeks later in aggregate metrics.

The lesson generalises beyond this one recipe: the regression harness must not be archived out of core. The lean-core reset removed the tool needed to measure quality, which is what let this defect run unmeasured between its introduction and its discovery. A small, fast, in-repo benchmark for each calibrated recipe is the cost of being able to say "fixed" with evidence — keep it lean (one script, one scorer, fixtures), but keep it in `main`.

The trade-off is that the benchmark's authoritative signal needs a model and therefore cannot run in the offline CI job; the opt-in live run is a human/CI-with-a-model step. The offline wiring smoke guards against the cheap failure (the bench drifting away from its fixtures or its scorer) without pretending to be the quality gate.
