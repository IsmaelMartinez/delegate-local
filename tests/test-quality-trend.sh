#!/usr/bin/env bash
# Tests for experiments/quality-trend.py — the reproducible weekly-quality
# rollup over the metrics JSONL. Feeds a hand-authored fixture so the
# hit-rate / coverage / per-recipe maths is pinned and future augmentation
# can't silently drift the numbers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREND="$SCRIPT_DIR/../experiments/quality-trend.py"

pass=0
fail=0
assert_contains() {
  local needle="$1" hay="$2" name="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then
    echo "  PASS  $name"; pass=$((pass + 1))
  else
    echo "  FAIL  $name (missing '$needle')"; fail=$((fail + 1))
  fi
}
assert_eq() {
  local want="$1" got="$2" name="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  PASS  $name"; pass=$((pass + 1))
  else
    echo "  FAIL  $name (expected '$want', got '$got')"; fail=$((fail + 1))
  fi
}

# Fixture: 8 delegations (6 commit-message across two weeks, 2 bare), 7 verdicts.
# commit-message: 5 HIT / 1 MISS = 6 verdicts, 83%. bare: 1 HIT. One bare
# delegation has no verdict (untracked) so coverage is 7/8 = 88%.
fixture=$(mktemp)
cat > "$fixture" <<'EOF'
{"ts":"2026-05-04T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}
{"ts":"2026-05-04T11:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}
{"ts":"2026-05-04T12:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}
{"ts":"2026-05-11T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}
{"ts":"2026-05-11T11:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}
{"ts":"2026-05-11T12:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}
{"ts":"2026-05-11T13:00:00Z","source":"delegate","tier":"prose","model":"q"}
{"ts":"2026-05-11T14:00:00Z","source":"delegate","tier":"prose","model":"q"}
{"ts":"2026-05-04T10:05:00Z","source":"feedback","ref_ts":"2026-05-04T10:00:00Z","kept":true}
{"ts":"2026-05-04T11:05:00Z","source":"feedback","ref_ts":"2026-05-04T11:00:00Z","kept":true}
{"ts":"2026-05-04T12:05:00Z","source":"feedback","ref_ts":"2026-05-04T12:00:00Z","kept":false}
{"ts":"2026-05-11T10:05:00Z","source":"feedback","ref_ts":"2026-05-11T10:00:00Z","kept":true}
{"ts":"2026-05-11T11:05:00Z","source":"feedback","ref_ts":"2026-05-11T11:00:00Z","kept":true}
{"ts":"2026-05-11T12:05:00Z","source":"feedback","ref_ts":"2026-05-11T12:00:00Z","kept":true}
{"ts":"2026-05-11T13:05:00Z","source":"feedback","ref_ts":"2026-05-11T13:00:00Z","kept":true}
EOF

out=$(python3 "$TREND" "$fixture" 2>&1)
ec=$?
assert_eq 0 "$ec" "exits 0 on a valid metrics file"
assert_contains "delegate-local — weekly recipe quality" "$out" "renders the trend chart header"
assert_contains "lifetime  6/7 HIT = 86%" "$out" "lifetime hit rate computed from verdicts"
assert_contains "88% verdict coverage" "$out" "coverage = verdicts / delegations"
assert_contains "commit-message" "$out" "per-recipe section lists commit-message (n>=5)"
assert_contains "83%" "$out" "commit-message hit rate (5/6)"
# bare recipe has only 1 verdict — below the >=5 threshold, so it is not shown.
bare_line=$(printf '%s' "$out" | grep -c "bare/no-recipe" || true)
assert_eq 0 "$bare_line" "recipe below the sample-size floor is omitted"

# Missing file → exit 1 with a clear message.
out=$(python3 "$TREND" "/nonexistent/metrics.jsonl" 2>&1); ec=$?
assert_eq 1 "$ec" "missing metrics file → exit 1"
assert_contains "not found" "$out" "missing file error names the cause"

# A metrics file with no feedback rows → exit 1, actionable message.
nofb=$(mktemp)
echo '{"ts":"2026-05-04T10:00:00Z","source":"delegate","recipe":"commit-message"}' > "$nofb"
out=$(python3 "$TREND" "$nofb" 2>&1); ec=$?
assert_eq 1 "$ec" "no feedback rows → exit 1"
assert_contains "no feedback rows yet" "$out" "no-feedback error points at delegate-feedback.sh"

rm -f "$fixture" "$nofb"
echo ""
echo "=== Results ==="
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
