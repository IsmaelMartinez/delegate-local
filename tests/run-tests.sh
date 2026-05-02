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

# 14. vision tier picks qwen3-vl thinking model when installed.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                          ID SIZE   MODIFIED
qwen3-vl:30b-a3b-thinking     vv 25 GB  1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" vision || true
assert_eq "qwen3-vl:30b-a3b-thinking" "$OUT" "vision picks qwen3-vl thinking variant"
rm -rf "$tmp"

# 15. embedding tier picks nomic-embed-text when installed.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                ID SIZE   MODIFIED
nomic-embed-text    nn 137 MB 1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" embedding || true
assert_eq "nomic-embed-text" "$OUT" "embedding picks nomic-embed-text"
rm -rf "$tmp"

# 16. embedding tier falls back to bge-large when nomic absent.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME       ID SIZE   MODIFIED
bge-large  bb 335 MB 1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" embedding || true
assert_eq "bge-large" "$OUT" "embedding falls back to bge-large"
rm -rf "$tmp"

# 17. premium-general tier picks qwen3.5 122b variant when installed.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                       ID SIZE    MODIFIED
qwen3.5:122b-a10b-q4_K_M   pp 70 GB   1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" premium-general || true
assert_eq "qwen3.5:122b-a10b-q4_K_M" "$OUT" "premium-general picks qwen3.5:122b"
rm -rf "$tmp"

# 18. premium-general does NOT silently downshift to qwen3.5:27b.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME         ID SIZE  MODIFIED
qwen3.5:27b  qq 17 GB 1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" premium-general || true
assert_eq "1" "$EC" "premium-general -> exit 1 when only smaller qwen3.5 installed"
rm -rf "$tmp"

# 19. reasoning-vision picks phi4-reasoning-vision when installed.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                       ID SIZE   MODIFIED
phi4-reasoning-vision:15b  rv 11 GB  1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" reasoning-vision || true
assert_eq "phi4-reasoning-vision:15b" "$OUT" "reasoning-vision picks phi4-reasoning-vision"
rm -rf "$tmp"

# 20. reasoning-vision falls back to qwen3-vl thinking when phi4 absent.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                       ID SIZE   MODIFIED
qwen3-vl:30b-a3b-thinking  vv 25 GB  1 day ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" reasoning-vision || true
assert_eq "qwen3-vl:30b-a3b-thinking" "$OUT" "reasoning-vision falls back to qwen3-vl thinking"
rm -rf "$tmp"

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
echo "=== AAIF symlink ==="

# AAIF compliance: .agents/skills/delegate-to-ollama must be a symlink to the
# repo root, not a regular file or directory copy. Catches the case where a
# Windows-without-symlinks checkout (or an accidental `cp -L`) replaces the
# entry with a regular file containing the literal string "../..".
AAIF_LINK="$SKILL_DIR/.agents/skills/delegate-to-ollama"
if [[ -L "$AAIF_LINK" ]]; then
  echo "  PASS  AAIF entry is a symlink"
  pass=$((pass+1))
else
  echo "  FAIL  AAIF entry is not a symlink (path: $AAIF_LINK)"
  fail=$((fail+1))
fi
if [[ -f "$AAIF_LINK/SKILL.md" ]]; then
  echo "  PASS  AAIF symlink resolves to a directory containing SKILL.md"
  pass=$((pass+1))
else
  echo "  FAIL  $AAIF_LINK/SKILL.md does not resolve"
  fail=$((fail+1))
fi

echo
echo "=== Results ==="
total=$((pass+fail))
echo "$pass/$total passed"
[[ "$fail" -eq 0 ]]
