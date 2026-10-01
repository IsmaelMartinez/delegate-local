# Calibration history for [`prompts/fix-with-test.md`](../../prompts/fix-with-test.md)

> 2026-10-01: `experiments/fanout-patch-eval.sh`, named below, was archived out of `main` in 22395b2. The current oracle is `scripts/apply-and-test.sh` run against the fixtures in `tests/fixtures/fix-with-test/`, which `tests/test-fix-with-test-fixtures.sh` keeps honest. The entry below is kept as written.

## Calibration notes

New recipe (2026-06-19), shipped with the code-gen fan-out initiative. Unlike the prose recipes it has a hard oracle (the test), so its calibration loop is the `experiments/fanout-patch-eval.sh` pass-rate measurement rather than hit/miss verdicts. The output is code, not prose, so no `checks:` block (the padding/subject guards do not apply). Future guards land here as `fanout-patch-eval.sh` surfaces recurring patch-format failures.
