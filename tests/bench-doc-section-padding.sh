#!/usr/bin/env bash
# doc-section closing-recap / padding-tail regression benchmark. Drives
# `delegate.sh --recipe doc-section` over diverse fixtures and scores each
# paragraph for the two deterministic failure shapes the recipe is built to
# suppress: a trailing recap/participial padding clause, and a sentence-cap
# violation (HARD RULE 4). doc-section ships NO `checks:` block, so production
# enforces neither — this bench is the recipe's only regression coverage (the
# deterministic scorer its own "What's not yet measured" note deferred).
#
# The padding detector is EXTRACTED from the production `padding_re` in
# scripts/delegate.sh at runtime, not copied, so the bench can never drift from
# the production no_padding_tail logic. Reps add no signal under MLX greedy
# determinism (ADR 0018); diversity comes from fixtures. Usage:
#   [BENCH_BACKENDS="mlx ollama"] [BENCH_GATE=1] bash tests/bench-doc-section-padding.sh
set -uo pipefail
SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DELEGATE="$SKILL_DIR/scripts/delegate.sh"; PICK="$SKILL_DIR/scripts/pick-model.sh"
FIX_DIR="$SKILL_DIR/tests/fixtures/doc-section"
BACKENDS="${BENCH_BACKENDS:-mlx ollama}"
fail=0
# One temp file for the whole run, cleaned up on any exit (incl. interrupt) via
# the EXIT trap, instead of a mktemp/rm pair per fixture.
err_log=$(mktemp "${TMPDIR:-/tmp}/bench-docsec.XXXXXX") || { echo "bench: failed to create temp file" >&2; exit 2; }
trap 'rm -f "$err_log"' EXIT

# Single source of truth: pull the production padding regex straight out of
# delegate.sh so this bench detects exactly what no_padding_tail detects.
eval "$(grep -E '^[[:space:]]*padding_re=' "$DELEGATE" | head -1)"
[[ -n "${padding_re:-}" ]] || { echo "bench: could not extract padding_re from $DELEGATE" >&2; exit 2; }

# A trailing recap / participial-padding clause (production anchors the This-X /
# in-summary arm to a sentence boundary, so a recap final sentence matches).
has_padding() { printf '%s' "$1" | tr '\n' ' ' | grep -Eiq "$padding_re"; }
# Approximate sentence count: terminal . ! ? followed by whitespace or end.
count_sentences() { printf '%s' "$1" | tr '\n' ' ' | grep -oE '[.!?]+([[:space:]]|$)' | wc -l | tr -d ' '; }

for backend in $BACKENDS; do
  model="$(DELEGATE_BACKEND="$backend" bash "$PICK" prose 2>/dev/null || echo '?')"
  # Warm the model once so a cold-load canary doesn't poison the first score.
  printf 'warmup' | DELEGATE_BACKEND="$backend" DELEGATE_LOCAL_NO_METRICS=1 \
    DELEGATE_PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-90}" \
    bash "$DELEGATE" prose "ok" >/dev/null 2>&1 || true
  pads=0; caps=0; errors=0; total=0
  for f in "$FIX_DIR"/*.txt; do
    base="$(basename "$f" .txt)"; total=$((total+1))
    maxs=$(awk '/^max_sentences:/{sub(/^max_sentences:[[:space:]]*/,""); print; exit}' "$f")
    topic=$(awk '/^topic:/{sub(/^topic:[[:space:]]*/,""); print; exit}' "$f")
    facts=$(awk 'show{print} /^facts:[[:space:]]*$/{show=1}' "$f")
    out="$(DELEGATE_BACKEND="$backend" DELEGATE_LOCAL_NO_METRICS=1 \
           DELEGATE_PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-90}" \
           bash "$DELEGATE" --recipe doc-section \
             --var topic="$topic" --var facts="$facts" --var max_sentences="$maxs" \
             prose "Match a calm reference-doc voice. Stop after the substantive sentences." 2>"$err_log")"; rc=$?
    if (( rc != 0 )) || [[ -z "$out" ]]; then
      res=ERROR; errors=$((errors+1))
      # ERROR makes the run inconclusive — surface stderr instead of swallowing it.
      [[ -s "$err_log" ]] && { echo "--- stderr for $base ($backend) ---" >&2; cat "$err_log" >&2; }
    elif has_padding "$out"; then res=PAD; pads=$((pads+1))
    elif [[ "$(count_sentences "$out")" -gt "$maxs" ]]; then res=CAP; caps=$((caps+1))
    else res=OK; fi
    printf '%s\t%s\t%s\tresult=%s\n' "$backend" "$model" "$base" "$res"
    [[ "${BENCH_GATE:-0}" == 1 && "$res" != OK ]] && fail=1
  done
  printf '# %s (%s): pads=%d caps=%d errors=%d total=%d\n' "$backend" "$model" "$pads" "$caps" "$errors" "$total"
done
exit "$fail"
