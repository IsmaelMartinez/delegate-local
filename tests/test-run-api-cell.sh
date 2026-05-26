#!/usr/bin/env bash
# Unit tests for experiments/lib/run_api_cell.sh.
# Mocks `curl` on a restricted PATH so the helper's HTTP call is canned
# and the metrics-appending behaviour is exercised without a real Ollama
# daemon. Mirrors the mock-curl technique in tests/test-delegate.sh.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/experiments/lib/run_api_cell.sh"
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

# Canned /api/generate response: includes the response text plus Ollama's
# token counters so the metrics path has real numbers to record.
make_mock_curl_ok() {
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s' '{"response":"mock cell output\n","prompt_eval_count":42,"eval_count":7,"total_duration":1234567}'
EOF
  chmod +x "$dir/curl"
}

make_mock_curl_fail() {
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "curl: connection refused" >&2
exit 7
EOF
  chmod +x "$dir/curl"
}

# Driver: invoke run_api_cell in a subshell with PATH restricted to the
# mock dir, capture the out_file and metrics JSONL. Session label comes
# from basename "$PWD" — the driver cd's into a known dir so the assertion
# is stable.
run_in_session() {
  local mock_bin="$1" session_dir="$2" out_file="$3" metrics_file="$4" extras="${5:-}"
  (
    cd "$session_dir"
    PATH="$mock_bin:$SAFE_PATH" DELEGATE_METRICS_FILE="$metrics_file" \
      bash -c "set -euo pipefail; source '$LIB'; run_api_cell 'mock-model:tag' 'hello' '$out_file' '$extras'"
  )
}

# 1. Happy path: canned OK response. Cell output is parsed, metrics line
# has source=experiment, session=<cwd leaf>, real token counters.
tmp=$(mktemp -d)
mkdir -p "$tmp/2026-05-04-fake-session"
make_mock_curl_ok "$tmp"
metrics="$tmp/metrics.jsonl"
out="$tmp/cell.txt"

EC=0
run_in_session "$tmp" "$tmp/2026-05-04-fake-session" "$out" "$metrics" >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "happy path exits 0"
assert_eq "mock cell output" "$(cat "$out")" "out_file contains .response text"
assert_eq 1 "$(wc -l < "$metrics" | tr -d ' ')" "metrics file has one line"

line=$(cat "$metrics")
assert_contains '"source":"experiment"' "$line" "metrics: source is experiment"
assert_contains '"session":"2026-05-04-fake-session"' "$line" "metrics: session from cwd leaf"
assert_contains '"model":"mock-model:tag"' "$line" "metrics: model passed through"
assert_contains '"prompt_tokens":42' "$line" "metrics: real prompt_tokens from response"
assert_contains '"eval_tokens":7' "$line" "metrics: real eval_tokens from response"
assert_contains '"estimated_tokens_avoided":49' "$line" "metrics: tokens_avoided = prompt + eval"
assert_contains '"exit_status":0' "$line" "metrics: exit_status 0 on success"

# 2. Opt-out: DELEGATE_LOCAL_NO_METRICS=1 → no metrics line, cell still works.
metrics2="$tmp/metrics2.jsonl"
out2="$tmp/cell2.txt"
EC=0
(
  cd "$tmp/2026-05-04-fake-session"
  PATH="$tmp:$SAFE_PATH" DELEGATE_METRICS_FILE="$metrics2" DELEGATE_LOCAL_NO_METRICS=1 \
    bash -c "set -euo pipefail; source '$LIB'; run_api_cell 'm' 'p' '$out2'"
) >/dev/null 2>&1 || EC=$?
assert_eq 0 "$EC" "opt-out: still exits 0"
[[ ! -f "$metrics2" ]]
assert_eq 0 $? "opt-out: metrics file not created"

# 3. curl failure: run_api_cell returns non-zero, out_file is empty, metrics
# line is still appended with exit_status != 0.
tmp3=$(mktemp -d)
mkdir -p "$tmp3/2026-05-04-fake-session"
make_mock_curl_fail "$tmp3"
metrics3="$tmp3/metrics.jsonl"
out3="$tmp3/cell.txt"

EC=0
run_in_session "$tmp3" "$tmp3/2026-05-04-fake-session" "$out3" "$metrics3" >/dev/null 2>&1 || EC=$?
[[ "$EC" -ne 0 ]]
assert_eq 0 $? "curl failure: non-zero exit"
assert_eq "" "$(cat "$out3")" "curl failure: out_file is empty"
if [[ -f "$metrics3" ]]; then
  line3=$(cat "$metrics3")
  assert_contains '"exit_status":7' "$line3" "metrics: failure exit_status logged"
  assert_contains '"prompt_tokens":0' "$line3" "metrics: prompt_tokens defaults to 0 on failure"
else
  echo "  FAIL  metrics file not created on curl failure"
  fail=$((fail+1))
fi

rm -rf "$tmp" "$tmp3"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
