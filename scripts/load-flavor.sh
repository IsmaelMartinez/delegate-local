#!/usr/bin/env bash
# Resolve the active flavor profile and print each value as a
# `flavor_<key>=<value>` line for delegate.sh to substitute (ADR 0013):
# shipped defaults, then the per-user profile.sh (owner/mode-checked, the same
# trust model as pick-model.sh's config.sh). Sourcing the user profile is
# isolated to this subprocess so the dispatcher never executes user bash.
#
# Env:
#   DELEGATE_LOCAL_DATA_DIR  per-user data (default ~/.local/share/delegate-local)
#   DELEGATE_LOCAL_PROFILE   override profile path (default <data dir>/profile.sh)
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Shipped defaults, so every placeholder resolves with no user profile.
defaults="$script_dir/flavor-defaults.sh"
# shellcheck source=/dev/null
[[ -f "$defaults" ]] && source "$defaults"

# 2. Per-user override, skipped when not owned by the current user or
#    group/world-writable. BSD stat first (macOS), GNU fallback (Linux).
profile="${DELEGATE_LOCAL_PROFILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/profile.sh}"
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

# 2b. Derived values, resolved after the profile so an override feeds them. A
#     recipe stating BOTH a structural shape and a word cap can be handed two
#     contradicting instructions (two paragraphs cannot fit a 50-word cap), and
#     the model follows the shape it can see. An explicit FLAVOR_COMMIT_BODY_SHAPE
#     wins; the 60-word threshold is a judgement (two paragraphs need roughly
#     30 words each).
if [[ -z "${FLAVOR_COMMIT_BODY_SHAPE:-}" ]]; then
  # `10#` forces base 10: a zero-padded `050` reads as octal and `08` aborts
  # the arithmetic.
  if [[ "${FLAVOR_COMMIT_BODY_MAX_WORDS:-}" =~ ^[0-9]+$ ]] \
     && (( 10#${FLAVOR_COMMIT_BODY_MAX_WORDS} <= 60 )); then
    FLAVOR_COMMIT_BODY_SHAPE="one short flowing-prose paragraph of one or two sentences"
  else
    FLAVOR_COMMIT_BODY_SHAPE="1-2 short flowing-prose paragraphs"
  fi
fi

# 3. Emit resolved flavor values as flavor_<lowercased-key>=<value> lines.
#    The `|| true` keeps a no-FLAVOR_*-set profile from tripping pipefail.
for v in $(compgen -v | grep '^FLAVOR_' || true); do
  key=$(printf '%s' "${v#FLAVOR_}" | tr 'A-Z' 'a-z')
  printf 'flavor_%s=%s\n' "$key" "${!v}"
done
