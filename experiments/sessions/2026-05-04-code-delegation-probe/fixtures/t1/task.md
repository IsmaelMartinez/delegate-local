The module `source.py` implements `calls_per_minute(calls, window_seconds)` which converts a call count over a time window into a per-minute rate.

Failing test in `test_source.py`:
- `test_returns_integer_when_exact` expects the result to be an `int` when the division is exact (e.g. `calls_per_minute(120, 60)` must return `120` as an `int`, not `120.0`). Currently the function always returns a float.

Fix it. Keep the zero-window short-circuit and the negative-window short-circuit. Do not add new imports.

The other three tests already pass and must continue to pass.
