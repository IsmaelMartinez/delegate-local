"""Shared plumbing for the agent-framework spike (throwaway).

Loads the real-case eval set, renders a recipe template exactly the way
scripts/delegate.sh does (first fenced block under "## Prompt template",
{{key}} substitution, empty string for absent optional vars) and talks to a
local OpenAI-compatible endpoint with the same envelope the wrapper uses.
"""
import json
import os
import re
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DATA = Path(os.environ.get("SPIKE_DATA", Path.home() / ".local/share/delegate-local/spikes"))
RESULTS = DATA / "results"
MLX = os.environ.get("SPIKE_MLX", "http://localhost:8080/v1")
DEFAULT_MODEL = os.environ.get("SPIKE_MODEL", "mlx-community/Qwen3.6-35B-A3B-8bit")


def load_cases(recipe=None, limit=None):
    cases = json.loads((DATA / "cases.json").read_text())
    if recipe:
        cases = [c for c in cases if c["recipe"] == recipe]
    return cases[:limit] if limit else cases


def template(recipe):
    """Port of the awk in delegate.sh: first fenced block after '## Prompt template'."""
    lines = (REPO / "prompts" / f"{recipe}.md").read_text().splitlines()
    out, inside, fenced = [], False, False
    for line in lines:
        if not inside:
            inside = line.startswith("## Prompt template")
            continue
        if line.startswith("```"):
            if fenced:
                break
            fenced = True
            continue
        if fenced:
            out.append(line)
    return "\n".join(out)


def optional_inputs(recipe):
    """Names declared `key: string?` in the recipe frontmatter."""
    text = (REPO / "prompts" / f"{recipe}.md").read_text()
    fm = text.split("---", 2)[1]
    return set(re.findall(r"^\s+(\w+): string\?", fm, re.M))


def render(case):
    tpl = template(case["recipe"])
    values = {"stdin": case["stdin"], **case.get("vars", {})}
    for key in optional_inputs(case["recipe"]):
        values.setdefault(key, "")
    for key, val in values.items():
        tpl = tpl.replace("{{" + key + "}}", val)
    missing = re.findall(r"{{(\w+)}}", tpl)
    if missing:
        raise ValueError(f"unsubstituted placeholders {missing} in case {case['id']}")
    return tpl


def chat(messages, model=DEFAULT_MODEL, base=MLX, temperature=0, max_tokens=2048, think=False, **extra):
    body = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": think},
        **extra,
    }
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=900) as resp:
        data = json.load(resp)
    msg = data["choices"][0]["message"]
    return {
        "content": (msg.get("content") or "").strip(),
        "tool_calls": msg.get("tool_calls"),
        "usage": data.get("usage", {}),
        "ms": int((time.time() - t0) * 1000),
    }


def save_result(arm, case, output, extra=None):
    RESULTS.mkdir(parents=True, exist_ok=True)
    row = {"arm": arm, "id": case["id"], "recipe": case["recipe"], "output": output, **(extra or {})}
    with (RESULTS / f"{arm}.jsonl").open("a") as fh:
        fh.write(json.dumps(row) + "\n")
    return row


def load_results(arm):
    path = RESULTS / f"{arm}.jsonl"
    if not path.exists():
        return {}
    rows = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    return {r["id"]: r for r in rows}  # last write wins
