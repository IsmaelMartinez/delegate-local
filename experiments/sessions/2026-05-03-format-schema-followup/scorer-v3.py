#!/usr/bin/env python3
"""Score v3-runs/ and compare against v2 from the parent retrospective dir.

Tests the hypothesis: does Ollama format:schema constrained decoding close
the severity-calibration gap that was the only remaining failure in v2?
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from statistics import mean, stdev

ROOT = Path(__file__).parent
RUNS = ROOT / "v3-runs"

GT_ST1 = {"F1": "medium", "F2": "medium", "F3": "low", "F4": "low", "F5": "info"}
GT_ST2 = {"F1": ("REAL", None), "F2": ("REAL", None), "F3": ("REAL", None),
          "F4": ("REAL", None), "F5": ("REAL", None)}
ST3_PATHS = {"F1": "scripts/pick-model.sh", "F2": "scripts/pick-model.sh",
             "F3": "scripts/init.sh", "F4": "scripts/init.sh",
             "F5": "scripts/pick-model.sh"}
IDS = ["F1", "F2", "F3", "F4", "F5"]


def parse(text):
    """v3 output is pure JSON (schema-enforced). Just json.loads."""
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def score_st1(arr):
    if not isinstance(arr, list):
        return 0
    # Guard: require known id before comparing severity. Without this, a
    # malformed `{}` dict makes both sides None and `None == None` counts
    # as a match. (Same fix Gemini applied to scorer-v6.py on PR #27.)
    return sum(1 for o in arr if isinstance(o, dict) and o.get("id") in GT_ST1 and o.get("severity") == GT_ST1[o["id"]])


def score_st2(arr):
    if not isinstance(arr, list):
        return 0
    matches = 0
    for o in arr:
        if not isinstance(o, dict):
            continue
        gt = GT_ST2.get(o.get("id"))
        if gt is None:
            continue
        if o.get("classification") == gt[0] and o.get("matched_allowlist") == gt[1]:
            matches += 1
    return matches


def score_st3(arr):
    if not isinstance(arr, list):
        return 0
    valid = 0
    for o in arr:
        if not isinstance(o, dict):
            continue
        prose = o.get("prose")
        path = ST3_PATHS.get(o.get("id"))
        if not isinstance(prose, str) or not path:
            continue
        if 80 <= len(prose) <= 800 and path in prose:
            valid += 1
    return valid


def score_st4(text):
    has_all = all(re.search(rf"\b{i}\b", text) for i in IDS)
    has_fx = bool(re.search(r"\bFX\b", text))
    return "PASS" if has_all and not has_fx else "FAIL"


def main():
    rows = []
    for model in ["qwen3.6", "coder-next"]:
        for st in [1, 2, 3, 4]:
            for rep in [1, 2, 3]:
                f = RUNS / f"{model}-st{st}-r{rep}.txt"
                if not f.exists() or f.stat().st_size == 0:
                    rows.append((model, st, rep, "NO_OUTPUT"))
                    continue
                text = f.read_text(errors="replace")
                if st == 4:
                    rows.append((model, st, rep, score_st4(text)))
                else:
                    arr = parse(text)
                    if arr is None:
                        rows.append((model, st, rep, "PARSE_FAIL"))
                    else:
                        s = {1: score_st1, 2: score_st2, 3: score_st3}[st](arr)
                        rows.append((model, st, rep, f"{s}/5"))

    print("=== v3 per-cell scores ===")
    print(f"{'model':<12}{'st':<4}{'rep':<5}{'score'}")
    for r in rows:
        print(f"{r[0]:<12}{r[1]:<4}{r[2]:<5}{r[3]}")

    print()
    print("=== v3 vs v2 aggregate (mean across 3 reps) ===")
    print(f"{'model':<12}{'st':<6}{'v2 mean':<10}{'v3 mean':<10}{'delta'}")

    v2_means = {
        ("qwen3.6", 1): 2.00, ("qwen3.6", 2): 5.00, ("qwen3.6", 3): 5.00,
        ("coder-next", 1): 3.00, ("coder-next", 2): 5.00, ("coder-next", 3): 5.00,
    }

    for model in ["qwen3.6", "coder-next"]:
        for st in [1, 2, 3]:
            scores = [r[3] for r in rows if r[0] == model and r[1] == st]
            nums = []
            for s in scores:
                m = re.match(r"(\d+)/5", s) if isinstance(s, str) else None
                if m:
                    nums.append(int(m.group(1)))
            v3 = mean(nums) if nums else 0
            v2 = v2_means.get((model, st), float("nan"))
            delta = v3 - v2
            sign = "+" if delta > 0 else ""
            print(f"{model:<12}st{st:<5}{v2:<10.2f}{v3:<10.2f}{sign}{delta:.2f}")
        s4 = [r[3] for r in rows if r[0] == model and r[1] == 4]
        pass_rate = sum(1 for s in s4 if s == "PASS") / max(len(s4), 1)
        print(f"{model:<12}st4    {'PASS':<10}{pass_rate:<10.2f}{'-'}")

    out_path = ROOT / "v3-scores.tsv"
    with out_path.open("w") as f:
        f.write("model\tsubtask\trep\tscore\n")
        for r in rows:
            f.write(f"{r[0]}\t{r[1]}\t{r[2]}\t{r[3]}\n")
    print(f"\n[wrote {out_path}]")


if __name__ == "__main__":
    main()
