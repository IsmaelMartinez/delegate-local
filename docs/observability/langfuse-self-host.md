# Langfuse self-hosted — OTLP runbook

This is the privacy-conscious fallback when telemetry must stay on-device. Langfuse is the OSS LLM-observability stack (web UI plus async worker, backed by PostgreSQL plus ClickHouse for OLAP, with Redis and S3-compatible blob storage for queues and event payloads). Self-hosted via Docker Compose, no SaaS account, no data leaves the workstation.

## When to pick this

Langfuse self-hosted via docker-compose keeps all telemetry on the workstation, avoiding SaaS accounts and outbound traffic from the collector. It models user feedback as a first-class scores object, which maps cleanly to the hit or miss verdict from delegate-feedback.sh. The stack remains MIT-licensed throughout, despite the acquisition of ClickHouse Inc. This setup suits environments where data must stay on-device for compliance or where the score model forms the primary review surface.

## Prerequisites

- Docker plus Docker Compose v2 (`docker compose ...`).
- ~4 GB of free disk for the ClickHouse, PostgreSQL, and MinIO volumes during initial bring-up; production volumes grow with span count.
- Port 3000 free on localhost for the Langfuse web UI.

## One-file docker-compose.yml

Langfuse maintains a canonical `docker-compose.yml` in the [langfuse/langfuse GitHub repo](https://github.com/langfuse/langfuse/blob/main/docker-compose.yml). Pull the latest:

```bash
mkdir -p ~/langfuse && cd ~/langfuse
curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/langfuse/langfuse/main/docker-compose.yml
```

The compose file brings up six services (see [Langfuse self-host docker-compose guide](https://langfuse.com/self-hosting/docker-compose) for the current authoritative reference):

- `langfuse-web` — `docker.io/langfuse/langfuse:3` on port `3000:3000` (the UI and ingest API).
- `langfuse-worker` — `docker.io/langfuse/langfuse-worker:3` on port `127.0.0.1:3030:3030` (async event processor).
- `clickhouse` — `docker.io/clickhouse/clickhouse-server` (OLAP store for traces, spans, observations).
- `postgres` — `docker.io/postgres:17` (transactional metadata: projects, users, API keys).
- `redis` — `docker.io/redis:7` (queue and cache).
- `minio` — `cgr.dev/chainguard/minio` (S3-compatible blob storage for raw events).

All sensitive defaults in the compose file are marked `# CHANGEME` — `SALT`, `ENCRYPTION_KEY`, `NEXTAUTH_SECRET`, `POSTGRES_PASSWORD`, `CLICKHOUSE_PASSWORD`, `REDIS_AUTH`, `MINIO_ROOT_PASSWORD`, and the three `LANGFUSE_S3_*_SECRET_ACCESS_KEY` values. For a workstation-local install, generate strong values once:

```bash
# Replace each CHANGEME with output of this command
openssl rand -base64 32
```

Bring everything up:

```bash
docker compose up -d
# Wait ~30 s for ClickHouse migrations to run
docker compose logs -f langfuse-web
```

The UI is then at `http://localhost:3000`.

## API-key extraction

Langfuse uses a public-key / secret-key pair for ingest authentication. Both are generated through the web UI, not the CLI.

1. Open `http://localhost:3000` and create an account (first user becomes the org owner).
2. Create a project (any name; this is the scope under which spans land).
3. Navigate to **Settings → API Keys → Create new API keys**.
4. Copy both the **Public Key** (`pk-lf-…`) and the **Secret Key** (`sk-lf-…`) — the secret displays once.

## OTLP endpoint and auth header

Langfuse exposes an OTLP-compatible ingest at `/api/public/otel/v1/traces` (signal-specific path; the base `/api/public/otel` works with collectors that auto-append `/v1/traces`). Authentication is HTTP Basic with `<public_key>:<secret_key>` base64-encoded. See [Langfuse OpenTelemetry get-started](https://langfuse.com/docs/opentelemetry/get-started) for the authoritative reference.

```bash
PUBLIC_KEY="pk-lf-1234567890"     # from the UI
SECRET_KEY="sk-lf-1234567890"     # from the UI
AUTH_B64=$(printf '%s:%s' "$PUBLIC_KEY" "$SECRET_KEY" | base64 | tr -d '\n')
# On GNU systems: base64 -w 0  to suppress wrapping
```

The full `Authorization` header is `Basic <AUTH_B64>`.

## Copy-pasteable env block

```bash
export DELEGATE_OTEL_ENDPOINT="http://localhost:3000/api/public/otel/v1/traces"
export DELEGATE_OTEL_HEADERS="Authorization: Basic <base64-encoded-public-key:secret-key>"
```

Substitute the base64 string from the auth step. Once exported, the next `delegate.sh` call posts one span per invocation; the matching `delegate-feedback.sh hit|miss` call posts the feedback span, and Langfuse renders it as a [score](https://langfuse.com/docs/scores/overview) attached to the parent trace via the OTLP span `links` field — making the hit/miss verdict a first-class object in the UI rather than a buried attribute.

## Dashboards (committed in `dashboards/langfuse/`)

Langfuse dashboards are session-views configured per-project through the web UI, not file-as-code artefacts the way Grafana ships — there is no portable dashboard JSON to import. The equivalent reproducible-from-scratch artefact is [`dashboards/langfuse/README.md`](../../dashboards/langfuse/README.md), which names the three views (Overview, Calibration, Errors) the Grafana JSON dashboards in `dashboards/grafana/` cover and explains how to recreate each one in Langfuse from saved filters, the Scores view, and a couple of sample public-API SQL queries. Follow the README after the exporter is wired and the first few spans have landed in the project.

## See also

- [docs/observability/grafana-cloud.md](grafana-cloud.md) — hosted alternative with pre-built GenAI dashboards when on-device storage is not a requirement.
- [docs/observability/phoenix.md](phoenix.md) — ultra-light single-container alternative for one-off local inspection without the ClickHouse and PostgreSQL footprint.
