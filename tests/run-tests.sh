#!/usr/bin/env bash
# Unit tests for pick-model.sh and audit-models.sh.
# Uses mock `ollama` and `llmfit` binaries on a restricted PATH so the
# tests run the same everywhere regardless of what's installed.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICK="$SKILL_DIR/scripts/pick-model.sh"
AUDIT="$SKILL_DIR/scripts/audit-models.sh"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

pass=0
fail=0

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS  $name"
    pass=$((pass+1))
  else
    echo "  FAIL  $name"
    echo "        expected: '$expected'"
    echo "        actual:   '$actual'"
    fail=$((fail+1))
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS  $name"
    pass=$((pass+1))
  else
    echo "  FAIL  $name"
    echo "        expected substring: '$needle'"
    echo "        in: '$haystack'"
    fail=$((fail+1))
  fi
}

# Create a mock `ollama` binary at $1/ollama that prints the given list body ($2)
# when called with `ollama list`. Other args no-op with exit 0.
make_mock_ollama() {
  local dir="$1" list_body="$2"
  cat > "$dir/ollama" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
  cat <<'LIST'
$list_body
LIST
fi
EOF
  chmod +x "$dir/ollama"
}

# pick-model.sh does not need llmfit, but audit-models.sh does. Keep a simple stub.
make_mock_llmfit() {
  local dir="$1"
  cat > "$dir/llmfit" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: any `recommend --json` prints an empty model list.
if [[ "$*" == *--json* ]]; then echo '{"models":[]}'; else echo ""; fi
EOF
  chmod +x "$dir/llmfit"
}

run() {
  # run <PATH> <cmd...> -> writes stdout to $OUT, stderr to $ERR, sets $EC
  local custom_path="$1"; shift
  OUT=$(env -i PATH="$custom_path" HOME="$HOME" "$@" 2>/tmp/.delegate-ollama-test.err) || EC=$?
  EC=${EC:-0}
  ERR=$(cat /tmp/.delegate-ollama-test.err)
  rm -f /tmp/.delegate-ollama-test.err
}

echo "=== pick-model.sh ==="

# 1. Missing argument -> usage error (exit 2).
tmp=$(mktemp -d)
EC=0; run "$SAFE_PATH" bash "$PICK" || true
assert_eq "2" "$EC" "no args exits 2"
rm -rf "$tmp"

# 2. Unknown tier -> exit 2.
EC=0; run "$SAFE_PATH" bash "$PICK" bogus || true
assert_eq "2" "$EC" "unknown tier exits 2"

# 3. ollama missing -> exit 1 with clear message.
EC=0; run "$SAFE_PATH" bash "$PICK" code || true
assert_eq "1" "$EC" "missing ollama -> exit 1"
assert_contains "ollama not on PATH" "$ERR" "missing ollama -> informative stderr"

# 4. Empty model list -> exit 1.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME  ID  SIZE  MODIFIED"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" code || true
assert_eq "1" "$EC" "empty ollama list -> exit 1"
rm -rf "$tmp"

# 5. Code tier with coder installed returns it.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                      ID SIZE   MODIFIED
qwen3-coder:30b-a3b-q8_0  xx 32 GB  2 weeks ago
gemma4:latest             yy 9.6 GB 2 weeks ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" code || true
assert_eq "0" "$EC" "code tier exits 0"
assert_eq "qwen3-coder:30b-a3b-q8_0" "$OUT" "code tier picks qwen3-coder"
rm -rf "$tmp"

# 6. Prose tier with only gemma4 falls back to gemma4.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME           ID SIZE   MODIFIED
gemma4:latest  yy 9.6 GB 2 weeks ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "gemma4:latest" "$OUT" "prose falls to gemma4 when no qwen3.6"
rm -rf "$tmp"

# 7. Prose tier prefers qwen3.6 when installed (the new preference).
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3.6:35b-a3b   aa 30 GB  1 day ago
gemma4:latest     yy 9.6 GB 2 weeks ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "prose picks qwen3.6 when installed"
rm -rf "$tmp"

# 7b. Prose tier prefers qwen3.6 over qwen3-next when both are installed.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                              ID SIZE   MODIFIED
qwen3.6:35b-a3b                   aa 30 GB  1 day ago
qwen3-next:80b-a3b-instruct-q8_0  bb 84 GB  1 week ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "prose picks qwen3.6 ahead of qwen3-next"
rm -rf "$tmp"

# 8. No preference match -> exit 1 (do NOT return an arbitrary fallback).
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME               ID SIZE  MODIFIED
unrelated:model    zz 5 GB  1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" code || true
assert_eq "1" "$EC" "no match -> exit 1"
rm -rf "$tmp"

# 9. long-context tier prefers qwen3.6 when available.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME            ID SIZE  MODIFIED
qwen3.6:35b-a3b aa 30 GB 1 day ago
llama4:scout    bb 67 GB 2 weeks ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" long-context || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "long-context picks qwen3.6 first"
rm -rf "$tmp"

# 10. --dry-run with a matching install: stdout = model, stderr has the trace.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3.6:35b-a3b   aa 30 GB  1 day ago
gemma4:latest     yy 9.6 GB 2 weeks ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" --dry-run prose || true
assert_eq "0" "$EC" "dry-run match -> exit 0"
assert_eq "qwen3.6:35b-a3b" "$OUT" "dry-run match -> stdout still has model"
assert_contains "dry-run: tier=prose" "$ERR" "dry-run match -> stderr has tier line"
assert_contains "dry-run: matched preference='qwen3.6'" "$ERR" "dry-run match -> stderr names matched preference"
rm -rf "$tmp"

# 11. --dry-run with no matching install: exit 1, stderr explains why.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME            ID SIZE  MODIFIED
unrelated:model zz 5 GB  1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" --dry-run code || true
assert_eq "1" "$EC" "dry-run no match -> exit 1"
assert_contains "no preference matched any installed model" "$ERR" "dry-run no match -> stderr explains why"
rm -rf "$tmp"

# 12. --dry-run without a tier arg: usage error (exit 2).
EC=0; run "$SAFE_PATH" bash "$PICK" --dry-run || true
assert_eq "2" "$EC" "dry-run no tier -> exit 2"
assert_contains "usage:" "$ERR" "dry-run no tier -> usage on stderr"

# 13. Unknown flag: usage error (exit 2) with informative stderr.
EC=0; run "$SAFE_PATH" bash "$PICK" --bogus prose || true
assert_eq "2" "$EC" "unknown flag -> exit 2"
assert_contains "unknown option: --bogus" "$ERR" "unknown flag -> stderr names the bad option"

echo
echo "=== audit-models.sh ==="

# A. ollama missing -> exit 1.
EC=0; run "$SAFE_PATH" bash "$AUDIT" || true
assert_eq "1" "$EC" "audit: missing ollama -> exit 1"

# B. ollama present, llmfit missing -> graceful skip, exit 0.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME             ID SIZE  MODIFIED
qwen3-coder:30b  xx 30 GB 1 day ago
gemma4:latest    yy 9 GB  1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$AUDIT" || true
assert_eq "0" "$EC" "audit: no llmfit -> exit 0"
assert_contains "Upgrade check skipped" "$OUT" "audit: no llmfit -> skip message"
rm -rf "$tmp"

# (The "no jq" path is hard to simulate portably since macOS 15+ ships
# /usr/bin/jq. The graceful-exit check in audit-models.sh is exercised by
# code review instead.)

echo
echo "=== Results ==="
total=$((pass+fail))
echo "$pass/$total passed"
[[ "$fail" -eq 0 ]]
