"""MCP server exposing delegate-to-ollama's routing scripts as tools.

The three tools (pick_model, audit_models, list_tiers) are thin shells over
scripts/pick-model.sh and scripts/audit-models.sh. No business logic lives
here — the bash scripts remain the source of truth for tier routing and
upgrade-suggestion behaviour.

DELEGATE_TO_OLLAMA_SCRIPTS env var overrides the scripts directory location
(useful when the package is installed outside its source tree).
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from mcp.server.fastmcp import FastMCP


def _default_scripts_dir() -> Path:
    return Path(__file__).resolve().parent.parent.parent / "scripts"


def scripts_dir() -> Path:
    override = os.environ.get("DELEGATE_TO_OLLAMA_SCRIPTS")
    return Path(override) if override else _default_scripts_dir()


app = FastMCP("delegate-to-ollama")


@app.tool()
def pick_model(tier: str, dry_run: bool = False) -> dict:
    """Resolve a tier to the best installed Ollama model.

    Returns {"model": str, "tier": str, "trace": str}. `trace` is empty
    unless dry_run=True, in which case it contains the resolution trace
    that pick-model.sh writes to stderr.

    Raises RuntimeError if the tier is unknown, ollama isn't on PATH,
    or no installed model matches the tier's preferences.
    """
    script = scripts_dir() / "pick-model.sh"
    cmd = ["bash", str(script)]
    if dry_run:
        cmd.append("--dry-run")
    cmd.append(tier)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"pick-model.sh exited {result.returncode}: {result.stderr.strip()}"
        )
    return {
        "model": result.stdout.strip(),
        "tier": tier,
        "trace": result.stderr.strip() if dry_run else "",
    }


@app.tool()
def audit_models() -> str:
    """Run the read-only model audit and return its stdout verbatim.

    Output includes installed models, tier routing, and (if llmfit is on
    PATH) upgrade suggestions filtered to first-party providers. Never
    pulls or installs anything.
    """
    script = scripts_dir() / "audit-models.sh"
    result = subprocess.run(["bash", str(script)], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"audit-models.sh exited {result.returncode}: {result.stderr.strip()}"
        )
    return result.stdout


@app.tool()
def list_tiers() -> list[str]:
    """Return the tier names supported by pick-model.sh.

    Parses the TIERS=... line in pick-model.sh so the script remains the
    single source of truth.
    """
    script = scripts_dir() / "pick-model.sh"
    text = script.read_text()
    match = re.search(r'^TIERS="([^"]+)"', text, re.MULTILINE)
    if not match:
        raise RuntimeError(f"could not find TIERS= line in {script}")
    return match.group(1).split("|")
