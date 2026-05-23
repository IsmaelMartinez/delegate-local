#!/usr/bin/env bash
# Unit tests for scripts/semantic-search.sh.
# Mocks `ollama` and `curl` with deterministic embeddings so the cosine
# similarities are predictable. The curl mock returns a different vector
# per input string (keyed by stdin payload) so the ranking is testable
# without touching a real model.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/semantic-search.sh"
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

# Mock curl with deterministic per-input vectors so the ranking is testable
# without touching a real model. The mock reads the JSON payload from stdin,
# extracts the `.input` field, and emits a vector that varies with the input
# string in a predictable way:
#   * input contains "query"   -> [1, 0, 0, 0]
#   * input contains "alpha"   -> [0.9, 0.1, 0, 0]   (high similarity to query)
#   * input contains "beta"    -> [0.5, 0.5, 0, 0]   (medium similarity)
#   * input contains "gamma"   -> [0, 1, 0, 0]       (orthogonal — score 0)
#   * input contains "delta"   -> [-1, 0, 0, 0]      (opposite — score -1)
#   * fallback                 -> [0.3, 0.3, 0.3, 0]
# Each call requires jq to be on PATH (the real semantic-search.sh
# expects jq too), so add `/usr/bin` and `/bin` to the mock's PATH via
# the SAFE_PATH the test harness uses.
make_mock_curl_deterministic() {
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
out_file=""
while (( $# > 0 )); do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
payload=$(cat)
input=$(printf '%s' "$payload" | jq -r '.input')
case "$input" in
  *query*) vec='[1,0,0,0]' ;;
  *alpha*) vec='[0.9,0.1,0,0]' ;;
  *beta*)  vec='[0.5,0.5,0,0]' ;;
  *gamma*) vec='[0,1,0,0]' ;;
  *delta*) vec='[-1,0,0,0]' ;;
  *)       vec='[0.3,0.3,0.3,0]' ;;
esac
body=$(jq -nc --argjson v "$vec" '{embeddings:[$v],model:"nomic-embed-text:latest"}')
if [[ -n "$out_file" ]]; then printf '%s' "$body" > "$out_file"
else printf '%s' "$body"; fi
EOF
  chmod +x "$dir/curl"
}

echo "=== semantic-search.sh ==="

# 1. No args -> exit 2.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 2 "$EC" "no args -> exit 2"

# 2. Only query, no files -> exit 2.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" "query" 2>&1) || EC=$?
assert_eq 2 "$EC" "query without files -> exit 2"

# 3. Non-numeric --top -> exit 2.
tmp=$(mktemp -d)
echo "alpha" > "$tmp/a.txt"
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" --top banana "query" "$tmp/a.txt" 2>&1) || EC=$?
assert_eq 2 "$EC" "non-numeric --top: exit 2"
assert_contains "positive integer" "$out" "non-numeric --top: stderr"
rm -rf "$tmp"

# 4. --top 0 -> exit 2 (must be positive).
tmp=$(mktemp -d)
echo "alpha" > "$tmp/a.txt"
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" --top 0 "query" "$tmp/a.txt" 2>&1) || EC=$?
assert_eq 2 "$EC" "--top 0: exit 2"
rm -rf "$tmp"

# 5. --top requires a value.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" bash "$SCRIPT" --top 2>&1) || EC=$?
assert_eq 2 "$EC" "--top no value: exit 2"

# 6. Happy path: rank three files. alpha should outrank beta should
# outrank gamma against "query".
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
echo "alpha content" > "$files_dir/a.txt"
echo "beta content"  > "$files_dir/b.txt"
echo "gamma content" > "$files_dir/c.txt"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query phrase" "$files_dir/a.txt" "$files_dir/b.txt" "$files_dir/c.txt" 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "happy path: exit 0"
# Three lines of output, alpha first.
line_count=$(printf '%s' "$out" | grep -c '^')
assert_eq 3 "$line_count" "happy path: 3 lines of output"
first=$(printf '%s' "$out" | head -1)
second=$(printf '%s' "$out" | sed -n '2p')
third=$(printf '%s' "$out" | sed -n '3p')
assert_contains "a.txt" "$first" "ranking: alpha (a.txt) first"
assert_contains "b.txt" "$second" "ranking: beta (b.txt) second"
assert_contains "c.txt" "$third" "ranking: gamma (c.txt) third"
# Each row is "<score> <path>" (a six-decimal float, then a space).
assert_contains "0." "$first" "ranking: first row has float score"
# Sorted descending: score1 > score2 > score3.
s1=$(printf '%s' "$first" | awk '{print $1}')
s2=$(printf '%s' "$second" | awk '{print $1}')
s3=$(printf '%s' "$third" | awk '{print $1}')
# Use awk for float comparison (bash can't compare floats natively).
if awk -v a="$s1" -v b="$s2" 'BEGIN { exit !(a > b) }'; then
  echo "  PASS  ranking: score1 > score2"; pass=$((pass+1))
else
  echo "  FAIL  ranking: score1 ($s1) > score2 ($s2)"; fail=$((fail+1))
fi
if awk -v a="$s2" -v b="$s3" 'BEGIN { exit !(a > b) }'; then
  echo "  PASS  ranking: score2 > score3"; pass=$((pass+1))
else
  echo "  FAIL  ranking: score2 ($s2) > score3 ($s3)"; fail=$((fail+1))
fi
rm -rf "$tmp" "$files_dir" "$metrics"

# 7. --top K limits the output rows.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
echo "alpha"  > "$files_dir/a.txt"
echo "beta"   > "$files_dir/b.txt"
echo "gamma"  > "$files_dir/c.txt"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" --top 2 "query" "$files_dir/a.txt" "$files_dir/b.txt" "$files_dir/c.txt" 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "--top 2: exit 0"
line_count=$(printf '%s' "$out" | grep -c '^')
assert_eq 2 "$line_count" "--top 2: 2 rows of output"
rm -rf "$tmp" "$files_dir" "$metrics"

# 8. Missing file emits stderr warning and is skipped, not failed.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
echo "alpha" > "$files_dir/a.txt"
metrics=$(mktemp)
EC=0
all=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query" "$files_dir/a.txt" "$files_dir/nonexistent.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "missing file: exit 0 (warn-and-skip)"
assert_contains "file not found" "$all" "missing file: stderr warning"
# Output (mixing stderr / stdout) still has one ranked line for a.txt.
assert_contains "a.txt" "$all" "missing file: surviving file still ranked"
rm -rf "$tmp" "$files_dir" "$metrics"

# 9. Empty file emits stderr warning and is skipped.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
echo "alpha" > "$files_dir/a.txt"
: > "$files_dir/empty.txt"   # zero-byte file
metrics=$(mktemp)
EC=0
all=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query" "$files_dir/a.txt" "$files_dir/empty.txt" 2>&1) || EC=$?
assert_eq 0 "$EC" "empty file: exit 0"
assert_contains "empty file" "$all" "empty file: stderr warning"
# Empty file should not appear in the ranked output (look in stdout only).
stdout_only=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query" "$files_dir/a.txt" "$files_dir/empty.txt" 2>/dev/null)
assert_not_contains "empty.txt" "$stdout_only" "empty file: not in stdout ranking"
rm -rf "$tmp" "$files_dir" "$metrics"

# 10. All files unusable -> exit 1.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query" "$files_dir/nonexistent1.txt" "$files_dir/nonexistent2.txt" 2>&1) || EC=$?
assert_eq 1 "$EC" "all files unusable: exit 1"
assert_contains "no files produced" "$out" "all files unusable: stderr"
rm -rf "$tmp" "$files_dir" "$metrics"

# 11. Output format: each row is "<float> <path>" with single space.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
echo "alpha" > "$files_dir/a.txt"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query" "$files_dir/a.txt" 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "single file: exit 0"
if [[ "$out" =~ ^[0-9-]+\.[0-9]+\ .+a\.txt$ ]]; then
  echo "  PASS  output format: <score> <path>"; pass=$((pass+1))
else
  echo "  FAIL  output format: expected '<float> <path>', got '$out'"; fail=$((fail+1))
fi
rm -rf "$tmp" "$files_dir" "$metrics"

# 12. Two embed metric rows per file pair: one for the query, one for the
# file. With one query + two files we expect three "source":"embed" rows.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
echo "alpha" > "$files_dir/a.txt"
echo "beta"  > "$files_dir/b.txt"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query" "$files_dir/a.txt" "$files_dir/b.txt" 2>/dev/null) || EC=$?
embed_rows=$(grep -c '"source":"embed"' "$metrics")
assert_eq 3 "$embed_rows" "metrics: 3 embed rows (1 query + 2 files)"
rm -rf "$tmp" "$files_dir" "$metrics"

# 13. Negative-score case: a "delta" file (opposite to query) gets a
# negative score but still appears in the ranking.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_deterministic "$tmp"
files_dir=$(mktemp -d)
echo "delta" > "$files_dir/d.txt"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" "query" "$files_dir/d.txt" 2>/dev/null) || EC=$?
assert_eq 0 "$EC" "negative score: exit 0"
assert_contains "-1." "$out" "negative score: shows up in output"
rm -rf "$tmp" "$files_dir" "$metrics"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
