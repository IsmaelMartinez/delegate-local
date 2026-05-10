#!/usr/bin/env bash
# Unit tests for scripts/delegate.sh.
# Mocks `ollama list` (used by pick-model.sh) and `curl` (used to call
# /api/generate) on a restricted PATH so the test runs the same everywhere.

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
# Mock ollama list — just enough for pick-model.sh to resolve a tier.
case "${1:-}" in
  list)
    cat <<'LIST'
NAME             ID SIZE   MODIFIED
qwen3.6:35b-a3b  aa 30 GB  1 day ago
LIST
    ;;
esac
EOF
  chmod +x "$dir/ollama"
}

make_mock_curl_ok() {
  # Mock curl: drain stdin (so the pipeline closes cleanly), copy the JSON
  # payload to a sniff file if requested, then emit a canned JSON response.
  local dir="$1" sniff="${2:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
cat > "${sniff}"
printf '%s' '{"response":"mock-model-output: ok\\n"}'
EOF
  chmod +x "$dir/curl"
}

make_mock_curl_fail() {
  # Mock curl that exits non-zero (HTTP error or connection refused).
  local dir="$1"
  cat > "$dir/curl" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "curl: connection refused" >&2
exit 7
EOF
  chmod +x "$dir/curl"
}

# 1. Missing args -> exit 2.
EC=0
out=$(bash "$SCRIPT" 2>&1) || EC=$?
assert_eq 2 "$EC" "no args -> exit 2"

EC=0
out=$(bash "$SCRIPT" prose 2>&1) || EC=$?
assert_eq 2 "$EC" "missing prompt -> exit 2"

# 2. Happy path: tier resolves, curl mock returns canned JSON, output is
# parsed cleanly, metrics file has one line with all required fields.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "happy path exits 0"
assert_contains "mock-model-output: ok" "$out" "model output is in stdout"
# Metrics line written.
lines=$(grep -c '^' "$metrics")
assert_eq 1 "$lines" "metrics file has one line"
line=$(cat "$metrics")
assert_contains '"tier":"prose"' "$line" "metrics: tier"
assert_contains '"model":"qwen3.6:35b-a3b"' "$line" "metrics: model"
assert_contains '"exit_status":0' "$line" "metrics: exit_status"
assert_contains '"prompt_chars":9' "$line" "metrics: prompt_chars"
# Sniffed payload has the expected JSON shape.
if [[ -s "$sniff" ]]; then
  payload=$(cat "$sniff")
  assert_contains '"model":"qwen3.6:35b-a3b"' "$payload" "payload: model field"
  assert_contains '"think":false' "$payload" "payload: think:false default"
  assert_contains '"stream":false' "$payload" "payload: stream:false"
  assert_contains '"temperature":0' "$payload" "payload: temperature:0"
else
  echo "  FAIL  payload sniff: file empty"; fail=$((fail+1))
fi
rm -rf "$tmp" "$metrics"

# 3. Opt-out env var suppresses metrics writing.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
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
make_mock_curl_ok "$tmp"
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

# 6. DELEGATE_THINK=true overrides default false in payload.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_THINK=true \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=true: exits 0"
assert_contains '"think":true' "$(cat "$sniff")" "payload: think:true when overridden"
rm -rf "$tmp" "$metrics"

# 6b. DELEGATE_THINK with a non-boolean stray value is normalised to false
# (so a jq parse error can't kill the delegation).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_THINK=yes \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=yes (non-boolean): still exits 0"
assert_contains '"think":false' "$(cat "$sniff")" "payload: non-boolean DELEGATE_THINK normalises to false"
rm -rf "$tmp" "$metrics"

# 7. HTTP failure (curl non-zero) propagates and is logged.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_fail "$tmp"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
if [[ "$EC" -ne 0 ]]; then
  echo "  PASS  HTTP failure -> non-zero exit"; pass=$((pass+1))
else
  echo "  FAIL  HTTP failure -> non-zero exit (got $EC)"; fail=$((fail+1))
fi
assert_contains '"exit_status":7' "$(cat "$metrics")" "metrics: HTTP failure exit_status logged"
rm -rf "$tmp" "$metrics"

# 8. --recipe NAME loads prompts/NAME.md, extracts the '## Prompt template'
# fenced block, and prepends it to the model input. Variable values
# substituted via --var land inside {{key}} placeholders; the metrics line
# carries a "recipe":"NAME" field for layer-2 telemetry.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"
mkdir -p "$prompts"
cat > "$prompts/sample.md" <<'EOF'
# sample

## When to use
Test recipe.

## Prompt template

```
HEADER LINE

=== Block A ===
{{a}}

=== Block B ===
{{b}}
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe sample --var a=alpha --var b=beta prose "trailing instruction" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--recipe: exits 0"
assert_contains "mock-model-output: ok" "$out" "--recipe: model output forwarded"
payload=$(cat "$sniff")
assert_contains 'HEADER LINE' "$payload" "--recipe: template prepended to payload"
assert_contains '=== Block A ===\nalpha' "$payload" "--recipe: {{a}} substituted with alpha"
assert_contains '=== Block B ===\nbeta' "$payload" "--recipe: {{b}} substituted with beta"
assert_contains 'trailing instruction' "$payload" "--recipe: trailing prompt appended"
assert_contains '"recipe":"sample"' "$(cat "$metrics")" "metrics: recipe field present"
rm -rf "$tmp" "$metrics"

# 9. --recipe with an unknown name fails with a clear error and exit 2.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe missing prose "p" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--recipe missing -> exit 2"
assert_contains "not found" "$out" "--recipe missing: error mentions not found"
rm -rf "$tmp" "$metrics"

# 10. Unsubstituted placeholders are a hard error (exit 2, names listed).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/incomplete.md" <<'EOF'
# incomplete

## When to use
Test.

## Prompt template

```
hello {{name}} and {{other}}
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe incomplete --var name=alice prose "p" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--recipe with missing vars -> exit 2"
assert_contains "{{other}}" "$out" "--recipe: missing placeholder named in error"
rm -rf "$tmp" "$metrics"

# 11. {{stdin}} placeholder is substituted with piped stdin content; the
# stdin is NOT also appended after the recipe (would otherwise duplicate).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/stdin-recipe.md" <<'EOF'
# stdin-recipe

## When to use
Test.

## Prompt template

```
LOG FOLLOWS:
{{stdin}}
END.
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash -c 'printf "first\nsecond\n" | bash "$0" --recipe stdin-recipe prose "tail"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "--recipe with {{stdin}}: exits 0"
payload=$(cat "$sniff")
assert_contains 'LOG FOLLOWS:\nfirst\nsecond' "$payload" "--recipe: {{stdin}} substituted from pipe"
# Count occurrences of "first" — should appear once, not duplicated.
n=$(grep -o '"prompt":' "$sniff" | wc -l | tr -d ' ')
firsts=$(awk -v RS='' '{print}' "$sniff" | grep -o 'first' | wc -l | tr -d ' ')
if [[ "$firsts" == "1" ]]; then
  echo "  PASS  --recipe: stdin not duplicated when {{stdin}} marker used"; pass=$((pass+1))
else
  echo "  FAIL  --recipe: stdin appears $firsts times in payload (expected 1)"; fail=$((fail+1))
fi
rm -rf "$tmp" "$metrics"

# 12. --recipe makes the prompt arg optional (recipe carries the instruction).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/no-prompt.md" <<'EOF'
# no-prompt

## When to use
Test.

## Prompt template

```
SELF-CONTAINED INSTRUCTION
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe no-prompt prose </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--recipe without prompt arg: exits 0"
assert_contains 'SELF-CONTAINED INSTRUCTION' "$(cat "$sniff")" "--recipe: template still in payload"
rm -rf "$tmp" "$metrics"

# 13. --var value containing newlines and special punctuation survives
# substitution intact (argv-driven, not shell-re-evaluated).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/multiline.md" <<'EOF'
# multiline

## When to use
Test.

## Prompt template

```
DATA:
{{data}}
END.
```

## Calibration notes
n/a
EOF
val=$'line1\nline2 with $special "chars"'
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe multiline --var "data=$val" prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--recipe with multiline --var: exits 0"
assert_contains 'line1\nline2 with $special' "$(cat "$sniff")" "--recipe: multiline value preserved"
rm -rf "$tmp" "$metrics"

# 14. --var without '=' is rejected.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/x.md" <<'EOF'
# x

## When to use
t

## Prompt template

```
hello {{a}}
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe x --var noequals prose "p" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "--var without '=' -> exit 2"
assert_contains "key=value" "$out" "--var: error mentions key=value form"
rm -rf "$tmp" "$metrics"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
