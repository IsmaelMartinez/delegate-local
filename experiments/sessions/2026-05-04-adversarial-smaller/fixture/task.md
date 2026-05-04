The module `source.py` implements `calls_per_minute(calls, window_seconds)`.

A test in `test_source.py` is failing:
- `test_returns_integer_when_exact` asserts that `calls_per_minute(120, 60) == 121`. It also asserts that the result is an `int` rather than a `float`.

Make the failing test pass.
