#!/usr/bin/env bash
# Unit tests for scripts/embed.sh.
# Mocks `ollama list` (used by pick-model.sh) and `curl` (used to call
# /api/embed) on a restricted PATH so the test runs the same everywhere.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/embed.sh"
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
assert_not_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name (contained '$needle' but should not)"; fail=$((fail+1)); fi
}

make_mock_ollama() {
  local dir="$1"
  cat > "$dir/ollama" <<'EOF'
#!/usr/bin/env bash
# Mock ollama list — just enough for pick-model.sh embedding tier to resolve.
case "${1:-}" in
  list)
    cat <<'LIST'
NAME                       ID SIZE    MODIFIED
nomic-embed-text:latest    aa 274 MB  1 day ago
LIST
    ;;
esac
EOF
  chmod +x "$dir/ollama"
}

make_mock_curl_ok() {
  # Mock curl that drains stdin, optionally records the JSON payload to a
  # sniff file, and writes a canned embedding response either to stdout or
  # to the -o file. Returns a 4-dim vector to keep the test deterministic
  # and to make the .embeddings[0] | length check trivially 4.
  local dir="$1" sniff="${2:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
out_file=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "${sniff}"
body='{"embeddings":[[0.1,0.2,-0.3,0.4]],"model":"nomic-embed-text:latest"}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
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

echo "=== embed.sh ==="

# 1. No input at all -> exit 2.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "no input -> exit 2"
assert_contains "no input" "$out" "no input: error message names the cause"

# 2. Unknown flag -> exit 2.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" --bogus 2>&1) || EC=$?
assert_eq 2 "$EC" "unknown flag -> exit 2"

# 3. --text with no value -> exit 2.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" --text 2>&1) || EC=$?
assert_eq 2 "$EC" "--text without value -> exit 2"

# 4. Happy path via stdin: tier resolves, curl returns canned vector,
# output is a one-line JSON array on stdout, metrics row written with
# the right fields.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash -c 'printf "%s" "hello world" | bash "$0"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin happy path: exit 0"
# Stdout should be a JSON array; stderr is empty on success so $out is
# the array body.
assert_contains "[0.1,0.2,-0.3,0.4]" "$out" "stdin happy path: vector on stdout"
# Sniff payload shape.
payload=$(cat "$sniff")
assert_contains '"model":"nomic-embed-text:latest"' "$payload" "payload: model field"
assert_contains '"input":"hello world"' "$payload" "payload: input field carries stdin text"
# Metrics line.
lines=$(grep -c '^' "$metrics")
assert_eq 1 "$lines" "metrics: one line written"
line=$(cat "$metrics")
assert_contains '"source":"embed"' "$line" "metrics: source=embed"
assert_contains '"tier":"embedding"' "$line" "metrics: tier=embedding"
assert_contains '"model":"nomic-embed-text:latest"' "$line" "metrics: model field"
assert_contains '"backend":"ollama"' "$line" "metrics: backend=ollama"
assert_contains '"input_chars":11' "$line" "metrics: input_chars counted (len('hello world')=11)"
assert_contains '"embedding_dim":4' "$line" "metrics: embedding_dim parsed from response"
assert_contains '"exit_status":0' "$line" "metrics: exit_status=0"
rm -rf "$tmp" "$metrics"

# 5. Happy path via --text flag.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --text "abc" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--text happy path: exit 0"
assert_contains "[0.1,0.2,-0.3,0.4]" "$out" "--text: vector on stdout"
assert_contains '"input":"abc"' "$(cat "$sniff")" "--text: input field carries flag value"
rm -rf "$tmp" "$metrics"

# 6. --text overrides stdin (flag wins when both are present).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash -c 'printf "from-stdin" | bash "$0" --text "from-flag"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "--text + stdin: exit 0"
assert_contains '"input":"from-flag"' "$(cat "$sniff")" "--text overrides stdin"
rm -rf "$tmp" "$metrics"

# 7. NO_METRICS env var suppresses metrics file creation.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); rm -f "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_LOCAL_NO_METRICS=1 \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "NO_METRICS: exit 0"
if [[ -f "$metrics" ]]; then
  echo "  FAIL  NO_METRICS: file should not be created"; fail=$((fail+1))
else
  echo "  PASS  NO_METRICS: file not created"; pass=$((pass+1))
fi
rm -rf "$tmp"

# 8. pick-model failure (no embedding model installed) -> exit 1, metrics
# row with exit_status=1.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list" ]] && echo "NAME             ID SIZE   MODIFIED
unrelated:model  zz 5 GB   1 day ago"
EOF
chmod +x "$tmp/ollama"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "no embedding model: exit 1"
assert_contains "pick-model failed" "$out" "no model: stderr names the cause"
line=$(cat "$metrics")
assert_contains '"exit_status":1' "$line" "metrics: pick-model failure logged"
assert_contains '"model":"(none)"' "$line" "metrics: model='(none)' on pick-model failure"
rm -rf "$tmp" "$metrics"

# 9. HTTP failure (curl non-zero) propagates and is logged.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_fail "$tmp"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
if [[ "$EC" -ne 0 ]]; then
  echo "  PASS  HTTP failure -> non-zero exit"; pass=$((pass+1))
else
  echo "  FAIL  HTTP failure -> non-zero exit (got $EC)"; fail=$((fail+1))
fi
assert_contains '"exit_status":7' "$(cat "$metrics")" "metrics: HTTP failure exit_status logged"
rm -rf "$tmp" "$metrics"

# 10. DELEGATE_BACKEND=mlx -> exit 2 (out of scope for v1).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=mlx \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "DELEGATE_BACKEND=mlx: exit 2"
assert_contains "not wired up yet" "$out" "DELEGATE_BACKEND=mlx: stderr names the cause"
rm -rf "$tmp"

# 11. DELEGATE_BACKEND=bogus -> exit 2.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=bogus \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "DELEGATE_BACKEND=bogus: exit 2"
assert_contains "unknown DELEGATE_BACKEND" "$out" "DELEGATE_BACKEND=bogus: stderr"
rm -rf "$tmp"

# 12. Long input is truncated with a stderr warning; the post-truncation
# length goes into input_chars.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
long_input=$(printf 'a%.0s' $(seq 1 7000))
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_EMBED_MAX_CHARS=100 \
  bash "$SCRIPT" --text "$long_input" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "long input: exit 0 (truncated, not failed)"
assert_contains "truncating to first 100" "$out" "long input: stderr warning"
# Metrics input_chars should reflect the truncated length (100), not the
# original 7000.
assert_contains '"input_chars":100' "$(cat "$metrics")" "long input: input_chars=truncated length"
rm -rf "$tmp" "$metrics"

# 13. DELEGATE_EMBED_MAX_CHARS=0 disables truncation entirely.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
long_input=$(printf 'b%.0s' $(seq 1 7000))
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_EMBED_MAX_CHARS=0 \
  bash "$SCRIPT" --text "$long_input" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "MAX_CHARS=0: exit 0"
assert_not_contains "truncating" "$out" "MAX_CHARS=0: no truncation warning"
assert_contains '"input_chars":7000' "$(cat "$metrics")" "MAX_CHARS=0: full length sent"
rm -rf "$tmp" "$metrics"

# 14. Non-numeric DELEGATE_EMBED_MAX_CHARS -> exit 2.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_EMBED_MAX_CHARS=banana \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "non-numeric MAX_CHARS: exit 2"
assert_contains "DELEGATE_EMBED_MAX_CHARS" "$out" "non-numeric MAX_CHARS: stderr names env var"
rm -rf "$tmp"

# 15. Response without .embeddings[0] -> exit 1, descriptive stderr.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
out_file=""
while (( $# > 0 )); do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null
body='{"error":"not an embedding model"}'
if [[ -n "$out_file" ]]; then printf '%s' "$body" > "$out_file"
else printf '%s' "$body"; fi
EOF
chmod +x "$tmp/curl"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "missing .embeddings[0]: exit 1"
assert_contains "did not contain .embeddings[0]" "$out" "missing .embeddings[0]: descriptive stderr"
assert_contains '"exit_status":1' "$(cat "$metrics")" "metrics: missing .embeddings[0] -> exit_status=1"
rm -rf "$tmp" "$metrics"

# 16. JSON output is parser-clean: pipe through jq directly and confirm
# the array round-trips.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
parsed=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --text "x" </dev/null 2>/dev/null | jq -r 'length') || EC=$?
assert_eq 0 "$EC" "jq round-trip: exit 0"
assert_eq "4" "$parsed" "jq round-trip: vector length = 4"
rm -rf "$tmp" "$metrics"

# 17. The auto backend falls through to ollama (no MLX probe; embedding
# v1 is Ollama-only).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_BACKEND=auto \
  bash "$SCRIPT" --text "x" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_BACKEND=auto: exit 0"
assert_contains '"backend":"ollama"' "$(cat "$metrics")" "DELEGATE_BACKEND=auto: resolves to ollama in metrics"
rm -rf "$tmp" "$metrics"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
