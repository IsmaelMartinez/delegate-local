# Contributing

Thanks for taking the time to look. This repo is one Claude Code skill, two bash scripts of routing logic, and a validation pipeline. There is no build, no linter, and no package manager. The runtime is `bash` (3.2+ — macOS-shipped is fine), `jq`, `awk`, `perl`, and `curl` (used by `scripts/delegate.sh` against the Ollama HTTP API and by all three scoring modes of the trigger eval — `--api`, `--ollama`, `--github-models`).

## What lives where

`SKILL.md` is the prompt Claude reads to decide whether to invoke the skill. Its frontmatter `description` field is load-bearing: changes to it directly affect trigger accuracy across every conversation that has the skill installed. Treat `SKILL.md` as production prompt content, not documentation.

`scripts/pick-model.sh` is the single source of truth for tier-to-model routing. Each tier (`code`, `prose`, `reasoning`, `long-context`, plus the scaffolded `vision`, `embedding`, `premium-general`, `reasoning-vision`) holds a substring-matched preference list, highest capability first. When the installed model set changes, edit the `prefs` arrays in this script — never hardcode model names in `SKILL.md` or in shell pipes.

`scripts/delegate.sh` wraps `pick-model.sh` plus Ollama's `POST /api/generate` and appends one JSON line per call to `~/.claude/skills/delegate-local/metrics.jsonl`. `scripts/audit-models.sh` is read-only and never pulls; it cross-checks `llmfit recommend --json` against `ollama list`. `scripts/metrics-summary.sh` is the read-only rollup over the metrics JSONL.

`mcp/` is the optional Python MCP server that exposes three read-only tools (`pick_model`, `audit_models`, `list_tiers`) to non-Claude clients. It is a thin `subprocess.run` wrapper over the bash scripts, not a reimplementation. `experiments/` is the empirical accuracy framework — three fixtures, one runner, one orchestrator, one deterministic T3 scorer. `docs/adr/` records the load-bearing design decisions; read them before proposing changes that contradict one.

`ROADMAP.md` is the authoritative project plan and is structured by phase. Consult it before starting non-trivial work — phases 2 and 3 in particular have ordering dependencies.

## Running the validation pipeline

The same gates CI runs on every PR are runnable locally:

```bash
bash scripts/validate-frontmatter.sh SKILL.md
bash scripts/validate-skill-content.sh SKILL.md
bash scripts/eval-skill-triggers.sh
bash tests/run-tests.sh
bash tests/test-validate-frontmatter.sh
bash tests/test-validate-content.sh
bash tests/test-delegate.sh
bash tests/test-metrics-summary.sh
bash tests/test-score-t3.sh
bash tests/test-runner.sh
bash tests/test-eval-skill-triggers.sh
```

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
