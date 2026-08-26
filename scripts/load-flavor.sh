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
#   DELEGATE_LOCAL_DATA_DIR     where per-user data lives
#                               (default ~/.local/share/delegate-local)
#   DELEGATE_LOCAL_PROFILE   override profile path
#                            (default ~/.local/share/delegate-local/profile.sh)
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

# 2b. Derived values, resolved after the profile so a profile override feeds
#     into them. A recipe that states BOTH a structural shape and a word cap can
#     otherwise be handed two instructions that contradict each other: "1-2
#     short flowing-prose paragraphs" is right for the shipped 120-word cap and
#     impossible under a profile that tightens the cap to 50, because two
#     stretches of prose short enough to fit do not read as paragraphs.
#
#     Measured 2026-08-26 on the live corpus: 11 of 14 `commit-message`
#     scaffolds were length rewrites, and the recorded reasons name the
#     STRUCTURE rather than the count — "body was three paragraphs against this
#     repo's one-to-two-sentence convention", "body ran to four clauses where
#     the repo convention is". The model follows the shape it can see and
#     overshoots the number it would have to count. Deriving the shape from the
#     cap removes the contradiction instead of asking the model to resolve it.
#
#     A profile that sets FLAVOR_COMMIT_BODY_SHAPE explicitly wins; this only
#     fills the gap. The 60-word threshold is a judgement, not a measurement:
#     two stretches of prose need roughly 30 words each to read as paragraphs,
#     so a cap below about 60 makes the two-paragraph shape unwritable.
if [[ -z "${FLAVOR_COMMIT_BODY_SHAPE:-}" ]]; then
  # `10#` forces base 10. Without it a zero-padded but perfectly valid value
  # like `050` is read as octal, and `08` is not octal at all, so bash aborts the
  # arithmetic with "value too great for base" on stderr — which in a recipe run
  # lands in the caller's stderr for no reason.
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
