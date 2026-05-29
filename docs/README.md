# docs

This index organises the documentation files to help you find the right resource quickly. You will find ADRs, per-backend install guides, observability details, and research notes here, while the authoritative project scope and plan lives in the parent [`../ROADMAP.md`](../ROADMAP.md).

## Architecture Decision Records — `adr/`

[`adr/`](adr/) holds the load-bearing design decisions, numbered in the order they were made. Read the relevant ADR before proposing a change that contradicts one — they explain *why* the skill is shaped the way it is (direct shell piping over a framework, static tier preference lists, the optional MCP server, the OTLP schema, and more).

## Install guides

Per-tool and per-backend setup, one file each:

- [`install-claude-code.md`](install-claude-code.md) — Claude Code
- [`install-codex.md`](install-codex.md) — Codex
- [`install-opencode.md`](install-opencode.md) — OpenCode
- [`install-mlx.md`](install-mlx.md) — the MLX backend on Apple Silicon (optional; auto-start via launchd)

The universal `npx skills add` install in the top-level [`../README.md`](../README.md) is the recommended path; these guides cover the cases where it is the wrong fit.

## Observability — `observability/`

[`observability/`](observability/) documents the opt-in OTLP telemetry exporter and the backends it targets: [Grafana Cloud](observability/grafana-cloud.md), [self-hosted Grafana + Tempo](observability/grafana-local.md), [Langfuse](observability/langfuse-self-host.md), and [Phoenix](observability/phoenix.md). The runnable local Grafana + Tempo compose stack lives in [`../observability/`](../observability/). The wire format is specified in [`otel-schema.md`](otel-schema.md).

## Research — `research/`

[`research/`](research/) holds forward-looking plans and exploratory notes (cross-project adoption, expansion planning). These are not commitments — the authoritative plan is [`../ROADMAP.md`](../ROADMAP.md).
