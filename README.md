# delegate-to-ollama

A Claude Code skill that routes summarisation, triage, and bulk-text tasks to locally-installed Ollama models instead of the Anthropic API. Saves tokens, keeps content on-device, and uses `llmfit` to keep the model set current.

## What it does

Claude reads the skill description and, when a user asks for something that fits the "gather context once, send one prompt, return text" pattern (log triage, commit-message drafting, batch classification, structured field extraction, prose rewriting, format conversion, regex generation, docstring stubbing), it shells out to `ollama run <model>` instead of handling it itself. Reasoning, tool-calling, and repo-wide tasks still go to Claude.

By default the skill auto-delegates without asking. Saying "delegate where it fits" or "auto-delegate" once in a conversation locks in that behaviour for every subsequent matching task.

Core pattern (from [local-brain](https://github.com/IsmaelMartinez/local-brain)):

```bash
MODEL=$(bash ~/.claude/skills/delegate-to-ollama/scripts/pick-model.sh prose)
git diff HEAD~5 | ollama run "$MODEL" "Summarise in 3 bullets."
```

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
- `scripts/delegate.sh <tier> "<prompt>"` — wraps `pick-model.sh` + `ollama run`, strips spinner ANSI from output, and appends one JSON line per invocation to `~/.claude/skills/delegate-to-ollama/metrics.jsonl`. Use this in place of bare `ollama run`.
- `scripts/pick-model.sh <tier>` — resolves `code|prose|reasoning|long-context` to the best installed Ollama model via substring preference lists. Edit this file (not the skill body) when your installed set changes.
- `scripts/audit-models.sh` — prints installed models, tier routing, and llmfit-driven upgrade suggestions filtered to first-party providers. Read-only; never pulls.
- `scripts/metrics-summary.sh` — reads the metrics JSONL and prints volume per tier, p50/p95 latency, total tokens-avoided, and top models by frequency. Read-only.
- `tests/` — unit tests for every script. Run with `bash tests/run-tests.sh` (and the per-script `bash tests/test-*.sh`).
- `mcp/` — optional Python MCP server that exposes `pick_model`, `audit_models`, and `list_tiers` to non-Claude tools (Codex, OpenCode, Cursor, custom MCP clients). Thin wrapper over the bash scripts, not a reimplementation. See [`mcp/README.md`](mcp/README.md) for install and config snippets.

## Validation

Three scripts gate every PR via GitHub Actions:

- `scripts/validate-frontmatter.sh SKILL.md` — asserts the SKILL.md frontmatter has required fields, the `name` matches the directory, and `name` matches the Claude Skills regex.
- `scripts/validate-skill-content.sh SKILL.md` — scans for seven categories of dangerous content (auth-disable, permissive flags, credential exfiltration, base64 obfuscation, zero-width / bidi unicode, broad tool grants, external URLs). Justified false positives go in `.content-check-allow`.
- `scripts/eval-skill-triggers.sh` — validates `evals/eval-set.json` shape by default; with `--api` and `ANTHROPIC_API_KEY` set, runs each tagged query through Claude using only the SKILL.md frontmatter description as the trigger surface and asserts recall + negative-precision thresholds.

To enable the API-mode trigger eval in CI, configure `ANTHROPIC_API_KEY` in repo secrets (Settings → Secrets and variables → Actions). Without the secret the API step is skipped, not failed.

## Design notes

The skill intentionally avoids frameworks. Local models are good summarisers and weak agents; delegation is a shell pipe, not an orchestration layer. The `pick-model.sh` preference lists are the single point of truth for routing — no hardcoded model names in the skill body.

`audit-models.sh` cross-checks llmfit's `installed` flag against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. It filters suggestions to Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu so third-party fine-tunes that Ollama won't have under the same name don't pollute the output.

## Related projects

This skill sits at the intersection of three personal projects, and is observed by a fourth.

[`local-brain`](https://github.com/IsmaelMartinez/local-brain) is the source of the framing this skill operationalises. The core finding — local models are strong summarisers and weak agents, so delegation is `context | ollama run model` rather than an orchestration layer — comes directly from that work, and is why this skill is two bash scripts instead of a framework.

[`ai-model-advisor`](https://github.com/IsmaelMartinez/ai-model-advisor) supplies the tier classification (`code` / `prose` / `reasoning` / `long-context`) and the "smallest model sufficient" environmental philosophy that `pick-model.sh` encodes. When you change the preference order in that script, the rationale you are applying is the one ai-model-advisor argues for: bigger is not better when a 9GB model handles the prompt in half the time.

[`llmfit`](https://github.com/IsmaelMartinez/llmfit) is an optional dependency that enables hardware-aware upgrade suggestions in `audit-models.sh`. When llmfit is not on PATH the audit prints routing only and skips the upgrade-check section with a hint. When it is present, the audit feeds llmfit's hardware-scored recommendations through a first-party-provider filter and surfaces upgrades that beat the installed leader by 3+ points. Patterns the audit script learns about Ollama-vs-HuggingFace name mappings (`hf_stem` normalisation) flow back to llmfit when worth generalising.

[`repo-butler`](https://github.com/IsmaelMartinez/repo-butler) tracks repo health across the portfolio. No integration work is needed here — repo-butler picks up new repos automatically once they exist on GitHub, and this one is now visible to it.

## License

MIT — reuse freely.
