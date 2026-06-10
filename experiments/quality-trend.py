#!/usr/bin/env python3
"""Weekly recipe-quality trend over the delegate-local metrics JSONL.

This is the reproducible method behind `experiments/results/<date>-quality-trend.md`.
It reads the hit/miss verdict feedback rows (the calibration signal) and the
delegation rows from the metrics file and prints four views:

  1. a weekly HIT-rate line chart   — output kept verbatim = HIT, the quality signal;
  2. weekly delegation volume        — so each HIT-rate point can be weighted by sample size;
  3. per-recipe HIT rate             — where quality is strong (input-digestion recipes)
                                       vs weak (taste-calibrated prose recipes);
  4. a lifetime summary              — overall hit rate plus verdict coverage.

Re-run it as data accumulates to augment the trend; when the picture shifts,
drop a new dated `experiments/results/<date>-quality-trend.md` writeup that
embeds the fresh charts and the interpretation. Verdicts are attributed to the
delegation time (`ref_ts`) so quality lands in the week the work happened, not
the week it was scored.

Usage:
  python3 experiments/quality-trend.py [METRICS_JSONL]

METRICS_JSONL defaults to $DELEGATE_METRICS_FILE, else
~/.claude/skills/delegate-local/metrics.jsonl (where delegate.sh appends).
Stdlib only — no third-party dependencies, in keeping with the repo's
portability rule.
"""
import json
import os
import sys
import datetime as dt
from collections import defaultdict

MIN_RECIPE_VERDICTS = 5  # don't report a recipe's hit rate below this sample size


def load_rows(path):
    rows = []
    # Explicit utf-8: metrics carry arbitrary commit/PR text, and the default
    # encoding is not utf-8 on every platform.
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue  # tolerate a partially-written trailing line
    return rows


def week_of(ts):
    """The Monday of the ISO week containing the YYYY-MM-DD prefix of ts, or
    None if ts is missing/malformed — tolerated the same way load_rows tolerates
    a bad JSON line, so one corrupt row can't crash the whole rollup."""
    try:
        d = dt.datetime.strptime((ts or "")[:10], "%Y-%m-%d").date()
    except (ValueError, TypeError):
        return None
    return (d - dt.timedelta(days=d.weekday())).isoformat()


def render_trend(series):
    """series: list of (week, volume, verdicts, hits, hit_pct_or_None)."""
    lo, hi, height, colspace = 50, 100, 11, 8
    width = len(series) * colspace
    grid = [[" "] * width for _ in range(height)]

    def row(pct):
        pct = max(lo, min(hi, pct))  # clamp: a sub-50% week pins to the floor, not off-grid
        return height - 1 - round((pct - lo) / (hi - lo) * (height - 1))

    pts = [(i * colspace + 1, row(s[4])) for i, s in enumerate(series) if s[4] is not None]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):  # interpolate the connecting line
        steps = x1 - x0
        for s in range(steps + 1):
            x = x0 + s
            y = round(y0 + (y1 - y0) * s / steps)
            if 0 <= y < height and 0 <= x < width and grid[y][x] == " ":
                grid[y][x] = "·"
    for x, y in pts:
        grid[y][x] = "●"

    out = ["", "  delegate-local — weekly recipe quality (HIT-rate of recorded verdicts)", ""]
    for r in range(height):
        pct = hi - round(r / (height - 1) * (hi - lo))
        label = f"{pct:3d}% ┤" if pct % 10 == 0 else "     │"
        out.append("  " + label + "".join(grid[r]))
    out.append("       └" + "─" * width)
    out.append("      " + "".join(s[0][5:].ljust(colspace) for s in series))
    out.append("  n=  " + "".join(str(s[2]).ljust(colspace) for s in series) + "  verdicts/wk")
    out.append("  hit=" + "".join((f"{s[4]}%" if s[4] is not None else "-").ljust(colspace) for s in series))
    return "\n".join(out)


def render_volume(series):
    out = ["", "  weekly delegation volume", ""]
    mx = max((s[1] for s in series), default=1) or 1
    for w, vol, *_ in series:
        out.append(f"  {w[5:]} │{'█' * round(40 * vol / mx)} {vol}")
    return "\n".join(out)


def render_recipes(rec_h, rec_m):
    out = ["", f"  per-recipe quality (recorded verdicts, recipes with >= {MIN_RECIPE_VERDICTS})", "",
           f"  {'recipe':<30}{'n':>4}{'hit%':>6}   bar"]
    recipes = sorted(set(rec_h) | set(rec_m), key=lambda k: -(rec_h[k] + rec_m[k]))
    for k in recipes:
        n = rec_h[k] + rec_m[k]
        if n < MIN_RECIPE_VERDICTS:
            continue
        hr = 100 * rec_h[k] / n
        filled = round(20 * hr / 100)
        out.append(f"  {k:<30}{n:>4}{hr:>5.0f}%   {'▰' * filled}{'▱' * (20 - filled)}")
    return "\n".join(out)


def main(argv):
    default = os.environ.get("DELEGATE_METRICS_FILE") or os.path.expanduser(
        "~/.claude/skills/delegate-local/metrics.jsonl")
    path = argv[1] if len(argv) > 1 else default
    if not os.path.exists(path):
        print(f"quality-trend: metrics file not found at {path}", file=sys.stderr)
        return 1

    rows = load_rows(path)
    deleg = [r for r in rows if r.get("source") == "delegate"]
    feedback = [r for r in rows if r.get("source") == "feedback"]
    if not feedback:
        print("quality-trend: no feedback rows yet — record verdicts with "
              "scripts/delegate-feedback.sh hit|miss", file=sys.stderr)
        return 1

    by_ts = {r.get("ts"): r for r in deleg if r.get("ts")}
    vol = defaultdict(int)
    hits = defaultdict(int)
    miss = defaultdict(int)
    rec_h = defaultdict(int)
    rec_m = defaultdict(int)

    for r in deleg:
        w = week_of(r.get("ts"))
        if w:
            vol[w] += 1
    for r in feedback:
        w = week_of(r.get("ref_ts") or r.get("ts"))
        if not w:
            continue
        kept = r.get("kept") is True
        (hits if kept else miss)[w] += 1
        # ref_ts joins the verdict back to its delegation to recover the recipe.
        # A ref_ts that resolves to no delegate row (e.g. a trimmed metrics
        # file) is its own "(ref-not-found)" bucket rather than being silently
        # folded into the genuine-bare count. (Sub-second ts collisions can
        # still mis-credit a recipe — the join key is ts, not a row id — but
        # that is rare and structural to the feedback->delegate linkage.)
        deleg_row = by_ts.get(r.get("ref_ts"))
        if deleg_row is None:
            recipe = "(ref-not-found)"
        else:
            recipe = deleg_row.get("recipe") or "(bare/no-recipe)"
        (rec_h if kept else rec_m)[recipe] += 1

    weeks = sorted(set(vol) | set(hits) | set(miss))
    series = []
    for w in weeks:
        v = hits[w] + miss[w]
        series.append((w, vol[w], v, hits[w], round(100 * hits[w] / v) if v else None))

    print(render_trend(series))
    print(render_volume(series))
    print(render_recipes(rec_h, rec_m))

    total_hits = sum(hits.values())
    total_verdicts = total_hits + sum(miss.values())
    total_deleg = len(deleg)
    if not total_verdicts:
        print("quality-trend: no verdicts with a usable timestamp to summarise", file=sys.stderr)
        return 1
    hit_pct = 100 * total_hits / total_verdicts
    coverage = f"{100 * total_verdicts / total_deleg:.0f}% verdict coverage" if total_deleg else "coverage n/a (no delegation rows)"
    print(f"\nlifetime  {total_hits}/{total_verdicts} HIT = {hit_pct:.0f}%"
          f"   ·   {total_deleg} delegations   ·   {coverage}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
