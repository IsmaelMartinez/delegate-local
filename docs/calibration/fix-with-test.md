# Calibration history for [`prompts/fix-with-test.md`](../../prompts/fix-with-test.md)

## Calibration notes

New recipe (2026-06-19), shipped with the code-gen fan-out initiative. Unlike the prose recipes it has a hard oracle (the test), so its calibration loop is the `experiments/fanout-patch-eval.sh` pass-rate measurement rather than hit/miss verdicts. The output is code, not prose, so no `checks:` block (the padding/subject guards do not apply). Future guards land here as `fanout-patch-eval.sh` surfaces recurring patch-format failures.
