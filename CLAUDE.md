# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo *is* a Claude Code skill, not an application that uses one. Editing `SKILL.md` changes how Claude itself behaves whenever the skill is loaded. Treat `SKILL.md` as production prompt content, not documentation: changes to its frontmatter `description` directly affect trigger accuracy across every conversation that has the skill installed.

The skill's job is to route "gather context once, send one prompt, return text" tasks to local Ollama models via shell pipes. It deliberately avoids any framework, router process, or orchestration layer — the entire runtime surface is two bash scripts.

## Commands

Run the unit tests (mocks `ollama` and `llmfit` on a restricted PATH so results are deterministic regardless of what is installed):

```bash
bash tests/run-tests.sh
```

Audit installed models and see tier routing plus llmfit upgrade suggestions (requires `ollama`, `jq`, and optionally `llmfit` on PATH):

```bash
bash scripts/audit-models.sh
```

Resolve a tier to a model name (used internally by `delegate.sh`, also useful for one-off shell pipes):

```bash
bash scripts/pick-model.sh <code|prose|reasoning|long-context|vision|embedding|premium-general|reasoning-vision>
```

Wrap a delegation through the metrics-capturing wrapper (preferred over bare `ollama run`):

```bash
echo "<context>" | bash scripts/delegate.sh prose "<prompt>"
```

Read the metrics roll-up:

```bash
bash scripts/metrics-summary.sh
```

Record a hit/miss verdict against the most recent delegation (the output was kept as-is = hit, or was rewritten / discarded = miss). The verdict appends a `source:"feedback"` row to the same metrics JSONL keyed by `ref_ts` to the delegate event:

```bash
bash scripts/delegate-feedback.sh hit
bash scripts/delegate-feedback.sh miss "bulleted output when prose was wanted"
```

Run the validation pipeline locally (the same gates CI runs on every PR — frontmatter shape, content scan, trigger-eval shape, plus per-script unit tests):

```bash
bash scripts/validate-frontmatter.sh SKILL.md
bash scripts/validate-skill-content.sh SKILL.md
bash scripts/eval-skill-triggers.sh
bash tests/test-validate-frontmatter.sh
bash tests/test-validate-content.sh
bash tests/test-delegate.sh
bash tests/test-metrics-summary.sh
bash tests/test-score-t3.sh
bash tests/test-runner.sh
bash tests/test-eval-skill-triggers.sh
```

Run the trigger eval against a local Ollama model (free, on-device; recommended pre-merge gate for any frontmatter `description` edit):

```bash
bash scripts/eval-skill-triggers.sh --ollama                          # default: pick-model.sh code
bash scripts/eval-skill-triggers.sh --ollama qwen3.6:35b-a3b-q8_0     # known-good batched scorer
```

Run the trigger eval against GitHub Models (free up to per-model rate-limit tier; this is what runs in CI on every PR):

```bash
GITHUB_TOKEN=$(gh auth token) bash scripts/eval-skill-triggers.sh --github-models  # default: openai/gpt-4o-mini
```

Run the trigger eval against the live Anthropic API (requires `ANTHROPIC_API_KEY`; kept for the rare case Claude-grade scoring is wanted):

```bash
ANTHROPIC_API_KEY=… bash scripts/eval-skill-triggers.sh --api
```

Run the empirical accuracy fixtures against a specific installed model and append timing + raw output to `experiments/results/raw/<slug>.txt`. `--reps N` repeats every task N times within the same file (default 1); `--t3-snapshot DATE` selects which dated T3 fixture (default `2026-04-28`):

```bash
bash experiments/runner.sh [--reps N] [--t3-snapshot DATE] <ollama-model-name>
```

Run the full sequential baseline matrix (one model resident at a time, `ollama stop` between models so timing is FS-cache-fair):

```bash
bash experiments/run-baseline.sh [--reps N] [--t3-snapshot DATE] [--no-stop] <model> [<model>...]
```

Score a model's T3 output deterministically (citation-rate against the dated T3 fixture; replaces the human-judged rubric used in the 2026-04-28 baseline):

```bash
bash experiments/score-t3.sh experiments/results/raw/<slug>.txt [--t3-snapshot DATE]
```

Apply a model's SEARCH/REPLACE patch output to a source directory and run pytest, returning a machine-parseable verdict (replaces the per-session open-coded apply-and-test logic in the v8 + adversarial scorers):

```bash
bash scripts/apply-and-test.sh [--test-script NAME] [--timeout SECS] [--out DIR] <source-dir> <patch-file>
echo "$model_output" | bash scripts/apply-and-test.sh <source-dir> -
```

There is no build step, no linter, no package manager. Runtime deps are `bash` (3.2+ — macOS-shipped is fine), `jq`, `awk`, and `perl` (used in one validator because BSD grep on macOS lacks `-P`). `curl` is required by `scripts/delegate.sh` (Ollama HTTP API) and by all three scoring modes of the trigger eval (`--api`, `--ollama`, `--github-models`). Cross-platform portability is a real constraint: avoid associative arrays (bash 4-only), avoid `grep -P` (GNU-only), and prefer `perl -CSD` for unicode-aware regex.

Install for end users is `npx skills add IsmaelMartinez/delegate-to-ollama` (Vercel Labs' multi-agent CLI symlinks it into Claude Code, Codex, OpenCode, Cursor, Copilot, etc.) — see `README.md` for the manual `cp -r` fallback.

## Architecture

`scripts/pick-model.sh` is the single source of truth for tier-to-model routing. Each tier holds a substring-matched preference list, highest capability first; the script returns the first installed model whose name contains a preference substring. The four active tiers are `code`, `prose`, `reasoning`, and `long-context`; four more (`vision`, `embedding`, `premium-general`, `reasoning-vision`) are scaffolded — routing is in place but resolution is gated on the relevant model being installed. When the installed model set changes, edit the `prefs` arrays in this script — never hardcode model names in `SKILL.md` or in shell pipes that delegate work.

`scripts/delegate.sh` is the wrapper `SKILL.md` teaches Claude to invoke. It calls `pick-model.sh` to resolve the tier, then `POST /api/generate` on the Ollama daemon (default `http://localhost:11434`, override via `OLLAMA_HOST`) with `think:false`, `temperature:0`, and `stream:false`. The HTTP body is plain text — no ANSI stripping needed, unlike the `ollama run` CLI it replaced (the CLI mixed cursor-rewrites and spinner bytes into stdout). Each call appends one JSON line to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Set `DELEGATE_TO_OLLAMA_NO_METRICS=1` to opt out for a single call. The metrics file is intentionally outside the repo so it survives `git clean -fdx` and isn't committed by accident. `scripts/metrics-summary.sh` reads that JSONL and prints volume/latency/tokens-avoided rollups; both scripts are idempotent and read-only with respect to the rest of the system. Layer 2 of the training-loop initiative added `--recipe NAME [--var key=value ...]` flags: when set, the wrapper loads `prompts/<NAME>.md`, awk-extracts the first fenced block under `## Prompt template`, substitutes each `{{key}}` placeholder from `--var` (and `{{stdin}}` from piped context), then refuses to send a partly-substituted template to the model — unsubstituted placeholders exit 2 with the missing keys named. The metrics line gains a `recipe` field when the flag is used; `DELEGATE_PROMPTS_DIR` env var overrides the recipe directory for tests.

The validation pipeline is the gate every PR has to clear. Three scripts plus the unit suite, all wired into `.github/workflows/ci.yml` and runnable locally. `scripts/validate-frontmatter.sh` asserts SKILL.md has the required frontmatter fields, `name` matches the directory and the Claude Skills regex, and `description` ≤ 4096 chars. `scripts/validate-skill-content.sh` scans for eight categories of dangerous content (SEC_DISABLE, SEC_PERMISSIVE, CRED_EXFIL, OBFUSC_B64, OBFUSC_UNICODE, TOOL_BROAD, CONFLICT_MARKER, URL_EXTERNAL) using a bash-3-compatible newline-delimited allowlist (associative arrays unavailable on macOS) and `perl -CSD` for the unicode regex. Justified false positives go in `.content-check-allow` keyed by either repo-relative path-and-line or sha256 of the offending line. `scripts/eval-skill-triggers.sh` validates `evals/eval-set.json` shape by default; with `--ollama [model]` it sends the full eval set as one batched call to a local Ollama model (free) using only the SKILL.md frontmatter description as the trigger surface, scoring recall and negative-precision against the thresholds inside the eval set. With `--github-models [model]` the same batched flow runs against the GitHub Models API (free up to per-model rate-limit tier, default `openai/gpt-4o-mini`) using the auto-provisioned `GITHUB_TOKEN`; this is what runs in CI on every PR. Batching collapses ~23 requests/run into 1 so a normal day of CI iteration stays under the GitHub Models 150 RPD free-tier quota (issue #62) — the per-query mode that preceded it exhausted the bucket after ~6 PR runs. Batching is more discriminating than per-query scoring on paraphrase-edge positives, so model choice matters more: `qwen3.6:35b-a3b-q8_0`, `deepseek-r1:32b`, and `qwen3-coder:30b-a3b-q8_0` all hit 1.000 / 1.000 on the current eval set in batched mode, while `qwen3-coder-next:latest` (the current `pick-model.sh code` default) drops to 0.800 recall on two paraphrase positives — pass `--ollama qwen3.6:35b-a3b-q8_0` (or any of the others) explicitly when running the local pre-merge gate. With `--api` and `ANTHROPIC_API_KEY` set, the same flow runs against Claude — kept for the rare case Claude-grade scoring is wanted. The eval-set is the seed for catching trigger drift: 10 positive queries (tagged exact / paraphrase) and 13 negative queries (adjacent / unrelated). When you change preference order in `pick-model.sh`, expect tests in `tests/run-tests.sh` to need updating; when you change SKILL.md frontmatter, run `--ollama` mode locally before merge — the local hook in `.claude/hooks/post-edit-validate.sh` runs the shape-mode and content checks automatically on save but does not run the trigger-accuracy gate.

`tests/run-tests.sh` (50 assertions) covers `pick-model.sh`, `init.sh`, and `audit-models.sh`. Each validator and wrapper has its own test file (`test-validate-frontmatter.sh` 10, `test-validate-content.sh` 20, `test-delegate.sh` 52, `test-metrics-summary.sh` 34, `test-score-t3.sh` 23, `test-runner.sh` 8, `test-eval-skill-triggers.sh` 62, `test-run-api-cell.sh` 16, `test-apply-and-test.sh` 44, `test-delegate-feedback.sh` 41, `test-prompts-library.sh` 67) using `tests/fixtures/` for both shape variants of SKILL.md and category-specific dangerous-content samples. Total 427 assertions run on every PR.

`prompts/` is the calibrated-recipe library introduced 2026-05-09 as layer 1 of the training-loop initiative (see ROADMAP). Each `prompts/<task>.md` ships the proven prompt skeleton + verbatim-example anchoring discipline + explicit anti-hallucination guards drawn from real session HITs. SKILL.md "Recipes" section points the agent at the directory; `tests/test-prompts-library.sh` enforces structural validity (required sections, README cross-reference, SKILL.md pointer) so a recipe can't drift into a broken template. Adding a new recipe is described in `prompts/README.md`: every recurring HIT graduates to a recipe entry, every MISS that names a missing recipe gets one filed.

`scripts/apply-and-test.sh <source-dir> <patch-file>` is the director-side test-runner helper that operationalises the apply-and-test loop the v8 + adversarial scorers (`experiments/sessions/2026-05-04-*/scorer*.py`) all open-coded. It parses `<<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE` blocks via perl (BSD awk rejects literal newlines in -v variables), applies them sequentially with literal-substring matching, runs pytest against the patched copy in an isolated tempdir, and emits a machine-parseable `VERDICT: PASS|FAIL|PARSE|APPLY|TIMEOUT|REFUSE` plus a `DETAIL:` context line. Exit codes encode the same six outcomes (0/1/2/3/4/5) so callers can branch without parsing stdout. Edge cases ported from the python scorers: empty SEARCH → APPLY, SEARCH not in source → APPLY, SEARCH matches more than once → APPLY (ambiguous prompts a unique-context fix in build-prompt.sh, never silent first-match), pytest timeout → TIMEOUT (uses coreutils `timeout` when available, falls back to no-timeout on BSD baseline), no blocks at all → PARSE, no blocks but `REFUSE:` line present → REFUSE. The interpreter is `python3` from PATH by default, override via `APPLY_AND_TEST_PYTHON=/path/to/venv/bin/python` to pin to a venv. Cross-validated against `scorer-v8.py`'s own self-test plus all 18 cells of the v8 run matrix on the reference host (`coder-next`/`deepseek-r1` × t1/t2/t3 × r1/r2/r3) — verdicts agree.

`experiments/runner.sh` runs the three fixture tasks (T1 doc-drift, T2 party-config, T3 merge-patterns) against a single Ollama model, with `--reps N` for repeating every task in the same file and `--t3-snapshot DATE` for selecting which dated T3 fixture to use. T1 and T2 fixtures are stable across baselines; T3 ships dated (`task-3-merge-patterns-2026-04-28.txt`) so future baselines snapshot their own input rather than overwriting the existing one. `experiments/run-baseline.sh` is the orchestrator: takes a model list, runs each sequentially with `ollama stop` and a 2-second pause between models so VRAM is released before the next cold load, and writes one raw file per model under `experiments/results/raw/`. `experiments/score-t3.sh` is the deterministic T3 scorer that replaces the human "real / plausible / hallucinated" rubric — it parses each rep's `CONCERN | PATTERN` lines, checks each `PATTERN` as a literal substring against the dated fixture, and reports per-rep, mean, stdev, min, max plus a machine-parseable `T3_SUMMARY:` line. The citation-against-fixture design keeps the score reproducible across machines and time without needing the live source repo to exist.

`scripts/audit-models.sh` is read-only by design and never pulls models. It cross-checks `llmfit recommend --json` output against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. The `hf_stem` function strips provider prefix and quant/variant suffixes (`-instruct`, `-fp8`, `-q4_K_M`, etc.) so that `Qwen/Qwen3.6-35B-A3B-Instruct-Q8_0` matches an installed `qwen3.6:35b-a3b-q8_0`. Suggestions are filtered to first-party providers (Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu) because third-party fine-tunes rarely appear on the Ollama library under the same name. The 3-point delta threshold for surfacing an upgrade is intentional — anything smaller is noise from llmfit's scoring.

`tests/run-tests.sh` builds an isolated PATH containing only `/usr/bin:/bin:/usr/sbin:/sbin` plus a temp dir holding mock `ollama` and `llmfit` binaries, then asserts specific tier outputs. The prose-tier ordering test (qwen3.6 ahead of qwen3-next) is intentional and encodes the empirical Phase 7 baseline finding — don't relax it without re-running the baseline.

`mcp/` is the optional Python MCP server from Phase 5 of the roadmap. It exposes five read-only tools — `pick_model(tier, dry_run)`, `audit_models()`, `list_tiers()`, `list_related_projects()`, and `recommend_prompt(task, include_examples, max_examples)` — each a thin wrapper around the bash scripts in `scripts/` or the markdown files in `prompts/`. The single source of truth for tier names stays in `pick-model.sh`'s `TIERS="..."` line; `list_tiers` parses that line rather than hardcoding the list. `recommend_prompt` (Layer 3 of the training-loop initiative) token-matches a task description against the recipe stems in `prompts/` (with British/US-spelling aliases like `summarize` → `summarise`), parses the matched recipe's H2 sections to surface its prompt template, variables, recommended tier, and copy-pasteable invocation, then joins the metrics JSONL (delegate rows tagged with `recipe`) against the feedback rows keyed by `ref_ts` to attach `hit_count`, `miss_count`, and the most recent local HITs with their feedback `reason` — turning the hit/miss log from a passive scoreboard into active routing signal for non-Claude MCP clients (Codex, OpenCode, Cursor). The Claude Code skill itself doesn't need this server — it exists for those other MCP-aware tools. Install is `cd mcp && pip install -e ".[dev]"`; tests are `pytest -q` from the same directory (38 cases) and run independently of the bash test suite. `DELEGATE_TO_OLLAMA_SCRIPTS` overrides the scripts directory; `DELEGATE_PROMPTS_DIR` overrides the recipe directory (same convention as `delegate.sh`); `DELEGATE_METRICS_FILE` overrides the metrics JSONL location (same convention as `delegate.sh` and `delegate-feedback.sh`). ADR `docs/adr/0004-optional-mcp-server.md` documents why Python over bash/TypeScript and why the wrapper-not-reimplementation rule is load-bearing.

`experiments/` is the empirical accuracy framework called out in Phase 7 of the roadmap. The three fixtures (`task-1-doc-drift`, `task-2-party-config`, `task-3-merge-patterns`) are intentionally chosen — T1 and T2 are closed-form prompts with single ground-truth answers; T3 is the open-ended hallucination probe. The first baseline (`results/2026-04-28-baseline.md`) found that the largest installed model (80B) was the worst performer on T2 and T3, which is why the design notes and SKILL.md emphasise "smallest model sufficient." When `pick-model.sh` preferences change materially, re-run the baseline to keep tier ordering empirical rather than llmfit-predicted.

## Conventions

`SKILL.md` frontmatter `description` field is load-bearing — it is the prompt Claude reads to decide whether to invoke this skill. The Phase 2 trigger evals (`scripts/eval-skill-triggers.sh` against `evals/eval-set.json`) gate changes to this field. The recommended pre-merge gate is `--ollama` mode (free, runs locally in 10–30 s, dogfoods the project's own routing); `--api` mode against Claude stays opt-in via the `ANTHROPIC_API_KEY` repo secret. Run the gate before merging any frontmatter `description` edit and confirm recall ≥ 0.9 and negative-precision ≥ 0.9. Keep the MUST/MUST NOT structure intact when editing.

When reasoning about whether work belongs in this skill, the discriminator is the local-brain insight: local models are strong summarisers and weak agents. If a task needs multi-step reasoning, repo-wide context, or tool-calling, it does not belong here even if the surface looks textual. The "out of scope" section of `ROADMAP.md` enumerates the boundaries; honour them when adding capabilities.

`ROADMAP.md` is the authoritative project plan and is structured by phase (1 shipped through 7 empirical benchmarking). Consult it before starting non-trivial work — phases 2 and 3 in particular have ordering dependencies (CI before plugin packaging).

## Repo Butler

This repo is monitored by [Repo Butler](https://github.com/IsmaelMartinez/repo-butler), a portfolio health agent that observes repo health daily and generates dashboards, governance proposals, and tier classifications.

**Your report:** https://ismaelmartinez.github.io/repo-butler/delegate-to-ollama.html
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
