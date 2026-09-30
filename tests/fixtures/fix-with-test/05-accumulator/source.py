def running_max(xs):
    out = []
    for x in xs:
        cur = x
        out.append(max(cur, x))
    return out
