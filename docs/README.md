# docs

This index lists the live documentation. The authoritative project scope and plan is [`../ROADMAP.md`](../ROADMAP.md); the recipe conventions are in [`../prompts/README.md`](../prompts/README.md). Finished plans, specs and research notes that nothing live cites any more were removed in #572 and remain in git history.

## Reference

- [`checks.md`](checks.md) — what a recipe call runs around the request: the pre-flight canary, weak-input labels, the deterministic output checks and the single retry.
- [`boundary-hook.md`](boundary-hook.md) — the opt-in `PreToolUse`, `PostToolUse` and `Stop` hooks that credit, enforce and capture delegations at commit, PR, issue and comment boundaries, with their install.
- [`self-improvement-loop.md`](self-improvement-loop.md) — the calibration procedure: the `self-improve.sh` bundle, quarantined finals, the replay gate, the daily launchd runner (its plist is [`launchd/`](launchd/)) and verdict recording.
- [`env.md`](env.md) — every `DELEGATE_*` environment variable the scripts read, with its default and effect.

## Architecture Decision Records — `adr/`

[`adr/`](adr/) holds the load-bearing design decisions, numbered in the order they were made. Read the relevant ADR before proposing a change that contradicts one; each one's Status line says whether it still holds or what superseded it.

## Install guides

Per-tool and per-backend setup, one file each. The universal `npx skills add` install in the top-level [`../README.md`](../README.md) is the recommended path; these guides cover the cases where it is the wrong fit.

- [`install-claude-code.md`](install-claude-code.md) — Claude Code
- [`install-codex.md`](install-codex.md) — Codex
- [`install-opencode.md`](install-opencode.md) — OpenCode
- [`install-mlx.md`](install-mlx.md) — the MLX backend on Apple Silicon (optional; auto-start via launchd)

## Observability — `observability/`

[`observability/`](observability/) documents the opt-in OTLP telemetry exporter and the backends it targets: [Grafana Cloud](observability/grafana-cloud.md), [self-hosted Grafana + Tempo](observability/grafana-local.md), [Langfuse](observability/langfuse-self-host.md), and [Phoenix](observability/phoenix.md). The runnable local Grafana + Tempo compose stack lives in [`../observability/`](../observability/). The wire format is specified in [`otel-schema.md`](otel-schema.md).

## Kept because something live cites them

Two design notes from the removed trees stay where they are because a live file links to them: [`superpowers/specs/2026-06-22-supervised-draft-delegation-design.md`](superpowers/specs/2026-06-22-supervised-draft-delegation-design.md) (cited by ADR 0025 and `prompts/code-draft.md`) and [`research/2026-06-15-phase-e-verdict-automation-design.md`](research/2026-06-15-phase-e-verdict-automation-design.md) (cited by ADR 0015).
