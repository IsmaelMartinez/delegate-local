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

Same as Claude Code's pattern: a hand-written `~/.local/share/delegate-local/config.sh` that reassigns `prefs` for the tiers you want reordered (see [`install-claude-code.md`](install-claude-code.md#per-machine-routing-override)). The path is the shared data directory whichever agent installed the skill; `DELEGATE_LOCAL_CONFIG` redirects it.

## Uninstall

```bash
rm -rf ~/.codex/skills/delegate-local
```

The metrics file written by `delegate.sh` defaults to `~/.local/share/delegate-local/metrics.jsonl` regardless of which agent invoked it. To redirect it, set `DELEGATE_METRICS_FILE=~/.codex/skills/delegate-local/metrics.jsonl` in the shell that runs Codex.
