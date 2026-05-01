#!/usr/bin/env bash
# Run the full baseline matrix (multiple models × 3 fixture tasks × N reps)
# under a single regime — sequential, one model resident at a time, with
# `ollama stop` between models so each starts cold.
#
# Usage: run-baseline.sh [--reps N] [--t3-snapshot DATE] [--no-stop] <model> [<model>...]
#
# --reps N            (default 3) reps per task per model.
# --t3-snapshot DATE  (default 2026-04-28) which T3 fixture to use.
# --no-stop           skip the `ollama stop` between models. Useful when one
#                     model is already loaded and you want to keep it warm
#                     for back-to-back reps; default is to stop between
#                     models so timing comparisons are FS-cache-fair.
#
# Output: one raw file per model under experiments/results/raw/<slug>.txt
# (each containing N reps of all 3 tasks, written by experiments/runner.sh).
#
# This script never pulls models. If a named model is not in `ollama list`,
# it is skipped with a warning so the baseline keeps moving.

set -euo pipefail

reps=3
t3_snapshot="2026-04-28"
do_stop=1

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --reps) reps="${2:-}"; shift 2 ;;
    --t3-snapshot) t3_snapshot="${2:-}"; shift 2 ;;
    --no-stop) do_stop=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if (( $# < 1 )); then
  echo "usage: run-baseline.sh [--reps N] [--t3-snapshot DATE] [--no-stop] <model> [<model>...]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$repo_root/experiments/runner.sh"

if ! command -v ollama >/dev/null 2>&1; then
  echo "ollama not on PATH" >&2
  exit 1
fi

installed=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')

baseline_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "baseline run started: $baseline_started"
echo "reps per task: $reps"
echo "T3 snapshot: $t3_snapshot"
echo "stop-between-models: $do_stop"
echo

for model in "$@"; do
  # Exact-line match — `grep -F` substring alone would match `phi` against
  # `phi4-reasoning:plus`. `-x` requires the whole line to match the model name.
  if ! grep -qxF -- "$model" <<<"$installed"; then
    echo "[skip] $model not installed; skipping" >&2
    continue
  fi

  echo "=== running $model ==="
  bash "$runner" --reps "$reps" --t3-snapshot "$t3_snapshot" "$model"

  if (( do_stop )); then
    echo "stopping $model to clear VRAM before next model..."
    ollama stop "$model" 2>/dev/null || true
    # Brief pause so the runtime fully releases GPU memory before the next load.
    sleep 2
  fi
  echo
done

baseline_finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "baseline run finished: $baseline_finished"
echo "raw outputs: $repo_root/experiments/results/raw/"
