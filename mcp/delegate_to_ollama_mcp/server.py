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

# Bounded timeouts so a wedged ollama or llmfit can't hang the MCP client
# indefinitely. pick-model.sh just shells `ollama list`; audit-models.sh
# additionally shells llmfit and several jq passes.
PICK_MODEL_TIMEOUT_S = 30
AUDIT_MODELS_TIMEOUT_S = 120


def _run(cmd: list[str], timeout: int, label: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{label} timed out after {timeout}s") from exc


@app.tool()
def pick_model(tier: str, dry_run: bool = False) -> dict:
    """Resolve a tier to the best installed Ollama model.

    Returns {"model": str, "tier": str, "trace": str}. `trace` is empty
    unless dry_run=True, in which case it contains the resolution trace
    that pick-model.sh writes to stderr.

    Raises RuntimeError if the tier is unknown, ollama isn't on PATH,
    no installed model matches the tier's preferences, or the script
    exceeds PICK_MODEL_TIMEOUT_S.
    """
    script = scripts_dir() / "pick-model.sh"
    cmd = ["bash", str(script)]
    if dry_run:
        cmd.append("--dry-run")
    cmd.append(tier)
    result = _run(cmd, PICK_MODEL_TIMEOUT_S, "pick-model.sh")
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
    pulls or installs anything. Raises RuntimeError if the script exits
    non-zero or exceeds AUDIT_MODELS_TIMEOUT_S.
    """
    script = scripts_dir() / "audit-models.sh"
    result = _run(["bash", str(script)], AUDIT_MODELS_TIMEOUT_S, "audit-models.sh")
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
    text = script.read_text(encoding="utf-8")
    match = re.search(r'^TIERS="([^"]+)"', text, re.MULTILINE)
    if not match:
        raise RuntimeError(f"could not find TIERS= line in {script}")
    return match.group(1).split("|")
