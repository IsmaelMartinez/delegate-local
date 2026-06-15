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
# All fixtures are temp files cleaned up by a trap, so an early exit or
# interrupt cannot leave them behind.
fixture="" nofb="" malformed="" phantom="" nots="" lowweek=""
trap 'rm -f "$fixture" "$nofb" "$malformed" "$phantom" "$nots" "$lowweek"' EXIT
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

# A directory path → exit 1 cleanly (not an IsADirectoryError from open()).
# Use an existing directory (SCRIPT_DIR) rather than a temp dir, so there is
# nothing to leak.
out=$(python3 "$TREND" "$SCRIPT_DIR" 2>&1); ec=$?
assert_eq 1 "$ec" "directory path → exit 1 (isfile guard, no IsADirectoryError)"
assert_contains "not a file" "$out" "directory path error names the cause"

# A metrics file with no feedback rows → exit 1, actionable message.
nofb=$(mktemp)
echo '{"ts":"2026-05-04T10:00:00Z","source":"delegate","recipe":"commit-message"}' > "$nofb"
out=$(python3 "$TREND" "$nofb" 2>&1); ec=$?
assert_eq 1 "$ec" "no feedback rows → exit 1"
assert_contains "no feedback rows yet" "$out" "no-feedback error points at delegate-feedback.sh"

# Robustness (review fixes): a malformed/short ts on a delegate row must not
# crash the rollup — it is skipped the way a bad JSON line is.
malformed=$(mktemp)
cat > "$malformed" <<'EOF'
{"ts":"2026-05","source":"delegate","recipe":"commit-message"}
42
["not", "an", "object"]
"a bare string"
{"ts":"2026-05-04T10:00:00Z","source":"delegate","recipe":"commit-message"}
{"ts":"2026-05-04T10:05:00Z","source":"feedback","ref_ts":"2026-05-04T10:00:00Z","kept":true}
EOF
out=$(python3 "$TREND" "$malformed" 2>&1); ec=$?
assert_eq 0 "$ec" "malformed ts + non-object JSON lines are tolerated (no crash)"
assert_contains "lifetime  1/1 HIT" "$out" "non-dict lines skipped, valid pair still counted"

# A verdict whose ref_ts resolves to no delegate row is bucketed as
# (ref-not-found), not silently counted as bare.
phantom=$(mktemp)
{
  for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2026-05-04T1${i}:00:00Z\",\"source\":\"delegate\",\"recipe\":\"commit-message\"}"
    echo "{\"ts\":\"2026-05-04T1${i}:05:00Z\",\"source\":\"feedback\",\"ref_ts\":\"1999-01-0${i}T00:00:00Z\",\"kept\":true}"
  done
} > "$phantom"
out=$(python3 "$TREND" "$phantom" 2>&1); ec=$?
assert_eq 0 "$ec" "phantom ref_ts → exit 0"
assert_contains "ref-not-found" "$out" "unresolved ref_ts gets its own bucket"

# Feedback rows that carry no usable timestamp at all → exit 1, not a crash.
nots=$(mktemp)
cat > "$nots" <<'EOF'
{"ts":"2026-05-04T10:00:00Z","source":"delegate","recipe":"commit-message"}
{"source":"feedback","kept":true}
EOF
out=$(python3 "$TREND" "$nots" 2>&1); ec=$?
assert_eq 1 "$ec" "verdicts with no usable timestamp → exit 1 (no ZeroDivisionError)"

# A week below the 50% chart floor must not push the plotted row off-grid
# (1 HIT / 3 MISS = 25%); the row() clamp keeps it on the floor instead of
# raising IndexError.
lowweek=$(mktemp)
cat > "$lowweek" <<'EOF'
{"ts":"2026-05-04T10:00:00Z","source":"delegate","recipe":"commit-message"}
{"ts":"2026-05-04T11:00:00Z","source":"delegate","recipe":"commit-message"}
{"ts":"2026-05-04T12:00:00Z","source":"delegate","recipe":"commit-message"}
{"ts":"2026-05-04T13:00:00Z","source":"delegate","recipe":"commit-message"}
{"ts":"2026-05-04T10:05:00Z","source":"feedback","ref_ts":"2026-05-04T10:00:00Z","kept":true}
{"ts":"2026-05-04T11:05:00Z","source":"feedback","ref_ts":"2026-05-04T11:00:00Z","kept":false}
{"ts":"2026-05-04T12:05:00Z","source":"feedback","ref_ts":"2026-05-04T12:00:00Z","kept":false}
{"ts":"2026-05-04T13:05:00Z","source":"feedback","ref_ts":"2026-05-04T13:00:00Z","kept":false}
EOF
out=$(python3 "$TREND" "$lowweek" 2>&1); ec=$?
assert_eq 0 "$ec" "sub-50% week renders without IndexError"
assert_contains "lifetime  1/4 HIT = 25%" "$out" "sub-50% week counted correctly"

# Phase E agent-observed verdict tier. Fixture: 9 commit-message delegations.
# Human verdicts on D0-D5: 5 HIT + 1 MISS (= 6 human verdicts, 83%). Agent
# verdicts on D6-D8: 2 used + 1 rewrote (= 3 agent verdicts, 67% usage). All 9
# delegations are covered → 100% coverage. The honesty property: the human
# hit-rate (5/6) must NOT be inflated by the agent HITs, the per-recipe quality
# count must be the 6 human verdicts (not 9), and the agent tier is its own
# lifetime figure.
agentq=$(mktemp)
agentonly=$(mktemp)
trap 'rm -f "$fixture" "$nofb" "$malformed" "$phantom" "$nots" "$lowweek" "$agentq" "$agentonly"' EXIT
{
  for i in 0 1 2 3 4 5 6 7 8; do
    printf '{"ts":"2026-05-04T10:0%d:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}\n' "$i"
  done
  for i in 0 1 2 3 4; do
    printf '{"ts":"2026-05-04T20:0%d:00Z","source":"feedback","ref_ts":"2026-05-04T10:0%d:00Z","kept":true}\n' "$i" "$i"
  done
  printf '{"ts":"2026-05-04T20:05:00Z","source":"feedback","ref_ts":"2026-05-04T10:05:00Z","kept":false}\n'
  printf '{"ts":"2026-05-04T21:06:00Z","source":"feedback","ref_ts":"2026-05-04T10:06:00Z","kept":true,"verdict_source":"agent"}\n'
  printf '{"ts":"2026-05-04T21:07:00Z","source":"feedback","ref_ts":"2026-05-04T10:07:00Z","kept":true,"verdict_source":"agent"}\n'
  printf '{"ts":"2026-05-04T21:08:00Z","source":"feedback","ref_ts":"2026-05-04T10:08:00Z","kept":false,"verdict_source":"agent"}\n'
} > "$agentq"
out=$(python3 "$TREND" "$agentq" 2>&1); ec=$?
assert_eq 0 "$ec" "agent-tier: exits 0"
assert_contains "lifetime  5/6 HIT = 83%" "$out" "agent-tier: human hit-rate excludes agent verdicts (5/6, not 7/9)"
assert_contains "100% verdict coverage" "$out" "agent-tier: coverage counts both tiers (9/9)"
assert_contains "agent-observed 2/3 used = 67%" "$out" "agent-tier: agent usage reported as its own figure"
assert_contains "HIT-rate of human verdicts" "$out" "agent-tier: trend header labels the human partition"
# Per-recipe quality counts human verdicts only: commit-message has 6, not 9.
recipe_line=$(printf '%s' "$out" | grep -E "^  commit-message")
assert_contains "human verdicts" "$out" "agent-tier: per-recipe header labels human partition"
n_in_line=$(printf '%s' "$recipe_line" | awk '{print $2}')
assert_eq 6 "$n_in_line" "agent-tier: per-recipe n is human verdicts only (6, not 9)"

# Agent-only file (early rollout): no human verdicts, but agent verdicts and
# coverage still summarised rather than erroring.
cat > "$agentonly" <<'EOF'
{"ts":"2026-05-04T10:00:00Z","source":"delegate","recipe":"commit-message","tier":"prose","model":"q"}
{"ts":"2026-05-04T20:00:00Z","source":"feedback","ref_ts":"2026-05-04T10:00:00Z","kept":true,"verdict_source":"agent"}
EOF
out=$(python3 "$TREND" "$agentonly" 2>&1); ec=$?
assert_eq 0 "$ec" "agent-only: exits 0 (not treated as no verdicts)"
assert_contains "no human verdicts" "$out" "agent-only: human partition reports no verdicts gracefully"
assert_contains "agent-observed 1/1 used = 100%" "$out" "agent-only: agent usage still reported"
assert_contains "100% verdict coverage" "$out" "agent-only: coverage counts the agent verdict"

echo ""
echo "=== Results ==="
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
