#!/usr/bin/env python3
"""Score v6 (discipline-not-size probe) and compare against v5 (qwen3-coder-next 5/5)."""
from __future__ import annotations

import json
import re
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).parent
RUNS = ROOT / "v6-runs"

GT = {"F1": "medium", "F2": "medium", "F3": "low", "F4": "low", "F5": "info"}
MODELS = [
    ("coder-next", "51"),
    ("coder-30b", "32"),
    ("deepseek-r1-32b", "19"),
    ("phi4-reasoning", "11"),
    ("gemma4", "9.6"),
]


def parse(text):
    text = text.strip()
    # Models like phi4-reasoning emit <think>...</think> blocks inline despite
    # think:false (their reasoning is in-band tagged tokens, not a separate
    # channel). Strip the think block before scanning for JSON.
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    # Strip markdown fences if present
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    # Find the LAST JSON array in the cleaned text (post-thinking models put
    # the answer at the end). Walk balanced brackets right-to-left.
    last = text.rfind("]")
    if last == -1:
        return None
    # Find matching `[` for this `]`.
    depth = 0
    for i in range(last, -1, -1):
        if text[i] == "]":
            depth += 1
        elif text[i] == "[":
            depth -= 1
            if depth == 0:
                candidate = text[i:last + 1]
                try:
                    return json.loads(candidate)
                except json.JSONDecodeError:
                    return None
    return None


def score(arr):
    if not isinstance(arr, list):
        return 0
    return sum(1 for o in arr if isinstance(o, dict) and o.get("severity") == GT.get(o.get("id")))


def main():
    print(f"{'model':<20}{'size':<8}{'r1':<6}{'r2':<6}{'r3':<6}{'mean':<8}{'verdict'}")
    rows = []
    for label, size in MODELS:
        scores = []
        details = []
        for rep in [1, 2, 3]:
            f = RUNS / f"{label}-r{rep}.txt"
            if not f.exists() or f.stat().st_size == 0:
                scores.append(None)
                details.append("MISSING")
                continue
            text = f.read_text(errors="replace")
            arr = parse(text)
            if arr is None:
                scores.append(None)
                details.append("PARSE")
            else:
                s = score(arr)
                scores.append(s)
                details.append(f"{s}/5")
        nums = [s for s in scores if s is not None]
        m = mean(nums) if nums else 0
        if m == 5.0:
            verdict = "PARITY (matches Opus)"
        elif m >= 4.0:
            verdict = "near-parity"
        elif m >= 3.0:
            verdict = "partial (CVSS-conservative)"
        elif m >= 1.0:
            verdict = "low signal"
        else:
            verdict = "format-failure"
        print(f"{label:<20}{size:<8}{details[0]:<6}{details[1]:<6}{details[2]:<6}{m:<8.2f}{verdict}")
        rows.append((label, size, scores, m))

    out = ROOT / "v6-scores.tsv"
    with out.open("w") as f:
        f.write("model\tsize_gb\tr1\tr2\tr3\tmean\n")
        for label, size, scores, m in rows:
            r = [str(s) if s is not None else "PARSE" for s in scores]
            f.write(f"{label}\t{size}\t{r[0]}\t{r[1]}\t{r[2]}\t{m:.2f}\n")
    print(f"\n[wrote {out}]")


if __name__ == "__main__":
    main()
