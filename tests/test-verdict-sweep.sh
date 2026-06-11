#!/usr/bin/env bash
# Unit tests for scripts/verdict-sweep.sh. Drives the interactive loop through
# the DELEGATE_SWEEP_ASSUME_TTY=1 test seam (a real pty can't run in CI) against
# fresh fixtures, pinning the window/exit_status/already-tracked filters, the
# opt-out, the non-tty no-op, and that recorded answers are written through the
# real delegate-feedback.sh --ts path.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/verdict-sweep.sh"

pass=0
fail=0
assert_eq() { if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1)); else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi; }
assert_contains() { case "$2" in *"$1"*) echo "  PASS  $3"; pass=$((pass+1));; *) echo "  FAIL  $3 (missing '$1')"; fail=$((fail+1));; esac; }
assert_absent() { case "$2" in *"$1"*) echo "  FAIL  $3 (unexpected '$1')"; fail=$((fail+1));; *) echo "  PASS  $3"; pass=$((pass+1));; esac; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
iso_ago() { perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]))' "$1"; }

R1=$(iso_ago 3600)    # recent, untracked
R2=$(iso_ago 7200)    # recent, untracked
R3=$(iso_ago 10800)   # recent, untracked
R4=$(iso_ago 14400)   # recent, already has a verdict -> excluded
OLD=$(iso_ago 108000) # 30h ago -> outside the 24h window
FAIL=$(iso_ago 5400)  # recent but exit_status:3 (no output) -> excluded

seed() {
  cat > "$1" <<EOF
{"ts":"$R1","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0}
{"ts":"$R2","source":"delegate","recipe":"summarise-issue","tier":"reasoning","model":"r","exit_status":0}
{"ts":"$R3","source":"delegate","recipe":"file-summary","tier":"prose","model":"q","exit_status":0}
{"ts":"$R4","source":"delegate","recipe":"doc-section","tier":"prose","model":"q","exit_status":0}
{"ts":"$OLD","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0}
{"ts":"$FAIL","source":"delegate","recipe":"pr-description","tier":"prose","model":"q","exit_status":3}
{"ts":"$(iso_ago 14395)","source":"feedback","ref_ts":"$R4","kept":true}
EOF
}

fb_rows() { jq -r 'select((.source//"")=="feedback") | "\(.kept) \(.ref_ts)"' "$1"; }

# --- T1: opt-out short-circuits, file untouched ------------------------------
met="$tmp/t1.jsonl"; seed "$met"
before=$(grep -c '' "$met")
out=$(printf 'h\nh\nh\n' | DELEGATE_LOCAL_NO_SWEEP=1 DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$met" 2>&1); ec=$?
assert_eq "0" "$ec" "T1: opt-out exits 0"
assert_eq "" "$out" "T1: opt-out prints nothing"
assert_eq "$before" "$(grep -c '' "$met")" "T1: opt-out wrote no feedback rows"

# --- T2: missing metrics file is a no-op, not an error -----------------------
out=$(printf '' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$tmp/nope.jsonl" 2>&1); ec=$?
assert_eq "0" "$ec" "T2: missing file exits 0"
assert_contains "nothing to sweep" "$out" "T2: missing file explained"

# --- T3: identifies exactly the untracked, in-window, successful rows --------
met="$tmp/t3.jsonl"; seed "$met"
out=$(printf 's\ns\ns\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$met" 2>&1); ec=$?
assert_eq "0" "$ec" "T3: skip-all exits 0"
assert_contains "3 untracked" "$out" "T3: counts 3 untracked"
assert_contains "$R1" "$out" "T3: lists recent untracked R1"
assert_contains "$R2" "$out" "T3: lists recent untracked R2"
assert_contains "$R3" "$out" "T3: lists recent untracked R3"
assert_absent "$R4" "$out" "T3: excludes already-verdicted R4"
assert_absent "$OLD" "$out" "T3: excludes out-of-window OLD"
assert_absent "$FAIL" "$out" "T3: excludes failed (exit_status:3) row"
assert_contains "recorded 0 verdict(s), skipped 3" "$out" "T3: tally reflects 3 skips"

# --- T4: records hit/miss/skip through delegate-feedback.sh --ts -------------
met="$tmp/t4.jsonl"; seed "$met"
out=$(printf 'h\nm\ns\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$met" 2>&1); ec=$?
assert_eq "0" "$ec" "T4: hit/miss/skip exits 0"
assert_contains "recorded 2 verdict(s), skipped 1" "$out" "T4: tally reflects 2 recorded, 1 skipped"
fbs=$(fb_rows "$met")
assert_contains "true $R1" "$fbs" "T4: R1 recorded as a HIT via delegate-feedback"
assert_contains "false $R2" "$fbs" "T4: R2 recorded as a MISS via delegate-feedback"
r3fb=$(jq -r --arg t "$R3" 'select((.source//"")=="feedback" and .ref_ts==$t) | .ref_ts' "$met")
assert_eq "" "$r3fb" "T4: skipped R3 got no feedback row"
# Two new feedback rows total (the seed's pre-existing R4 verdict plus the two recorded).
assert_eq "3" "$(jq -rs '[.[]|select((.source//"")=="feedback")]|length' "$met")" "T4: exactly two feedback rows appended"

# --- T5: quit records nothing -----------------------------------------------
met="$tmp/t5.jsonl"; seed "$met"
before=$(jq -rs '[.[]|select((.source//"")=="feedback")]|length' "$met")
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$met" 2>&1); ec=$?
assert_eq "0" "$ec" "T5: quit exits 0"
assert_contains "recorded 0 verdict(s)" "$out" "T5: quit records nothing"
assert_eq "$before" "$(jq -rs '[.[]|select((.source//"")=="feedback")]|length' "$met")" "T5: quit appended no feedback rows"

# --- T6: all recent rows tracked -> no untracked, clean exit -----------------
met="$tmp/t6.jsonl"
{
  echo "{\"ts\":\"$R1\",\"source\":\"delegate\",\"recipe\":\"commit-message\",\"tier\":\"prose\",\"exit_status\":0}"
  echo "{\"ts\":\"$(iso_ago 3595)\",\"source\":\"feedback\",\"ref_ts\":\"$R1\",\"kept\":true}"
} > "$met"
before=$(grep -c '' "$met")
out=$(printf 'h\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$met" 2>&1); ec=$?
assert_eq "0" "$ec" "T6: all-tracked exits 0"
assert_contains "no untracked delegations" "$out" "T6: reports nothing to do"
assert_eq "$before" "$(grep -c '' "$met")" "T6: all-tracked wrote nothing"

# --- T7: non-interactive (no tty, no assume-tty) -> report and no-op ---------
met="$tmp/t7.jsonl"; seed "$met"
before=$(jq -rs '[.[]|select((.source//"")=="feedback")]|length' "$met")
out=$(bash "$SCRIPT" --file "$met" </dev/null 2>&1); ec=$?
assert_eq "0" "$ec" "T7: non-interactive exits 0"
assert_contains "run this in an interactive shell" "$out" "T7: points at interactive use"
assert_eq "$before" "$(jq -rs '[.[]|select((.source//"")=="feedback")]|length' "$met")" "T7: non-interactive recorded nothing"

# --- T8: usage error on an unknown flag -------------------------------------
out=$(bash "$SCRIPT" --bogus 2>&1); ec=$?
assert_eq "2" "$ec" "T8: unknown flag -> exit 2"
assert_contains "unknown arg" "$out" "T8: names the bad flag"

# --- T9: a non-numeric window env var is rejected at the boundary ------------
met="$tmp/t9.jsonl"; seed "$met"
out=$(DELEGATE_SWEEP_WINDOW_HOURS=abc bash "$SCRIPT" --file "$met" </dev/null 2>&1); ec=$?
assert_eq "2" "$ec" "T9: non-numeric window -> exit 2"
assert_contains "non-negative integer" "$out" "T9: explains the bad window value"

# --- T10: a malformed feedback row (no ref_ts) doesn't crash the jq join -----
met="$tmp/t10.jsonl"
{
  echo "{\"ts\":\"$R1\",\"source\":\"delegate\",\"recipe\":\"commit-message\",\"tier\":\"prose\",\"exit_status\":0}"
  echo "{\"ts\":\"$(iso_ago 3590)\",\"source\":\"feedback\",\"kept\":true}"
} > "$met"
out=$(printf 's\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$met" 2>&1); ec=$?
assert_eq "0" "$ec" "T10: malformed feedback row (no ref_ts) does not crash"
assert_contains "$R1" "$out" "T10: the untracked delegate row is still listed"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
