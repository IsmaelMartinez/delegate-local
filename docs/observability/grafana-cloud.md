# Grafana Cloud — OTLP runbook

This is the recommended default backend for the `delegate-to-ollama` OTLP exporter once Phase 11 Track A lands. Hosted by Grafana Labs, free tier covers the workstation-scale telemetry volumes this skill produces, and the pre-built GenAI dashboards key off the same `gen_ai.*` semantic attributes the exporter emits — so you import the dashboards once and they populate automatically.

## When to pick this

Use Grafana Cloud as the default for delegate-to-ollama's OTLP exporter when you require immediate visibility into GenAI metrics without managing infrastructure. The free tier provides pre-built dashboards that consume the specific semantic attributes emitted by the exporter, such as operation names and model details. This setup removes the need for local Docker or ClickHouse instances while transmitting only anonymised metadata like char counts and model identifiers to the collector.

## Sign up for the free tier

1. Create a free account at [grafana.com/auth/sign-up/create-user](https://grafana.com/auth/sign-up/create-user). The free tier (Grafana Cloud Free) includes 10k metric series, 50 GB logs, and 50 GB traces per month — orders of magnitude above what a single workstation generates from this skill.
2. After signup, a default stack is provisioned for you in the region you select (US, EU, AU, etc.).

## Generate an OTLP access-policy token

The OTLP gateway uses Basic authentication with `<instanceID>:<accessPolicyToken>` base64-encoded. Both halves come from the Grafana Cloud portal.

1. From [grafana.com](https://grafana.com), navigate to your stack, then **Configure → OpenTelemetry** (or in newer portals, **Send data → OpenTelemetry**).
2. The OpenTelemetry tile shows your stack's **Instance ID** (a numeric string like `123456`) and the **OTLP endpoint URL**.
3. Click **Generate now** under "API token" to mint an access-policy token scoped to `metrics:write`, `logs:write`, and `traces:write`. The token displays once; copy it.

Alternatively, access policies are also manageable under **My Account → Access Policies** in the Cloud Portal; create a policy with the three `*:write` scopes, then mint a token under that policy. See [Grafana Cloud access policies documentation](https://grafana.com/docs/grafana-cloud/account-management/authentication-and-permissions/access-policies/) for the longer path.

## OTLP endpoint URL shape

The OTLP gateway URL follows the pattern (verify against your stack's portal — region IDs vary):

```
https://otlp-gateway-prod-<region>.grafana.net/otlp
```

For example, a US-Central stack resolves to `https://otlp-gateway-prod-us-central-0.grafana.net/otlp`; an EU stack to `https://otlp-gateway-prod-eu-west-0.grafana.net/otlp`. Multi-zone endpoints (post-Jan-2026 regions) follow `https://otlp-gateway-prod-<region>-multi-zone.grafana.net/otlp`. The portal's OpenTelemetry tile shows the exact URL for your stack; copy that rather than guess.

For signal-specific exporters (the path `delegate.sh` uses), the traces endpoint is the base URL plus `/v1/traces`:

```
https://otlp-gateway-prod-<region>.grafana.net/otlp/v1/traces
```

See [Send data to the Grafana Cloud OTLP endpoint](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/) for the authoritative reference.

## Basic-auth header construction

The `Authorization` header is `Basic <base64(instanceID:apiToken)>`. On macOS / Linux:

```bash
# Replace with your instance ID and token from the portal
INSTANCE_ID="123456"
ACCESS_TOKEN="glc_eyJv..."  # pasted from the portal
AUTH_B64=$(printf '%s:%s' "$INSTANCE_ID" "$ACCESS_TOKEN" | base64 | tr -d '\n')
# On GNU systems with long tokens, prevent line wrapping: base64 -w 0
```

The resulting header is `Authorization: Basic <AUTH_B64>`. See the [community thread on OTLP credentials](https://community.grafana.com/t/opentelemetry-protocol-otlp-endpoint-credentials-for-grafana-cloud/105782) for the canonical example.

## Pre-built GenAI dashboards

Grafana Cloud's [AI Observability integration](https://grafana.com/docs/grafana-cloud/monitor-applications/ai-observability/genai/observability/) ships six pre-built dashboards covering GenAI observability (request volume, latency, token usage), GenAI evaluations, vector database observability, MCP server observability, and GPU monitoring. The dashboards key off the OTel `gen_ai.*` semantic conventions — the same attributes `delegate.sh` emits (`gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.client.operation.duration`) — so they populate from this skill's spans without per-panel rewiring.

Import them from your stack's **Apps → AI Observability** tile. The dashboard panels filter by `gen_ai.provider.name="ollama"` (or `"mlx"`) so spans from this skill appear alongside any other GenAI workload sending to the same stack.

## Skill-specific dashboards (committed in `dashboards/grafana/`)

The pre-built integration above covers the GenAI-generic view. Three skill-specific dashboards committed to the repo cover the slices Grafana's GenAI integration does not — the recipe-and-tier slices keyed off the private `delegate.*` namespace, the HIT/MISS calibration view that consumes the feedback-as-linked-span pattern, and the exit-status breakdown including the canary-timeout (`exit_status=3`) rate. Each is one JSON file; import via **Dashboards → New → Import → Upload JSON file** in the Grafana UI:

- Import [`dashboards/grafana/delegate-overview.json`](../../dashboards/grafana/delegate-overview.json) for call volume over time broken down by `delegate.tier`, `delegate.recipe`, and `gen_ai.provider.name`, plus histograms for `delegate.queue_wait_ms`, `delegate.generation_ms`, and end-to-end span duration.
- Import [`dashboards/grafana/delegate-calibration.json`](../../dashboards/grafana/delegate-calibration.json) for the HIT/MISS rate keyed off `delegate.feedback.verdict`, per-recipe HIT-rate trend, and a recent-MISSes table grouped by recipe and reason.
- Import [`dashboards/grafana/delegate-errors.json`](../../dashboards/grafana/delegate-errors.json) for the exit-status breakdown, the canary-timeout rate (`exit_status=3`), the recipe-substitution-failure count (`exit_status=2`), and a recent-failed-spans table.

All three dashboards target a Tempo datasource provisioned with the UID `tempo` (Grafana Cloud's default name for the bundled traces datasource); if your stack uses a different UID, update the `datasource.uid` field in each JSON before importing. The TraceQL queries inside the panels reference attribute names verbatim from [`docs/otel-schema.md`](../otel-schema.md), so the dashboards stay correct as long as the schema doc and the exporter stay in sync — [`tests/test-dashboards.sh`](../../tests/test-dashboards.sh) is the CI gate that pins each panel's referenced attribute back to the schema.

## Copy-pasteable env block

After generating the auth string above, export the two variables `delegate.sh` reads:

```bash
export DELEGATE_OTEL_ENDPOINT="https://otlp-gateway-prod-<region>.grafana.net/otlp/v1/traces"
export DELEGATE_OTEL_HEADERS="Authorization: Basic <base64-encoded-instance-id:token>"
```

Substitute your region (e.g. `us-central-0`, `eu-west-0`) and the base64 string from the auth step. Once exported, the next `delegate.sh` call posts one span per invocation; the matching `delegate-feedback.sh hit|miss` call posts the feedback span with `links` to the parent.

## Backfill historical metrics

The exporter only emits spans for new delegations going forward. If your `metrics.jsonl` already has weeks or months of pre-exporter rows, the dashboards will start empty until enough new traffic accumulates. To seed the dashboards with the existing history, run the backfill script after the env vars above are exported:

```bash
bash scripts/backfill-otel.sh                       # post every pre-exporter row
bash scripts/backfill-otel.sh --since 2026-05-01T00:00:00Z  # only since a date
bash scripts/backfill-otel.sh --dry-run             # preview without POSTing
bash scripts/backfill-otel.sh --update-jsonl        # also write the IDs back
```

Row-level idempotent: any row that was already exported live (carries `otel_trace_id` in the JSONL) is skipped, and rows that pre-date the exporter get deterministic trace and span IDs derived from `sha256(ts|source)` and `sha1(ts|source)`. Re-running the backfill — or resuming an interrupted run — collides in Tempo's OTel ID space and produces no duplicate spans. `--update-jsonl` writes the computed IDs back into the JSONL so subsequent runs skip via the live-exported path (mutates the metrics file atomically via tempfile-and-rename); it's opt-in because mutating the metrics file is a more invasive operation than the default read-only backfill.

## See also

- [docs/observability/langfuse-self-host.md](langfuse-self-host.md) — privacy-conscious self-hosted alternative when telemetry must stay on-device.
- [docs/observability/phoenix.md](phoenix.md) — ultra-light single-container alternative for local-only inspection without infrastructure.
