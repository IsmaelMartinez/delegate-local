# Phoenix — OTLP runbook

[Arize Phoenix](https://github.com/Arize-ai/phoenix) is the ultra-light alternative to Grafana Cloud and Langfuse. A single container, SQLite-backed by default, zero configuration. Best for short-lived local inspection sessions where standing up ClickHouse and PostgreSQL would dwarf the data being inspected.

## When to pick this

Phoenix operates as a single Docker container with a default SQLite backend, requiring zero configuration to run. It translates OpenTelemetry gen_ai attributes into the OpenInference vocabulary at ingest, allowing immediate inspection of traces without external databases. This setup suits short-lived sessions where you need to review a handful of delegations without standing up complex infrastructure. The tool provides a native UI for this purpose rather than offering pre-built dashboards or first-class scoring models.

## One-liner bring-up

```bash
docker run -p 6006:6006 -p 4317:4317 -i -t arizephoenix/phoenix:latest
```

Port 6006 serves both the UI and the OTLP HTTP collector; 4317 is the OTLP gRPC collector for clients that prefer it. The container starts in ~5 seconds; no database to initialise, no migrations to run, no env vars required for a workstation install. State persists in the container's filesystem (back the SQLite file with `-v $HOME/phoenix:/phoenix-data` if you want it to survive `docker rm`).

The UI is then at [http://localhost:6006](http://localhost:6006). See [Phoenix Docker deployment docs](https://arize.com/docs/phoenix/self-hosting/deployment-options/docker) for the authoritative reference, including the available image tags and volume-mount options for persistent storage.

## OTLP endpoint

Phoenix's OTLP HTTP traces endpoint is the standard signal-specific path:

```
http://localhost:6006/v1/traces
```

No authentication is required for the default workstation deployment — Phoenix expects to run on `localhost` behind whatever the host already trusts. (For shared deployments, see Phoenix's [authentication guide](https://arize.com/docs/phoenix/deployment/authentication); the Track A exporter passes `DELEGATE_OTEL_HEADERS` through verbatim so any header-based scheme works.)

## OpenInference and gen_ai.* attribute translation

Phoenix uses [OpenInference](https://github.com/Arize-ai/openinference) as its native semantic-convention layer, but the project ships an OpenInference-side converter that translates OTel's `gen_ai.*` semantic conventions into the OpenInference equivalents at ingest. The `delegate.sh` exporter emits the standard `gen_ai.*` namespace (the same attributes Grafana Cloud's GenAI dashboards key off), and Phoenix's `OpenInferenceSpanProcessor` performs the mapping so the spans show up in Phoenix's LLM-trace view with token counts, model name, provider, and latency populated. See the [Phoenix translating-conventions docs](https://arize.com/docs/phoenix/tracing/concepts-tracing/translating-conventions) for the current mapping table — the relevant rows for this skill are `gen_ai.request.model → llm.model_name`, `gen_ai.provider.name → llm.provider`, `gen_ai.operation.name → openinference.span.kind`.

In practice this means: spans land in Phoenix without modifying the exporter, but UI panels surface them under Phoenix's vocabulary rather than the raw `gen_ai.*` attribute names. The trade-off is acceptable for the inspection use case Phoenix targets; for cross-tool dashboards (Grafana panels that key off `gen_ai.client.operation.duration`) the hosted Grafana Cloud path is the better fit.

## Copy-pasteable env block

```bash
export DELEGATE_OTEL_ENDPOINT="http://localhost:6006/v1/traces"
```

No `DELEGATE_OTEL_HEADERS` is required for the default workstation install. Once exported, the next `delegate.sh` call posts one span per invocation; the matching `delegate-feedback.sh hit|miss` call posts the feedback span with `links` to the parent — Phoenix renders the two as a linked trace pair under the parent's project view.

## See also

- [docs/observability/grafana-cloud.md](grafana-cloud.md) — hosted alternative with pre-built GenAI dashboards keyed on the native `gen_ai.*` attributes.
- [docs/observability/langfuse-self-host.md](langfuse-self-host.md) — privacy-conscious self-hosted alternative with first-class scores for the hit/miss verdict, at the cost of a full ClickHouse plus PostgreSQL stack.
