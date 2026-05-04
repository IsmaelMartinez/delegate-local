def paginate(items, page, page_size):
    if page_size <= 0:
        raise ValueError("page_size must be positive")
    start = page * page_size
    end = start + page_size
    return items[start:end]
