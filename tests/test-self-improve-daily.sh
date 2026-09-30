#!/usr/bin/env bash
# Unit tests for scripts/self-improve-daily.sh — the launchd runner for the
# daily calibration pass (#558). `claude`, `git` and self-improve.sh are all
# mocked on a restricted PATH, and the data dir is a temp dir, so nothing
# here touches the live corpus, the live clone or the API.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO/scripts/self-improve-daily.sh"

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
assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (unexpectedly found '$needle')"; fail=$((fail+1)); fi
}

unset DELEGATE_SELF_IMPROVE_STATE DELEGATE_METRICS_FILE

# setup: a fake live clone (the runner copied beside a mock self-improve.sh),
# a mock bin dir with `claude` and `git`, and an empty data dir. The mocks
# record what they were called with under $T/rec.
setup() {
  T=$(mktemp -d)
  mkdir -p "$T/root/scripts" "$T/bin" "$T/data" "$T/rec"
  cp "$RUNNER" "$T/root/scripts/self-improve-daily.sh" 2>/dev/null || true
  cat > "$T/root/scripts/self-improve.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/rec/gate.args"
rc=\${MOCK_GATE_RC:-0}
if [[ \$rc -ne 10 ]]; then
  echo "=== delegate-local self-improvement evidence ==="
  echo "Newest row: 2026-09-30T12:00:00Z"
  echo "New delegations since watermark: 3"
fi
exit \$rc
EOF
  cat > "$T/bin/claude" <<EOF
#!/usr/bin/env bash
{ echo "--- call"; for a in "\$@"; do printf '%s\n' "\$a"; done; } >> "$T/rec/claude.args"
pwd > "$T/rec/claude.cwd"
cat > "$T/rec/claude.stdin"
[[ -n "\${MOCK_CLAUDE_SLEEP:-}" ]] && sleep "\$MOCK_CLAUDE_SLEEP"
exit \${MOCK_CLAUDE_RC:-0}
EOF
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/rec/git.args"
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    --detach) mkdir -p "\${args[i+1]}";;
    remove) rm -rf "\${args[\${#args[@]}-1]}";;
  esac
done
exit 0
EOF
  chmod +x "$T/root/scripts/self-improve.sh" "$T/bin/claude" "$T/bin/git"
}
run() {
  EC=0
  PATH="$T/bin:/usr/bin:/bin" DELEGATE_LOCAL_DATA_DIR="$T/data" \
    bash "$T/root/scripts/self-improve-daily.sh" > "$T/rec/stdout" 2>&1 || EC=$?
  LOG=$(cat "$T/data/self-improve-daily.log" 2>/dev/null)
}
claude_calls() { grep -c -- '^--- call$' "$T/rec/claude.args" 2>/dev/null || echo 0; }

echo "== self-improve-daily.sh =="

# 1. A quiet gate (exit 10) is a successful run: exit 0, no claude session,
#    and the gate was a --peek so the watermark is the runner's to move.
setup
MOCK_GATE_RC=10 run
assert_eq 0 "$EC" "quiet gate exits 0"
assert_eq 0 "$(claude_calls)" "quiet gate starts no claude session"
assert_contains "--peek" "$(cat "$T/rec/gate.args" 2>/dev/null)" "the gate runs self-improve.sh --peek"
assert_eq "" "$(cat "$T/data/self-improve.state" 2>/dev/null)" "quiet gate writes no watermark"
assert_contains "quiet" "$LOG" "quiet gate is logged"
assert_eq 600 "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$T/data/self-improve-daily.log")" \
  "a new log is private"
rm -rf "$T"

# 1b. A log left world-readable by an earlier run is made private.
setup
mkdir -p "$T/data"
: > "$T/data/self-improve-daily.log"
chmod 644 "$T/data/self-improve-daily.log"
MOCK_GATE_RC=10 run
assert_eq 600 "$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$T/data/self-improve-daily.log")" \
  "an existing log is made private"
rm -rf "$T"

# 2. An open gate runs exactly one headless session with the bundle on
#    stdin, inside a detached worktree that is removed afterwards, and a
#    successful session advances the watermark to the newest row it saw.
setup
MOCK_GATE_RC=0 run
assert_eq 0 "$EC" "open gate with a successful session exits 0"
assert_eq 1 "$(claude_calls)" "open gate starts exactly one claude session"
cargs=$(cat "$T/rec/claude.args" 2>/dev/null)
assert_contains $'\n-p\n' "$cargs" "claude runs headless (-p)"
assert_contains $'--permission-mode\ndontAsk' "$cargs" "claude denies anything not allowlisted"
assert_contains "--allowedTools" "$cargs" "claude gets an explicit tool allowlist"
assert_contains "Bash(gh pr merge *)" "$cargs" "merging is on the deny list"
assert_contains "docs/self-improvement-loop.md" "$cargs" "the prompt names the procedure"
assert_contains $'\nEdit(prompts/**)\n' "$cargs" "edits are confined to prompts/"
assert_not_contains $'\nEdit\n' "$cargs" "no unscoped Edit"
assert_not_contains $'\nWrite\n' "$cargs" "no unscoped Write"
assert_not_contains "Bash(bash tests/*)" "$cargs" "no wildcard over runnable test files"
assert_contains $'\nBash(bash tests/test-prompts-library.sh)\n' "$cargs" "the suites the procedure runs are named exactly"
assert_contains $'--setting-sources\nproject\n' "$cargs" "user settings cannot widen the allowlist"
assert_contains "Newest row: 2026-09-30T12:00:00Z" "$(cat "$T/rec/claude.stdin" 2>/dev/null)" \
  "the bundle is piped to the session"
assert_contains "worktree add --detach" "$(cat "$T/rec/git.args" 2>/dev/null)" \
  "the session gets a detached worktree of the live clone"
assert_contains "$T/data/" "$(cat "$T/rec/claude.cwd" 2>/dev/null)" "the session runs inside that worktree"
assert_contains "worktree remove --force" "$(cat "$T/rec/git.args" 2>/dev/null)" "the worktree is removed afterwards"
assert_eq "2026-09-30T12:00:00Z" "$(cat "$T/data/self-improve.state" 2>/dev/null)" \
  "a successful session advances the watermark to the bundle's newest row"
rm -rf "$T"

# 3. A failed session leaves the watermark where it was, so the next day's
#    run sees the same window again.
setup
echo "2026-09-22T10:14:53Z" > "$T/data/self-improve.state"
MOCK_GATE_RC=0 MOCK_CLAUDE_RC=1 run
assert_eq 1 "$EC" "a failed session exits non-zero"
assert_eq "2026-09-22T10:14:53Z" "$(cat "$T/data/self-improve.state")" "a failed session does not advance the watermark"
rm -rf "$T"

# 4. A gate error (exit 2) is surfaced, not treated as quiet.
setup
MOCK_GATE_RC=2 run
assert_eq 2 "$EC" "gate error exits 2"
assert_eq 0 "$(claude_calls)" "gate error starts no claude session"
rm -rf "$T"

# 5. A lock held by a live run means this run steps aside without a session.
setup
sleep 30 & holder=$!
ln -s "$holder" "$T/data/self-improve-daily.lock"
MOCK_GATE_RC=0 run
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
assert_eq 0 "$EC" "a held lock exits 0"
assert_eq 0 "$(claude_calls)" "a held lock starts no claude session"
assert_contains "already running" "$LOG" "a held lock is logged"
assert_eq "$holder" "$(readlink "$T/data/self-improve-daily.lock" 2>/dev/null)" "a held lock is left to its owner"
rm -rf "$T"

# 6. A lock left by a dead run is taken over, so one killed run cannot stop
#    the loop for good.
setup
sh -c 'exit 0' & dead=$!; wait "$dead"
ln -s "$dead" "$T/data/self-improve-daily.lock"
MOCK_GATE_RC=0 run
assert_eq 0 "$EC" "a stale lock is taken over"
assert_eq 1 "$(claude_calls)" "a stale lock does not block the session"
[[ -L "$T/data/self-improve-daily.lock" ]] && held=yes || held=no
assert_eq no "$held" "the lock is released when the run ends"
rm -rf "$T"

# 7. Two runs started together: the second finds the first's lock and does
#    not start a second session.
setup
MOCK_GATE_RC=0 MOCK_CLAUDE_SLEEP=2 PATH="$T/bin:/usr/bin:/bin" DELEGATE_LOCAL_DATA_DIR="$T/data" \
  bash "$T/root/scripts/self-improve-daily.sh" >/dev/null 2>&1 & first=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$T/rec/claude.stdin" ]] && break; sleep 0.3; done
MOCK_GATE_RC=0 run
wait "$first"
assert_eq 0 "$EC" "an overlapping run exits 0"
assert_eq 1 "$(claude_calls)" "an overlapping run starts no second session"
rm -rf "$T"

# 8. No claude binary on PATH (launchd's minimal PATH) fails with a message
#    that says what to fix, before the gate runs.
setup
rm "$T/bin/claude"
MOCK_GATE_RC=0 run
assert_eq 2 "$EC" "missing claude exits 2"
assert_contains "claude not found on PATH" "$LOG" "missing claude names the binary and PATH"
assert_eq "" "$(cat "$T/rec/gate.args" 2>/dev/null)" "missing claude fails before the gate"
rm -rf "$T"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
