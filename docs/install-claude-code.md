# Install — Claude Code

Claude Code reads skills from `~/.claude/skills/` (user-scoped) and `<project>/.claude/skills/` (project-scoped); the project path takes precedence when both exist. The skill auto-loads when its frontmatter `description` triggers — no manual activation needed.

## Recommended

```bash
npx skills add IsmaelMartinez/delegate-local -a claude-code
```

The `-a claude-code` flag scopes the install to Claude Code only, so the skill is not also installed into other agent tools the CLI detects. Add `-g` if you want the install to be user-scoped (`~/.claude/skills/delegate-local`) rather than project-scoped, and `--copy` on systems where symlinks do not work (most network filesystems, some Windows configurations).

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

`pick-model.sh` already picks the first preference a running provider serves, so most hosts need no override. To put a model first for a tier on this host without forking the repo, write `~/.local/share/delegate-local/config.sh` by hand, prepending to the shipped list:

```bash
case "$tier" in
  prose) prefs=(gemma-4-26b "${prefs[@]}") ;;
esac
```

The override is sourced after the shipped defaults so any tier it touches wins; untouched tiers fall through. Prepending keeps the shipped list as the fallback and keeps it current; a tier reassigned to a full list of its own stops following it, and `audit-models.sh` warns about that. See [`README.md`](../README.md#personalising-routing-recommended) for the full pattern.

## Uninstall

```bash
rm -rf ~/.claude/skills/delegate-local
```

The metrics file at `~/.local/share/delegate-local/metrics.jsonl` is per-user telemetry — delete it manually if you want to clear the local history.
