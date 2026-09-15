#!/usr/bin/env bash
# Pick the best installed local-LLM model for a task tier.
# Usage: pick-model.sh [--dry-run] <tier>
#   tier ∈ {code, prose, reasoning, long-context,
#           vision, embedding, premium-general, reasoning-vision}
# Prints the model name on stdout; exit 1 when no match, 2 on usage error.
# --dry-run also traces the resolution to stderr. --print-providers,
# --print-installed and --print-prefs take no tier and exist so callers never
# re-derive routing state; --print-resolution prints "<base>\t<model>".
#
# Preference order per tier is a substring-matched list, highest capability
# first; edit the arrays below when the installed set changes. Prefer the
# smallest model sufficient.
#
# DELEGATE_BASE_URL is a space-separated, ordered list of OpenAI-compatible
# base URLs; the first that answers GET {base}/models AND holds a model the
# tier prefers wins. The default is built from MLX_HOST, DOCKER_MODEL_HOST
# and OLLAMA_HOST, provider-major on purpose (ADR 0022: MLX is roughly an
# order of magnitude faster than Ollama on the same weights). Userinfo in a
# URL exits 2 before any probe. DELEGATE_PROBE_TIMEOUT (default 1 s) bounds
# each probe. Discovery is only ever what a running provider reports, never a
# filesystem scan, and matching is case-insensitive so one list covers every
# provider's spelling.
#
# vision and reasoning-vision resolve a name but do not go through delegate.sh
# (no --image passthrough); embedding goes through embed.sh.

set -euo pipefail

# Single source of truth for the tier names; delegate.sh reads this line.
TIERS="code|prose|reasoning|long-context|vision|embedding|premium-general|reasoning-vision"

# Space-separated substrings per tier; --print-prefs emits them all so
# external callers never duplicate the lists.
CODE_PREFS="qwen3-coder-next qwen3-coder deepseek-r1 qwen3.5"
PROSE_PREFS="qwen3.6 qwen3-next gemma4:latest gemma4 llama4 qwen3.5"
REASONING_PREFS="deepseek-r1:32b deepseek-r1-distill-qwen-32b phi4-reasoning qwq glm-4"
LONG_CONTEXT_PREFS="qwen3.6 qwen3-next llama4:scout qwen3-coder-next llama4 glm-4"
VISION_PREFS="qwen3-vl:30b-a3b-thinking qwen3-vl-30b-a3b-thinking qwen3-vl"
EMBEDDING_PREFS="nomic-embed-text bge-large"
PREMIUM_GENERAL_PREFS="qwen3.5:122b qwen3.5-122b"
REASONING_VISION_PREFS="phi4-reasoning-vision qwen3-vl:30b-a3b-thinking qwen3-vl-30b-a3b-thinking"

dry_run=0
print_prefs=0
print_providers=0
print_installed=0
print_resolution=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --print-prefs) print_prefs=1 ;;
    --print-providers) print_providers=1 ;;
    --print-installed) print_installed=1 ;;
    --print-resolution) print_resolution=1 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if (( print_prefs )); then
  printf 'code:%s\n' "$CODE_PREFS"
  printf 'prose:%s\n' "$PROSE_PREFS"
  printf 'reasoning:%s\n' "$REASONING_PREFS"
  printf 'long-context:%s\n' "$LONG_CONTEXT_PREFS"
  printf 'vision:%s\n' "$VISION_PREFS"
  printf 'embedding:%s\n' "$EMBEDDING_PREFS"
  printf 'premium-general:%s\n' "$PREMIUM_GENERAL_PREFS"
  printf 'reasoning-vision:%s\n' "$REASONING_VISION_PREFS"
  exit 0
fi


trace() {
  (( dry_run )) && printf "dry-run: %s\n" "$*" >&2
  return 0
}

# Built from the host variables, not literal ports, so a non-default port or
# a remote daemon keeps working.
DELEGATE_BASE_URL="${DELEGATE_BASE_URL:-${MLX_HOST:-http://localhost:8080}/v1 ${DOCKER_MODEL_HOST:-http://localhost:12434}/engines/v1 ${OLLAMA_HOST:-http://localhost:11434}/v1}"

# A user:pass@ URL would reach the metrics label and the --dry-run trace.
for _u in $DELEGATE_BASE_URL; do
  case "$_u" in
    *"://"*"@"*)
      echo "pick-model: DELEGATE_BASE_URL entry '$_u' contains userinfo (user:pass@); refusing" >&2
      exit 2
      ;;
  esac
done

# Prints "<base_url><TAB><model_id>" for the first provider both reachable and
# holding a model this tier prefers. Returns 1 when a provider answered but
# none matched, 2 when nothing answered: the remedies are opposite, and a
# counter set here would die with the command-substitution subshell.
# Provider-major, not preference-major: the lists interleave per-provider
# spellings of one model, so preference-major would re-route tiers across
# runtimes at different quantisations.
resolve_via_providers() {
  local base models pref hit reachable=0
  for base in $DELEGATE_BASE_URL; do
    base="${base%/}"
    # Explicit failure branch: under `set -e` a stopped first provider would
    # abort resolution before the rest were tried.
    if ! models=$(curl -sS --fail --max-time "${DELEGATE_PROBE_TIMEOUT:-1}" \
        "$base/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null | sort); then
      trace "provider $base: unreachable, skipping"
      continue
    fi
    reachable=$((reachable + 1))
    if [[ -z "$models" ]]; then
      trace "provider $base: reachable but reports no models, skipping"
      continue
    fi
    for pref in "${prefs[@]}"; do
      # sort + grep -im1: daemon ordering is not stable, so without the sort a
      # two-match preference resolves differently run to run.
      hit=$(printf '%s\n' "$models" | grep -im1 -F -- "$pref" || true)
      if [[ -n "$hit" ]]; then
        trace "provider $base: matched preference='$pref' -> model='$hit'"
        printf '%s\t%s\n' "$base" "$hit"
        return 0
      fi
    done
    trace "provider $base: no model matches this tier, skipping"
  done
  (( reachable > 0 )) || return 2
  return 1
}

# The union of every reachable provider's /models, deduplicated; the audit
# reports its inventory through this so it cannot differ from routing.
list_installed() {
  local base ids
  for base in $DELEGATE_BASE_URL; do
    base="${base%/}"
    if ! ids=$(curl -sS --fail --max-time "${DELEGATE_PROBE_TIMEOUT:-1}" \
        "$base/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null); then
      continue
    fi
    printf '%s\n' "$ids"
  done | sort -u
}

# Tier-independent surfaces answer before the tier argument is read.
if (( print_providers )); then
  # Deliberately unquoted: each space-separated entry becomes its own line.
  printf '%s\n' $DELEGATE_BASE_URL
  exit 0
fi

if (( print_installed )); then
  list_installed
  exit 0
fi

tier="${1:-}"
if [[ -z "$tier" ]]; then
  echo "usage: pick-model.sh [--dry-run] <$TIERS>" >&2
  exit 2
fi

case "$tier" in
  code)             prefs=($CODE_PREFS) ;;
  prose)            prefs=($PROSE_PREFS) ;;
  reasoning)        prefs=($REASONING_PREFS) ;;
  long-context)     prefs=($LONG_CONTEXT_PREFS) ;;
  vision)           prefs=($VISION_PREFS) ;;
  embedding)        prefs=($EMBEDDING_PREFS) ;;
  premium-general)  prefs=($PREMIUM_GENERAL_PREFS) ;;
  reasoning-vision) prefs=($REASONING_VISION_PREFS) ;;
  *) echo "unknown tier: $tier (valid: $TIERS)" >&2; exit 2 ;;
esac

trace "tier=$tier"
trace "providers=$DELEGATE_BASE_URL"
trace "preferences=${prefs[*]}"

# Per-user override: plain bash sourced after the defaults populate `prefs`,
# which it may reassign. User-owned content executed in the user's own
# context by design; the threat model assumes single-user dev. Path:
# DELEGATE_LOCAL_CONFIG (or the legacy DELEGATE_TO_OLLAMA_CONFIG), else
# <data dir>/config.sh.
config="${DELEGATE_LOCAL_CONFIG:-${DELEGATE_TO_OLLAMA_CONFIG:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/config.sh}}"
if [[ -f "$config" ]]; then
  # Skip an override not owned by the current user or group/world-writable.
  # BSD `stat` first (macOS), GNU fallback (Linux).
  if stat -f '%Su' "$config" >/dev/null 2>&1; then
    cfg_owner=$(stat -f '%Su' "$config")
    cfg_mode=$(stat -f '%Lp' "$config")
  else
    cfg_owner=$(stat -c '%U' "$config")
    cfg_mode=$(stat -c '%a' "$config")
  fi
  cfg_mode=$(printf '%03d' "$cfg_mode")
  cfg_group=${cfg_mode: -2:1}
  cfg_world=${cfg_mode: -1}
  if [[ "$cfg_owner" != "$(id -un)" ]]; then
    echo "warning: $config not owned by $(id -un), skipping override" >&2
  elif [[ "$cfg_group" == [2367] || "$cfg_world" == [2367] ]]; then
    echo "warning: $config is group/world-writable (mode $cfg_mode), skipping override" >&2
  else
    trace "sourcing override: $config (owner=$cfg_owner, mode=$cfg_mode)"
    # shellcheck disable=SC1090
    source "$config"
    trace "preferences (post-override)=${prefs[*]}"
  fi
fi

resolve_rc=0
_resolved=$(resolve_via_providers) || resolve_rc=$?
if (( resolve_rc != 0 )); then
  # "Nothing answered" means start a daemon; "answered but no match" means
  # pull a model or edit the prefs list.
  if (( resolve_rc == 2 )); then
    echo "pick-model: no provider is reachable" >&2
  else
    echo "pick-model: no provider holds a model for tier '$tier'" >&2
  fi
  echo "            tried: $DELEGATE_BASE_URL" >&2
  exit 1
fi

if (( print_resolution )); then
  printf '%s\n' "$_resolved"
else
  printf '%s\n' "${_resolved#*	}"
fi
