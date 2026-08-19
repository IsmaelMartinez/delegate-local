#!/usr/bin/env bash
# Pick the best installed local-LLM model for a task tier.
# Usage: pick-model.sh [--dry-run] <tier>
#   tier ∈ {code, prose, reasoning, long-context,
#           vision, embedding, premium-general, reasoning-vision}
# Prints the model name on stdout, or exits 1 if no match and 2 on usage error.
# With --dry-run, also prints the resolution trace (tier, provider list,
# preference list, matched preference) to stderr so it can be inspected
# without affecting downstream pipes that consume stdout.
# --print-providers prints the effective provider list and exits;
# --print-installed prints the models those providers report, one per line,
# and exits. Both take no tier and exist so callers (scripts/audit-models.sh)
# never re-derive routing state locally.
#
# Preference order per tier is a substring-matched list, highest capability first.
# Edit the arrays below when your installed set changes. Run
# `pick-model.sh --print-installed` to see what the running providers serve.
# Prefer the smallest model sufficient — bigger is not better.
#
# Provider list (env var DELEGATE_BASE_URL): a space-separated, ordered list
# of OpenAI-compatible base URLs. Each is tried in order, and the first that
# answers GET {base}/models AND holds a model this tier prefers wins. The
# default is the three runtimes this skill supports, built from the host
# variables rather than literals so a non-default port or a remote daemon
# keeps working:
#
#     ${MLX_HOST:-http://localhost:8080}/v1
#     ${DOCKER_MODEL_HOST:-http://localhost:12434}/engines/v1
#     ${OLLAMA_HOST:-http://localhost:11434}/v1
#
# The order is provider-major and deliberate: ADR 0022 measured MLX at roughly
# an order of magnitude lower latency than Ollama on identical weights, so a
# reachable MLX server wins over a reachable Ollama one. A URL containing
# userinfo (user:pass@) is rejected with exit 2 before anything is probed. One
# trailing slash is stripped per entry. DELEGATE_PROBE_TIMEOUT bounds each
# /models probe: default 1 second, kept low deliberately, since a dead
# provider must cost close to nothing for cheap fallthrough to be the point.
#
# Discovery is only ever "what a running provider reports", never a filesystem
# scan — a model in the HuggingFace cache that no daemon is serving cannot be
# dispatched to, and counting it as installed only moved the failure later.
# Matching is case-insensitive so one prefs list covers every provider's
# spelling (Ollama uses lowercase tags, MLX uses HF-style mixed case).
#
# Note: vision and reasoning-vision tiers resolve a model name but do NOT go
# through scripts/delegate.sh today (which lacks --image flag passthrough);
# embedding tier goes through scripts/embed.sh, which posts to
# `{base}/embeddings` and returns a vector rather than text. See SKILL.md for
# the call shape per tier.

set -euo pipefail

# Single source of truth for the tier name list. The case statement below is
# the runtime gate (each branch needs its own prefs array, so the list of
# names is intrinsically duplicated there) but the usage message and the
# header comment are derived from this.
TIERS="code|prose|reasoning|long-context|vision|embedding|premium-general|reasoning-vision"

# Single source of truth for tier preference lists. The case statement below
# selects which list applies; the --print-prefs path emits all of them.
# Per-tier values are space-separated substrings (no quoting required because
# none contain whitespace). External callers query this surface to avoid
# duplicating the prefs in their own code (e.g. scripts/model-change-audit.sh
# uses it for tier inference from a model name).
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

# Emit all tier:prefs lines and exit. External callers (e.g.
# scripts/model-change-audit.sh) use this surface to avoid hardcoding the
# preference lists; keeps a single source of truth for tier definitions.
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

# The default list is built from the host variables, not from literal ports:
# hardcoding them would make MLX_HOST / DOCKER_MODEL_HOST / OLLAMA_HOST dead
# and silently re-route anyone running a daemon on a non-default port or a
# remote host back to localhost.
DELEGATE_BASE_URL="${DELEGATE_BASE_URL:-${MLX_HOST:-http://localhost:8080}/v1 ${DOCKER_MODEL_HOST:-http://localhost:12434}/engines/v1 ${OLLAMA_HOST:-http://localhost:11434}/v1}"

# Reject userinfo before anything is probed. A user:pass@ URL would otherwise
# reach the metrics label and the --dry-run trace, writing the credential to a
# file and printing it to a terminal.
for _u in $DELEGATE_BASE_URL; do
  case "$_u" in
    *"://"*"@"*)
      echo "pick-model: DELEGATE_BASE_URL entry '$_u' contains userinfo (user:pass@); refusing" >&2
      exit 2
      ;;
  esac
done

# Provider-list resolution. Prints "<base_url><TAB><model_id>" for the first
# provider that is both reachable and holding a model this tier prefers.
# Returns 1 when a provider answered but none held a match, and 2 when nothing
# answered at all: the two need opposite remedies (pull a model vs start a
# daemon), and the caller cannot tell them apart otherwise, because the
# function runs in a command substitution and any counter it sets dies with
# the subshell. Reads the `prefs` array from scope, as the matcher below does.
#
# Provider-major rather than preference-major: the preference lists interleave
# per-provider spellings of one model (see the note above), so they rank where
# a model runs, not which capability you get. Letting them drive the outer loop
# silently re-routes tiers across runtimes at different quantisations.
resolve_via_providers() {
  local base models pref hit reachable=0
  for base in $DELEGATE_BASE_URL; do
    base="${base%/}"
    # Explicit failure branch, not a bare assignment: under `set -e` a stopped
    # first provider would abort resolution before the rest were tried, which
    # is the exact inverse of the fallthrough this exists to provide.
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
      # sort above + grep -im1 here: grep takes the first match and daemon
      # ordering is not stable (ollama list is recency-ordered), so without the
      # sort a two-match preference resolves differently run to run.
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

# Enumerate the models the providers report, one per line: the union of every
# reachable provider's /models, deduplicated. scripts/audit-models.sh reports
# its inventory through this, so the audit cannot show a different model set
# than routing consults.
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

# Provider-only surfaces. Both are tier-independent, so they answer before the
# tier argument is read — a caller asking "which providers are in effect?" has
# no tier to name. scripts/audit-models.sh uses both.
if (( print_providers )); then
  # Deliberately unquoted: the list is space-separated and each entry becomes
  # its own line.
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

# Per-user override hook. The override file is plain bash sourced after the
# shipped defaults have populated `prefs`; it sees `$tier` and `$prefs` in
# scope and may reassign `prefs` to reorder or extend the list. Lives outside
# the repo so `git clean` can't eat it and it's never accidentally committed.
# Trust model: user-owned content executed in the user's own context, by
# design — same shape as ~/.aiderrc and ~/.claude/settings.local.json. The
# trade-offs (sudo, shared-HOME CI, env-var redirection) are documented in
# experiments/sessions/2026-05-03-security-review-delegation/RETROSPECTIVE.md
# F1/F2 — the threat model assumes single-user dev.
# Path: DELEGATE_LOCAL_CONFIG (or the legacy DELEGATE_TO_OLLAMA_CONFIG),
# else $DELEGATE_LOCAL_DATA_DIR/config.sh, else
# ~/.local/share/delegate-local/config.sh.
config="${DELEGATE_LOCAL_CONFIG:-${DELEGATE_TO_OLLAMA_CONFIG:-${DELEGATE_LOCAL_DATA_DIR:-$HOME/.local/share/delegate-local}/config.sh}}"
if [[ -f "$config" ]]; then
  # Defense-in-depth: skip the override if it isn't owned by the current
  # user, or if it has group/world write bits set. The trust model assumes
  # single-user dev; this catches accidents (chmod 666 / shared HOME) before
  # they become arbitrary-code-execution under our process. BSD `stat` first
  # (macOS), GNU `stat` fallback (Linux).
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
  # Two failures needing opposite remedies. "Nothing answered" means start a
  # daemon; "answered but no match" means pull a model or edit the prefs list.
  # Collapsing them sent callers to audit-models.sh on a host where no daemon
  # was running, which reports an empty inventory and explains nothing.
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
