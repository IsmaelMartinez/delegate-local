# Install — OpenCode

OpenCode reads skills from `~/.config/opencode/skills/` (user-scoped). The skill auto-loads when its frontmatter `description` triggers — no manual activation needed.

## Recommended

```bash
npx skills add IsmaelMartinez/delegate-local -a opencode
```

The `-a opencode` flag scopes the install to OpenCode only. Add `-g` for a user-scoped install (`~/.config/opencode/skills/delegate-local`) instead of project-scoped, and `--copy` if symlinks do not work on your filesystem.

## Manual

```bash
git clone https://github.com/IsmaelMartinez/delegate-local
ln -s "$PWD/delegate-local" ~/.config/opencode/skills/delegate-local
```

Use `cp -r` instead of `ln -s` on filesystems without symlink support. The directory must end at the skill name (`delegate-local`), not at `skills/` — OpenCode expects each skill in its own subdirectory.

## Verify

Ask OpenCode for something the skill should fire on (a log summary, a commit-message draft, a triage pass) and confirm it announces "Delegated to <model> (<tier> tier)" before producing the output. The audit script confirms both that the skill is reachable and that `ollama list` shows installed models in the resolved tiers:

```bash
bash ~/.config/opencode/skills/delegate-local/scripts/audit-models.sh
```

If OpenCode answers without delegating, check that the SKILL.md is reachable at `~/.config/opencode/skills/delegate-local/SKILL.md` and that the Ollama daemon is running.

## Per-machine routing override

Same pattern as Claude Code: a hand-written `~/.local/share/delegate-local/config.sh` that prepends to `prefs` for the tiers you want reordered, e.g. `prose) prefs=(gemma-4-26b "${prefs[@]}") ;;` (see [`install-claude-code.md`](install-claude-code.md#per-machine-routing-override)). The path is the shared data directory whichever agent installed the skill; `DELEGATE_LOCAL_CONFIG` redirects it.

## Uninstall

```bash
rm -rf ~/.config/opencode/skills/delegate-local
```

The metrics file written by `delegate.sh` defaults to `~/.local/share/delegate-local/metrics.jsonl` regardless of which agent invoked it. To redirect it, set `DELEGATE_METRICS_FILE=~/.config/opencode/skills/delegate-local/metrics.jsonl` in the shell that runs OpenCode.
