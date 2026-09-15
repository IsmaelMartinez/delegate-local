#!/usr/bin/env bash
# Unit tests for scripts/delegate-verdict-stop-hook.sh, the Stop hook that
# hands a session's untracked delegations back to the agent for a verdict.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/delegate-verdict-stop-hook.sh"

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
  else echo "  FAIL  $name (missing '$needle')"; fail=$((fail+1)); fi
}
assert_empty() {
  local val="$1" name="$2"
  if [[ -z "$val" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (expected empty, got '$val')"; fail=$((fail+1)); fi
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD=$(perl -MPOSIX -e 'print POSIX::strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - 48*3600))')

# Build a Stop payload. The hook derives the project from cwd as delegate.sh
# does, so each test's cwd is a real git repository. DELEGATE_PROJECT is
# unset so the suite's own environment cannot rename every row.
unset DELEGATE_PROJECT
mk_tmp_repo() {  # -> prints the path of a fresh temp git repository
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q . ) >/dev/null 2>&1
  printf '%s\n' "$d"
}
payload() {  # <session_id> <cwd>
  jq -nc --arg s "$1" --arg c "$2" '{session_id:$s, cwd:$c, hook_event_name:"Stop"}'
}
# Run the hook, capture stdout to a file (the reason carries newlines, so a
# file round-trips more reliably than a shell variable through a pipe).
run_hook() {  # <session_id> <cwd> <metrics_file> <out_file>  [env assignments...]
  local sid="$1" cwd="$2" mf="$3" of="$4"; shift 4
  payload "$sid" "$cwd" | env "$@" DELEGATE_METRICS_FILE="$mf" bash "$SCRIPT" >"$of" 2>/dev/null
}

# --- T1. No metrics file → exit 0, no output -------------------------------
tmp=$(mktemp -d)
run_hook "s1" "$tmp" "$tmp/nope.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T1: no metrics file → exit 0"
assert_empty "$(cat "$tmp/out")" "T1: no metrics file → no output"
rm -rf "$tmp"

# --- T2. Untracked delegation in project → decision:block + marker ---------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s2"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s2" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T2: untracked delegation → exit 0"
jq -e . "$tmp/out" >/dev/null 2>&1 && { pass=$((pass+1)); echo "  PASS  T2: output is valid JSON"; } || { fail=$((fail+1)); echo "  FAIL  T2: output is not valid JSON"; }
assert_eq "block" "$(jq -r .decision "$tmp/out" 2>/dev/null)" "T2: decision is block"
assert_contains "$NOW" "$(jq -r .reason "$tmp/out")" "T2: reason names the untracked ts"
assert_contains "commit-message" "$(jq -r .reason "$tmp/out")" "T2: reason names the recipe"
[[ -f "$tmp/.verdict-stop-markers/s2" ]] && { pass=$((pass+1)); echo "  PASS  T2: session marker written on inject"; } || { fail=$((fail+1)); echo "  FAIL  T2: session marker not written"; }
rm -rf "$tmp"

# --- T3. The injected instruction names delegate-feedback.sh, --source agent,
# and a pin the agent can copy off each batch line ---------------------------
# The pin is --id with the row's otel_span_id (parallel delegations share a
# second); a row with no span id is pinned by --ts instead, since a `--id -`
# would match nothing and the row would never be surfaced again.
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","otel_span_id":"abcdef0123456789","session":"s3"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s3" "$tmp" "$tmp/m.jsonl" "$tmp/out"
reason=$(jq -r .reason "$tmp/out")
assert_contains "--source agent" "$reason" "T3: instruction records with --source agent"
assert_contains "delegate-feedback.sh" "$reason" "T3: instruction names delegate-feedback.sh"
assert_contains "  - --id abcdef0123456789  " "$reason" "T3: a row with a span id is pinned by --id on its batch line"
# Scoped to the batch lines: the prose beneath names both pin forms on purpose.
case "$(printf '%s\n' "$reason" | grep -E '^  - ')" in
  *"--ts "*) echo "  FAIL  T3: a row with a span id is not offered a --ts pin"; fail=$((fail+1));;
  *) echo "  PASS  T3: a row with a span id is not offered a --ts pin"; pass=$((pass+1));;
esac
case "$reason" in
  *"verdict-sweep"*) echo "  FAIL  T3: no hand-off to an interactive sweep"; fail=$((fail+1));;
  *) echo "  PASS  T3: no hand-off to an interactive sweep"; pass=$((pass+1));;
esac
# Each verdict is its own complete command on its own line: `a | b | c` runs
# as a pipeline and `a, b or c` passes `hit,` as the verdict. The annotation
# after each is a shell comment so a whole-line copy still runs.
cmd_lines=$(printf '%s\n' "$reason" | grep -F 'delegate-feedback.sh')
assert_eq 3 "$(printf '%s\n' "$cmd_lines" | grep -c '')" "T3: three verdict commands, one per line"
cmd_re='delegate-feedback\.sh" <pin> --source agent (scaffold "<reason>"|miss "<reason>"|hit)( +# [a-z -]+)?$'
assert_eq 3 "$(printf '%s\n' "$cmd_lines" | grep -Ec "$cmd_re")" "T3: every line is one complete command plus an optional # note"
assert_eq 1 "$(printf '%s\n' "$cmd_lines" | grep -Ec -- '--source agent hit( |$)')" "T3: a hit command"
assert_eq 1 "$(printf '%s\n' "$cmd_lines" | grep -Ec -- '--source agent scaffold "<reason>"')" "T3: a scaffold command"
assert_eq 1 "$(printf '%s\n' "$cmd_lines" | grep -Ec -- '--source agent miss "<reason>"')" "T3: a miss command"
case "$cmd_lines" in
  *","*|*" | "*|*" or "*) echo "  FAIL  T3: no command line joins alternatives with ',', '|' or 'or'"; fail=$((fail+1));;
  *) echo "  PASS  T3: no command line joins alternatives with ',', '|' or 'or'"; pass=$((pass+1));;
esac
# Same session, a row with no otel_span_id: the pin on its line is --ts.
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s3b"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s3b" "$tmp" "$tmp/m.jsonl" "$tmp/out"
reason=$(jq -r .reason "$tmp/out")
assert_contains "  - --ts $NOW  " "$reason" "T3: a row with no span id is pinned by --ts on its batch line"
case "$reason" in
  *"--id -"*|*"id=-"*) echo "  FAIL  T3: a row with no span id is not offered an empty --id"; fail=$((fail+1));;
  *) echo "  PASS  T3: a row with no span id is not offered an empty --id"; pass=$((pass+1));;
esac
rm -rf "$tmp"

# --- T4. Session-once guard: a second Stop in the same session does not
# re-inject, even though the delegation is still untracked -------------------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"sLoop"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "sLoop" "$tmp" "$tmp/m.jsonl" "$tmp/out1"
assert_eq "block" "$(jq -r .decision "$tmp/out1" 2>/dev/null)" "T4: first Stop injects"
run_hook "sLoop" "$tmp" "$tmp/m.jsonl" "$tmp/out2"; ec=$?
assert_eq 0 "$ec" "T4: second Stop (same session) → exit 0"
assert_empty "$(cat "$tmp/out2")" "T4: second Stop (same session) → no re-inject (loop guard)"
rm -rf "$tmp"

# --- T4b. A different session in the same repo is not offered the batch:
# the scan is per-session, and no marker is written for it ------------------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"sA"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "sA" "$tmp" "$tmp/m.jsonl" "$tmp/outA"
assert_eq "block" "$(jq -r .decision "$tmp/outA" 2>/dev/null)" "T4b: the owning session is offered the batch"
run_hook "sB" "$tmp" "$tmp/m.jsonl" "$tmp/outB"
assert_empty "$(cat "$tmp/outB")" "T4b: another session in the same repo is not offered sA's row"
[[ -f "$tmp/.verdict-stop-markers/sB" ]] && { fail=$((fail+1)); echo "  FAIL  T4b: no marker for a session with nothing to verdict"; } || { pass=$((pass+1)); echo "  PASS  T4b: no marker for a session with nothing to verdict"; }
rm -rf "$tmp"

# --- T5. off mode → exit 0, no output --------------------------------------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s5"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s5" "$tmp" "$tmp/m.jsonl" "$tmp/out" DELEGATE_VERDICT_STOP_MODE=off; ec=$?
assert_eq 0 "$ec" "T5: off mode → exit 0"
assert_empty "$(cat "$tmp/out")" "T5: off mode → no output"
[[ -f "$tmp/.verdict-stop-markers/s5" ]] && { fail=$((fail+1)); echo "  FAIL  T5: off mode must not write a marker"; } || { pass=$((pass+1)); echo "  PASS  T5: off mode writes no marker"; }
rm -rf "$tmp"

# --- T6. Window exclusion: a delegation older than the window is not surfaced --
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s6"}\n' "$OLD" "$proj" > "$tmp/m.jsonl"
run_hook "s6" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T6: out-of-window delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T6: out-of-window delegation not surfaced"
rm -rf "$tmp"

# --- T7. Already-tracked: a delegation with a feedback row is not surfaced --
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s7"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true}\n' "$NOW" "$NOW"
} > "$tmp/m.jsonl"
run_hook "s7" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T7: already-tracked delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T7: already-tracked delegation not surfaced"
rm -rf "$tmp"

# --- T7b. An AGENT verdict also counts as tracked (not re-surfaced) ---------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s7b"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent"}\n' "$NOW" "$NOW"
} > "$tmp/m.jsonl"
run_hook "s7b" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_empty "$(cat "$tmp/out")" "T7b: a recorded agent verdict drops the delegation from the next scan"
rm -rf "$tmp"

# --- T8. Per-project scoping: a delegation in another project is not surfaced --
tmp=$(mk_tmp_repo)  # cwd → project = basename(tmp); the row carries a different project
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"some-other-repo","session":"s8"}\n' "$NOW" > "$tmp/m.jsonl"
run_hook "s8" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T8: other-project delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T8: other-project delegation not surfaced"
rm -rf "$tmp"

# --- T9. Failed delegation (exit_status != 0) is not surfaced --------------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":3,"project":"%s","session":"s9"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s9" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T9: failed delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T9: failed delegation (no output) not surfaced"
rm -rf "$tmp"

# --- T10. A bare / no-recipe untracked delegation is still surfaced --------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s10"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s10" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_eq "block" "$(jq -r .decision "$tmp/out" 2>/dev/null)" "T10: bare delegation surfaced"
assert_contains "(bare/no-recipe)" "$(jq -r .reason "$tmp/out")" "T10: bare delegation labelled in the batch"
rm -rf "$tmp"

# --- T11. Corrupt metrics file → fail open (exit 0, no output) -------------
tmp=$(mktemp -d)
printf 'this is not json{{{\n' > "$tmp/m.jsonl"
run_hook "s11" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T11: corrupt metrics file → exit 0 (fail open)"
assert_empty "$(cat "$tmp/out")" "T11: corrupt metrics file → no output"
rm -rf "$tmp"

# --- T12. Empty stdin / no payload → exit 0 (fail open) --------------------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
out=$(printf '' | DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>/dev/null); ec=$?
assert_eq 0 "$ec" "T12: empty payload → exit 0"
assert_empty "$out" "T12: empty payload → no output (no session_id to scope)"
rm -rf "$tmp"

# --- T13. No session_id, no inject: the loop-guard marker is keyed by it ----
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
no_sid_payload=$(jq -nc --arg c "$tmp" '{cwd:$c, hook_event_name:"Stop"}')
out=$(printf '%s' "$no_sid_payload" | DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>/dev/null); ec=$?
assert_eq 0 "$ec" "T13: no session_id → exit 0"
assert_empty "$out" "T13: no session_id → no inject (guardless re-inject would loop)"
[[ -d "$tmp/.verdict-stop-markers" ]] && { fail=$((fail+1)); echo "  FAIL  T13: no marker dir should be created without a session_id"; } || { pass=$((pass+1)); echo "  PASS  T13: no marker written without a session_id"; }
rm -rf "$tmp"

# --- T14. A cwd outside any git repository derives no project (#476): a row
# under the folder basename is not this cwd's, a projectless row is, but
# only one this session wrote (#479); a projectless row with no session is
# left alone, and the reason must not print an empty project name ----------
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s14" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T14: non-repo cwd → exit 0"
assert_empty "$(cat "$tmp/out")" "T14: non-repo cwd does not derive the folder basename as the project"
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"session":"s14b"}\n' "$NOW" > "$tmp/m.jsonl"
run_hook "s14b" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_eq "block" "$(jq -r .decision "$tmp/out" 2>/dev/null)" "T14: non-repo cwd surfaces this session's projectless delegation"
case "$(jq -r .reason "$tmp/out")" in
  *"project ''"*) assert_eq "absent" "present" "T14: reason does not print an empty project name" ;;
  *)              assert_eq "absent" "absent"  "T14: reason does not print an empty project name" ;;
esac
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"session":"someone-else"}\n' "$NOW" > "$tmp/m.jsonl"
run_hook "s14c" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T14: another session's projectless row → exit 0"
assert_empty "$(cat "$tmp/out")" "T14: another session's projectless untracked row does not block this Stop"
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0}\n' "$NOW" > "$tmp/m.jsonl"
run_hook "s14d" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_empty "$(cat "$tmp/out")" "T14: a projectless row with no session cannot be scoped and is left alone"
rm -rf "$tmp"

# --- T16. A named-project row is session-scoped too (#482): only a row this
# session wrote is listed, and a row with no session field is nobody's -----
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s16"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s16" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_eq "block" "$(jq -r .decision "$tmp/out" 2>/dev/null)" "T16: this session's named-project row is listed"
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"someone-else"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s16b" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T16: another session's named-project row → exit 0"
assert_empty "$(cat "$tmp/out")" "T16: another session's named-project row is not listed"
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s16c" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T16: a named-project row with no session field → exit 0"
assert_empty "$(cat "$tmp/out")" "T16: a named-project row with no session field is nobody's and is not listed"
rm -rf "$tmp"

# --- T17. Same-second siblings: a verdict on one does not track the other
# (#481); the map is keyed on ref_id where present, ref_ts otherwise --------
tmp=$(mk_tmp_repo); proj=$(basename "$tmp")
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s17","otel_span_id":"aaaa000000000001"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s17","otel_span_id":"aaaa000000000002"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","ref_id":"aaaa000000000001","kept":true,"verdict_source":"agent"}\n' "$NOW" "$NOW"
} > "$tmp/m.jsonl"
run_hook "s17" "$tmp" "$tmp/m.jsonl" "$tmp/out"
reason=$(jq -r .reason "$tmp/out" 2>/dev/null)
assert_contains "1 delegation(s)" "$reason" "T17: exactly the unverdicted sibling is surfaced"
assert_contains "--id aaaa000000000002" "$reason" "T17: the surfaced row is the sibling without a verdict"
case "$reason" in
  *"aaaa000000000001"*) echo "  FAIL  T17: the verdicted sibling is not re-surfaced"; fail=$((fail+1));;
  *) echo "  PASS  T17: the verdicted sibling is not re-surfaced"; pass=$((pass+1));;
esac
# A legacy feedback row (ref_ts only) still tracks by ts: both siblings drop
# out, which is the best a row with no ref_id can do.
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s17b","otel_span_id":"aaaa000000000003"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"delegate","recipe":"maintainer-reply","tier":"prose","model":"q","exit_status":0,"project":"%s","session":"s17b","otel_span_id":"aaaa000000000004"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true}\n' "$NOW" "$NOW"
} > "$tmp/m.jsonl"
run_hook "s17b" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_empty "$(cat "$tmp/out")" "T17: a legacy ref_ts-only verdict still tracks every row of its second"
rm -rf "$tmp"

# --- T15. DELEGATE_PROJECT wins, as it does for delegate.sh and feedback -----
tmp=$(mk_tmp_repo)
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"explicit-name","session":"s15"}\n' "$NOW" > "$tmp/m.jsonl"
run_hook "s15" "$tmp" "$tmp/m.jsonl" "$tmp/out" DELEGATE_PROJECT=explicit-name
assert_eq "block" "$(jq -r .decision "$tmp/out" 2>/dev/null)" "T15: DELEGATE_PROJECT scopes the scan"
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
