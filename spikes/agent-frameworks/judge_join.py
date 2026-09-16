"""Join the blind grades back to arms and print per-arm grade distributions (throwaway).

Usage: python3 judge_join.py <pack_dir>
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

from common import load_cases

if __name__ == "__main__":
    d = Path(sys.argv[1])
    key = json.loads((d.parent / f"{d.name}-key.json").read_text())
    grades = json.loads((d / "_grades.json").read_text())
    recipe_of = {c["id"]: c["recipe"] for c in load_cases()}
    per = defaultdict(lambda: defaultdict(list))
    for cid, letters in grades.items():
        for letter, g in letters.items():
            arm = key.get(cid, {}).get(letter)
            if arm:
                per[recipe_of[cid]][arm].append(int(g))
    for recipe, arms in per.items():
        print(f"\n### grades: {recipe}\n")
        print("| arm | n | mean | 5 (ship) | 4 | 3 | 2 | 1 | ship-or-4 |")
        print("|---|---|---|---|---|---|---|---|---|")
        for arm in sorted(arms):
            g = arms[arm]
            c = {k: g.count(k) for k in (5, 4, 3, 2, 1)}
            print(f"| {arm} | {len(g)} | {statistics.mean(g):.2f} | {c[5]} | {c[4]} | {c[3]} | {c[2]} | {c[1]} | "
                  f"{(c[5] + c[4]) / len(g):.0%} |")
