#!/usr/bin/env bash
# Unit tests for scripts/audit-metrics.sh — the on-demand counterpart to
# the per-MISS runtime nudge in delegate-feedback.sh. Mirrors the n18-n27
# block of test-delegate-feedback.sh: seed a synthetic metrics JSONL with
# N MISS rows of varying similarity / age, then assert the audit produces
# (or suppresses) draft `gh issue create` commands as documented.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/audit-metrics.sh"

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
assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (unexpected '$needle' present)"; fail=$((fail+1)); fi
}

# Helper: write N MISS feedback rows with a common reason template, all
# inside the last hour so they fall well inside any reasonable window.
# Each row carries its index so the matcher sees distinct strings while
# still meeting the Jaccard threshold via shared content tokens.
seed_misses() {
  local file="$1" n="$2"
  local reason_template="${3:-pr-description recipe stalled past 30s on prose tier body}"
  : > "$file"
  local i
  for (( i=1; i<=n; i++ )); do
    local ts
    ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-1800+'"$i"'*60))')
    echo "{\"ts\":\"$ts\",\"source\":\"feedback\",\"ref_ts\":\"$ts\",\"kept\":false,\"reason\":\"$reason_template ($i)\"}" >> "$file"
  done
}

# 1. usage: unexpected positional arg -> exit 2.
EC=0
out=$(bash "$SCRIPT" some-arg 2>&1) || EC=$?
assert_eq 2 "$EC" "unexpected arg -> exit 2"
assert_contains "usage:" "$out" "unexpected arg -> usage line"

# 2. usage: --help -> exit 2 (usage doc).
EC=0
out=$(bash "$SCRIPT" --help 2>&1) || EC=$?
assert_eq 2 "$EC" "--help -> exit 2"
assert_contains "usage:" "$out" "--help -> usage line"

# 3. missing file -> exit 1.
tmp=$(mktemp -d)
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/nope.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 1 "$EC" "missing file -> exit 1"
assert_contains "metrics file not found" "$out" "missing file -> error"
rm -rf "$tmp"

# 4. empty JSONL -> exit 0, "no MISS feedback rows" message.
tmp=$(mktemp -d); : > "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "empty JSONL: exit 0"
assert_contains "No MISS feedback rows" "$out" "empty JSONL: friendly message"
assert_not_contains "gh issue create" "$out" "empty JSONL: no draft command"
rm -rf "$tmp"

# 5. only delegate + HIT rows (no MISS) -> no draft, friendly message.
tmp=$(mktemp -d)
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$ts","source":"delegate","tier":"prose","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"$ts","source":"feedback","ref_ts":"$ts","kept":true}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "no MISS rows: exit 0"
assert_contains "No MISS feedback rows" "$out" "no MISS rows: friendly message"
assert_not_contains "gh issue create" "$out" "no MISS rows: no draft command"
rm -rf "$tmp"

# 6. below-threshold bucket (2 similar, default nudge_at=3) -> no draft.
tmp=$(mktemp -d); seed_misses "$tmp/m.jsonl" 2
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "below-threshold: exit 0"
assert_contains "no bucket reached the threshold" "$out" "below-threshold: explains why no draft"
assert_not_contains "gh issue create" "$out" "below-threshold: no draft command"
rm -rf "$tmp"

# 7. at-threshold bucket (3 similar) -> draft fires.
tmp=$(mktemp -d); seed_misses "$tmp/m.jsonl" 3
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "at-threshold: exit 0"
assert_contains "found 1 recurring bucket" "$out" "at-threshold: summary line names bucket count"
assert_contains "3 similar MISSes" "$out" "at-threshold: bucket size rendered"
assert_contains "gh issue create" "$out" "at-threshold: draft command present"
assert_contains "--label prompt-pattern" "$out" "at-threshold: label flag present"
assert_contains "pr-description recipe stalled" "$out" "at-threshold: representative reason rendered"
rm -rf "$tmp"

# 8. multiple distinct buckets -> each emits its own draft.
tmp=$(mktemp -d)
seed_misses "$tmp/m.jsonl" 3 "pr-description recipe stalled past 30s on prose tier body"
# Append a second distinct bucket — content tokens fully disjoint so Jaccard=0.
for i in 1 2 3; do
  ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600+'"$i"'*60))')
  echo "{\"ts\":\"$ts\",\"source\":\"feedback\",\"ref_ts\":\"$ts\",\"kept\":false,\"reason\":\"commit-message recipe emitted bullets instead flowing paragraph form ($i)\"}" >> "$tmp/m.jsonl"
done
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "multi-bucket: exit 0"
assert_contains "found 2 recurring bucket" "$out" "multi-bucket: summary names 2 buckets"
# Two draft commands should be present — count occurrences.
draft_count=$(echo "$out" | grep -c "gh issue create" || true)
[[ "$draft_count" -eq 2 ]] && pass=$((pass+1)) && echo "  PASS  multi-bucket: 2 draft commands emitted" \
  || { fail=$((fail+1)); echo "  FAIL  multi-bucket: expected 2 drafts, got $draft_count"; }
assert_contains "pr-description recipe stalled" "$out" "multi-bucket: first bucket rep rendered"
assert_contains "commit-message recipe emitted" "$out" "multi-bucket: second bucket rep rendered"
rm -rf "$tmp"

# 9. window filter excludes MISSes older than DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS.
tmp=$(mktemp -d)
: > "$tmp/m.jsonl"
# 4 historical similar MISSes 35 days old — outside the 30-day default.
for i in 1 2 3 4; do
  old_ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 35*86400 + '"$i"'*60))')
  echo "{\"ts\":\"$old_ts\",\"source\":\"feedback\",\"ref_ts\":\"$old_ts\",\"kept\":false,\"reason\":\"pr-description recipe stalled past 30s on prose tier body ($i)\"}" >> "$tmp/m.jsonl"
done
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "window-excluded: exit 0"
assert_contains "No MISS feedback rows" "$out" "window-excluded: 30d window drops 35d-old rows"
assert_not_contains "gh issue create" "$out" "window-excluded: no draft command"
# Same data with widened window should surface the bucket.
EC=0
out=$(DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS=60 DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "window-widened: exit 0"
assert_contains "found 1 recurring bucket" "$out" "window-widened: bucket now in scope"
assert_contains "gh issue create" "$out" "window-widened: draft fires"
rm -rf "$tmp"

# 10. DELEGATE_FEEDBACK_NUDGE_AT=2 lowers the threshold (2 similar fires).
tmp=$(mktemp -d); seed_misses "$tmp/m.jsonl" 2
EC=0
out=$(DELEGATE_FEEDBACK_NUDGE_AT=2 DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "NUDGE_AT=2: exit 0"
assert_contains "found 1 recurring bucket" "$out" "NUDGE_AT=2: fires with 2 members"
assert_contains "2 similar MISSes" "$out" "NUDGE_AT=2: count rendered"
rm -rf "$tmp"

# 11. DELEGATE_FEEDBACK_SIMILAR_THRESHOLD=0.99 separates near-but-not-identical
# reasons into single-member buckets that fail the count threshold.
tmp=$(mktemp -d)
# Three reasons sharing some tokens but differing enough that very strict
# Jaccard puts them in separate buckets.
ts1=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-300))')
ts2=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-200))')
ts3=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-100))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$ts1","source":"feedback","ref_ts":"$ts1","kept":false,"reason":"pr-description recipe stalled past 30s body"}
{"ts":"$ts2","source":"feedback","ref_ts":"$ts2","kept":false,"reason":"commit-message recipe added bullets instead paragraph"}
{"ts":"$ts3","source":"feedback","ref_ts":"$ts3","kept":false,"reason":"summarise-diff recipe truncated mid sentence"}
EOF
EC=0
out=$(DELEGATE_FEEDBACK_SIMILAR_THRESHOLD=0.99 DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "high threshold: exit 0"
assert_contains "no bucket reached the threshold" "$out" "high threshold: each MISS its own bucket → no draft"
rm -rf "$tmp"

# 12. Read-only contract: script does not append to the JSONL.
tmp=$(mktemp -d); seed_misses "$tmp/m.jsonl" 3
before=$(wc -c < "$tmp/m.jsonl" | tr -d ' ')
before_lines=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" >/dev/null 2>&1
after=$(wc -c < "$tmp/m.jsonl" | tr -d ' ')
after_lines=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_eq "$before" "$after" "read-only: byte count unchanged"
assert_eq "$before_lines" "$after_lines" "read-only: line count unchanged"
rm -rf "$tmp"

# 13. Draft title includes the prompt-pattern prefix so the maintainer
# can identify the issue type at a glance.
tmp=$(mktemp -d); seed_misses "$tmp/m.jsonl" 3
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1)
assert_contains "--title 'prompt-pattern:" "$out" "draft title: prompt-pattern: prefix present"
rm -rf "$tmp"

# 14. Each matched reason's timestamp appears in the bucket listing so
# the user can correlate audit output with the metrics JSONL.
tmp=$(mktemp -d); seed_misses "$tmp/m.jsonl" 3
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1)
# Every member row should be rendered with its ISO timestamp.
ts_lines=$(echo "$out" | grep -cE '  - [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: ' || true)
[[ "$ts_lines" -eq 3 ]] && pass=$((pass+1)) && echo "  PASS  draft body: 3 timestamped members rendered" \
  || { fail=$((fail+1)); echo "  FAIL  draft body: expected 3 timestamped lines, got $ts_lines"; }
rm -rf "$tmp"

# 15. HIT rows in the JSONL never count toward MISS buckets.
tmp=$(mktemp -d); : > "$tmp/m.jsonl"
# Three HIT rows with the bucket's would-be reason — must be ignored.
for i in 1 2 3; do
  ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-300+'"$i"'*60))')
  echo "{\"ts\":\"$ts\",\"source\":\"feedback\",\"ref_ts\":\"$ts\",\"kept\":true,\"reason\":\"pr-description recipe stalled past 30s body ($i)\"}" >> "$tmp/m.jsonl"
done
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "HITs only: exit 0"
assert_contains "No MISS feedback rows" "$out" "HITs only: no buckets (kept:true filtered out)"
rm -rf "$tmp"

# 16. Draft command targets the default repo when DELEGATE_GITHUB_REPO is
# unset, and the override repo when it is set (fork support).
tmp=$(mktemp -d); seed_misses "$tmp/m.jsonl" 3
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1)
assert_contains "--repo IsmaelMartinez/delegate-local" "$out" "repo default: draft targets IsmaelMartinez/delegate-local"
out=$(DELEGATE_GITHUB_REPO="someorg/forked-skill" DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>&1)
assert_contains "--repo someorg/forked-skill" "$out" "repo override: draft targets DELEGATE_GITHUB_REPO"
assert_not_contains "IsmaelMartinez/delegate-local" "$out" "repo override: default repo absent from draft"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
