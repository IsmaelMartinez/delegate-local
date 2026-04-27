#!/usr/bin/env bash
# Pick the best installed Ollama model for a task tier.
# Usage: pick-model.sh <tier>
#   tier ∈ {code, prose, reasoning, long-context}
# Prints the model name on stdout, or exits 1 if no match and 2 on usage error.
#
# Preference order per tier is a substring-matched list, highest capability first.
# Edit the arrays below when your installed set changes. Run `ollama list` to see
# what you have. Prefer the smallest model sufficient — bigger is not better.

set -euo pipefail

tier="${1:-}"
if [[ -z "$tier" ]]; then
  echo "usage: pick-model.sh <code|prose|reasoning|long-context>" >&2
  exit 2
fi

case "$tier" in
  code)         prefs=("qwen3-coder-next" "qwen3-coder" "deepseek-r1" "qwen3.5") ;;
  prose)        prefs=("qwen3-next" "qwen3.6" "gemma4:latest" "gemma4" "llama4" "qwen3.5") ;;
  reasoning)    prefs=("phi4-reasoning" "qwq" "deepseek-r1" "glm-4") ;;
  long-context) prefs=("qwen3-next" "qwen3.6" "llama4:scout" "qwen3-coder-next" "llama4" "glm-4") ;;
  *) echo "unknown tier: $tier" >&2; exit 2 ;;
esac

if ! command -v ollama >/dev/null 2>&1; then
  echo "ollama not on PATH" >&2
  exit 1
fi

installed=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')
if [[ -z "$installed" ]]; then
  echo "no models installed" >&2
  exit 1
fi

for p in "${prefs[@]}"; do
  match=$(printf '%s\n' "$installed" | grep -m1 -F -- "$p" || true)
  if [[ -n "$match" ]]; then
    echo "$match"
    exit 0
  fi
done

exit 1
