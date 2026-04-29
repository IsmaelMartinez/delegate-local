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

Resolve a tier to a model name (used by Claude when delegating, also useful for one-off shell pipes):

```bash
bash scripts/pick-model.sh <code|prose|reasoning|long-context>
```

Run the empirical accuracy fixtures against a specific installed model and append timing + raw output to `experiments/results/raw/<slug>.txt`:

```bash
bash experiments/runner.sh <ollama-model-name>
```

There is no build step, no linter, no package manager. Everything is plain bash plus `jq`.

## Architecture

`scripts/pick-model.sh` is the single source of truth for tier-to-model routing. Each tier (`code`, `prose`, `reasoning`, `long-context`) holds a substring-matched preference list, highest capability first; the script returns the first installed model whose name contains a preference substring. When the installed model set changes, edit the `prefs` arrays in this script — never hardcode model names in `SKILL.md` or in shell pipes that delegate work.

`scripts/audit-models.sh` is read-only by design and never pulls models. It cross-checks `llmfit recommend --json` output against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. The `hf_stem` function strips provider prefix and quant/variant suffixes (`-instruct`, `-fp8`, `-q4_K_M`, etc.) so that `Qwen/Qwen3.6-35B-A3B-Instruct-Q8_0` matches an installed `qwen3.6:35b-a3b-q8_0`. Suggestions are filtered to first-party providers (Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu) because third-party fine-tunes rarely appear on the Ollama library under the same name. The 3-point delta threshold for surfacing an upgrade is intentional — anything smaller is noise from llmfit's scoring.

`tests/run-tests.sh` builds an isolated PATH containing only `/usr/bin:/bin:/usr/sbin:/sbin` plus a temp dir holding mock `ollama` and `llmfit` binaries, then asserts specific tier outputs. When you change preference order in `pick-model.sh`, expect tests 5–9 to need updating; they encode current routing decisions, not just sanity checks.

`experiments/` is the empirical accuracy framework called out in Phase 7 of the roadmap. The three fixtures (`task-1-doc-drift`, `task-2-party-config`, `task-3-merge-patterns`) are intentionally chosen — T1 and T2 are closed-form prompts with single ground-truth answers; T3 is the open-ended hallucination probe. The first baseline (`results/2026-04-28-baseline.md`) found that the largest installed model (80B) was the worst performer on T2 and T3, which is why the design notes and SKILL.md emphasise "smallest model sufficient." When `pick-model.sh` preferences change materially, re-run the baseline to keep tier ordering empirical rather than llmfit-predicted.

## Conventions

`SKILL.md` frontmatter `description` field is load-bearing — it is the prompt Claude reads to decide whether to invoke this skill. Trigger evals (planned for Phase 2, see `ROADMAP.md`) gate changes to this field. Keep the MUST/MUST NOT structure intact when editing.

When reasoning about whether work belongs in this skill, the discriminator is the local-brain insight: local models are strong summarisers and weak agents. If a task needs multi-step reasoning, repo-wide context, or tool-calling, it does not belong here even if the surface looks textual. The "out of scope" section of `ROADMAP.md` enumerates the boundaries; honour them when adding capabilities.

`ROADMAP.md` is the authoritative project plan and is structured by phase (1 shipped through 7 empirical benchmarking). Consult it before starting non-trivial work — phases 2 and 3 in particular have ordering dependencies (CI before plugin packaging).
