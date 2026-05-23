#!/usr/bin/env bash
# Rank files by cosine similarity to a query embedding. Useful primitive
# for "find the runbook that mentions X" / "which doc covers Y" — the
# pattern the agent today solves by reading every file. Per-call saving
# is high: every file the agent doesn't have to read is 1–20 KB of
# Sonnet input avoided.
#
# Usage:
#   semantic-search.sh [--top K] <query> <file> [<file>...]
#
# Output: one line per file, `<score> <path>`, sorted descending by score.
#         --top K limits to K rows (default 5).
#
# Implementation: bash + jq. Each input embedding (query + each file) is
# fetched via scripts/embed.sh; cosine similarity is computed by jq as a
# dot product after defensive L2 normalisation. Keeps the "two bash
# scripts" architecture invariant — no python/numpy dependency.
#
# Skipped files (missing or empty) emit a stderr warning and are dropped
# from the output, so a glob that picks up a deleted or unreadable path
# doesn't kill the whole search.
#
# Env: inherits everything embed.sh honours (DELEGATE_BACKEND, OLLAMA_HOST,
#      DELEGATE_TO_OLLAMA_NO_METRICS, DELEGATE_METRICS_FILE).

set -uo pipefail

top_k=5
positional=()
while (($# > 0)); do
  case "$1" in
    --top)
      if [[ $# -lt 2 ]]; then
        echo 'semantic-search: --top requires a value' >&2; exit 2
      fi
      top_k="$2"; shift 2;;
    --top=*)
      top_k="${1#--top=}"; shift;;
    -h|--help)
      echo 'usage: semantic-search.sh [--top K] <query> <file> [<file>...]' >&2
      exit 0;;
    *)
      positional+=("$1"); shift;;
  esac
done

# Validate --top before anything else so a non-numeric value fails fast
# rather than after the embedding cost is sunk.
if ! [[ "$top_k" =~ ^[0-9]+$ ]] || (( top_k == 0 )); then
  echo "semantic-search: --top must be a positive integer (got '$top_k')" >&2
  exit 2
fi

if (( ${#positional[@]} < 2 )); then
  echo 'usage: semantic-search.sh [--top K] <query> <file> [<file>...]' >&2
  exit 2
fi

query="${positional[0]}"
files=("${positional[@]:1}")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
embed="$script_dir/embed.sh"

# Embed the query once. Failure here is fatal — without the query vector
# the whole script is meaningless.
query_vec=$(printf '%s' "$query" | bash "$embed")
if [[ -z "$query_vec" ]]; then
  echo "semantic-search: failed to embed query" >&2
  exit 1
fi

# Cosine similarity over two equal-length JSON arrays of floats. Computed
# as dot(a,b) / (||a|| * ||b||) — defensive even though nomic-embed-text
# already returns L2-normalised vectors per Ollama docs, in case a future
# model swap (bge-large) does not. jq has no fma so the sum-of-products
# is a one-liner; the norm is sqrt(sum of squares).
#
# `--argjson` parses both arrays as JSON values, so the jq program sees
# real arrays (not strings) and the arithmetic is direct.
cosine_sim() {
  local a="$1" b="$2"
  jq -nr --argjson a "$a" --argjson b "$b" '
    def norm(v): (v | map(. * .) | add) | sqrt;
    def dot(x; y): [range(0; x | length) | x[.] * y[.]] | add;
    (dot($a; $b)) / ((norm($a)) * (norm($b)))
  '
}

# Score each file. Missing or empty files get a stderr warning and are
# skipped rather than killing the whole search.
results=""
for f in "${files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "semantic-search: skipping '$f' (file not found)" >&2
    continue
  fi
  if [[ ! -s "$f" ]]; then
    echo "semantic-search: skipping '$f' (empty file)" >&2
    continue
  fi
  doc_vec=$(bash "$embed" < "$f")
  if [[ -z "$doc_vec" ]]; then
    echo "semantic-search: skipping '$f' (embedding failed)" >&2
    continue
  fi
  score=$(cosine_sim "$query_vec" "$doc_vec")
  # printf with %.6f keeps the output stable across systems (jq's default
  # is ~17 sig figs which is overkill and varies with locale).
  printf -v score_fmt '%.6f' "$score"
  results="${results}${score_fmt} ${f}"$'\n'
done

if [[ -z "$results" ]]; then
  echo 'semantic-search: no files produced a usable embedding' >&2
  exit 1
fi

# Sort descending by score (LC_ALL=C keeps the locale-stable behaviour the
# test suite expects across macOS and Linux) and take the top K.
printf '%s' "$results" | LC_ALL=C sort -k1,1 -gr | head -n "$top_k"
