# Install — Codex

Codex (OpenAI's CLI) reads skills from `~/.codex/skills/` (user-scoped) and `<project>/.codex/skills/` (project-scoped). The skill auto-loads when its frontmatter `description` matches the current task — no manual activation needed.

## Recommended

```bash
npx skills add IsmaelMartinez/delegate-local -a codex
```

The `-a codex` flag scopes the install to Codex only. Add `-g` for a user-scoped install (`~/.codex/skills/delegate-local`) instead of project-scoped, and `--copy` if symlinks do not work on your filesystem.

## Manual

```bash
git clone https://github.com/IsmaelMartinez/delegate-local
ln -s "$PWD/delegate-local" ~/.codex/skills/delegate-local
```

For project-scoped install replace `~/.codex/skills/` with `<project>/.codex/skills/`. Use `cp -r` instead of `ln -s` on filesystems without symlink support.

## Verify

Ask Codex something the skill should fire on (a log summary, a commit-message draft, a triage of N items) and confirm it announces "Delegated to <model> (<tier> tier)" before producing the output. The audit script confirms both that the skill is reachable and that `ollama list` shows installed models in the resolved tiers:

```bash
bash ~/.codex/skills/delegate-local/scripts/audit-models.sh
```

If Codex answers without delegating, check that `~/.codex/skills/delegate-local/SKILL.md` exists (the path `npx skills add -a codex` installs to) and that the Ollama daemon is running.

## Per-machine routing override

Same as Claude Code's pattern — `init.sh` writes a starter override based on installed models. Path is `~/.codex/skills/delegate-local/config.sh`:

```bash
bash ~/.codex/skills/delegate-local/scripts/init.sh > ~/.codex/skills/delegate-local/config.sh
```

The default config path is the Claude Code one (`~/.claude/skills/...`). On a Codex-only host, set `DELEGATE_LOCAL_CONFIG=~/.codex/skills/delegate-local/config.sh` in your shell profile so `pick-model.sh` reads from the Codex location.

## Uninstall

```bash
rm -rf ~/.codex/skills/delegate-local
```

The metrics file written by `delegate.sh` defaults to `~/.claude/skills/delegate-local/metrics.jsonl` regardless of which agent invoked it. To redirect it, set `DELEGATE_METRICS_FILE=~/.codex/skills/delegate-local/metrics.jsonl` in the shell that runs Codex.
