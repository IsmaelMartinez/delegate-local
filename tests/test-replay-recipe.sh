#!/usr/bin/env bash
# Unit tests for scripts/replay-recipe.sh — the offline half of the replay
# gate. The wrapper is a stub injected through DELEGATE_REPLAY_DELEGATE_SH, so
# no model server is touched: the stub answers by arm (the prompts directory
# it is handed) and counts its calls, which is how the cache and the
# stored-draft shortcut are asserted.
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

GOOD='Fixed at src/main.js:412 for #2632 with 531 tests.'
BAD='Fixed it.'

# The stub: answers GOOD under a prompts dir whose name contains "good" and
# BAD otherwise, reports one failed check when STUB_CHECKS names its arm,
# and appends a line per call to STUB_CALLS so a test can count them.
make_stub() {
  cat > "$1/stub-delegate.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$DELEGATE_PROMPTS_DIR $*" >> "${STUB_CALLS:-/dev/null}"
case "$DELEGATE_PROMPTS_DIR" in
  *good*) printf 'Fixed at src/main.js:412 for #2632 with 531 tests.\n' ;;
  *)      printf 'Fixed it.\n' ;;
esac
checks=0
case "$DELEGATE_PROMPTS_DIR" in *"${STUB_CHECKS:-__none__}"*) checks=1 ;; esac
echo "delegate-meta: model=\"m\" tier=\"prose\" recipe=\"rp\" checks_failed=$checks" >&2
exit 0
EOF
  chmod +x "$1/stub-delegate.sh"
}

# A corpus for recipe `rp`: N rejected cases whose draft is BAD and whose
# final is GOOD, plus one kept case (draft == final == GOOD). Every row
# carries the champion template's hash, so the champion arm reads the
# stored draft and never calls the wrapper.
seed() {
  local dir="$1" n_rejected="$2" sha="$3" i ts
  mkdir -p "$dir/drafts"
  : > "$dir/m.jsonl"
  for i in $(seq 1 "$n_rejected"); do
    ts=$(printf '2026-09-%02dT10:00:00Z' "$i")
    stem=$(printf '2026%02dT100000Z-rej%05d' "$i" "$i")
    printf '%s\n' "$BAD" > "$dir/drafts/$stem.draft.txt"
    printf '%s\n' "$GOOD" > "$dir/drafts/$stem.final.txt"
    printf '{"recipe":"rp","stdin":"The fix lives at src/main.js:412 and closes #2632; 531 tests pass.","vars":{"who":"alice"}}' > "$dir/drafts/$stem.inputs.json"
    printf '{"ts":"%s","source":"delegate","recipe":"rp","exit_status":0,"otel_span_id":"rej%05d","draft_file":"%s.draft.txt","input_file":"%s.input.txt","inputs_file":"%s.inputs.json","template_sha":"%s","checks_failed":0}\n' \
      "$ts" "$i" "$stem" "$stem" "$stem" "$sha" >> "$dir/m.jsonl"
    printf '{"ts":"%s","source":"feedback","ref_id":"rej%05d","kept":false,"reason":"dropped the anchors","final_file":"%s.final.txt"}\n' \
      "$ts" "$i" "$stem" >> "$dir/m.jsonl"
  done
  stem="20260930T100000Z-kept0001"
  printf '%s\n' "$GOOD" > "$dir/drafts/$stem.draft.txt"
  printf '{"recipe":"rp","stdin":"The fix lives at src/main.js:412 and closes #2632; 531 tests pass.","vars":{"who":"alice"}}' > "$dir/drafts/$stem.inputs.json"
  printf '{"ts":"2026-09-30T10:00:00Z","source":"delegate","recipe":"rp","exit_status":0,"otel_span_id":"kept0001","draft_file":"%s.draft.txt","inputs_file":"%s.inputs.json","template_sha":"%s","checks_failed":0}\n' \
    "$stem" "$stem" "$sha" >> "$dir/m.jsonl"
  printf '{"ts":"2026-09-30T10:00:00Z","source":"feedback","ref_id":"kept0001","kept":true}\n' >> "$dir/m.jsonl"
}

write_recipe() { # <dir> <body marker>
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
EOF
}

tmp=$(mktemp -d)
make_stub "$tmp"
write_recipe "$tmp/champion" "CHAMPION"
write_recipe "$tmp/good" "CANDIDATE"
write_recipe "$tmp/worse" "WORSE"
champ_sha=$(shasum -a 256 "$tmp/champion/rp.md" | cut -c1-12)
run() { # extra args
  DELEGATE_REPLAY_DELEGATE_SH="$tmp/stub-delegate.sh" DELEGATE_METRICS_FILE="$tmp/data/m.jsonl" \
    STUB_CALLS="$tmp/calls" bash "$SCRIPT" --champion "$tmp/champion" --out "$tmp/out" "$@" 2>&1
}

# 1. Usage errors.
EC=0; out=$(run 2>&1) || EC=$?
assert_eq 2 "$EC" "no --recipe exits 2"
EC=0; out=$(run --recipe rp --bogus 2>&1) || EC=$?
assert_eq 2 "$EC" "unknown argument exits 2"
EC=0; out=$(run --recipe nope 2>&1) || EC=$?
assert_eq 2 "$EC" "a recipe absent from the champion dir exits 2"
assert_contains "no nope.md in champion dir" "$out" "the missing recipe is named"

# 2. No replayable case.
mkdir -p "$tmp/data"; : > "$tmp/data/m.jsonl"
EC=0; out=$(run --recipe rp 2>&1) || EC=$?
assert_eq 3 "$EC" "no case for the recipe exits 3"

# 3. Baseline read: the champion alone, every output from the stored draft.
seed "$tmp/data" 2 "$champ_sha"
rm -f "$tmp/calls"; rm -rf "$tmp/out"
EC=0; out=$(run --recipe rp) || EC=$?
assert_eq 0 "$EC" "baseline read exits 0"
assert_contains "Cases:     3 (kept=1 scaffold=0 rewrote=2; newest 40)" "$out" "cases are counted by verdict"
assert_contains "Verdict: BASELINE" "$out" "no candidate yields the baseline verdict"
assert_eq "0" "$(cat "$tmp/calls" 2>/dev/null | grep -c '')" \
  "champion outputs under the same template are the stored drafts: the wrapper is never called"
# The supplied anchors are the path, the ref and three numbers (412 both
# inside main.js:412 and alone, 2632, 531); the BAD draft carries none.
assert_contains "0/5/0/0=5" "$out" "a rejected case scores the champion's five dropped anchors"
assert_contains "0/0/0/0=0" "$out" "the kept case scores zero against itself"

# 4. A candidate that carries the anchors wins the rejected cases and ties
# the kept one; two wins to none is not yet significant.
rm -f "$tmp/calls"; rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/good")
assert_eq "3" "$(grep -c '' "$tmp/calls")" "the candidate arm runs once per case"
assert_contains "$tmp/good --recipe rp --var who=alice" "$(head -1 "$tmp/calls")" \
  "the wrapper is called with the case's --var and the candidate prompts dir"
assert_contains "Summary: n=3  wins=2  losses=0  ties=1  errors=0" "$out" "wins, losses and ties are tallied"
assert_contains "Sign test: p=0.250" "$out" "two wins to none reports p=0.250"
assert_contains "Verdict: INCONCLUSIVE" "$out" "two wins is not yet significant"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c ' WIN$')" "each rejected case is a WIN"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c ' tie$')" "the kept case is a tie"

# 5. The cache: a second run against the same candidate sends nothing.
rm -f "$tmp/calls"
out2=$(run --recipe rp --candidate "$tmp/good")
assert_eq "0" "$(cat "$tmp/calls" 2>/dev/null | grep -c '')" "cached outputs are reused"
assert_contains "Summary: n=3  wins=2  losses=0  ties=1  errors=0" "$out2" "the cached run reports the same tally"

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
  STUB_CALLS="$tmp/calls" bash "$SCRIPT" --champion "$tmp/goodchampion" --out "$tmp/out" --recipe rp --candidate "$tmp/worse" 2>&1)
mv "$tmp/goodchampion" "$tmp/champion"
assert_eq "14" "$(grep -c '' "$tmp/calls")" "both arms run when the stored template differs from the champion"
assert_contains "Summary: n=7  wins=0  losses=7  ties=0" "$out" "a worse candidate loses every case"
assert_contains "Verdict: REJECT" "$out" "a significant loss is rejected"

# 9. --limit takes the newest cases; --seed adds cases the corpus lacks.
seed "$tmp/data" 2 "$champ_sha"
rm -rf "$tmp/out"
out=$(run --recipe rp --limit 1)
assert_contains "Cases:     1 " "$out" "--limit caps the case count"
assert_contains "kept0001" "$out" "--limit keeps the newest case"
cat > "$tmp/seed.json" <<EOF
[
 {"id":"seed0001","ts":"2026-08-01T00:00:00Z","recipe":"rp","stdin":"The fix lives at src/main.js:412 and closes #2632.","vars":{"who":"bob"},"draft":"$BAD","final":"$GOOD","verdict":"miss"},
 {"id":"seed0002","ts":"2026-08-02T00:00:00Z","recipe":"rp","stdin":"x","vars":{"who":"bob"},"draft":"$BAD","final":"","verdict":"miss"},
 {"id":"rej00001","ts":"2026-08-03T00:00:00Z","recipe":"rp","stdin":"x","vars":{"who":"bob"},"draft":"$BAD","final":"$GOOD","verdict":"miss"},
 {"id":"seed0003","ts":"2026-08-04T00:00:00Z","recipe":"other","stdin":"x","vars":{},"draft":"$BAD","final":"$GOOD","verdict":"miss"}
]
EOF
out=$(run --recipe rp --seed "$tmp/seed.json")
assert_contains "Cases:     4 " "$out" "a seed case with a final is added once"
assert_contains "seed0001" "$out" "the seed case is listed"
assert_not_contains "seed0002" "$out" "a seed case without a final is skipped"
assert_not_contains "seed0003" "$out" "a seed case for another recipe is skipped"
assert_eq "1" "$(printf '%s\n' "$out" | grep -c 'rej00001')" "a seed case whose id the corpus has is not duplicated"
assert_eq "bob" "$(jq -r '.vars.who' "$tmp/out/seed/seed0001.inputs.json")" "the seed case's inputs are materialised for the wrapper"

# 10. An identical candidate is reported, not measured.
rm -rf "$tmp/out"
out=$(run --recipe rp --candidate "$tmp/champion")
assert_contains "byte-identical to the champion" "$out" "a candidate equal to the champion is inconclusive without a run"

rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
