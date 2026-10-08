#!/usr/bin/env bash
# Audit the models the running providers serve: reachability, inventory, tier
# routing and a frozen-config.sh warning. Installs nothing. The provider list
# comes from pick-model.sh so the audit cannot report an inventory routing does
# not consult. Choosing a new model is the trial in docs/model-swap.md (#658).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pick="$script_dir/pick-model.sh"

# Pinned for the whole audit so every section answers against the same providers.
DELEGATE_BASE_URL=$(bash "$pick" --print-providers | tr '\n' ' ')
DELEGATE_BASE_URL="${DELEGATE_BASE_URL% }"
export DELEGATE_BASE_URL

echo "=== Providers ==="
for base in $DELEGATE_BASE_URL; do
  if curl -sS --fail --max-time "${DELEGATE_PROBE_TIMEOUT:-1}" "${base%/}/models" >/dev/null 2>&1; then
    printf "  %-44s reachable\n" "$base"
  else
    printf "  %-44s unreachable\n" "$base"
  fi
done
echo "  First match wins: the first reachable provider holding a model the tier"
echo "  prefers takes the call."
echo

echo "=== Installed models (union of the reachable providers) ==="
bash "$pick" --print-installed
echo

# Every tier, including the scaffolded ones resolving to (none): that is the
# state to surface. Names come from --print-prefs, single-sourced.
echo "=== Tier routing (which model wins per tier) ==="
while IFS= read -r tier; do
  [[ -n "$tier" ]] || continue
  if ! model=$(bash "$pick" "$tier" 2>/dev/null); then
    model="(none)"
  fi
  printf "  %-17s -> %s\n" "$tier" "$model"
done < <(bash "$pick" --print-prefs | cut -d: -f1)
# A frozen copy (the old init.sh output) shadows every later change to the
# shipped lists without changing the routing table above (#653).
frozen=$(bash "$pick" --print-frozen-tiers | tr '\n' ' ')
if [[ -n "$frozen" ]]; then
  echo "  warning: config.sh replaces the shipped preferences for: ${frozen% }"
  echo "  Later changes to those shipped lists never reach this machine. Prepend"
  echo "  instead, e.g. prose) prefs=(gemma-4-26b \"\${prefs[@]}\") ;; or drop the tier."
fi
echo

echo "To trial or switch a model, follow docs/model-swap.md."
