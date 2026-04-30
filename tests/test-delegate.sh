#!/usr/bin/env bash
# Unit tests for scripts/delegate.sh.
# Mocks ollama on a restricted PATH so the test runs the same everywhere.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/delegate.sh"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

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

make_mock_ollama() {
  local dir="$1"
  cat > "$dir/ollama" <<'EOF'
#!/usr/bin/env bash
# Mock ollama. `list` returns a fixed model set; `run` echoes a canned reply
# with some spinner-bytes mixed in so the ANSI strip is exercised.
case "${1:-}" in
  list)
    cat <<'LIST'
NAME             ID SIZE   MODIFIED
qwen3.6:35b-a3b  aa 30 GB  1 day ago
LIST
    ;;
  run)
    # Read stdin to drain it (real ollama would consume it).
    cat > /dev/null
    # Emit some ANSI noise + a clean line so the test verifies stripping.
    printf '\x1b[?25l\x1b[K  spinner\n'
    printf 'mock-model-output: ok\n'
    printf '\x1b[?25h'
    ;;
esac
EOF
  chmod +x "$dir/ollama"
}

# 1. Missing args -> exit 2.
EC=0
out=$(bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 2 "$EC" "no args -> exit 2"

EC=0
out=$(bash "$SCRIPT" prose 2>&1) || EC=$?
assert_eq 2 "$EC" "missing prompt -> exit 2"

# 2. Happy path: tier resolves, ollama mock returns canned text, output is
# stripped of ANSI, metrics file has one line with all required fields.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "happy path exits 0"
assert_contains "mock-model-output: ok" "$out" "model output is in stdout"
# After ANSI strip we should not see escape bytes.
if [[ "$out" == *$'\x1b'* ]]; then
  echo "  FAIL  ANSI bytes stripped from output"; fail=$((fail+1))
else
  echo "  PASS  ANSI bytes stripped from output"; pass=$((pass+1))
fi
# Metrics line written.
lines=$(grep -c '^' "$metrics")
assert_eq 1 "$lines" "metrics file has one line"
line=$(cat "$metrics")
assert_contains '"tier":"prose"' "$line" "metrics: tier"
assert_contains '"model":"qwen3.6:35b-a3b"' "$line" "metrics: model"
assert_contains '"exit_status":0' "$line" "metrics: exit_status"
assert_contains '"prompt_chars":9' "$line" "metrics: prompt_chars"
rm -rf "$tmp" "$metrics"

# 3. Opt-out env var suppresses metrics writing.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
metrics=$(mktemp); rm -f "$metrics"  # ensure file does not exist
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TO_OLLAMA_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "opt-out: still exits 0"
if [[ -f "$metrics" ]]; then
  echo "  FAIL  opt-out: metrics file should not be created"; fail=$((fail+1))
else
  echo "  PASS  opt-out: metrics file not created"; pass=$((pass+1))
fi
rm -rf "$tmp"

# 4. pick-model failure (no model installed) is reflected in metrics + exit.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
# No matching model installed.
[[ "${1:-}" == "list" ]] && echo "NAME             ID SIZE   MODIFIED
unrelated:model  zz 5 GB   1 day ago"
EOF
chmod +x "$tmp/ollama"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "pick-model failure -> exit 1"
assert_contains '"exit_status":1' "$(cat "$metrics")" "metrics: failure logged with exit_status=1"
rm -rf "$tmp" "$metrics"

# 5. Stdin context is included in metrics char count.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash -c 'echo "context-text-here" | bash "$0" prose "Summarise"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin context: exits 0"
line=$(cat "$metrics")
# "context-text-here\n" through cat stripping the trailing newline is 17 chars.
assert_contains '"context_chars":17' "$line" "metrics: context_chars counted"
rm -rf "$tmp" "$metrics"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
