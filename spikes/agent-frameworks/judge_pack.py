"""Build blind grading packs: per case, every arm's output shuffled under letters (throwaway).

The grader (a Claude subagent, not a local model, so the verdict is not the
weak-reasoner noise ADR 0030 warns about) sees the facts, the vars, the reply
the maintainer actually shipped, and the candidates A, B, C... without arm
names. It returns a 1-5 grade per letter; `judge_join.py` maps letters back.

Usage: python3 judge_pack.py <out_dir> [arm ...]
"""
import json
import random
import sys
from pathlib import Path

from common import RESULTS, load_cases, load_results

RUBRIC = """Grade each candidate reply 1-5 against the reference the maintainer actually posted:
5 = could be posted as-is in place of the reference: same facts, same asks, nothing invented, nothing that was supplied turned into a question, no fact line copied, same register and roughly the same length.
4 = one small edit away (a word, a dropped clause, a merged sentence).
3 = usable scaffold: right shape and most facts, but needs rewriting of a sentence or an ask.
2 = mostly rewrite: echoes the facts back, asks the reader to confirm what the facts state, invents an action or value, or misses the verdict.
1 = unusable or empty.
Grade the candidate on its own merits against the facts and the rules implied by the reference; the reference is the human's choice, not the only acceptable wording."""

if __name__ == "__main__":
    out_dir = Path(sys.argv[1])
    arms = sys.argv[2:] or sorted(p.stem for p in RESULTS.glob("*.jsonl"))
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20260915)
    key = {}
    for case in load_cases():
        if not case.get("final"):
            continue
        cands = []
        for arm in arms:
            r = load_results(arm).get(case["id"])
            if r is not None:
                cands.append((arm, r["output"]))
        cands.append(("stored-draft", case["draft"]))
        rng.shuffle(cands)
        letters = [chr(ord("A") + i) for i in range(len(cands))]
        key[case["id"]] = dict(zip(letters, [a for a, _ in cands]))
        pack = {
            "id": case["id"], "recipe": case["recipe"], "rubric": RUBRIC,
            "facts": case["stdin"], "vars": case.get("vars", {}),
            "reference": case["final"],
            "candidates": {l: t for l, (_, t) in zip(letters, cands)},
        }
        (out_dir / f"{case['id']}.json").write_text(json.dumps(pack, indent=1))
    # the key lives beside, not inside, the pack directory: the grader reads the directory blind
    key_path = out_dir.parent / f"{out_dir.name}-key.json"
    key_path.write_text(json.dumps(key, indent=1))
    print(f"{len(key)} packs in {out_dir}; key at {key_path}; grades go to {out_dir}/_grades.json as {{id: {{letter: grade}}}}")
