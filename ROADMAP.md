# Roadmap

This is the authoritative, intentionally short project plan. The full historical
record lives in git history, `CHANGELOG.md`, the ADRs under `docs/adr/`, and —
for everything removed in the 2026-06-19 lean-core reset — the
`pre-cleanup-2026-06-19` tag and the `archive/research-machinery` branch.

## What this is

delegate-local is a Claude Code skill that routes "gather context once, send one
prompt, return text" tasks to a locally-installed model (Ollama or MLX) over a
shell pipe. The runtime is deliberately tiny: `scripts/pick-model.sh` resolves a
tier to the best installed model, and `scripts/delegate.sh` posts the prompt to
the backend and returns clean text plus a metrics row. Everything else — the
recipe library, the install/onboarding probes, the calibration feedback loop,
and the CI gates — exists to make that one path reliable and self-correcting.

The discriminator for what belongs here is the local-brain insight: local models
are strong summarisers and weak agents. If a task needs multi-step reasoning,
repo-wide context, or tool-calling, it does not belong in this skill even if the
surface looks textual.

## Where we are (2026-06-19)

Shipped and stable. The skill installs via `npx skills add` (or `cp -r`), routes
across the `code` / `prose` / `reasoning` / `long-context` tiers (with `vision`,
`embedding`, `premium-general`, and `reasoning-vision` scaffolded), auto-selects
Ollama or MLX, ships 21 calibrated recipes led by `commit-message`, records
hit/miss verdicts that feed `metrics-summary.sh`, and gates every PR on a
frontmatter + content + trigger-eval CI pipeline plus the bash test suite.

The 2026-06-19 lean-core reset returned the repo to that core after a period of
heavy accretion. It archived the maintainer-facing research machinery out of the
installed tree (the `experiments/` accuracy framework, the
embeddings/semantic-search path, the Python MCP server, the verdict-automation
hooks, the maintainer analysis tools, and the faithfulness-grounding prototype),
trimmed the accreted verify-and-
escalate gate out of `delegate.sh`, cut the `commit-message` recipe from 62KB to
~14KB by removing inline calibration history, and pruned the dead recipe tail.
The principle of the reset: recover quality by shrinking what a model and a
reader have to take in, not by adding more gates. All of it is recoverable from
the tag and archive branch named at the top of this file.

The OpenTelemetry → Loki/Grafana observability pipeline is explicitly retained,
not archived: `scripts/lib/otel.sh` span emission (opt-in via
`DELEGATE_OTEL_ENDPOINT`), the `sync-metrics-to-loki.sh` and `backfill-otel.sh`
exporters, the Grafana `dashboards/`, `observability/`, and the
`docs/observability/` guides are the maintainer's live visibility into
delegation traffic and stay in the core.

## Where we're going (next, priority-ordered)

1. Decide on a deeper recipe prune. The reset kept every recipe with real usage
   or a SKILL.md trigger; a further cut to the ~10-recipe high-usage head is
   available if the maintainer wants the library leaner still.
2. Re-verify the install on a genuinely clean machine (not the dev symlink) and
   keep the install path covered as the headline trust surface.
3. Sweep the few in-code comments in `delegate.sh` that still reference the
   removed escalate gate.

Anything beyond this is a fresh, evidence-gated decision. Re-introducing an
archived capability (MCP, experiments) should be driven by a real consumer
asking for it, not by default.

## Out of scope

- Code edits, refactors, or feature implementation. Local models are weak agents and the skill description explicitly rejects these. The local-brain finding stands: "they didn't need Smolagents, they needed `git status | ollama run model`".
- Auto-pulling models without confirmation. Multi-GB downloads stay user-decided; the audit script suggests, never installs.
- A general-purpose router that competes with Claude on routing decisions. This skill picks a model within Ollama; it does not decide whether to call Claude vs Ollama. That decision belongs in the skill description, evaluated by Claude itself.
