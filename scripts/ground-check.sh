#!/usr/bin/env bash
# ground-check.sh — the single runtime wrapper for the ground-check recipe.
# Reads an assembled EVIDENCE + `=== CLAIMS ===` + numbered-claims document on
# stdin (or via --evidence-file / --claims-file), runs the local model through
# `delegate.sh --recipe ground-check`, then applies the shared substring
# post-check (experiments/lib/ground-substring.sh — the SAME rule the scorer
# enforces) to downgrade any fabricated-quote verdict to UNVERIFIED and to emit
# unparseable model lines loudly rather than dropping them.
#
# It is strictly ADVISORY. Exit status is decoupled from the verdict outcome:
# the wrapper exits 0 on any successful run and reports clean=true|false as a
# FIELD on a GROUND_CHECK_SUMMARY line — never as an exit code (a non-zero exit
# on un-grounded claims is exactly the pre-commit/merge-gate affordance the
# scope boundary and the no-autonomous-merge rule forbid). delegate.sh's
# 2/3/4 exits propagate unchanged (real operational failures).
#
# Usage:
#   printf '%s\n\n=== CLAIMS ===\n%s\n' "$evidence" "$claims" | bash scripts/ground-check.sh
#   bash scripts/ground-check.sh --evidence-file diff.txt --claims-file claims.txt

set -uo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=experiments/lib/ground-substring.sh
. "$repo_root/experiments/lib/ground-substring.sh"

evidence_file_arg=""
claims_file_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence-file) evidence_file_arg="${2:-}"; [[ -n "$evidence_file_arg" ]] || { echo "--evidence-file requires a path" >&2; exit 2; }; shift 2 ;;
    --claims-file)   claims_file_arg="${2:-}";   [[ -n "$claims_file_arg" ]]   || { echo "--claims-file requires a path" >&2; exit 2; }; shift 2 ;;
    -h|--help) echo "usage: ground-check.sh [--evidence-file F --claims-file F]   (else reads the assembled doc on stdin)" >&2; exit 2 ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *) echo "unexpected arg: $1" >&2; exit 2 ;;
  esac
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
evidence_file="$work/evidence.txt"

# Assemble the stdin document and isolate the EVIDENCE portion (everything
# before the first `=== CLAIMS ===` line) for the substring post-check.
if [[ -n "$evidence_file_arg" || -n "$claims_file_arg" ]]; then
  [[ -n "$evidence_file_arg" && -n "$claims_file_arg" ]] || { echo "--evidence-file and --claims-file must be given together" >&2; exit 2; }
  [[ -f "$evidence_file_arg" ]] || { echo "evidence file not found: $evidence_file_arg" >&2; exit 2; }
  [[ -f "$claims_file_arg" ]]   || { echo "claims file not found: $claims_file_arg" >&2; exit 2; }
  cp "$evidence_file_arg" "$evidence_file"
  doc="$(cat "$evidence_file_arg")"$'\n\n'"=== CLAIMS ==="$'\n'"$(cat "$claims_file_arg")"
else
  doc="$(cat)"
  awk '/^[[:space:]]*===[[:space:]]*CLAIMS[[:space:]]*===[[:space:]]*$/{exit} {print}' <<<"$doc" > "$evidence_file"
fi

# Run the model. delegate.sh substitutes {{stdin}} with the piped document.
verdicts=$(printf '%s' "$doc" | bash "$repo_root/scripts/delegate.sh" --recipe ground-check reasoning "Output only the per-claim verdict lines, in id order.")
rc=$?
if [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi

# Parse the verdict label from the text before the first quote character.
parse_label() {
  local up
  up=$(printf '%s' "$1" | perl -CSD -pe 's/["\x{201c}\x{201d}].*$//s' | tr '[:lower:]' '[:upper:]')
  if [[ "$up" == *"NOT-STATED"* || "$up" == *"NOT STATED"* ]]; then echo "NOT-STATED"
  elif [[ "$up" == *"CONTRADICTED"* ]]; then echo "CONTRADICTED"
  elif [[ "$up" == *"UNVERIFIED"* ]]; then echo "UNVERIFIED"
  elif [[ "$up" == *"SUPPORTED"* ]]; then echo "SUPPORTED"
  else echo "INVALID"; fi
}

n_claims=0; supported=0; contradicted=0; not_stated=0; unverified=0; unparseable=0
clean=true
out=""

while IFS= read -r line; do
  [[ -z "${line//[[:space:]]/}" ]] && continue
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z]+[0-9]+)[[:space:]]*: ]]; then
    id=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
  else
    out+="UNPARSEABLE — ${line}"$'\n'; unparseable=$((unparseable+1)); clean=false; continue
  fi
  n_claims=$((n_claims+1))
  after="${line#*:}"
  quote=$(printf '%s' "$line" | perl -CSD -ne 'if (/["\x{201c}\x{201d}](.*)["\x{201c}\x{201d}]/) { print $1 }')
  label=$(parse_label "$after")

  case "$label" in
    NOT-STATED)
      out+="${id}: NOT-STATED"$'\n'; not_stated=$((not_stated+1)); clean=false ;;
    UNVERIFIED)
      out+="${id}: UNVERIFIED"$'\n'; unverified=$((unverified+1)); clean=false ;;
    SUPPORTED|CONTRADICTED)
      if [[ -z "$quote" ]]; then
        out+="${id}: UNPARSEABLE — ${after# }"$'\n'; unparseable=$((unparseable+1)); clean=false
      elif ground_quote_verifies "$quote" "$evidence_file"; then
        out+="${id}: ${label} — \"${quote}\""$'\n'
        if [[ "$label" == "SUPPORTED" ]]; then supported=$((supported+1)); else contradicted=$((contradicted+1)); clean=false; fi
      else
        out+="${id}: UNVERIFIED — \"${quote}\""$'\n'; unverified=$((unverified+1)); clean=false
      fi ;;
    *)
      out+="${id}: UNPARSEABLE — ${after# }"$'\n'; unparseable=$((unparseable+1)); clean=false ;;
  esac
done <<<"$verdicts"

printf '%s' "$out"
printf 'GROUND_CHECK_SUMMARY: clean=%s claims=%d supported=%d contradicted=%d not_stated=%d unverified=%d unparseable=%d\n' \
  "$clean" "$n_claims" "$supported" "$contradicted" "$not_stated" "$unverified" "$unparseable"
exit 0
