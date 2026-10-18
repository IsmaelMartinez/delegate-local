# docs

This index lists the live documentation. The authoritative project scope and plan is [`../ROADMAP.md`](../ROADMAP.md); the recipe conventions are in [`../prompts/README.md`](../prompts/README.md). The project was wound down by [ADR 0035](adr/0035-narrow-to-large-piped-inputs-and-wind-down.md); what it taught is in [`learnings.md`](learnings.md). Documents for removed tooling (the boundary hooks, the self-improvement loop, the model-swap runbook) are recoverable from commit `a00b2e9`, and older ones removed in #572 remain in git history.

## Reference

- [`learnings.md`](learnings.md) — what the experiment taught about cost, quality, enforcement, latency and engineering habits, and how to measure it again.
- [`checks.md`](checks.md) — what a recipe call runs around the request: the pre-flight canary, weak-input labels, the deterministic output checks and the single retry.
- [`env.md`](env.md) — every `DELEGATE_*` environment variable the scripts read, with its default and effect.
- [`verify.md`](verify.md) — `verify-draft.sh`, the offline grounding check of a draft against its inputs (dormant since ADR 0035).

## Architecture Decision Records — `adr/`

[`adr/`](adr/) holds the load-bearing design decisions, numbered in the order they were made. Read the relevant ADR before proposing a change that contradicts one; each one's Status line says whether it still holds or what superseded it.

## Recipe calibration history — `calibration/`

[`calibration/`](calibration/) holds one file per recipe in [`../prompts/`](../prompts/): the dated record of what each recipe edit observed, measured and changed, moved out of the recipes in #569 so a recipe stays the size of what its caller reads. Every recipe edit adds an entry here.

## Install guides

Per-tool and per-backend setup, one file each. The universal `npx skills add` install in the top-level [`../README.md`](../README.md) is the recommended path; these guides cover the cases where it is the wrong fit.

- [`install-claude-code.md`](install-claude-code.md) — Claude Code
- [`install-codex.md`](install-codex.md) — Codex
- [`install-opencode.md`](install-opencode.md) — OpenCode
- [`install-mlx.md`](install-mlx.md) — the MLX backend on Apple Silicon (optional; auto-start via launchd)

## Observability — `observability/`

[`observability/`](observability/) documents the opt-in OTLP telemetry exporter and the backends it targets: [Grafana Cloud](observability/grafana-cloud.md), [self-hosted Grafana + Tempo](observability/grafana-local.md), [Langfuse](observability/langfuse-self-host.md), and [Phoenix](observability/phoenix.md). The runnable local Grafana + Tempo compose stack lives in [`../observability/`](../observability/). The wire format is specified in [`otel-schema.md`](otel-schema.md).

## Kept because something live cites them

Two design notes from the removed trees stay where they are because a live file links to them: [`superpowers/specs/2026-06-22-supervised-draft-delegation-design.md`](superpowers/specs/2026-06-22-supervised-draft-delegation-design.md) (cited by ADR 0025) and [`research/2026-06-15-phase-e-verdict-automation-design.md`](research/2026-06-15-phase-e-verdict-automation-design.md) (cited by ADR 0015).
