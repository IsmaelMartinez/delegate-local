# 28. Cut the metrics corpus at 2026-08-19 and restart collection from zero

Date: 2026-08-19

## Status

Accepted. Does not supersede ADR 0015 or ADR 0016, whose mechanisms stand, but retires the corpus their published rates were measured on. Every hit-rate quoted in ADRs 0012, 0015, 0016, 0023, 0024, 0026 and 0027 now refers to the archive named below rather than to the live metrics file.

## Context

The metrics JSONL had grown to 4949 rows spanning 2026-05-03 to 2026-08-19. The quality signal it exists to produce is 20 human verdicts, split 10 hit and 10 miss. Fourteen of those attach to a recipe delegation and thirteen of the fourteen are `commit-message`, so the calibration corpus for the other eighteen recipes in the library is a single verdict on `maintainer-reply`. The remaining 974 feedback rows carry `verdict_source: agent` and answer a different question, per ADR 0015: whether the producing agent used the output, not whether it was any good.

Two things independently made the older rows non-comparable with the newer ones. The first is the ADR 0015 backfill, which retagged 616 rows as agent by 300-second proximity, so the tier label on anything before 2026-06-18 is derived rather than recorded. The second is the run of pull requests merged on 2026-08-19 itself, which changed what several fields mean while the file was still being appended to. #413 and #414 changed how the `tier` field is resolved, and the corpus shows exactly what the old resolution cost: 45 of 1533 delegations carry a tier the router does not have, among them five where a flag name (`--tier`, `--file`, `--project`, `--ts`, `--print-model`) was recorded as the tier and forty invented names such as `small`, `fast` and `balanced`. #415 left the 3.13M "tokens avoided" headline unchanged but decomposed it, showing that 311k of it came from experiment rows and failed delegations, and that only 1.50M was output shipped as written. #416 and #417 redefined a delegation's current verdict as the latest by timestamp within each tier rather than the last one appended, which is a change of meaning even though the feedback rows in this corpus happen to be chronological and so move by no number under it.

ADR 0027 is the concrete casualty and is worth naming here rather than leaving to be discovered. It retired the `pr-description` flaky gate on probation, requiring "the next ~10 real pr-description calls" to record a human HIT or MISS so the recipe would re-enter the calibration loop. Twenty-three verdicts did land on `pr-description` after 2026-06-28, and all twenty-three carry `verdict_source: agent` (6 kept, 17 rewritten). Zero are human. The probation was never satisfiable from this corpus, and the 26% agent-kept rate it did produce is a usage number that cannot be read against the 45% human hit-rate the gate was originally argued from.

## Decision

Cut the corpus at 2026-08-19 and restart collection from zero. Nothing is deleted. The 4949-row file, the three historic `.bak` files, the stale in-repo copy left behind by the #404 data-directory move, and a `SUMMARY-before-reset.txt` holding the final `metrics-summary.sh` and `quality-report.sh` output are archived together at `~/.local/share/delegate-local/archive/2026-08-19-pre-reset/`. Any past claim can be re-derived by pointing `DELEGATE_METRICS_FILE` at that copy.

The live file was truncated in place, its Loki watermark reset to zero, and the Loki data volume recreated so the dashboards start empty rather than charting a projection of a corpus that no longer exists. Loki holds no unique state: it is a pure projection of the JSONL, and `sync-metrics-to-loki.sh --full` against the archive rebuilds it exactly. Tempo was deliberately left intact. No dashboard queries it, its blocks are ingestion-time indexed so the history is unreachable at its real time anyway, and with `DELEGATE_OTEL_INCLUDE_CONTENT=1` its spans are the only place some prompt and response text exists.

Trimming the corpus rather than cutting it was rejected. There is no window inside it that is both recent enough to have been written by current code and large enough to carry a quality signal, because the code changed on the same day as the newest rows and the human sample is 20 verdicts across the whole period.

## Consequences

Reporting degrades cleanly at zero rows: `metrics-summary.sh`, `quality-report.sh` and both `verdict-sweep.sh` modes each print an explicit empty-state message and exit 0, verified before the first new row was written. The write path was then verified end to end from zero, one delegation through the sync to a Loki query returning exactly one entry.

The reset on its own changes nothing about collection, and that is the part which decides whether it was worth the loss. The old corpus was 0.4% human verdicts because nothing ever asked for one, and running the same mechanism for another three months reproduces the same ratio and the same unusable sample. What makes the new corpus different is #417, whose `verdict-sweep.sh --calibrate` offers back the delegations the agent graded itself a hit on and no person has judged. The first honest checkpoint on the new corpus is 20 human verdicts, matching the entire yield of the old one; at the historical rate that is months away, and through the sweep it is a few sessions.

The principal residual risk is that the new corpus has no baseline. A regression in the coming weeks has nothing to compare against except an archive whose field semantics differ, so the first weeks are a baseline being established rather than a trend being watched, and should not be read as improvement or decline against the archived numbers.
