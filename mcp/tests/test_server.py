"""Unit tests for the MCP server.

subprocess.run is mocked so tests are deterministic regardless of whether
ollama / llmfit / the bash scripts behave on the host. The point is to
verify the wrapper logic, not re-test the bash scripts (which have their
own suite under ../../tests/).
"""

from __future__ import annotations

import json
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
    monkeypatch.delenv("DELEGATE_BACKEND", raising=False)
    out = server.pick_model("prose")
    assert out == {
        "model": "qwen3.6:35b-a3b-q8_0",
        "tier": "prose",
        "backend": "ollama",
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


def test_pick_model_mlx_backend_sets_env_and_url(monkeypatch):
    """backend='mlx' overlays DELEGATE_BACKEND into the subprocess env and
    routes the URL to HuggingFace instead of the Ollama library."""
    captured = {}

    def fake_run(cmd, capture_output, text, timeout, env=None):
        captured["cmd"] = cmd
        captured["env"] = env
        return _completed(
            stdout="mlx-community/Qwen3.6-35B-A3B-Instruct-4bit\n",
            stderr="",
            returncode=0,
        )

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.delenv("DELEGATE_BACKEND", raising=False)
    out = server.pick_model("prose", backend="mlx")
    assert out == {
        "model": "mlx-community/Qwen3.6-35B-A3B-Instruct-4bit",
        "tier": "prose",
        "backend": "mlx",
        "url": "https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-Instruct-4bit",
        "trace": "",
    }
    # The overlay must contain DELEGATE_BACKEND=mlx and inherit the rest
    # of the parent env (so PATH, HOME, HF_HOME etc. survive).
    assert captured["env"] is not None
    assert captured["env"].get("DELEGATE_BACKEND") == "mlx"


def test_pick_model_backend_param_wins_over_env(monkeypatch):
    """If the MCP server was launched with DELEGATE_BACKEND=ollama, an explicit
    backend='mlx' on the tool call still overlays the call's env with mlx."""
    captured = {}

    def fake_run(cmd, capture_output, text, timeout, env=None):
        captured["env"] = env
        return _completed(
            stdout="mlx-community/Qwen3.6-35B-A3B-Instruct-4bit\n",
            stderr="",
            returncode=0,
        )

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setenv("DELEGATE_BACKEND", "ollama")
    out = server.pick_model("prose", backend="mlx")
    assert out["backend"] == "mlx"
    assert captured["env"]["DELEGATE_BACKEND"] == "mlx"


def test_pick_model_no_backend_arg_inherits_env(monkeypatch):
    """When backend is omitted but DELEGATE_BACKEND is set in the parent env,
    the resolved backend reflects the env. The subprocess inherits the env
    via subprocess.run's default (no env= kwarg passed)."""
    captured = {}

    def fake_run(cmd, capture_output, text, timeout):
        # No env kwarg — _run does not pass it when env_overlay is None.
        captured["cmd"] = cmd
        return _completed(
            stdout="mlx-community/Qwen3.6-35B-A3B-Instruct-4bit\n",
            stderr="",
            returncode=0,
        )

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setenv("DELEGATE_BACKEND", "mlx")
    out = server.pick_model("prose")
    assert out["backend"] == "mlx"
    assert out["url"].startswith("https://huggingface.co/")


def test_pick_model_invalid_backend_raises(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout, env=None):
        # Should never be called — validation happens before subprocess dispatch.
        raise AssertionError("subprocess.run must not be called for invalid backend")

    monkeypatch.setattr(subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match="unknown backend 'bogus'"):
        server.pick_model("prose", backend="bogus")


def test_pick_model_auto_infers_backend_from_model_name(monkeypatch):
    """backend='auto' lets pick-model.sh probe and resolve; the MCP layer
    infers the resolved backend from the returned model name's shape so
    callers see the actual backend, not the literal "auto"."""
    captured = {}

    def fake_run_mlx_resolution(cmd, capture_output, text, timeout, env=None):
        captured["env"] = env
        # Model name contains a slash → MLX HuggingFace stem.
        return subprocess.CompletedProcess(
            args=cmd, returncode=0,
            stdout="mlx-community/Qwen3.6-35B-A3B-Instruct-8bit\n", stderr="",
        )

    monkeypatch.setattr(subprocess, "run", fake_run_mlx_resolution)
    monkeypatch.delenv("DELEGATE_BACKEND", raising=False)
    out = server.pick_model("prose", backend="auto")
    assert out["backend"] == "mlx"
    assert out["url"] == "https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-Instruct-8bit"
    # The "auto" literal must have been forwarded into the subprocess env so
    # pick-model.sh runs its own probe path.
    assert captured["env"]["DELEGATE_BACKEND"] == "auto"


def test_pick_model_auto_falls_back_to_ollama_when_resolved_to_ollama_tag(monkeypatch):
    """Same auto path but the bash probe resolved to ollama (returned an
    Ollama-style tag with no slash). The MCP layer must report backend=ollama."""

    def fake_run(cmd, capture_output, text, timeout, env=None):
        return subprocess.CompletedProcess(
            args=cmd, returncode=0,
            stdout="qwen3.6:35b-a3b-q8_0\n", stderr="",
        )

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.delenv("DELEGATE_BACKEND", raising=False)
    out = server.pick_model("prose", backend="auto")
    assert out["backend"] == "ollama"
    assert out["url"] == "https://ollama.com/library/qwen3.6"


def test_pick_model_default_backend_is_auto_now(monkeypatch):
    """When backend is omitted AND DELEGATE_BACKEND is unset, the bash
    default kicks in (auto). The MCP infers the resolved backend from the
    model name; we exercise the ollama-tag case here (no slash)."""

    def fake_run(cmd, capture_output, text, timeout, env=None):
        # No DELEGATE_BACKEND overlay because backend arg is None.
        assert env is None
        return subprocess.CompletedProcess(
            args=cmd, returncode=0,
            stdout="qwen3.6:35b-a3b-q8_0\n", stderr="",
        )

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.delenv("DELEGATE_BACKEND", raising=False)
    out = server.pick_model("prose")
    assert out["backend"] == "ollama"


def test_pick_model_url_mlx_for_mlx_backend(monkeypatch):
    """Regression: the URL must point at HuggingFace, not the Ollama library,
    when backend=mlx. The earlier _model_url implementation only knew about
    the Ollama URL space."""
    assert (
        server._model_url("mlx-community/Qwen3.6-35B-A3B-Instruct-4bit", "mlx")
        == "https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-Instruct-4bit"
    )
    # Default backend stays ollama for back-compat with existing callers.
    assert (
        server._model_url("qwen3.6:35b-a3b-q8_0")
        == "https://ollama.com/library/qwen3.6"
    )


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


def test_model_url_leading_colon():
    """Defensive: a name starting with ':' has an empty stem, must not produce
    a malformed `https://ollama.com/library/` URL."""
    assert server._model_url(":latest") == ""


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


def test_app_registers_five_tools():
    """Smoke-test that all five tool names are registered on the FastMCP app.

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
        "recommend_prompt",
    }


# --- recommend_prompt --------------------------------------------------------


RECIPE_TEMPLATE = """# {name}

## When to use

{when}

## Context to gather first

```bash
git diff --cached
```

## Prompt template

```
Do the thing in the project's voice.
Input:
{{{{stdin}}}}
```

## Variables

- `{{{{stdin}}}}` — piped context.

## Invocation

```bash
bash scripts/delegate.sh --recipe {name} {tier} "match the shape"
```

## Expected output shape

```
<one paragraph>
```

## Calibration notes

Source session: 2026-05-09.
"""


def _write_recipe(tmp_path, name, when, tier):
    (tmp_path / f"{name}.md").write_text(
        RECIPE_TEMPLATE.format(name=name, when=when, tier=tier),
        encoding="utf-8",
    )


@pytest.fixture
def fake_prompts(tmp_path, monkeypatch):
    """Stand up an isolated prompts dir with two recipes and a README sentinel.

    The README must be ignored by the matcher, otherwise an innocuous file
    next to recipes would skew matching.
    """
    _write_recipe(tmp_path, "commit-message", "Draft a git commit message.", "prose")
    _write_recipe(tmp_path, "summarise-diff", "Bullet summary of a diff.", "prose")
    (tmp_path / "README.md").write_text("# Prompts library\n", encoding="utf-8")
    monkeypatch.setenv("DELEGATE_PROMPTS_DIR", str(tmp_path))
    return tmp_path


@pytest.fixture
def empty_metrics(tmp_path, monkeypatch):
    """Point DELEGATE_METRICS_FILE at a path that does not exist.

    Tests the cold-start path where the agent has never delegated yet, which
    must not error.
    """
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(tmp_path / "missing.jsonl"))


def test_recommend_prompt_happy_path(fake_prompts, empty_metrics):
    out = server.recommend_prompt("draft a commit message")
    assert out["recipe"] == "commit-message"
    assert out["task"] == "draft a commit message"
    assert out["tier"] == "prose"
    assert "Draft a git commit message." in out["when_to_use"]
    assert "{{stdin}}" in out["template"]
    assert "delegate.sh --recipe commit-message" in out["invocation"]
    assert out["path"].endswith("commit-message.md")
    assert out["hit_count"] == 0
    assert out["miss_count"] == 0
    assert out["recent_hits"] == []


def test_recommend_prompt_matches_summarise_diff(fake_prompts, empty_metrics):
    out = server.recommend_prompt("please summarise this diff")
    assert out["recipe"] == "summarise-diff"


def test_recommend_prompt_normalises_summarize_to_summarise(fake_prompts, empty_metrics):
    """US spelling must reach the British-spelled recipe stem.

    Without the alias, "summarize this diff" only overlaps on `diff` against
    `summarise-diff` (score=1), same as a hypothetical `diff-foo` recipe —
    the alias guarantees the more-specific match.
    """
    out = server.recommend_prompt("summarize this diff for me")
    assert out["recipe"] == "summarise-diff"


def test_recommend_prompt_unknown_task_raises(fake_prompts, empty_metrics):
    with pytest.raises(RuntimeError, match="no recipe matched"):
        server.recommend_prompt("rewrite the kubernetes manifest")


def test_recommend_prompt_lists_available_recipes_in_error(fake_prompts, empty_metrics):
    with pytest.raises(RuntimeError) as exc:
        server.recommend_prompt("totally unrelated request")
    msg = str(exc.value)
    assert "commit-message" in msg
    assert "summarise-diff" in msg


def test_recommend_prompt_empty_prompts_dir_raises(tmp_path, monkeypatch, empty_metrics):
    monkeypatch.setenv("DELEGATE_PROMPTS_DIR", str(tmp_path))
    with pytest.raises(RuntimeError, match="no recipes found"):
        server.recommend_prompt("draft a commit message")


def test_recommend_prompt_counts_hits_and_misses(fake_prompts, tmp_path, monkeypatch):
    """A delegate row paired with a kept-true feedback row counts as a HIT.

    The metrics JSONL is append-only; the latest feedback for a given ref_ts
    wins. Delegate rows without a matching feedback row are not counted at
    all (neither hit nor miss).
    """
    metrics_path = tmp_path / "metrics.jsonl"
    rows = [
        # HIT: delegate + feedback kept=true
        {"ts": "2026-05-09T20:23:04Z", "source": "delegate",
         "tier": "prose", "model": "qwen3.6:35b-a3b-q8_0",
         "recipe": "commit-message"},
        {"ts": "2026-05-09T20:23:37Z", "source": "feedback",
         "ref_ts": "2026-05-09T20:23:04Z", "kept": True,
         "reason": "anchored prompt produced verbatim-usable output"},
        # MISS: delegate + feedback kept=false
        {"ts": "2026-05-09T18:56:22Z", "source": "delegate",
         "tier": "prose", "model": "qwen3.6:35b-a3b-q8_0",
         "recipe": "commit-message"},
        {"ts": "2026-05-09T20:17:28Z", "source": "feedback",
         "ref_ts": "2026-05-09T18:56:22Z", "kept": False,
         "reason": "bullets when project style is flowing prose"},
        # No-verdict delegate row: not counted
        {"ts": "2026-05-09T22:00:00Z", "source": "delegate",
         "tier": "prose", "model": "qwen3.6:35b-a3b-q8_0",
         "recipe": "commit-message"},
        # Different recipe: filtered out
        {"ts": "2026-05-10T01:00:00Z", "source": "delegate",
         "tier": "prose", "model": "qwen3.6:35b-a3b-q8_0",
         "recipe": "summarise-diff"},
        {"ts": "2026-05-10T01:01:00Z", "source": "feedback",
         "ref_ts": "2026-05-10T01:00:00Z", "kept": True,
         "reason": "different recipe — must not bleed across"},
    ]
    metrics_path.write_text(
        "\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8"
    )
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(metrics_path))

    out = server.recommend_prompt("draft a commit message")
    assert out["hit_count"] == 1
    assert out["miss_count"] == 1
    assert len(out["recent_hits"]) == 1
    assert out["recent_hits"][0]["ts"] == "2026-05-09T20:23:04Z"
    assert out["recent_hits"][0]["model"] == "qwen3.6:35b-a3b-q8_0"
    assert "anchored prompt" in out["recent_hits"][0]["reason"]


def test_recommend_prompt_latest_feedback_wins(fake_prompts, tmp_path, monkeypatch):
    """Two feedback rows for the same ref_ts: the latter must overwrite.

    Real example from the metrics file: an initial HIT was downgraded to MISS
    on a later session when a hallucinated suffix was discovered in the same
    output. delegate-feedback.sh allows this; the rollup must mirror it.
    """
    metrics_path = tmp_path / "metrics.jsonl"
    rows = [
        {"ts": "2026-05-09T22:46:42Z", "source": "delegate",
         "model": "qwen3.6:35b-a3b-q8_0", "recipe": "commit-message"},
        {"ts": "2026-05-09T22:47:12Z", "source": "feedback",
         "ref_ts": "2026-05-09T22:46:42Z", "kept": True,
         "reason": "first-pass kept"},
        {"ts": "2026-05-10T08:52:41Z", "source": "feedback",
         "ref_ts": "2026-05-09T22:46:42Z", "kept": False,
         "reason": "downgraded — hallucinated (#NN) suffix found later"},
    ]
    metrics_path.write_text(
        "\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8"
    )
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(metrics_path))

    out = server.recommend_prompt("draft a commit message")
    assert out["hit_count"] == 0
    assert out["miss_count"] == 1


def test_recommend_prompt_skips_malformed_jsonl(fake_prompts, tmp_path, monkeypatch):
    metrics_path = tmp_path / "metrics.jsonl"
    metrics_path.write_text(
        '{"ts":"2026-05-09T20:23:04Z","source":"delegate","recipe":"commit-message","model":"m"}\n'
        "this is not json at all\n"
        "\n"
        '{"ts":"2026-05-09T20:23:37Z","source":"feedback","ref_ts":"2026-05-09T20:23:04Z","kept":true,"reason":"ok"}\n',
        encoding="utf-8",
    )
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(metrics_path))
    out = server.recommend_prompt("commit message")
    assert out["hit_count"] == 1


def test_recommend_prompt_include_examples_false_drops_reasons(fake_prompts, tmp_path, monkeypatch):
    """Counts must still populate even when example bodies are suppressed.

    The use case is a caller that only wants the recipe text and confidence
    indicator (hit/miss totals) without paying the per-HIT prose tax.
    """
    metrics_path = tmp_path / "metrics.jsonl"
    rows = [
        {"ts": "2026-05-09T20:23:04Z", "source": "delegate",
         "model": "m", "recipe": "commit-message"},
        {"ts": "2026-05-09T20:23:37Z", "source": "feedback",
         "ref_ts": "2026-05-09T20:23:04Z", "kept": True,
         "reason": "kept"},
    ]
    metrics_path.write_text(
        "\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8"
    )
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(metrics_path))
    out = server.recommend_prompt("commit message", include_examples=False)
    assert out["hit_count"] == 1
    assert out["recent_hits"] == []


def test_recommend_prompt_max_examples_caps_recent_hits(fake_prompts, tmp_path, monkeypatch):
    metrics_path = tmp_path / "metrics.jsonl"
    rows = []
    for i in range(5):
        ts = f"2026-05-09T20:0{i}:00Z"
        fb_ts = f"2026-05-09T20:0{i}:30Z"
        rows.append({"ts": ts, "source": "delegate",
                     "model": "m", "recipe": "commit-message"})
        rows.append({"ts": fb_ts, "source": "feedback",
                     "ref_ts": ts, "kept": True, "reason": f"hit {i}"})
    metrics_path.write_text(
        "\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8"
    )
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(metrics_path))
    out = server.recommend_prompt("commit message", max_examples=2)
    assert out["hit_count"] == 5
    assert len(out["recent_hits"]) == 2
    # Newest first
    assert out["recent_hits"][0]["ts"] > out["recent_hits"][1]["ts"]


def test_recommend_prompt_against_real_prompts_dir(monkeypatch, tmp_path):
    """Sanity-check against the real prompts/ in this repo.

    Catches the case where a recipe gets renamed or its H2 sections drift in a
    way the parser can't follow.
    """
    monkeypatch.delenv("DELEGATE_PROMPTS_DIR", raising=False)
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(tmp_path / "missing.jsonl"))
    out = server.recommend_prompt("draft a commit message")
    assert out["recipe"] == "commit-message"
    assert out["tier"] == "prose"
    assert out["template"]
    assert out["invocation"]


def test_tokenise_task_normalises_aliases():
    tokens = server._tokenise_task("Summarizing the Diffs")
    assert "summarise" in tokens
    assert "diff" in tokens


def test_extract_tier_finds_long_context():
    tier = server._extract_tier(
        "```bash\nbash scripts/delegate.sh --recipe foo long-context \"x\"\n```"
    )
    assert tier == "long-context"


def test_split_h2_sections_basic():
    text = "# Title\n## A\nbody-a\n## B\nbody-b\n"
    sections = server._split_h2_sections(text)
    assert sections["A"] == "body-a"
    assert sections["B"] == "body-b"


def test_metrics_file_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("DELEGATE_METRICS_FILE", str(tmp_path / "x.jsonl"))
    assert server.metrics_file() == tmp_path / "x.jsonl"


def test_prompts_dir_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("DELEGATE_PROMPTS_DIR", str(tmp_path))
    assert server.prompts_dir() == tmp_path
