#!/usr/bin/env bash
# Onboarding wizard (ADR 0013): wraps init.sh (installed models -> config.sh)
# and derive-flavor.sh (git history -> profile.sh), presents each derived value
# for confirm-or-edit, and writes only on explicit confirmation, backing up an
# existing target as .bak.<ts> first. Writes are chmod 600 so the profile
# passes load-flavor.sh's owner/mode check. Without a terminal it degrades to
# print-only and writes nothing.
#
# Interactive use (a terminal):
#   bash scripts/onboard.sh
#
# Migration:
#   bash scripts/onboard.sh --migrate-data
# COPIES the per-user files from the legacy skill directory to the data
# directory; never moves, so it cannot destroy anything.
#
# Env:
#   DELEGATE_LOCAL_DATA_DIR     where per-user data lives
#                               (default ~/.local/share/delegate-local)
#   DELEGATE_LOCAL_CONFIG       config.sh target
#                               (default $DELEGATE_LOCAL_DATA_DIR/config.sh)
#   DELEGATE_LOCAL_PROFILE      profile.sh target
#                               (default $DELEGATE_LOCAL_DATA_DIR/profile.sh)
#   DELEGATE_ONBOARD_ASSUME_TTY=1  test seam: read answers from stdin instead of
#                               /dev/tty (a real pty can't be driven in CI)
# Exit: 0 on the happy / print-only / quit paths; 2 on a usage error.
set -uo pipefail

migrate_data=0
while (($# > 0)); do
  case "$1" in
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    --migrate-data) migrate_data=1; shift;;
    *) echo "onboard: unknown arg '$1'" >&2; exit 2;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The same resolution (legacy env name included) as the consumer, pick-model.sh.
config_target="${DELEGATE_LOCAL_CONFIG:-${DELEGATE_TO_OLLAMA_CONFIG:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/config.sh}}"
profile_target="${DELEGATE_LOCAL_PROFILE:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/profile.sh}"

# --- --migrate-data: legacy skill directory -> data directory (#360) -------
# The installer owns the legacy directory, so `skills update` could delete the
# calibration history. COPY, never move; resolution no longer looks at the
# legacy files, which is why a read-only fallback was rejected (it could
# resurrect a stale snapshot months later).
if (( migrate_data )); then
  legacy_dir="$HOME/.claude/skills/delegate-local"
  data_dir="${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}"
  # metrics.loki-sync rides along, else the watermark resets and re-pushes every row.
  migrate_names="metrics.jsonl config.sh profile.sh metrics.loki-sync"

  if [[ ! -d "$legacy_dir" ]]; then
    echo "onboard: nothing to migrate — no legacy directory at $legacy_dir" >&2
    exit 0
  fi
  found=0
  for n in $migrate_names; do [[ -f "$legacy_dir/$n" ]] && found=1; done
  if (( ! found )); then
    # A legacy directory with no user data means the real history sits
    # elsewhere; fail loudly rather than report success having copied nothing.
    {
      echo "onboard: $legacy_dir exists but holds none of: $migrate_names"
      echo "         if this machine has run delegate.sh before, the skill symlink"
      echo "         was probably repointed already and the history is elsewhere."
      echo "         Find it before migrating: the old checkout still has it."
    } >&2
    exit 1
  fi

  mkdir -p "$data_dir" || { echo "onboard: cannot create $data_dir" >&2; exit 1; }
  copied=0
  for n in $migrate_names; do
    src="$legacy_dir/$n"
    [[ -f "$src" ]] || continue
    dst="$data_dir/$n"
    if [[ -f "$dst" ]]; then
      if cmp -s "$src" "$dst"; then
        echo "onboard: $n already migrated, unchanged"
        continue
      fi
      {
        echo "onboard: refusing to overwrite $dst"
        echo "         it already exists and differs from $src"
        echo "         merge or remove it by hand, then re-run"
      } >&2
      exit 1
    fi
    cp -p "$src" "$dst" || { echo "onboard: failed to copy $src" >&2; exit 1; }
    echo "onboard: copied $n -> $dst"
    copied=$((copied + 1))
  done
  echo "onboard: migrated $copied file(s); the originals under $legacy_dir are untouched"
  echo "onboard: verify with 'bash scripts/metrics-summary.sh' before repointing any symlink"
  exit 0
fi

interactive=0
[[ "${DELEGATE_ONBOARD_ASSUME_TTY:-}" == "1" || -t 0 ]] && interactive=1

err_tmp=$(mktemp)
trap 'rm -f "$err_tmp"' EXIT

# --- Probe 1: environment (facts, no questions) ------------------------------
# No reachable provider skips this section; flavor-only onboarding still works.
config_candidate=""
if ! config_candidate=$(bash "$script_dir/init.sh" 2>"$err_tmp"); then
  config_candidate=""
  reason=$(head -1 "$err_tmp")
  echo "onboard: environment probe skipped (${reason:-init.sh failed})." >&2
fi

# --- Probe 2: flavor from the user's own git history -------------------------
# Outside a repo (or with no commits) the shipped defaults become the prefill.
derived=""
if ! derived=$(bash "$script_dir/derive-flavor.sh" 2>"$err_tmp"); then
  derived=""
  reason=$(head -1 "$err_tmp")
  echo "onboard: flavor derivation skipped (${reason:-derive-flavor failed}) — prefills fall back to shipped defaults." >&2
fi
derived_subject_max=$(printf '%s\n' "$derived" | sed -n 's/^FLAVOR_COMMIT_SUBJECT_MAX=\(.*\)$/\1/p')
derived_types=$(printf '%s\n' "$derived" | sed -n 's/^FLAVOR_COMMIT_TYPES="\(.*\)"$/\1/p')
corpus_line=$(printf '%s\n' "$derived" | sed -n 's/^# Source corpus: \([^.]*\)\..*$/\1/p')

# Surface, never silently drop, a derived FLAVOR_* key this wizard does not handle yet.
extra_keys=$(printf '%s\n' "$derived" \
  | sed -n 's/^\(FLAVOR_[A-Z_]*\)=.*/\1/p' \
  | grep -v -e '^FLAVOR_COMMIT_SUBJECT_MAX$' -e '^FLAVOR_COMMIT_TYPES$' || true)
[[ -n "$extra_keys" ]] && echo "onboard: derived keys this wizard doesn't handle yet ($(printf '%s' "$extra_keys" | tr '\n' ' ' | sed 's/ $//')) — install them with derive-flavor.sh directly." >&2

# Shipped defaults give every key a prefill even on a thin corpus.
defaults_file="$script_dir/flavor-defaults.sh"
[[ -f "$defaults_file" ]] || { echo "onboard: missing $defaults_file — broken install?" >&2; exit 2; }
# shellcheck source=/dev/null
source "$defaults_file"
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
    printf '#   bash %s/init.sh > %s\n' "$script_dir" "$config_target"
    printf '%s\n\n' "$config_candidate"
  fi
  printf '# ---- flavor profile candidate — write to: %s ----\n' "$profile_target"
  # A shell redirect truncates the target BEFORE the command runs, so it is
  # only suggested when the probe succeeded.
  if [[ -n "$derived" ]]; then
    printf '#   bash %s/derive-flavor.sh > %s\n' "$script_dir" "$profile_target"
  else
    printf '#   (derive-flavor found no usable git history here — shipped defaults shown; no profile needed)\n'
  fi
  build_profile_body "$prefill_subject_max" "$prefill_types"
  echo "onboard: no interactive terminal — printed candidates only, wrote nothing. Run in a terminal to confirm-and-write." >&2
  exit 0
fi

# --- Interactive layer -------------------------------------------------------
read_answer() {
  if [[ "${DELEGATE_ONBOARD_ASSUME_TTY:-}" == "1" ]]; then
    IFS= read -r _ans
  else
    IFS= read -r _ans </dev/tty
  fi
}

# Enter=accept prefill, value=validated override, s=skip (shipped default at
# load time), q=quit with nothing written. Result in $confirmed; $quit=1 on q.
quit=0
ask_value() { # $1=label $2=prefill $3=default $4=validation-regex $5=validation-hint
  local label="$1" prefill="$2" default="$3" regex="$4" hint="$5"
  confirmed=""
  while true; do
    printf '%s: derived %s (shipped default %s)\n' "$label" "$prefill" "$default" >&2
    printf '  [Enter]=accept %s, or type a value, s=skip this key, q=quit without writing: ' "$prefill" >&2
    _ans=""
    # On EOF read returns non-zero but still fills $_ans with an unterminated
    # final line; only a truly empty read is quit/decline.
    read_answer || [[ -n "$_ans" ]] || _ans="q"
    case "$_ans" in
      "") confirmed="$prefill"; return 0;;
      s|S) confirmed=""; return 0;;
      q|Q) quit=1; return 0;;
      *)
        if [[ "$_ans" =~ $regex ]]; then
          confirmed="$_ans"; return 0
        fi
        echo "    invalid value ($hint) — try again." >&2;;
    esac
  done
}

# Overwrite confirmation and a <target>.bak.<ts> backup when the target
# exists; chmod 600 keeps load-flavor.sh's owner/mode check green.
write_confirmed() { # $1=target $2=content $3=what
  local target="$1" content="$2" what="$3"
  if [[ -f "$target" ]]; then
    printf '%s already exists at %s — overwrite (a .bak copy is kept)? [y/N]: ' "$what" "$target" >&2
    _ans=""
    read_answer || [[ -n "$_ans" ]] || _ans="n"
    case "$_ans" in
      y|Y)
        if ! cp -p "$target" "$target.bak.$(date +%Y%m%d%H%M%S)"; then
          echo "  backup failed — keeping existing $what untouched." >&2
          return 1
        fi;;
      *) echo "  kept existing $what untouched." >&2; return 1;;
    esac
  fi
  mkdir -p "$(dirname "$target")"
  if ! printf '%s\n' "$content" > "$target"; then
    echo "  failed to write $target" >&2
    return 1
  fi
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
  read_answer || [[ -n "$_ans" ]] || _ans="n"
  case "$_ans" in
    y|Y) write_confirmed "$config_target" "$config_candidate" "routing override" && wrote_config=1;;
    *) echo "  routing override not installed (shipped preference lists stay active)." >&2;;
  esac
fi

echo "" >&2
echo "onboard: done — profile $( ((wrote_profile)) && echo written || echo unchanged ), routing override $( ((wrote_config)) && echo written || echo unchanged )." >&2
echo "Next: pipe a task through the wrapper (e.g. git diff | bash $script_dir/delegate.sh --recipe commit-message ...)," >&2
echo "record verdicts with delegate-feedback.sh (hit, scaffold \"<reason>\" or miss \"<reason>\"), and re-run onboard.sh as your history grows." >&2
