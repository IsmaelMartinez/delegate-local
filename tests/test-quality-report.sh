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
out=$(bash "$SCRIPT" --file "$fx" 2>/dev/null)
assert_contains "mode: keyword heuristic" "$out" "keyword: mode label"
assert_contains "Verdicts:                 5  (4 hits, 1 misses)" "$out" "keyword: verdict counts (delegate row ignored)"
assert_contains "Reason coverage:          4 / 5" "$out" "keyword: reason coverage excludes no-reason hit"
assert_contains "Raw hit-rate (used):      80%   (4/5)" "$out" "keyword: raw hit-rate"
assert_contains "clean hit (used as-is):          1" "$out" "keyword: one clean hit"
assert_contains "fixed hit (used, then edited):   1" "$out" "keyword: one fixed hit"
assert_contains "ambiguous hit (keyword unsure):   1" "$out" "keyword: one ambiguous hit"
assert_contains "miss (rewritten / discarded):    1" "$out" "keyword: one miss"
assert_contains "Indeterminate (no reason):" "$out" "keyword: indeterminate label"

# window: --since after all rows -> empty window note
EC=0; out=$(bash "$SCRIPT" --file "$fx" --since 2027-01-01 2>&1) || EC=$?
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
out=$(DELEGATE_QUALITY_DELEGATE_SH="$stub" bash "$SCRIPT" --file "$fx" --classify 2>/dev/null)
assert_contains "mode: local-model classification" "$out" "classify: mode label"
# 4 reasoned rows -> stub labels them CLEAN, FAITHFULNESS, PADDING, STRUCTURAL in order.
# rows: 1=clean-hit(CLEAN), 2=fixed-hit(FAITHFULNESS), 3=hit(PADDING), 4=miss(STRUCTURAL).
assert_contains "clean hit (used as-is):          1" "$out" "classify: one clean hit"
assert_contains "Failure modes in the" "$out" "classify: failure-mode section present"
assert_contains "faithfulness     1" "$out" "classify: one faithfulness problem"
rm -f "$fx" "$stub"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
