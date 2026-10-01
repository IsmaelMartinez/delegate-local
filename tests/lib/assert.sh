#!/usr/bin/env bash
# Shared test helpers (#561), sourced by a tests/test-*.sh file as
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
# and adopted file by file as each one is touched. It sets REPO, SAFE_PATH and
# the pass/fail counters, defines the asserts and the footer, and pins HOME to
# an empty temp dir, so a developer's ~/.local/share/delegate-local
# (config.sh, profile.sh, metrics.jsonl) can neither leak into a test nor be
# written by one. TMPDIR moves under the same dir, so every mktemp a test
# makes, and the drafts/ dir delegate.sh writes beside a mktemp'd metrics
# file, go when the file exits instead of piling up in the system temp dir.
# Not a test file itself: the CI matrix runs tests/test-*.sh.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
pass=0
fail=0

TEST_ROOT=$(mktemp -d)
export HOME="$TEST_ROOT/home" TMPDIR="$TEST_ROOT/tmp"
mkdir -p "$HOME" "$TMPDIR"
_cleanup_paths=("$TEST_ROOT")
# cleanup_on_exit PATH... — removed when the test file exits. Use it rather
# than a trap of your own, which would replace this one.
cleanup_on_exit() { _cleanup_paths+=("$@"); }
trap 'rm -rf "${_cleanup_paths[@]}"' EXIT

assert_eq() {
  if [[ "$1" == "$2" ]]; then echo "  PASS  $3"; pass=$((pass+1))
  else echo "  FAIL  $3 (expected '$1', got '$2')"; fail=$((fail+1)); fi
}
assert_contains() {
  if [[ "$2" == *"$1"* ]]; then echo "  PASS  $3"; pass=$((pass+1))
  else echo "  FAIL  $3 (missing '$1')"; fail=$((fail+1)); fi
}
assert_not_contains() {
  if [[ "$2" != *"$1"* ]]; then echo "  PASS  $3"; pass=$((pass+1))
  else echo "  FAIL  $3 (unexpectedly found '$1')"; fail=$((fail+1)); fi
}
# assert_true NAME CMD... — passes when CMD exits 0.
assert_true() {
  local name="$1"; shift
  if "$@"; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name"; fail=$((fail+1)); fi
}
# assert_false NAME CMD... — passes when CMD exits non-zero.
assert_false() {
  local name="$1"; shift
  if "$@"; then echo "  FAIL  $name"; fail=$((fail+1))
  else echo "  PASS  $name"; pass=$((pass+1)); fi
}

# finish — the footer every file ends with; exits non-zero on any failure.
finish() {
  echo
  echo "$pass passed, $fail failed"
  [[ "$fail" -eq 0 ]]
}

# mock_models_json ID... — the GET {base}/models answer listing those ids.
mock_models_json() {
  local out="" id
  for id in "$@"; do
    [[ -n "$out" ]] && out="$out,"
    out="$out{\"id\":\"${id//\"/\\\"}\",\"object\":\"model\"}"
  done
  printf '{"object":"list","data":[%s]}' "$out"
}

# Every mock curl answers discovery from this list. Tests set MOCK_MODELS
# before building a mock and restore it afterwards.
MOCK_MODELS='qwen3.6:35b-a3b'

# mock_curl DIR [CONTENT] [PAYLOAD_SNIFF] [ARGV_SNIFF] — writes DIR/curl, a
# provider that answers GET {base}/models from $MOCK_MODELS and every other
# call with a chat-completions body whose content is CONTENT (JSON-escaped:
# write \n for a newline; default "mock-model-output: ok\n"). The request
# payload read from stdin goes to PAYLOAD_SNIFF and the argv of the last
# non-discovery call to ARGV_SNIFF as one space-joined line. It honours the
# -o body_file / -w "%{time_starttransfer}" pair delegate.sh uses for TTFB,
# answering a synthetic 0.001 s (queue_wait_ms=1).
mock_curl() {
  local dir="$1" content="${2:-mock-model-output: ok\\n}" sniff="${3:-/dev/null}" argv_sniff="${4:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in */models) printf '%s' '$(mock_models_json $MOCK_MODELS)'; exit 0 ;; esac
done
printf '%s\n' "\$*" > "${argv_sniff}"
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "${sniff}"
body='{"choices":[{"message":{"content":"${content}"},"finish_reason":"stop"}]}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
  chmod +x "$dir/curl"
}
