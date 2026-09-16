"""Aggregate every arm's outputs against the deterministic scorers (throwaway).

Usage: python3 report.py [arm ...]   (default: every results/*.jsonl)
Prints one markdown table per recipe plus a per-case grid of pass/fail marks.
"""
import json
import statistics
import sys
from collections import Counter

from common import RESULTS, load_cases, load_results
from score import score


def summarise(arm, cases, rows):
    scored = [(c, score(c, rows[c["id"]]["output"])) for c in cases if c["id"] in rows]
    if not scored:
        return None
    n = len(scored)
    fails = Counter(f for _, s in scored for f in s["fails"])
    ms = [rows[c["id"]].get("ms") for c, _ in scored if rows[c["id"]].get("ms")]
    reqs = [rows[c["id"]].get("requests") for c, _ in scored if rows[c["id"]].get("requests")]
    sims = [s["similarity"] for _, s in scored if s["similarity"] is not None]
    kept = [s["anchors_kept"] for _, s in scored if s["anchors_kept"] is not None]
    return {
        "arm": arm, "n": n,
        "ship": sum(1 for _, s in scored if s["ship"]),
        "core": sum(1 for _, s in scored if s["ship_core"]),
        "echo": fails["echo"], "ratio": fails["ratio"], "questions": fails["questions"],
        "invented": fails["invented"], "anchors": fails["anchors"], "shape": fails["shape"],
        "length": fails["length"], "style": fails["style"], "empty": fails["empty"],
        "anchors_kept": round(statistics.mean(kept), 2) if kept else None,
        "similarity": round(statistics.mean(sims), 2) if sims else None,
        "p50_ms": int(statistics.median(ms)) if ms else None,
        "req": round(statistics.mean(reqs), 2) if reqs else None,
    }


def table(rows):
    cols = ["arm", "n", "ship", "core", "echo", "ratio", "questions", "invented", "anchors", "shape", "length", "style",
            "empty", "anchors_kept", "similarity", "p50_ms", "req"]
    out = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        out.append("| " + " | ".join(str(r[c]) for c in cols) + " |")
    return "\n".join(out)


if __name__ == "__main__":
    arms = sys.argv[1:] or sorted(p.stem for p in RESULTS.glob("*.jsonl"))
    cases = load_cases()
    for recipe in sorted({c["recipe"] for c in cases}):
        subset = [c for c in cases if c["recipe"] == recipe]
        print(f"\n### {recipe} (n={len(subset)})\n")
        rows = [summarise(a, subset, load_results(a)) for a in arms]
        rows = [r for r in rows if r]
        # the stored draft (what the wrapper produced at the time) and the shipped final as reference rows
        rows.insert(0, summarise("stored-draft", subset, {c["id"]: {"output": c["draft"]} for c in subset}))
        finals = {c["id"]: {"output": c["final"]} for c in subset if c.get("final")}
        if finals:
            rows.insert(1, summarise("shipped-final", subset, finals))
        print(table(rows))
        print("\nper-case (ship=. fail=first letters of failed rules):\n")
        print("| id | verdict | " + " | ".join(a for a in arms) + " |")
        print("|---|---|" + "---|" * len(arms))
        for c in subset:
            marks = []
            for a in arms:
                r = load_results(a).get(c["id"])
                if not r:
                    marks.append("-")
                    continue
                s = score(c, r["output"])
                marks.append("." if s["ship"] else ",".join(f[:3] for f in s["fails"]))
            print(f"| {c['id'][:8]} | {c.get('verdict')} | " + " | ".join(marks) + " |")
