"""MCP server exposing delegate-to-ollama's routing scripts as tools.

The tools are thin shells over scripts/pick-model.sh and scripts/audit-models.sh
plus a recipe-recommendation tool that reads prompts/ and the local metrics
JSONL. No new business logic lives here — the bash scripts remain the source
of truth for tier routing and upgrade-suggestion behaviour, and prompts/ remains
the source of truth for recipe content.

DELEGATE_TO_OLLAMA_SCRIPTS env var overrides the scripts directory location
(useful when the package is installed outside its source tree).
DELEGATE_PROMPTS_DIR overrides the prompts directory (same convention as
scripts/delegate.sh). DELEGATE_METRICS_FILE overrides the metrics JSONL
location (same convention as scripts/delegate.sh and delegate-feedback.sh).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

from mcp.server.fastmcp import FastMCP


def _default_scripts_dir() -> Path:
    return Path(__file__).resolve().parent.parent.parent / "scripts"


def _default_prompts_dir() -> Path:
    return Path(__file__).resolve().parent.parent.parent / "prompts"


def _default_metrics_file() -> Path:
    return Path.home() / ".claude" / "skills" / "delegate-to-ollama" / "metrics.jsonl"


def scripts_dir() -> Path:
    override = os.environ.get("DELEGATE_TO_OLLAMA_SCRIPTS")
    return Path(override) if override else _default_scripts_dir()


def prompts_dir() -> Path:
    override = os.environ.get("DELEGATE_PROMPTS_DIR")
    return Path(override) if override else _default_prompts_dir()


def metrics_file() -> Path:
    override = os.environ.get("DELEGATE_METRICS_FILE")
    return Path(override) if override else _default_metrics_file()


app = FastMCP("delegate-to-ollama")

# Bounded timeouts so a wedged ollama or llmfit can't hang the MCP client
# indefinitely. pick-model.sh just shells `ollama list`; audit-models.sh
# additionally shells llmfit and several jq passes.
PICK_MODEL_TIMEOUT_S = 30
AUDIT_MODELS_TIMEOUT_S = 120

# Sibling projects this skill cross-links to. Source of truth for the URLs
# that previously only lived in README.md "Related projects". Edit here when
# a new project joins the constellation.
RELATED_PROJECTS = [
    {
        "name": "local-brain",
        "url": "https://github.com/IsmaelMartinez/local-brain",
        "summary": "Source of the 'local models are strong summarisers, weak agents' framing this skill operationalises.",
    },
    {
        "name": "ai-model-advisor",
        "url": "https://github.com/IsmaelMartinez/ai-model-advisor",
        "summary": "Tier classification (code / prose / reasoning / long-context) and the smallest-sufficient-model philosophy that pick-model.sh encodes.",
    },
    {
        "name": "llmfit",
        "url": "https://github.com/IsmaelMartinez/llmfit",
        "summary": "Optional dependency that enables hardware-aware upgrade suggestions in audit-models.sh.",
    },
    {
        "name": "repo-butler",
        "url": "https://github.com/IsmaelMartinez/repo-butler",
        "summary": "Tracks repo health across the portfolio; picks up new repos automatically once they exist on GitHub.",
    },
]


def _run(cmd: list[str], timeout: int, label: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"{label} timed out after {timeout}s") from exc


def _model_url(model: str) -> str:
    """Map an Ollama model name to its library page URL.

    Library models (`qwen3.6:35b-a3b-q8_0`) map under `/library/`; user-
    namespaced models (`someuser/foo:tag`) keep their namespace. Returns
    empty string for empty input.
    """
    if not model:
        return ""
    base = model.split(":", 1)[0]
    if not base:
        return ""
    if "/" in base:
        return f"https://ollama.com/{base}"
    return f"https://ollama.com/library/{base}"


@app.tool()
def pick_model(tier: str, dry_run: bool = False) -> dict:
    """Resolve a tier to the best installed Ollama model.

    Returns {"model": str, "tier": str, "url": str, "trace": str}. `url`
    is the resolved model's Ollama library page (or user-namespace page
    if the model name is namespaced). `trace` is empty unless dry_run=True,
    in which case it contains the resolution trace that pick-model.sh
    writes to stderr.

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
    model = result.stdout.strip()
    return {
        "model": model,
        "tier": tier,
        "url": _model_url(model),
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
def list_related_projects() -> list[dict[str, str]]:
    """Return the four sibling projects this skill cross-links to.

    Each entry has {"name", "url", "summary"}. Mirrors the README's
    "Related projects" section so MCP clients can surface clickable
    links to local-brain, ai-model-advisor, llmfit, and repo-butler
    without parsing prose.
    """
    return [dict(p) for p in RELATED_PROJECTS]


# --- Recipe recommendation ----------------------------------------------------
#
# Recipes live in prompts/<name>.md (sibling directory of mcp/). Each file
# follows the structure documented in prompts/README.md: H2 sections for
# `When to use`, `Prompt template`, `Variables`, `Invocation`, etc. The
# `Invocation` block names a tier as a positional arg to `delegate.sh`, which
# is the load-bearing routing metadata callers of this tool need.

# Tier names mirror pick-model.sh. Kept in sync via the test suite.
_TIER_NAMES = (
    "code",
    "prose",
    "reasoning",
    "long-context",
    "vision",
    "embedding",
    "premium-general",
    "reasoning-vision",
)

# Task-token aliases. Maps colloquial variants to the canonical token used in
# recipe filenames. Kept deliberately small — extend only when a real session
# misses a match.
_TASK_ALIASES = {
    "summarize": "summarise",
    "summarising": "summarise",
    "summarizing": "summarise",
    "summary": "summarise",
    "msg": "message",
    "commits": "commit",
    "messages": "message",
    "descriptions": "description",
    "notes": "note",
    "diffs": "diff",
    "issues": "issue",
    "review": "review",
    "reviews": "review",
    "replies": "reply",
    "responding": "reply",
    "respond": "reply",
}


def _tokenise_task(task: str) -> set[str]:
    """Lowercase, alias-normalise, and split a task description into tokens."""
    tokens = re.findall(r"[A-Za-z]+", task.lower())
    return {_TASK_ALIASES.get(t, t) for t in tokens}


def _list_recipes() -> list[str]:
    """Return the names (file stems) of every recipe in prompts/.

    Filters out README.md and any non-recipe markdown so the directory can hold
    documentation alongside recipes without breaking matching.
    """
    pdir = prompts_dir()
    if not pdir.is_dir():
        return []
    return sorted(
        p.stem
        for p in pdir.glob("*.md")
        if p.stem.lower() != "readme"
    )


def _match_recipe(task: str, recipes: list[str]) -> str | None:
    """Pick the recipe whose stem tokens overlap most with the task.

    Returns None if no recipe shares a single token with the task. Ties are
    broken by recipe-stem length (more specific stem wins), then alphabetical
    order for determinism.
    """
    task_tokens = _tokenise_task(task)
    if not task_tokens:
        return None
    scored = []
    for recipe in recipes:
        stem_tokens = {t.lower() for t in recipe.split("-")}
        score = len(stem_tokens & task_tokens)
        if score > 0:
            scored.append((score, len(stem_tokens), recipe))
    if not scored:
        return None
    scored.sort(key=lambda x: (-x[0], -x[1], x[2]))
    return scored[0][2]


_H2_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)


def _split_h2_sections(text: str) -> dict[str, str]:
    """Split a markdown document into a {h2-title: body} map.

    Body is everything between this H2 and the next H2 (or EOF). Titles are
    stored verbatim (case-sensitive), so callers should look up the exact
    section name they expect.
    """
    sections: dict[str, str] = {}
    matches = list(_H2_RE.finditer(text))
    for i, match in enumerate(matches):
        title = match.group(1).strip()
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        sections[title] = text[start:end].strip()
    return sections


_FENCED_RE = re.compile(r"```(?:[^\n]*)\n(.*?)\n```", re.DOTALL)


def _first_fenced_block(body: str) -> str:
    """Return the contents of the first fenced code block in ``body``.

    Falls back to the section body verbatim if no fence is present, since some
    sections (Variables) are intentionally written as bullet prose. The caller
    decides whether to require a fence.
    """
    match = _FENCED_RE.search(body)
    return match.group(1) if match else body.strip()


# Tier appears as a bare positional arg immediately before the quoted prompt
# in every recipe's Invocation example, e.g. `... prose "Match the example…"`.
# Multi-line invocations with `\` continuations still preserve this contract on
# the final line. Anchoring on `<tier> "` avoids false positives from words
# like "prose" appearing earlier in the example.
_TIER_RE = re.compile(
    r"\b(" + "|".join(re.escape(t) for t in _TIER_NAMES) + r')\s+"'
)


def _extract_tier(invocation_body: str) -> str:
    """Pull the tier name out of a recipe's Invocation example.

    The convention is `bash scripts/delegate.sh --recipe NAME [...] <tier> "<prompt>"`.
    Returns the first matching tier name, or empty string if none found.
    """
    match = _TIER_RE.search(invocation_body)
    return match.group(1) if match else ""


def _parse_recipe(path: Path) -> dict:
    """Read a recipe markdown file and return its structured fields."""
    text = path.read_text(encoding="utf-8")
    sections = _split_h2_sections(text)
    template_section = sections.get("Prompt template", "")
    invocation_section = sections.get("Invocation", "")
    return {
        "when_to_use": sections.get("When to use", "").strip(),
        "template": _first_fenced_block(template_section),
        "variables": sections.get("Variables", "").strip(),
        "invocation": _first_fenced_block(invocation_section),
        "tier": _extract_tier(invocation_section),
    }


def _read_recipe_metrics(recipe_name: str, max_examples: int) -> dict:
    """Walk the metrics JSONL and roll up hit/miss counts for one recipe.

    Returns {"hit_count", "miss_count", "recent_hits"} where recent_hits is a
    list of up to ``max_examples`` HIT events (newest first), each annotated
    with the matched feedback reason and the delegating model. If the metrics
    file is absent or unreadable, all counts are zero — this is the cold-start
    case, not an error.
    """
    path = metrics_file()
    if not path.exists():
        return {"hit_count": 0, "miss_count": 0, "recent_hits": []}

    delegate_rows: list[dict] = []
    feedback_by_ref: dict[str, dict] = {}
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return {"hit_count": 0, "miss_count": 0, "recent_hits": []}

    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Old delegate rows pre-date the `source` field; treat them as delegate.
        source = row.get("source", "delegate")
        if source == "delegate" and row.get("recipe") == recipe_name:
            delegate_rows.append(row)
        elif source == "feedback":
            ref = row.get("ref_ts")
            if ref:
                # Latest verdict for a given ref_ts wins. File is append-only
                # so plain overwrite gives the correct semantics.
                feedback_by_ref[ref] = row

    hits = 0
    misses = 0
    hit_events: list[dict] = []
    for d in delegate_rows:
        fb = feedback_by_ref.get(d.get("ts"))
        if fb is None:
            continue
        if fb.get("kept"):
            hits += 1
            hit_events.append(
                {
                    "ts": d.get("ts", ""),
                    "model": d.get("model", ""),
                    "reason": fb.get("reason", ""),
                }
            )
        else:
            misses += 1

    hit_events.sort(key=lambda r: r["ts"], reverse=True)
    return {
        "hit_count": hits,
        "miss_count": misses,
        "recent_hits": hit_events[:max_examples],
    }


@app.tool()
def recommend_prompt(
    task: str,
    include_examples: bool = True,
    max_examples: int = 3,
) -> dict:
    """Return the best-known recipe for a task plus local HIT examples.

    Matches ``task`` against the recipes in ``prompts/`` by token overlap with
    the recipe filename stem, then reads the local metrics JSONL to attach
    hit/miss counts and (when ``include_examples`` is true) the most recent
    ``max_examples`` HIT events with their feedback reason.

    This turns the hit/miss log from a passive scoreboard into an active
    training signal — recent local-machine HITs surface alongside the recipe
    text so callers see what worked on this host.

    Returns ``{"task", "recipe", "path", "tier", "when_to_use", "template",
    "variables", "invocation", "hit_count", "miss_count", "recent_hits"}``.
    Raises RuntimeError if no recipe matches the task; the error message lists
    every available recipe so the caller can retry with a better phrasing.
    """
    recipes = _list_recipes()
    if not recipes:
        raise RuntimeError(f"no recipes found in {prompts_dir()}")
    recipe = _match_recipe(task, recipes)
    if recipe is None:
        raise RuntimeError(
            f"no recipe matched task {task!r}. Available recipes: "
            + ", ".join(recipes)
        )
    path = prompts_dir() / f"{recipe}.md"
    parsed = _parse_recipe(path)
    metrics = _read_recipe_metrics(
        recipe, max_examples if include_examples else 0
    )
    return {
        "task": task,
        "recipe": recipe,
        "path": str(path),
        "tier": parsed["tier"],
        "when_to_use": parsed["when_to_use"],
        "template": parsed["template"],
        "variables": parsed["variables"],
        "invocation": parsed["invocation"],
        "hit_count": metrics["hit_count"],
        "miss_count": metrics["miss_count"],
        "recent_hits": metrics["recent_hits"] if include_examples else [],
    }


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
