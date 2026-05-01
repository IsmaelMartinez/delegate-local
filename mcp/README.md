# delegate-to-ollama-mcp

An optional MCP server that exposes the routing logic of
[delegate-to-ollama](https://github.com/IsmaelMartinez/delegate-to-ollama) to
non-Claude tools (Codex, OpenCode, Cursor, custom MCP clients, etc.). It is
a thin wrapper over the existing bash scripts — no new business logic
lives here.

The Claude Code skill itself does not need this MCP server. Use it when
another MCP-aware client wants to query "which model would route for
tier X" or "show me the audit summary" without shelling out.

## Tools exposed

- `pick_model(tier, dry_run=False)` — resolves a tier (`code`, `prose`,
  `reasoning`, `long-context`, `vision`, `embedding`, `premium-general`,
  `reasoning-vision`) to the best installed Ollama model. Returns
  `{"model", "tier", "trace"}`. Set `dry_run=True` to capture the
  resolution trace from `pick-model.sh --dry-run`.
- `audit_models()` — runs `audit-models.sh` and returns its stdout
  verbatim. Read-only; never pulls a model.
- `list_tiers()` — returns the tier names supported by `pick-model.sh`.
  Parsed from the script so it stays in sync.

## Install

From a clone of this repository:

```bash
cd mcp
python3 -m venv .venv
.venv/bin/pip install -e .
```

This puts a `delegate-to-ollama-mcp` console script on PATH (inside the
venv) and exposes the package as `delegate_to_ollama_mcp`.

The server expects the bash scripts to be reachable. By default it
resolves `../scripts/` relative to the package install location (works
when installed editable from the repo). Override with the env var
`DELEGATE_TO_OLLAMA_SCRIPTS=/abs/path/to/scripts`.

## Run

Stdio (the standard MCP transport):

```bash
.venv/bin/delegate-to-ollama-mcp
# or equivalently:
.venv/bin/python -m delegate_to_ollama_mcp
```

The server reads JSON-RPC requests from stdin and writes responses to
stdout. Connect any MCP-aware client to it.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "delegate-to-ollama": {
      "command": "/abs/path/to/mcp/.venv/bin/delegate-to-ollama-mcp"
    }
  }
}
```

### Codex / OpenCode / Cursor

Each of these reads MCP servers from its own config file. The command
to invoke is the same — a path to the venv's `delegate-to-ollama-mcp`
script. See each tool's MCP integration docs for the exact config
location and key names.

### Inspect interactively

If you have `mcp-inspector` installed:

```bash
mcp dev .
```

…will boot the server and open the inspector UI for poking at tools.

## Test

```bash
.venv/bin/pip install -e ".[dev]"
.venv/bin/pytest -q
```

The test suite mocks `subprocess.run` so it runs deterministically
without needing `ollama` or `llmfit` on the host.

## Why a thin wrapper

Every tool in this server delegates to a bash script that already
exists and has its own test suite under `../tests/`. Re-implementing
the routing logic in Python would create two sources of truth and
bit-rot the day someone edited one without the other. The wrapper is
intentionally boring — three functions, one regex, and `subprocess.run`
calls. See `docs/adr/0004-optional-mcp-server.md` in the repo root for
the design rationale.

## Scope

Out of scope:

- Wrapping `delegate.sh` itself. Delegation belongs to the Claude Code
  skill (`SKILL.md`); the MCP surface intentionally stays read-only
  routing metadata.
- Pulling or removing models. The audit script is read-only by design.
- Running the experiments framework. Phase 7 tooling has its own
  surface; expose it here only if a real consumer asks.
