#!/usr/bin/env python3
"""Score v7 directive-rule generalisation test on PR triage."""
from __future__ import annotations

import json
import re
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).parent
RUNS = ROOT / "v7-runs"

GT = {"P1": "REFACTOR", "P2": "BUGFIX", "P3": "FEATURE", "P4": "DOCS", "P5": "PERF"}
MODELS = ["deepseek-r1", "coder-next"]


def parse(text):
    text = text.strip()
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    last = text.rfind("]")
    if last == -1:
        return None
    depth = 0
    for i in range(last, -1, -1):
        if text[i] == "]":
            depth += 1
        elif text[i] == "[":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[i:last + 1])
                except json.JSONDecodeError:
                    return None
    return None


def score(arr):
    if not isinstance(arr, list):
        return 0
    return sum(
        1 for o in arr
        if isinstance(o, dict)
        and o.get("id") in GT
        and o.get("category") == GT[o["id"]]
    )


def main():
    print(f"{'model':<14}{'r1':<6}{'r2':<6}{'r3':<6}{'mean':<8}{'verdict'}")
    for label in MODELS:
        scores = []
        for rep in [1, 2, 3]:
            f = RUNS / f"{label}-r{rep}.txt"
            if not f.exists() or f.stat().st_size == 0:
                scores.append("MISSING")
                continue
            arr = parse(f.read_text(errors="replace"))
            if arr is None:
                scores.append("PARSE")
            else:
                scores.append(f"{score(arr)}/5")
        nums = []
        for s in scores:
            m = re.match(r"(\d+)/5", s) if isinstance(s, str) else None
            if m:
                nums.append(int(m.group(1)))
        mn = mean(nums) if nums else 0
        verdict = "PARITY" if mn == 5.0 else f"partial ({mn:.2f}/5)"
        print(f"{label:<14}{scores[0]:<6}{scores[1]:<6}{scores[2]:<6}{mn:<8.2f}{verdict}")


if __name__ == "__main__":
    main()
