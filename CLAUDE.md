# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo *is* a Claude Code skill, not an application that uses one. Editing `SKILL.md` changes how Claude itself behaves whenever the skill is loaded. Treat `SKILL.md` as production prompt content, not documentation: its frontmatter `description` is the prompt Claude reads to decide whether to invoke the skill, so an edit to it changes trigger accuracy in every conversation that has the skill installed. Keep the MUST/MUST NOT structure intact, and gate every `description` edit with the trigger eval below (recall ≥ 0.9 and negative-precision ≥ 0.9).

Since ADR 0035 (2026-10-18) the project is wound down to one shape: a large input Claude has not read (a long log, thread, document, directory or item list) is piped in chunks to a local model (MLX, Docker Model Runner or Ollama) over a shell pipe, and a short answer anchored to the input comes back for Claude to spot-check. Drafting text Claude will publish was measured net negative and left `main` with its hooks and calibration loop; `docs/learnings.md` keeps the lessons and commit `a00b2e9` the code. There is no framework, router process or orchestration layer: the runtime path is `scripts/pick-model.sh` and `scripts/delegate.sh`. The discriminator is the local-brain insight: local models are strong summarisers and weak agents, so a task that needs multi-step reasoning, repo-wide context or tool-calling does not belong even if it looks textual. `ROADMAP.md` "Out of scope" enumerates the boundaries; do not add recipes or calibration machinery without a new ADR that answers ADR 0035's signposts.

## Commands

There is no build step and no package manager. Run the whole suite (every file mocks `curl`, so a machine with a live model server gets the same counts as CI):

```bash
for f in tests/run-tests.sh tests/test-*.sh; do bash "$f"; done
```

Delegate, with or without a recipe (a recipe's tier comes from its frontmatter; `--tier` overrides):

```bash
grep -nE 'ERROR|FAIL' build.log | bash scripts/delegate.sh reasoning "<closed question with line-number anchors>"
gh issue view 142 --comments | bash scripts/delegate.sh --recipe summarise-issue --var kind=issue --var N_FACTS=5
bash scripts/pick-model.sh <code|prose|reasoning|long-context|vision|embedding|premium-general|reasoning-vision>
bash scripts/audit-models.sh        # read-only: tier routing
bash scripts/metrics-summary.sh --days 7          # or --since YYYY-MM-DD
```

The validation pipeline CI runs on every PR, runnable locally:

```bash
bash scripts/validate-frontmatter.sh SKILL.md
bash scripts/validate-skill-content.sh SKILL.md
bash scripts/eval-skill-triggers.sh                           # eval-set shape only
bash scripts/eval-skill-triggers.sh --decide                  # pre-merge trigger gate for a description edit (free, on-device, #638)
ANTHROPIC_API_KEY=… bash scripts/eval-skill-triggers.sh --api # what CI runs when SKILL.md or evals/ change and the secret is set
find scripts tests .claude/hooks -name '*.sh' -print0 | xargs -0 shellcheck -S error
```

`.claude/hooks/post-edit-validate.sh` runs the frontmatter, content and eval-shape checks on save, not the trigger-accuracy gate.

## Architecture

`scripts/pick-model.sh` is the single source of truth for tier-to-model routing. Each tier holds a case-insensitive substring preference list, highest capability first, and the first served model matching one wins. `code`, `prose`, `reasoning` and `long-context` are active, and since #652 the other three reuse the `prose` list so a server that advertises its whole cache (`mlx_lm.server`) never loads a second large model for them; `vision`, `embedding` and `reasoning-vision` resolve only when a matching model is served, and `premium-general` ships an empty list that only `config.sh` fills. When the model set changes, edit the `prefs` in this script; never hardcode model names in `SKILL.md` or in delegation pipes. Discovery and dispatch go through `DELEGATE_BASE_URL`, an ordered list of OpenAI-compatible base URLs defaulting to MLX (`:8080/v1`), Docker Model Runner (`:12434/engines/v1`) and Ollama (`:11434/v1`), each overridable by `MLX_HOST`, `DOCKER_MODEL_HOST` and `OLLAMA_HOST`. Each is probed with `GET {base}/models` (1 s, `DELEGATE_PROBE_TIMEOUT`); the first reachable one serving a preferred model wins, and MLX leads because ADR 0022 measured it about ten times faster than Ollama on identical weights. "Installed" means a running provider reports it, never a filesystem scan.

`scripts/delegate.sh` is the wrapper `SKILL.md` teaches. It resolves `<base>\t<model>` with `pick-model.sh --print-resolution` and posts to `{base}/chat/completions` with `temperature:0`, `stream:false` and `chat_template_kwargs.enable_thinking` (false unless `DELEGATE_THINK=true`); the raw `/v1/completions` endpoint is avoided because it bypasses the chat template. Each call appends one JSON row to `~/.local/share/delegate-local/metrics.jsonl` with a `backend` label derived from the winning URL (`DELEGATE_LOCAL_NO_METRICS=1` opts out), and stores the draft, and for recipe calls the rendered input and structured inputs, under `drafts/` beside it. `--recipe NAME` loads `prompts/<NAME>.md`, substitutes `{{key}}` from `--var` and `{{stdin}}` from the pipe, and exits 2 on any unsubstituted placeholder. Recipe calls also run a 1-token pre-flight canary (exit 3 on a stall), weak-input labels, the deterministic output checks and at most one retry; all of that is in `docs/checks.md`.

Shared code lives in `scripts/lib/`: `recipe.sh` (every recipe reader, including `recipe_template_sha`), `checks.sh` (`run_output_checks`), `text.sh` (sentence, normalise and anchor helpers shared by the checks and the scorer), `pair-score.sh` and `pair.jq` (draft/final scoring and the verdict join used by `metrics-summary.sh`), `otel.sh` (`delegate_project_name` and opt-in span emission) and `gpu-gate.sh` (the heat gate batch callers run before each item, #646, and their `caffeinate -i` idle-sleep guard, #657, which a closed lid on battery still overrides).

A delegation is filed under the main repository's basename (`delegate_project_name`, so a linked worktree files under its repo); outside a git repository the `project` field is omitted rather than set to the cwd's basename, and `--project NAME` or `DELEGATE_PROJECT` override. `delegate-feedback.sh` copies the project off the row it references.

`prompts/` holds the three recipes that fit the large-input shape (`summarise-issue`, `bulk-classify`, `file-summary`); `prompts/README.md` covers the template conventions and `tests/test-prompts-library.sh` enforces each recipe's structure. Each recipe's history is in `docs/calibration/<recipe>.md`.

Dormant since ADR 0035 and kept only until the repository is archived: `delegate-feedback.sh` (verdicts are optional and no longer requested), `verify-draft.sh`, `decide.sh`, `embed.sh`, `semantic-search.sh` and the OpenTelemetry and Loki tooling. They cost nothing per session; do not extend them.

## Conventions

Portability is a real constraint. Runtime deps are `bash` 3.2+ (macOS-shipped), `jq`, `awk`, `perl` and `curl`. Avoid associative arrays (bash 4 only) and `grep -P` (GNU only); use `perl -CSD` for unicode-aware regex, and keep every new regex or glob linear-time (no nested quantifiers). ShellCheck at `-S error` is the one linter, configured by `.shellcheckrc`.

Tests share `tests/lib/assert.sh` (#561: the asserts and counters, `SAFE_PATH`, `mock_curl`, and `HOME`/`TMPDIR` pinned to a temp dir so a developer's `config.sh` and `profile.sh` never reach a test); files adopt it as they are next touched. CI discovers every `tests/test-*.sh` plus `tests/run-tests.sh`, so a new test file needs no `ci.yml` edit. The prose-tier ordering test in `tests/run-tests.sh` (the current prose model ahead of qwen3-next) encodes a measured baseline; do not relax it without re-measuring, and expect that suite to change when you reorder `pick-model.sh` preferences.

Name the tier's role ("the prose-tier model"), never the model it currently resolves, outside `scripts/pick-model.sh`. Tests use `$PROSE_MODEL` from `tests/lib/assert.sh` (derived from the shipped prose list) or a neutral id such as `test-prose-model`. `tests/test-model-names.sh` enforces this and holds the allowlist: routing, the routing tests, shipped calibration data and history (ADRs, `docs/calibration/`, `CHANGELOG.md`, dated read-outs).

`ROADMAP.md` is the authoritative plan. When asked to continue earlier work, start from its "Active work" section, which names the tracking epic, the next issues in order and the working method.

Not everything absent from `main` was never built. Commit `22395b2` ("chore: archive research/observability machinery out of main") deleted 406 files, including working tooling that was later restored (the verdict scripts in #416, `scripts/apply-and-test.sh` in #419). Before writing a new helper, check `git show --numstat --format="" 22395b2 | grep -F '<name>'`, and for anything the ADR 0035 wind-down removed, `git show a00b2e9:<path>`.

The metrics corpus restarted from zero on 2026-08-19 (ADR 0028); the earlier rows are archived under `~/.local/share/delegate-local/archive/2026-08-19-pre-reset/` and no rate from before that date is comparable to a live one. Quote the N beside every rate you read from `metrics-summary.sh`; at this sample size one delegation moves every percentage.

## The live install on the maintainer's machine

End users install with `npx skills add IsmaelMartinez/delegate-local` (`README.md` has the manual fallback). On the maintainer's machine, since #360 both `~/.claude-home/skills/delegate-local` and `~/.claude-work/skills/delegate-local` are symlinks to `~/.local/share/delegate-local-live`, a separate clone of `origin/main` (a clone, not a worktree, so `git worktree prune` can never delete it). Since ADR 0035 no hook should call into it; a profile `settings.json` that still names `delegate-boundary-hook.sh`, `delegate-boundary-confirm-hook.sh` or `delegate-verdict-stop-hook.sh` must drop those entries before the live clone is pulled past the wind-down. This checkout's branch therefore does not change what other sessions run. After a merge, update the live skill with `git -C ~/.local/share/delegate-local-live pull --ff-only`. Test unmerged code by running scripts from this checkout or a worktree by path with `DELEGATE_LOCAL_DATA_DIR` or `DELEGATE_METRICS_FILE` pointed at a scratch location, and never repoint either symlink at this checkout. The data dir `~/.local/share/delegate-local` (metrics, drafts, `config.sh`) is outside every checkout.

## Repo Butler

This repo is monitored by [Repo Butler](https://github.com/IsmaelMartinez/repo-butler), a portfolio health agent that observes repo health daily and generates dashboards, governance proposals, and tier classifications.

**Your report:** https://ismaelmartinez.github.io/repo-butler/delegate-local.html
**Portfolio dashboard:** https://ismaelmartinez.github.io/repo-butler/
**Consumer guide:** https://github.com/IsmaelMartinez/repo-butler/blob/main/docs/consumer-guide.md

### Querying Reginald (the butler MCP server)

To query your repo's health tier, governance findings, and portfolio data from any Claude Code session, add the MCP server once (adjust the path to your local repo-butler checkout):

```bash
claude mcp add repo-butler node /path/to/repo-butler/src/mcp.js
```

Available tools: `get_health_tier`, `get_campaign_status`, `query_portfolio`, `get_snapshot_diff`, `get_governance_findings`, `trigger_refresh`.

When working on health improvements, check the per-repo report for the current tier checklist and use the consumer guide for fix instructions.

If this repo deploys a page, set its GitHub repository Homepage URL (the Website field in the repo's About section — not `package.json`'s `homepage`) to the canonical URL. That's how repo-butler surfaces the deployed link in dashboards and agent cards.
