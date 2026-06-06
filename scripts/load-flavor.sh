#!/usr/bin/env bash
# Resolve the active flavor profile and print each value as a
# `flavor_<key>=<value>` line for delegate.sh to substitute into {{flavor_*}}
# recipe placeholders (ADR 0013, portable recipes). Shipped defaults first,
# then the per-user profile.sh override (owner/mode-checked, same trust model
# as pick-model.sh's config.sh hook). Read-only w.r.t. the filesystem; prints
# to stdout. Sourcing of the user profile is isolated to this subprocess so the
# dispatcher never executes user bash in its own shell.
#
# Env:
#   DELEGATE_LOCAL_PROFILE   override profile path
#                            (default ~/.claude/skills/delegate-local/profile.sh)
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Shipped defaults (trusted, in-repo): guarantee every flavor placeholder a
#    recipe uses resolves even with no user profile, keeping prompts back-compatible.
defaults="$script_dir/flavor-defaults.sh"
# shellcheck source=/dev/null
[[ -f "$defaults" ]] && source "$defaults"

# 2. Per-user override. Defence-in-depth mirrors pick-model.sh's config.sh hook:
#    skip the file if it isn't owned by the current user or is group/world-writable,
#    so a stray chmod can't turn it into arbitrary code execution under our process.
#    BSD stat first (macOS), GNU stat fallback (Linux).
profile="${DELEGATE_LOCAL_PROFILE:-$HOME/.claude/skills/delegate-local/profile.sh}"
if [[ -f "$profile" ]]; then
  if stat -f '%Su' "$profile" >/dev/null 2>&1; then
    p_owner=$(stat -f '%Su' "$profile"); p_mode=$(stat -f '%Lp' "$profile")
  else
    p_owner=$(stat -c '%U' "$profile"); p_mode=$(stat -c '%a' "$profile")
  fi
  p_mode=$(printf '%03d' "$p_mode")
  if [[ "$p_owner" != "$(id -un)" ]]; then
    echo "load-flavor: $profile not owned by $(id -un), skipping override" >&2
  elif [[ "${p_mode: -2:1}" == [2367] || "${p_mode: -1}" == [2367] ]]; then
    echo "load-flavor: $profile is group/world-writable (mode $p_mode), skipping override" >&2
  else
    # shellcheck source=/dev/null
    source "$profile"
  fi
fi

# 3. Emit resolved flavor values as flavor_<lowercased-key>=<value> lines.
#    The `|| true` keeps a no-FLAVOR_*-set profile from tripping pipefail.
for v in $(compgen -v | grep '^FLAVOR_' || true); do
  key=$(printf '%s' "${v#FLAVOR_}" | tr 'A-Z' 'a-z')
  printf 'flavor_%s=%s\n' "$key" "${!v}"
done
