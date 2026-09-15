#!/usr/bin/env bash
# Unit tests for scripts/delegate-feedback.sh. Builds a synthetic metrics
# JSONL in $tmp and asserts on the appended feedback row.

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

# Seeds two delegate rows and one experiment row. The oldest sits outside
# the default 300 s window so the implicit lookup sees exactly one candidate
# (two fresh rows refuse as ambiguous, #474); perl keeps the timestamp
# format the same on BSD and GNU.
TS_OLDEST=""
TS_LATEST=""
seed_metrics() {
  local file="$1"
  TS_OLDEST=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-400))')
  TS_LATEST=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$file" <<EOF
{"ts":"$TS_OLDEST","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_span_id":"$ID_OLDEST"}
{"ts":"$TS_OLDEST","source":"experiment","session":"foo","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":10}
{"ts":"$TS_LATEST","source":"delegate","tier":"reasoning","model":"d","project":"seed-project","duration_ms":7000,"exit_status":0,"estimated_tokens_avoided":60,"otel_span_id":"$ID_LATEST"}
EOF
}
ID_OLDEST="0000000000000001"
ID_LATEST="0000000000000002"

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
assert_contains '"project":"seed-project"' "$last" "hit: project is copied from the referenced delegate row"
[[ "$last" == *'"reason"'* ]] && { fail=$((fail+1)); echo "  FAIL  hit (no reason): reason field absent"; } || { pass=$((pass+1)); echo "  PASS  hit (no reason): reason field absent"; }
rm -rf "$tmp"

# 5b. The project is the referenced row's, never re-derived from the cwd
# (#474); a row with no project yields a verdict with no project.
tmp=$(mktemp -d)
T_FRESH=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0}\n' "$T_FRESH" > "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null 2>&1
assert_eq "false" "$(tail -1 "$tmp/m.jsonl" | jq -r 'has("project")')" \
  "project: a referenced row with no project yields a verdict with no project"
rm -rf "$tmp"

# 5c. DELEGATE_PROJECT in the recording shell does not override the copy.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_PROJECT=other-repo bash "$SCRIPT" hit >/dev/null 2>&1
assert_eq "seed-project" "$(tail -1 "$tmp/m.jsonl" | jq -r '.project // ""')" \
  "project: DELEGATE_PROJECT in the recording shell does not override the row's project"
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

# 7. ref_ts is the one delegate row inside the window; an older row outside
# it is not a candidate.
tmp=$(mktemp -d)
T_EARLY=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-400))')
T_LATE=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-10))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_EARLY","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"$T_EARLY","source":"experiment","session":"foo","model":"q","duration_ms":1000,"exit_status":0,"estimated_tokens_avoided":10}
{"ts":"$T_LATE","source":"delegate","tier":"long-context","model":"q","duration_ms":9000,"exit_status":0,"estimated_tokens_avoided":80}
EOF
EC=0
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "ref_ts: one fresh candidate plus a stale row -> exit 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains "\"ref_ts\":\"$T_LATE\"" "$last" "ref_ts: picks the fresh delegate, not the stale one"
rm -rf "$tmp"

# 7b. Two delegate rows inside the window is an ambiguity, not a choice
# (#474): the refusal lists every candidate so the caller can pin.
tmp=$(mktemp -d)
T_A=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-40))')
T_B=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-10))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_A","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"repo-butler","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_span_id":"aaaaaaaaaaaaaaa1"}
{"ts":"$T_B","source":"delegate","tier":"prose","model":"q","duration_ms":9000,"exit_status":0,"estimated_tokens_avoided":80,"otel_span_id":"aaaaaaaaaaaaaaa2"}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 1 "$EC" "ambiguous window: exit 1 when two delegate rows are inside the window"
assert_contains "aaaaaaaaaaaaaaa1  $T_A  commit-message  repo-butler" "$out" \
  "ambiguous window: each candidate is listed as id, ts, recipe, project"
assert_contains "aaaaaaaaaaaaaaa2  $T_B  (bare)  -" "$out" \
  "ambiguous window: a bare-tier row with no project is listed with placeholders"
assert_contains "--id" "$out" "ambiguous window: the refusal names --id as the pin"
assert_eq 2 "$(grep -c '' "$tmp/m.jsonl")" "ambiguous window: no row appended on refuse"
# Pinning resolves it to the pinned row, not the newest.
EC=0
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$T_A" hit >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "ambiguous window: --ts resolves the ambiguity"
assert_contains "\"ref_ts\":\"$T_A\"" "$(tail -1 "$tmp/m.jsonl")" \
  "ambiguous window: the pinned verdict lands on the pinned row"
# DELEGATE_FEEDBACK_STALE_SECONDS=0 keeps the unbounded most-recent path.
EC=0
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_STALE_SECONDS=0 bash "$SCRIPT" hit >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "ambiguous window: STALE_SECONDS=0 keeps the unbounded most-recent lookup"
assert_contains "\"ref_ts\":\"$T_B\"" "$(tail -1 "$tmp/m.jsonl")" \
  "ambiguous window: STALE_SECONDS=0 attaches to the newest row as before"
rm -rf "$tmp"

# 7c. The pin is the row's otel_span_id, since parallel delegations share a
# second. Two draft-bearing rows share one second and the pin names the
# first, the case a last-row-wins lookup gets wrong.
same_second_setup() {
  tmp=$(mktemp -d); mkdir -p "$tmp/drafts"
  T_SHARED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_SHARED","source":"delegate","tier":"prose","model":"q","recipe":"commit-message","project":"repo-butler","exit_status":0,"otel_trace_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1","otel_span_id":"aaaaaaaaaaaaaaa1","draft_file":"20260911T054711Z-first000.draft.txt"}
{"ts":"$T_SHARED","source":"delegate","tier":"prose","model":"q","recipe":"maintainer-reply","project":"teams-for-linux","exit_status":0,"otel_trace_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2","otel_span_id":"aaaaaaaaaaaaaaa2","draft_file":"20260911T054711Z-second00.draft.txt"}
EOF
}
same_second_setup
printf 'the commit message that shipped' > "$tmp/mine.txt"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id aaaaaaaaaaaaaaa1 --source agent --final "$tmp/mine.txt" miss "r" 2>&1) || EC=$?
assert_eq 0 "$EC" "--id: pins a row on a shared second"
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "$T_SHARED" "$(printf '%s' "$last" | jq -r '.ref_ts // ""')" "--id: ref_ts is the pinned row's ts"
assert_eq "aaaaaaaaaaaaaaa1" "$(printf '%s' "$last" | jq -r '.ref_id // ""')" "--id: the row records ref_id beside ref_ts"
assert_eq "repo-butler" "$(printf '%s' "$last" | jq -r '.project // ""')" "--id: project comes off the pinned (first) row, not the last row on that second"
assert_eq "20260911T054711Z-first000.final.txt" "$(printf '%s' "$last" | jq -r '.final_file // ""')" \
  "--id: the final is named after the pinned row's draft, not its sibling's"
assert_eq "the commit message that shipped" "$(cat "$tmp/drafts/20260911T054711Z-first000.final.txt" 2>/dev/null)" \
  "--id: the shipped text sits beside the pinned row's draft"
assert_eq "false" "$([[ -e "$tmp/drafts/20260911T054711Z-second00.final.txt" ]] && echo true || echo false)" \
  "--id: nothing is written under the sibling's stem"
rm -rf "$tmp"

# --ts on a shared second refuses and lists the candidates with their ids.
same_second_setup
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$T_SHARED" hit 2>&1) || EC=$?
assert_eq 1 "$EC" "--ts on a shared second: exit 1"
assert_contains "aaaaaaaaaaaaaaa1  $T_SHARED  commit-message  repo-butler" "$out" \
  "--ts on a shared second: lists the first candidate with its id"
assert_contains "aaaaaaaaaaaaaaa2  $T_SHARED  maintainer-reply  teams-for-linux" "$out" \
  "--ts on a shared second: lists the second candidate with its id"
assert_contains "--id" "$out" "--ts on a shared second: tells the caller to pin with --id"
assert_eq 2 "$(grep -c '' "$tmp/m.jsonl")" "--ts on a shared second: no row appended"
rm -rf "$tmp"

# An unknown id refuses, like an unknown ts.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --id ffffffffffffffff hit 2>&1) || EC=$?
assert_eq 1 "$EC" "--id: unknown id -> exit 1"
assert_contains "does not match any delegate row" "$out" "--id: unknown id names the mismatch"
assert_eq 3 "$(grep -c '' "$tmp/m.jsonl")" "--id: unknown id appends no row"
# --id needs a value, and cannot be combined with --ts (two pins, one row).
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" "--id=" hit 2>&1) || EC=$?
assert_eq 2 "$EC" "--id= (empty value) -> exit 2"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --id "$ID_LATEST" --ts "$TS_LATEST" hit 2>&1) || EC=$?
assert_eq 2 "$EC" "--id with --ts -> exit 2 (one pin)"
# The implicit path records ref_id when the row has one, and none when it does not.
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null 2>&1
assert_eq "$ID_LATEST" "$(tail -1 "$tmp/m.jsonl" | jq -r '.ref_id // ""')" \
  "ref_id: the implicit path records the referenced row's otel_span_id"
rm -rf "$tmp"
tmp=$(mktemp -d)
T_FRESH=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0}\n' "$T_FRESH" > "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit >/dev/null 2>&1
assert_eq "false" "$(tail -1 "$tmp/m.jsonl" | jq -r 'has("ref_id")')" \
  "ref_id: a referenced row with no otel_span_id yields a verdict with no ref_id"
rm -rf "$tmp"

# 7d. ts is the start time but rows land at completion, so the one fresh
# candidate need not be the last delegate line in the file.
tmp=$(mktemp -d)
T_SHORT=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-10))')
T_LONG=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-400))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_SHORT","source":"delegate","tier":"prose","model":"q","exit_status":0,"otel_span_id":"bbbbbbbbbbbbbbb1"}
{"ts":"$T_LONG","source":"delegate","tier":"prose","model":"q","exit_status":0,"otel_span_id":"bbbbbbbbbbbbbbb2"}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "single fresh candidate not on the last line: exit 0"
assert_eq "$T_SHORT" "$(tail -1 "$tmp/m.jsonl" | jq -r '.ref_ts // ""')" \
  "single fresh candidate not on the last line: the verdict lands on the fresh row"
assert_eq "bbbbbbbbbbbbbbb1" "$(tail -1 "$tmp/m.jsonl" | jq -r '.ref_id // ""')" \
  "single fresh candidate not on the last line: ref_id is the fresh row's"
rm -rf "$tmp"

# 8. Output is valid JSON (jq can parse it back).
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "ok" >/dev/null
last=$(tail -1 "$tmp/m.jsonl")
EC=0
echo "$last" | jq -e . >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "feedback row is valid JSON"
rm -rf "$tmp"

# 9. Feedback after a feedback still finds the original delegate.
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

# 11. Stale window: refuse when the most recent delegate row is older than
# the window (default 300 s).
tmp=$(mktemp -d)
T_OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-3600))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_OLD","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 1 "$EC" "stale window: exit 1 when delegate row is too old"
assert_contains "DELEGATE_FEEDBACK_STALE_SECONDS" "$out" "stale window: error mentions env override"
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

# 15. A --ts that matches a feedback row, not a delegate row, exits 1.
tmp=$(mktemp -d)
T_DEL=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-200))')
T_FB=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-100))')
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_DEL","source":"delegate","tier":"prose","model":"q","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
{"ts":"$T_FB","source":"feedback","ref_ts":"$T_DEL","kept":true}
EOF
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$T_FB" miss "r" 2>&1) || EC=$?
assert_eq 1 "$EC" "--ts pointing to a feedback row -> exit 1"
assert_contains "does not match any delegate row" "$out" "--ts feedback row: error refers to no-match"
rm -rf "$tmp"

# 16. --ts requires a value.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts hit 2>&1) || EC=$?
# Exit 2 from the parser, or 'hit' consumed as the ts and no verdict found:
# either rejection is acceptable.
[[ "$EC" -ne 0 ]] && pass=$((pass+1)) && echo "  PASS  --ts without value -> non-zero exit" || { fail=$((fail+1)); echo "  FAIL  --ts without value should fail (got $EC)"; }
rm -rf "$tmp"

# 16b. --ts= (empty value) is rejected with the same wording.
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

# --- Recurrence nudge on MISS (#88) ---

# seed_history <file> <N_similar> [<reason>]: N delegate + MISS pairs within
# the last hour, then a fresh delegate row for the new verdict to attach to.
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

# n24: a MISS with no reason is refused before the matcher runs.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss 2>&1) || EC=$?
assert_eq 2 "$EC" "empty-reason MISS: exit 2"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  empty-reason MISS: nudge silent"; pass=$((pass+1))
else echo "  FAIL  empty-reason MISS: nudge fired"; fail=$((fail+1)); fi
rm -rf "$tmp"

# n25: MISSes outside the 30-day window (35 days old) do not count.
tmp=$(mktemp -d)
: > "$tmp/m.jsonl"
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
# The same data fires when the window is widened.
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

# n27: a stopword-only reason has length but no tokens, so it reaches the
# matcher's empty-tokens path and must not crash perl.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 3
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "on the to a an" 2>&1) || EC=$?
assert_eq 0 "$EC" "stopword-only reason: exit 0 (no Perl crash)"
assert_contains "MISS recorded" "$out" "stopword-only reason: still records the verdict"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  stopword-only reason: nudge silent (no tokens to match)"; pass=$((pass+1))
else echo "  FAIL  stopword-only reason: nudge fired"; fail=$((fail+1)); fi
rm -rf "$tmp"

# n27b: the draft gh command targets DELEGATE_GITHUB_REPO when set.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 2
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "repo default: exit 0"
assert_contains "--repo IsmaelMartinez/delegate-local" "$out" "repo default: nudge targets IsmaelMartinez/delegate-local"
rm -rf "$tmp"
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 2
EC=0
out=$(DELEGATE_GITHUB_REPO="someorg/forked-skill" DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
      bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "repo override: exit 0"
assert_contains "--repo someorg/forked-skill" "$out" "repo override: nudge targets DELEGATE_GITHUB_REPO"
if [[ "$out" != *"IsmaelMartinez/delegate-local"* ]]; then echo "  PASS  repo override: default repo absent from nudge"; pass=$((pass+1))
else echo "  FAIL  repo override: default repo still present in nudge"; fail=$((fail+1)); fi
rm -rf "$tmp"

# --- Every code path appends exactly one row (#171): never zero, never two ---

# assert_one_row_added <before_count> <after_count> <name>
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

# n33: miss + NO_NUDGE=1 with five similar priors, so the nudge path runs
# silenced and still writes one row.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
DELEGATE_FEEDBACK_NO_NUDGE=1 DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" >/dev/null 2>&1
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "single-row miss with NO_NUDGE=1 + similar history"
rm -rf "$tmp"

# n34: miss with the nudge firing still writes exactly one row (the nudge is
# stderr only).
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

# n35: n34 with --ts pinning.
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

# --- Feedback as a linked OTel span (#134, ADR 0007): a new trace whose
# `links` and parent_* attributes point at the delegation ---

# Captures the OTel POST body; the feedback script only ever calls /v1/traces.
make_mock_curl_fb_otel() {
  local dir="$1" otel_sniff="${2:-/dev/null}" invocations="${3:-/dev/null}" behaviour="${4:-ok}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
echo "args \$*" >> "${invocations}"
saw_otel=0
for a in "\$@"; do
  case "\$a" in *"/v1/traces"*) saw_otel=1 ;; esac
done
if (( saw_otel == 1 )); then
  cat > "${otel_sniff}"
  case "${behaviour}" in
    fail)    exit 22 ;;
    timeout) exit 28 ;;
    refused) exit 7 ;;
    *)       exit 0 ;;
  esac
fi
exit 0
EOF
  chmod +x "$dir/curl"
}

# seed_metrics_with_otel <file> [<trace_id>] [<span_id>]: one delegate row with OTel ids.
seed_metrics_with_otel() {
  local file="$1"
  local tid="${2:-aaaa1111bbbb2222cccc3333dddd4444}"
  local sid="${3:-feedface12345678}"
  TS_LATEST=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$file" <<EOF
{"ts":"$TS_LATEST","source":"delegate","tier":"prose","model":"qwen3.6:35b","project":"otel-project","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_trace_id":"$tid","otel_span_id":"$sid"}
EOF
}

# FB-OT1. DELEGATE_OTEL_ENDPOINT unset: no OTLP POST.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  bash "$SCRIPT" hit "verbatim used" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT1: endpoint unset → exits 0"
otel_count=$(grep -c '^args' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 0 "$otel_count" "FB-OT1: endpoint unset → zero OTel POSTs"
fb_count=$(grep -c '"source":"feedback"' "$tmp/m.jsonl")
assert_eq 1 "$fb_count" "FB-OT1: feedback row still written when exporter disabled"
rm -rf "$tmp"

# FB-OT2. Endpoint set: exactly one OTLP POST in the feedback shape, with
# the reason redacted by default (#158).
tmp=$(mktemp -d)
PARENT_TID="aaaa1111bbbb2222cccc3333dddd4444"
PARENT_SID="feedface12345678"
seed_metrics_with_otel "$tmp/m.jsonl" "$PARENT_TID" "$PARENT_SID"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit "verbatim used" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT2: endpoint set → exits 0"
otel_count=$(grep -c '^args' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 1 "$otel_count" "FB-OT2: endpoint set → exactly one OTLP POST"
otel_body=$(cat "$otel_sniff")
if echo "$otel_body" | jq -e . >/dev/null 2>&1; then
  echo "  PASS  FB-OT2: body parses as JSON"
  pass=$((pass+1))
else
  echo "  FAIL  FB-OT2: body is not valid JSON"
  fail=$((fail+1))
fi
assert_contains '"feedback qwen3.6:35b"' "$otel_body" "FB-OT2: span name includes parent model"
assert_contains '"kind":1' "$otel_body" "FB-OT2: span kind=1 (INTERNAL)"
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT2: delegate.feedback.verdict attribute"
assert_contains '"hit"' "$otel_body" "FB-OT2: verdict value is 'hit'"
assert_contains '"delegate.feedback.parent_trace_id"' "$otel_body" "FB-OT2: parent_trace_id attribute"
assert_contains "\"$PARENT_TID\"" "$otel_body" "FB-OT2: parent_trace_id value matches delegate row"
assert_contains '"delegate.feedback.parent_span_id"' "$otel_body" "FB-OT2: parent_span_id attribute"
assert_contains "\"$PARENT_SID\"" "$otel_body" "FB-OT2: parent_span_id value matches delegate row"
# delegate.project is the referenced row's project, the same value as the JSONL row.
assert_contains '"delegate.project"' "$otel_body" "FB-OT2: delegate.project attribute present on feedback span"
fb_project=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].attributes | map(select(.key == "delegate.project")) | .[0].value.stringValue // ""')
assert_eq "otel-project" "$fb_project" "FB-OT2: delegate.project is the referenced delegate row's project"
assert_eq "otel-project" "$(tail -1 "$tmp/m.jsonl" | jq -r '.project // ""')" \
  "FB-OT2: the feedback row carries the same project as the span"
case "$otel_body" in
  *'delegate.feedback.reason'*)
    echo "  FAIL  FB-OT2: delegate.feedback.reason MUST be absent without DELEGATE_OTEL_INCLUDE_CONTENT=1 (Track F #158)"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT2: delegate.feedback.reason absent by default (Track F #158)"
    pass=$((pass+1));;
esac
case "$otel_body" in
  *'verbatim used'*)
    echo "  FAIL  FB-OT2: reason text 'verbatim used' must not appear in payload when content is redacted"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT2: reason text not present in payload (no sentinel leak, no key leak)"
    pass=$((pass+1));;
esac
assert_contains '"links":[' "$otel_body" "FB-OT2: links array present"
links_trace=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].links[0].traceId')
links_span=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].links[0].spanId')
assert_eq "$PARENT_TID" "$links_trace" "FB-OT2: links[0].traceId == parent trace_id"
assert_eq "$PARENT_SID" "$links_span" "FB-OT2: links[0].spanId == parent span_id"
# The feedback span is a new trace.
own_trace=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].traceId')
own_span=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].spanId')
if [[ "$own_trace" != "$PARENT_TID" ]]; then
  echo "  PASS  FB-OT2: feedback trace_id differs from parent (new-trace pattern)"
  pass=$((pass+1))
else
  echo "  FAIL  FB-OT2: feedback trace_id is the parent's (should be new)"
  fail=$((fail+1))
fi
if [[ "$own_span" != "$PARENT_SID" ]]; then
  echo "  PASS  FB-OT2: feedback span_id differs from parent"
  pass=$((pass+1))
else
  echo "  FAIL  FB-OT2: feedback span_id is the parent's (should be new)"
  fail=$((fail+1))
fi
case "$otel_body" in
  *'gen_ai.prompt'*|*'gen_ai.completion'*|*'delegate.prompt_text'*|*'delegate.output_text'*)
    echo "  FAIL  FB-OT2: body must not contain content-bearing attributes"
    fail=$((fail+1));;
  *) echo "  PASS  FB-OT2: body has no content-bearing attributes"; pass=$((pass+1));;
esac
fb_count=$(grep -c '"source":"feedback"' "$tmp/m.jsonl")
assert_eq 1 "$fb_count" "FB-OT2: feedback row still written alongside the OTLP POST"
rm -rf "$tmp"

# FB-OT3. DELEGATE_OTEL_INCLUDE_CONTENT=1: the reason travels with the verdict.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=1 \
  bash "$SCRIPT" miss "had to rewrite the bullets" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT3: miss verdict + include-content opt-in → exits 0"
otel_body=$(cat "$otel_sniff")
assert_contains '"miss"' "$otel_body" "FB-OT3: verdict value is 'miss'"
assert_contains '"delegate.feedback.reason"' "$otel_body" "FB-OT3: reason attribute present when include-content=1"
assert_contains '"had to rewrite the bullets"' "$otel_body" "FB-OT3: reason text preserved when include-content=1"
rm -rf "$tmp"

# FB-OT4. A hit with no reason omits the attribute rather than sending "".
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT4: hit verdict no-reason → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'delegate.feedback.reason'*)
    echo "  FAIL  FB-OT4: reason attribute should be absent when no reason supplied"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT4: reason attribute absent when no reason supplied"
    pass=$((pass+1));;
esac
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT4: verdict attribute still present"
rm -rf "$tmp"

# FB-OT5. An OTLP failure does not change the exit status; the row was
# appended before the export ran.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "fail"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit "ok" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT5: OTel HTTP error → delegate-feedback.sh STILL exits 0"
fb_count=$(grep -c '"source":"feedback"' "$tmp/m.jsonl")
assert_eq 1 "$fb_count" "FB-OT5: feedback row still written when OTLP fails"
rm -rf "$tmp"

# FB-OT6. DELEGATE_OTEL_TIMEOUT flows into curl's --max-time argv.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_TIMEOUT=1 \
  bash "$SCRIPT" hit "ok" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT6: timeout override → exits 0"
otel_args_line=$(grep '^args' "$invocations" | head -1)
assert_contains "--max-time 1" "$otel_args_line" "FB-OT6: --max-time 1 in curl argv"
rm -rf "$tmp"

# FB-OT7. DELEGATE_OTEL_HEADERS produces one -H flag per header.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_HEADERS="Authorization: Bearer x, X-Tenant: y" \
  bash "$SCRIPT" hit "ok" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT7: headers → exits 0"
otel_args_line=$(grep '^args' "$invocations" | head -1)
assert_contains "Authorization: Bearer x" "$otel_args_line" "FB-OT7: first header in argv"
assert_contains "X-Tenant: y" "$otel_args_line" "FB-OT7: second header in argv"
rm -rf "$tmp"

# FB-OT8. A parent row without otel ids still gets a span, with no `links`.
tmp=$(mktemp -d)
TS_PRE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$TS_PRE","source":"delegate","tier":"prose","model":"qwen3.6:35b","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
EOF
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit "ok" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT8: pre-exporter row → exits 0"
otel_count=$(grep -c '^args' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 1 "$otel_count" "FB-OT8: OTel POST happens even without parent IDs"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'"links":['*)
    echo "  FAIL  FB-OT8: links array should be absent when parent IDs unknown"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT8: links array absent when parent IDs unknown"
    pass=$((pass+1));;
esac
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT8: verdict attribute still emitted"
rm -rf "$tmp"

# FB-OT9. A --ts pin links to the pinned row's ids, not the newest row's.
tmp=$(mktemp -d)
T_OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-200))')
T_RECENT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OLD_TID="1111111111111111aaaaaaaaaaaaaaaa"
OLD_SID="1111111111111111"
RECENT_TID="2222222222222222bbbbbbbbbbbbbbbb"
RECENT_SID="2222222222222222"
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_OLD","source":"delegate","tier":"prose","model":"qwen3.6:35b","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_trace_id":"$OLD_TID","otel_span_id":"$OLD_SID"}
{"ts":"$T_RECENT","source":"delegate","tier":"prose","model":"qwen3.6:35b","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_trace_id":"$RECENT_TID","otel_span_id":"$RECENT_SID"}
EOF
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --ts "$T_OLD" hit "verbatim" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT9: --ts pinned + OTel → exits 0"
otel_body=$(cat "$otel_sniff")
linked_trace=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].links[0].traceId')
assert_eq "$OLD_TID" "$linked_trace" "FB-OT9: links use the --ts pinned row's trace_id, not the most-recent row's"
rm -rf "$tmp"

# FB-OT10. DELEGATE_OTEL_HEADERS url-decodes values, so a %2C comma survives
# the split between headers (mirrors OT12 in test-delegate.sh).
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_HEADERS="Cookie: a%3D1%2C%20b%3D2, X-Tenant: y" \
  bash "$SCRIPT" hit "ok" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT10: url-encoded comma in header → exits 0"
otel_args_line=$(grep '^args' "$invocations" | head -1)
assert_contains "Cookie: a=1, b=2" "$otel_args_line" "FB-OT10: header value's literal comma round-trips after url-decode"
assert_contains "X-Tenant: y" "$otel_args_line" "FB-OT10: second header still parsed after comma-bearing first header"
# Content-Type + Cookie + X-Tenant; a fragmented Cookie would make four.
h_count=$(echo "$otel_args_line" | grep -oE '\-H ' | wc -l | tr -d ' ')
assert_eq 3 "$h_count" "FB-OT10: exactly three -H flags (Content-Type + Cookie + X-Tenant) — not four"
rm -rf "$tmp"

# --- Privacy redaction (#158): DELEGATE_OTEL_INCLUDE_CONTENT gates the
# reason attribute; the JSONL row always keeps the reason ---

# FB-OT11. Default redaction: no reason key, no reason text, no sentinel on
# the wire; the on-disk row still carries it.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
REASON="sensitive customer URL https://internal.example.com/customers/42 leaked into the prompt"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" miss "$REASON" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT11: default redaction → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'delegate.feedback.reason'*)
    echo "  FAIL  FB-OT11: delegate.feedback.reason key MUST be absent by default"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT11: delegate.feedback.reason key absent by default"
    pass=$((pass+1));;
esac
case "$otel_body" in
  *'internal.example.com'*|*'customers/42'*)
    echo "  FAIL  FB-OT11: reason text MUST NOT appear anywhere in the body"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT11: reason text omitted from body entirely"
    pass=$((pass+1));;
esac
case "$otel_body" in
  *'<redacted>'*)
    echo "  FAIL  FB-OT11: no '<redacted>' sentinel should leak into the body"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT11: no '<redacted>' sentinel in body (omission, not placeholder)"
    pass=$((pass+1));;
esac
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT11: verdict attribute still present"
assert_contains '"miss"' "$otel_body" "FB-OT11: verdict value 'miss' still present"
assert_contains '"delegate.feedback.parent_trace_id"' "$otel_body" "FB-OT11: parent_trace_id attribute still present"
last_row=$(grep '"source":"feedback"' "$tmp/m.jsonl" | tail -1)
assert_contains "$REASON" "$last_row" "FB-OT11: reason still recorded on-disk JSONL row (gate is wire-only)"
rm -rf "$tmp"

# FB-OT12. Opt-in: the reason attribute carries its original value.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
REASON="prose model added 'going forward' tail to body paragraph"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=1 \
  bash "$SCRIPT" miss "$REASON" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT12: opt-in include-content → exits 0"
otel_body=$(cat "$otel_sniff")
assert_contains '"delegate.feedback.reason"' "$otel_body" "FB-OT12: reason attribute present when opt-in"
assert_contains "\"$REASON\"" "$otel_body" "FB-OT12: reason value matches input verbatim"
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT12: verdict attribute present"
assert_contains '"miss"' "$otel_body" "FB-OT12: verdict value 'miss' present"
rm -rf "$tmp"

# FB-OT13. Opt-in with no reason still emits no reason attribute.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=1 \
  bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT13: opt-in + no reason → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'delegate.feedback.reason'*)
    echo "  FAIL  FB-OT13: reason attribute should be absent when no reason supplied (even with opt-in)"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT13: reason attribute absent when no reason supplied (opt-in is necessary, not sufficient)"
    pass=$((pass+1));;
esac
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT13: verdict attribute present"
rm -rf "$tmp"

# FB-OT14. An explicit =0 redacts like unset.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=0 \
  bash "$SCRIPT" miss "explicit zero" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT14: explicit =0 → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'delegate.feedback.reason'*|*'explicit zero'*)
    echo "  FAIL  FB-OT14: DELEGATE_OTEL_INCLUDE_CONTENT=0 must redact same as unset"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT14: DELEGATE_OTEL_INCLUDE_CONTENT=0 redacts same as unset"
    pass=$((pass+1));;
esac
rm -rf "$tmp"

# FB-OT15. Only the literal "1" enables include-content; =true stays redacted.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_INCLUDE_CONTENT=true \
  bash "$SCRIPT" miss "should stay redacted" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT15: =true (not '1') → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'delegate.feedback.reason'*|*'should stay redacted'*)
    echo "  FAIL  FB-OT15: DELEGATE_OTEL_INCLUDE_CONTENT=true must NOT enable content (only '1')"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT15: only literal '1' enables include-content (typo-safe)"
    pass=$((pass+1));;
esac
rm -rf "$tmp"

# --- delegate.recipe on the feedback span (#187): copied from the parent
# row; a recipe name is metadata, so it is never content-gated ---

# seed_metrics_with_recipe <file> <recipe_name> [<trace_id>] [<span_id>]
seed_metrics_with_recipe() {
  local file="$1" recipe="$2"
  local tid="${3:-aaaa1111bbbb2222cccc3333dddd4444}"
  local sid="${4:-feedface12345678}"
  TS_LATEST=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$file" <<EOF
{"ts":"$TS_LATEST","source":"delegate","tier":"prose","model":"qwen3.6:35b","recipe":"$recipe","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_trace_id":"$tid","otel_span_id":"$sid"}
EOF
}

# FB-OT16. A recipe parent puts delegate.recipe on the span without the content gate.
tmp=$(mktemp -d)
seed_metrics_with_recipe "$tmp/m.jsonl" "commit-message"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit "verbatim used" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT16: recipe parent → exits 0"
otel_body=$(cat "$otel_sniff")
assert_contains '"delegate.recipe"' "$otel_body" "FB-OT16: delegate.recipe attribute present on feedback span"
assert_contains '"commit-message"' "$otel_body" "FB-OT16: delegate.recipe value matches parent row"
case "$otel_body" in
  *'delegate.feedback.reason'*)
    echo "  FAIL  FB-OT16: reason should be absent (content gate unchanged)"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT16: reason absent (recipe travels but content gate still applies to reason)"
    pass=$((pass+1));;
esac
rm -rf "$tmp"

# FB-OT17. A bare-tier parent omits the delegate.recipe attribute entirely.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit "verbatim used" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT17: bare-tier parent → exits 0"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'delegate.recipe'*)
    echo "  FAIL  FB-OT17: delegate.recipe MUST be absent when parent had no --recipe"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT17: delegate.recipe absent for bare-tier parent (consistent with parent span)"
    pass=$((pass+1));;
esac
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT17: verdict attribute still present"
assert_contains '"delegate.feedback.parent_trace_id"' "$otel_body" "FB-OT17: parent_trace_id attribute still present"
rm -rf "$tmp"

# FB-OT18. A parent row with neither otel ids nor recipe still gets a span:
# no links, no delegate.recipe, verdict present.
tmp=$(mktemp -d)
TS_PRE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$TS_PRE","source":"delegate","tier":"prose","model":"qwen3.6:35b","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40}
EOF
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit "ok" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT18: pre-exporter row (no recipe, no otel IDs) → exits 0"
otel_count=$(grep -c '^args' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 1 "$otel_count" "FB-OT18: OTel POST happens even on pre-exporter rows"
otel_body=$(cat "$otel_sniff")
case "$otel_body" in
  *'delegate.recipe'*)
    echo "  FAIL  FB-OT18: delegate.recipe MUST be absent when parent row has no recipe field"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT18: delegate.recipe absent on pre-exporter rows (recipe field genuinely missing)"
    pass=$((pass+1));;
esac
assert_contains '"delegate.feedback.verdict"' "$otel_body" "FB-OT18: verdict still travels"
case "$otel_body" in
  *'"links":['*)
    echo "  FAIL  FB-OT18: links should be absent on pre-exporter rows"
    fail=$((fail+1));;
  *)
    echo "  PASS  FB-OT18: links absent on pre-exporter rows (parent IDs unknown)"
    pass=$((pass+1));;
esac
rm -rf "$tmp"

# FB-OT19. A --ts pin takes the recipe from the pinned row, not the newest.
tmp=$(mktemp -d)
T_OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-200))')
T_RECENT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OLD_TID="1111111111111111aaaaaaaaaaaaaaaa"
OLD_SID="1111111111111111"
RECENT_TID="2222222222222222bbbbbbbbbbbbbbbb"
RECENT_SID="2222222222222222"
cat > "$tmp/m.jsonl" <<EOF
{"ts":"$T_OLD","source":"delegate","tier":"prose","model":"qwen3.6:35b","recipe":"commit-message","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_trace_id":"$OLD_TID","otel_span_id":"$OLD_SID"}
{"ts":"$T_RECENT","source":"delegate","tier":"prose","model":"qwen3.6:35b","recipe":"pr-description","duration_ms":5000,"exit_status":0,"estimated_tokens_avoided":40,"otel_trace_id":"$RECENT_TID","otel_span_id":"$RECENT_SID"}
EOF
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --ts "$T_OLD" hit "verbatim" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-OT19: --ts pinned to old row with recipe → exits 0"
otel_body=$(cat "$otel_sniff")
recipe_attr=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].attributes[] | select(.key=="delegate.recipe") | .value.stringValue')
assert_eq "commit-message" "$recipe_attr" "FB-OT19: delegate.recipe pulled from --ts pinned row, not most-recent"
rm -rf "$tmp"

# FB-OT20. --id on a shared second: link and project come off the pinned
# (first) row, not the last row with that ts.
same_second_setup
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --id aaaaaaaaaaaaaaa1 hit "verbatim" >/dev/null 2>&1
assert_eq "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1" \
  "$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].links[0].traceId' "$otel_sniff" 2>/dev/null)" \
  "FB-OT20: --id on a shared second links the pinned row's trace, not its sibling's"
assert_eq "repo-butler" \
  "$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].attributes[] | select(.key=="delegate.project") | .value.stringValue' "$otel_sniff" 2>/dev/null)" \
  "FB-OT20: --id on a shared second carries the pinned row's project"
rm -rf "$tmp"

# --- One verdict tier (ADR 0030): default agent, verdict_source:"agent" on
# every row, --source human refused, any other value rejected ---

# FB-SRC1. Default (no --source) is agent.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-SRC1: default source → exits 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"verdict_source":"agent"' "$last" "FB-SRC1: verdict_source is agent by default"
rm -rf "$tmp"

# FB-SRC2. --source agent: the row carries verdict_source:"agent".
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --source agent hit 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-SRC2: --source agent → exits 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"verdict_source":"agent"' "$last" "FB-SRC2: agent row carries verdict_source:agent"
vs=$(echo "$last" | jq -r '.verdict_source')
assert_eq "agent" "$vs" "FB-SRC2: verdict_source parses back as agent"
rm -rf "$tmp"

# FB-SRC3. --source human is refused with exit 2 naming ADR 0030; nothing is appended.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(grep -c '' "$tmp/m.jsonl")
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --source human miss "rewrote it" 2>&1) || EC=$?
assert_eq 2 "$EC" "FB-SRC3: --source human → exit 2"
assert_contains "ADR 0030" "$out" "FB-SRC3: the refusal points at ADR 0030"
assert_eq "$before" "$(grep -c '' "$tmp/m.jsonl")" "FB-SRC3: the refused verdict writes no row"
rm -rf "$tmp"

# FB-SRC4. --source=agent (equals form) is accepted the same as the space form.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --source=agent hit 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-SRC4: --source=agent → exits 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"verdict_source":"agent"' "$last" "FB-SRC4: equals form sets agent tier"
rm -rf "$tmp"

# FB-SRC5. An invalid --source value is rejected with exit 2.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --source robot hit 2>&1) || EC=$?
assert_eq 2 "$EC" "FB-SRC5: invalid --source → exit 2"
assert_contains "must be 'agent'" "$out" "FB-SRC5: error names the one allowed value"
rm -rf "$tmp"

# FB-SRC6. --source with no value (flags parse first, nothing follows) → exit 2.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --source 2>&1) || EC=$?
assert_eq 2 "$EC" "FB-SRC6: --source with no value → exit 2"
assert_contains "requires a value" "$out" "FB-SRC6: error explains --source needs a value"
rm -rf "$tmp"

# FB-SRC7. --source agent composes with --ts and a reason.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --ts "$TS_LATEST" --source agent miss "rewrote the bullets" 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-SRC7: --ts + --source agent + reason → exits 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"verdict_source":"agent"' "$last" "FB-SRC7: agent tier recorded with --ts"
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "FB-SRC7: --ts pin still honoured alongside --source"
assert_contains '"reason":"rewrote the bullets"' "$last" "FB-SRC7: reason captured alongside --source"
EC=0; echo "$last" | jq -e . >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "FB-SRC7: agent feedback row is valid JSON"
rm -rf "$tmp"

# FB-SRC8. OTel: --source agent emits delegate.feedback.source=agent on the span.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --source agent hit 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-SRC8: --source agent + OTel → exits 0"
otel_body=$(cat "$otel_sniff")
assert_contains '"delegate.feedback.source"' "$otel_body" "FB-SRC8: delegate.feedback.source attribute present"
src_attr=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].attributes[] | select(.key=="delegate.feedback.source") | .value.stringValue')
assert_eq "agent" "$src_attr" "FB-SRC8: source attribute value is agent"
rm -rf "$tmp"

# FB-SRC9. OTel: the default source is agent on the span too.
tmp=$(mktemp -d)
seed_metrics_with_otel "$tmp/m.jsonl"
invocations="$tmp/invocations"; : > "$invocations"
otel_sniff="$tmp/otel.json"
make_mock_curl_fb_otel "$tmp" "$otel_sniff" "$invocations" "ok"
EC=0
out=$(env -i PATH="$tmp:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" hit 2>&1) || EC=$?
assert_eq 0 "$EC" "FB-SRC9: default source + OTel → exits 0"
otel_body=$(cat "$otel_sniff")
src_attr=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].attributes[] | select(.key=="delegate.feedback.source") | .value.stringValue')
assert_eq "agent" "$src_attr" "FB-SRC9: default source attribute value is agent"
rm -rf "$tmp"

# FB-SRC10. scripts/lib/otel.sh defaults agree; only other emitters reach
# them, and the lib has no suite of its own.
assert_eq 0 "$(grep -c ':-human}' "$REPO/scripts/lib/otel.sh")" \
  "FB-SRC10: scripts/lib/otel.sh no longer defaults any verdict_source to human"
assert_eq 2 "$(grep -c 'verdict_source="\${\(9\|11\):-agent}"' "$REPO/scripts/lib/otel.sh")" \
  "FB-SRC10: both emit_otel_feedback_span entry points default verdict_source to agent"

# --- Scaffold verdict: the draft was discarded but useful. The row carries
# kept:false (so kept-only readers never inflate hit-rate) plus scaffold:true,
# and it is not a miss for the recurrence nudge ---

# SC1: scaffold with a reason writes one row with scaffold:true and kept:false.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" scaffold "draft compiled, kept the approach not the code" 2>&1) || EC=$?
assert_eq 0 "$EC" "scaffold: exit 0"
after=$(wc -l < "$tmp/m.jsonl" | tr -d ' ')
assert_one_row_added "$before" "$after" "scaffold: exactly one row appended"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"source":"feedback"' "$last" "scaffold: source field"
assert_contains '"scaffold":true' "$last" "scaffold: scaffold:true discriminator present"
assert_contains '"kept":false' "$last" "scaffold: kept:false for back-compat readers"
assert_contains "\"ref_ts\":\"$TS_LATEST\"" "$last" "scaffold: ref_ts is latest delegate"
assert_contains '"reason":"draft compiled, kept the approach not the code"' "$last" "scaffold: reason captured"
assert_contains "SCAFFOLD recorded" "$out" "scaffold: stdout reports SCAFFOLD"
EC=0; echo "$last" | jq -e . >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "scaffold: row is valid JSON"
rm -rf "$tmp"

# SC2: --source agent scaffold → row carries verdict_source:"agent" AND scaffold:true.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --source agent scaffold "executable feedback only" 2>&1) || EC=$?
assert_eq 0 "$EC" "scaffold --source agent: exit 0"
last=$(tail -1 "$tmp/m.jsonl")
assert_contains '"scaffold":true' "$last" "scaffold --source agent: scaffold:true present"
assert_contains '"verdict_source":"agent"' "$last" "scaffold --source agent: verdict_source agent"
assert_contains '"kept":false' "$last" "scaffold --source agent: kept:false"
rm -rf "$tmp"

# SC3: scaffold with no reason is refused like a miss.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(grep -c '' "$tmp/m.jsonl")
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" scaffold 2>&1) || EC=$?
assert_eq 2 "$EC" "scaffold no-reason: exit 2"
assert_contains "needs a reason" "$out" "scaffold no-reason: the refusal says what is missing"
assert_eq "$before" "$(grep -c '' "$tmp/m.jsonl")" "scaffold no-reason: no row written"
rm -rf "$tmp"

# SC4: a scaffold never fires the recurrence nudge, even with five similar priors.
tmp=$(mktemp -d); seed_history "$tmp/m.jsonl" 5
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" scaffold "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "scaffold with similar MISSes: exit 0"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  scaffold with similar MISSes: nudge silent (scaffold is not a miss)"; pass=$((pass+1))
else echo "  FAIL  scaffold with similar MISSes: nudge fired (scaffold must not nudge)"; fail=$((fail+1)); fi
rm -rf "$tmp"

# SC5: historical scaffold rows (kept:false, scaffold:true) are not similar
# misses for a later real miss's nudge.
tmp=$(mktemp -d)
: > "$tmp/m.jsonl"
for i in 1 2 3 4; do
  hist_ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-1800+'"$i"'*60))')
  echo "{\"ts\":\"$hist_ts\",\"source\":\"feedback\",\"ref_ts\":\"$hist_ts\",\"kept\":false,\"scaffold\":true,\"reason\":\"pr-description recipe stalled past 30s on prose tier body ($i)\"}" >> "$tmp/m.jsonl"
done
fresh_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"ts\":\"$fresh_ts\",\"source\":\"delegate\",\"tier\":\"prose\",\"model\":\"q\",\"duration_ms\":1000,\"exit_status\":0,\"estimated_tokens_avoided\":40}" >> "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" miss "pr-description recipe stalled past 30s on prose tier body" 2>&1) || EC=$?
assert_eq 0 "$EC" "historical-scaffold-not-miss: exit 0"
if [[ "$out" != *"NOTE: this MISS plus"* ]]; then echo "  PASS  historical scaffold rows not counted as similar misses (matcher skips scaffold)"; pass=$((pass+1))
else echo "  FAIL  historical scaffold rows counted as similar misses (matcher must skip scaffold)"; fail=$((fail+1)); fi
rm -rf "$tmp"

# SC6: a near-miss verdict word is still rejected.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" scaffolding 2>&1) || EC=$?
assert_eq 2 "$EC" "near-miss verdict 'scaffolding' -> exit 2 (not silently accepted)"
rm -rf "$tmp"

# --- FN: --final stores the text that shipped beside the captured draft ---
# FN1: a file path is copied in and named on the row.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
printf 'the reply that actually shipped\n' > "$tmp/final.txt"
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --final "$tmp/final.txt" miss "dropped every anchor" 2>&1)
row=$(tail -1 "$tmp/m.jsonl")
final_name=$(printf '%s' "$row" | jq -r '.final_file // ""')
stem=$(printf '%s' "$TS_LATEST" | tr -d ':-')
assert_eq "$stem-nodraft.final.txt" "$final_name" \
  "--final: falls back to a ts stem when the row has no draft_file"
assert_eq "the reply that actually shipped" "$(cat "$tmp/drafts/$final_name" 2>/dev/null)" \
  "--final: shipped text stored verbatim beside the draft"
rm -rf "$tmp"

# FN1b: the final is named after the row's draft_file, not ref_ts, since
# parallel delegations share a second. The appended row shares the seed's
# second, so the verdict is pinned by id.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
mkdir -p "$tmp/drafts"
printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0,"otel_span_id":"dddddddddddddddd","draft_file":"20260826T101206Z-a1b2c3d4.draft.txt"}\n' \
  "$TS_LATEST" >> "$tmp/m.jsonl"
printf 'shipped\n' > "$tmp/f.txt"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --final "$tmp/f.txt" miss "r" >/dev/null 2>&1
assert_eq "20260826T101206Z-a1b2c3d4.final.txt" \
  "$(tail -1 "$tmp/m.jsonl" | jq -r '.final_file // ""')" \
  "--final: named after the row's draft_file, not after ref_ts"
rm -rf "$tmp"

# FN1c: neither the directory nor the file may inherit a permissive umask.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
printf 'shipped\n' > "$tmp/f.txt"
( umask 000
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
    bash "$SCRIPT" --final "$tmp/f.txt" miss "r" >/dev/null 2>&1 )
final_name=$(tail -1 "$tmp/m.jsonl" | jq -r '.final_file // ""')
assert_eq "700" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$tmp/drafts")" \
  "--final: drafts directory is private (700) under a permissive umask"
assert_eq "600" "$(perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$tmp/drafts/$final_name")" \
  "--final: shipped-text file is private (600) under a permissive umask"
rm -rf "$tmp"

# FN2: - reads the shipped text from stdin.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
echo "shipped via stdin" | DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --final - miss "reason" >/dev/null 2>&1
final_name=$(tail -1 "$tmp/m.jsonl" | jq -r '.final_file // ""')
assert_eq "shipped via stdin" "$(cat "$tmp/drafts/$final_name" 2>/dev/null)" \
  "--final -: shipped text read from stdin"
rm -rf "$tmp"

# FN3: a nonexistent path fails before the verdict row is written.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
before=$(grep -c '' "$tmp/m.jsonl")
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --final "$tmp/nope.txt" miss "r" 2>&1) || EC=$?
assert_eq 2 "$EC" "--final: missing file exits 2"
assert_contains "--final file not found" "$out" "--final: missing file names the path"
assert_eq "$before" "$(grep -c '' "$tmp/m.jsonl")" "--final: missing file writes no verdict row"
rm -rf "$tmp"

# FN4: --final requires a value.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" --final 2>&1) || EC=$?
assert_eq 2 "$EC" "--final with no value exits 2"
rm -rf "$tmp"

# FN5: omitting --final leaves the row shape as it was.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" miss "r" >/dev/null 2>&1
assert_eq "false" "$(tail -1 "$tmp/m.jsonl" | jq -r 'has("final_file")')" \
  "--final omitted: no final_file field on the row"
rm -rf "$tmp"

# --- A rejection needs a reason: with one tier (ADR 0030) every verdict is
# the agent's own just-finished delegation ---
tmp=$(mktemp -d); metrics="$tmp/m.jsonl"
seed_row() { printf '{"ts":"%s","source":"delegate","recipe":"x","tier":"prose","exit_status":0}\n' "$1" > "$metrics"; }
fb() { DELEGATE_METRICS_FILE="$metrics" bash "$SCRIPT" --ts 2026-08-26T23:00:00Z "$@" 2>&1; }
fbrc() { DELEGATE_METRICS_FILE="$metrics" bash "$SCRIPT" --ts 2026-08-26T23:00:00Z "$@" >/dev/null 2>&1; echo $?; }

seed_row 2026-08-26T23:00:00Z
assert_eq 2 "$(fbrc --source agent miss)" "reason-required: an agent miss with no reason exits 2"
assert_contains "needs a reason" "$(fb --source agent miss)" \
  "reason-required: the refusal says what is missing"
assert_eq 1 "$(grep -c . "$metrics")" "reason-required: the refused row is not written"

seed_row 2026-08-26T23:00:00Z
assert_eq 2 "$(fbrc --source agent scaffold)" "reason-required: an agent scaffold with no reason exits 2"
# Whitespace is not a reason.
seed_row 2026-08-26T23:00:00Z
assert_eq 2 "$(fbrc --source agent miss '   ')" "reason-required: whitespace is not a reason"

# The three paths that must keep working.
seed_row 2026-08-26T23:00:00Z
assert_eq 0 "$(fbrc --source agent miss 'dropped every file:line anchor')" \
  "reason-required: an agent miss with a reason still records"
seed_row 2026-08-26T23:00:00Z
assert_eq 0 "$(fbrc --source agent hit)" \
  "reason-required: an agent hit needs no reason"
# No --source is the agent default, not an exemption.
seed_row 2026-08-26T23:00:00Z
assert_eq 2 "$(fbrc miss)" \
  "reason-required: a reasonless miss with no --source is refused too"
assert_eq 1 "$(grep -c . "$metrics")" "reason-required: the refused sourceless row is not written"
rm -rf "$tmp"

# --- Flags are honoured wherever they appear, not only before the verdict ---
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
mkdir -p "$tmp/drafts"
printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0,"otel_span_id":"dddddddddddddddd","draft_file":"20260827T090000Z-abcd1234.draft.txt"}\n' \
  "$TS_LATEST" >> "$tmp/m.jsonl"
printf 'the reply that actually shipped\n' > "$tmp/shipped.txt"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd scaffold "body ran long" --final "$tmp/shipped.txt" >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "20260827T090000Z-abcd1234.final.txt" "$(printf '%s' "$last" | jq -r '.final_file // ""')" \
  "trailing --final: the shipped text is stored"
assert_eq "body ran long" "$(printf '%s' "$last" | jq -r '.reason // ""')" \
  "trailing --final: the flag is consumed, not left in the reason"
assert_eq "the reply that actually shipped" "$(cat "$tmp/drafts/20260827T090000Z-abcd1234.final.txt" 2>/dev/null)" \
  "trailing --final: the stored text is the shipped text"
rm -rf "$tmp"

# The same for the other two flags.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" miss "dropped every anchor" --source agent >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "agent" "$(printf '%s' "$last" | jq -r '.verdict_source // ""')" \
  "trailing --source: the verdict tier is honoured"
assert_eq "dropped every anchor" "$(printf '%s' "$last" | jq -r '.reason // ""')" \
  "trailing --source: the flag is consumed, not left in the reason"
rm -rf "$tmp"

tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" miss "wrong subject" --ts "$TS_OLDEST" >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "$TS_OLDEST" "$(printf '%s' "$last" | jq -r '.ref_ts // ""')" \
  "trailing --ts: the verdict is pinned to the named row"
assert_eq "wrong subject" "$(printf '%s' "$last" | jq -r '.reason // ""')" \
  "trailing --ts: the flag is consumed, not left in the reason"
rm -rf "$tmp"

# `--` ends flag parsing so a reason can quote a flag.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" -- miss "the nudge should name --final here" >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "the nudge should name --final here" "$(printf '%s' "$last" | jq -r '.reason // ""')" \
  "-- ends flag parsing: a reason may quote a flag verbatim"
assert_eq "false" "$(printf '%s' "$last" | jq -r 'has("final_file")')" \
  "-- ends flag parsing: the quoted flag stored nothing"
rm -rf "$tmp"

# An unknown double-dash token is reason text, not an error.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" miss "shape was --bulleted not prose" >/dev/null 2>&1
assert_eq "shape was --bulleted not prose" "$(tail -1 "$tmp/m.jsonl" | jq -r '.reason // ""')" \
  "unknown --token stays in the reason"
rm -rf "$tmp"

# Only the first positional is the verdict; later verdict words are reason text.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" scaffold "closer to a hit than a miss" >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "true" "$(printf '%s' "$last" | jq -r '.scaffold // false')" \
  "first positional is the verdict: later verdict words are reason text"
assert_eq "closer to a hit than a miss" "$(printf '%s' "$last" | jq -r '.reason // ""')" \
  "first positional is the verdict: the reason keeps them"
rm -rf "$tmp"


# --- Adopting a final the boundary hook captured under the draft's stem;
# `final_source` keeps an inferred pair distinguishable from a vouched one.
# The appended row shares the seed's second, so every call pins with --id ---
adopt_setup() { # -> tmp with a delegate row naming a draft, and drafts/
  tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
  mkdir -p "$tmp/drafts"
  printf '{"ts":"%s","source":"delegate","tier":"prose","recipe":"maintainer-reply","exit_status":0,"otel_span_id":"dddddddddddddddd","draft_file":"20260827T100000Z-aaaa1111.draft.txt"}\n' \
    "$TS_LATEST" >> "$tmp/m.jsonl"
}

adopt_setup
printf 'what the hook saw go out' > "$tmp/drafts/20260827T100000Z-aaaa1111.final.txt"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --source agent scaffold "trimmed the second paragraph" >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "20260827T100000Z-aaaa1111.final.txt" "$(printf '%s' "$last" | jq -r '.final_file // ""')" \
  "adopt: a hook-captured final is adopted when --final was not passed"
assert_eq "posted" "$(printf '%s' "$last" | jq -r '.final_source // ""')" \
  "adopt: the row records that the pair was inferred from a post"
rm -rf "$tmp"

# An explicit --final is not relabelled as inferred and never overwrites an
# existing final (#474): the caller's text lands in a numbered sibling.
adopt_setup
printf 'what the hook saw go out' > "$tmp/drafts/20260827T100000Z-aaaa1111.final.txt"
printf 'what the caller says shipped' > "$tmp/mine.txt"
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --source agent scaffold "r" --final "$tmp/mine.txt" 2>&1)
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "20260827T100000Z-aaaa1111.final.2.txt" "$(printf '%s' "$last" | jq -r '.final_file // ""')" \
  "adopt: an explicit --final beside a hook capture is stored as a numbered sibling"
assert_eq "what the caller says shipped" "$(cat "$tmp/drafts/20260827T100000Z-aaaa1111.final.2.txt" 2>/dev/null)" \
  "adopt: the sibling holds the caller's text"
assert_eq "what the hook saw go out" "$(cat "$tmp/drafts/20260827T100000Z-aaaa1111.final.txt")" \
  "adopt: the hook's capture is left untouched"
assert_eq "false" "$(printf '%s' "$last" | jq -r 'has("final_source")')" \
  "adopt: an explicit --final is not labelled as inferred"
assert_contains "20260827T100000Z-aaaa1111.final.txt already exists" "$out" \
  "adopt: the caller is told the stem already had a final"
rm -rf "$tmp"

# Each further final on the same stem takes the next free number, and every
# row names the file it wrote.
adopt_setup
printf 'first shipped' > "$tmp/one.txt"
printf 'second shipped' > "$tmp/two.txt"
printf 'third shipped' > "$tmp/three.txt"
for f in one two three; do
  DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
    bash "$SCRIPT" --id dddddddddddddddd --source agent miss "r $f" --final "$tmp/$f.txt" >/dev/null 2>&1
done
assert_eq "first shipped" "$(cat "$tmp/drafts/20260827T100000Z-aaaa1111.final.txt" 2>/dev/null)" \
  "numbered final: the first final keeps the bare name and its text"
assert_eq "second shipped" "$(cat "$tmp/drafts/20260827T100000Z-aaaa1111.final.2.txt" 2>/dev/null)" \
  "numbered final: the second final is .final.2.txt"
assert_eq "third shipped" "$(cat "$tmp/drafts/20260827T100000Z-aaaa1111.final.3.txt" 2>/dev/null)" \
  "numbered final: the third final is .final.3.txt"
assert_eq "20260827T100000Z-aaaa1111.final.txt 20260827T100000Z-aaaa1111.final.2.txt 20260827T100000Z-aaaa1111.final.3.txt" \
  "$(jq -r 'select(.source=="feedback") | .final_file' "$tmp/m.jsonl" | tr '\n' ' ' | sed 's/ $//')" \
  "numbered final: each row names the file it wrote"
rm -rf "$tmp"

# The name is claimed by an exclusive create, not a stat: parallel writers
# on one stem each get their own file and every row names its own.
adopt_setup
writers=8
for i in $(seq 1 $writers); do
  printf 'writer %s shipped' "$i" > "$tmp/w$i.txt"
done
for i in $(seq 1 $writers); do
  ( DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
      bash "$SCRIPT" --id dddddddddddddddd --source agent miss "w $i" --final "$tmp/w$i.txt" >/dev/null 2>&1 ) &
done
wait
assert_eq "$writers" "$(ls "$tmp/drafts" | grep -c 'aaaa1111\.final')" \
  "parallel finals: as many files as writers"
assert_eq "$writers" "$(jq -r 'select(.source=="feedback") | .final_file' "$tmp/m.jsonl" | sort -u | grep -c '')" \
  "parallel finals: every row names a distinct final_file"
assert_eq "$writers" "$(jq -r 'select(.source=="feedback") | .final_file' "$tmp/m.jsonl" | grep -c '')" \
  "parallel finals: every writer recorded a final_file"
# Reason "w N" pairs with content "writer N".
mismatch=0
while IFS=$'\037' read -r r f; do
  n="${r#w }"
  [[ "$(cat "$tmp/drafts/$f")" == "writer $n shipped" ]] || mismatch=$((mismatch+1))
done < <(jq -r 'select(.source=="feedback") | [.reason, .final_file] | join("\u001f")' "$tmp/m.jsonl")
assert_eq 0 "$mismatch" "parallel finals: every row's file holds that writer's own text"
rm -rf "$tmp"

# A claim that succeeds but a copy that fails is not a collision: the claim
# is released, the loop stops, and the verdict lands without a final_file.
adopt_setup
printf "unreadable after the check" > "$tmp/locked.txt"
chmod 000 "$tmp/locked.txt"
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  perl -e "alarm 10; exec @ARGV" bash "$SCRIPT" --id dddddddddddddddd --source agent miss "copy fails" --final "$tmp/locked.txt" 2>&1)
assert_eq 0 "$(ls "$tmp/drafts" | grep -c "aaaa1111\.final")" \
  "failed copy: no final file is left behind, numbered or bare"
assert_contains "could not store --final" "$out" \
  "failed copy: the caller is told the final was not stored"
assert_eq 1 "$(jq -c "select(.source==\"feedback\")" "$tmp/m.jsonl" | grep -c "")" \
  "failed copy: the verdict row is still written"
assert_eq "null" "$(jq -r "select(.source==\"feedback\") | .final_file" "$tmp/m.jsonl")" \
  "failed copy: the row carries no final_file"
chmod 600 "$tmp/locked.txt"
rm -rf "$tmp"

# A final an earlier verdict supplied by hand is carried by a later verdict
# without the posted label.
adopt_setup
printf 'what the caller shipped' > "$tmp/mine.txt"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --source agent miss "first verdict" --final "$tmp/mine.txt" >/dev/null 2>&1
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --source agent scaffold "second verdict, same row" >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "20260827T100000Z-aaaa1111.final.txt" "$(printf '%s' "$last" | jq -r '.final_file // ""')" \
  "adopt after --final: the later verdict carries the hand-supplied final's name"
assert_eq "false" "$(printf '%s' "$last" | jq -r 'has("final_source")')" \
  "adopt after --final: a hand-supplied final is not relabelled as posted"
rm -rf "$tmp"

# A hit shipped as-is, so there is nothing to adopt.
adopt_setup
printf 'what the hook saw go out' > "$tmp/drafts/20260827T100000Z-aaaa1111.final.txt"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --source agent hit >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "feedback" "$(printf '%s' "$last" | jq -r '.source')" \
  "adopt: the hit verdict was recorded"
assert_eq "false" "$(printf '%s' "$last" | jq -r 'has("final_file")')" \
  "adopt: a hit does not adopt a captured final"
rm -rf "$tmp"

# No capture, no field.
adopt_setup
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --source agent scaffold "r" >/dev/null 2>&1
last=$(tail -1 "$tmp/m.jsonl")
assert_eq "feedback" "$(printf '%s' "$last" | jq -r '.source')" \
  "adopt: the scaffold verdict was recorded"
assert_eq "false" "$(printf '%s' "$last" | jq -r 'has("final_file")')" \
  "adopt: nothing captured means no final_file"
assert_eq "false" "$(printf '%s' "$last" | jq -r 'has("final_source")')" \
  "adopt: nothing captured means no final_source"
rm -rf "$tmp"

# draft_file is untrusted input that becomes part of a written path; a
# rejected value falls through to the ts-derived stem.
tmp=$(mktemp -d); seed_metrics "$tmp/m.jsonl"
printf '{"ts":"%s","source":"delegate","tier":"prose","exit_status":0,"otel_span_id":"dddddddddddddddd","draft_file":"../escaped.draft.txt"}\n' \
  "$TS_LATEST" >> "$tmp/m.jsonl"
printf 'shipped\n' > "$tmp/f.txt"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id dddddddddddddddd --final "$tmp/f.txt" miss "r" >/dev/null 2>&1
assert_eq "false" "$([[ -e "$tmp/escaped.final.txt" ]] && echo true || echo false)" \
  "traversing draft_file: nothing is written outside the drafts directory"
assert_eq "$(printf '%s' "$TS_LATEST" | tr -d ':-')-nodraft.final.txt" \
  "$(tail -1 "$tmp/m.jsonl" | jq -r '.final_file // ""')" \
  "traversing draft_file: falls through to the ts-derived stem"
rm -rf "$tmp"

# --- Repeated-reason warning (#487): a reason byte-identical to one on
# another feedback row inside DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS
# (default 600) is warned about; the row is still written ---

# seed_repeats <file> <N> <reason> <age_seconds>: N feedback rows a second
# apart, then the fresh delegate row the new verdict attaches to.
seed_repeats() {
  local file="$1" n="$2" reason="$3" age="$4"
  : > "$file"
  local i rep_ts
  for (( i=1; i<=n; i++ )); do
    rep_ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-'"$age"'+'"$i"'))')
    printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false,"reason":"%s","verdict_source":"agent"}\n' \
      "$rep_ts" "$rep_ts" "$reason" >> "$file"
  done
  TS_LATEST=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0,"otel_span_id":"%s"}\n' \
    "$TS_LATEST" "$ID_LATEST" >> "$file"
}
REPEAT_REASON="restated the fact sheet verbatim as one paragraph with the verdict string as a heading"

# Two identical rows inside the window: warned with the count, row still written.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 2 "$REPEAT_REASON" 120
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1) || EC=$?
assert_eq 0 "$EC" "repeat reason: a warned miss still exits 0"
assert_contains "this reason was already recorded 2 time(s) in the last 10 min" "$out" \
  "repeat reason: the warning names the count and the window"
assert_contains "record what THIS draft did" "$out" \
  "repeat reason: the warning says what to record instead"
assert_eq 3 "$(jq -c 'select(.source=="feedback")' "$tmp/m.jsonl" | grep -c '')" \
  "repeat reason: the row is written anyway"
assert_eq "$REPEAT_REASON" "$(tail -1 "$tmp/m.jsonl" | jq -r '.reason')" \
  "repeat reason: the row carries the reason as given"
rm -rf "$tmp"

# A scaffold is a rejection too, and a sweep pastes those the same way.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 1 "$REPEAT_REASON" 60
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" scaffold "$REPEAT_REASON" 2>&1)
assert_contains "this reason was already recorded 1 time(s)" "$out" \
  "repeat reason: a scaffold with a pasted reason warns too"
rm -rf "$tmp"

# The same reason outside the window is a coincidence, not a sweep.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 2 "$REPEAT_REASON" 900
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1) || EC=$?
assert_eq 0 "$EC" "repeat reason outside window: exit 0"
if [[ "$out" != *"already recorded"* ]]; then echo "  PASS  repeat reason outside window: no warning"; pass=$((pass+1))
else echo "  FAIL  repeat reason outside window: warned ($out)"; fail=$((fail+1)); fi
assert_eq 3 "$(jq -c 'select(.source=="feedback")' "$tmp/m.jsonl" | grep -c '')" \
  "repeat reason outside window: the row is written"
# Widening the window brings the seeded rows back in; the miss just recorded
# references this same delegation and does not count.
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS=1200 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1)
assert_contains "this reason was already recorded 2 time(s) in the last 20 min" "$out" \
  "repeat reason: DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS widens the window"
rm -rf "$tmp"

# A different reason inside the window is what the loop wants; no warning.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 2 "$REPEAT_REASON" 120
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "turned the key count 258 into a question to the contributor" 2>&1)
if [[ "$out" != *"already recorded"* ]]; then echo "  PASS  repeat reason: a different reason does not warn"; pass=$((pass+1))
else echo "  FAIL  repeat reason: a different reason warned ($out)"; fail=$((fail+1)); fi
rm -rf "$tmp"

# A hit never warns, whatever reason words it carries.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 2 "$REPEAT_REASON" 120
EC=0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" hit "$REPEAT_REASON" 2>&1) || EC=$?
assert_eq 0 "$EC" "repeat reason on a hit: exit 0"
if [[ "$out" != *"already recorded"* ]]; then echo "  PASS  repeat reason on a hit: no warning"; pass=$((pass+1))
else echo "  FAIL  repeat reason on a hit: warned ($out)"; fail=$((fail+1)); fi
assert_eq 3 "$(jq -c 'select(.source=="feedback")' "$tmp/m.jsonl" | grep -c '')" \
  "repeat reason on a hit: the row is written"
rm -rf "$tmp"

# A second verdict on the same delegation is a revision, not a sweep: rows
# referencing this row (by ref_id, or ref_ts on a row without ids) never count.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 0 "$REPEAT_REASON" 120
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" >/dev/null 2>&1
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1)
if [[ "$out" != *"already recorded"* ]]; then echo "  PASS  repeat reason: a revision on the same delegation does not warn"; pass=$((pass+1))
else echo "  FAIL  repeat reason: a revision on the same delegation warned ($out)"; fail=$((fail+1)); fi
# A same-second sibling is a different delegation: with ids on both rows the
# exclusion compares ids, so the same reason on the sibling warns.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 0 "$REPEAT_REASON" 120
printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0,"otel_span_id":"0000000000000009"}\n' \
  "$TS_LATEST" >> "$tmp/m.jsonl"
DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" >/dev/null 2>&1
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id 0000000000000009 miss "$REPEAT_REASON" 2>&1)
assert_contains "already recorded 1 time(s)" "$out" \
  "repeat reason: a same-second sibling with its own id still warns"
rm -rf "$tmp"
# Same again with a prior row carrying only ref_ts (no ref_id).
tmp2=$(mktemp -d); seed_repeats "$tmp2/m.jsonl" 0 "$REPEAT_REASON" 120
printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false,"reason":"%s","verdict_source":"agent"}\n' \
  "$TS_LATEST" "$TS_LATEST" "$REPEAT_REASON" >> "$tmp2/m.jsonl"
out=$(DELEGATE_METRICS_FILE="$tmp2/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1)
if [[ "$out" != *"already recorded"* ]]; then echo "  PASS  repeat reason: a same-ref_ts row without ref_id does not count either"; pass=$((pass+1))
else echo "  FAIL  repeat reason: a same-ref_ts row without ref_id counted ($out)"; fail=$((fail+1)); fi
rm -rf "$tmp" "$tmp2"

# Only kept:false rows count; a prior hit with the same words does not.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 0 "$REPEAT_REASON" 120
for age in 100 80; do
  hit_ts=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time-'"$age"'))')
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","ref_id":"ffff000000000001","kept":true,"reason":"%s","verdict_source":"agent"}\n' \
    "$hit_ts" "$hit_ts" "$REPEAT_REASON" >> "$tmp/m.jsonl"
done
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1)
if [[ "$out" != *"already recorded"* ]]; then echo "  PASS  repeat reason: prior hits with the same reason do not count"; pass=$((pass+1))
else echo "  FAIL  repeat reason: prior hits with the same reason counted ($out)"; fail=$((fail+1)); fi
rm -rf "$tmp"

# REPEAT_WINDOW_SECONDS=0 is the off switch (unlike STALE_SECONDS, where 0 is
# unbounded); the seed rows are in the current second so a zero-width window
# would still include them.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 2 "$REPEAT_REASON" 0
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS=0 \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1)
if [[ "$out" != *"already recorded"* ]]; then echo "  PASS  repeat reason: REPEAT_WINDOW_SECONDS=0 disables the warning"; pass=$((pass+1))
else echo "  FAIL  repeat reason: REPEAT_WINDOW_SECONDS=0 still warned ($out)"; fail=$((fail+1)); fi
assert_eq 3 "$(jq -c 'select(.source=="feedback")' "$tmp/m.jsonl" | grep -c '')" \
  "repeat reason: REPEAT_WINDOW_SECONDS=0 still writes the row"
rm -rf "$tmp"

# A non-numeric value falls back to the default and says so.
tmp=$(mktemp -d); seed_repeats "$tmp/m.jsonl" 2 "$REPEAT_REASON" 120
out=$(DELEGATE_METRICS_FILE="$tmp/m.jsonl" DELEGATE_FEEDBACK_NO_NUDGE=1 DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS=10m \
  bash "$SCRIPT" --id "$ID_LATEST" miss "$REPEAT_REASON" 2>&1)
assert_contains "DELEGATE_FEEDBACK_REPEAT_WINDOW_SECONDS='10m' is not a number of seconds; using 600" "$out" \
  "repeat reason: a non-numeric window falls back to 600 and says so"
assert_contains "this reason was already recorded 2 time(s) in the last 10 min" "$out" \
  "repeat reason: the fallback window still warns"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
