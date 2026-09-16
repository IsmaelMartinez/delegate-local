"""Deterministic scorers for one candidate reply against a real case (throwaway).

Each scorer mirrors a rule the reply recipes state (context echo, length
ratio, stated-not-asked, no-fact-drop, no invented values, list shape) and
uses the reply the maintainer actually shipped as the reference where the
rule needs one. `ship` is the heuristic conjunction; the per-rule columns are
what to read.
"""
import difflib
import re

SENT_SPLIT = re.compile(r"(?<=[.!?])\s+|\n+")
FILLER = re.compile(r"\b(great work|awesome|nice job|thanks for this|here'?s the reply)\b", re.I)
INSTRUCTION_ECHO = re.compile(
    r"\b(ask (them|the (author|reporter|contributor)) to|they should|the (reporter|author|contributor) needs to)\b", re.I
)
PARTICIPIAL_TAIL = re.compile(
    r",\s*(ensuring|allowing|making|enabling|providing|reflecting|leading to|supported by)\b[^.?!]*[.!]?\s*$", re.I
)
NUMBERED = re.compile(r"^\s*\d+[.)]\s", re.M)
ANCHOR = re.compile(
    r"#\d+"  # issue / PR refs
    r"|\b[\w./-]+\.\w+:\d+\b"  # file:line
    r"|\b[\w-]+\.(?:py|js|ts|sh|md|toml|json|ya?ml|go|c|h|txt)\b"  # file names
    r"|\b\d{2,}\b"  # numbers
    r"|\b[A-Za-z]+_[A-Za-z_]+\b"  # snake_case identifiers
    r"|\b[a-z]+[A-Z][A-Za-z]+\b"  # camelCase identifiers
)


def normalise(s):
    return re.sub(r"\s+", " ", s or "").strip().lower()


def sentences(text, floor=40):
    return {normalise(x) for x in SENT_SPLIT.split(text or "") if len(normalise(x)) >= floor}


def echo_count(context, output):
    out = normalise(output)
    return sum(1 for s in sentences(context) if s in out)


def anchors(text):
    return {a.strip("`") for a in ANCHOR.findall(text or "")}


def word_limit(ask):
    m = re.search(r"\b(?:under|max(?:imum)?|at most|no more than)\s+(\d+)\s+words", ask or "", re.I)
    return int(m.group(1)) if m else None


def score(case, output):
    stdin = case["stdin"]
    vars_ = case.get("vars", {})
    final = case.get("final")
    inputs = stdin + "\n" + "\n".join(vars_.values())
    out = output or ""
    ctx_chars = len(stdin)
    ratio = round(len(out) / ctx_chars, 2) if ctx_chars else None
    echo = echo_count(stdin, out)
    src = anchors(inputs)
    required = (src & anchors(final)) if final else src
    kept = len(required & anchors(out)) / len(required) if required else None
    invented = sorted(a for a in anchors(out) - src if re.fullmatch(r"#\d+|\d{2,}", a))
    questions = out.count("?")
    if final is not None:
        expected_q = final.count("?")
    else:
        expected_q = 0 if not vars_.get("ask", "").strip() else None
    limit = word_limit(vars_.get("ask"))
    words = len(out.split())
    r = {
        "chars": len(out),
        "ratio": ratio,
        "echo": echo,
        "anchors_kept": round(kept, 2) if kept is not None else None,
        "invented": invented,
        "questions": questions,
        "expected_q": expected_q,
        "numbered": bool(NUMBERED.search(out)),
        "final_numbered": bool(NUMBERED.search(final)) if final else None,
        "words": words,
        "word_limit": limit,
        "filler": bool(FILLER.search(out)),
        "instruction_echo": bool(INSTRUCTION_ECHO.search(out)),
        "participial_tail": bool(PARTICIPIAL_TAIL.search(out)),
        "similarity": round(difflib.SequenceMatcher(None, normalise(final), normalise(out)).ratio(), 2) if final else None,
    }
    fails = []
    if echo >= 2:
        fails.append("echo")
    if ctx_chars >= 400 and ratio is not None and ratio >= 0.8:
        fails.append("ratio")
    if expected_q is not None and questions != expected_q:
        fails.append("questions")
    if invented:
        fails.append("invented")
    if kept is not None and kept < 0.75:
        fails.append("anchors")
    if r["final_numbered"] is not None and r["numbered"] != r["final_numbered"]:
        fails.append("shape")
    if limit and words > limit * 1.1:
        fails.append("length")
    if r["filler"] or r["instruction_echo"] or r["participial_tail"]:
        fails.append("style")
    if not out.strip():
        fails.append("empty")
    r["fails"] = fails
    r["ship"] = not fails
    # the two length rules are stricter than what the maintainer ships (6 of 21
    # shipped finals fail one of them), so also report a pass that ignores them
    r["ship_core"] = not [f for f in fails if f not in ("length", "ratio")]
    return r


if __name__ == "__main__":
    from common import load_cases

    # Sanity: score the stored drafts and the shipped finals. Finals should pass.
    for case in load_cases():
        d = score(case, case["draft"])
        f = score(case, case["final"]) if case.get("final") else None
        print(
            case["id"], case["recipe"][:18], case.get("verdict"),
            "draft:", "ship" if d["ship"] else ",".join(d["fails"]),
            "| final:", ("ship" if f["ship"] else ",".join(f["fails"])) if f else "-",
        )
