"""Unit tests for the MCP server.

subprocess.run is mocked so tests are deterministic regardless of whether
ollama / llmfit / the bash scripts behave on the host. The point is to
verify the wrapper logic, not re-test the bash scripts (which have their
own suite under ../../tests/).
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from delegate_to_ollama_mcp import server


def _completed(stdout: str = "", stderr: str = "", returncode: int = 0):
    return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=returncode)


def test_scripts_dir_defaults_to_repo_scripts(monkeypatch):
    monkeypatch.delenv("DELEGATE_TO_OLLAMA_SCRIPTS", raising=False)
    path = server.scripts_dir()
    assert path.name == "scripts"
    assert (path / "pick-model.sh").exists(), (
        f"expected pick-model.sh under default scripts dir {path}"
    )


def test_scripts_dir_respects_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("DELEGATE_TO_OLLAMA_SCRIPTS", str(tmp_path))
    assert server.scripts_dir() == tmp_path


def test_pick_model_happy_path(monkeypatch):
    captured = {}

    def fake_run(cmd, capture_output, text, timeout):
        captured["cmd"] = cmd
        return _completed(stdout="qwen3.6:35b-a3b-q8_0\n", stderr="", returncode=0)

    monkeypatch.setattr(subprocess, "run", fake_run)
    out = server.pick_model("prose")
    assert out == {
        "model": "qwen3.6:35b-a3b-q8_0",
        "tier": "prose",
        "url": "https://ollama.com/library/qwen3.6",
        "trace": "",
    }
    assert captured["cmd"][0] == "bash"
    assert captured["cmd"][-1] == "prose"
    assert "--dry-run" not in captured["cmd"]


def test_pick_model_dry_run_captures_trace(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        assert "--dry-run" in cmd
        return _completed(
            stdout="qwen3.6:35b-a3b-q8_0\n",
            stderr="dry-run: tier=prose\ndry-run: matched preference='qwen3.6'\n",
            returncode=0,
        )

    monkeypatch.setattr(subprocess, "run", fake_run)
    out = server.pick_model("prose", dry_run=True)
    assert out["model"] == "qwen3.6:35b-a3b-q8_0"
    assert out["url"] == "https://ollama.com/library/qwen3.6"
    assert "tier=prose" in out["trace"]
    assert "matched preference" in out["trace"]


def test_pick_model_unknown_tier_raises(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        return _completed(stdout="", stderr="unknown tier: bogus", returncode=2)

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match="pick-model.sh exited 2"):
        server.pick_model("bogus")


def test_pick_model_no_match_raises(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        return _completed(stdout="", stderr="no models installed", returncode=1)

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match="exited 1"):
        server.pick_model("prose")


def test_audit_models_returns_stdout(monkeypatch):
    fake_output = "=== Installed models ===\nqwen3.6:35b-a3b-q8_0\n\n=== Tier routing ===\n"

    def fake_run(cmd, capture_output, text, timeout):
        assert cmd[0] == "bash"
        assert cmd[1].endswith("audit-models.sh")
        return _completed(stdout=fake_output, stderr="", returncode=0)

    monkeypatch.setattr(subprocess, "run", fake_run)
    assert server.audit_models() == fake_output


def test_audit_models_failure_raises(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        return _completed(stdout="", stderr="ollama not on PATH", returncode=1)

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match="audit-models.sh exited 1"):
        server.audit_models()


def test_list_tiers_parses_pick_model(monkeypatch, tmp_path):
    fake_script = tmp_path / "pick-model.sh"
    fake_script.write_text(
        '#!/usr/bin/env bash\n'
        'set -euo pipefail\n'
        'TIERS="code|prose|reasoning|long-context|vision"\n'
        '# rest of script...\n'
    )
    monkeypatch.setenv("DELEGATE_TO_OLLAMA_SCRIPTS", str(tmp_path))
    assert server.list_tiers() == [
        "code", "prose", "reasoning", "long-context", "vision",
    ]


def test_list_tiers_against_real_script():
    """Sanity-check against the real pick-model.sh in this repo.

    Catches the case where the TIERS= line gets renamed or moved without
    the parser being updated.
    """
    tiers = server.list_tiers()
    assert "code" in tiers
    assert "prose" in tiers
    assert "reasoning" in tiers
    assert "long-context" in tiers
    # 8 tiers as of Phase 4: code, prose, reasoning, long-context, vision,
    # embedding, premium-general, reasoning-vision.
    assert len(tiers) == 8


def test_list_tiers_missing_marker_raises(monkeypatch, tmp_path):
    fake_script = tmp_path / "pick-model.sh"
    fake_script.write_text("#!/usr/bin/env bash\n# no TIERS line here\n")
    monkeypatch.setenv("DELEGATE_TO_OLLAMA_SCRIPTS", str(tmp_path))
    with pytest.raises(RuntimeError, match="could not find TIERS"):
        server.list_tiers()


def test_pick_model_timeout_raises(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=timeout)

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match=r"pick-model\.sh timed out after \d+s"):
        server.pick_model("prose")


def test_audit_models_timeout_raises(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        raise subprocess.TimeoutExpired(cmd=cmd, timeout=timeout)

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match=r"audit-models\.sh timed out after \d+s"):
        server.audit_models()


def test_model_url_library_namespace():
    assert (
        server._model_url("qwen3.6:35b-a3b-q8_0")
        == "https://ollama.com/library/qwen3.6"
    )


def test_model_url_no_tag():
    assert server._model_url("nomic-embed-text") == "https://ollama.com/library/nomic-embed-text"


def test_model_url_user_namespace():
    assert (
        server._model_url("someuser/foo:tag")
        == "https://ollama.com/someuser/foo"
    )


def test_model_url_empty():
    assert server._model_url("") == ""


def test_list_related_projects_returns_four_siblings():
    projects = server.list_related_projects()
    assert len(projects) == 4
    names = {p["name"] for p in projects}
    assert names == {"local-brain", "ai-model-advisor", "llmfit", "repo-butler"}
    for p in projects:
        assert set(p.keys()) == {"name", "url", "summary"}
        assert p["url"].startswith("https://github.com/IsmaelMartinez/")
        assert p["summary"]


def test_list_related_projects_returns_copies():
    """Mutating the return value must not corrupt the module-level constant."""
    projects = server.list_related_projects()
    projects[0]["name"] = "MUTATED"
    assert server.list_related_projects()[0]["name"] == "local-brain"


def test_app_registers_four_tools():
    """Smoke-test that all four tool names are registered on the FastMCP app.

    Uses asyncio to drive the async list_tools() coroutine without
    requiring pytest-asyncio.
    """
    import asyncio

    tools = asyncio.run(server.app.list_tools())
    names = {t.name for t in tools}
    assert names == {
        "pick_model",
        "audit_models",
        "list_tiers",
        "list_related_projects",
    }
