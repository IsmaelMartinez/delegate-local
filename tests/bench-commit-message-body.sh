#!/usr/bin/env bash
# Commit-message body-drop regression benchmark. Drives delegate.sh --recipe auto
# with a REAL diff on stdin (the production path) and scores with the exact
# body_required logic. Reps add no signal under MLX greedy determinism (ADR 0018);
# diversity comes from fixtures. Usage:
#   [BENCH_BACKENDS="mlx ollama"] [BENCH_GATE=1] bash tests/bench-commit-message-body.sh
set -uo pipefail
SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DELEGATE="$SKILL_DIR/scripts/delegate.sh"; PICK="$SKILL_DIR/scripts/pick-model.sh"
FIX_DIR="$SKILL_DIR/tests/fixtures/commit-message"
BACKENDS="${BENCH_BACKENDS:-mlx ollama}"; RC="$(cat "$FIX_DIR/recent_commits.txt")"
fail=0

# Exact mirror of delegate.sh body_required (delegate.sh:1373): the same
# `tr -d '\r' | awk 'NF { n++ } END { print n + 0 }'` non-empty-line count and
# the same `< 2` -> fail threshold.
score_body() { local n; n=$(printf '%s\n' "$1" | tr -d '\r' | awk 'NF { n++ } END { print n + 0 }'); (( n >= 2 )); }

for backend in $BACKENDS; do
  model="$(DELEGATE_BACKEND="$backend" bash "$PICK" prose 2>/dev/null || echo '?')"
  # Warm the model once so a cold-load canary doesn't poison the first score.
  printf 'warmup' | DELEGATE_BACKEND="$backend" DELEGATE_LOCAL_NO_METRICS=1 \
    DELEGATE_PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-90}" \
    bash "$DELEGATE" prose "ok" >/dev/null 2>&1 || true
  drops=0; errors=0; total=0
  for d in "$FIX_DIR"/*.diff; do
    base="$(basename "$d" .diff)"; why="$(cat "${d%.diff}.why")"; total=$((total+1))
    err_log=$(mktemp)
    out="$(DELEGATE_BACKEND="$backend" DELEGATE_LOCAL_NO_METRICS=1 \
           DELEGATE_PREFLIGHT_TIMEOUT="${DELEGATE_PREFLIGHT_TIMEOUT:-90}" \
           bash "$DELEGATE" --recipe auto --var why="$why" --var recent_commits="$RC" \
             prose "Write the commit message." < "$d" 2>"$err_log")"; rc=$?
    if (( rc != 0 )) || [[ -z "$out" ]]; then
      res=ERROR; errors=$((errors+1))
      # An ERROR makes the run inconclusive — surface the captured stderr so the
      # cause (timeout, cold-load, connection) is visible instead of swallowed.
      [[ -s "$err_log" ]] && { echo "--- stderr for $base ($backend) ---" >&2; cat "$err_log" >&2; }
    elif score_body "$out"; then res=BODY
    else res=DROP; drops=$((drops+1)); fi
    rm -f "$err_log"
    printf '%s\t%s\t%s\tresult=%s\n' "$backend" "$model" "$base" "$res"
    [[ "${BENCH_GATE:-0}" == 1 && "$res" != BODY ]] && fail=1
  done
  printf '# %s (%s): drops=%d errors=%d total=%d\n' "$backend" "$model" "$drops" "$errors" "$total"
done
exit "$fail"
