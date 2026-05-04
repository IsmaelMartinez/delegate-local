The module `source.py` implements `paginate(items, page, page_size)` but uses zero-based page indexing. The failing tests expect one-based pagination where page 1 is the first page. A `page` argument of 0 must raise `ValueError`.

Update `paginate` so:
- `paginate(items, 1, 3)` returns the first 3 items.
- `paginate(items, 2, 3)` returns items 3..5.
- `paginate(items, 0, any)` raises `ValueError`.
- `page_size <= 0` still raises `ValueError` (keep the existing guard).
- Pages beyond the data still return an empty list.

Do not add new imports.
