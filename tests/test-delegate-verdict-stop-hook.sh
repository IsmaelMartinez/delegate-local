#!/usr/bin/env bash
# Unit tests for scripts/delegate-verdict-stop-hook.sh — the Phase E Stop hook
# that hands a session's untracked delegations back to the live agent for an
# agent-observed verdict. Builds synthetic metrics + Stop payloads in $tmp and
# asserts the surface/skip decisions, the session-once loop guard, and that the
# injected instruction always carries --source agent.
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

# Build a Stop payload. project is derived by the hook from cwd; we point cwd
# at a non-repo temp dir so the project resolves to its basename deterministically.
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
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s2" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T2: untracked delegation → exit 0"
jq -e . "$tmp/out" >/dev/null 2>&1 && { pass=$((pass+1)); echo "  PASS  T2: output is valid JSON"; } || { fail=$((fail+1)); echo "  FAIL  T2: output is not valid JSON"; }
assert_eq "block" "$(jq -r .decision "$tmp/out" 2>/dev/null)" "T2: decision is block"
assert_contains "$NOW" "$(jq -r .reason "$tmp/out")" "T2: reason names the untracked ts"
assert_contains "commit-message" "$(jq -r .reason "$tmp/out")" "T2: reason names the recipe"
[[ -f "$tmp/.verdict-stop-markers/s2" ]] && { pass=$((pass+1)); echo "  PASS  T2: session marker written on inject"; } || { fail=$((fail+1)); echo "  FAIL  T2: session marker not written"; }
rm -rf "$tmp"

# --- T3. The injected instruction ALWAYS carries --source agent ------------
# Load-bearing: if the tier tag silently dropped to the human default, the
# agent verdict would contaminate the quality signal.
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s3" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_contains "--source agent" "$(jq -r .reason "$tmp/out")" "T3: instruction records with --source agent"
assert_contains "delegate-feedback.sh" "$(jq -r .reason "$tmp/out")" "T3: instruction names delegate-feedback.sh"
rm -rf "$tmp"

# --- T4. Session-once guard: second Stop, SAME session → exit 0, no output --
# The regression test for the decision:block re-inject loop. After T's inject
# writes the marker, a second Stop in the same session must NOT re-inject even
# though the delegation is still untracked.
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "sLoop" "$tmp" "$tmp/m.jsonl" "$tmp/out1"
assert_eq "block" "$(jq -r .decision "$tmp/out1" 2>/dev/null)" "T4: first Stop injects"
run_hook "sLoop" "$tmp" "$tmp/m.jsonl" "$tmp/out2"; ec=$?
assert_eq 0 "$ec" "T4: second Stop (same session) → exit 0"
assert_empty "$(cat "$tmp/out2")" "T4: second Stop (same session) → no re-inject (loop guard)"
rm -rf "$tmp"

# --- T4b. A DIFFERENT session surfaces the still-untracked batch once -------
# The marker is per-session, so a fresh agent is offered the batch (and leaves
# what it doesn't recognise) rather than the item being lost — not a loop.
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "sA" "$tmp" "$tmp/m.jsonl" "$tmp/outA"
run_hook "sB" "$tmp" "$tmp/m.jsonl" "$tmp/outB"
assert_eq "block" "$(jq -r .decision "$tmp/outB" 2>/dev/null)" "T4b: a new session re-surfaces the untracked batch once"
rm -rf "$tmp"

# --- T5. off mode → exit 0, no output --------------------------------------
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s5" "$tmp" "$tmp/m.jsonl" "$tmp/out" DELEGATE_VERDICT_STOP_MODE=off; ec=$?
assert_eq 0 "$ec" "T5: off mode → exit 0"
assert_empty "$(cat "$tmp/out")" "T5: off mode → no output"
[[ -f "$tmp/.verdict-stop-markers/s5" ]] && { fail=$((fail+1)); echo "  FAIL  T5: off mode must not write a marker"; } || { pass=$((pass+1)); echo "  PASS  T5: off mode writes no marker"; }
rm -rf "$tmp"

# --- T6. Window exclusion: a delegation older than the window is not surfaced --
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$OLD" "$proj" > "$tmp/m.jsonl"
run_hook "s6" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T6: out-of-window delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T6: out-of-window delegation not surfaced"
rm -rf "$tmp"

# --- T7. Already-tracked: a delegation with a feedback row is not surfaced --
tmp=$(mktemp -d); proj=$(basename "$tmp")
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true}\n' "$NOW" "$NOW"
} > "$tmp/m.jsonl"
run_hook "s7" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T7: already-tracked delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T7: already-tracked delegation not surfaced"
rm -rf "$tmp"

# --- T7b. An AGENT verdict also counts as tracked (not re-surfaced) ---------
tmp=$(mktemp -d); proj=$(basename "$tmp")
{
  printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj"
  printf '{"ts":"%s","source":"feedback","ref_ts":"%s","kept":true,"verdict_source":"agent"}\n' "$NOW" "$NOW"
} > "$tmp/m.jsonl"
run_hook "s7b" "$tmp" "$tmp/m.jsonl" "$tmp/out"
assert_empty "$(cat "$tmp/out")" "T7b: a recorded agent verdict drops the delegation from the next scan"
rm -rf "$tmp"

# --- T8. Per-project scoping: a delegation in another project is not surfaced --
tmp=$(mktemp -d)  # cwd → project = basename(tmp); the row carries a different project
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"some-other-repo"}\n' "$NOW" > "$tmp/m.jsonl"
run_hook "s8" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T8: other-project delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T8: other-project delegation not surfaced"
rm -rf "$tmp"

# --- T9. Failed delegation (exit_status != 0) is not surfaced --------------
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":3,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
run_hook "s9" "$tmp" "$tmp/m.jsonl" "$tmp/out"; ec=$?
assert_eq 0 "$ec" "T9: failed delegation → exit 0"
assert_empty "$(cat "$tmp/out")" "T9: failed delegation (no output) not surfaced"
rm -rf "$tmp"

# --- T10. A bare / no-recipe untracked delegation is still surfaced --------
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
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
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
out=$(printf '' | DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>/dev/null); ec=$?
assert_eq 0 "$ec" "T12: empty payload → exit 0"
assert_empty "$out" "T12: empty payload → no output (no session_id to scope)"
rm -rf "$tmp"

# --- T13. Payload with cwd but NO session_id → never inject ----------------
# The marker is the loop guard and it is keyed by session_id; without one the
# hook cannot guard against a re-inject loop, so it must NOT inject at all even
# when an untracked delegation exists (fail open to a clean stop).
tmp=$(mktemp -d); proj=$(basename "$tmp")
printf '{"ts":"%s","source":"delegate","recipe":"commit-message","tier":"prose","model":"q","exit_status":0,"project":"%s"}\n' "$NOW" "$proj" > "$tmp/m.jsonl"
no_sid_payload=$(jq -nc --arg c "$tmp" '{cwd:$c, hook_event_name:"Stop"}')
out=$(printf '%s' "$no_sid_payload" | DELEGATE_METRICS_FILE="$tmp/m.jsonl" bash "$SCRIPT" 2>/dev/null); ec=$?
assert_eq 0 "$ec" "T13: no session_id → exit 0"
assert_empty "$out" "T13: no session_id → no inject (guardless re-inject would loop)"
[[ -d "$tmp/.verdict-stop-markers" ]] && { fail=$((fail+1)); echo "  FAIL  T13: no marker dir should be created without a session_id"; } || { pass=$((pass+1)); echo "  PASS  T13: no marker written without a session_id"; }
rm -rf "$tmp"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
