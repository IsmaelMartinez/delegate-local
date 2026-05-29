# Grafana + Tempo (local, self-hosted) — OTLP runbook

This is the on-device alternative to Grafana Cloud: a self-hosted Grafana + Tempo stack that runs the three committed dashboards on your own workstation, with no SaaS account and nothing leaving the box. The compose file and provisioning live in [`observability/`](../../observability/); the dashboards it loads are the same JSON files in [`dashboards/grafana/`](../../dashboards/grafana/) that the Grafana Cloud path imports.

## When to pick this

Choose the local Grafana and Tempo backend when you require persistent per-recipe, per-tier, and HIT/MISS calibration dashboards that the Phoenix flat single-project trace view cannot display. This solution runs fully on-device as two Docker containers — Tempo for trace storage with TraceQL metrics and Grafana for the dashboards — eliminating the need for a SaaS account and sending no data off the workstation. It offers a lighter footprint than the six-container Langfuse self-host stack, though metric trend panels build up from live delegations going forward rather than instantly from backfilled history.

## Prerequisites

- Docker plus Docker Compose v2 (`docker compose ...`).
- Ports `4317`, `4318`, and `3200` free for Tempo (OTLP gRPC, OTLP HTTP, query API), and `3001` free for the Grafana UI. If you already run a Phoenix / otel-collector stack it is holding `4317`/`4318` — see the swap step below.
- ~1 GB of disk for the Tempo and Grafana volumes at workstation scale.

## Bring it up

```bash
docker compose -f observability/docker-compose.yml up -d
```

Grafana comes up at [http://localhost:3001](http://localhost:3001) with anonymous admin access and no login form — the Tempo datasource and the three dashboards are provisioned automatically, so the `delegate-local` dashboard folder is populated on first start. Tempo's query API is at `http://localhost:3200`.

## Swapping in from a Phoenix / otel-collector stack

Tempo binds the standard OTLP ports `4317`/`4318` so the default `DELEGATE_OTEL_ENDPOINT=http://localhost:4318/v1/traces` routes here with no env change. If a Phoenix or otel-collector container already holds those ports, stop it first so Tempo can bind them:

```bash
docker stop otelcol phoenix     # whatever your current OTLP containers are named
docker compose -f observability/docker-compose.yml up -d
```

If you would rather run this alongside an existing stack, remap Tempo's host ports in a compose override and point the env var at the new HTTP port — e.g. `4318 -> 14318`, then `export DELEGATE_OTEL_ENDPOINT="http://localhost:14318/v1/traces"`.

## OTLP endpoint and env

No auth header is needed for the local workstation install. With the default ports the env is just:

```bash
export DELEGATE_OTEL_ENDPOINT="http://localhost:4318/v1/traces"
```

Once exported, the next `delegate.sh` call posts one span per invocation and the matching `delegate-feedback.sh hit|miss` posts the feedback span linked to it.

## How the dashboards populate (read this before deciding the panels are broken)

The dashboards are powered by **TraceQL metrics** (`rate()`, `count_over_time()`, `histogram_over_time()`), which Tempo's `local-blocks` metrics processor computes from spans **as they are ingested live**. Two consequences are specific to the local backend and differ from Grafana Cloud:

- A freshly-sent span does not appear in the metric panels immediately — the processor only exposes it once it cuts a complete block, roughly one to two minutes after ingestion. The trace itself is searchable right away.
- `backfill-otel.sh` (below) replays your historical `metrics.jsonl` so the spans are **searchable** in Tempo, but those old-timestamp spans do **not** retroactively fill the metric trend panels — the local processor only buckets live ingestion. The metric panels therefore start empty and build up from the point you wire the exporter and run real delegations. Grafana Cloud's hosted Tempo computes historical metrics differently, which is why its runbook describes backfill as seeding the dashboards; locally, backfill seeds trace search only.

In short: the per-recipe / per-tier / calibration trend panels fill in over the following day or two of real use; the trace-search view is available for the whole history immediately after a backfill.

## Backfill historical traces (optional, for trace search)

```bash
bash scripts/backfill-otel.sh                       # post every pre-exporter row
bash scripts/backfill-otel.sh --since 2026-05-01T00:00:00Z  # only since a date
bash scripts/backfill-otel.sh --dry-run             # preview without POSTing
```

Row-level idempotent: rows already exported live (carrying `otel_trace_id`) are skipped, and pre-exporter rows get deterministic IDs so re-running produces no duplicate traces. This populates Tempo's trace search; see the section above for why it does not fill the metric panels.

## Tear down

```bash
docker compose -f observability/docker-compose.yml down       # keep data
docker compose -f observability/docker-compose.yml down -v    # also wipe the volumes
```

## See also

- [docs/observability/grafana-cloud.md](grafana-cloud.md) — the hosted version of the same dashboards when on-device storage is not a requirement.
- [docs/observability/phoenix.md](phoenix.md) — ultra-light single-container trace inspection without dashboards.
- [docs/observability/langfuse-self-host.md](langfuse-self-host.md) — heavier on-device alternative with a first-class scores model.
