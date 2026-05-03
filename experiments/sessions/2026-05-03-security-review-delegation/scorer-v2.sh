#!/usr/bin/env bash
# Score v2-runs/* mechanically. For each cell:
# - st1 (severity): parse JSON array, count exact matches against ground truth
# - st2 (FP filter): parse JSON array, count exact matches; flag internally inconsistent rows
# - st3 (prose): parse JSON array, count items where prose is a string of 80-800 chars and contains the expected file path
# - st4 (PR comment): plaintext; pass if F1-F5 IDs all present and no "FX" placeholder
#
# Output: v2-scores.tsv (per-cell scores), printed summary table.

set -uo pipefail

cd "$(dirname "$0")"

GT_ST1='[{"id":"F1","severity":"medium"},{"id":"F2","severity":"medium"},{"id":"F3","severity":"low"},{"id":"F4","severity":"low"},{"id":"F5","severity":"info"}]'
GT_ST2='[{"id":"F1","classification":"REAL","matched_allowlist":null},{"id":"F2","classification":"REAL","matched_allowlist":null},{"id":"F3","classification":"REAL","matched_allowlist":null},{"id":"F4","classification":"REAL","matched_allowlist":null},{"id":"F5","classification":"REAL","matched_allowlist":null}]'

declare -a ST3_PATHS=("scripts/pick-model.sh" "scripts/pick-model.sh" "scripts/init.sh" "scripts/init.sh" "scripts/pick-model.sh")
declare -a IDS=(F1 F2 F3 F4 F5)

# Extract the first JSON array from a file (greedy, between first '[' and last ']').
extract_json_array() {
  local f="$1"
  awk '/^\[/{p=1} p{print} /\]$/{if(p)exit}' "$f" 2>/dev/null \
    || python3 -c "
import sys, re
text = open('$f').read()
m = re.search(r'\[.*\]', text, re.DOTALL)
print(m.group(0) if m else '')
" 2>/dev/null
}

score_st1() {
  local f="$1"
  local json
  json=$(extract_json_array "$f")
  [[ -z "$json" ]] && { echo "0/5 PARSE_FAIL"; return; }
  local matches=0
  for i in 0 1 2 3 4; do
    local id sev gt_sev
    id=${IDS[$i]}
    sev=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .severity' <<<"$json" 2>/dev/null | head -1)
    gt_sev=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .severity' <<<"$GT_ST1")
    if [[ "$sev" == "$gt_sev" ]]; then matches=$((matches+1)); fi
  done
  echo "${matches}/5"
}

score_st2() {
  local f="$1"
  local json
  json=$(extract_json_array "$f")
  [[ -z "$json" ]] && { echo "0/5 PARSE_FAIL"; return; }
  local matches=0 inconsistent=0
  for id in "${IDS[@]}"; do
    local cls aw gt_cls
    cls=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .classification' <<<"$json" 2>/dev/null | head -1)
    aw=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .matched_allowlist' <<<"$json" 2>/dev/null | head -1)
    gt_cls=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .classification' <<<"$GT_ST2")
    if [[ "$cls" == "$gt_cls" ]]; then matches=$((matches+1)); fi
    if [[ "$cls" == "ALLOWLISTED_FP" && ( "$aw" == "null" || -z "$aw" ) ]]; then
      inconsistent=$((inconsistent+1))
    fi
  done
  if (( inconsistent > 0 )); then
    echo "${matches}/5 inconsistent=${inconsistent}"
  else
    echo "${matches}/5"
  fi
}

score_st3() {
  local f="$1"
  local json
  json=$(extract_json_array "$f")
  [[ -z "$json" ]] && { echo "0/5 PARSE_FAIL"; return; }
  local valid=0
  for i in 0 1 2 3 4; do
    local id path prose plen
    id=${IDS[$i]}
    path=${ST3_PATHS[$i]}
    prose=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .prose' <<<"$json" 2>/dev/null | head -1)
    if [[ -z "$prose" || "$prose" == "null" ]]; then continue; fi
    plen=${#prose}
    if (( plen >= 80 && plen <= 800 )) && [[ "$prose" == *"$path"* ]]; then
      valid=$((valid+1))
    fi
  done
  echo "${valid}/5"
}

score_st4() {
  local f="$1"
  # Strip ANSI conservatively
  local clean
  clean=$(perl -CSD -pe 's/\e\[[\?]?[0-9;]*[a-zA-Z]//g' "$f" 2>/dev/null | tr -d '\r')
  local has_all_ids=1
  for id in F1 F2 F3 F4 F5; do
    if ! grep -q -- "$id" <<<"$clean"; then has_all_ids=0; break; fi
  done
  local has_fx=0
  if grep -q -- "FX" <<<"$clean"; then has_fx=1; fi
  if (( has_all_ids == 1 && has_fx == 0 )); then
    echo "PASS"
  else
    local reasons=""
    (( has_all_ids == 0 )) && reasons="${reasons}MISSING_ID "
    (( has_fx == 1 )) && reasons="${reasons}FX_PLACEHOLDER "
    echo "FAIL ${reasons}"
  fi
}

echo -e "model\tsubtask\trep\tscore" > v2-scores.tsv

for model_label in qwen3.6 coder-next; do
  for st in 1 2 3 4; do
    for rep in 1 2 3; do
      f="v2-runs/${model_label}-st${st}-r${rep}.txt"
      [[ ! -s "$f" ]] && { echo -e "${model_label}\t${st}\t${rep}\tNO_OUTPUT" >> v2-scores.tsv; continue; }
      case "$st" in
        1) sc=$(score_st1 "$f") ;;
        2) sc=$(score_st2 "$f") ;;
        3) sc=$(score_st3 "$f") ;;
        4) sc=$(score_st4 "$f") ;;
      esac
      echo -e "${model_label}\t${st}\t${rep}\t${sc}" >> v2-scores.tsv
    done
  done
done

echo
echo "=== Per-cell scores ==="
column -t -s $'\t' v2-scores.tsv
