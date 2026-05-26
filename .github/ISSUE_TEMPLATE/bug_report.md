---
name: Bug report
about: Something in the skill behaves incorrectly
title: ''
labels: bug
assignees: ''
---

## What happened

A short description of the unexpected behaviour.

## What you expected

What you thought would happen instead.

## Reproduction

The exact command(s) that surface the issue. Include the tier (`code` / `prose` / `reasoning` / `long-context`) and, if relevant, the resolved model name (`bash scripts/pick-model.sh <tier>`).

```bash
# paste the failing command here
```

## Output

Paste the full output, ideally with `set -x` enabled so the resolved model and any environment overrides are visible.

## Environment

- OS and version (e.g. macOS 15.1, Ubuntu 24.04):
- bash version (`bash --version`):
- Ollama version (`ollama --version`):
- Output of `ollama list` (or the relevant lines):
- Skill version or commit SHA:
- Install method (npx skills add / per-tool guide / manual cp):

## Anything else

Logs from `~/.claude/skills/delegate-local/metrics.jsonl` (last few lines) are useful when the bug is in routing or the wrapper. Redact any sensitive content first.
