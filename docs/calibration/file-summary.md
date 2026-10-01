# Calibration history for [`prompts/file-summary.md`](../../prompts/file-summary.md)

## Calibration notes

Initial recipe drafted 2026-05-11 from the 24-call batch summarisation reported in issue #95 — ADR and analysis files in a sibling repo summarised against `qwen3.6:35b-a3b-q8_0` via `scripts/delegate.sh prose`. The first-batch hit rate was 23 of 24; the single MISS dropped the subject and emitted `Confirmed because slope conditioning reveals heterogeneity that the 2-axis grid averages out across slope buckets.` — exactly the verb-led-fragment shape the subject-required guard now blocks. The re-prompt with the explicit subject directive produced `The 3-axis grid surfaces one new regime cell missed by the 2-axis grid because slope conditioning reveals heterogeneity averaged out in the broader grid.` on the same input.

The 95%+ first-pass rate on a 24-call batch is the empirical anchor for treating this recipe as ready-to-ship rather than "starting point, calibrate later". The remaining ~4% miss rate motivates the subject-required guard rather than a spot-check workflow — the recipe is meant for batch use across many files where per-file review defeats the point.

### Tier choice

Prose tier (`qwen3.6:35b-a3b-q8_0` by default). The task is generating one sentence of prose from a document body; it is not classification, not extraction, not analysis. Anyone reaching for `reasoning` here is over-spending — the 2026-05-11 batch confirmed prose-tier is sufficient when the subject-required guard is in the prompt.
