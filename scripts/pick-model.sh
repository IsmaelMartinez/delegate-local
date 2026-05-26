#!/usr/bin/env bash
# Pick the best installed local-LLM model for a task tier.
# Usage: pick-model.sh [--dry-run] <tier>
#   tier ∈ {code, prose, reasoning, long-context,
#           vision, embedding, premium-general, reasoning-vision}
# Prints the model name on stdout, or exits 1 if no match and 2 on usage error.
# With --dry-run, also prints the resolution trace (tier, backend, preference
# list, installed models, matched preference) to stderr so it can be inspected
# without affecting downstream pipes that consume stdout.
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
REASONING_PREFS="deepseek-r1:32b phi4-reasoning qwq glm-4"
LONG_CONTEXT_PREFS="qwen3.6 qwen3-next llama4:scout qwen3-coder-next llama4 glm-4"
VISION_PREFS="qwen3-vl:30b-a3b-thinking qwen3-vl"
EMBEDDING_PREFS="nomic-embed-text bge-large"
PREMIUM_GENERAL_PREFS="qwen3.5:122b"
REASONING_VISION_PREFS="phi4-reasoning-vision qwen3-vl:30b-a3b-thinking"

dry_run=0
print_prefs=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --print-prefs) print_prefs=1 ;;
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

if [[ "$backend" == "ollama" ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    echo "ollama not on PATH" >&2
    exit 1
  fi
  installed=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')
else
  # MLX: list models in the HuggingFace hub cache. Each downloaded model
  # lives at <hub>/models--<org>--<name>/snapshots/<hash>/. A directory with
  # an empty snapshots/ (interrupted download) doesn't count as installed.
  hub_dir="${HF_HOME:-$HOME/.cache/huggingface}/hub"
  if [[ ! -d "$hub_dir" ]]; then
    echo "MLX hub cache not found at $hub_dir" >&2
    exit 1
  fi
  installed=""
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
    installed+="${name}"$'\n'
  done
  installed="${installed%$'\n'}"
fi

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
