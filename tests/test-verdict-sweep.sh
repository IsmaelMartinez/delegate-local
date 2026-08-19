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

# --- T11: --calibrate (the second-look sample) ------------------------------
# The default work set is "no feedback row of any tier", so an agent verdict
# marks a row done and a human can never revisit it. That is right for coverage
# and wrong for calibration: the bias ADR 0015 predicts ("I used it, so it was
# good") is only visible on rows the agent claimed as hits.
NOW=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 3600))')
OLDER=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 7200))')
OLDEST=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 10800))')
FB=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 60))')
cal="$tmp/cal.jsonl"
LONG="ninety-plus characters of agent reasoning that runs well past the hundred character truncation boundary and keeps going"
{
  # eligible: agent HIT, no human verdict
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"m","exit_status":0}\n' "$NOW"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent","reason":"%s"}\n' "$FB" "$NOW" "$LONG"
  # NOT eligible: agent MISS (no self-flattery left to catch)
  printf '{"ts":"%s","source":"delegate","recipe":"pr-description","tier":"prose","model":"m","exit_status":0}\n' "$OLDER"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false,"verdict_source":"agent"}\n' "$FB" "$OLDER"
  # NOT eligible: agent SCAFFOLD (the prompt has no key for that outcome)
  printf '{"ts":"%s","source":"delegate","recipe":"doc-section","tier":"prose","model":"m","exit_status":0}\n' "$OLDEST"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false,"scaffold":true,"verdict_source":"agent"}\n' "$FB" "$OLDEST"
} > "$cal"

out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --file "$cal" 2>&1)
assert_contains "$NOW" "$out" "T11: --calibrate offers the agent-HIT row"
assert_absent  "$OLDER" "$out" "T11: --calibrate skips an agent-MISS row"
assert_absent  "$OLDEST" "$out" "T11: --calibrate skips an agent-SCAFFOLD row"
assert_contains "agent said HIT" "$out" "T11: the agent claim is shown"
assert_contains "was the output good" "$out" "T11: the human is asked the human question"

# A long reason is truncated so it cannot destroy the prompt line.
assert_contains "…" "$out" "T11: an over-long agent reason is truncated"
assert_absent "and keeps going" "$out" "T11: the truncated tail is not printed"

# The two modes are disjoint, asserted both ways.
out_def=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$cal" 2>&1)
assert_contains "no untracked delegations" "$out_def" "T11: the default mode offers none of the agent-verdicted rows"

# --- T12: a row that already has a HUMAN verdict is offered by neither -------
cal2="$tmp/cal2.jsonl"
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"m","exit_status":0}\n' "$NOW"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent"}\n' "$FB" "$NOW"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false}\n' "$FB" "$NOW"
} > "$cal2"
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --file "$cal2" 2>&1)
assert_contains "no agent-hit delegations" "$out" "T12: a row with a human verdict is not re-offered"
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --file "$cal2" 2>&1)
assert_contains "no untracked delegations" "$out" "T12: nor by the default mode"

# A reasonless agent verdict still renders.
cal3="$tmp/cal3.jsonl"
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"m","exit_status":0}\n' "$NOW"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent"}\n' "$FB" "$NOW"
} > "$cal3"
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --file "$cal3" 2>&1)
assert_contains "(no reason recorded)" "$out" "T12: a reasonless agent verdict still renders"

# --- T13: the recorded verdict is HUMAN-tier and coexists -------------------
out=$(printf 'm\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --file "$cal3" 2>&1)
assert_contains "MISS recorded" "$out" "T13: --calibrate records through delegate-feedback.sh"
human_rows=$(jq -c 'select(.source=="feedback" and (.verdict_source|not))' "$cal3" | wc -l | tr -d ' ')
agent_rows=$(jq -c 'select(.source=="feedback" and .verdict_source=="agent")' "$cal3" | wc -l | tr -d ' ')
assert_eq "1" "$human_rows" "T13: exactly one human-tier row was written"
assert_eq "1" "$agent_rows" "T13: the agent row still stands (coexists, not replaced)"

# --- T14: --sample caps, and takes most recent by ts not file order ---------
cal4="$tmp/cal4.jsonl"
: > "$cal4"
# Capture each stamp ONCE and reuse it. Recomputing `time - 3600` for the
# assertion after writing the row is a clock race: a second ticking over between
# the two makes them differ and the test fails intermittently.
T_OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 10800))')
T_MID=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 7200))')
T_NEW=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 3600))')
# Written OLDEST-first in the file so a tail would pick the wrong rows.
for T in "$T_OLD" "$T_MID" "$T_NEW"; do
  printf '{"ts":"%s","source":"delegate","recipe":"r","tier":"prose","model":"m","exit_status":0}\n' "$T" >> "$cal4"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent"}\n' "$FB" "$T" >> "$cal4"
done
NEWEST="$T_NEW"
EARLIEST="$T_OLD"
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --sample 1 --file "$cal4" 2>&1)
assert_contains "1 delegation(s) the agent graded" "$out" "T14: --sample 1 caps the offer"
assert_contains "$NEWEST" "$out" "T14: --sample takes the most recent by ts"
assert_absent "$EARLIEST" "$out" "T14: --sample drops the older rows"
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --sample 0 --file "$cal4" 2>&1)
assert_contains "3 delegation(s) the agent graded" "$out" "T14: --sample 0 means no cap"
ec=0; bash "$SCRIPT" --calibrate --sample abc --file "$cal4" >/dev/null 2>&1 || ec=$?
assert_eq "2" "$ec" "T14: a non-numeric --sample exits 2"

# --- T15: "last verdict" means last by TIMESTAMP, not by file order ---------
# The metrics file is not strictly chronological, and 3 delegations in the live
# history have a different last verdict by file order than by time. Written
# here so file order says MISS (not eligible) while time order says HIT
# (eligible): without sort_by(.ts) before the reduce this row is skipped.
cal5="$tmp/cal5.jsonl"
D=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 3600))')
T_LATE=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 120))')
T_EARLY=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 600))')
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"m","exit_status":0}\n' "$D"
  # HIT carries the LATER ts but is written FIRST.
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent"}\n' "$T_LATE" "$D"
  # MISS carries the EARLIER ts but is written LAST.
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false,"verdict_source":"agent"}\n' "$T_EARLY" "$D"
} > "$cal5"
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --file "$cal5" 2>&1)
assert_contains "$D" "$out" "T15: last-verdict is resolved by ts, not file order"

# ...and the mirror: file order says HIT, time order says MISS -> not eligible.
cal6="$tmp/cal6.jsonl"
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"m","exit_status":0}\n' "$D"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":false,"verdict_source":"agent"}\n' "$T_LATE" "$D"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent"}\n' "$T_EARLY" "$D"
} > "$cal6"
out=$(printf 'q\n' | DELEGATE_SWEEP_ASSUME_TTY=1 bash "$SCRIPT" --calibrate --file "$cal6" 2>&1)
assert_contains "no agent-hit delegations" "$out" "T15: a superseded HIT is not re-offered"

echo
echo "$pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then exit 1; fi
