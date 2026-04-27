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

## Requirements

- [Ollama](https://ollama.com) with at least one model pulled
- `jq` (for `audit-models.sh`)
- `llmfit` (optional, enables upgrade suggestions based on your hardware)

## Install

Copy the directory into your Claude skills folder:

```bash
git clone <this-repo> delegate-to-ollama
cp -r delegate-to-ollama ~/.claude/skills/
```

Claude Code picks it up on the next session. Run the audit once to confirm routing:

```bash
bash ~/.claude/skills/delegate-to-ollama/scripts/audit-models.sh
```

## Files

- `SKILL.md` — triggering description and usage patterns Claude reads.
- `scripts/pick-model.sh <tier>` — resolves `code|prose|reasoning|long-context` to the best installed Ollama model via substring preference lists. Edit this file (not the skill body) when your installed set changes.
- `scripts/audit-models.sh` — prints installed models, tier routing, and llmfit-driven upgrade suggestions filtered to first-party providers. Read-only; never pulls.
- `tests/run-tests.sh` — unit tests for the two scripts. Run with `bash tests/run-tests.sh`.

## Design notes

The skill intentionally avoids frameworks. Local models are good summarisers and weak agents; delegation is a shell pipe, not an orchestration layer. The `pick-model.sh` preference lists are the single point of truth for routing — no hardcoded model names in the skill body.

`audit-models.sh` cross-checks llmfit's `installed` flag against `ollama list` because llmfit tracks its own HuggingFace GGUF cache rather than Ollama's model store. It filters suggestions to Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu so third-party fine-tunes that Ollama won't have under the same name don't pollute the output.

## License

MIT — reuse freely.
