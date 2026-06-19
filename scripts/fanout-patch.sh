#!/usr/bin/env bash
# fanout-patch.sh — fan-out code-patch generation with a test oracle.
#
# Draw N diverse candidate patches from a warm code model (seeds at
# temperature>0 via DELEGATE_SEED), apply-and-test each against the
# director-provided failing test, and keep the smallest diff that passes. If
# every cheap sample fails, optionally escalate to a strong model; if a
# majority refuse, hand back "the test may be wrong"; never return an
# unverified patch — the worst case is "no patch", never "a broken patch that
# looks fine".
#
# Composes two trustworthy pieces and owns only the fan-out decision logic:
#   delegate.sh --recipe fix-with-test   generation (diversity via DELEGATE_SEED)
#   apply-and-test.sh                     the oracle (apply to a copy, run pytest)
#
# Usage: fanout-patch.sh [OPTIONS] <source-dir>
#   <source-dir>  dir with source.py + test_source.py (the failing test = oracle)
# Options: --n N (5) --escalate-m M (2; 0 disables) --tier T (code)
#   --strong-tier T (reasoning) --temperature F (0.7) --timeout S (30)
#   --test-script NAME (test_source.py) --source-name NAME (source.py)
#   --why TEXT  --out FILE
# Env: FANOUT_DELEGATE_SH FANOUT_APPLY_AND_TEST_SH (sibling defaults)
#      FANOUT_BACKEND (ollama — seed works there; MLX broken until #1331)
# Exit: 0 PASS  1 NO_PASS  2 REFUSE_MAJORITY  3 USAGE
#
# Security: apply-and-test.sh runs model-generated pytest with no sandbox.
# Strictly for the director's own author-controlled source/tests and
# locally-chosen models — never untrusted source, an externally-supplied
# test, or model output from a non-local source.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
delegate_sh="${FANOUT_DELEGATE_SH:-$repo_root/scripts/delegate.sh}"
apply_sh="${FANOUT_APPLY_AND_TEST_SH:-$repo_root/scripts/apply-and-test.sh}"
backend="${FANOUT_BACKEND:-ollama}"

n=5 escalate_m=2 tier="code" strong_tier="reasoning" temperature="0.7"
timeout_secs=30 test_script="test_source.py" source_name="source.py" why=""
source_dir="" out_file=""

usage() {
  cat >&2 <<'EOF'
usage: fanout-patch.sh [--n N] [--escalate-m M] [--tier T] [--strong-tier T]
       [--temperature F] [--timeout S] [--test-script NAME] [--source-name NAME]
       [--why TEXT] [--out FILE] <source-dir>
EOF
  exit 3
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n) n="$2"; shift 2 ;;
    --escalate-m) escalate_m="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --strong-tier) strong_tier="$2"; shift 2 ;;
    --temperature) temperature="$2"; shift 2 ;;
    --timeout) timeout_secs="$2"; shift 2 ;;
    --test-script) test_script="$2"; shift 2 ;;
    --source-name) source_name="$2"; shift 2 ;;
    --why) why="$2"; shift 2 ;;
    --out) out_file="$2"; shift 2 ;;
    -h|--help) usage ;;
    --*) echo "unknown flag: $1" >&2; usage ;;
    *) if [[ -z "$source_dir" ]]; then source_dir="$1"; else echo "too many positional args" >&2; usage; fi; shift ;;
  esac
done

[[ -n "$source_dir" ]] || usage
[[ -d "$source_dir" ]] || { echo "source-dir not a directory: $source_dir" >&2; exit 3; }
[[ -f "$source_dir/$source_name" ]] || { echo "missing $source_name in $source_dir" >&2; exit 3; }
[[ -f "$source_dir/$test_script" ]] || { echo "missing $test_script in $source_dir" >&2; exit 3; }
[[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "--n must be a positive integer" >&2; exit 3; }
[[ "$escalate_m" =~ ^[0-9]+$ ]] || { echo "--escalate-m must be a non-negative integer" >&2; exit 3; }
[[ -f "$delegate_sh" ]] || { echo "delegate.sh not found: $delegate_sh" >&2; exit 3; }
[[ -f "$apply_sh" ]] || { echo "apply-and-test.sh not found: $apply_sh" >&2; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/fanout-patch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
[[ -n "$out_file" ]] || out_file="$work/selected.patch"

src_text="$(cat "$source_dir/$source_name")"
test_text="$(cat "$source_dir/$test_script")"

# Generate one candidate for (label, seed, tier); write the patch and run the
# oracle. Echoes the bare verdict word (PASS/FAIL/REFUSE/APPLY/PARSE/TIMEOUT).
generate_and_test() { # label seed gtier
  local label="$1" seed="$2" gtier="$3"
  local patch_file="$work/patch.$label" verdict_file="$work/verdict.$label"
  env DELEGATE_SEED="$seed" DELEGATE_TEMPERATURE="$temperature" DELEGATE_BACKEND="$backend" \
    "$delegate_sh" --recipe fix-with-test \
    --var source="$src_text" --var test="$test_text" --var why="$why" \
    "$gtier" "Output ONLY SEARCH/REPLACE blocks (or a single REFUSE: line). Minimal diff." \
    > "$patch_file" 2>/dev/null
  "$apply_sh" --test-script "$test_script" --source-name "$source_name" --timeout "$timeout_secs" \
    "$source_dir" "$patch_file" > "$verdict_file" 2>/dev/null
  local v; v="$(sed -n 's/^VERDICT: //p' "$verdict_file" | head -1)"
  printf '%s' "${v:-PARSE}"
}

# Rank a non-pass verdict by how close it got: FAIL applied+ran (closest),
# TIMEOUT applied but hung, APPLY did not apply, PARSE/other produced no block.
rank_of() { case "$1" in PASS) echo 5;; FAIL) echo 4;; TIMEOUT) echo 3;; APPLY) echo 2;; REFUSE) echo 1;; *) echo 0;; esac; }

passers=()            # "<size> <label>" per PASS candidate
refuse_count=0
fail_count=0
best_fail_rank=-1
best_fail_label=""

consider() { # label verdict
  local label="$1" v="$2"
  if [[ "$v" == "PASS" ]]; then
    local sz; sz=$(wc -c < "$work/patch.$label" | tr -d ' ')
    passers+=("$sz $label")
  elif [[ "$v" == "REFUSE" ]]; then
    refuse_count=$((refuse_count + 1))
  else
    fail_count=$((fail_count + 1))
    local r; r=$(rank_of "$v")
    if (( r > best_fail_rank )); then best_fail_rank=$r; best_fail_label="$label"; fi
  fi
}

echo "fanout-patch: source=$source_dir n=$n tier=$tier strong=$strong_tier temp=$temperature backend=$backend" >&2

for ((s=1; s<=n; s++)); do
  v=$(generate_and_test "s$s" "$s" "$tier")
  echo "  seed $s ($tier): $v" >&2
  consider "s$s" "$v"
done

majority=$(( (n + 1) / 2 ))

emit_result() { # outcome selected_label escalated patch_src detail
  local outcome="$1" sel="$2" esc="$3" patch_src="$4" detail="$5"
  # refuse_coexist: a passer was selected yet a majority of the OTHER samples
  # refused — the director should sanity-check that the test is the right thing
  # to be passing. "Other" = n minus the passers, per the spec wording.
  local refuse_coexist=0 others=$(( n - ${#passers[@]} ))
  (( others > 0 && refuse_count * 2 > others )) && refuse_coexist=1
  if [[ -n "$patch_src" && -f "$patch_src" ]]; then cp "$patch_src" "$out_file"; else : > "$out_file"; fi
  printf 'FANOUT_RESULT: %s n=%d passes=%d refuses=%d fails=%d selected=%s escalated=%d refuse_coexist=%d patch_file=%s\n' \
    "$outcome" "$n" "${#passers[@]}" "$refuse_count" "$fail_count" "${sel:--}" "$esc" "$refuse_coexist" "$out_file"
  [[ -n "$detail" ]] && printf 'DETAIL: %s\n' "$detail"
}

# A passer exists → smallest diff wins.
if (( ${#passers[@]} > 0 )); then
  sel_label=$(printf '%s\n' "${passers[@]}" | sort -n | head -1 | awk '{print $2}')
  emit_result PASS_LOCAL "$sel_label" 0 "$work/patch.$sel_label" ""
  exit 0
fi

# No passer, and a majority refused → the test is probably wrong. Do not escalate.
if (( refuse_count >= majority )); then
  emit_result REFUSE_MAJORITY "" 0 "" "majority of samples refused — the failing test may be wrong or self-contradictory"
  exit 2
fi

# Escalate to a strong model.
escalated=0
if (( escalate_m > 0 )); then
  escalated=1
  for ((j=1; j<=escalate_m; j++)); do
    v=$(generate_and_test "E$j" "$((n + j))" "$strong_tier")
    echo "  escalate $j ($strong_tier): $v" >&2
    if [[ "$v" == "PASS" ]]; then
      emit_result PASS_ESCALATED "E$j" 1 "$work/patch.E$j" ""
      exit 0
    fi
    consider "E$j" "$v"
  done
fi

# Still nothing — hand back the closest failing attempt.
detail="no candidate passed the test"
patch_src=""
if [[ -n "$best_fail_label" ]]; then
  patch_src="$work/patch.$best_fail_label"
  detail="$detail; closest attempt: $(sed -n 's/^DETAIL: //p' "$work/verdict.$best_fail_label" | head -1)"
fi
emit_result NO_PASS "${best_fail_label:-}" "$escalated" "$patch_src" "$detail"
exit 1
