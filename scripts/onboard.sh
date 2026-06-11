#!/usr/bin/env bash
# Onboarding wizard (ADR 0013): probe the environment and the user's own git
# history, present each derived value for confirm-or-edit, and write the two
# per-user override files on explicit confirmation. Wraps the existing probes —
# init.sh (installed models -> config.sh routing override) and derive-flavor.sh
# (git history -> profile.sh flavor values) — rather than reimplementing them.
#
# Interactive use (a terminal):
#   bash scripts/onboard.sh
#
# Without a terminal it degrades to print-only: both candidate files go to
# stdout with the manual redirect commands, and nothing is written — the same
# read-only contract init.sh and derive-flavor.sh already keep. Files are only
# ever written after an explicit per-file confirmation, with a timestamped
# .bak.<ts> backup when the target already exists, and chmod 600 so the
# profile passes load-flavor.sh's owner/mode trust check immediately.
#
# Env:
#   DELEGATE_LOCAL_CONFIG       config.sh target
#                               (default ~/.claude/skills/delegate-local/config.sh)
#   DELEGATE_LOCAL_PROFILE      profile.sh target
#                               (default ~/.claude/skills/delegate-local/profile.sh)
#   DELEGATE_ONBOARD_ASSUME_TTY=1  test seam: read answers from stdin instead of
#                               /dev/tty (a real pty can't be driven in CI)
# Exit: 0 on the happy / print-only / quit paths; 2 on a usage error.
set -uo pipefail

while (($# > 0)); do
  case "$1" in
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "onboard: unknown arg '$1'" >&2; exit 2;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_target="${DELEGATE_LOCAL_CONFIG:-$HOME/.claude/skills/delegate-local/config.sh}"
profile_target="${DELEGATE_LOCAL_PROFILE:-$HOME/.claude/skills/delegate-local/profile.sh}"

interactive=0
[[ "${DELEGATE_ONBOARD_ASSUME_TTY:-}" == "1" || -t 0 ]] && interactive=1

# --- Probe 1: environment (facts, no questions) ------------------------------
# init.sh prints a routing override built from `ollama list`; a host without
# ollama or models just skips this section — flavor-only onboarding still works.
config_candidate=""
if ! config_candidate=$(bash "$script_dir/init.sh" 2>/dev/null); then
  config_candidate=""
  echo "onboard: environment probe skipped (init.sh found no usable ollama install)." >&2
fi

# --- Probe 2: flavor from the user's own git history -------------------------
# derive-flavor.sh reads the cwd's repo; outside a repo (or with no commits)
# the shipped defaults become the prefill instead.
derived=""
if ! derived=$(bash "$script_dir/derive-flavor.sh" 2>/dev/null); then
  derived=""
  echo "onboard: no git history here — flavor prefills fall back to shipped defaults." >&2
fi
derived_subject_max=$(printf '%s\n' "$derived" | sed -n 's/^FLAVOR_COMMIT_SUBJECT_MAX=\(.*\)$/\1/p')
derived_types=$(printf '%s\n' "$derived" | sed -n 's/^FLAVOR_COMMIT_TYPES="\(.*\)"$/\1/p')
corpus_line=$(printf '%s\n' "$derived" | sed -n 's/^# Source corpus: \([^.]*\)\..*$/\1/p')

# Shipped defaults give every key a prefill even on a thin corpus.
# shellcheck source=/dev/null
source "$script_dir/flavor-defaults.sh"
default_subject_max="$FLAVOR_COMMIT_SUBJECT_MAX"
default_types="$FLAVOR_COMMIT_TYPES"
prefill_subject_max="${derived_subject_max:-$default_subject_max}"
prefill_types="${derived_types:-$default_types}"

build_profile_body() { # $1=subject_max-or-empty $2=types-or-empty
  printf '# delegate-local flavor profile — written by scripts/onboard.sh\n'
  [[ -n "$corpus_line" ]] && printf '# Source corpus: %s\n' "$corpus_line"
  printf '# Re-run onboard.sh (or derive-flavor.sh) after the history grows, or edit to taste.\n'
  [[ -n "$1" ]] && printf 'FLAVOR_COMMIT_SUBJECT_MAX=%s\n' "$1"
  [[ -n "$2" ]] && printf 'FLAVOR_COMMIT_TYPES="%s"\n' "$2"
}

# --- Print-only mode (no terminal): show both candidates, write nothing ------
if (( ! interactive )); then
  if [[ -n "$config_candidate" ]]; then
    printf '# ---- routing override candidate — write to: %s ----\n' "$config_target"
    printf '#   bash scripts/init.sh > %s\n' "$config_target"
    printf '%s\n\n' "$config_candidate"
  fi
  printf '# ---- flavor profile candidate — write to: %s ----\n' "$profile_target"
  printf '#   bash scripts/derive-flavor.sh > %s\n' "$profile_target"
  build_profile_body "$prefill_subject_max" "$prefill_types"
  echo "onboard: no interactive terminal — printed candidates only, wrote nothing. Run in a terminal to confirm-and-write." >&2
  exit 0
fi

# --- Interactive layer (verdict-sweep.sh pattern) ----------------------------
read_answer() {
  if [[ "${DELEGATE_ONBOARD_ASSUME_TTY:-}" == "1" ]]; then
    IFS= read -r _ans
  else
    IFS= read -r _ans </dev/tty
  fi
}

# Ask one flavor value: Enter=accept prefill, typed value=validated override,
# s=skip the key (falls through to shipped defaults at load time), q=quit the
# wizard with nothing written. Result lands in $confirmed; $quit=1 on q.
quit=0
ask_value() { # $1=label $2=prefill $3=default $4=validation-regex $5=validation-hint
  local label="$1" prefill="$2" default="$3" regex="$4" hint="$5"
  confirmed=""
  while true; do
    printf '%s: derived %s (shipped default %s)\n' "$label" "$prefill" "$default" >&2
    printf '  [Enter]=accept %s, or type a value, s=skip this key, q=quit without writing: ' "$prefill" >&2
    _ans=""
    read_answer || _ans="q"
    case "$_ans" in
      "") confirmed="$prefill"; return 0;;
      s|S) confirmed=""; return 0;;
      q|Q) quit=1; return 0;;
      *)
        if printf '%s' "$_ans" | grep -Eq "$regex"; then
          confirmed="$_ans"; return 0
        fi
        echo "    invalid value ($hint) — try again." >&2;;
    esac
  done
}

# Write $2 (content) to $1 (target) after an overwrite confirmation when the
# target exists, backing the old file up as <target>.bak.<ts> first. chmod 600
# keeps load-flavor.sh's owner/mode trust check green from the first call.
write_confirmed() { # $1=target $2=content $3=what
  local target="$1" content="$2" what="$3"
  if [[ -f "$target" ]]; then
    printf '%s already exists at %s — overwrite (a .bak copy is kept)? [y/N]: ' "$what" "$target" >&2
    _ans=""
    read_answer || _ans="n"
    case "$_ans" in
      y|Y) cp -p "$target" "$target.bak.$(date +%Y%m%d%H%M%S)";;
      *) echo "  kept existing $what untouched." >&2; return 1;;
    esac
  fi
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$content" > "$target"
  chmod 600 "$target"
  echo "  wrote $what to $target" >&2
  return 0
}

echo "delegate-local onboarding — confirm-or-edit each derived value." >&2
[[ -n "$corpus_line" ]] && echo "Flavor source: $corpus_line" >&2

ask_value "FLAVOR_COMMIT_SUBJECT_MAX" "$prefill_subject_max" "$default_subject_max" \
  '^[0-9]+$' "must be a positive integer"
subject_max_final="$confirmed"
if (( ! quit )); then
  ask_value "FLAVOR_COMMIT_TYPES" "$prefill_types" "$default_types" \
    '^[a-z]+(, [a-z]+)*$' "comma-space separated lowercase types, e.g. feat, fix, docs"
  types_final="$confirmed"
fi
if (( quit )); then
  echo "onboard: quit — nothing written." >&2
  exit 0
fi

wrote_profile=0
if [[ -n "$subject_max_final" || -n "$types_final" ]]; then
  profile_body=$(build_profile_body "$subject_max_final" "$types_final")
  write_confirmed "$profile_target" "$profile_body" "flavor profile" && wrote_profile=1
else
  echo "onboard: both flavor keys skipped — profile not written (shipped defaults stay active)." >&2
fi

wrote_config=0
if [[ -n "$config_candidate" ]]; then
  printf '\nRouting override candidate (puts your installed models first per tier):\n%s\n' "$config_candidate" >&2
  printf 'install routing override at %s? [y/N]: ' "$config_target" >&2
  _ans=""
  read_answer || _ans="n"
  case "$_ans" in
    y|Y) write_confirmed "$config_target" "$config_candidate" "routing override" && wrote_config=1;;
    *) echo "  routing override not installed (shipped preference lists stay active)." >&2;;
  esac
fi

echo "" >&2
echo "onboard: done — profile $( ((wrote_profile)) && echo written || echo unchanged ), routing override $( ((wrote_config)) && echo written || echo unchanged )." >&2
echo "Next: pipe a task through the wrapper (e.g. git diff | bash $script_dir/delegate.sh --recipe commit-message ...)," >&2
echo "record verdicts with delegate-feedback.sh hit|miss, and re-run onboard.sh as your history grows." >&2
