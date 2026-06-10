# Contributing

Thanks for taking the time to look. This repo is one Claude Code skill, two bash scripts of routing logic, and a validation pipeline. There is no build, no linter, and no package manager. The runtime is `bash` (3.2+ — macOS-shipped is fine), `jq`, `awk`, `perl`, and `curl` (used by `scripts/delegate.sh` against the backend HTTP API and by all three scoring modes of the trigger eval — `--api`, `--ollama`, `--github-models`).

## What lives where

`SKILL.md` is the prompt Claude reads to decide whether to invoke the skill. Its frontmatter `description` field is load-bearing: changes to it directly affect trigger accuracy across every conversation that has the skill installed. Treat `SKILL.md` as production prompt content, not documentation.

`scripts/pick-model.sh` is the single source of truth for tier-to-model routing. Each tier (`code`, `prose`, `reasoning`, `long-context`, plus the scaffolded `vision`, `embedding`, `premium-general`, `reasoning-vision`) holds a substring-matched preference list, highest capability first. When the installed model set changes, edit the `prefs` arrays in this script — never hardcode model names in `SKILL.md` or in shell pipes.

`scripts/delegate.sh` wraps `pick-model.sh` plus the backend's HTTP completions API and appends one JSON line per call to `~/.claude/skills/delegate-local/metrics.jsonl`. It supports two backends selected by `DELEGATE_BACKEND=auto|ollama|mlx` (default `auto`): `auto` probes the local MLX server (`mlx_lm.server`, default `http://localhost:8080`) and routes through it when reachable, otherwise falls back to Ollama (`POST /api/generate`, default `http://localhost:11434`). Non-Apple-Silicon hosts always fall through to Ollama. `scripts/audit-models.sh` is read-only and never pulls; it cross-checks `llmfit recommend --json` against `ollama list`. `scripts/metrics-summary.sh` is the read-only rollup over the metrics JSONL.

`prompts/` is the calibrated-recipe library — each `prompts/<task>.md` ships a proven prompt skeleton with anti-hallucination guards drawn from real session feedback. To add a recipe (or graduate a recurring delegation pattern into one), follow the flow documented in [`prompts/README.md`](prompts/README.md); `tests/test-prompts-library.sh` enforces the required structure.

`mcp/` is the optional Python MCP server that exposes five read-only tools (`pick_model`, `audit_models`, `list_tiers`, `list_related_projects`, `recommend_prompt`) to non-Claude clients. It is a thin `subprocess.run` wrapper over the bash scripts and the recipe markdown, not a reimplementation. `experiments/` is the empirical accuracy framework — six fixtures, one runner, one orchestrator, and a deterministic scorer per task. `docs/adr/` records the load-bearing design decisions; read them before proposing changes that contradict one.

`ROADMAP.md` is the authoritative project plan and is structured by phase. Consult it before starting non-trivial work — phases 2 and 3 in particular have ordering dependencies.

## Running the validation pipeline

The same gates CI runs on every PR are runnable locally. The two frontmatter / content validators plus the unit suite cover most edits:

```bash
bash scripts/validate-frontmatter.sh SKILL.md
bash scripts/validate-skill-content.sh SKILL.md
bash scripts/eval-skill-triggers.sh   # shape check (no model call)
bash tests/run-tests.sh
```

Each script has its own per-script test file under `tests/` (there are many — `test-delegate.sh`, `test-score-t3.sh` through `test-score-t9.sh`, `test-run-api-cell.sh`, `test-apply-and-test.sh`, `test-delegate-feedback.sh`, `test-prompts-library.sh`, `test-audit-metrics.sh`, and more). Rather than enumerate them here, the authoritative list of gates is [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — run the `tests/test-*.sh` step that matches the script you touched, and run the full set before opening the PR to match CI.

If you edit the `description` field in `SKILL.md` frontmatter, run the trigger eval against a real model before opening the PR:

```bash
bash scripts/eval-skill-triggers.sh --ollama
```

This is free, runs locally in 10–30 seconds, and dogfoods the project's own routing. CI runs the same gate against GitHub Models on every PR, so a regression there will fail the build. The threshold is recall ≥ 0.9 and negative-precision ≥ 0.9 against `evals/eval-set.json`.

The MCP server's tests run independently from the bash suite:

```bash
cd mcp && pytest -q
```

A post-edit hook at `.claude/hooks/post-edit-validate.sh` runs the frontmatter and content checks automatically when you save through Claude Code. It does not run the trigger-accuracy gate — run that yourself before merge.

The `URL_EXTERNAL` content check applies to `SKILL.md` only; contributor docs under `prompts/` may cite external sources (papers, third-party libraries) as evidence of design decisions without going through the allowlist.

## Commits and PRs

Conventional-commit prefixes (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`) are required by the release-please pipeline that drives versioning and CHANGELOG generation. Keep commit and PR messages concise. Reference an issue or roadmap item when the change is non-trivial.

PRs run frontmatter validation, the content scan, the unit suite, the trigger eval against GitHub Models, and the MCP test suite. All five must pass. The trigger eval uses the auto-provisioned `GITHUB_TOKEN` so there is no secret to configure.

## Labels

Two project-specific issue labels you may encounter. `prompt-pattern` marks an issue that captures a recurring delegation MISS — a task shape the local model keeps getting wrong — so the maintainer can graduate it into a calibrated `prompts/<task>.md` recipe (the `delegate-feedback.sh` nudge drafts these; see the README "Calibration feedback loop"). `baseline-staleness` marks an issue filed by the fortnightly staleness check when the newest `experiments/results/<date>-baseline.md` is more than 14 days old, prompting a re-run of the empirical baseline on a workstation with the routed local backend (MLX by default; see ROADMAP "Phase 7 — Empirical accuracy benchmarking" for the exact command). The writeup must be named `<date>-baseline.md` with no infix — a `-mlx-baseline.md` style name escapes the staleness check's date pattern.

## Cross-platform constraints

This skill runs on the macOS-shipped bash 3.2 and the GNU bash that most Linux distributions ship. Two things to avoid:

```bash
# Avoid: associative arrays (bash 4-only — breaks on macOS)
declare -A foo

# Avoid: grep -P (GNU-only — breaks on macOS BSD grep)
grep -P '\d+' file
```

Use newline-delimited allowlists keyed by either path-and-line or sha256, and use `perl -CSD` for unicode-aware regex. The validation scripts already follow this pattern; match their style when adding new ones.

## Scope

The "out of scope" section of `ROADMAP.md` is binding. The discriminator is the local-brain insight: local models are strong summarisers and weak agents. If a task needs multi-step reasoning, repo-wide context, or tool-calling, it does not belong in this skill even if the surface looks textual. A general-purpose router, an auto-pulling installer, and code-edit / refactor delegation are all explicitly out of scope.

## Where to start

The roadmap's "Next session" section lists priority-ordered work. Items marked `[done]` are shipped; unmarked items in the priority list are the live ones. Items in the deferred or out-of-scope sections need a concrete trigger before they become live.

For first-time contributors, the lowest-friction starting points are: adding a fixture to `experiments/fixtures/`, refining a tier's preference list in `pick-model.sh` (with a corresponding test in `tests/run-tests.sh`), or adding an issue category to `scripts/validate-skill-content.sh` with a test fixture. ADR `docs/adr/0003-tier-preference-lists.md` covers the rationale for the routing shape if you want to read before editing.

## Code of Conduct

Participation in this project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
