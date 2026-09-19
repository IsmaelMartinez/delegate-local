#!/usr/bin/env bash
# Unit tests for scripts/replay-recipe.sh — the offline half of the replay
# gate. The wrapper is a stub injected through DELEGATE_REPLAY_DELEGATE_SH, so
# no model server is touched: the stub answers by arm (the prompts directory
# it is handed) and counts its calls, which is how the cache and the
# stored-draft shortcut are asserted. DELEGATE_REPLAY_MODEL pins the model so
# pick-model.sh is never probed.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/replay-recipe.sh"

pass=0
fail=0
assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected '$expected', got '$actual')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}
assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (unexpectedly found '$needle')"; fail=$((fail+1)); fi
}

echo "== replay-recipe.sh =="

STDIN='The fix lives at src/main.js:412 and closes #2632; 531 tests pass.'
GOOD='Fixed at src/main.js:412 for #2632 with 531 tests.'
BAD='Fixed it.'

# The stub answers by the prompts dir it is handed: GOOD under a name with
# "good", GOOD plus an invented ref under "invent", the piped sentence then
# GOOD under "echo", BAD otherwise; one failed check when STUB_CHECKS names
# its arm; a line per call in STUB_CALLS carrying the args and the stdin.
make_stub() {
  cat > "$1/stub-delegate.sh" <<'EOF'
#!/usr/bin/env bash
ctx=$(cat)
printf '%s :: %s\n' "$DELEGATE_PROMPTS_DIR $*" "$ctx" >> "${STUB_CALLS:-/dev/null}"
case "$DELEGATE_PROMPTS_DIR" in
  *invent*) printf 'Fixed at src/main.js:412 for #2632 with 531 tests. See also #9999.\n' ;;
  *echo*)   printf '%s Fixed at src/main.js:412 for #2632 with 531 tests.\n' "$ctx" ;;
  *good*)   printf 'Fixed at src/main.js:412 for #2632 with 531 tests.\n' ;;
  *)        printf 'Fixed it.\n' ;;
esac
checks=0
case "$DELEGATE_PROMPTS_DIR" in *"${STUB_CHECKS:-__none__}"*) checks=1 ;; esac
case "$*" in *"${STUB_FAIL_ON:-__none__}"*) echo "stub: refusing" >&2; exit 2 ;; esac
# As delegate.sh: no meta line (and no checks) under NO_META=1, and the
# checks_failed field only when it is non-zero.
[[ "${DELEGATE_LOCAL_NO_META:-}" == "1" ]] && exit 0
meta="delegate-meta: model=\"${STUB_MODEL:-stub-model}\" tier=\"prose\" recipe=\"rp\""
(( checks > 0 )) && meta="$meta checks_failed=$checks"
echo "$meta" >&2
exit 0
EOF
  chmod +x "$1/stub-delegate.sh"
}

# A corpus for recipe `rp`: N rejected cases whose draft is BAD and whose
# final is GOOD, plus one kept case (draft == final == GOOD). Every row
# carries the given template hash and model, so with the champion's hash
# and the pinned model the champion arm reads the stored draft and never
# calls the wrapper.
seed() {
  local dir="$1" n_rejected="$2" sha="$3" model="${4:-stub-model}" i ts stem
  mkdir -p "$dir/drafts"
  : > "$dir/m.jsonl"
  for i in $(seq 1 "$n_rejected"); do
    ts=$(printf '2026-09-%02dT10:00:00Z' "$i")
    stem=$(printf '2026%02dT100000Z-rej%05d' "$i" "$i")
    printf '%s\n' "$BAD" > "$dir/drafts/$stem.draft.txt"
    printf '%s\n' "$GOOD" > "$dir/drafts/$stem.final.txt"
    printf '{"recipe":"rp","tier":"prose","stdin":"%s","vars":{"who":"alice"}}' "$STDIN" > "$dir/drafts/$stem.inputs.json"
    printf '{"ts":"%s","source":"delegate","recipe":"rp","model":"%s","exit_status":0,"otel_span_id":"rej%05d","draft_file":"%s.draft.txt","input_file":"%s.input.txt","inputs_file":"%s.inputs.json","template_sha":"%s","checks_failed":0}\n' \
      "$ts" "$model" "$i" "$stem" "$stem" "$stem" "$sha" >> "$dir/m.jsonl"
    printf '{"ts":"%s","source":"feedback","ref_id":"rej%05d","kept":false,"reason":"dropped the anchors","final_file":"%s.final.txt"}\n' \
      "$ts" "$i" "$stem" >> "$dir/m.jsonl"
  done
  stem="20260930T100000Z-kept0001"
  printf '%s\n' "$GOOD" > "$dir/drafts/$stem.draft.txt"
  printf '{"recipe":"rp","tier":"prose","stdin":"%s","vars":{"who":"alice"}}' "$STDIN" > "$dir/drafts/$stem.inputs.json"
  printf '{"ts":"2026-09-30T10:00:00Z","source":"delegate","recipe":"rp","model":"%s","exit_status":0,"otel_span_id":"kept0001","draft_file":"%s.draft.txt","inputs_file":"%s.inputs.json","template_sha":"%s","checks_failed":0}\n' \
    "$model" "$stem" "$stem" "$sha" >> "$dir/m.jsonl"
  printf '{"ts":"2026-09-30T10:00:00Z","source":"feedback","ref_id":"kept0001","kept":true}\n' >> "$dir/m.jsonl"
}

write_recipe() { # <dir> <body marker> [<note>]
  mkdir -p "$1"
  cat > "$1/rp.md" <<EOF
---
tier: prose
inputs:
  stdin: string
  who: string
---
# rp

## Prompt template

\`\`\`
$2
{{stdin}} for {{who}}
\`\`\`

## Calibration notes
${3:-n/a}
EOF
}

tmp=$(mktemp -d)
make_stub "$tmp"
write_recipe "$tmp/champion" "CHAMPION"
write_recipe "$tmp/good" "CANDIDATE"
write_recipe "$tmp/worse" "WORSE"
write_recipe "$tmp/invent" "INVENT"
write_recipe "$tmp/echo" "ECHO"
write_recipe "$tmp/noted" "CHAMPION" "- 2026-09-19: a dated note, prose only"
. "$REPO/scripts/lib/recipe.sh"
champ_sha=$(recipe_template_sha "$tmp/champion/rp.md")
# The cache key carries a digest of the model id, not its name.
mkey=$(printf '%s' stub-model | shasum -a 256 | cut -c1-10)
run() { # extra args
  DELEGATE_REPLAY_DELEGATE_SH="$tmp/stub-delegate.sh" DELEGATE_METRICS_FILE="$tmp/data/m.jsonl" \
    DELEGATE_REPLAY_MODEL=stub-model STUB_CALLS="$tmp/calls" \
    bash "$SCRIPT" --champion "$tmp/champion" --out "$tmp/out" "$@" 2>&1
}
calls() { cat "$tmp/calls" 2>/dev/null | grep -c ''; }

# 1. Usage errors.
EC=0; out=$(run 2>&1) || EC=$?
assert_eq 2 "$EC" "no --recipe exits 2"
EC=0; out=$(run --recipe rp --bogus 2>&1) || EC=$?
assert_eq 2 "$EC" "unknown argument exits 2"
EC=0; out=$(run --recipe nope 2>&1) || EC=$?
assert_eq 2 "$EC" "a recipe absent from the champion dir exits 2"
assert_contains "no nope.md in champion dir" "$out" "the missing recipe is named"
EC=0; out=$(run --recipe 'a/b' 2>&1) || EC=$?
assert_eq 2 "$EC" "a recipe name with a path separator exits 2"

# 2. No replayable case.
mkdir -p "$tmp/data"; : > "$tmp/data/m.jsonl"
EC=0; out=$(run --recipe rp 2>&1) || EC=$?
assert_eq 3 "$EC" "no case for the recipe exits 3"

# 3. Baseline read: the champion alone, every output from the stored draft.
seed "$tmp/data" 2 "$champ_sha"
rm -f "$tmp/calls"; rm -rf "$tmp/out"
EC=0; out=$(run --recipe rp) || EC=$?
assert_eq 0 "$EC" "baseline read exits 0"
assert_contains "Model:     stub-model" "$out" "the pinned model is reported"
assert_contains "Cases:     3 (kept=1 scaffold=0 rewrote=2; newest 40)" "$out" "cases are counted by verdict"
assert_contains "Verdict: BASELINE" "$out" "no candidate yields the baseline verdict"
assert_eq "0" "$(calls)" \
  "champion outputs under the same template and model are the stored drafts: the wrapper is never called"
# The supplied anchors are the path, the ref and three numbers (412 both
# inside main.js:412 and alone, 2632, 531); the BAD draft carries none.
assert_contains "0/5/0/0/0=5" "$out" "a rejected case scores the champion's five dropped anchors"
assert_contains "0/0/0/0/0=0" "$out" "the kept case scores zero against itself"
assert_eq "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$tmp/out/"*kept0001*.out.txt)" \
  "cache files are private (600)"

# 4. A candidate that carries the anchors wins the rejected cases and ties
# the kept one; two wins to none is not yet significant.
rm -f "$tmp/calls"; rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/good")
assert_eq "3" "$(calls)" "the candidate arm runs once per case"
assert_contains "$tmp/good --recipe rp --var who=alice --tier prose :: $STDIN" "$(head -1 "$tmp/calls")" \
  "the wrapper is called with the case's --var, its tier and its stdin under the candidate prompts dir"
assert_contains "Summary: n=3  wins=2  losses=0  ties=1  errors=0" "$out" "wins, losses and ties are tallied"
assert_contains "Sign test: p=0.250" "$out" "two wins to none reports p=0.250"
assert_contains "Verdict: INCONCLUSIVE" "$out" "two wins is not yet significant"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c ' WIN$')" "each rejected case is a WIN"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c ' tie$')" "the kept case is a tie"

# 5. The cache: a second run against the same candidate sends nothing; an
# output without its checks sidecar (an interrupted run) is a miss.
rm -f "$tmp/calls"
out2=$(run --recipe rp --candidate "$tmp/good")
assert_eq "0" "$(calls)" "cached outputs are reused"
assert_contains "Summary: n=3  wins=2  losses=0  ties=1  errors=0" "$out2" "the cached run reports the same tally"
cand_sha=$(recipe_template_sha "$tmp/good/rp.md")
rm -f "$tmp/out/kept0001.$cand_sha.$mkey.checks"
rm -f "$tmp/calls"
out2=$(run --recipe rp --candidate "$tmp/good")
assert_eq "1" "$(calls)" "an output with no checks sidecar is regenerated"
assert_contains "Summary: n=3  wins=2  losses=0  ties=1  errors=0" "$out2" "the regenerated case scores as before"

# 6. Six wins to none clears the gate.
seed "$tmp/data" 6 "$champ_sha"
rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/good")
assert_contains "Summary: n=7  wins=6  losses=0  ties=1" "$out" "six rejected cases yield six wins"
assert_contains "Sign test: p=0.016" "$out" "six wins to none reports p=0.016"
assert_contains "Verdict: ACCEPT" "$out" "six wins to none is accepted"
assert_contains "Newest third (3 cases)" "$out" "the newest-third line names its size"

# 7. A rise in failed checks blocks acceptance even with the wins.
rm -rf "$tmp/out"
out=$(STUB_CHECKS=good run --recipe rp --candidate "$tmp/good")
assert_contains "Checks failed: champion=0  candidate=7" "$out" "failed checks are summed per arm from the meta line"
assert_contains "Verdict: INCONCLUSIVE — more wins than losses, but failed checks rose" "$out" \
  "more failed checks blocks acceptance"

# 8. A candidate that loses is rejected. The champion is re-run here
# because the stored drafts carry another template's hash.
seed "$tmp/data" 6 "otherotherot"
rm -rf "$tmp/out"; rm -f "$tmp/calls"
mv "$tmp/champion" "$tmp/goodchampion"
out=$(DELEGATE_REPLAY_DELEGATE_SH="$tmp/stub-delegate.sh" DELEGATE_METRICS_FILE="$tmp/data/m.jsonl" \
  DELEGATE_REPLAY_MODEL=stub-model STUB_CALLS="$tmp/calls" \
  bash "$SCRIPT" --champion "$tmp/goodchampion" --out "$tmp/out" --recipe rp --candidate "$tmp/worse" 2>&1)
mv "$tmp/goodchampion" "$tmp/champion"
assert_eq "14" "$(calls)" "both arms run when the stored template differs from the champion"
assert_contains "Summary: n=7  wins=0  losses=7  ties=0" "$out" "a worse candidate loses every case"
assert_contains "Verdict: REJECT" "$out" "a significant loss is rejected"

# 9. A stored draft from another model, or one cut at the byte cap, does
# not stand in for the champion.
seed "$tmp/data" 2 "$champ_sha" "other-model"
rm -rf "$tmp/out"; rm -f "$tmp/calls"
out=$(run --recipe rp)
assert_eq "3" "$(calls)" "a draft produced by another model is regenerated for the champion arm"
seed "$tmp/data" 2 "$champ_sha"
printf '\n[truncated at 20 bytes by DELEGATE_DRAFT_MAX_BYTES]\n' >> "$tmp/data/drafts/202601T100000Z-rej00001.draft.txt"
rm -rf "$tmp/out"; rm -f "$tmp/calls"
out=$(run --recipe rp)
assert_eq "1" "$(calls)" "a draft cut at the byte cap is regenerated, the others are read from disk"
assert_not_contains "[truncated at" "$(cat "$tmp/out/rej00001.$champ_sha.$mkey.out.txt")" \
  "the truncated case's champion output is the fresh generation, not the cut draft"

# 9b. The wrapper resolves its own model; a run on another model is an
# error, not a cached output under the pinned model's key, and a wrapper
# that reports no meta line (NO_META inherited, which also skips the
# checks) is an error too — the replay forces the line on.
seed "$tmp/data" 2 "otherotherot"
rm -rf "$tmp/out"; rm -f "$tmp/calls"
out=$(STUB_MODEL=some-other-model run --recipe rp)
assert_contains "ERR (champion)" "$out" "a run on a model other than the pinned one is an error"
assert_contains "Verdict: ERROR — every case failed to run" "$out" "model mismatch on every case is the error verdict"
assert_contains "ran on some-other-model, the replay measures stub-model" "$(cat "$tmp/out"/*.err.txt)" \
  "the err file names both models"
rm -rf "$tmp/out"; rm -f "$tmp/calls"
out=$(DELEGATE_LOCAL_NO_META=1 run --recipe rp)
assert_contains "Verdict: BASELINE" "$out" "an inherited NO_META=1 is overridden so the wrapper still reports"
assert_eq "3" "$(calls)" "the three regenerated cases ran"

# 9c. Bytes round-trip: a --var ending in a newline keeps it, and a prompt
# that starts with an option-like token is passed after -- as the prompt.
seed "$tmp/data" 1 "otherotherot"
printf '{"recipe":"rp","tier":"prose","stdin":"s","vars":{"who":"alice\\n"},"prompt":"--tier is not a flag here"}' > "$tmp/data/drafts/202601T100000Z-rej00001.inputs.json"
rm -rf "$tmp/out"; rm -f "$tmp/calls"
out=$(run --recipe rp)
assert_contains $'--var who=alice\n --tier prose -- --tier is not a flag here :: s' "$(cat "$tmp/calls")" \
  "a --var keeps its trailing newline and the prompt follows -- verbatim"

# 10. Invented anchors and echoed sentences count against an output, so a
# kept case is a regression guard rather than a free tie.
seed "$tmp/data" 2 "$champ_sha"
rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/invent")
assert_contains "0/0/2/0/0=2" "$out" "an invented ref scores under invented (the ref and its number)"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c ' LOSS$')" "the kept case is a LOSS when the candidate invents"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c ' WIN$')" "the rejected cases still win (2 defects against 5)"
rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/echo")
assert_contains "0/0/0/1/0=1" "$out" "a piped sentence handed back scores under echoed"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c ' LOSS$')" "the kept case is a LOSS when the candidate echoes what the shipped text did not"

# 10b. A case that fails to run is neither a win nor a loss, and its
# presence makes the verdict inconclusive whatever the others say; a
# stored-draft copy that fails is an error too, not a zero-score arm.
seed "$tmp/data" 6 "$champ_sha"
printf '{"recipe":"rp","tier":"prose","stdin":"%s","vars":{"who":"zed"}}' "$STDIN" > "$tmp/data/drafts/202601T100000Z-rej00001.inputs.json"
rm -rf "$tmp/out"
out=$(STUB_FAIL_ON=who=zed run --recipe rp --candidate "$tmp/good")
assert_contains "ERR (candidate)" "$out" "a case the wrapper refuses is marked ERR"
assert_contains "Summary: n=7  wins=5  losses=0  ties=1  errors=1" "$out" "the errored case is left out of the tally"
assert_contains "Verdict: INCONCLUSIVE — 1 case(s) failed to run" "$out" "an errored case blocks acceptance even at five wins to none"
seed "$tmp/data" 2 "$champ_sha"
chmod 000 "$tmp/data/drafts/202601T100000Z-rej00001.draft.txt"
rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/good")
chmod 600 "$tmp/data/drafts/202601T100000Z-rej00001.draft.txt"
assert_contains "ERR (champion)" "$out" "a stored draft that cannot be copied is an error, not a zero-score champion"
assert_contains "Verdict: INCONCLUSIVE — 1 case(s) failed to run" "$out" "the copy failure blocks the verdict"

# 10c. A verdict that names only a timestamp is not a case: two delegations
# can share the second, and a replay takes no case it cannot be sure of.
seed "$tmp/data" 2 "$champ_sha"
stem="20260915T100000Z-tsonly01"
printf '%s\n' "$BAD" > "$tmp/data/drafts/$stem.draft.txt"
printf '%s\n' "$GOOD" > "$tmp/data/drafts/$stem.final.txt"
printf '{"recipe":"rp","tier":"prose","stdin":"%s","vars":{"who":"alice"}}' "$STDIN" > "$tmp/data/drafts/$stem.inputs.json"
printf '{"ts":"2026-09-15T10:00:00Z","source":"delegate","recipe":"rp","model":"stub-model","exit_status":0,"otel_span_id":"tsonly01","draft_file":"%s.draft.txt","inputs_file":"%s.inputs.json","template_sha":"%s","checks_failed":0}\n' \
  "$stem" "$stem" "$champ_sha" >> "$tmp/data/m.jsonl"
printf '{"ts":"2026-09-15T10:00:00Z","source":"feedback","ref_ts":"2026-09-15T10:00:00Z","kept":false,"reason":"r","final_file":"%s.final.txt"}\n' "$stem" >> "$tmp/data/m.jsonl"
rm -rf "$tmp/out"
out=$(run --recipe rp)
assert_contains "Cases:     3 " "$out" "a ts-only verdict adds no case"
assert_not_contains "tsonly01" "$out" "the ts-only delegation is not listed"

# 10d. A token is present only as a whole token: #12 is not in #123, but
# 412 is in main.js:412 and a backticked name matches its bare spelling.
. "$REPO/scripts/lib/pair-score.sh"
printf 'see #123 and main.js:412 and inLocale() here\n' > "$tmp/absent.txt"
assert_eq "#12" "$(printf '#12\n412\ninlocale()\n' | absent_from "$tmp/absent.txt")" \
  "absent_from: #12 is absent from #123 while 412 and inlocale() are present"

# 11. Inputs that are not valid JSON are skipped, not run.
seed "$tmp/data" 2 "$champ_sha"
printf '{"recipe":"rp","stdin":"x' > "$tmp/data/drafts/202601T100000Z-rej00001.inputs.json"
rm -rf "$tmp/out"
out=$(run --recipe rp)
assert_contains "Cases:     2 " "$out" "a case with unreadable inputs is left out"
assert_contains "is not valid JSON" "$out" "the skipped case is named on stderr"

# 12. --limit takes the newest cases; --seed adds cases the corpus lacks.
seed "$tmp/data" 2 "$champ_sha"
rm -rf "$tmp/out"
out=$(run --recipe rp --limit 1)
assert_contains "Cases:     1 " "$out" "--limit caps the case count"
assert_contains "kept0001" "$out" "--limit keeps the newest case"
cat > "$tmp/seed.json" <<EOF
[
 {"id":"seed0001","ts":"2026-08-01T00:00:00Z","recipe":"rp","stdin":"$STDIN","vars":{"who":"bob"},"draft":"$BAD","final":"$GOOD","verdict":"miss"},
 {"id":"seed0002","ts":"2026-08-02T00:00:00Z","recipe":"rp","stdin":"x","vars":{"who":"bob"},"draft":"$BAD","final":"","verdict":"miss"},
 {"id":"rej00001","ts":"2026-08-03T00:00:00Z","recipe":"rp","stdin":"x","vars":{"who":"bob"},"draft":"$BAD","final":"$GOOD","verdict":"miss"},
 {"id":"seed0003","ts":"2026-08-04T00:00:00Z","recipe":"other","stdin":"x","vars":{},"draft":"$BAD","final":"$GOOD","verdict":"miss"},
 {"id":"bad.id","ts":"2026-08-05T00:00:00Z","recipe":"rp","stdin":"x","vars":{"who":"bob"},"draft":"$BAD","final":"$GOOD","verdict":"miss"},
 {"id":"nostdin1","ts":"2026-08-06T00:00:00Z","recipe":"rp","vars":{"who":"bob"},"draft":"$BAD","final":"$GOOD","verdict":"miss"}
]
EOF
rm -f "$tmp/calls"
out=$(run --recipe rp --seed "$tmp/seed.json" --candidate "$tmp/good")
assert_contains "Cases:     5 " "$out" "seed cases with a final are added once"
assert_contains "seed0001" "$out" "the seed case is listed"
assert_not_contains "seed0002" "$out" "a seed case without a final is skipped"
assert_not_contains "seed0003" "$out" "a seed case for another recipe is skipped"
# Table rows only: with a candidate the progress line on stderr names the
# case too.
assert_eq "1" "$(printf '%s\n' "$out" | grep -c '^  rej00001 ')" "a seed case whose id the corpus has is not duplicated"
assert_contains "seed id 'bad.id' skipped" "$out" "a seed id outside [A-Za-z0-9_-] is skipped and named"
assert_eq "bob" "$(jq -r '.vars.who' "$tmp/out/seed/seed0001.inputs.json")" "the seed case's inputs are materialised for the wrapper"
# A seed case has no template hash, so both arms run it: two calls, each
# with nothing after the separator.
assert_eq "2" "$(grep -c -- ':: $' "$tmp/calls")" \
  "a seed case without stdin pipes an empty context on both arms"
assert_eq "0" "$(grep -c -- ':: null$' "$tmp/calls")" \
  "a seed case without stdin never pipes the word null"

# 13. An identical candidate is reported, not measured; a notes-only edit
# hashes the same as the champion.
rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/champion")
assert_contains "identical to the champion" "$out" "a candidate equal to the champion is inconclusive without a run"
out=$(run --recipe rp --candidate "$tmp/noted")
assert_contains "identical to the champion" "$out" "a candidate that differs only in its calibration notes is the same template"

rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
