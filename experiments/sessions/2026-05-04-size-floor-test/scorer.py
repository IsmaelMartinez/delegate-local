#!/usr/bin/env python3
"""Score the size-floor test (deepseek-r1:14b) using the same ground truth
and parser as scorer-v6 in the sibling 2026-05-03-smaller-model-test session.
Reuses the v5 prompt's severity enum so results are directly comparable to
the v6 baseline in that session.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from statistics import mean, stdev

ROOT = Path(__file__).parent
RUNS = ROOT / "size-floor-runs"

GT = {"F1": "medium", "F2": "medium", "F3": "low", "F4": "low", "F5": "info"}

MODELS = [("deepseek-r1-14b", "9.0")]
REPS = [1, 2, 3]


def parse(text: str):
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


def score_arr(arr):
    if not isinstance(arr, list):
        return 0
    return sum(
        1 for o in arr
        if isinstance(o, dict)
        and o.get("id") in GT
        and o.get("severity") == GT[o["id"]]
    )


def main():
    print(f"{'model':<20}{'size':<8}{'r1':<6}{'r2':<6}{'r3':<6}{'mean':<8}{'stdev':<8}{'verdict'}")
    for label, size in MODELS:
        scores = []
        labels = []
        for rep in REPS:
            f = RUNS / f"{label}-r{rep}.txt"
            if not f.exists() or f.stat().st_size == 0:
                labels.append("MISSING")
                continue
            arr = parse(f.read_text(errors="replace"))
            if arr is None:
                labels.append("PARSE")
                continue
            n = score_arr(arr)
            scores.append(n)
            labels.append(f"{n}/5")
        while len(labels) < 3:
            labels.append("-")
        if scores:
            mn = mean(scores)
            sd = stdev(scores) if len(scores) > 1 else 0.0
        else:
            mn, sd = 0.0, 0.0
        if mn == 5.0:
            verdict = "PARITY (Opus-grade)"
        elif mn >= 4.0:
            verdict = f"near-parity ({mn:.2f}/5)"
        elif mn >= 3.0:
            verdict = f"partial ({mn:.2f}/5)"
        else:
            verdict = f"broken ({mn:.2f}/5)"
        print(f"{label:<20}{size:<8}{labels[0]:<6}{labels[1]:<6}{labels[2]:<6}{mn:<8.2f}{sd:<8.2f}{verdict}")


if __name__ == "__main__":
    main()
