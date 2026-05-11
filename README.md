# delegate-to-ollama

A Claude Code skill that routes summarisation, triage, and bulk-text tasks to locally-installed Ollama models instead of the Anthropic API. Saves tokens, keeps content on-device, and uses `llmfit` to keep the model set current.

## What it does

Claude reads the skill description and, when a user asks for something that fits the "gather context once, send one prompt, return text" pattern (log triage, commit-message drafting, batch classification, structured field extraction, prose rewriting, format conversion, regex generation, docstring stubbing), it shells out to `ollama run <model>` instead of handling it itself. Reasoning, tool-calling, and repo-wide tasks still go to Claude.

By default the skill auto-delegates without asking. Saying "delegate where it fits" or "auto-delegate" once in a conversation locks in that behaviour for every subsequent matching task.

Core pattern (from [local-brain](https://github.com/IsmaelMartinez/local-brain)) — a delegated call resolves a tier (`prose` here; the full list is documented under [Files](#files) below) to the best installed local model, then pipes context into it:

```bash
MODEL=$(bash ~/.claude/skills/delegate-to-ollama/scripts/pick-model.sh prose)
git diff HEAD~5 | ollama run "$MODEL" "Summarise in 3 bullets."
```

The path shown is the default Claude Code skills location; `npx skills add` (recommended; see [Install](#install) below) symlinks the repo there for Claude Code, and at the equivalent default path for each other agent it detects. Other tools land at their own path — see the [Per-tool guides](#per-tool-guides).

### Capturing output non-interactively

When the response is being captured by another tool (a Bash wrapper, a CI step, an agent harness) rather than read in a terminal, `ollama run` interleaves spinner ANSI sequences (`\x1b[?25l` / `\x1b[?2026h` / `\x1b[K`) and partial-word stream-rewrites (`[9D[K`) into stdout. The actual response is fine; the noise just makes the captured bytes hard to parse.

Two reliable workarounds:

```bash
# Option 1: write to file, strip control codes on read
ollama run "$MODEL" "..." > /tmp/out.txt 2>/dev/null
sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' /tmp/out.txt

# Option 2: pipe-strip inline
ollama run "$MODEL" "..." 2>/dev/null \
  | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g'
```

Both keep the model output and drop the cursor-control bytes. `--hidethinking` does not currently affect the spinner — it only suppresses `<think>...</think>` blocks for reasoning models.

## Requirements

- [Ollama](https://ollama.com) with at least one model pulled
- `jq` (for `audit-models.sh`)
- `llmfit` (optional, enables upgrade suggestions based on your hardware)

## Install

### Universal (recommended)

Use [Vercel Labs' `skills` CLI](https://github.com/vercel-labs/skills), which symlinks the skill into every detected agent tool (Claude Code, Codex, OpenCode, Cursor, Copilot, and many others) so updates propagate everywhere at once:

```bash
npx skills add IsmaelMartinez/delegate-to-ollama
```

Pass `-g` to install globally (`~/<agent>/skills/`) instead of per-project, `--copy` to make independent copies on systems without symlink support, or `-a claude-code` to limit to a specific agent.

### Per-tool guides

When the universal install is the wrong fit (per-machine routing, MCP-only consumers, AAIF-only setups), the per-tool docs cover the specifics:

- [Claude Code](docs/install-claude-code.md)
- [Codex](docs/install-codex.md)
- [OpenCode](docs/install-opencode.md)

### Manual copy

The skill is conformant with the [Agent Skills standard](https://agentskills.io/specification) — `SKILL.md` at the directory root with `name` and `description` frontmatter — so any tool that reads that format can use it. The repo is also AAIF-discoverable directly: a symlink at `.agents/skills/delegate-to-ollama` points at the repo root, so tools that scan the AAIF layout (Cursor, Copilot, OpenCode) find the skill without per-tool copying. For tools that do not support AAIF discovery, drop the directory into the tool's expected skills path:

```bash
git clone https://github.com/IsmaelMartinez/delegate-to-ollama
cp -r delegate-to-ollama ~/.claude/skills/   # or your tool's skills dir
```

### Confirm routing

After install, run the audit from wherever the skill landed:

```bash
bash <install-path>/scripts/audit-models.sh
```

### Personalising routing (optional)

The shipped `pick-model.sh` is one preference list for everyone. To override the order on a specific machine without forking the repo, drop a bash file at `~/.claude/skills/delegate-to-ollama/config.sh`. `pick-model.sh` sources it after the shipped defaults are set, so any tier the file touches wins. Untouched tiers fall through to shipped defaults; an absent file changes nothing.

```bash
# ~/.claude/skills/delegate-to-ollama/config.sh
case "$tier" in
  prose) prefs=("gemma4" "qwen3.6" "qwen3-next") ;;
esac
```

`scripts/init.sh` writes a starter override based on what's currently installed — read-only, prints to stdout, never auto-writes:

```bash
bash <install-path>/scripts/init.sh > ~/.claude/skills/delegate-to-ollama/config.sh
```

Set `DELEGATE_TO_OLLAMA_CONFIG=/some/other/path.sh` to redirect the override path (useful for testing or per-project overrides).

## Files

- `SKILL.md` — triggering description and usage patterns Claude reads.
- `scripts/delegate.sh <tier> "<prompt>"` — wraps `pick-model.sh` + Ollama's `POST /api/generate` (with `think:false` and `temperature:0` defaults), and appends one JSON line per invocation to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Use this in place of bare `ollama run` or hand-rolled `curl` calls. Honours `OLLAMA_HOST` (default `http://localhost:11434`).
- `scripts/pick-model.sh <tier>` — resolves a tier to the best installed Ollama model via substring preference lists. Tiers are `code`, `prose`, `reasoning`, and `long-context` (active), plus `vision`, `embedding`, `premium-general`, and `reasoning-vision` (scaffolded — routing in place, resolution gated on the relevant model being installed). Edit this file (not the skill body) when your installed set changes.
- `scripts/audit-models.sh` — prints installed models, tier routing, and llmfit-driven upgrade suggestions filtered to first-party providers. Read-only; never pulls.
- `scripts/metrics-summary.sh` — reads the metrics JSONL and prints volume per tier, p50/p95 latency, total tokens-avoided, and top models by frequency. Read-only.
- `tests/` — unit tests for every script. Run with `bash tests/run-tests.sh` (and the per-script `bash tests/test-*.sh`).
- `mcp/` — optional Python MCP server that exposes `pick_model`, `audit_models`, and `list_tiers` to non-Claude tools (Codex, OpenCode, Cursor, custom MCP clients). Thin wrapper over the bash scripts, not a reimplementation. See [`mcp/README.md`](mcp/README.md) for install and config snippets.

## Validation

Three scripts gate every PR via GitHub Actions:

- `scripts/validate-frontmatter.sh SKILL.md` — asserts the SKILL.md frontmatter has required fields, the `name` matches the directory, and `name` matches the Claude Skills regex.
- `scripts/validate-skill-content.sh SKILL.md` — scans for eight categories of dangerous content (auth-disable, permissive flags, credential exfiltration, base64 obfuscation, zero-width / bidi unicode, broad tool grants, unresolved merge markers, external URLs). Justified false positives go in `.content-check-allow`.
- `scripts/eval-skill-triggers.sh` — validates `evals/eval-set.json` shape by default; with `--ollama [model]` runs each tagged query through a local Ollama model (free, on-device; defaults to `pick-model.sh code` which baselines at 1.000 / 1.000 against the current eval set on the reference host); with `--github-models [model]` runs against GitHub Models (free up to the per-model rate-limit tier; defaults to `openai/gpt-4o-mini` which baselines at 0.900 / 1.000); with `--api` and `ANTHROPIC_API_KEY` set, runs against Claude — kept for the rare case Claude-grade scoring is wanted. All three modes use only the SKILL.md frontmatter description as the trigger surface and assert recall + negative-precision thresholds.

The `--ollama` mode is the recommended local pre-merge gate (10–30 s on a mid-tier machine, dogfoods the project's own routing). The `--github-models` mode is the recommended CI gate — uses the auto-provisioned `GITHUB_TOKEN` so there is no secret to configure; the workflow declares `permissions: models: read` to grant scope. The `--api` mode is opt-in via the `ANTHROPIC_API_KEY` repo secret (Settings → Secrets and variables → Actions); without the secret the CI step is skipped, not failed.

## Calibration feedback loop

Recipes evolve from real session feedback. The loop is end-to-end on-device until you decide to share a finding:

```
delegate.sh run                metrics.jsonl                delegate-feedback.sh
  ↓                              (append-only,                miss "<reason>"
  appends one row                 gitignored)                   ↓
  per call                                                    appends one row
                                                              ↓
                                                              matches reason
                                                              against historical
                                                              MISS rows (Jaccard
                                                              over content tokens)
                                                                ↓
                                                              if N≥3 similars in
                                                              last 30d → nudge
                                                              prints draft gh
                                                              issue command
                                                                ↓
                                                          you decide whether to
                                                          file a prompt-pattern
                                                          issue → maintainer
                                                          graduates it into
                                                          prompts/<new>.md
```

The single-machine metrics JSONL has no scheduled job behind it; the nudge is the runtime signal. After the third similar MISS in the rolling window, `delegate-feedback.sh` prints the matched reasons and a draft `gh issue create` command pre-targeted at the `prompt-pattern` label. The nudge is advisory — it never opens the issue on its own — so each filing stays a deliberate call. Silence one invocation with `DELEGATE_FEEDBACK_NO_NUDGE=1`; tune the trigger via `DELEGATE_FEEDBACK_NUDGE_AT` (default 3), `DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS` (default 30), and `DELEGATE_FEEDBACK_SIMILAR_THRESHOLD` (default 0.4 Jaccard over stopword-stripped content tokens).

`scripts/audit-metrics.sh` is the on-demand counterpart to that runtime nudge — the same matcher applied many-vs-many across the whole JSONL instead of one-vs-many at MISS time. Run it for periodic review, or to scan a cross-machine JSONL the per-MISS nudge would never see (the JSONL is gitignored, so each host has its own). The script reads `DELEGATE_METRICS_FILE` and honours the same `DELEGATE_FEEDBACK_NUDGE_AT` / `_WINDOW_DAYS` / `_SIMILAR_THRESHOLD` envs, prints one draft `gh issue create` command per recurring bucket, and never writes to the JSONL itself.

A `prompt-pattern` issue captures the task shape, tier and resolved model, verbatim prompt and model output, and (when known) the prompt that turned the MISS into a HIT. `prompts/README.md` documents how the maintainer graduates an issue into a `prompts/<new>.md` recipe paired with an `evals/eval-set.json` positive — closing the loop empirically rather than evaporating after one conversation.

## What you actually save

Worth being explicit about this because the skill could easily be oversold.

The delegated call is where the savings live — the local model writes the summary, classification, or patch instead of Claude. That's real and measurable: the metrics rollup (`scripts/metrics-summary.sh`) reports a "tokens avoided" headline computed from real Ollama `prompt_eval_count` + `eval_count` counts. The 2026-05-04 v8 probe's "~250× cheaper than Opus" number is also real for the specific workload it measured — 18 minimal-patch code cells scored by pytest.

But a realistic delegation flow costs more Anthropic tokens than just "the delegated call minus zero." In a typical turn, Claude still spends tokens to:

- read the user's request and decide a local model fits,
- frame the delegation prompt,
- read the local model's response back,
- verify the response against the actual files (for correctness-critical work — see SKILL.md's Discipline subsection on running the test when delegating code, and the gather-delegate-verify pattern throughout).

For small tasks — a 3-bullet diff summary, a one-line commit message — the verification overhead can eat most of the headline saving. The shape where this skill actually pays off is bulk or repeated work: triage 50 TODOs, classify 40 findings against an allowlist, draft release notes from a 200-line changelog. There the per-item Anthropic cost is dominated by the delegated generation, which is the part that moves to local.

Rough annual estimates (char-count tokens, ~1.5 KTok per round-trip that would otherwise go to the API):

| Usage profile                         | Delegations/year | Haiku-equiv save | Sonnet-equiv save | Opus-equiv save |
|---------------------------------------|------------------|------------------|-------------------|-----------------|
| Subscription user (Claude Max/Pro)    | any              | $0 (marginal)    | $0                | $0              |
| Casual API user (~10/hour × 20 h/wk)  | ~10k             | $25–40           | $75–115           | $375–560        |
| Heavy/team (~500/day × every day)     | ~180k            | $450–700         | $1.4k–2k          | $6.8k–10k       |

The subscription row is the honest one for individual developers: inside a Claude Max or Pro plan the marginal API cost of a delegation is zero, so the direct-dollar saving is zero. The real benefit in that case is different: **context-window preservation** (those tokens don't bloat Claude's active context, so long conversations stay focused) and **privacy** (sensitive logs, configs, and credentials never leave the machine).

More capable local models will shift these numbers but probably not by an order of magnitude. "250× cheaper than Opus" is a headline for one measured shape, not a general claim.

## Design notes

The skill intentionally avoids frameworks. Local models are good summarisers and weak agents; delegation is a shell pipe, not an orchestration layer. The `pick-model.sh` preference lists are the single point of truth for routing — no hardcoded model names in the skill body.

`audit-models.sh` cross-checks llmfit's `installed` flag against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. It filters suggestions to Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu so third-party fine-tunes that Ollama won't have under the same name don't pollute the output.

## Related projects

This skill sits at the intersection of three personal projects, and is observed by a fourth.

[`local-brain`](https://github.com/IsmaelMartinez/local-brain) is the source of the framing this skill operationalises. The core finding — local models are strong summarisers and weak agents, so delegation is `context | ollama run model` rather than an orchestration layer — comes directly from that work, and is why this skill is two bash scripts instead of a framework.

[`ai-model-advisor`](https://github.com/IsmaelMartinez/ai-model-advisor) supplies the tier classification (`code` / `prose` / `reasoning` / `long-context`) and the "smallest model sufficient" environmental philosophy that `pick-model.sh` encodes. When you change the preference order in that script, the rationale you are applying is the one ai-model-advisor argues for: bigger is not better when a 9GB model handles the prompt in half the time.

[`llmfit`](https://github.com/IsmaelMartinez/llmfit) is an optional dependency that enables hardware-aware upgrade suggestions in `audit-models.sh`. When llmfit is not on PATH the audit prints routing only and skips the upgrade-check section with a hint. When it is present, the audit feeds llmfit's hardware-scored recommendations through a first-party-provider filter and surfaces upgrades that beat the installed leader by 3+ points. Patterns the audit script learns about Ollama-vs-HuggingFace name mappings (`hf_stem` normalisation) flow back to llmfit when worth generalising.

[`repo-butler`](https://github.com/IsmaelMartinez/repo-butler) tracks repo health across the portfolio. No integration work is needed here — repo-butler picks up new repos automatically once they exist on GitHub, and this one is now visible to it.

## Maintenance

A monthly reminder to re-run `scripts/audit-models.sh` is automated via [`.github/workflows/monthly-audit-reminder.yml`](.github/workflows/monthly-audit-reminder.yml). The workflow opens a tracking issue on the 1st of each month (idempotent — skips when one is already open) because the audit needs a local `ollama list` and can't run on the hosted runner; `workflow_dispatch` is the manual escape hatch.

## License

MIT — reuse freely.
