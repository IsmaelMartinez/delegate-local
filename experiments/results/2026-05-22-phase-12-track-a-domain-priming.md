# Phase 12 Track A — Domain-priming validation gate (issue #160)

## Decision: NULL RESULT — recipes are NOT modified

The hypothesis under test was that adding a single domain-priming opening line (per the Wharton "Playing Pretend" / "Principled Personas" thread, arXiv 2508.19764) to the `## Prompt template` of three calibrated recipes would improve their structural-check pass rate against local Qwen-class models. The hypothesis is rejected. Variant 2 (domain priming) did not beat variant 1 (control) by ≥0.5 mean score with non-overlapping stdev intervals on any of the six (model, recipe) combinations measured. On the `commit-message` recipe against `qwen3.6:35b-a3b-q8_0` it actively regressed the score by 0.33 mean points. The production recipes stay as-is.

## Background

The literature sweep on 2026-05-22 found two distinct claims worth separating empirically. Persona setting (e.g. "You are an expert X") is null-to-negative on Qwen-class small models per Zheng et al. arXiv 2311.10054 (162 personas tested across Qwen2.5 3B-72B), and irrelevant persona attributes can degrade accuracy by up to 30 points (arXiv 2507.16076). Domain-context priming (declarative input-naming such as "The input is a unified diff hunk") is supported by Wharton "Playing Pretend" plus "Principled Personas" arXiv 2508.19764 as a distinct mechanism — it primes content, not identity. This ticket is the empirical gate for whether domain priming is worth promoting to a recipe convention in this skill's production prompts.

## Experiment design

Three variants of three recipes (`commit-message.md`, `file-summary.md`, `summarise-issue.md`), each tested against two installed Ollama models with five reps per cell. Variant v1 is the unmodified production recipe (control). Variant v2 adds one opening line at the top of the `## Prompt template` fenced block — domain-priming. Variant v3 adds one opening line at the same position naming a professional persona — persona-priming, the negative control. The exact opening lines tested:

- `commit-message` v2: "The input is a staged unified diff plus three verbatim recent commits as shape anchors."
- `commit-message` v3: "You are an expert software engineer drafting a commit message."
- `file-summary` v2: "The input is a single Markdown or source file from a software project."
- `file-summary` v3: "You are an expert technical writer summarising a document."
- `summarise-issue` v2: "The input is a GitHub issue body plus its comments, with timestamps and author names."
- `summarise-issue` v3: "You are an expert project manager summarising a discussion thread."

Recipes route via `scripts/delegate.sh --recipe NAME` so the same wrapper (preflight canary, metrics logging, recipe-template substitution) handles every cell. Variants live under `prompts/_experiments/` so the production directory is untouched.

Scoring uses the existing T4 deterministic structural scorer for `commit-message` (subject ≤72 chars, conventional-commit prefix, no `(#NN)` suffix, body flush-left, no bullets, no participial-/declarative-padding tails). Two new scorers were built for this ticket: T7 for `file-summary` (single line, ≤200 chars, no leading dash, subject-led not bare-verb opener, contains a mechanism word, no padding tail) and T8 for `summarise-issue` (contains `## What happened`, starts with that heading, ≥1 bullet under it, no "No blockers"-class placeholder phrases, no group-claim phrases, no padding tail). Each rep produces a 0-6 structural score; the cell mean / stdev / min / max are reported below.

Inputs: T4 reuses the existing 2026-05-21 fixture (recent_commits + diff_stat + why anchors parsed back into recipe variables). T7 uses an ADR-style document body (`task-7-file-summary-2026-05-22.txt`). T8 uses a representative issue-and-comments JSON (`task-8-summarise-issue-2026-05-22.txt`).

Models: `qwen3.6:35b-a3b-q8_0` (prose-tier default) and `qwen3-coder:30b-a3b-q8_0` (code-tier default). Total: 3 recipes × 3 variants × 2 models × 5 reps = 90 reps. Actual wall-clock: 488 seconds. HIT/MISS recorded for every rep via `scripts/delegate-feedback.sh` — 90 HITs, 0 MISSes (every rep returned non-empty output within the per-rep timeout).

## Results table

Each cell holds the mean structural-check score across 5 reps (range 0.0 to 1.0). Stdev was 0.0 on every cell — the per-rep variance was below the resolution of the structural checks given deterministic `temperature:0` decoding.

| Model                       | Recipe          | v1 control | v2 domain | v3 persona | v2 − v1  |
|-----------------------------|-----------------|------------|-----------|------------|----------|
| `qwen3.6:35b-a3b-q8_0`      | commit-message  | **1.00**   | 0.67      | 0.83       | **−0.33** |
| `qwen3.6:35b-a3b-q8_0`      | file-summary    | 1.00       | 1.00      | 0.83       | 0.00     |
| `qwen3.6:35b-a3b-q8_0`      | summarise-issue | 1.00       | 1.00      | 1.00       | 0.00     |
| `qwen3-coder:30b-a3b-q8_0`  | commit-message  | 0.83       | 0.83      | 0.83       | 0.00     |
| `qwen3-coder:30b-a3b-q8_0`  | file-summary    | 1.00       | 1.00      | 1.00       | 0.00     |
| `qwen3-coder:30b-a3b-q8_0`  | summarise-issue | 1.00       | 1.00      | 1.00       | 0.00     |

The strongest signal is the `commit-message` regression on `qwen3.6` under v2. The remaining cells show no separation — they either saturated at 1.00 (insufficient headroom for a positive effect to show) or stayed flat below the ceiling.

## Decision verdict per the acceptance gate

The acceptance gate from issue #160 states: ship the domain-priming change only if variant 2 beats variant 1 by ≥0.5 mean score with non-overlapping stdev intervals on at least one model, AND variant 3 does not exceed variant 2 on that model. Applied to each cell:

`qwen3.6:35b-a3b-q8_0` + `commit-message`: v2 − v1 = −0.33. Variant 2 regressed against control. Acceptance gate fails.

`qwen3.6:35b-a3b-q8_0` + `file-summary` and `summarise-issue`: v2 − v1 = 0.00 (both saturated at 1.00). Acceptance gate fails — no measurable gain.

`qwen3-coder:30b-a3b-q8_0` + all three recipes: v2 − v1 = 0.00. Acceptance gate fails — no measurable gain.

Decision: NULL RESULT. Domain-priming is not promoted to a recipe convention. The production recipes (`prompts/commit-message.md`, `prompts/file-summary.md`, `prompts/summarise-issue.md`) and `prompts/README.md` are NOT modified.

## Why domain priming regressed the commit-message recipe

The five v2 reps against `qwen3.6` produced an identical 77-char subject across all five reps: `feat: add T4 commit-message fixture and score-t4.sh for empirical calibration` (note: 77 chars, exceeds the 72-char rule). The v1 reps against the same model produced a 67-char subject across all five reps: `feat: add T4 commit-message fixture and score-t4.sh structural checks`. The body of every v2 rep also ended with a participial-padding tail: "...providing a concrete metric for the hardening introduced in the previous commit." — matching the existing `,[[:space:]]+providing([[:space:]]|[.!?,])` regex in `experiments/score-t4.sh`. The v1 reps had no padding tails.

This matches the recipe's own calibration history. The 2026-05-11 entry in `prompts/commit-message.md` ("invocation-example reinforcement for subject length (SUBJECT_LEN)") and the 2026-05-13 entry ("T4 fixture regen confirms MLX 18/18 after closes-the-gap extension") both anticipated this pattern: a longer preamble nudges the model toward a longer subject, and the SUBJECT_LEN check is the most prompt-length-sensitive check in the scorer. The domain-priming line adds ~85 chars of preamble before the substantive instructions; that bloat is enough to shift the subject by 10 chars on a recipe whose existing budget was 67-72 chars.

## Why domain priming was a no-op elsewhere

File-summary and summarise-issue both saturated at 1.00 under v1 on both models. The outputs across variants are essentially indistinguishable on the structural checks — same single-sentence subject-led summary with a mechanism word for T7, same `## What happened` / `## What's next` structure with cited bullets for T8. The structural scorers do not detect content-quality differences that domain priming might in principle affect (e.g. clearer named subjects, less hedging) — they detect structural compliance, and both control and v2 already satisfied every structural check. A richer rubric would be required to see a positive effect, if one exists, on these task shapes.

The conclusion the experiment can deliver, given the rubric it has: domain priming offers no measurable structural benefit on these two task shapes under these two models, and actively harms the third (subject-length-budgeted) task on at least one of the two models. The Wharton claim does not translate into a usable convention for this skill's recipe library.

## Persona priming as the negative control

Variant 3 (persona) was the literature-claimed negative — Zheng et al. found persona setting to be null-to-negative on Qwen-class small models. The data confirms that direction. Persona dropped `commit-message` on `qwen3.6` from 1.00 to 0.83 (one fewer check passing than v1, same 77-char subject as v2 but cleaner body without the participial tail), and dropped `file-summary` on `qwen3.6` from 1.00 to 0.83 (one rep emitted a multi-line output instead of a single sentence). Persona made no difference on `qwen3-coder` for any recipe. Variant 3 underperforms or matches v1 on every cell — consistent with the published null-to-negative findings.

The relative position of v2 vs v3 is interesting: domain priming regressed `commit-message` further than persona priming on `qwen3.6` (v2=0.67 vs v3=0.83). The literature framed domain priming as "distinct from persona", but the data here treats both as adding preamble bloat that subtracts from the recipe's effective budget. The mechanism that matters on this task is character economy, not the semantic category of the opening line.

## Surprising findings worth recording

The most surprising result is that the persona variant (v3) outperformed the domain-priming variant (v2) on `commit-message` against `qwen3.6` (0.83 vs 0.67). The literature predicted the opposite ordering — domain priming distinct and beneficial, persona null-to-negative. The likely mechanism is character count: the persona line was shorter than the domain-priming line by ~22 chars, so its preamble penalty was smaller. This argues that the literature's "domain vs persona" axis is not the load-bearing variable on this task shape — preamble length is.

A subsidiary surprise: every cell had stdev=0.0 across 5 reps. With `temperature:0` and no other source of stochasticity, the API returned deterministic outputs across all 90 calls. The structural-check rubric is also deterministic. The combination means the means below are exact integer fractions and the "non-overlapping stdev intervals" half of the acceptance gate is never the binding constraint — only the magnitude of the difference matters. A future iteration could use `temperature>0` to introduce a meaningful stdev distribution, but at temperature 0 the per-cell signal is the full signal.

## Artefacts

Raw outputs: `experiments/results/raw/phase-12-track-a/<model-slug>/<recipe>-v<n>.txt` (each cell is one file with 5 reps in the `===== T?-<recipe-id> rep N =====` envelope the existing scorers consume).

Variant recipes: `prompts/_experiments/<recipe>-v2-domain-priming.md` and `prompts/_experiments/<recipe>-v3-persona.md`. Kept under `_experiments/` so the production recipe directory stays single-source-of-truth.

New scorers: `experiments/score-t7.sh` (file-summary, 6 checks), `experiments/score-t8.sh` (summarise-issue, 6 checks). Both follow the same per-rep + machine-parseable `T?_SUMMARY:` line shape as `score-t4.sh`. Unit tests in `tests/test-score-t7.sh` (17 assertions) and `tests/test-score-t8.sh` (16 assertions) cover every check and edge case.

New fixtures: `experiments/fixtures/task-7-file-summary-2026-05-22.txt` (ADR-style document body), `experiments/fixtures/task-8-summarise-issue-2026-05-22.txt` (issue JSON with body + 3 comments). Dated per the existing T3/T4/T5/T6 convention.

Experiment runner: `experiments/phase-12-track-a-runner.sh` and aggregator `experiments/phase-12-track-a-score-all.sh`. The runner uses a pick-model.sh override (copied scripts/ to a tempdir, replaced pick-model.sh) so a specific model handles every cell regardless of the tier the recipe requests; the override stays inside the runner's tempdir and never touches the production wrapper.

## Implications for Phase 12 Track B and beyond

Track B should ship without the domain-priming piece per issue #160's explicit gating. The acceptance gate failed cleanly — this is not an ambiguous result requiring more reps; the regression on `commit-message` is deterministic and large, and the no-effect cells are saturated rather than near the decision boundary.

A follow-up worth filing if Phase 12 wants to explore content-quality differences: build a content-quality rubric (e.g. semantic alignment with the input's headline finding, named-subject coverage) so future preamble experiments can detect effects that don't show up on structural checks alone. The current ceiling-saturation on file-summary and summarise-issue is the bottleneck on signal, not the experiment design.
