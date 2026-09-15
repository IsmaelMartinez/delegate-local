#!/usr/bin/env bash
# Rank files by cosine similarity to a query embedding, so the agent need not
# read every file to find the one that covers X. bash + jq only: embeddings
# come from embed.sh, cosine is a jq dot product after L2 normalisation.
#
# Usage:
#   semantic-search.sh [--top K] <query> <file> [<file>...]
#
# Output: one line per file, `<score> <path>`, sorted descending; --top K
#         limits to K rows (default 5). Missing or empty files warn on stderr
#         and are dropped rather than killing the search.
#
# Env: inherits everything embed.sh honours.

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

# Validated first, before the embedding cost is sunk.
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

# Embed the query once; failure is fatal.
query_vec=$(printf '%s' "$query" | bash "$embed")
if [[ -z "$query_vec" ]]; then
  echo "semantic-search: failed to embed query" >&2
  exit 1
fi

# dot(a,b) / (||a|| * ||b||): normalised defensively in case a future model
# swap does not return unit vectors. `--argjson` hands jq real arrays.
cosine_sim() {
  local a="$1" b="$2"
  jq -nr --argjson a "$a" --argjson b "$b" '
    def norm(v): (v | map(. * .) | add) | sqrt;
    def dot(x; y): [range(0; x | length) | x[.] * y[.]] | add;
    (dot($a; $b)) / ((norm($a)) * (norm($b)))
  '
}

# A bash array keeps the accumulator O(N) on large file sets.
results=()
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
  # %.6f keeps the output stable across systems and locales.
  printf -v score_fmt '%.6f' "$score"
  results+=("${score_fmt} ${f}")
done

if (( ${#results[@]} == 0 )); then
  echo 'semantic-search: no files produced a usable embedding' >&2
  exit 1
fi

# LC_ALL=C keeps the sort locale-stable across macOS and Linux.
printf '%s\n' "${results[@]}" | LC_ALL=C sort -k1,1 -gr | head -n "$top_k"
