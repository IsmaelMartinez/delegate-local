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

# Mock curl answering GET {base}/models with an OpenAI models list. $2 is a
# space-separated "port:id,id" spec; a port absent from the spec exits 7
# (connection refused) so a dead provider can be simulated without binding a
# socket, and a port with an empty id list answers with an empty data array so
# "reachable but serving nothing" is distinguishable from "unreachable".
# Discovery is the only thing pick-model.sh curls, so this mock needs no
# chat-completions arm.
make_mock_provider() {
  local dir="$1" spec="$2"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
port=\$(printf '%s' "\$url" | sed -n 's|.*://[^:/]*:\([0-9]*\).*|\1|p')
for entry in ${spec}; do
  p="\${entry%%:*}"; ids="\${entry#*:}"
  if [[ "\$p" == "\$port" ]]; then
    printf '{"object":"list","data":['
    if [[ -n "\$ids" ]]; then
      first=1
      IFS=, read -ra arr <<< "\$ids"
      for id in "\${arr[@]}"; do
        if (( first == 0 )); then printf ','; fi
        printf '{"id":"%s","object":"model"}' "\$id"
        first=0
      done
    fi
    printf ']}'
    exit 0
  fi
done
exit 7
EOF
  chmod +x "$dir/curl"
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
  # One provider, on Ollama's port, so a mock built by make_mock_provider with
  # an "1:..." spec answers it. Tests that install no mock get a real curl
  # against a closed port, which refuses instantly rather than resolving DNS.
  local extra=(DELEGATE_BASE_URL=http://localhost:1/v1)
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

# 3. No provider answering -> exit 1 with clear message.
EC=0; run "$SAFE_PATH" bash "$PICK" code || true
assert_eq "1" "$EC" "no provider reachable -> exit 1"
assert_contains "no provider is reachable" "$ERR" "no provider reachable -> informative stderr"

# 4. Empty model list -> exit 1.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" code || true
assert_eq "1" "$EC" "provider serving nothing -> exit 1"
rm -rf "$tmp"

# 5. Code tier with coder installed returns it.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3-coder:30b-a3b-q8_0,gemma4:latest"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" code || true
assert_eq "0" "$EC" "code tier exits 0"
assert_eq "qwen3-coder:30b-a3b-q8_0" "$OUT" "code tier picks qwen3-coder"
rm -rf "$tmp"

# 6. Prose tier with only gemma4 falls back to gemma4.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:gemma4:latest"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "gemma4:latest" "$OUT" "prose falls to gemma4 when no qwen3.6"
rm -rf "$tmp"

# 7. Prose tier prefers qwen3.6 when installed (the new preference).
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,gemma4:latest"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "prose picks qwen3.6 when installed"
rm -rf "$tmp"

# 7b. Prose tier prefers qwen3.6 over qwen3-next when both are installed.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,qwen3-next:80b-a3b-instruct-q8_0"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "prose picks qwen3.6 ahead of qwen3-next"
rm -rf "$tmp"

# 8. No preference match -> exit 1 (do NOT return an arbitrary fallback).
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:unrelated:model"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" code || true
assert_eq "1" "$EC" "no match -> exit 1"
rm -rf "$tmp"

# 9. long-context tier prefers qwen3.6 when available.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,llama4:scout"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" long-context || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "long-context picks qwen3.6 first"
rm -rf "$tmp"

# 10. --dry-run with a matching install: stdout = model, stderr has the trace.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,gemma4:latest"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" --dry-run prose || true
assert_eq "0" "$EC" "dry-run match -> exit 0"
assert_eq "qwen3.6:35b-a3b" "$OUT" "dry-run match -> stdout still has model"
assert_contains "dry-run: tier=prose" "$ERR" "dry-run match -> stderr has tier line"
assert_contains "matched preference='qwen3.6'" "$ERR" "dry-run match -> stderr names matched preference"
rm -rf "$tmp"

# 11. --dry-run with no matching install: exit 1, stderr explains why.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:unrelated:model"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" --dry-run code || true
assert_eq "1" "$EC" "dry-run no match -> exit 1"
assert_contains "no model matches this tier" "$ERR" "dry-run no match -> stderr explains why"
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
make_mock_provider "$tmp" "1:qwen3-vl:30b-a3b-thinking"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" vision || true
assert_eq "qwen3-vl:30b-a3b-thinking" "$OUT" "vision picks qwen3-vl thinking variant"
rm -rf "$tmp"

# 15. embedding tier picks nomic-embed-text when installed.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:nomic-embed-text"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" embedding || true
assert_eq "nomic-embed-text" "$OUT" "embedding picks nomic-embed-text"
rm -rf "$tmp"

# 16. embedding tier falls back to bge-large when nomic absent.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:bge-large"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" embedding || true
assert_eq "bge-large" "$OUT" "embedding falls back to bge-large"
rm -rf "$tmp"

# 17. premium-general tier picks qwen3.5 122b variant when installed.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.5:122b-a10b-q4_K_M"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" premium-general || true
assert_eq "qwen3.5:122b-a10b-q4_K_M" "$OUT" "premium-general picks qwen3.5:122b"
rm -rf "$tmp"

# 18. premium-general does NOT silently downshift to qwen3.5:27b.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.5:27b"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" premium-general || true
assert_eq "1" "$EC" "premium-general -> exit 1 when only smaller qwen3.5 installed"
rm -rf "$tmp"

# 19. reasoning-vision picks phi4-reasoning-vision when installed.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:phi4-reasoning-vision:15b"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" reasoning-vision || true
assert_eq "phi4-reasoning-vision:15b" "$OUT" "reasoning-vision picks phi4-reasoning-vision"
rm -rf "$tmp"

# 20. reasoning-vision falls back to qwen3-vl thinking when phi4 absent.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3-vl:30b-a3b-thinking"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" reasoning-vision || true
assert_eq "qwen3-vl:30b-a3b-thinking" "$OUT" "reasoning-vision falls back to qwen3-vl thinking"
rm -rf "$tmp"

# 20b. reasoning tier prefers deepseek-r1 over phi4-reasoning when both are
# installed. Pinned by the 2026-05-03 v6 baseline (deepseek-r1 5/5 vs
# phi4-reasoning 3.33/5 on directive-rule severity classification, same prompt).
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:deepseek-r1:32b,phi4-reasoning:plus"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" reasoning || true
assert_eq "deepseek-r1:32b" "$OUT" "reasoning picks deepseek-r1 ahead of phi4-reasoning"
rm -rf "$tmp"

echo
echo "=== pick-model.sh override (Phase 9) ==="

# 21. Override file reorders prefs: prose normally picks qwen3.6 first, but
# an override that puts gemma4 ahead must win.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,gemma4:latest"
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
make_mock_provider "$tmp" "1:qwen3-coder:30b,qwen3.6:35b-a3b"
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
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b"
EC=0
DELEGATE_LOCAL_CONFIG="$tmp/does-not-exist.sh" run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "qwen3.6:35b-a3b" "$OUT" "missing override file -> shipped defaults still resolve"
unset DELEGATE_LOCAL_CONFIG
rm -rf "$tmp"

# 23b. World-writable override is rejected with a warning; shipped defaults win.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,gemma4:latest"
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
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,gemma4:latest"
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

# 25. No provider reachable -> exit 1 with hint.
EC=0; run "$SAFE_PATH" bash "$INIT" || true
assert_eq "1" "$EC" "init: no provider reachable -> exit 1"
assert_contains "nothing to personalise" "$ERR" "init: no provider reachable -> hint message"

# 26. Provider reachable but serving nothing -> exit 1 with the same hint.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:"
EC=0; run "$tmp:$SAFE_PATH" bash "$INIT" || true
assert_eq "1" "$EC" "init: empty provider list -> exit 1"
assert_contains "nothing to personalise" "$ERR" "init: empty list -> hint message"
rm -rf "$tmp"

# 27. With installed models, init prints a valid bash override that, when
# fed back into pick-model.sh, resolves to the same model.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b,gemma4:latest"
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

# A. Nothing reachable is a report, not a failure: the audit is what a user
# runs to find out why delegation stopped working.
tmp=$(mktemp -d)
make_mock_provider "$tmp" ""
EC=0; run "$tmp:$SAFE_PATH" bash "$AUDIT" || true
assert_eq "0" "$EC" "audit: no provider reachable -> exit 0"
assert_contains "unreachable" "$OUT" "audit: no provider reachable -> marks the provider unreachable"
rm -rf "$tmp"

# B. Provider present, llmfit missing -> graceful skip, exit 0.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3-coder:30b,gemma4:latest"
EC=0; run "$tmp:$SAFE_PATH" bash "$AUDIT" || true
assert_eq "0" "$EC" "audit: no llmfit -> exit 0"
assert_contains "Upgrade check skipped" "$OUT" "audit: no llmfit -> skip message"
rm -rf "$tmp"

# (The "no jq" path is hard to simulate portably since macOS 15+ ships
# /usr/bin/jq. The graceful-exit check in audit-models.sh is exercised by
# code review instead.)

echo
echo "=== pick-model.sh: --print-providers / --print-installed ==="

# Both surfaces answer without a tier argument — a caller asking "which
# providers are in effect?" has no tier to name.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b-q8_0,gemma4:latest"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" --print-providers || true
assert_eq "0" "$EC" "--print-providers exits 0 without a tier"
assert_eq "http://localhost:1/v1" "$OUT" "--print-providers prints the pinned list"

EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" --print-installed || true
assert_eq "0" "$EC" "--print-installed exits 0 without a tier"
assert_eq "gemma4:latest
qwen3.6:35b-a3b-q8_0" "$OUT" "--print-installed lists what the provider serves"
rm -rf "$tmp"

# The default list is built from the host variables, not from literal ports:
# hardcoding them would make a non-default port or a remote daemon unreachable
# while silently reporting localhost as the target.
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" \
  MLX_HOST=http://mlx.test:1234 \
  DOCKER_MODEL_HOST=http://docker.test:2345 \
  OLLAMA_HOST=http://ollama.test:3456 \
  bash "$PICK" --print-providers 2>/dev/null) || EC=$?
assert_eq "http://mlx.test:1234/v1
http://docker.test:2345/engines/v1
http://ollama.test:3456/v1" "$OUT" "--print-providers honours MLX_HOST / DOCKER_MODEL_HOST / OLLAMA_HOST"

# The shipped default, with no host variables set at all.
EC=0
OUT=$(env -i PATH="$SAFE_PATH" HOME="$tmp" bash "$PICK" --print-providers 2>/dev/null) || EC=$?
assert_eq "http://localhost:8080/v1
http://localhost:12434/engines/v1
http://localhost:11434/v1" "$OUT" "--print-providers defaults to MLX, Docker Model Runner, Ollama in that order"

# Nothing reachable is reported as such. Collapsing it into "no provider holds
# a model for this tier" sent debugging after a model pull on a host where the
# real problem was that no daemon was running.
tmp=$(mktemp -d)
make_mock_provider "$tmp" ""
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "1" "$EC" "no provider reachable -> exit 1"
assert_contains "no provider is reachable" "$ERR" "no provider reachable -> says so"
rm -rf "$tmp"

# Reachable but holding nothing this tier wants is the other failure, and it
# needs the opposite remedy.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:unrelated:model"
EC=0; run "$tmp:$SAFE_PATH" bash "$PICK" prose || true
assert_eq "1" "$EC" "reachable but no tier match -> exit 1"
assert_contains "no provider holds a model for tier 'prose'" "$ERR" "reachable but no tier match -> names the tier"
rm -rf "$tmp"

echo
echo "=== audit-models.sh: provider awareness ==="

# The audit has to name the providers it is reporting on: printing one
# daemon's inventory on a host whose routing consulted another sent debugging
# at the wrong model set (issue #344).
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3-coder:30b"
EC=0; run "$tmp:$SAFE_PATH" bash "$AUDIT" || true
assert_eq "0" "$EC" "audit: reachable provider -> exit 0"
assert_contains "reachable" "$OUT" "audit: reports provider reachability"
assert_contains "qwen3-coder:30b" "$OUT" "audit: inventory is what the provider serves"
assert_contains "reasoning-vision" "$OUT" "audit: routing table covers the scaffolded tiers"
rm -rf "$tmp"

# A host with no ollama binary at all still gets a full routing report instead
# of an early exit 1: nothing on the routing path needs the CLI any more.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:qwen3.6:35b-a3b-q8_0"
EC=0; run "$tmp:$SAFE_PATH" bash "$AUDIT" || true
assert_eq "0" "$EC" "audit: no ollama binary -> exit 0"
assert_contains "prose" "$OUT" "audit: still prints tier routing without the ollama CLI"
assert_contains "Upgrade check skipped" "$OUT" "audit: no ollama -> llmfit cross-check skipped, not fatal"
rm -rf "$tmp"

# The embedding tier carries no special case any more: it resolves against the
# same list as every other tier, to whichever provider serves an embedding
# model. The audit used to pin it to Ollama and label it, which was a
# display-layer patch over a routing-layer fact (issue #357).
tmp=$(mktemp -d)
make_mock_provider "$tmp" "1:nomic-embed-text:v1.5"
EC=0; run "$tmp:$SAFE_PATH" bash "$AUDIT" || true
assert_contains "nomic-embed-text" "$OUT" "audit: embedding tier resolves like any other tier"
assert_absent_out() { case "$OUT" in *"$1"*) echo "  FAIL  $2"; fail=$((fail+1));; *) echo "  PASS  $2"; pass=$((pass+1));; esac; }
assert_absent_out "embed.sh pins it" "audit: no per-tier provider pin is advertised"
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
echo "=== commit-message body-drop bench (wiring smoke — no model contact) ==="

# This is a deliberately OFFLINE smoke: it never runs the bench (which would
# contact a model). It only proves the bench stays wired to its fixtures and
# its scorer matches production. The live, model-driven gate is opt-in:
#   BENCH_GATE=1 BENCH_BACKENDS="mlx ollama" bash tests/bench-commit-message-body.sh
# run by a human / CI with a model — see docs/adr/0026-*.md.
BENCH="$SKILL_DIR/tests/bench-commit-message-body.sh"
CM_FIX="$SKILL_DIR/tests/fixtures/commit-message"

if bash -n "$BENCH" 2>/dev/null; then
  echo "  PASS  bench script is syntactically valid"
  pass=$((pass+1))
else
  echo "  FAIL  bench script has a syntax error"
  fail=$((fail+1))
fi

# Shared anchors + >=6 thin diffs + a rich control, each with a paired .why.
diff_count=0
for d in "$CM_FIX"/*.diff; do [[ -f "$d" ]] && diff_count=$((diff_count+1)); done
if [[ -f "$CM_FIX/recent_commits.txt" && "$diff_count" -ge 7 ]]; then
  echo "  PASS  bench fixtures present ($diff_count diffs + recent_commits.txt)"
  pass=$((pass+1))
else
  echo "  FAIL  bench fixtures missing (found $diff_count diffs, want >=7 + recent_commits.txt)"
  fail=$((fail+1))
fi

missing_why=0
for d in "$CM_FIX"/*.diff; do [[ -f "${d%.diff}.why" ]] || missing_why=$((missing_why+1)); done
assert_eq "0" "$missing_why" "every bench .diff has a paired .why"

# Unit-test the ACTUAL score_body from the bench (single source of truth) without
# running the bench: grab its one-line definition and eval it here.
eval "$(grep -E '^score_body\(\) ' "$BENCH")"
if score_body "$(printf 'subject line\n\nbody paragraph')"; then
  echo "  PASS  score_body accepts a subject+body (>=2 non-empty lines)"
  pass=$((pass+1))
else
  echo "  FAIL  score_body rejected a valid subject+body"
  fail=$((fail+1))
fi
if score_body "only-a-subject"; then
  echo "  FAIL  score_body accepted a subject-only message"
  fail=$((fail+1))
else
  echo "  PASS  score_body rejects a subject-only message (the body-drop shape)"
  pass=$((pass+1))
fi

echo
echo "=== doc-section padding bench (wiring smoke — no model contact) ==="

# Offline smoke for tests/bench-doc-section-padding.sh: never runs the bench
# (which would contact a model). The live gate is opt-in:
#   BENCH_GATE=1 BENCH_BACKENDS="mlx ollama" bash tests/bench-doc-section-padding.sh
DSBENCH="$SKILL_DIR/tests/bench-doc-section-padding.sh"
DS_FIX="$SKILL_DIR/tests/fixtures/doc-section"

if bash -n "$DSBENCH" 2>/dev/null; then
  echo "  PASS  doc-section bench is syntactically valid"
  pass=$((pass+1))
else
  echo "  FAIL  doc-section bench has a syntax error"
  fail=$((fail+1))
fi

ds_count=0
for f in "$DS_FIX"/*.txt; do [[ -f "$f" ]] && ds_count=$((ds_count+1)); done
if [[ "$ds_count" -ge 6 ]]; then
  echo "  PASS  doc-section fixtures present ($ds_count topic files)"
  pass=$((pass+1))
else
  echo "  FAIL  doc-section fixtures missing (found $ds_count, want >=6)"
  fail=$((fail+1))
fi

# Unit-test the bench's OWN scorers without running the bench: extract padding_re
# from delegate.sh (the same source the bench reads) and the two scorer functions
# from the bench, then exercise them on a known recap vs a clean paragraph. Guard
# the extraction: if any grep finds nothing (bench renamed / pattern drift), fail
# this check cleanly instead of erroring on an undefined function below.
eval "$(grep -E '^[[:space:]]*padding_re=' "$SKILL_DIR/scripts/delegate.sh" | head -1)"
eval "$(grep -E '^has_padding\(\) ' "$DSBENCH")"
eval "$(grep -E '^count_sentences\(\) ' "$DSBENCH")"
if [[ -n "${padding_re:-}" ]] && command -v has_padding >/dev/null 2>&1 && command -v count_sentences >/dev/null 2>&1; then
  ds_recap="One sentence of guidance. Consequently, this is strictly opt-in and should be avoided."
  ds_clean="One sentence of guidance. The four knobs are enforced via CI env vars that override the TOML."
  if has_padding "$ds_recap"; then
    echo "  PASS  has_padding flags a closing-recap sentence"
    pass=$((pass+1))
  else
    echo "  FAIL  has_padding missed a closing-recap sentence"
    fail=$((fail+1))
  fi
  if has_padding "$ds_clean"; then
    echo "  FAIL  has_padding false-positived a clean paragraph"
    fail=$((fail+1))
  else
    echo "  PASS  has_padding passes a clean paragraph"
    pass=$((pass+1))
  fi
  assert_eq "3" "$(count_sentences 'a. b! c?')" "count_sentences counts terminal punctuation"
else
  echo "  FAIL  could not extract padding_re / has_padding / count_sentences (bench drifted?)"
  fail=$((fail+1))
fi

echo "=== pick-model.sh: DELEGATE_BASE_URL provider list ==="

# The first reachable provider holding a tier match wins.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:mlx-community/Qwen3.6-35B-A3B-8bit 11434:qwen3.6-ollama"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:8080/v1 http://localhost:11434/v1" \
  bash "$PICK" prose 2>/dev/null)
assert_eq "mlx-community/Qwen3.6-35B-A3B-8bit" "$got" "provider list: first provider wins"
rm -rf "$tmp"

# An unreachable first provider is skipped, not fatal. This is the case that
# regresses if the probe is written as a bare assignment under set -e.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "11434:qwen3.6-ollama"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:11434/v1" \
  bash "$PICK" prose 2>/dev/null)
assert_eq "qwen3.6-ollama" "$got" "provider list: falls through an unreachable provider"
rm -rf "$tmp"

# Reachable but holding no model for this tier is also a skip.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:nomic-embed-text 11434:qwen3.6-ollama"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:8080/v1 http://localhost:11434/v1" \
  bash "$PICK" prose 2>/dev/null)
assert_eq "qwen3.6-ollama" "$got" "provider list: falls through a provider with no tier match"
rm -rf "$tmp"

# Every provider unreachable -> exit 1.
tmp=$(mktemp -d)
make_mock_provider "$tmp" ""
EC=0
env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:8/v1" \
  bash "$PICK" prose >/dev/null 2>&1 || EC=$?
assert_eq "1" "$EC" "provider list: all providers unreachable exits 1"
rm -rf "$tmp"

# The dry-run trace names the provider it skipped, so a misconfigured list is
# diagnosable without a packet capture.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "11434:qwen3.6-ollama"
trace=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:11434/v1" \
  bash "$PICK" --dry-run prose 2>&1)
assert_contains "localhost:9" "$trace" "provider list: trace names the skipped provider"
rm -rf "$tmp"

# Sorting the reported ids makes a two-match preference deterministic; daemon
# ordering is not stable (ollama list is recency-ordered).
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:qwen3.6-b,qwen3.6-a"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:8080/v1" \
  bash "$PICK" prose 2>/dev/null)
assert_eq "qwen3.6-a" "$got" "provider list: sorted ids make two matches deterministic"
rm -rf "$tmp"

# --print-resolution returns base and model in one call, so delegate.sh probes
# a dead provider once rather than once per question.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:mlx-community/Qwen3.6-35B-A3B-8bit"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:8080/v1" \
  bash "$PICK" --print-resolution prose 2>/dev/null)
assert_eq "http://localhost:8080/v1	mlx-community/Qwen3.6-35B-A3B-8bit" "$got" \
  "provider list: --print-resolution returns base and model"
rm -rf "$tmp"

# One trailing slash is stripped so the base never doubles up.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:mlx-community/Qwen3.6-35B-A3B-8bit"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:8080/v1/" \
  bash "$PICK" --print-resolution prose 2>/dev/null)
assert_eq "http://localhost:8080/v1	mlx-community/Qwen3.6-35B-A3B-8bit" "$got" \
  "provider list: one trailing slash is stripped"
rm -rf "$tmp"

# A userinfo URL is rejected before any request leaves the process: it would
# otherwise reach the metrics label and the dry-run trace.
tmp=$(mktemp -d)
cat > "$tmp/curl" <<'EOF'
#!/usr/bin/env bash
echo "MOCK CURL WAS CALLED" >&2
exit 0
EOF
chmod +x "$tmp/curl"
EC=0
err=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://user:pass@localhost:8080/v1" \
  bash "$PICK" prose 2>&1) || EC=$?
assert_eq "2" "$EC" "provider list: userinfo URL exits 2"
case "$err" in
  *"MOCK CURL WAS CALLED"*) assert_eq "no request" "a request was made" "provider list: userinfo rejected before any request" ;;
  *) assert_eq "no request" "no request" "provider list: userinfo rejected before any request" ;;
esac
rm -rf "$tmp"

# --print-installed reports what the providers serve, not an HF cache scan.
# Without the provider arm the "provider" backend label falls through to the
# MLX arm and this surface silently reports a set routing never consults.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "8080:mlx-a,mlx-b 11434:ollama-a"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:8080/v1 http://localhost:11434/v1" \
  bash "$PICK" --print-installed 2>/dev/null | tr '\n' ' ')
assert_eq "mlx-a mlx-b ollama-a " "$got" "provider list: --print-installed unions the providers"
rm -rf "$tmp"

# An unreachable provider is skipped by --print-installed too, rather than
# aborting the listing under set -e.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "11434:ollama-a"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  DELEGATE_BASE_URL="http://localhost:9/v1 http://localhost:11434/v1" \
  bash "$PICK" --print-installed 2>/dev/null | tr '\n' ' ')
assert_eq "ollama-a " "$got" "provider list: --print-installed skips an unreachable provider"
rm -rf "$tmp"

# --print-resolution needs no explicit list: the default is a real list, so
# the flag answers from it. This is the assertion that fails if the default is
# ever taken back out.
tmp=$(mktemp -d)
make_mock_provider "$tmp" "11434:qwen3.6-ollama"
got=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$tmp" \
  bash "$PICK" --print-resolution prose 2>/dev/null)
assert_eq "http://localhost:11434/v1	qwen3.6-ollama" "$got" \
  "provider list: --print-resolution answers from the default list"
rm -rf "$tmp"

# Structural guard for the deletion. The native /api/generate arm and
# DELEGATE_BACKEND are both easy to reintroduce by copy-paste from git
# history, and a reintroduced arm is invisible to behavioural tests for as
# long as the OpenAI arm keeps working. The file list is explicit rather than
# a tree walk: scripts/eval-skill-triggers.sh still posts to /api/generate and
# is tracked separately, and scripts/metrics-summary.sh names DELEGATE_BACKEND
# in a comment about pre-2026-05 metrics rows that really were written that
# way.
leftovers=$(grep -l 'api/generate\|DELEGATE_BACKEND' \
  "$SKILL_DIR/scripts/delegate.sh" "$SKILL_DIR/scripts/pick-model.sh" \
  "$SKILL_DIR/scripts/embed.sh" "$SKILL_DIR/scripts/audit-models.sh" 2>/dev/null || true)
assert_eq "" "$leftovers" "dispatch path: no /api/generate arm and no DELEGATE_BACKEND left"

echo
echo "=== Results ==="
total=$((pass+fail))
echo "$pass/$total passed"
[[ "$fail" -eq 0 ]]
