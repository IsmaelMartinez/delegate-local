#!/usr/bin/env bash
# Pick the best installed local-LLM model for a task tier.
# Usage: pick-model.sh [--dry-run] <tier>
#   tier ∈ {code, prose, reasoning, long-context,
#           vision, embedding, premium-general, reasoning-vision}
# Prints the model name on stdout, or exits 1 if no match and 2 on usage error.
# With --dry-run, also prints the resolution trace (tier, backend, preference
# list, installed models, matched preference) to stderr so it can be inspected
# without affecting downstream pipes that consume stdout.
# --print-backend prints the resolved backend and exits; --print-installed
# prints that backend's installed models, one per line, and exits. Both take
# no tier and exist so callers (scripts/audit-models.sh) never re-derive
# routing state locally.
#
# Preference order per tier is a substring-matched list, highest capability first.
# Edit the arrays below when your installed set changes. Run `ollama list` (or
# `ls ~/.cache/huggingface/hub` for MLX) to see what you have. Prefer the
# smallest model sufficient — bigger is not better.
#
# Backend selection (env var DELEGATE_BACKEND, default "auto"):
#   auto    — probe ${MLX_HOST:-http://localhost:8080}/v1/models with a 1 s
#             timeout; if reachable, route through MLX, otherwise Ollama.
#             Default. Non-Apple-Silicon hosts and Apple Silicon hosts
#             without `mlx_lm.server` running both fall through to ollama
#             transparently — same behaviour as before the auto default
#             landed. Override the probe timeout via
#             DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT.
#
#   DELEGATE_BASE_URL is a space-separated, ordered list of OpenAI-compatible
#             base URLs. When set it supersedes backend probing entirely: each
#             is tried in order, and the first that answers GET {base}/models
#             AND holds a model this tier prefers wins. Unset (the default)
#             leaves the DELEGATE_BACKEND path untouched. A URL containing
#             userinfo (user:pass@) is rejected with exit 2 before anything is
#             probed. One trailing slash is stripped per entry.
#   DELEGATE_PROBE_TIMEOUT bounds each /models probe. Default 1 second, kept
#             low deliberately: a dead provider must cost close to nothing,
#             since cheap fallthrough is the point of the list.
#   ollama  — query `ollama list` for installed models. Skips the probe.
#   mlx     — scan the HuggingFace hub cache (~/.cache/huggingface/hub or
#             $HF_HOME/hub) for MLX-converted models. Apple Silicon only;
#             needs `mlx-lm` installed for delegate.sh to actually call them.
# Matching is case-insensitive so a single prefs list covers both backends
# (Ollama uses lowercase tags, MLX uses HF-style mixed case).
#
# Note: vision and reasoning-vision tiers resolve a model name but do NOT go
# through scripts/delegate.sh today (which lacks --image flag passthrough);
# embedding tier uses `POST /api/embed` (no `ollama` CLI subcommand exists),
# not `ollama run`. See SKILL.md for the call shape per tier.

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
print_backend=0
print_installed=0
print_resolution=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --print-prefs) print_prefs=1 ;;
    --print-backend) print_backend=1 ;;
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

# Reject userinfo before anything is probed. A user:pass@ URL would otherwise
# reach the metrics label and the --dry-run trace, writing the credential to a
# file and printing it to a terminal.
if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
  for _u in $DELEGATE_BASE_URL; do
    case "$_u" in
      *"://"*"@"*)
        echo "pick-model: DELEGATE_BASE_URL entry '$_u' contains userinfo (user:pass@); refusing" >&2
        exit 2
        ;;
    esac
  done
fi

# Provider-list resolution. Prints "<base_url><TAB><model_id>" for the first
# provider that is both reachable and holding a model this tier prefers, or
# returns 1 if none is. Reads the `prefs` array from scope, as the matcher
# below does.
#
# Provider-major rather than preference-major: the preference lists interleave
# per-provider spellings of one model (see the note above), so they rank where
# a model runs, not which capability you get. Letting them drive the outer loop
# silently re-routes tiers across runtimes at different quantisations.
resolve_via_providers() {
  local base models pref hit
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
  return 1
}

# Resolve auto backend by probing the MLX server. The probe is cheap
# (sub-second timeout, single HEAD-equivalent GET) and runs once per
# invocation. Explicit ollama|mlx skip the probe.
auto_resolve_backend() {
  local mlx_host="${MLX_HOST:-http://localhost:8080}"
  local timeout="${DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT:-1}"
  if curl -sS --max-time "$timeout" --fail "$mlx_host/v1/models" >/dev/null 2>&1; then
    echo "mlx"
  else
    echo "ollama"
  fi
}

# DELEGATE_BASE_URL supersedes backend probing entirely, so skip the probe
# rather than paying for a resolution that is about to be discarded.
if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
  backend="provider"
  backend_requested="provider"
else
backend_requested="${DELEGATE_BACKEND:-auto}"
case "$backend_requested" in
  auto)
    backend=$(auto_resolve_backend)
    trace "backend=auto -> probed MLX_HOST and resolved to '$backend'"
    ;;
  ollama|mlx)
    backend="$backend_requested"
    ;;
  *) echo "unknown backend: $backend_requested (valid: auto|ollama|mlx)" >&2; exit 2 ;;
esac
fi

# Enumerate the installed models the resolved backend can see, one per line.
# Shared by the resolution path below and by the --print-installed surface.
# scripts/audit-models.sh reports the MLX inventory through it, so on that
# backend the audit cannot show a different model set than routing consults;
# on Ollama the audit calls `ollama list` directly to keep the SIZE/MODIFIED
# columns, and the two agree because both read the same source.
list_installed() {
  # Under a provider list, "installed" means what the running providers report,
  # so report exactly that. Without this the backend=="provider" label falls
  # through to the MLX arm below and --print-installed silently reports an HF
  # cache scan that routing never consults.
  if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
    local base ids
    for base in $DELEGATE_BASE_URL; do
      base="${base%/}"
      if ! ids=$(curl -sS --fail --max-time "${DELEGATE_PROBE_TIMEOUT:-1}" \
          "$base/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null); then
        continue
      fi
      printf '%s\n' "$ids"
    done | sort -u
    return 0
  fi
  if [[ "$backend" == "ollama" ]]; then
    if ! command -v ollama >/dev/null 2>&1; then
      echo "ollama not on PATH" >&2
      exit 1
    fi
    ollama list 2>/dev/null | awk 'NR>1 {print $1}'
    return 0
  fi
  # MLX: list models in the HuggingFace hub cache. Each downloaded model
  # lives at <hub>/models--<org>--<name>/snapshots/<hash>/. A directory with
  # an empty snapshots/ (interrupted download) doesn't count as installed.
  local hub_dir="${HF_HOME:-$HOME/.cache/huggingface}/hub"
  if [[ ! -d "$hub_dir" ]]; then
    echo "MLX hub cache not found at $hub_dir" >&2
    exit 1
  fi
  local d snap stem name has_snap
  for d in "$hub_dir"/models--*; do
    [[ -d "$d" ]] || continue
    [[ -d "$d/snapshots" ]] || continue
    # Skip if every snapshot dir is empty (no weights actually present).
    has_snap=0
    for snap in "$d/snapshots"/*; do
      [[ -d "$snap" ]] || continue
      if [[ -n "$(ls -A "$snap" 2>/dev/null)" ]]; then has_snap=1; break; fi
    done
    (( has_snap )) || continue
    stem="${d##*/models--}"
    # models--mlx-community--Qwen3-0.6B-4bit -> mlx-community/Qwen3-0.6B-4bit
    name="${stem//--//}"
    printf '%s\n' "$name"
  done
}

# Backend-only surfaces. Both are tier-independent, so they answer before the
# tier argument is read — a caller asking "which backend is in effect?" has no
# tier to name. scripts/audit-models.sh uses both.
if (( print_backend )); then
  echo "$backend"
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
trace "backend=$backend"
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
config="${DELEGATE_LOCAL_CONFIG:-${DELEGATE_TO_OLLAMA_CONFIG:-$HOME/.claude/skills/delegate-local/config.sh}}"
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

# The provider list short-circuits the installed-set path: discovery is only
# ever "what a running provider reports", never a filesystem scan.
if [[ -n "${DELEGATE_BASE_URL:-}" ]]; then
  if ! _resolved=$(resolve_via_providers); then
    echo "pick-model: no provider holds a model for tier '$tier'" >&2
    echo "            tried: $DELEGATE_BASE_URL" >&2
    exit 1
  fi
  if (( print_resolution )); then
    printf '%s\n' "$_resolved"
  else
    printf '%s\n' "${_resolved#*	}"
  fi
  exit 0
fi

# Tier-dependent, so unlike --print-backend it cannot be answered before the
# tier is parsed — which is the whole reason it is a separate flag.
if (( print_resolution )); then
  echo "pick-model: --print-resolution requires DELEGATE_BASE_URL" >&2
  exit 2
fi

installed=$(list_installed)

if [[ -z "$installed" ]]; then
  echo "no models installed (backend=$backend)" >&2
  exit 1
fi

trace "installed=$(printf '%s' "$installed" | tr '\n' ' ')"

for p in "${prefs[@]}"; do
  # Case-insensitive fixed-string match so the single prefs list covers both
  # Ollama's lowercase tags (qwen3.6:35b-a3b-q8_0) and MLX's HF-style mixed
  # case (mlx-community/Qwen3.6-35B-A3B-Instruct-4bit).
  match=$(printf '%s\n' "$installed" | grep -im1 -F -- "$p" || true)
  if [[ -n "$match" ]]; then
    trace "matched preference='$p' -> model='$match'"
    echo "$match"
    exit 0
  fi
done

trace "no preference matched any installed model"
exit 1
