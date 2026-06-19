---
inputs:
  source: string
  test: string
  why: string?
---
# fix-with-test

## When to use

The director has a single source file plus a pytest that currently fails, and wants a minimal patch that makes the test pass. The failing test is the oracle: the patch is verified by re-running it, never trusted on the model's say-so. Scope is one file. Multi-file edits, cross-module reasoning, and tests the director cannot re-run are out of scope — those stay with the director.

## Context to gather first

```bash
cat path/to/source.py        # the file to patch
cat path/to/test_source.py   # the failing test (the oracle)
python3 -m pytest -q path/to/test_source.py   # confirm it fails first
```

The failing test is load-bearing — without a test the director can re-run, this recipe does not apply.

## Prompt template

```
Produce a minimal patch to the source file below so the failing test passes. Change only what the test requires. Do not rewrite unrelated code, rename symbols, reformat, or add features the test does not exercise.

Output format — non-negotiable:
Emit one or more SEARCH/REPLACE blocks and NOTHING else. No prose, no explanation, no markdown code fence. Each block is exactly:
<<<<<<< SEARCH
<lines copied VERBATIM from the source, enough to match exactly once>
=======
<the replacement lines>
>>>>>>> REPLACE

The SEARCH text must be copied character-for-character from the source, including indentation, and must appear exactly once. If it would match more than once, include more surrounding lines so it is unique.

Example (illustrative — use the real source below, not this):
<<<<<<< SEARCH
def total(items):
    return sum(items)
=======
def total(items):
    return sum(items) if items else 0
>>>>>>> REPLACE

If the test is wrong, self-contradictory, or cannot be satisfied by editing this one file, do NOT invent a patch. Emit a single line instead:
REFUSE: <one sentence on why the test cannot be honestly satisfied>

=== Source file ===
{{source}}

=== Failing test ===
{{test}}

=== Why / intent (optional) ===
{{why}}
```

## Variables

- `{{source}}` — verbatim contents of the file to patch.
- `{{test}}` — verbatim contents of the failing pytest.
- `{{why}}` — OPTIONAL one-sentence intent. Omit to let the test speak for itself; `delegate.sh` collapses the empty placeholder.

## Invocation

```bash
bash scripts/delegate.sh --recipe fix-with-test \
  --var source="$(cat source.py)" \
  --var test="$(cat test_source.py)" \
  code "Output ONLY SEARCH/REPLACE blocks (or a single REFUSE: line). Minimal diff."
```

In practice the `fanout-patch.sh` orchestrator wires these for you across N seeds; this direct form is for one-off use.

## Expected output shape

One or more `<<<<<<< SEARCH … ======= … >>>>>>> REPLACE` blocks with no surrounding prose or fence, OR a single `REFUSE: …` line. Verify by piping the output to `apply-and-test.sh` and reading the `VERDICT:` — a patch is only HIT if the oracle returns `PASS`.

## Anti-hallucination guards (each line addresses a real failure mode)

- "Change only what the test requires … do not rewrite unrelated code" — small models over-edit, rewriting whole functions when a one-line fix suffices; the oracle's smallest-diff tie-break rewards the minimal patch.
- "No prose, no explanation, no markdown code fence" — a wrapping fence or a "Here's the fix:" preamble corrupts the SEARCH block so `apply-and-test.sh` returns APPLY/PARSE instead of PASS.
- "copied character-for-character … must appear exactly once" — `apply-and-test.sh` does literal-substring matching and treats >1 match as APPLY (ambiguous); the guard pushes the model to include unique context.
- "REFUSE: …" hatch — when the test is wrong, a fabricated patch wastes an escalation; the oracle and orchestrator treat a majority REFUSE as a signal the test may be broken.

## Calibration notes

New recipe (2026-06-19), shipped with the code-gen fan-out initiative. Unlike the prose recipes it has a hard oracle (the test), so its calibration loop is the `experiments/fanout-patch-eval.sh` pass-rate measurement rather than hit/miss verdicts. The output is code, not prose, so no `checks:` block (the padding/subject guards do not apply). Future guards land here as `fanout-patch-eval.sh` surfaces recurring patch-format failures.
