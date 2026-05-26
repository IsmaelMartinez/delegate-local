# Install — Claude Code

Claude Code reads skills from `~/.claude/skills/` (user-scoped) and `<project>/.claude/skills/` (project-scoped); the project path takes precedence when both exist. The skill auto-loads when its frontmatter `description` triggers — no manual activation needed.

## Recommended

```bash
npx skills add IsmaelMartinez/delegate-local -a claude-code
```

The `-a claude-code` flag scopes the install to Claude Code only, so the AAIF symlink does not propagate to other tools you have installed. Add `-g` if you want the install to be user-scoped (`~/.claude/skills/delegate-local`) rather than project-scoped, and `--copy` on systems where symlinks do not work (most network filesystems, some Windows configurations).

## Manual

```bash
git clone https://github.com/IsmaelMartinez/delegate-local
ln -s "$PWD/delegate-local" ~/.claude/skills/delegate-local
```

For project-scoped install replace `~/.claude/skills/` with `<project>/.claude/skills/`. Use `cp -r` instead of `ln -s` if symlinks are not an option.

## Verify

Ask Claude Code something the skill should fire on, for example "summarise this build log" or "draft a commit message for this diff", and confirm it announces "Delegated to <model> (<tier> tier)" before producing the output. If it answers without delegating, check that `~/.claude/skills/delegate-local/SKILL.md` exists and that `ollama list` shows at least one installed model in the resolved tier. The audit script gives both signals at once:

```bash
bash ~/.claude/skills/delegate-local/scripts/audit-models.sh
```

## Per-machine routing override

Different machines have different installed model sets. To override `pick-model.sh` on this host without forking the repo:

```bash
bash ~/.claude/skills/delegate-local/scripts/init.sh > ~/.claude/skills/delegate-local/config.sh
```

`init.sh` is read-only and prints a starter override based on what `ollama list` currently reports — review and edit before saving. The override is sourced after the shipped defaults so any tier it touches wins; untouched tiers fall through. See [`README.md`](../README.md#personalising-routing-optional) for the full pattern.

## Uninstall

```bash
rm -rf ~/.claude/skills/delegate-local
```

The metrics file at `~/.claude/skills/delegate-local/metrics.jsonl` is per-user telemetry — delete it manually if you want to clear the local history.
