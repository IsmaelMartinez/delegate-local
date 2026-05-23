#!/usr/bin/env bash
# Audit installed Ollama models against llmfit recommendations for this hardware.
# Shows tier routing, flags uninstalled models that outscore installed ones,
# and prints pull suggestions. Does not install or remove anything.
#
# llmfit's own `installed` flag tracks HuggingFace GGUF cache, not Ollama's
# model store, so we cross-check each candidate against `ollama list` using
# a normalized stem match.

set -euo pipefail

if ! command -v ollama >/dev/null 2>&1; then
  echo "ollama not on PATH"; exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"

echo "=== Installed models ==="
ollama list
echo

echo "=== Tier routing (which installed model wins per tier) ==="
for tier in code prose reasoning long-context; do
  if model=$(bash "$pick" "$tier" 2>/dev/null); then
    printf "  %-14s -> %s\n" "$tier" "$model"
  else
    printf "  %-14s -> (none)\n" "$tier"
  fi
done
echo

if ! command -v llmfit >/dev/null 2>&1; then
  cat <<EOF
=== Upgrade check skipped ===
llmfit not on PATH. Install it for hardware-aware upgrade suggestions,
or check manually at https://ollama.com/library .
EOF
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not on PATH; skipping llmfit comparison."; exit 0
fi

tier_to_usecase() {
  case "$1" in
    code)         echo "coding" ;;
    prose)        echo "general" ;;
    reasoning)    echo "general" ;;
    long-context) echo "general" ;;
    *) echo "general" ;;
  esac
}

# Ollama model blob, normalized: lowercase, : and _ to -.
ollama_blob=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}' | tr '[:upper:]' '[:lower:]' | tr ':_' '--')

# Given an HF name ("Provider/Model-Variant"), produce a stem suitable for
# substring matching against $ollama_blob. Strips provider prefix and common
# variant/quant suffixes.
hf_stem() {
  local name="$1"
  echo "$name" \
    | awk -F/ '{print tolower($NF)}' \
    | sed -E 's/[-_](instruct|it|chat|base|fp8|fp16|bf16|mlx|awq[^ ]*|gptq[^ ]*|nvfp[^ ]*|q[0-9]+[^ ]*|abliterated|uncensored|speculator[^ ]*).*$//'
}

# Check if an HF model is represented in `ollama list`.
is_in_ollama() {
  local stem
  stem=$(hf_stem "$1")
  # Need a non-empty stem of at least 4 chars to avoid false positives.
  [[ ${#stem} -ge 4 ]] || return 1
  [[ "$ollama_blob" == *"$stem"* ]]
}

# First-party providers whose names tend to map to Ollama library tags.
# Fine-tunes and merges from third parties rarely appear on Ollama under the
# same name, so filter them out of pull suggestions.
FIRST_PARTY_FILTER='["alibaba","qwen","google","meta","microsoft","deepseek","mistralai","mistral","zhipu","openai"]'

# Cache the per-tier llmfit JSON once so the top-5 and pull-suggestion loops
# below don't both call llmfit for the same tier (4 subprocesses instead of 8).
cache_dir=$(mktemp -d)
trap 'rm -rf "$cache_dir"' EXIT
for tier in code prose reasoning long-context; do
  uc=$(tier_to_usecase "$tier")
  llmfit recommend --use-case "$uc" --min-fit good -n 20 --json > "$cache_dir/$tier.json" 2>/dev/null \
    || echo '{"models":[]}' > "$cache_dir/$tier.json"
done

echo "=== Top llmfit recommendations per tier (for this hardware) ==="
echo "Scores are llmfit composite (quality+speed+fit+context). Installed status"
echo "checked against 'ollama list' (not llmfit's HF cache). Filtered to"
echo "first-party providers (Alibaba/Google/Meta/Microsoft/DeepSeek/Mistral/Zhipu)."
echo

for tier in code prose reasoning long-context; do
  uc=$(tier_to_usecase "$tier")
  filtered=$(jq --argjson fp "$FIRST_PARTY_FILTER" '
    .models | map(select((.provider | ascii_downcase) as $p | $fp | index($p)))
    | sort_by(-.score) | .[0:5]
  ' "$cache_dir/$tier.json")
  count=$(echo "$filtered" | jq 'length')
  if [[ "$count" -eq 0 ]]; then
    printf "  %-14s  (no first-party llmfit results)\n" "$tier"
    continue
  fi
  printf "  --- tier: %s (llmfit use-case: %s) ---\n" "$tier" "$uc"
  while IFS=$'\t' read -r score tps params name; do
    if is_in_ollama "$name"; then tag="[installed]"; else tag="[not installed]"; fi
    printf "    %s  %stps  %s  %s  %s\n" "$score" "$tps" "$params" "$name" "$tag"
  done < <(echo "$filtered" | jq -r '.[] | "\(.score)\t\(.estimated_tps)\t\(.parameter_count)\t\(.name)"')
  echo
done

echo "=== Suggested pulls ==="
seen_suggestions=""
found=0
for tier in code prose reasoning long-context; do
  filtered=$(jq --argjson fp "$FIRST_PARTY_FILTER" '
    .models
    | map(select((.provider | ascii_downcase) as $p | $fp | index($p)))
    | map(select(.name | test("-(Base|FP8|FP16|BF16|AWQ|GPTQ|MLX|NVFP|speculator)"; "i") | not))
    | sort_by([.score, (.release_date // "0000-00-00")]) | reverse
  ' "$cache_dir/$tier.json")

  # Best installed score (among first-party models in llmfit top-20).
  best_installed=0
  while IFS=$'\t' read -r s n; do
    if is_in_ollama "$n"; then
      if awk -v a="$s" -v b="$best_installed" 'BEGIN{ exit !(a>b) }'; then best_installed="$s"; fi
    fi
  done < <(echo "$filtered" | jq -r '.[] | "\(.score)\t\(.name)"')

  # First non-installed candidate that beats installed by 3+ points.
  while IFS=$'\t' read -r s p n; do
    if is_in_ollama "$n"; then continue; fi
    if ! awk -v a="$s" -v b="$best_installed" 'BEGIN{ exit !(a-b >= 3) }'; then continue; fi
    # Dedupe: same HF model across tiers prints once.
    case "$seen_suggestions" in *"|$n|"*) continue ;; esac
    seen_suggestions="${seen_suggestions}|$n|"
    hint=$(echo "$n" | awk -F/ '{print tolower($NF)}')
    if [[ "$best_installed" == "0" ]]; then
      printf "  [%s] %s (%s) — llmfit %.1f (no comparable first-party installed)\n" \
        "$tier" "$n" "$p" "$s"
    else
      printf "  [%s] %s (%s) — llmfit %.1f vs installed %.1f\n" \
        "$tier" "$n" "$p" "$s" "$best_installed"
    fi
    printf "         try: ollama pull %s   (verify at https://ollama.com/library)\n" "$hint"
    found=1
    break
  done < <(echo "$filtered" | jq -r '.[] | "\(.score)\t\(.parameter_count)\t\(.name)"')
done

if [[ "$found" -eq 0 ]]; then
  echo "  No strong upgrades found — installed models lead or match the llmfit top for your hardware."
fi
echo
cat <<'EOF'
=== Next steps ===
- Verify the Ollama tag matches the HF name (Ollama sometimes re-packages).
- After any pull, edit scripts/pick-model.sh prefs if the model-name pattern
  changed, then re-run this script.
- Prefer the smallest model sufficient for the task (speed + energy).

To validate any suggested upgrade against the recipe library before
adopting, run:
    bash scripts/model-change-audit.sh <model> [<tier>]
EOF
