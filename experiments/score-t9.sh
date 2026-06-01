#!/usr/bin/env bash
# Mechanical T9 scoring — three deterministic per-claim checks for the
# ground-check recipe (plan §3.3). Unlike T4/T8 (structural checks on one
# output) this scores per-claim verdicts against a fixture's EXPECTED labels,
# resolving each emitted verdict through the shared substring post-check FIRST
# (a SUPPORTED/CONTRADICTED whose quote is not an exact substring of the
# evidence is downgraded to UNVERIFIED), THEN scoring three checks per claim:
#
#   1. SHAPE          — exactly one parseable verdict line per fixture claim id
#                       (valid label; a SUPPORTED/CONTRADICTED line must carry
#                       an extractable quote). Separator/quote-style tolerant.
#   2. QUOTE_VERBATIM — every emitted SUPPORTED/CONTRADICTED quote is an exact
#                       substring of the evidence via the shared
#                       experiments/lib/ground-substring.sh helper (plus the
#                       MINLEN floor). NOT-STATED / post-downgrade UNVERIFIED
#                       are vacuously PASS. This is the load-bearing safety
#                       check; a non-substring quote FAILS here and is counted
#                       in quote_fab_fails.
#   3. VERDICT_MATCH  — the resolved label equals (or is in the accept-set of)
#                       the fixture EXPECTED label. This is the relevance axis
#                       the substring check provably cannot cover (it catches
#                       a true-but-irrelevant "right-quote-wrong-claim" span).
#
# Denominator is fixed at 3 × n_claims per rep (mirrors score-t4's fixed /6).
#
# Usage: score-t9.sh <raw-output-file> [--fixture-date YYYY-MM-DD]
#
# Per-rep output: rep N: K/(3·n) → frac  fails=[C2:VERDICT_MATCH,...]
# Aggregate: mean, min, max, stdev across reps + machine-parseable T9_SUMMARY
# line carrying quote_fab_fails / verdict_mismatch / per-class recall.

set -euo pipefail

fixture_date="2026-05-31"
infile=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fixture-date)
      fixture_date="${2:-}"
      [[ -n "$fixture_date" ]] || { echo "--fixture-date requires a date" >&2; exit 2; }
      shift 2
      ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$infile" ]] || { echo "unexpected extra arg: $1" >&2; exit 2; }
      infile="$1"
      shift
      ;;
  esac
done

if [[ -z "$infile" || ! -f "$infile" ]]; then
  echo "usage: score-t9.sh <raw-output-file> [--fixture-date YYYY-MM-DD]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=experiments/lib/ground-substring.sh
. "$repo_root/experiments/lib/ground-substring.sh"

fixture="$repo_root/experiments/fixtures/task-9-ground-check-${fixture_date}.txt"
if [[ ! -f "$fixture" ]]; then
  echo "T9 fixture not found: $fixture" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- Parse the fixture: EVIDENCE corpus + EXPECTED per-claim labels. -------
evidence_file="$work/evidence.txt"
awk '/^===== EVIDENCE =====$/{f=1;next} /^===== CLAIMS =====$/{f=0} f' "$fixture" > "$evidence_file"

# EXPECTED lines: "Cx: LABEL[|LABEL] [# annotation]". Strip the trailing
# annotation and surrounding whitespace before storing (plan §3.3).
exp_ids=()
exp_specs=()
while IFS= read -r eline; do
  [[ -z "${eline//[[:space:]]/}" ]] && continue
  local_id="${eline%%:*}"
  local_id="${local_id//[[:space:]]/}"
  spec="${eline#*:}"
  spec="${spec%%#*}"                                   # drop trailing annotation
  spec="${spec#"${spec%%[![:space:]]*}"}"              # strip leading whitespace (pure bash)
  spec="${spec%"${spec##*[![:space:]]}"}"              # strip trailing whitespace (pure bash)
  exp_ids+=("$local_id")
  exp_specs+=("$spec")
done < <(awk '/^===== EXPECTED =====$/{f=1;next} /^===== / && f{f=0} f' "$fixture")

n_claims=${#exp_ids[@]}
if (( n_claims == 0 )); then
  echo "no EXPECTED claims parsed from fixture: $fixture" >&2
  exit 1
fi

# Space-padded id index for O(1)-ish "is this id in the fixture set" lookups.
exp_id_index=" "
for id in "${exp_ids[@]}"; do exp_id_index+="${id} "; done

# Per-class denominators (single-label SUPPORTED / CONTRADICTED claims only;
# accept-set entries are excluded from recall).
sup_total_per_rep=0
con_total_per_rep=0
for spec in "${exp_specs[@]}"; do
  case "$spec" in
    SUPPORTED)    sup_total_per_rep=$((sup_total_per_rep + 1)) ;;
    CONTRADICTED) con_total_per_rep=$((con_total_per_rep + 1)) ;;
  esac
done

# --- Extract each T9 rep's OUTPUT section into a temp file. ----------------
awk -v work="$work" '
  /^===== T9-ground-check rep [0-9]+ =====$/ {
    if (in_rep && capture) close(out)
    rep = $4
    out = work "/rep-" rep ".txt"
    in_rep = 1
    capture = 0
    next
  }
  /^===== / { in_rep = 0; capture = 0; next }
  in_rep && /^OUTPUT:$/ { capture = 1; next }
  in_rep && capture { print > out }
' "$infile"

shopt -s nullglob
rep_files=("$work"/rep-*.txt)
shopt -u nullglob
n_reps=${#rep_files[@]}
if (( n_reps == 0 )); then
  echo "no T9 reps found in $infile" >&2
  exit 1
fi

# label_in_set <resolved-label> <expected-spec>  — accept-set membership.
label_in_set() {
  local r="$1" spec="$2" part
  local IFS='|'
  for part in $spec; do
    [[ "$part" == "$r" ]] && return 0
  done
  return 1
}

# Parse the verdict label from the text before the first quote character.
# Order matters: NOT-STATED and CONTRADICTED are checked before SUPPORTED so a
# substring never mis-classifies (none overlap, but be explicit).
parse_label() {
  local region up
  region=$(printf '%s' "$1" | perl -CSD -pe 's/["\x{201c}\x{201d}].*$//s')
  up=$(printf '%s' "$region" | tr '[:lower:]' '[:upper:]')
  if [[ "$up" == *"NOT-STATED"* || "$up" == *"NOT STATED"* ]]; then echo "NOT-STATED"
  elif [[ "$up" == *"CONTRADICTED"* ]]; then echo "CONTRADICTED"
  elif [[ "$up" == *"UNVERIFIED"* ]]; then echo "UNVERIFIED"
  elif [[ "$up" == *"SUPPORTED"* ]]; then echo "SUPPORTED"
  else echo "INVALID"; fi
}

# Score one rep. Emits a pipe-delimited record:
#   passed|total|quote_fab|verdict_mismatch|sup_matched|con_matched|fails_csv
score_one() {
  local rep_file="$1"
  local passed=0
  local total=$((3 * n_claims))
  local quote_fab=0
  local verdict_mismatch=0
  local sup_matched=0
  local con_matched=0
  local fails=""

  local idx id spec
  for (( idx=0; idx<n_claims; idx++ )); do
    id="${exp_ids[idx]}"
    spec="${exp_specs[idx]}"

    local matches matched_count first_line
    matches=$(grep -inE "^[[:space:]]*${id}[[:space:]]*:" "$rep_file" || true)
    if [[ -z "$matches" ]]; then matched_count=0; else matched_count=$(printf '%s\n' "$matches" | grep -c .); fi

    local shape=1 qv=1 vm=0 resolved="" label="" quote="" has_quote=0

    if (( matched_count == 0 )); then
      # Absent claim id → all three checks fail (plan §3.3).
      fails+="${id}:ABSENT,"
      continue
    fi

    first_line=$(printf '%s\n' "$matches" | head -n1 | sed -E 's/^[0-9]+://')
    (( matched_count > 1 )) && { shape=0; fails+="${id}:DUP,"; }

    local after
    after="${first_line#*:}"
    quote=$(printf '%s' "$first_line" | perl -CSD -ne 'if (/["\x{201c}\x{201d}](.*)["\x{201c}\x{201d}]/) { print $1 }')
    [[ -n "$quote" ]] && has_quote=1
    label=$(parse_label "$after")

    case "$label" in
      NOT-STATED|UNVERIFIED)
        resolved="$label"
        ;;
      SUPPORTED|CONTRADICTED)
        if (( has_quote == 1 )); then
          local rc
          if ground_quote_verifies "$quote" "$evidence_file"; then rc=0; else rc=$?; fi
          if (( rc == 0 )); then
            qv=1; resolved="$label"
          elif (( rc == 2 )); then
            qv=0; quote_fab=$((quote_fab + 1)); resolved="UNVERIFIED"; fails+="${id}:QUOTE_VERBATIM(MINLEN),"
          else
            qv=0; quote_fab=$((quote_fab + 1)); resolved="UNVERIFIED"; fails+="${id}:QUOTE_VERBATIM,"
          fi
        else
          shape=0; qv=0; resolved="UNVERIFIED"; fails+="${id}:SHAPE(noquote),"
        fi
        ;;
      *)
        shape=0; qv=0; resolved="INVALID"; fails+="${id}:SHAPE(label),"
        ;;
    esac

    if [[ "$label" != "INVALID" ]]; then
      if label_in_set "$resolved" "$spec"; then
        vm=1
      else
        vm=0; verdict_mismatch=$((verdict_mismatch + 1)); fails+="${id}:VERDICT_MATCH,"
      fi
    fi

    # Per-class recall: only single-label SUPPORTED/CONTRADICTED expectations.
    if [[ "$spec" == "SUPPORTED" && $vm -eq 1 ]]; then sup_matched=$((sup_matched + 1)); fi
    if [[ "$spec" == "CONTRADICTED" && $vm -eq 1 ]]; then con_matched=$((con_matched + 1)); fi

    passed=$((passed + shape + qv + vm))
  done

  # Extra verdict ids not in the fixture claim set: ignored for the denominator
  # but recorded as EXTRA:Cx (a fabricated-claim / injection signal).
  local out_ids oid
  out_ids=$(grep -oiE "^[[:space:]]*[A-Za-z]+[0-9]+[[:space:]]*:" "$rep_file" 2>/dev/null \
            | sed -E 's/[[:space:]]//g; s/://' | tr '[:lower:]' '[:upper:]' | sort -u || true)
  if [[ -n "$out_ids" ]]; then
    while IFS= read -r oid; do
      [[ -z "$oid" ]] && continue
      case "$exp_id_index" in
        *" $oid "*) : ;;
        *) fails+="EXTRA:${oid}," ;;
      esac
    done <<< "$out_ids"
  fi

  fails="${fails%,}"
  printf '%d|%d|%d|%d|%d|%d|%s\n' "$passed" "$total" "$quote_fab" "$verdict_mismatch" "$sup_matched" "$con_matched" "$fails"
}

# --- Aggregate across reps. ------------------------------------------------
SCORE_SCALE=10000
declare -a scores
declare -a per_rep_passed
declare -a per_rep_total
declare -a per_rep_fails
total_passed=0
total_checks=0
quote_fab_fails=0
verdict_mismatch_total=0
sup_matched_total=0
con_matched_total=0

for (( i=1; i<=n_reps; i++ )); do
  rep_file="$work/rep-$i.txt"
  record=$(score_one "$rep_file")
  IFS='|' read -r p t qf vm sm cm fcsv <<< "$record"
  total_passed=$((total_passed + p))
  total_checks=$((total_checks + t))
  quote_fab_fails=$((quote_fab_fails + qf))
  verdict_mismatch_total=$((verdict_mismatch_total + vm))
  sup_matched_total=$((sup_matched_total + sm))
  con_matched_total=$((con_matched_total + cm))
  per_rep_passed[i]=$p
  per_rep_total[i]=$t
  per_rep_fails[i]="$fcsv"
  scores+=( "$((p * SCORE_SCALE / t))" )
done

# Mean.
sum=0
for s in "${scores[@]}"; do sum=$((sum + s)); done
mean=$((sum / n_reps))

# Stdev (population).
sumsq=0
for s in "${scores[@]}"; do
  d=$((s - mean))
  sumsq=$((sumsq + d * d))
done
var=$((sumsq / n_reps))
stdev=$(perl -e "printf '%.0f', sqrt($var)")

# Min / max.
min=${scores[0]}
max=${scores[0]}
for s in "${scores[@]}"; do
  (( s < min )) && min=$s
  (( s > max )) && max=$s
done

# Per-class recall (derived; fixed integer math). Vacuous 1.0 when a class is
# absent from the fixture so the gate's recall guard only bites when the class
# exists.
sup_total_all=$((sup_total_per_rep * n_reps))
con_total_all=$((con_total_per_rep * n_reps))
if (( sup_total_all > 0 )); then sup_recall=$((sup_matched_total * SCORE_SCALE / sup_total_all)); else sup_recall=$SCORE_SCALE; fi
if (( con_total_all > 0 )); then con_recall=$((con_matched_total * SCORE_SCALE / con_total_all)); else con_recall=$SCORE_SCALE; fi

printf "T9 score for %s\n" "$infile"
printf "  fixture: %s\n" "$fixture"
printf "  reps: %d   claims: %d\n" "$n_reps" "$n_claims"
printf "  per-rep pass rates:\n"
for (( i=1; i<=n_reps; i++ )); do
  p=${per_rep_passed[i]}
  t=${per_rep_total[i]}
  f=${per_rep_fails[i]}
  if [[ -z "$f" ]]; then
    printf "    rep %d: %d/%d → %0.2f\n" "$i" "$p" "$t" "$(perl -e "printf '%f', $p / $t")"
  else
    printf "    rep %d: %d/%d → %0.2f  fails=%s\n" "$i" "$p" "$t" "$(perl -e "printf '%f', $p / $t")" "$f"
  fi
done
printf "  totals: %d passed / %d total across all reps\n" "$total_passed" "$total_checks"
printf "  mean: %0.2f   stdev: %0.2f   min: %0.2f   max: %0.2f\n" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")"
printf "  quote_fab_fails: %d   verdict_mismatch: %d   supported_recall: %0.2f   contradicted_recall: %0.2f\n" \
  "$quote_fab_fails" "$verdict_mismatch_total" \
  "$(perl -e "printf '%f', $sup_recall / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $con_recall / $SCORE_SCALE")"
printf "T9_SUMMARY: reps=%d claims=%d total_passed=%d total_checks=%d mean=%0.4f stdev=%0.4f min=%0.4f max=%0.4f quote_fab_fails=%d verdict_mismatch=%d supported_recall=%0.4f contradicted_recall=%0.4f\n" \
  "$n_reps" "$n_claims" "$total_passed" "$total_checks" \
  "$(perl -e "printf '%f', $mean / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $stdev / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $min / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $max / $SCORE_SCALE")" \
  "$quote_fab_fails" "$verdict_mismatch_total" \
  "$(perl -e "printf '%f', $sup_recall / $SCORE_SCALE")" \
  "$(perl -e "printf '%f', $con_recall / $SCORE_SCALE")"
