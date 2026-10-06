#!/usr/bin/env bash
# Unit tests for scripts/export-verdicts.sh (#637) over a fixture corpus.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
SCRIPT="$REPO/scripts/export-verdicts.sh"

data="$TEST_ROOT/data"
mkdir -p "$data/drafts"
d="$data/drafts"
# Six delegations: a hit, a scaffold, a miss, a ritual, one whose draft is
# gone and one whose draft name tries to leave the drafts dir; plus one
# before --since. Two days, so --holdout-from can split them.
row() { # ts id recipe draft_file
  printf '{"ts":"%s","otel_span_id":"%s","recipe":"%s","template_sha":"t1","model":"m","project":"p","draft_file":"%s","input_file":"%s.input.txt","inputs_file":"%s.inputs.json"}\n' \
    "$1" "$2" "$3" "$4" "$2" "$2"
}
verdict() { # ts id kept scaffold reason final_file final_preexisting
  printf '{"source":"feedback","ts":"%s","ref_id":"%s","kept":%s,"scaffold":%s,"reason":"%s","final_file":"%s","final_preexisting":%s}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
{
  row 2026-09-19T10:00:00Z old commit-message old.draft.txt
  verdict 2026-09-19T10:01:00Z old true false "" "" false
  row 2026-10-01T10:00:00Z hit commit-message hit.draft.txt
  verdict 2026-10-01T10:01:00Z hit true false "" "" false
  row 2026-10-01T11:00:00Z sca pr-description sca.draft.txt
  verdict 2026-10-01T11:01:00Z sca false true "trimmed a paragraph" sca.final.txt false
  row 2026-10-02T10:00:00Z mis maintainer-reply mis.draft.txt
  verdict 2026-10-02T10:01:00Z mis false false "wrong fact" mis.final.txt false
  row 2026-10-02T11:00:00Z rit maintainer-review-reply rit.draft.txt
  verdict 2026-10-02T11:01:00Z rit false false "already approved" rit.final.txt true
  row 2026-10-02T12:00:00Z gon commit-message gon.draft.txt
  verdict 2026-10-02T12:01:00Z gon true false "" "" false
  row 2026-10-02T13:00:00Z esc commit-message ../escape.draft.txt
  verdict 2026-10-02T13:01:00Z esc true false "" "" false
} > "$data/metrics.jsonl"
for id in old hit sca mis rit esc; do
  printf 'draft %s\n' "$id" > "$d/$id.draft.txt"
  printf 'input %s\n' "$id" > "$d/$id.input.txt"
  printf '{"vars":{"why":"%s"}}' "$id" > "$d/$id.inputs.json"
done
printf 'draft escape\n' > "$data/escape.draft.txt"
printf 'final sca\n' > "$d/sca.final.txt"
printf 'final mis\n' > "$d/mis.final.txt"
printf 'final rit\n' > "$d/rit.final.txt"
# A quarantined final is dropped to null.
printf 'mis.final.txt\tmisattributed\n' > "$data/suspect-finals.tsv"

out="$TEST_ROOT/out"
run() { DELEGATE_LOCAL_DATA_DIR="$data" bash "$SCRIPT" --out "$out" "$@"; }
rec() { jq -c --arg id "$1" 'select(.id == $id)' "$out/dev.jsonl" "$out/holdout.jsonl"; }

echo "default export"
summary=$(run --holdout-from 2026-10-02)
assert_eq "hit" "$(rec hit | jq -r .verdict)" "kept maps to hit"
assert_eq "scaffold" "$(rec sca | jq -r .verdict)" "scaffold stays scaffold"
assert_eq "miss" "$(rec mis | jq -r .verdict)" "rewrote maps to miss"
assert_eq "trimmed a paragraph" "$(rec sca | jq -r .reason)" "the reason is carried"
assert_eq "draft sca" "$(rec sca | jq -r .draft | head -1)" "the draft text is inlined"
assert_eq "input sca" "$(rec sca | jq -r .input | head -1)" "the rendered input is inlined"
assert_eq "sca" "$(rec sca | jq -r .inputs.vars.why)" "inputs.json is inlined as an object"
assert_eq "final sca" "$(rec sca | jq -r .final | head -1)" "the final is inlined"
assert_eq "null" "$(rec mis | jq -r .final)" "a quarantined final is dropped"
assert_eq "" "$(rec rit)" "a ritual row is left out by default"
assert_eq "" "$(rec old)" "a row before --since is left out"
assert_eq "" "$(rec gon)" "a row without a stored draft is left out"
assert_eq "" "$(rec esc)" "a draft name leaving the drafts dir is not read"
assert_contains "skipped: 1 ritual, 2 without a stored draft" "$summary" "the summary counts what was skipped"
assert_eq "2" "$(wc -l < "$out/dev.jsonl" | tr -d ' ')" "dev holds the days before the cut"
assert_eq "1" "$(wc -l < "$out/holdout.jsonl" | tr -d ' ')" "holdout holds the cut day on"
assert_contains "pr-description" "$summary" "the summary lists N per recipe"
assert_not_contains "pass --holdout-from" "$summary" "a given cut is not re-suggested"

echo "options"
summary=$(run --include-ritual --holdout-from 2026-10-02)
assert_eq "ritual" "$(rec rit | jq -r .verdict)" "--include-ritual keeps ritual rows"
assert_eq "true" "$(rec rit | jq -r .ritual)" "and flags them"
summary=$(run)
assert_contains "pass --holdout-from" "$summary" "a computed cut is printed for freezing"
first=$(shasum "$out/dev.jsonl" "$out/holdout.jsonl")
run >/dev/null
assert_eq "$first" "$(shasum "$out/dev.jsonl" "$out/holdout.jsonl")" "a rerun writes identical files"

echo "errors"
DELEGATE_LOCAL_DATA_DIR="$data" bash "$SCRIPT" --out "$REPO/tests" >/dev/null 2>&1
assert_eq "2" "$?" "an output dir inside a git checkout is refused"
run --since 2026-9-1 >/dev/null 2>&1
assert_eq "2" "$?" "a malformed date exits 2"
run --holdout-from >/dev/null 2>&1
assert_eq "2" "$?" "a value-less option exits 2"
DELEGATE_LOCAL_DATA_DIR="$TEST_ROOT/none" bash "$SCRIPT" --out "$out" >/dev/null 2>&1
assert_eq "1" "$?" "a missing metrics file exits 1"

finish
