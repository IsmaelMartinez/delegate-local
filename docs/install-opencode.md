# Install — OpenCode

OpenCode reads skills from `~/.config/opencode/skills/` (user-scoped) and from any `.agents/skills/` directory in the project root via AAIF discovery. The skill auto-loads when its frontmatter `description` triggers — no manual activation needed.

## Recommended

```bash
npx skills add IsmaelMartinez/delegate-local -a opencode
```

The `-a opencode` flag scopes the install to OpenCode only. Add `-g` for a user-scoped install (`~/.config/opencode/skills/delegate-local`) instead of project-scoped, and `--copy` if symlinks do not work on your filesystem.

## AAIF auto-discovery

The repo ships an AAIF symlink at `.agents/skills/delegate-local` pointing back at the repo root. If you have cloned the repo into a project that OpenCode is reading, the skill is already discoverable — no copy needed. Verify with:

```bash
ls .agents/skills/delegate-local/SKILL.md
```

If the file resolves through the symlink, OpenCode will find it on its next session. AAIF discovery is the most portable install path — it survives repo updates without re-running the install command.

## Manual

```bash
git clone https://github.com/IsmaelMartinez/delegate-local
ln -s "$PWD/delegate-local" ~/.config/opencode/skills/delegate-local
```

Use `cp -r` instead of `ln -s` on filesystems without symlink support. The directory must end at the skill name (`delegate-local`), not at `skills/` — OpenCode expects each skill in its own subdirectory.

## Use the optional MCP server instead

OpenCode supports MCP servers natively. If you would rather expose the routing scripts as MCP tools (`pick_model`, `audit_models`, `list_tiers`) than have OpenCode read the SKILL.md directly, install the optional Python server in `mcp/` — see [`mcp/README.md`](../mcp/README.md) for the install snippet and the OpenCode configuration block. The bash routing logic stays the source of truth; the MCP server is a thin wrapper.

## Verify

Ask OpenCode for something the skill should fire on (a log summary, a commit-message draft, a triage pass) and confirm it announces "Delegated to <model> (<tier> tier)" before producing the output. The audit script confirms both that the skill is reachable and that `ollama list` shows installed models in the resolved tiers:

```bash
bash ~/.config/opencode/skills/delegate-local/scripts/audit-models.sh
```

If OpenCode answers without delegating, check that the SKILL.md is reachable through one of the documented paths (user-scoped, project-scoped, or AAIF) and that the Ollama daemon is running.

## Per-machine routing override

Same pattern as Claude Code — `init.sh` writes a starter override based on `ollama list`. Path is `~/.config/opencode/skills/delegate-local/config.sh`:

```bash
bash ~/.config/opencode/skills/delegate-local/scripts/init.sh > ~/.config/opencode/skills/delegate-local/config.sh
```

The default config path is the Claude Code one (`~/.claude/skills/...`). On an OpenCode-only host, set `DELEGATE_LOCAL_CONFIG=~/.config/opencode/skills/delegate-local/config.sh` in your shell profile so `pick-model.sh` reads from the OpenCode location.

## Uninstall

```bash
rm -rf ~/.config/opencode/skills/delegate-local
```

The metrics file written by `delegate.sh` defaults to `~/.claude/skills/delegate-local/metrics.jsonl` regardless of which agent invoked it. To redirect it, set `DELEGATE_METRICS_FILE=~/.config/opencode/skills/delegate-local/metrics.jsonl` in the shell that runs OpenCode.
