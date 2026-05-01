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
bash scripts/pick-model.sh <code|prose|reasoning|long-context>
```

Wrap a delegation through the metrics-capturing wrapper (preferred over bare `ollama run`):

```bash
echo "<context>" | bash scripts/delegate.sh prose "<prompt>"
```

Read the metrics roll-up:

```bash
bash scripts/metrics-summary.sh
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
```

Run the trigger eval against the live Anthropic API (requires `ANTHROPIC_API_KEY`; gates whether a frontmatter `description` edit keeps recall ≥ 0.9 and negative-precision ≥ 0.9):

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

There is no build step, no linter, no package manager. Runtime deps are `bash` (3.2+ — macOS-shipped is fine), `jq`, and `perl` (used in one validator because BSD grep on macOS lacks `-P`). `curl` is required only for `--api` mode of the trigger eval. Cross-platform portability is a real constraint: avoid associative arrays (bash 4-only), avoid `grep -P` (GNU-only), and prefer `perl -CSD` for unicode-aware regex.

Install for end users is `npx skills add IsmaelMartinez/delegate-to-ollama` (Vercel Labs' multi-agent CLI symlinks it into Claude Code, Codex, OpenCode, Cursor, Copilot, etc.) — see `README.md` for the manual `cp -r` fallback.

## Architecture

`scripts/pick-model.sh` is the single source of truth for tier-to-model routing. Each tier (`code`, `prose`, `reasoning`, `long-context`) holds a substring-matched preference list, highest capability first; the script returns the first installed model whose name contains a preference substring. When the installed model set changes, edit the `prefs` arrays in this script — never hardcode model names in `SKILL.md` or in shell pipes that delegate work.

`scripts/delegate.sh` is the wrapper `SKILL.md` teaches Claude to invoke. It calls `pick-model.sh`, runs `ollama run`, strips spinner ANSI bytes from the captured output (so the response is clean for downstream parsers), and appends one JSON line per invocation to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Set `DELEGATE_TO_OLLAMA_NO_METRICS=1` to opt out for a single call. The metrics file is intentionally outside the repo so it survives `git clean -fdx` and isn't committed by accident. `scripts/metrics-summary.sh` reads that JSONL and prints volume/latency/tokens-avoided rollups; both scripts are idempotent and read-only with respect to the rest of the system.

The validation pipeline is the gate every PR has to clear. Three scripts plus the unit suite, all wired into `.github/workflows/ci.yml` and runnable locally. `scripts/validate-frontmatter.sh` asserts SKILL.md has the required frontmatter fields, `name` matches the directory and the Claude Skills regex, and `description` ≤ 4096 chars. `scripts/validate-skill-content.sh` scans for seven categories of dangerous content (SEC_DISABLE, SEC_PERMISSIVE, CRED_EXFIL, OBFUSC_B64, OBFUSC_UNICODE, TOOL_BROAD, URL_EXTERNAL) using a bash-3-compatible newline-delimited allowlist (associative arrays unavailable on macOS) and `perl -CSD` for the unicode regex. Justified false positives go in `.content-check-allow` keyed by either repo-relative path-and-line or sha256 of the offending line. `scripts/eval-skill-triggers.sh` validates `evals/eval-set.json` shape by default; with `--api` it sends each query through Claude using only the SKILL.md frontmatter description as the trigger surface, scoring recall and negative-precision against the thresholds inside the eval set. The eval-set is the seed for catching trigger drift: 10 positive queries (tagged exact / paraphrase) and 13 negative queries (adjacent / unrelated). When you change preference order in `pick-model.sh`, expect tests in `tests/run-tests.sh` to need updating; when you change SKILL.md frontmatter, the API-mode trigger eval is what tells you whether recall held — the local hook in `.claude/hooks/post-edit-validate.sh` runs the shape-mode and content checks automatically on save but cannot run the API mode (no key in scope).

`tests/run-tests.sh` (32 assertions) covers `pick-model.sh` and `audit-models.sh`. Each validator and wrapper has its own test file (`test-validate-frontmatter.sh` 10, `test-validate-content.sh` 18, `test-delegate.sh` 16, `test-metrics-summary.sh` 13, `test-score-t3.sh` 19, `test-runner.sh` 8) using `tests/fixtures/` for both shape variants of SKILL.md and category-specific dangerous-content samples. Total 116 assertions run on every PR.

`experiments/runner.sh` runs the three fixture tasks (T1 doc-drift, T2 party-config, T3 merge-patterns) against a single Ollama model, with `--reps N` for repeating every task in the same file and `--t3-snapshot DATE` for selecting which dated T3 fixture to use. T1 and T2 fixtures are stable across baselines; T3 ships dated (`task-3-merge-patterns-2026-04-28.txt`) so future baselines snapshot their own input rather than overwriting the existing one. `experiments/run-baseline.sh` is the orchestrator: takes a model list, runs each sequentially with `ollama stop` and a 2-second pause between models so VRAM is released before the next cold load, and writes one raw file per model under `experiments/results/raw/`. `experiments/score-t3.sh` is the deterministic T3 scorer that replaces the human "real / plausible / hallucinated" rubric — it parses each rep's `CONCERN | PATTERN` lines, checks each `PATTERN` as a literal substring against the dated fixture, and reports per-rep, mean, stdev, min, max plus a machine-parseable `T3_SUMMARY:` line. The citation-against-fixture design keeps the score reproducible across machines and time without needing the live source repo to exist.

`scripts/audit-models.sh` is read-only by design and never pulls models. It cross-checks `llmfit recommend --json` output against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. The `hf_stem` function strips provider prefix and quant/variant suffixes (`-instruct`, `-fp8`, `-q4_K_M`, etc.) so that `Qwen/Qwen3.6-35B-A3B-Instruct-Q8_0` matches an installed `qwen3.6:35b-a3b-q8_0`. Suggestions are filtered to first-party providers (Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu) because third-party fine-tunes rarely appear on the Ollama library under the same name. The 3-point delta threshold for surfacing an upgrade is intentional — anything smaller is noise from llmfit's scoring.

`tests/run-tests.sh` builds an isolated PATH containing only `/usr/bin:/bin:/usr/sbin:/sbin` plus a temp dir holding mock `ollama` and `llmfit` binaries, then asserts specific tier outputs. The prose-tier ordering test (qwen3.6 ahead of qwen3-next) is intentional and encodes the empirical Phase 7 baseline finding — don't relax it without re-running the baseline.

`experiments/` is the empirical accuracy framework called out in Phase 7 of the roadmap. The three fixtures (`task-1-doc-drift`, `task-2-party-config`, `task-3-merge-patterns`) are intentionally chosen — T1 and T2 are closed-form prompts with single ground-truth answers; T3 is the open-ended hallucination probe. The first baseline (`results/2026-04-28-baseline.md`) found that the largest installed model (80B) was the worst performer on T2 and T3, which is why the design notes and SKILL.md emphasise "smallest model sufficient." When `pick-model.sh` preferences change materially, re-run the baseline to keep tier ordering empirical rather than llmfit-predicted.

## Conventions

`SKILL.md` frontmatter `description` field is load-bearing — it is the prompt Claude reads to decide whether to invoke this skill. The Phase 2 trigger evals (`scripts/eval-skill-triggers.sh --api` against `evals/eval-set.json`) gate changes to this field; in CI the step is gated on the `ANTHROPIC_API_KEY` repo secret. Run the API-mode eval before merging any frontmatter `description` edit and confirm recall ≥ 0.9 and negative-precision ≥ 0.9. Keep the MUST/MUST NOT structure intact when editing.

When reasoning about whether work belongs in this skill, the discriminator is the local-brain insight: local models are strong summarisers and weak agents. If a task needs multi-step reasoning, repo-wide context, or tool-calling, it does not belong here even if the surface looks textual. The "out of scope" section of `ROADMAP.md` enumerates the boundaries; honour them when adding capabilities.

`ROADMAP.md` is the authoritative project plan and is structured by phase (1 shipped through 7 empirical benchmarking). Consult it before starting non-trivial work — phases 2 and 3 in particular have ordering dependencies (CI before plugin packaging).
