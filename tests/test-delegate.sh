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
  # When invoked with the auto-mode MLX probe URL (/v1/models), exits 7 to
  # simulate "no MLX server reachable" so the default auto backend falls
  # back to ollama — that lets every existing ollama-shaped test keep
  # working without explicitly setting DELEGATE_BACKEND=ollama.
  #
  # #170: delegate.sh now invokes the dispatch curl with `-o body_file -w
  # "%{time_starttransfer}"` so it can capture time-to-first-byte and split
  # duration_ms into queue_wait_ms + generation_ms. The mock parses -o /
  # -w out of argv: with -o the canned response goes to the named file
  # (the body curl would normally write to stdout); with -w the mock emits
  # a synthetic TTFB on stdout (0.001 seconds → 1 queue_wait_ms after
  # awk-rounding). Without -o / -w (older callers), the canned response
  # still goes to stdout for back-compat.
  local dir="$1" sniff="${2:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
out_file=""
write_out=""
saw_probe=0
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *"/v1/models"*) saw_probe=1; shift ;;
    *) shift ;;
  esac
done
if (( saw_probe == 1 )); then exit 7; fi
cat > "${sniff}"
body='{"response":"mock-model-output: ok\\n"}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  # Substitute %{time_starttransfer} with a synthetic 1-ms value so the
  # delegate.sh awk-conversion exercises the float→int path.
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
  chmod +x "$dir/curl"
}

make_mock_curl_fail() {
  # Mock curl that exits non-zero (HTTP error or connection refused). #170:
  # the dispatch now uses `-o body_file -w "%{time_starttransfer}"`; on a
  # failure the body file stays empty and no TTFB is emitted, so the mock
  # exits before writing anything. delegate.sh handles the empty-ttfb_s
  # case by defaulting queue_wait_ms = 0 (and generation_ms = duration_ms).
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

# 15. --var value containing {{...}} (Vue/Angular bindings, Go templates,
# logs with curly braces) must NOT trigger the unsubstituted-placeholder
# guard. The guard checks the original template's placeholders, not the
# post-substitution string, so substituted content can contain anything.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/curly-content.md" <<'EOF'
# curly-content

## When to use
Test.

## Prompt template

```
Render: {{template}}
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe curly-content --var "template=Hello {{name}}, your value is {{value}}" prose "render this" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--var with {{...}} content: exits 0 (no false-positive on substituted braces)"
assert_contains 'Hello {{name}}, your value is {{value}}' "$(cat "$sniff")" "--var with curly content: payload preserved verbatim"
rm -rf "$tmp" "$metrics"

# 16. Recipe with a markdown heading inside the fenced block must extract
# the full block — the awk section-end check should not fire while inside
# a code block.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
make_mock_curl_ok "$tmp" "$sniff"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/heading-in-block.md" <<'EOF'
# heading-in-block

## When to use
Test.

## Prompt template

```
Render this with embedded headings:
## Inner heading one
content one
## Inner heading two
END_OF_TEMPLATE
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe heading-in-block prose "go" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--recipe with ## inside fence: exits 0"
payload=$(cat "$sniff")
assert_contains 'Inner heading one' "$payload" "--recipe: heading inside fence preserved"
assert_contains 'END_OF_TEMPLATE' "$payload" "--recipe: full block extracted past inner headings"
rm -rf "$tmp" "$metrics"

# 17. Recipe metric: prompt_chars includes the recipe template length so a
# 2-char prompt arg doesn't under-report a multi-line recipe template.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/sized.md" <<'EOF'
# sized

## When to use
Test.

## Prompt template

```
AAAAAAAAAA
```

## Calibration notes
n/a
EOF
# Template body is "AAAAAAAAAA" (10 chars; bash command substitution
# strips the trailing newline from awk's output).
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe sized prose "go" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "--recipe metric: exits 0"
line=$(cat "$metrics")
# 10 (template "AAAAAAAAAA") + 2 (prompt "go") = 12
assert_contains '"prompt_chars":12' "$line" "--recipe metric: prompt_chars includes template length"
rm -rf "$tmp" "$metrics"

# 12. DELEGATE_BACKEND=mlx dispatches to /v1/chat/completions, parses
# .choices[0].message.content, and tags the metrics line with backend:"mlx".
make_mock_curl_mlx_ok() {
  # Mock curl that succeeds on both the auto probe (/v1/models — returns
  # an empty success body) and the dispatch call (/v1/chat/completions —
  # returns the chat-completions shape). The argv sniff captures the LAST
  # curl invocation, which is always the dispatch (probe runs first).
  # #170: dispatch now uses `-o body_file -w "%{time_starttransfer}"`; the
  # mock parses both and writes the body to the named file when present,
  # while emitting a synthetic 1-ms TTFB to stdout via the -w format.
  local dir="$1" payload_sniff="${2:-/dev/null}" argv_sniff="${3:-/dev/null}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"/v1/models"*)
      # Probe: drain stdin, emit a minimal models-list response, exit 0.
      cat > /dev/null
      printf '%s' '{"object":"list","data":[]}'
      exit 0
      ;;
  esac
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
cat > "${payload_sniff}"
body='{"choices":[{"message":{"role":"assistant","content":"mlx-output-ok"},"finish_reason":"stop"}]}'
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

# 12a. Happy path with MLX backend: fake HF hub, fake curl, assert dispatch.
tmp=$(mktemp -d)
# Fake hub with a Qwen3.6 MLX model so prose tier resolves.
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
payload_sniff="$tmp/payload.json"
argv_sniff="$tmp/argv.txt"
make_mock_curl_mlx_ok "$tmp" "$payload_sniff" "$argv_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=mlx HF_HOME="$tmp/hf" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "MLX happy path exits 0"
assert_contains "mlx-output-ok" "$out" "MLX output parsed from .choices[0].message.content"
line=$(cat "$metrics")
assert_contains '"backend":"mlx"' "$line" "MLX metrics: backend field"
assert_contains '"model":"mlx-community/Qwen3.6-35B-A3B-Instruct-4bit"' "$line" "MLX metrics: model field"
assert_contains '"tier":"prose"' "$line" "MLX metrics: tier field"
# Sniffed argv must contain the chat-completions endpoint, not /api/generate
# or the raw /v1/completions endpoint (which bypasses the chat template and
# produces whitespace-only output on instruction-tuned models — see ROADMAP
# MLX backend track 2026-05-12).
argv=$(cat "$argv_sniff")
assert_contains "/v1/chat/completions" "$argv" "MLX dispatch hits /v1/chat/completions"
case "$argv" in
  *"/api/generate"*) echo "  FAIL  MLX dispatch must not hit /api/generate"; fail=$((fail+1));;
  *) echo "  PASS  MLX dispatch does not hit /api/generate"; pass=$((pass+1));;
esac
case "$argv" in
  *"/v1/completions"*) echo "  FAIL  MLX dispatch must not hit raw /v1/completions"; fail=$((fail+1));;
  *) echo "  PASS  MLX dispatch does not hit raw /v1/completions"; pass=$((pass+1));;
esac
# Sniffed payload uses the chat-completions shape: a messages array with a
# user-role entry, plus max_tokens, temperature:0, and
# chat_template_kwargs.enable_thinking:false (mirroring Ollama's think:false
# default so the response carries the answer in .content rather than the
# reasoning trace in .reasoning).
payload=$(cat "$payload_sniff")
assert_contains '"model":"mlx-community/Qwen3.6-35B-A3B-Instruct-4bit"' "$payload" "MLX payload: model field"
assert_contains '"max_tokens":' "$payload" "MLX payload: max_tokens (OpenAI shape)"
assert_contains '"temperature":0' "$payload" "MLX payload: temperature:0"
assert_contains '"messages":' "$payload" "MLX payload: messages array (chat-completions shape)"
assert_contains '"role":"user"' "$payload" "MLX payload: user-role message"
assert_contains '"enable_thinking":false' "$payload" "MLX payload: enable_thinking:false by default (mirrors Ollama think:false)"
case "$payload" in
  *'"think":'*) echo "  FAIL  MLX payload must not carry Ollama-only think field"; fail=$((fail+1));;
  *) echo "  PASS  MLX payload omits Ollama-only think field"; pass=$((pass+1));;
esac
case "$payload" in
  *'"prompt":'*) echo "  FAIL  MLX payload must not carry raw prompt field"; fail=$((fail+1));;
  *) echo "  PASS  MLX payload omits raw prompt field"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# 12b. Explicit DELEGATE_BACKEND=ollama tags the metrics line backend:"ollama"
# and skips the auto probe entirely. (Default backend is now auto — see 12g
# below for the unset-default test.)
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=ollama \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "explicit ollama: exits 0"
assert_contains '"backend":"ollama"' "$(cat "$metrics")" "explicit ollama tagged in metrics"
rm -rf "$tmp" "$metrics"

# 12c. Unknown DELEGATE_BACKEND value -> exit 2 with informative stderr,
# and the valid-set must mention auto alongside ollama and mlx.
EC=0
out=$(env -i PATH="$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=bogus \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "DELEGATE_BACKEND=bogus -> exit 2"
assert_contains "unknown DELEGATE_BACKEND" "$out" "DELEGATE_BACKEND=bogus -> informative stderr"
assert_contains "auto|ollama|mlx" "$out" "bogus error names auto in valid set"

# 12g. Default (unset) backend is auto: probe runs and (when MLX is
# unreachable in the test env) falls back to ollama. The mock's `/v1/models`
# branch exits 7, so the metrics line should still carry backend:"ollama".
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "default (auto) backend: exits 0"
assert_contains '"backend":"ollama"' "$(cat "$metrics")" "default auto + probe fails -> tagged ollama"
rm -rf "$tmp" "$metrics"

# 12h. Auto with reachable MLX server: probe succeeds, wrapper resolves
# the prose tier against the HF hub cache, dispatches to /v1/chat/completions,
# and the metrics line is tagged backend:"mlx".
tmp=$(mktemp -d)
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
argv_sniff="$tmp/argv.txt"
make_mock_curl_mlx_ok "$tmp" "/dev/null" "$argv_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=auto HF_HOME="$tmp/hf" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "auto + reachable MLX: exits 0"
assert_contains '"backend":"mlx"' "$(cat "$metrics")" "auto + reachable MLX: tagged mlx in metrics"
assert_contains "/v1/chat/completions" "$(cat "$argv_sniff")" "auto + reachable MLX: dispatch hits chat-completions"
rm -rf "$tmp" "$metrics"

# 12i. DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT is honoured. The probe still
# returns the canonical mock result (exit 7 from /v1/models in make_mock_curl_ok)
# regardless of timeout, but the timeout flag must reach curl's argv. We
# capture the probe's argv into a sniff file and assert --max-time appears
# with the user's value.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
probe_argv="$tmp/probe-argv.txt"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"/v1/models"*)
      printf '%s\n' "\$*" > "${probe_argv}"
      exit 7
      ;;
  esac
done
# Dispatch path: honour -o / -w (#170 introduced these on the dispatch
# curl call so delegate.sh can split duration_ms into queue/generation).
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > /dev/null
body='{"response":"mock-model-output: ok\\n"}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
chmod +x "$tmp/curl"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=auto \
  DELEGATE_BACKEND_AUTO_PROBE_TIMEOUT=3 \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "AUTO_PROBE_TIMEOUT override: exits 0"
assert_contains "--max-time 3" "$(cat "$probe_argv")" "AUTO_PROBE_TIMEOUT override flows into curl argv"
rm -rf "$tmp" "$metrics"

# 12d. MLX_HOST override is honoured by the dispatch URL.
tmp=$(mktemp -d)
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
argv_sniff="$tmp/argv.txt"
make_mock_curl_mlx_ok "$tmp" "/dev/null" "$argv_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=mlx HF_HOME="$tmp/hf" \
  MLX_HOST="http://10.0.0.5:9999" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "MLX_HOST override: exits 0"
assert_contains "http://10.0.0.5:9999/v1/chat/completions" "$(cat "$argv_sniff")" "MLX_HOST override applied to curl URL"
rm -rf "$tmp" "$metrics"

# 12e. DELEGATE_MAX_TOKENS overrides the MLX max_tokens default.
tmp=$(mktemp -d)
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
payload_sniff="$tmp/payload.json"
make_mock_curl_mlx_ok "$tmp" "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=mlx HF_HOME="$tmp/hf" \
  DELEGATE_MAX_TOKENS=16384 \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_MAX_TOKENS override: exits 0"
assert_contains '"max_tokens":16384' "$(cat "$payload_sniff")" "DELEGATE_MAX_TOKENS override flows into payload"
rm -rf "$tmp" "$metrics"

# 12f. DELEGATE_THINK=true on MLX flips chat_template_kwargs.enable_thinking
# to true (the inverse mapping of Ollama's think field — Ollama's think:true
# enables reasoning; MLX's enable_thinking:true does the same via the chat
# template).
tmp=$(mktemp -d)
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
payload_sniff="$tmp/payload.json"
make_mock_curl_mlx_ok "$tmp" "$payload_sniff"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=mlx HF_HOME="$tmp/hf" \
  DELEGATE_THINK=true \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "DELEGATE_THINK=true on MLX: exits 0"
assert_contains '"enable_thinking":true' "$(cat "$payload_sniff")" "DELEGATE_THINK=true flips enable_thinking on for MLX"
rm -rf "$tmp" "$metrics"

# 13. jq-based metrics line correctly escapes a model name with embedded
# double quotes (regression: the prior printf %s implementation would have
# emitted invalid JSON for such names). Ollama tag rules don't permit
# quotes today, but pick-model returns whatever ollama list prints, so
# defending against future schema changes is cheap.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list" ]] && cat <<'LIST'
NAME                  ID SIZE   MODIFIED
qwen3.6:35b"weird-name aa 30 GB  1 day ago
LIST
EOF
chmod +x "$tmp/ollama"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "jq-metrics: weird model name still exits 0"
line=$(cat "$metrics")
# The line must be valid JSON (jq -e would have failed under the old printf path).
if echo "$line" | jq -e . >/dev/null 2>&1; then
  echo "  PASS  jq-metrics: line is valid JSON despite embedded quote in model"
  pass=$((pass+1))
else
  echo "  FAIL  jq-metrics: produced invalid JSON for weird model name"
  echo "        line: $line"
  fail=$((fail+1))
fi
# The decoded model field round-trips exactly.
decoded_model=$(echo "$line" | jq -r '.model')
assert_eq 'qwen3.6:35b"weird-name' "$decoded_model" "jq-metrics: model field decodes to original string"
rm -rf "$tmp" "$metrics"

# 14. Verdict nudge prints to stderr on a successful call. The nudge is the
# 2026-05-18 intervention against the untracked-verdict gap (65% of prose
# delegations carried no feedback row at that point). Captures stderr
# separately from stdout so the assertion is unambiguous.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge: happy path exits 0"
stderr_content=$(cat "$stderr_file")
assert_contains "delegate: record verdict" "$stderr_content" "verdict-nudge: prints to stderr on success"
assert_contains "delegate-feedback.sh hit" "$stderr_content" "verdict-nudge: names hit"
assert_contains "miss" "$stderr_content" "verdict-nudge: names miss"
# Nudge stays on stderr — stdout should hold only the model output, so
# downstream pipes (e.g. `delegate.sh prose "..." | jq ...`) keep working.
if echo "$out" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge: leaked into stdout"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge: stdout unaffected"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 15. DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1 silences the nudge but keeps
# the rest of the behaviour intact (metrics row still written, model
# output still on stdout). For users who genuinely don't want the noise.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TO_OLLAMA_NO_VERDICT_NUDGE=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge opt-out: still exits 0"
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge opt-out: nudge still printed"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge opt-out: silenced"; pass=$((pass+1))
fi
# Metrics row still written under opt-out (the opt-out targets nudge only,
# not metrics — that's NO_METRICS).
assert_eq 1 "$(grep -c '^' "$metrics")" "verdict-nudge opt-out: metrics row still written"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 16. NO_METRICS=1 also silences the nudge, because there's no metrics row
# to point a verdict at. Without this guard the nudge would tell users to
# record a verdict that delegate-feedback.sh would then reject as orphan.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); rm -f "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TO_OLLAMA_NO_METRICS=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "verdict-nudge NO_METRICS: still exits 0"
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge NO_METRICS: nudge printed despite no metrics row"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge NO_METRICS: silenced"; pass=$((pass+1))
fi
rm -rf "$tmp" "$stderr_file"

# 17. Non-zero exit (pick-model failure) also silences the nudge — verdicts
# on failed calls are meaningless because there's no model output to judge.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list" ]] && echo "NAME             ID SIZE   MODIFIED
unrelated:model  zz 5 GB   1 day ago"
EOF
chmod +x "$tmp/ollama"
metrics=$(mktemp); : > "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 1 "$EC" "verdict-nudge on failure: still exits 1"
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  verdict-nudge on failure: nudge printed despite non-zero exit"; fail=$((fail+1))
else
  echo "  PASS  verdict-nudge on failure: silenced"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 18. Pre-flight canary on --recipe. Issue #110 documented stalls of 6–10
# minutes when a 35B-class prose-tier model was hit with a recipe-shaped
# prompt; the canary is a 1-token probe that fails loud before the input
# investment is sunk. The probe is identified inside the mock by its
# `"num_predict":1` (Ollama) or `"max_tokens":1` (MLX) signature; the real
# dispatch uses different values so the mock can route the two responses
# independently. Each canary test sets up a `--recipe` invocation against
# a tiny prompts/ dir and asserts (a) the probe ran, (b) the dispatch
# either followed or was skipped based on the canary outcome, and (c) the
# metrics row + exit code reflect the right state.
#
# Helper: a curl mock that distinguishes the auto-probe (/v1/models — exit
# 7 to fall back to ollama), the pre-flight canary (1-token payload —
# behaviour controlled by $4), and the real dispatch (everything else —
# always returns the canned response). Each invocation logs `canary` or
# `dispatch` to an invocations file so tests can count the dispatches.
make_mock_curl_probe_aware() {
  # #170: dispatch invocations now pass `-o body_file -w "%{time_starttransfer}"`;
  # the mock parses both and routes the canned dispatch body into the file
  # when -o is present, emitting a synthetic 1-ms TTFB on stdout via -w.
  # Canary invocations don't use -o/-w (delegate.sh sends canary output to
  # /dev/null) so their handling is unchanged.
  local dir="$1" sniff="${2:-/dev/null}" invocations_log="${3:-/dev/null}" canary_behaviour="${4:-ok}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
url=""
out_file=""
write_out=""
saw_args=( "\$@" )
for arg in "\$@"; do
  case "\$arg" in
    http*|https*) url="\$arg" ;;
  esac
done
case "\$url" in
  *"/v1/models"*) exit 7 ;;
esac
# Parse -o and -w out of argv for the dispatch path; canary path doesn't
# emit these but the loop costs nothing on either.
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
payload=\$(cat)
# Distinguish canary from dispatch by 1-token request signature. The
# follow-on character ([,}]) ensures \`"max_tokens":1\` doesn't match a
# prefix of a larger number like 1024 or 16384.
if echo "\$payload" | grep -qE '"num_predict":1|"max_tokens":1[,}]'; then
  echo "canary url=\$url" >> "${invocations_log}"
  case "${canary_behaviour}" in
    timeout)    exit 28 ;;
    refused)    exit 7 ;;
    http_error) exit 22 ;;
    *)          printf '%s' '{"response":"ok"}'; exit 0 ;;
  esac
fi
echo "dispatch url=\$url" >> "${invocations_log}"
echo "\$payload" > "${sniff}"
body='{"response":"mock-model-output: ok\\n"}'
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

setup_recipe_prompts() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/canary-recipe.md" <<'RECIPE'
# canary-recipe

## When to use
test

## Prompt template

```
CANARY-TEST TEMPLATE BODY
```

## Calibration notes
n/a
RECIPE
}

# 18a. Canary succeeds → real dispatch runs, exit 0, single metrics row.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "ok"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "canary success: exits 0"
assert_contains "mock-model-output: ok" "$out" "canary success: dispatch output reaches stdout"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 1 "$canary_count" "canary success: probe was called exactly once"
assert_eq 1 "$dispatch_count" "canary success: dispatch followed exactly once"
# Sniff carries the dispatch payload — recipe template body must be in it.
assert_contains 'CANARY-TEST TEMPLATE BODY' "$(cat "$sniff")" "canary success: dispatch carries recipe template"
# Single metrics row with status:0 (the canary itself doesn't write a row
# on success — only the final dispatch does).
lines=$(grep -c '^' "$metrics")
assert_eq 1 "$lines" "canary success: one metrics row"
assert_contains '"exit_status":0' "$(cat "$metrics")" "canary success: dispatch logged status:0"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 18b. Canary times out (curl --max-time fires, exit 28) → exit 3, no
# dispatch, stderr names the recipe + model + recovery options.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "timeout"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 3 "$EC" "canary timeout: exit 3"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 1 "$canary_count" "canary timeout: probe was called"
assert_eq 0 "$dispatch_count" "canary timeout: dispatch was NOT called"
# Sniff was not overwritten by the canary (canary doesn't write the
# sniff; only dispatch does).
if [[ -s "$sniff" ]]; then
  echo "  FAIL  canary timeout: dispatch sniff should be empty"; fail=$((fail+1))
else
  echo "  PASS  canary timeout: dispatch sniff stays empty"; pass=$((pass+1))
fi
stderr_content=$(cat "$stderr_file")
assert_contains "pre-flight canary" "$stderr_content" "canary timeout: stderr names the canary"
# Cause-specific message — gemini-code-assist flagged that the original
# wording attributed every failure to a timeout regardless of curl exit.
# Exit 28 must now read "did not return within Ns (curl --max-time fired)".
assert_contains "did not return within 10s" "$stderr_content" "canary timeout: stderr names the timeout duration"
assert_contains "curl --max-time fired" "$stderr_content" "canary timeout: stderr names the curl flag that fired"
assert_contains "recipe='canary-recipe'" "$stderr_content" "canary timeout: stderr names recipe"
assert_contains "model='qwen3.6:35b-a3b'" "$stderr_content" "canary timeout: stderr names resolved model"
assert_contains "DELEGATE_PREFLIGHT_TIMEOUT" "$stderr_content" "canary timeout: stderr suggests timeout override"
assert_contains "DELEGATE_NO_PREFLIGHT=1" "$stderr_content" "canary timeout: stderr names the opt-out"
assert_contains "hand-write" "$stderr_content" "canary timeout: stderr suggests hand-writing"
# Metrics row tagged status:3 so audit-metrics can pivot on it later.
lines=$(grep -c '^' "$metrics")
assert_eq 1 "$lines" "canary timeout: one metrics row"
metric_line=$(cat "$metrics")
assert_contains '"exit_status":3' "$metric_line" "canary timeout: metrics row tagged status:3"
assert_contains '"recipe":"canary-recipe"' "$metric_line" "canary timeout: metrics row carries recipe name"
assert_contains '"model":"qwen3.6:35b-a3b"' "$metric_line" "canary timeout: metrics row carries resolved model"
# Verdict nudge must NOT fire on a status:3 exit.
if echo "$stderr_content" | grep -q "record verdict"; then
  echo "  FAIL  canary timeout: verdict nudge leaked"; fail=$((fail+1))
else
  echo "  PASS  canary timeout: verdict nudge silenced"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 18c. DELEGATE_NO_PREFLIGHT=1 skips the canary entirely. With a canary
# mock that would have timed out, the dispatch still runs (and the mock's
# dispatch path returns success).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "timeout"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_NO_PREFLIGHT=1 \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "NO_PREFLIGHT=1: exits 0 even with timing-out canary mock"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 0 "$canary_count" "NO_PREFLIGHT=1: probe was NOT called"
assert_eq 1 "$dispatch_count" "NO_PREFLIGHT=1: dispatch was called"
rm -rf "$tmp" "$metrics"

# 18d. DELEGATE_PREFLIGHT_TIMEOUT=0 is the documented disable equivalent.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "timeout"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_PREFLIGHT_TIMEOUT=0 \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "PREFLIGHT_TIMEOUT=0: exits 0 (canary disabled)"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
assert_eq 0 "$canary_count" "PREFLIGHT_TIMEOUT=0: probe was NOT called"
rm -rf "$tmp" "$metrics"

# 18e. DELEGATE_PREFLIGHT_TIMEOUT=N flows into curl's --max-time argv on
# the canary call. Capture the canary's argv into a sniff file and assert.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
# Custom mock that records the canary's argv specifically (not the
# auto-probe's, not the dispatch's).
canary_argv="$tmp/canary-argv.txt"; : > "$canary_argv"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
  case "\$arg" in
    http*|https*) url="\$arg" ;;
  esac
done
case "\$url" in
  *"/v1/models"*) exit 7 ;;
esac
# Snapshot argv for the canary-argv assertion before we shift it parsing
# -o / -w (dispatch path uses these — #170).
argv_snapshot="\$*"
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
payload=\$(cat)
if echo "\$payload" | grep -qE '"num_predict":1|"max_tokens":1[,}]'; then
  printf '%s\n' "\$argv_snapshot" > "${canary_argv}"
  printf '%s' '{"response":"ok"}'
  exit 0
fi
body='{"response":"mock-model-output: ok\\n"}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
chmod +x "$tmp/curl"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_PREFLIGHT_TIMEOUT=7 \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "PREFLIGHT_TIMEOUT=7: exits 0"
assert_contains "--max-time 7" "$(cat "$canary_argv")" "PREFLIGHT_TIMEOUT=7 flows into curl --max-time"
rm -rf "$tmp" "$metrics"

# 18f. No --recipe → canary is skipped. A canary mock that would time out
# does not affect bare delegations (the only call is the dispatch).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "timeout"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "no --recipe: bare call exits 0 even with timing-out canary mock"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 0 "$canary_count" "no --recipe: probe was NOT called"
assert_eq 1 "$dispatch_count" "no --recipe: dispatch was called"
rm -rf "$tmp" "$metrics"

# 18g. MLX backend canary uses /v1/chat/completions with max_tokens:1.
# The canary mock writes its payload to a separate sniff file so we can
# assert against the MLX shape independently of the dispatch shape.
tmp=$(mktemp -d)
snap="$tmp/hf/hub/models--mlx-community--Qwen3.6-35B-A3B-Instruct-4bit/snapshots/abc"
mkdir -p "$snap"
touch "$snap/weights.safetensors"
canary_payload_sniff="$tmp/canary-payload.json"; : > "$canary_payload_sniff"
canary_argv_sniff="$tmp/canary-argv.txt"; : > "$canary_argv_sniff"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
  case "\$arg" in
    http*|https*) url="\$arg" ;;
  esac
done
case "\$url" in
  *"/v1/models"*)
    # Probe succeeds so auto-mode routes to MLX.
    cat > /dev/null
    printf '%s' '{"object":"list","data":[]}'
    exit 0
    ;;
esac
# Snapshot argv before parsing -o / -w (dispatch path uses these — #170).
argv_snapshot="\$*"
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
payload=\$(cat)
if echo "\$payload" | grep -qE '"max_tokens":1[,}]'; then
  echo "\$payload" > "${canary_payload_sniff}"
  printf '%s\n' "\$argv_snapshot" > "${canary_argv_sniff}"
  printf '%s' '{"choices":[{"message":{"role":"assistant","content":"k"},"finish_reason":"stop"}]}'
  exit 0
fi
body='{"choices":[{"message":{"role":"assistant","content":"mlx-ok"},"finish_reason":"stop"}]}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
chmod +x "$tmp/curl"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_BACKEND=mlx HF_HOME="$tmp/hf" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "MLX canary: exits 0"
canary_payload=$(cat "$canary_payload_sniff")
canary_argv=$(cat "$canary_argv_sniff")
assert_contains "/v1/chat/completions" "$canary_argv" "MLX canary: hits chat-completions endpoint"
assert_contains '"max_tokens":1' "$canary_payload" "MLX canary: payload carries max_tokens:1"
assert_contains '"messages":' "$canary_payload" "MLX canary: chat-completions shape"
assert_contains '"role":"user"' "$canary_payload" "MLX canary: user-role message"
assert_contains '"content":"hi"' "$canary_payload" "MLX canary: minimal 'hi' content"
assert_contains '"enable_thinking":false' "$canary_payload" "MLX canary: enable_thinking:false (mirrors dispatch default)"
rm -rf "$tmp" "$metrics"

# 18h. Ollama canary uses /api/generate with num_predict:1.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
canary_payload_sniff="$tmp/canary-payload.json"; : > "$canary_payload_sniff"
canary_argv_sniff="$tmp/canary-argv.txt"; : > "$canary_argv_sniff"
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
  case "\$arg" in
    http*|https*) url="\$arg" ;;
  esac
done
case "\$url" in
  *"/v1/models"*) exit 7 ;;
esac
# Snapshot argv before parsing -o / -w (dispatch path uses these — #170).
argv_snapshot="\$*"
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
payload=\$(cat)
if echo "\$payload" | grep -q '"num_predict":1'; then
  echo "\$payload" > "${canary_payload_sniff}"
  printf '%s\n' "\$argv_snapshot" > "${canary_argv_sniff}"
  printf '%s' '{"response":"k"}'
  exit 0
fi
body='{"response":"mock-model-output: ok\\n"}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
chmod +x "$tmp/curl"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "Ollama canary: exits 0"
canary_payload=$(cat "$canary_payload_sniff")
canary_argv=$(cat "$canary_argv_sniff")
assert_contains "/api/generate" "$canary_argv" "Ollama canary: hits /api/generate"
assert_contains '"num_predict":1' "$canary_payload" "Ollama canary: payload carries num_predict:1"
assert_contains '"prompt":"hi"' "$canary_payload" "Ollama canary: minimal 'hi' prompt"
assert_contains '"think":false' "$canary_payload" "Ollama canary: think:false (mirrors dispatch default)"
rm -rf "$tmp" "$metrics"

# 18i. Canary connection-refused (curl exit 7) → exit 3 + stderr message
# names the right cause (backend daemon may be down) rather than the
# generic timeout copy. Addresses gemini-code-assist's PR #129 review
# concern that --fail conflates non-timeout failures with timeouts.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "refused"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 3 "$EC" "canary refused: exit 3"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 1 "$canary_count" "canary refused: probe was called"
assert_eq 0 "$dispatch_count" "canary refused: dispatch was NOT called"
stderr_content=$(cat "$stderr_file")
assert_contains "could not reach" "$stderr_content" "canary refused: stderr names connection-refused cause"
assert_contains "connection refused" "$stderr_content" "canary refused: stderr names the connection failure"
case "$stderr_content" in
  *"did not return within"*)
    echo "  FAIL  canary refused: must not use timeout copy"; fail=$((fail+1));;
  *)
    echo "  PASS  canary refused: timeout copy not used"; pass=$((pass+1));;
esac
assert_contains '"exit_status":3' "$(cat "$metrics")" "canary refused: metrics row tagged status:3"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 18j. Canary HTTP-error (curl --fail on 4xx, exit 22) → exit 3 + stderr
# names the right cause (HTTP error, bad model name / invalid payload)
# rather than the generic timeout copy. Same gemini-code-assist concern.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"; : > "$sniff"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "http_error"
prompts="$tmp/prompts"
setup_recipe_prompts "$prompts"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe canary-recipe prose "tail" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 3 "$EC" "canary http_error: exit 3"
canary_count=$(grep -c '^canary' "$invocations" 2>/dev/null) || canary_count=0
dispatch_count=$(grep -c '^dispatch' "$invocations" 2>/dev/null) || dispatch_count=0
assert_eq 1 "$canary_count" "canary http_error: probe was called"
assert_eq 0 "$dispatch_count" "canary http_error: dispatch was NOT called"
stderr_content=$(cat "$stderr_file")
assert_contains "HTTP error" "$stderr_content" "canary http_error: stderr names HTTP-error cause"
case "$stderr_content" in
  *"did not return within"*)
    echo "  FAIL  canary http_error: must not use timeout copy"; fail=$((fail+1));;
  *)
    echo "  PASS  canary http_error: timeout copy not used"; pass=$((pass+1));;
esac
assert_contains '"exit_status":3' "$(cat "$metrics")" "canary http_error: metrics row tagged status:3"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 19. delegate-meta stderr line is the contract surface SKILL.md teaches
# the assistant to read. On success, the line carries model / tier / backend
# / tokens_local / duration_ms as space-separated key=value pairs. The test
# captures stderr separately so the assertions are unambiguous against the
# verdict nudge that also fires on the same path.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "delegate-meta: happy path exits 0"
stderr_content=$(cat "$stderr_file")
assert_contains "delegate-meta:" "$stderr_content" "delegate-meta: line prefix on stderr"
# String-typed fields are quoted so values containing spaces stay one
# token; integer fields stay bare. Asserting the opening quote captures
# the format contract that PR #133's gemini-code-assist review tightened.
assert_contains 'model="qwen3.6:35b-a3b' "$stderr_content" "delegate-meta: model field (quoted)"
assert_contains 'tier="prose"' "$stderr_content" "delegate-meta: tier field (quoted)"
assert_contains 'backend="ollama"' "$stderr_content" "delegate-meta: backend field (quoted)"
assert_contains "tokens_local=" "$stderr_content" "delegate-meta: tokens_local field (bare integer)"
assert_contains "duration_ms=" "$stderr_content" "delegate-meta: duration_ms field (bare integer)"
# Line is stderr-only — model output on stdout must NOT contain the meta marker.
if echo "$out" | grep -q "delegate-meta:"; then
  echo "  FAIL  delegate-meta: leaked into stdout"; fail=$((fail+1))
else
  echo "  PASS  delegate-meta: stdout unaffected"; pass=$((pass+1))
fi
# tokens_local matches the chars/4 formula across prompt + context + output.
# Prompt "Summarise" is 9 chars; no context (stdin closed); output is the
# mock's "mock-model-output: ok\n" which is 21 chars after the JSON-encoded
# newline becomes literal. (9 + 0 + 21) / 4 = 7. Extract the value and
# compare numerically rather than asserting a literal string so any future
# adjustment to the mock output is caught as a clean mismatch rather than a
# silent equality drift.
meta_line=$(grep '^delegate-meta:' "$stderr_file")
tokens_val=$(printf '%s' "$meta_line" | grep -oE 'tokens_local=[0-9]+' | cut -d= -f2)
if [[ -n "$tokens_val" && "$tokens_val" =~ ^[0-9]+$ ]] && (( tokens_val >= 0 )); then
  echo "  PASS  delegate-meta: tokens_local is a non-negative integer ($tokens_val)"
  pass=$((pass+1))
else
  echo "  FAIL  delegate-meta: tokens_local missing or non-numeric ('$tokens_val')"
  fail=$((fail+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 20. DELEGATE_TO_OLLAMA_NO_META=1 silences the meta line but the rest of
# the delegation still runs (metrics row written, model output on stdout,
# verdict nudge still fires — meta and nudge are independent surfaces with
# independent opt-outs).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_TO_OLLAMA_NO_META=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "delegate-meta opt-out: still exits 0"
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "delegate-meta:"; then
  echo "  FAIL  delegate-meta opt-out: line still printed"; fail=$((fail+1))
else
  echo "  PASS  delegate-meta opt-out: silenced"; pass=$((pass+1))
fi
# Verdict nudge still fires — opt-out is meta-only.
assert_contains "record verdict" "$stderr_content" "delegate-meta opt-out: verdict nudge unaffected"
# Metrics row still written — opt-out is meta-only.
assert_eq 1 "$(grep -c '^' "$metrics")" "delegate-meta opt-out: metrics row still written"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 21. Non-zero exit (pick-model failure) silences the meta line — counts
# on a failed call would point at nothing, since there's no model output.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list" ]] && echo "NAME             ID SIZE   MODIFIED
unrelated:model  zz 5 GB   1 day ago"
EOF
chmod +x "$tmp/ollama"
metrics=$(mktemp); : > "$metrics"
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 1 "$EC" "delegate-meta on failure: still exits 1"
stderr_content=$(cat "$stderr_file")
if echo "$stderr_content" | grep -q "delegate-meta:"; then
  echo "  FAIL  delegate-meta on failure: line printed despite non-zero exit"; fail=$((fail+1))
else
  echo "  PASS  delegate-meta on failure: silenced"; pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics" "$stderr_file"

# 22. --recipe NAME adds a `recipe=NAME` field to the meta line so the
# assistant can mention which recipe routed the work ("Delegated via the
# commit-message recipe to qwen3.6:35b — ~578 tokens kept local"). The
# --recipe pre-flight canary (test 18) runs first; the dispatch path is
# what emits the meta line, so use the probe-aware mock with `ok` so the
# canary passes and dispatch runs through to the meta-line code path.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/payload.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_probe_aware "$tmp" "$sniff" "$invocations" "ok"
metrics=$(mktemp)
stderr_file=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/meta-test.md" <<'EOF'
# meta-test

## When to use
Test.

## Prompt template

```
DUMMY TEMPLATE
```

## Calibration notes
n/a
EOF
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe meta-test prose "tail" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "delegate-meta with --recipe: exits 0"
assert_contains 'recipe="meta-test"' "$(cat "$stderr_file")" "delegate-meta: recipe field present and quoted when --recipe used"
rm -rf "$tmp" "$metrics" "$stderr_file"

# 23. Stdin probe regression for #169. The original `[[ ! -t 0 ]]` check
# returned true for unix-socket FDs (and other non-tty, non-pipe FDs) that
# hold no data, then `cat` blocked forever on them — hit on 2026-05-22 by
# Agent SDK callers running delegate.sh with `run_in_background:true`.
# These tests pin the new `-p /dev/stdin || -s /dev/stdin` probe.

# 23a. </dev/null redirect: not a pipe, holds no data — cat is skipped,
# context_chars==0, no hang. This is the workaround the parallel agents
# manually applied; the script now does it implicitly.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  perl -e 'alarm 5; exec @ARGV' \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin probe: </dev/null exits 0 (no hang)"
assert_contains '"context_chars":0' "$(cat "$metrics")" "stdin probe: </dev/null skips cat (context_chars=0)"
rm -rf "$tmp" "$metrics"

# 23b. Real piped stdin still works — the fix must not break the documented
# `echo data | delegate.sh ...` flow. Mirrors test 5 but with the explicit
# perl-alarm wrapper to assert no-hang.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  perl -e 'alarm 5; exec @ARGV' \
  bash -c 'printf "%s" "piped-data" | bash "$0" prose "Summarise"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin probe: piped data exits 0"
assert_contains '"context_chars":10' "$(cat "$metrics")" "stdin probe: piped data captured (10 chars)"
rm -rf "$tmp" "$metrics"

# 23c. Socket-FD simulation — the actual bug-mode regression test. perl's
# socketpair() gives a real AF_UNIX SOCK_STREAM pair; we hand one end to
# delegate.sh as stdin and keep the other end open in a child process
# without ever writing or closing it. Under the old `! -t 0` check, `cat`
# would block waiting for an EOF that never arrives; under the new probe,
# the script sees neither a pipe nor data and skips cat. The perl alarm
# kills the run after 5s if the bug returns — exit 142 from a hang is a
# clear regression signal versus exit 0 with context_chars=0 from the fix.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  perl -e '
use Socket;
socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $pid = fork();
if ($pid == 0) {
  close($b);
  sleep 30;
  exit 0;
}
close($a);
open(STDIN, "<&", fileno($b)) or die "dup: $!";
$SIG{ALRM} = sub { kill 9, $pid; exit 142 };
alarm 5;
my $rc = system(@ARGV);
kill 9, $pid;
exit($rc >> 8);
' bash "$SCRIPT" prose "Summarise" 2>&1) || EC=$?
assert_eq 0 "$EC" "stdin probe: empty unix socket exits 0 (no hang, #169 regression)"
assert_contains '"context_chars":0' "$(cat "$metrics")" "stdin probe: empty unix socket skips cat (context_chars=0)"
rm -rf "$tmp" "$metrics"

# 24. Queue-wait / generation-time split (#170). On a successful delegation
# the metrics row carries queue_wait_ms (time spent waiting for the Ollama
# daemon to start streaming — surfaces concurrent-caller queueing under
# parallel agents) and generation_ms (the actual model-generation slice),
# while duration_ms remains the inclusive total so existing
# metrics-summary.sh rollups still work. The mock's synthetic TTFB is
# 0.001 s → 1 ms queue_wait_ms after awk-rounding, which is below most
# real-world numbers but exercises the float→int conversion path and
# proves the field shape end-to-end. The sum-equals-duration invariant
# is the contract we promise downstream consumers (Phase 11 OTel).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "queue-wait split: happy path exits 0"
line=$(cat "$metrics")
# Field presence — both new keys must be in the JSONL row.
assert_contains '"queue_wait_ms":' "$line" "queue-wait split: queue_wait_ms field present"
assert_contains '"generation_ms":' "$line" "queue-wait split: generation_ms field present"
# Existing duration_ms field is preserved (rollups in metrics-summary.sh
# read it; #170 promises not to break them).
assert_contains '"duration_ms":' "$line" "queue-wait split: duration_ms field preserved"
# Both new fields are integers (jq's @numeric output for --argjson, so the
# JSON type is number; we additionally check the string match has no
# decimal point inside the value).
qwait_val=$(echo "$line" | jq -r '.queue_wait_ms')
gen_val=$(echo "$line" | jq -r '.generation_ms')
dur_val=$(echo "$line" | jq -r '.duration_ms')
if [[ "$qwait_val" =~ ^[0-9]+$ ]]; then
  echo "  PASS  queue-wait split: queue_wait_ms is a non-negative integer ($qwait_val)"
  pass=$((pass+1))
else
  echo "  FAIL  queue-wait split: queue_wait_ms not an integer ('$qwait_val')"
  fail=$((fail+1))
fi
if [[ "$gen_val" =~ ^[0-9]+$ ]]; then
  echo "  PASS  queue-wait split: generation_ms is a non-negative integer ($gen_val)"
  pass=$((pass+1))
else
  echo "  FAIL  queue-wait split: generation_ms not an integer ('$gen_val')"
  fail=$((fail+1))
fi
# Sum-equals-duration invariant — the two new fields together must equal
# duration_ms (no rounding gap; both are derived from integer arithmetic
# after the awk float→int conversion, so the math is exact).
sum=$((qwait_val + gen_val))
if [[ "$sum" == "$dur_val" ]]; then
  echo "  PASS  queue-wait split: queue_wait_ms + generation_ms == duration_ms ($qwait_val + $gen_val == $dur_val)"
  pass=$((pass+1))
else
  echo "  FAIL  queue-wait split: $qwait_val + $gen_val != $dur_val"
  fail=$((fail+1))
fi
# The mock emits time_starttransfer=0.001 (1 ms after rounding), so we
# expect queue_wait_ms to be exactly 1 — exercising the float→int path
# rather than the empty-string-falls-to-zero fallback.
assert_eq 1 "$qwait_val" "queue-wait split: synthetic 0.001s TTFB → 1 ms queue_wait_ms"
rm -rf "$tmp" "$metrics"

# 25. On a failed dispatch (HTTP error / connection refused), queue_wait_ms
# defaults to 0 so the sum-equals-duration invariant still holds. The
# split is meaningful only on success; on failure consumers can detect
# "no split available" by queue_wait_ms == 0 alongside exit_status != 0.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_fail "$tmp"
metrics=$(mktemp); : > "$metrics"
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
if [[ "$EC" -ne 0 ]]; then
  echo "  PASS  queue-wait split on failure: non-zero exit"
  pass=$((pass+1))
else
  echo "  FAIL  queue-wait split on failure: expected non-zero exit, got 0"
  fail=$((fail+1))
fi
line=$(cat "$metrics")
qwait_val=$(echo "$line" | jq -r '.queue_wait_ms')
gen_val=$(echo "$line" | jq -r '.generation_ms')
dur_val=$(echo "$line" | jq -r '.duration_ms')
assert_eq 0 "$qwait_val" "queue-wait split on failure: queue_wait_ms is 0"
# generation_ms absorbs the whole duration on failure so the sum invariant
# still holds — same shape downstream consumers can rely on.
sum=$((qwait_val + gen_val))
if [[ "$sum" == "$dur_val" ]]; then
  echo "  PASS  queue-wait split on failure: sum-equals-duration invariant holds ($qwait_val + $gen_val == $dur_val)"
  pass=$((pass+1))
else
  echo "  FAIL  queue-wait split on failure: $qwait_val + $gen_val != $dur_val"
  fail=$((fail+1))
fi
rm -rf "$tmp" "$metrics"

# 26. Pick-model failure (no model installed) records queue_wait_ms = 0
# and generation_ms = duration_ms — the failure happens before any HTTP
# call so the queue/generation split is structurally undefined. The two
# fields are emitted anyway so the JSON shape stays consistent across
# success and failure rows.
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
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "queue-wait split on pick-model failure: exit 1"
line=$(cat "$metrics")
# Both fields are still present even though the model never started — the
# shape is the contract surface, missing fields would break Phase 11
# OTel translation logic.
assert_contains '"queue_wait_ms":' "$line" "queue-wait split on pick-model failure: queue_wait_ms still emitted"
assert_contains '"generation_ms":' "$line" "queue-wait split on pick-model failure: generation_ms still emitted"
assert_eq 0 "$(echo "$line" | jq -r '.queue_wait_ms')" "queue-wait split on pick-model failure: queue_wait_ms == 0"

# 27. Pre-flight inputs: type validation (Phase 12 Track B, issue #161).
# Optional frontmatter `inputs:` block declares flat key:type pairs that
# delegate.sh validates before contacting the model. Supported types:
# integer | string | integer? | string? (the `?` suffix means optional).
# Lazy migration: recipes without a frontmatter inputs: block keep their
# pre-existing behaviour, and undeclared --var keys pass through.

# Helper: write a recipe with optional frontmatter + inputs block. Body uses
# {{key}} placeholders that --var will substitute.
make_typed_recipe() {
  local path="$1" frontmatter="$2"
  cat > "$path" <<RECIPE
${frontmatter}# typed-recipe

## When to use
test

## Prompt template

\`\`\`
pr_number={{pr_number}}
body={{body}}
\`\`\`

## Variables

- \`{{pr_number}}\` — PR number
- \`{{body}}\` — body

## Calibration notes
n/a
RECIPE
}

# 27a. Valid inputs: block + all required --var provided → success.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
make_typed_recipe "$prompts/typed-recipe.md" $'---\ninputs:\n  pr_number: integer\n  body: string\n---\n'
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var pr_number=123 --var body=hello prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: valid integer + string → exits 0"
assert_contains "mock-model-output: ok" "$out" "inputs: dispatch reached the model"
rm -rf "$tmp" "$metrics"

# 27b. Required --var missing → exit 2 with clear error listing missing key.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
make_typed_recipe "$prompts/typed-recipe.md" $'---\ninputs:\n  pr_number: integer\n  body: string\n---\n'
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var pr_number=123 prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "inputs: missing required --var → exit 2"
assert_contains "missing required inputs" "$out" "inputs: error names the failure mode"
assert_contains "body" "$out" "inputs: error names the missing key"
rm -rf "$tmp" "$metrics"

# 27c. --var integer fails type check → exit 2 with key/type/value named.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
make_typed_recipe "$prompts/typed-recipe.md" $'---\ninputs:\n  pr_number: integer\n  body: string\n---\n'
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var pr_number=abc --var body=hi prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "inputs: integer type-check failure → exit 2"
assert_contains "pr_number" "$out" "inputs: type error names the key"
assert_contains "integer" "$out" "inputs: type error names the declared type"
assert_contains "abc" "$out" "inputs: type error names the offending value"
rm -rf "$tmp" "$metrics"

# 27d. Optional `string?` --var missing → success (lazy migration friendly).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
# Recipe declares anchor: string? as optional; body of template references
# {{pr_number}} only so the missing --var anchor doesn't fail placeholder
# substitution.
cat > "$prompts/typed-recipe.md" <<'RECIPE'
---
inputs:
  pr_number: integer
  anchor: string?
---
# typed-recipe

## When to use
test

## Prompt template

```
pr_number={{pr_number}}
```

## Variables

- `{{pr_number}}` — PR number

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var pr_number=42 prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: optional --var missing → exits 0"
rm -rf "$tmp" "$metrics"

# 27e. Recipe without a frontmatter inputs: block → back-compat path, no
# type-check runs. This is the lazy-migration safety net so existing recipes
# work unchanged until they're touched for other reasons.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/legacy.md" <<'RECIPE'
# legacy

## When to use
test

## Prompt template

```
body={{body}}
```

## Variables

- `{{body}}` — body

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe legacy --var body=hello prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: no inputs: block → exits 0 (back-compat)"
rm -rf "$tmp" "$metrics"

# 27f. Undeclared --var passes through untouched (lazy migration — strict
# mode is deferred). A recipe declaring only `body: string` accepts a
# caller-supplied --var extra=value without complaint.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/typed-recipe.md" <<'RECIPE'
---
inputs:
  body: string
---
# typed-recipe

## When to use
test

## Prompt template

```
body={{body}} extra={{extra}}
```

## Variables

- `{{body}}` — body
- `{{extra}}` — extra

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var body=hi --var extra=undeclared prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: undeclared --var passes through → exits 0"
rm -rf "$tmp" "$metrics"

# 27g. Optional `integer?` --var present but invalid → exit 2 (the `?` only
# affects whether it's required, not whether the type check applies).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/typed-recipe.md" <<'RECIPE'
---
inputs:
  age: integer?
---
# typed-recipe

## When to use
test

## Prompt template

```
age={{age}}
```

## Variables

- `{{age}}` — age

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var age=notanint prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "inputs: optional --var still type-checked when provided → exit 2"
assert_contains "age" "$out" "inputs: optional type error names key"
assert_contains "integer" "$out" "inputs: optional type error names integer"
rm -rf "$tmp" "$metrics"

# 27h. Unsupported type in inputs: block → exit 2 (recipe authoring error).
# Today only integer/string and their `?` forms are supported.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp); : > "$metrics"
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/bad-type.md" <<'RECIPE'
---
inputs:
  count: number
---
# bad-type

## When to use
test

## Prompt template

```
count={{count}}
```

## Variables

- `{{count}}` — count

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe bad-type --var count=5 prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 2 "$EC" "inputs: unsupported type → exit 2"
assert_contains "unsupported type" "$out" "inputs: error names the failure mode"
assert_contains "count" "$out" "inputs: error names the offending input"
rm -rf "$tmp" "$metrics"

# 27i. Negative integer is accepted (real-world: error codes, offsets).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/typed-recipe.md" <<'RECIPE'
---
inputs:
  offset: integer
---
# typed-recipe

## When to use
test

## Prompt template

```
offset={{offset}}
```

## Variables

- `{{offset}}` — offset

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash "$SCRIPT" --recipe typed-recipe --var offset=-42 prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: negative integer accepted → exits 0"
rm -rf "$tmp" "$metrics"

# 27j. {{stdin}} satisfies a declared `stdin: string` input. Lets a recipe
# require the piped context via the typed surface without forcing the
# caller to pass it twice (--var + pipe).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/stdin-required.md" <<'RECIPE'
---
inputs:
  stdin: string
---
# stdin-required

## When to use
test

## Prompt template

```
LOG: {{stdin}}
```

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash -c 'echo "piped" | bash "$0" --recipe stdin-required prose "tail"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: stdin: string satisfied by pipe → exits 0"
rm -rf "$tmp" "$metrics"

# 23k. stdin: integer type-checks the piped value. Numeric piped value
# satisfies; non-numeric exits 2.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/stdin-int.md" <<'RECIPE'
---
inputs:
  stdin: integer
---
# stdin-int

## When to use
test

## Prompt template

```
N: {{stdin}}
```

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash -c 'echo "42" | bash "$0" --recipe stdin-int prose "tail"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 0 "$EC" "inputs: stdin: integer satisfied by numeric pipe → exits 0"

EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash -c 'echo "not a number" | bash "$0" --recipe stdin-int prose "tail"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 2 "$EC" "inputs: stdin: integer rejects non-numeric pipe → exits 2"
assert_contains "stdin expected type 'integer'" "$out" "inputs: stdin: integer error names the type"
rm -rf "$tmp" "$metrics"

# 23l. Missing-required error message has no trailing space (cosmetic
# fix). Pin so a future refactor doesn't re-introduce the dangling space.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
prompts="$tmp/prompts"; mkdir -p "$prompts"
cat > "$prompts/required-foo.md" <<'RECIPE'
---
inputs:
  foo: string
---
# required-foo

## When to use
test

## Prompt template

```
F: {{foo}}
```

## Calibration notes
n/a
RECIPE
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  bash -c 'bash "$0" --recipe required-foo prose "tail"' "$SCRIPT" 2>&1) || EC=$?
assert_eq 2 "$EC" "inputs: missing required exits 2"
# Capture just the first error line and assert no trailing space.
first_line=$(printf '%s\n' "$out" | grep -F 'missing required inputs:' | head -1)
if [[ "$first_line" == *' ' ]]; then
  echo "  FAIL  inputs: missing-required error has trailing whitespace"
  echo "        first_line=[$first_line]"
  fail=$((fail+1))
else
  echo "  PASS  inputs: missing-required error has no trailing whitespace"
  pass=$((pass+1))
fi
rm -rf "$tmp" "$metrics"

# ---------------------------------------------------------------------------
# Phase 11 Track A — OTLP/HTTP exporter (#134)
# When DELEGATE_OTEL_ENDPOINT is set, delegate.sh POSTs one OTLP span per
# invocation to that endpoint after the metrics row is written. The exporter
# is off by default; failures never change exit status; payload shape matches
# ADR 0007 / docs/otel-schema.md.
# ---------------------------------------------------------------------------

# Curl mock that distinguishes three call types by URL:
#   - probe (/v1/models)      — exits 7 to fall back to ollama
#   - dispatch (/api/generate or /v1/chat/completions) — returns canned body
#   - otel    (/v1/traces)    — captures body to $sniff_otel, returns 200
# Each invocation appends one "ARGS: ..." line to $invocations_log and one
# "OTEL_BODY: ..." line per OTel call so the test can count call types and
# assert OTel payload shape. Forced-failure on the OTel POST is controlled
# by $otel_behaviour: "ok" returns 0, "fail" returns 22.
make_mock_curl_otel_aware() {
  local dir="$1" dispatch_sniff="${2:-/dev/null}" otel_sniff="${3:-/dev/null}" invocations_log="${4:-/dev/null}" otel_behaviour="${5:-ok}"
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
  case "\$arg" in
    http*|https*) url="\$arg" ;;
  esac
done
case "\$url" in
  *"/v1/models"*) exit 7 ;;
  *"/v1/traces"*)
    # OTel POST — log argv, capture body, return per behaviour.
    echo "otel \$*" >> "${invocations_log}"
    cat > "${otel_sniff}"
    case "${otel_behaviour}" in
      fail)    exit 22 ;;
      timeout) exit 28 ;;
      refused) exit 7 ;;
      *)       exit 0 ;;
    esac
    ;;
esac
# Dispatch path: honour -o body_file -w "%{time_starttransfer}" (#170).
echo "dispatch \$*" >> "${invocations_log}"
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "${dispatch_sniff}"
body='{"response":"mock-model-output: ok\\n"}'
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

# OT1. DELEGATE_OTEL_ENDPOINT unset → no OTLP POST attempted. The mock's
# OTel path would never fire because the dispatch is the only http call
# made (besides the auto-probe which exits 7).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT1: endpoint unset → exits 0"
otel_count=$(grep -c '^otel' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 0 "$otel_count" "OT1: endpoint unset → zero OTel POSTs"
# Metrics row still written (the exporter is opt-in, the JSONL is not).
assert_eq 1 "$(grep -c '^' "$metrics")" "OT1: metrics row still written when exporter disabled"
rm -rf "$tmp" "$metrics"

# OT2. DELEGATE_OTEL_ENDPOINT set → exactly one OTLP POST per delegate call.
# Asserts payload contains the spec's required gen_ai.* and delegate.*
# attributes; the resourceSpans → scopeSpans → spans envelope; the span
# kind/status; the traceId/spanId fields.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT2: endpoint set → exits 0"
otel_count=$(grep -c '^otel' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 1 "$otel_count" "OT2: endpoint set → exactly one OTLP POST"
# Shape assertions on the OTel body.
otel_body=$(cat "$otel_sniff")
assert_contains '"resourceSpans"' "$otel_body" "OT2: body has resourceSpans envelope"
assert_contains '"scopeSpans"' "$otel_body" "OT2: body has scopeSpans"
assert_contains '"spans"' "$otel_body" "OT2: body has spans array"
assert_contains '"traceId":' "$otel_body" "OT2: body has traceId"
assert_contains '"spanId":' "$otel_body" "OT2: body has spanId"
# Validate it's actual JSON.
if echo "$otel_body" | jq -e . >/dev/null 2>&1; then
  echo "  PASS  OT2: body parses as JSON"
  pass=$((pass+1))
else
  echo "  FAIL  OT2: body is not valid JSON"
  fail=$((fail+1))
fi
# Required gen_ai.* attributes per docs/otel-schema.md.
assert_contains '"gen_ai.operation.name"' "$otel_body" "OT2: gen_ai.operation.name"
assert_contains '"chat"' "$otel_body" "OT2: operation.name value is 'chat'"
assert_contains '"gen_ai.provider.name"' "$otel_body" "OT2: gen_ai.provider.name"
assert_contains '"ollama"' "$otel_body" "OT2: provider.name value is 'ollama'"
assert_contains '"gen_ai.request.model"' "$otel_body" "OT2: gen_ai.request.model"
assert_contains '"qwen3.6:35b-a3b"' "$otel_body" "OT2: request.model is the resolved model"
assert_contains '"gen_ai.request.temperature"' "$otel_body" "OT2: gen_ai.request.temperature"
# Required delegate.* attributes per docs/otel-schema.md.
assert_contains '"delegate.tier"' "$otel_body" "OT2: delegate.tier"
assert_contains '"prose"' "$otel_body" "OT2: delegate.tier value is 'prose'"
assert_contains '"delegate.prompt_chars"' "$otel_body" "OT2: delegate.prompt_chars"
assert_contains '"delegate.context_chars"' "$otel_body" "OT2: delegate.context_chars"
assert_contains '"delegate.output_chars"' "$otel_body" "OT2: delegate.output_chars"
assert_contains '"delegate.queue_wait_ms"' "$otel_body" "OT2: delegate.queue_wait_ms"
assert_contains '"delegate.generation_ms"' "$otel_body" "OT2: delegate.generation_ms"
assert_contains '"delegate.estimated_tokens_avoided"' "$otel_body" "OT2: delegate.estimated_tokens_avoided"
assert_contains '"delegate.exit_status"' "$otel_body" "OT2: delegate.exit_status"
# Span kind 3 = CLIENT per the schema doc.
assert_contains '"kind":3' "$otel_body" "OT2: span kind=3 (CLIENT)"
# Status code 1 = OK on a successful call.
assert_contains '"status":{"code":1}' "$otel_body" "OT2: span status OK on exit 0"
# resource.service.name attribute.
assert_contains '"service.name"' "$otel_body" "OT2: resource has service.name"
assert_contains '"delegate-to-ollama"' "$otel_body" "OT2: resource service.name value"
# Metrics row carries the same trace/span IDs (cross-correlation enabler).
metric_line=$(cat "$metrics")
assert_contains '"otel_trace_id":"' "$metric_line" "OT2: metrics row has otel_trace_id"
assert_contains '"otel_span_id":"' "$metric_line" "OT2: metrics row has otel_span_id"
# Same IDs in the OTel body and the metrics row (the linkage is the whole point).
trace_in_metrics=$(echo "$metric_line" | jq -r '.otel_trace_id')
trace_in_otel=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].traceId')
assert_eq "$trace_in_metrics" "$trace_in_otel" "OT2: trace_id matches between metrics row and OTel body"
span_in_metrics=$(echo "$metric_line" | jq -r '.otel_span_id')
span_in_otel=$(echo "$otel_body" | jq -r '.resourceSpans[0].scopeSpans[0].spans[0].spanId')
assert_eq "$span_in_metrics" "$span_in_otel" "OT2: span_id matches between metrics row and OTel body"
# trace_id is 32 hex chars, span_id is 16 hex chars.
if [[ "$trace_in_otel" =~ ^[0-9a-f]{32}$ ]]; then
  echo "  PASS  OT2: trace_id is 32 hex chars"
  pass=$((pass+1))
else
  echo "  FAIL  OT2: trace_id is not 32 hex chars (got '$trace_in_otel')"
  fail=$((fail+1))
fi
if [[ "$span_in_otel" =~ ^[0-9a-f]{16}$ ]]; then
  echo "  PASS  OT2: span_id is 16 hex chars"
  pass=$((pass+1))
else
  echo "  FAIL  OT2: span_id is not 16 hex chars (got '$span_in_otel')"
  fail=$((fail+1))
fi
# Privacy assertion: ADR 0007's no-content rule means no prompt/output text
# attributes are present, regardless of env-var settings.
case "$otel_body" in
  *'gen_ai.prompt'*)
    echo "  FAIL  OT2: body must not contain gen_ai.prompt (no-content rule)"
    fail=$((fail+1));;
  *) echo "  PASS  OT2: body has no gen_ai.prompt"; pass=$((pass+1));;
esac
case "$otel_body" in
  *'gen_ai.completion'*)
    echo "  FAIL  OT2: body must not contain gen_ai.completion (no-content rule)"
    fail=$((fail+1));;
  *) echo "  PASS  OT2: body has no gen_ai.completion"; pass=$((pass+1));;
esac
case "$otel_body" in
  *'delegate.prompt_text'*|*'delegate.output_text'*|*'delegate.context_text'*)
    echo "  FAIL  OT2: body must not contain content-bearing attributes"
    fail=$((fail+1));;
  *) echo "  PASS  OT2: body has no content-bearing delegate.* attributes"; pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics"

# OT3. OTel POST failure (curl exit non-zero) does NOT change delegate.sh's
# exit status. The original prose response still lands on stdout. The
# metrics JSONL row still gets written.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "fail"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT3: OTel HTTP error → delegate.sh STILL exits 0"
assert_contains "mock-model-output: ok" "$out" "OT3: model output still reaches stdout"
assert_eq 1 "$(grep -c '^' "$metrics")" "OT3: metrics row still written when OTel POST fails"
# The OTel POST WAS attempted (we want failure to be silent, not skipped).
otel_count=$(grep -c '^otel' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 1 "$otel_count" "OT3: OTel POST was attempted (one curl call to the endpoint)"
rm -rf "$tmp" "$metrics"

# OT4. OTel timeout (curl exit 28 from --max-time) also doesn't change exit
# status. Same invariant as OT3 but exercises a different failure mode.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "timeout"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT4: OTel timeout → delegate.sh STILL exits 0"
assert_contains "mock-model-output: ok" "$out" "OT4: model output still reaches stdout"
rm -rf "$tmp" "$metrics"

# OT5. DELEGATE_OTEL_TIMEOUT=1 flows into curl's --max-time argv. Capture
# the OTel curl invocation's args and assert --max-time 1.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_TIMEOUT=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT5: timeout override → exits 0"
otel_args_line=$(grep '^otel' "$invocations" | head -1)
assert_contains "--max-time 1" "$otel_args_line" "OT5: --max-time 1 in OTel curl argv"
rm -rf "$tmp" "$metrics"

# OT6. DELEGATE_OTEL_HEADERS splits on comma and emits one -H per header.
# This is the auth-pass-through path Grafana Cloud / Langfuse both use.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_HEADERS="Authorization: Bearer x, X-Tenant: y" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT6: headers → exits 0"
otel_args_line=$(grep '^otel' "$invocations" | head -1)
assert_contains "Authorization: Bearer x" "$otel_args_line" "OT6: first header in argv"
assert_contains "X-Tenant: y" "$otel_args_line" "OT6: second header in argv"
# Each header is preceded by -H so they're treated as separate flags.
auth_h=$(echo "$otel_args_line" | grep -o "\-H Authorization" | head -1)
tenant_h=$(echo "$otel_args_line" | grep -o "\-H X-Tenant" | head -1)
assert_eq "-H Authorization" "$auth_h" "OT6: -H prefix on Authorization header"
assert_eq "-H X-Tenant" "$tenant_h" "OT6: -H prefix on X-Tenant header"
rm -rf "$tmp" "$metrics"

# OT7. --recipe call emits delegate.recipe as a span attribute. Bare prose-
# tier calls (OT2 above) explicitly omit the attribute per the schema.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
# probe-aware mock that ALSO recognises the OTel endpoint. Compose by
# layering: dispatch/probe path same as make_mock_curl_probe_aware (with
# canary=ok), then add the /v1/traces branch.
cat > "$tmp/curl" <<EOF
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
  case "\$arg" in
    http*|https*) url="\$arg" ;;
  esac
done
case "\$url" in
  *"/v1/models"*) exit 7 ;;
  *"/v1/traces"*)
    echo "otel \$*" >> "${invocations}"
    cat > "${otel_sniff}"
    exit 0
    ;;
esac
out_file=""
write_out=""
while (( \$# > 0 )); do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    -w) write_out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
payload=\$(cat)
if echo "\$payload" | grep -qE '"num_predict":1|"max_tokens":1[,}]'; then
  echo "canary" >> "${invocations}"
  printf '%s' '{"response":"ok"}'
  exit 0
fi
echo "dispatch" >> "${invocations}"
echo "\$payload" > "${sniff}"
body='{"response":"mock-model-output: ok\\n"}'
if [[ -n "\$out_file" ]]; then
  printf '%s' "\$body" > "\$out_file"
else
  printf '%s' "\$body"
fi
if [[ -n "\$write_out" ]]; then
  printf '%s' "\${write_out//%\\{time_starttransfer\\}/0.001}"
fi
EOF
chmod +x "$tmp/curl"
prompts="$tmp/prompts"
mkdir -p "$prompts"
cat > "$prompts/otel-recipe.md" <<'RECIPE'
# otel-recipe

## When to use
test

## Prompt template

```
RECIPE BODY
```

## Calibration notes
n/a
RECIPE
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_PROMPTS_DIR="$prompts" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" --recipe otel-recipe prose "tail" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT7: recipe call → exits 0"
otel_body=$(cat "$otel_sniff")
assert_contains '"delegate.recipe"' "$otel_body" "OT7: recipe call → delegate.recipe attribute present"
assert_contains '"otel-recipe"' "$otel_body" "OT7: delegate.recipe value matches recipe name"
# Metrics row carries the recipe too.
assert_contains '"recipe":"otel-recipe"' "$(cat "$metrics")" "OT7: metrics row carries recipe field"
rm -rf "$tmp" "$metrics"

# OT8. Pick-model failure → exit 1 still happens, OTel span is emitted with
# status ERROR (code 2). The metrics row also has exit_status:1.
tmp=$(mktemp -d)
cat > "$tmp/ollama" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "list" ]] && echo "NAME             ID SIZE   MODIFIED
unrelated:model  zz 5 GB   1 day ago"
EOF
chmod +x "$tmp/ollama"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "ok"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 1 "$EC" "OT8: pick-model failure → exit 1"
otel_count=$(grep -c '^otel' "$invocations" 2>/dev/null) || otel_count=0
assert_eq 1 "$otel_count" "OT8: OTel span emitted even on pick-model failure"
otel_body=$(cat "$otel_sniff")
assert_contains '"status":{"code":2}' "$otel_body" "OT8: span status ERROR (code 2) on non-zero exit"
assert_contains '"delegate.exit_status"' "$otel_body" "OT8: exit_status attribute present on failure span"
rm -rf "$tmp" "$metrics"

# OT9. DELEGATE_OTEL_VERBOSE=1 + failing endpoint → stderr names the failure.
# Default (verbose unset) is silent — caller doesn't see the error.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "fail"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  DELEGATE_OTEL_VERBOSE=1 \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "OT9: verbose + failure → exits 0 (failure non-fatal)"
stderr_content=$(cat "$stderr_file")
assert_contains "OTLP export failed" "$stderr_content" "OT9: verbose logs failure to stderr"
rm -rf "$tmp" "$metrics" "$stderr_file"

# OT10. Default (verbose unset) + failing endpoint → no OTLP-error mention
# on stderr. Pin the silent-by-default behaviour so a future change doesn't
# accidentally spam the caller's tool output.
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
dispatch_sniff="$tmp/dispatch.json"
otel_sniff="$tmp/otel.json"
invocations="$tmp/invocations.log"; : > "$invocations"
make_mock_curl_otel_aware "$tmp" "$dispatch_sniff" "$otel_sniff" "$invocations" "fail"
metrics=$(mktemp)
stderr_file=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  DELEGATE_OTEL_ENDPOINT="https://otlp.example.com/v1/traces" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>"$stderr_file") || EC=$?
assert_eq 0 "$EC" "OT10: default verbose + failure → exits 0"
stderr_content=$(cat "$stderr_file")
case "$stderr_content" in
  *"OTLP export failed"*)
    echo "  FAIL  OT10: default-verbose should NOT log OTLP-error to stderr"
    fail=$((fail+1));;
  *)
    echo "  PASS  OT10: default-verbose is silent on OTLP failure"
    pass=$((pass+1));;
esac
rm -rf "$tmp" "$metrics" "$stderr_file"

# OT11. Always-emit metrics IDs: trace_id / span_id are written to the
# JSONL row even when DELEGATE_OTEL_ENDPOINT is unset. This is what lets
# delegate-feedback.sh emit a linked feedback span even on rows where the
# original delegation didn't export (e.g. exporter was turned on between
# the delegation and the verdict).
tmp=$(mktemp -d)
make_mock_ollama "$tmp"
make_mock_curl_ok "$tmp"
metrics=$(mktemp)
EC=0
out=$(env -i PATH="$tmp:$SAFE_PATH" HOME="$HOME" \
  DELEGATE_METRICS_FILE="$metrics" \
  bash "$SCRIPT" prose "Summarise" </dev/null 2>&1) || EC=$?
assert_eq 0 "$EC" "OT11: endpoint unset → exits 0"
line=$(cat "$metrics")
assert_contains '"otel_trace_id":"' "$line" "OT11: metrics row carries otel_trace_id even with exporter unset"
assert_contains '"otel_span_id":"' "$line" "OT11: metrics row carries otel_span_id even with exporter unset"
rm -rf "$tmp" "$metrics"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
