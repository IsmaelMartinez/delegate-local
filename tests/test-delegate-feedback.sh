#!/usr/bin/env bash
# Unit tests for scripts/delegate-feedback.sh.
# Builds a synthetic metrics JSONL in $tmp, exercises every flag, and asserts
# the appended feedback row points at the most recent delegate event with the
# correct kept value and reason.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/delegate-feedback.sh"

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
  else echo "  FAIL  $name (missing '$needle' in '$haystack')"; fail=$((fail+1)); fi
}

# Seed a metrics JSONL with two delegate calls and one experiment call.
seed_metrics() {
  local file="$1"
  cat > "$file" <<'EOF'
{"ts":"2026-05-09T10:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"2026-05-09T10:05:00Z","source":"experiment","session":"foo","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":10}
{"ts":"2026-05-09T10:10:00Z","source":"delegate","tier":"reasoning","model":"d","duration_ms":7000,"exit_status":0,"estimated_tokens_avoided":60}
EOF
}

# 1. usage: no args -> exit 2.
EC=0
out=$(bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 2 "$EC" "no args -> exit 2"
assert_contains "usage:" "$out" "no args -> usage line"

# 2. usage: bad verdict -> exit 2.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" maybe 2>&1) || EC=$?
assert_eq 2 "$EC" "bad verdict -> exit 2"
assert_contains "first arg must be" "$out" "bad verdict -> error"
rm -rf "$tmp"

# 3. file missing -> exit 1.
tmp=$(mktemp -d)
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/nope.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 1 "$EC" "missing file -> exit 1"
assert_contains "metrics file not found" "$out" "missing file -> error"
rm -rf "$tmp"

# 4. no delegate event -> exit 1.
tmp=$(mktemp -d)
echo '{"ts":"2026-05-09T10:00:00Z","source":"experiment","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":0}' > "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 1 "$EC" "no delegate event -> exit 1"
assert_contains "no recent delegate event" "$out" "no delegate event -> error"
rm -rf "$tmp"

# 5. hit: appends a feedback row pointing at the most recent delegate.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "hit: exit 0"
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
[[ "$after" -eq $((before + 1)) ]] && pass=$((pass+1)) && echo "  PASS  hit: file gains one line" || { fail=$((fail+1)); echo "  FAIL  hit: line count $before -> $after"; }
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"source":"feedback"' "$last" "hit: source field"
assert_contains '"kept":true' "$last" "hit: kept=true"
assert_contains '"ref_ts":"2026-05-09T10:10:00Z"' "$last" "hit: ref_ts is latest delegate"
[[ "$last" == *'"reason"'* ]] && { fail=$((fail+1)); echo "  FAIL  hit (no reason): reason field absent"; } || { pass=$((pass+1)); echo "  PASS  hit (no reason): reason field absent"; }
rm -rf "$tmp"

# 6. miss with reason: kept=false and reason field present.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "bullets when prose was wanted" 2>&1) || EC=$?
assert_eq 0 "$EC" "miss: exit 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"kept":false' "$last" "miss: kept=false"
assert_contains '"reason":"bullets when prose was wanted"' "$last" "miss: reason captured"
assert_contains "MISS recorded" "$out" "miss: stdout reports MISS"
rm -rf "$tmp"

# 7. ref_ts picks the LATEST delegate event when multiple exist.
tmp=$(mktemp -d)
cat > "$tmp/m.jsonl" <<'EOF'
{"ts":"2026-05-09T09:00:00Z","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"2026-05-09T11:00:00Z","source":"experiment","session":"foo","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":10}
{"ts":"2026-05-09T12:30:00Z","source":"delegate","tier":"long-context","model":"q","duration_ms":9000,"exit_status":0,"estimated_tokens_avoided":80}
EOF
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"ref_ts":"2026-05-09T12:30:00Z"' "$last" "ref_ts: picks latest delegate, not earliest"
rm -rf "$tmp"

# 8. Output is valid JSON (jq can parse it back).
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "ok" >/dev/null
last=$(tail -1 "$tmp/m.jsonl")
EC=0
echo "$last" | jq -e . >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "feedback row is valid JSON"
rm -rf "$tmp"

# 9. Feedback after a feedback still finds the original delegate (the
#    feedback event itself is excluded from the "most recent delegate" search).
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "actually no" >/dev/null
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"ref_ts":"2026-05-09T10:10:00Z"' "$last" "back-to-back feedback: still refers to delegate, not previous feedback"
rm -rf "$tmp"

# 10. Custom DELEGATE_METRICS_FILE path is honoured.
tmp=$(mktemp -d); custom="$tmp/elsewhere.jsonl"; seed_metrics "$custom"
EC=0
DELEGATE_METRICS_FILE="$custom" bash "$SCRIPT" hit >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "custom DELEGATE_METRICS_FILE: exit 0"
[[ $(wc -l < "$custom" | tr -d ' ') -eq 4 ]] && pass=$((pass+1)) && echo "  PASS  custom path: feedback appended there" || { fail=$((fail+1)); echo "  FAIL  custom path: line count wrong"; }
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
