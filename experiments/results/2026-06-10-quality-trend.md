# Production quality trend — 2026-06-10

First analysis of the skill's real-session quality signal over time, as opposed to the controlled fixture baselines under `experiments/results/<date>-baseline.md`. Where a baseline measures a model against a frozen fixture, this measures whether the output the skill actually produced in real sessions was kept verbatim — a HIT in `scripts/delegate-feedback.sh` terms — across every project that delegates to the skill.

## Method

The numbers and charts below are produced by `experiments/quality-trend.py`, which reads the metrics JSONL (`~/.claude/skills/delegate-local/metrics.jsonl` by default, override with `DELEGATE_METRICS_FILE` or a positional path). Quality is the HIT-rate of recorded verdicts: every `source:"feedback"` row carries `kept:true` (HIT — output used as-is) or `kept:false` (MISS), and each verdict is attributed to the delegation it scores via its `ref_ts`, so quality lands in the week the work happened rather than the week it was scored. Volume counts `source:"delegate"` rows; coverage is verdicts divided by delegations. Re-run it to refresh the picture:

```bash
python3 experiments/quality-trend.py
```

This snapshot covers 2026-05-03 → 2026-06-10 (the metrics file's full span at the time of writing): 922 delegations, 553 recorded verdicts, 448 HIT / 105 MISS.

## Weekly quality trend

```
  delegate-local — weekly recipe quality (HIT-rate of recorded verdicts)

  100% ┤
   90% ┤                       ··●··
       │                    ···     ···       ···●
   80% ┤        ·●·······●··           ··●····
   70% ┤    ···
   60% ┤ ●·
   50% ┤
       └────────────────────────────────────────────────
      05-04   05-11   05-18   05-25   06-01   06-08
  n=  8       30      288     86      75      66      verdicts/wk
  hit=62%     80%     79%     90%     79%     85%
```

```
  weekly delegation volume

  05-04 │███ 25
  05-11 │████████ 72
  05-18 │████████████████████████████████████████ 347
  05-25 │███████████████████████████████ 266
  06-01 │███████████ 96
  06-08 │█████████████ 116
```

## Per-recipe quality

```
  recipe                 n   hit%
  (bare / no recipe)    236   82%
  commit-message        154   75%
  summarise-issue        15   87%
  doc-section            15   73%
  file-summary           12  100%
  pr-description          11   45%
  release-note           10   80%
  bulk-file-summary       9   89%
```

The `*-v2-domain-priming` / `*-v3-persona` entries the script also surfaces are Phase 12 A/B experiment cells, not production recipes, and are excluded from the table above.

## Findings

The trend is stable, not climbing. After the early small-sample ramp — the 62% opening week is only 8 verdicts and should not be read as a real low — quality settles into a steady ~80% band. The most statistically trustworthy point is the 05-18 week at n=288, which sits at 79%; the 90% peak (05-25, n=86) and the 85% last week ride smaller samples. This flatness is not a regression. It is the directive-binding ceiling the recipe-calibration phases (15–17) already documented from the fixture side, now corroborated by production data: prose-recipe quality stopped responding to further prompt tuning, and the aggregate has plateaued.

The aggregate hides a structural split, and that split is the actionable finding. It validates the universal-vs-taste-calibrated classification merged in PR #289 (ADR 0013). The input-digestion recipes — `file-summary` (100%), `bulk-file-summary` (89%), `summarise-issue` (87%) — run near-perfect because their output has a near-ground-truth correct answer. The taste-calibrated prose recipes drag the average down: `commit-message` at 75%, `doc-section` at 73%, and `pr-description` at 45%, the weakest production recipe and the one already carrying the `flaky_on_models` gate that routes the agent to hand-writing. So the flat ~80% line is really a ~90%+ universal tier blended with a ~70% prose tier. The lever for raising the aggregate is the prose tier specifically; iterating the universal recipes has almost no headroom left.

The binding constraint on improvement is not quality but coverage. Only 60% of delegations carry a verdict (40% untracked), and the weekly coverage swings widely (32–83%) with the development cadence. Untracked delegations are invisible to the calibration loop, so the real quality distribution — especially for the high-volume `bare` and `commit-message` paths — is measured on barely more than half the evidence. Closing that gap (the open Phase E item, target under 20% untracked) would sharpen every number on this page and is the highest-leverage move before any further prose-recipe iteration.

## Augmenting this

Re-run `python3 experiments/quality-trend.py` as the metrics file grows. When the picture shifts materially — a sustained move off the ~80% band, a recipe crossing a quality threshold, or coverage clearing the Phase E target — drop a new `experiments/results/<date>-quality-trend.md` capturing the fresh charts and what changed, the same append-style cadence the dated baselines use. The script is the stable method; these writeups are the dated readings.
