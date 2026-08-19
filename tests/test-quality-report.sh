#!/usr/bin/env bash
# Unit tests for scripts/quality-report.sh using fixture JSONL. The keyword and
# arg-validation paths are deterministic (no model). The --classify path is
# exercised against a stub delegate.sh via DELEGATE_QUALITY_DELEGATE_SH so the
# test stays offline.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/quality-report.sh"

pass=0
fail=0
assert_eq() {
  local e="$1" a="$2" n="$3"
  if [[ "$e" == "$a" ]]; then echo "  PASS  $n"; pass=$((pass+1))
  else echo "  FAIL  $n (expected '$e', got '$a')"; fail=$((fail+1)); fi
}
assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}

# --- arg validation --------------------------------------------------------
EC=0; out=$(bash "$SCRIPT" --file /nonexistent/x.jsonl 2>&1) || EC=$?
assert_eq 2 "$EC" "missing file -> exit 2"

empty=$(mktemp); : > "$empty"
EC=0; out=$(bash "$SCRIPT" --file "$empty" 2>&1) || EC=$?
assert_eq 0 "$EC" "empty file -> exit 0"
assert_contains "no feedback rows" "$out" "empty file message"
rm -f "$empty"

f=$(mktemp)
echo '{"ts":"2026-06-01T00:00:00Z","source":"feedback","kept":true,"reason":"used verbatim"}' > "$f"
EC=0; bash "$SCRIPT" --file "$f" --since 2026-01-01 --days 7 >/dev/null 2>&1 || EC=$?
assert_eq 2 "$EC" "--since + --days mutually exclusive -> exit 2"
EC=0; bash "$SCRIPT" --file "$f" --days abc >/dev/null 2>&1 || EC=$?
assert_eq 2 "$EC" "non-integer --days -> exit 2"
EC=0; bash "$SCRIPT" --file "$f" --days 0 >/dev/null 2>&1 || EC=$?
assert_eq 2 "$EC" "zero --days -> exit 2"
EC=0; bash "$SCRIPT" --file "$f" --since not-a-date >/dev/null 2>&1 || EC=$?
assert_eq 2 "$EC" "invalid --since -> exit 2"
EC=0; bash "$SCRIPT" --file "$f" --bogus >/dev/null 2>&1 || EC=$?
assert_eq 2 "$EC" "unknown flag -> exit 2"
rm -f "$f"

# --- keyword mode on a known fixture ---------------------------------------
# 5 feedback rows: clean hit, fixed hit, ambiguous hit, no-reason hit, miss.
fx=$(mktemp)
cat > "$fx" <<'EOF'
{"ts":"2026-06-01T10:00:00Z","source":"feedback","kept":true,"reason":"used verbatim, no edits, 6/6 checks"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","kept":true,"reason":"one mechanical edit required: stripped a hallucinated PR number before commit"}
{"ts":"2026-06-01T10:02:00Z","source":"feedback","kept":true,"reason":"anchored prompt produced flowing prose paragraphs"}
{"ts":"2026-06-01T10:03:00Z","source":"feedback","kept":true}
{"ts":"2026-06-01T10:04:00Z","source":"feedback","kept":false,"reason":"trailing participial padding tail had to be removed"}
{"ts":"2026-06-01T10:05:00Z","source":"delegate","tier":"prose","model":"m","exit_status":0}
EOF
out=$(bash "$SCRIPT" --file "$fx" --tier human 2>/dev/null)
assert_contains "mode: keyword heuristic" "$out" "keyword: mode label"
assert_contains "Verdicts:                 5  (4 hits, 1 misses, 0 scaffold)" "$out" "keyword: verdict counts (delegate row ignored)"
assert_contains "Reason coverage:          4 / 5" "$out" "keyword: reason coverage excludes no-reason hit"
assert_contains "Raw hit-rate (used):      80%   (4/5)" "$out" "keyword: raw hit-rate"
assert_contains "clean hit (used as-is):          1" "$out" "keyword: one clean hit"
assert_contains "fixed hit (used, then edited):   1" "$out" "keyword: one fixed hit"
assert_contains "ambiguous hit (keyword unsure):   1" "$out" "keyword: one ambiguous hit"
assert_contains "miss (rewritten / discarded):    1" "$out" "keyword: one miss"
assert_contains "Indeterminate (no reason):" "$out" "keyword: indeterminate label"

# window: --since after all rows -> empty window note
EC=0; out=$(bash "$SCRIPT" --file "$fx" --tier human --since 2027-01-01 2>&1) || EC=$?
assert_eq 0 "$EC" "future --since -> exit 0"
assert_contains "no feedback rows" "$out" "future --since -> empty note"

# --- --classify against a stub model ---------------------------------------
# Stub delegate.sh: reads the numbered batch on stdin, echoes "N: <LABEL>"
# cycling through a fixed category sequence so the aggregation is deterministic.
stub=$(mktemp); chmod +x "$stub"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
# Ignore all args; read numbered notes on stdin, assign categories by line order.
labels=(CLEAN FAITHFULNESS PADDING STRUCTURAL)
i=0
while IFS= read -r line; do
  [[ "$line" =~ ^([0-9]+)\. ]] || continue
  n="${BASH_REMATCH[1]}"
  echo "$n: ${labels[$(( i % 4 ))]}"
  i=$((i+1))
done
STUB
out=$(DELEGATE_QUALITY_DELEGATE_SH="$stub" bash "$SCRIPT" --file "$fx" --tier human --classify 2>/dev/null)
assert_contains "mode: local-model classification" "$out" "classify: mode label"
# 4 reasoned rows -> stub labels them CLEAN, FAITHFULNESS, PADDING, STRUCTURAL in order.
# rows: 1=clean-hit(CLEAN), 2=fixed-hit(FAITHFULNESS), 3=hit(PADDING), 4=miss(STRUCTURAL).
assert_contains "clean hit (used as-is):          1" "$out" "classify: one clean hit"
assert_contains "Failure modes in the" "$out" "classify: failure-mode section present"
assert_contains "faithfulness     1" "$out" "classify: one faithfulness problem"
rm -f "$stub"

# --- --classify with a parse gap (model returns no label for some rows) ------
# Rows missing a classification must be indeterminate, NOT counted as fixed/miss
# problem cases, and the breakdown percentages must use the classified count as
# the denominator (Copilot findings on PR #315).
stub2=$(mktemp); chmod +x "$stub2"
cat > "$stub2" <<'STUB'
#!/usr/bin/env bash
# Only label the first two notes; leave the rest as parse gaps.
while IFS= read -r line; do
  [[ "$line" =~ ^([0-9]+)\. ]] || continue
  n="${BASH_REMATCH[1]}"
  (( n <= 2 )) && echo "$n: CLEAN"
done
STUB
out=$(DELEGATE_QUALITY_DELEGATE_SH="$stub2" bash "$SCRIPT" --file "$fx" --tier human --classify 2>/dev/null)
# 4 reasoned rows, only 2 classified (both CLEAN hits) -> clean=2 over classified=2 (100%).
assert_contains "Re-reviewed verdicts (2 classified of 4 reasoned)" "$out" "parse-gap: classified denominator in header"
assert_contains "clean hit (used as-is):          2  (100%)" "$out" "parse-gap: clean pct over classified, not reasoned"
assert_contains "miss (rewritten / discarded):    0" "$out" "parse-gap: unclassified miss not counted as miss"
assert_contains "2 reasoned rows were not classified" "$out" "parse-gap: indeterminate NOTE present"
rm -f "$fx" "$stub2"

echo ""
# Verdict-tier partition (ADR 0015). The tool used to pool 974 agent-observed
# usage rows with 20 human quality verdicts into one "hit-rate" — the same
# conflation #408 removed from the dashboards. The restored fixture above has no
# verdict_source at all, so it could not have caught this; this one does.
tierfx=$(mktemp)
cat > "$tierfx" <<'EOF'
{"ts":"2026-06-01T10:00:00Z","source":"feedback","kept":true,"reason":"used verbatim, no edits"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","kept":false,"reason":"rewritten entirely"}
{"ts":"2026-06-01T10:02:00Z","source":"feedback","kept":true,"reason":"used verbatim, no edits","verdict_source":"agent"}
{"ts":"2026-06-01T10:03:00Z","source":"feedback","kept":true,"reason":"used verbatim, no edits","verdict_source":"agent"}
{"ts":"2026-06-01T10:04:00Z","source":"feedback","kept":true,"reason":"used verbatim, no edits","verdict_source":"agent"}
{"ts":"2026-06-01T10:05:00Z","source":"feedback","kept":false,"scaffold":true,"reason":"discarded the draft but the divergence helped","verdict_source":"agent"}
EOF

out=$(bash "$SCRIPT" --file "$tierfx" --tier human 2>/dev/null)
assert_contains "Tier:                     human verdicts" "$out" "tier: human is labelled as quality"
assert_contains "Verdicts:                 2  (1 hits, 1 misses, 0 scaffold)" "$out" "tier: human counts only human rows"
assert_contains "(4 verdict(s) in the other tier" "$out" "tier: human names the agent count it excluded"

out=$(bash "$SCRIPT" --file "$tierfx" --tier agent 2>/dev/null)
assert_contains "Tier:                     agent-observed" "$out" "tier: agent is labelled as usage"
assert_contains "(2 verdict(s) in the other tier" "$out" "tier: agent names the human count it excluded"
# 4 agent rows: 3 hits + 1 scaffold. Scaffold is NOT a miss —
# delegate-feedback.sh:372 says so and writes kept:false, so an unfiltered
# count files it under misses.
assert_contains "Verdicts:                 4  (3 hits, 0 misses, 1 scaffold)" "$out" "tier: scaffold is its own outcome, not a miss"

# agent is the default, because that is where the volume is. A pooled figure is
# reachable only by asking for it, and says outright that it is not quality.
out=$(bash "$SCRIPT" --file "$tierfx" 2>/dev/null)
assert_contains "Tier:                     agent-observed" "$out" "tier: defaults to agent"
out=$(bash "$SCRIPT" --file "$tierfx" --tier all 2>/dev/null)
assert_contains "NOT a quality figure" "$out" "tier: pooled mode says it is not a quality figure"
assert_contains "Verdicts:                 6  (4 hits, 1 misses, 1 scaffold)" "$out" "tier: pooled counts every row"

EC=0; bash "$SCRIPT" --file "$tierfx" --tier bogus >/dev/null 2>&1 || EC=$?
assert_eq 2 "$EC" "tier: an unknown tier exits 2"
EC=0; bash "$SCRIPT" --file "$tierfx" --tier >/dev/null 2>&1 || EC=$?
assert_eq 2 "$EC" "tier: --tier without a value exits 2"

# --by-recipe reads the same filtered set, so it cannot be a second unpartitioned
# surface. The agent rows reference no delegate row here, so the human tier's
# single reasoned recipe row is the only one that can appear.
recipefx=$(mktemp)
cat > "$recipefx" <<'EOF'
{"ts":"2026-06-01T09:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","exit_status":0}
{"ts":"2026-06-01T09:01:00Z","source":"delegate","recipe":"pr-description","tier":"prose","exit_status":0}
{"ts":"2026-06-01T10:00:00Z","source":"feedback","ref_ts":"2026-06-01T09:00:00Z","kept":true,"reason":"used verbatim"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","ref_ts":"2026-06-01T09:01:00Z","kept":true,"reason":"used verbatim","verdict_source":"agent"}
EOF
out=$(bash "$SCRIPT" --file "$recipefx" --tier human --by-recipe 2>/dev/null)
assert_contains "commit-message: n=1" "$out" "by-recipe: human tier shows its own recipe"
case "$out" in
  *pr-description*) assert_eq "absent" "present" "by-recipe: agent-tier recipe excluded from the human report" ;;
  *)                assert_eq "absent" "absent"  "by-recipe: agent-tier recipe excluded from the human report" ;;
esac
rm -f "$tierfx" "$recipefx"

# Clean-as-is denominates on CLASSIFIED rows. Numerator comes only from reasoned
# rows, so dividing by every verdict made the metric fall as reason coverage
# fell — and coverage differs 100% vs 66% between the tiers on live data, which
# is exactly where a cross-tier read would mislead.
denfx=$(mktemp)
cat > "$denfx" <<'EOF'
{"ts":"2026-06-01T10:00:00Z","source":"feedback","kept":true,"reason":"used verbatim, no edits"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","kept":true}
{"ts":"2026-06-01T10:02:00Z","source":"feedback","kept":true}
{"ts":"2026-06-01T10:03:00Z","source":"feedback","kept":true}
EOF
out=$(bash "$SCRIPT" --file "$denfx" --tier human 2>/dev/null)
assert_contains "Clean-as-is rate:         100%   (1/1 classified)" "$out" "clean-as-is: denominated on classified, not total"
rm -f "$denfx"

# The failure-mode denominator counts CLASSIFIED problem cases only. The
# category tallies come from classified reasoned rows, so mixing them with the
# raw miss count — which includes misses that carry no reason and were never
# categorised — understated every percentage. Fixture: 3 reasoned rows plus one
# UNREASONED miss, so miss(2) > miss_classified(1).
dfx=$(mktemp)
cat > "$dfx" <<'EOF'
{"ts":"2026-06-01T10:00:00Z","source":"feedback","kept":true,"reason":"note one"}
{"ts":"2026-06-01T10:01:00Z","source":"feedback","kept":true,"reason":"note two"}
{"ts":"2026-06-01T10:02:00Z","source":"feedback","kept":false,"reason":"note three"}
{"ts":"2026-06-01T10:03:00Z","source":"feedback","kept":false}
EOF
dstub=$(mktemp); chmod +x "$dstub"
cat > "$dstub" <<'STUB'
#!/usr/bin/env bash
labels=(CLEAN FAITHFULNESS PADDING)
i=0
while IFS= read -r line; do
  [[ "$line" =~ ^([0-9]+)\. ]] || continue
  echo "${BASH_REMATCH[1]}: ${labels[$(( i % 3 ))]}"
  i=$((i+1))
done
STUB
out=$(DELEGATE_QUALITY_DELEGATE_SH="$dstub" bash "$SCRIPT" --file "$dfx" --tier human --classify 2>/dev/null)
# 3 classified: CLEAN hit, FAITHFULNESS hit (=fixed), PADDING miss.
# problems = 1 fixed-hit + 1 classified miss = 2. The unreasoned miss is excluded.
assert_contains "Failure modes in the 2 classified problem cases" "$out" "failure-modes: denominator excludes the unreasoned miss"
assert_contains "(fixed-hits + classified misses)" "$out" "failure-modes: label names the classified denominator"
# Both categories are 50% of 2. Under the old `fixed_hit + miss` denominator of
# 3 they would have read 33%.
assert_contains "faithfulness     1  (50%)" "$out" "failure-modes: percentage is over the classified denominator"
assert_contains "Verdicts:                 4  (2 hits, 2 misses, 0 scaffold)" "$out" "failure-modes: headline still counts every verdict"
rm -f "$dfx" "$dstub"

echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
