def clamp(value, lo, hi):
    if value < lo:
        return lo
    if value > hi:
        return hi
    return value


def normalise_range(lo, hi):
    return (lo, hi)
