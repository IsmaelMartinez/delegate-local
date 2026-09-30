def flatten(xs):
    out = []
    for x in xs:
        if isinstance(x, list):
            out += x
        else:
            out.append(x)
    return out
