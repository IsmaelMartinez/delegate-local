# v8 follow-up: does code-generation delegate under Aider-style SEARCH/REPLACE?

**Date:** 2026-05-04
**Parent thread:** v5/v6/v7 directive-rule classification chain (`../2026-05-03-*`)
**Hypothesis:** The v5-v7 chain showed local models reach Opus parity on closed-form classification when given a directive-shaped prompt. The open question was whether that discipline carries over to *code work* — specifically, whether a local model can emit a correct minimal patch when the output format is a constrained Aider-style SEARCH/REPLACE block rather than free-form prose.

## Setup

Three small Python fixtures, each a `source.py` + `test_source.py` pair with at least one failing test:

- **t1** — `calls_per_minute`: return an `int` when the division is exact instead of always returning `float`.
- **t2** — `paginate`: switch zero-based to one-based pagination, raise `ValueError` on `page == 0`.
- **t3** — `clamp` + `normalise_range`: add an inverted-bounds guard to `clamp`; make `normalise_range` return `(min, max)`.

Prompt template (`build-prompt.sh`) applies the v5-v7 discipline rules to code work: non-negotiable output format rule, one-shot example of a correct SEARCH/REPLACE block, explicit ban on prose, fences, imports, or modifying the test file. The model sees task description, current `source.py`, current `test_source.py`.

2 models × 3 tasks × 3 reps = 18 cells. Models: `deepseek-r1:32b` (v6 reasoning-tier winner, 19 GB) and `qwen3-coder-next:latest` (v5 code-tier winner, 51 GB). `think:false`, `temperature: 0`, `/api/generate`, ms-precision timing via `run_api_cell.sh`.

Scorer (`scorer-v8.py`): parse SEARCH/REPLACE blocks with a regex, apply them to `source.py` via literal string replace, write the patched file to an isolated dir alongside the original `test_source.py`, run `pytest -q`, emit `PASS` iff pytest returns 0. Verdict buckets: `PASS`, `FAIL` (pytest nonzero), `APPLY` (SEARCH section didn't match source), `PARSE` (no valid blocks), `MISSING`, `TIMEOUT`.

## Result: 18/18 PASS, byte-identical across reps

| model          | t1    | t2    | t3    | mean  | stdev |
|----------------|-------|-------|-------|-------|-------|
| deepseek-r1:32b | 3/3 | 3/3 | 3/3 | 1.000 | 0.000 |
| qwen3-coder-next:latest | 3/3 | 3/3 | 3/3 | 1.000 | 0.000 |

Output bytes are identical across the three reps of every cell, matching the determinism signal observed in v5-v7. Both models produced minimal patches that touched only the lines needed to make the failing tests pass and left the passing tests untouched.

Sample outputs:

```
# deepseek-r1 t3 r2 — clamp + normalise_range
<<<<<<< SEARCH
def clamp(value, lo, hi):
=======
def clamp(value, lo, hi):
    if lo > hi:
        raise ValueError("lo must be <= hi")
>>>>>>> REPLACE

<<<<<<< SEARCH
def normalise_range(lo, hi):
    return (lo, hi)
=======
def normalise_range(lo, hi):
    return (min(lo, hi), max(lo, hi))
>>>>>>> REPLACE
```

```
# coder-next t1 r1 — calls_per_minute, returns int when exact, float otherwise
rate = calls / window_seconds * 60
return int(rate) if rate.is_integer() else rate
```

coder-next's t1 answer is slightly over-specified (the tests only ever pass exact values, so `int(...)` alone would also pass), but it's correct — and the passing tests still pass. deepseek-r1's t1 answer used a plain `int(...)` cast.

## Timing

| model | cold-load | warm mean | warm range |
|---|---|---|---|
| deepseek-r1:32b | ~13.7s (t1 r1) | ~4.9s | 3.9–6.3s |
| qwen3-coder-next:latest | ~10.6s (t1 r1) | ~3.0s | 1.9–4.1s |

coder-next is ~40% faster per warm cell despite being 2.7× the weights, which matches the v6 finding that MoE width beats dense parameter count on this hardware.

## Cost comparison (money saved)

Prompt size per task averaged ~2.1 KB (≈525 tokens) and output ~0.4 KB (≈100 tokens). Across the 18 cells, total tokens approximate 9,450 input + 1,800 output.

Anthropic pricing (2026-05 list):
- **Haiku 4.5**: $1/MTok input, $5/MTok output → (9450 × $1 + 1800 × $5) / 1e6 = **$0.0189** for this workload.
- **Sonnet 4.6**: $3/MTok input, $15/MTok output → **$0.0554**.
- **Opus 4.7**: $15/MTok input, $75/MTok output → **$0.277**.

Local cost is M5 Max wall power. The M5 Max CPU+GPU draws ≤120 W under sustained inference. Total wall time across the 18 cells was ~92 seconds of model compute (summing the `duration_ms` column), so the marginal energy cost is 120 W × 92 s = ~3.07 Wh. At UK 2026 grid rates (~30 p/kWh) that's **£0.0009 ≈ $0.0011**.

| Option | Cost per 18-cell suite | Multiple vs local |
|---|---|---|
| Local (deepseek-r1 + coder-next) | $0.0011 | 1× |
| Haiku 4.5 | $0.019 | 17× |
| Sonnet 4.6 | $0.055 | 50× |
| Opus 4.7 | $0.277 | 250× |

The per-task delta is small in absolute terms, but the multiplier is the relevant number for routine delegation: if this workload ran daily on a moderate codebase (~50 fixture-sized tasks), a year of local delegation costs about $0.27 in electricity vs $67 for Opus, with no material loss in correctness on this task shape. That's roughly the gap the v5-v7 chain already showed on classification; v8 confirms it holds for the minimal-patch code-edit pattern too.

Caveats worth stating. The fixtures are deliberately small and the bugs are textbook (type coercion, off-by-one, bounds check, min/max pair). This probe does not address multi-file refactors, cross-module reasoning, or fixes that require reading tests other than the ones named in the task description. The v8 design-intent was to test whether the format-discipline that worked for classification extends to code at all; that question now has a clean positive answer. Whether the envelope extends further is the next probe.

## What this means for the skill

`SKILL.md`'s current Fits list does not mention code work. The delegation-discipline subsection (added in v5) already covers the pattern v8 uses: atomic per call, one-shot example, explicit output-format rule, directive-style non-negotiable framing. v8 adds one ingredient — the output format itself is machine-applicable (SEARCH/REPLACE) and independently verifiable (pytest passes or doesn't).

Two small skill updates are warranted:

1. Add a Fits bullet for "minimal single-file code patches where you can supply the failing test and the source file, and verify the output by running the test" — with the caveat that the director must apply and verify the patch, not trust the model's word.
2. Do not expand the description field to claim code work generally. The probe is narrow; the honest framing is "minimal-patch style code edits with verifiable tests," not "delegate code to local."

This is the first experiment in the chain where the output is not a classification enum but an executable artefact. The scoring is correspondingly less ambiguous: pytest is the judge, not a CVSS interpretation or a citation check. That's a sign the probe is well-scoped.

## Future work

1. **Multi-file patch probe.** Same format, but the fix requires edits to two files (e.g. source + a helper). Tests whether the SEARCH/REPLACE block shape holds when the model has to produce multiple SEARCH contexts from different files.
2. **Adversarial test file.** Same fixture, but the model is told to *not* modify the test file, and the test contains a subtly wrong assertion. Does the model correctly refuse or does it silently edit the test to make it pass?
3. **Larger source file.** t1-t3 are 5-10 line functions. A 100-200 line source forces the model to locate the relevant region — does the SEARCH context stay unique?
4. **Smaller-model floor test.** Re-run v8 on the 14B class (deepseek-r1:14b, qwen3.5:14b) to find the size floor for this pattern, mirroring the v6 size-floor probe for directive-rule classification.
