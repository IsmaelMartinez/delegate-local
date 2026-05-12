#!/usr/bin/env bash
# Run the full baseline matrix (multiple models × 6 fixture tasks × N reps)
# under a single regime — sequential, one model resident at a time, cold
# between models so timing comparisons are FS-cache-fair.
#
# Usage: run-baseline.sh [--backend ollama|mlx] [--reps N] [--t3-snapshot DATE] [--no-stop] <model> [<model>...]
#
# --backend ollama|mlx (default ollama) which local backend to target. Forwarded
#                     to runner.sh. The cold-start mechanism differs per
#                     backend: ollama -> `ollama stop <model>` between models;
#                     mlx -> the mlx_lm.server holds one model resident at a
#                     time and re-loads on the first request to a new model
#                     id, so the equivalent of `ollama stop` happens
#                     implicitly via the next request's model field.
# --reps N            (default 3) reps per task per model.
# --t3-snapshot DATE  (default 2026-04-28) which T3 fixture to use.
# --no-stop           skip the `ollama stop` between models. Useful when one
#                     model is already loaded and you want to keep it warm
#                     for back-to-back reps; default is to stop between
#                     models so timing comparisons are FS-cache-fair. No-op
#                     when --backend mlx (the mlx server has no equivalent
#                     idle-eviction command).
#
# Output: one raw file per model under experiments/results/raw/<slug>.txt
# (each containing N reps of all 6 tasks, written by experiments/runner.sh).
#
# This script never pulls models. If a named ollama model is not in
# `ollama list`, it is skipped with a warning so the baseline keeps moving.
# Under --backend mlx the model-presence check is delegated to runner.sh's
# downstream HTTP call (the MLX server returns a model-not-found error which
# surfaces as a non-zero curl exit and a metrics row tagged exit_status>0).

set -euo pipefail

backend="ollama"
ollama_api=0
reps=3
t3_snapshot="2026-04-28"
do_stop=1

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --backend)
      backend="${2:-}"
      case "$backend" in
        ollama|mlx) ;;
        *) echo "--backend requires ollama|mlx, got '$backend'" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --ollama-api) ollama_api=1; shift ;;
    --reps) reps="${2:-}"; shift 2 ;;
    --t3-snapshot) t3_snapshot="${2:-}"; shift 2 ;;
    --no-stop) do_stop=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if (( $# < 1 )); then
  echo "usage: run-baseline.sh [--backend ollama|mlx] [--ollama-api] [--reps N] [--t3-snapshot DATE] [--no-stop] <model> [<model>...]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$repo_root/experiments/runner.sh"

installed=""
if [[ "$backend" == "ollama" ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    echo "ollama not on PATH" >&2
    exit 1
  fi
  installed=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')
fi

baseline_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "baseline run started: $baseline_started"
echo "backend: $backend"
echo "reps per task: $reps"
echo "T3 snapshot: $t3_snapshot"
echo "stop-between-models: $do_stop"
echo

for model in "$@"; do
  if [[ "$backend" == "ollama" ]]; then
    # Exact-line match — `grep -F` substring alone would match `phi` against
    # `phi4-reasoning:plus`. `-x` requires the whole line to match the model name.
    if ! grep -qxF -- "$model" <<<"$installed"; then
      echo "[skip] $model not installed; skipping" >&2
      continue
    fi
  fi

  echo "=== running $model ==="
  runner_args=(--backend "$backend" --reps "$reps" --t3-snapshot "$t3_snapshot")
  (( ollama_api )) && runner_args+=(--ollama-api)
  bash "$runner" "${runner_args[@]}" "$model"

  if [[ "$backend" == "ollama" ]] && (( do_stop )); then
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
