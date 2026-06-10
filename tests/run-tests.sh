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
  # run <PATH> <cmd...> -> writes stdout to $OUT, stderr to $ERR, sets $EC.
  # HOME is sandboxed to a tmp dir so a real per-user override config in
  # the developer's actual ~/.claude/skills/... can't leak into test runs.
  # If $DELEGATE_LOCAL_CONFIG is set in the parent environment, it is
  # forwarded so override tests can opt in to a specific config path.
  local custom_path="$1"; shift
  local sandbox_home; sandbox_home=$(mktemp -d)
  local extra=(DELEGATE_BACKEND=ollama)
  if [[ -n "${DELEGATE_LOCAL_CONFIG:-}" ]]; then
    extra+=(DELEGATE_LOCAL_CONFIG="$DELEGATE_LOCAL_CONFIG")
  fi
  local err_file; err_file=$(mktemp)
  OUT=$(env -i PATH="$custom_path" HOME="$sandbox_home" ${extra[@]+"${extra[@]}"} "$@" 2>"$err_file") || EC=$?
  EC=${EC:-0}
  ERR=$(cat "$err_file")
  rm -f "$err_file"
  rm -rf "$sandbox_home"
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

# 20b. reasoning tier prefers deepseek-r1 over phi4-reasoning when both are
# installed. Pinned by the 2026-05-03 v6 baseline (deepseek-r1 5/5 vs
# phi4-reasoning 3.33/5 on directive-rule severity classification, same prompt).
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME                  ID SIZE   MODIFIED
deepseek-r1:32b       dd 19 GB  1 day ago
phi4-reasoning:plus   pp 11 GB  1 week ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" reasoning || true
assert_eq "deepseek-r1:32b" "$OUT" "reasoning picks deepseek-r1 ahead of phi4-reasoning"
rm -rf "$tmp"

echo
echo "=== pick-model.sh override (Phase 9) ==="

# 21. Override file reorders prefs: prose normally picks qwen3.6 first, but
# an override that puts gemma4 ahead must win.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3.6:35b-a3b   aa 30 GB  1 day ago
gemma4:latest     yy 9.6 GB 2 weeks ago"
cat > "$tmp/config.sh" <<'EOF'
case "$tier" in
  prose) prefs=("gemma4" "qwen3.6") ;;
esac
EOF
EC=0
DELEGATE_LOCAL_CONFIG="$tmp/config.sh" run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "gemma4:latest" "$OUT" "override reorders prose to gemma4 first"
unset DELEGATE_LOCAL_CONFIG
rm -rf "$tmp"

# 22. Override that only touches one tier leaves other tiers on shipped defaults.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3-coder:30b   xx 30 GB  1 day ago
qwen3.6:35b-a3b   aa 30 GB  1 day ago"
cat > "$tmp/config.sh" <<'EOF'
case "$tier" in
  prose) prefs=("not-installed-model") ;;
esac
EOF
EC=0
DELEGATE_LOCAL_CONFIG="$tmp/config.sh" run "$tmp:$SAFE_PATH" bash "$PICK" code || true
assert_eq "qwen3-coder:30b" "$OUT" "override leaves untouched tiers using shipped defaults"
unset DELEGATE_LOCAL_CONFIG
rm -rf "$tmp"

# 23. Override file absent: defaults resolve exactly as before.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3.6:35b-a3b   aa 30 GB  1 day ago"
EC=0
DELEGATE_LOCAL_CONFIG="$tmp/does-not-exist.sh" run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "missing override file -> shipped defaults still resolve"
unset DELEGATE_LOCAL_CONFIG
rm -rf "$tmp"

# 23b. World-writable override is rejected with a warning; shipped defaults win.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3.6:35b-a3b   aa 30 GB  1 day ago
gemma4:latest     yy 9.6 GB 2 weeks ago"
cat > "$tmp/config.sh" <<'EOF'
case "$tier" in
  prose) prefs=("gemma4" "qwen3.6") ;;
esac
EOF
chmod 666 "$tmp/config.sh"
EC=0
DELEGATE_LOCAL_CONFIG="$tmp/config.sh" run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "world-writable override is ignored, shipped defaults win"
assert_contains "group/world-writable" "$ERR" "world-writable override produces warning on stderr"
unset DELEGATE_LOCAL_CONFIG
rm -rf "$tmp"

# 24. --dry-run surfaces the override in the trace so users can debug it.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3.6:35b-a3b   aa 30 GB  1 day ago
gemma4:latest     yy 9.6 GB 2 weeks ago"
cat > "$tmp/config.sh" <<'EOF'
case "$tier" in
  prose) prefs=("gemma4" "qwen3.6") ;;
esac
EOF
EC=0
DELEGATE_LOCAL_CONFIG="$tmp/config.sh" run "$tmp:$SAFE_PATH" bash "$PICK" --dry-run prose || true
assert_contains "sourcing override:" "$ERR" "dry-run names the override file"
assert_contains "post-override" "$ERR" "dry-run surfaces post-override prefs"
unset DELEGATE_LOCAL_CONFIG
rm -rf "$tmp"

echo
echo "=== scripts/init.sh (Phase 9) ==="

INIT="$SKILL_DIR/scripts/init.sh"

# 25. ollama missing -> exit 1.
EC=0; run "$SAFE_PATH" bash "$INIT" || true
assert_eq "1" "$EC" "init: missing ollama -> exit 1"
assert_contains "ollama not on PATH" "$ERR" "init: missing ollama -> informative stderr"

# 26. Empty model list -> exit 1 with hint.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME  ID  SIZE  MODIFIED"
EC=0; run "$tmp:$SAFE_PATH" bash "$INIT" || true
assert_eq "1" "$EC" "init: empty ollama list -> exit 1"
assert_contains "nothing to personalise" "$ERR" "init: empty list -> hint message"
rm -rf "$tmp"

# 27. With installed models, init prints a valid bash override that, when
# fed back into pick-model.sh, resolves to the same model.
tmp=$(mktemp -d)
make_mock_ollama "$tmp" "NAME              ID SIZE   MODIFIED
qwen3.6:35b-a3b   aa 30 GB  1 day ago
gemma4:latest     yy 9.6 GB 2 weeks ago"
EC=0; run "$tmp:$SAFE_PATH" bash "$INIT" || true
assert_eq "0" "$EC" "init: happy path exits 0"
assert_contains "case \"\$tier\" in" "$OUT" "init: emits a case-on-tier block"
assert_contains "prose) prefs=(" "$OUT" "init: includes prose tier"
# Round-trip: write the generated override and check pick-model still picks
# qwen3.6 for prose (currently-installed-first ordering preserves the win).
echo "$OUT" > "$tmp/config.sh"
EC=0
DELEGATE_LOCAL_CONFIG="$tmp/config.sh" run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "init: round-trip override picks the installed model"
unset DELEGATE_LOCAL_CONFIG
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
echo "=== pick-model.sh: DELEGATE_BACKEND=mlx ==="

# Helper: build a fake HuggingFace hub directory under $1/hub with snapshot
# weights at models--$2--<name>/snapshots/<hash>/ for each <name> in $3..$N.
make_fake_hub() {
  local base="$1" org="$2"; shift 2
  mkdir -p "$base/hub"
  for name in "$@"; do
    local snap="$base/hub/models--${org}--${name}/snapshots/abc123"
    mkdir -p "$snap"
    # An empty snapshot dir is treated as a half-downloaded model and skipped,
    # so drop a sentinel file to signal a complete download.
    touch "$snap/weights.safetensors"
  done
}

# Unknown backend value -> exit 2.
tmp=$(mktemp -d)
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=bogus bash "$PICK" prose 2>&1) || EC=$?
assert_eq "2" "$EC" "DELEGATE_BACKEND=bogus -> exit 2"
assert_contains "unknown backend" "$OUT" "DELEGATE_BACKEND=bogus -> informative stderr"
rm -rf "$tmp"

# MLX with no hub dir -> exit 1.
tmp=$(mktemp -d)
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=mlx HF_HOME="$tmp/nope" bash "$PICK" prose 2>&1) || EC=$?
assert_eq "1" "$EC" "DELEGATE_BACKEND=mlx + missing hub -> exit 1"
assert_contains "MLX hub cache not found" "$OUT" "missing hub -> informative stderr"
rm -rf "$tmp"

# MLX hub with one Qwen3.6 model installed -> prose tier resolves to it.
tmp=$(mktemp -d)
make_fake_hub "$tmp" "mlx-community" "Qwen3.6-35B-A3B-Instruct-4bit"
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=mlx HF_HOME="$tmp" bash "$PICK" prose 2>&1) || EC=$?
assert_eq "0" "$EC" "MLX prose with Qwen3.6 installed -> exit 0"
assert_eq "mlx-community/Qwen3.6-35B-A3B-Instruct-4bit" "$OUT" "MLX prose -> Qwen3.6 model"
rm -rf "$tmp"

# Case-insensitive matching: prefs list uses lowercase 'qwen3.6' but the MLX
# model name carries mixed case. The match should still succeed.
tmp=$(mktemp -d)
make_fake_hub "$tmp" "mlx-community" "Qwen3.6-Reasoner-30B-A3B-8bit"
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=mlx HF_HOME="$tmp" bash "$PICK" prose 2>&1) || EC=$?
assert_eq "mlx-community/Qwen3.6-Reasoner-30B-A3B-8bit" "$OUT" "MLX case-insensitive match"
rm -rf "$tmp"

# MLX hub with only a half-downloaded snapshot -> still treated as no models.
tmp=$(mktemp -d)
mkdir -p "$tmp/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
# snapshot dir exists but is empty (interrupted pull) -> skipped.
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=mlx HF_HOME="$tmp" bash "$PICK" prose 2>&1) || EC=$?
assert_eq "1" "$EC" "MLX empty snapshot -> exit 1"
assert_contains "no models installed" "$OUT" "MLX empty snapshot -> informative stderr"
rm -rf "$tmp"

# MLX hub with multiple models — tier preference order is respected.
# code tier prefers qwen3-coder over qwen3.6, so install both and assert.
tmp=$(mktemp -d)
make_fake_hub "$tmp" "mlx-community" "Qwen3.6-35B-A3B-Instruct-4bit" "Qwen3-Coder-30B-A3B-Instruct-4bit"
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=mlx HF_HOME="$tmp" bash "$PICK" code 2>&1) || EC=$?
assert_eq "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit" "$OUT" "MLX code tier prefers qwen3-coder over qwen3.6"
rm -rf "$tmp"

# Dry-run trace includes the backend line.
tmp=$(mktemp -d)
make_fake_hub "$tmp" "mlx-community" "Qwen3.6-35B-A3B-Instruct-4bit"
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=mlx HF_HOME="$tmp" bash "$PICK" --dry-run prose 2>&1) || EC=$?
assert_contains "backend=mlx" "$OUT" "MLX --dry-run trace surfaces backend"
rm -rf "$tmp"

echo
echo "=== pick-model.sh: DELEGATE_BACKEND=auto (probe) ==="

# Mock-curl helper. Writes a script that exits with the requested status
# regardless of argv — used to simulate "MLX server reachable" (exit 0) and
# "MLX server unreachable" (non-zero). The real pick-model code never reads
# curl's stdout for the probe, only its exit status, so the mock only needs
# to set $?.
make_mock_curl() {
  local dir="$1" exit_code="$2"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
exit ${exit_code}
EOF
  chmod +x "$dir/curl"
}

# auto + reachable MLX -> resolves to mlx and uses the hub-cache resolver.
tmp=$(mktemp -d)
make_mock_curl "$tmp" 0
make_fake_hub "$tmp" "mlx-community" "Qwen3.6-35B-A3B-Instruct-4bit"
EC=0
OUT=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BACKEND=auto HF_HOME="$tmp" \
  bash "$PICK" --dry-run prose 2>&1) || EC=$?
assert_eq "0" "$EC" "auto + curl-ok: exit 0"
assert_contains "backend=auto -> probed MLX_HOST and resolved to 'mlx'" "$OUT" "auto + curl-ok: trace shows mlx resolution"
assert_contains "mlx-community/Qwen3.6-35B-A3B-Instruct-4bit" "$OUT" "auto + curl-ok: uses MLX hub cache"
rm -rf "$tmp"

# auto + unreachable MLX -> resolves to ollama and uses ollama list.
tmp=$(mktemp -d)
make_mock_curl "$tmp" 7  # curl: 7 = couldn't connect
make_mock_ollama "$tmp" "NAME                  ID  SIZE   MODIFIED
qwen3.6:35b-a3b-q8_0  aa  30 GB  1 day ago"
EC=0
OUT=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BACKEND=auto \
  bash "$PICK" --dry-run prose 2>&1) || EC=$?
assert_eq "0" "$EC" "auto + curl-fail: exit 0"
assert_contains "backend=auto -> probed MLX_HOST and resolved to 'ollama'" "$OUT" "auto + curl-fail: trace shows ollama resolution"
assert_contains "qwen3.6:35b-a3b-q8_0" "$OUT" "auto + curl-fail: uses ollama list"
rm -rf "$tmp"

# Default (env var unset) is now auto, not ollama — the trace surfaces the probe.
tmp=$(mktemp -d)
make_mock_curl "$tmp" 7
make_mock_ollama "$tmp" "NAME                  ID  SIZE   MODIFIED
qwen3.6:35b-a3b-q8_0  aa  30 GB  1 day ago"
EC=0
# Note: env -i clears DELEGATE_BACKEND, so this exercises the new auto default.
OUT=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  bash "$PICK" --dry-run prose 2>&1) || EC=$?
assert_eq "0" "$EC" "default (unset) backend: exit 0"
assert_contains "backend=auto -> probed MLX_HOST" "$OUT" "default backend triggers the auto probe"
rm -rf "$tmp"

# Explicit DELEGATE_BACKEND=ollama still skips the probe entirely — the
# probe trace line must NOT appear when the user pinned the backend.
tmp=$(mktemp -d)
# Deliberately no mock curl — if the probe ran, this test would fail anyway
# because curl wouldn't be on PATH. Explicit ollama must not invoke it.
make_mock_ollama "$tmp" "NAME                  ID  SIZE   MODIFIED
qwen3.6:35b-a3b-q8_0  aa  30 GB  1 day ago"
EC=0
OUT=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BACKEND=ollama \
  bash "$PICK" --dry-run prose 2>&1) || EC=$?
assert_eq "0" "$EC" "explicit ollama: exit 0"
case "$OUT" in
  *"backend=auto"*) echo "  FAIL  explicit ollama should not show auto trace"; fail=$((fail+1));;
  *) echo "  PASS  explicit ollama skips the auto probe"; pass=$((pass+1));;
esac
rm -rf "$tmp"

# Updated error message: bogus value must mention auto in the valid set.
tmp=$(mktemp -d)
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" DELEGATE_BACKEND=bogus bash "$PICK" prose 2>&1) || EC=$?
assert_eq "2" "$EC" "DELEGATE_BACKEND=bogus -> exit 2"
assert_contains "valid: auto|ollama|mlx" "$OUT" "bogus error names auto in valid set"
rm -rf "$tmp"

echo
echo "=== no installer-breaking AAIF self-symlink ==="

# Regression guard for the `npx skills add` ENAMETOOLONG failure. A symlink under
# .agents/skills/ that resolves to the repo root makes Vercel's `skills` CLI recurse
# .agents/skills/<name>/.agents/skills/<name>/... forever while it copies the skill,
# dying with ENAMETOOLONG — and it exits 0, so the failure is silent. The skill is
# discovered from the root SKILL.md instead, so no repo-root self-symlink may exist.
SELF_LINK="$SKILL_DIR/.agents/skills/delegate-local"
if [[ -L "$SELF_LINK" ]] && \
   [[ "$(cd "$(dirname "$SELF_LINK")" && cd "$(readlink "$SELF_LINK" 2>/dev/null)" 2>/dev/null && pwd -P)" == "$(cd "$SKILL_DIR" && pwd -P)" ]]; then
  echo "  FAIL  .agents/skills/delegate-local symlinks the repo root (re-creates the npx install recursion)"
  fail=$((fail+1))
else
  echo "  PASS  no repo-root self-symlink under .agents/skills/"
  pass=$((pass+1))
fi
if [[ -f "$SKILL_DIR/SKILL.md" ]]; then
  echo "  PASS  root SKILL.md present (the location the installer copies from)"
  pass=$((pass+1))
else
  echo "  FAIL  root SKILL.md missing"
  fail=$((fail+1))
fi

echo
echo "=== Results ==="
total=$((pass+fail))
echo "$pass/$total passed"
[[ "$fail" -eq 0 ]]
