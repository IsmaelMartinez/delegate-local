#!/usr/bin/env python3
"""Score v8 code-delegation probe.

For each cell:
  1. Parse SEARCH/REPLACE blocks from the model output.
  2. Apply them to the fixture's source.py in an isolated copy.
  3. Run pytest against the patched copy.
  4. Emit PASS if all tests pass, PARSE if no valid blocks, APPLY if a block's
     SEARCH section doesn't match, FAIL if pytest returns non-zero.

Prints per-cell verdicts, a per-(model, task) mean score (1.0 = all reps pass),
and a per-model aggregate. Also writes a machine-readable v8-scores.tsv.

apply_blocks rejects empty SEARCH sections and SEARCH sections that match more
than once in source.py — an ambiguous SEARCH returns the APPLY verdict rather
than silently patching the first hit. The SEARCH/REPLACE format expects the
model to include enough surrounding context for the match to be unique (that
rule is in build-prompt.sh's output rules), so ambiguity signals a prompt
compliance failure, not something the scorer should paper over.

Security note: this scorer executes model-generated Python via pytest on the
host, with no sandboxing. That is acceptable here because the operator chose
which Ollama models to run, the fixtures are author-written, and the prompt
rules forbid new imports. A contributor adapting this scorer for untrusted
model output, third-party fixtures, or shared CI runners should add sandboxing
(container, firejail, or `subprocess` with seccomp/resource caps) before
running. The Future Work section of RETROSPECTIVE.md tracks sandboxing as a
follow-up if the fixture surface grows.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from statistics import mean, stdev

PYTEST_PYTHON = os.environ.get("V8_PYTHON", sys.executable)

ROOT = Path(__file__).parent
RUNS = ROOT / "v8-runs"
FIXTURES = ROOT / "fixtures"
PATCHED = ROOT / "v8-patched"

MODELS = ["deepseek-r1", "coder-next"]
TASKS = ["t1", "t2", "t3"]
REPS = [1, 2, 3]

BLOCK_RE = re.compile(
    r"<{5,}\s*SEARCH\s*\n(.*?)\n={5,}\s*\n(.*?)\n>{5,}\s*REPLACE",
    re.DOTALL,
)


def parse_blocks(text: str):
    return [(m.group(1), m.group(2)) for m in BLOCK_RE.finditer(text)]


def apply_blocks(source: str, blocks):
    current = source
    for search, replace in blocks:
        if not search:
            return None, "empty SEARCH block"
        count = current.count(search)
        if count == 0:
            return None, f"SEARCH not found: {search[:60]!r}"
        if count > 1:
            return None, f"SEARCH is ambiguous ({count} matches): {search[:60]!r}"
        current = current.replace(search, replace)
    return current, None


def run_pytest(workdir: Path):
    result = subprocess.run(
        [PYTEST_PYTHON, "-m", "pytest", "-q", "--no-header", "test_source.py"],
        cwd=workdir,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.returncode, result.stdout + result.stderr


def score_cell(model: str, task: str, rep: int):
    out_file = RUNS / f"{model}-{task}-r{rep}.txt"
    if not out_file.exists() or out_file.stat().st_size == 0:
        return "MISSING", ""

    text = out_file.read_text(errors="replace")
    blocks = parse_blocks(text)
    if not blocks:
        return "PARSE", "no SEARCH/REPLACE blocks"

    src = (FIXTURES / task / "source.py").read_text()
    patched, err = apply_blocks(src, blocks)
    if patched is None:
        return "APPLY", err

    workdir = PATCHED / f"{model}-{task}-r{rep}"
    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "source.py").write_text(patched)
    shutil.copy(FIXTURES / task / "test_source.py", workdir / "test_source.py")

    try:
        code, log = run_pytest(workdir)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "pytest > 30s"
    return ("PASS" if code == 0 else "FAIL"), log.splitlines()[-1] if log else ""


def main():
    rows = []
    for model in MODELS:
        for task in TASKS:
            verdicts = []
            for rep in REPS:
                verdict, _ = score_cell(model, task, rep)
                rows.append((model, task, rep, verdict))
                verdicts.append(verdict)
            pass_count = sum(1 for v in verdicts if v == "PASS")
            rows.append((model, task, "agg", f"{pass_count}/{len(REPS)}"))

    print(f"{'model':<14}{'task':<6}{'rep':<6}{'verdict'}")
    for model, task, rep, verdict in rows:
        print(f"{model:<14}{task:<6}{str(rep):<6}{verdict}")

    print()
    print(f"{'model':<14}{'tasks passed (mean)':<22}{'stdev':<8}")
    for model in MODELS:
        task_rates = []
        for task in TASKS:
            passes = sum(
                1 for rep in REPS
                if next(
                    (v for m, t, r, v in rows
                     if m == model and t == task and r == rep),
                    "",
                ) == "PASS"
            )
            task_rates.append(passes / len(REPS))
        mn = mean(task_rates)
        sd = stdev(task_rates) if len(task_rates) > 1 else 0.0
        print(f"{model:<14}{mn:<22.3f}{sd:<8.3f}")

    tsv = ROOT / "v8-scores.tsv"
    with tsv.open("w") as f:
        f.write("model\ttask\trep\tverdict\n")
        for model, task, rep, verdict in rows:
            f.write(f"{model}\t{task}\t{rep}\t{verdict}\n")
    print(f"\n[scores written to {tsv.name}]")


def self_test():
    """Exercise parse_blocks and apply_blocks with synthetic inputs.

    Not wired into CI; run with `scorer-v8.py --self-test` before trusting the
    scorer on new fixtures. Covers the shapes that have actually shown up in
    model output (single block, multiple blocks, surrounding prose, missing
    SEARCH) plus the first-match documented limitation.
    """
    failures = []

    def check(name, cond, detail=""):
        if not cond:
            failures.append(f"{name}: {detail}")

    blocks = parse_blocks(
        "<<<<<<< SEARCH\nfoo\n=======\nbar\n>>>>>>> REPLACE\n"
    )
    check("single block parses", blocks == [("foo", "bar")], repr(blocks))

    blocks = parse_blocks(
        "<<<<<<< SEARCH\na\n=======\nA\n>>>>>>> REPLACE\n"
        "\n"
        "<<<<<<< SEARCH\nb\n=======\nB\n>>>>>>> REPLACE\n"
    )
    check("two blocks parse", blocks == [("a", "A"), ("b", "B")], repr(blocks))

    blocks = parse_blocks("hello world no blocks here")
    check("no blocks returns empty", blocks == [], repr(blocks))

    patched, err = apply_blocks("x = 1\ny = 2\n", [("y = 2", "y = 3")])
    check("apply replaces match", patched == "x = 1\ny = 3\n" and err is None,
          f"patched={patched!r} err={err!r}")

    patched, err = apply_blocks("x = 1\n", [("z = 9", "z = 10")])
    check("apply reports unmatched SEARCH",
          patched is None and err is not None and "not found" in err,
          f"patched={patched!r} err={err!r}")

    patched, err = apply_blocks("a\na\nb\n", [("a", "A")])
    check("apply rejects ambiguous SEARCH",
          patched is None and err is not None and "ambiguous" in err,
          f"patched={patched!r} err={err!r}")

    patched, err = apply_blocks("x = 1\n", [("", "z = 0\n")])
    check("apply rejects empty SEARCH",
          patched is None and err is not None and "empty" in err,
          f"patched={patched!r} err={err!r}")

    if failures:
        for f in failures:
            print(f"FAIL  {f}")
        sys.exit(1)
    print("self-test: all checks pass")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        main()
