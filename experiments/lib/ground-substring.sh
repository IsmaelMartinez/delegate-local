#!/usr/bin/env bash
# ground-substring.sh — the single shared quote-verification helper for the
# ground-check recipe. Sourced by BOTH experiments/score-t9.sh and
# scripts/ground-check.sh so the substring / normalisation / MINLEN rule is
# byte-identical across the scorer and the runtime wrapper (the parity
# guarantee tests/test-score-t9.sh asserts — see plan §3.1, §6(g)).
#
# The lever (see prompts/ground-check.md): a local model is forced to QUOTE
# verbatim rather than JUDGE. This helper is the deterministic second line —
# it verifies a quoted span is an exact substring of the evidence, so a
# fabricated quote can be downgraded to UNVERIFIED. It guarantees zero
# fabricated-quote SUPPORTED; it does NOT guarantee the quote is relevant to
# the claim (a true-but-irrelevant span passes — that residual gap is closed
# by the scorer's VERDICT_MATCH check, not here).
#
# Algorithm (literal, metacharacter-safe):
#   1. Normalise quote and evidence identically: curly quotes → straight,
#      collapse every run of whitespace (incl. newlines) to one space, strip
#      leading/trailing space. The symmetric whitespace-collapse lets a quote
#      spanning a hard line-wrap in the evidence still verify (no false
#      UNVERIFIED alarm).
#   2. Reject quotes shorter than GROUND_MINLEN normalised characters (cuts
#      coincidental short matches like a bare `200`). NOT a relevance check.
#   3. `grep -F` literal containment (NOT bash case-glob: `[ ] * ?` are common
#      in diffs/logs and a glob would silently mis-match).

# Guard against double-sourcing (mirrors scripts/lib/otel.sh).
[ -n "${_GROUND_SUBSTRING_LIB_LOADED:-}" ] && return 0
_GROUND_SUBSTRING_LIB_LOADED=1

# Minimum normalised-quote length in characters. Overridable for calibration.
: "${GROUND_MINLEN:=8}"

# ground_normalize  —  reads text on stdin, writes the normalised form to
# stdout. Used on both the quote and the evidence before comparison so the
# rule is symmetric.
ground_normalize() {
  perl -CSD -0777 -pe '
    tr/\x{2018}\x{2019}\x{201c}\x{201d}/\x{27}\x{27}\x{22}\x{22}/;
    s/\s+/ /g;
    s/^ //;
    s/ $//;
  '
}

# ground_quote_verifies <quote> <evidence-file>
#   exit 0 — the normalised quote is a literal substring of the normalised
#            evidence and meets the MINLEN floor (verified).
#   exit 1 — the quote is NOT a substring of the evidence (fabricated).
#   exit 2 — the quote is shorter than GROUND_MINLEN (coincidental-token floor).
# Callers downgrade a SUPPORTED/CONTRADICTED verdict to UNVERIFIED on exit 1
# or 2; the scorer additionally records exit 2 with a MINLEN note.
ground_quote_verifies() {
  local quote="$1" evidence_file="$2"
  local nq ne
  nq=$(printf '%s' "$quote" | ground_normalize)
  if [ "${#nq}" -lt "$GROUND_MINLEN" ]; then
    return 2
  fi
  ne=$(ground_normalize < "$evidence_file")
  if printf '%s' "$ne" | grep -F -q -- "$nq"; then
    return 0
  fi
  return 1
}
