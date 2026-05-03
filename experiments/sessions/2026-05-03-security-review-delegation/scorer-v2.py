#!/usr/bin/env python3
"""Robust scorer for v2-runs/. Extracts the LAST balanced JSON array from each
cell (handles ollama stream-rewrite duplicates), parses it, scores against
ground truth."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from statistics import mean, stdev

ROOT = Path(__file__).parent
RUNS = ROOT / "v2-runs"

GT_ST1 = {"F1": "medium", "F2": "medium", "F3": "low", "F4": "low", "F5": "info"}
GT_ST2 = {"F1": ("REAL", None), "F2": ("REAL", None), "F3": ("REAL", None),
          "F4": ("REAL", None), "F5": ("REAL", None)}
ST3_PATHS = {"F1": "scripts/pick-model.sh", "F2": "scripts/pick-model.sh",
             "F3": "scripts/init.sh", "F4": "scripts/init.sh",
             "F5": "scripts/pick-model.sh"}
IDS = ["F1", "F2", "F3", "F4", "F5"]

ANSI_RE = re.compile(r"\x1b\[[\?]?[0-9;]*[a-zA-Z]|\x1b\[[\?]?[0-9;]*[hl]")


def clean(text: str) -> str:
    return ANSI_RE.sub("", text).replace("\r", "")


def extract_last_json_array(text: str):
    """Find the last `[` ... `]` substring that parses as a JSON list. Walks
    each `]` from right to left; for each, tries every `[` left of it in
    right-to-left order. Handles ollama stream-rewrite duplication where the
    same array is partially re-emitted multiple times in the captured stream."""
    text = clean(text)
    rb_positions = [i for i, c in enumerate(text) if c == "]"]
    lb_positions = [i for i, c in enumerate(text) if c == "["]
    for rb in reversed(rb_positions):
        for lb in reversed([p for p in lb_positions if p < rb]):
            candidate = text[lb:rb + 1]
            try:
                val = json.loads(candidate)
                if isinstance(val, list) and val and all(isinstance(x, dict) for x in val):
                    return val
            except json.JSONDecodeError:
                continue
    return None


def score_st1(arr):
    if not arr:
        return 0, "PARSE_FAIL"
    matches = sum(1 for o in arr if isinstance(o, dict) and o.get("severity") == GT_ST1.get(o.get("id")))
    return matches, ""


def score_st2(arr):
    if not arr:
        return 0, "PARSE_FAIL"
    matches = 0
    inconsistent = 0
    for o in arr:
        if not isinstance(o, dict):
            continue
        gt = GT_ST2.get(o.get("id"))
        if gt is None:
            continue
        if o.get("classification") == gt[0] and o.get("matched_allowlist") == gt[1]:
            matches += 1
        if o.get("classification") == "ALLOWLISTED_FP" and o.get("matched_allowlist") in (None, "null", ""):
            inconsistent += 1
    note = f"inconsistent={inconsistent}" if inconsistent else ""
    return matches, note


def score_st3(arr):
    if not arr:
        return 0, "PARSE_FAIL"
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
    return valid, ""


def score_st4(text):
    text = clean(text)
    has_all = all(re.search(rf"\b{i}\b", text) for i in IDS)
    has_fx = bool(re.search(r"\bFX\b", text))
    if has_all and not has_fx:
        return "PASS", ""
    reasons = []
    if not has_all:
        reasons.append("MISSING_ID")
    if has_fx:
        reasons.append("FX_PLACEHOLDER")
    return "FAIL", " ".join(reasons)


def main():
    rows = []
    for model in ["qwen3.6", "coder-next"]:
        for st in [1, 2, 3, 4]:
            for rep in [1, 2, 3]:
                f = RUNS / f"{model}-st{st}-r{rep}.txt"
                if not f.exists() or f.stat().st_size == 0:
                    rows.append((model, st, rep, "NO_OUTPUT", ""))
                    continue
                text = f.read_text(errors="replace")
                if st == 4:
                    score, note = score_st4(text)
                    rows.append((model, st, rep, score, note))
                else:
                    arr = extract_last_json_array(text)
                    if st == 1:
                        s, n = score_st1(arr)
                    elif st == 2:
                        s, n = score_st2(arr)
                    else:
                        s, n = score_st3(arr)
                    rows.append((model, st, rep, f"{s}/5", n))

    print("=== Per-cell scores ===")
    print(f"{'model':<12}{'st':<4}{'rep':<5}{'score':<10}{'note'}")
    for r in rows:
        print(f"{r[0]:<12}{r[1]:<4}{r[2]:<5}{str(r[3]):<10}{r[4]}")

    print()
    print("=== Aggregate (mean ± stdev across 3 reps per cell) ===")
    print(f"{'model':<12}{'subtask':<10}{'mean':<8}{'stdev':<8}{'pass_rate'}")
    for model in ["qwen3.6", "coder-next"]:
        for st in [1, 2, 3, 4]:
            scores = [r[3] for r in rows if r[0] == model and r[1] == st]
            if st == 4:
                pass_rate = sum(1 for s in scores if s == "PASS") / len(scores)
                print(f"{model:<12}{f'st{st}':<10}{'-':<8}{'-':<8}{pass_rate:.2f}")
            else:
                nums = []
                for s in scores:
                    m = re.match(r"(\d+)/5", s) if isinstance(s, str) else None
                    if m:
                        nums.append(int(m.group(1)))
                if nums:
                    mn = mean(nums)
                    sd = stdev(nums) if len(nums) > 1 else 0
                    print(f"{model:<12}{f'st{st}':<10}{mn:<8.2f}{sd:<8.2f}{'-'}")
                else:
                    print(f"{model:<12}{f'st{st}':<10}{'PARSE':<8}{'FAIL':<8}{'-'}")

    out_path = ROOT / "v2-scores.tsv"
    with out_path.open("w") as f:
        f.write("model\tsubtask\trep\tscore\tnote\n")
        for r in rows:
            f.write(f"{r[0]}\t{r[1]}\t{r[2]}\t{r[3]}\t{r[4]}\n")
    print(f"\n[wrote {out_path}]")


if __name__ == "__main__":
    main()
