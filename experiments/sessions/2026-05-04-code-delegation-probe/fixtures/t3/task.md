The module `source.py` has two functions. Two tests fail:

1. `clamp(value, lo, hi)` currently accepts inverted bounds (`lo > hi`). `test_clamp_inverted_bounds_raises` expects it to raise `ValueError` when `lo > hi`. Add that check at the top of `clamp`.

2. `normalise_range(lo, hi)` currently returns the arguments unchanged. `test_normalise_range_orders_ascending` expects `(min(lo, hi), max(lo, hi))`. Fix the function to return the two values in ascending order.

Do not add new imports.
