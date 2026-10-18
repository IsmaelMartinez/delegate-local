# delegate-local

An agent skill that reads large text inputs on this machine instead of in the agent's context: a long log, thread, document, directory or item list is piped to a locally-installed model (MLX, Docker Model Runner or Ollama), in chunks, and the agent gets back a short answer anchored to the input that it spot-checks.

> **Status: wound down (October 2026).** This started as a skill that delegated every kind of text work, commit messages and review replies included, to a local model. Measured over 2,159 delegations, that cost Claude more output tokens than it saved and added about 20 seconds per call, so [ADR 0035](docs/adr/0035-narrow-to-large-piped-inputs-and-wind-down.md) narrowed it to the one shape that paid: large inputs Claude never reads. [What delegate-local taught](docs/learnings.md) keeps the lessons. Everything removed is recoverable from commit `a00b2e9`.

## Quickstart

```bash
# 1. Install the skill (SKILL.md + scripts/ + prompts/) into Claude Code, user-scoped
npx skills add IsmaelMartinez/delegate-local -a claude-code -g

# 2. Confirm a local model is served and see how tiers route
bash ~/.claude/skills/delegate-local/scripts/audit-models.sh

# 3. Read a large input locally
grep -nE 'ERROR|FAIL' build.log | bash ~/.claude/skills/delegate-local/scripts/delegate.sh reasoning \
  "Group these lines by root cause. One line per cause, with the line numbers it covers."
```

Step 2 needs an OpenAI-compatible model server running locally (see [Providers](#providers)). After install the agent delegates matching tasks itself; the raw call in step 3 only confirms the backend works.

## What it does

When the input is too large to be worth reading in full and the answer is a summary, the matching lines, extracted fields or a label per item, the agent pipes the input to `delegate.sh` in chunks of about 30k characters, asks a closed question with anchors (line numbers, quoted lines, item ids), spot-checks a sample of anchors with `grep`, and combines the answers. It does not draft anything the agent will publish, and it does not reason, plan or call tools. `SKILL.md` is the contract the agent follows.

Three recipes fit the shape: `summarise-issue` (a status timeline of a long thread or CI log), `bulk-classify` (one label per item from a fixed set) and `file-summary` (one sentence per document). Bare tier calls cover the rest:

```bash
gh issue view 142 --comments | bash scripts/delegate.sh --recipe summarise-issue --var kind=issue --var N_FACTS=5
```

When the content may leave the machine, a subagent on a small cloud model is an equally good way to keep a large input out of the agent's context. This skill is for the cases where it must stay on the device.

## Requirements

- An OpenAI-compatible model server running locally: [`mlx-lm`](https://github.com/ml-explore/mlx-lm) on Apple Silicon, Docker Model Runner, or [Ollama](https://ollama.com).
- `bash` 3.2+, `jq`, `awk`, `perl` and `curl`.

## Providers

Every call goes to `POST {base}/chat/completions`. `DELEGATE_BASE_URL` is an ordered list of base URLs, and the first provider that is reachable and serves a model the tier prefers takes the call:

```
${MLX_HOST:-http://localhost:8080}/v1
${DOCKER_MODEL_HOST:-http://localhost:12434}/engines/v1
${OLLAMA_HOST:-http://localhost:11434}/v1
```

MLX leads because [ADR 0022](docs/adr/0022-mlx-primary-backend-rationale.md) measured it about ten times faster than Ollama on identical weights. Install and launchd auto-start for MLX are in [docs/install-mlx.md](docs/install-mlx.md). Keep one model resident: `mlx_lm.server` loads any cached model a request names, and alternating two costs a reload each time. Cap its prompt cache with `--prompt-cache-bytes`.

## Install

`npx skills add IsmaelMartinez/delegate-local` installs the whole skill directory into every detected agent tool; `-g` installs user-scoped and `-a claude-code` limits it to one tool. The per-tool guides are [Claude Code](docs/install-claude-code.md), [Codex](docs/install-codex.md) and [OpenCode](docs/install-opencode.md). The skill follows the [Agent Skills standard](https://agentskills.io/specification), so cloning the repo into a tool's skills directory also works.

### Overriding routing

`pick-model.sh` holds one preference list per tier. To put a different model first on one machine, write `~/.local/share/delegate-local/config.sh`; `pick-model.sh` sources it after the shipped lists:

```bash
# ~/.local/share/delegate-local/config.sh
case "$tier" in
  prose|reasoning|long-context) prefs=(gemma-4-26b "${prefs[@]}") ;;
esac
```

`config.sh` is sourced as bash, so only place one you wrote yourself (see [SECURITY.md](SECURITY.md)). `DELEGATE_LOCAL_CONFIG` redirects the path.

## Where per-user data lives

```
~/.local/share/delegate-local/
  metrics.jsonl   one JSON line per call
  drafts/         each call's output, and on recipe calls its rendered input
  config.sh       routing override
```

`DELEGATE_LOCAL_DATA_DIR` moves the directory and `DELEGATE_METRICS_FILE` the metrics file; `DELEGATE_LOCAL_NO_METRICS=1` opts a call out.

## Files

- `SKILL.md`: the triggering description and the pattern the agent follows.
- `scripts/delegate.sh <tier> "<prompt>"` (or `--recipe NAME`): resolves the tier, posts to the provider with `temperature:0` and thinking off, runs a recipe's canary and output checks, prints the answer on stdout and a `delegate-meta:` line on stderr, and appends a metrics row.
- `scripts/pick-model.sh <tier>`: resolves a tier to the first served model in its preference list. The single place model names live.
- `scripts/audit-models.sh`: prints providers, served models and tier routing. Read-only.
- `scripts/metrics-summary.sh [--days N | --since YYYY-MM-DD]`: volume, latency and per-recipe counts from the metrics file. Its "tokens avoided" figure is what stayed local, not what Claude saved (ADR 0035).
- `scripts/lib/gpu-gate.sh`: the heat gate batch callers can source between calls.
- `scripts/eval-skill-triggers.sh`, `scripts/validate-frontmatter.sh`, `scripts/validate-skill-content.sh`: the gates for `SKILL.md`.
- Dormant and kept only as history until the repository is archived: `delegate-feedback.sh` (optional verdicts), `verify-draft.sh` and `decide.sh`, `embed.sh` and `semantic-search.sh`, and the OpenTelemetry and Loki tooling (`docs/observability/`).
- [`docs/env.md`](docs/env.md) lists every `DELEGATE_*` variable.

## Troubleshooting

Exit 1 (`pick-model failed for tier`) means no served model matches the tier's list: `bash scripts/audit-models.sh` says whether no provider is reachable or none serves a matching model. Exit 2 is a usage error, including a recipe placeholder left unfilled. Exit 3 (`pre-flight canary`) on a recipe call means the model did not answer a 1-token probe in time, usually a cold load: rerun with `DELEGATE_PREFLIGHT_TIMEOUT=90`. Empty output from an MLX model points at a hand-rolled `curl` hitting the raw completions endpoint instead of chat completions.

## Validation

CI runs `validate-frontmatter.sh` and `validate-skill-content.sh` on `SKILL.md`, the eval-set shape check, ShellCheck at `-S error` and every `tests/test-*.sh`. The trigger-accuracy gate for a description change is `bash scripts/eval-skill-triggers.sh --decide` (on-device) or `--api` with `ANTHROPIC_API_KEY` set; `evals/eval-set.json` holds the trigger and no-trigger queries and the 0.9 recall and negative-precision thresholds.

## What you actually save

Less than the metrics suggest. The "tokens avoided" headline counts every character the local model processed. Measured against transcripts (ADR 0035), drafting text Claude will publish saved nothing: Claude has to put the substance into the brief, reads the draft back, usually edits it, and its output tokens cost five times its fresh input. The saving is real only when a large input goes to the local model without Claude reading it, and the benefit then is that the content stays on the machine and out of the context window. On a subscription plan the direct cost saving is zero either way.

## Design notes

No framework: local models are good summarisers and weak agents, so delegation is a shell pipe ([local-brain](https://github.com/IsmaelMartinez/local-brain)'s finding, ADR 0001). The preference lists in `pick-model.sh` are the single source of truth for routing. [`ai-model-advisor`](https://github.com/IsmaelMartinez/ai-model-advisor) supplied the tier names and the "smallest model sufficient" rule.

## License

MIT.
