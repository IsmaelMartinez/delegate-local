#!/usr/bin/env bash
# Validate an incoming Ollama model against this skill's recipe library
# before adopting it as a pick-model.sh preference. Runs three regression
# gates against the candidate and reports a side-by-side verdict with
# the current tier incumbent.
#
# Usage: model-change-audit.sh <new-model> [<tier>]
#
# Args:
#   <new-model>  Ollama model tag (e.g., qwen3-coder:30b-a3b-q8_0). Must
#                already be in `ollama list`; this script never pulls.
#   <tier>       Optional. One of code|prose|reasoning|long-context|vision|
#                embedding|premium-general|reasoning-vision. If omitted,
#                tier is inferred from <new-model> against pick-model.sh
#                prefs (substring match, first hit wins). Inference falls
#                through to "no incumbent" if no tier claims the model.
#
# Gates (run in sequence; script always runs all three before printing):
#   1. Trigger eval — bash scripts/eval-skill-triggers.sh --ollama <model>.
#                     Captures recall + negative-precision. Pass: both ≥ 0.9.
#   2. Empirical scorers — bash experiments/run-baseline.sh --reps 3 <model>,
#                     then score-t4/t5/t6 (plus t7/t8 if those scorers are
#                     present in the tree). Pass per scorer: mean ≥ incumbent
#                     mean if a recent incumbent baseline exists, else ≥ 0.8.
#   3. Chat-template diff — ollama show --modelfile <model> | grep -A20
#                     '^TEMPLATE'. Flags whether the template uses think
#                     blocks, defaults a system prompt, or carries the
#                     chat_template_kwargs.enable_thinking surface.
#
# Verdicts:
#   ADOPT       all gates pass; exit 0
#   INVESTIGATE marginal degradation (any gate drops < 0.1 below incumbent
#               but ≥ floor); exit 1
#   REJECT      material degradation (any mean drops > 0.1 below incumbent,
#               trigger metric < 0.8, or chat template diverges); exit 2
#   error       gate execution failed (model not installed, scorers crashed,
#               etc.); exit 3
#
# Read-only with respect to the repo — never edits pick-model.sh. The user
# decides whether to promote based on the printed verdict.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: model-change-audit.sh <new-model> [<tier>]
  <new-model>  Ollama model tag, must be installed locally.
  <tier>       Optional: code|prose|reasoning|long-context|vision|embedding|premium-general|reasoning-vision.
               If omitted, inferred from the model name via pick-model.sh prefs.
EOF
  exit 3
}

new_model="${1:-}"
tier_arg="${2:-}"
[[ -n "$new_model" ]] || usage

if [[ -n "$tier_arg" ]]; then
  case "$tier_arg" in
    code|prose|reasoning|long-context|vision|embedding|premium-general|reasoning-vision) ;;
    *) echo "unknown tier: $tier_arg" >&2; usage ;;
  esac
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pick="$repo_root/scripts/pick-model.sh"
eval_script="$repo_root/scripts/eval-skill-triggers.sh"
baseline_script="$repo_root/experiments/run-baseline.sh"
raw_dir="$repo_root/experiments/results/raw"

# Single tmpdir for all gate logs. One trap, removes everything on exit
# regardless of which gate added what — robust to future gate additions.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Confirm the model is installed via ollama list. Substring matching
# against `ollama list` output mirrors how pick-model.sh resolves prefs;
# require an exact tag match here so a user typo doesn't silently audit
# the wrong model.
if ! command -v ollama >/dev/null 2>&1; then
  echo "ollama not on PATH" >&2
  exit 3
fi
if ! ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF -- "$new_model"; then
  echo "model not installed: $new_model" >&2
  echo "hint: run 'ollama list' to see installed tags, or 'ollama pull $new_model' first" >&2
  exit 3
fi

# Tier inference: probe each tier's prefs list for a case-insensitive
# substring match against $new_model. First tier whose prefs contain a
# matching substring wins. Mirror pick-model.sh's prefs arrays here
# Sources prefs from pick-model.sh --print-prefs so the tier definitions stay
# single-sourced. Each call shells out once (not once per tier) and parses
# the resulting tier:prefs lines locally.
infer_tier() {
  local model_lc
  model_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  local line t prefs p
  while IFS= read -r line; do
    t="${line%%:*}"
    prefs="${line#*:}"
    for p in $prefs; do
      case "$model_lc" in
        *"$p"*) echo "$t"; return 0 ;;
      esac
    done
  done < <(bash "$pick" --print-prefs)
  return 1
}

tier=""
if [[ -n "$tier_arg" ]]; then
  tier="$tier_arg"
else
  if inferred=$(infer_tier "$new_model"); then
    tier="$inferred"
    echo "inferred tier: $tier (from model name '$new_model')"
  else
    echo "could not infer tier from model name; comparing against absolute floor only"
  fi
fi

# Slug mirrors experiments/runner.sh: tr '/:.' '___'.
slug_of() { printf '%s' "$1" | tr '/:.' '___'; }
new_slug=$(slug_of "$new_model")
new_raw="$raw_dir/$new_slug.txt"

# Incumbent resolution: ask pick-model.sh for the current winner of the
# tier, using ollama backend explicitly so the auto MLX probe doesn't
# redirect us to a model the user can't compare against. If the new
# model itself happens to be the current winner, treat as "no incumbent"
# — there is no prior calibration to compare against.
incumbent=""
incumbent_slug=""
incumbent_raw=""
if [[ -n "$tier" ]]; then
  if resolved=$(DELEGATE_BACKEND=ollama bash "$pick" "$tier" 2>/dev/null); then
    if [[ "$resolved" != "$new_model" ]]; then
      incumbent="$resolved"
      incumbent_slug=$(slug_of "$incumbent")
      incumbent_raw="$raw_dir/$incumbent_slug.txt"
    fi
  fi
fi

# ---- gate 1: trigger eval ------------------------------------------------

echo
echo "=== gate 1: trigger eval against $new_model ==="
gate1_log="$tmpdir/gate1.log"
bash "$eval_script" --ollama "$new_model" >"$gate1_log" 2>&1
gate1_rc=$?
cat "$gate1_log"

new_recall="0.000"
new_neg_prec="0.000"
results_line=$(grep '^results:' "$gate1_log" | tail -1 || true)
if [[ -n "$results_line" ]]; then
  new_recall=$(printf '%s\n' "$results_line" | sed -n 's/.*recall=\([0-9.]*\).*/\1/p')
  new_neg_prec=$(printf '%s\n' "$results_line" | sed -n 's/.*negative-precision=\([0-9.]*\).*/\1/p')
fi
[[ -z "$new_recall" ]] && new_recall="0.000"
[[ -z "$new_neg_prec" ]] && new_neg_prec="0.000"

gate1_pass=0
gate1_marginal=0
if (( gate1_rc != 0 )) && (( gate1_rc != 1 )); then
  # Exit code 2 from eval-skill-triggers.sh is a transport/config error,
  # not a threshold breach. Surface that as a gate-execution error so
  # the verdict isn't a false REJECT on (e.g.) a transient network blip.
  echo "gate 1 execution error (eval-skill-triggers.sh exit $gate1_rc)" >&2
  exit 3
fi
if awk -v r="$new_recall" -v p="$new_neg_prec" 'BEGIN{ exit !(r+0 >= 0.9 && p+0 >= 0.9) }'; then
  gate1_pass=1
elif awk -v r="$new_recall" -v p="$new_neg_prec" 'BEGIN{ exit !(r+0 >= 0.8 && p+0 >= 0.8) }'; then
  gate1_marginal=1
fi

# ---- gate 2: empirical scorers ------------------------------------------

echo
echo "=== gate 2: empirical scorers (reps=3) ==="
gate2_log="$tmpdir/gate2.log"
bash "$baseline_script" --reps 3 "$new_model" >"$gate2_log" 2>&1
gate2_rc=$?
cat "$gate2_log"
if (( gate2_rc != 0 )); then
  echo "gate 2 execution error (run-baseline.sh exit $gate2_rc)" >&2
  exit 3
fi
if [[ ! -f "$new_raw" ]]; then
  echo "gate 2 execution error: expected raw file not written: $new_raw" >&2
  exit 3
fi

# Run each scorer present in the tree and capture its T<n>_SUMMARY mean.
# Scoring is per-fixture: a missing T<n> rep block is normal (T7/T8 may
# not have fixture coverage in older raw files), so a scorer that exits
# non-zero on "no reps" is skipped rather than treated as a gate failure.
score_mean_of() {
  local n="$1" raw="$2"
  local scorer="$repo_root/experiments/score-t${n}.sh"
  [[ -x "$scorer" ]] || { echo ""; return; }
  local summary
  summary=$(bash "$scorer" "$raw" 2>/dev/null | grep -E "^T${n}_SUMMARY:" | tail -1 || true)
  [[ -n "$summary" ]] || { echo ""; return; }
  printf '%s\n' "$summary" | sed -n 's/.*mean=\([0-9.]*\).*/\1/p'
}

new_t4=$(score_mean_of 4 "$new_raw")
new_t5=$(score_mean_of 5 "$new_raw")
new_t6=$(score_mean_of 6 "$new_raw")
new_t7=""
new_t8=""
[[ -x "$repo_root/experiments/score-t7.sh" ]] && new_t7=$(score_mean_of 7 "$new_raw")
[[ -x "$repo_root/experiments/score-t8.sh" ]] && new_t8=$(score_mean_of 8 "$new_raw")

incumbent_t4=""
incumbent_t5=""
incumbent_t6=""
incumbent_t7=""
incumbent_t8=""
if [[ -n "$incumbent_raw" && -f "$incumbent_raw" ]]; then
  incumbent_t4=$(score_mean_of 4 "$incumbent_raw")
  incumbent_t5=$(score_mean_of 5 "$incumbent_raw")
  incumbent_t6=$(score_mean_of 6 "$incumbent_raw")
  [[ -x "$repo_root/experiments/score-t7.sh" ]] && incumbent_t7=$(score_mean_of 7 "$incumbent_raw")
  [[ -x "$repo_root/experiments/score-t8.sh" ]] && incumbent_t8=$(score_mean_of 8 "$incumbent_raw")
fi

# Per-scorer verdict: PASS / MARGINAL / FAIL. Floor 0.80 applies when no
# incumbent baseline exists. Against an incumbent: PASS if new ≥ incumbent
# OR drop < 0.05; MARGINAL if drop < 0.10; FAIL if drop ≥ 0.10.
classify_score() {
  local new="$1" incumbent="$2"
  if [[ -z "$new" ]]; then
    echo "MISSING"
    return
  fi
  if [[ -z "$incumbent" ]]; then
    if awk -v n="$new" 'BEGIN{ exit !(n+0 >= 0.8) }'; then
      echo "PASS"
    elif awk -v n="$new" 'BEGIN{ exit !(n+0 >= 0.7) }'; then
      echo "MARGINAL"
    else
      echo "FAIL"
    fi
    return
  fi
  if awk -v n="$new" -v i="$incumbent" 'BEGIN{ exit !(n+0 >= i+0 - 0.05) }'; then
    echo "PASS"
  elif awk -v n="$new" -v i="$incumbent" 'BEGIN{ exit !(n+0 >= i+0 - 0.10) }'; then
    echo "MARGINAL"
  else
    echo "FAIL"
  fi
}

t4_status=$(classify_score "$new_t4" "$incumbent_t4")
t5_status=$(classify_score "$new_t5" "$incumbent_t5")
t6_status=$(classify_score "$new_t6" "$incumbent_t6")
t7_status="SKIPPED"
t8_status="SKIPPED"
[[ -n "$new_t7" ]] && t7_status=$(classify_score "$new_t7" "$incumbent_t7")
[[ -n "$new_t8" ]] && t8_status=$(classify_score "$new_t8" "$incumbent_t8")

# ---- gate 3: chat-template diff -----------------------------------------

echo
echo "=== gate 3: chat-template diff ==="
template_block=$(ollama show --modelfile "$new_model" 2>/dev/null \
  | awk 'BEGIN{c=0} /^TEMPLATE/{c=1; print; next} c && /^[A-Z]+[[:space:]]/{c=0} c{print}' \
  || true)
if [[ -z "$template_block" ]]; then
  # Older Ollama releases omit a TEMPLATE block when the model uses the
  # provider default. Print a placeholder so the verdict block stays
  # readable; treat absent-template as COMPATIBLE (the wrapper sends
  # user-role only, which the default template handles).
  template_block="(no TEMPLATE block in modelfile; provider default in use)"
fi
echo "$template_block"

template_note=""
template_compatible=1
case "$template_block" in
  *"<think>"*|*"</think>"*)
    template_note="uses <think> blocks — think:false dispatch handles this"
    ;;
esac
case "$template_block" in
  *"enable_thinking"*|*"chat_template_kwargs"*)
    template_note="${template_note:+$template_note; }surfaces chat_template_kwargs.enable_thinking — MLX path binds correctly"
    ;;
esac
case "$template_block" in
  *"{{ if .System }}"*|*"{{.System}}"*|*"{{ .System }}"*)
    template_note="${template_note:+$template_note; }defaults a system prompt — wrapper sends user-role only, no implicit override"
    ;;
esac

# Detect known incompatibilities. Anything with a hand-rolled tool-call
# surface, or a non-OpenAI message shape on MLX-bound payloads, would
# require wrapper changes; flag as DIVERGES so the verdict is INVESTIGATE
# at minimum.
case "$template_block" in
  *"<|tool_call|>"*|*"<tool_call>"*|*"tool_calls"*)
    template_note="${template_note:+$template_note; }tool-call surface in template — wrapper does not bind tool_calls"
    template_compatible=0
    ;;
esac

[[ -z "$template_note" ]] && template_note="no template surfaces requiring wrapper changes"

# ---- aggregate verdict --------------------------------------------------

# REJECT if any: trigger metrics below 0.8 floor, any scorer FAIL, template DIVERGES.
# INVESTIGATE if any: trigger marginal, any scorer MARGINAL.
# ADOPT otherwise.
verdict="ADOPT"
exit_code=0
if (( gate1_pass == 0 && gate1_marginal == 0 )); then
  verdict="REJECT"; exit_code=2
elif [[ "$t4_status" == "MISSING" || "$t5_status" == "MISSING" || "$t6_status" == "MISSING" ]]; then
  # Core scorer produced no result — verdict cannot be validated against
  # the recipe library on this dimension. Fail closed.
  verdict="REJECT"; exit_code=2
elif [[ "$t4_status" == "FAIL" || "$t5_status" == "FAIL" || "$t6_status" == "FAIL" || "$t7_status" == "FAIL" || "$t8_status" == "FAIL" ]]; then
  verdict="REJECT"; exit_code=2
elif (( template_compatible == 0 )); then
  verdict="REJECT"; exit_code=2
elif (( gate1_marginal == 1 )); then
  verdict="INVESTIGATE"; exit_code=1
elif [[ "$t7_status" == "MISSING" || "$t8_status" == "MISSING" ]]; then
  # Optional scorer is available but produced no result for this raw file —
  # not a strict REJECT (T7/T8 are not yet core invariants), but worth
  # surfacing for manual review.
  verdict="INVESTIGATE"; exit_code=1
elif [[ "$t4_status" == "MARGINAL" || "$t5_status" == "MARGINAL" || "$t6_status" == "MARGINAL" || "$t7_status" == "MARGINAL" || "$t8_status" == "MARGINAL" ]]; then
  verdict="INVESTIGATE"; exit_code=1
fi

fmt_score() {
  local val="$1"
  if [[ -z "$val" ]]; then echo "      "; else printf '%0.4f' "$val"; fi
}

trigger_status="PASS"
if (( gate1_pass == 0 )); then
  if (( gate1_marginal == 1 )); then trigger_status="MARGINAL"; else trigger_status="FAIL"; fi
fi
template_status="COMPATIBLE"
(( template_compatible == 0 )) && template_status="DIVERGES"

echo
echo "=== model-change-audit verdict: $verdict ==="
printf 'model:     %s\n' "$new_model"
printf 'tier:      %s\n' "${tier:-(none — no incumbent comparison)}"
printf 'incumbent: %s\n' "${incumbent:-none}"
if [[ -n "$tier" && -z "$incumbent" ]]; then
  echo "(no recent incumbent baseline; absolute floor 0.80 applied to scorer gates)"
elif [[ -n "$incumbent" && ! -f "$incumbent_raw" ]]; then
  echo "(incumbent $incumbent has no recent baseline at $incumbent_raw; absolute floor 0.80 applied)"
fi
echo
printf 'trigger eval:    recall=%s  negative_precision=%s   %s\n' "$new_recall" "$new_neg_prec" "$trigger_status"
printf 'T4 mean:         %s  (incumbent=%s)             %s\n' "$(fmt_score "$new_t4")" "$(fmt_score "$incumbent_t4")" "$t4_status"
printf 'T5 mean:         %s  (incumbent=%s)             %s\n' "$(fmt_score "$new_t5")" "$(fmt_score "$incumbent_t5")" "$t5_status"
printf 'T6 mean:         %s  (incumbent=%s)             %s\n' "$(fmt_score "$new_t6")" "$(fmt_score "$incumbent_t6")" "$t6_status"
if [[ "$t7_status" != "SKIPPED" ]]; then
  printf 'T7 mean:         %s  (incumbent=%s)             %s\n' "$(fmt_score "$new_t7")" "$(fmt_score "$incumbent_t7")" "$t7_status"
fi
if [[ "$t8_status" != "SKIPPED" ]]; then
  printf 'T8 mean:         %s  (incumbent=%s)             %s\n' "$(fmt_score "$new_t8")" "$(fmt_score "$incumbent_t8")" "$t8_status"
fi
printf 'chat template:   %s   %s\n' "$template_note" "$template_status"
echo
echo "next steps:"
echo "  ADOPT       → update pick-model.sh prefs to promote this model"
echo "  INVESTIGATE → review the per-gate output above; decide manually"
echo "  REJECT      → keep current incumbent; do not promote"

exit "$exit_code"
