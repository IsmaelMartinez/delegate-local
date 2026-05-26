# Langfuse — equivalent views for `delegate-local`

Langfuse does not ship a portable dashboard JSON model the way Grafana does — its dashboards are session-views configured per-project through the web UI, and the rendered surface (the trace list, the per-trace timeline, the scores panel) is derived from query state rather than a versioned JSON file. The closest reproducible-from-scratch artefact for the Langfuse backend is this documentation, which names the three views the Grafana dashboards in `dashboards/grafana/` cover and explains how to recreate each one in Langfuse from scratch.

This is documentation-as-code: when a maintainer updates the Grafana dashboards, the corresponding Langfuse view definition here is updated in lock-step so the two backends stay equivalent.

## Prerequisite — exporter wired

Before any of the views below populate, the OTLP exporter has to be pointed at the Langfuse instance per [`docs/observability/langfuse-self-host.md`](../../docs/observability/langfuse-self-host.md). The runbook covers the docker-compose bring-up, API-key extraction, and the `DELEGATE_OTEL_ENDPOINT` / `DELEGATE_OTEL_HEADERS` env vars. Once those are exported, every `delegate.sh` call posts one span and every `delegate-feedback.sh hit|miss` call posts a linked feedback span — and the views below filter against attributes those spans already carry.

The exporter emits the attribute schema in [`docs/otel-schema.md`](../../docs/otel-schema.md). Langfuse renders OTLP spans as traces under the project the API key belongs to, with attributes available as filter and group-by keys in the UI. The `delegate.feedback.verdict` attribute on feedback spans is recognised by Langfuse's [scores API](https://langfuse.com/docs/scores/overview) as a first-class score object via the `links` field — meaning HIT/MISS appears as a score on the parent trace in the UI, not just as a buried attribute.

## View 1 — Overview (counterpart to `delegate-overview.json`)

Surface: the Traces list filtered to this skill's service, plus a few saved filters that recreate the per-tier, per-recipe, and per-backend slices of the Grafana overview dashboard.

Recreate in Langfuse:

1. Open the project the exporter writes to. The left nav shows **Tracing → Traces**.
2. Add a filter: **Trace metadata → `service.name` equals `delegate-local`**. This filter is the equivalent of the Grafana `resource.service.name="delegate-local"` clause and prevents spans from other GenAI workloads sharing the project from bleeding into the panels.
3. Save the filter as `delegate-local — all`. Future visits to the Traces page restore the filter automatically.
4. Clone the saved filter three times and tighten each clone:
   - `delegate-local — by tier` — group by `delegate.tier` in the column controls. The table renders a row per tier with the call count.
   - `delegate-local — by recipe` — group by `delegate.recipe`. Bare-prose-tier calls (no recipe attribute) collapse into a single `null` row that the Grafana panel excludes; in Langfuse the null row is informative because it surfaces the count of non-recipe delegations.
   - `delegate-local — by backend` — group by `gen_ai.provider.name`. The two-row split (`ollama` versus `mlx`) matches the auto-default backend's behaviour: MLX-when-available, Ollama-fallback.

Latency and tokens-avoided trends:

5. Open the **Tracing → Sessions** view (Langfuse aggregates spans per session by default) and switch the chart to **Latency p50 / p95** grouped by `delegate.tier`. The same view supports `delegate.queue_wait_ms` and `delegate.generation_ms` as plottable attributes when added through the column controls — the histograms in the Grafana overview map onto these line charts in Langfuse.
6. Add a **Metric card** at the top of the project dashboard summing `delegate.estimated_tokens_avoided`. This is the rollup equivalent of the Grafana `Tokens kept local (estimated)` stat panel; Langfuse renders it as a single numeric tile.

## View 2 — Calibration (counterpart to `delegate-calibration.json`)

Surface: Langfuse's **Scores** view, which natively models the HIT/MISS verdict because the feedback span's `delegate.feedback.verdict` attribute is recognised through the `links` field on the parent trace.

Recreate in Langfuse:

1. Open **Tracing → Scores**. Each row is one feedback event joined to its parent delegation through the OTLP `links` field. Langfuse renders the join automatically.
2. Filter on **Score name** = `delegate.feedback.verdict`. Two values are present: `hit` and `miss`.
3. Switch the score chart to **Aggregation by score value** and the time range to last 7 days. The two stacked series (HIT count and MISS count) are the calibration view's headline.
4. Save the filter as `delegate-local — calibration`.
5. Add a second filter clone scoped to `score value = miss` and group by `delegate.recipe` (joined through the link to the parent span). The bar chart shows MISSes per recipe — the recurring-MISS detection signal that the runtime nudge in `delegate-feedback.sh` keys off when it prints the draft `gh issue create` command.

Sample query against the Langfuse public API for the HIT rate (useful when the dashboard is being driven by an external tool rather than the UI):

```sql
-- Langfuse SQL editor — public-API SQL surface
SELECT
  date_trunc('day', t.timestamp) AS day,
  s.metadata->>'delegate.recipe' AS recipe,
  COUNT(*) FILTER (WHERE s.value = 'hit') * 1.0 / NULLIF(COUNT(*), 0) AS hit_rate,
  COUNT(*) FILTER (WHERE s.value = 'hit') AS hits,
  COUNT(*) FILTER (WHERE s.value = 'miss') AS misses
FROM scores s
JOIN traces t ON t.id = s.trace_id
WHERE s.name = 'delegate.feedback.verdict'
  AND t.metadata->>'service.name' = 'delegate-local'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
```

The query keys off the same attributes the Grafana `Per-recipe HIT rate trend` panel uses (`delegate.feedback.verdict`, the parent's `delegate.recipe`) — only the surface differs (Langfuse SQL versus TraceQL).

Recent-MISS table:

6. Add a third filter clone scoped to `score value = miss` and a column for `comment` (Langfuse stores the free-text feedback reason there when the OTLP `delegate.feedback.reason` attribute is set). The resulting table is the Langfuse counterpart of the Grafana `Recent MISSes (by recipe + reason)` panel — each row a MISS with its recipe, model, tier, and the verbatim reason the caller typed.

## View 3 — Errors (counterpart to `delegate-errors.json`)

Surface: the Traces list filtered to error-status spans plus saved filters per exit code.

Recreate in Langfuse:

1. Open **Tracing → Traces** and apply the saved `delegate-local — all` filter from View 1.
2. Add a second filter: **Trace status** = `ERROR`. The exporter sets the OTel status to ERROR when `delegate.exit_status != 0`, so this filter is the Langfuse counterpart of the Grafana `Failed-export count` stat.
3. Group by `delegate.exit_status`. Three rows are typical: `1` (generic failure), `2` (recipe-substitution refusal), `3` (pre-flight canary timeout).
4. Save as `delegate-local — errors`.
5. Clone the filter and tighten the exit-status filter to `= 3`. The resulting saved filter is the Langfuse counterpart of the Grafana `Canary timeout rate (exit 3)` stat — track the count rather than the rate, which Langfuse computes per-day rather than as a percentage.

Sample query for the exit-status breakdown (handy for an external alerting tool rather than the UI):

```sql
SELECT
  date_trunc('hour', t.timestamp) AS hour,
  t.metadata->>'delegate.exit_status' AS exit_status,
  COUNT(*) AS span_count
FROM traces t
WHERE t.metadata->>'service.name' = 'delegate-local'
  AND t.metadata->>'gen_ai.operation.name' = 'chat'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
```

The query keys off the same attributes the Grafana `Exit-status breakdown` timeseries panel uses, expressed as Langfuse public-API SQL rather than TraceQL.

## Why Langfuse views are documented rather than versioned

Two reasons. First, Langfuse's dashboards are session-views configured per-project through the web UI, not file-as-code artefacts — there is no portable JSON the way Grafana ships. Second, the HIT/MISS verdict has a first-class home in Langfuse (the Scores API recognises it from the OTLP `links` field), which means the calibration view is materially simpler in Langfuse than in Grafana and a verbatim port of the Grafana JSON would carry baggage the Langfuse UI does not need.

The exporter contract in [`docs/otel-schema.md`](../../docs/otel-schema.md) is the canonical surface — both backends consume the same attributes. The Grafana JSON files in `dashboards/grafana/` are the file-as-code artefact for Grafana, and this README is the file-as-code artefact for Langfuse. Updates to one without the other are drift; see [`tests/test-dashboards.sh`](../../tests/test-dashboards.sh) for the test that pins each Grafana panel's referenced attribute back to the schema doc.

## See also

- [`../../docs/observability/grafana-cloud.md`](../../docs/observability/grafana-cloud.md) — Grafana Cloud runbook (the recommended default backend; ships pre-built GenAI dashboards in addition to the three skill-specific ones in `../grafana/`).
- [`../../docs/observability/langfuse-self-host.md`](../../docs/observability/langfuse-self-host.md) — Langfuse self-host runbook (docker-compose, API-key extraction, `DELEGATE_OTEL_ENDPOINT` env vars).
- [`../../docs/observability/phoenix.md`](../../docs/observability/phoenix.md) — Phoenix runbook (one-container alternative for short-lived local inspection).
- [`../../docs/adr/0007-otel-schema.md`](../../docs/adr/0007-otel-schema.md) — ADR for the namespace split, feedback-as-linked-span pattern, and no-content rule that the views above depend on.
- [`../../docs/otel-schema.md`](../../docs/otel-schema.md) — attribute reference; every filter and group-by in this document is keyed against one of the attribute names listed there.
