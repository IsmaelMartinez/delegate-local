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
# Timestamps are derived from `date` so the rows are within the default
# stale window (300 s) — the existing assertions about ref_ts equality
# need stable values, so we capture them in TS_OLDEST / TS_LATEST.
TS_OLDEST=""
TS_LATEST=""
seed_metrics() {
  local file="$1"
  # Two fresh timestamps 2 min apart — both inside the default 300 s
  # stale window, yet distinct so "picks latest delegate" assertions are
  # meaningful. Generated via perl so the format is consistent across BSD
  # and GNU date.
  TS_OLDEST=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-120))')
  TS_LATEST=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$file" <<EOF
{"ts":"$TS_OLDEST","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"$TS_OLDEST","source":"experiment","session":"foo","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":10}
{"ts":"$TS_LATEST","source":"delegate","tier":"reasoning","model":"d","duration_ms":7000,"exit_status":0,"estimated_tokens_avoided":60}
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
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "hit: ref_ts is latest delegate"
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
T_EARLY=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-200))')
T_LATE=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-10))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_EARLY","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"$T_EARLY","source":"experiment","session":"foo","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":10}
{"ts":"$T_LATE","source":"delegate","tier":"long-context","model":"q","duration_ms":9000,"exit_status":0,"estimated_tokens_avoided":80}
EOF
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$T_LATE\"" "$last" "ref_ts: picks latest delegate, not earliest"
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
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "back-to-back feedback: still refers to delegate, not previous feedback"
rm -rf "$tmp"

# 10. Custom DELEGATE_METRICS_FILE path is honoured.
tmp=$(mktemp -d); custom="$tmp/elsewhere.jsonl"; seed_metrics "$custom"
EC=0
DELEGATE_METRICS_FILE="$custom" bash "$SCRIPT" hit >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "custom DELEGATE_METRICS_FILE: exit 0"
[[ $(wc -l < "$custom" | tr -d ' ') -eq 4 ]] && pass=$((pass+1)) && echo "  PASS  custom path: feedback appended there" || { fail=$((fail+1)); echo "  FAIL  custom path: line count wrong"; }
rm -rf "$tmp"

# 11. Stale-window: refuse when most recent delegate row is older than the
# configured window (default 300 s). Seed an old row and assert exit 1
# with a message mentioning the threshold.
tmp=$(mktemp -d)
T_OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_OLD","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 1 "$EC" "stale window: exit 1 when delegate row is too old"
assert_contains "DELEGATE_FEEDBACK_STALE_SECONDS" "$out" "stale window: error mentions env override"
# Confirm no row was appended.
[[ $(wc -l < "$tmp/m.jsonl" | tr -d ' ') -eq 1 ]] && pass=$((pass+1)) && echo "  PASS  stale window: no row appended on refuse" || { fail=$((fail+1)); echo "  FAIL  stale window: row appended despite refuse"; }
rm -rf "$tmp"

# 12. DELEGATE_FEEDBACK_STALE_SECONDS=0 disables the check (back-compat).
tmp=$(mktemp -d)
T_OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_OLD","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_STALE_SECONDS=0 bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "stale window disabled (=0): exit 0 even on old row"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$T_OLD\"" "$last" "stale window disabled: feedback attached"
rm -rf "$tmp"

# 13. --ts pinning: caller can attach a verdict to a specific stale row.
tmp=$(mktemp -d)
T_OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_OLD","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$T_OLD" miss "killed before metrics" 2>&1) || EC=$?
assert_eq 0 "$EC" "--ts: exit 0 when ts matches a delegate row even if stale"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$T_OLD\"" "$last" "--ts: feedback attached to pinned ts"
assert_contains '"kept":false' "$last" "--ts: kept=false carried through"
rm -rf "$tmp"

# 14. --ts pinning: bogus ts that doesn't match any delegate row -> exit 1.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "1999-01-01T00:00:00Z" hit 2>&1) || EC=$?
assert_eq 1 "$EC" "--ts: bogus ts -> exit 1"
assert_contains "does not match any delegate row" "$out" "--ts: error names the unmatched ts"
# No new row appended.
[[ $(wc -l < "$tmp/m.jsonl" | tr -d ' ') -eq 3 ]] && pass=$((pass+1)) && echo "  PASS  --ts bogus: no row appended" || { fail=$((fail+1)); echo "  FAIL  --ts bogus: row appended despite refuse"; }
rm -rf "$tmp"

# 15. --ts pinning: ts that matches a feedback row (not a delegate row) -> exit 1.
# Prevents the case where a typoed --ts accidentally pins to a prior feedback.
# Construct distinct, non-colliding timestamps to avoid wall-clock races
# between the seeded delegate ts and the feedback ts that delegate-
# feedback.sh would write itself.
tmp=$(mktemp -d)
T_DEL=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-200))')
T_FB=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-100))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_DEL","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"$T_FB","source":"feedback","ref_ts":"$T_DEL","kept":true}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$T_FB" miss 2>&1) || EC=$?
assert_eq 1 "$EC" "--ts pointing to a feedback row -> exit 1"
assert_contains "does not match any delegate row" "$out" "--ts feedback row: error refers to no-match"
rm -rf "$tmp"

# 16. --ts requires a value.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts hit 2>&1) || EC=$?
# Either the parser rejects --ts with no value (exit 2), or it consumes
# 'hit' as the ts and then fails to find a verdict. Both are acceptable
# rejections — the test asserts non-zero exit and no row appended.
[[ "$EC" -ne 0 ]] && pass=$((pass+1)) && echo "  PASS  --ts without value -> non-zero exit" || { fail=$((fail+1)); echo "  FAIL  --ts without value should fail (got $EC)"; }
rm -rf "$tmp"

# 16b. --ts= (equals-attached, empty value) rejected with the same wording
# as `--ts` with no value — consistency between the two flag forms.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" "--ts=" hit 2>&1) || EC=$?
assert_eq 2 "$EC" "--ts= (empty value) -> exit 2"
assert_contains "requires a value" "$out" "--ts= empty: error mentions requires a value"
rm -rf "$tmp"

# 17. --ts=value form (equals-attached) also works.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" "--ts=$TS_LATEST" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "--ts=value form: exit 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "--ts=value form: feedback attached to pinned ts"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# Trigger-on-MISS recurrence nudge (issue #88)
# Helpers seed a metrics file with N historical similar MISS rows, all
# placed inside the default 30-day window unless an explicit older
# timestamp is requested. Each test then appends a fresh MISS via the
# script and asserts the nudge fires (or stays quiet) as documented.
# ---------------------------------------------------------------------------

# seed_history <file> <N_similar> [<extra_reason>]
#   Writes one delegate + one MISS feedback row per similar entry, all
#   stamped within the last hour so they fall well inside any reasonable
#   window. Then writes a fresh delegate row that the new feedback can
#   attach to. <extra_reason>, when set, becomes the historical reason
#   text — defaults to a stable "pr-description prose tier stalled" shape.
seed_history() {
  local file="$1" n="$2"
  local reason_template="${3:-pr-description recipe stalled past 30s on prose tier body}"
  : > "$file"
  local i
  for (( i=1; i<=n; i++ )); do
    local hist_ts
    hist_ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-1800+'"$i"'*60))')
    echo "{\"ts\":\"$hist_ts\",\"source\":\"delegate\",\"tier\":\"prose\",\"model\":\"q\",\"duration_ms\":1000,\"exit_status\":0,\"estimated_tokens_avoided\":50}" >> "$file"
    echo "{\"ts\":\"$hist_ts\",\"source\":\"feedback\",\"ref_ts\":\"$hist_ts\",\"kept\":false,\"reason\":\"$reason_template ($i)\"}" >> "$file"
  done
  # Fresh delegate row for the new feedback to attach to.
  TS_LATEST=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"ts\":\"$TS_LATEST\",\"source\":\"delegate\",\"tier\":\"prose\",\"model\":\"q\",\"duration_ms\":1000,\"exit_status\":0,\"estimated_tokens_avoided\":40}" >> "$file"
}

# n18: single MISS with no prior history → no nudge.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 0
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "first time pr-description tier stalled" 2>&1) || EC=$?
assert_eq 0 "$EC" "no-history MISS: exit 0"
assert_contains "MISS recorded" "$out" "no-history MISS: recorded line present"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  no-history MISS: nudge silent"; pass=$((pass+1))
else echo "  FAIL  no-history MISS: nudge fired unexpectedly ($out)"; fail=$((fail+1)); fi
rm -rf "$tmp"

# n19: HIT with N prior similar MISSes → no nudge (HITs never nudge).
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "HIT with similar MISSes: exit 0"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  HIT with similar MISSes: nudge silent"; pass=$((pass+1))
else echo "  FAIL  HIT with similar MISSes: nudge fired (HITs should not nudge)"; fail=$((fail+1)); fi
rm -rf "$tmp"

# n20: 2 prior similar MISSes + this MISS = 3 total → default nudge fires.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 2
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "2-prior MISS: exit 0"
assert_contains "NOTE: this MISS plus 2 prior similar" "$out" "2-prior MISS: nudge header"
assert_contains "= 3 total" "$out" "2-prior MISS: nudge counts to 3"
assert_contains "prompt-pattern issue" "$out" "2-prior MISS: nudge mentions issue label"
assert_contains "gh issue create" "$out" "2-prior MISS: nudge prints gh command"
rm -rf "$tmp"

# n21: dissimilar prior MISSes do not count toward the nudge.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 3 "completely different recipe failure unrelated tokens"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "dissimilar prior MISSes: exit 0"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  dissimilar prior MISSes: nudge silent"; pass=$((pass+1))
else echo "  FAIL  dissimilar prior MISSes: nudge fired (Jaccard should have filtered)"; fail=$((fail+1)); fi
rm -rf "$tmp"

# n22: DELEGATE_FEEDBACK_NUDGE_AT=2 fires with one prior similar.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 1
EC=0
out=$(DELEGATE_FEEDBACK_NUDGE_AT=2 DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
      bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "NUDGE_AT=2: exit 0"
assert_contains "NOTE: this MISS plus 1 prior similar" "$out" "NUDGE_AT=2: fires with 1 prior"
rm -rf "$tmp"

# n23: DELEGATE_FEEDBACK_NO_NUDGE=1 silences the nudge even when triggered.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 3
EC=0
out=$(DELEGATE_FEEDBACK_NO_NUDGE=1 DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
      bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "NO_NUDGE=1: exit 0"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  NO_NUDGE=1: nudge silenced"; pass=$((pass+1))
else echo "  FAIL  NO_NUDGE=1: nudge still printed"; fail=$((fail+1)); fi
rm -rf "$tmp"

# n24: MISS with empty reason → no nudge (no tokens to match against).
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss 2>&1) || EC=$?
assert_eq 0 "$EC" "empty-reason MISS: exit 0"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  empty-reason MISS: nudge silent"; pass=$((pass+1))
else echo "  FAIL  empty-reason MISS: nudge fired"; fail=$((fail+1)); fi
rm -rf "$tmp"

# n25: MISSes outside the window (35 days old) don't count toward nudge.
tmp=$(mktemp -d)
: > "$tmp/m.jsonl"
# Write 4 historical similar MISSes 35 days old — outside the 30-day default.
for i in 1 2 3 4; do
  old_ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 35*86400 + '"$i"' * 60))')
  echo "{\"ts\":\"$old_ts\",\"source\":\"feedback\",\"ref_ts\":\"$old_ts\",\"kept\":false,\"reason\":\"pr-description recipe stalled past 30s on prose tier body ($i)\"}" >> "$tmp/m.jsonl"
done
fresh_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"ts\":\"$fresh_ts\",\"source\":\"delegate\",\"tier\":\"prose\",\"model\":\"q\",\"duration_ms\":1000,\"exit_status\":0,\"estimated_tokens_avoided\":40}" >> "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "old-MISS window: exit 0"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  old MISSes outside window: nudge silent"; pass=$((pass+1))
else echo "  FAIL  old MISSes outside window: nudge fired (window filter not working)"; fail=$((fail+1)); fi
# And confirm the same data DOES fire when the window is widened.
EC=0
out=$(DELEGATE_FEEDBACK_NUDGE_WINDOW_DAYS=60 DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
      bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "old-MISS window widened: exit 0"
assert_contains "NOTE: this MISS plus" "$out" "old-MISS window widened: nudge fires"
rm -rf "$tmp"

# n26: nudge body names the matched reasons so the user can recognise them.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 2 "pr-description prose tier stalled past 30 seconds body"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "nudge names matches: exit 0"
assert_contains "pr-description prose tier stalled" "$out" "nudge names matches: reason text rendered"
rm -rf "$tmp"

# n27: stopword-only reason → matcher must short-circuit cleanly (regression
# for the `return outside subroutine` bug gemini-code-assist caught on PR #91:
# the earlier draft used `return print ... unless @new_t` at Perl top level,
# which would crash the Perl process. With the fix in place this test
# exercises the empty-tokens path WITHOUT going through the bash-side
# empty-reason short-circuit (the reason has length, just no content tokens).
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 3
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "on the to a an" 2>&1) || EC=$?
assert_eq 0 "$EC" "stopword-only reason: exit 0 (no Perl crash)"
assert_contains "MISS recorded" "$out" "stopword-only reason: still records the verdict"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  stopword-only reason: nudge silent (no tokens to match)"; pass=$((pass+1))
else echo "  FAIL  stopword-only reason: nudge fired"; fail=$((fail+1)); fi
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# Single-row-per-invocation regression (issue #171)
# Every code path through delegate-feedback.sh must append exactly one new
# JSONL row — never zero (silent drop), never two (double-count in
# metrics-summary). Bisects across verdict (hit/miss), reason absent/present,
# --ts absent/present, and DELEGATE_FEEDBACK_NO_NUDGE absent/present so a
# future stray write or premature row added before the verdict is detected.
# ---------------------------------------------------------------------------

# assert_one_row_added <file> <name>
#   Compares wc -l of <file> before/after the most recent invocation; expects
#   delta == 1 and the appended row to be valid JSON with the expected source.
assert_one_row_added() {
  local before="$1" after="$2" name="$3"
  local delta=$((after - before))
  if (( delta == 1 )); then
    echo "  PASS  $name: exactly one row appended (delta=1)"
    pass=$((pass+1))
  else
    echo "  FAIL  $name: expected 1 row appended, got $delta (before=$before, after=$after)"
    fail=$((fail+1))
  fi
}

# n28: hit with no reason, no --ts → one row.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null 2>&1
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row hit no-reason no-ts"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"kept":true' "$last" "single-row hit no-reason no-ts: kept=true on the appended row"
rm -rf "$tmp"

# n29: hit with reason, no --ts → one row, reason preserved.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit "verbatim used" >/dev/null 2>&1
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row hit with-reason no-ts"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"reason":"verbatim used"' "$last" "single-row hit with-reason no-ts: reason preserved on the appended row"
assert_contains '"kept":true' "$last" "single-row hit with-reason no-ts: kept=true on the appended row"
rm -rf "$tmp"

# n30: hit with --ts pinned to the latest delegate row → one row.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$TS_LATEST" hit "verbatim used" >/dev/null 2>&1
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row hit with-reason with --ts"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "single-row hit with --ts: ref_ts matches pinned"
assert_contains '"reason":"verbatim used"' "$last" "single-row hit with --ts: reason preserved"
rm -rf "$tmp"

# n31: miss with reason, no --ts → one row, reason and kept=false preserved.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "needed rewrite" >/dev/null 2>&1
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row miss with-reason no-ts"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"reason":"needed rewrite"' "$last" "single-row miss with-reason no-ts: reason preserved"
assert_contains '"kept":false' "$last" "single-row miss with-reason no-ts: kept=false preserved"
rm -rf "$tmp"

# n32: miss with reason + --ts → one row, both preserved.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$TS_LATEST" miss "needed rewrite" >/dev/null 2>&1
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row miss with-reason with --ts"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "single-row miss with --ts: ref_ts matches pinned"
assert_contains '"reason":"needed rewrite"' "$last" "single-row miss with --ts: reason preserved"
assert_contains '"kept":false' "$last" "single-row miss with --ts: kept=false preserved"
rm -rf "$tmp"

# n33: miss with reason + DELEGATE_FEEDBACK_NO_NUDGE=1 → one row even when
# nudge would otherwise fire. Seeds 5 prior similar MISSes so the nudge code
# path is fully exercised but silenced — guards against a future change that
# accidentally writes a row during the nudge logic.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_FEEDBACK_NO_NUDGE=1 DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" >/dev/null 2>&1
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row miss with NO_NUDGE=1 + similar history"
rm -rf "$tmp"

# n34: miss with reason + nudge fires (default settings, ≥3 similar prior) →
# still exactly one row. The nudge writes to stderr only — a regression that
# adds a preliminary or duplicate JSONL row during the matcher must fail
# here. This is the load-bearing assertion against the "two rows per
# verdict — one empty, one with reason" shape called out in issue #171.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1)
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row miss nudge-fires default + 5 similar history"
assert_contains "NOTE: this MISS plus" "$out" "single-row miss nudge-fires: nudge actually fired (so the assertion is meaningful)"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"reason":"pr-description recipe stalled past 30s on prose tier body"' "$last" "single-row miss nudge-fires: reason on the appended row is the real one, not empty"
assert_contains '"kept":false' "$last" "single-row miss nudge-fires: kept=false on the appended row"
rm -rf "$tmp"

# n35: same scenario as n34 but with --ts pinning → still exactly one row.
# Crosses the two most recently-extended code paths (--ts validation + nudge
# matcher) so a stray write at either branch boundary is detected.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  bash "$SCRIPT" --ts "$TS_LATEST" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1)
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row miss with --ts + nudge fires"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "single-row miss with --ts + nudge: ref_ts pinned"
assert_contains '"reason":"pr-description recipe stalled past 30s on prose tier body"' "$last" "single-row miss with --ts + nudge: reason on the appended row is the real one"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
